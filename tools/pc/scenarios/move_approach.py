"""Живой сценарий потока B: approach к сундуку/постройке хозяина → job_done в досягаемости.

Постройку ищет операцией `map` вокруг помощника (и на нескольких соседних центрах):
сундук (C) предпочтительнее, иначе любая своя постройка с unit_number, по возможности
не ближе MIN_DIST клеток (дальше досягаемости). Помощник в конце удаляется.
"""
from __future__ import annotations

import math

MODS = ["factorio-partner"]
HELPER = "bappr"
JOB_TIMEOUT_S = 90.0
MIN_DIST = 14.0  # дальше досягаемости (reach 10): помощник обязан пройти путь
REACH_SLACK = 0.6
CENTER_OFFSETS = [(0, 0), (48, 0), (-48, 0), (0, 48), (0, -48)]


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
        except Exception:  # noqa: BLE001
            pass
    return found.get("ev"), job


def pick_target(entities, origin):
    """Сундук лучше прочего; среди равных — дальше MIN_DIST и ближе к origin."""
    cands = [e for e in entities if e.get("unit") is not None and not e.get("ghost")]
    if not cands:
        return None

    def key(e):
        d = _dist(e["pos"], origin)
        return (0 if e.get("c") == "C" else 1, 0 if d >= MIN_DIST else 1, d)

    return sorted(cands, key=key)[0]


def find_target(client, helper, origin):
    for dx, dy in CENTER_OFFSETS:
        center = {"x": round(origin["x"] + dx, 1), "y": round(origin["y"] + dy, 1)}
        data = client.call_ok("map", {"center": center, "radius": 32}, helper)
        t = pick_target(data.get("entities") or [], origin)
        if t is not None:
            return t
    return None


def run(client) -> dict:
    res = {"ok": False}
    res["mod"] = client.call_ok("hello").get("mod")
    spawn = client.call_ok("helper_spawn", {}, HELPER)
    res["spawn"] = {"surface": spawn["surface"], "pos": spawn["pos"]}
    try:
        state = client.call_ok("state", {}, HELPER)
        reach = (state.get("reach") or {}).get("reach", 10)
        start = spawn["pos"]
        target = find_target(client, HELPER, start)
        if target is None:
            res["reason"] = "рядом нет построек хозяина (map)"
            return res
        res["target"] = {"name": target["name"], "pos": target["pos"], "unit": target["unit"],
                         "dist_before": round(_dist(target["pos"], start), 1)}
        ev, job = act_and_wait(client, HELPER, "approach", {"target": {"unit_number": target["unit"]}})
        if ev and ev["kind"] == "job_failed" and ev["data"].get("code") == "not_found":
            # Живой замер 2026-10-09: на стенде без игроков game.get_entity_by_unit_number не находит
            # поставленные постройки (персонажей находит). Запоминаем и берём форму {name, pos}.
            res["unit_lookup"] = "not_found"
            ev, job = act_and_wait(client, HELPER, "approach",
                                   {"target": {"name": target["name"], "pos": target["pos"]}})
        end, hstate = helper_pos(client, HELPER)
        res["job"] = job
        res["result"] = ev["kind"] if ev else "timeout"
        if ev and ev["kind"] == "job_failed":
            res["code"] = ev["data"].get("code")
            res["text"] = ev["data"].get("text")
        res["end"] = end
        if ev and ev["kind"] == "job_done" and end:
            d = _dist(end, target["pos"])
            res["dist_after"] = round(d, 2)
            res["ok"] = d <= reach + REACH_SLACK and hstate == "alive"
            if not res["ok"]:
                res["reason"] = "job_done, но помощник не в досягаемости"
        elif "reason" not in res:
            res["reason"] = "approach не завершился успехом"
    finally:
        try:
            client.call("helper_remove", {}, HELPER)
        except Exception:  # noqa: BLE001
            pass
    return res
