"""Живой сценарий потока R «Перекладка ленты» (ревизия 3.5): `plan_belt {from: "resume"}`.

«Планируем по карте, на месте перепроверяем»: лента размечена, построена не до конца, впереди
появилась помеха — помощник перекладывает остаток, а не бросает задачу.

Ход:
1. `hello`, помощник (`helper_spawn`), свободная полоса земли рядом (`map`).
2. Лента и сундук берутся честно со складов базы (`collect`, при нужде `craft`): лент — меньше, чем
   клеток в будущей ленте, чтобы стройка остановилась посередине.
3. `plan_belt {from, to, belt, underground: "never"}` — прямая на 30–60 клеток.
4. `build_ghosts {area, mode: "hand"}` — строит, пока хватает лент (итог `no_items` — ожидаем).
5. Помощник ЧЕСТНО ставит помеху: сундук из своего инвентаря (`place`) на клетку недостроенной части.
6. `plan_belt {from: "resume"}` — без `to`.
7. Сверка с игрой (`map`), а не с ответом действия:
   - построенная часть цела: те же клетки, те же направления;
   - `resumed.built` = длине построенной части от начала ленты, `resumed.removed` = числу призраков
     ленты, стоявших до перекладки;
   - старых призраков вне нового пути нет: каждый призрак ленты на карте лежит на цепочке от начала;
   - цепочка (построенное + призраки) непрерывна от начала до цели и не идёт через клетку помехи;
   - сундук стоит, призрака под ним нет; призраков на карте столько, сколько в ответе.
Только конверты `/partner <JSON>` (TESTING.md §3). Сейв — копия стенда.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]

WINDOWS = ((44, 7), (36, 7), (32, 5))   # полоса: длина ленты + по клетке с краёв; ширина — место для обхода
CHESTS = ("wooden-chest", "iron-chest", "steel-chest")
BUILT_SHARE = 3                          # лент берём на треть ленты
OBSTACLE_AHEAD = 4                       # помеха — на столько клеток дальше конца построенной части
BUILD_TIMEOUT_S = 300.0
PLACE_TIMEOUT_S = 120.0


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


E = _load("_e2e")


def row_of(area):
    """Средняя строка окна: клетки слева направо, без крайних. → [клетки]."""
    x0, x1 = int(area["left_top"]["x"]), int(area["right_bottom"]["x"])
    y0, y1 = int(area["left_top"]["y"]), int(area["right_bottom"]["y"])
    y = (y0 + y1 - 1) // 2
    return [(x, y) for x in range(x0 + 1, x1 - 1)]


def pad(area, n):
    return {"left_top": {"x": area["left_top"]["x"] - n, "y": area["left_top"]["y"] - n},
            "right_bottom": {"x": area["right_bottom"]["x"] + n, "y": area["right_bottom"]["y"] + n}}


def walk_chain(belts, start, end, limit=4000):
    """Пройти по лентам от start: каждая передаёт в клетку, на которую смотрит.
    → (пройденные клетки, дошёл ли до end)."""
    path, seen, cur = [], set(), start
    while cur in belts and cur not in seen and len(path) < limit:
        seen.add(cur)
        path.append(cur)
        if cur == end:
            return path, True
        v = E.VEC.get(belts[cur].get("dir"))
        if v is None:
            break
        cur = (cur[0] + v[0], cur[1] + v[1])
    return path, False


def warning(detail, prefix):
    for w in E.as_list(detail.get("warnings")):
        if isinstance(w, str) and w.startswith(prefix):
            return w
    return None


def run(client) -> dict:
    result = {}
    api = E.api_for(client)
    if not E.start(api, result):
        return result
    log = result.setdefault("steps", [])

    # 1. место
    row = None
    for w, h in WINDOWS:
        wins = E.ground_windows(api, w, h, log, limit=1)
        if wins:
            row = row_of(wins[0])
            result["window"] = wins[0]
            break
    if row is None:
        return E.fail_setup(result, "рядом с помощником нет свободной полосы земли 32×5 (map)")
    start, goal = row[0], row[-1]
    result["points"] = {"from": list(start), "to": list(goal), "cells": len(row)}

    # 2. предметы: лент меньше, чем клеток
    belt = E.pick_available(api, E.BELTS, log, "belt")
    chest = E.pick_available(api, CHESTS, log, "chest")
    if belt is None or chest is None:
        return E.fail_setup(result, f"на складах базы нет ленты или сундука: belt={belt}, chest={chest}")
    have = len(row) // BUILT_SHARE
    left, notes = E.obtain(api, {belt: have, chest: 1}, log)
    if left:
        return E.fail_setup(result, f"не удалось честно взять предметы: {left}", notes=notes)
    inv = E.inventory(api)
    if inv.get(belt, 0) > len(row) - 2 * OBSTACLE_AHEAD:
        return E.fail_setup(result, f"у помощника слишком много лент ({inv.get(belt)}): стройка не остановится посередине")
    result["items"] = {"belt": belt, "chest": chest, "belts": inv.get(belt, 0)}

    reasons = []

    # 3. разметка
    plan = api.act("plan_belt", {"from": E.cell_center(start), "to": E.cell_center(goal), "belt": belt,
                                 "underground": "never"})
    result["plan"] = E.brief(plan)
    pd = E.detail_of(plan)
    if plan["kind"] != "job_done" or not pd.get("area"):
        reasons.append(f"plan_belt не done: {E.code_of(plan)} {E.text_of(plan)}")
        return E.finish(result, reasons)
    if pd.get("ghosts") != len(row):
        reasons.append(f"прямая на {len(row)} клеток, а призраков {pd.get('ghosts')}")
    watch = [pad(pd["area"], 6)]

    # 4. стройка, пока хватает лент
    api.act("walk", {"to": E.cell_center(start), "radius": 3}, E.WALK_TIMEOUT_S)
    build = api.act("build_ghosts", {"area": pd["area"], "mode": "hand"}, BUILD_TIMEOUT_S)
    result["build"] = E.brief(build)
    if build["kind"] is None:
        reasons.append("build_ghosts не закончился за отведённое время")
    belts, truncated = E.belt_cells(api, watch, [belt])
    if truncated:
        reasons.append("карта обрезала список лент — сверка неполная")
    # у базы на карте есть чужие ленты того же вида: построенным считаем только клетки плана
    row_set = set(row)
    built = {c: b for c, b in belts.items() if not b["ghost"] and c in row_set}
    prefix = 0
    while prefix < len(row) and row[prefix] in built:
        prefix += 1
    apart = sorted(c for c in built if c not in row[:prefix])
    old_ghosts = {c for c, b in belts.items() if b["ghost"]}
    result["before"] = {"built": len(built), "prefix": prefix, "apart": len(apart), "ghosts": len(old_ghosts)}
    if not built:
        reasons.append("build_ghosts не построил ни одной ленты")
    if len(old_ghosts) < 2 * OBSTACLE_AHEAD:
        reasons.append(f"недостроенных призраков всего {len(old_ghosts)}: перекладывать нечего")
    if reasons:
        return E.finish(result, reasons)

    # 5. помеха — сундук из своего инвентаря на клетку недостроенной части
    at = min(prefix + OBSTACLE_AHEAD, len(row) - 3)
    while at < len(row) - 2 and row[at] not in old_ghosts:
        at += 1
    obstacle = row[at]
    if obstacle not in old_ghosts:
        return E.fail_setup(result, "на недостроенной части нет клетки с призраком под помеху", before=result["before"])
    put = api.act("place", {"item": chest, "pos": E.cell_center(obstacle)}, PLACE_TIMEOUT_S)
    result["obstacle"] = {"cell": list(obstacle), "place": E.brief(put)}
    if put["kind"] != "job_done":
        return E.fail_setup(result, f"помеху поставить не удалось: {E.code_of(put)} {E.text_of(put)}",
                            before=result["before"])
    # призрак под сундуком игра могла убрать сама: считаем призраки заново, уже с помехой
    belts, _ = E.belt_cells(api, watch, [belt])
    old_ghosts = {c for c, b in belts.items() if b["ghost"]}
    result["obstacle"].update(ghost_under=obstacle in old_ghosts, ghosts=len(old_ghosts))

    # 6. перекладка
    relay = api.act("plan_belt", {"from": "resume"})
    result["resume"] = E.brief(relay)
    rd = E.detail_of(relay)
    if relay["kind"] != "job_done":
        reasons.append(f"plan_belt resume не done: {E.code_of(relay)} {E.text_of(relay)}")
        return E.finish(result, reasons)
    resumed = E.as_map(rd.get("resumed"))
    if rd.get("area"):
        watch.append(pad(rd["area"], 2))

    # 7. сверка с картой
    after, truncated = E.belt_cells(api, watch, [belt])
    if truncated:
        reasons.append("карта обрезала список лент после перекладки — сверка неполная")
    for cell, b in sorted(built.items()):
        now = after.get(cell)
        if now is None or now["ghost"] or now.get("dir") != b.get("dir"):
            reasons.append(f"построенная лента {cell} не цела: было {b}, стало {now}")
            break
    new_ghosts = {c for c, b in after.items() if b["ghost"]}
    path, reached = walk_chain(after, start, goal)
    on_chain = set(path)
    result["after"] = {"ghosts": len(new_ghosts), "chain": len(path), "reached": reached,
                       "resumed": dict(resumed), "warnings": E.as_list(rd.get("warnings"))}
    if resumed.get("built") != prefix:
        reasons.append(f"resumed.built = {resumed.get('built')}, а на карте от начала построено {prefix}")
    if resumed.get("removed") != len(old_ghosts):
        reasons.append(f"resumed.removed = {resumed.get('removed')}, а призраков ленты до перекладки было {len(old_ghosts)}")
    if rd.get("ghosts") != len(new_ghosts):
        reasons.append(f"на карте {len(new_ghosts)} призраков ленты, в ответе {rd.get('ghosts')}")
    if obstacle in after:
        reasons.append(f"на клетке помехи {obstacle} осталась лента или её призрак: {after[obstacle]}")
    stray = sorted(new_ghosts - on_chain)
    if stray and not apart:
        reasons.append(f"призраки вне нового пути (старые не убраны?): {stray[:5]}")
    if apart:
        # построено не подряд: эти клетки остаются помехой, перекладка говорит о них предупреждением
        if warning(rd, "built_apart:") is None:
            reasons.append(f"построено не подряд ({len(apart)} клеток), а предупреждения built_apart нет")
    elif not reached:
        reasons.append(f"лента не доходит до цели {goal}: цепочка от начала кончилась у {path[-1] if path else start}")
    if obstacle in on_chain:
        reasons.append(f"новый путь идёт через клетку помехи {obstacle}")
    if len(new_ghosts) <= len(row) - prefix - 1 and reached:
        reasons.append(f"обход не длиннее прямой: {len(new_ghosts)} призраков на {len(row) - prefix} клеток остатка")
    chests, _, _ = E.on_map(api, [chest], E.cell_center(obstacle), 2)
    if not any(E.cell_of(e["pos"]) == obstacle for e in chests if e.get("pos")):
        reasons.append(f"помеха (сундук) пропала с клетки {obstacle}")

    # 8. поворот своей построенной ленты (действие rotate) и возврат как было
    if built:
        cell = sorted(built)[0]
        tgt = {"name": belt, "pos": E.cell_center(cell)}
        turn = api.act("rotate", {"target": tgt, "direction": 0})
        td = E.detail_of(turn)
        was = td.get("was")
        if was == 0:
            turn = api.act("rotate", {"target": tgt, "direction": 4})
            td = E.detail_of(turn)
        result["rotate"] = {"cell": list(cell), "turn": E.brief(turn)}
        if turn["kind"] != "job_done" or td.get("direction") == td.get("was"):
            reasons.append(f"rotate не повернул ленту {cell}: {E.code_of(turn)} {E.text_of(turn)} {td}")
        elif was is not None:
            back = api.act("rotate", {"target": tgt, "direction": was})
            bd = E.detail_of(back)
            result["rotate"]["back"] = E.brief(back)
            if back["kind"] != "job_done" or bd.get("direction") != was or bd.get("was") != td.get("direction"):
                reasons.append(f"rotate не вернул ленту {cell} как было: {bd}")
    return E.finish(result, reasons)
