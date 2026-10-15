"""Живой сценарий: маленький чертёж частично на плитке без опоры (лава, вода).

Зачем (docs/ACTIONS.md («build_blueprint»), PROTOCOL §6.12): если хоть под одной клеткой чертежа нет возможной
подложки (фундамент открывается в конце игры), чертёж не ставится вовсе — мод отвечает
`cannot_place` с `on_liquid`, `liquids` и `fit` (ближайший сдвиг, при котором чертёж встаёт целиком).
Обрезанный чертёж — только с `partial:true`.

Ход:
1. Помощник, сундуки честно со складов хозяина (как build_place).
2. Берег: по `map` ищется клетка жидкости (`~`), у которой сосед слева или справа — суша; чертёж из
   двух сундуков в ряд ставится серединой на границу. Место принимается, когда оценка (`dry_run`)
   говорит: одна клетка на жидкости, вторая постройка встаёт, сносить нечего.
3. `dry_run` — без ошибки: `on_liquid` = 1, `liquids` = {плитка: 1}, `fit` со сдвигом.
4. Без `partial` — `job_failed{cannot_place}` с теми же `on_liquid`, `liquids`, `fit`; в мире не
   появилось ни призраков, ни построек.
5. `rotate:true` — перебор поворотов и зеркала работает: оценка с `rotate` на малом радиусе отвечает
   без ошибки, `fit` (если нашёлся) несёт `direction` и `mirror`, а оценка в этом положении
   подтверждает: клеток на жидкости нет, ничего не пропущено.
6. Постановка по `fit` (`anchor` из ответа) — чертёж встаёт целиком: `built` = 2, оба сундука на карте.
   Потом сундуки разбираются (`deconstruct{area, filter}`), чтобы не мешать шагу 7.
7. `partial:true` на исходном месте — обрезанный чертёж: `ghosts` = 1, `built` = 1, клетка на
   жидкости — в `skipped` с `reason: "liquid"`.
Имён плиток в сценарии нет: какая жидкость — говорит сам мод в `liquids`.
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
ITEM_COUNT = 3              # два на постановку по fit, один запасной
MAX_SHORES = 16             # столько мест на берегу пробуем оценкой
ROTATE_SEARCH = 2           # радиус поиска в замере rotate
BUILD_TIMEOUT_S = 240.0
BAD_CODES = ("internal", "bad_args", "limit")


def shores(lava):
    """Места на берегу: [(anchor, клетка жидкости, клетка суши)] — чертёж 1×2 серединой на границе."""
    cells = {(c["x"], c["y"]) for c in lava}
    out = []
    for c in lava:
        for side in (1, -1):
            if (c["x"] + side, c["y"]) not in cells:
                out.append(({"x": c["x"] + side * 0.5, "y": c["y"]}, {"x": c["x"], "y": c["y"]},
                            {"x": c["x"] + side, "y": c["y"]}))
    return out


def box(anchor, r=2.5):
    return {"left_top": {"x": anchor["x"] - r, "y": anchor["y"] - r},
            "right_bottom": {"x": anchor["x"] + r, "y": anchor["y"] + r}}


def step(client, blob, anchor, timeout=BUILD_TIMEOUT_S, **extra):
    r = P.act(client, "build_blueprint", dict({"blob": blob, "anchor": anchor}, **extra), timeout)
    return {"args": dict(extra, anchor=anchor), "kind": r["kind"], "code": P.code_of(r), "seconds": r["seconds"],
            "detail": P.detail_of(r), "text": (r.get("data") or {}).get("text")}


def world(client, item, anchor):
    """Что стоит вокруг точки: призраки и постройки чертежа."""
    ghosts = client.call_ok("ghosts", {"area": box(anchor)}, P.HELPER)
    built = sum(len(P.entities_at(client, item, {"x": anchor["x"] + dx, "y": anchor["y"]})) for dx in (-0.5, 0.5))
    return {"ghosts": ghosts.get("count"), "built": built}


def liquid_total(detail):
    liquids = detail.get("liquids")
    return sum(liquids.values()) if isinstance(liquids, dict) else None


def find_shore(client, blob, lava, result):
    """Первое место на берегу, где оценка видит ровно одну клетку на жидкости. → (anchor, суша, оценка)."""
    log = []
    for anchor, wet, dry_cell in shores(lava)[:MAX_SHORES]:
        s = step(client, blob, anchor, dry_run=True)
        d = s["detail"]
        log.append({"anchor": anchor, "kind": s["kind"], "code": s["code"], "on_liquid": d.get("on_liquid"),
                    "ghosts": d.get("ghosts"), "skipped": d.get("skipped_total"), "to_remove": d.get("to_remove_total")})
        if (s["kind"] == "job_done" and d.get("on_liquid") == 1 and d.get("ghosts") == 1
                and d.get("skipped_total") == 1 and not d.get("to_remove_total")):
            result["shore_tries"] = log
            return anchor, dry_cell, s
        if s["kind"] is None or s["code"] in BAD_CODES:
            break
    result["shore_tries"] = log
    return None, None, None


def check_fit(fit, rotate):
    """Форма `fit`: {anchor, shift:{dx,dy}, direction?, mirror?}. → список замечаний."""
    out = []
    if not isinstance(fit, dict):
        return [f"fit не объект: {fit}"]
    a, sh = fit.get("anchor"), fit.get("shift")
    if not (isinstance(a, dict) and isinstance(a.get("x"), (int, float)) and isinstance(a.get("y"), (int, float))):
        out.append(f"fit.anchor: {a}")
    if not (isinstance(sh, dict) and isinstance(sh.get("dx"), int) and isinstance(sh.get("dy"), int)):
        out.append(f"fit.shift: {sh}")
    if rotate:
        if fit.get("direction") not in (0, 4, 8, 12):
            out.append(f"fit.direction: {fit.get('direction')}")
        if not isinstance(fit.get("mirror"), bool):
            out.append(f"fit.mirror: {fit.get('mirror')}")
    return out


def fit_args(fit):
    """Аргументы постановки «по fit»."""
    args = {}
    if "direction" in fit:
        args["direction"] = fit["direction"]
    if fit.get("mirror"):
        args["mirror"] = True
    return args


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    item = P.get_chests(client, result, ITEM_COUNT)
    if item is None:
        return P.setup_failed(result, f"не удалось добыть {ITEM_COUNT} сундука (склады хозяина, крафт)")
    result["item"] = item
    around = P.survey(client, result)
    if not around["lava"]:
        return P.setup_failed(result, "рядом с помощником нет воды и лавы — проверить нечем")
    blob = G.new_blob(client, G.blueprint_string(item, 2), "liquid")
    anchor, dry_cell, dry = find_shore(client, blob, around["lava"], result)
    if anchor is None:
        result.update(ok=False, reasons=["не нашлось места на берегу, где оценка видит одну клетку на жидкости: "
                                         f"{result['shore_tries'][-1] if result['shore_tries'] else None}"])
        return result
    result.update(anchor=anchor, land_cell=dry_cell, dry_run=dry)

    reasons = []
    d = dry["detail"]
    # 3. оценка
    if liquid_total(d) != 1:
        reasons.append(f"dry_run: liquids = {d.get('liquids')}, а on_liquid = 1")
    fit = d.get("fit")
    if fit is None:
        reasons.append("dry_run: fit не найден (search по умолчанию 16), хотя рядом суша")
    else:
        reasons += ["dry_run: " + r for r in check_fit(fit, False)]
    if [s.get("reason") for s in d.get("skipped") or []] != ["liquid"]:
        reasons.append(f"dry_run: в skipped ждали одну клетку с reason liquid: {d.get('skipped')}")

    # 4. без partial — не ставится вовсе
    refused = step(client, blob, anchor, mode="hand")
    refused["after"] = world(client, item, anchor)
    result["refused"] = refused
    rd = refused["detail"]
    if refused["kind"] != "job_failed" or refused["code"] != "cannot_place":
        reasons.append(f"без partial ждали job_failed cannot_place, а пришло {refused['kind']} {refused['code']} ({refused['text']})")
    if rd.get("on_liquid") != 1 or liquid_total(rd) != 1:
        reasons.append(f"без partial: on_liquid = {rd.get('on_liquid')}, liquids = {rd.get('liquids')}")
    if fit is not None and rd.get("fit") != fit:
        reasons.append(f"без partial: fit {rd.get('fit')} не совпал с оценкой {fit}")
    if refused["after"]["ghosts"] or refused["after"]["built"]:
        reasons.append(f"без partial чертёж не должен встать, а в мире {refused['after']}")

    # 5. rotate: перебор поворотов и зеркала
    plain = step(client, blob, anchor, dry_run=True, search=ROTATE_SEARCH)
    turned = step(client, blob, anchor, dry_run=True, search=ROTATE_SEARCH, rotate=True)
    rot = {"plain": plain, "rotate": turned}
    result["rotate"] = rot
    for key, s in rot.items():
        if s["kind"] != "job_done" or s["detail"].get("on_liquid") != 1:
            reasons.append(f"rotate/{key}: ждали done с on_liquid = 1: {s['kind']} {s['code']} {s['detail'].get('on_liquid')}")
    rfit = turned["detail"].get("fit")
    if plain["detail"].get("fit") is not None and rfit is None:
        reasons.append("rotate: без поворотов сдвиг нашёлся, а с поворотами — нет")
    if rfit is not None:
        reasons += ["rotate: " + r for r in check_fit(rfit, True)]
        proof = step(client, blob, rfit.get("anchor") or anchor, dry_run=True, search=0, **fit_args(rfit))
        rot["proof"] = proof
        pd = proof["detail"]
        if proof["kind"] != "job_done" or pd.get("on_liquid") or pd.get("skipped_total") or pd.get("ghosts") != 2:
            reasons.append(f"rotate: в положении fit чертёж не встаёт целиком: {proof['code']} {pd}")

    # 6. по fit — встаёт целиком
    if fit is not None and not check_fit(fit, False):
        before = P.helper_count(client, item)
        placed = step(client, blob, fit["anchor"], mode="hand", **fit_args(fit))
        placed["after"] = world(client, item, fit["anchor"])
        placed["items_used"] = before - P.helper_count(client, item)
        result["by_fit"] = placed
        pd = placed["detail"]
        if placed["kind"] != "job_done":
            reasons.append(f"по fit ждали job_done, а пришло {placed['code']} ({placed['text']})")
        else:
            for key, want in (("ghosts", 2), ("built", 2), ("left", 0), ("skipped_total", 0), ("on_liquid", 0)):
                if pd.get(key) != want:
                    reasons.append(f"по fit: {key} = {pd.get(key)}, а не {want}")
            if placed["after"]["built"] != 2 or placed["after"]["ghosts"]:
                reasons.append(f"по fit: на карте {placed['after']}, ждали 2 постройки без призраков")
            if placed["items_used"] != 2:
                reasons.append(f"по fit: у помощника убыло {placed['items_used']} сундуков, а не 2")
        # убрать поставленное: дальше — обрезанный чертёж на исходном месте
        r = P.act(client, "deconstruct", {"area": box(fit["anchor"]), "filter": [item]})
        result["cleanup"] = P.brief(r)

    # 7. partial — обрезанный
    if P.helper_count(client, item) < 1 and not P.get_item(client, item, 1, result):
        reasons.append("для шага partial не осталось сундука")
    else:
        cut = step(client, blob, anchor, mode="hand", partial=True)
        cut["after"] = {"ghosts": client.call_ok("ghosts", {"area": box(anchor)}, P.HELPER).get("count"),
                        "built_on_land": len(P.entities_at(client, item, dry_cell))}
        result["partial"] = cut
        cd = cut["detail"]
        if cut["kind"] != "job_done":
            reasons.append(f"partial: ждали job_done, а пришло {cut['code']} ({cut['text']})")
        else:
            for key, want in (("ghosts", 1), ("built", 1), ("left", 0), ("on_liquid", 1)):
                if cd.get(key) != want:
                    reasons.append(f"partial: {key} = {cd.get(key)}, а не {want}")
            if [s.get("reason") for s in cd.get("skipped") or []] != ["liquid"]:
                reasons.append(f"partial: в skipped ждали одну клетку с reason liquid: {cd.get('skipped')}")
            if cut["after"]["built_on_land"] != 1:
                reasons.append(f"partial: на суше в {dry_cell} построек {cut['after']['built_on_land']}, а не 1")

    for key in ("dry_run", "refused", "by_fit", "partial"):
        s = result.get(key)
        if s and (s["kind"] is None or s["code"] in BAD_CODES):
            reasons.append(f"{key}: {s['kind']} {s['code']} ({s.get('text')})")
    result["facts"] = {"liquids": d.get("liquids"), "fit": fit, "fit_checked": d.get("fit_checked"),
                       "rotate_fit": rfit, "refused": refused["code"]}
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
