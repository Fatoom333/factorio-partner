"""Живой сценарий `supply` (поток U, ревизия 3.7): «что из чего и где это взять».
Контракт — STATE.md «supply».

Что спрашивать, сценарий берёт из самого сейва, а не из списка имён: предметы со складов рядом
(`stock`), из карманов помощника (`state`) и из того, что он может сделать руками (`recipes`).
Запасной короткий список базовых предметов игры — только если рядом с хозяином совсем пусто.
Проверяется форма ответа и его внутренняя согласованность, а не «правильность» базы.

 1. hello / helper_spawn — помощник у последней позиции хозяина
 2. discover             — кандидаты из stock, state, recipes; берём первые 3, на которые supply ответил
 3. supply_<n>           — форма дерева: need/have/short, crafts и ингредиенты × crafts, источники,
                           summary, nodes ≤ 60, warnings
 4. depth                — depth=1: ниже корня ничего не раскрыто; depth=5: узлов не больше 60;
                           count×10 — потребность корня выросла
 5. charted              — каждая pos из ответа лежит в открытом чанке (по `map` вокруг неё)
 6. refusals             — неизвестный предмет → not_found; плохие count / depth / лишнее поле;
                           без помощника → no_helper
 7. read_only            — задач не появилось, помощник тот же, module_errors не вырос
 8. helper_remove

Только `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [...], "failed": [имена], "found": {...}}.
"""
from __future__ import annotations

import math
import re

MODS = ["factorio-partner"]

HELPER = "supply1"
MAX_NODES = 60
MAX_NAMES = 3
MAX_ITEMS = 3
MAX_CANDIDATES = 12
MAX_POSITIONS = 8
STOCK_RADIUS = 128
NOTES = ("enough", "depth", "no_recipe", "not_researched", "cycle")
WARNING = re.compile(r"^(other_surface|(not_researched|no_source):[A-Za-z0-9_.\-]+)$")
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] op supply failed"
# если рядом с хозяином пусто (ни складов, ни карманов, ни рецептов) — то, что в игре есть всегда
FALLBACK_ITEMS = ("iron-gear-wheel", "transport-belt", "electronic-circuit", "iron-plate")
UNKNOWN_ITEM = "no-such-item-xyz"


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_int(v):
    return (isinstance(v, int) and not isinstance(v, bool)) or (isinstance(v, float) and v == int(v))


def is_pos(v):
    return isinstance(v, dict) and is_num(v.get("x")) and is_num(v.get("y"))


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def as_map(v):
    return {} if v == [] else v


def short_of(n):
    return str(n)[:120]


def check_group(g, what, with_recipe):
    need(isinstance(g, dict), f"{what}: не объект")
    need(is_int(g.get("count")) and g["count"] >= 1, f"{what}.count: {short_of(g)}")
    need(is_pos(g.get("pos")), f"{what}.pos: {short_of(g)}")
    need(is_num(g.get("dist")) and g["dist"] >= 0, f"{what}.dist: {short_of(g)}")
    names = as_map(g.get("names"))
    need(isinstance(names, dict) and names and len(names) <= MAX_NAMES, f"{what}.names: {short_of(g)}")
    need(all(is_int(n) and n >= 1 for n in names.values()) and sum(names.values()) <= g["count"],
         f"{what}.names: {names!r}")
    if with_recipe:
        need(isinstance(g.get("recipe"), str) and g["recipe"], f"{what}.recipe: {short_of(g)}")
        need(is_int(g.get("out")) and g["out"] >= 0, f"{what}.out: {short_of(g)}")
    else:
        need("recipe" not in g and "out" not in g, f"{what}: recipe и out — только у producers")


