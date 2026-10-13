"""Сквозной сценарий «поставь добычу», путь `plan_mining` + `plan_belt` (поток V4, TESTING.md §4, docs/E2E.md).

Помощник сам размечает руду (раскладки MPP), ведёт от неё ленту (`plan_belt`), собирает предметы и строит:

1. `hello`, помощник. Бур, лента и столб выбираются по складам базы (`find`): что где-то лежит, а
   чего нет — то, что сценарий умеет скрафтить из сырья со складов.
2. Руда: `resources` по именам руд вокруг помощника и кольцами дальше; на карте (`map`) пятна ищется
   свободное окно — только земля и руда, без построек и жидкости. Окно маленькое, чтобы на буры хватило
   ручного крафта: поручение целиком на всё пятно — это сотни буров, их честно не собрать за один прогон.
   Руда, которую выбранный бур не берёт (вольфрам — только большим буром), отбрасывается.
3. `plan_mining {resource, area, layout: "simple", miner, belt, pole, dry_run}` — сколько чего нужно
   (`need`); окна перебираются, пока раскладка не встанет без пропусков и не слишком большой.
4. `access {area}` — суша и выходы с участка: остров без выходов (`enclosed`) сценарий не размечает.
5. Та же разметка без `dry_run` — призраки стоят (сила хозяина); ленты разметки смотрят в заданную сторону.
6. Лента от добычи: `plan_belt {from: "patch", to, belt, underground: "never", dry_run}` до свободной
   площадки за краем разметки, потом без `dry_run` — призраки ленты стоят.
7. Предметы честно (на разметку и на ленту): `collect` со складов, поход к дальним складам, чего нет —
   сырьё и `craft`.
8. `build_ghosts {area, mode: "hand"}` по области разметки, потом по области (или кускам) ленты.
9. Сверка с игрой: призраков в областях 0; буров на карте столько, сколько обещала разметка; каждый
   бур достаёт хотя бы до одной клетки руды; буры покрывают руду окна (доля); предметов убыло ровно
   `need` разметки и ленты; **лента непрерывна** — от каждой ленты разметки и от каждой клетки
   проложенной ленты предмет доезжает до конечной точки.
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
MAX_BELT = 64                        # длиннее ленту за прогон честно не собрать и не построить
MAX_BELT_TRIES = 4                   # сколько концов ленты пробовать сухим прогоном
PLAN_TIMEOUT_S = 90.0
BELT_TIMEOUT_S = 120.0
BUILD_TIMEOUT_S = 420.0
# предупреждения plan_belt, при которых не все выходы разметки сведены в одну ленту (ACTIONS.md)
UNMERGED = ("unmerged_outputs", "not_bundled")


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


def belt_args(to, chosen, dry_run=False):
    args = {"from": "patch", "to": E.cell_center(to), "belt": chosen["belt"], "underground": "never"}
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


def look_at_access(api, win, result, reasons):
    """`access` по окну разметки: суша, жидкость, выходы. → можно ли размечать (не остров)."""
    r = api.try_read("access", {"area": win["area"]})
    if not r["ok"]:
        result["access"] = {"error": r["error"]}
        reasons.append(f"access по окну разметки отказал: {r['error'].get('code')} {r['error'].get('text')}")
        return False
    d = r["data"]
    exits = E.as_list(d.get("exits"))
    result["access"] = {"land": d.get("land"), "liquid": d.get("liquid"), "liquids": E.as_map(d.get("liquids")),
                        "enclosed": d.get("enclosed"), "best": d.get("best"), "reachable": d.get("reachable"),
                        "exits": [{"side": e.get("side"), "width": e.get("width"), "neck": e.get("neck")}
                                  for e in exits], "warnings": E.as_list(d.get("warnings"))}
    if not isinstance(d.get("enclosed"), bool) or not isinstance(d.get("land"), int):
        reasons.append(f"ответ access не по контракту: {result['access']}")
        return False
    if d["enclosed"] or not exits:
        reasons.append("у окна разметки нет выходов (enclosed): ленту не вывести, сценарий здесь не размечает")
        return False
    return True


def plan_route(api, chosen, area, resource, log, result, reasons):
    """Лента от выходов разметки до свободной площадки за её краем: сухие прогоны по нескольким концам,
    потом настоящий. → (клетка конца, detail, ленты на пути до прокладки) | None."""
    tries = []
    result["belt_dry_run"] = tries
    picked = None
    for to in E.belt_targets(api, area, DIRECTION, log, MAX_BELT_TRIES, resource):
        r = api.act("plan_belt", belt_args(to, chosen, dry_run=True), BELT_TIMEOUT_S)
        d = E.detail_of(r)
        need = E.as_map(d.get("need"))
        tries.append({"to": list(to), "kind": r["kind"], "code": E.code_of(r), "text": E.text_of(r),
                      "ghosts": d.get("ghosts"), "length": d.get("length"), "need": need or None,
                      "warnings": E.as_list(d.get("warnings")), "skipped": d.get("skipped")})
        if r["kind"] not in ("job_done", "job_failed"):
            break                        # задача не принята или не завершилась — другие концы не помогут
        if (r["kind"] == "job_done" and 0 < (d.get("ghosts") or 0) <= MAX_BELT and not d.get("skipped")
                and set(need) == {chosen["belt"]}):
            picked = (to, d)
            break
    if picked is None:
        reasons.append("plan_belt (dry_run) не проложил ленту от разметки ни к одной свободной площадке "
                       f"(пробовал {len(tries)})")
        return None
    to, dry = picked
    # ленты, которые уже стоят там, где пройдёт новая (постройки базы): в сверку они не идут
    old = E.belt_cells(api, belt_areas(dry), [chosen["belt"]])[0] if dry.get("area") else {}
    result["belts_before"] = len(old)
    real = api.act("plan_belt", belt_args(to, chosen), BELT_TIMEOUT_S)
    result["belt_plan"] = E.brief(real)
    d = E.detail_of(real)
    if real["kind"] != "job_done":
        reasons.append(f"plan_belt не done: {E.code_of(real)} {E.text_of(real)}")
        return None
    if d.get("dry_run"):
        reasons.append("настоящий plan_belt ответил dry_run")
    if (d.get("ghosts"), E.as_map(d.get("need"))) != (dry.get("ghosts"), E.as_map(dry.get("need"))):
        reasons.append(f"лента разошлась с сухим прогоном: {d.get('ghosts')} / {d.get('need')} против "
                       f"{dry.get('ghosts')} / {dry.get('need')}")
    if sum(E.as_map(d.get("need")).values()) != d.get("ghosts"):
        reasons.append(f"need ленты {d.get('need')} не сходится с числом призраков {d.get('ghosts')}")
    if not d.get("area"):
        reasons.append("в ответе plan_belt нет area")
        return None
    return to, d, old


def belt_areas(detail):
    """Области для `build_ghosts`: куски `areas` длинной ленты или одна `area` (ACTIONS.md «plan_belt»)."""
    return E.as_list(detail.get("areas")) or [detail["area"]]


def verify_belt(api, chosen, mining, route, to, mining_belts, old, result, reasons):
    """Лента непрерывна: от каждой ленты разметки и от каждой клетки проложенной ленты предмет
    доезжает до конечной точки `to` (по построенным лентам, как их видит игра). `old` — ленты,
    стоявшие на пути до прокладки: проложенными они не считаются."""
    cells, truncated = E.belt_cells(api, [mining["area"]] + belt_areas(route), [chosen["belt"]])
    built = {c: b for c, b in cells.items() if not b["ghost"]}
    info = {"to": list(to), "on_map": len(built), "truncated": truncated, "length": route.get("length")}
    result["belt"] = info
    if truncated:
        reasons.append("карта обрезала список лент — сверка непрерывности неполная")
    if to not in built:
        reasons.append(f"в конечной точке ленты {list(to)} ленты нет")
        return
    laid = [c for c in built if c not in mining_belts and c not in old]
    lost = [c for c in laid if not E.flows_to(built, c, to)[0]]
    info.update(laid=len(laid), laid_lost=[list(c) for c in lost[:5]])
    if len(laid) != route.get("ghosts"):
        reasons.append(f"проложенных лент на карте {len(laid)}, а plan_belt сообщил {route.get('ghosts')}")
    if lost:
        reasons.append(f"лента рвётся: с {len(lost)} её клеток до конца не доехать, первая — {list(lost[0])}")
    cut = [c for c in mining_belts if c not in built or not E.flows_to(built, c, to)[0]]
    info.update(mining_belts=len(mining_belts), mining_cut=[list(c) for c in cut[:5]])
    warnings = E.as_list(route.get("warnings"))
    partly = any(str(w).split(":")[0] in UNMERGED for w in warnings)
    if cut and (not partly or len(cut) == len(mining_belts)):
        reasons.append(f"лента разметки не соединена с проложенной: с {len(cut)} из {len(mining_belts)} её "
                       f"клеток до конца не доехать, первая — {list(cut[0])}")


def verify(api, win, detail, chosen, before, need, result, reasons):
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
    names = [chosen["miner"], chosen["pole"]]
    built, _, truncated = E.on_map(api, names, center, radius)

    def inside(e):
        return (area["left_top"]["x"] - 1 <= e["pos"]["x"] <= area["right_bottom"]["x"] + 1
                and area["left_top"]["y"] - 1 <= e["pos"]["y"] <= area["right_bottom"]["y"] + 1)

    built = [e for e in built if inside(e)]
    drills = [e for e in built if e["name"] == chosen["miner"]]
    result["on_map"] = {"drills": len(drills), "poles": sum(1 for e in built if e["name"] == chosen["pole"]),
                        "truncated": truncated}
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

    after = E.inventory(api)
    spent = {k: before.get(k, 0) - after.get(k, 0) for k in need}
    result["inventory"] = {"need": need, "spent": spent}
    if spent != need:
        reasons.append(f"у помощника убыло {spent}, а разметке и ленте нужно {need}")


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
    if not look_at_access(api, win, result, reasons):
        return E.finish(result, reasons)

    real = api.act("plan_mining", plan_args(win, chosen), PLAN_TIMEOUT_S)
    result["plan"] = E.brief(real)
    detail = E.detail_of(real)
    if real["kind"] != "job_done":
        reasons.append(f"plan_mining не done: {E.code_of(real)} {E.text_of(real)}")
        return E.finish(result, reasons)
    need = dict(E.as_map(detail.get("need")))
    if need != E.as_map(dry_detail.get("need")) or detail.get("ghosts") != dry_detail.get("ghosts"):
        reasons.append(f"разметка разошлась с сухим прогоном: {detail.get('ghosts')} / {need} против "
                       f"{dry_detail.get('ghosts')} / {dry_detail.get('need')}")
    seen = api.read("ghosts", {"area": detail["area"]}) if detail.get("area") else {}
    result["ghosts_op"] = {"count": seen.get("count"), "need": seen.get("need"), "blocked_total": seen.get("blocked_total")}
    if seen.get("count") != detail.get("ghosts"):
        reasons.append(f"операция ghosts видит {seen.get('count')} призраков, а разметка сообщила {detail.get('ghosts')}")
    if not detail.get("area"):
        reasons.append("в ответе plan_mining нет area")
        return E.finish(result, reasons)

    # ленты разметки — до прокладки: куда смотрят и где стоят (потом от них сверяется непрерывность)
    cells, _ = E.belt_cells(api, [detail["area"]], [chosen["belt"]])
    mining_belts = {c: b for c, b in cells.items() if b["ghost"]}
    dirs = sorted({b.get("dir") for b in mining_belts.values()})
    result["belt_dirs"] = dirs
    if mining_belts and dirs != [E.DIR_NUM[DIRECTION]]:
        reasons.append(f"лента разметки смотрит в {dirs}, а не в {E.DIR_NUM[DIRECTION]} ({DIRECTION})")

    planned = plan_route(api, chosen, detail["area"], win["patch"]["name"], log, result, reasons)
    if planned is None:
        return E.finish(result, reasons)
    to, route, old = planned
    for item, n in E.as_map(route.get("need")).items():
        need[item] = need.get(item, 0) + n

    missing, notes = E.obtain(api, need, log)
    if missing:
        result["missing"] = missing
        result["missing_detail"] = notes
        reasons.append(f"не удалось честно добыть предметы: {missing}")
        return E.finish(result, reasons)
    before = E.inventory(api)

    built_total = 0
    builds = []
    result["build"] = builds
    for area in [detail["area"]] + belt_areas(route):
        r = api.act("build_ghosts", {"area": area, "mode": "hand"}, BUILD_TIMEOUT_S)
        d = E.detail_of(r)
        builds.append(dict(E.brief(r), area=area))
        if r["kind"] != "job_done":
            reasons.append(f"build_ghosts не done: {E.code_of(r)} {E.text_of(r)}")
            break
        built_total += d.get("built") or 0
        if d.get("left"):
            reasons.append(f"после build_ghosts в области осталось призраков: {d.get('left')}")
    expected = (detail.get("ghosts") or 0) + (route.get("ghosts") or 0)
    result["built"] = {"total": built_total, "expected": expected}
    if built_total != expected:
        reasons.append(f"построено {built_total}, а призраков разметки и ленты было {expected}")
    for area in belt_areas(route):
        left = api.read("ghosts", {"area": area})
        if left.get("count"):
            reasons.append(f"в области ленты осталось призраков: {left.get('count')}")
    verify(api, win, detail, chosen, before, need, result, reasons)
    verify_belt(api, chosen, detail, route, to, mining_belts, old, result, reasons)
    return E.finish(result, reasons)
