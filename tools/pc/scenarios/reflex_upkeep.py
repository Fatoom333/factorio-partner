"""Живой сценарий: рефлекс `upkeep` — заправка машин на горелках.

Ход (сервер без окна, хозяин офлайн):
1. `hello`, `helper_spawn`; текущий набор рефлексов читается `reflexes` без `set` и запоминается.
2. `reflexes {set: <набор без upkeep> + {type:"upkeep"}}` — в ответе есть upkeep со значениями по умолчанию.
3. Топливо помощнику — `get_items` (первое из FUELS, что есть на складах).
4. `status {radius:96}` — поиск остановившейся по топливу машины (cause=fuel). Нашлась — до FIRE_WAIT_S
   ждём `reflex_fired{type:"upkeep"}`. Нет — OBSERVE_S секунд наблюдения: ни `helper_lost`/`died`,
   ни роста `module_errors` в `hello`.
5. В любом случае в конце исходный набор рефлексов возвращается `reflexes {set}` и сверяется чтением.
Контракт: docs/EVENTS.md («upkeep»), docs/STATE.md («status»).
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
HELPER = P.HELPER
FUELS = ("coal", "solid-fuel", "wood")
FUEL_COUNT = 20
RADIUS = 96
FIRE_WAIT_S = 40.0
OBSERVE_S = 20.0
BAD_KINDS = ("helper_lost", "died")


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def _fired(events):
    return [e["data"] for e in events if e.get("kind") == "reflex_fired" and (e.get("data") or {}).get("type") == "upkeep"]


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    original = as_list(client.call_ok("reflexes", {}, HELPER).get("set"))
    result["original_set"] = original
    reasons = []
    try:
        _body(client, result, original, reasons)
    finally:
        back = client.call("reflexes", {"set": original}, HELPER)
        now = as_list(client.call_ok("reflexes", {}, HELPER).get("set")) if back["ok"] else None
        result["restored"] = bool(back["ok"] and now == original)
        if not result["restored"]:
            reasons.append(f"исходный набор рефлексов не вернулся: было {original!r}, стало {now!r}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result


def _body(client, result, original, reasons):
    new = [r for r in original if r.get("type") != "upkeep"] + [{"type": "upkeep"}]
    r = client.call("reflexes", {"set": new}, HELPER)
    if not r["ok"]:
        reasons.append(f"reflexes с upkeep не принят: {r.get('error')}")
        return
    upkeep = next((x for x in as_list(r["data"].get("set")) if x.get("type") == "upkeep"), None)
    result["upkeep"] = upkeep
    if upkeep is None:
        reasons.append(f"в ответе нет upkeep: {r['data'].get('set')!r}")
        return

    total, _radius = P._stock_total(client, FUELS, result)
    fuel = next((f for f in FUELS if total.get(f, 0) > 0), None)
    if fuel is None:
        result["fuel"] = "на видимых складах нет топлива"
    else:
        got = P.act(client, "get_items", {"items": {fuel: min(FUEL_COUNT, total[fuel])}})
        result["fuel"] = {"item": fuel, "get_items": P.brief(got), "have": P.helper_count(client, fuel)}

    hello0 = client.call_ok("hello")
    errors0 = hello0.get("module_errors", 0) or 0
    state = {"since": hello0["seq"]}
    seen = []

    def drain():
        data = client.call_ok("events", {"since": state["since"], "helper": HELPER, "limit": 200})
        seen.extend(as_list(data.get("events")))
        state["since"] = data.get("seq", state["since"])
        return bool(_fired(seen))

    status = client.call_ok("status", {"radius": RADIUS}, HELPER)
    rows = [g for g in as_list(status.get("stopped")) if g.get("cause") == "fuel"]
    result["fuel_groups"] = rows[:3]
    if rows:
        ok = client.poll(drain, FIRE_WAIT_S, 1.0)
        result["fired"] = _fired(seen)[:3]
        if not ok:
            reasons.append(f"машина без топлива есть ({rows[0].get('name')}), но upkeep не сработал за {FIRE_WAIT_S:.0f} с")
        elif (result["fired"][0].get("detail") or {}).get("kind") not in ("fuel", "science"):
            reasons.append(f"reflex_fired upkeep: странный detail {result['fired'][0]}")
    else:
        result["note"] = "машины без топлива рядом нет: проверены приём рефлекса и отсутствие ошибок"
        client.poll(drain, OBSERVE_S, 2.0)
    kinds = sorted({e.get("kind") for e in seen})
    result["kinds"] = kinds
    for k in BAD_KINDS:
        if k in kinds:
            reasons.append(f"во время наблюдения событие {k}")
    errors1 = client.call_ok("hello").get("module_errors", 0) or 0
    result["module_errors"] = {"before": errors0, "after": errors1}
    if errors1 > errors0:
        reasons.append(f"module_errors вырос с {errors0} до {errors1}")
