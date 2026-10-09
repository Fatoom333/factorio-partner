import json
import re

import pytest

from factorio_partner.bridge import MAX_REQUEST, Bridge
from factorio_partner.errors import PartnerError

from conftest import make_bridge


def sent_ids(fake):
    return [json.loads(c[len("/partner "):])["id"] for c in fake.commands]


def test_ids_unique_and_valid(cfg):
    b1, b2 = Bridge(cfg), Bridge(cfg)
    ids = [b1.new_id() for _ in range(100)]
    assert len(set(ids)) == 100
    assert all(re.match(r"^[A-Za-z0-9_.:-]{1,40}$", i) for i in ids)
    assert b1.new_id().split("-")[0] != b2.new_id().split("-")[0]  # per-process prefix


async def test_envelope_shape(bridge, fake):
    resp = await bridge.request("act", {"do": "walk", "args": {"to": {"x": 1, "y": 2}}}, "h1")
    assert resp["ok"]
    env = json.loads(fake.commands[0][len("/partner "):])
    assert env["v"] == 1 and env["op"] == "act" and env["helper"] == "h1"
    assert env["args"]["do"] == "walk"
    assert fake.commands[0].isascii()


async def test_drop_retries_same_id_without_duplicate(bridge, fake):
    fake.faults.append("drop")
    resp = await bridge.request("act", {"do": "wait", "args": {"seconds": 1}}, "h1")
    assert resp["ok"] and resp["data"]["job"] == 1
    ids = sent_ids(fake)
    assert len(ids) == 2 and ids[0] == ids[1]
    assert fake.mod.executed["act"] == 1   # idempotent: executed once
    assert fake.connections == 2           # reconnected after the timeout


async def test_three_failures_transport_timeout(bridge, fake):
    fake.faults.extend(["drop", "drop", "drop"])
    with pytest.raises(PartnerError) as ei:
        await bridge.request("hello")
    assert ei.value.code == "transport_timeout"
    assert len(set(sent_ids(fake))) == 1 and len(fake.commands) == 3


@pytest.mark.parametrize("fault", ["stale", "wrong_packet_id", "garbage", "empty", "close"])
async def test_bad_replies_are_retried(bridge, fake, fault):
    await bridge.request("hello")          # gives "stale" a previous envelope
    fake.faults.append(fault)
    resp = await bridge.request("act", {"do": "wait", "args": {"seconds": 1}}, "h1")
    assert resp["ok"] and resp["data"]["job"] == 1
    assert fake.mod.executed["act"] == 1


async def test_slow_reply_then_ok(cfg, fake):
    b = make_bridge(cfg, cmd_timeout=0.2)
    fake.faults.append(("delay", 0.5))
    resp = await b.request("hello")
    assert resp["ok"]
    await b.close()


async def test_garbage_three_times_reports_excerpt(bridge, fake):
    fake.faults.extend(["garbage"] * 3)
    with pytest.raises(PartnerError) as ei:
        await bridge.request("hello")
    assert ei.value.code == "transport_timeout"
    assert "Unknown command" in str(ei.value)


async def test_auth_failure_no_retry(cfg, fake, home):
    (home / "rcon.pw").write_text("nope", encoding="utf-8")
    b = make_bridge(cfg)
    with pytest.raises(PartnerError) as ei:
        await b.request("hello")
    assert ei.value.code == "transport_timeout" and "authentication" in str(ei.value)
    assert fake.auth_failures == 1
    assert "nope" not in str(ei.value)


async def test_request_too_large_not_sent(bridge, fake):
    with pytest.raises(PartnerError) as ei:
        await bridge.request("say", {"text": "x" * MAX_REQUEST}, "h1")
    assert ei.value.code == "limit"
    assert fake.commands == []


async def test_bad_helper_rejected(bridge):
    with pytest.raises(PartnerError):
        await bridge.request("state", {}, "H1;/c")


async def test_mod_error_without_id_accepted(bridge, fake):
    # emulate a mod that could not read the envelope: reply without id
    orig = fake.mod.handle
    fake.mod.handle = lambda env: {"v": 1, "ok": False, "tick": 5, "seq": 0,
                                   "error": {"code": "bad_request", "text": "x"}}
    resp = await bridge.request("hello")
    assert resp["ok"] is False and resp["error"]["code"] == "bad_request"
    assert len(fake.commands) == 1
    fake.mod.handle = orig


async def test_reload_detected(bridge, fake):
    seen = []
    bridge.on_reload(lambda tick, seq: seen.append((tick, seq)))
    await bridge.request("hello")
    fake.mod.tick = 10
    fake.mod.seq = 3
    await bridge.request("hello")
    assert seen == [(11, 3)]
    assert bridge.reloads == 1


async def test_paused_detection(cfg, fake):
    now = [100.0]
    b = make_bridge(cfg, clock=lambda: now[0])
    fake.mod.tick_step = 0
    await b.request("hello")
    assert not b.paused
    now[0] += 2.0
    await b.request("hello")
    assert not b.paused
    now[0] += 1.5
    await b.request("hello")
    assert b.paused
    fake.mod.tick_step = 1
    await b.request("hello")
    assert not b.paused
    await b.close()


async def test_channels_are_separate(bridge, fake):
    await bridge.request("hello", channel="cmd")
    await bridge.request("events", {"since": 0}, channel="poll")
    assert fake.connections == 2


async def test_mod_error_without_id_on_reused_socket_not_trusted(bridge, fake):
    await bridge.request("hello")               # the cmd socket is now in use
    orig = fake.mod.handle
    fake.mod.handle = lambda env: {"v": 1, "ok": False, "tick": 5, "seq": 0,
                                   "error": {"code": "bad_request", "text": "x"}}
    resp = await bridge.request("hello")
    # on a reused socket an id-less refusal may be a late reply to an earlier command: the
    # bridge reconnects and accepts it only from the fresh socket
    assert resp["ok"] is False and resp["error"]["code"] == "bad_request"
    assert len(fake.commands) == 3 and fake.connections == 2
    fake.mod.handle = orig


async def test_budget_limits_retries(cfg, fake):
    import time
    b = make_bridge(cfg, poll_timeout=5.0, retry_delay=0.01)
    fake.faults.extend(["drop", "drop", "drop"])
    t0 = time.monotonic()
    with pytest.raises(PartnerError) as ei:
        await b.request("events", {"since": 0}, channel="poll", budget=0.6)
    took = time.monotonic() - t0
    assert ei.value.code == "transport_timeout"
    assert took < 2.0                    # not 3 x 5 s
    assert len(fake.commands) == 1
    await b.close()


async def test_password_file_missing_is_a_clear_error(cfg, fake, home):
    (home / "rcon.pw").unlink()
    b = make_bridge(cfg)
    with pytest.raises(PartnerError) as ei:
        await b.request("hello")
    assert ei.value.code == "transport_timeout"
    assert "password file" in str(ei.value)
    assert fake.commands == [] and fake.connections == 0
    await b.close()
