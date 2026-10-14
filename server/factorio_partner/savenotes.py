"""Standing rules of the owner and the helper's memo, kept per save (revision 3.12, docs/MCP.md).

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


def listing(save: str, kind: str) -> list[dict]:
    return [{"n": i, "text": t} for i, t in enumerate(load(save, kind), 1)]


def op(save: str, kind, action, text=None, n=None, quote: str | None = None) -> dict:
    if kind not in KINDS:
        raise PartnerError("bad_args", "kind: one of " + ", ".join(KINDS))
    if action not in ACTIONS:
        raise PartnerError("bad_args", "action: one of " + ", ".join(ACTIONS))
    items = load(save, kind)
    if action == "add":
        t = _clean(text)
        if len(items) >= MAX_ITEMS[kind]:
            raise PartnerError("limit", f"{kind}: at most {MAX_ITEMS[kind]} entries; remove one first")
        said = ""
        if quote is not None:
            q = " ".join(quote.split()).replace("»", "\"")[:MAX_QUOTE]
            said = f" — хозяин: «{q}»"
        items.append(f"{t} ({date.today().isoformat()}){said}")
        _write(save, kind, items)
    elif action == "remove":
        if isinstance(n, bool) or not isinstance(n, int) or not 1 <= n <= len(items):
            raise PartnerError("bad_args", f"n: entry number 1..{len(items)}")
        items.pop(n - 1)
        _write(save, kind, items)
    return {"save": save, "kind": kind, "items": [{"n": i, "text": t} for i, t in enumerate(items, 1)]}
