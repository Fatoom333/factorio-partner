"""Живой сценарий потока M «Разметка добычи»: ближайшее пятно руды → `plan_mining`.

Ход:
1. `hello`, помощник (`helper_spawn`), `resources` вокруг него — пятна руды от ближнего к дальнему.
2. Сухой прогон `act plan_mining {near, resource, direction, dry_run:true}` по пятнам, пока раскладка
   не встанет: `job_done`, `ghosts > 0`, `need` не пуст (лучше — без пропущенных призраков).
   Жидкости, слишком большие пятна и занятые места отсеиваются сами (`not_found`, `limit`, `skipped`).
3. Та же команда без `dry_run` — призраки ставятся силой хозяина.
4. Сверка с игрой, не с ответом действия:
   - операция `ghosts` по `detail.area`: призраков стало больше ровно на `detail.ghosts` (без плиток),
     предметов в `need` — ровно на `detail.need`;
   - буры покрывают руду: нет предупреждения `uncovered_ore_tiles`, буров столько же, сколько в ответе,
     пятно из `resources` лежит внутри размеченной области;
   - лента выходит в заданную сторону: все призраки ленты на карте (`map`) смотрят туда.
   - ревизия 3.3: карта до разметки (`map`) — клетки жидкости; ни один бур на них не стоит;
     предупреждения `enclosed` / `narrow_access` / `access_side` согласны с операцией `access` по
     рамке пятна (если пятно не обрезано кругом поиска и размечено целиком).
5. Повторная разметка того же пятна записывается в итог как справка (`repeat`): что отвечает движок на
   призрак поверх такого же призрака, заглушкой не проверить.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3). Сейв — копия стенда.
"""
from __future__ import annotations

import importlib.util
import math
import os

MODS = ["factorio-partner"]
HELPER = "mining"
JOB_TIMEOUT_S = 90.0
LAYOUT = "simple"
DIRECTION = "east"
DIR_NUM = {"north": 0, "east": 4, "south": 8, "west": 12}
MAX_TRIES = 8           # сколько пятен пробовать
MAX_PATCH_SIDE = 100    # пятно крупнее в область `ghosts` (≤ 128) с бурами по краям не влезет
MIN_TILES = 16          # меньше — не пятно (гейзер, нефть, огрызок руды)
# твёрдые руды base и Space Age — для поиска по имени, когда общий ответ `resources` забит гейзерами
ORE_NAMES = ("iron-ore", "copper-ore", "coal", "stone", "uranium-ore", "tungsten-ore", "calcite", "scrap")
SEARCH_RADIUS = 128     # предел операции resources
WINDOW = 48             # окно разметки для пятна крупнее MAX_PATCH_SIDE
_R1, _R2 = 200, 400
# точки поиска: у помощника, затем кольца на 200 и 400 клеток (круги радиуса 128 перекрываются)
RINGS = (
    ((0, 0),),
    ((_R1, 0), (-_R1, 0), (0, _R1), (0, -_R1), (_R1, _R1), (-_R1, _R1), (_R1, -_R1), (-_R1, -_R1)),
    ((_R2, 0), (-_R2, 0), (0, _R2), (0, -_R2), (_R2, _R2), (-_R2, _R2), (_R2, -_R2), (-_R2, -_R2),
     (_R2, _R1), (_R2, -_R1), (-_R2, _R1), (-_R2, -_R1), (_R1, _R2), (-_R1, _R2), (_R1, -_R2), (-_R1, -_R2)),
)
COVER_MARGIN = 6        # бур достаёт руду за своим краем: запас при сверке области


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


H = _load("_hands")


def act(client, do, args, timeout=JOB_TIMEOUT_S):
    return H.act(client, do, args, timeout, HELPER)


def code_of(r):
    return ((r or {}).get("data") or {}).get("code")


def text_of(r):
    return ((r or {}).get("data") or {}).get("text")


def detail_of(r):
    return ((r or {}).get("data") or {}).get("detail") or {}


def brief(r):
    return {"job": r["job"], "seconds": r["seconds"], "kind": r["kind"], "data": r["data"]}


