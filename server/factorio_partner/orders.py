"""The package bridge: the server starts the strategist's packages and checks them, without a model
turn (docs/MCP.md «Пакеты стройки», docs/EVENTS.md «Пакеты стройки»).

Every ``step`` (the server runs one every ``INTERVAL`` seconds) goes over the helpers that have open
packages in the ledger of the save:

1. Reads the helper's events after its own cursor: ``plan_done`` of the package's plan ends the
   run (``done`` → ``verifying``; cancelled → ``paused``; any other failure → ``failed``);
   ``owner_stop`` / ``owner_resume`` / ``reflex_resumed`` follow the owner's word and the return
   after a flight.
2. ``verifying``: once the game is ``VERIFY_TICKS`` past the end of the plan, measures the checks
   with the same reads an agent has (``stock``, ``rates``, ``ghosts``) → ``package_verified`` or
   ``package_unmet``.
3. No package of the helper runs: if the body is free (no job, empty queue, idle a moment), the
   owner's hold is not set, no open order of the owner waits and no package stands stopped past the
   bridge (``cancelled``, ``cancel_all``), the next package is claimed in the file (``queued`` →
   ``posting``, compare-and-set) and goes to the mod as one ``plan`` job (a long one — as a ``blob``
   sent with ``blob_put``).

A new large order of the owner (``partner_order{size:"large"}``) lets the running package finish
its current step (``cancel{at_boundary}``) and pauses it; it goes on from the next step once the
packages for the new order are done.

The bridge changes nothing in the game that an agent could not: it only queues ``plan`` jobs of
ordinary actions, cancels them and reads — honesty rules of PROTOCOL §6 hold for every step.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import TYPE_CHECKING, Any

from . import ledger as L
from . import roles as R
from . import validate as V
from .errors import GAME_PAUSED, TRANSPORT_TIMEOUT, PartnerError

if TYPE_CHECKING:
    from .core import Core

log = logging.getLogger("factorio_partner.orders")

INTERVAL = 2.0              # s between bridge steps
VERIFY_TICKS = 2 * 60 * 60  # the checks are measured 2 minutes of game time after plan_done
IDLE_GRACE_TICKS = 120      # the body has been idle at least this long (the pilot's own next act first)
ORDER_GATE_TICKS = 10 * 60 * 60  # an open order of the owner younger than this holds new packages
ACK_GRACE_TICKS = 10 * 60   # a small order just taken by the pilot holds new packages this long more
STOP_WINDOW_TICKS = 120     # plan_done{cancelled} this close after owner_stop is the owner's stop
STOP_TEXT = "stopped by owner"  # the mod's text of a job cut by the owner's word (owner_words.do_stop)
POSTING_STALE_S = 60.0      # s: a package left in ``posting`` this long by a dead process is checked
FLEE_RETURN_TICKS = 150 * 60  # a plan cancelled by a flight comes back within this (EVENTS.md «flee»)
STATE_CHECK_S = 15.0        # s: a running package is checked against the body's state this often
HELLO_EVERY_S = 5.0         # s: a fresh tick for verifying packages
POST_TRIES = 5              # transient failures to start a package before it fails
VERIFY_TRIES = 3            # failed measurements before a package is unmet
EVENT_PAGES = 5
TRANSIENT = (TRANSPORT_TIMEOUT, GAME_PAUSED, "internal")
# paused this way, a package holds every other one until the strategist resumes or cancels it: the
# body was stopped past the bridge (partner_cancel, replace) and must not go on by itself
HOLDING_REASONS = ("cancelled", "cancel_all")
_POSTING_FIELDS = ("posting_from", "posting_by", "posting_at")


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _as_list(v: Any) -> list:
    return v if isinstance(v, list) else []


def resume_step(data: dict, base: int) -> int | None:
    """The step a cut plan goes on from: the cut step itself (``f`` at ``at``), else the first step
    that never began (``s``); None — every step has run."""
    marks = data.get("marks") if isinstance(data.get("marks"), str) else ""
    at = data.get("at")
    if _is_int(at) and 1 <= at <= len(marks) and marks[at - 1] == "f":
        return at
    i = marks.find("s")
    if i >= 0:
        return i + 1
    if not marks and _is_int(at):
        return at
    return None if marks else base


def _stopped_by_owner(d: dict) -> bool:
    """plan_done of a plan cut by the owner's «стоп» / «иди сюда»: the mod sends it before owner_stop."""
    texts = [d.get("text")] + [f.get("text") for f in _as_list(d.get("failures")) if isinstance(f, dict)]
    return any(isinstance(t, str) and STOP_TEXT in t for t in texts)


