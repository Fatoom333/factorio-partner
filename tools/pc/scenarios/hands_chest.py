"""Живой сценарий потока C «Руки»: extract из сундука хозяина и insert обратно — без потерь и дублей.

Ход (сервер без окна, хозяин офлайн, PROTOCOL §4 helper_spawn):
1. `hello`, `helper_spawn` помощника HELPER (пустой инвентарь).
2. `stock` вокруг помощника (64, потом 128) дважды с паузой STABLE_S — берём сундук, содержимое
   которого не меняется (иначе в базе работают манипуляторы и сверка «без дублей» невозможна).
3. Предмет с наибольшим числом в сундуке; N = min(10, count // 2).
4. `act extract {target:{unit_number}, items:{item:N}}` → job_done, extracted = N;
   `stock`: в сундуке ровно −N, `state`: у помощника ровно +N.
5. `act insert {target, items:{item:N}}` → job_done, inserted = N; сундук и помощник — как в начале.
Подходит к сундуку сам (поток B): запускать после слияния wave-2/B.
"""
from __future__ import annotations

import importlib.util
import os


def _common():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_hands.py")
    spec = importlib.util.spec_from_file_location("fp_scenario__hands", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


H = _common()
HELPER = H.HELPER
STABLE_S = 2.0
JOB_TIMEOUT_S = 150.0
VISIBLE_WAIT_S = 15.0


def _containers(client, radius):
    data = client.call_ok("stock", {"radius": radius, "limit": 200}, HELPER)
    return {c["unit"]: c for c in data.get("containers", []) if c.get("unit") is not None}, data.get("hidden", 0)


def pick_chest(client, result):
    for radius in (64, 128):
        def visible():
            cs, hidden = _containers(client, radius)
            visible.last = (cs, hidden)
            return cs
        visible.last = ({}, 0)
        client.poll(visible, VISIBLE_WAIT_S, 1.0)
        first, hidden = visible.last
        result.setdefault("scan", []).append({"radius": radius, "containers": len(first), "hidden": hidden})
        if not first:
            continue
        client.sleep(STABLE_S)
        second, _ = _containers(client, radius)
        stable = [c for u, c in first.items() if u in second and second[u].get("items") == c.get("items")]
        stable = [c for c in stable if any(n >= 2 for n in (c.get("items") or {}).values())]
        if stable:
            stable.sort(key=lambda c: c.get("dist", 1e9))
            return stable[0]
    return None


def chest_count(client, unit, item, radius=128):
    cs, _ = _containers(client, radius)
    c = cs.get(unit)
    return (c.get("items") or {}).get(item, 0) if c else 0


def helper_count(client, item):
    return (client.call_ok("state", {}, HELPER).get("inv") or {}).get(item, 0)


def _act(client, do, args, result, key, alt_target=None):
    """Задача do до итога; запись в result[key]. → событие-итог (kind, data) или None.
    Живой замер 2026-10-09: на стенде без игроков поиск по unit_number не находит постройки
    (not_found за 0 с) — тогда повторяем с формой цели {name, pos} (alt_target)."""
    r = H.act(client, do, args, JOB_TIMEOUT_S)
    if alt_target and r["kind"] == "job_failed" and (r["data"] or {}).get("code") == "not_found":
        result["unit_lookup"] = "not_found"
        r = H.act(client, do, dict(args, target=alt_target), JOB_TIMEOUT_S)
    result[key] = {"job": r["job"], "seconds": r["seconds"], "kind": r["kind"], "data": r["data"]}
    return {"kind": r["kind"], "data": r["data"]} if r["kind"] else None


def run(client) -> dict:
    hello = client.call_ok("hello")
    result = {"mod": str(hello.get("mod", "")), "players_online": hello.get("players_online")}
    if not H.check_mod(hello, result):
        return result
    if not H.spawn(client, result):
        result["ok"] = False
        return result

    chest = pick_chest(client, result)
    if chest is None:
        result.update(ok=False, error={"kind": "setup", "text": "нет видимого сундука хозяина с неизменным содержимым"})
        return result
    items = chest.get("items") or {}
    item = max(items, key=lambda k: items[k])
    n = min(10, items[item] // 2)
    unit = chest["unit"]
    result["chest"] = {"unit": unit, "name": chest.get("name"), "pos": chest.get("pos"), "dist": chest.get("dist"),
                       "item": item, "n": n}
    c0, h0 = items[item], helper_count(client, item)
    # ACTIONS.md «target»: {unit_number, pos} — мод сам ищет вокруг pos, если движок не находит
    # постройку по unit_number; alt ({name, pos}) остаётся запасным
    target = {"unit_number": unit, "pos": chest.get("pos")}
    alt ={"name": chest.get("name"), "pos": chest.get("pos")}
    reasons = []

    ev = _act(client, "extract", {"target": target, "items": {item: n}}, result, "extract", alt)
    c1, h1 = chest_count(client, unit, item), helper_count(client, item)
    result["after_extract"] = {"chest": c1, "helper": h1}
    if ev is None or ev["kind"] != "job_done":
        reasons.append(f"extract не done: {result['extract']}")
    else:
        got = ((ev.get("data") or {}).get("detail") or {}).get("extracted", {}).get(item, 0)
        if got != n:
            reasons.append(f"extracted {got} ≠ {n}")
        if c0 - c1 != n:
            reasons.append(f"в сундуке убыло {c0 - c1}, а не {n}")
        if h1 - h0 != n:
            reasons.append(f"у помощника прибыло {h1 - h0}, а не {n}")

    if not reasons:
        ev2 = _act(client, "insert", {"target": target, "items": {item: n}}, result, "insert", alt)
        c2, h2 = chest_count(client, unit, item), helper_count(client, item)
        result["after_insert"] = {"chest": c2, "helper": h2}
        if ev2 is None or ev2["kind"] != "job_done":
            reasons.append(f"insert не done: {result['insert']}")
        else:
            put = ((ev2.get("data") or {}).get("detail") or {}).get("inserted", {}).get(item, 0)
            if put != n:
                reasons.append(f"inserted {put} ≠ {n}")
            if c2 != c0:
                reasons.append(f"сундук в конце {c2}, в начале {c0}")
            if h2 != h0:
                reasons.append(f"у помощника в конце {h2}, в начале {h0}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
