"""Живой сценарий: поставить сундук из инвентаря помощника (act place).

Ход (сервер без окна, хозяин офлайн, PROTOCOL §4 helper_spawn):
1. `hello`, `helper_spawn` помощника HELPER (пустой инвентарь).
2. Сундук берётся честно: `stock` по складам хозяина → `act collect {items:{<сундук>:1}}`
   (не взял — `act extract` из ближайшего сундука по `stock`).
   Сундуков на складах нет — запасной путь: сырьё со склада тем же способом и `act craft`
   (сундук из железа, дерева или стали либо стена из каменного кирпича).
3. `act place {item, pos}` рядом с помощником; `cannot_place` — следующее место из списка.
4. Сверка: job_done с unit_number; у помощника стало на 1 предмет меньше; `map` видит сундук на месте.
Остальные сценарии build_* берут отсюда `prepare()`, `get_item()`, `place_near()` и разведку карты
(`survey`, `lava_cells`, `rocks`) — загрузка по пути, как _hands.
Цель действий — всегда `{unit_number, pos}` (docs/ACTIONS.md «target»).
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import importlib.util
import os


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


H = _load("_hands")
HELPER = "build"
JOB_TIMEOUT_S = 150.0
VISIBLE_WAIT_S = 15.0
CHESTS = ("wooden-chest", "iron-chest", "steel-chest")
# запасной путь: из чего скрафтить сундук руками
# (на складах базы не было ни сундуков, ни пластин железа, ни дерева — только
# сталь и каменный кирпич, поэтому в списке есть и они; стена — такая же постройка 1×1)
CRAFT = (("iron-chest", "iron-plate", 8), ("wooden-chest", "wood", 2),
         ("steel-chest", "steel-plate", 8), ("stone-wall", "stone-brick", 5))
# из чего скрафтить руками прочие постройки сценариев: {предмет: (сырьё, штук на одну)}
RECIPES = {"iron-chest": ("iron-plate", 8), "wooden-chest": ("wood", 2), "steel-chest": ("steel-plate", 8),
           "stone-wall": ("stone-brick", 5), "stone-furnace": ("stone", 5)}
OFFSETS = ((3, 0), (0, 3), (-3, 0), (0, -3), (4, 4), (-4, 4), (4, -4), (-4, -4), (6, 0), (0, 6), (-6, 0), (0, -6))


def act(client, do, args, timeout=JOB_TIMEOUT_S):
    return H.act(client, do, args, timeout, HELPER)


def code_of(r):
    return ((r or {}).get("data") or {}).get("code")


def detail_of(r):
    return ((r or {}).get("data") or {}).get("detail") or {}


def brief(r):
    return {"job": r["job"], "seconds": r["seconds"], "kind": r["kind"], "data": r["data"]}


def helper_state(client):
    return client.call_ok("state", {}, HELPER)


def helper_count(client, item):
    return (helper_state(client).get("inv") or {}).get(item, 0)


def _stock_total(client, items, result):
    """Сколько каждого предмета на видимых складах хозяина: {item: n}, радиус."""
    for radius in (64, 128):
        def look():
            data = client.call_ok("stock", {"radius": radius, "items": list(items), "limit": 50}, HELPER)
            look.last = data
            return data.get("total") or {}
        look.last = {}
        total = client.poll(look, VISIBLE_WAIT_S, 1.0)
        result.setdefault("scan", []).append(
            {"radius": radius, "total": total, "hidden": look.last.get("hidden", 0)})
        if total:
            return total, radius
    return {}, 128


def obtain(client, item, count, radius, result, key):
    """Взять count предметов item со складов хозяина: `collect`, а если он ничего не взял —
    `extract` из ближайшего сундука по `stock` (без игроков онлайн `collect`
    отвечал no_items, хотя `stock` показывал сундук рядом — обзор помощника). → bool."""
    before = helper_count(client, item)
    r = act(client, "collect", {"items": {item: count}, "radius": radius})
    result[key] = brief(r)
    if helper_count(client, item) - before >= count:
        return True
    data = client.call_ok("stock", {"radius": radius, "items": [item], "limit": 50}, HELPER)
    boxes = [c for c in data.get("containers", []) if (c.get("items") or {}).get(item, 0) >= count]
    boxes.sort(key=lambda c: c.get("dist", 1e9))
    for c in boxes[:3]:
        need = count - (helper_count(client, item) - before)
        # цель — {unit_number, pos}: по одному номеру движок 2.0 отдаёт не все сущности (ACTIONS «target»)
        target = {"unit_number": c.get("unit"), "pos": c.get("pos")}
        r = act(client, "extract", {"target": target, "items": {item: need}})
        result[key + "_extract"] = brief(r)
        if helper_count(client, item) - before >= count:
            return True
    return False


def get_item(client, item, count, result, key=None):
    """Довести число предметов item у помощника до count: со складов хозяина, а если их там нет —
    сырьё со складов и ручной крафт (RECIPES). → bool."""
    key = key or ("get_" + item)
    need = count - helper_count(client, item)
    if need <= 0:
        return True
    total, radius = _stock_total(client, [item], result)
    if total.get(item, 0) >= need and obtain(client, item, need, radius, result, key):
        return True
    recipe = RECIPES.get(item)
    if recipe is None:
        return False
    raw, per = recipe
    need = count - helper_count(client, item)
    raw_need = per * need - helper_count(client, raw)
    if raw_need > 0:
        raw_total, radius = _stock_total(client, [raw], result)
        if raw_total.get(raw, 0) < raw_need or not obtain(client, raw, raw_need, radius, result, key + "_raw"):
            return False
    r = act(client, "craft", {"recipe": item, "count": need})
    result[key + "_craft"] = brief(r)
    return helper_count(client, item) >= count


def start(client, result):
    """hello + проверка мода + спавн помощника. → bool (ошибка — в result)."""
    hello = client.call_ok("hello")
    result.update(mod=str(hello.get("mod", "")), players_online=hello.get("players_online"))
    if not H.check_mod(hello, result):
        return False
    if not H.spawn(client, result, HELPER):
        result["ok"] = False
        return False
    return True


def setup_failed(result, text):
    result.update(ok=False, error={"kind": "setup", "text": text})
    return result


# ---------------------------------------------------------------- разведка карты

def scan_map(client, center, radius=32, types=("simple-entity", "tree")):
    return client.call_ok("map", {"center": center, "radius": radius, "types": list(types)}, HELPER)


def lava_cells(data):
    """Центры клеток воды/лавы (`~`) из ответа map. → [{x, y}]."""
    box = data.get("bbox") or {}
    out = []
    for r, row in enumerate(data.get("rows") or []):
        for c, ch in enumerate(row):
            if ch == "~":
                out.append({"x": box["x0"] + c + 0.5, "y": box["y0"] + r + 0.5})
    return out


def rocks(data):
    """Камни (не утёсы) из ответа map с types=[simple-entity]. → [{name, pos, unit?}]."""
    return [e for e in data.get("entities", []) if e.get("c") == "#" and "cliff" not in e.get("name", "")]


def trees(data):
    return [e for e in data.get("entities", []) if e.get("c") == "T"]


def dist(a, b):
    return ((a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2) ** 0.5


def survey(client, result, reach=64):
    """Обойти картой окрестности помощника (9 окон по 65 клеток).
    → {pos, lava: [клетки], rocks, trees} — ближние к помощнику первыми."""
    pos = helper_state(client)["pos"]
    lava, rock, tree, seen = [], [], [], set()
    for dx in (0, -reach, reach):
        for dy in (0, -reach, reach):
            data = scan_map(client, {"x": pos["x"] + dx, "y": pos["y"] + dy})
            for cell in lava_cells(data):
                key = (cell["x"], cell["y"])
                if key not in seen:
                    seen.add(key)
                    lava.append(cell)
            for kind, items in ((rock, rocks(data)), (tree, trees(data))):
                for e in items:
                    key = (e["name"], e["pos"]["x"], e["pos"]["y"])
                    if key not in seen:
                        seen.add(key)
                        kind.append(e)
    lava.sort(key=lambda c: dist(c, pos))
    rock.sort(key=lambda e: dist(e["pos"], pos))
    tree.sort(key=lambda e: dist(e["pos"], pos))
    result["survey"] = {"pos": pos, "lava_cells": len(lava), "rocks": len(rock), "trees": len(tree)}
    return {"pos": pos, "lava": lava, "rocks": rock, "trees": tree}


def get_chests(client, result, count=1):
    """Честно добыть count одинаковых сундуков в инвентарь помощника. → имя предмета | None."""
    total, radius = _stock_total(client, CHESTS, result)
    for item in CHESTS:
        if total.get(item, 0) >= count:
            if obtain(client, item, count, radius, result, "collect"):
                return item
    # запасной путь: сырьё со склада и ручной крафт
    raw_total, radius = _stock_total(client, [c[1] for c in CRAFT], result)
    for item, raw, per in CRAFT:
        need = per * count
        if raw_total.get(raw, 0) < need:
            continue
        if not obtain(client, raw, need, radius, result, "collect_raw"):
            continue
        r = act(client, "craft", {"recipe": item, "count": count})
        result["craft"] = brief(r)
        if r["kind"] == "job_done" and helper_count(client, item) >= count:
            return item
    return None


def prepare(client, result, count=1):
    """hello + спавн + count сундуков в инвентаре. → имя предмета | None (ошибка — в result)."""
    if not start(client, result):
        return None
    item = get_chests(client, result, count)
    if item is None:
        result.update(ok=False, error={"kind": "setup", "text": "на видимых складах хозяина нет ни сундуков, ни сырья для них"})
        return None
    result["item"] = item
    return item


def cell_center(pos, dx=0, dy=0):
    """Центр клетки рядом с pos (постройка 1×1 стоит в центре клетки)."""
    return {"x": int(pos["x"] // 1) + dx + 0.5, "y": int(pos["y"] // 1) + dy + 0.5}


def place_near(client, item, result, key="place"):
    """`act place` на первом свободном месте рядом с помощником. → (pos, итог) | (None, итог)."""
    base = helper_state(client)["pos"]
    tries = []
    last = None
    for dx, dy in OFFSETS:
        pos = cell_center(base, dx, dy)
        last = act(client, "place", {"item": item, "pos": pos})
        tries.append({"pos": pos, "kind": last["kind"], "code": code_of(last)})
        if last["kind"] == "job_done":
            result[key] = dict(brief(last), pos=pos, tries=tries)
            return pos, last
        if code_of(last) != "cannot_place":
            break
    result[key] = dict(brief(last), tries=tries) if last else {"tries": tries}
    return None, last


def entities_at(client, item, pos, radius=2):
    """Постройки item в радиусе 0.6 от pos по `map` (свои постройки — статичное, видно всегда)."""
    data = client.call_ok("map", {"center": pos, "radius": radius, "names": [item]}, HELPER)
    return [e for e in data.get("entities", [])
            if e.get("name") == item and not e.get("ghost")
            and abs(e["pos"]["x"] - pos["x"]) <= 0.6 and abs(e["pos"]["y"] - pos["y"]) <= 0.6]


def run(client) -> dict:
    result = {}
    item = prepare(client, result)
    if item is None:
        return result
    before = helper_count(client, item)
    pos, last = place_near(client, item, result)
    reasons = []
    if pos is None:
        reasons.append(f"place не done: {result.get('place')}")
    else:
        detail = detail_of(last)
        if not isinstance(detail.get("unit_number"), int):
            reasons.append(f"в detail нет unit_number: {detail}")
        after = helper_count(client, item)
        result["inventory"] = {"before": before, "after": after}
        if before - after != 1:
            reasons.append(f"у помощника убыло {before - after}, а не 1")
        found = entities_at(client, item, pos)
        result["on_map"] = len(found)
        if len(found) != 1:
            reasons.append(f"на карте в точке {pos} построек {item}: {len(found)}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
