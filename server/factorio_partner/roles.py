"""Roles of the agents that drive one helper (docs/MCP.md «Роли»).

A helper key belongs to one role: ``voice`` (answers the owner in chat and files his orders),
``pilot`` (the body: every physical action) or ``strategist`` (plans; reads only). A key of the old
form — a plain string in ``helpers.json`` — is the pilot's.

Every tool call is checked here against the role of its key before any argument check or mod call:
a role never gets past its rights, whatever the arguments.
"""
from __future__ import annotations

from typing import Any

from .errors import PartnerError

VOICE = "voice"
PILOT = "pilot"
STRATEGIST = "strategist"
ROLES = (VOICE, PILOT, STRATEGIST)
NOT_ALLOWED = "not_allowed"

# tools that only read (the game, the server's notes, the inbox) whatever the arguments
_READS = frozenset({
    "partner_brief", "partner_state", "partner_map", "partner_resources", "partner_stock",
    "partner_find", "partner_status", "partner_access", "partner_ghosts", "partner_rates",
    "partner_recipes", "partner_supply", "partner_lookup", "partner_wait",
})
# the read form of a tool that also writes: ``partner_notes`` list, ``partner_hold`` without
# release, ``partner_reflex`` without set, ``partner_inbox`` without ack, ``partner_ledger`` list
_READ_FORMS = frozenset({"partner_notes", "partner_hold", "partner_reflex", "partner_inbox",
                         "partner_ledger"})
READ = _READS | _READ_FORMS

# capability names: a tool, or "<tool>.write" for the writing form of a tool from _READ_FORMS, and
# three narrow forms:
#   "partner_cancel.all"   — partner_cancel{all:true} without job (the voice: the owner's stop that
#                            the mod did not catch as a word);
#   "partner_notes.rules"  — add/remove/confirm of the owner's rules (kind "rules"): each needs a
#                            message of the owner and his "да" (notes.py), so the voice may file them;
#   "partner_act.dry_run"  — a trial run of an action that only plans (DRY_RUN_ACTS) with
#                            args.dry_run exactly true and no replace: the mod changes nothing;
#   "partner_ledger.cancel" — take a build package off (the pilot may drop one the body cannot do);
#                            "partner_ledger.write" (put, resume) is the strategist's alone.
DRY_RUN_ACTS = frozenset({"plan_mining", "plan_belt", "build_blueprint"})
_PILOT_WRITES = frozenset({
    "partner_act", "partner_act.dry_run", "partner_cancel", "partner_cancel.all", "partner_say",
    "partner_plan", "partner_notes.write", "partner_notes.rules", "partner_hold.write",
    "partner_reflex.write", "partner_inbox.write", "partner_ledger.cancel",
})
ALLOWED: dict[str, frozenset[str]] = {
    VOICE: READ | {"partner_say", "partner_order", "partner_cancel.all", "partner_notes.rules"},
    PILOT: READ | _PILOT_WRITES,
    STRATEGIST: READ | {"partner_plan", "partner_inbox.write", "partner_act.dry_run",
                        "partner_ledger.write", "partner_ledger.cancel"},
}

# which events a role's partner_wait hands over (docs/MCP.md «Роли»); None — every event, as before
WAKE: dict[str, frozenset[str] | None] = {
    PILOT: None,
    VOICE: frozenset({"player_said", "owner_stop", "owner_resume", "game_reloaded"}),
    STRATEGIST: frozenset({"order", "plan_done", "owner_stop", "owner_resume", "game_reloaded",
                           "died", "helper_lost", "package_verified", "package_unmet"}),
}


def capability(tool: str, args: dict | None) -> str:
    """The right a call needs. The read form is chosen only by the exact default value of the
    argument that switches a tool to writing; anything else counts as a write (fail closed)."""
    a = args if isinstance(args, dict) else {}
    if tool == "partner_notes":
        if a.get("action", "list") == "list":
            return tool
        return tool + (".rules" if a.get("kind") == "rules" else ".write")
    if tool == "partner_cancel":
        return tool + ".all" if a.get("all") is True and a.get("job") is None else tool
    if tool == "partner_act":
        inner = a.get("args")
        if (a.get("do") in DRY_RUN_ACTS and isinstance(inner, dict) and inner.get("dry_run") is True
                and (a.get("replace") is None or a.get("replace") is False)):
            return tool + ".dry_run"
        return tool
    if tool == "partner_hold":
        rel = a.get("release")
        return tool if rel is False or rel is None else tool + ".write"    # 0 == False, but is not it
    if tool == "partner_reflex":
        return tool if a.get("set") is None else tool + ".write"
    if tool == "partner_inbox":
        return tool if a.get("ack") is None else tool + ".write"
    if tool == "partner_ledger":
        act = a.get("action", "list")
        if act == "list":
            return tool
        return tool + (".cancel" if act == "cancel" else ".write")
    return tool


def allowed(role: str, tool: str, args: dict | None = None) -> bool:
    return capability(tool, args) in ALLOWED.get(role, frozenset())


def require(role: str, tool: str, args: dict | None = None) -> None:
    if not allowed(role, tool, args):
        cap = capability(tool, args)
        what = tool if cap == tool else f"{tool} ({_WRITE_FORM.get(tool, 'write')})"
        raise PartnerError(NOT_ALLOWED, f"{what} is not allowed for role {role}")


_WRITE_FORM = {"partner_notes": "add/remove/confirm", "partner_hold": "release",
               "partner_reflex": "set", "partner_inbox": "ack", "partner_cancel": "all",
               "partner_act": "dry_run", "partner_ledger": "put/resume/cancel"}


def keys_of(entry: Any, min_key: int) -> dict[str, str]:
    """``helpers.json`` entry -> {role: key}.

    ``"<key>"`` is the pilot's key; ``{"pilot": "<key>", "voice": "<key>", "strategist": "<key>"}``
    gives each role its own key (any of them may be absent). Unknown roles, short keys and a key
    shared by two roles of the helper are ignored: such a key opens nothing.
    """
    if isinstance(entry, str):
        raw = {PILOT: entry}
    elif isinstance(entry, dict):
        raw = {r: entry.get(r) for r in ROLES}
    else:
        return {}
    good = {r: k for r, k in raw.items() if isinstance(k, str) and len(k) >= min_key}
    seen: dict[str, int] = {}
    for k in good.values():
        seen[k] = seen.get(k, 0) + 1
    return {r: k for r, k in good.items() if seen[k] == 1}


def keep(role: str, ev: dict) -> str | None:
    """How a role's wait treats an event: "wake", "noise" (a sample, does not wake) or None (not
    handed to this role; its cursor still moves past it)."""
    loud = bool(ev.get("loud"))
    kinds = WAKE.get(role)
    if kinds is None:
        return "wake" if loud else "noise"
    if ev.get("kind") not in kinds:
        return None
    return "wake" if loud else "noise"