def _plan_summary(d: dict) -> dict:
    out = {k: d[k] for k in ("status", "code", "text", "at", "steps", "done", "failed", "skipped", "marks")
           if k in d and isinstance(d[k], (str, int, float, bool))}
    if isinstance(out.get("text"), str):
        out["text"] = out["text"][:300]
    fails = d.get("failures")
    if isinstance(fails, list):
        out["failures"] = [{k: f[k] for k in ("step", "do", "code", "text") if k in f}
                           for f in fails[:3] if isinstance(f, dict)]
    return out


class PackageBridge:
    def __init__(self, core: "Core"):
        self.core = core
        self.owner = f"{os.getpid()}-{id(self):x}"
        self.cursors: dict[str, int] = {}
        self.last_stop: dict[str, int] = {}
        self.acked: dict[str, int] = {}      # helper -> tick of the last small order taken (ack)
        self.reconcile = False
        self._state_at: dict[str, float] = {}
        self._hello_at = -1e9
        self._posted: dict[str, dict] = {}   # package id -> fields of a started plan not yet written
        self._lock = asyncio.Lock()

    # ------------------------------------------------------------------ helpers
    def ledger(self) -> L.Ledger:
        return self.core.ledger()

    def _tick(self) -> int | None:
        t = self.core.bridge.last_tick
        return t if _is_int(t) else None

    def notify(self, helper: str, kind: str, data: dict, roles: tuple[str, ...] = (R.PILOT, R.STRATEGIST)) -> None:
        """A loud server-made event for the roles of the helper that have called the server."""
        ev = {"seq": self.core.bridge.last_seq, "tick": self.core.bridge.last_tick, "helper": helper,
              "kind": kind, "data": data, "loud": True}
        for role in roles:
            if (helper, role) in self.core.cursors:
                self.core._notice((helper, role), json.loads(json.dumps(ev)))

    def _set(self, pid: str, **fields) -> dict | None:
        def fn(d):
            p = L.find(d, pid)
            if p is None:
                return None
            p.update(fields)
            return dict(p)
        return self.ledger().mutate(fn)

    @staticmethod
    def _head(p: dict) -> dict:
        return {"id": p.get("id"), "name": p.get("name")}

    # ------------------------------------------------------------------ the loop
    async def run(self, interval: float = INTERVAL) -> None:
        while True:
            try:
                await self.step()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                log.exception("package bridge step failed")
            await asyncio.sleep(interval)

    def on_reload(self) -> None:
        """The save was loaded: the mod's seq started over and the jobs belong to the loaded save."""
        self.cursors.clear()
        self.last_stop.clear()
        self.acked.clear()
        self._state_at.clear()
        self.reconcile = True

    async def step(self) -> None:
        async with self._lock:
            led = self.ledger()
            helpers = sorted(led.helpers())
            if not helpers or not led.take_lease(self.owner):
                return
            await self.core._ensure_started()
            if self.reconcile:
                self.reconcile = False
                for h in helpers:
                    await self._reconcile(h)
            for h in helpers:
                if not led.take_lease(self.owner):
                    return                       # the lease went to another process: it drives now
                try:
                    await self._step_helper(h)
                except PartnerError as e:
                    log.info("package bridge: helper %s: %s", h, e.code)

    def _needs_events(self, h: str) -> bool:
        """A run to follow, a stop to lift (``owner_resume``) or a flight to come back from."""
        tick = self._tick()
        for p in self.ledger().open_of(h):
            st, why = p.get("status"), p.get("paused_reason")
            if st in ("running", "pausing") or (st == "paused" and why == "owner_stop"):
                return True
            if (st == "paused" and why == "cancelled" and _is_int(p.get("paused_tick")) and tick is not None
                    and tick - p["paused_tick"] <= FLEE_RETURN_TICKS):
                return True
        return False

    async def _step_helper(self, h: str) -> None:
        await self._finish_posts(h)
        await self._check_posting(h)
        if self._needs_events(h):
            await self._read_events(h)
            await self._check_running(h)
        await self._verify(h)
        await self._maybe_post(h)

    # ------------------------------------------------------------------ events
    async def _read_events(self, h: str) -> None:
        running = [p for p in self.ledger().open_of(h) if p.get("status") in ("running", "pausing")]
        cur = self.cursors.get(h)
        if cur is None:
            seqs = [p["seq"] for p in running if _is_int(p.get("seq"))]
            cur = min(seqs) if seqs else (self.core.start_seq or 0)
        ticket = self.core.poller.ticket()
        for i in range(EVENT_PAGES):
            # the first page is fetched after this step began (shared with the roles' waits)
            data = await self.core.poller.events(h, cur, 200, 5.0, after=ticket if i == 0 else None)
            evs = sorted((e for e in _as_list(data.get("events"))
                          if isinstance(e, dict) and _is_int(e.get("seq")) and e["seq"] > cur),
                         key=lambda e: e["seq"])
            for ev in evs:
                cur = ev["seq"]
                self._on_event(h, ev)
            if not data.get("more") or not evs:
                if not data.get("more") and _is_int(data.get("seq")) and data["seq"] > cur:
                    cur = data["seq"]
                break
        self.cursors[h] = cur

    def _on_event(self, h: str, ev: dict) -> None:
        kind, d = ev.get("kind"), ev.get("data") if isinstance(ev.get("data"), dict) else {}
        tick = ev.get("tick") if _is_int(ev.get("tick")) else self._tick()
        if kind in ("owner_stop", "owner_resume") and h not in _as_list(d.get("helpers")):
            return
        if kind == "owner_stop":
            self.last_stop[h] = tick or 0
            # the mod cuts the jobs first and says owner_stop after: a plan_done just before it
            # without the owner's text was the owner's stop too
            for p in self.ledger().open_of(h):
                if (p.get("status") == "paused" and p.get("paused_reason") == "cancelled"
                        and tick is not None and _is_int(p.get("paused_tick"))
                        and 0 <= tick - p["paused_tick"] <= STOP_WINDOW_TICKS):
                    q = self._set(p["id"], paused_reason="owner_stop")
                    if q is not None:
                        self.notify(h, "package_paused", dict(self._head(q), reason="owner_stop",
                                                              from_step=q.get("from_step", 1)))
        elif kind == "owner_resume":
            for p in self.ledger().open_of(h):
                if p.get("status") == "paused" and p.get("paused_reason") == "owner_stop":
                    self._set(p["id"], status="queued")
        elif kind == "plan_done" and ev.get("helper") == h:
            for p in self.ledger().open_of(h):
                if p.get("status") in ("running", "pausing") and p.get("job") == d.get("job"):
                    self._plan_done(p, d, tick)
        elif kind == "reflex_resumed" and ev.get("helper") == h and d.get("type") == "flee":
            plans = [j for j in _as_list(d.get("jobs")) if isinstance(j, dict) and j.get("do") == "plan"
                     and _is_int(j.get("job"))]
            for p in self.ledger().open_of(h):
                if (plans and p.get("status") == "paused" and p.get("paused_reason") == "cancelled"
                        and _is_int(p.get("paused_tick")) and tick is not None
                        and tick - p["paused_tick"] <= FLEE_RETURN_TICKS):
                    self._set(p["id"], status="running", job=plans[0]["job"], paused_reason=None)
                    break

    def _plan_done(self, p: dict, d: dict, tick: int | None) -> None:
        summary = _plan_summary(d)
        status, code = d.get("status"), d.get("code")
        if status == "done":
            self._set(p["id"], status="verifying", plan=summary, done_tick=tick,
                      verify_at=(tick + VERIFY_TICKS) if tick is not None else None, verify_tries=0)
            return
        if code in ("cancelled", "owner_hold"):
            nxt = resume_step(d, int(p.get("from_step") or 1))
            if nxt is None:
                # every step ran before the cut: the result is what the checks say
                self._set(p["id"], status="verifying", plan=summary, done_tick=tick,
                          verify_at=(tick + VERIFY_TICKS) if tick is not None else None, verify_tries=0)
                return
            stop = self.last_stop.get(p["helper"])
            if p.get("status") == "pausing":
                reason = "owner_order"
            elif code == "owner_hold" or _stopped_by_owner(d) or (
                    stop is not None and tick is not None and 0 <= tick - stop <= STOP_WINDOW_TICKS):
                reason = "owner_stop"
            else:
                reason = "cancelled"
            q = self._set(p["id"], status="paused", paused_reason=reason, paused_tick=tick, from_step=nxt,
                          plan=summary)
            if q is not None:
                data = dict(self._head(q), reason=reason, from_step=nxt)
                if q.get("paused_for"):
                    data["order"] = q["paused_for"]
                self.notify(p["helper"], "package_paused", data)
            return
        q = self._set(p["id"], status="failed", plan=summary, done_tick=tick)
        if q is not None:
            data = dict(self._head(q), code=code if isinstance(code, str) else "failed")
            for k in ("text", "at", "failures"):
                if k in summary:
                    data[k] = summary[k]
            self.notify(p["helper"], "package_failed", data)

    async def _check_running(self, h: str) -> None:
        """The plan_done of a running package was not seen (events lost, a restart of the server
        while the save moved on): once the body no longer holds the job, the checks decide."""
        now = self.core.clock()
        if now - self._state_at.get(h, -1e9) < STATE_CHECK_S:
            return
        self._state_at[h] = now
        running = [p for p in self.ledger().open_of(h) if p.get("status") in ("running", "pausing")]
        if not running:
            return
        st = await self.core._mod("state", {}, h)
        job = st.get("job") if isinstance(st.get("job"), dict) else None
        queue = st.get("queue") if _is_int(st.get("queue")) else 0
        tick = self._tick()
        for p in running:
            if (job is not None and job.get("job") == p.get("job")) or queue > 0:
                continue
            log.info("package %s: its plan is gone without plan_done; checking the result", p.get("id"))
            self._set(p["id"], status="verifying", done_tick=tick, plan={"status": "unknown"},
                      verify_at=(tick + VERIFY_TICKS) if tick is not None else None, verify_tries=0)

    async def _reconcile(self, h: str) -> None:
        """After a save was loaded: a plan the loaded save still runs stays; any other run is paused
        (``reloaded``) for the strategist to resume or cancel; checks wait 2 minutes from now."""
        open_ = self.ledger().open_of(h)
        if not open_:
            return
        try:
            st = await self.core._mod("state", {}, h)
        except PartnerError:
            st = {}
        job = st.get("job") if isinstance(st.get("job"), dict) else None
        tick = self._tick()
        for p in open_:
            if p.get("status") in ("running", "pausing"):
                if job is not None and job.get("do") == "plan" and job.get("job") == p.get("job"):
                    self._set(p["id"], seq=self.core.start_seq or 0)
                    continue
                q = self._set(p["id"], status="paused", paused_reason="reloaded", paused_tick=tick)
                if q is not None:
                    self.notify(h, "package_paused", dict(self._head(q), reason="reloaded",
                                                          from_step=q.get("from_step", 1)))
            elif p.get("status") == "verifying":
                self._set(p["id"], verify_at=(tick + VERIFY_TICKS) if tick is not None else None)

    # ------------------------------------------------------------------ verify
    async def _verify(self, h: str) -> None:
        waiting = [p for p in self.ledger().open_of(h) if p.get("status") == "verifying"]
        if not waiting:
            return
        if self.core.clock() - self._hello_at >= HELLO_EVERY_S:
            self._hello_at = self.core.clock()
            await self.core.bridge.request("hello", channel="poll")
        tick = self._tick()
        if tick is None:
            return
        for p in waiting:
            at = p.get("verify_at")
            if not _is_int(at):
                self._set(p["id"], verify_at=tick + VERIFY_TICKS)
                continue
            if tick < at:
                continue
            checks, broken = [], None
            for c in p.get("verify") or []:
                try:
                    checks.append(await self._measure(h, p, c))
                except PartnerError as e:
                    broken = e.code
                    checks.append(dict(c, value=None, ok=False, error=e.code))
                except (KeyError, TypeError, ValueError):
                    # a check broken by a hand edit of the file: it can never be measured
                    broken = "bad_args"
                    checks.append({"kind": str(c.get("kind"))[:20] if isinstance(c, dict) else "?",
                                   "value": None, "ok": False, "error": "bad_args"})
            if broken is not None and int(p.get("verify_tries") or 0) + 1 < VERIFY_TRIES:
                self._set(p["id"], verify_tries=int(p.get("verify_tries") or 0) + 1)
                continue
            ok = all(c.get("ok") for c in checks)
            q = self._set(p["id"], status="verified" if ok else "unmet", checks=checks, verified_tick=tick)
            if q is not None:
                self.notify(h, "package_verified" if ok else "package_unmet", dict(self._head(q), checks=checks))

    async def _measure(self, h: str, p: dict, c: dict) -> dict:
        kind = c.get("kind")
        center = c.get("center") or p.get("anchor")
        if kind == "stock":
            data = await self.core._mod("stock", {"items": [c["item"]], "center": center,
                                                  "radius": c.get("radius", V.CHECK_RADIUS_DEFAULT)}, h)
            total = data.get("total") if isinstance(data.get("total"), dict) else {}
            value = total.get(c["item"], 0)
            value = value if isinstance(value, (int, float)) and not isinstance(value, bool) else 0
            return dict(c, value=value, ok=value >= c["at_least"])
        if kind == "rate":
            args: dict = {"scope": "surface", "period": "1m", "items": [c["item"]]}
            if c.get("surface"):
                args["surface"] = c["surface"]
            data = await self.core._mod("rates", args, h)
            row = None
            for group in ("items", "fluids"):
                g = data.get(group) if isinstance(data.get(group), dict) else {}
                if isinstance(g.get(c["item"]), dict):
                    row = g[c["item"]]
                    break
            made = row.get("made", 0) if row else 0
            made = made if isinstance(made, (int, float)) and not isinstance(made, bool) else 0
            return dict(c, value=made, ok=made >= c["at_least"])
        if kind == "ghosts":
            data = await self.core._mod("ghosts", {"center": center,
                                                   "radius": c.get("radius", V.CHECK_RADIUS_DEFAULT)}, h)
            count = data.get("count") if _is_int(data.get("count")) else 0
            return dict(c, value=count, ok=count <= c.get("at_most", 0))
        raise PartnerError("bad_args", f"unknown check {kind!r}")

    # ------------------------------------------------------------------ start
    def _order_gate(self, h: str, pkg: dict) -> bool:
        """An open order of the owner holds new packages: a small one is the pilot's next work; a
        large one waits for its own packages (``order``) — those may go, older ones wait."""
        tick = self._tick()
        at = self.acked.get(h)
        if at is not None and tick is not None and 0 <= tick - at < ACK_GRACE_TICKS:
            return True
        for o in self.core.orders.get(h, ()):
            ot = o.get("tick")
            if tick is not None and _is_int(ot) and tick - ot > ORDER_GATE_TICKS:
                continue
            if o.get("size") == "large" and pkg.get("order") == o.get("id"):
                continue
            return True
        return False

    def _candidate(self, h: str) -> dict | None:
        pkgs = self.ledger().open_of(h)
        if any(p.get("status") in ("posting", "running", "pausing") for p in pkgs):
            return None
        if any(p.get("status") == "paused" and p.get("paused_reason") in HOLDING_REASONS for p in pkgs):
            return None
        for p in L.next_up(pkgs):
            if not self._order_gate(h, p):
                return p
        # a package paused for a large order goes on once nothing newer waits
        paused = sorted((p for p in pkgs if p.get("status") == "paused" and p.get("paused_reason") == "owner_order"),
                        key=lambda p: p.get("n", 0))
        if paused and not L.next_up(pkgs) and not self._order_gate(h, paused[0]):
            return paused[0]
        return None

    async def _body_free(self, h: str) -> bool:
        st = await self.core._mod("state", {}, h)
        if isinstance(st.get("job"), dict) or (_is_int(st.get("queue")) and st["queue"] > 0):
            return False
        idle = st.get("idle_ticks")
        if _is_int(idle) and idle < IDLE_GRACE_TICKS:
            return False
        hold = await self.core._mod("owner_hold", {}, h)
        held = hold.get("hold") if isinstance(hold.get("hold"), dict) else {}
        return h not in held

    async def _maybe_post(self, h: str) -> None:
        if h in self.acked:
            # the grace after an ack counts in game ticks: a fresh tick, then the grace may be over
            await self.core.bridge.request("hello", channel="poll")
            tick = self._tick()
            if tick is None or not 0 <= tick - self.acked[h] < ACK_GRACE_TICKS:
                del self.acked[h]
        p = self._candidate(h)
        if p is None or not await self._body_free(h):
            return
        try:
            # the file can be edited by hand: what goes to the mod is checked again, like any act
            steps = V.package_steps("package.steps", p.get("steps"))
            for i, c in enumerate(p.get("verify") or [], 1):
                V.check_package_check(f"package.verify[{i}]", c)
            on_fail = V.enum("stop", "continue")("package.on_fail", p.get("on_fail", "stop"))
            from_step = V.integer(1, len(steps))("package.from_step", p.get("from_step") or 1)
        except PartnerError as e:
            q = self._set(p["id"], status="failed", plan={"status": "failed", "code": e.code,
                                                           "text": (e.text or "")[:300]})
            if q is not None:
                self.notify(h, "package_failed", dict(self._head(q), code=e.code, text=(e.text or "")[:300]))
            return
        args: dict = {"on_fail": on_fail}
        if from_step > 1:
            args["from_step"] = from_step
        was = p.get("status")
        if not self._claim(p["id"], was):
            return                                   # another process or a cancel got there first
        try:
            mod_steps = [dict(st, args=await self.core._plan_to_blob(st["do"], st.get("args") or {}))
                         for st in steps]
            if V.json_size(dict(args, steps=mod_steps)) > V.MAX_ACT_ARGS:
                # a long plan goes as a blob: the 4 KB limit of act.args holds about 60 steps
                text = json.dumps(mod_steps, ensure_ascii=True, separators=(",", ":"))
                args["blob"] = await self.core._upload_blob(text)
            else:
                args["steps"] = mod_steps
            data = await self.core._mod("act", {"do": "plan", "args": args, "replace": False}, h, mutating=True)
        except PartnerError as e:
            if e.code == "owner_hold":
                self._unclaim(p["id"], status=was)
                return
            tries = int(p.get("post_tries") or 0) + 1
            if e.code in TRANSIENT and tries < POST_TRIES:
                self._unclaim(p["id"], status=was, post_tries=tries)
                return
            q = self._unclaim(p["id"], status="failed", plan={"status": "failed", "code": e.code,
                                                               "text": (e.text or "")[:300]})
            if q is not None:
                self.notify(h, "package_failed", dict(self._head(q), code=e.code, text=(e.text or "")[:300]))
            return
        job = data.get("job")
        if not _is_int(job):
            log.warning("package %s: act plan answered without a job", p.get("id"))
            self._unclaim(p["id"], status=was)
            return
        seq = self.core.bridge.last_seq if _is_int(self.core.bridge.last_seq) else 0
        if h not in self.cursors or self.cursors[h] > seq:
            self.cursors[h] = seq
        self._state_at[h] = self.core.clock()
        # kept until written: a failed write leaves the package in ``posting`` with its job known,
        # and the next step writes it instead of starting the plan again
        self._posted[p["id"]] = {"helper": h, "job": job, "seq": seq, "started_tick": self._tick(),
                                 "runs": int(p.get("runs") or 0) + 1, "from_step": from_step,
                                 "steps": len(steps)}
        await self._finish_posts(h)

    def _claim(self, pid: str, was: Any) -> bool:
        """Compare-and-set ``was`` → ``posting`` in the file: only one bridge sends a package to the mod."""
        def fn(d):
            q = L.find(d, pid)
            if q is None or q.get("status") != was:
                return False
            q.update(status="posting", posting_from=was, posting_by=self.owner, posting_at=time.time())
            return True
        try:
            return bool(self.ledger().mutate(fn))
        except PartnerError:
            return False

    def _unclaim(self, pid: str, **fields) -> dict | None:
        """``posting`` → ``fields`` (the plan did not start); a package cancelled meanwhile stays so."""
        def fn(d):
            q = L.find(d, pid)
            if q is None or q.get("status") != "posting":
                return None
            for k in _POSTING_FIELDS:
                q.pop(k, None)
            q.update(fields)
            return dict(q)
        return self.ledger().mutate(fn)

    async def _finish_posts(self, h: str) -> None:
        """Write the started plans: ``posting`` → ``running``. A package cancelled while its plan was
        being sent gets the plan cancelled in the mod."""
        for pid, f in list(self._posted.items()):
            if f["helper"] != h:
                continue

            def fn(d, f=f, pid=pid):
                q = L.find(d, pid)
                if q is None or q.get("status") != "posting":
                    return None
                for k in _POSTING_FIELDS:
                    q.pop(k, None)
                q.update(status="running", job=f["job"], seq=f["seq"], started_tick=f["started_tick"],
                         post_tries=0, paused_reason=None, paused_for=None, runs=f["runs"])
                return dict(q)
            try:
                q = self.ledger().mutate(fn)
            except PartnerError as e:
                log.info("package %s: started as job %s, not written yet: %s", pid, f["job"], e.code)
                continue
            del self._posted[pid]
            if q is None:
                try:
                    await self.core._mod("cancel", {"job": f["job"]}, h, mutating=True)
                except PartnerError as e:
                    log.info("the plan job %s of a cancelled package was not cancelled: %s", f["job"], e.code)
                continue
            self.notify(h, "package_started", dict(self._head(q), job=f["job"], from_step=f["from_step"],
                                                    steps=f["steps"]), roles=(R.PILOT,))

    async def _check_posting(self, h: str) -> None:
        """A package left in ``posting`` by a process that died between the claim and the write: the
        body's job decides — a plan there is that package's run, an idle body means it never went."""
        now = time.time()

        def stale(p):
            at = p.get("posting_at")
            return (p.get("status") == "posting" and p["id"] not in self._posted
                    and (not isinstance(at, (int, float)) or now - at > POSTING_STALE_S))
        found = [p for p in self.ledger().open_of(h) if stale(p)]
        if not found:
            return
        st = await self.core._mod("state", {}, h)
        job = st.get("job") if isinstance(st.get("job"), dict) else None
        queue = st.get("queue") if _is_int(st.get("queue")) else 0
        p = found[0]
        if job is not None and job.get("do") == "plan" and _is_int(job.get("job")):
            log.info("package %s: found its plan as job %s", p["id"], job["job"])
            self._unclaim(p["id"], status="running", job=job["job"], seq=self.core.start_seq or 0,
                          started_tick=self._tick())
        elif job is None and queue == 0:
            self._unclaim(p["id"], status=p.get("posting_from") or "queued")

    # ------------------------------------------------------------------ the owner's large order, cancel
    async def on_large_order(self, h: str, order: dict) -> None:
        """A new large order: the running package finishes its step and pauses (the new one first)."""
        for p in self.ledger().open_of(h):
            if p.get("status") != "running" or not _is_int(p.get("job")):
                continue
            try:
                await self.core._mod("cancel", {"job": p["job"], "at_boundary": True}, h, mutating=True)
            except PartnerError as e:
                log.info("package %s: cannot stop at the step boundary: %s", p.get("id"), e.code)
                continue
            self._set(p["id"], status="pausing", paused_for=order.get("id"))

    def on_small_ack(self, h: str) -> None:
        """A small order left the inbox: the pilot's first act for it has a moment before a package."""
        tick = self._tick()
        if tick is not None:
            self.acked[h] = tick

    def on_cancel_all(self, h: str) -> None:
        """``partner_cancel{all:true}`` of any role (the voice carries out a free-form «хватит»): the
        waiting packages stand too — none starts on the freed body until the strategist resumes it."""
        tick = self._tick()

        def fn(d):
            out = []
            for p in d["packages"]:
                if p.get("helper") != h:
                    continue
                if p.get("status") == "queued" or (p.get("status") == "paused"
                                                   and p.get("paused_reason") == "owner_order"):
                    p.update(status="paused", paused_reason="cancel_all", paused_tick=tick)
                    out.append(dict(p))
            return out
        for q in self.ledger().mutate(fn):
            self.notify(h, "package_paused", dict(self._head(q), reason="cancel_all",
                                                  from_step=q.get("from_step", 1)))

    async def cancel(self, h: str, pid: str) -> dict:
        """``partner_ledger{action:"cancel"}``: the package leaves; its running plan is cancelled now."""
        def fn(d):
            p = L.find(d, pid)
            if p is None or p.get("helper") != h:
                raise PartnerError("not_found", f"id: no open package {pid}")
            before = p.get("status")
            p["status"] = "cancelled"
            return dict(p, was=before)
        p = self.ledger().mutate(fn)
        out = {"cancelled": pid, "was": p["was"]}
        if p["was"] in ("running", "pausing") and _is_int(p.get("job")):
            try:
                await self.core._mod("cancel", {"job": p["job"]}, h, mutating=True)
                out["job"] = p["job"]
            except PartnerError as e:
                out["warning"] = f"the plan job {p['job']} was not cancelled: {e.code}"
        return out
