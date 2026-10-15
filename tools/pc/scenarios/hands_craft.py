"""Живой сценарий: скрафтить что-нибудь из выкопанного (ACTIONS.md `mine`, `craft`).

Ход (сервер без окна, хозяин офлайн, PROTOCOL §4 helper_spawn — пустой инвентарь, поэтому всё,
из чего крафтим, — выкопано самим помощником):
1. `hello`, `helper_spawn` помощника HELPER.
2. Источники по очереди, пока `recipes` не покажет что-то крафтабельное:
   руда в `resources` (камень первым, `mine {resource, count: MINE_COUNT}`), затем камни и деревья
   из `map {types:[simple-entity, tree]}` (`mine {target:{name,pos}}`).
3. `act craft {recipe, count: 1}` — рецепт из PREFERRED, иначе первый крафтабельный.
4. Проверка: job_done, detail.crafted, продукт в инвентаре (`state`).
На Вулкане руками крафтится немного (из угля/кальцита — ничего), поэтому камни/деревья — запасной путь.
Нужен модуль пути (подход).
"""
from __future__ import annotations

import importlib.util
import os


def _common():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_hands.py")
    spec = importlib.util.spec_from_file_location("fp_scenario__hands", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


H = _common()
HELPER = H.HELPER
MINE_COUNT = 10
JOB_TIMEOUT_S = 240.0
MAX_SOURCES = 4
HAND_ORES = ["stone", "iron-ore", "copper-ore", "coal", "calcite"]
PREFERRED = ["stone-furnace", "wooden-chest", "iron-gear-wheel", "pipe", "small-electric-pole", "copper-cable"]


def _act(client, do, args):
    r = H.act(client, do, args, JOB_TIMEOUT_S)
    r.pop("kinds", None)
    return r


def sources(client):
    """Список аргументов mine по предпочтению."""
    out = []
    me0 = client.call_ok("state", {}, HELPER)["pos"]
    patches = []
    for dx, dy in [(0, 0)] + [(a, b) for a in (-128, 0, 128) for b in (-128, 0, 128) if a or b]:
        r = client.call("resources", {"radius": 128, "center": {"x": me0["x"] + dx, "y": me0["y"] + dy}}, HELPER)
        ps = (r.get("data") or {}).get("patches") if r.get("ok") else None
        for p in (ps if isinstance(ps, list) else []):
            if p.get("name") in HAND_ORES:
                p["dist"] = ((p["center"]["x"] - me0["x"]) ** 2 + (p["center"]["y"] - me0["y"]) ** 2) ** 0.5
                patches.append(p)
    patches.sort(key=lambda p: (HAND_ORES.index(p["name"]), p.get("dist", 1e9)))
    for p in patches:
        out.append({"resource": p["name"], "near": p["center"], "count": MINE_COUNT})
    r = client.call("map", {"radius": 32, "types": ["simple-entity", "tree"]}, HELPER)
    m = r.get("data") or {} if r.get("ok") else {}
    ents = [e for e in m.get("entities", []) if e.get("name") and e.get("pos") and not e.get("ghost")]
    me = None
    try:
        me = client.call_ok("state", {}, HELPER).get("pos")
    except Exception:
        me = None
    if me:
        ents.sort(key=lambda e: (e["pos"]["x"] - me["x"]) ** 2 + (e["pos"]["y"] - me["y"]) ** 2)
    for e in ents[:3]:
        out.append({"target": {"name": e["name"], "pos": e["pos"]}, "count": 1})
    # камни раньше дальних руд, если камня-руды нет
    if patches and patches[0]["name"] != "stone":
        rocks = [s for s in out if "target" in s]
        ores = [s for s in out if "resource" in s]
        out = ores[:1] + rocks + ores[1:]
    return out


def from_chest(client, result):
    """extract до 10 штук самого многочисленного предмета ближайшего сундука; цель {name,pos}
    (поиск по unit_number на стенде без игроков постройки не находит). → craftable."""
    for radius in (64, 128):
        data = client.call_ok("stock", {"radius": radius, "limit": 50}, HELPER)
        cs = sorted((c for c in data.get("containers", []) if c.get("items") and c.get("pos")),
                    key=lambda c: c.get("dist", 1e9))
        if cs:
            break
    else:
        return {}
    for c in cs[:3]:
        item = max(c["items"], key=lambda k: c["items"][k])
        r = _act(client, "extract", {"target": {"name": c["name"], "pos": c["pos"]},
                                     "items": {item: min(10, c["items"][item])}})
        result.setdefault("from_chest", []).append({"chest": c["name"], "item": item, "kind": r["kind"], "data": r["data"]})
        can = craftable(client)
        if can:
            return can
    return {}


def craftable(client):
    return client.call_ok("recipes", {"filter": ""}, HELPER).get("craftable") or {}


def run(client) -> dict:
    hello = client.call_ok("hello")
    result = {"mod": str(hello.get("mod", "")), "players_online": hello.get("players_online"), "mined": []}
    if not H.check_mod(hello, result):
        return result
    if not H.spawn(client, result):
        result["ok"] = False
        return result
    inv0 = client.call_ok("state", {}, HELPER).get("inv") or {}
    result["inv_start"] = inv0

    can = craftable(client)
    srcs = sources(client)
    result["sources"] = srcs[:MAX_SOURCES]
    for args in srcs[:MAX_SOURCES]:
        if can:
            break
        r = _act(client, "mine", args)
        result["mined"].append(r)
        can = craftable(client)
    if not can:
        # Вулкан: из угля/кальцита руками ничего. Запасной путь — взять ингредиенты из сундука
        # хозяина (extract): помощник честно несёт их себе, ничего не создаётся.
        can = from_chest(client, result)
    result["craftable"] = can
    if not can:
        result.update(ok=False, error={"kind": "setup", "text": "из выкопанного ничего не крафтится"})
        return result

    recipe = next((r for r in PREFERRED if can.get(r, 0) >= 1), None) or sorted(can)[0]
    before = client.call_ok("state", {}, HELPER).get("inv") or {}
    c = _act(client, "craft", {"recipe": recipe, "count": 1})
    after = client.call_ok("state", {}, HELPER).get("inv") or {}
    result["craft"] = c
    result["inv_before_craft"] = before
    result["inv_end"] = after
    reasons = []
    if c["kind"] != "job_done":
        reasons.append(f"craft не done: {c['data']}")
    else:
        crafted = ((c["data"] or {}).get("detail") or {}).get("crafted") or {}
        if not crafted:
            reasons.append("detail.crafted пуст")
        for name, n in crafted.items():
            if after.get(name, 0) - before.get(name, 0) != n:
                reasons.append(f"{name}: в инвентаре +{after.get(name, 0) - before.get(name, 0)}, в detail {n}")
        spent = {k: before[k] - after.get(k, 0) for k in before if before[k] > after.get(k, 0)}
        result["spent"] = spent
        if not spent:
            reasons.append("ингредиенты не потрачены — крафт не честный?")
    if any(v for k, v in inv0.items()):
        reasons.append(f"инвентарь при спавне не пуст: {inv0}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
