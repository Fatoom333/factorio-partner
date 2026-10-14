"""Сценарий lookup_live против фейкового RCON с маленькой моделью игры (без ПК и без игры).

Модель отвечает по правилам STATE.md «lookup» — проверяется не алгоритм мода (его тесты —
mod/tests/perception_lookup.lua), а то, что сценарий ловит ошибки ответа.
"""
from __future__ import annotations

import copy
import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    return lc.load_scenario("lookup_live", os.path.join(PC_DIR, "scenarios"))


def recipe(name, enabled=True, category="crafting", hand=True, ingredients=None, products=None,
           machines=("maker",), unlocked_by=None):
    r = {"name": name, "enabled": enabled, "category": category, "hand": hand, "time": 0.5,
         "ingredients": ingredients or {}, "products": products or [{"name": name, "type": "item", "amount": 1}],
         "machines": list(machines) or {}, "machines_total": len(machines)}
    if unlocked_by is not None:
        r["unlocked_by"] = unlocked_by
    return r


class Model:
    RECIPES = {
        "plate": recipe("plate", category="smelting", hand=False, machines=("smelter",),
                        ingredients=[{"name": "ore", "type": "item", "amount": 1}]),
        "plate-alt": recipe("plate-alt", enabled=False, category="smelting", hand=False, machines=("smelter",),
                            ingredients=[{"name": "rock", "type": "item", "amount": 2}],
                            products=[{"name": "plate", "type": "item", "amount": 1}]),
        "gear": recipe("gear", ingredients=[{"name": "plate", "type": "item", "amount": 2}]),
        "smelter": recipe("smelter", ingredients=[{"name": "gear", "type": "item", "amount": 5}]),
    }
    UNLOCKS = {"plate-alt": ["t-secret"]}
    TECHS = {"t-a": [], "t-b": ["t-a"], "t-c": ["t-b"], "t-secret": ["t-c"]}
    RESEARCHED = {"t-a"}
    ITEMS = {"plate": {"stack_size": 100, "made_by": ["plate", "plate-alt"], "used_in": ["gear"]},
             "gear": {"stack_size": 100, "made_by": ["gear"], "used_in": ["smelter"]},
             "smelter": {"stack_size": 50, "made_by": ["smelter"], "used_in": [], "place_result": "smelter"}}
    ENTITIES = {"smelter": {"type": "furnace", "size": {"w": 2, "h": 2}, "items_to_place": ["smelter"],
                            "crafting_categories": ["smelting"], "crafting_speed": 2},
                "maker": {"type": "assembling-machine", "size": {"w": 3, "h": 3}, "items_to_place": {},
                          "crafting_categories": ["crafting"], "crafting_speed": 0.5, "energy_usage": 75000}}

    def __init__(self, empty_game=False, missing_wrong_order=False, available_wrong=False, limit_ignored=False,
                 no_suggest=False, accepts_unknown=False, accepts_bad=False, crash=False, unlocked_on_open=False,
                 entity_extra=False, too_many_machines=False, lookup_fails=None):
        self.__dict__.update(locals())
        del self.__dict__["self"]
        self.alive = False
        self.module_errors = 0
        self.ops = []

    def all_names(self):
        return sorted(set(self.ITEMS) | set(self.RECIPES) | set(self.TECHS) | set(self.ENTITIES))

    def recipe_of(self, name, always_unlocks):
        r = copy.deepcopy(self.RECIPES[name])
        if always_unlocks or not r["enabled"] or self.unlocked_on_open:
            r["unlocked_by"] = list(self.UNLOCKS.get(name, [])) or {}
        if self.too_many_machines:
            r["machines"] = ["maker"] + [f"m{i}" for i in range(10)]
            r["machines_total"] = 11
        return r

    def missing_of(self, name):
        out, seen = [], set()

        def visit(t):
            for p in sorted(self.TECHS[t]):
                if p not in seen and p not in self.RESEARCHED:
                    seen.add(p)
                    visit(p)
                    out.append(p)
        visit(name)
        return out

    def lookup(self, args, helper):
        if set(args) - {"name", "kind", "limit"}:
            return "bad_args"
        name, kind, limit = args.get("name"), args.get("kind"), args.get("limit", 20)
        if not isinstance(name, str) or (kind is not None and kind not in ("item", "fluid", "recipe",
                                                                            "technology", "entity")):
            return "bad_args"
        if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
            return "bad_args"
        if limit > 50:
            return "limit"
        if self.limit_ignored:
            limit = 20
        for k in ([kind] if kind else ["item", "fluid", "recipe", "technology", "entity"]):
            if k == "item" and name in self.ITEMS:
                it = self.ITEMS[name]
                made = [self.recipe_of(r, False) for r in it["made_by"]]
                used = [{"recipe": r, "enabled": self.RECIPES[r]["enabled"], "category": self.RECIPES[r]["category"]}
                        for r in it["used_in"]]
                d = {"kind": "item", "name": name, "type": "item", "stack_size": it["stack_size"],
                     "made_by": made[:limit] or {}, "made_by_total": len(made),
                     "used_in": used[:limit] or {}, "used_in_total": len(used), "mined_from": {},
                     "researched_any": any(r["enabled"] for r in made)}
                if "place_result" in it:
                    d["place_result"] = it["place_result"]
                return d
            if k == "recipe" and name in self.RECIPES:
                return dict(self.recipe_of(name, True), kind="recipe")
            if k == "technology" and name in self.TECHS:
                pre = [{"name": p, "researched": p in self.RESEARCHED} for p in sorted(self.TECHS[name])]
                missing = self.missing_of(name)
                if self.missing_wrong_order:
                    missing.reverse()
                available = all(p["researched"] for p in pre) or self.available_wrong
                return {"kind": "technology", "name": name, "researched": name in self.RESEARCHED,
                        "enabled": True, "available": available, "prerequisites": pre or {},
                        "missing": missing or {}, "unlocks": [r for r, ts in self.UNLOCKS.items() if name in ts] or {},
                        "other_effects": {}, "cost": {"count": 50, "ingredients": [{"name": "pack", "amount": 1}],
                                                      "time": 15}}
            if k == "entity" and name in self.ENTITIES:
                d = dict(copy.deepcopy(self.ENTITIES[name]), kind="entity", name=name)
                if self.entity_extra:
                    d["health"] = 300
                return d
        return "not_found"

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
            return ok({"proto": 1, "mod": "0.4.3", "owner": "Owner", "module_errors": self.module_errors,
                       "players_online": 0})
        if op == "helper_spawn":
            self.alive = True
            return ok({"helper": helper, "unit_number": 77, "surface": "nauvis", "pos": {"x": 0, "y": 0}})
        if op == "helper_remove":
            self.alive = False
            return ok({})
        if op == "helper_list":
            return ok({"helpers": [{"id": "lookup1", "state": "alive"}] if self.alive else {}})
        if op == "jobs":
            return ok({"queue": {}})
        if op == "recipes":
            # имя рецепта — не всегда имя предмета: "gear-by-hand" сценарий должен пропустить
            return ok({"craftable": {} if self.empty_game else {"gear-by-hand": 3, "gear": 2}})
        if op == "state":
            return ok({"helper": helper, "inv": {} if self.empty_game else {"plate": 5, "zz-unknown": 1}})
        if op == "lookup":
            if self.lookup_fails:
                return fail(self.lookup_fails, "boom")
            if self.crash:
                self.module_errors += 1
            res = self.lookup(args, helper)
            if isinstance(res, str):
                if res == "not_found":
                    if self.accepts_unknown:
                        return ok({"kind": "item", "name": args.get("name"), "type": "item", "made_by": {},
                                   "made_by_total": 0, "used_in": {}, "used_in_total": 0, "mined_from": {},
                                   "researched_any": False})
                    q = str(args.get("name", "")).lower()
                    sug = sorted((n for n in self.all_names() if q in n.lower()), key=lambda n: (len(n), n))[:5]
                    text = "no thing named " + str(args.get("name"))[:60]
                    if sug and not self.no_suggest:
                        text += "; suggest: " + ", ".join(sug)
                    return fail("not_found", text)
                if res in ("bad_args", "limit") and self.accepts_bad:
                    return ok(self.lookup({"name": "plate"}, helper))
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


