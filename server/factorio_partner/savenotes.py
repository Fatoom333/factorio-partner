"""Standing rules of the owner and the helper's memo, kept per save (docs/MCP.md).

The owner asked (15.10) for rules that outlive one shift: «всё, что считаем мусором — X, Y, Z — носи в
бак вот тут». They live as plain files in the project folder the helper is started from (the owner's
choice), one folder per save:

    <FP_NOTES_DIR or <repo>/save-notes>/<save>/rules.md   — the owner's standing rules (orders)
    <FP_NOTES_DIR or <repo>/save-notes>/<save>/memo.md    — what the helper remembers about the base

``<save>`` is ``FP_SAVE_NAME``, else the forge profile of the save, else ``default``. The folder is in
``.gitignore``: the repository is public and the notes are the owner's own. The owner can edit the
files by hand; the format is a numbered markdown list, one entry per line.
Only the helper writes here, through ``partner_notes``. A rule changes only with the seq of the
owner's own chat message, checked by the server (core.op_notes), and the owner's words are kept next to
it; the memo is the helper's notes — data, not orders.
"""
from __future__ import annotations

import os
import re
from datetime import date
from pathlib import Path

from .errors import PartnerError

KINDS = ("rules", "memo")
ACTIONS = ("list", "add", "remove")
MAX_RULE = 160          # a rule is read back to the owner in one chat line (say ≤ 200)
MAX_ITEMS = {"rules": 30, "memo": 40}
MAX_TEXT = 300
MAX_QUOTE = 200
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")  # not "..": the folder stays under root()
ITEM_RE = re.compile(r"^\s*(\d+)\.\s+(.*\S)\s*$")
TITLES = {"rules": "Правила хозяина для помощника", "memo": "Память помощника о базе"}
REPO_ROOT = Path(__file__).resolve().parents[2]


def root() -> Path:
    env = os.environ.get("FP_NOTES_DIR")
    return Path(env).expanduser() if env else REPO_ROOT / "save-notes"


def save_name(config, profile: str | None = None) -> str:
    for cand in (os.environ.get("FP_SAVE_NAME"), getattr(config, "forge_profile", None), profile):
        if isinstance(cand, str) and NAME_RE.match(cand):
            return cand
    return "default"


def _path(save: str, kind: str) -> Path:
    return root() / save / f"{kind}.md"


def load(save: str, kind: str) -> list[str]:
    try:
        text = _path(save, kind).read_text(encoding="utf-8-sig")
    except OSError:
        return []
    out = []
    for line in text.splitlines():
        m = ITEM_RE.match(line)
        if m:
            out.append(m.group(2))
    return out


def _write(save: str, kind: str, items: list[str]) -> None:
    p = _path(save, kind)
    p.parent.mkdir(parents=True, exist_ok=True)
    body = "\n".join(f"{i}. {t}" for i, t in enumerate(items, 1))
    p.write_text(f"# {TITLES[kind]} ({save})\n\n{body}\n" if items else f"# {TITLES[kind]} ({save})\n",
                 encoding="utf-8")


def _clean(text) -> str:
    if not isinstance(text, str):
        raise PartnerError("bad_args", "text: must be a string")
    t = " ".join(text.split())
    if not t:
        raise PartnerError("bad_args", "text: must not be empty")
    if len(t) > MAX_TEXT:
        raise PartnerError("limit", f"text: at most {MAX_TEXT} characters")
    return t


SAID_RE = re.compile(r"^(.*?) — хозяин: «([^«»]*)»$")


def _item(i: int, line: str, kind: str) -> dict:
    """A stored line → {n, text[, owner_said]}: the owner's words are a separate field, so a rule
    text cannot pass itself off as them (rule texts never contain « » or «хозяин:», see clean_rule)."""
    if kind == "rules":
        m = SAID_RE.match(line)
        if m:
            return {"n": i, "text": m.group(1), "owner_said": m.group(2)}
    return {"n": i, "text": line}


def listing(save: str, kind: str) -> list[dict]:
    return [_item(i, t, kind) for i, t in enumerate(load(save, kind), 1)]


def _unquote(t: str) -> str:
    t = t.replace("«", '"').replace("»", '"')
    return re.sub(r"(?i)хозяин\s*:", "хозяин -", t)


def clean_rule(text) -> str:
    t = _unquote(_clean(text))
    if len(t) > MAX_RULE:
        raise PartnerError("limit", f"text: a rule is at most {MAX_RULE} characters")
    return t


# Самостоятельный режим: правило сейва ровно в одной из двух форм — «AUTO» или «AUTO: цель», маркер
# только заглавными. Маркер пишет голос, поэтому обычные правила вроде «auto refuel turrets» или
# «AUTO-sort» режим не включают. Пишется обычным путём правил (подтверждение «да»), снимается
# удалением правила; отдельного хранилища нет.
AUTO_RE = re.compile(r"^AUTO(?::\s*(\S.*))?$")
DATE_SUFFIX_RE = re.compile(r"\s*\(\d{4}-\d{2}-\d{2}\)\s*$")
MAX_GOAL = 100


def auto_match(text: str):
    """Совпадение маркера AUTO для текста правила (дата записи в конце не мешает) или ``None``."""
    return AUTO_RE.match(DATE_SUFFIX_RE.sub("", text))


def auto_state(save: str) -> dict:
    """``{on, goal, rule}`` по правилам сейва. Режим включён, пока в rules.md есть правило с маркером
    AUTO; ``goal`` — цель, если хозяин её назвал; ``rule`` — номер правила (его снимает ``remove``)."""
    for n, line in enumerate(load(save, "rules"), 1):
        m = auto_match(_item(n, line, "rules")["text"])
        if m:
            goal = (m.group(1) or "").strip(" .")
            return {"on": True, "goal": goal[:MAX_GOAL] or None, "rule": n}
    return {"on": False, "goal": None, "rule": None}


def op(save: str, kind, action, text=None, n=None, quote: str | None = None) -> dict:
    if kind not in KINDS:
        raise PartnerError("bad_args", "kind: one of " + ", ".join(KINDS))
    if action not in ACTIONS:
        raise PartnerError("bad_args", "action: one of " + ", ".join(ACTIONS))
    items = load(save, kind)
    if action == "add":
        t = clean_rule(text) if kind == "rules" else _clean(text)
        if len(items) >= MAX_ITEMS[kind]:
            raise PartnerError("limit", f"{kind}: at most {MAX_ITEMS[kind]} entries; remove one first")
        if kind == "rules" and auto_match(t) and auto_state(save)["on"]:
            raise PartnerError("bad_args", "text: самостоятельный режим уже включён — сначала снять его "
                               "правило (remove), потом записать новое")
        said = ""
        if quote is not None:
            q = " ".join(quote.split()).replace("«", '"').replace("»", '"')[:MAX_QUOTE]
            said = f" — хозяин: «{q}»"
        items.append(f"{t} ({date.today().isoformat()}){said}")
        _write(save, kind, items)
    elif action == "remove":
        if isinstance(n, bool) or not isinstance(n, int) or not 1 <= n <= len(items):
            raise PartnerError("bad_args", f"n: entry number 1..{len(items)}")
        items.pop(n - 1)
        _write(save, kind, items)
    return {"save": save, "kind": kind, "items": [_item(i, t, kind) for i, t in enumerate(items, 1)]}
