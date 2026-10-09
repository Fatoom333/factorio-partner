"""Живой сценарий потока C «Руки»: помощник сам накапывает руду рядом (ACTIONS.md `mine`).

Ход (сервер без окна, хозяин офлайн — helper_spawn у его последней позиции, PROTOCOL §4):
1. `hello` — мод factorio-partner.
2. `helper_spawn` помощника HELPER (или берём уже живого).
3. `resources` вокруг помощника (32, потом 64) — ближайшее пятно руды, которую можно копать руками.
4. `act mine {resource, near: центр пятна, count: COUNT}` — помощник сам идёт (поток B) и копает.
5. Ждём `job_done`/`job_failed` по `events`; проверяем detail.mined и инвентарь в `state`.
Нужен путь потока B: сценарий запускается после слияния wave-2/B в ветку C.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
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
COUNT = 5
JOB_TIMEOUT_S = 240.0
# Руды, которые копаются руками (вольфрам на Вулкане — нет: hard-solid). Порядок — предпочтение.
HAND_ORES = ["stone", "iron-ore", "copper-ore", "coal", "calcite"]


def _dist(a, b):
    return ((a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2) ** 0.5


def pick_patch(client):
    """Ближайшее пятно ручной руды. resources смотрит ≤ 128, а хозяин мог встать далеко от руды
    (живой замер 2026-10-09: Вулкан, ближайший уголь ~120 клеток) — поэтому сетка центров 128 вокруг
    помощника; расстояние считаем сами. → (пятно с полем dist, радиус поиска)."""
    me = client.call_ok("state", {}, HELPER)["pos"]
    best = None
    for radius, offsets in ((32, [(0, 0)]), (128, [(0, 0)] + [(dx, dy) for dx in (-128, 0, 128) for dy in (-128, 0, 128) if dx or dy])):
        for dx, dy in offsets:
            r = client.call("resources", {"radius": radius, "center": {"x": me["x"] + dx, "y": me["y"] + dy}}, HELPER)
            if not r.get("ok"):
                continue
            ps = r["data"].get("patches") or []
            for p in (ps if isinstance(ps, list) else []):
                if p.get("name") in HAND_ORES:
                    d = _dist(me, p["center"])
                    if best is None or (d, HAND_ORES.index(p["name"])) < (best[0]["dist"], HAND_ORES.index(best[0]["name"])):
                        best = (dict(p, dist=round(d, 1)), radius)
        if best is not None:
            return best
    return None, None


def run(client) -> dict:
    hello = client.call_ok("hello")
    result = {"mod": str(hello.get("mod", "")), "players_online": hello.get("players_online")}
    if not H.check_mod(hello, result):
        return result
    if not H.spawn(client, result):
        result["ok"] = False
        return result
    st0 = client.call_ok("state", {}, HELPER)
    result["start"] = {"pos": st0.get("pos"), "surface": st0.get("surface"), "inv": st0.get("inv")}

    patch, radius = pick_patch(client)
    if patch is None:
        result.update(ok=False, error={"kind": "setup", "text": "в радиусе 128 нет руды, которую копают руками"})
        return result
    name = patch["name"]
    result["patch"] = {"name": name, "center": patch.get("center"), "dist": patch.get("dist"), "radius": radius}
    before = (st0.get("inv") or {}).get(name, 0)

    r = H.act(client, "mine", {"resource": name, "near": patch["center"], "count": COUNT}, JOB_TIMEOUT_S)
    job = r["job"]
    result["seconds"] = r["seconds"]
    result["event_kinds"] = r["kinds"]
    st1 = client.call_ok("state", {}, HELPER)
    after = (st1.get("inv") or {}).get(name, 0)
    result["end"] = {"pos": st1.get("pos"), "inv": st1.get("inv")}
    if r["kind"] is None:
        result.update(ok=False, error={"kind": "timeout", "text": f"нет итога задачи {job} за {JOB_TIMEOUT_S:.0f} с"})
        return result
    ev = {"kind": r["kind"], "data": r["data"]}
    result["job"] = {"kind": ev["kind"], "data": ev.get("data")}
    mined = ((ev.get("data") or {}).get("detail") or {}).get("mined") or {}
    reasons = []
    if ev["kind"] != "job_done":
        reasons.append(f"задача не done: {ev.get('data', {}).get('code')} {ev.get('data', {}).get('text')}")
    if mined.get(name, 0) < COUNT:
        reasons.append(f"mined[{name}] = {mined.get(name, 0)} < {COUNT}")
    if after - before < COUNT:
        reasons.append(f"в инвентаре прибавилось {after - before} < {COUNT}")
    if after - before != mined.get(name, 0):
        reasons.append(f"detail.mined ({mined.get(name, 0)}) не совпал с приростом инвентаря ({after - before})")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
