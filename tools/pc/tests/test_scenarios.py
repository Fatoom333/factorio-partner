"""Сценарии e_* против фейков: сквозь настоящий LiveClient и фейковый RCON с моделью мода."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


def reply(env, ok=True, data=None, error=None, with_id=True):
    r = {"v": 1, "ok": ok, "tick": 1, "seq": 0}
    if with_id:
        r["id"] = env["id"]
    if ok:
        r["data"] = data or {}
    else:
        r["error"] = error
    return json.dumps(r)


# ---------- e_rcon_maxlen ----------

def test_search_finds_limit_exactly():
    maxlen = load("e_rcon_maxlen")
    limit = 70000
    res = maxlen.search(lambda s: {"size": s, "ok": s <= limit, "kind": "x"}, resolution=16)
    assert res["max_ok"] <= limit < res["first_fail"]
    assert res["first_fail"] - res["max_ok"] <= 16
    assert not res["cap_reached"]


def test_search_cap_reached():
    maxlen = load("e_rcon_maxlen")
    res = maxlen.search(lambda s: {"size": s, "ok": True}, cap=8192)
    assert res["max_ok"] == 8192 and res["cap_reached"]


def test_search_first_fails():
    maxlen = load("e_rcon_maxlen")
    res = maxlen.search(lambda s: {"size": s, "ok": False, "kind": "transport"})
    assert res["max_ok"] is None and res["first_fail"] == 1024


def _mod_handler(limit, mode="echo"):
    """Модель: команда длиннее limit байт — соединение рвётся (как неизвестный предел RCON)."""
    def handler(cmd):
        if cmd == "/quit":
            return None
        param = cmd[len("/partner "):]
        if len(param.encode()) > limit:
            return None
        env = json.loads(param)
        if env["op"] == "hello":
            return reply(env, data={"mod": "partner-test 0.2.0" if mode == "echo" else "factorio-partner 0.1.0"})
        if env["op"] == "e_echo":
            if mode == "echo":
                return reply(env, data={"len": len(param.encode()), "pad": len(env["args"]["pad"])})
            return reply(env, ok=False, error={"code": "unknown_op", "text": "e_echo"})
        if env["op"] == "e_big" and mode == "echo":
            return reply(env, data={"bytes": env["args"]["bytes"], "pad": "x" * env["args"]["bytes"]})
        return reply(env, ok=False, error={"code": "unknown_op", "text": env["op"]})
    return handler


@pytest.mark.parametrize("mode", ["echo", "unknown_op"])
def test_maxlen_against_fake_server(fake_rcon, mode):
    maxlen = load("e_rcon_maxlen")
    srv = fake_rcon(handler=_mod_handler(20000, mode))
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = maxlen.run(c)
    assert res["mode"] == mode
    assert res["max_ok_param_bytes"] <= 20000 < res["first_fail_param_bytes"]
    assert res["first_fail_param_bytes"] - res["max_ok_param_bytes"] <= maxlen.RESOLUTION
    assert res["ok"] is True and res["contract_limit_ok"] is True
    assert res["server_alive_after"] is True
    if mode == "echo":
        assert res["big_reply"] == {"ok": True, "kind": "big", "bytes": maxlen.BIG_REPLY}
    else:
        assert res["big_reply"] is None
    # каждая отправленная команда — /partner-конверт
    assert all(c.startswith("/partner {") for c in srv.commands)


def test_maxlen_below_contract_is_not_ok(fake_rcon):
    maxlen = load("e_rcon_maxlen")
    srv = fake_rcon(handler=_mod_handler(4000))
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = maxlen.run(c)
    assert res["max_ok_param_bytes"] < 4096 and res["ok"] is False


def test_maxlen_detects_truncation(fake_rcon):
    maxlen = load("e_rcon_maxlen")

    def handler(cmd):
        param = cmd[len("/partner "):]
        env = json.loads(param)
        if env["op"] == "hello":
            return reply(env, data={"mod": "partner-test 0.2.0"})
        # мод «видит» не больше 10000 байт — как будто RCON молча обрезал
        return reply(env, data={"len": min(len(param), 10000), "pad": 0})

    srv = fake_rcon(handler=handler)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = maxlen.run(c)
    assert res["max_ok_param_bytes"] <= 10000 < res["first_fail_param_bytes"]
    assert res["fail_kind"] == "length_mismatch"


def test_envelope_exact_size():
    maxlen = load("e_rcon_maxlen")
    c = lc.LiveClient(27100, PASSWORD)
    for size in (200, 1024, 8192, 100000):
        env = maxlen._envelope_for(c, size)
        assert len(lc.build_command(env).encode()) - len("/partner ") == size


# ---------- e_chart ----------

class ChartModel:
    """Модель мода: e_chart find/chart/check на силе игрока, чанк открывается после chart."""

    def __init__(self, charts=True, players_online=0, mod="partner-test 0.3.0", pre_charted=False, find_fails=False, delay=0):
        self.delay = delay  # сколько вызовов check после chart чанк ещё закрыт (чартинг асинхронный)
        self.pending = None
        self.tick = 1000
        self.charted = pre_charted
        self.charts = charts
        self.players_online = players_online
        self.mod = mod
        self.find_fails = find_fails
        self.ops = []
        self.modes = []

    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        env = json.loads(cmd[len("/partner "):])
        op = env["op"]
        self.ops.append(op)
        self.tick += 30
        if op == "hello":
            return reply(env, data={"mod": self.mod, "players_online": self.players_online, "players": []})
        if op == "e_chart":
            args = env["args"]
            self.modes.append(args["mode"])
            if args["mode"] == "find":
                if self.find_fails:
                    return reply(env, ok=False, error={"code": "not_found", "text": "нет чанка"})
                return reply(env, data={"chunk": {"x": 21, "y": -1}, "dist": 12, "force": "player"})
            if args["mode"] == "chart" and self.charts:
                if self.delay:
                    self.pending = self.delay
                else:
                    self.charted = True
            elif args["mode"] == "check" and self.pending is not None:
                self.pending -= 1
                if self.pending <= 0:
                    self.charted, self.pending = True, None
            return reply(env, data={"force": "player", "chunk": args["chunk"], "charted": self.charted,
                                    "window_charted": 21 if self.charted else 0, "window": 25,
                                    "tick": self.tick, "players_online": self.players_online})
        return reply(env, ok=False, error={"code": "unknown_op", "text": op})


@pytest.fixture
def fast_chart(monkeypatch):
    chart = load("e_chart")
    monkeypatch.setattr(chart, "BASELINE_S", 0.01)
    monkeypatch.setattr(chart, "CHART_TIMEOUT_S", 0.3)
    monkeypatch.setattr(chart, "POLL_S", 0.01)
    return chart


def test_chart_ok(fake_rcon, fast_chart):
    model = ChartModel()
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = fast_chart.run(c)
    assert res["ok"] is True, res
    assert res["force"] == "player" and res["chunk"] == {"x": 21, "y": -1}
    assert res["baseline"]["charted"] is False and res["after"]["charted"] is True
    assert model.modes[0] == "find" and model.modes.count("chart") == 1
    # телепортов, /c и прочих команд нет: только e_chart и hello
    assert set(model.ops) == {"hello", "e_chart"}


def test_chart_async_charting_opens_on_later_poll(fake_rcon, fast_chart):
    model = ChartModel(delay=3)
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = fast_chart.run(c)
    assert res["ok"] is True, res
    assert model.modes.count("check") >= 2 + 3


@pytest.mark.parametrize("kw, reason", [
    ({"charts": False}, "не открылся"),
    ({"players_online": 1}, "игроки"),
    ({"pre_charted": True}, "ещё до force.chart"),
])
def test_chart_failures(fake_rcon, fast_chart, kw, reason):
    model = ChartModel(**kw)
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = fast_chart.run(c)
    assert res["ok"] is False
    assert any(reason in r for r in res["reasons"]), res["reasons"]


def test_chart_needs_partner_test(fake_rcon, fast_chart):
    srv = fake_rcon(handler=ChartModel(mod="factorio-partner 0.1.0"))
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = fast_chart.run(c)
    assert res["ok"] is False and "partner-test" in res["error"]["text"]


def test_chart_no_candidate_chunk_raises(fake_rcon, fast_chart):
    srv = fake_rcon(handler=ChartModel(find_fails=True))
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        with pytest.raises(Exception, match="not_found|нет чанка"):
            fast_chart.run(c)


def test_scenarios_export_run_and_mods():
    d = os.path.join(PC_DIR, "scenarios")
    for n in sorted(os.listdir(d)):
        if n.endswith(".py"):
            mod = load(n[:-3])
            assert callable(mod.run)


def test_maxlen_fails_on_fragmented_big_reply(fake_rcon):
    """Ответ e_big пришёл не целиком (первый кусок, как Source RCON по 4096) — сценарий не ok."""
    maxlen = load("e_rcon_maxlen")
    base = _mod_handler(20000)

    def handler(cmd):
        if cmd.startswith("/partner ") and '"op":"e_big"' in cmd:
            env = json.loads(cmd[len("/partner "):])
            return reply(env, data={"bytes": 199000, "pad": "x" * 199000})[:4096]
        return base(cmd)

    srv = fake_rcon(handler=handler)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = maxlen.run(c)
    assert res["big_reply"]["ok"] is False and res["big_reply"]["kind"] == "protocol"
    assert res["ok"] is False
    assert res["contract_limit_ok"] is True  # длина команды сама по себе в порядке
