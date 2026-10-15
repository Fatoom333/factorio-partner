"""Живой сценарий: постройка 2×2 и все четыре поворота чертежа (0, 4, 8, 12).

Ход:
1. Помощник; печь 2×2 (камень со складов хозяина + `craft`) и сундук 1×1 (как в build_place).
2. `act place` печи: центр постройки чётного размера — на стыке клеток. Сверка: `map` видит печь
   ровно там, куда ставили; `act deconstruct {target:{unit_number, pos}}` возвращает предмет.
3. Несимметричный чертёж: печь 2×2 и сундук справа от неё в верхнем ряду. Для каждого поворота
   0, 4, 8, 12: `act build_blueprint {direction, mode:"hand"}` → обе постройки построены, ничего не
   пропущено; по `map` сундук стоит относительно печи там, куда его переносит поворот (вектор
   «печь → сундук» повёрнут на 90° × n по часовой стрелке).
4. Сверка раскладки мода с движком: `dry_run` с `force: normal` поверх только что построенного —
   обе постройки должны попасть в `skipped`, а их `pos` (расчёт мода) — совпасть с тем, где их
   на самом деле поставил движок. Потом `deconstruct {area, filter}` и следующий поворот.
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
BIG = "stone-furnace"
DIRECTIONS = (0, 4, 8, 12)
CHEST_OFFSET = (1.5, -0.5)   # сундук относительно центра печи в чертеже (справа, верхний ряд)
CORNERS = ((5, 0), (0, 5), (-5, 0), (0, -5), (6, 6), (-6, 6), (6, -6), (-6, -6), (9, 0), (0, 9), (-9, 0), (0, -9))


def rotate(dx, dy, direction):
    """Поворот вектора по часовой стрелке (y вниз): 4 — на 90°, 8 — на 180°, 12 — на 270°."""
    if direction == 4:
        return -dy, dx
    if direction == 8:
        return -dx, -dy
    if direction == 12:
        return dy, -dx
    return dx, dy


def blueprint(chest):
    return G.encode_blueprint([
        {"name": BIG, "position": {"x": 0, "y": 0}},
        {"name": chest, "position": {"x": CHEST_OFFSET[0], "y": CHEST_OFFSET[1]}},
    ])


def found(client, anchor, names):
    """Постройки с этими именами возле anchor по `map`: {имя: [pos, ...]}."""
    data = client.call_ok("map", {"center": anchor, "radius": 6, "names": list(names)}, P.HELPER)
    out = {n: [] for n in names}
    for e in data.get("entities", []):
        if e.get("name") in out and not e.get("ghost"):
            out[e["name"]].append(e["pos"])
    return out


def near(a, b, eps=0.05):
    return abs(a["x"] - b["x"]) <= eps and abs(a["y"] - b["y"]) <= eps


def place_big(client, result, reasons):
    """Шаг 2: place печи на стыке клеток, сверка по карте, разбор по {unit_number, pos}."""
    base = P.helper_state(client)["pos"]
    tries, pos, placed = [], None, None
    for dx, dy in CORNERS:
        p = {"x": int(base["x"] // 1) + dx, "y": int(base["y"] // 1) + dy}
        r = P.act(client, "place", {"item": BIG, "pos": p})
        tries.append({"pos": p, "kind": r["kind"], "code": P.code_of(r)})
        if r["kind"] == "job_done":
            pos, placed = p, r
            break
        if P.code_of(r) != "cannot_place":
            break
    result["place"] = {"tries": tries, "detail": P.detail_of(placed) if placed else None}
    if pos is None:
        reasons.append(f"place печи не done: {tries[-1] if tries else None}")
        return
    seen = found(client, pos, [BIG])[BIG]
    result["place"]["on_map"] = seen
    if len(seen) != 1 or not near(seen[0], pos):
        reasons.append(f"печь ставили в {pos}, а на карте она в {seen}")
    unit = P.detail_of(placed).get("unit_number")
    r = P.act(client, "deconstruct", {"target": {"unit_number": unit, "pos": pos}})
    result["place"]["deconstruct"] = P.brief(r)
    if r["kind"] != "job_done" or P.detail_of(r).get("removed") != 1:
        reasons.append(f"deconstruct печи: {result['place']['deconstruct']}")


def turn(client, blob, chest, anchor, direction, reasons):
    """Шаги 3–4 для одного поворота. → запись в результат."""
    rec = {"direction": direction}
    r = P.act(client, "build_blueprint", {"blob": blob, "anchor": anchor, "direction": direction, "mode": "hand"})
    rec["build"] = P.brief(r)
    d = P.detail_of(r)
    tag = f"поворот {direction}"
    if r["kind"] != "job_done" or d.get("built") != 2 or d.get("skipped_total") or d.get("left"):
        reasons.append(f"{tag}: build_blueprint: {rec['build']}")
        return rec
    seen = found(client, anchor, [BIG, chest])
    rec["on_map"] = seen
    if len(seen[BIG]) != 1 or len(seen[chest]) != 1:
        reasons.append(f"{tag}: на карте {seen}")
        return rec
    big, small = seen[BIG][0], seen[chest][0]
    want = rotate(CHEST_OFFSET[0], CHEST_OFFSET[1], direction)
    got = (small["x"] - big["x"], small["y"] - big["y"])
    rec["vector"] = {"expected": want, "built": got}
    if abs(got[0] - want[0]) > 0.05 or abs(got[1] - want[1]) > 0.05:
        reasons.append(f"{tag}: сундук относительно печи {got}, а поворот даёт {want}")
    # раскладка мода против движка: normal поверх построенного — обе в skipped, pos = расчёт мода
    r = P.act(client, "build_blueprint", {"blob": blob, "anchor": anchor, "direction": direction,
                                          "force": "normal", "dry_run": True})
    skipped = {s["name"]: s["pos"] for s in P.detail_of(r).get("skipped") or []}
    rec["mod_layout"] = skipped
    if r["kind"] != "job_done" or set(skipped) != {BIG, chest}:
        reasons.append(f"{tag}: dry_run поверх построенного не назвал обе постройки: {P.detail_of(r)}")
    elif not near(skipped[BIG], big) or not near(skipped[chest], small):
        reasons.append(f"{tag}: расчёт мода {skipped}, а движок поставил печь в {big}, сундук в {small}")
    area = {"left_top": {"x": anchor["x"] - 5, "y": anchor["y"] - 5},
            "right_bottom": {"x": anchor["x"] + 5, "y": anchor["y"] + 5}}
    r = P.act(client, "deconstruct", {"area": area, "filter": [BIG, chest]})
    rec["deconstruct"] = P.brief(r)
    if r["kind"] != "job_done" or P.detail_of(r).get("removed") != 2:
        reasons.append(f"{tag}: deconstruct области не убрал 2: {rec['deconstruct']}")
    return rec


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    if not P.get_item(client, BIG, 1, result):
        return P.setup_failed(result, f"не удалось добыть {BIG} (камень со складов хозяина и крафт)")
    chest = P.get_chests(client, result, 1)
    if chest is None:
        return P.setup_failed(result, "не удалось добыть сундук")
    result["item"] = chest
    reasons = []
    place_big(client, result, reasons)

    blob = G.new_blob(client, blueprint(chest), "big")
    base = P.helper_state(client)["pos"]
    anchor, dry_log = None, []
    for dx, dy in CORNERS:
        a = {"x": int(base["x"] // 1) + dx, "y": int(base["y"] // 1) + dy}
        clean = True
        for direction in DIRECTIONS:
            r = P.act(client, "build_blueprint", {"blob": blob, "anchor": a, "direction": direction, "dry_run": True})
            d = P.detail_of(r)
            dry_log.append({"anchor": a, "direction": direction, "kind": r["kind"], "code": P.code_of(r),
                            "ghosts": d.get("ghosts"), "skipped": d.get("skipped_total"), "to_remove": d.get("to_remove_total")})
            if r["kind"] != "job_done" or d.get("ghosts") != 2 or d.get("skipped_total") or d.get("to_remove_total"):
                clean = False
                break
        if clean:
            anchor = a
            break
    result["dry_run"] = dry_log[-8:]
    if anchor is None:
        reasons.append(f"dry_run не нашёл места, чистого для всех поворотов: {dry_log[-1] if dry_log else None}")
    else:
        result["anchor"] = anchor
        result["turns"] = []
        for direction in DIRECTIONS:
            if P.helper_count(client, BIG) < 1 or P.helper_count(client, chest) < 1:
                reasons.append(f"поворот {direction}: предметы не вернулись после разбора")
                break
            result["turns"].append(turn(client, blob, chest, anchor, direction, reasons))
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
