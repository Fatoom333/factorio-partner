"""Живой сценарий: пометки к сносу, которые поставила задача, снимаются при сбое и отмене.

Зачем (docs/ACTIONS.md («build_blueprint»)): `build_blueprint` в режиме `forced` помечает
деревья и камни на месте построек к сносу. Если задача упала или её отменили, а пометки остались,
дроны хозяина снесут помеченное без замены. Задача обязана снять свои пометки (`cancel_deconstruction`)
при `failed`, `cancel` и `stuck`.

Пометку к сносу операции чтения не показывают, поэтому она проверяется делом: после сбоя/отмены
помощнику даётся `build_ghosts{mode:"hand"}` по тому же месту с предметом в инвентаре. Пометка
снята — призрак над камнем заблокирован, помощник ничего не разбирает (`removed` = 0), камень на
месте. Пометка осталась — помощник разобрал бы камень сам (`removed` = 1).

Ход:
1. Помощник, два сундука честно со складов хозяина (как build_place); камни и деревья — по `map`.
2. Сбой: чертёж из одного сундука на ближний камень/дерево, `force:"forced"`, `mode:"robots"`. Личных
   дронов у помощника нет → призрак и пометка поставлены, задача сразу падает `no_items`.
   Проверка делом: `removed` = 0, камень на месте.
3. Отмена: тот же чертёж на дальний камень/дерево, `mode:"hand"`; как только в области появился
   призрак (чертёж поставлен, помощник идёт) — `cancel`. Итог `cancelled`; проверка делом.
4. Замер, а не проверка (`recovery`): повторный `build_blueprint{forced, hand}` на первом месте —
   помечает ли движок помеху заново поверх уже стоящего призрака и достраивает ли помощник.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import importlib.util
import os
import time


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


P = _load("build_place")
G = _load("build_ghosts")
M = _load("build_modes")
ITEM = "steel-chest"
ITEM_COUNT = 2
FAR_MIN = 12.0              # до «дальней» помехи идти не меньше стольких клеток: успеть отменить
PLACED_WAIT_S = 30.0        # ждём появления призрака перед отменой
BUILD_TIMEOUT_S = 240.0
BAD_CODES = ("internal", "bad_args", "limit")


def box(anchor, r=1.5):
    return {"left_top": {"x": anchor["x"] - r, "y": anchor["y"] - r},
            "right_bottom": {"x": anchor["x"] + r, "y": anchor["y"] + r}}


def pick(obstacles, pos):
    """Ближняя помеха и дальняя (не ближе FAR_MIN от помощника и не та же). → (near, far | None)."""
    if not obstacles:
        return None, None
    near = obstacles[0]
    far = next((e for e in obstacles[1:] if P.dist(e["pos"], pos) >= FAR_MIN and P.dist(e["pos"], near["pos"]) >= 6), None)
    return near, far


def obstacle_left(client, anchor, obstacle):
    data = P.scan_map(client, anchor, 3, ("simple-entity", "tree"))
    return sum(1 for e in data.get("entities", [])
               if e.get("name") == obstacle["name"] and not e.get("ghost") and P.dist(e["pos"], obstacle["pos"]) < 0.6)


def probe(client, anchor, obstacle):
    """Проверка делом: остались ли пометки. → запись с `marks_left` (True — помощник разобрал помеху)."""
    r = P.act(client, "build_ghosts", {"area": box(anchor), "mode": "hand"}, BUILD_TIMEOUT_S)
    d = P.detail_of(r)
    left = obstacle_left(client, anchor, obstacle)
    return {"kind": r["kind"], "code": P.code_of(r), "detail": d, "obstacle_left": left,
            "marks_left": bool(d.get("removed")) or left == 0}


def judge(tag, trial, reasons):
    """Общие проверки замера: чертёж поставил призрак и пометку, после итога пометок нет."""
    d = trial["run"]["detail"]
    if trial["run"]["kind"] is None or trial["run"]["code"] in BAD_CODES:
        reasons.append(f"{tag}: задача {trial['run']['kind']} {trial['run']['code']} ({trial['run'].get('text')})")
    p = trial.get("probe")
    if p is None:
        return
    if p["kind"] is None or p["code"] in BAD_CODES:
        reasons.append(f"{tag}: проверка делом {p['kind']} {p['code']}")
    if p["marks_left"]:
        reasons.append(f"{tag}: пометка к сносу не снята — помощник разобрал помеху сам "
                       f"(removed = {p['detail'].get('removed')}, на карте осталось {p['obstacle_left']})")
    # число снятых своих пометок — в detail итога (failed, cancel, stuck)
    if trial["run"]["kind"] == "job_failed":
        n = d.get("unmarked")
        if not isinstance(n, (int, float)) or isinstance(n, bool) or n < 1:
            reasons.append(f"{tag}: в detail нет числа снятых пометок (unmarked = {n!r})")
    if d.get("to_remove_total") is not None and d.get("to_remove_total") < 1:
        reasons.append(f"{tag}: чертёж ничего не пометил (to_remove_total = {d.get('to_remove_total')}) — проверять нечего")


def failed_trial(client, blob, obstacle):
    """Сбой: mode robots без личных дронов → no_items сразу после постановки."""
    anchor = M.cell(obstacle["pos"])
    r = P.act(client, "build_blueprint", {"blob": blob, "anchor": anchor, "force": "forced", "mode": "robots"}, BUILD_TIMEOUT_S)
    trial = {"anchor": anchor, "obstacle": obstacle,
             "run": {"kind": r["kind"], "code": P.code_of(r), "detail": P.detail_of(r), "text": (r.get("data") or {}).get("text")}}
    if r["kind"] == "job_failed":
        trial["probe"] = probe(client, anchor, obstacle)
    return trial


def job_end(client, job, since):
    """Один опрос событий: итог задачи job, если он уже есть. → (событие | None, новый since)."""
    data = client.call_ok("events", {"since": since, "helper": P.HELPER, "limit": 200})
    for ev in data.get("events", []):
        if ev.get("kind") in ("job_done", "job_failed") and (ev.get("data") or {}).get("job") == job:
            return ev, data.get("seq", since)
    return None, data.get("seq", since)


def cancel_trial(client, blob, obstacle):
    """Отмена: чертёж поставлен, помощник идёт — cancel."""
    anchor = M.cell(obstacle["pos"])
    since = client.call("hello")["seq"]
    job = client.call_ok("act", {"do": "build_blueprint", "args": {
        "blob": blob, "anchor": anchor, "force": "forced", "mode": "hand"}}, P.HELPER)["job"]
    t0 = time.monotonic()
    placed, ended = False, None
    while time.monotonic() - t0 < min(PLACED_WAIT_S, client.time_left()):
        if client.call_ok("ghosts", {"area": box(anchor)}, P.HELPER).get("count"):
            placed = True
            break
        ended, since = job_end(client, job, since)
        if ended is not None:
            break
        client.sleep(0.2)
    trial = {"anchor": anchor, "obstacle": obstacle, "job": job, "placed": placed,
             "placed_after_s": round(time.monotonic() - t0, 1)}
    if ended is None:
        trial["cancel"] = client.call("cancel", {"job": job}, P.HELPER).get("data")
        ended, _, _ = P.H.wait_job(client, job, since, 30.0, P.HELPER)
    data = (ended or {}).get("data") or {}
    trial["run"] = {"kind": ended and ended.get("kind"), "code": data.get("code"), "detail": data.get("detail") or {},
                    "text": data.get("text")}
    if placed and trial["run"]["code"] == "cancelled":
        trial["probe"] = probe(client, anchor, obstacle)
    return trial


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    if not P.get_item(client, ITEM, ITEM_COUNT, result):
        return P.setup_failed(result, f"не удалось добыть {ITEM_COUNT} × {ITEM} (склады хозяина, крафт)")
    around = P.survey(client, result)
    obstacles = sorted(around["rocks"] + around["trees"], key=lambda e: P.dist(e["pos"], around["pos"]))
    near, far = pick(obstacles, around["pos"])
    if near is None:
        return P.setup_failed(result, "рядом с помощником нет ни камней, ни деревьев — помечать нечего")
    blob = G.new_blob(client, G.encode_blueprint([{"name": ITEM, "position": {"x": 0.5, "y": 0.5}}]), "marks")

    reasons = []
    failed = failed_trial(client, blob, near)
    result["failed"] = failed
    if failed["run"]["kind"] != "job_failed" or failed["run"]["code"] != "no_items":
        reasons.append(f"сбой: ждали job_failed no_items (mode robots без дронов), а пришло "
                       f"{failed['run']['kind']} {failed['run']['code']}")
    judge("сбой", failed, reasons)

    if far is None:
        reasons.append(f"не нашлось второй помехи дальше {FAR_MIN:.0f} клеток — отмена не проверена")
    else:
        cancelled = cancel_trial(client, blob, far)
        result["cancelled"] = cancelled
        if not cancelled["placed"] or cancelled["run"]["code"] != "cancelled":
            reasons.append(f"отмена: задача кончилась раньше отмены или не отменилась: placed = {cancelled['placed']}, "
                           f"итог {cancelled['run']['kind']} {cancelled['run']['code']}")
        judge("отмена", cancelled, reasons)

    # замер: повторная постановка на первом месте (поверх своего призрака) — помечает ли движок заново
    if failed.get("probe") is not None and not failed["probe"]["marks_left"]:
        r = P.act(client, "build_blueprint", {"blob": blob, "anchor": failed["anchor"], "force": "forced", "mode": "hand"},
                  BUILD_TIMEOUT_S)
        d = P.detail_of(r)
        result["recovery"] = {"kind": r["kind"], "code": P.code_of(r), "detail": d,
                              "obstacle_left": obstacle_left(client, failed["anchor"], near),
                              "built_on_map": len(P.entities_at(client, ITEM, failed["anchor"])),
                              "ok": r["kind"] == "job_done" and d.get("removed", 0) >= 1}
        if r["kind"] is None or P.code_of(r) in BAD_CODES:
            reasons.append(f"повторная постановка: {r['kind']} {P.code_of(r)}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
