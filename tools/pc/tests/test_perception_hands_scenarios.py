"""Сценарии hands_get_items, perception_status, reflex_upkeep против фейкового RCON с маленькой моделью мода."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


class World:
    def __init__(self, stock=None, index_after=0, fuel_machine=False, fire=True, sets=None, errors_grow=False,
                 bad_status=False):
        self.stock = dict(stock if stock is not None else {"iron-plate": 400, "coal": 100})
        self.inv = {}
        self.sets = list(sets or [])
        self.index_after = index_after      # сколько ответов status index_ready=false
        self.fuel_machine = fuel_machine
        self.fire = fire
        self.errors_grow = errors_grow
        self.bad_status = bad_status
        self.events, self.seq, self.job, self.errors = [], 0, 0, 0
        self.ops, self.commands, self.acts = [], [], []

    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "build", "kind": kind, "data": data, "loud": True})

    def _get_items(self, items):
        self.job += 1
        (item, target), = items.items()
        have = self.inv.get(item, 0)
        frm = {}
        if have:
            frm["inventory"] = {item: have}
        take = min(target - have, self.stock.get(item, 0)) if item in self.stock else 0
        if take > 0:
            self.stock[item] -= take
            self.inv[item] = have + take
            frm["storage"] = {item: take}
        elif item == "iron-gear-wheel":
            need = (target - have) * 2
            self.inv["iron-plate"] = self.inv.get("iron-plate", 0) - need
            self.inv[item] = target
            frm["crafted"] = {item: target - have}
        self._emit("job_done", {"job": self.job, "do": "get_items",
                                "detail": {"have": {item: self.inv.get(item, 0)}, "from": frm}})

    def __call__(self, cmd):
        self.commands.append(cmd)
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}
        self.ops.append(op)

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": self.seq, "id": env["id"], "data": data})

        def fail(code):
            return json.dumps({"v": 1, "ok": False, "tick": 1, "seq": self.seq, "id": env["id"],
                               "error": {"code": code, "text": code}})

        if op == "hello":
            if self.errors_grow:
                self.errors += 1
            return ok({"proto": 1, "mod": "factorio-partner 0.5.0", "players_online": 0, "seq": self.seq,
                       "module_errors": self.errors})
        if op == "helper_spawn":
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "vulcanus", "pos": {"x": 0, "y": 0}})
        if op == "state":
            return ok({"helper": env["helper"], "pos": {"x": 0, "y": 0}, "inv": dict(self.inv) or {}})
        if op == "stock":
            want = args.get("items")
            total = {k: v for k, v in self.stock.items() if v > 0 and (not want or k in want)}
            return ok({"containers": [], "total": total or {}, "hidden": 0, "truncated": False})
        if op == "act":
            assert args["do"] == "get_items", args
            self.acts.append(args["args"])
            self._get_items(args["args"]["items"])
            return ok({"job": self.job, "queued_before": 0})
        if op == "events":
            return ok({"seq": self.seq, "events": [e for e in self.events if e["seq"] > args["since"]] or {},
                       "lost": False})
        if op == "cancel":
            return ok({"cancelled": []})
        if op == "reflexes":
            if "set" in args:
                self.sets = [dict(r, **({"radius": 96, "min": 2} if r["type"] == "upkeep" else {})) for r in args["set"]]
            return ok({"set": self.sets or {}})
        if op == "status":
            if args.get("radius", 0) > 128:
                return fail("limit")
            if self.bad_status:
                return ok({"machines": {"seen": "много"}, "causes": [], "stopped": [], "radius": args["radius"]})
            self.index_after -= 1
            if self.fuel_machine and self.fire and args["radius"] == 96:
                self._emit("reflex_fired", {"type": "upkeep", "detail": {"kind": "fuel", "item": "coal", "count": 10}})
            stopped = [{"name": "stone-furnace", "reason": "no_fuel", "cause": "fuel", "count": 2,
                        "pos": {"x": 5, "y": 5}, "dist": 7}] if self.fuel_machine else []
            return ok({"surface": "vulcanus", "center": {"x": 0, "y": 0}, "radius": args["radius"],
                       "machines": {"seen": 5, "running": 5 - len(stopped) * 2, "stopped": len(stopped) * 2,
                                    "hidden": 0, "ignored": 0},
                       "causes": {"fuel": 2} if stopped else {}, "stopped": stopped or {},
                       "index_ready": self.index_after < 0, "helper": {"queue": 0}})
        raise AssertionError(op)


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)
    monkeypatch.setattr(lc.time, "sleep", lambda s: None)
    real_poll = lc.LiveClient.poll
    # ожидания сценариев (до 40 с) в тесте сводятся к паре опросов
    monkeypatch.setattr(lc.LiveClient, "poll", lambda self, fn, timeout, interval=1.0: real_poll(self, fn, min(timeout, 0.05), interval))


def run(name, world, fake_rcon, **patch):
    sc = load(name)
    for k, v in patch.items():
        setattr(sc, k, v)
    srv = fake_rcon(handler=world)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = sc.run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)
    return res


# ---------- hands_get_items ----------

def test_get_items_storage_then_craft(fake_rcon):
    w = World()
    res = run("hands_get_items", w, fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("error")
    assert w.acts[0] == {"items": {"iron-plate": 20}}
    assert w.acts[1] == {"items": {"iron-gear-wheel": 5}}
    assert res["storage"]["after"] - res["storage"]["before"] == 20
    assert res["craft"]["from"].get("crafted")


def test_get_items_nothing_on_storage_is_setup_failure(fake_rcon):
    res = run("hands_get_items", World(stock={}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_get_items_storage_source_missing_is_failure(fake_rcon):
    w = World()
    orig = w._get_items

    def no_source(items):
        orig(items)
        w.events[-1]["data"]["detail"]["from"] = {}
    w._get_items = no_source
    res = run("hands_get_items", w, fake_rcon)
    assert res["ok"] is False
    assert any("detail.from.storage" in r for r in res["reasons"]), res["reasons"]


# ---------- perception_status ----------

def test_status_waits_for_index_and_parses(fake_rcon):
    w = World(index_after=2, fuel_machine=True)
    res = run("perception_status", w, fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("error")
    assert res["index_ready"] is True and res["machines"]["seen"] == 5
    assert res["stopped_groups"] == 1 and res["radius_129"] == "limit"
    assert w.ops.count("status") >= 4


def test_status_index_never_ready_fails(fake_rcon):
    res = run("perception_status", World(index_after=10 ** 6), fake_rcon, INDEX_WAIT_S=0.05)
    assert res["ok"] is False
    assert any("index_ready" in r for r in res["reasons"])


def test_status_bad_format_fails(fake_rcon):
    res = run("perception_status", World(bad_status=True), fake_rcon, INDEX_WAIT_S=0.05)
    assert res["ok"] is False
    assert any("machines.seen" in r for r in res["reasons"])


# ---------- reflex_upkeep ----------

ORIGINAL = [{"type": "watch", "radius": 32, "every_s": 10}]


def test_upkeep_fires_and_restores_set(fake_rcon):
    w = World(fuel_machine=True, sets=ORIGINAL)
    res = run("reflex_upkeep", w, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["fired"][0]["detail"]["kind"] == "fuel" and res["restored"] is True
    assert w.sets == ORIGINAL
    assert w.acts[0] == {"items": {"coal": 20}}


def test_upkeep_no_machine_observes_quietly_and_restores(fake_rcon):
    w = World(sets=ORIGINAL)
    res = run("reflex_upkeep", w, fake_rcon, OBSERVE_S=0.05)
    assert res["ok"] is True, res.get("reasons")
    assert "note" in res and w.sets == ORIGINAL


def test_upkeep_not_fired_is_failure_but_set_restored(fake_rcon):
    w = World(fuel_machine=True, fire=False, sets=ORIGINAL)
    res = run("reflex_upkeep", w, fake_rcon, FIRE_WAIT_S=0.05)
    assert res["ok"] is False and any("не сработал" in r for r in res["reasons"])
    assert w.sets == ORIGINAL


def test_upkeep_module_errors_growth_is_failure(fake_rcon):
    w = World(errors_grow=True)
    res = run("reflex_upkeep", w, fake_rcon, OBSERVE_S=0.05)
    assert res["ok"] is False and any("module_errors" in r for r in res["reasons"])
    assert w.sets == []
