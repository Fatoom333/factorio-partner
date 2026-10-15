"""Сквозной сценарий «поставь добычу», путь «призраки уже стоят» (TESTING.md §4, docs/E2E.md).

Имитация рамки игрока (MPP / P.U.M.P. / чертёж): призраки маленького чертежа буров стоят на земле
ДО того, как у помощника появились предметы. Дальше — то, что делает агент по поручению:

1. `hello`, помощник (`helper_spawn`, пустой инвентарь). Какую ленту брать, решает склад базы
   (`find` по складам: первая лента, которая где-то лежит).
2. Место: свободное окно на руде (`resources` + `map`), подтверждённое `build_blueprint {dry_run}` —
   все 5 призраков встают без помех и сноса. Именно на руде: призрак бура на голой земле движок не
   ставит (`cannot_place`, замер 2.0.77), как и на руде, которую бур не добывает (вольфрам).
3. Призраки: тот же чертёж с `mode: "robots"`. Дронов у помощника нет, инвентарь пуст — призраки
   ставятся и остаются стоять (`no_items`), ничего не построено. Так на карте появляется ровно то, что
   оставил бы игрок рамкой.
4. `ghosts` по области: что нужно (`need`) — 2 бура и 3 ленты.
5. Предметы честно: `collect` со складов базы, поход к дальним складам, чего нет — сырьё и `craft`.
6. `build_ghosts {area, mode: "hand"}`.
7. Сверка с игрой: призраков в области 0; на карте 2 бура (лицом друг к другу) и 3 ленты; у помощника
   убыло ровно 2 бура и 3 ленты.
Только конверты `/partner <JSON>` через live_client; никаких /c, /sc, /silent-command.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
HELPER = "e2e"
MINER = "electric-mining-drill"
PAD = 5          # половина стороны области сверки вокруг якоря (чертёж 7×3)
SPOT = (9, 5)    # свободное окно под чертёж: 7×3 и клетка запаса с каждой стороны
MIN_ORE = 30     # руды в окне 9×5 — чтобы под обоими бурами она была наверняка
MAX_SPOTS = 8


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


E = _load("_e2e")


def find_spot(api, blob, total, log, steps):
    """Якорь на руде, где сухой прогон ставит все total призраков без помех и сноса.

    Кандидаты — свободные окна на руде (чертёж 7×3 и клетка запаса вокруг): бур ставится только на
    руду, которую он добывает. Руда, на которой буры не встали дважды, отбрасывается (вольфрам).
    → (якорь, имя руды) | (None, None)."""
    bad, fails = set(), {}
    for win in E.ore_candidates(api, steps, SPOT[0], SPOT[1], min_ore=MIN_ORE, bad=bad):
        if len(log) >= MAX_SPOTS:
            break
        ore = win["patch"]["name"]
        anchor = E.area_center(win["area"])
        r = api.act("build_blueprint", {"blob": blob, "anchor": anchor, "dry_run": True})
        d = E.detail_of(r)
        why = [{"name": s.get("name"), "reason": s.get("reason")} for s in E.as_list(d.get("skipped"))[:5]]
        log.append({"anchor": anchor, "ore": ore, "kind": r["kind"], "code": E.code_of(r), "ghosts": d.get("ghosts"),
                    "skipped": d.get("skipped_total"), "to_remove": d.get("to_remove_total"), "why": why})
        if (r["kind"] == "job_done" and d.get("ghosts") == total and not d.get("skipped_total")
                and not d.get("to_remove_total") and not E.as_map(d.get("tiles"))):
            return anchor, ore
        if r["kind"] not in ("job_done", "job_failed"):
            break         # задача не завершилась или не принята — дальше пробовать нет смысла
        fails[ore] = fails.get(ore, 0) + 1
        if fails[ore] >= 2:
            bad.add(ore)
    return None, None


def standing(api, anchor, names):
    """Готовые постройки с такими именами в области сверки (PAD вокруг якоря). → [сущности карты]."""
    built, _, _ = E.on_map(api, names, anchor, PAD + 2)
    return [e for e in built if abs(e["pos"]["x"] - anchor["x"]) <= PAD and abs(e["pos"]["y"] - anchor["y"]) <= PAD]


def spot_of(e):
    return (e["name"], e["pos"]["x"], e["pos"]["y"])


def verify(api, anchor, area, miner, belt, was, before, result, reasons):
    """was — постройки, стоявшие в области до сценария (рядом может быть чужая добыча): новое — всё остальное."""
    left = api.read("ghosts", {"area": area})
    result["ghosts_left"] = left.get("count")
    if left.get("count") != 0:
        reasons.append(f"в области осталось призраков: {left.get('count')}")
    _, ghosts, _ = E.on_map(api, [miner, belt], anchor, PAD + 2)
    inside = [e for e in standing(api, anchor, [miner, belt]) if spot_of(e) not in was]
    drills = sorted((e for e in inside if e["name"] == miner), key=lambda e: e["pos"]["x"])
    belts = [e for e in inside if e["name"] == belt]
    result["on_map"] = {"drills": [{"pos": e["pos"], "dir": e.get("dir")} for e in drills], "belts": len(belts),
                        "ghosts": len(ghosts)}
    if len(drills) != 2:
        reasons.append(f"буров на карте {len(drills)}, а не 2")
    elif [e.get("dir") for e in drills] != [4, 12]:
        reasons.append(f"буры смотрят в {[e.get('dir') for e in drills]}, а должны друг на друга (4 и 12)")
    elif abs((drills[1]["pos"]["x"] - drills[0]["pos"]["x"]) - 4) > 0.01 or drills[0]["pos"]["y"] != drills[1]["pos"]["y"]:
        reasons.append(f"буры стоят не как в чертеже: {result['on_map']['drills']}")
    if len(belts) != 3:
        reasons.append(f"лент на карте {len(belts)}, а не 3")
    after = E.inventory(api)
    result["inventory"] = {"before": {miner: before.get(miner, 0), belt: before.get(belt, 0)},
                           "after": {miner: after.get(miner, 0), belt: after.get(belt, 0)}}
    for item, n in ((miner, 2), (belt, 3)):
        spent = before.get(item, 0) - after.get(item, 0)
        if spent != n:
            reasons.append(f"у помощника убыло {item}: {spent}, а не {n}")


def run(client) -> dict:
    result = {"scenario": "e2e_ghosts"}
    api = E.api_for(client)
    if not E.start(api, result):
        return result
    log = []
    result["steps"] = log
    belt = E.pick_available(api, E.BELTS, log, "belt")
    if belt is None:
        return E.fail_setup(result, "на складах базы нет ни одной ленты и рецепт сценарию неизвестен")
    result["chosen"] = {"miner": MINER, "belt": belt}
    entities = E.drill_pair_blueprint(MINER, belt)
    blob = E.put_blob(client, E.encode_blueprint(entities), "e2eg")

    empty = E.inventory(api)
    if empty.get(MINER) or empty.get(belt):
        return E.fail_setup(result, "у помощника уже есть предметы чертежа — призраки нельзя оставить непостроенными")
    dry = []
    result["dry_run"] = dry
    anchor, ore = find_spot(api, blob, len(entities), dry, log)
    if anchor is None:
        result.update(ok=False, reasons=["нет свободного места на руде под чертёж 7×3 (карта и dry_run): "
                                         f"{dry[-1] if dry else 'на карте нет свободных окон на руде'}"])
        return result
    result.update(anchor=anchor, ore=ore)
    was = {spot_of(e) for e in standing(api, anchor, [MINER, belt])}     # чужая добыча по соседству
    result["stood_before"] = len(was)
    area = E.area_around(anchor, PAD)
    reasons = []

    # имитация рамки игрока: призраки стоят, строить их нечем
    r = api.act("build_blueprint", {"blob": blob, "anchor": anchor, "mode": "robots"})
    result["place_ghosts"] = E.brief(r)
    seen = api.read("ghosts", {"area": area})
    result["ghosts_op"] = {"count": seen.get("count"), "need": seen.get("need"), "blocked_total": seen.get("blocked_total")}
    want = {MINER: 2, belt: 3}
    if seen.get("count") != len(entities):
        reasons.append(f"призраков в области {seen.get('count')}, а чертёж — {len(entities)} ({E.code_of(r)})")
        return E.finish(result, reasons)
    if E.as_map(seen.get("need")) != want:
        reasons.append(f"ghosts.need = {seen.get('need')}, а чертёж — {want}")
    if {spot_of(e) for e in standing(api, anchor, [MINER, belt])} != was:
        reasons.append("постановка призраков что-то построила — имитация рамки игрока не чистая")

    missing, notes = E.obtain(api, want, log)
    if missing:
        result["missing"] = missing
        result["missing_detail"] = notes
        reasons.append(f"не удалось честно добыть предметы: {missing}")
        return E.finish(result, reasons)
    before = E.inventory(api)

    r = api.act("build_ghosts", {"area": area, "mode": "hand"}, 240.0)
    result["build"] = E.brief(r)
    d = E.detail_of(r)
    if r["kind"] != "job_done":
        reasons.append(f"build_ghosts не done: {E.code_of(r)} {E.text_of(r)}")
    else:
        if d.get("built") != len(entities):
            reasons.append(f"built = {d.get('built')}, а не {len(entities)}")
        if d.get("left"):
            reasons.append(f"left = {d.get('left')}")
    verify(api, anchor, area, MINER, belt, was, before, result, reasons)
    return E.finish(result, reasons)