def check_node(n, level, depth, nodes, positions):
    need(isinstance(n, dict), f"узел не объект: {short_of(n)}")
    name = n.get("name")
    need(isinstance(name, str) and name, f"node.name: {short_of(n)}")
    need(n.get("kind") in ("item", "fluid"), f"{name}.kind={n.get('kind')!r}")
    for k in ("need", "have", "short"):
        need(is_int(n.get(k)) and n[k] >= 0, f"{name}.{k}={n.get(k)!r}")
    need(n["need"] >= 1, f"{name}.need={n['need']!r}")
    need(n["short"] == max(0, n["need"] - n["have"]),
         f"{name}: short={n['short']}, а need − have = {n['need']} − {n['have']}")
    if n["kind"] == "fluid":
        need(n["have"] == 0, f"{name}: жидкость в карманах")
    note = n.get("note")
    need(note is None or note in NOTES, f"{name}.note={note!r}")
    nodes.append(n)

    if "stored" in n:
        s = n["stored"]
        need(isinstance(s, dict) and is_int(s.get("total")) and is_int(s.get("n")), f"{name}.stored: {short_of(s)}")
        need(0 <= s["n"] <= s["total"], f"{name}.stored: n={s['n']} больше total={s['total']}")
        need(is_pos(s.get("pos")) and is_num(s.get("dist")) and s["dist"] >= 0, f"{name}.stored: {short_of(s)}")
        positions.append((name + ".stored", s["pos"]))
    if "producers" in n:
        check_group(n["producers"], name + ".producers", True)
        positions.append((name + ".producers", n["producers"]["pos"]))
    if "resource" in n:
        r = n["resource"]
        need(isinstance(r, dict) and isinstance(r.get("name"), str) and r["name"], f"{name}.resource: {short_of(r)}")
        need(is_pos(r.get("pos")) and is_num(r.get("dist")) and r["dist"] >= 0, f"{name}.resource: {short_of(r)}")
        need(is_num(r.get("amount")) and r["amount"] >= 0, f"{name}.resource.amount: {short_of(r)}")
        need(is_int(r.get("drills")) and r["drills"] >= 0, f"{name}.resource.drills: {short_of(r)}")
        positions.append((name + ".resource", r["pos"]))

    recipe = n.get("recipe")
    if recipe is None:
        need(note is not None, f"{name}: узел не раскрыт и нет note")
        need((note == "enough") == (n["short"] == 0), f"{name}: note={note!r} при short={n['short']}")
        return
    need(note is None, f"{name}: раскрыт, а note={note!r}")
    need(n["short"] > 0, f"{name}: раскрыт при short=0")
    need(level < depth, f"{name}: раскрыт на уровне {level} при depth={depth}")
    need(isinstance(recipe, dict) and isinstance(recipe.get("name"), str) and recipe["name"],
         f"{name}.recipe.name: {short_of(recipe)}")
    need(isinstance(recipe.get("hand"), bool), f"{name}.recipe.hand: {recipe.get('hand')!r}")
    need(isinstance(recipe.get("category"), str), f"{name}.recipe.category: {recipe.get('category')!r}")
    need(is_int(recipe.get("yield")) and recipe["yield"] >= 1, f"{name}.recipe.yield: {recipe.get('yield')!r}")
    need(is_int(recipe.get("crafts")) and recipe["crafts"] == math.ceil(n["short"] / recipe["yield"]),
         f"{name}: crafts={recipe.get('crafts')!r}, а ceil(short / yield) = ceil({n['short']} / {recipe['yield']})")
    need(is_num(recipe.get("time")) and recipe["time"] >= 0, f"{name}.recipe.time: {recipe.get('time')!r}")
    if "makers" in recipe:
        check_group(recipe["makers"], name + ".recipe.makers", False)
        positions.append((name + ".makers", recipe["makers"]["pos"]))
    ingredients = as_list(recipe.get("ingredients"))
    need(isinstance(ingredients, list), f"{name}.recipe.ingredients: список")
    for child in ingredients:
        check_node(child, level + 1, depth, nodes, positions)
        # количество жидкости в рецепте может быть дробным — кратность проверяется у предметов
        if child["kind"] == "item":
            need(child["need"] >= recipe["crafts"] and child["need"] % recipe["crafts"] == 0,
                 f"{name} → {child['name']}: need={child['need']} не кратно crafts={recipe['crafts']}")
        if recipe["hand"]:
            need(child["kind"] == "item", f"{name}: hand=true, а среди ингредиентов жидкость")


