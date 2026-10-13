"""Сценарии reflex_* (поток H) против фейкового RCON с моделью мода (без ПК и без игры)."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR

FLEE = {"radius": 20, "distance": 30, "health": 1, "on_attack": True, "to": "away"}
WATCH = {"radius": 32, "every_s": 10}
LIMITS = {"radius": 32, "distance": 64, "health": 1, "every_s": 600}


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


class Model:
    """Модель мода: помощники, набор рефлексов со схемой flee/watch, очередь из одной задачи wait."""

    def __init__(self, mod="0.1.0", accept_unknown=False, respawn_after_remove=False, lose_helper=False,
                 frozen=False, no_defaults=False, no_cooldown=False, enemies=False):
        self.tick = 1000
        self.seq = 0
        self.events = []
        self.helpers = {}      # id -> {"state", "removed_tick"}
        self.sets = {}
        self.mod = mod
        self.accept_unknown = accept_unknown
        self.respawn_after_remove = respawn_after_remove
        self.lose_helper = lose_helper
        self.frozen = frozen
        self.no_defaults = no_defaults
        self.no_cooldown = no_cooldown
        self.enemies = enemies
        self.job = 0
        self.ops = []
        self.commands = []

    def emit(self, helper, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.tick, "helper": helper, "kind": kind, "data": data,
                            "loud": kind != "saw_enemy"})

    def advance(self):
        if not self.frozen:
            self.tick += 60
        for hid, h in self.helpers.items():
            if (self.respawn_after_remove and h["state"] == "removed" and not h.get("respawned")
                    and self.tick - h["removed_tick"] >= 600):
                h["respawned"] = True
                h["state"] = "alive"
                self.emit(hid, "respawned", {"pos": {"x": 0, "y": 0}})
            if self.lose_helper and h["state"] == "alive" and self.tick - h["spawned_tick"] >= 900:
                h["state"] = "removed"
                h["removed_tick"] = self.tick
                self.emit(hid, "helper_lost", {"reason": "destroyed"})
            if self.enemies and h["state"] == "alive" and self.sets.get(hid):
                self.emit(hid, "saw_enemy", {"name": "small-biter", "pos": {"x": 9, "y": 9}, "dist": 12})

    def check_set(self, rset):
        out = []
        for r in rset:
            t = r.get("type")
            base = {"flee": FLEE, "watch": WATCH}.get(t)
            if base is None:
                if self.accept_unknown and t is not None:
                    out.append(dict(r))
                    continue
                return None, "bad_args"
            item = {"type": t} if self.no_defaults else dict(base, type=t)
            for k, v in r.items():
                if k == "type":
                    continue
                if k not in base:
                    return None, "bad_args"
                if k in LIMITS and isinstance(v, (int, float)) and v > LIMITS[k]:
                    return None, "limit"
                item[k] = v
            out.append(item)
        return out, None

    def __call__(self, cmd):
        self.commands.append(cmd)
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {")
        env = json.loads(cmd[len("/partner "):])
        op, args, helper = env["op"], env.get("args", {}), env.get("helper")
        self.ops.append(op)
        self.advance()

        def ok(data):
            return json.dumps({"v": 1, "id": env["id"], "ok": True, "tick": self.tick, "seq": self.seq, "data": data})

        def fail(code, text=""):
            return json.dumps({"v": 1, "id": env["id"], "ok": False, "tick": self.tick, "seq": self.seq,
                               "error": {"code": code, "text": text}})

        h = self.helpers.get(helper)
        if op == "hello":
            return ok({"proto": 1, "mod": self.mod, "tick": self.tick, "seq": self.seq, "owner": "Tartaluga",
                       "players_online": 0, "players": [], "helpers": {}})
        if op == "helper_list":
            return ok({"helpers": [{"id": k, "state": v["state"]} for k, v in sorted(self.helpers.items())]})
        if op == "events":
            evs = [e for e in self.events if e["seq"] > args["since"] and e["helper"] in (None, args.get("helper"))]
            return ok({"seq": self.seq, "events": evs or {}, "lost": False})
        if op == "helper_spawn":
            if h and h["state"] == "alive":
                return fail("helper_exists")
            if h and h["state"] == "removed" and not self.no_cooldown:
                return fail("cooldown")
            self.helpers[helper] = {"state": "alive", "spawned_tick": self.tick}
            return ok({"helper": helper, "unit_number": 7, "surface": "nauvis", "pos": {"x": 2, "y": 0}})
        if not h or h["state"] != "alive":
            return fail("no_helper")
        if op == "helper_remove":
            h["state"] = "removed"
            h["removed_tick"] = self.tick
            self.sets.pop(helper, None)
            return ok({"corpse": {"x": 2, "y": 0}})
        if op == "reflexes":
            rset, code = self.check_set(args.get("set") or [])
            if code:
                return fail(code)
            self.sets[helper] = rset
            return ok({"set": rset or {}})
        if op == "act":
            self.job += 1
            self.emit(helper, "job_done", {"job": self.job, "do": args["do"], "detail": {}})
            return ok({"job": self.job, "queued_before": 0})
        return fail("unknown_op", op)


def run(fake_rcon, scenario, model):
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        return scenario.run(c)


def failed(res):
    return {s["name"]: s.get("error") for s in res["steps"] if not s["ok"]}


# ---------- reflex_set ----------

@pytest.fixture
def fast_set(monkeypatch):
    sc = load("reflex_set")
    monkeypatch.setattr(sc, "WATCH_S", 0.2)
    monkeypatch.setattr(sc, "POLL_S", 0.02)
    monkeypatch.setattr(sc, "JOB_TIMEOUT_S", 1.0)
    return sc


def test_set_ok(fake_rcon, fast_set):
    model = Model()
    res = run(fake_rcon, fast_set, model)
    assert res["ok"] is True, failed(res)
    assert [s["name"] for s in res["steps"]] == [
        "hello", "helper_spawn", "reflexes set", "reflexes replace", "reflexes bad", "reflexes set again",
        "watch", "act wait", "reflexes clear", "helper_remove"]
    watch = next(s for s in res["steps"] if s["name"] == "watch")
    assert watch["info"]["ticks"] >= fast_set.MIN_TICKS
    assert model.helpers["rset"]["state"] == "removed"
    assert model.sets.get("rset") is None
    # только конверты /partner: ни одной консольной команды
    assert all(c.startswith("/partner {") for c in model.commands)
    assert set(model.ops) == {"hello", "helper_spawn", "helper_list", "events", "reflexes", "act", "helper_remove"}
    assert res["log_must_not_match"]


def test_set_with_enemies_noise_is_ok(fake_rcon, fast_set):
    res = run(fake_rcon, fast_set, Model(enemies=True))
    assert res["ok"] is True, failed(res)
    watch = next(s for s in res["steps"] if s["name"] == "watch")
    assert watch["info"]["kinds"].get("saw_enemy", 0) >= 1


@pytest.mark.parametrize("kw, step, text", [
    ({"accept_unknown": True}, "reflexes bad", "bad_args"),
    ({"no_defaults": True}, "reflexes set", "набор в ответе"),
    ({"lose_helper": True}, "watch", ""),
    ({"frozen": True}, "watch", "тиков"),
])
def test_set_failures(fake_rcon, fast_set, kw, step, text):
    model = Model(**kw)
    res = run(fake_rcon, fast_set, model)
    assert res["ok"] is False
    bad = failed(res)
    assert step in bad and text in bad[step], bad
    # уборка: живых помощников не осталось
    assert all(h["state"] != "alive" for h in model.helpers.values())


def test_set_needs_factorio_partner(fake_rcon, fast_set):
    model = Model(mod="partner-test 0.3.0")
    res = run(fake_rcon, fast_set, model)
    assert res["ok"] is False and res["failed"] == ["hello"]
    assert model.ops == ["hello"]


def test_same_treats_empty_and_numbers():
    sc = load("reflex_set")
    assert sc.same({"a": 1, "b": []}, {"a": 1.0, "b": {}})
    assert not sc.same({"a": True}, {"a": 1})
    assert not sc.same([{"type": "flee"}], [{"type": "flee", "radius": 20}])


# ---------- reflex_death ----------

@pytest.fixture
def fast_death(monkeypatch):
    sc = load("reflex_death")
    monkeypatch.setattr(sc, "WATCH_TIMEOUT_S", 3.0)
    monkeypatch.setattr(sc, "POLL_S", 0.01)
    monkeypatch.setattr(sc, "JOB_TIMEOUT_S", 1.0)
    return sc


def test_death_ok(fake_rcon, fast_death):
    model = Model()
    res = run(fake_rcon, fast_death, model)
    assert res["ok"] is True, failed(res)
    assert len(res["steps"]) == 9
    watch = next(s for s in res["steps"] if s["name"] == "watch")
    assert watch["info"]["ticks"] >= fast_death.WATCH_TICKS > fast_death.RESPAWN_TICKS
    assert "запрещены" in res["limitation"]
    assert {h["state"] for h in model.helpers.values()} == {"removed"}
    assert all(c.startswith("/partner {") for c in model.commands)


def test_death_detects_respawn_after_remove(fake_rcon, fast_death):
    model = Model(respawn_after_remove=True)
    res = run(fake_rcon, fast_death, model)
    assert res["ok"] is False
    assert "watch" in failed(res)
    assert all(h["state"] != "alive" for h in model.helpers.values()), "уборка сняла и «возродившегося»"


def test_death_detects_missing_cooldown(fake_rcon, fast_death):
    model = Model(no_cooldown=True)
    res = run(fake_rcon, fast_death, model)
    assert res["ok"] is False
    assert "cooldown" in failed(res)
    assert all(h["state"] != "alive" for h in model.helpers.values())


def test_death_times_out_when_game_is_frozen(fake_rcon, fast_death, monkeypatch):
    monkeypatch.setattr(fast_death, "WATCH_TIMEOUT_S", 0.2)
    res = run(fake_rcon, fast_death, Model(frozen=True))
    assert res["ok"] is False
    assert "тиков" in failed(res)["watch"]


def test_death_needs_factorio_partner(fake_rcon, fast_death):
    res = run(fake_rcon, fast_death, Model(mod="partner-test 0.3.0"))
    assert res["ok"] is False and res["failed"] == ["hello"]
