"""Живой сценарий `lookup`: справка «как в Факториопедии».
Контракт — STATE.md «lookup».

Что спрашивать, сценарий берёт из ответов самой игры, а не из списка имён: предметы — из карманов
помощника (`state`), рецепты — из того, что он делает руками (`recipes`), технология — из `unlocked_by`
рецепта, постройка — из `place_result` предмета или `machines` рецепта. Короткий запасной список
базовых имён игры — только если игра не подсказала ничего. Проверяется форма ответа и его
согласованность, а не «правильность» дерева технологий.

 1. hello / helper_spawn — помощник у последней позиции хозяина
 2. discover        — по одному имени на вид: item, recipe, technology, entity
 3. item            — made_by/used_in/mined_from, *_total, рецепты целиком (machines ≤ 10, hand)
 4. recipe          — тот же recipe + unlocked_by всегда
 5. technology      — prerequisites, available, missing (≤ 30, без повторов, все неизученные
                      предпосылки в нём), cost или trigger; первая из missing — доступна (порядок)
 6. entity          — size, items_to_place, необязательные поля только своих типов
 7. limit           — limit=1 режет списки, *_total те же
 8. not_found       — kind не тот → not_found, в тексте suggest с самим именем; неизвестное имя;
                      плохие kind / limit / лишнее поле
 9. read_only       — задач не появилось, помощник тот же, module_errors не вырос
10. helper_remove

Только `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [...], "failed": [имена], "found": {...}}.
"""
from __future__ import annotations

import re

MODS = ["factorio-partner"]

HELPER = "lookup1"
MAX_MACHINES = 10
MAX_UNLOCKED_BY = 5
MAX_MISSING = 30
MAX_SUGGEST = 5
DEFAULT_LIMIT = 20
MAX_CANDIDATES = 8
KINDS = ("item", "fluid", "recipe", "technology", "entity")
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,199}$")
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] op lookup failed"
# если игра ничего не подсказала — то, что есть в базовой игре всегда
FALLBACK = {
    "item": ("iron-plate", "iron-gear-wheel", "wood"),
    "recipe": ("iron-gear-wheel", "transport-belt"),
    "technology": ("automation", "logistics"),
    "entity": ("stone-furnace", "assembling-machine-1"),
}
UNKNOWN = "no-such-thing-xyz"


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_int(v):
    return (isinstance(v, int) and not isinstance(v, bool)) or (isinstance(v, float) and v == int(v))


def is_name(v):
    return isinstance(v, str) and bool(NAME.match(v))


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def short_of(v):
    return str(v)[:120]


def names_list(v, what, top=None):
    v = as_list(v)
    need(isinstance(v, list) and all(is_name(n) for n in v), f"{what}: {short_of(v)}")
    need(len(set(v)) == len(v), f"{what}: повторы {short_of(v)}")
    if top is not None:
        need(len(v) <= top, f"{what}: {len(v)} > {top}")
    return v


def check_entries(v, what, with_probability):
    v = as_list(v)
    need(isinstance(v, list), f"{what}: не список")
    for e in v:
        need(isinstance(e, dict) and is_name(e.get("name")), f"{what}: {short_of(e)}")
        need(e.get("type") in ("item", "fluid", "research-progress"), f"{what}.type: {short_of(e)}")
        need(is_num(e.get("amount")) and e["amount"] >= 0, f"{what}.amount: {short_of(e)}")
        if "probability" in e:
            need(with_probability and is_num(e["probability"]) and 0 < e["probability"] < 1,
                 f"{what}.probability: {short_of(e)}")
    return v


def check_recipe(r, what, always_unlocks=False):
    need(isinstance(r, dict) and is_name(r.get("name")), f"{what}: {short_of(r)}")
    name = r["name"]
    need(isinstance(r.get("enabled"), bool), f"{name}.enabled={r.get('enabled')!r}")
    need(isinstance(r.get("category"), str), f"{name}.category={r.get('category')!r}")
    need(isinstance(r.get("hand"), bool), f"{name}.hand={r.get('hand')!r}")
    need(is_num(r.get("time")) and r["time"] >= 0, f"{name}.time={r.get('time')!r}")
    need(r.get("hidden", True) is True, f"{name}.hidden={r.get('hidden')!r} (только true или нет поля)")
    ings = check_entries(r.get("ingredients"), name + ".ingredients", False)
    check_entries(r.get("products"), name + ".products", True)
    if r["hand"]:
        need(not any(e["type"] == "fluid" for e in ings), f"{name}: руками, а среди ингредиентов жидкость")
    machines = names_list(r.get("machines"), name + ".machines", MAX_MACHINES)
    need(is_int(r.get("machines_total")) and r["machines_total"] >= len(machines),
         f"{name}.machines_total={r.get('machines_total')!r}")
    need(len(machines) == min(MAX_MACHINES, r["machines_total"]), f"{name}: machines обрезан не по 10")
    if always_unlocks or not r["enabled"]:
        need("unlocked_by" in r, f"{name}: нет unlocked_by")
    else:
        need("unlocked_by" not in r, f"{name}: unlocked_by у открытого рецепта предмета")
    if "unlocked_by" in r:
        names_list(r["unlocked_by"], name + ".unlocked_by", MAX_UNLOCKED_BY)
    return r


