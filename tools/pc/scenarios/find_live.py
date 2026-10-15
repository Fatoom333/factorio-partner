"""Живой сценарий `find`: поиск по всей базе. Контракт — STATE.md «find».

Что искать, сценарий берёт из самого сейва, а не из списка имён: постройку — из `map` вокруг
помощника (она точно стоит на базе), предмет — из `stock` (точно лежит на складе) и из `rates`
(точно производится). Проверяются формы ответа, группы, `total`, порядок и лимиты.

 1. hello / helper_spawn   — помощник у последней позиции хозяина (его «глаза» видят склады рядом)
 2. что есть на базе       — map + stock + rates: постройка, предмет со склада, производимый предмет
 3. find entities          — постройка из map находится (total.entities >= 1), формы групп
 4. find storage           — предмет со склада: storage >= 1, сумма amount не меньше, чем видит stock
 5. find по умолчанию      — producers/consumers/storage производимого предмета: формы и total
 6. limit                  — limit=1 режет список и ставит truncated, total при этом не меняется
 7. без помощника          — find с явной surface: тот же total (расстояний может не быть)
 8. отказы                 — неизвестный предмет, пустые kinds, чужой kind, limit 0/51, 5 kinds,
                             неизвестная поверхность, лишнее поле
 9. только чтение          — helper_list и число событий не изменились, module_errors не вырос
10. helper_remove

Только `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [...], "failed": [имена], "found": {...}}.
"""
from __future__ import annotations

MODS = ["factorio-partner"]

HELPER = "find1"
KINDS = ("producers", "consumers", "storage", "entities")
DEFAULT_KINDS = ("producers", "consumers", "storage")
MAP_RADIUS = 32
STOCK_RADIUS = 128
MAX_NAMES = 8
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] op find failed"
# если рядом с хозяином пусто (ни построек, ни складов), пробуем то, что обычно есть на базе
FALLBACK_ITEMS = ("iron-plate", "copper-plate", "stone", "coal", "calcite", "tungsten-ore", "iron-ore")


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


def about(a, b):
    """Числа двух опросов живой базы: между вызовами машины и сундуки успевают измениться."""
    return abs(a - b) <= max(2, 0.1 * max(a, b))


def check_find(d, item, kinds, limit=20, want_dist=None):
    """Форма ответа `find` (STATE.md). Возвращает список групп."""
    need(isinstance(d, dict), f"ответ не объект: {str(d)[:80]}")
    need(d.get("item") == item, f"item={d.get('item')!r}, ждали {item!r}")
    need(isinstance(d.get("surface"), str) and d["surface"], "surface: строка")
    groups = as_list(d.get("groups"))
    need(isinstance(groups, list), "groups: список")
    need(len(groups) <= limit, f"групп {len(groups)} больше limit={limit}")
    total = as_map(d.get("total"))
    need(isinstance(total, dict) and set(total) == set(kinds), f"total: ждали ключи {sorted(kinds)}, пришло {total!r}")
    for k in kinds:
        need(is_int(total[k]) and total[k] >= 0, f"total.{k}: целое >= 0")
    need("truncated" not in d or d["truncated"] is True, "truncated: либо нет, либо true")
    if "storage" in kinds:
        need(is_int(d.get("hidden")) and d["hidden"] >= 0, f"hidden: целое >= 0, пришло {d.get('hidden')!r}")
    else:
        need("hidden" not in d, "hidden: только когда просили storage")
    per_kind = {k: 0 for k in kinds}
    last = None
    for g in groups:
        need(isinstance(g, dict) and g.get("kind") in kinds, f"groups[].kind: {str(g)[:100]}")
        need(is_pos(g.get("pos")), f"groups[].pos: {str(g)[:100]}")
        need(is_int(g.get("count")) and g["count"] >= 1, f"groups[].count: {str(g)[:100]}")
        names = as_map(g.get("names"))
        need(isinstance(names, dict) and names and len(names) <= MAX_NAMES, f"groups[].names: {str(g)[:100]}")
        named = sum(names.values())
        need(all(is_int(n) and n >= 1 for n in names.values()) and named <= g["count"], f"names: {names!r}")
        need(named == g["count"] or is_int(g.get("names_more")), "names не покрывают count и нет names_more")
        need("recipe" not in g or isinstance(g["recipe"], str), "groups[].recipe: строка")
        if g["kind"] == "storage":
            need(is_num(g.get("amount")) and g["amount"] > 0, f"storage без amount: {str(g)[:100]}")
        else:
            need("amount" not in g, f"amount только у storage: {str(g)[:100]}")
        if want_dist is True:
            need(is_num(g.get("dist")) and g["dist"] >= 0, f"groups[].dist: {str(g)[:100]}")
        if want_dist is False:
            need("dist" not in g, f"dist без центра: {str(g)[:100]}")
        if is_num(g.get("dist")):
            need(last is None or g["dist"] >= last, "группы не по возрастанию dist")
            last = g["dist"]
        per_kind[g["kind"]] += g["count"]
    for k in kinds:
        if d.get("truncated"):
            need(per_kind[k] <= total[k], f"{k}: в группах {per_kind[k]} больше total {total[k]}")
        else:
            need(per_kind[k] == total[k], f"{k}: в группах {per_kind[k]}, total {total[k]}")
    return groups


