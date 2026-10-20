"""Roles of the agents that drive one helper (docs/MCP.md «Роли»).

A helper key belongs to one role: ``voice`` (answers the owner in chat and files his orders),
``pilot`` (the body: every physical action) or ``strategist`` (plans; reads only). A key of the old
form — a plain string in ``helpers.json`` — is the pilot's.

One voice and one strategist may serve every helper of the server: their keys sit in the shared
entry ``"*"`` of ``helpers.json`` (``{"voice": "<key>", "strategist": "<key>"}``). Such a key opens
its role for any helper that has a pilot key, never the pilot's rights; the pilot's key opens only
its own helper. ``"*"`` is never a helper id (it does not match ``HELPER_RE``).

The shared entry may also hold ``"host"``: the key of the dispatcher — the main chat where the owner
types to the roles directly («передай стратегу: …»). It is not an agent role: it opens one tool only,
``partner_relay``, which files the owner's words for the voice, a pilot or the strategist.

Every tool call is checked here against the role of its key before any argument check or mod call:
a role never gets past its rights, whatever the arguments.
"""
from __future__ import annotations

from typing import Any

from .errors import PartnerError

VOICE = "voice"
PILOT = "pilot"
STRATEGIST = "strategist"
HOST = "host"                       # the dispatcher's key: the owner's words from the main chat
ROLES = (VOICE, PILOT, STRATEGIST)
ALL_ROLES = ROLES + (HOST,)
SHARED = "*"                        # the shared entry of helpers.json and the scope of shared roles
SHARED_ROLES = (VOICE, STRATEGIST)  # agent roles a shared key may carry
RELAY_TO = (VOICE, PILOT, STRATEGIST)
NOT_ALLOWED = "not_allowed"
BUDGET = "budget"

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
#                            "partner_ledger.write" (put, resume) is the strategist's alone;
#   "partner_ledger.note"  — the strategist's note on the work (the voice reads it in partner_brief);
#   "partner_ledger.ask"   — a question to the owner (the server says it in chat itself): the
#                            strategist's, and the pilot's for its own body (before an action the
#                            settings put at «спросить»: its answer is the leave of the call,
#                            approved + order);
#   "partner_ledger.answer" — the asker closes its own question by the owner's real message (said_seq):
#                            the strategist its own, the pilot those of its body; never another's;
#   "partner_ledger.forget" — the owner's «забудь / отмени / не надо» (the voice alone; each call needs
#                            a real message of the owner): takes off a package, a task, a question or
#                            an order;
#   "partner_ledger.thoughts" — the owner's switch «show the strategist's thoughts» (the voice alone;
#                            each call needs a message of the owner);
#   "partner_ledger.scale" — the owner's «запусти / добавь / убери N помощников» (the voice alone;
#                            only right after a message of the owner);
#   "partner_inbox.report" — the pilot's report on a task of the strategist to its own body;
#   "partner_task"         — the strategist's tasks to a pilot (give, cancel); "partner_task.list"
#                            reads them. A task is not the owner's word: it lifts no hold and gives
#                            no leave (owner_ok), whatever its text;
#   "partner_task.owner"   — the voice cancels a task on the owner's word (cancel + said_seq): his
#                            order outranks any task of the strategist.
DRY_RUN_ACTS = frozenset({"plan_mining", "plan_belt", "build_blueprint", "build_layout",
                          "connect_entities"})
_PILOT_WRITES = frozenset({
    "partner_act", "partner_act.dry_run", "partner_cancel", "partner_cancel.all", "partner_say",
    "partner_plan", "partner_notes.write", "partner_notes.rules", "partner_hold.write",
    "partner_reflex.write", "partner_inbox.write", "partner_inbox.report", "partner_ledger.cancel",
    "partner_ledger.ask", "partner_ledger.answer",
})
ALLOWED: dict[str, frozenset[str]] = {
    VOICE: READ | {"partner_say", "partner_order", "partner_cancel.all", "partner_notes.rules",
                   "partner_task.list", "partner_task.owner",
                   "partner_ledger.thoughts", "partner_ledger.scale", "partner_ledger.forget"},
    PILOT: READ | _PILOT_WRITES,
    STRATEGIST: READ | {"partner_plan", "partner_inbox.write", "partner_act.dry_run",
                        "partner_ledger.write", "partner_ledger.cancel", "partner_ledger.note",
                        "partner_ledger.ask", "partner_ledger.answer", "partner_task",
                        "partner_task.list"},
    # the dispatcher reads nothing and drives nothing: it only hands the owner's words on
    # (and takes the owner's request to restart the roles on N helpers: partner_rescale)
    HOST: frozenset({"partner_relay", "partner_rescale"}),
}

