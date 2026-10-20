"""Envelope v1 over two RCON connections (PROTOCOL.md §2, §5).

* ``cmd`` — agent operations, timeout 10 s; ``poll`` — event polling, timeout 5 s.
* Every request has a fresh ``id``; after a timeout / broken reply the bridge reconnects and
  repeats **the same id** (the mod's ``storage.recent`` returns the stored answer, nothing runs
  twice). Three failed attempts -> ``transport_timeout``.
* ``id`` = random per-process prefix + counter, so a restarted server never collides with ids
  still held in the mod's ``recent`` ring (that would return a stale answer).
* Tick tracking: the tick has not grown for ≥ 3 s across responses -> ``paused``;
  the tick went down -> the save was reloaded (callbacks get ``(tick, seq)``).
"""
from __future__ import annotations

import asyncio
import itertools
import json
import logging
import re
import secrets
import time
from typing import Any, Callable

from . import PROTOCOL_VERSION
from .config import Config
from .errors import TRANSPORT_TIMEOUT, PartnerError
from .rcon import PARTNER_PREFIX, RconAuthError, RconConnection, RconError

log = logging.getLogger("factorio_partner.bridge")

MAX_REQUEST = 8 * 1024          # PROTOCOL §2: command parameter ≤ 8 KB
CMD_TIMEOUT = 10.0
POLL_TIMEOUT = 5.0
ATTEMPTS = 3
RETRY_DELAY = 0.5
PAUSE_AFTER = 3.0
MIN_ATTEMPT = 0.5               # shortest RCON timeout an attempt gets under a budget (s)
ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,40}$")
HELPER_RE = re.compile(r"^[a-z0-9_-]{1,16}$")