def prepare(client, result):
    """hello + мод + помощник. → bool (ошибка — в result)."""
    hello = client.call_ok("hello")
    result.update(mod=str(hello.get("mod", "")), players_online=hello.get("players_online"))
    if not H.check_mod(hello, result):
        return False
    if not H.spawn(client, result, HELPER):
        result["ok"] = False
        return False
    return True


def side(area):
    return (area["right_bottom"]["x"] - area["left_top"]["x"], area["right_bottom"]["y"] - area["left_top"]["y"])


def _fit(patches):
    # одиночные клетки (гейзеры, нефть, огрызки руды) — не пятно для раскладки
    return [p for p in patches
            if max(side(p["area"])) <= MAX_PATCH_SIDE and (p.get("tiles") or 0) >= MIN_TILES]


def _window(patch):
    """Пятно крупнее лимита: размечаем окно WINDOW×WINDOW вокруг его центра (режим `area`)."""
    c = patch["center"]
    half = WINDOW / 2
    out = dict(patch)
    out["window"] = {"left_top": {"x": math.floor(c["x"] - half), "y": math.floor(c["y"] - half)},
                     "right_bottom": {"x": math.floor(c["x"] + half), "y": math.floor(c["y"] + half)}}
    return out


def _query(client, center, scan):
    """Пятна вокруг точки: общий запрос, а если ответ забит мелочью — по именам руд. → (годные, крупные)."""
    args = {"radius": SEARCH_RADIUS}
    if center is not None:
        args["center"] = center
    data = client.call_ok("resources", dict(args), HELPER)
    raw = list(data.get("patches") or [])
    scan["queries"] += 1
    if len(raw) >= 20 and not _fit(raw):
        # `resources` отдаёт 20 ближайших пятен; живой замер 2026-10-13 (Vulcanus): все 20 — гейзеры
        # кислоты по одной клетке, руда в ответ не попала. Ищем по именам (чужое имя — bad_args).
        scan["swamped"] = sorted(set(scan.get("swamped", [])) | {p["name"] for p in raw})
        raw = []
        for name in ORE_NAMES:
            r = client.call("resources", dict(args, name=name), HELPER)
            scan["queries"] += 1
            if r.get("ok"):
                raw.extend((r.get("data") or {}).get("patches") or [])
            elif (r.get("error") or {}).get("code") != "bad_args":
                scan.setdefault("errors", {})[name] = (r.get("error") or {}).get("code")
    fit = _fit(raw)
    big = [p for p in raw if max(side(p["area"])) > MAX_PATCH_SIDE and (p.get("tiles") or 0) >= MIN_TILES]
    return fit, big


def find_patches(client, result):
    """Пятна руды от ближнего к дальнему: вокруг помощника, потом кольцами дальше (STATE.md «resources»).

    Рядом с базой руды может не быть (живой замер 2026-10-13: в 128 клетках от хозяина только гейзеры),
    поэтому поиск идёт кольцами точек на 200 и 400 клеток от помощника; `plan_mining` размечает и
    далёкое пятно — телу помощника идти не нужно, нужны только открытые чанки."""
    base = client.call_ok("state", {}, HELPER)["pos"]
    for i, ring in enumerate(RINGS):
        scan = {"ring": i, "queries": 0}
        result.setdefault("scan", []).append(scan)
        seen, fit, big = set(), [], []
        for dx, dy in ring:
            center = None if (dx, dy) == (0, 0) else {"x": base["x"] + dx, "y": base["y"] + dy}
            f, b = _query(client, center, scan)
            for group, found in ((fit, f), (big, b)):
                for p in found:
                    key = (p["name"], p["area"]["left_top"]["x"], p["area"]["left_top"]["y"])
                    if key not in seen:
                        seen.add(key)
                        dist = math.hypot(p["center"]["x"] - base["x"], p["center"]["y"] - base["y"])
                        group.append(dict(p, dist=round(dist, 1)))
        scan.update(fit=len(fit), big=len(big))
        patches = fit + [_window(p) for p in big]
        if patches:
            patches.sort(key=lambda p: (1 if p.get("window") else 0, p["dist"]))
            return patches
    return []


