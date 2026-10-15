"""Живой сценарий: режимы `robots` и `auto` у стройки призраков.

Личные дроны помощнику нужны честные: броня с робопортом (и питанием в сетке) и строительные дроны
со складов хозяина. Сценарий сначала смотрит, есть ли это на складах (`stock`):
* есть — броня переносится целым стаком и надевается (`extract {equip:true}`), дроны берутся
  `collect`; если после этого `state.robots.construction` > 0, чертёж строится в режиме `robots`
  (руками ничего не ставится) — это полная проверка;
* нет — в результат пишется ограничение (`robots_available: false`, `limitation`), и проверяется то,
  что без дронов обязано работать по контракту: `mode: robots` сразу отвечает `no_items` (призраки
  остаются стоять), а `build_ghosts {mode: auto}` по той же области строит их руками.
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


P = _load("build_place")
G = _load("build_ghosts")
ARMORS = ("mech-armor", "power-armor-mk2", "power-armor", "modular-armor")
ROBOT = "construction-robot"
ROBOTS_WANTED = 5
COUNT = 2


def try_robots(client, result):
    """Честно добыть броню с робопортом и дронов. → True, если у помощника появились личные дроны."""
    total, radius = P._stock_total(client, list(ARMORS) + [ROBOT], result)
    info = {"stock": total}
    result["robots_setup"] = info
    armor = next((a for a in ARMORS if total.get(a, 0) >= 1), None)
    if armor is None or total.get(ROBOT, 0) < 1:
        info["why"] = "на видимых складах хозяина нет брони с сеткой и/или строительных дронов"
        return False
    data = client.call_ok("stock", {"radius": radius, "items": [armor], "limit": 50}, P.HELPER)
    boxes = sorted((c for c in data.get("containers", []) if (c.get("items") or {}).get(armor)),
                   key=lambda c: c.get("dist", 1e9))
    for c in boxes[:3]:
        r = P.act(client, "extract", {"target": {"unit_number": c.get("unit"), "pos": c.get("pos")},
                                      "items": {armor: 1}, "equip": True})
        info["armor"] = P.brief(r)
        if r["kind"] == "job_done":
            break
    P.obtain(client, ROBOT, min(ROBOTS_WANTED, total.get(ROBOT, 0)), radius, result, "collect_robots")
    robots = (P.helper_state(client).get("robots") or {})
    info["state_robots"] = robots
    if not robots.get("construction"):
        info["why"] = "броня надета, но личных дронов нет: в её сетке нет робопорта или питания"
        return False
    return True


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    item = P.get_chests(client, result, COUNT)
    if item is None:
        return P.setup_failed(result, "не удалось добыть сундуки")
    result["item"] = item
    result["robots_available"] = try_robots(client, result)
    blob = G.new_blob(client, G.blueprint_string(item, COUNT), "robots")

    base = P.helper_state(client)["pos"]
    anchor = None
    for dx, dy in G.OFFSETS:
        a = G.anchor_near(base, dx, dy)
        r = P.act(client, "build_blueprint", {"blob": blob, "anchor": a, "dry_run": True})
        d = P.detail_of(r)
        if r["kind"] == "job_done" and d.get("ghosts") == COUNT and not d.get("skipped_total") and not d.get("to_remove_total"):
            anchor = a
            break
    if anchor is None:
        result.update(ok=False, reasons=["dry_run не нашёл места для чертежа"])
        return result
    result["anchor"] = anchor
    area = {"left_top": {"x": anchor["x"] - 3, "y": anchor["y"] - 3},
            "right_bottom": {"x": anchor["x"] + 3, "y": anchor["y"] + 3}}
    reasons = []
    before = P.helper_count(client, item)

    r = P.act(client, "build_blueprint", {"blob": blob, "anchor": anchor, "mode": "robots"})
    result["robots"] = P.brief(r)
    d = P.detail_of(r)
    if result["robots_available"]:
        if r["kind"] != "job_done" or d.get("built") != COUNT or d.get("left"):
            reasons.append(f"mode robots с дронами: {result['robots']}")
    else:
        result["limitation"] = ("режим robots с настоящими дронами не проверен: " + result["robots_setup"].get("why", "") +
                                "; надеть на помощника оборудование в сетку брони действием v1 нельзя")
        if r["kind"] != "job_failed" or P.code_of(r) != "no_items":
            reasons.append(f"mode robots без дронов должен дать no_items: {result['robots']}")
        if r["seconds"] > 10:
            reasons.append(f"mode robots без дронов ответил не сразу: {r['seconds']} с")
        if d.get("ghosts") != COUNT or d.get("built") != 0 or d.get("left") != COUNT:
            reasons.append(f"mode robots без дронов: призраки должны остаться стоять: {d}")
        if P.helper_count(client, item) != before:
            reasons.append("mode robots без дронов: предметы не должны тратиться")

    left = client.call_ok("ghosts", {"area": area}, P.HELPER).get("count")
    result["ghosts_after_robots"] = left
    if left:
        r = P.act(client, "build_ghosts", {"area": area, "mode": "auto"})
        result["auto"] = P.brief(r)
        d = P.detail_of(r)
        if r["kind"] != "job_done" or d.get("built") != left or d.get("left"):
            reasons.append(f"build_ghosts auto: {result['auto']}")
    elif not result["robots_available"]:
        reasons.append("после mode robots без дронов призраков в области нет")
    result["ghosts_left"] = client.call_ok("ghosts", {"area": area}, P.HELPER).get("count")
    if result["ghosts_left"]:
        reasons.append(f"в области осталось призраков: {result['ghosts_left']}")
    after = P.helper_count(client, item)
    result["inventory"] = {"before": before, "after": after}
    if before - after != COUNT:
        reasons.append(f"у помощника убыло {before - after}, а не {COUNT}")
    result["on_map"] = len(G.built_cells(client, item, anchor))
    if result["on_map"] != COUNT:
        reasons.append(f"на карте построек {item}: {result['on_map']}, а не {COUNT}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
