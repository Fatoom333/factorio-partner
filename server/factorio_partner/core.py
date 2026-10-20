"""Core operations ``op_*`` shared by the MCP server and the CLI (docs/MCP.md).

Knows nothing about MCP. Every agent call goes through ``Core._tool``:
helper key check -> argument checks -> bridge -> response size check -> per-helper log.
Errors are ``PartnerError`` (server.py turns them into ``ToolError``).

Never logged or returned: helper keys, the RCON password, blueprint strings.
"""
from __future__ import annotations

import asyncio
import contextvars
import hmac
import importlib
import json
import logging
import math
import re
import secrets
import time
from collections import OrderedDict
from typing import Any, Awaitable, Callable

from . import roles as R
from . import validate as V
from .bridge import HELPER_RE, Bridge
from . import ledger as L
from . import savenotes
from .orders import PackageBridge
from .poller import EventPoller
from .brief import build_brief
from .config import Config
from .errors import (ACCESS_DENIED, GAME_PAUSED, REPEATED_FAILURE, RESPONSE_TOO_LARGE,
                     PartnerError)

log = logging.getLogger("factorio_partner.core")

MAX_RESPONSE = 24 * 1024
MIN_KEY = 32
MAX_KEY = 256
WAIT_MAX = 55
POLL_INTERVAL = 0.5
EVENTS_LIMIT = 200
NOISY_KEEP = 6
LOUD_MAX = 40
RULE_SAID_MAX_AGE = 10 * 60 * 60   # ticks: the owner's message that asked for a rule (partner_notes)
RULE_CONFIRM_MAX_AGE = 2 * 60 * 60  # ticks: the rule question waits this long for the owner
ORDER_SAID_MAX_AGE = 10 * 60 * 60  # ticks: the owner's message behind partner_order
INBOX_MAX = 20                  # open orders per helper; more -> limit (the voice tells the owner)
ORDER_MEMORY = 4096             # said_seq already turned into orders (a message is one order)
ORDER_ACK_MAX = 20
PENDING_MAX = 64                # server-made notices queued per (helper, role)
YES_RE = re.compile(r"^\s*(да|ага|подтверждаю|yes|y|ok|ок|\+)\s*[.!]*\s*$", re.IGNORECASE)
BLOB_PART = 3500
BLOB_MAX = 1024 * 1024
FAIL_LIMIT = 3
JOB_MEMORY = 512
WAIT_BUDGET = MAX_RESPONSE      # partner_wait cuts its answer to this size itself
FIRST_POLL_BUDGET = 5.0         # RCON time for the first events poll of a wait (s)
LAST_POLL_MIN = 0.5             # ...and at least this much for any later poll (s)
_SHRINK_KEEP = ("job", "do", "code", "type", "outcome", "reason")
BLUEPRINT_RE = re.compile(r"^0[A-Za-z0-9+/=]+$")
_SECRET_FIELDS = {"key", "password", "blob_data", "blueprint", "data"}

BODY_KINDS = ("character", "player")    # STATE.md «state».body, PROTOCOL §7 «Два вида тела»

HINTS = {
    "partner_access": "pass a smaller area or radius",
    "partner_map": "reduce radius or pass types/names",
    "partner_resources": "reduce radius or pass name",
    "partner_stock": "reduce radius or pass items",
    "partner_ghosts": "reduce radius or pass a smaller area",
    "partner_rates": "pass items or a smaller top",
    "partner_recipes": "pass filter",
    "partner_find": "pass a smaller limit or fewer kinds",
    "partner_status": "pass a smaller radius or limit",
    "partner_supply": "pass a smaller depth",
    "partner_lookup": "pass a smaller limit",
    "partner_state": "",
    "partner_wait": "",     # never too large: _fit_wait cuts the page and sets more=true
    "partner_inbox": "",
}

# role of the key of the call being served (set by Core._tool for the duration of the call)
_ROLE: contextvars.ContextVar[str | None] = contextvars.ContextVar("fp_role", default=None)


