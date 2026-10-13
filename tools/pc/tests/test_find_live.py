"""Сценарий find_live против фейкового RCON с маленькой моделью базы (без ПК и без игры)."""
from __future__ import annotations

import json
import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR

KINDS = ("producers", "consumers", "storage", "entities")
DEFAULT = ("producers", "consumers", "storage")


def load():
    return lc.load_scenario("find_live", os.path.join(PC_DIR, "scenarios"))


class Model:
    """База: печи делают iron-plate, сборщики его тратят, пластины лежат в сундуках.

    Группы уже посчитаны — модель проверяет не алгоритм мода, а то, что сценарий ловит ошибки.
    """

    GROUPS = {
        "iron-plate": [
            {"kind": "storage", "pos": {"x": 6, "y": 5.5}, "count": 2, "amount": 1000,
             "names": {"steel-chest": 1, "passive-provider-chest": 1}},
            {"kind": "producers", "pos": {"x": 12, "y": 0}, "count": 2, "names": {"stone-furnace": 2},
             "recipe": "iron-plate"},
            {"kind": "consumers", "pos": {"x": 60, "y": 60}, "count": 1, "names": {"assembling-machine-2": 1},
             "recipe": "iron-gear-wheel"},
            {"kind": "producers", "pos": {"x": 200, "y": 0}, "count": 1, "names": {"steel-furnace": 1},
             "recipe": "iron-plate"},
        ],
        "stone-furnace": [
            {"kind": "entities", "pos": {"x": 12, "y": 0}, "count": 2, "names": {"stone-furnace": 2}},
        ],
    }

    def __init__(self, empty_base=False, unsorted=False, wrong_total=False, no_limit=False, accepts_bad=False,
                 find_fails=None, crash=False, lost_storage=False, online=False):
        self.empty_base = empty_base
        self.unsorted = unsorted
        self.wrong_total = wrong_total
        self.no_limit = no_limit
        self.accepts_bad = accepts_bad
        self.find_fails = find_fails
        self.crash = crash
        self.lost_storage = lost_storage
        self.online = online
        self.alive = False
        self.module_errors = 0
        self.ops = []

    def find(self, args, helper):
        if set(args) - {"item", "kinds", "surface", "limit"}:
            return "bad_args"
        item = args.get("item")
        known = set(self.GROUPS) | {"coal"}
        if not isinstance(item, str) or item not in known:
            return "bad_args"
        kinds = args.get("kinds", list(DEFAULT))
        if not isinstance(kinds, list) or not kinds:
            return "bad_args"
        if len(kinds) > 4:
            return "limit"
        if any(k not in KINDS for k in kinds):
            return "bad_args"
        limit = args.get("limit", 20)
        if not isinstance(limit, int) or limit < 1:
            return "bad_args"
        if limit > 50:
            return "limit"
        if args.get("surface", "nauvis") != "nauvis":
            return "not_found"
        with_center = helper is not None or self.online
        groups = []
        for g in self.GROUPS.get(item, []):
            if g["kind"] in kinds:
                g = dict(g)
                if g["kind"] == "storage" and self.lost_storage:
                    continue
                if with_center:
                    g["dist"] = round(math.hypot(g["pos"]["x"], g["pos"]["y"]), 1)
                groups.append(g)
        if with_center:
            groups.sort(key=lambda g: g["dist"], reverse=self.unsorted)
        total = {k: sum(g["count"] for g in groups if g["kind"] == k) for k in kinds}
        if self.wrong_total and "producers" in total:
            total["producers"] += 5
        out = {"item": item, "surface": "nauvis", "total": total}
        if not self.no_limit and len(groups) > limit:
            groups = groups[:limit]
            out["truncated"] = True
        out["groups"] = groups if groups else {}
        if "storage" in kinds:
            out["hidden"] = 3
        return out

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
                       "players_online": 1 if self.online else 0})
        if op == "helper_spawn":
            self.alive = True
            return ok({"helper": helper, "unit_number": 77, "surface": "nauvis", "pos": {"x": 0, "y": 0}})
        if op == "helper_remove":
            self.alive = False
            return ok({})
        if op == "helper_list":
            return ok({"helpers": [{"id": "find1", "state": "alive"}] if self.alive else {}})
        if op == "jobs":
            return ok({"queue": {}})
        if op == "map":
            ents = {} if self.empty_base else [
                {"c": "@", "name": "character", "pos": {"x": 0, "y": 0}},
                {"c": "g", "name": "stone-furnace", "pos": {"x": 3, "y": 3}, "ghost": True},
                {"c": "F", "name": "stone-furnace", "pos": {"x": 10, "y": 0}, "dir": 0, "unit": 5},
            ]
            return ok({"rows": ["."], "entities": ents})
        if op == "stock":
            if self.empty_base:
                return ok({"containers": {}, "total": {}, "hidden": 0, "truncated": False})
            return ok({"containers": [{"unit": 9, "name": "steel-chest", "pos": {"x": 5.5, "y": 5.5}, "dist": 7.8,
                                       "items": {"iron-plate": 800}}],
                       "total": {"iron-plate": 1000, "coal": 5}, "hidden": 0, "truncated": False})
        if op == "rates":
            return ok({"scope": "surface", "surface": "nauvis", "period": "1h",
                       "items": {"iron-plate": {"made": 5000, "used": 4000}, "coal": {"made": 0, "used": 90}},
                       "fluids": {}, "truncated": False})
        if op == "find":
            if self.find_fails:
                return fail(self.find_fails, "surface nauvis has more than 4000 chunks")
            if self.crash:
                self.module_errors += 1
            res = self.find(args, helper)
            if isinstance(res, str):
                if self.accepts_bad:
                    return ok({"item": args.get("item"), "surface": "nauvis", "groups": {}, "total": {}})
                return fail(res)
            return ok(res)
        return fail("unknown_op", op)