def plan_args(patch, layout, direction, dry_run=False, extra=None):
    args = {"resource": patch["name"], "layout": layout, "direction": direction}
    if patch.get("window"):
        args["area"] = patch["window"]
    else:
        args["near"] = patch["center"]
    if dry_run:
        args["dry_run"] = True
    args.update(extra or {})
    return args


def pick_patch(client, patches, layout, direction, result, key="dry_run"):
    """Сухой прогон по пятнам: первое, где раскладка встаёт без пропусков (иначе первое, где встаёт
    хоть как-то). → (пятно, итог сухого прогона) | None."""
    log = []
    best = None
    not_ore = set()   # имена, про которые мод уже сказал «не твёрдая руда»
    for patch in patches:
        if patch["name"] in not_ore:
            continue
        if len(log) >= MAX_TRIES:
            break
        r = act(client, "plan_mining", plan_args(patch, layout, direction, dry_run=True))
        d = detail_of(r)
        if code_of(r) == "bad_args" and "not a solid ore" in str(text_of(r)):
            not_ore.add(patch["name"])
        log.append({"name": patch["name"], "center": patch["center"], "tiles": patch.get("tiles"),
                    "kind": r["kind"], "code": code_of(r), "text": text_of(r), "ghosts": d.get("ghosts"),
                    "skipped": d.get("skipped"), "warnings": d.get("warnings"), "seconds": r["seconds"]})
        if r["kind"] is None:
            break  # задача не завершилась — дальше пробовать нет смысла
        if r["kind"] == "job_done" and (d.get("ghosts") or 0) > 0 and d.get("need"):
            if not d.get("skipped"):
                best = (patch, r)
                break
            if best is None:
                best = (patch, r)
    result[key] = log
    return best


def ghosts_in(client, area):
    return client.call_ok("ghosts", {"area": area}, HELPER)


def belt_ghosts(client, area, belt):
    """Призраки ленты на карте в области (до 100, радиус карты ≤ 32). → (список, обрезано)."""
    w, h = side(area)
    center = {"x": (area["left_top"]["x"] + area["right_bottom"]["x"]) / 2,
              "y": (area["left_top"]["y"] + area["right_bottom"]["y"]) / 2}
    radius = max(4, min(32, int(math.ceil(max(w, h) / 2)) + 1))
    data = client.call_ok("map", {"center": center, "radius": radius, "names": [belt]}, HELPER)
    found = [e for e in data.get("entities", []) if e.get("ghost") and e.get("name") == belt]
    return found, bool(data.get("truncated"))


def covers(area, patch_area, margin=COVER_MARGIN):
    return (area["left_top"]["x"] - margin <= patch_area["left_top"]["x"]
            and area["left_top"]["y"] - margin <= patch_area["left_top"]["y"]
            and area["right_bottom"]["x"] + margin >= patch_area["right_bottom"]["x"]
            and area["right_bottom"]["y"] + margin >= patch_area["right_bottom"]["y"])


# ---- ревизия 3.3: жидкость и выходы с участка (PROTOCOL §6.12 — имён плиток в сценарии нет)

WARNING_PREFIXES = ("on_liquid:", "access_side:", "marked_for_deconstruction:", "uncovered_ore_tiles:", "skipped:",
                    "not_researched:")
WARNING_WORDS = ("narrow_access", "enclosed", "no_pole_researched", "fluid_needed_no_pipes", "failed_placing_belt",
                 "unable_to_create_a_layout")
ACCESS_SIDES = ("north", "east", "south", "west")
MAP_RADIUS = 32


def _windows(area):
    """Центры окон карты (65×65), которыми накрывается область."""
    xs = list(range(int(math.floor(area["left_top"]["x"])) + MAP_RADIUS, int(math.ceil(area["right_bottom"]["x"])) + MAP_RADIUS,
                    2 * MAP_RADIUS + 1))
    ys = list(range(int(math.floor(area["left_top"]["y"])) + MAP_RADIUS, int(math.ceil(area["right_bottom"]["y"])) + MAP_RADIUS,
                    2 * MAP_RADIUS + 1))
    return [{"x": x, "y": y} for x in xs for y in ys]


