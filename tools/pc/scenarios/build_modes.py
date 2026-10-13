"""Живой сценарий потока F «Стройка»: три режима постановки чертежа против настоящего движка.

Зачем: поведение режимов `force` у `build_blueprint` (normal — клик, forced — Shift, superforced —
Ctrl+Shift) записано в ACTIONS.md со слов игрока. Здесь оно сверяется с движком: маленький чертёж
(одна постройка 1×1) ставится в трёх режимах на трёх видах места, и в результат подробно
записывается, что произошло на самом деле.

Места:
* `lava` — клетка лавы/воды (по `map`, символ `~`), для каждого режима своя клетка;
* `rock` — камень (neutral, по `map types:[simple-entity]`), а если рядом есть деревья — ещё и `tree`;
* `own` — своя постройка 2×2 (печь), которую помощник сам поставил через `place`.

Для каждого места и режима: `dry_run` (оценка мода) → настоящая постановка с `mode: hand` →
осмотр (`map`, `ghosts`). В запись идут: сколько призраков встало, какие призраки плиток добавил
движок (`tiles`), что помечено к сносу (`to_remove`), что помощник разобрал (`removed`) и построил.

Итог `ok` — это «сценарий отработал и мод вёл себя согласованно», а не «движок совпал с контрактом»:
совпадение с контрактом — в `facts` и `contract` (true/false по каждому утверждению), расхождения
оценки `dry_run` с фактом — в `dry_run_mismatch`.
Предметы честные: сталь и камень со складов хозяина (`collect`/`extract`), сундуки и печь — `craft`.
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
MODES = ("normal", "forced", "superforced")
ITEM = "steel-chest"        # постройка чертежа, 1×1
OWN = "stone-furnace"       # своя постройка-помеха, 2×2
ITEM_COUNT = 6
BUILD_TIMEOUT_S = 240.0     # до камня бывает далеко идти
CORNERS = ((4, 0), (0, 4), (-4, 0), (0, -4), (5, 5), (-5, 5), (5, -5), (-5, -5), (8, 0), (0, 8), (-8, 0), (0, -8))
BAD_CODES = ("internal", "bad_args", "limit")


def cell(pos):
    """Центр клетки, в которой лежит точка."""
    return {"x": int(pos["x"] // 1) + 0.5, "y": int(pos["y"] // 1) + 0.5}


def spread(cells, count, gap=3.0):
    """Первые count клеток, не ближе gap друг к другу."""
    out = []
    for c in cells:
        if all(P.dist(c, o) >= gap for o in out):
            out.append(c)
            if len(out) == count:
                break
    return out


def look(client, anchor, obstacle=None):
    """Что стоит в точке после постановки: постройка чертежа, призраки, помеха."""
    area = {"left_top": {"x": anchor["x"] - 1, "y": anchor["y"] - 1},
            "right_bottom": {"x": anchor["x"] + 1, "y": anchor["y"] + 1}}
    ghosts = client.call_ok("ghosts", {"area": area}, P.HELPER)
    seen = {"built": len(P.entities_at(client, ITEM, anchor)), "ghosts": ghosts.get("count"),
            "ghosts_blocked": ghosts.get("blocked_total")}
    if obstacle:
        data = P.scan_map(client, anchor, 3, ("simple-entity", "tree", "furnace"))
        seen["obstacle_left"] = sum(1 for e in data.get("entities", [])
                                    if e.get("name") == obstacle["name"] and not e.get("ghost")
                                    and P.dist(e["pos"], obstacle["pos"]) < 0.6)
    return seen


def trial(client, blob, place, mode, anchor, obstacle=None):
    """Один замер: dry_run, настоящая постановка, осмотр."""
    args = {"blob": blob, "anchor": anchor, "force": mode}
    dry = P.act(client, "build_blueprint", dict(args, dry_run=True))
    run = P.act(client, "build_blueprint", dict(args, mode="hand"), BUILD_TIMEOUT_S)
    return {"place": place, "force": mode, "anchor": anchor, "obstacle": obstacle,
            "dry_run": {"kind": dry["kind"], "code": P.code_of(dry), "detail": P.detail_of(dry)},
            "run": {"kind": run["kind"], "code": P.code_of(run), "seconds": run["seconds"], "detail": P.detail_of(run),
                    "text": (run.get("data") or {}).get("text")},
            "after": look(client, anchor, obstacle)}


def fact(t):
    d = t["run"]["detail"]
    return {"result": t["run"]["code"] or t["run"]["kind"], "ghosts": d.get("ghosts"), "tiles": d.get("tiles") or {},
            "marked": d.get("to_remove_total", 0), "marked_names": sorted({e["name"] for e in d.get("to_remove") or []}),
            "removed": d.get("removed", 0), "built": d.get("built", 0), "missing": d.get("missing") or {},
            "skipped": [s.get("reason") for s in d.get("skipped") or []],
            "obstacle_left": t["after"].get("obstacle_left"), "built_on_map": t["after"]["built"]}


def mismatch(t):
    """Где оценка dry_run разошлась с настоящей постановкой."""
    a, b = t["dry_run"]["detail"], t["run"]["detail"]
    out = {}
    for key in ("ghosts", "to_remove_total", "tiles", "tiles_skipped", "skipped_total"):
        x, y = a.get(key), b.get(key)
        if (x or 0) != (y or 0) and (x or {}) != (y or {}):
            out[key] = {"dry_run": x, "run": y}
    return out


def place_own(client, result):
    """Поставить свою постройку 2×2 рядом с помощником (центр — на стыке клеток). → (pos, unit) | (None, None)."""
    base = P.helper_state(client)["pos"]
    tries = []
    for dx, dy in CORNERS:
        pos = {"x": int(base["x"] // 1) + dx, "y": int(base["y"] // 1) + dy}
        r = P.act(client, "place", {"item": OWN, "pos": pos})
        tries.append({"pos": pos, "kind": r["kind"], "code": P.code_of(r)})
        if r["kind"] == "job_done":
            result.setdefault("own_placed", []).append({"pos": pos, "tries": tries})
            return P.detail_of(r).get("pos") or pos, P.detail_of(r).get("unit_number")
        if P.code_of(r) != "cannot_place":
            break
    result.setdefault("own_placed", []).append({"pos": None, "tries": tries})
    return None, None


def own_trials(client, blob, result, trials):
    pos, _ = place_own(client, result)
    for mode in MODES:
        if pos is None:
            return
        if not P.get_item(client, ITEM, 1, result):
            return
        # чертёж — в клетку внутри печи (печь 2×2 стоит центром на стыке клеток)
        anchor = {"x": pos["x"] - 0.5, "y": pos["y"] - 0.5}
        t = trial(client, blob, "own", mode, anchor, {"name": OWN, "pos": pos})
        trials.append(t)
        if t["after"].get("obstacle_left") == 0 and mode != MODES[-1]:
            # печь снесли раньше, чем ждали — следующему режиму нужна новая
            if not P.get_item(client, OWN, 1, result):
                return
            pos, _ = place_own(client, result)


def obstacle_trials(client, blob, result, trials, place, found):
    """Камни/деревья: normal и forced — на первой помехе (normal её не трогает), superforced — на второй."""
    if not found:
        return
    targets = [found[0], found[0], found[1] if len(found) > 1 else found[0]]
    for mode, e in zip(MODES, targets):
        if not P.get_item(client, ITEM, 1, result):
            return
        t = trial(client, blob, place, mode, cell(e["pos"]), {"name": e["name"], "pos": e["pos"]})
        trials.append(t)
        if mode == "forced" and t["after"].get("obstacle_left") and len(found) < 2:
            return


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    if not P.get_item(client, ITEM, ITEM_COUNT, result):
        return P.setup_failed(result, f"не удалось добыть {ITEM_COUNT} × {ITEM} (склады хозяина, крафт)")
    result["own_item"] = P.get_item(client, OWN, 2, result)
    around = P.survey(client, result)
    blob = G.new_blob(client, G.encode_blueprint([{"name": ITEM, "position": {"x": 0.5, "y": 0.5}}]), "modes")
    result["blob"] = blob

    trials = []
    for mode, c in zip(MODES, spread(around["lava"], len(MODES))):
        trials.append(trial(client, blob, "lava", mode, c))
    obstacle_trials(client, blob, result, trials, "tree", around["trees"])
    obstacle_trials(client, blob, result, trials, "rock", around["rocks"])
    if result["own_item"]:
        own_trials(client, blob, result, trials)
    result["trials"] = trials

    facts, wrong = {}, {}
    for t in trials:
        facts.setdefault(t["place"], {})[t["force"]] = fact(t)
        m = mismatch(t)
        if m:
            wrong[t["place"] + "/" + t["force"]] = m
    result["facts"] = facts
    result["dry_run_mismatch"] = wrong

    def got(place, mode, key, default=None):
        return ((facts.get(place) or {}).get(mode) or {}).get(key, default)

    # утверждения ACTIONS.md ревизии 3.2 (None — место не нашлось, проверить нечем)
    result["contract"] = {
        "normal_marks_nothing": all(f.get("marked", 0) == 0 for p in facts.values() for m, f in p.items() if m == "normal"),
        "normal_on_obstacle_places_no_ghost": None if "rock" not in facts else got("rock", "normal", "ghosts") == 0,
        "forced_on_lava_puts_tile_ghosts": None if "lava" not in facts else bool(got("lava", "forced", "tiles")),
        "forced_on_lava_tile_names": got("lava", "forced", "tiles"),
        "forced_marks_rock": None if "rock" not in facts else got("rock", "forced", "marked", 0) > 0,
        "forced_marks_tree": None if "tree" not in facts else got("tree", "forced", "marked", 0) > 0,
        "forced_marks_own_building": None if "own" not in facts else got("own", "forced", "marked", 0) > 0,
        "superforced_marks_own_building": None if "own" not in facts else got("own", "superforced", "marked", 0) > 0,
    }

    reasons = []
    places = {t["place"] for t in trials}
    for need in ("lava", "rock", "own"):
        if need not in places:
            reasons.append(f"не нашлось места «{need}» — режимы на нём не проверены")
    for t in trials:
        tag = f"{t['place']}/{t['force']}"
        for step in ("dry_run", "run"):
            if t[step]["kind"] is None:
                reasons.append(f"{tag}: {step} не завершился")
            elif t[step]["code"] in BAD_CODES:
                reasons.append(f"{tag}: {step} → {t[step]['code']} ({t[step].get('text')})")
        d = t["run"]["detail"]
        if t["run"]["kind"] == "job_done":
            # согласованность мода: готово — значит, всё поставленное построено и помеченное разобрано
            if d.get("left") != 0:
                reasons.append(f"{tag}: job_done, а left = {d.get('left')}")
            if d.get("to_remove_total", 0) != d.get("removed", 0):
                reasons.append(f"{tag}: помечено {d.get('to_remove_total')}, разобрано {d.get('removed', 0)}")
            if d.get("ghosts") and t["after"]["built"] != 1:
                reasons.append(f"{tag}: job_done, но на карте построек {t['after']['built']}")
            if t["after"]["ghosts"]:
                reasons.append(f"{tag}: job_done, но остались призраки: {t['after']['ghosts']}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
