"""Живой сценарий потока F «Стройка»: чертёж с плитками — призраки плиток строятся раньше построек.

Ход:
1. Помощник; предмет плитки со складов хозяина (первое, что есть: очищенный бетон, бетон, каменный
   кирпич) и один сундук (как в build_place).
2. Чертёж: сундук 1×1 и ряд из трёх плиток под ним и по бокам. Место — `dry_run`, пока оценка не
   скажет: 1 призрак постройки, 3 призрака плиток, ничего не пропущено и не помечено к сносу.
3. `act build_blueprint {mode:"hand"}`. Сверка: job_done; `tiles` = 3; `built` = 4,
   из них `tiles_built` = 3; `tiles_first` = true (ни одна постройка не поставлена раньше последней
   плитки); у помощника убыло 3 предмета плитки и 1 сундук; сундук виден на карте.
4. Повторный `dry_run` там же: плитки уже лежат → `tiles` пусто и `tiles_skipped` = 0 (мод читает
   настоящую плитку поверхности), сундук — в `skipped`.
5. Чертёж из одних плиток (две клетки рядом): `ghosts` = 0, `built` = `tiles_built` = 2.
6. Замер, а не проверка (`liquid`): если рядом есть лава/вода и на складах есть отсыпка — чертёж
   «сундук + плитка отсыпки под ним» ставится на клетку лавы. В результат идёт, что сказала оценка
   и что сделал движок (положил ли призрак плитки, встал ли призрак постройки, построилось ли).
   На `ok` влияет только сбой самого мода.
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
# (предмет, плитка) — что класть; берётся первое, чего на складах хватает
TILES = (("refined-concrete", "refined-concrete"), ("concrete", "concrete"), ("stone-brick", "stone-path"))
TILE_COUNT = 5
OFFSETS = ((4, 0), (0, 4), (-4, 0), (0, -4), (5, 5), (-5, 5), (5, -5), (-5, -5), (8, 0), (0, 8), (-8, 0), (0, -8))
COVER = ("landfill", "landfill")   # (предмет, плитка) для замера на лаве/воде
BAD_CODES = ("internal", "bad_args", "limit")


def tile_blueprint(item, tile):
    """Сундук в клетке (0, 0) и три плитки в ряд: клетки −1, 0, 1. Рамка x −1..2 → центр (0.5, 0.5)."""
    return G.encode_blueprint([{"name": item, "position": {"x": 0.5, "y": 0.5}}],
                              [{"name": tile, "position": {"x": dx, "y": 0}} for dx in (-1, 0, 1)])


def tiles_only_blueprint(tile):
    return G.encode_blueprint([], [{"name": tile, "position": {"x": dx, "y": 0}} for dx in (0, 1)])


def liquid_probe(client, result, chest, reasons):
    """Шаг 6: плитка чертежа под постройкой на лаве/воде — что делает движок. Записывает result["liquid"]."""
    around = P.survey(client, result)
    if not around["lava"]:
        result["liquid"] = {"skipped": "рядом с помощником нет воды и лавы"}
        return
    item, tile = COVER
    if not P.get_item(client, item, 1, result) or not P.get_item(client, chest, 1, result):
        result["liquid"] = {"skipped": f"на складах хозяина нет {item} или сундука"}
        return
    blob = G.new_blob(client, G.encode_blueprint([{"name": chest, "position": {"x": 0.5, "y": 0.5}}],
                                                 [{"name": tile, "position": {"x": 0, "y": 0}}]), "liquid")
    anchor = around["lava"][0]
    rec = {"anchor": anchor, "tile": tile}
    for key, extra in (("dry_run", {"dry_run": True}), ("run", {"mode": "hand"})):
        r = P.act(client, "build_blueprint", dict({"blob": blob, "anchor": anchor}, **extra), 240.0)
        rec[key] = {"kind": r["kind"], "code": P.code_of(r), "detail": P.detail_of(r)}
        if r["kind"] is None or P.code_of(r) in BAD_CODES:
            reasons.append(f"замер на лаве, {key}: {rec[key]}")
    d = rec["run"]["detail"]
    rec["facts"] = {"tile_ghost_placed": bool(d.get("tiles")), "entity_ghost_placed": bool(d.get("ghosts")),
                    "tiles_built": d.get("tiles_built", 0), "built": d.get("built", 0),
                    "tiles_first": d.get("tiles_first"), "on_liquid": d.get("on_liquid", 0),
                    "liquids": d.get("liquids") or {}}
    result["liquid"] = rec


def pick_tile(client, result):
    """Предмет плитки, которого на складах хватает. → (предмет, плитка) | None."""
    total, _ = P._stock_total(client, [t[0] for t in TILES], result)
    for item, tile in TILES:
        if total.get(item, 0) >= TILE_COUNT and P.get_item(client, item, TILE_COUNT, result):
            return item, tile
    return None


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    picked = pick_tile(client, result)
    if picked is None:
        return P.setup_failed(result, "на складах хозяина нет предметов плитки (бетон, каменный кирпич)")
    tile_item, tile = picked
    chest = P.get_chests(client, result, 1)
    if chest is None:
        return P.setup_failed(result, "не удалось добыть сундук")
    result.update(tile_item=tile_item, tile=tile, item=chest)
    blob = G.new_blob(client, tile_blueprint(chest, tile), "tiles")

    base = P.helper_state(client)["pos"]
    anchor, dry_log = None, []
    for dx, dy in OFFSETS:
        a = {"x": int(base["x"] // 1) + dx + 0.5, "y": int(base["y"] // 1) + dy + 0.5}
        r = P.act(client, "build_blueprint", {"blob": blob, "anchor": a, "dry_run": True})
        d = P.detail_of(r)
        dry_log.append({"anchor": a, "kind": r["kind"], "code": P.code_of(r), "ghosts": d.get("ghosts"),
                        "tiles": d.get("tiles"), "tiles_skipped": d.get("tiles_skipped"),
                        "skipped": d.get("skipped_total"), "to_remove": d.get("to_remove_total")})
        if (r["kind"] == "job_done" and d.get("ghosts") == 1 and d.get("tiles") == 3
                and not d.get("skipped_total") and not d.get("to_remove_total") and not d.get("tiles_skipped")):
            anchor = a
            break
        if r["kind"] != "job_done" and P.code_of(r) not in ("cannot_place", "not_charted"):
            break
    result["dry_run"] = dry_log
    if anchor is None:
        result.update(ok=False, reasons=[f"dry_run не нашёл чистого места: {dry_log[-1] if dry_log else None}"])
        return result
    result["anchor"] = anchor

    reasons = []
    before = {tile_item: P.helper_count(client, tile_item), chest: P.helper_count(client, chest)}
    r = P.act(client, "build_blueprint", {"blob": blob, "anchor": anchor, "mode": "hand"})
    result["build"] = P.brief(r)
    d = P.detail_of(r)
    if r["kind"] != "job_done":
        reasons.append(f"build_blueprint не done: {result['build']}")
    else:
        for key, want in (("ghosts", 1), ("built", 4), ("left", 0), ("tiles_built", 3), ("tiles_first", True),
                          ("tiles_skipped", 0), ("tiles", 3), ("on_liquid", 0)):
            if d.get(key) != want:
                reasons.append(f"{key} = {d.get(key)}, а не {want}")
    after = {tile_item: P.helper_count(client, tile_item), chest: P.helper_count(client, chest)}
    result["inventory"] = {"before": before, "after": after}
    if before[tile_item] - after[tile_item] != 3:
        reasons.append(f"предметов плитки убыло {before[tile_item] - after[tile_item]}, а не 3")
    if before[chest] - after[chest] != 1:
        reasons.append(f"сундуков убыло {before[chest] - after[chest]}, а не 1")
    result["on_map"] = len(P.entities_at(client, chest, anchor))
    if result["on_map"] != 1:
        reasons.append(f"сундука на карте в {anchor}: {result['on_map']}")

    # плитки уже лежат: оценка это видит по настоящей поверхности
    r = P.act(client, "build_blueprint", {"blob": blob, "anchor": anchor, "dry_run": True})
    d2 = P.detail_of(r)
    result["dry_run_again"] = {"kind": r["kind"], "code": P.code_of(r), "detail": d2}
    if r["kind"] != "job_done" or d2.get("tiles") or d2.get("tiles_skipped") or d2.get("ghosts") != 0:
        reasons.append(f"повторный dry_run: плитки должны считаться уложенными, а сундук — стоящим: {d2}")

    # чертёж из одних плиток, на клетку ниже (две клетки, центр рамки — стык клеток)
    blob2 = G.new_blob(client, tiles_only_blueprint(tile), "tiles")
    a2 = {"x": anchor["x"] + 0.5, "y": anchor["y"] + 2}
    r = P.act(client, "build_blueprint", {"blob": blob2, "anchor": a2, "mode": "hand"})
    result["tiles_only"] = dict(P.brief(r), anchor=a2)
    d3 = P.detail_of(r)
    if r["kind"] != "job_done" or d3.get("ghosts") != 0 or d3.get("built") != 2 or d3.get("tiles_built") != 2:
        reasons.append(f"чертёж из одних плиток: {result['tiles_only']}")
    liquid_probe(client, result, chest, reasons)
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