def check_supply(d, item, count=1, depth=3):
    """Форма и согласованность ответа `supply` (STATE.md). → (узлы, позиции)."""
    need(isinstance(d, dict), f"ответ не объект: {str(d)[:80]}")
    need(d.get("item") == item, f"item={d.get('item')!r}, ждали {item!r}")
    need(d.get("count") == count, f"count={d.get('count')!r}, ждали {count}")
    need(isinstance(d.get("surface"), str) and d["surface"], "surface: строка")
    need("truncated" not in d or d["truncated"] is True, "truncated: либо нет, либо true")
    need("hidden" not in d or (is_int(d["hidden"]) and d["hidden"] >= 0), f"hidden={d.get('hidden')!r}")
    nodes, positions = [], []
    check_node(d.get("tree"), 0, depth, nodes, positions)
    root = nodes[0]
    need(root["name"] == item and root["need"] == count, f"корень: {root['name']} × {root['need']}")
    need(is_int(d.get("nodes")) and d["nodes"] == len(nodes), f"nodes={d.get('nodes')!r}, в дереве {len(nodes)}")
    need(len(nodes) <= MAX_NODES, f"узлов {len(nodes)} больше {MAX_NODES}")
    # Обрезанный по числу узлов помечен `depth` (список note в контракте закрытый), но стоит выше
    # предела глубины — по этому его и видно.
    def cut_in(n, level):
        if n.get("note") == "depth" and level < depth:
            return True
        return any(cut_in(ch, level + 1) for ch in as_list((n.get("recipe") or {}).get("ingredients") or []))

    cut = cut_in(d["tree"], 0)
    need(cut == bool(d.get("truncated")), f"truncated={d.get('truncated')!r}, а обрезанных узлов: {cut}")

    summary = d.get("summary")
    need(isinstance(summary, dict), "summary: объект")
    want = {}
    for n in nodes:
        if n["short"] > 0 and n.get("note") != "cycle":   # «круг» уже посчитан выше по ветке
            want[n["name"]] = want.get(n["name"], 0) + n["short"]
    lists = {}
    for part in ("short", "raw"):
        rows = as_list(summary.get(part))
        need(isinstance(rows, list), f"summary.{part}: список")
        got = {}
        for r in rows:
            need(isinstance(r, dict) and isinstance(r.get("name"), str) and is_int(r.get("n")) and r["n"] > 0,
                 f"summary.{part}: {short_of(r)}")
            need(r["name"] not in got, f"summary.{part}: {r['name']} дважды")
            got[r["name"]] = r["n"]
        lists[part] = got
    need(lists["short"] == want, f"summary.short={lists['short']!r}, по дереву {want!r}")
    for name, n in lists["raw"].items():
        need(lists["short"].get(name) == n, f"summary.raw.{name}={n}, а в short {lists['short'].get(name)!r}")

    warnings = as_list(d.get("warnings"))
    need(isinstance(warnings, list), "warnings: список")
    for w in warnings:
        need(isinstance(w, str) and WARNING.match(w), f"warnings: {w!r}")
        if w.startswith("not_researched:"):
            name = w.split(":", 1)[1]
            need(any(n["name"] == name and n.get("note") == "not_researched" for n in nodes),
                 f"{w}: такого узла в дереве нет")
    return nodes, positions


