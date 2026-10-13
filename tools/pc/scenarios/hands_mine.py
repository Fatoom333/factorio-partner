"""Живой сценарий потока C «Руки»: помощник сам накапывает руду рядом (ACTIONS.md `mine`).

Ход (сервер без окна, хозяин офлайн — helper_spawn у его последней позиции, PROTOCOL §4):
1. `hello` — мод factorio-partner.
2. `helper_spawn` помощника HELPER (или берём уже живого).
3. `resources` вокруг помощника (32, потом 64) — ближайшее пятно руды, которую можно копать руками.
4. `act mine {resource, near: центр пятна, count: COUNT}` — помощник сам идёт (поток B) и копает.
5. Ждём `job_done`/`job_failed` по `events`; проверяем detail.mined и инвентарь в `state`.
6. Дерево и камень вплотную (ACTIONS.md «Подход», ревизия 3.3): ближайшие камень и дерево по `map`
   (`types: simple-entity, tree`) → `act mine {target:{name, pos}, count:1}`. Рукой они добываются
   только с `resource_reach_distance` (2.7), а не с `reach_distance` (10): помощник должен подойти
   вплотную, цель — исчезнуть с карты, в инвентаре — прирост. Чего рядом нет (на Вулканусе мало
   деревьев) — пропускается с пометкой; нет ни того, ни другого — шаг не проверен (сбой).
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
NEAR_MAX = 4.5      # после добычи тело не дальше этого от центра цели (2.7 + половина большого камня)
NEAR_REACH = 64     # в стольких клетках от помощника ищем камень и дерево


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


def naturals(client, pos):
    """Камни и деревья вокруг помощника по `map` (9 окон по 65 клеток), ближние первыми.
    → {"rock": [...], "tree": [...]} — записи {name, pos}."""
    found, seen = {"rock": [], "tree": []}, set()
    for dx in (0, -NEAR_REACH, NEAR_REACH):
        for dy in (0, -NEAR_REACH, NEAR_REACH):
            r = client.call("map", {"center": {"x": pos["x"] + dx, "y": pos["y"] + dy}, "radius": 32,
                                    "types": ["simple-entity", "tree"]}, HELPER)
            if not r.get("ok"):
                continue
            ents = r["data"].get("entities") or []
            for e in (ents if isinstance(ents, list) else []):
                kind = "tree" if e.get("c") == "T" else ("rock" if e.get("c") == "#" and "cliff" not in e.get("name", "") else None)
                key = (e.get("name"), e["pos"]["x"], e["pos"]["y"])
                if kind and key not in seen:
                    seen.add(key)
                    found[kind].append({"name": e["name"], "pos": e["pos"]})
    for items in found.values():
        items.sort(key=lambda e: _dist(e["pos"], pos))
    return found


def still_there(client, target):
    r = client.call("map", {"center": target["pos"], "radius": 2, "types": ["simple-entity", "tree"]}, HELPER)
    ents = (r.get("data") or {}).get("entities") or [] if r.get("ok") else []
    return sum(1 for e in (ents if isinstance(ents, list) else [])
               if e.get("name") == target["name"] and _dist(e["pos"], target["pos"]) < 0.6)


def mine_near(client, kind, target, reasons):
    """Добыть камень или дерево по цели {name, pos}; → запись шага."""
    inv0 = client.call_ok("state", {}, HELPER).get("inv") or {}
    r = H.act(client, "mine", {"target": {"name": target["name"], "pos": target["pos"]}, "count": 1}, JOB_TIMEOUT_S)
    st = client.call_ok("state", {}, HELPER)
    inv1 = st.get("inv") or {}
    data = r["data"] or {}
    mined = (data.get("detail") or {}).get("mined") or {}
    gain = {k: n - inv0.get(k, 0) for k, n in inv1.items() if n > inv0.get(k, 0)}
    rec = {"target": target, "kind": r["kind"], "code": data.get("code"), "text": data.get("text"), "seconds": r["seconds"],
           "mined": mined, "gain": gain, "dist_after": round(_dist(st["pos"], target["pos"]), 1),
           "left_on_map": still_there(client, target)}
    if r["kind"] != "job_done":
        reasons.append(f"{kind}: mine не done: {rec['code']} {rec['text']}")
        return rec
    if not mined or mined != gain:
        reasons.append(f"{kind}: detail.mined {mined} не совпал с приростом инвентаря {gain}")
    if rec["dist_after"] > NEAR_MAX:
        reasons.append(f"{kind}: тело в {rec['dist_after']} клетках от цели — вплотную не подошёл")
    if rec["left_on_map"]:
        reasons.append(f"{kind}: {target['name']} остался на карте после добычи")
    return rec


def near_step(client, result, reasons):
    """Шаг 6: камень и дерево вплотную."""
    pos = client.call_ok("state", {}, HELPER)["pos"]
    found = naturals(client, pos)
    near = {"found": {k: len(v) for k, v in found.items()}}
    for kind in ("rock", "tree"):
        if found[kind]:
            near[kind] = mine_near(client, kind, found[kind][0], reasons)
        else:
            near[kind] = {"skipped": "рядом нет"}
    if not found["rock"] and not found["tree"]:
        reasons.append(f"в {NEAR_REACH} клетках нет ни камней, ни деревьев — добыча вплотную не проверена")
    result["near"] = near


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
    near_step(client, result, reasons)
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