def _canon(v: Any) -> str:
    return json.dumps(v, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def _as_list(v: Any) -> list:
    # PROTOCOL §1: the mod may send an empty table as {} — treat {} and [] alike
    if isinstance(v, list):
        return v
    if isinstance(v, dict) and not v:
        return []
    return []


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


class Core:
    def __init__(self, cfg: Config, bridge: Bridge | None = None, *,
                 poll_interval: float = POLL_INTERVAL,
                 clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
                 forge_module: str = "factorio_partner.forge"):
        self.cfg = cfg
        self.bridge = bridge if bridge is not None else Bridge(cfg)
        self.poll_interval = poll_interval
        self.clock = clock
        self.sleep = sleep
        self.forge_module = forge_module
        self.start_seq: int | None = None
        self._start_lock = asyncio.Lock()
        # cursors, server-made notices and wait locks are per (helper, role): the voice, the pilot
        # and the strategist of a helper wait at once and never take each other's events
        self.cursors: dict[tuple[str, str], int] = {}
        self.pending: dict[tuple[str, str], list[dict]] = {}
        self._wait_locks: dict[tuple[str, str], asyncio.Lock] = {}
        self.poller = EventPoller(self._poll_fetch, clock, fresh=poll_interval * 0.8, limit=EVENTS_LIMIT)
        self.orders: dict[str, list[dict]] = {}
        self._order_used: OrderedDict[int, None] = OrderedDict()
        self._order_n = 0
        self.job_sig: OrderedDict[tuple[str, int], str] = OrderedDict()
        self.fail_counts: dict[tuple[str, str], int] = {}
        self._ledgers: dict[str, L.Ledger] = {}
        self.packages = PackageBridge(self)     # starts and checks the strategist's packages
        self.bridge.on_reload(self._on_reload)

    # ================================================================ access
    def _load_keys(self) -> dict:
        try:
            data = json.loads(self.cfg.helpers_file.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def check_access(self, helper: Any, key: Any) -> str:
        """Constant-time key check; every failure is the same ``access denied``.

        Returns the role of the key (roles.py): every role key of the helper is compared, with no
        early exit, so the time does not tell which role a wrong key came close to."""
        ok_shape = (isinstance(helper, str) and HELPER_RE.match(helper) is not None
                    and isinstance(key, str) and MIN_KEY <= len(key) <= MAX_KEY)
        keys: dict[str, str] = {}
        if ok_shape:
            keys = R.keys_of(self._load_keys().get(helper), MIN_KEY)
        given = key.encode("utf-8", "replace")[:MAX_KEY * 4] if isinstance(key, str) else b""
        role = None
        for r in R.ROLES:
            expected = keys.get(r, "")
            match = hmac.compare_digest(expected.encode("utf-8") or b"\0" * MIN_KEY, given)
            if match and expected and role is None:
                role = r
        if not (ok_shape and role):
            log.info("access denied for helper %s",
                     helper if isinstance(helper, str) and HELPER_RE.match(helper) else "?")
            raise PartnerError(ACCESS_DENIED)
        return role

    # ================================================================ logging
    def _log_call(self, helper: str, tool: str, args: dict, code: str, started: float,
                  role: str | None = None) -> None:
        rec = {
            "t": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "tool": tool,
            "role": role,
            "args": _redact(args),
            "code": code,
            "ms": round((time.monotonic() - started) * 1000),
        }
        line = json.dumps(rec, ensure_ascii=False)
        if len(line) > 4000:
            rec["args"] = "<too large>"
            line = json.dumps(rec, ensure_ascii=False)
        try:
            self.cfg.logs_dir.mkdir(parents=True, exist_ok=True)
            with open(self.cfg.logs_dir / f"{helper}.jsonl", "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except OSError:
            log.warning("cannot write helper log")

    async def _tool(self, tool: str, helper: Any, key: Any, args: dict,
                    fn: Callable[[str], Awaitable[dict]]) -> dict:
        started = time.monotonic()
        got = self.check_access(helper, key)
        # check_access raises on every failure; a stand-in that returns the helper id (the old
        # contract) means a key of the old form, i.e. the pilot
        role = got if got in R.ROLES else R.PILOT
        code = "ok"
        token = _ROLE.set(role)
        try:
            R.require(role, tool, args)     # before any argument check or mod call
            await self._ensure_started()
            self._cursor((helper, role))    # register the role: reload notices and orders reach it
            result = await fn(helper)
            size = _json_size(result)
            if size > MAX_RESPONSE:
                hint = HINTS.get(tool, "")
                raise PartnerError(RESPONSE_TOO_LARGE,
                                   f"{size} bytes > {MAX_RESPONSE}" + (f"; {hint}" if hint else ""))
            return result
        except PartnerError as e:
            code = e.code
            raise
        except Exception:
            code = "internal"
            log.exception("tool %s failed", tool)
            raise PartnerError("internal", "server error (see server.log)") from None
        finally:
            _ROLE.reset(token)
            self._log_call(helper, tool, args, code, started, role)

    @staticmethod
    def _role() -> str:
        return _ROLE.get() or R.PILOT

    # ================================================================ events bookkeeping
    async def _ensure_started(self) -> None:
        if self.start_seq is not None:
            return
        async with self._start_lock:
            if self.start_seq is not None:
                return
            resp = await self.bridge.request("hello")
            seq = resp.get("seq")
            if not _is_int(seq) and resp.get("ok"):
                seq = (resp.get("data") or {}).get("seq")
            self.start_seq = seq if _is_int(seq) else 0

    def _on_reload(self, tick: int, seq: int | None) -> None:
        new = seq if seq is not None else 0
        self.start_seq = new
        ev = {"seq": new, "tick": tick, "helper": None, "kind": "game_reloaded",
              "data": {"tick": tick}, "loud": True}
        self.poller.reset()
        for k in list(self.cursors):
            self.cursors[k] = new
            self._notice(k, dict(ev))
        self.job_sig.clear()
        self.fail_counts.clear()
        # orders belong to the timeline that was left: drop them; the mod's seq start over from the
        # loaded save, so the used seq of the old timeline would refuse new messages of the owner
        self.orders.clear()
        self._order_used.clear()
        # the packages outlive a reload; the bridge re-reads what the loaded save runs
        self.packages.on_reload()

    def _cursor(self, key: tuple[str, str]) -> int:
        if key not in self.cursors:
            self.cursors[key] = self.start_seq or 0
        return self.cursors[key]

    def _notice(self, key: tuple[str, str], ev: dict) -> None:
        """Queue a server-made event for one (helper, role); the oldest go past PENDING_MAX."""
        q = self.pending.setdefault(key, [])
        q.append(ev)
        if len(q) > PENDING_MAX:
            del q[:len(q) - PENDING_MAX]

    async def _poll_fetch(self, helper: str, since: int, limit: int, budget: float | None) -> dict:
        return await self._mod("events", {"since": since, "helper": helper, "limit": limit},
                               None, channel="poll", budget=budget)

    def _note_event(self, helper: str, ev: dict) -> None:
        """Track consecutive job_failed per (do, args) for ``repeated_failure``; a plan ends with
        ``plan_done`` instead: ``status:"failed"`` counts as a failure of the whole plan."""
        kind = ev.get("kind")
        if kind == "plan_done":
            st = (ev.get("data") or {}).get("status") if isinstance(ev.get("data"), dict) else None
            kind = "job_failed" if st == "failed" else "job_done" if st == "done" else None
        if kind not in ("job_done", "job_failed") or ev.get("helper") not in (helper, None):
            return
        data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
        job = data.get("job")
        if not _is_int(job):
            return
        sig = self.job_sig.get((helper, job))
        if sig is None:
            return
        k = (helper, sig)
        if kind == "job_done":
            self.fail_counts.pop(k, None)
        elif data.get("code") != "cancelled":
            self.fail_counts[k] = self.fail_counts.get(k, 0) + 1

    # ================================================================ mod calls
    async def _mod(self, op: str, args: dict | None, helper: str | None,
                   channel: str = "cmd", mutating: bool = False,
                   budget: float | None = None) -> dict:
        if mutating and self.bridge.paused:
            # refresh the observation before refusing: the game may have resumed
            await self.bridge.request("hello", channel=channel)
            if self.bridge.paused:
                raise PartnerError(GAME_PAUSED, "the game is paused or the host is in the menu; wait and retry")
        resp = await self.bridge.request(op, args, helper, channel, budget=budget)
        if not resp.get("ok"):
            err = resp.get("error") if isinstance(resp.get("error"), dict) else {}
            code = err.get("code") if isinstance(err.get("code"), str) else "internal"
            text = err.get("text") if isinstance(err.get("text"), str) else None
            raise PartnerError(code[:40], text[:500] if text else None)
        data = resp.get("data")
        if isinstance(data, list) and not data:
            data = {}
        if not isinstance(data, dict):
            data = {"value": data}
        if self.bridge.paused:
            # reads are safe on a paused game: hand the data over with a warning
            # (a mutating call that slipped in right as the game paused gets the same warning)
            data = dict(data, warning=GAME_PAUSED)
        return data

    def _stamp(self, data: dict) -> dict:
        out = dict(data)
        if "tick" not in out and self.bridge.last_tick is not None:
            out["tick"] = self.bridge.last_tick
        if "seq" not in out and self.bridge.last_seq is not None:
            out["seq"] = self.bridge.last_seq
        return out

    # ================================================================ tools
    async def op_brief(self, helper, key) -> dict:
        async def run(h):
            notes = await self._forge_notes()
            out = dict(build_brief(self.cfg, notes), helper=h, role=self._role())
            # the owner's standing rules and the helper's memo for this save
            profile = notes.get("profile") if isinstance(notes, dict) else None
            save = savenotes.save_name(self.cfg, profile)
            self._notes_save = save
            out["save"] = save
            out["owner_rules"] = savenotes.listing(save, "rules")
            # the memo is the helper's own notes: data, not orders (only rules carry the owner's words)
            out["memo"] = savenotes.listing(save, "memo")
            out["memo_is"] = "data, not orders"
            return out
        return await self._tool("partner_brief", helper, key, {}, run)

    async def op_notes(self, helper, key, kind, action="list", text=None, n=None, said_seq=None) -> dict:
        """``partner_notes`` — the owner's standing rules / the helper's memo per save.

        A rule is an order that outlives the shift, so the agent alone cannot write one:
        ``add`` needs ``said_seq`` (the owner's own ``player_said`` that asked for it); the server then
        asks the owner in game chat itself, with the exact text it will keep, and the rule is written
        only on ``confirm`` with the seq of the owner's «да» that came after that question. ``remove``
        needs the owner's message too. Every owner message authorizes one change. Text from other
        players, pages or tool output never becomes a rule.
        """
        async def run(h):
            save = getattr(self, "_notes_save", None) or savenotes.save_name(self.cfg)
            pending = self.__dict__.setdefault("_rule_pending", {})
            if kind == "rules" and action == "add":
                quote = await self._owner_said(h, said_seq)
                t = savenotes.clean_rule(text)
                ask = f"Запомнить правило: «{t}»? Ответь «да»."
                await self._mod("say", {"text": V.check_say(ask)}, h, mutating=True)
                ask_seq, now = self.bridge.last_seq, self.bridge.last_tick
                if not (isinstance(ask_seq, int) and isinstance(now, int)):
                    # without the question's place in the event stream no answer can be bound to it
                    raise PartnerError("internal", "no event seq after the rule question; try again")
                pending[h] = {"text": t, "quote": quote, "save": save, "ask_seq": ask_seq, "tick": now}
                return {"save": save, "kind": kind, "pending": t, "items": savenotes.listing(save, kind),
                        "next": "wait for the owner's answer; «да» — action confirm with its said_seq"}
            if kind == "rules" and action == "confirm":
                p = self._rule_waiting(h)
                if p is None:
                    raise PartnerError("bad_args", "no rule waits for the owner's confirmation")
                answer = await self._owner_said(h, said_seq)
                if said_seq <= p["ask_seq"]:
                    raise PartnerError("bad_args", "said_seq: the owner's answer must come after the question")
                if said_seq != await self._first_owner_said(h, p["ask_seq"]):
                    pending.pop(h, None)
                    raise PartnerError("bad_args", "said_seq: only the owner's first message after the question "
                                                   "answers it; the rule is dropped")
                if not YES_RE.match(answer):
                    pending.pop(h, None)
                    raise PartnerError("bad_args", "the owner did not answer «да»: the rule is dropped")
                pending.pop(h, None)
                return savenotes.op(p["save"], kind, "add", p["text"], quote=p["quote"])
            if kind == "rules" and action == "remove":
                await self._owner_said(h, said_seq)
            if action not in savenotes.ACTIONS:
                raise PartnerError("bad_args", "action: one of list, add, remove, confirm")
            return savenotes.op(save, kind, action, text, n)
        return await self._tool("partner_notes", helper, key,
                                {"kind": kind, "action": action, "n": n, "said_seq": said_seq}, run)

    def _rule_waiting(self, helper: str) -> dict | None:
        """The rule question that still waits for the owner's answer (dropped after RULE_CONFIRM_MAX_AGE)."""
        pending = self.__dict__.setdefault("_rule_pending", {})
        p = pending.get(helper)
        if p is None:
            return None
        now, asked = self.bridge.last_tick, p.get("tick")
        if isinstance(now, int) and isinstance(asked, int) and now - asked > RULE_CONFIRM_MAX_AGE:
            pending.pop(helper, None)
            return None
        return p

    async def _first_owner_said(self, helper: str, after: int) -> int | None:
        """Seq of the owner's first player_said after event ``after`` (the server's rule question)."""
        data = await self._mod("events", {"since": after, "helper": helper, "limit": 200}, None)
        for ev in (data.get("events") or []) if isinstance(data, dict) else []:
            d = ev.get("data") if isinstance(ev, dict) else None
            if ev.get("kind") == "player_said" and isinstance(d, dict) and d.get("owner") is True:
                return ev.get("seq")
        return None

    async def _owner_said(self, helper: str, said_seq) -> str:
        if isinstance(said_seq, bool) or not isinstance(said_seq, int) or said_seq < 1:
            raise PartnerError("bad_args", "said_seq: seq of the owner's player_said that asked for this rule")
        data = await self._mod("events", {"since": said_seq - 1, "helper": helper, "limit": 1}, None)
        evs = data.get("events") if isinstance(data, dict) else None
        ev = evs[0] if isinstance(evs, list) and evs else None
        d = ev.get("data") if isinstance(ev, dict) else None
        if not (isinstance(ev, dict) and ev.get("seq") == said_seq and ev.get("kind") == "player_said"
                and isinstance(d, dict) and d.get("owner") is True and isinstance(d.get("text"), str)):
            raise PartnerError("bad_args", "said_seq: not a message of the owner (player_said, owner:true)")
        now = data.get("tick") if isinstance(data.get("tick"), int) else self.bridge.last_tick
        if isinstance(now, int) and isinstance(ev.get("tick"), int) and now - ev["tick"] > RULE_SAID_MAX_AGE:
            raise PartnerError("bad_args", "said_seq: the owner's message is too old; ask him again")
        used = self.__dict__.setdefault("_said_used", set())
        if said_seq in used:
            raise PartnerError("bad_args", "said_seq: this message of the owner was already used")
        used.add(said_seq)
        return d["text"]

    async def op_state(self, helper, key) -> dict:
        """op ``state`` (STATE.md). The answer carries ``body`` (the kind of the helper's body) and
        ``module_errors`` (the mod's counter of module and reflex failures): the agent watches the
        counter grow during the game."""
        async def run(h):
            return self._stamp(await self._state_extras(h, await self._mod("state", {}, h)))
        return await self._tool("partner_state", helper, key, {}, run)

    async def _state_extras(self, helper: str, data: dict) -> dict:
        """``body`` and ``module_errors`` come with ``state`` itself. A mod that
        does not send them yet is asked the old way — ``hello`` and ``helper_list``. A failure of
        these extra reads never hides the state the mod has already given."""
        if _is_int(data.get("module_errors")) and data.get("body") in BODY_KINDS:
            return data
        out = dict(data)
        try:
            if not _is_int(out.get("module_errors")):
                out.pop("module_errors", None)
                hello = await self._mod("hello", {}, None)
                if _is_int(hello.get("module_errors")):
                    out["module_errors"] = hello["module_errors"]
            if out.get("body") not in BODY_KINDS:
                out.pop("body", None)
                listed = await self._mod("helper_list", {}, None)
                for row in _as_list(listed.get("helpers")):
                    if isinstance(row, dict) and row.get("id") == helper and row.get("body") in BODY_KINDS:
                        out["body"] = row["body"]
        except PartnerError as e:
            log.info("state extras are not available: %s", e.code)
        return out

    async def op_map(self, helper, key, radius=16, center=None, types=None, names=None,
                     near=None) -> dict:
        a = {"radius": radius, "center": center, "types": types, "names": names, "near": near}

        async def run(h):
            args: dict = {"radius": V.number(1, 32)("radius", radius)}
            if center is not None and near is not None:
                raise V.bad("args", "use only one of center / near")
            if center is not None:
                args["center"] = V.pos("center", center)
            if near is not None:
                args["near"] = V.enum("player")("near", near)
            if types is not None:
                args["types"] = V.check_types("types", types)
            if names is not None:
                args["names"] = V.check_types("names", names)
            return await self._mod("map", args, h)
        return await self._tool("partner_map", helper, key, a, run)

    @staticmethod
    def _where(args: dict, center, near) -> None:
        """center? | near? (STATE.md): the centre of a read — a position or the owner."""
        if center is not None and near is not None:
            raise V.bad("args", "use only one of center / near")
        if center is not None:
            args["center"] = V.pos("center", center)
        if near is not None:
            args["near"] = V.enum("player")("near", near)

    async def op_resources(self, helper, key, radius=None, name=None, center=None,
                           near=None) -> dict:
        a = {"radius": radius, "name": name, "center": center, "near": near}

        async def run(h):
            args: dict = {}
            if radius is not None:
                args["radius"] = V.number(1, 128)("radius", radius)
            if name is not None:
                args["name"] = V.name("name", name)
            self._where(args, center, near)
            return await self._mod("resources", args, h)
        return await self._tool("partner_resources", helper, key, a, run)

    async def op_stock(self, helper, key, radius=None, items=None, limit=None, center=None,
                       near=None) -> dict:
        a = {"radius": radius, "items": items, "limit": limit, "center": center, "near": near}

        async def run(h):
            args: dict = {}
            if radius is not None:
                args["radius"] = V.number(1, 128)("radius", radius)
            if items is not None:
                args["items"] = V.check_names("items", items)
            if limit is not None:
                args["limit"] = V.integer(1, 200)("limit", limit)
            self._where(args, center, near)
            return await self._mod("stock", args, h)
        return await self._tool("partner_stock", helper, key, a, run)

    async def op_status(self, helper, key, radius=None, limit=None, center=None, near=None) -> dict:
        """op ``status`` (STATE.md): which machines around stand still and why."""
        a = {"radius": radius, "limit": limit, "center": center, "near": near}

        async def run(h):
            args: dict = {}
            if radius is not None:
                args["radius"] = V.number(1, V.STATUS_RADIUS_MAX)("radius", radius)
            if limit is not None:
                args["limit"] = V.integer(1, V.STATUS_LIMIT_MAX)("limit", limit)
            self._where(args, center, near)
            return await self._mod("status", args, h)
        return await self._tool("partner_status", helper, key, a, run)

    async def op_ghosts(self, helper, key, radius=None, area=None, center=None,
                        near=None) -> dict:
        a = {"radius": radius, "area": area, "center": center, "near": near}

        async def run(h):
            if radius is not None and area is not None:
                raise V.bad("args", "use only one of radius / area")
            args: dict = {}
            if radius is not None:
                args["radius"] = V.number(1, 128)("radius", radius)
            if area is not None:
                args["area"] = V.area("area", area)
            self._where(args, center, near)
            return await self._mod("ghosts", args, h)
        return await self._tool("partner_ghosts", helper, key, a, run)

    async def op_rates(self, helper, key, scope="surface", period="1m", area=None, items=None,
                       top=None, surface=None) -> dict:
        a = {"scope": scope, "period": period, "area": area, "items": items, "top": top,
             "surface": surface}

        async def run(h):
            args: dict = {"scope": V.enum("surface", "area")("scope", scope),
                          "period": V.enum("1m", "10m", "1h")("period", period)}
            if scope == "area":
                if area is None:
                    raise V.bad("area", "required for scope=area")
                args["area"] = V.area("area", area)
            elif area is not None:
                raise V.bad("area", "only for scope=area")
            if items is not None:
                args["items"] = V.check_names("items", items)
            if top is not None:
                args["top"] = V.integer(1, 100)("top", top)
            if surface is not None:
                args["surface"] = V.name("surface", surface)
            return await self._mod("rates", args, h)
        return await self._tool("partner_rates", helper, key, a, run)

    async def op_find(self, helper, key, item=None, kinds=None, surface=None, limit=None) -> dict:
        """op ``find`` (STATE.md): where the whole base makes, uses and stores an item."""
        a = {"item": item, "kinds": kinds, "surface": surface, "limit": limit}

        async def run(h):
            if item is None:
                raise V.bad("item", "required")
            args: dict = {"item": V.name("item", item)}
            if kinds is not None:
                args["kinds"] = V.check_kinds("kinds", kinds)
            if surface is not None:
                args["surface"] = V.name("surface", surface)
            if limit is not None:
                args["limit"] = V.integer(1, V.FIND_LIMIT_MAX)("limit", limit)
            return await self._mod("find", args, h)
        return await self._tool("partner_find", helper, key, a, run)

    async def op_supply(self, helper, key, item=None, count=None, depth=None) -> dict:
        """op ``supply`` (STATE.md): what an item is made of and where the base has it — the
        tree of needs with the sources of every node. The mod's answer is passed as is; one
        that does not fit the response limit is refused with a hint to lower ``depth``."""
        a = {"item": item, "count": count, "depth": depth}

        async def run(h):
            if item is None:
                raise V.bad("item", "required")
            args: dict = {"item": V.name("item", item)}
            if count is not None:
                args["count"] = V.integer(1, V.SUPPLY_COUNT_MAX)("count", count)
            if depth is not None:
                args["depth"] = V.integer(1, V.SUPPLY_DEPTH_MAX)("depth", depth)
            return await self._mod("supply", args, h)
        return await self._tool("partner_supply", helper, key, a, run)

    async def op_lookup(self, helper, key, name=None, kind=None, limit=None) -> dict:
        """op ``lookup`` (STATE.md): what a thing is in the game, as the Factoriopedia shows it —
        recipes, where it is used, machines, technologies. The mod's answer is passed as is; one that
        does not fit the response limit is refused with a hint to lower ``limit``. For ``not_found``
        the mod puts name suggestions into the text (``…; suggest: a, b``): they also go to
        ``detail.suggest``."""
        a = {"name": name, "kind": kind, "limit": limit}

        async def run(h):
            if name is None:
                raise V.bad("name", "required")
            args: dict = {"name": V.name("name", name)}
            if kind is not None:
                args["kind"] = V.enum(*V.LOOKUP_KINDS)("kind", kind)
            if limit is not None:
                args["limit"] = V.integer(1, V.LOOKUP_LIMIT_MAX)("limit", limit)
            try:
                return await self._mod("lookup", args, h)
            except PartnerError as e:
                if e.code == "not_found" and e.text and "; suggest: " in e.text:
                    tail = e.text.rsplit("; suggest: ", 1)[1]
                    names = [n for n in (s.strip() for s in tail.split(",")) if V.NAME_RE.match(n)]
                    e.detail = {"suggest": names[:5]}
                raise
        return await self._tool("partner_lookup", helper, key, a, run)

    async def op_access(self, helper, key, area=None, radius=None, center=None, near=None) -> dict:
        """op ``access`` (STATE.md): land, liquid and the exits of a site — either ``area``, or a
        square of ``radius`` around the helper, ``center`` or the owner (``near``)."""
        a = {"area": area, "radius": radius, "center": center, "near": near}

        async def run(h):
            args: dict = {}
            if area is not None:
                if radius is not None or center is not None or near is not None:
                    raise V.bad("args", "use either area or center / near with radius")
                args["area"] = V.area("area", area)
            else:
                if radius is not None:
                    args["radius"] = V.integer(1, V.ACCESS_RADIUS_MAX)("radius", radius)
                self._where(args, center, near)
            return await self._mod("access", args, h)
        return await self._tool("partner_access", helper, key, a, run)

    async def op_recipes(self, helper, key, filter=None) -> dict:  # noqa: A002
        a = {"filter": filter}

        async def run(h):
            args: dict = {}
            if filter is not None:
                args["filter"] = V.recipe_filter("filter", filter)
            return self._stamp(await self._mod("recipes", args, h))
        return await self._tool("partner_recipes", helper, key, a, run)

    async def op_act(self, helper, key, do, args=None, replace=False) -> dict:
        a = {"do": do, "args": args, "replace": replace}

        async def run(h):
            clean = V.check_act(do, args)
            rep = V.boolean("replace", replace)
            sig = _canon({"do": do, "args": clean})
            if self.fail_counts.get((h, sig), 0) >= FAIL_LIMIT:
                raise PartnerError(REPEATED_FAILURE,
                                   f"{do} with these args failed {FAIL_LIMIT} times in a row; "
                                   "change the plan or ask the owner")
            mod_args = await self._plan_to_blob(do, clean)
            if do == "plan" and "steps" in clean:
                # steps go to the mod as their own acts: a build_blueprint step with a forge plan id
                # gets the same blob upload as a single act
                mod_args = dict(clean, steps=[dict(st, args=await self._plan_to_blob(st["do"], st["args"]))
                                              for st in clean["steps"]])
            data = await self._mod("act", {"do": do, "args": mod_args, "replace": rep}, h,
                                   mutating=True)
            job = data.get("job")
            if _is_int(job):
                self.job_sig[(h, job)] = sig
                while len(self.job_sig) > JOB_MEMORY:
                    self.job_sig.popitem(last=False)
            return self._stamp(data)
        return await self._tool("partner_act", helper, key, a, run)

    async def _plan_to_blob(self, do: str, clean: dict) -> dict:
        """``build_blueprint{plan}`` -> the same args with ``blob``: the forge plan is uploaded."""
        if do != "build_blueprint" or "plan" not in clean:
            return clean
        bp = await self._load_plan(clean["plan"])
        blob = await self._upload_blob(bp)
        out = {k: v for k, v in clean.items() if k != "plan"}
        out["blob"] = blob
        return out

    async def op_cancel(self, helper, key, job=None, all=False, at_boundary=False) -> dict:  # noqa: A002
        a = {"job": job, "all": all, "at_boundary": at_boundary}

        async def run(h):
            boundary = V.boolean("at_boundary", at_boundary)
            if V.boolean("all", all):
                if job is not None:
                    raise V.bad("args", "use only one of job / all")
                if boundary:
                    raise V.bad("at_boundary", "only with job")
                args = {"all": True}
            elif job is not None:
                args = {"job": V.integer(1, 2**53)("job", job)}
                if boundary:
                    args["at_boundary"] = True
            else:
                raise V.bad("args", "pass job or all=true")
            out = await self._mod("cancel", args, h, mutating=True)
            if args.get("all"):
                # «хватит» in free form: the bridge must not start the next package on the freed body
                try:
                    self.packages.on_cancel_all(h)
                except PartnerError as e:
                    out = dict(out, warning=f"waiting packages were not paused: {e.code}")
            return self._stamp(out)
        return await self._tool("partner_cancel", helper, key, a, run)

    async def op_hold(self, helper, key, release=False, said_seq=None) -> dict:
        """``partner_hold`` -> op ``owner_hold`` (docs/EVENTS.md «Слово хозяина»).

        Without ``release`` it only reads the owner's hold on this helper. ``release=true`` lifts it
        and needs ``said_seq``: a new message of the owner (``player_said``, ``owner:true``) that came
        after the hold. The hold is lifted only by such a message that was not a stop word or a
        templated question the mod already answered; the mod also refuses a message addressed by name
        to another helper and a message that already lifted this helper's hold (a message without a
        name lifts each helper's hold once). Whether the message is an order is decided by the agent
        under its own rules.
        """
        a = {"release": release, "said_seq": said_seq}

        async def run(h):
            if not V.boolean("release", release):
                if said_seq is not None:
                    raise V.bad("said_seq", "only with release=true")
                return await self._mod("owner_hold", {}, h)
            if said_seq is None:
                raise V.bad("said_seq", "seq of the owner's new order (player_said, owner:true) is required")
            seq = V.integer(1, 2**53)("said_seq", said_seq)
            return self._stamp(await self._mod("owner_hold", {"release": True, "seq": seq}, h,
                                               mutating=True))
        return await self._tool("partner_hold", helper, key, a, run)

    async def op_reflex(self, helper, key, set=None) -> dict:  # noqa: A002
        a = {"set": set}

        async def run(h):
            if set is None:
                # `reflexes{}` without `set` only reads the current set
                return await self._mod("reflexes", {}, h)
            rset = V.check_reflexes(set)
            return await self._mod("reflexes", {"set": rset}, h, mutating=True)
        return await self._tool("partner_reflex", helper, key, a, run)

    async def op_say(self, helper, key, text) -> dict:
        a = {"text": text}

        async def run(h):
            pending = self.__dict__.setdefault("_rule_pending", {})
            if any(self._rule_waiting(x) is not None for x in list(pending)):
                # the owner's next message must answer the server's rule question, not a question of
                # this or any other helper (one owner, one chat)
                raise PartnerError("bad_args", "a rule waits for the owner's answer: no chat until he "
                                               "answers (partner_notes confirm) or 2 minutes pass")
            return await self._mod("say", {"text": V.check_say(text)}, h, mutating=True)
        return await self._tool("partner_say", helper, key, a, run)

    async def op_order(self, helper, key, said_seq=None, text=None, size=None, urgent=False) -> dict:
        """``partner_order`` — the voice files an order of the owner into the helper's inbox.

        Only with ``said_seq`` of a real message of the owner: the server reads that event from the
        mod itself (``player_said``, ``owner:true``, no ``auto_reply`` — the mod has not handled it as
        a word, not older than 10 minutes). One message is one order: a seq used once is refused.
        ``text`` is the voice's short wording; the owner's own words come with the order as
        ``owner_said``, read from the event, not from the caller.
        """
        a = {"said_seq": said_seq, "text": text, "size": size, "urgent": urgent}

        async def run(h):
            seq = V.integer(1, 2**53)("said_seq", said_seq)
            sz = V.enum(*V.ORDER_SIZES)("size", size)
            urg = V.boolean("urgent", urgent)
            t = V.check_order_text(text)
            if seq <= (self.start_seq or 0):
                # the message came before this server started or before the save was loaded: whether
                # it already became an order is unknown (the used seq live in this process only)
                raise PartnerError("bad_args", "said_seq: the message came before the server started or "
                                               "the save was loaded; ask the owner again")
            if seq in self._order_used:
                raise PartnerError("bad_args", "said_seq: this message of the owner is already an order")
            if len(self.orders.get(h, ())) >= INBOX_MAX:
                raise PartnerError("limit", f"the inbox holds {INBOX_MAX} open orders; tell the owner "
                                            "it is full")
            words, tick = await self._order_said(h, seq)
            if seq <= (self.start_seq or 0):  # the save was reloaded while reading the message
                raise PartnerError("bad_args", "said_seq: the save was loaded; ask the owner again")
            if seq in self._order_used:       # a parallel call with the same seq got there first
                raise PartnerError("bad_args", "said_seq: this message of the owner is already an order")
            if len(self.orders.get(h, ())) >= INBOX_MAX:
                raise PartnerError("limit", f"the inbox holds {INBOX_MAX} open orders; tell the owner "
                                            "it is full")
            self._order_used[seq] = None
            while len(self._order_used) > ORDER_MEMORY:
                self._order_used.popitem(last=False)
            self._order_n += 1
            order = {"id": f"o{self._order_n}", "said_seq": seq, "tick": tick, "size": sz,
                     "urgent": urg, "text": t, "owner_said": words}
            self.orders.setdefault(h, []).append(order)
            ev = {"seq": self.bridge.last_seq, "tick": self.bridge.last_tick, "helper": h,
                  "kind": "order", "data": dict(order), "loud": True}
            for role in (R.PILOT, R.STRATEGIST):
                if (h, role) in self.cursors:     # roles that have called the server get woken
                    self._notice((h, role), dict(ev))
            if sz == "large":
                # the running package finishes its step and pauses: the new order goes first
                try:
                    await self.packages.on_large_order(h, order)
                except PartnerError as e:
                    log.info("cannot pause the running package for order %s: %s", order["id"], e.code)
            return {"order": order, "open": len(self.orders[h])}
        return await self._tool("partner_order", helper, key, a, run)

    async def _order_said(self, helper: str, said_seq: int) -> tuple[str, int | None]:
        """The owner's message behind an order, read from the mod: (his text, its tick)."""
        data = await self._mod("events", {"since": said_seq - 1, "helper": helper, "limit": 1}, None)
        evs = data.get("events") if isinstance(data, dict) else None
        ev = evs[0] if isinstance(evs, list) and evs else None
        d = ev.get("data") if isinstance(ev, dict) else None
        if not (isinstance(ev, dict) and ev.get("seq") == said_seq and ev.get("kind") == "player_said"
                and isinstance(d, dict) and d.get("owner") is True and isinstance(d.get("text"), str)):
            raise PartnerError("bad_args", "said_seq: not a message of the owner (player_said, owner:true)")
        if d.get("auto_reply") is True:
            raise PartnerError("bad_args", "said_seq: the mod already answered this message as a word "
                                           "(auto_reply): it is not an order")
        now = data.get("tick") if _is_int(data.get("tick")) else self.bridge.last_tick
        if _is_int(now) and _is_int(ev.get("tick")) and now - ev["tick"] > ORDER_SAID_MAX_AGE:
            raise PartnerError("bad_args", "said_seq: the owner's message is older than 10 minutes")
        return d["text"][:500], ev.get("tick") if _is_int(ev.get("tick")) else None

    async def op_inbox(self, helper, key, ack=None) -> dict:
        """``partner_inbox`` — the owner's open orders of this helper (oldest first); ``ack`` —
        ids of orders that are done or taken over: they leave the inbox."""
        a = {"ack": ack}

        async def run(h):
            box = self.orders.setdefault(h, [])
            acked: list[str] = []
            if ack is not None:
                if (not isinstance(ack, list) or not ack or len(ack) > ORDER_ACK_MAX
                        or not all(isinstance(x, str) for x in ack)):
                    raise V.bad("ack", f"must be a list of 1..{ORDER_ACK_MAX} order ids")
                known = {o["id"] for o in box}
                unknown = [x for x in ack if x not in known]
                if unknown:
                    raise V.bad("ack", "no open order " + ", ".join(x[:20] for x in unknown[:5]))
                want = set(ack)
                acked = [o["id"] for o in box if o["id"] in want]
                if any(o["id"] in want and o.get("size") != "large" for o in box):
                    # the pilot took a small order: its first act comes after this answer
                    self.packages.on_small_ack(h)
                box[:] = [o for o in box if o["id"] not in want]
            out: dict = {"orders": [dict(o) for o in box]}
            if acked:
                out["acked"] = acked
            return self._stamp(out)
        return await self._tool("partner_inbox", helper, key, a, run)

    # ================================================================ build packages
    def ledger(self) -> L.Ledger:
        """The packages of the save the notes belong to (savenotes.save_name)."""
        save = getattr(self, "_notes_save", None) or savenotes.save_name(self.cfg)
        led = self._ledgers.get(save)
        if led is None:
            led = self._ledgers[save] = L.Ledger(save)
        return led

    async def op_ledger(self, helper, key, action="list", package=None, id=None, rev=None) -> dict:  # noqa: A002
        """``partner_ledger`` — the strategist's build packages of this helper (docs/MCP.md
        «Пакеты стройки»). ``list`` (every role): open packages without steps and the last finished
        ones; with ``id`` — that package in full. ``put`` (the strategist): a new package, the server
        starts it itself. ``resume`` (the strategist): a paused package goes back to the queue.
        ``cancel`` (the pilot and the strategist): the package leaves, its running plan is cancelled."""
        a = {"action": action, "package": package, "id": id, "rev": rev}

        async def run(h):
            act = V.enum("list", "put", "cancel", "resume")("action", action)
            led = self.ledger()
            if act != "put" and package is not None:
                raise V.bad("package", "only with action=put")
            if act == "put" and id is not None:
                raise V.bad("id", "not with action=put")
            if rev is not None and act != "put":
                raise V.bad("rev", "only with action=put")
            if act == "list":
                if id is not None:
                    p = led.get(h, V.ident("id", id))
                    if p is None:
                        raise PartnerError("not_found", f"id: no package {id}")
                    return self._stamp({"save": led.save, "rev": led.data()["rev"], "package": p})
                d = led.data()
                return self._stamp({
                    "save": led.save, "rev": d["rev"],
                    "packages": [L.compact(p) for p in d["packages"] if p.get("helper") == h],
                    "history": [p for p in d["history"] if p.get("helper") == h],
                })
            if act == "put":
                if package is None:
                    raise V.bad("package", "required for action=put")
                clean = V.check_package(package)
                r = None if rev is None else V.integer(0, 2**53)("rev", rev)
                tick = self.bridge.last_tick
                p = led.mutate(lambda d: L.add(d, h, clean, tick, r))
                return self._stamp({"package": L.compact(p), "rev": led.data()["rev"]})
            pid = V.ident("id", id) if id is not None else None
            if pid is None:
                raise V.bad("id", f"required for action={act}")
            if act == "cancel":
                return self._stamp(dict(await self.packages.cancel(h, pid), rev=led.data()["rev"]))

            def resume(d):
                p = L.find(d, pid)
                if p is None or p.get("helper") != h:
                    raise PartnerError("not_found", f"id: no open package {pid}")
                if p.get("status") != "paused":
                    raise V.bad("id", f"package {pid} is {p.get('status')}, not paused")
                p["status"] = "queued"
                p["paused_reason"] = None
                return L.compact(p)
            p = led.mutate(resume)
            return self._stamp({"package": p, "rev": led.data()["rev"]})
        return await self._tool("partner_ledger", helper, key, a, run)

    async def op_wait(self, helper, key, timeout=30, quiet=True, since=None) -> dict:
        a = {"timeout": timeout, "quiet": quiet, "since": since}

        async def run(h):
            t = V.number(0, WAIT_MAX)("timeout", timeout)
            q = V.boolean("quiet", quiet)
            s = None if since is None else V.integer(0, 2**53)("since", since)
            k = (h, self._role())
            # one wait at a time per (helper, role); the roles of a helper wait side by side
            lock = self._wait_locks.setdefault(k, asyncio.Lock())
            async with lock:
                return await self._wait(k, t, q, s)
        return await self._tool("partner_wait", helper, key, a, run)

    async def _wait(self, k: tuple[str, str], timeout: float, quiet: bool, since: int | None) -> dict:
        """Poll ``events`` (through the shared poller) until something worth waking for, or ``timeout``.

        ``k`` is (helper, role). The cursor (EVENTS.md: last seq HANDED to the agent) moves only at
        the very end, after the answer has been cut to fit ``MAX_RESPONSE``: anything not handed
        over stays in the mod's buffer (or in ``pending``) for the next call. On any exception the
        cursor is untouched and server-made notices go back to ``pending``. Events this role does
        not take (roles.keep) are passed over: the cursor moves past them.
        """
        helper, role = k
        if since is None:
            cursor = self._cursor(k)
        elif since == 0:
            resp = await self.bridge.request("hello", channel="poll")
            cursor = resp.get("seq") if _is_int(resp.get("seq")) else self._cursor(k)
        else:
            cursor = since
        self.cursors.setdefault(k, cursor)
        start_cursor = cursor
        deadline = self.clock() + timeout
        # items in arrival order: (event, origin) — origin "notice" (server-made, from pending)
        # or "mod" (from the mod's buffer)
        items: list[tuple[dict, str]] = [(ev, "notice") for ev in self.pending.pop(k, [])]
        n_loud = len(items)
        n_noisy = 0
        lost = False
        timed_out = False
        more = False
        reloaded = False
        reloads = self.bridge.reloads
        first = True
        ticket = self.poller.ticket()
        try:
            while True:
                left = deadline - self.clock()
                # the last poll must not push the call past the deadline (MCP timeouts, ≤55 s):
                # its RCON budget is what is left (at least a short minimum); the first poll gets
                # a normal budget so that timeout=0 still works on a slow tick
                budget = max(left, FIRST_POLL_BUDGET if first else LAST_POLL_MIN)
                # the first poll takes only a page fetched after the call began; later ones may
                # share a page another role of this helper fetched a moment ago
                data = await self.poller.events(helper, cursor, EVENTS_LIMIT, budget,
                                                after=ticket if first else None)
                first = False
                if self.bridge.reloads != reloads:
                    # the save was reloaded while waiting: _on_reload reset the cursor and queued
                    # game_reloaded for known roles. Events collected in this call before the
                    # reload belong to the abandoned timeline (their jobs no longer exist): drop
                    # them so the notice is never the part cut off by the size limit.
                    items = [it for it in items if it[1] == "notice"]
                    reloads = self.bridge.reloads
                    reloaded = True
                    notices = self.pending.pop(k, [])
                    cursor = self.cursors.get(k, self.start_seq or 0)
                    if not any(e.get("kind") == "game_reloaded" for e in notices):
                        notices.append({"seq": cursor, "tick": self.bridge.last_tick, "helper": None,
                                        "kind": "game_reloaded",
                                        "data": {"tick": self.bridge.last_tick}, "loud": True})
                    items.extend((ev, "notice") for ev in notices)
                    break
                evs = _as_list(data.get("events"))
                lost = lost or bool(data.get("lost"))
                full = bool(data.get("more")) or len(evs) >= EVENTS_LIMIT
                before = cursor
                stopped_early = False
                for ev in evs:
                    if not isinstance(ev, dict) or not _is_int(ev.get("seq")):
                        continue
                    if ev["seq"] <= cursor:
                        continue
                    cursor = ev["seq"]
                    how = R.keep(role, ev)
                    if how is None:
                        continue        # not this role's event: passed over
                    items.append((_fit_null(ev), "mod"))
                    if how == "wake":
                        n_loud += 1
                        if n_loud >= LOUD_MAX:
                            stopped_early = True
                            break
                    else:
                        n_noisy += 1
                        if n_noisy > NOISY_KEEP:
                            # drop the oldest noisy event: noise is a sample, not a record
                            i = next(j for j, (e, o) in enumerate(items)
                                     if o == "mod" and R.keep(role, e) == "noise")
                            del items[i]
                            n_noisy -= 1
                if not full and not stopped_early and _is_int(data.get("seq")) and data["seq"] > cursor:
                    cursor = data["seq"]
                if stopped_early or (full and cursor > before):
                    more = True
                if n_loud or (not quiet and n_noisy) or stopped_early:
                    break
                left = deadline - self.clock()
                if left <= 0:
                    timed_out = True
                    break
                if full and cursor > before:
                    continue        # a full page that moved the cursor: fetch the rest now
                more = False
                await self.sleep(min(self.poll_interval, left))
        except BaseException:
            # nothing was handed over: the cursor stays, server-made notices are kept for next time
            notices = [ev for ev, o in items if o == "notice"]
            if notices:
                self.pending[k] = notices + self.pending.get(k, [])
            raise

        out = self._fit_wait(k, items, cursor, start_cursor, reloaded, timed_out, lost, more)
        self.cursors[k] = out["seq"]
        return out

    def _fit_wait(self, k: tuple[str, str], items: list[tuple[dict, str]], cursor: int,
                  start_cursor: int, reloaded: bool, timed_out: bool, lost: bool, more: bool) -> dict:
        """Build the wait answer, cutting it to ``MAX_RESPONSE``; the cursor covers only what
        is handed over. Cut-off notices go back to ``pending``."""
        helper, role = k
        inbox = len(self.orders.get(helper, ())) if R.allowed(role, "partner_inbox", {"ack": []}) else 0

        def build(evs: list[dict], seq: int, more_: bool) -> dict:
            o = {"seq": seq, "tick": self.bridge.last_tick, "events": evs, "timed_out": timed_out}
            if lost:
                o["lost"] = True
            if more_:
                o["more"] = True
            if inbox:
                o["inbox"] = inbox      # open orders of the owner (partner_inbox)
            if self.bridge.paused:
                o["warning"] = GAME_PAUSED
            return o

        kept = list(items)
        cut: list[tuple[dict, str]] = []
        out = build([e for e, _ in kept], cursor, more)
        while _json_size(out) > WAIT_BUDGET and len(kept) > 1:
            cut.append(kept.pop())
            if reloaded:
                seq = cursor            # pre-reload events are moot; the notice must get through
            else:
                mod_seqs = [e["seq"] for e, o in kept if o == "mod"]
                seq = mod_seqs[-1] if mod_seqs else start_cursor
            out = build([e for e, _ in kept], seq, True)
        if _json_size(out) > WAIT_BUDGET and kept:
            # one event alone is too large (huge detail): keep its identity, drop the payload
            kept = [(_shrink_event(kept[0][0]), kept[0][1])]
            out = build([kept[0][0]], out["seq"], out.get("more", False))
        notices = [e for e, o in reversed(cut) if o == "notice"]
        if notices:
            self.pending[k] = notices + self.pending.get(k, [])
        if role == R.PILOT:
            # repeated_failure counts only the failures handed to the role that acts
            for ev, o in kept:
                if o == "mod":
                    self._note_event(helper, ev)
        return out

    async def op_plan(self, helper, key, task="mining", resource=None, patch=None, options=None) -> dict:
        a = {"task": task, "resource": resource, "patch": patch, "options": options}

        async def run(h):
            if task != "mining":
                raise V.bad("task", "only 'mining' is supported")
            if (resource is None) == (patch is None):
                raise V.bad("args", "pass exactly one of resource / patch")
            for nm, v in (("resource", resource), ("patch", patch), ("options", options)):
                if v is not None and not isinstance(v, dict):
                    raise V.bad(nm, "must be an object")
            if V.json_size({"r": resource, "p": patch, "o": options}) > V.MAX_ACT_ARGS:
                raise PartnerError("limit", f"plan request larger than {V.MAX_ACT_ARGS} bytes")
            return await self._forge_plan(h, task, resource, patch, options)
        return await self._tool("partner_plan", helper, key, a, run)

    def _forge(self):
        """The forge module, or None when it is not installed."""
        try:
            return importlib.import_module(self.forge_module)
        except ImportError:
            return None

    async def _forge_plan(self, helper, task, resource, patch, options) -> dict:
        forge = self._forge()
        if forge is None:
            return {"supported": False, "reason": "forge integration is not installed on the server"}
        fn = getattr(forge, "plan", None)
        if not callable(fn):
            return {"supported": False, "reason": "forge integration has no plan()"}
        try:
            # the Python contract of MCP.md, the only one: plan(task, resource, patch, options, *, config)
            result = await asyncio.to_thread(fn, task, resource, patch, options, config=self.cfg)
        except PartnerError:
            raise       # PlanArgsError is a PartnerError with code bad_args
        except Exception as exc:  # noqa: BLE001
            # the message may hold file paths / profile names: details go to server.log only
            log.exception("forge plan failed")
            return {"supported": False, "reason": f"forge failed ({type(exc).__name__}); see server.log"}
        return _plan_answer(result)

    async def _forge_notes(self) -> dict | None:
        """``forge.brief_notes(config)``: the only source of the profile notes for partner_brief."""
        forge = self._forge()
        fn = getattr(forge, "brief_notes", None) if forge is not None else None
        if not callable(fn):
            return None
        try:
            res = await asyncio.to_thread(fn, self.cfg)
        except Exception:  # noqa: BLE001
            log.exception("forge brief_notes failed")
            return {"reason": "заметки профиля не прочитались (см. server.log)"}
        return res if isinstance(res, dict) else None

    # ================================================================ blueprints
    async def _load_plan(self, plan: str) -> str:
        """Blueprint string for a plan id from ``partner_plan``: ``forge.load_plan(id, config=)``."""
        V.ident("args.plan", plan)
        forge = self._forge()
        fn = getattr(forge, "load_plan", None) if forge is not None else None
        if not callable(fn):
            raise PartnerError("not_found", "plans are not available: forge integration is not installed")
        try:
            text = await asyncio.to_thread(fn, plan, config=self.cfg)
        except PartnerError:
            raise
        except Exception:  # noqa: BLE001
            log.exception("forge load_plan failed")
            raise PartnerError("not_found", "plan not found; call partner_plan again") from None
        if not isinstance(text, str):
            raise PartnerError("not_found", "plan not found; call partner_plan again")
        text = text.strip()
        if len(text) > BLOB_MAX:
            raise PartnerError("limit", "blueprint larger than 1 MB")
        if not BLUEPRINT_RE.match(text):
            raise PartnerError("bad_args", "plan is not a blueprint string")
        return text

    async def _upload_blob(self, text: str) -> str:
        data = text.encode("ascii")
        parts = [data[i:i + BLOB_PART] for i in range(0, len(data), BLOB_PART)] or [b""]
        blob = "bp-" + secrets.token_hex(8)
        total = len(parts)
        for i, part in enumerate(parts, 1):
            await self._mod("blob_put", {"blob": blob, "part": i, "total": total,
                                         "data": part.decode("ascii")}, None, mutating=True)
        return blob

    # ================================================================ admin
    async def admin_hello(self) -> dict:
        resp = await self.bridge.request("hello")
        return _admin_result(resp)

    async def admin_spawn(self, helper: str) -> dict:
        if not isinstance(helper, str) or not HELPER_RE.match(helper):
            raise V.bad("helper", "must match ^[a-z0-9_-]{1,16}$")
        return _admin_result(await self.bridge.request("helper_spawn", {}, helper))

    async def admin_remove(self, helper: str) -> dict:
        if not isinstance(helper, str) or not HELPER_RE.match(helper):
            raise V.bad("helper", "must match ^[a-z0-9_-]{1,16}$")
        return _admin_result(await self.bridge.request("helper_remove", {}, helper))

    async def admin_limit(self, max: int) -> dict:  # noqa: A002
        """``helper_limit {max}``: how many helpers the player allowed (PROTOCOL §4)."""
        args = {"max": V.helper_max("max", max)}
        return _admin_result(await self.bridge.request("helper_limit", args))

    async def admin_attach(self, helper: str, player: str) -> dict:
        """``helper_attach {player}``: the helper's body is the character of a second connected
        client (PROTOCOL §7, ``--body player``). The operation itself lives in the mod."""
        if not isinstance(helper, str) or not HELPER_RE.match(helper):
            raise V.bad("helper", "must match ^[a-z0-9_-]{1,16}$")
        args = {"player": V.player_name("player", player)}
        return _admin_result(await self.bridge.request("helper_attach", args, helper))

    async def admin_raw_events(self, since: int = 0, helper: str | None = None, limit: int = 100) -> dict:
        args = {"since": V.integer(0, 2**53)("since", since), "limit": V.integer(1, 200)("limit", limit)}
        if helper is not None:
            if not isinstance(helper, str) or not HELPER_RE.match(helper):
                raise V.bad("helper", "must match ^[a-z0-9_-]{1,16}$")
            args["helper"] = helper
        resp = await self.bridge.request("events", args, channel="poll")
        data = resp.get("data") if isinstance(resp, dict) else None
        if resp.get("ok") and isinstance(data, dict) and isinstance(data.get("events"), list):
            # the same `fit: null` as partner_wait adds (docs/ACTIONS.md, «plan_belt»)
            events = [_fit_null(ev) if isinstance(ev, dict) else ev for ev in data["events"]]
            resp = dict(resp, data=dict(data, events=events))
        return _admin_result(resp)

    async def close(self) -> None:
        await self.bridge.close()


def _fit_null(ev: dict) -> dict:
    """ACTIONS.md: a `build_blueprint` result whose shift search found nothing carries
    ``detail.fit = null``. The mod's JSON has no null (a Lua table cannot hold one): it sends
    ``fit_checked`` without ``fit`` — the field is added here, so the agent always sees it."""
    data = ev.get("data")
    if ev.get("kind") not in ("job_done", "job_failed") or not isinstance(data, dict):
        return ev
    detail = data.get("detail")
    if (data.get("do") == "build_blueprint" and isinstance(detail, dict)
            and "fit_checked" in detail and "fit" not in detail):
        return dict(ev, data=dict(data, detail=dict(detail, fit=None)))
    return ev


def _admin_result(resp: dict) -> dict:
    if not resp.get("ok"):
        err = resp.get("error") if isinstance(resp.get("error"), dict) else {}
        raise PartnerError(str(err.get("code") or "internal")[:40],
                           str(err.get("text"))[:500] if err.get("text") else None)
    out = {"tick": resp.get("tick"), "seq": resp.get("seq"), "data": resp.get("data")}
    if len(json.dumps(out, ensure_ascii=False).encode("utf-8")) > MAX_RESPONSE:
        raise PartnerError(RESPONSE_TOO_LARGE, "narrow the request")
    return out


PLAN_KEYS = ("plan", "anchor", "direction", "items", "size", "summary")   # MCP.md partner_plan


def _plan_answer(result: Any) -> dict:
    """Check forge's answer against MCP.md and pass on only the contract fields.

    The blueprint string and anything else forge adds never reach the agent.
    """
    if not isinstance(result, dict):
        return {"supported": False, "reason": "forge returned no plan"}
    if result.get("supported") is False:
        reason = result.get("reason")
        reason = reason[:300] if isinstance(reason, str) else "forge cannot plan this"
        return {"supported": False, "reason": reason}
    try:
        V.ident("plan", result.get("plan"))
        anchor = V.pos("anchor", result.get("anchor"))
        if not _is_int(result.get("direction")) or not 0 <= result["direction"] <= 15:
            raise V.bad("direction", "must be 0..15")
        items = result.get("items")
        if isinstance(items, list) and not items:
            items = {}
        if not isinstance(items, dict) or not all(
                isinstance(k, str) and V.NAME_RE.match(k) and _is_int(n) and n >= 0
                for k, n in items.items()):
            raise V.bad("items", "must be {item: count}")
        size = result.get("size")
        if not (isinstance(size, dict) and set(size) == {"w", "h"}
                and all(isinstance(size[k], (int, float)) and not isinstance(size[k], bool)
                        and 0 < size[k] <= 10_000 for k in ("w", "h"))):
            raise V.bad("size", "must be {w, h}")
        summary = result.get("summary")
        if not isinstance(summary, str):
            raise V.bad("summary", "must be a string")
    except PartnerError as e:
        log.warning("forge plan has a bad shape: %s", e)
        return {"supported": False, "reason": "forge returned a plan of unexpected shape"}
    out = {k: result[k] for k in PLAN_KEYS}
    out["anchor"] = anchor
    out["items"] = items
    out["summary"] = summary[:2000]
    return out


def _json_size(v: Any) -> int:
    return len(json.dumps(v, ensure_ascii=False).encode("utf-8"))


def _shrink_event(ev: dict) -> dict:
    """An event too large to hand over even alone: keep its identity and outcome fields."""
    data = ev.get("data") if isinstance(ev.get("data"), dict) else {}
    small = {k: data[k] for k in _SHRINK_KEEP
             if k in data and (not isinstance(data[k], str) or len(data[k]) <= 200)
             and isinstance(data[k], (str, int, float, bool))}
    small["truncated"] = True
    return {k: ev.get(k) for k in ("seq", "tick", "helper", "kind", "loud")} | {"data": small}


def _redact(v: Any, depth: int = 0) -> Any:
    if depth > 6:
        return "…"
    if isinstance(v, dict):
        out = {}
        for k, x in v.items():
            if k in _SECRET_FIELDS and isinstance(x, str):
                out[k] = f"<{len(x)} chars>"
            else:
                out[k] = _redact(x, depth + 1)
        return out
    if isinstance(v, list):
        return [_redact(x, depth + 1) for x in v[:50]]
    if isinstance(v, str) and len(v) > 300:
        return v[:300] + "…"
    if isinstance(v, float) and not math.isfinite(v):
        return str(v)
    if isinstance(v, (str, int, float, bool)) or v is None:
        return v
    return repr(v)[:100]
