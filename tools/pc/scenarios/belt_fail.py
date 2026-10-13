"""Живой сценарий потока N «Прокладка лент»: пути нет (`plan_belt` → `path_failed`).

Ход:
1. `hello`, помощник, съёмка местности операцией `map`.
2. Поиск острова: суша, со всех сторон окружённая жидкостью шире, чем достаёт подземный конвейер.
3. `act plan_belt` от земли рядом с помощником до острова: итог `job_failed{path_failed}`, в `detail`
   есть `reached` (докуда дошёл поиск) — и эта клетка не на острове; ни одного призрака не поставлено
   (операция `ghosts` до и после).
4. Заодно: конец на самой жидкости → `cannot_place`.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3). Сейв — копия стенда.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
MAX_DISTANCE = 400      # действие берёт до 512 по прямой
GHOSTS_RADIUS = 64


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


B = _load("_belt")


def ghost_count(client, cell):
    return client.call_ok("ghosts", {"center": B.center(cell), "radius": GHOSTS_RADIUS}, B.HELPER).get("count")


def run(client) -> dict:
    result = {}
    origin = B.prepare(client, result)
    if origin is None:
        return result
    t = B.scan(client, origin)
    result["terrain"] = {"maps": t.maps, "cells": len(t.cells), "liquid": t.count(t.liquid), "land": t.count(t.land)}
    found = B.find_island(t, origin)
    if found is None:
        result.update(ok=False, error={"kind": "setup", "text": "в 160 клетках от помощника нет острова, "
                                       "окружённого жидкостью"})
        return result
    island, size, home = found
    dist = abs(island[0] - home[0]) + abs(island[1] - home[1])
    result["points"] = {"from": list(home), "to": list(island), "island_cells": size, "dist": dist}
    if dist > MAX_DISTANCE:
        result.update(ok=False, error={"kind": "setup", "text": f"остров слишком далеко: {dist} клеток"})
        return result

    reasons = []
    before = ghost_count(client, home)
    real = B.act(client, "plan_belt", {"from": B.center(home), "to": B.center(island)})
    result["plan"] = B.brief(real)
    detail = B.detail_of(real)
    if real["kind"] != "job_failed" or B.code_of(real) != "path_failed":
        reasons.append(f"ждали job_failed{{path_failed}}, получили {real['kind']} {B.code_of(real)} {B.text_of(real)}")
    else:
        reached = detail.get("reached")
        if not isinstance(reached, dict) or "x" not in reached or "y" not in reached:
            reasons.append(f"в detail нет reached: {detail}")
        else:
            cell = (int(reached["x"] // 1), int(reached["y"] // 1))
            if t.liquid(cell):
                reasons.append(f"reached {cell} — на жидкости")
            if cell in B.component(island, t.passable, limit=5000):
                reasons.append(f"reached {cell} — на острове, куда пути нет")
        if detail.get("reason") not in ("unreachable", "budget"):
            reasons.append(f"detail.reason = {detail.get('reason')!r}")
    after = ghost_count(client, home)
    result["ghosts_op"] = {"before": before, "after": after}
    if before != after:
        reasons.append(f"после неудачи призраков стало {after}, было {before}")

    # конец на жидкости
    wet = None
    for dx, dy in B.VEC.values():
        for k in range(1, B.MAX_UNDERGROUND + 2):
            n = (island[0] + dx * k, island[1] + dy * k)
            if t.liquid(n):
                wet = n
                break
        if wet:
            break
    if wet is not None:
        r = B.act(client, "plan_belt", {"from": B.center(home), "to": B.center(wet)})
        result["on_liquid"] = {"to": list(wet), "kind": r["kind"], "code": B.code_of(r), "text": B.text_of(r)}
        if r["kind"] != "job_failed" or B.code_of(r) != "cannot_place":
            reasons.append(f"конец на жидкости: ждали cannot_place, получили {r['kind']} {B.code_of(r)}")

    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
