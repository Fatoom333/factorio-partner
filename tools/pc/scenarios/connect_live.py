"""Живой сценарий: соединить две точки лентой и опорами (`connect_entities`).

Часть «лента» (kind belt):
1. Помощник; съёмка местности `map` вокруг него; две свободные клетки на земле в 15–25 клетках друг от
   друга, между которыми есть путь по суше.
2. `dry_run`: `done`, `length` не меньше расстояния по клеткам, `path` не пуст, `dry_run` в ответе; `map`
   до и после одинаков — ничего не поставлено (ни лент, ни призраков).
3. Настоящий вызов с `build: true` и `auto_supply`: `done`; от первой клетки до второй стоит непрерывная
   цепочка настоящих лент (не призраков) по направлению движения, новых лент ровно столько, сколько
   сообщено в `ghosts`.
4. В конце свои ленты разбираются по одной (`deconstruct` по `{name, pos}`), `map` — как до прогона.
Часть «опоры» (kind power): если рядом с телом (32 клетки) на сейве есть электрическая опора — помощник
ставит временную постройку-потребитель (манипулятор), соединяет свободную клетку и потребителя опорами
(`from {pos}`, `to {target}`), и по `map` сверяются опоры: они стоят, связаны проводами по дальности
опоры и одна из них накрывает потребителя зоной питания. Затем опоры и потребитель разбираются. Нет
опор на сейве, нет места или манипулятор не достать — `setup_failed` этой части.
Часть, которой на базе нечего взять (нет места, нет лент, нет электричества), пишет `setup_failed`, это не
отказ мода; общий `ok` тогда False с error.kind=setup.
Контракт: docs/ACTIONS.md («connect_entities», «deconstruct», «place»). Только конверты `/partner <JSON>`
через live_client (TESTING.md §3). Сейв — копия стенда.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] op (act|map|state) failed"


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


B = _load("_belt")
P = _load("build_place")
HELPER = B.HELPER
P.HELPER = HELPER          # общие помощники build_place работают с тем же помощником, что и этот сценарий
BELT_NAMES = ("transport-belt", "fast-transport-belt", "express-transport-belt", "underground-belt",
              "fast-underground-belt", "express-underground-belt")
POLES = ("small-electric-pole", "medium-electric-pole", "big-electric-pole", "substation")
# опора -> (радиус зоны питания, дальность провода): прототипы базовой игры
POLE_REACH = {"small-electric-pole": (2.5, 7.5), "medium-electric-pole": (3.5, 9.0),
              "big-electric-pole": (2.0, 30.0), "substation": (9.0, 18.0)}
CONSUMER = "inserter"
LEN_LO, LEN_HI = 15, 25
SNAP_PAD = 12
PAIR_OFFSETS = ((20, 0), (0, 20), (-20, 0), (0, -20), (16, 10), (-16, 10), (16, -10), (-16, -10),
                (10, 16), (-10, 16), (10, -16), (-10, -16), (15, 0), (0, 15), (25, 0), (0, 25))
POWER_OFFSETS = ((8, 0), (0, 8), (-8, 0), (0, -8), (6, 6), (-6, 6), (6, -6), (-6, -6), (10, 0), (0, 10))


# ---------------------------------------------------------------- общее
def _snap(client, area, names):
    """Все постройки и призраки с этими именами в области, как их видит `map`: {(имя, x, y, призрак)}."""
    out = set()
    step = 2 * B.MAP_WINDOW + 1
    x0, y0 = int(area["left_top"]["x"]), int(area["left_top"]["y"])
    x1, y1 = int(area["right_bottom"]["x"]), int(area["right_bottom"]["y"])
    y = y0
    while y <= y1:
        x = x0
        while x <= x1:
            c = {"x": x + B.MAP_WINDOW + 0.5, "y": y + B.MAP_WINDOW + 0.5}
            data = client.call_ok("map", {"center": c, "radius": B.MAP_WINDOW, "names": list(names)}, HELPER)
            for e in data.get("entities", []):
                if e.get("name") in names:
                    out.add((e["name"], e["pos"]["x"], e["pos"]["y"], bool(e.get("ghost"))))
            x += step
        y += step
    return out


def _snap_all(client, areas, names):
    out = set()
    for area in areas:
        out |= _snap(client, area, names)
    return out


def _dist(a, b):
    return ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5


def _remove(client, items, result, key, reasons):
    """Разобрать свои постройки: items — [(имя, x, y) | (имя, x, y, unit_number)] → по `{name, pos}`
    (ленты и опоры) или `{unit_number, pos}`. Сбой не прерывает остальные."""
    log = []
    for name, x, y, *unit in items:
        pos = {"x": x, "y": y}
        target = {"unit_number": unit[0], "pos": pos} if unit and unit[0] else {"name": name, "pos": pos}
        r = B.act(client, "deconstruct", {"target": target})
        log.append({"name": name, "pos": [x, y], "kind": r["kind"], "code": B.code_of(r)})
        if r["kind"] != "job_done":
            reasons.append(f"{key}: {name} в ({x}, {y}) не разобрана: {B.code_of(r)}")
    result[key + "_cleanup"] = log


# ---------------------------------------------------------------- лента
def _find_pair(t, origin):
    """Две клетки земли в LEN_LO..LEN_HI клетках друг от друга (по большей оси) с путём по суше между ними.
    Ближние к телу первыми. → (a, b) | None."""
    cells = sorted((c for c in t.cells if t.land(c)), key=lambda c: abs(c[0] - origin[0]) + abs(c[1] - origin[1]))
    searches = 0
    for a in cells[:600]:
        for dx, dy in PAIR_OFFSETS:
            b = (a[0] + dx, a[1] + dy)
            if not (LEN_LO <= max(abs(dx), abs(dy)) <= LEN_HI) or not t.land(b):
                continue
            searches += 1
            if searches > B.MAX_PATH_SEARCHES:
                return None
            if B.reachable(t, a, b) is not None:
                return a, b
    return None


def part_belt(client, result, reasons, t, origin):
    part = result.setdefault("belt", {})
    pair = _find_pair(t, origin)
    if pair is None:
        part["setup_failed"] = f"в окрестности тела нет двух свободных клеток земли в {LEN_LO}-{LEN_HI} клетках с путём между ними"
        return
    a, b = pair
    span = max(abs(a[0] - b[0]), abs(a[1] - b[1]))
    part["points"] = {"from": list(a), "to": list(b), "span": span}
    args = {"kind": "belt", "from": {"pos": B.center(a)}, "to": {"pos": B.center(b)}, "belt": "transport-belt"}
    areas = [B.area_of([a, b], pad=SNAP_PAD)]
    before = _snap_all(client, areas, BELT_NAMES)
    part["before"] = len(before)
    built = []
    try:
        dry = B.act(client, "connect_entities", dict(args, dry_run=True))
        dd = B.detail_of(dry)
        part["dry"] = {"kind": dry["kind"], "code": B.code_of(dry), "text": B.text_of(dry), "seconds": dry["seconds"],
                       "length": dd.get("length"), "path_total": dd.get("path_total"), "need": dd.get("need"),
                       "warnings": dd.get("warnings")}
        if dry["kind"] != "job_done":
            reasons.append(f"belt: dry_run не done: {B.code_of(dry)} {B.text_of(dry)}")
            return
        if not dd.get("dry_run"):
            reasons.append("belt: в ответе сухого прогона нет dry_run")
        if (dd.get("length") or 0) < span + 1:
            reasons.append(f"belt: length {dd.get('length')} меньше расстояния {span + 1}")
        if not dd.get("path"):
            reasons.append("belt: в ответе сухого прогона нет path")
        after_dry = _snap_all(client, areas, BELT_NAMES)
        if after_dry != before:
            reasons.append(f"belt: dry_run изменил карту: {sorted(after_dry ^ before)[:5]}")
        if isinstance(dd.get("area"), dict) and dd["area"] not in areas:
            # путь вышел за рамку вокруг точек: его область сравнивается с картой после (уже проверенного) сухого прогона
            areas.append(dd["area"])
            before = _snap_all(client, areas, BELT_NAMES)

        need = {k: v for k, v in (dd.get("need") or {}).items() if isinstance(v, int) and v > 0}
        if need:
            # склады стенда далеко от места прокладки: принести заранее с широким радиусом
            part["prefetch"] = B.brief(B.act(client, "get_items", {"items": need, "radius": 128}))
        real = B.act(client, "connect_entities", dict(args, build=True, auto_supply=True))
        rd = B.detail_of(real)
        part["real"] = B.brief(real)
        if real["kind"] != "job_done":
            if B.code_of(real) == "no_items":
                part["setup_failed"] = f"лент нет ни на складах, ни из сырья: {rd.get('supply') or rd.get('missing')}"
            else:
                reasons.append(f"belt: connect_entities не done: {B.code_of(real)} {B.text_of(real)}")
            return
        chosen = rd.get("chosen") or {}
        names = [n for n in (chosen.get("belt"), chosen.get("underground")) if n] or list(BELT_NAMES)
        if isinstance(rd.get("area"), dict) and rd["area"] not in areas:
            areas.append(rd["area"])
        after = _snap_all(client, areas, set(names) | set(BELT_NAMES))
        new = {(n, x, y, g) for n, x, y, g in after if (n, x, y, g) not in before}
        built = [(n, x, y) for n, x, y, _ in new]
        part["built"] = len(built)
        ghosts = [c for c in new if c[3]]
        if ghosts:
            reasons.append(f"belt: после постройки остались призраки: {len(ghosts)}")
        if rd.get("ghosts") is not None and len(new) != rd.get("ghosts"):
            reasons.append(f"belt: на карте новых лент {len(new)}, в ответе ghosts {rd.get('ghosts')}")
        _check_chain(client, rd, new, a, b, part, reasons, chosen)
    finally:
        if built:
            _remove(client, built, result, "belt", reasons)
        after_all = _snap_all(client, areas, BELT_NAMES)
        part["after_cleanup"] = len(after_all)
        if after_all != before:
            reasons.append(f"belt: после разбора карта другая: {sorted(after_all ^ before)[:5]}")


def _check_chain(client, rd, new, a, b, part, reasons, chosen):
    """Цепочка лент от a до b: направление — из `map` (`dir`), подземные пары — как в belt_*."""
    dirs = {}
    names = {e[0] for e in new}
    area = rd.get("area")
    if area and names:
        for e in _entities(client, area, names):
            dirs[(int(e["pos"]["x"] // 1), int(e["pos"]["y"] // 1))] = {"name": e["name"], "dir": e.get("dir")}
    cells = {(int(x // 1), int(y // 1)) for _, x, y, _ in new}
    chain = {c: dirs[c] for c in cells if c in dirs}
    if len(chain) != len(cells):
        reasons.append(f"belt: у {len(cells) - len(chain)} лент нет направления на карте")
        return
    path, pairs, why = B.follow(chain, a, chosen.get("underground"))
    part["chain"] = {"cells": len(chain), "walked": len(path), "undergrounds": len(pairs)}
    if why:
        reasons.append(f"belt: {why}")
    if len(path) != len(chain):
        reasons.append(f"belt: цепочка от начала прошла {len(path)} лент из {len(chain)}: рвётся у {path[-1] if path else a}")
    elif path and path[-1] != b:
        reasons.append(f"belt: лента кончается в {path[-1]}, а не в {b}")


def _entities(client, area, names):
    """Сырые записи `map` по именам в области (с направлением)."""
    out = []
    step = 2 * B.MAP_WINDOW + 1
    x0, y0 = int(area["left_top"]["x"]), int(area["left_top"]["y"])
    x1, y1 = int(area["right_bottom"]["x"]), int(area["right_bottom"]["y"])
    y = y0
    while y <= y1:
        x = x0
        while x <= x1:
            c = {"x": x + B.MAP_WINDOW + 0.5, "y": y + B.MAP_WINDOW + 0.5}
            data = client.call_ok("map", {"center": c, "radius": B.MAP_WINDOW, "names": list(names)}, HELPER)
            out.extend(e for e in data.get("entities", []) if e.get("name") in names)
            x += step
        y += step
    return out


# ---------------------------------------------------------------- опоры
def _find_power_pair(t, origin):
    """Клетка опоры F и клетка потребителя C в 6..10 клетках друг от друга, обе на земле, у тела. → (F, C) | None."""
    cells = sorted((c for c in t.cells if t.land(c)), key=lambda c: abs(c[0] - origin[0]) + abs(c[1] - origin[1]))
    for f in cells[:400]:
        for dx, dy in POWER_OFFSETS:
            c = (f[0] + dx, f[1] + dy)
            if t.land(c) and B.reachable(t, f, c, margin=12) is not None:
                return f, c
    return None


def _get_consumer(client, result):
    """Манипулятор в карманы: склад или `get_items` (крафт с промежуточными). → bool."""
    if P.helper_count(client, CONSUMER) >= 1:
        return True
    r = B.act(client, "get_items", {"items": {CONSUMER: 1}, "radius": 128})
    result["consumer_get"] = B.brief(r)
    return P.helper_count(client, CONSUMER) >= 1


def _wired(poles, kind_reach):
    """Связны ли опоры проводами: у каждой пары в цепочке дальность не больше меньшей из двух. → bool."""
    if not poles:
        return False
    seen, todo = {0}, [0]
    while todo:
        i = todo.pop()
        for j, q in enumerate(poles):
            if j not in seen and _dist(poles[i][1:3], q[1:3]) <= min(kind_reach(poles[i][0]), kind_reach(q[0])):
                seen.add(j)
                todo.append(j)
    return len(seen) == len(poles)


def part_power(client, result, reasons, t, origin):
    part = result.setdefault("power", {})
    near = client.call_ok("map", {"center": B.center(origin), "radius": 32, "names": list(POLES)}, HELPER)
    if not [e for e in near.get("entities", []) if e.get("name") in POLES]:
        part["setup_failed"] = "рядом с телом (32 клетки) на сейве нет электрических опор: электричества нет"
        return
    pair = _find_power_pair(t, origin)
    if pair is None:
        part["setup_failed"] = "рядом с телом нет двух свободных клеток земли в 6-10 клетках друг от друга"
        return
    f, c = pair
    part["points"] = {"pole": list(f), "consumer": list(c)}
    if not _get_consumer(client, result):
        part["setup_failed"] = f"{CONSUMER}: ни на складе, ни из сырья его не достать"
        return
    area = B.area_of([f, c], pad=SNAP_PAD)
    before = _snap(client, area, POLES + (CONSUMER,))
    placed, poles = None, []
    try:
        pos = B.center(c)
        r = B.act(client, "place", {"item": CONSUMER, "pos": pos})
        part["place"] = B.brief(r)
        if r["kind"] != "job_done":
            part["setup_failed"] = f"потребитель не ставится в {pos}: {B.code_of(r)}"
            return
        unit = B.detail_of(r).get("unit_number")
        placed = (CONSUMER, pos["x"], pos["y"], unit)
        part["prefetch"] = B.brief(B.act(client, "get_items", {"items": {"medium-electric-pole": 3}, "radius": 128}))
        real = B.act(client, "connect_entities",
                     {"kind": "power", "from": {"pos": B.center(f)}, "to": {"target": {"unit_number": unit, "pos": pos}},
                      "build": True, "auto_supply": True})
        rd = B.detail_of(real)
        part["real"] = B.brief(real)
        if real["kind"] != "job_done":
            if B.code_of(real) == "no_items":
                part["setup_failed"] = f"опор нет ни на складах, ни из сырья: {rd.get('supply') or rd.get('missing')}"
            else:
                reasons.append(f"power: connect_entities не done: {B.code_of(real)} {B.text_of(real)}")
            return
        chosen = (rd.get("chosen") or {}).get("pole")
        names = {chosen} if chosen else set(POLES)
        after = _snap(client, rd.get("area") or area, names)
        new = [(n, x, y, g) for n, x, y, g in after if (n, x, y, g) not in before]
        poles = [(n, x, y) for n, x, y, _ in new]
        part["poles"] = {"on_map": len(new), "in_reply": rd.get("poles"), "chosen": chosen}
        if any(g for *_, g in new):
            reasons.append("power: после постройки остались призраки опор")
        if not new:
            reasons.append("power: на карте нет новых опор")
        elif rd.get("poles") is not None and len(new) != rd.get("poles"):
            reasons.append(f"power: на карте новых опор {len(new)}, в ответе poles {rd.get('poles')}")
        if new and chosen in POLE_REACH:
            supply, _ = POLE_REACH[chosen]
            _check_power(new, f, pos, supply, part, reasons)
        elif new:
            part["note"] = f"опора {chosen} не из базовой игры: покрытие и провода не проверены"
    finally:
        removal = list(poles) + ([placed] if placed else [])
        if removal:
            _remove(client, removal, result, "power", reasons)
        after_all = _snap(client, area, POLES + (CONSUMER,))
        part["after_cleanup"] = len(after_all)
        if after_all != before:
            reasons.append(f"power: после разбора карта другая: {sorted(after_all ^ before)[:5]}")


def _check_power(new, f, consumer, supply, part, reasons):
    poles = [(n, x, y) for n, x, y, _ in new]
    reach = lambda name: POLE_REACH.get(name, (0, 0))[1]       # noqa: E731
    start = (f[0] + 0.5, f[1] + 0.5)
    if not any(abs(x - start[0]) <= 0.6 and abs(y - start[1]) <= 0.6 for _, x, y in poles):
        reasons.append(f"power: опоры нет в заданной клетке {start}")
    covers = [(n, x, y) for n, x, y in poles if abs(x - consumer["x"]) <= supply + 0.5 and abs(y - consumer["y"]) <= supply + 0.5]
    part["covers"] = len(covers)
    if not covers:
        reasons.append(f"power: ни одна опора не накрывает потребителя ({consumer}) зоной питания")
    if not _wired(poles, reach):
        reasons.append(f"power: опоры не связаны проводами по дальности: {poles}")


# ---------------------------------------------------------------- прогон
def run(client) -> dict:
    result = {"log_must_not_match": LOG_MUST_NOT_MATCH}
    origin = B.prepare(client, result)
    if origin is None:
        return result
    t = B.scan(client, origin, rings=0)
    result["terrain"] = {"maps": t.maps, "cells": len(t.cells), "land": t.count(t.land)}
    reasons = []
    for part in (part_belt, part_power):
        part(client, result, reasons, t, origin)
    setups = {k: v["setup_failed"] for k, v in result.items() if isinstance(v, dict) and v.get("setup_failed")}
    result["ok"] = not reasons and not setups
    if reasons:
        result["reasons"] = reasons
    if setups:
        result["setup_failed"] = setups
        result["error"] = {"kind": "setup", "text": "; ".join(f"{k}: {v}" for k, v in setups.items())}
    return result
