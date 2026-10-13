"""Core operations ``op_*`` shared by the MCP server and the CLI (docs/MCP.md).

Knows nothing about MCP. Every agent call goes through ``Core._tool``:
helper key check -> argument checks -> bridge -> response size check -> per-helper log.
Errors are ``PartnerError`` (server.py turns them into ``ToolError``).

Never logged or returned: helper keys, the RCON password, blueprint strings.
"""
from __future__ import annotations

import asyncio
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

from . import validate as V
from .bridge import HELPER_RE, Bridge
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

HINTS = {
    "partner_map": "reduce radius or pass types/names",
    "partner_resources": "reduce radius or pass name",
    "partner_stock": "reduce radius or pass items",
    "partner_ghosts": "reduce radius or pass a smaller area",
    "partner_rates": "pass items or a smaller top",
    "partner_recipes": "pass filter",
    "partner_find": "pass a smaller limit or fewer kinds",
    "partner_state": "",
    "partner_wait": "",     # never too large: _fit_wait cuts the page and sets more=true
}


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
        self.cursors: dict[str, int] = {}
        self.pending: dict[str, list[dict]] = {}
        self._wait_locks: dict[str, asyncio.Lock] = {}
        self.job_sig: OrderedDict[tuple[str, int], str] = OrderedDict()
        self.fail_counts: dict[tuple[str, str], int] = {}
        self.bridge.on_reload(self._on_reload)

    # ================================================================ access
    def _load_keys(self) -> dict:
        try:
            data = json.loads(self.cfg.helpers_file.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def check_access(self, helper: Any, key: Any) -> str:
        """Constant-time key check; every failure is the same ``access denied``."""
        ok_shape = (isinstance(helper, str) and HELPER_RE.match(helper) is not None
                    and isinstance(key, str) and MIN_KEY <= len(key) <= MAX_KEY)
        expected = ""
        if ok_shape:
            v = self._load_keys().get(helper)
            if isinstance(v, str) and len(v) >= MIN_KEY:
                expected = v
        given = key.encode("utf-8", "replace") if isinstance(key, str) else b""
        match = hmac.compare_digest(expected.encode("utf-8") or b"\0" * MIN_KEY, given[:MAX_KEY * 4])
        if not (ok_shape and expected and match):
            log.info("access denied for helper %s",
                     helper if isinstance(helper, str) and HELPER_RE.match(helper) else "?")
            raise PartnerError(ACCESS_DENIED)
        return helper

    # ================================================================ logging
    def _log_call(self, helper: str, tool: str, args: dict, code: str, started: float) -> None:
        rec = {
            "t": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "tool": tool,
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
        self.check_access(helper, key)
        code = "ok"
        try:
            await self._ensure_started()
            self._cursor(helper)        # register the helper: reload notices reach it
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
            self._log_call(helper, tool, args, code, started)

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
        for h in list(self.cursors):
            self.cursors[h] = new
            self.pending.setdefault(h, []).append(dict(ev))
        self.job_sig.clear()
        self.fail_counts.clear()

    def _cursor(self, helper: str) -> int:
        if helper not in self.cursors:
            self.cursors[helper] = self.start_seq or 0
        return self.cursors[helper]

    def _note_event(self, helper: str, ev: dict) -> None:
        """Track consecutive job_failed per (do, args) for ``repeated_failure``."""
        kind = ev.get("kind")
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
            return dict(build_brief(self.cfg, await self._forge_notes()), helper=h)
        return await self._tool("partner_brief", helper, key, {}, run)

    async def op_state(self, helper, key) -> dict:
        async def run(h):
            return self._stamp(await self._mod("state", {}, h))
        return await self._tool("partner_state", helper, key, {}, run)

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
            mod_args = clean
            if do == "build_blueprint" and "plan" in clean:
                bp = await self._load_plan(clean["plan"])
                blob = await self._upload_blob(bp)
                mod_args = {k: v for k, v in clean.items() if k != "plan"}
                mod_args["blob"] = blob
            data = await self._mod("act", {"do": do, "args": mod_args, "replace": rep}, h,
                                   mutating=True)
            job = data.get("job")
            if _is_int(job):
                self.job_sig[(h, job)] = sig
                while len(self.job_sig) > JOB_MEMORY:
                    self.job_sig.popitem(last=False)
            return self._stamp(data)
        return await self._tool("partner_act", helper, key, a, run)

    async def op_cancel(self, helper, key, job=None, all=False) -> dict:  # noqa: A002
        a = {"job": job, "all": all}

        async def run(h):
            if V.boolean("all", all):
                if job is not None:
                    raise V.bad("args", "use only one of job / all")
                args = {"all": True}
            elif job is not None:
                args = {"job": V.integer(1, 2**53)("job", job)}
            else:
                raise V.bad("args", "pass job or all=true")
            return self._stamp(await self._mod("cancel", args, h, mutating=True))
        return await self._tool("partner_cancel", helper, key, a, run)

    async def op_reflex(self, helper, key, set) -> dict:  # noqa: A002
        a = {"set": set}

        async def run(h):
            rset = V.check_reflexes(set)
            return await self._mod("reflexes", {"set": rset}, h, mutating=True)
        return await self._tool("partner_reflex", helper, key, a, run)

    async def op_say(self, helper, key, text) -> dict:
        a = {"text": text}

        async def run(h):
            return await self._mod("say", {"text": V.check_say(text)}, h, mutating=True)
        return await self._tool("partner_say", helper, key, a, run)

    async def op_wait(self, helper, key, timeout=30, quiet=True, since=None) -> dict:
        a = {"timeout": timeout, "quiet": quiet, "since": since}

        async def run(h):
            t = V.number(0, WAIT_MAX)("timeout", timeout)
            q = V.boolean("quiet", quiet)
            s = None if since is None else V.integer(0, 2**53)("since", since)
            lock = self._wait_locks.setdefault(h, asyncio.Lock())
            async with lock:
                return await self._wait(h, t, q, s)
        return await self._tool("partner_wait", helper, key, a, run)

    async def _wait(self, helper: str, timeout: float, quiet: bool, since: int | None) -> dict:
        """Poll ``events`` until something worth waking for, or ``timeout``.

        The helper's cursor (EVENTS.md: last seq HANDED to the agent) moves only at the very end,
        after the answer has been cut to fit ``MAX_RESPONSE``: anything not handed over stays in
        the mod's buffer (or in ``pending``) for the next call. On any exception the cursor is
        untouched and reload notices go back to ``pending``.
        """
        if since is None:
            cursor = self._cursor(helper)
        elif since == 0:
            resp = await self.bridge.request("hello", channel="poll")
            cursor = resp.get("seq") if _is_int(resp.get("seq")) else self._cursor(helper)
        else:
            cursor = since
        self.cursors.setdefault(helper, cursor)
        start_cursor = cursor
        deadline = self.clock() + timeout
        # items in arrival order: (event, origin) — origin "notice" (server-made, from pending)
        # or "mod" (from the mod's buffer)
        items: list[tuple[dict, str]] = [(ev, "notice") for ev in self.pending.pop(helper, [])]
        n_loud = len(items)
        n_noisy = 0
        lost = False
        timed_out = False
        more = False
        reloaded = False
        reloads = self.bridge.reloads
        first = True
        try:
            while True:
                left = deadline - self.clock()
                # the last poll must not push the call past the deadline (MCP timeouts, ≤55 s):
                # its RCON budget is what is left (at least a short minimum); the first poll gets
                # a normal budget so that timeout=0 still works on a slow tick
                budget = max(left, FIRST_POLL_BUDGET if first else LAST_POLL_MIN)
                first = False
                data = await self._mod("events",
                                       {"since": cursor, "helper": helper, "limit": EVENTS_LIMIT},
                                       None, channel="poll", budget=budget)
                if self.bridge.reloads != reloads:
                    # the save was reloaded while waiting: _on_reload reset the cursor and queued
                    # game_reloaded for known helpers. Events collected in this call before the
                    # reload belong to the abandoned timeline (their jobs no longer exist): drop
                    # them so the notice is never the part cut off by the size limit.
                    items = [it for it in items if it[1] == "notice"]
                    reloads = self.bridge.reloads
                    reloaded = True
                    notices = self.pending.pop(helper, [])
                    cursor = self.cursors.get(helper, self.start_seq or 0)
                    if not any(e.get("kind") == "game_reloaded" for e in notices):
                        notices.append({"seq": cursor, "tick": self.bridge.last_tick, "helper": None,
                                        "kind": "game_reloaded",
                                        "data": {"tick": self.bridge.last_tick}, "loud": True})
                    items.extend((ev, "notice") for ev in notices)
                    break
                evs = _as_list(data.get("events"))
                lost = lost or bool(data.get("lost"))
                full = len(evs) >= EVENTS_LIMIT
                before = cursor
                stopped_early = False
                for ev in evs:
                    if not isinstance(ev, dict) or not _is_int(ev.get("seq")):
                        continue
                    if ev["seq"] <= cursor:
                        continue
                    cursor = ev["seq"]
                    items.append((ev, "mod"))
                    if ev.get("loud"):
                        n_loud += 1
                        if n_loud >= LOUD_MAX:
                            stopped_early = True
                            break
                    else:
                        n_noisy += 1
                        if n_noisy > NOISY_KEEP:
                            # drop the oldest noisy event: noise is a sample, not a record
                            i = next(k for k, (e, o) in enumerate(items)
                                     if o == "mod" and not e.get("loud"))
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
            # nothing was handed over: the cursor stays, reload notices are kept for next time
            notices = [ev for ev, o in items if o == "notice"]
            if notices:
                self.pending[helper] = notices + self.pending.get(helper, [])
            raise

        out = self._fit_wait(helper, items, cursor, start_cursor, reloaded, timed_out, lost, more)
        self.cursors[helper] = out["seq"]
        return out

    def _fit_wait(self, helper: str, items: list[tuple[dict, str]], cursor: int, start_cursor: int,
                  reloaded: bool, timed_out: bool, lost: bool, more: bool) -> dict:
        """Build the wait answer, cutting it to ``MAX_RESPONSE``; the cursor covers only what
        is handed over. Cut-off notices go back to ``pending``."""
        def build(evs: list[dict], seq: int, more_: bool) -> dict:
            o = {"seq": seq, "tick": self.bridge.last_tick, "events": evs, "timed_out": timed_out}
            if lost:
                o["lost"] = True
            if more_:
                o["more"] = True
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
            self.pending[helper] = notices + self.pending.get(helper, [])
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
        return _admin_result(await self.bridge.request("events", args, channel="poll"))

    async def close(self) -> None:
        await self.bridge.close()


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
