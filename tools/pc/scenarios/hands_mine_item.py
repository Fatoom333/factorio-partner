"""Живой сценарий `mine{item}` — «набери предмет» из камней подряд (ACTIONS.md).

Ход (сервер без окна, хозяин офлайн):
1. `hello`, `helper_spawn` помощника HELPER (или уже живой).
2. `act mine {item, count}` — по очереди пробуем ITEMS (вольфрам из камней Вулкануса, потом камень):
   `bad_args` «nothing gives» или `not_found` сразу — следующий предмет.
3. Пока идёт задача, дважды в секунду смотрим `state`: позицию и инвентарь. Пауза — тело стоит на
   месте и предмет не прибавляется. Самая долгая пауза не должна быть больше MAX_IDLE_S: мод сам
   переходит от камня к камню, без «подумать» между ними.
4. Итог `job_done`, прирост предмета ≥ COUNT и равен detail.mined[item].
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import importlib.util
import os
import time


def _common():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_hands.py")
    spec = importlib.util.spec_from_file_location("fp_scenario__hands", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


H = _common()
HELPER = H.HELPER
ITEMS = [("tungsten-ore", 20), ("stone", 20)]
JOB_TIMEOUT_S = 300.0
MAX_IDLE_S = 12.0   # дольше любой добычи одного камня рукой; «подумать» агента сюда не влезает
STILL = 0.05        # сдвиг меньше — стоит на месте


def _moved(a, b):
    return ((a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2) ** 0.5 >= STILL


def watch(client, item, job, since):
    """Опрос state до итога задачи. → (событие|None, самая долгая пауза, с; прирост по ходу)."""
    end = time.monotonic() + min(JOB_TIMEOUT_S, client.time_left())
    st = client.call_ok("state", {}, HELPER)
    last_pos, last_n = st["pos"], (st.get("inv") or {}).get(item, 0)
    idle_from, idle_max = time.monotonic(), 0.0
    while time.monotonic() < end:
        data = client.call_ok("events", {"since": since, "helper": HELPER, "limit": 200})
        for ev in data.get("events", []):
            d = ev.get("data") or {}
            if ev.get("kind") in ("job_done", "job_failed") and d.get("job") == job:
                return ev, round(idle_max, 1)
        since = data.get("seq", since)
        st = client.call_ok("state", {}, HELPER)
        n = (st.get("inv") or {}).get(item, 0)
        now = time.monotonic()
        if n > last_n or _moved(st["pos"], last_pos):
            idle_from = now
        idle_max = max(idle_max, now - idle_from)
        last_pos, last_n = st["pos"], n
        client.sleep(0.5)
    client.call("cancel", {"job": job}, HELPER)
    return None, round(idle_max, 1)


def nearest_rock(client, pos):
    """Ближайший камень по `map` (окна по 65 клеток вокруг помощника) — как пинг хозяина. → (pos|None, n)."""
    best, n = None, 0
    for dx in (0, -64, 64):
        for dy in (0, -64, 64):
            r = client.call("map", {"center": {"x": pos["x"] + dx, "y": pos["y"] + dy}, "radius": 32,
                                    "types": ["simple-entity"]}, HELPER)
            ents = (r.get("data") or {}).get("entities") or [] if r.get("ok") else []
            for e in (ents if isinstance(ents, list) else []):
                if "cliff" in e.get("name", ""):
                    continue
                n += 1
                d = ((e["pos"]["x"] - pos["x"]) ** 2 + (e["pos"]["y"] - pos["y"]) ** 2) ** 0.5
                if best is None or d < best[0]:
                    best = (d, e["pos"], e.get("name"))
    return (best[1], best[2]) if best else (None, None), n


def run(client) -> dict:
    hello = client.call_ok("hello")
    result = {"mod": str(hello.get("mod", "")), "tries": []}
    if not H.check_mod(hello, result):
        return result
    if not H.spawn(client, result):
        result["ok"] = False
        return result
    reasons = []
    (near, rock_name), n_rocks = nearest_rock(client, client.call_ok("state", {}, HELPER)["pos"])
    result["rocks"] = {"found": n_rocks, "nearest": near, "name": rock_name}
    for item, count in ITEMS:
        st0 = client.call_ok("state", {}, HELPER)
        before = (st0.get("inv") or {}).get(item, 0)
        since = client.call("hello")["seq"]
        r = client.call("act", {"do": "mine", "args": dict({"item": item, "count": count}, **({"near": near} if near else {}))}, HELPER)
        if not r.get("ok"):
            result["tries"].append({"item": item, "error": r.get("error")})
            continue
        job = r["data"]["job"]
        t0 = time.monotonic()
        ev, idle = watch(client, item, job, since)
        st1 = client.call_ok("state", {}, HELPER)
        gain = (st1.get("inv") or {}).get(item, 0) - before
        data = (ev or {}).get("data") or {}
        rec = {"item": item, "count": count, "kind": ev and ev["kind"], "code": data.get("code"),
               "text": data.get("text"), "seconds": round(time.monotonic() - t0, 1), "gain": gain,
               "mined": (data.get("detail") or {}).get("mined"), "idle_max_s": idle}
        result["tries"].append(rec)
        if ev is not None and ev["kind"] == "job_failed" and data.get("code") in ("bad_args", "not_found") and gain == 0:
            continue  # этот предмет здесь не добыть — пробуем следующий
        if ev is None:
            reasons.append(f"{item}: нет итога за {JOB_TIMEOUT_S:.0f} с")
        elif ev["kind"] != "job_done":
            reasons.append(f"{item}: не done: {data.get('code')} {data.get('text')}")
        if gain < count:
            reasons.append(f"{item}: прибавилось {gain} < {count}")
        if (rec["mined"] or {}).get(item) != gain:
            reasons.append(f"{item}: detail.mined {rec['mined']} не совпал с приростом {gain}")
        if idle > MAX_IDLE_S:
            reasons.append(f"{item}: стоял без дела {idle} с > {MAX_IDLE_S}")
        break
    else:
        reasons.append("ни один предмет из ITEMS здесь не добыть — mine{item} не проверен")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
