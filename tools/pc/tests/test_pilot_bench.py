"""Сценарий pilot_bench против фейкового RCON с маленькой моделью мода и «агентом» внутри модели."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    return lc.load_scenario("pilot_bench", os.path.join(PC_DIR, "scenarios"))


class World:
    """Помощник с карманами и сундуками. `script` — что «агент» делает при очередном опросе state."""

    def __init__(self, stock=400, inv=None, chests=None, script=None, errors_grow=False, mod="factorio-partner 0.6.0"):
        self.stock = stock
        self.inv = dict(inv or {})
        self.chests = list(chests or [])        # [{"name","pos"}]
        self.script = list(script or [])        # шаги: вызываются по очереди на каждом state
        self.errors_grow = errors_grow
        self.mod = mod
        self.tick = 1000
        self.state_calls = 0
        self.idle = 0
        self.job = None
        self.module_errors = 0
        self.ops, self.commands = [], []

    def __call__(self, cmd):
        self.commands.append(cmd)
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}
        self.ops.append(op)

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": self.tick, "seq": 0, "id": env["id"], "data": data})

        if op == "hello":
            return ok({"proto": 1, "mod": self.mod, "players_online": 0, "seq": 0, "module_errors": self.module_errors})
        if op == "helper_spawn":
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "vulcanus", "pos": {"x": 10, "y": 20}})
        if op == "stock":
            return ok({"containers": [], "total": {"iron-plate": self.stock} if self.stock else {}, "hidden": 0,
                       "truncated": False})
        if op == "state":
            self.state_calls += 1
            if self.script and self.state_calls > 1:      # первый state — снимок начала, агент ещё не начал
                self.script.pop(0)(self)
            self.tick += 600
            if self.errors_grow:
                self.module_errors += 1
            st = {"helper": env["helper"], "pos": {"x": 10.5, "y": 20.5}, "inv": dict(self.inv) or {},
                  "idle_ticks": self.idle, "tick": self.tick, "busy_share": 0.5}
            if self.job:
                st["job"] = {"job": 1, "do": self.job}
            return ok(st)
        if op == "map":
            assert args["radius"] <= 32 and set(args["names"]) <= {"wooden-chest", "iron-chest", "steel-chest"}
            ents = [{"c": "C", "name": c["name"], "pos": c["pos"]} for c in self.chests]
            return ok({"entities": ents or [], "rows": [], "bbox": {}})
        raise AssertionError(op)


def add_plates(n):
    def step(w):
        w.inv["iron-plate"] = w.inv.get("iron-plate", 0) + n
        w.job = "get_items"
    return step


def place(name, x):
    def step(w):
        w.chests.append({"name": name, "pos": {"x": x, "y": 20.5}})
        w.job = "place"
    return step


def finish(w):
    w.job = None
    w.idle = 600


@pytest.fixture(autouse=True)
def fast(monkeypatch, tmp_path):
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)
    monkeypatch.setattr(lc.time, "sleep", lambda s: None)
    monkeypatch.setenv("FP_BENCH_DIR", str(tmp_path / "bench"))
    monkeypatch.delenv("FP_BENCH_PHASE", raising=False)


def run(world, fake_rcon, **patch):
    sc = load()
    sc.WAIT_S = 2.0
    for k, v in patch.items():
        setattr(sc, k, v)
    srv = fake_rcon(handler=world)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = sc.run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)
    return res


def test_done_settles_early(fake_rcon):
    w = World(script=[add_plates(30), add_plates(20), place("wooden-chest", 12.5), place("wooden-chest", 13.5), finish])
    res = run(w, fake_rcon)
    assert res["ok"] is True and res["verdict"] == "done", res
    assert res["plates_gain"] == 50 and res["chests_new"] == 2 and res["score"] == 1.0
    assert res["ended_by"] == "settled" and "Поручение" in res["task"]
    assert res["body"]["game_minutes"] > 0 and res["body"]["idle_ticks_last"] == 600
    assert 0 < res["body"]["busy_polls_share"] < 1 and res["module_errors"] == 0


def test_iron_chests_count_plates_spent_on_them(fake_rcon):
    # 58 пластин добыто, 16 ушло в два железных сундука: в карманах 42, но задача сделана
    w = World(script=[add_plates(58), lambda w: (w.inv.update({"iron-plate": 42}), place("iron-chest", 12.5)(w),
                                                 place("iron-chest", 13.5)(w)), finish])
    res = run(w, fake_rcon)
    assert res["verdict"] == "done" and res["plates_gain"] == 58


def test_partial_when_only_plates(fake_rcon):
    res = run(World(script=[add_plates(50)]), fake_rcon, WAIT_S=0.05)
    assert res["verdict"] == "partial" and res["ok"] is False and res["score"] == 0.5
    assert res["ended_by"] == "timeout" and any("partial" in r for r in res["reasons"])


def test_none_when_agent_did_nothing(fake_rcon):
    res = run(World(), fake_rcon, WAIT_S=0.05)
    assert res["verdict"] == "none" and res["score"] == 0.0 and res["ok"] is False


def test_existing_chests_do_not_count(fake_rcon):
    old = [{"name": "wooden-chest", "pos": {"x": 11.5, "y": 20.5}}, {"name": "iron-chest", "pos": {"x": 9.5, "y": 20.5}}]
    res = run(World(chests=old), fake_rcon, WAIT_S=0.05)
    assert res["chests_new"] == 0 and res["verdict"] == "none"


def test_stop_file_ends_wait(fake_rcon, tmp_path):
    def stop(w):
        open(os.path.join(str(tmp_path / "bench"), "stop"), "w").close()
    res = run(World(script=[add_plates(5), stop]), fake_rcon)
    assert res["ended_by"] == "stop_file" and res["verdict"] == "partial"


def test_not_enough_plates_is_setup_failure(fake_rcon):
    res = run(World(stock=10), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_wrong_mod_is_setup_failure(fake_rcon):
    res = run(World(mod="partner-test 0.1.0"), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_module_errors_growth_fails_even_when_done(fake_rcon):
    w = World(script=[add_plates(50), place("wooden-chest", 12.5), place("wooden-chest", 13.5), finish],
              errors_grow=True)
    res = run(w, fake_rcon)
    assert res["verdict"] == "done" and res["ok"] is False
    assert any("module_errors" in r for r in res["reasons"])


def test_prepare_then_judge_phases(fake_rcon, monkeypatch):
    w = World()
    monkeypatch.setenv("FP_BENCH_PHASE", "prepare")
    res = run(w, fake_rcon)
    assert res["ok"] is True and res["phase"] == "prepare" and res["task"]
    assert "state" in w.ops and w.ops.count("state") == 1   # ожидания нет
    # «агент» поработал между фазами
    w.inv["iron-plate"] = 50
    w.chests += [{"name": "wooden-chest", "pos": {"x": 12.5, "y": 20.5}}, {"name": "steel-chest", "pos": {"x": 14.5, "y": 20.5}}]
    monkeypatch.setenv("FP_BENCH_PHASE", "judge")
    res = run(w, fake_rcon)
    assert res["verdict"] == "done" and res["ok"] is True


def test_judge_without_baseline_is_setup_failure(fake_rcon, monkeypatch):
    monkeypatch.setenv("FP_BENCH_PHASE", "judge")
    res = run(World(), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_bad_phase_is_refused(fake_rcon, monkeypatch):
    monkeypatch.setenv("FP_BENCH_PHASE", "хм")
    res = run(World(), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_evaluate_is_pure():
    sc = load()
    base = {"plates": 10, "chests": {"a": "wooden-chest"}}
    now = {"plates": 60, "chests": {"a": "wooden-chest", "b": "wooden-chest", "c": "wooden-chest"}}
    assert sc.evaluate(base, now)["verdict"] == "done"
    assert sc.evaluate(base, dict(now, plates=59))["verdict"] == "partial"