def liquid_cells(client, area):
    """Клетки области, где карта рисует жидкость: `~` (не пройти) и `,` (нужна подложка).
    Снимать ДО разметки: призраки закрашивают клетки под собой. → (множество клеток, имена плиток)."""
    cells, names = set(), set()
    for center in _windows(area):
        m = client.call_ok("map", {"center": center, "radius": MAP_RADIUS}, HELPER)
        bbox = m.get("bbox") or {}
        for r, row in enumerate(m.get("rows") or []):
            for c, ch in enumerate(row):
                if ch in "~,":
                    cells.add((bbox["x0"] + c, bbox["y0"] + r))
        liquids = m.get("liquids")
        if isinstance(liquids, dict):
            names.update(liquids)
    return cells, sorted(names)


def drills_on_liquid(client, area, miner, cells):
    """Призраки буров, у которых центр или соседняя с ним клетка — жидкость. → (список, сколько буров видели)."""
    bad, seen = [], set()
    if not miner:
        return bad, 0
    for center in _windows(area):
        m = client.call_ok("map", {"center": center, "radius": MAP_RADIUS, "names": [miner]}, HELPER)
        for e in m.get("entities") or []:
            if not (e.get("ghost") and e.get("name") == miner):
                continue
            x, y = e["pos"]["x"], e["pos"]["y"]
            if (x, y) in seen:
                continue
            seen.add((x, y))
            # клетки, чей центр не дальше клетки от центра бура: для бура 3×3 — все девять, для 2×2 — четыре
            hit = [(cx, cy) for cx in range(int(math.floor(x - 1)), int(math.floor(x + 1)) + 1)
                   for cy in range(int(math.floor(y - 1)), int(math.floor(y + 1)) + 1)
                   if abs(cx + 0.5 - x) <= 1 and abs(cy + 0.5 - y) <= 1 and (cx, cy) in cells]
            if hit:
                bad.append({"pos": e["pos"], "cells": hit[:4]})
    return bad, len(seen)


def check_warnings(detail, reasons):
    """Предупреждения — только известные слова; `access_side` называет сторону."""
    warnings = detail.get("warnings") or []
    for w in warnings:
        w = str(w)
        if not (w in WARNING_WORDS or w.startswith(WARNING_PREFIXES)):
            reasons.append(f"неизвестное предупреждение {w!r}")
        if w.startswith("access_side:") and w.split(":", 1)[1] not in ACCESS_SIDES:
            reasons.append(f"access_side без стороны: {w!r}")
        if w.startswith("on_liquid:") and not w.split(":", 1)[1].isdigit():
            reasons.append(f"on_liquid без числа: {w!r}")
    return [str(w) for w in warnings]


def check_liquid_and_access(client, patch, detail, cells, result, reasons):
    """Буры не стоят на жидкости; предупреждения о выходах согласны с операцией `access`."""
    warnings = check_warnings(detail, reasons)
    area = detail.get("area")
    miner = (detail.get("chosen") or {}).get("miner")
    bad, seen = drills_on_liquid(client, area, miner, cells) if area else ([], 0)
    result["liquid"] = {"cells_in_area": len(cells), "drills_seen": seen, "drills_on_liquid": bad[:5],
                        "on_liquid": [w for w in warnings if w.startswith("on_liquid:")]}
    if bad:
        reasons.append(f"буры стоят на жидкости: {len(bad)} из {seen}, первый {bad[0]}")
    if patch.get("window") or patch.get("clipped"):
        result["access"] = {"skipped": "пятно размечено окном или обрезано кругом поиска: рамка пятна неизвестна"}
        return
    r = client.call("access", {"area": patch["area"]}, HELPER)
    if not r.get("ok"):
        reasons.append(f"access по пятну: {(r.get('error') or {}).get('code')}")
        return
    acc = r["data"]
    exits = acc.get("exits") or []
    best_neck = exits[0].get("neck") if exits else None
    sides = [w.split(":", 1)[1] for w in warnings if w.startswith("access_side:")]
    result["access"] = {"land": acc.get("land"), "liquid": acc.get("liquid"), "liquids": acc.get("liquids"),
                        "enclosed": acc.get("enclosed"), "best": acc.get("best"), "best_neck": best_neck,
                        "exits": len(exits), "plan_warnings": [w for w in warnings if not w.startswith(("skipped:", "uncovered"))]}
    if bool(acc.get("enclosed")) != ("enclosed" in warnings):
        reasons.append(f"access.enclosed={acc.get('enclosed')}, а предупреждения разметки — {warnings}")
    if (best_neck == "narrow") != ("narrow_access" in warnings):
        reasons.append(f"лучший выход по access — {best_neck}, а предупреждения разметки — {warnings}")
    if sides and sides != [acc.get("best")]:
        reasons.append(f"access_side {sides}, а access.best = {acc.get('best')!r}")
    if acc.get("enclosed") and sides:
        reasons.append(f"выходов нет, а разметка называет сторону {sides}")


