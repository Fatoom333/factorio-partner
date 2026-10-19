"""One shared events poll of the mod for every ``partner_wait`` of a helper (docs/MCP.md «Роли»).

The voice, the pilot and the strategist of a helper wait at the same time, each with its own
cursor. Instead of three polls of the mod every half second they share one: the poller keeps the
helper's recent events (``base < seq <= top``, everything the mod has for this helper in that range)
and fetches only what came after ``top``. A wait whose cursor is inside the cache is answered from
it; an older cursor (the first wait, a role that fell far behind) is asked of the mod directly.

At most one fetch per helper is in flight: a wait that needs a fresh page joins it. The first poll
of a wait never takes a page fetched before the wait began, so ``timeout=0`` still sees every event
emitted before the call.

The answer has the shape of the mod's ``events`` (``{seq, events, lost}``) plus ``more``: the page
was cut (by ``limit`` or by the mod) and the rest can be fetched at once from ``seq``.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from typing import Awaitable, Callable

from .errors import TRANSPORT_TIMEOUT, PartnerError

CACHE_MAX = 1000        # events kept per helper; older cursors are asked of the mod directly

Fetch = Callable[[str, int, int, float | None], Awaitable[dict]]


def _is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


@dataclass
class _Cache:
    base: int                   # every event of the helper with base < seq <= top is in events
    top: int
    events: list[dict] = field(default_factory=list)
    more: bool = False          # the last fetch was a full page: the mod has more after top
    lost_below: int = 0         # a cursor below this missed events the mod had already dropped
    gen: int = 0                # generation of the fetch that last moved top
    at: float = 0.0             # clock when that fetch started


@dataclass
class _Flight:
    gen: int
    task: asyncio.Task


class EventPoller:
    def __init__(self, fetch: Fetch, clock: Callable[[], float], fresh: float, limit: int):
        self._fetch = fetch
        self._clock = clock
        self.fresh = fresh
        self.limit = limit
        self._cache: dict[str, _Cache] = {}
        self._flight: dict[str, _Flight] = {}
        self._gen = 0
        self._epoch = 0
        self.fetches = 0        # fetches sent to the mod (tests and the log read it)

    def ticket(self) -> int:
        """Generation now: a wait's first poll accepts only pages fetched after this."""
        return self._gen

    def reset(self) -> None:
        """The save was reloaded: forget everything (a fetch in flight is dropped when it ends)."""
        self._epoch += 1
        self._cache.clear()
        self._flight.clear()

    async def events(self, helper: str, since: int, limit: int, budget: float | None,
                     after: int | None = None) -> dict:
        """Events of ``helper`` with ``seq > since``. ``after`` — a ``ticket()``: only a page
        fetched after it will do; ``None`` — a page younger than ``fresh`` seconds will do."""
        while True:
            c = self._cache.get(helper)
            if c is not None and since < c.base:
                return await self._direct(helper, since, limit, budget)
            if c is not None and since <= c.top and self._fresh(c, after):
                return self._slice(c, since, limit)
            fl = self._flight.get(helper)
            if fl is not None and after is not None and fl.gen <= after:
                # a fetch that began before this wait: let it end, then fetch anew
                try:
                    await self._join(fl, budget)
                except PartnerError:
                    pass
                continue
            if fl is None:
                fl = self._start(helper, since, budget)
            await self._join(fl, budget)
            c = self._cache.get(helper)
            if c is not None and c.base <= since <= c.top:
                return self._slice(c, since, limit)
            # the cache was reset meanwhile, or this cursor is past its end
            return await self._direct(helper, since, limit, budget)

    # ------------------------------------------------------------------ internals
    def _fresh(self, c: _Cache, after: int | None) -> bool:
        if after is not None:
            return c.gen > after
        return self._clock() - c.at < self.fresh

    def _start(self, helper: str, since: int, budget: float | None) -> _Flight:
        self._gen += 1
        fl = _Flight(self._gen, None)  # type: ignore[arg-type]
        fl.task = asyncio.ensure_future(self._refresh(helper, since, budget, fl))
        fl.task.add_done_callback(_retrieve)
        self._flight[helper] = fl
        return fl

    async def _join(self, fl: _Flight, budget: float | None) -> None:
        try:
            if budget is None:
                await asyncio.shield(fl.task)
            else:
                await asyncio.wait_for(asyncio.shield(fl.task), max(budget, 0.0))
        except (asyncio.TimeoutError, TimeoutError):
            raise PartnerError(TRANSPORT_TIMEOUT, "the mod did not answer the events poll in time") from None

    async def _refresh(self, helper: str, since: int, budget: float | None, fl: _Flight) -> None:
        epoch, at = self._epoch, self._clock()
        try:
            c = self._cache.get(helper)
            start = c.top if c is not None else since
            self.fetches += 1
            data = await self._fetch(helper, start, self.limit, budget)
            if epoch != self._epoch:
                return
            raw = data.get("events") if isinstance(data.get("events"), list) else []
            full = len(raw) >= self.limit
            evs = sorted((e for e in raw if isinstance(e, dict) and _is_int(e.get("seq")) and e["seq"] > start),
                         key=lambda e: e["seq"])
            c = self._cache.get(helper)
            if c is None or c.top != start or data.get("lost"):
                # a new cache from start; when the mod lost events after start, every cursor
                # below the first event it still has gets ``lost``
                c = _Cache(base=start, top=start)
                if data.get("lost"):
                    c.lost_below = evs[0]["seq"] - 1 if evs else (data["seq"] if _is_int(data.get("seq")) else start)
                self._cache[helper] = c
            last = evs[-1]["seq"] if evs else start
            if full:
                top = last          # a cut page: only what it carried is known
            else:
                head = data.get("seq")
                top = max(last, head if _is_int(head) else start, start)
            c.events.extend(evs)
            if len(c.events) > CACHE_MAX:
                drop = len(c.events) - CACHE_MAX
                c.base = c.events[drop - 1]["seq"]
                del c.events[:drop]
            c.top = top
            c.more = full and last > start
            c.gen, c.at = fl.gen, at
        finally:
            if self._flight.get(helper) is fl:
                del self._flight[helper]

    def _slice(self, c: _Cache, since: int, limit: int) -> dict:
        evs = [e for e in c.events if e["seq"] > since]
        cut = len(evs) > limit
        evs = evs[:limit]
        seq = evs[-1]["seq"] if cut else c.top
        return {"seq": seq, "events": evs, "lost": since < c.lost_below, "more": cut or c.more}

    async def _direct(self, helper: str, since: int, limit: int, budget: float | None) -> dict:
        self.fetches += 1
        data = await self._fetch(helper, since, limit, budget)
        raw = data.get("events") if isinstance(data.get("events"), list) else []
        return dict(data, more=len(raw) >= limit)


def _retrieve(task: asyncio.Task) -> None:
    # the failure reaches every joined wait; this only keeps asyncio from logging it as unseen
    if not task.cancelled():
        task.exception()