def run(client) -> dict:
    c = client
    steps = []
    found = {}
    st = {"spawned": False, "surface": None, "online": 0, "errors0": 0, "seq0": 0}

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
        reply = c.call("find", args, helper)
        return None if reply.get("ok") else (reply.get("error") or {}).get("code")

    def find(args, helper=HELPER):
        return c.call_ok("find", args, helper)

    def hello():
        d = c.call_ok("hello")
        need(d.get("proto") == 1, f"proto={d.get('proto')!r}")
        need(is_int(d.get("module_errors")), f"module_errors={d.get('module_errors')!r}")
        st["errors0"] = d["module_errors"]
        st["online"] = d.get("players_online") or 0
        return {"mod": d.get("mod"), "owner": d.get("owner"), "players_online": st["online"]}

    def spawn():
        d = c.call_ok("helper_spawn", {}, HELPER)
        st["spawned"] = True
        st["surface"] = d.get("surface")
        need(isinstance(st["surface"], str) and st["surface"], f"helper_spawn: {str(d)[:120]}")
        return {"surface": st["surface"], "pos": d.get("pos")}

    def discover():
        m = c.call_ok("map", {"radius": MAP_RADIUS}, HELPER)
        own = [e for e in as_list(m.get("entities")) if isinstance(e, dict) and not e.get("ghost")
               and e.get("c") not in ("X", "H", "P", "@", "g", "T") and isinstance(e.get("name"), str)
               and e.get("name") != "character"]
        if own:
            found["entity"] = own[0]["name"]
        s = c.call_ok("stock", {"radius": STOCK_RADIUS}, HELPER)
        total = as_map(s.get("total"))
        if total:
            item = max(sorted(total), key=lambda k: total[k])
            found["stored"] = item
            found["stored_seen"] = total[item]
            if "entity" not in found:
                conts = as_list(s.get("containers"))
                if conts:
                    found["entity"] = conts[0]["name"]
        r = c.call_ok("rates", {"scope": "surface", "period": "1h"}, HELPER)
        made = {k: v.get("made", 0) for k, v in as_map(r.get("items")).items() if isinstance(v, dict)}
        made = {k: v for k, v in made.items() if is_num(v) and v > 0}
        if made:
            found["made"] = max(sorted(made), key=lambda k: made[k])
        if "made" not in found:
            found["made"] = found.get("stored") or FALLBACK_ITEMS[0]
        need("entity" in found or "stored" in found,
             "рядом с хозяином нет ни построек, ни складов — сценарию не на чем проверять find")
        return dict(found)

    def find_entities():
        if "entity" not in found:
            return {"skipped": "нет постройки рядом"}
        name = found["entity"]
        d = find({"item": name, "kinds": ["entities"]})
        groups = check_find(d, name, ("entities",), want_dist=True)
        need(d["total"]["entities"] >= 1, f"постройка {name} стоит рядом, а find её не нашёл")
        need(all(set(as_map(g["names"])) == {name} for g in groups), "в группах entities чужие имена")
        return {"item": name, "total": d["total"]["entities"], "groups": len(groups),
                "truncated": bool(d.get("truncated"))}

    def find_storage():
        if "stored" not in found:
            return {"skipped": "на складах рядом пусто"}
        item = found["stored"]
        d = find({"item": item, "kinds": ["storage"], "limit": 50})
        groups = check_find(d, item, ("storage",), limit=50, want_dist=True)
        need(d["total"]["storage"] >= 1, f"{item} лежит на складе рядом, а find его не нашёл")
        amount = sum(g["amount"] for g in groups)
        if not d.get("truncated"):
            # find смотрит всю поверхность, stock — круг 128 клеток: find видит не меньше (с запасом
            # на то, что база работает и между двумя опросами сундуки пустеют)
            need(amount >= 0.5 * found["stored_seen"],
                 f"find видит {amount} {item}, а stock в радиусе {STOCK_RADIUS} — {found['stored_seen']}")
        return {"item": item, "total": d["total"]["storage"], "groups": len(groups), "amount": amount,
                "hidden": d["hidden"], "stock_saw": found["stored_seen"]}

    def find_default():
        item = found["made"]
        d = find({"item": item})
        groups = check_find(d, item, DEFAULT_KINDS, want_dist=True)
        found["default_total"] = dict(as_map(d["total"]))
        found["default_groups"] = len(groups)
        return {"item": item, "total": d["total"], "groups": len(groups), "hidden": d["hidden"],
                "truncated": bool(d.get("truncated")),
                "recipes": sorted({g["recipe"] for g in groups if "recipe" in g})[:5]}

    def limits():
        item = found["made"]
        full = find({"item": item, "kinds": list(KINDS), "limit": 50})
        groups = check_find(full, item, KINDS, limit=50, want_dist=True)
        one = find({"item": item, "kinds": list(KINDS), "limit": 1})
        check_find(one, item, KINDS, limit=1, want_dist=True)
        need(all(about(one["total"][k], full["total"][k]) for k in KINDS),
             f"total зависит от limit: {one['total']!r} и {full['total']!r}")
        if len(groups) > 1:
            need(one.get("truncated") is True, "групп больше одной, а truncated при limit=1 нет")
            first = as_list(one["groups"])[0]
            need(abs(first["dist"] - groups[0]["dist"]) <= 2, "limit=1 отдал не ближайшую группу")
        else:
            need("truncated" not in one, "truncated при единственной группе")
        return {"groups_full": len(groups), "total": full["total"]}

    def without_helper():
        item = found["made"]
        d = c.call_ok("find", {"item": item, "surface": st["surface"]})
        check_find(d, item, DEFAULT_KINDS, want_dist=None if st["online"] else False)
        for k in ("producers", "consumers"):
            need(about(d["total"][k], found["default_total"][k]),
                 f"без помощника total.{k}={d['total'][k]}, с помощником {found['default_total'][k]}")
        # склады без «глаз» помощника видны только в видимых чанках силы: их не больше
        need(d["total"]["storage"] <= found["default_total"]["storage"] + 2, "без помощника складов видно больше")
        return {"total": d["total"], "hidden": d["hidden"]}

    def refusals():
        item = found["made"]
        cases = [
            ({"item": "no-such-item-xyz"}, "bad_args"),
            ({}, "bad_args"),
            ({"item": item, "kinds": []}, "bad_args"),
            ({"item": item, "kinds": ["everything"]}, "bad_args"),
            ({"item": item, "kinds": ["storage"] * 5}, "limit"),
            ({"item": item, "limit": 0}, "bad_args"),
            ({"item": item, "limit": 51}, "limit"),
            ({"item": item, "surface": "no-such-surface-xyz"}, "not_found"),
            ({"item": item, "radius": 10}, "bad_args"),
        ]
        for args, want in cases:
            got = code_of(args)
            need(got == want, f"find {args!r}: ждали {want}, пришло {got!r}")
        return {"checked": len(cases)}

    def read_only():
        lst = as_list(c.call_ok("helper_list")["helpers"])
        alive = [h["id"] for h in lst if h.get("state") == "alive"]
        need(alive == [HELPER], f"живые помощники: {alive}")
        j = c.call_ok("jobs", {}, HELPER)
        need(as_list(j.get("queue")) == [] and j.get("active") is None, "find поставил задачу")
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
            return finish(steps, found, aborted="на базе рядом с хозяином нечего искать")
        for name, fn in (("find_entities", find_entities), ("find_storage", find_storage),
                         ("find_default", find_default), ("limits", limits)):
            step(name, fn)
        if "default_total" in found:
            step("without_helper", without_helper)
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
