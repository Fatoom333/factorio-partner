"""Общее для живых сценариев «Руки» (hands_*): проверка мода, спавн, ожидание задачи.

Не сценарий: сценарии загружаются по пути (live_client.load_scenario), а не как пакет, поэтому
hands_* подгружают этот файл сами по пути рядом с собой (`_common()`). `run` здесь — только чтобы
загрузчик и проверка «у каждого файла сценариев есть run» его не роняли.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import time

HELPER = "hands"


def check_mod(hello, result):
    """Отвечает ли factorio-partner (proto=1); иначе — ошибка setup в result. → bool."""
    mod = str(hello.get("mod", ""))
    # factorio-partner отвечает proto=1 и версией в mod; тестовый partner-test — "partner-test x.y.z"
    if mod.startswith("partner-test") or hello.get("proto") != 1:
        result.update(ok=False, error={"kind": "setup", "text": f"нужен мод factorio-partner, ответил {mod!r}"})
        return False
    return True


def spawn(client, result, helper=HELPER):
    """helper_spawn или уже живой помощник. → bool (ошибка — в result["error"])."""
    r = client.call("helper_spawn", {}, helper)
    if r["ok"]:
        result["spawn"] = r["data"]
        return True
    code = (r.get("error") or {}).get("code")
    if code == "helper_exists":
        result["spawn"] = {"reused": True}
        return True
    result["error"] = {"kind": "spawn", "code": code, "text": (r.get("error") or {}).get("text")}
    return False


def wait_job(client, job, since, timeout, helper=HELPER):
    """События помощника с seq > since до итога задачи job. → (событие|None, seq, kinds)."""
    end = time.monotonic() + min(timeout, client.time_left())
    seen = []
    while time.monotonic() < end:
        data = client.call_ok("events", {"since": since, "helper": helper, "limit": 200})
        for ev in data.get("events", []):
            seen.append(ev.get("kind"))
            d = ev.get("data") or {}
            if ev.get("kind") in ("job_done", "job_failed") and d.get("job") == job:
                return ev, data.get("seq", since), seen
        since = data.get("seq", since)
        client.sleep(0.5)
    return None, since, seen


def act(client, do, args, timeout, helper=HELPER):
    """Поставить задачу и дождаться итога; нет итога — cancel.
    → {do, args, job, seconds, kind, data, kinds}."""
    since = client.call("hello")["seq"]  # seq конверта — последнее событие в буфере
    job = client.call_ok("act", {"do": do, "args": args}, helper)["job"]
    t0 = time.monotonic()
    ev, _, kinds = wait_job(client, job, since, timeout, helper)
    if ev is None:
        client.call("cancel", {"job": job}, helper)
    return {"do": do, "args": args, "job": job, "seconds": round(time.monotonic() - t0, 1),
            "kind": ev and ev["kind"], "data": ev and ev.get("data"), "kinds": kinds[-30:]}


def run(client) -> dict:
    return {"ok": False, "error": {"kind": "setup", "text": "_hands — общий модуль сценариев hands_*, не сценарий"}}