def charted_at(m, pos):
    """По ответу `map` вокруг pos: клетка открыта (не `?`)."""
    rows = as_list(m.get("rows"))
    bbox = m.get("bbox")
    if not rows or not isinstance(bbox, dict):
        return False
    y = int(math.floor(pos["y"])) - int(bbox.get("y0", 0))
    x = int(math.floor(pos["x"])) - int(bbox.get("x0", 0))
    if 0 <= y < len(rows) and 0 <= x < len(rows[y]):
        return rows[y][x] != "?"
    return False  # pos вне карты, которую просили вокруг неё же, — провал, а не «открыто»


def run(client) -> dict:
    c = client
    steps = []
    found = {"items": []}
    st = {"spawned": False, "errors0": 0, "answers": {}, "positions": []}

    def step(name, fn):
        rec = {"name": name, "ok": True}
        try:
            out = fn()
            if isinstance(out, dict) and out:
                rec["info"] = out
        except Exception as e:  # сбой транспорта или проверки — это шаг, а не падение сценария
            rec["ok"] = False
            rec["error"] = f"{type(e).__name__}: {e}"[:300]
        steps.append(rec)
        return rec["ok"]

    def code_of(args, helper=HELPER):
        reply = c.call("supply", args, helper)
        return None if reply.get("ok") else (reply.get("error") or {}).get("code")

    def hello():
        d = c.call_ok("hello")
        need(d.get("proto") == 1, f"proto={d.get('proto')!r}")
        need(is_int(d.get("module_errors")), f"module_errors={d.get('module_errors')!r}")
        st["errors0"] = d["module_errors"]
        return {"mod": d.get("mod"), "owner": d.get("owner")}

    def spawn():
        d = c.call_ok("helper_spawn", {}, HELPER)
        st["spawned"] = True
        return {"surface": d.get("surface"), "pos": d.get("pos")}

    def discover():
        names = []

        def add(more):
            for n in more:
                if isinstance(n, str) and n not in names:
                    names.append(n)

        # что помощник делает руками — у таких предметов дерево точно не пустое
        add(sorted(as_map(c.call_ok("recipes", {}, HELPER).get("craftable"))))
        total = as_map(c.call_ok("stock", {"radius": STOCK_RADIUS}, HELPER).get("total"))
        add(sorted(total, key=lambda k: (-total[k], k)))
        add(sorted(as_map(c.call_ok("state", {}, HELPER).get("inv"))))
        found["from_save"] = len(names)
        add(FALLBACK_ITEMS)
        tried = 0
        for name in names[:MAX_CANDIDATES]:
            tried += 1
            reply = c.call("supply", {"item": name}, HELPER)
            if reply.get("ok"):
                st["answers"][name] = reply.get("data")
                found["items"].append(name)
                if len(found["items"]) >= MAX_ITEMS:
                    break
            else:
                # имя рецепта — не всегда имя предмета: такой кандидат просто не подходит
                code = (reply.get("error") or {}).get("code")
                need(code == "not_found", f"supply {name!r}: {code!r}")
        need(found["items"], "supply не ответил ни на один предмет из сейва и запасного списка")
        return {"items": list(found["items"]), "tried": tried, "from_save": found["from_save"]}

    def supply_step(item):
        def fn():
            d = st["answers"][item]
            nodes, positions = check_supply(d, item)
            st["positions"].extend(positions)
            return {"item": item, "nodes": len(nodes), "short": len(as_list(d["summary"].get("short"))),
                    "raw": [r["name"] for r in as_list(d["summary"].get("raw"))][:6],
                    "expanded": sum(1 for n in nodes if "recipe" in n),
                    "sources": sum(1 for n in nodes if "stored" in n or "producers" in n or "resource" in n),
                    "hidden": d.get("hidden", 0), "truncated": bool(d.get("truncated")),
                    "warnings": as_list(d.get("warnings"))[:6]}
        return fn

    def depth():
        item = found["items"][0]
        one = c.call_ok("supply", {"item": item, "count": 1, "depth": 1}, HELPER)
        nodes, _ = check_supply(one, item, 1, 1)
        deep = c.call_ok("supply", {"item": item, "count": 1, "depth": 5}, HELPER)
        deep_nodes, positions = check_supply(deep, item, 1, 5)
        st["positions"].extend(positions)
        need(len(deep_nodes) >= len(nodes) or deep.get("truncated"), "depth=5 дал меньше узлов, чем depth=1")
        many = c.call_ok("supply", {"item": item, "count": 10, "depth": 1}, HELPER)
        many_nodes, _ = check_supply(many, item, 10, 1)
        need(many_nodes[0]["need"] == 10, "count не дошёл до корня")
        return {"item": item, "nodes_depth1": len(nodes), "nodes_depth5": len(deep_nodes),
                "truncated": bool(deep.get("truncated"))}

    def charted():
        seen, checked = set(), 0
        for what, pos in st["positions"]:
            key = (round(pos["x"]), round(pos["y"]))
            if key in seen:
                continue
            seen.add(key)
            if checked >= MAX_POSITIONS:
                break
            checked += 1
            m = c.call_ok("map", {"center": {"x": pos["x"], "y": pos["y"]}, "radius": 2}, HELPER)
            need(charted_at(m, pos), f"{what}: pos {pos!r} в неоткрытом чанке")
        return {"checked": checked, "positions": len(seen)}

    def refusals():
        item = found["items"][0]
        cases = [
            ({"item": UNKNOWN_ITEM}, "not_found"),
            ({}, "bad_args"),
            ({"item": item, "count": 0}, "bad_args"),
            ({"item": item, "count": 1.5}, "bad_args"),
            ({"item": item, "count": 10001}, "limit"),
            ({"item": item, "depth": 0}, "bad_args"),
            ({"item": item, "depth": 6}, "limit"),
            ({"item": item, "radius": 10}, "bad_args"),
        ]
        for args, want in cases:
            got = code_of(args)
            need(got == want, f"supply {args!r}: ждали {want}, пришло {got!r}")
        got = code_of({"item": item}, None)
        need(got == "no_helper", f"supply без помощника: ждали no_helper, пришло {got!r}")
        return {"checked": len(cases) + 1}

    def read_only():
        lst = as_list(c.call_ok("helper_list")["helpers"])
        alive = [h["id"] for h in lst if h.get("state") == "alive"]
        need(alive == [HELPER], f"живые помощники: {alive}")
        j = c.call_ok("jobs", {}, HELPER)
        need(as_list(j.get("queue")) == [] and j.get("active") is None, "supply поставил задачу")
        d = c.call_ok("hello")
        need(d.get("module_errors") == st["errors0"], f"module_errors вырос до {d.get('module_errors')!r}")

    def remove():
        c.call_ok("helper_remove", {}, HELPER)
        st["spawned"] = False

    try:
        if not step("hello", hello):
            return finish(steps, found, aborted="hello не прошёл")
        if not step("helper_spawn", spawn):
            return finish(steps, found, aborted="helper_spawn не удался")
        if not step("discover", discover):
            step("helper_remove", remove)
            return finish(steps, found, aborted="supply не ответил ни на один предмет")
        for i, item in enumerate(found["items"], 1):
            step(f"supply_{i}", supply_step(item))
        step("depth", depth)
        step("charted", charted)
        step("refusals", refusals)
        step("read_only", read_only)
        step("helper_remove", remove)
        return finish(steps, found)
    finally:
        if st["spawned"]:
            try:
                c.call("helper_remove", {}, HELPER)
            except Exception:  # уборка не прячет основной результат
                pass


def finish(steps, found, aborted=None):
    failed = [s["name"] for s in steps if not s["ok"]]
    out = {"ok": not failed and aborted is None, "steps": steps, "failed": failed, "found": found,
           "log_must_not_match": LOG_MUST_NOT_MATCH}
    if aborted:
        out["aborted"] = aborted
    return out
