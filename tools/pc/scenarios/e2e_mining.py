"""Сквозной сценарий «поставь добычу», путь `plan_mining` (поток K, TESTING.md §4, docs/E2E.md).

Помощник сам размечает руду (раскладки MPP, поток M), собирает предметы и строит:

1. `hello`, помощник. Бур, лента и столб выбираются по складам базы (`find`): что где-то лежит, а
   чего нет — то, что сценарий умеет скрафтить из сырья со складов.
2. Руда: `resources` по именам руд вокруг помощника и кольцами дальше; на карте (`map`) пятна ищется
   свободное окно — только земля и руда, без построек. Окно маленькое, чтобы на буры хватило ручного
   крафта: поручение целиком на всё пятно — это сотни буров, их честно не собрать за один прогон.
   Руда, которую выбранный бур не берёт (вольфрам — только большим буром), отбрасывается.
3. `plan_mining {resource, area, layout: "simple", miner, belt, pole, dry_run}` — сколько чего нужно
   (`need`); окна перебираются, пока раскладка не встанет без пропусков и не слишком большой.
4. Та же команда без `dry_run` — призраки стоят (сила хозяина).
5. Предметы честно: `collect` со складов, поход к дальним складам, чего нет — сырьё и `craft`.
6. `build_ghosts {area: detail.area, mode: "hand"}` — помощник сам идёт к руде и строит.
7. Сверка с игрой («покрытие»): призраков в области 0; буров на карте столько, сколько обещала
   разметка; каждый бур достаёт хотя бы до одной клетки руды; буры покрывают руду окна (доля);
   предметов убыло ровно `need`; ленты смотрят в заданную сторону.
Только конверты `/partner <JSON>` через live_client; никаких /c, /sc, /silent-command.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
HELPER = "e2e"
LAYOUT = "simple"
DIRECTION = "north"
WINDOWS = ((9, 9), (8, 7), (7, 7))   # размеры окна разметки: от большего к меньшему
MAX_DRILLS = 6                       # больше руками за прогон не скрафтить и не донести
MAX_PATCHES = 5                      # сколько ближних пятен смотреть за один проход поиска
MAX_DRY_RUNS = 16
MIN_COVER = 0.6                      # доля клеток руды окна под бурами
PLAN_TIMEOUT_S = 90.0
BUILD_TIMEOUT_S = 420.0


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


E = _load("_e2e")


def plan_args(win, chosen, dry_run=False):
    args = {"resource": win["patch"]["name"], "area": win["area"], "layout": LAYOUT, "direction": DIRECTION,
            "miner": chosen["miner"], "belt": chosen["belt"], "pole": chosen["pole"]}
    if dry_run:
        args["dry_run"] = True
    return args


def unfit(r):
    """Мод сказал, что эту руду выбранным буром не взять (вольфрам — только большим, жидкости)."""
    text = str(E.text_of(r) or "")
    return E.code_of(r) == "bad_args" and ("can't mine" in text or "not a solid ore" in text)


def pick_window(api, chosen, log, tries, result):
    """Пятно и окно, где сухой прогон даёт раскладку без пропусков и не больше MAX_DRILLS буров.
    Руда, которую выбранный бур не добывает, отбрасывается целиком, поиск идёт дальше.
    → (окно, итог сухого прогона) | None."""
    skip = []
    result["ore_skipped"] = skip
    found_any = False
    for _ in range(len(E.ORE_NAMES)):
        patches = E.find_ore(api, log, [n for n in E.ORE_NAMES if n not in skip])
        if not patches:
            break
        found_any = True
        before = len(skip)
        for patch in patches[:MAX_PATCHES]:
            if patch["name"] in skip:
                continue
            for w, h in WINDOWS:
                if len(tries) >= MAX_DRY_RUNS or patch["name"] in skip:
                    break
                for win in E.patch_windows(api, patch, w, h, log, limit=2):
                    r = api.act("plan_mining", plan_args(win, chosen, dry_run=True), PLAN_TIMEOUT_S)
                    d = E.detail_of(r)
                    tries.append({"resource": patch["name"], "window": win["area"], "ore": win["ore"],
                                  "kind": r["kind"], "code": E.code_of(r), "text": E.text_of(r),
                                  "ghosts": d.get("ghosts"), "drills": d.get("drills"), "skipped": d.get("skipped"),
                                  "need": d.get("need"), "warnings": d.get("warnings")})
                    if r["kind"] not in ("job_done", "job_failed"):
                        return None      # задача не завершилась или не принята — дальше пробовать нет смысла
                    if unfit(r):
                        skip.append(patch["name"])
                        break
                    if (r["kind"] == "job_done" and 0 < (d.get("drills") or 0) <= MAX_DRILLS
                            and not d.get("skipped") and not d.get("tiles") and E.as_map(d.get("need"))):
                        return win, r
        if len(skip) == before:
            break                        # новых негодных руд нет — искать дальше нечего
    result["ore_found"] = found_any
    return None


def verify(api, win, detail, chosen, before, result, reasons):
    area = detail.get("area")
    if not area or max(E.area_side(area)) > 64:
        reasons.append(f"detail.area нет или она слишком большая: {area}")
        return
    left = api.read("ghosts", {"area": area})
    result["ghosts_left"] = left.get("count")
    if left.get("count") != 0:
        reasons.append(f"в области осталось призраков: {left.get('count')}")
    center = E.area_center(area)
    radius = max(E.area_side(area)) / 2 + 2
    names = [chosen["miner"], chosen["belt"], chosen["pole"]]
    built, _, truncated = E.on_map(api, names, center, radius)

    def inside(e):
        return (area["left_top"]["x"] - 1 <= e["pos"]["x"] <= area["right_bottom"]["x"] + 1
                and area["left_top"]["y"] - 1 <= e["pos"]["y"] <= area["right_bottom"]["y"] + 1)

    built = [e for e in built if inside(e)]
    drills = [e for e in built if e["name"] == chosen["miner"]]
    belts = [e for e in built if e["name"] == chosen["belt"]]
    result["on_map"] = {"drills": len(drills), "belts": len(belts),
                        "poles": sum(1 for e in built if e["name"] == chosen["pole"]), "truncated": truncated}
    if len(drills) != detail.get("drills"):
        reasons.append(f"буров на карте {len(drills)}, а разметка обещала {detail.get('drills')}")

    # покрытие: клетки руды окна сняты с карты ДО постановки призраков
    cells = E.ore_cells(win["map"], win["patch"]["name"])
    a = win["area"]
    cells = {(x, y) for (x, y) in cells
             if a["left_top"]["x"] <= x < a["right_bottom"]["x"] and a["left_top"]["y"] <= y < a["right_bottom"]["y"]}
    reach = E.MINING_REACH.get(chosen["miner"])
    if reach is None:
        result["coverage"] = {"skipped": f"область добычи бура {chosen['miner']} сценарию неизвестна"}
    else:
        off_ore = [e["pos"] for e in drills if not E.drill_on_ore(e["pos"], reach, cells)]
        share = E.covered_share([e["pos"] for e in drills], reach, cells)
        result["coverage"] = {"ore_cells": len(cells), "covered_share": share, "drills_off_ore": off_ore,
                              "min_share": MIN_COVER}
        if off_ore:
            reasons.append(f"буры без руды в области добычи: {off_ore}")
        if share < MIN_COVER:
            reasons.append(f"буры покрывают {share:.0%} клеток руды окна, меньше {MIN_COVER:.0%}")
    dirs = sorted({e.get("dir") for e in belts})
    result["belt_dirs"] = dirs
    if belts and dirs != [E.DIR_NUM[DIRECTION]]:
        reasons.append(f"лента смотрит в {dirs}, а не в {E.DIR_NUM[DIRECTION]} ({DIRECTION})")

    after = E.inventory(api)
    need = E.as_map(detail.get("need"))
    spent = {k: before.get(k, 0) - after.get(k, 0) for k in need}
    result["inventory"] = {"need": need, "spent": spent}
    if spent != need:
        reasons.append(f"у помощника убыло {spent}, а разметке нужно {need}")


def run(client) -> dict:
    result = {"scenario": "e2e_mining", "layout": LAYOUT, "direction": DIRECTION}
    api = E.api_for(client)
    if not E.start(api, result):
        return result
    log = []
    result["steps"] = log
    chosen = {"miner": E.pick_available(api, E.MINERS, log, "miner"),
              "belt": E.pick_available(api, E.BELTS, log, "belt"),
              "pole": E.pick_available(api, E.POLES, log, "pole")}
    result["chosen"] = chosen
    lacking = [k for k, v in chosen.items() if v is None]
    if lacking:
        return E.fail_setup(result, f"на складах базы нет и скрафтить нечем: {lacking}")

    tries = []
    result["dry_run"] = tries
    picked = pick_window(api, chosen, log, tries, result)
    if picked is None:
        if result.get("ore_found") is False:
            return E.fail_setup(result, "в 400 клетках от помощника нет открытых пятен твёрдой руды (resources)")
        result.update(ok=False, reasons=["plan_mining (dry_run) не встал ни в одном свободном окне на руде, "
                                         f"которую добывает {chosen['miner']} (отброшено: {result['ore_skipped']})"])
        return result
    win, dry = picked
    dry_detail = E.detail_of(dry)
    result["patch"] = {"name": win["patch"]["name"], "center": win["patch"]["center"], "tiles": win["patch"].get("tiles"),
                       "dist": win["patch"].get("dist"), "window": win["area"], "ore_in_window": win["ore"]}
    reasons = []

    real = api.act("plan_mining", plan_args(win, chosen), PLAN_TIMEOUT_S)
    result["plan"] = E.brief(real)
    detail = E.detail_of(real)
    if real["kind"] != "job_done":
        reasons.append(f"plan_mining не done: {E.code_of(real)} {E.text_of(real)}")
        return E.finish(result, reasons)
    need = E.as_map(detail.get("need"))
    if need != E.as_map(dry_detail.get("need")) or detail.get("ghosts") != dry_detail.get("ghosts"):
        reasons.append(f"разметка разошлась с сухим прогоном: {detail.get('ghosts')} / {need} против "
                       f"{dry_detail.get('ghosts')} / {dry_detail.get('need')}")
    seen = api.read("ghosts", {"area": detail["area"]}) if detail.get("area") else {}
    result["ghosts_op"] = {"count": seen.get("count"), "need": seen.get("need"), "blocked_total": seen.get("blocked_total")}
    if seen.get("count") != detail.get("ghosts"):
        reasons.append(f"операция ghosts видит {seen.get('count')} призраков, а разметка сообщила {detail.get('ghosts')}")

    missing, notes = E.obtain(api, need, log)
    if missing:
        result["missing"] = missing
        result["missing_detail"] = notes
        reasons.append(f"не удалось честно добыть предметы: {missing}")
        return E.finish(result, reasons)
    before = E.inventory(api)

    r = api.act("build_ghosts", {"area": detail["area"], "mode": "hand"}, BUILD_TIMEOUT_S)
    result["build"] = E.brief(r)
    d = E.detail_of(r)
    if r["kind"] != "job_done":
        reasons.append(f"build_ghosts не done: {E.code_of(r)} {E.text_of(r)}")
    elif d.get("built") != detail.get("ghosts") or d.get("left"):
        reasons.append(f"построено {d.get('built')} из {detail.get('ghosts')}, осталось {d.get('left')}")
    verify(api, win, detail, chosen, before, result, reasons)
    return E.finish(result, reasons)
