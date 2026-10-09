"""partner_wait: response size cut, cursor = last handed-over seq, no spin, notices kept, deadline."""
import asyncio
import json
import time

import pytest

from factorio_partner.core import MAX_RESPONSE, Core
from factorio_partner.errors import PartnerError

from conftest import KEY, make_bridge


async def code_of(coro):
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


def _detail(n):
    return {"missing": [{"name": f"item-{i:02d}", "count": i, "pos": {"x": i * 1.5, "y": -i * 2.5}}
                        for i in range(n)]}


def _size(v):
    return len(json.dumps(v, ensure_ascii=False).encode("utf-8"))


async def test_wait_large_page_is_cut_not_lost(core, fake):
    """40 loud job_failed with ~700-byte detail exceed 24 KB: nothing may be lost."""
    await core.op_state("h1", KEY)
    for j in range(1, 41):
        fake.mod.emit("job_failed", {"job": j, "do": "build_ghosts", "code": "blocked",
                                     "detail": _detail(10)})
    assert _size(fake.mod.events) > MAX_RESPONSE
    got = []
    pages = 0
    while True:
        r = await core.op_wait("h1", KEY, timeout=0.5)
        pages += 1
        assert _size(r) <= MAX_RESPONSE
        got += [e["data"]["job"] for e in r["events"]]
        assert r["events"] and r["seq"] == r["events"][-1]["seq"]   # cursor = last handed over
        if not r.get("more"):
            break
        assert pages < 6
    assert pages >= 2
    assert got == list(range(1, 41))
    r = await core.op_wait("h1", KEY, timeout=0.05)
    assert r["events"] == [] and r["timed_out"]


async def test_wait_single_huge_event_shrunk(core, fake):
    await core.op_state("h1", KEY)
    fake.mod.emit("job_failed", {"job": 7, "do": "build_ghosts", "code": "blocked",
                                 "detail": _detail(400)})
    r = await core.op_wait("h1", KEY, timeout=0.5)
    assert _size(r) <= MAX_RESPONSE
    ev = r["events"][0]
    assert ev["data"] == {"job": 7, "do": "build_ghosts", "code": "blocked", "truncated": True}
    assert ev["kind"] == "job_failed" and r["seq"] == ev["seq"]


async def test_wait_cut_page_counts_failures_once(core, fake):
    await core.op_state("h1", KEY)
    args = {"seconds": 5}
    jobs = [(await core.op_act("h1", KEY, "wait", args))["job"] for _ in range(2)]
    for j in range(100, 130):       # filler that forces a cut before our events
        fake.mod.emit("job_failed", {"job": j, "do": "x", "code": "blocked", "detail": _detail(10)})
    for j in jobs:
        fake.mod.emit("job_failed", {"job": j, "do": "wait", "code": "stuck"})
    for _ in range(6):
        r = await core.op_wait("h1", KEY, timeout=0.2)
        if not r.get("more"):
            break
    # two failures, each counted once even though pages were re-fetched -> still allowed
    await core.op_act("h1", KEY, "wait", args)


async def test_wait_full_page_without_progress_does_not_spin(cfg, fake):
    now = [0.0]
    c = Core(cfg, make_bridge(cfg), poll_interval=0.5, forge_module="tests_no_such_forge_module",
             clock=lambda: now[0])

    async def fake_sleep(dt):
        now[0] += dt
        await asyncio.sleep(0)
    c.sleep = fake_sleep
    await c.op_state("h1", KEY)
    # a broken mod: a full page of events that never move the cursor
    fake.mod.handlers["events"] = lambda a, e: {
        "seq": 0, "events": [{"seq": 0, "kind": "x", "loud": False}] * 200}
    r = await c.op_wait("h1", KEY, timeout=5)
    assert r["timed_out"] is True and r["events"] == []
    assert fake.mod.executed["events"] <= 12      # ~timeout / poll_interval, not thousands
    await c.close()


async def test_wait_reload_notice_survives_poll_failure(core, fake):
    await core.op_state("h1", KEY)
    fake.mod.tick = 5
    await core.op_state("h1", KEY)                 # reload seen on cmd: notice queued for h1
    fake.faults.extend(["drop", "drop", "drop"])   # the first poll of the wait fails
    e = await code_of(core.op_wait("h1", KEY, timeout=0.05))
    assert e.code == "transport_timeout"
    r = await core.op_wait("h1", KEY, timeout=0.05)
    assert [x["kind"] for x in r["events"]] == ["game_reloaded"]


async def test_wait_last_poll_respects_deadline(cfg, fake):
    """A mod that hangs mid-wait must not stretch partner_wait far past its timeout."""
    c = Core(cfg, make_bridge(cfg, poll_timeout=5.0, retry_delay=0.01), poll_interval=0.05,
             forge_module="tests_no_such_forge_module")
    await c.op_state("h1", KEY)
    real = fake.mod.handle
    calls = [0]

    def handle(env):
        if env.get("op") == "events":
            calls[0] += 1
            if calls[0] == 2:
                fake.faults.extend(["drop"] * 3)
        return real(env)
    fake.mod.handle = handle
    t0 = time.monotonic()
    with pytest.raises(PartnerError) as ei:
        await c.op_wait("h1", KEY, timeout=1.0)
    assert ei.value.code == "transport_timeout"
    assert time.monotonic() - t0 < 3.0      # not 1 s + 3 x 5 s
    await c.close()
