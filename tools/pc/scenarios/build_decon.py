"""Живой сценарий потока F «Стройка»: разобрать поставленное — предмет вернулся (act deconstruct).

Ход:
1. Как build_place: помощник, сундук честно со склада хозяина (`collect`), `act place` рядом.
2. `act deconstruct {target:{unit_number, pos}}` (номер — из ответа `place`) — подход, `selected` + `mining_state` до исчезновения.
3. Сверка: job_done, removed = 1, got = {<сундук>: 1}; у помощника предметов столько же, сколько
   было до постановки; `map` больше не видит сундук на месте.
Общие шаги — из build_place.py (загрузка по пути). Только конверты `/partner <JSON>`.
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


P = _load("build_place")


def run(client) -> dict:
    result = {}
    item = P.prepare(client, result)
    if item is None:
        return result
    before = P.helper_count(client, item)
    pos, placed = P.place_near(client, item, result)
    if pos is None:
        result.update(ok=False, reasons=[f"place не done: {result.get('place')}"])
        return result

    reasons = []
    unit = P.detail_of(placed).get("unit_number")
    r = P.act(client, "deconstruct", {"target": {"unit_number": unit, "pos": pos}})
    result["deconstruct"] = P.brief(r)
    if r["kind"] != "job_done":
        reasons.append(f"deconstruct не done: {result['deconstruct']}")
    else:
        detail = P.detail_of(r)
        if detail.get("removed") != 1:
            reasons.append(f"removed = {detail.get('removed')}, а не 1")
        if (detail.get("got") or {}).get(item, 0) != 1:
            reasons.append(f"got = {detail.get('got')}, ждали {item}: 1")
    after = P.helper_count(client, item)
    result["inventory"] = {"before_place": before, "after_deconstruct": after}
    if after != before:
        reasons.append(f"у помощника {after} шт., до постановки было {before}")
    left = P.entities_at(client, item, pos)
    result["on_map"] = len(left)
    if left:
        reasons.append(f"постройка {item} осталась на месте {pos}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
