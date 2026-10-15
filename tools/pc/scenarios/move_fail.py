"""Живой сценарий: ошибки ходьбы.

1. Точка в неоткрытом чанке (очень далеко) → job_failed{code:"not_charted"} без похода.
2. Точка посреди воды/лавы (клетка `~` на `map`, вокруг которой в радиусе INNER тоже `~`)
   → job_failed{code:"path_failed"}. Если рядом нет такой воды/лавы — проверка пропускается
   (`skipped` в итоге), сценарий судит по первой.
Помощник в конце удаляется.
"""
from __future__ import annotations

import math

MODS = ["factorio-partner"]
HELPER = "bfail"
JOB_TIMEOUT_S = 90.0
FAR = [(100000, 0), (0, 100000), (-100000, 0), (0, -100000)]
INNER = 3
CENTER_OFFSETS = [(0, 0), (60, 0), (-60, 0), (0, 60), (0, -60), (60, 60), (-60, -60), (60, -60), (-60, 60)]


def helper_pos(client, helper):
    for h in client.call_ok("helper_list")["helpers"]:
        if h["id"] == helper:
            return h.get("pos"), h.get("state")
    return None, None


def act_and_wait(client, helper, do, args, timeout=JOB_TIMEOUT_S):
    """Поставить задачу и дождаться job_done/job_failed. → (событие | None, job)."""
    since = client.call_ok("hello")["seq"]
    job = client.call_ok("act", {"do": do, "args": args}, helper)["job"]
    found = {}

    def check():
        nonlocal since
        data = client.call_ok("events", {"since": since, "helper": helper, "limit": 200})
        for ev in data["events"]:
            if ev["kind"] in ("job_done", "job_failed") and ev["data"].get("job") == job:
                found["ev"] = ev
        since = data["seq"]
        return "ev" in found

    client.poll(check, timeout, 0.5)
    if "ev" not in found:
        try:
            client.call("cancel", {"job": job}, helper)
        except Exception:  # noqa: BLE001
            pass
    return found.get("ev"), job


def find_liquid(map_data, inner=INNER):
    """Клетка `~`, у которой все клетки в квадрате ±inner тоже `~` → центр клетки {x, y} | None."""
    rows = map_data.get("rows") or []
    bbox = map_data.get("bbox") or {}
    if not rows or "x0" not in bbox:
        return None
    x0, y0 = bbox["x0"], bbox["y0"]
    h = len(rows)
    for r in range(inner, h - inner):
        row = rows[r]
        for c in range(inner, len(row) - inner):
            if row[c] != "~":
                continue
            ok = True
            for rr in range(r - inner, r + inner + 1):
                line = rows[rr]
                if len(line) < c + inner + 1 or any(ch != "~" for ch in line[c - inner:c + inner + 1]):
                    ok = False
                    break
            if ok:
                return {"x": x0 + c + 0.5, "y": y0 + r + 0.5}
    return None


def check_not_charted(client, res):
    out = {"attempts": []}
    for dx, dy in FAR:
        start, _ = helper_pos(client, HELPER)
        goal = {"x": round(start["x"] + dx, 1), "y": round(start["y"] + dy, 1)}
        ev, job = act_and_wait(client, HELPER, "walk", {"to": goal, "radius": 1}, timeout=30.0)
        code = ev["data"].get("code") if ev and ev["kind"] == "job_failed" else None
        out["attempts"].append({"goal": goal, "result": ev["kind"] if ev else "timeout", "code": code})
        if code == "not_charted":
            end, _ = helper_pos(client, HELPER)
            out["moved"] = round(math.hypot(end["x"] - start["x"], end["y"] - start["y"]), 2)
            out["ok"] = out["moved"] < 1.0
            return out
    out["ok"] = False
    return out


def check_path_failed(client, res):
    out = {}
    origin, _ = helper_pos(client, HELPER)
    for dx, dy in CENTER_OFFSETS:
        center = {"x": round(origin["x"] + dx, 1), "y": round(origin["y"] + dy, 1)}
        data = client.call_ok("map", {"center": center, "radius": 32}, HELPER)
        goal = find_liquid(data)
        if goal is not None:
            break
    else:
        out["skipped"] = "рядом нет воды/лавы шириной ≥ " + str(2 * INNER + 1)
        out["ok"] = None
        return out
    out["goal"] = goal
    ev, job = act_and_wait(client, HELPER, "walk", {"to": goal, "radius": 1})
    out["result"] = ev["kind"] if ev else "timeout"
    if ev and ev["kind"] == "job_failed":
        out["code"] = ev["data"].get("code")
    out["ok"] = out.get("code") == "path_failed"
    return out


def run(client) -> dict:
    res = {"ok": False}
    res["mod"] = client.call_ok("hello").get("mod")
    spawn = client.call_ok("helper_spawn", {}, HELPER)
    res["spawn"] = {"surface": spawn["surface"], "pos": spawn["pos"]}
    try:
        res["not_charted"] = check_not_charted(client, res)
        res["path_failed"] = check_path_failed(client, res)
        pf = res["path_failed"].get("ok")
        res["ok"] = bool(res["not_charted"].get("ok")) and pf is not False
        if pf is None:
            res["skipped"] = ["path_failed"]
    finally:
        try:
            client.call("helper_remove", {}, HELPER)
        except Exception:  # noqa: BLE001
            pass
    return res