# the evacuate reflex of the mod (EVENTS.md «evacuate»): the voice tells the owner, the strategist plans
EVACUATE_EVENTS = frozenset({"evacuate_started", "evacuated", "evacuate_restored", "evacuate_missing"})
# which events a role's partner_wait hands over (docs/MCP.md «Роли»); None — every event, as before.
# The strategist also gets the owner's player_said while it has an open question of its own (keep,
# ``asking``): it takes his answer itself (partner_ledger answer)
WAKE: dict[str, frozenset[str] | None] = {
    PILOT: None,
    VOICE: frozenset({"player_said", "owner_stop", "owner_resume", "game_reloaded", "budget_low",
                      "strategist_question", "strategist_note", "host_message", "follow_lag",
                      "owner_panel", "rescale", "task_report", "question_answered"}) | EVACUATE_EVENTS,
    STRATEGIST: frozenset({"order", "plan_done", "owner_stop", "owner_resume", "game_reloaded",
                           "died", "helper_lost", "package_verified", "package_unmet", "rescale",
                           "task_report", "owner_forgot"}) | EVACUATE_EVENTS,
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
        if a.get("report") is not None:
            return tool + ".report"
        return tool if a.get("ack") is None else tool + ".write"
    if tool == "partner_task":
        if a.get("action", "list") == "list":
            return tool + ".list"
        return tool + ".owner" if a.get("said_seq") is not None else tool
    if tool == "partner_ledger":
        act = a.get("action", "list")
        if act == "list":
            return tool
        if act in ("cancel", "note", "ask", "answer", "thoughts", "scale", "forget"):
            return tool + "." + act
        return tool + ".write"
    return tool


def allowed(role: str, tool: str, args: dict | None = None) -> bool:
    return capability(tool, args) in ALLOWED.get(role, frozenset())


def require(role: str, tool: str, args: dict | None = None) -> None:
    if not allowed(role, tool, args):
        cap = capability(tool, args)
        what = tool if cap == tool else f"{tool} ({_WRITE_FORM.get(tool, 'write')})"
        raise PartnerError(NOT_ALLOWED, f"{what} is not allowed for role {role}")


def budget_gate(level: str, role: str, tool: str, args: dict | None = None) -> None:
    """The plan-limit watchdog (budget.py, docs/MCP.md «Сторож лимита»), after ``require``.

    ``voice_only``: the pilot and the strategist keep reading and ``partner_cancel`` /
    ``partner_hold`` (stopping and holding the body costs nothing); every other write is refused.
    ``strategist_off``: the strategist may not put or resume build packages. Other levels pass."""
    if level == "voice_only" and role in (PILOT, STRATEGIST):
        cap = capability(tool, args)
        # what only stops or closes stays: cancel, hold, a task lifted by the strategist, the
        # pilot's report on a task (a duty must not keep holding the packages)
        closing = (cap in ("partner_task.list", "partner_inbox.report")
                   or (cap == "partner_task" and (args or {}).get("action") == "cancel"))
        if cap not in READ and not closing and tool not in ("partner_cancel", "partner_hold"):
            raise PartnerError(BUDGET, f"{tool}: the plan limit is nearly spent, only the mod and "
                                       "the voice work now (partner_cancel, partner_hold, partner_task "
                                       "cancel and the pilot's report stay)")
    elif level in ("strategist_off", "voice_only") and role == STRATEGIST:
        cap = capability(tool, args)
        if cap == "partner_ledger.write":
            raise PartnerError(BUDGET, "partner_ledger put/resume: the plan limit passed its first "
                                       "threshold, the strategist sets no new goals")
        if cap == "partner_task" and (args or {}).get("action") == "give":
            raise PartnerError(BUDGET, "partner_task give: the plan limit passed its first threshold, "
                                       "the strategist sets no new goals (cancel stays)")


_WRITE_FORM = {"partner_notes": "add/remove/confirm", "partner_hold": "release",
               "partner_reflex": "set", "partner_inbox": "ack/report",
               "partner_task": "give/cancel", "partner_cancel": "all",
               "partner_act": "dry_run", "partner_ledger": "put/resume/cancel/note/ask/answer/thoughts/scale/forget"}


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


def _all_keys(data: dict) -> dict[str, int]:
    """How many times each key string appears anywhere in ``helpers.json``."""
    seen: dict[str, int] = {}
    for entry in data.values():
        vals = [entry] if isinstance(entry, str) else list(entry.values()) if isinstance(entry, dict) else []
        for k in vals:
            if isinstance(k, str):
                seen[k] = seen.get(k, 0) + 1
    return seen


def shared_keys_of(data: Any, min_key: int) -> dict[str, str]:
    """The shared entry ``"*"`` of ``helpers.json`` -> {role: key} for the voice, the strategist and
    the dispatcher (``host``).

    A short key, another role and a key that appears anywhere else in the file (another role, a
    pilot of some helper) are ignored: such a key opens nothing."""
    if not isinstance(data, dict):
        return {}
    entry = data.get(SHARED)
    if not isinstance(entry, dict):
        return {}
    seen = _all_keys(data)
    return {r: k for r in SHARED_ROLES + (HOST,)
            if isinstance(k := entry.get(r), str) and len(k) >= min_key and seen.get(k) == 1}


def keep(role: str, ev: dict, asking: bool = False) -> str | None:
    """How a role's wait treats an event: "wake", "noise" (a sample, does not wake) or None (not
    handed to this role; its cursor still moves past it). ``asking`` — the role has an open question
    of its own to the owner: his messages reach it (the strategist takes the answer itself)."""
    loud = bool(ev.get("loud"))
    kinds = WAKE.get(role)
    if kinds is None:
        return "wake" if loud else "noise"
    if ev.get("kind") not in kinds and not (asking and owner_message(ev)):
        return None
    return "wake" if loud else "noise"


def owner_message(ev: dict) -> bool:
    """A chat message of the owner himself (``player_said``, ``owner:true``)."""
    d = ev.get("data")
    return ev.get("kind") == "player_said" and isinstance(d, dict) and d.get("owner") is True
