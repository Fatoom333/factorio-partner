"""Сценарий core_limit против фейкового RCON с моделью лимита помощников (без ПК и без игры)."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    return lc.load_scenario("core_limit", os.path.join(PC_DIR, "scenarios"))


class Model:
    """Лимит помощников по PROTOCOL §4: max_helpers по умолчанию 1, helper_limit {max:1..16}."""

    def __init__(self, default_max=1, ignore_limit=False, allow_below=False, no_op=False, crash=False,
                 preexisting=False):
        self.max = default_max
        self.ignore_limit = ignore_limit    # старый мод: лимит не действует
        self.allow_below = allow_below      # ошибка мода: даёт опустить ниже числа живых
        self.no_op = no_op                  # мод без операции helper_limit
        self.crash = crash
        self.alive = ["old"] if preexisting else []
        self.removed = []
        self.module_errors = 0
        self.body = {"body": "character"}   # helper_list.body (ревизия 3.3); {} — мод до 3.3
        self.ops = []

    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {")
        env = json.loads(cmd[len("/partner "):])
        op, args, helper = env["op"], env.get("args", {}), env.get("helper")
        self.ops.append((op, helper, args))

        def ok(data):
            return json.dumps({"v": 1, "id": env["id"], "ok": True, "tick": 100, "seq": 0, "data": data})

        def fail(code, text=""):
            return json.dumps({"v": 1, "id": env["id"], "ok": False, "tick": 100, "seq": 0,
                               "error": {"code": code, "text": text}})

        if op == "hello":
            return ok({"proto": 1, "mod": "0.1.0", "owner": "Tartaluga", "module_errors": self.module_errors,
                       "helpers": list(self.alive)})
        if op == "helper_list":
            return ok({"helpers": [dict({"id": h, "state": "alive"}, **self.body) for h in self.alive]
                       + [{"id": h, "state": "removed", "cooldown_s": 300} for h in self.removed]})
        if op == "helper_spawn":
            if helper in self.alive:
                return fail("helper_exists")
            if not self.ignore_limit and len(self.alive) >= self.max:
                return fail("limit", f"at most {self.max} helpers")
            self.alive.append(helper)
            return ok({"helper": helper, "unit_number": 100 + len(self.alive), "surface": "nauvis",
                       "pos": {"x": 1, "y": 2}})
        if op == "helper_remove":
            if helper not in self.alive:
                return fail("no_helper")
            self.alive.remove(helper)
            self.removed.append(helper)
            return ok({})
        if op == "helper_limit":
            if self.no_op:
                return fail("unknown_op", op)
            if set(args) != {"max"}:
                return fail("bad_args", "args")
            m = args["max"]
            if not isinstance(m, int) or isinstance(m, bool) or m < 1:
                return fail("bad_args", "args.max")
            if m > 16:
                return fail("limit", "args.max")
            if m < len(self.alive) and not self.allow_below:
                return fail("limit", "below alive")
            self.max = m
            if self.crash:
                self.module_errors += 1
            return ok({"max": m, "alive": len(self.alive)})
        return fail("unknown_op", op)


def run(fake_rcon, **kw):
    model = Model(**kw)
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load().run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)  # только /partner <JSON>
    return res, model


def test_limit_ok(fake_rcon):
    res, model = run(fake_rcon)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == [
        "hello", "default_one", "limit_2", "second_spawn", "third_limit", "bounds", "not_below_alive", "limit_3",
        "cleanup", "hello_end"]
    assert res["log_must_not_match"]
    # два spawn прошли, третий при max=2 получил limit
    spawns = [(h, ) for op, h, _ in model.ops if op == "helper_spawn"]
    assert [h for (h,) in spawns][:4] == ["lim-a", "lim-b", "lim-b", "lim-c"]
    # после сценария сейв чистый и лимит снова по умолчанию
    assert model.alive == [] and model.max == 1


def test_limit_old_mod_without_limit_fails(fake_rcon):
    res, model = run(fake_rcon, ignore_limit=True)
    assert res["ok"] is False and "default_one" in res["failed"]
    assert model.alive == [], "лишние помощники убраны и при провале"


def test_limit_mod_without_the_op(fake_rcon):
    res, model = run(fake_rcon, no_op=True)
    assert res["ok"] is False
    assert "limit_2" in res["failed"] and "second_spawn" in res["failed"]
    assert model.alive == []


def test_limit_below_alive_must_be_refused(fake_rcon):
    res, model = run(fake_rcon, allow_below=True)
    assert "not_below_alive" in res["failed"]
    assert model.alive == []


def test_limit_module_errors_growth_fails(fake_rcon):
    res, _ = run(fake_rcon, crash=True)
    assert res["failed"] == ["hello_end"]


def test_limit_needs_a_clean_save(fake_rcon):
    res, model = run(fake_rcon, preexisting=True)
    assert res["ok"] is False and res["failed"] == ["hello"] and "aborted" in res
    assert model.alive == ["old"], "чужого помощника сценарий не трогает"
    assert not any(op == "helper_spawn" for op, _, _ in model.ops)


def test_limit_cleans_up_on_exception(fake_rcon, monkeypatch):
    m = load()
    model = Model()
    srv = fake_rcon(handler=model)
    boom = {"n": 0}
    orig = lc.LiveClient.call_ok

    def call_ok(self, op, args=None, helper=None, **kw):
        if op == "helper_list":
            boom["n"] += 1
            if boom["n"] == 3:
                raise KeyboardInterrupt()
        return orig(self, op, args, helper, **kw)

    monkeypatch.setattr(lc.LiveClient, "call_ok", call_ok)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        with pytest.raises(KeyboardInterrupt):
            m.run(c)
    assert model.alive == [] and model.max == 1


def test_limit_needs_body_in_helper_list(fake_rcon):
    """Ревизия 3.3: в helper_list у каждой записи есть body; мод без него сценарий не проходит."""
    m = load()
    model = Model()
    model.body = {}
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = m.run(c)
    assert res["ok"] is False
    bad = {s["name"]: s.get("error", "") for s in res["steps"] if not s["ok"]}
    assert "default_one" in bad and "body" in bad["default_one"], bad
    assert model.alive == [], "помощники убраны и при провале"