class Bridge:
    def __init__(self, cfg: Config | None = None, *,
                 connections: dict[str, Any] | None = None,
                 cmd_timeout: float = CMD_TIMEOUT, poll_timeout: float = POLL_TIMEOUT,
                 attempts: int = ATTEMPTS, retry_delay: float = RETRY_DELAY,
                 pause_after: float = PAUSE_AFTER,
                 clock: Callable[[], float] = time.monotonic):
        if connections is None:
            if cfg is None:
                raise ValueError("Bridge needs a Config or explicit connections")
            connections = {
                ch: RconConnection(cfg.rcon_host, cfg.rcon_port, cfg.read_password, name=ch)
                for ch in ("cmd", "poll")
            }
        self.conns = connections
        self.timeouts = {"cmd": cmd_timeout, "poll": poll_timeout}
        self.attempts = attempts
        self.retry_delay = retry_delay
        self.pause_after = pause_after
        self.clock = clock
        self._prefix = "s" + secrets.token_hex(4)
        self._counter = itertools.count(1)
        # tick / seq observation
        self.last_tick: int | None = None
        self.tick_changed_at: float | None = None
        self.last_seq: int | None = None
        self.paused = False
        self.reloads = 0
        self._reload_cbs: list[Callable[[int, int | None], None]] = []

    # ---- ids -------------------------------------------------------------
    def new_id(self) -> str:
        return f"{self._prefix}-{next(self._counter):06d}"

    def on_reload(self, cb: Callable[[int, int | None], None]) -> None:
        self._reload_cbs.append(cb)

    # ---- envelope ----------------------------------------------------------
    def build(self, op: str, args: dict | None, helper: str | None, req_id: str,
              owner_ok: list[str] | None = None) -> str:
        env: dict[str, Any] = {"v": PROTOCOL_VERSION, "id": req_id, "op": op}
        if helper is not None:
            if not HELPER_RE.match(helper):
                raise PartnerError("bad_args", "helper")
            env["helper"] = helper
        env["args"] = args if args is not None else {}
        if owner_ok:
            # the owner's leave for «спросить» (PROTOCOL «owner_ok»): the permission keys his «да» was
            # about, a field of the envelope, set only by core after it checked his answer; never taken
            # from an agent's args
            if not isinstance(owner_ok, (list, tuple)) or not all(isinstance(k, str) for k in owner_ok):
                raise PartnerError("internal", "owner_ok must be a list of permission keys")
            env["owner_ok"] = list(owner_ok)
        # ensure_ascii: the RCON line stays pure ASCII, no encoding surprises over the wire
        text = json.dumps(env, ensure_ascii=True, separators=(",", ":"), allow_nan=False)
        if len(text.encode("ascii")) > MAX_REQUEST:
            raise PartnerError("limit", f"request too large ({len(text)} > {MAX_REQUEST} bytes)")
        return PARTNER_PREFIX + text

    @staticmethod
    def _parse(body: str, req_id: str, fresh: bool = True) -> dict:
        try:
            resp = json.loads(body)
        except ValueError:
            raise _BadReply("mod returned non-JSON" + _excerpt(body)) from None
        if not isinstance(resp, dict):
            raise _BadReply("mod reply is not an object")
        rid = resp.get("id")
        # a mod that could not read our envelope (bad_request / version_mismatch) may not echo
        # the id; accept such a refusal instead of retrying it three times — but only on a
        # freshly opened socket: on a reused one it may be a late reply to an earlier command
        if rid != req_id and not (fresh and rid is None and resp.get("ok") is False):
            raise _BadReply("reply id mismatch")
        if not isinstance(resp.get("ok"), bool) or (
                resp.get("v") != PROTOCOL_VERSION and resp.get("ok") is not False):
            raise _BadReply("reply is not a v1 envelope")
        return resp

    async def request(self, op: str, args: dict | None = None, helper: str | None = None,
                      channel: str = "cmd", *, budget: float | None = None,
                      owner_ok: list[str] | None = None) -> dict:
        """Send one operation, return the mod's envelope (``ok`` may be false).

        ``budget`` (seconds) caps the whole call including retries: each attempt gets at most
        what is left (but at least ``MIN_ATTEMPT``), and no new attempt starts once it is spent.
        """
        req_id = self.new_id()
        command = self.build(op, args, helper, req_id, owner_ok=owner_ok)
        conn = self.conns[channel]
        timeout = self.timeouts[channel]
        end = None if budget is None else time.monotonic() + max(budget, 0.0)
        last = "no attempt"
        tried = 0
        for attempt in range(1, self.attempts + 1):
            t = timeout
            if end is not None:
                left = end - time.monotonic()
                if attempt > 1 and left < MIN_ATTEMPT:
                    break
                t = min(timeout, max(left, MIN_ATTEMPT))
            tried = attempt
            try:
                fresh = not getattr(conn, "connected", False)
                body = await conn.execute(command, t)
                resp = self._parse(body, req_id, fresh)
            except RconAuthError as exc:
                log.warning("rcon %s: %s", channel, exc)
                raise PartnerError(TRANSPORT_TIMEOUT, str(exc)) from None
            except (RconError, _BadReply) as exc:
                last = str(exc)
                log.warning("rcon %s: %s op=%s id=%s attempt %d/%d: %s", channel,
                            type(exc).__name__, op, req_id, attempt, self.attempts, last)
                if isinstance(exc, _BadReply):
                    # a desynchronised socket may still carry a late reply: start clean
                    await conn.close()
                if attempt < self.attempts and (
                        end is None or end - time.monotonic() >= MIN_ATTEMPT + self.retry_delay):
                    await asyncio.sleep(self.retry_delay)
                continue
            self._observe(resp)
            return resp
        raise PartnerError(TRANSPORT_TIMEOUT, f"mod unreachable after {tried} attempts ({last})")

    # ---- tick / seq ----------------------------------------------------------
    def _observe(self, resp: dict) -> None:
        tick = resp.get("tick")
        seq = resp.get("seq")
        if isinstance(seq, int) and not isinstance(seq, bool):
            self.last_seq = seq
        else:
            seq = None
        if not isinstance(tick, int) or isinstance(tick, bool):
            return
        now = self.clock()
        if self.last_tick is not None and tick < self.last_tick:
            self.reloads += 1
            log.warning("tick went back %s -> %s: game reloaded", self.last_tick, tick)
            self.last_tick, self.tick_changed_at, self.paused = tick, now, False
            for cb in list(self._reload_cbs):
                try:
                    cb(tick, seq)
                except Exception:  # noqa: BLE001
                    log.exception("reload callback failed")
            return
        if tick != self.last_tick or self.tick_changed_at is None:
            self.last_tick, self.tick_changed_at, self.paused = tick, now, False
        else:
            self.paused = now - self.tick_changed_at >= self.pause_after

    async def close(self) -> None:
        for c in self.conns.values():
            try:
                await c.close()
            except Exception:  # noqa: BLE001
                pass


class _BadReply(Exception):
    pass


def _excerpt(body: str) -> str:
    s = "".join(ch if ch.isprintable() else " " for ch in (body or "")[:120]).strip()
    return f": {s!r}" if s else " (empty)"
