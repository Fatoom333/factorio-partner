"""Сценарий supply_live против фейкового RCON с маленькой моделью базы (без ПК и без игры).

Модель считает дерево сама по правилам STATE.md «supply» — проверяется не алгоритм мода (его
тесты — mod/tests/perception_supply.lua), а то, что сценарий ловит ошибки ответа.
"""
from __future__ import annotations

import json
import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    return lc.load_scenario("supply_live", os.path.join(PC_DIR, "scenarios"))


class Model:
    # предмет: (рецепт, руками, категория, выход, {ингредиент: количество}) или None — сырьё
    RECIPES = {
        "widget": ("widget", True, "crafting", 1, {"gear": 5, "board": 3}),
        "gear": ("gear", True, "crafting", 1, {"plate": 2}),
        "board": ("board", True, "crafting", 1, {"plate": 1, "wire": 3}),
        "wire": ("wire", True, "crafting", 2, {"bar": 1}),
        "plate": ("plate", False, "smelting", 1, {"ore": 1}),
        "bar": ("bar", False, "smelting", 1, {"rock": 1}),
        "resin": ("resin", False, "crafting", 1, {"goo": 20, "rock": 1}),
        "ore": None, "rock": None, "goo": None,
    }
    FLUIDS = {"goo"}
    POCKETS = {"gear": 4, "plate": 3}
    STORED = {"plate": {"total": 1150, "pos": {"x": 6, "y": 0.5}, "dist": 6, "n": 150}}
    PRODUCERS = {"plate": {"count": 2, "pos": {"x": 12, "y": 0}, "dist": 12, "names": {"smelter": 2},
                           "recipe": "plate", "out": 12}}
    MAKERS = {"smelting": {"count": 3, "pos": {"x": 13, "y": 0}, "dist": 13, "names": {"smelter": 3}}}
    RESOURCE = {"ore": {"name": "ore", "pos": {"x": 42, "y": 1.5}, "dist": 42, "amount": 6000, "drills": 2}}

    def __init__(self, empty_base=False, wrong_short=False, wrong_crafts=False, wrong_need=False,
                 too_many=False, bad_summary=False, accepts_unknown=False, accepts_bad=False, crash=False,
                 uncharted=False, deep_at_one=False, lost_count=False, supply_fails=None, with_helper_only=True):
        self.empty_base = empty_base
        self.wrong_short = wrong_short
        self.wrong_crafts = wrong_crafts
        self.wrong_need = wrong_need
        self.too_many = too_many
        self.bad_summary = bad_summary
        self.accepts_unknown = accepts_unknown
        self.accepts_bad = accepts_bad
        self.crash = crash
        self.uncharted = uncharted
        self.deep_at_one = deep_at_one
        self.lost_count = lost_count
        self.supply_fails = supply_fails
        self.with_helper_only = with_helper_only
        self.alive = False
        self.module_errors = 0
        self.ops = []

    def supply(self, args, helper):
        if set(args) - {"item", "count", "depth"}:
            return "bad_args"
        item = args.get("item")
        if not isinstance(item, str):
            return "bad_args"
        count, depth = args.get("count", 1), args.get("depth", 3)
        for v, top in ((count, 10000), (depth, 5)):
            if not isinstance(v, int) or isinstance(v, bool) or v < 1:
                return "bad_args"
            if v > top:
                return "limit"
        if helper is None and self.with_helper_only:
            return "no_helper"
        if item not in self.RECIPES:
            return "not_found"
        if self.deep_at_one:
            depth = 5
        if self.lost_count:
            count = 1
        pool = dict(self.POCKETS)
        nodes, queue = [], []

        def make(name, need, parent, level):
            kind = "fluid" if name in self.FLUIDS else "item"
            have = pool.get(name, 0) if kind == "item" else 0
            node = {"name": name, "kind": kind, "need": need, "have": have, "short": max(0, need - have)}
            pool[name] = max(0, have - need)
            nodes.append(node)
            queue.append((node, parent, level))
            return node

        tree = make(item, count, None, 0)
        i = 0
        while i < len(queue):
            node, _, level = queue[i]
            i += 1
            name = node["name"]
            rec = self.RECIPES[name]
            for key, src in (("stored", self.STORED), ("producers", self.PRODUCERS), ("resource", self.RESOURCE)):
                if name in src:
                    node[key] = dict(src[name])
            if node["short"] == 0:
                node["note"] = "enough"
            elif rec is None:
                node["note"] = "no_recipe"
            elif level >= depth:
                node["note"] = "depth"
            else:
                rname, hand, category, yld, ingredients = rec
                crafts = math.ceil(node["short"] / yld)
                recipe = {"name": rname, "hand": hand, "category": category, "yield": yld, "crafts": crafts,
                          "time": crafts * 0.5, "ingredients": []}
                if category in self.MAKERS:
                    recipe["makers"] = dict(self.MAKERS[category])
                for ing in sorted(ingredients):
                    recipe["ingredients"].append(make(ing, ingredients[ing] * crafts, node, level + 1))
                node["recipe"] = recipe
        short, raw = {}, {}
        for n in nodes:
            if n["short"] > 0:
                short[n["name"]] = short.get(n["name"], 0) + n["short"]
                if self.RECIPES[n["name"]] is None:
                    raw[n["name"]] = short[n["name"]]
        warnings = [f"no_source:{n}" for n in sorted(raw) if n not in self.RESOURCE and n not in self.STORED]
        out = {"item": item, "count": count, "surface": "nauvis", "tree": tree, "nodes": len(nodes),
               "summary": {"short": [{"name": k, "n": v} for k, v in short.items()] or {},
                           "raw": [{"name": k, "n": v} for k, v in raw.items()] or {}},
               "warnings": warnings or {}, "hidden": 1}
        # ошибки мода, которые сценарий обязан поймать
        expanded = [n for n in nodes if "recipe" in n]
        if self.wrong_short and expanded:
            expanded[0]["short"] += 1
        if self.wrong_crafts and expanded:
            expanded[0]["recipe"]["crafts"] += 1
        if self.wrong_need and expanded:
            expanded[0]["recipe"]["ingredients"][0]["need"] += 1
        if self.too_many:
            out["nodes"] = 61
        if self.bad_summary and out["summary"]["short"]:
            out["summary"]["short"][0]["n"] += 7
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
            return ok({"proto": 1, "mod": "0.4.2", "owner": "Tartaluga", "module_errors": self.module_errors,
                       "players_online": 0})
        if op == "helper_spawn":
            self.alive = True
            return ok({"helper": helper, "unit_number": 77, "surface": "nauvis", "pos": {"x": 0, "y": 0}})
        if op == "helper_remove":
            self.alive = False
            return ok({})
        if op == "helper_list":
            return ok({"helpers": [{"id": "supply1", "state": "alive"}] if self.alive else {}})
        if op == "jobs":
            return ok({"queue": {}})
        if op == "recipes":
            # имя рецепта — не всегда имя предмета: "gear-by-hand" сценарий должен пропустить
            return ok({"craftable": {} if self.empty_base else {"gear-by-hand": 3, "widget": 1}})
        if op == "stock":
            return ok({"containers": {}, "total": {} if self.empty_base else {"plate": 1150, "resin": 2},
                       "hidden": 0, "truncated": False})
        if op == "state":
            return ok({"helper": helper, "inv": {} if self.empty_base else dict(self.POCKETS)})
        if op == "map":
            c = args["center"]
            x0, y0 = math.floor(c["x"]) - 2, math.floor(c["y"]) - 2
            ch = "?" if self.uncharted else "."
            return ok({"bbox": {"x0": x0, "y0": y0, "x1": x0 + 4, "y1": y0 + 4}, "rows": [ch * 5] * 5,
                       "entities": {}})
        if op == "supply":
            if self.supply_fails:
                return fail(self.supply_fails, "more than 20000 entities to look through")
            if self.crash:
                self.module_errors += 1
            res = self.supply(args, helper)
            if isinstance(res, str):
                if res == "not_found" and self.accepts_unknown:
                    return ok({"item": args.get("item"), "count": 1, "surface": "nauvis", "nodes": 1,
                               "tree": {"name": args.get("item"), "kind": "item", "need": 1, "have": 0,
                                        "short": 1, "note": "no_recipe"},
                               "summary": {"short": [{"name": args.get("item"), "n": 1}], "raw": {}},
                               "warnings": {}})
                if res in ("bad_args", "limit") and self.accepts_bad:
                    return ok(self.supply({"item": args.get("item", "widget")}, helper))
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