def test_lookup_live_ok(fake_rcon):
    res, model = run(fake_rcon)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == [
        "hello", "helper_spawn", "discover", "item", "recipe", "technology", "entity", "limit", "not_found",
        "read_only", "helper_remove"]
    # имена взяты из ответов игры: предмет из карманов, рецепт из recipes (имя рецепта-не-предмета
    # пропущено), технология из unlocked_by рецепта предмета, постройка из machines рецепта
    assert step(res, "discover")["info"] == {"item": "plate", "recipe": "gear", "technology": "t-secret",
                                             "entity": "maker"}
    tech = step(res, "technology")["info"]
    assert tech["missing"] == 2 and tech["first"] == "t-b" and tech["available"] is False
    assert step(res, "limit")["info"] == {"made_by": 1, "used_in": 1}
    assert "plate" in step(res, "not_found")["info"]["suggest"]
    asked = [a for op, _, a in model.ops if op == "lookup"]
    assert {"name": "no-such-thing-xyz"} in asked, "отрицательная проверка not_found"
    fallback = {n for names in load().FALLBACK.values() for n in names}
    assert not any(a.get("name") in fallback for a in asked), "запасной список не понадобился"
    assert not model.alive, "помощник убран"
    assert res["log_must_not_match"]


@pytest.mark.parametrize("kw,failed", [
    ({"missing_wrong_order": True}, {"technology"}),
    ({"available_wrong": True}, {"technology"}),
    ({"limit_ignored": True}, {"limit"}),
    ({"no_suggest": True}, {"not_found"}),
    ({"accepts_unknown": True}, {"not_found"}),
    ({"accepts_bad": True}, {"not_found"}),
    ({"crash": True}, {"read_only"}),
    ({"unlocked_on_open": True}, {"item"}),
    ({"entity_extra": True}, {"entity"}),
    ({"too_many_machines": True}, {"recipe"}),
])
def test_lookup_live_catches_mod_faults(fake_rcon, kw, failed):
    res, model = run(fake_rcon, **kw)
    assert res["ok"] is False
    assert failed & set(res["failed"]), res["failed"]
    assert not model.alive