def verify(client, patch, before, real, result, reasons, direction=None, belts=True):
    """Сверка поставленного с игрой (шаг 4). before — ответ `ghosts` до постановки."""
    detail = detail_of(real)
    if real["kind"] != "job_done":
        reasons.append(f"plan_mining не done: {code_of(real)} {text_of(real)}")
        return
    area = detail.get("area")
    if not area or max(side(area)) > 128:
        reasons.append(f"detail.area нет или она больше 128: {area}")
        return
    after = ghosts_in(client, area)
    placed = (detail.get("ghosts") or 0) - (detail.get("tiles") or 0)
    delta = (after.get("count") or 0) - (before.get("count") or 0)
    result["ghosts_op"] = {"before": before.get("count"), "after": after.get("count"),
                           "by_name": after.get("by_name"), "blocked_total": after.get("blocked_total")}
    if placed <= 0:
        reasons.append("призраков построек не поставлено")
    if delta != placed:
        reasons.append(f"операция ghosts видит прирост {delta}, а действие сообщило {placed}")
    need_before, need_after = before.get("need") or {}, after.get("need") or {}
    for item, n in (detail.get("need") or {}).items():
        if item not in need_after and (detail.get("tiles") or 0) > 0:
            continue  # предмет плитки: призраки плиток операция ghosts не считает
        got = need_after.get(item, 0) - need_before.get(item, 0)
        if got != n:
            reasons.append(f"need[{item}] = {n}, а по призракам на карте — {got}")

    chosen = detail.get("chosen") or {}
    miner = chosen.get("miner")
    drills = (after.get("by_name") or {}).get(miner, 0) - (before.get("by_name") or {}).get(miner, 0)
    result["drills"] = {"detail": detail.get("drills"), "on_map": drills, "miner": miner}
    if not detail.get("drills") or drills != detail.get("drills"):
        reasons.append(f"буров на карте {drills}, в ответе {detail.get('drills')}")
    # MPP сам считает клетки руды, до которых не достал ни один бур, и на неровном пятне может
    # оставить единицы (живой замер 2026-10-13: 1 клетка на 380 буров) — допускаем 1 на 50 буров
    uncovered = 0
    for w in detail.get("warnings") or []:
        if str(w).startswith("uncovered_ore_tiles:"):
            uncovered = int(str(w).split(":")[1])
    allowed = max(1, (detail.get("drills") or 0) // 50)
    result["uncovered"] = {"tiles": uncovered, "allowed": allowed}
    if uncovered > allowed:
        reasons.append(f"руда покрыта не вся: мимо {uncovered} клеток (допуск {allowed})")
    if patch.get("window"):
        # размечено окно крупного пятна: разметка должна лежать в окне (с запасом на буры по краям)
        if not covers(patch["window"], area, margin=COVER_MARGIN + 8):
            reasons.append(f"размеченная область {area} вылезла из окна {patch['window']}")
    elif not covers(area, patch["area"]):
        reasons.append(f"пятно {patch['area']} не внутри размеченной области {area}")

    if belts:
        belt = chosen.get("belt")
        found, truncated = belt_ghosts(client, area, belt) if belt else ([], False)
        dirs = sorted({e.get("dir") for e in found})
        result["belts"] = {"belt": belt, "seen": len(found), "dirs": dirs, "truncated": truncated,
                           "want": DIR_NUM[direction]}
        if not found:
            reasons.append(f"на карте нет призраков ленты {belt}")
        elif dirs != [DIR_NUM[direction]]:
            reasons.append(f"лента смотрит в {dirs}, а не в {DIR_NUM[direction]} ({direction})")


def run(client) -> dict:
    result = {"layout": LAYOUT, "direction": DIRECTION}
    if not prepare(client, result):
        return result
    patches = find_patches(client, result)
    if not patches:
        result.update(ok=False, error={"kind": "setup", "text": "в 400 клетках от помощника нет открытых пятен руды (resources)"})
        return result
    picked = pick_patch(client, patches, LAYOUT, DIRECTION, result)
    if picked is None:
        result.update(ok=False, reasons=["сухой прогон plan_mining не встал ни на одном пятне"])
        return result
    patch, dry = picked
    dry_detail = detail_of(dry)
    result["patch"] = {"name": patch["name"], "center": patch["center"], "area": patch["area"], "tiles": patch.get("tiles"),
                       "dist": patch.get("dist"), "window": patch.get("window"), "clipped": patch.get("clipped")}
    result["dry"] = {"ghosts": dry_detail.get("ghosts"), "need": dry_detail.get("need"), "area": dry_detail.get("area"),
                     "chosen": dry_detail.get("chosen"), "warnings": dry_detail.get("warnings")}

    reasons = []
    # справка для контракта (на итог не влияет): что даёт отсыпка там, где раскладка легла на воду или лаву
    probe = act(client, "plan_mining", plan_args(patch, LAYOUT, DIRECTION, dry_run=True, extra={"options": {"landfill": True}}))
    pd = detail_of(probe)
    result["landfill_probe"] = {"kind": probe["kind"], "code": code_of(probe), "ghosts": pd.get("ghosts"),
                                "tiles": pd.get("tiles"), "skipped": pd.get("skipped"), "drills": pd.get("drills"),
                                "need": pd.get("need"), "warnings": pd.get("warnings")}

    dry_area_ok = bool(dry_detail.get("area")) and max(side(dry_detail["area"])) <= 128
    before = ghosts_in(client, dry_detail["area"]) if dry_area_ok else {}
    cells, _ = liquid_cells(client, dry_detail["area"]) if dry_area_ok else (set(), [])  # до разметки
    real = act(client, "plan_mining", plan_args(patch, LAYOUT, DIRECTION))
    result["plan"] = brief(real)
    detail = detail_of(real)
    if real["kind"] == "job_done":
        if detail.get("dry_run"):
            reasons.append("настоящий прогон ответил dry_run")
        if detail.get("ghosts") != dry_detail.get("ghosts"):
            reasons.append(f"призраков {detail.get('ghosts')}, а сухой прогон обещал {dry_detail.get('ghosts')}")
        if detail.get("need") != dry_detail.get("need"):
            reasons.append(f"need {detail.get('need')}, а сухой прогон обещал {dry_detail.get('need')}")
        if detail.get("warnings") != dry_detail.get("warnings"):
            reasons.append(f"предупреждения {detail.get('warnings')}, а сухой прогон обещал {dry_detail.get('warnings')}")
    verify(client, patch, before, real, result, reasons, direction=DIRECTION)
    if real["kind"] == "job_done":
        check_liquid_and_access(client, patch, detail, cells, result, reasons)

    if not reasons:
        again = act(client, "plan_mining", plan_args(patch, LAYOUT, DIRECTION))
        d2 = detail_of(again)
        result["repeat"] = {"kind": again["kind"], "code": code_of(again), "ghosts": d2.get("ghosts"),
                            "skipped": d2.get("skipped")}
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
