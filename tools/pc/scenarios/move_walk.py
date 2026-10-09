"""Живой сценарий потока B: helper_spawn → walk на 30 клеток → job_done, помощник у цели.

Пробует несколько направлений (на месте может оказаться вода, лава, скалы или постройки):
первое удачное — успех. Помощник в конце удаляется (helper_remove), сейв — копия стенда.
"""
from __future__ import annotations

import math

MODS = ["factorio-partner"]
HELPER = "bwalk"
DIST = 30.0
RADIUS = 1.0
JOB_TIMEOUT_S = 60.0
DIRECTIONS = [(1, 0), (-1, 0), (0, 1), (0, -1), (0.7071, 0.7071), (-0.7071, -0.7071)]


def _dist(a, b):
    return math.hypot(a["x"] - b["x"], a["y"] - b["y"])


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
        except Exception:  # noqa: BLE001 — уборка, итог уже «таймаут»
            pass
    return found.get("ev"), job


def run(client) -> dict:
    res = {"ok": False, "attempts": []}
    hello = client.call_ok("hello")
    res["mod"] = hello.get("mod")
    spawn = client.call_ok("helper_spawn", {}, HELPER)
    res["spawn"] = {"surface": spawn["surface"], "pos": spawn["pos"]}
    try:
        for vx, vy in DIRECTIONS:
            start, _ = helper_pos(client, HELPER)
            goal = {"x": round(start["x"] + vx * DIST, 1), "y": round(start["y"] + vy * DIST, 1)}
            ev, job = act_and_wait(client, HELPER, "walk", {"to": goal, "radius": RADIUS})
            end, state = helper_pos(client, HELPER)
            att = {"goal": goal, "start": start, "end": end, "job": job,
                   "result": ev["kind"] if ev else "timeout"}
            if ev and ev["kind"] == "job_failed":
                att["code"] = ev["data"].get("code")
            res["attempts"].append(att)
            if ev and ev["kind"] == "job_done":
                detail = ev["data"].get("detail") or {}
                att["detail"] = detail
                d_goal = _dist(end, goal) if end else None
                walked = detail.get("walked") or 0
                att["dist_to_goal"] = d_goal
                res["ok"] = (d_goal is not None and d_goal <= RADIUS + 0.5 and walked >= DIST - RADIUS - 3
                             and state == "alive")
                if not res["ok"]:
                    res["reason"] = "job_done, но помощник не у цели или прошёл мало"
                break
            if ev is None or att.get("code") not in ("path_failed", "not_charted", "stuck"):
                res["reason"] = "неожиданный итог ходьбы"
                break
        else:
            res["reason"] = "ни одно направление не прошло"
    finally:
        try:
            client.call("helper_remove", {}, HELPER)
        except Exception:  # noqa: BLE001
            pass
    return res
