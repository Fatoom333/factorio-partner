"""Which helper the owner named in a message (docs/MCP.md «Роли», ``partner_order``).

The same rules as the mod's word of the owner (``scripts/core/owner_words.lua``): the name stands
at the start or at the end of the message («Claude2, принеси железо», «принеси железо, h2»); the
name of ``h1`` is the helper name itself («Claude»), the others are «Claude h2»; accepted are
``claude2``, ``claude h2``, ``claudeh2`` and ``h2``. Case, spaces and punctuation do not matter.
The helper name is the mod setting ``partner-helper-name``; the server takes it from
``FP_HELPER_NAME`` (default «Claude»).

The text is data: it is only compared with the names, nothing in it is run.
"""
from __future__ import annotations

import os
import re

DEFAULT_NAME = "Claude"
MAX_NAME = 24               # bytes of UTF-8, as the mod cuts the name (scripts/core/nameplate.lua)
ADDRESS_SPAN = 4            # a name is at most this many words in a row
_MARKS = ("—", "–", "…", "«", "»", "“", "”")
_SEP = re.compile(r"[\s,.!?;:\"()\[\]{}<>~*/\\|=]")
_TAG = re.compile(r"\[[^\]]*\]")
_ID_N = re.compile(r"^h(\d+)$")


def clean_name(value: str | None) -> str:
    """The helper name as the mod shows it: no ``[`` ``]``, trimmed, at most MAX_NAME bytes of
    UTF-8 (a letter cut in half is dropped); empty -> DEFAULT_NAME."""
    v = re.sub(r"[\[\]]", "", value or "").strip()
    if not v:
        return DEFAULT_NAME
    v = v.encode("utf-8")[:MAX_NAME].decode("utf-8", "ignore")
    return v or DEFAULT_NAME


def base_name() -> str:
    return clean_name(os.environ.get("FP_HELPER_NAME"))


def lower(s: str) -> str:
    """Lower case as the mod's ``owner_words.lower``: Latin and Russian letters only, ё -> е."""
    out = []
    for ch in s:
        c = ord(ch)
        if 0x41 <= c <= 0x5A or 0x410 <= c <= 0x42F:
            ch = chr(c + 0x20)
        elif c in (0x401, 0x451):
            ch = "е"
        out.append(ch)
    return "".join(out)


def tokens(text: str) -> list[str]:
    """Words of a message, as the mod's ``owner_words.tokens`` makes them."""
    s = lower(" ".join(str(text or "").split()))
    s = _TAG.sub(" ", s)
    for m in _MARKS:
        s = s.replace(m, " ")
    s = _SEP.sub(" ", s)
    out = []
    for w in s.split():
        w = w.strip("-'")
        if w:
            out.append(w)
    return out


def squash(name: str) -> str:
    return "".join(tokens(name))


def display_name(hid: str, base: str | None = None) -> str:
    b = base if base is not None else base_name()
    return b if hid == "h1" else f"{b} {hid}"


def aliases(hid: str, base: str | None = None) -> set[str]:
    b = squash(display_name("h1", base))
    out = {hid}
    n = _ID_N.match(hid)
    if hid == "h1" and b:
        out.add(b)
    if n and b:
        out.add(b + n.group(1))
        out.add(b + "h" + n.group(1))
    own = squash(display_name(hid, base))
    if own:
        out.add(own)
    return out


def named(text: str, ids: list[str], base: str | None = None) -> list[str]:
    """Helpers named at the start or the end of ``text`` (in the order of ``ids``); [] — no name."""
    alias_of: dict[str, str] = {}
    for hid in ids:
        for a in aliases(hid, base):
            alias_of.setdefault(a, hid)
    toks = tokens(text)
    found: set[str] = set()

    def take(from_start: bool) -> bool:
        nonlocal toks
        for k in range(min(ADDRESS_SPAN, len(toks) - 1), 0, -1):
            part = toks[:k] if from_start else toks[len(toks) - k:]
            hid = alias_of.get("".join(part))
            if hid is not None:
                found.add(hid)
                toks = toks[k:] if from_start else toks[:len(toks) - k]
                return True
        return False

    while take(True):
        pass
    while take(False):
        pass
    return [h for h in ids if h in found]