def check_item(d, name, kind="item", limit=DEFAULT_LIMIT):
    need(isinstance(d, dict), "ответ не объект")
    need(d.get("kind") == kind and d.get("name") == name, f"kind/name: {d.get('kind')!r} {d.get('name')!r}")
    need(isinstance(d.get("type"), str), f"type={d.get('type')!r}")
    made = as_list(d.get("made_by"))
    used = as_list(d.get("used_in"))
    mined = as_list(d.get("mined_from"))
    need(isinstance(made, list) and isinstance(used, list) and isinstance(mined, list), "списки — не списки")
    need(len(made) <= limit and len(used) <= limit and len(mined) <= limit, "список длиннее limit")
    for key, lst in (("made_by_total", made), ("used_in_total", used)):
        need(is_int(d.get(key)) and d[key] >= len(lst), f"{key}={d.get(key)!r} при {len(lst)}")
        need(len(lst) == min(limit, d[key]), f"{key}: список обрезан не по limit")
    for r in made:
        check_recipe(r, "made_by")
        need(any(p["name"] == name for p in as_list(r["products"])), f"made_by {r['name']}: среди продуктов нет {name}")
    for u in used:
        need(isinstance(u, dict) and is_name(u.get("recipe")) and isinstance(u.get("enabled"), bool)
             and isinstance(u.get("category"), str), f"used_in: {short_of(u)}")
    for m in mined:
        need(isinstance(m, dict) and is_name(m.get("resource")), f"mined_from: {short_of(m)}")
        if "required_fluid" in m:
            need(is_name(m["required_fluid"]), f"mined_from.required_fluid: {short_of(m)}")
        if "amount" in m:
            need(is_num(m["amount"]) and m["amount"] >= 0, f"mined_from.amount: {short_of(m)}")
    need(isinstance(d.get("researched_any"), bool), f"researched_any={d.get('researched_any')!r}")
    if any(r["enabled"] for r in made) or mined:
        need(d["researched_any"] is True, "открытый рецепт или добыча есть, а researched_any=false")
    if "stack_size" in d:
        need(kind == "item" and is_int(d["stack_size"]) and d["stack_size"] >= 1, f"stack_size={d['stack_size']!r}")
    if "place_result" in d:
        need(kind == "item" and is_name(d["place_result"]), f"place_result={d['place_result']!r}")
    if "fuel_value" in d:
        need(is_num(d["fuel_value"]) and d["fuel_value"] > 0, f"fuel_value={d['fuel_value']!r}")
    return d


def check_technology(d, name):
    need(isinstance(d, dict) and d.get("kind") == "technology" and d.get("name") == name,
         f"kind/name: {short_of(d)}")
    for k in ("researched", "enabled", "available"):
        need(isinstance(d.get(k), bool), f"{k}={d.get(k)!r}")
    pre = as_list(d.get("prerequisites"))
    need(isinstance(pre, list), "prerequisites: не список")
    for p in pre:
        need(isinstance(p, dict) and is_name(p.get("name")) and isinstance(p.get("researched"), bool),
             f"prerequisites: {short_of(p)}")
    open_pre = [p["name"] for p in pre if not p["researched"]]
    need(d["available"] == (not open_pre), f"available={d['available']} при неизученных {open_pre}")
    missing = names_list(d.get("missing"), "missing", MAX_MISSING)
    need(name not in missing, "сама технология в missing")
    if len(missing) < MAX_MISSING:
        need(set(open_pre) <= set(missing), f"неизученные предпосылки {open_pre} не все в missing {missing[:6]}")
    need(bool(missing) == bool(open_pre), f"missing={missing[:6]} при неизученных {open_pre}")
    names_list(d.get("unlocks"), "unlocks")
    other = as_list(d.get("other_effects"))
    need(isinstance(other, list) and all(isinstance(e, dict) and isinstance(e.get("type"), str) for e in other),
         f"other_effects: {short_of(other)}")
    if "cost" in d:
        c = d["cost"]
        need(isinstance(c, dict) and is_int(c.get("count")) and c["count"] >= 1, f"cost: {short_of(c)}")
        need(is_num(c.get("time")) and c["time"] >= 0, f"cost.time: {short_of(c)}")
        for ing in as_list(c.get("ingredients")):
            need(isinstance(ing, dict) and is_name(ing.get("name")) and is_num(ing.get("amount")),
                 f"cost.ingredients: {short_of(ing)}")
    if "trigger" in d:
        need(isinstance(d["trigger"], dict) and isinstance(d["trigger"].get("type"), str), f"trigger: {short_of(d['trigger'])}")
        need("cost" not in d, "и cost, и trigger")
    return d


