"""Живой сценарий: набор рефлексов задаётся, проверки идут 30 с, ядро живо.

 1. hello                 — отвечает factorio-partner (proto=1)
 2. helper_spawn          — помощник появился
 3. reflexes{set}         — flee + watch: ответ возвращает набор со значениями по умолчанию
 4. reflexes{set}         — полная замена: в ответе только новый набор
 5. плохие наборы         — неизвестный тип -> bad_args, radius 99 -> limit, лишнее поле -> bad_args
 6. reflexes{set}         — снова flee + watch (с ним идёт наблюдение)
 7. наблюдение 30 с       — тики идут (>= 600: проверки рефлексов вызваны десятки раз), помощник
                            всё время alive, нет helper_lost/died; виды событий — в результате
 8. act wait 1 с          — очередь задач работает рядом с рефлексами (job_done; если рядом
                            оказались враги и flee снял задачу — это тоже годится)
 9. reflexes{set: []}     — набор снят
10. helper_remove

Ошибки внутри check мод пишет только в журнал игры (в RCON их не видно): после прогона в
вычищенном журнале стенда не должно быть строк «reflex ... failed» — образец в `log_must_not_match`.
Только конверты `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [{"name", "ok", "error"?, "info"?}], "failed": [имена]}.
"""
from __future__ import annotations

MODS = ["factorio-partner"]

HELPER = "rset"
WATCH_S = 30.0          # столько наблюдаем
POLL_S = 2.0
MIN_TICKS = 600         # за время наблюдения игра должна пройти хотя бы столько тиков
JOB_TIMEOUT_S = 20.0
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] (reflex|on_nth|event) .* failed"

FLEE_DEFAULT = {"type": "flee", "radius": 20, "distance": 30, "health": 1, "on_attack": True, "to": "away",
                "resume": True, "resume_health": 0.8}
WATCH_DEFAULT = {"type": "watch", "radius": 32, "every_s": 10}
BAD_KINDS = ("helper_lost", "died", "respawned")


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def same(a, b):
    """Сравнение ответа с ожиданием: 1 и 1.0 равны, {} и [] равны."""
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if a in ({}, []) and b in ({}, []):
        return True
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    return a == b


def helper_state(client, helper):
    for h in as_list(client.call_ok("helper_list")["helpers"]):
        if h["id"] == helper:
            return h.get("state")
    return None


def expect_error(client, rset, code):
    r = client.call("reflexes", {"set": rset}, HELPER)
    got = None if r["ok"] else (r.get("error") or {}).get("code")
    need(got == code, f"набор {rset!r}: ждали {code}, пришло {got!r}")