def test_lookup_live_failure_is_reported(fake_rcon):
    res, model = run(fake_rcon, lookup_fails="internal")
    assert res["ok"] is False and res["failed"] == ["discover"] and "aborted" in res
    assert "internal" in step(res, "discover")["error"]
    assert not model.alive


def test_lookup_live_empty_game_falls_back(fake_rcon):
    # игра ничего не подсказала: сценарий пробует запасной список; модель таких имён не знает → прерывается
    res, model = run(fake_rcon, empty_game=True)
    assert res["ok"] is False and "aborted" in res and res["failed"] == ["discover"]
    asked = [a.get("name") for op, _, a in model.ops if op == "lookup"]
    fb = load().FALLBACK
    assert asked == list(fb["item"]) + list(fb["recipe"]) + list(fb["technology"]) + list(fb["entity"])
    assert not model.alive


def test_check_shapes():
    m = load()
    model = Model()
    item = json.loads(json.dumps(model.lookup({"name": "plate"}, "h")))
    m.check_item(item, "plate")
    tech = json.loads(json.dumps(model.lookup({"name": "t-secret"}, "h")))
    m.check_technology(tech, "t-secret")
    ent = json.loads(json.dumps(model.lookup({"name": "maker", "kind": "entity"}, "h")))
    m.check_entity(ent, "maker")

    def bad(fn, d, *a, edit):
        d = copy.deepcopy(d)
        edit(d)
        with pytest.raises(m.Check):
            fn(d, *a)

    bad(m.check_item, item, "plate", edit=lambda d: d.update(made_by_total=5))
    bad(m.check_item, item, "plate", edit=lambda d: d.update(researched_any=False))
    bad(m.check_item, item, "plate", edit=lambda d: d["made_by"][0].update(hand="yes"))
    bad(m.check_item, item, "plate", edit=lambda d: d["made_by"][0].update(hidden=False))
    bad(m.check_item, item, "plate", edit=lambda d: d["made_by"][1].pop("unlocked_by"))
    bad(m.check_item, item, "plate", edit=lambda d: d["made_by"][0]["products"][0].update(name="other"))
    bad(m.check_item, item, "plate", edit=lambda d: d["made_by"][0]["products"][0].update(probability=1))
    bad(m.check_item, item, "plate", edit=lambda d: d.update(mined_from=[{"resource": "a b"}]))
    bad(m.check_item, item, "plate", edit=lambda d: d.update(kind="fluid"))
    bad(m.check_technology, tech, "t-secret", edit=lambda d: d.update(missing=["t-b", "t-b"]))
    bad(m.check_technology, tech, "t-secret", edit=lambda d: d.update(missing={}))
    bad(m.check_technology, tech, "t-secret", edit=lambda d: d.update(trigger={"type": "craft-item"}))
    bad(m.check_technology, tech, "t-secret", edit=lambda d: d["cost"].update(count=0))
    bad(m.check_technology, tech, "t-secret", edit=lambda d: d.update(missing=["t-secret", "t-c"]))
    bad(m.check_entity, ent, "maker", edit=lambda d: d.update(size={"w": 0, "h": 1}))
    bad(m.check_entity, ent, "maker", edit=lambda d: d.update(crafting_categories={}))
    # жидкость в рецепте «руками» — ошибка
    r = model.recipe_of("gear", True)
    r["ingredients"] = [{"name": "goo", "type": "fluid", "amount": 1}]
    with pytest.raises(m.Check):
        m.check_recipe(r, "recipe", always_unlocks=True)


def test_suggestions_parser():
    m = load()
    assert m.suggestions("no item named x; suggest: a, b-c") == ["a", "b-c"]
    assert m.suggestions("no item named x") == []
    assert m.suggestions(None) == []