def test_supply_live_ok(fake_rcon):
    res, model = run(fake_rcon)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == [
        "hello", "helper_spawn", "discover", "supply_1", "supply_2", "supply_3", "depth", "charted",
        "refusals", "read_only", "helper_remove"]
    # что спрашивать, сценарий взял из самого сейва; имя рецепта, не ставшее предметом, пропущено
    assert res["found"]["items"] == ["widget", "plate", "resin"]
    assert step(res, "discover")["info"]["tried"] == 4
    first = step(res, "supply_1")["info"]
    assert first["nodes"] == 8 and first["expanded"] == 5 and first["raw"] == ["ore"]
    assert step(res, "depth")["info"] == {"item": "widget", "nodes_depth1": 3, "nodes_depth5": 9,
                                          "truncated": False}
    assert step(res, "charted")["info"]["checked"] >= 3
    asked = [(h, a) for op, h, a in model.ops if op == "supply"]
    assert any(h is None for h, _ in asked), "отказ без помощника проверен"
    assert any(a.get("item") == "no-such-item-xyz" for _, a in asked), "отрицательная проверка not_found"
    assert not any(a.get("item") in load().FALLBACK_ITEMS for _, a in asked), "запасной список не понадобился"
    assert not model.alive, "помощник убран"
    assert res["log_must_not_match"]