def run(fake_rcon, **kw):
    model = Model(**kw)
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load().run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)  # только /partner <JSON>
    return res, model


def step(res, name):
    return next(s for s in res["steps"] if s["name"] == name)


def test_find_live_ok(fake_rcon):
    res, model = run(fake_rcon)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == [
        "hello", "helper_spawn", "discover", "find_entities", "find_storage", "find_default", "limits",
        "without_helper", "refusals", "read_only", "helper_remove"]
    # что искать, сценарий взял из самого сейва: постройку из map, предмет из stock и rates
    assert res["found"]["entity"] == "stone-furnace"
    assert res["found"]["stored"] == "iron-plate" and res["found"]["made"] == "iron-plate"
    assert step(res, "find_entities")["info"]["total"] == 2
    assert step(res, "find_storage")["info"]["amount"] == 1000
    assert step(res, "find_default")["info"]["total"] == {"producers": 3, "consumers": 1, "storage": 2}
    assert step(res, "limits")["info"]["groups_full"] == 4
    finds = [(h, a) for op, h, a in model.ops if op == "find"]
    assert any(h is None and a.get("surface") == "nauvis" for h, a in finds), "find без помощника — с явной surface"
    assert any(a.get("limit") == 1 for _, a in finds)
    assert not model.alive, "помощник убран"
    assert res["log_must_not_match"]


def test_find_live_owner_online_keeps_dist_without_helper(fake_rcon):
    res, _ = run(fake_rcon, online=True)
    assert res["ok"] is True, res


@pytest.mark.parametrize("kw,failed", [
    ({"unsorted": True}, {"find_default", "limits", "find_storage"}),
    ({"wrong_total": True}, {"find_default", "limits"}),
    ({"no_limit": True}, {"limits"}),
    ({"accepts_bad": True}, {"refusals"}),
    ({"crash": True}, {"read_only"}),
    ({"lost_storage": True}, {"find_storage"}),
])
def test_find_live_catches_mod_faults(fake_rcon, kw, failed):
    res, model = run(fake_rcon, **kw)
    assert res["ok"] is False
    assert failed & set(res["failed"]), res["failed"]
    assert not model.alive


def test_find_live_surface_too_large_is_reported(fake_rcon):
    res, model = run(fake_rcon, find_fails="limit")
    assert res["ok"] is False and "find_entities" in res["failed"]
    assert "limit" in step(res, "find_entities")["error"]
    assert not model.alive


def test_find_live_empty_base_aborts(fake_rcon):
    res, model = run(fake_rcon, empty_base=True)
    assert res["ok"] is False and "aborted" in res and res["failed"] == ["discover"]
    assert not any(op == "find" for op, _, _ in model.ops)
    assert not model.alive


def test_check_find_shapes():
    m = load()
    good = {"item": "x", "surface": "nauvis", "total": {"storage": 1}, "hidden": 0,
            "groups": [{"kind": "storage", "pos": {"x": 1, "y": 2}, "dist": 3, "count": 1, "amount": 5,
                        "names": {"steel-chest": 1}}]}
    assert len(m.check_find(good, "x", ("storage",))) == 1
    # пустая таблица мода приходит как {} (PROTOCOL §1)
    m.check_find({"item": "x", "surface": "nauvis", "total": {"entities": 0}, "groups": {}}, "x", ("entities",))

    def bad(**change):
        d = json.loads(json.dumps(good))
        for k, v in change.items():
            if v is None:
                d.pop(k, None)
            else:
                d[k] = v
        with pytest.raises(m.Check):
            m.check_find(d, "x", ("storage",))

    bad(item="y")
    bad(total={"storage": 2})
    bad(total={"storage": 1, "producers": 0})
    bad(hidden=None)
    bad(truncated=False)
    bad(groups=[dict(good["groups"][0], amount=None)])
    bad(groups=[dict(good["groups"][0], names={})])
    bad(groups=[dict(good["groups"][0], names={"a": 1, "b": 1})])
    bad(groups=[dict(good["groups"][0], kind="producers")])
    bad(groups=[dict(good["groups"][0], count=0)])
    with pytest.raises(m.Check):
        m.check_find(good, "x", ("storage",), limit=0)
    with pytest.raises(m.Check):
        m.check_find(good, "x", ("storage",), want_dist=False)