def run(client) -> dict:
    res = {"ok": False, "steps": [], "failed": [], "log_must_not_match": LOG_MUST_NOT_MATCH}
    state = {"spawned": False}

    def step(name, fn):
        entry = {"name": name, "ok": False}
        try:
            info = fn()
            entry["ok"] = True
            if info is not None:
                entry["info"] = info
        except Check as e:
            entry["error"] = str(e)
        except Exception as e:  # noqa: BLE001 — ошибка шага не должна ронять уборку
            entry["error"] = f"{type(e).__name__}: {e}"
        res["steps"].append(entry)
        if not entry["ok"]:
            res["failed"].append(name)
        return entry["ok"]

    def s_hello():
        d = client.call_ok("hello")
        mod = str(d.get("mod", ""))
        need(d.get("proto") == 1 and not mod.startswith("partner-test"), f"нужен мод factorio-partner, ответил {mod!r}")
        return {"mod": mod, "players_online": d.get("players_online")}

    def s_spawn():
        d = client.call_ok("helper_spawn", {}, HELPER)
        state["spawned"] = True
        return {"surface": d.get("surface"), "pos": d.get("pos")}

    def s_set():
        d = client.call_ok("reflexes", {"set": [{"type": "flee", "radius": 16, "health": 0.5},
                                                {"type": "watch", "every_s": 5}]}, HELPER)
        want = [dict(FLEE_DEFAULT, radius=16, health=0.5), dict(WATCH_DEFAULT, every_s=5)]
        need(same(as_list(d.get("set")), want), f"набор в ответе: {d.get('set')!r}")
        # без set — только чтение, набор тот же
        got = client.call_ok("reflexes", {}, HELPER)
        need(same(as_list(got.get("set")), want), f"reflexes без set: {got.get('set')!r}")

    def s_replace():
        d = client.call_ok("reflexes", {"set": [{"type": "watch"}]}, HELPER)
        need(same(as_list(d.get("set")), [WATCH_DEFAULT]), f"после замены: {d.get('set')!r}")

    def s_bad():
        expect_error(client, [{"type": "dance"}], "bad_args")
        expect_error(client, [{"type": "flee", "radius": 99}], "limit")
        expect_error(client, [{"type": "flee", "speed": 3}], "bad_args")
        expect_error(client, [{"radius": 5}], "bad_args")

    def s_set_again():
        d = client.call_ok("reflexes", {"set": [{"type": "flee"}, {"type": "watch"}]}, HELPER)
        need(same(as_list(d.get("set")), [FLEE_DEFAULT, WATCH_DEFAULT]), f"набор в ответе: {d.get('set')!r}")

    def s_watch():
        first = client.call_ok("hello")
        tick0, since = first["tick"], first["seq"]
        kinds = {}
        polls = 0
        left = WATCH_S
        tick = tick0
        while True:
            st = helper_state(client, HELPER)
            need(st == "alive", f"помощник {st!r} на {polls}-м опросе")
            data = client.call_ok("events", {"since": since, "helper": HELPER, "limit": 200})
            for ev in as_list(data.get("events")):
                kinds[ev["kind"]] = kinds.get(ev["kind"], 0) + 1
            since = data.get("seq", since)
            tick = client.call_ok("hello")["tick"]
            polls += 1
            if left <= 0:
                break
            client.sleep(min(POLL_S, left))
            left -= POLL_S
        for k in BAD_KINDS:
            need(k not in kinds, f"событие {k} во время наблюдения: {kinds!r}")
        need(tick - tick0 >= MIN_TICKS, f"игра прошла {tick - tick0} тиков, нужно >= {MIN_TICKS}")
        state["kinds"] = kinds
        return {"ticks": tick - tick0, "polls": polls, "kinds": kinds}

    def s_act():
        since = client.call_ok("hello")["seq"]
        job = client.call_ok("act", {"do": "wait", "args": {"seconds": 1}}, HELPER)["job"]
        found = {}

        def check():
            data = client.call_ok("events", {"since": since, "helper": HELPER, "limit": 200})
            for ev in as_list(data.get("events")):
                if ev["kind"] == "reflex_fired":
                    found["fired"] = True
                if ev["kind"] in ("job_done", "job_failed") and (ev.get("data") or {}).get("job") == job:
                    found["ev"] = ev
            return "ev" in found

        client.poll(check, JOB_TIMEOUT_S, 0.5)
        need("ev" in found, "нет итога задачи wait")
        ev = found["ev"]
        if ev["kind"] == "job_failed":
            code = (ev.get("data") or {}).get("code")
            need(code == "cancelled" and found.get("fired"), f"wait: job_failed {code!r} без срабатывания flee")
            return {"result": "снята рефлексом flee (рядом враги)"}
        return {"result": "job_done"}

    def s_clear():
        d = client.call_ok("reflexes", {"set": []}, HELPER)
        need(as_list(d.get("set")) == [], f"пустой набор: {d.get('set')!r}")
        got = client.call_ok("reflexes", {}, HELPER)
        need(as_list(got.get("set")) == [], f"reflexes без set после снятия: {got.get('set')!r}")

    def s_remove():
        client.call_ok("helper_remove", {}, HELPER)
        state["spawned"] = False
        need(helper_state(client, HELPER) == "removed", "после helper_remove состояние не removed")

    try:
        if step("hello", s_hello) and step("helper_spawn", s_spawn):
            step("reflexes set", s_set)
            step("reflexes replace", s_replace)
            step("reflexes bad", s_bad)
            if step("reflexes set again", s_set_again):
                step("watch", s_watch)
            step("act wait", s_act)
            step("reflexes clear", s_clear)
            step("helper_remove", s_remove)
    finally:
        if state["spawned"]:
            try:
                client.call("helper_remove", {}, HELPER)
            except Exception:  # noqa: BLE001 — уборка
                pass
    res["ok"] = not res["failed"] and len(res["steps"]) == 10
    return res