@pytest.mark.parametrize("kw,failed", [
    ({"wrong_short": True}, {"supply_1"}),
    ({"wrong_crafts": True}, {"supply_1"}),
    ({"wrong_need": True}, {"supply_1"}),
    ({"too_many": True}, {"supply_1"}),
    ({"bad_summary": True}, {"supply_1"}),
    ({"accepts_unknown": True}, {"refusals"}),
    ({"accepts_bad": True}, {"refusals"}),
    ({"with_helper_only": False}, {"refusals"}),
    ({"crash": True}, {"read_only"}),
    ({"uncharted": True}, {"charted"}),
    ({"deep_at_one": True}, {"depth"}),
    ({"lost_count": True}, {"depth"}),
])
def test_supply_live_catches_mod_faults(fake_rcon, kw, failed):
    res, model = run(fake_rcon, **kw)
    assert res["ok"] is False
    assert failed & set(res["failed"]), res["failed"]
    assert not model.alive


def test_supply_live_limit_is_reported(fake_rcon):
    res, model = run(fake_rcon, supply_fails="limit")
    assert res["ok"] is False and res["failed"] == ["discover"] and "aborted" in res
    assert "limit" in step(res, "discover")["error"]
    assert not model.alive


def test_supply_live_empty_base_falls_back_and_aborts_when_nothing_answers(fake_rcon):
    # рядом пусто: сценарий пробует запасной список; модель таких предметов не знает → прерывается
    res, model = run(fake_rcon, empty_base=True)
    assert res["ok"] is False and "aborted" in res and res["failed"] == ["discover"]
    asked = [a.get("item") for op, _, a in model.ops if op == "supply"]
    assert asked == list(load().FALLBACK_ITEMS)
    assert not model.alive


def test_check_supply_shapes():
    m = load()
    model = Model()
    good = model.supply({"item": "widget", "count": 2}, "h")
    nodes, positions = m.check_supply(json.loads(json.dumps(good)), "widget", 2)
    assert len(nodes) == 9
    assert {what for what, _ in positions} == {"plate.stored", "plate.producers", "plate.makers", "ore.resource"}
    # пустые таблицы мода приходят как {} (PROTOCOL §1)
    enough = {"item": "x", "count": 1, "surface": "nauvis", "nodes": 1, "summary": {"short": {}, "raw": {}},
              "warnings": {}, "tree": {"name": "x", "kind": "item", "need": 1, "have": 4, "short": 0, "note": "enough"}}
    m.check_supply(enough, "x")

    def bad(edit, **kw):
        d = json.loads(json.dumps(good))
        edit(d)
        with pytest.raises(m.Check):
            m.check_supply(d, "widget", kw.get("count", 2), kw.get("depth", 3))

    def at(d, *path):
        n = d["tree"]
        for i in path:
            n = n["recipe"]["ingredients"][i]
        return n

    bad(lambda d: d.update(item="y"))
    bad(lambda d: d.update(count=3))
    bad(lambda d: d.update(nodes=8))
    bad(lambda d: d.update(truncated=False))
    bad(lambda d: d.update(truncated=True))                       # обрезанных узлов нет
    bad(lambda d: d.update(warnings=["something else"]))
    bad(lambda d: d.update(warnings=["not_researched:widget"]))   # такого узла нет
    bad(lambda d: d["summary"].update(raw=[{"name": "ore", "n": 1}]))
    bad(lambda d: d["summary"]["short"].pop())
    bad(lambda d: at(d).update(kind="thing"))
    bad(lambda d: at(d).update(have=1))                           # short не сходится
    bad(lambda d: at(d).update(note="depth"))                     # раскрыт и с note
    bad(lambda d: at(d, 0).pop("recipe"))                         # не раскрыт и без note
    bad(lambda d: at(d, 0).update(note="strange"))
    bad(lambda d: at(d)["recipe"].update(hand="yes"))
    bad(lambda d: at(d)["recipe"].update(**{"yield": 0}))
    bad(lambda d: at(d, 0, 0)["stored"].update(n=5000))           # n больше total
    bad(lambda d: at(d, 0, 0)["producers"].pop("out"))
    bad(lambda d: at(d, 0, 0)["producers"].update(names={}))
    bad(lambda d: at(d, 0, 0)["recipe"]["makers"].update(out=3))  # out — только у producers
    bad(lambda d: at(d, 0, 0, 0)["resource"].update(drills=-1))
    bad(lambda d: None, depth=1)                                  # раскрыто глубже, чем просили
    # жидкость: в карманах её нет, руками с ней нельзя
    resin = model.supply({"item": "resin"}, "h")
    m.check_supply(json.loads(json.dumps(resin)), "resin")
    resin["tree"]["recipe"]["hand"] = True
    with pytest.raises(m.Check):
        m.check_supply(resin, "resin")


def test_charted_at():
    m = load()
    rows = ["??...", "??...", "??...", "??...", "??..."]
    ans = {"bbox": {"x0": 10, "y0": 20, "x1": 14, "y1": 24}, "rows": rows}
    assert m.charted_at(ans, {"x": 12.5, "y": 22.5}) is True
    assert m.charted_at(ans, {"x": 10.5, "y": 22.5}) is False
    assert m.charted_at({"rows": {}}, {"x": 0, "y": 0}) is False
