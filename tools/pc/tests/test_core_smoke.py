"""Сценарий core_smoke против фейкового RCON с моделью мода (без ПК и без игры)."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    return lc.load_scenario("core_smoke", os.path.join(PC_DIR, "scenarios"))


class Model:
    """Минимальная модель мода: отвечает формами из PROTOCOL.md / STATE.md."""

    def __init__(self, unknown_after_vision=0, no_owner=False, no_job_done=False, bad_state=False,
                 spawn_error=None):
        self.tick = 100
        self.seq = 3
        self.alive = False
        self.removed = False
        self.vision = False
        self.unknown_after_vision = unknown_after_vision
        self.no_owner = no_owner
        self.no_job_done = no_job_done
        self.bad_state = bad_state
        self.spawn_error = spawn_error
        self.job = None
        self.ops = []

    def rows(self):
        rows = ["." * 33 for _ in range(33)]
        mid = list(rows[16])
        mid[16] = "@"
        rows[16] = "".join(mid)
        if not self.vision:
            rows[0] = "?" * 33
        elif self.unknown_after_vision:
            rows[0] = "?" * self.unknown_after_vision + "." * (33 - self.unknown_after_vision)
        return rows

    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {")
        env = json.loads(cmd[len("/partner "):])
        op, args, helper = env["op"], env.get("args", {}), env.get("helper")
        self.ops.append(op)
        self.tick += 30

        def ok(data):
            return json.dumps({"v": 1, "id": env["id"], "ok": True, "tick": self.tick, "seq": self.seq, "data": data})

        def fail(code, text=""):
            return json.dumps({"v": 1, "id": env["id"], "ok": False, "tick": self.tick, "seq": self.seq,
                               "error": {"code": code, "text": text}})

        if op == "hello":
            return ok({"proto": 1, "mod": "0.1.0", "tick": self.tick, "seq": self.seq,
                       "owner": None if self.no_owner else "Tartaluga", "players_online": 0,
                       "players": [{"index": 1, "name": "Tartaluga", "online": False, "surface": "nauvis",
                                    "pos": {"x": 1, "y": 2}}], "helpers": {}})
        if op == "helper_spawn":
            if self.spawn_error:
                return fail(self.spawn_error)
            self.alive = True
            return ok({"helper": helper, "unit_number": 77, "surface": "nauvis", "pos": {"x": 3.5, "y": 2}})
        if op == "helper_list":
            if self.removed:
                return ok({"helpers": [{"id": "h1", "state": "removed", "cooldown_s": 300}]})
            return ok({"helpers": [{"id": "h1", "state": "alive", "surface": "nauvis", "pos": {"x": 3.5, "y": 2}}]})
        if not self.alive and op != "helper_remove":
            return fail("no_helper")
        if op == "state":
            d = {"helper": "h1", "surface": "nauvis", "pos": {"x": 3.5, "y": 2}, "health": 250, "max_health": 250,
                 "reach": {"build": 10, "reach": 10, "resource": 2.7, "pickup": 1}, "inv": {}, "inv_free": 80,
                 "robots": {"construction": 0, "available": 0}, "queue": 0, "players": {},
                 "near": {"enemies": {}, "containers": 0}, "vision": True, "tick": self.tick, "seq": self.seq}
            if self.bad_state:
                del d["reach"]
            return ok(d)
        if op == "map":
            return ok({"surface": "nauvis", "bbox": {"x0": -13, "y0": -14, "x1": 19, "y1": 18}, "axis": "x: -13",
                       "rows": self.rows(), "legend": {".": "земля", "@": "помощник", "?": "не открыто"},
                       "entities": {}, "truncated": False})
        if op == "resources":
            return ok({"patches": [{"name": "coal", "center": {"x": 10, "y": 5}, "area": {}, "tiles": 40,
                                    "amount": 1000, "dist": 8.5}], "truncated": False})
        if op == "stock":
            return ok({"containers": {}, "total": {}, "hidden": 0, "truncated": False})
        if op == "ghosts":
            return ok({"count": 0, "by_name": {}, "need": {}, "have": {"helper": {}, "stock": {}},
                       "missing": {}, "blocked": {}, "area": {}})
        if op == "recipes":
            return ok({"craftable": {}})
        if op == "rates":
            return ok({"scope": "surface", "surface": "nauvis", "period": "1m",
                       "items": {"iron-plate": {"made": 3, "used": 1}}, "fluids": {}, "truncated": False})
        if op == "vision":
            self.vision = args["on"]
            return ok({"on": self.vision})
        if op == "say":
            return ok({})
        if op == "act":
            self.job = 5
            self.seq += 1
            return ok({"job": 5, "queued_before": 0})
        if op == "events":
            evs = {}  # пустая таблица мода уходит как {} (PROTOCOL §1)
            if self.job and not self.no_job_done:
                evs = [{"seq": self.seq, "tick": self.tick, "helper": "h1", "kind": "job_done", "loud": True,
                        "data": {"job": 5, "do": "wait", "detail": {}}}]
            return ok({"seq": self.seq, "events": evs, "lost": False})
        if op == "jobs":
            return ok({"queue": {}})
        if op == "helper_remove":
            self.alive = False
            self.removed = True
            return ok({})
        return fail("unknown_op", op)


@pytest.fixture
def smoke(monkeypatch):
    m = load()
    monkeypatch.setattr(m, "VISION_WAIT_S", 0.01)
    monkeypatch.setattr(m, "VISION_EXTRA_S", 0.1)
    monkeypatch.setattr(m, "JOB_TIMEOUT_S", 0.3)
    monkeypatch.setattr(m, "POLL_S", 0.01)
    return m


def run(fake_rcon, smoke, **kw):
    model = Model(**kw)
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = smoke.run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)  # только /partner <JSON>
    return res, model


def test_smoke_ok(fake_rcon, smoke):
    res, model = run(fake_rcon, smoke)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == [
        "hello", "helper_spawn", "helper_list", "state", "map", "resources", "stock", "ghosts", "recipes",
        "rates", "vision", "say", "act_wait_events", "jobs", "helper_remove"]
    # порядок операций из задания
    order = [o for o in model.ops if o in ("hello", "helper_spawn", "state", "map", "resources", "stock", "ghosts",
                                           "recipes", "rates", "vision", "say", "act", "events", "helper_remove")]
    firsts = []
    for o in order:
        if o not in firsts:
            firsts.append(o)
    assert firsts == ["hello", "helper_spawn", "state", "map", "resources", "stock", "ghosts", "recipes", "rates",
                      "vision", "say", "act", "events", "helper_remove"]


def test_smoke_unknown_cells_after_vision_fail(fake_rcon, smoke):
    res, _ = run(fake_rcon, smoke, unknown_after_vision=3)
    assert res["ok"] is False and res["failed"] == ["vision"]
    assert "«?»" in next(s for s in res["steps"] if s["name"] == "vision")["error"]


def test_smoke_no_job_done(fake_rcon, smoke):
    res, _ = run(fake_rcon, smoke, no_job_done=True)
    assert res["failed"] == ["act_wait_events"]


def test_smoke_bad_state_shape(fake_rcon, smoke):
    res, _ = run(fake_rcon, smoke, bad_state=True)
    assert res["failed"] == ["state"]
    assert "reach" in next(s for s in res["steps"] if s["name"] == "state")["error"]


def test_smoke_no_owner_fails_hello_and_spawn_abort(fake_rcon, smoke):
    res, model = run(fake_rcon, smoke, no_owner=True, spawn_error="no_player")
    assert res["ok"] is False
    assert res["failed"] == ["hello", "helper_spawn"] and "aborted" in res
    assert "state" not in model.ops


def test_smoke_cleans_up_helper_on_exception(fake_rcon, smoke, monkeypatch):
    monkeypatch.setattr(smoke, "check_state", lambda d: None)
    monkeypatch.setattr(smoke, "check_map", lambda d: (_ for _ in ()).throw(KeyboardInterrupt()))
    model = Model()
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        with pytest.raises(KeyboardInterrupt):
            smoke.run(c)
    assert model.ops[-1] == "helper_remove"
