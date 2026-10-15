"""Живой сценарий: удаление помощника — не смерть; рефлексы смерти не ломают ядро.

ОГРАНИЧЕНИЕ. Честно убить помощника на стенде нечем: врагов рядом с хозяином в тестовом сейве
нет, а нанести урон можно только консольной командой — они в проекте запрещены (никаких /c, /sc:
PROTOCOL §1, §6.10). Поэтому сама смерть, событие died и возрождение через 600 тиков проверены
юнит-тестами (mod/tests/reflex_death.lua), а вживую — только в игре с врагами (финал с игроком).
Здесь проверяется то, что можно: модуль смерти слушает on_entity_died всех персонажей, и
helper_remove (тело умирает через die()) не должен приниматься за смерть.

 1. hello                — отвечает factorio-partner (proto=1)
 2. helper_spawn A       — помощник; ему задаётся набор рефлексов (flee + watch)
 3. helper_remove A      — ответ ok; тело умерло «по-тихому»
 4. наблюдение ≥ 700 тиков (дольше срока возрождения 600): A всё время removed, событий died /
                            respawned / reflex_done / helper_lost нет
 5. helper_spawn A       — cooldown (тела нет, идёт перезарядка — возрождения не было)
 6. helper_spawn B       — второй помощник появляется: ядро и спавн работают
 7. reflexes{set} B      — набор принимается
 8. act wait 1 с B       — job_done: очередь задач работает
 9. helper_remove B

Только конверты `/partner <JSON>` через client.call.
Результат: {"ok": bool, "steps": [...], "failed": [имена], "limitation": текст}.
"""
from __future__ import annotations

MODS = ["factorio-partner"]

HELPER_A = "rdeath"
HELPER_B = "rdeath2"
RESPAWN_TICKS = 600     # срок возрождения (PROTOCOL §6.9)
WATCH_TICKS = 700       # наблюдаем дольше срока
WATCH_TIMEOUT_S = 60.0
POLL_S = 1.0
JOB_TIMEOUT_S = 20.0
BAD_KINDS = ("died", "respawned", "reflex_done", "reflex_fired", "helper_lost")
LIMITATION = ("смерть от урона и возрождение вживую не проверены: без врагов убить помощника можно "
              "только консольной командой, а они запрещены; покрыто юнит-тестами reflex_death.lua")


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def as_list(v):
    return [] if v == {} else v


def helper_info(client, helper):
    for h in as_list(client.call_ok("helper_list")["helpers"]):
        if h["id"] == helper:
            return h
    return None


def run(client) -> dict:
    res = {"ok": False, "steps": [], "failed": [], "limitation": LIMITATION}
    touched = []   # кого пытались заспавнить — всех убираем в конце, что бы ни случилось
    mark = {}

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
        return {"mod": mod}

    def s_spawn_a():
        touched.append(HELPER_A)
        d = client.call_ok("helper_spawn", {}, HELPER_A)
        client.call_ok("reflexes", {"set": [{"type": "flee"}, {"type": "watch"}]}, HELPER_A)
        return {"surface": d.get("surface"), "pos": d.get("pos")}

    def s_remove_a():
        first = client.call_ok("hello")
        mark["tick"], mark["seq"] = first["tick"], first["seq"]
        d = client.call_ok("helper_remove", {}, HELPER_A)
        return {"corpse": d.get("corpse")}

    def s_watch():
        since = mark["seq"]
        kinds = {}
        seen = {}

        def check():
            info = helper_info(client, HELPER_A)
            st = info and info.get("state")
            need(st == "removed", f"помощник после удаления: {st!r}")
            data = client.call_ok("events", {"since": seen.get("since", since), "helper": HELPER_A, "limit": 200})
            for ev in as_list(data.get("events")):
                kinds[ev["kind"]] = kinds.get(ev["kind"], 0) + 1
            seen["since"] = data.get("seq", since)
            seen["tick"] = client.call_ok("hello")["tick"]
            return seen["tick"] - mark["tick"] >= WATCH_TICKS

        done = client.poll(check, WATCH_TIMEOUT_S, POLL_S)
        ticks = seen.get("tick", mark["tick"]) - mark["tick"]
        for k in BAD_KINDS:
            need(k not in kinds, f"событие {k} после helper_remove: {kinds!r}")
        need(done, f"за {WATCH_TIMEOUT_S} с прошло только {ticks} тиков из {WATCH_TICKS}")
        return {"ticks": ticks, "kinds": kinds}

    def s_cooldown():
        r = client.call("helper_spawn", {}, HELPER_A)
        code = None if r["ok"] else (r.get("error") or {}).get("code")
        need(code == "cooldown", f"helper_spawn сразу после удаления: ждали cooldown, пришло {code or 'ok'!r}")

    def s_spawn_b():
        touched.append(HELPER_B)
        d = client.call_ok("helper_spawn", {}, HELPER_B)
        info = helper_info(client, HELPER_B)
        need(info is not None and info.get("state") == "alive", f"второй помощник: {info!r}")
        return {"pos": d.get("pos")}

    def s_set_b():
        d = client.call_ok("reflexes", {"set": [{"type": "flee", "to": "spawn"}]}, HELPER_B)
        got = as_list(d.get("set"))
        need(len(got) == 1 and got[0].get("type") == "flee" and got[0].get("to") == "spawn", f"набор: {d.get('set')!r}")

    def s_act_b():
        since = client.call_ok("hello")["seq"]
        job = client.call_ok("act", {"do": "wait", "args": {"seconds": 1}}, HELPER_B)["job"]
        found = {}

        def check():
            data = client.call_ok("events", {"since": since, "helper": HELPER_B, "limit": 200})
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

    def s_remove_b():
        client.call_ok("helper_remove", {}, HELPER_B)

    try:
        if step("hello", s_hello) and step("helper_spawn A", s_spawn_a):
            if step("helper_remove A", s_remove_a):
                step("watch", s_watch)
                step("cooldown", s_cooldown)
            if step("helper_spawn B", s_spawn_b):
                step("reflexes B", s_set_b)
                step("act wait B", s_act_b)
                step("helper_remove B", s_remove_b)
    finally:
        for h in touched:
            try:
                client.call("helper_remove", {}, h)  # уже удалён -> no_helper, это не ошибка
            except Exception:  # noqa: BLE001 — уборка
                pass
    res["ok"] = not res["failed"] and len(res["steps"]) == 9
    return res
