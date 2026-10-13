"""Живой сценарий потока N «Прокладка лент»: подземные участки (`plan_belt`).

Часть 1 — через ленту. Настоящих лент на пути в копии сейва может не быть, а построить их помощнику
нечем (инвентарь пуст), поэтому помеха — призраки ленты, которые ставит сам сценарий:
1. На свободном квадрате 41 × 41 — лента сверху вниз через середину (`underground: "never"`).
2. Вторая лента слева направо через середину (режим по умолчанию, `auto`): она обязана пройти под первой
   подземным участком. Сверка с игрой (`map`): вторая лента непрерывна и приходит в конец, подземная
   пара стоит по разные стороны первой ленты, призраки первой ленты целы.

Часть 2 — через жидкость подземного нет. Две точки по разные стороны жидкости (на Вулкане — лава),
`underground: "prefer"` (подземные везде, где можно): ни под одним подземным участком нет жидкости, ни
одного призрака на жидкости, лента непрерывна.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3). Сейв — копия стенда.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
SQUARE = 41


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


B = _load("_belt")


def crossing(client, t, origin, result, reasons):
    corner = B.find_free_square(t, origin, SQUARE)
    if corner is None:
        reasons.append(f"нет свободного квадрата {SQUARE} × {SQUARE} для части 1")
        return
    x0, y0 = corner
    mid = SQUARE // 2
    top, bottom = (x0 + mid, y0), (x0 + mid, y0 + SQUARE - 1)
    left, right = (x0, y0 + mid), (x0 + SQUARE - 1, y0 + mid)
    cross = (x0 + mid, y0 + mid)
    result["square"] = {"corner": list(corner), "side": SQUARE}

    first = B.act(client, "plan_belt", {"from": B.center(top), "to": B.center(bottom), "underground": "never"})
    result["first"] = B.brief(first)
    if first["kind"] != "job_done":
        reasons.append(f"первая лента не done: {B.code_of(first)} {B.text_of(first)}")
        return
    info1, line1 = B.verify_chain(client, t, first, top, bottom, reasons)
    result["first_chain"] = info1
    if len(line1) != SQUARE:
        reasons.append(f"первая лента: {len(line1)} призраков вместо {SQUARE}")

    second = B.act(client, "plan_belt", {"from": B.center(left), "to": B.center(right)})
    result["second"] = B.brief(second)
    if second["kind"] != "job_done":
        reasons.append(f"вторая лента не done: {B.code_of(second)} {B.text_of(second)}")
        return
    d2 = B.detail_of(second)
    info2, line2 = B.verify_chain(client, t, second, left, right, reasons, before=line1)
    result["second_chain"] = info2
    if (d2.get("undergrounds") or 0) < 1:
        reasons.append("вторая лента прошла без подземного участка")
    under = (d2.get("chosen") or {}).get("underground")
    if not under or (d2.get("need") or {}).get(under) != 2 * (d2.get("undergrounds") or 0):
        reasons.append(f"need не считает подземные: {d2.get('need')} при undergrounds={d2.get('undergrounds')}")
    over = [p for p in info2.get("pairs") or [] if list(cross) in [list(c) for c in B.between(tuple(p[0]), tuple(p[1]))]]
    if not over:
        reasons.append(f"подземная пара не перекрывает клетку пересечения {cross}: {info2.get('pairs')}")
    if cross in line2:
        reasons.append("вторая лента встала на клетку первой")
    # первая лента цела
    names = [n for n in ((B.detail_of(first).get("chosen") or {}).get("belt"),) if n]
    now, _ = B.belt_ghosts(client, B.detail_of(first)["area"], names)
    lost = [c for c, g in line1.items() if now.get(c) != g]
    if lost:
        reasons.append(f"призраки первой ленты изменились: {lost[:5]}")


def liquid(client, t, origin, result, reasons):
    pair = B.find_detour_pair(t, origin, lo=20, hi=80)
    if pair is None:
        result["liquid"] = {"found": False}
        reasons.append("рядом нет жидкости с обходом по суше — часть 2 не проверить")
        return
    a, b, info = pair
    result["liquid"] = {"found": True, "from": list(a), "to": list(b), **info}
    args = {"from": B.center(a), "to": B.center(b), "underground": "prefer"}
    dry = B.act(client, "plan_belt", dict(args, dry_run=True))
    old = B.snapshot(client, B.detail_of(dry))   # призраки части 1 и те, что были в сейве
    real = B.act(client, "plan_belt", args)
    result["prefer"] = B.brief(real)
    if real["kind"] != "job_done":
        reasons.append(f"лента через жидкость не done: {B.code_of(real)} {B.text_of(real)}")
        return
    chain, _ = B.verify_chain(client, t, real, a, b, reasons, before=old)
    result["prefer_chain"] = chain
    if (B.detail_of(real).get("undergrounds") or 0) < 1:
        result["liquid"]["note"] = "в режиме prefer не встало ни одного подземного участка"


def run(client) -> dict:
    result = {}
    origin = B.prepare(client, result)
    if origin is None:
        return result
    t = B.scan(client, origin)
    result["terrain"] = {"maps": t.maps, "cells": len(t.cells), "liquid": t.count(t.liquid), "land": t.count(t.land)}
    reasons = []
    crossing(client, t, origin, result, reasons)
    liquid(client, t, origin, result, reasons)
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