ENTITY_FIELDS = {"kind", "name", "type", "size", "items_to_place", "crafting_categories", "crafting_speed",
                 "mining_categories", "energy_usage", "mineable_results"}


def check_entity(d, name):
    need(isinstance(d, dict) and d.get("kind") == "entity" and d.get("name") == name, f"kind/name: {short_of(d)}")
    need(set(d) <= ENTITY_FIELDS, f"лишние поля: {sorted(set(d) - ENTITY_FIELDS)}")
    need(isinstance(d.get("type"), str), f"type={d.get('type')!r}")
    s = d.get("size")
    need(isinstance(s, dict) and is_int(s.get("w")) and is_int(s.get("h")) and s["w"] >= 1 and s["h"] >= 1,
         f"size={short_of(s)}")
    names_list(d.get("items_to_place"), "items_to_place")
    if "crafting_categories" in d:
        need(names_list(d["crafting_categories"], "crafting_categories"), "crafting_categories пуст")
    if "crafting_speed" in d:
        need(is_num(d["crafting_speed"]) and d["crafting_speed"] > 0, f"crafting_speed={d['crafting_speed']!r}")
    if "mining_categories" in d:
        need(names_list(d["mining_categories"], "mining_categories"), "mining_categories пуст")
    if "energy_usage" in d:
        need(is_num(d["energy_usage"]) and d["energy_usage"] > 0, f"energy_usage={d['energy_usage']!r}")
    if "mineable_results" in d:
        check_entries(d["mineable_results"], "mineable_results", False)
    return d


def suggestions(text):
    """`…; suggest: a, b` → ['a', 'b'] (ошибка операции в протоколе — только code и text)."""
    if not isinstance(text, str) or "; suggest: " not in text:
        return []
    return [s.strip() for s in text.rsplit("; suggest: ", 1)[1].split(",")]


