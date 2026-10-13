"""Сценарий hands_mine (поток V2, «Руки») против фейкового RCON с маленькой моделью мода.

Проверяется шаг ревизии 3.3: дерево и камень добываются вплотную (`resource_reach_distance`), а не с
`reach_distance`. Модель умеет вести себя и «по-старому» (встаёт в 8 клетках и ничего не добывает).
"""
from __future__ import annotations

import json
import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


class World:
    """Руда рядом, камень и дерево поодаль. far_reach — мод подходит к камню и дереву только на
    reach_distance (как до ревизии 3.3): в игре с такого расстояния рука их не добывает."""

    YIELD = {"big-volcanic-rock": {"stone": 4, "coal": 2}, "ashland-lichen-tree": {"wood": 2}}

    def __init__(self, naturals=None, far_reach=False, ore=True, lose_item=False):
        self.pos = {"x": 5.0, "y": 5.0}
        self.inv = {}
        self.naturals = dict(naturals if naturals is not None else {
            (20.4, 6.1): "big-volcanic-rock", (-9.5, 12.5): "ashland-lichen-tree"})
        self.far_reach = far_reach
        self.ore = ore
        self.lose_item = lose_item
        self.events, self.seq, self.job, self.acts = [], 0, 0, []

    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "hands", "kind": kind, "data": data, "loud": True})

    def _give(self, items):
        for k, n in items.items():
            self.inv[k] = self.inv.get(k, 0) + n

    def _walk(self, to, stop):
        d = math.hypot(to[0] - self.pos["x"], to[1] - self.pos["y"])
        if d > stop:
            k = (d - stop) / d
            self.pos = {"x": round(self.pos["x"] + (to[0] - self.pos["x"]) * k, 1),
                        "y": round(self.pos["y"] + (to[1] - self.pos["y"]) * k, 1)}

    def _mine(self, a):
        self.job += 1
        self.acts.append(a)
        if "resource" in a:
            self._walk((a["near"]["x"], a["near"]["y"]), 2.0)
            self._give({a["resource"]: a["count"]})
            return self._emit("job_done", {"job": self.job, "do": "mine", "detail": {"mined": {a["resource"]: a["count"]}}})
        t = a["target"]
        key = next((k for k, n in self.naturals.items()
                    if n == t["name"] and math.hypot(k[0] - t["pos"]["x"], k[1] - t["pos"]["y"]) <= 1), None)
        if key is None:
            return self._emit("job_failed", {"job": self.job, "do": "mine", "code": "not_found", "text": "not found", "detail": {}})
        if self.far_reach:
            # встал на reach_distance: движок с такого расстояния камень не добывает
            self._walk(key, 8.5)
            return self._emit("job_failed", {"job": self.job, "do": "mine", "code": "stuck",
                                             "text": "target is not being mined", "detail": {"mined": {}}})
        self._walk(key, 2.0)
        got = dict(self.YIELD[self.naturals.pop(key)])
        self._give(got)
        if self.lose_item:
            got = {k: n + 1 for k, n in got.items()}
        self._emit("job_done", {"job": self.job, "do": "mine", "detail": {"mined": got}})

    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": self.seq, "id": env["id"], "data": data})

        if op == "hello":
            return ok({"proto": 1, "mod": "factorio-partner 0.1.0", "players_online": 0})
        if op == "helper_spawn":
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "vulcanus", "pos": self.pos})
        if op == "state":
            return ok({"helper": env["helper"], "pos": self.pos, "surface": "vulcanus", "inv": dict(self.inv)})
        if op == "resources":
            patches = [{"name": "coal", "center": {"x": 12.0, "y": 5.0}, "tiles": 40, "amount": 9000}] if self.ore else []
            return ok({"patches": patches, "truncated": False})
        if op == "map":
            c, r = args["center"], args.get("radius", 16)
            assert args.get("types") == ["simple-entity", "tree"], "нейтральное запрошено явно"
            ents = [{"c": "T" if "tree" in n else "#", "name": n, "pos": {"x": k[0], "y": k[1]}}
                    for k, n in self.naturals.items() if abs(k[0] - c["x"]) <= r and abs(k[1] - c["y"]) <= r]
            return ok({"entities": ents, "rows": [], "truncated": False})
        if op == "act":
            assert args["do"] == "mine"
            self._mine(args["args"])
            return ok({"job": self.job, "queued_before": 0})
        if op == "events":
            return ok({"seq": self.seq, "events": [e for e in self.events if e["seq"] > args["since"]], "lost": False})
        if op == "cancel":
            return ok({"cancelled": []})
        raise AssertionError(op)


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)


def run(world, fake_rcon):
    srv = fake_rcon(handler=world)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = lc.load_scenario("hands_mine", os.path.join(PC_DIR, "scenarios")).run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)
    return res


def test_mine_ore_then_rock_and_tree_up_close(fake_rcon):
    w = World()
    res = run(w, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    near = res["near"]
    assert near["found"] == {"rock": 1, "tree": 1}
    # цель — в форме {name, pos}: у камней и деревьев нет unit_number
    assert w.acts[1] == {"target": {"name": "big-volcanic-rock", "pos": {"x": 20.4, "y": 6.1}}, "count": 1}
    assert w.acts[2]["target"]["name"] == "ashland-lichen-tree"
    assert near["rock"]["mined"] == {"stone": 4, "coal": 2} and near["rock"]["gain"] == {"stone": 4, "coal": 2}
    assert near["rock"]["dist_after"] <= 2.7 and near["rock"]["left_on_map"] == 0
    assert near["tree"]["mined"] == {"wood": 2} and near["tree"]["dist_after"] <= 2.7
    assert w.naturals == {}


def test_mine_from_reach_distance_is_failure(fake_rcon):
    """Мод до ревизии 3.3: подходит на reach_distance и застревает — сценарий это ловит."""
    res = run(World(far_reach=True), fake_rcon)
    assert res["ok"] is False
    assert sum("mine не done: stuck" in r for r in res["reasons"]) == 2, res["reasons"]
    assert res["near"]["rock"]["dist_after"] > 4.5 and res["near"]["rock"]["left_on_map"] == 1


def test_mine_only_rock_nearby_is_ok(fake_rcon):
    res = run(World(naturals={(20.4, 6.1): "big-volcanic-rock"}), fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["near"]["tree"] == {"skipped": "рядом нет"} and res["near"]["rock"]["kind"] == "job_done"


def test_mine_nothing_nearby_is_not_verified(fake_rcon):
    res = run(World(naturals={}), fake_rcon)
    assert res["ok"] is False
    assert any("не проверена" in r for r in res["reasons"])


def test_mine_detail_must_match_inventory(fake_rcon):
    res = run(World(lose_item=True), fake_rcon)
    assert res["ok"] is False
    assert any("не совпал с приростом инвентаря" in r for r in res["reasons"]), res["reasons"]


def test_naturals_helper_sorts_and_skips_cliffs(fake_rcon):
    s = lc.load_scenario("hands_mine", os.path.join(PC_DIR, "scenarios"))
    w = World(naturals={(30.5, 5.0): "big-volcanic-rock", (8.5, 5.0): "huge-volcanic-rock", (6.5, 5.0): "cliff-vulcanus",
                        (7.0, 9.0): "ashland-lichen-tree"})
    srv = fake_rcon(handler=w)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        found = s.naturals(c, w.pos)
    assert [e["name"] for e in found["rock"]] == ["huge-volcanic-rock", "big-volcanic-rock"]
    assert [e["name"] for e in found["tree"]] == ["ashland-lichen-tree"]