def run(client) -> dict:
    c = client
    steps = []
    found = {}
    st = {"spawned": False, "errors0": 0, "answers": {}}

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

    def ask(args, helper=HELPER):
        return c.call("lookup", args, helper)

    def error_of(reply):
        if reply.get("ok"):
            return None, None
        e = reply.get("error") or {}
        return e.get("code"), e.get("text")

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

    def first_answer(kind, candidates):
        seen = []
        for n in candidates:
            if is_name(n) and n not in seen:
                seen.append(n)
        for n in seen[:MAX_CANDIDATES]:
            reply = ask({"name": n, "kind": kind})
            if reply.get("ok"):
                found[kind] = n
                st["answers"][kind] = reply.get("data")
                return n
            code, _ = error_of(reply)
            need(code == "not_found", f"lookup {kind} {n!r}: {code!r}")
        return None

    def discover():
        inv = sorted((c.call_ok("state", {}, HELPER).get("inv") or {}))
        craftable = sorted((c.call_ok("recipes", {}, HELPER).get("craftable") or {}))
        from_game = {"item": len(inv), "recipe": len(craftable)}
        first_answer("item", list(inv) + list(craftable) + list(FALLBACK["item"]))
        first_answer("recipe", list(craftable) + list(FALLBACK["recipe"]))
        techs, ents = [], []
        rec = st["answers"].get("recipe") or {}
        techs += as_list(rec.get("unlocked_by") or [])
        ents += as_list(rec.get("machines") or [])
        item = st["answers"].get("item") or {}
        for r in as_list(item.get("made_by") or []):
            techs += as_list(r.get("unlocked_by") or [])
        if item.get("place_result"):
            ents.insert(0, item["place_result"])
        from_game["technology"] = len(techs)
        from_game["entity"] = len(ents)
        first_answer("technology", techs + list(FALLBACK["technology"]))
        first_answer("entity", ents + list(FALLBACK["entity"]))
        found["from_game"] = from_game
        missing = [k for k in ("item", "recipe", "technology", "entity") if k not in found]
        need(not missing, f"lookup не ответил ни на одно имя вида {missing}")
        return {k: found[k] for k in ("item", "recipe", "technology", "entity")}

    def item():
        d = check_item(st["answers"]["item"], found["item"])
        # без kind — то же самое (предмет ищется первым)
        same = c.call_ok("lookup", {"name": found["item"]}, HELPER)
        need(same.get("kind") == "item", f"без kind: kind={same.get('kind')!r}")
        return {"made_by": d["made_by_total"], "used_in": d["used_in_total"],
                "mined_from": len(as_list(d["mined_from"])), "researched_any": d["researched_any"]}

    def recipe():
        r = check_recipe(st["answers"]["recipe"], "recipe", always_unlocks=True)
        need(r.get("kind") == "recipe", f"kind={r.get('kind')!r}")
        return {"enabled": r["enabled"], "hand": r["hand"], "machines": r["machines_total"],
                "unlocked_by": as_list(r["unlocked_by"])}

    def technology():
        name = found["technology"]
        d = check_technology(st["answers"]["technology"], name)
        info = {"researched": d["researched"], "available": d["available"],
                "missing": len(as_list(d["missing"])), "cost": "cost" in d, "trigger": "trigger" in d}
        missing = as_list(d["missing"])
        if missing:
            # порядок изучения: у первой из missing все предпосылки уже изучены
            first = check_technology(c.call_ok("lookup", {"name": missing[0], "kind": "technology"}, HELPER),
                                     missing[0])
            need(first["available"] is True, f"первая из missing ({missing[0]}) ещё недоступна")
            info["first"] = missing[0]
        return info

    def entity():
        d = check_entity(st["answers"]["entity"], found["entity"])
        return {"type": d["type"], "size": d["size"], "fields": sorted(set(d) - {"kind", "name", "type", "size"})}

    def limit():
        full = st["answers"]["item"]
        one = check_item(c.call_ok("lookup", {"name": found["item"], "kind": "item", "limit": 1}, HELPER),
                         found["item"], limit=1)
        need(one["made_by_total"] == full["made_by_total"] and one["used_in_total"] == full["used_in_total"],
             "limit поменял *_total")
        return {"made_by": len(as_list(one["made_by"])), "used_in": len(as_list(one["used_in"]))}

    def not_found():
        name = found["item"]
        info = {}
        # тот же предмет как технология: не найдено, а в подсказках — он сам
        reply = ask({"name": name, "kind": "technology"})
        code, text = error_of(reply)
        if code is None:
            info["also_technology"] = True  # бывает: имя совпало у двух видов — проверяем на постройке
            reply = ask({"name": found["technology"], "kind": "fluid"})
            code, text = error_of(reply)
            name = found["technology"]
        need(code == "not_found", f"kind не тот: ждали not_found, пришло {code!r}")
        sug = suggestions(text)
        need(0 < len(sug) <= MAX_SUGGEST, f"suggest: {text!r}")
        need(name in sug, f"{name} нет в подсказках {sug}")
        need(all(is_name(s) for s in sug), f"suggest: {sug}")
        info["suggest"] = sug
        code, _ = error_of(ask({"name": UNKNOWN}))
        need(code == "not_found", f"{UNKNOWN}: {code!r}")
        cases = [
            ({}, "bad_args"),
            ({"name": name, "kind": "thing"}, "bad_args"),
            ({"name": name, "limit": 0}, "bad_args"),
            ({"name": name, "limit": 51}, "limit"),
            ({"name": name, "radius": 10}, "bad_args"),
        ]
        for args, want in cases:
            got, _ = error_of(ask(args))
            need(got == want, f"lookup {args!r}: ждали {want}, пришло {got!r}")
        info["checked"] = len(cases) + 2
        return info

    def read_only():
        lst = as_list(c.call_ok("helper_list")["helpers"])
        alive = [h["id"] for h in lst if h.get("state") == "alive"]
        need(alive == [HELPER], f"живые помощники: {alive}")
        j = c.call_ok("jobs", {}, HELPER)
        need(as_list(j.get("queue")) == [] and j.get("active") is None, "lookup поставил задачу")
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
            return finish(steps, found, aborted="lookup не ответил на имена одного из видов")
        step("item", item)
        step("recipe", recipe)
        step("technology", technology)
        step("entity", entity)
        step("limit", limit)
        step("not_found", not_found)
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
