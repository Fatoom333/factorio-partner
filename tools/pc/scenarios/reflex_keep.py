"""Живой сценарий потока V1: набор рефлексов не сбрасывается работой очереди задач.

EVENTS.md «Рефлексы v1»: набор хранится в `storage.reflexes`, переживает возрождение, перезагрузку
сейва и возврат тела-игрока, сбрасывается только `helper_remove`.

ОГРАНИЧЕНИЯ СТЕНДА (что вживую проверить нельзя и где это покрыто):
  * Перезагрузка сейва. Стенд поднимает сервер один раз на сценарий, а клиент шлёт только
    конверты `/partner <JSON>` и `/quit` в конце: сохранить игру и загрузить её снова из сценария
    нечем (команды сохранения — консольные, PROTOCOL §1 их запрещает). Покрыто юнит-тестом
    mod/tests/reflex_keep.lua («сохранение и загрузка сейва», в т. ч. пока помощник мёртв).
  * Возрождение. Честно убить помощника на стенде нечем (как в reflex_death) — юнит-тест
    «смерть и возрождение». Возврат тела-игрока — нужен второй клиент игры, юнит-тест
    «тело-игрок»; вживую — финал с игроком.
  * Прочитать набор обратно нельзя: операция `reflexes` только заменяет его целиком, в `state`
    набора нет. Поэтому «набор на месте» вживую видно лишь косвенно: проверки идут без ошибок
    (`module_errors` не растёт, в журнале нет «reflex ... failed»), а если рядом есть враги —
    приходит шумное `saw_enemy` (число — в результате шага).

Что проверяется здесь:
 1. hello                — отвечает factorio-partner (proto=1), запоминаем module_errors
 2. helper_spawn         — помощник; в helper_list он alive, body=character
 3. reflexes{set}        — flee + watch: умолчания по контракту (flee.to = "away", on_attack = true)
 4. работа очереди       — act wait -> job_done; act wait + cancel -> job_failed{cancelled};
                           vision off/on: ничто из этого набор не трогает (ошибок нет)
 5. наблюдение >= 600 тиков — помощник всё время alive, нет helper_lost/died/respawned
 6. повтор запроса       — тот же id запроса reflexes возвращает сохранённый ответ (набор тот же)
 7. helper_remove        — состояние removed
 8. hello                — module_errors не вырос

Только конверты `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [...], "failed": [имена], "limitation": текст}.
"""
from __future__ import annotations

MODS = ["factorio-partner"]

HELPER = "rkeep"
WATCH_TICKS = 600
WATCH_TIMEOUT_S = 60.0
POLL_S = 1.0
JOB_TIMEOUT_S = 20.0
STEPS = 8
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] (reflex|on_nth|event|attach) .* failed"
BAD_KINDS = ("helper_lost", "died", "respawned")
LIMITATION = ("перезагрузка сейва, возрождение и возврат тела-игрока вживую не проверены: стенд не умеет "
              "сохранять и загружать игру из сценария, убить помощника без консольных команд нельзя (они "
              "запрещены), второго клиента нет; прочитать набор обратно контракт не позволяет. Покрыто "
              "юнит-тестами mod/tests/reflex_keep.lua")

FLEE = {"type": "flee", "radius": 20, "distance": 30, "health": 1, "on_attack": True, "to": "away"}
WATCH = {"type": "watch", "radius": 32, "every_s": 5}
SET = [{"type": "flee"}, {"type": "watch", "every_s": 5}]


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


def helper_item(client, helper):
    for h in as_list(client.call_ok("helper_list")["helpers"]):
        if h["id"] == helper:
            return h
    return None


def run(client) -> dict:
    res = {"ok": False, "steps": [], "failed": [], "limitation": LIMITATION,
           "log_must_not_match": LOG_MUST_NOT_MATCH}
    state = {"spawned": False, "errors0": None, "seq0": 0}

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
            entry["error"] = f"{type(e).__name__}: {e}"[:300]
        res["steps"].append(entry)
        if not entry["ok"]:
            res["failed"].append(name)
        return entry["ok"]

    def events_since(since):
        data = client.call_ok("events", {"since": since, "helper": HELPER, "limit": 200})
        return as_list(data.get("events")), data.get("seq", since)

    def job_result(job, since):
        found = {}

        def check():
            evs, _ = events_since(since)
            for ev in evs:
                if ev["kind"] in ("job_done", "job_failed") and (ev.get("data") or {}).get("job") == job:
                    found["ev"] = ev
            return "ev" in found

        client.poll(check, JOB_TIMEOUT_S, 0.5)
        need("ev" in found, f"нет итога задачи {job}")
        return found["ev"]

    def s_hello():
        d = client.call_ok("hello")
        mod = str(d.get("mod", ""))
        need(d.get("proto") == 1 and not mod.startswith("partner-test"), f"нужен мод factorio-partner, ответил {mod!r}")
        errors = d.get("module_errors")
        need(isinstance(errors, (int, float)) and not isinstance(errors, bool), f"module_errors={errors!r}")
        state["errors0"] = errors
        state["seq0"] = d.get("seq", 0)
        return {"mod": mod, "module_errors": errors}

    def s_spawn():
        client.call_ok("helper_spawn", {}, HELPER)
        state["spawned"] = True
        item = helper_item(client, HELPER)
        need(item is not None and item.get("state") == "alive", f"helper_list: {item!r}")
        need(item.get("body") == "character", f"helper_list: body={item.get('body')!r}, ждали 'character'")
        need("away" not in item, f"helper_list: лишнее поле away: {item!r}")

    def s_set():
        d = client.call_ok("reflexes", {"set": SET}, HELPER)
        need(same(as_list(d.get("set")), [FLEE, WATCH]), f"набор в ответе: {d.get('set')!r}")

    def s_churn():
        since = client.call_ok("hello")["seq"]
        job = client.call_ok("act", {"do": "wait", "args": {"seconds": 1}}, HELPER)["job"]
        ev = job_result(job, since)
        fired = any(e["kind"] == "reflex_fired" for e in events_since(since)[0])
        if ev["kind"] == "job_failed":
            code = (ev.get("data") or {}).get("code")
            need(code == "cancelled" and fired, f"wait: job_failed {code!r} без срабатывания flee")
        since = client.call_ok("hello")["seq"]
        job2 = client.call_ok("act", {"do": "wait", "args": {"seconds": 30}}, HELPER)["job"]
        r = client.call("cancel", {"job": job2}, HELPER)
        if r["ok"]:
            ev2 = job_result(job2, since)
            need(ev2["kind"] == "job_failed" and (ev2.get("data") or {}).get("code") == "cancelled",
                 f"cancel: итог {ev2['kind']} {(ev2.get('data') or {}).get('code')!r}")
        else:
            # задачу уже снял рефлекс flee (рядом враги) — тогда отменять нечего
            need((r.get("error") or {}).get("code") == "not_found", f"cancel: {r.get('error')!r}")
        need(client.call_ok("vision", {"on": False}, HELPER).get("on") is False, "vision off")
        need(client.call_ok("vision", {"on": True}, HELPER).get("on") is True, "vision on")
        return {"flee_fired": fired}

    def s_watch():
        first = client.call_ok("hello")
        tick0, since = first["tick"], first["seq"]
        kinds = {}
        tick = tick0

        def passed():
            nonlocal since, tick
            item = helper_item(client, HELPER)
            need(item is not None and item.get("state") == "alive", f"помощник: {item!r}")
            evs, since = events_since(since)
            for ev in evs:
                kinds[ev["kind"]] = kinds.get(ev["kind"], 0) + 1
            tick = client.call_ok("hello")["tick"]
            return tick - tick0 >= WATCH_TICKS

        client.poll(passed, WATCH_TIMEOUT_S, POLL_S)
        for k in BAD_KINDS:
            need(k not in kinds, f"событие {k} во время наблюдения: {kinds!r}")
        need(tick - tick0 >= WATCH_TICKS, f"игра прошла {tick - tick0} тиков, нужно >= {WATCH_TICKS}")
        return {"ticks": tick - tick0, "kinds": kinds, "saw_enemy": kinds.get("saw_enemy", 0)}

    def s_repeat():
        env = client.make_envelope("reflexes", {"set": SET}, HELPER)
        a = client.send(env)
        b = client.send(env)
        need(a.get("ok") and b.get("ok"), f"reflexes: {a.get('error') or b.get('error')!r}")
        need(a.get("tick") == b.get("tick") and same(a.get("data"), b.get("data")),
             "повтор запроса с тем же id должен вернуть сохранённый ответ")
        need(same(as_list((b.get("data") or {}).get("set")), [FLEE, WATCH]), f"набор: {b.get('data')!r}")

    def s_remove():
        client.call_ok("helper_remove", {}, HELPER)
        state["spawned"] = False
        item = helper_item(client, HELPER)
        need(item is not None and item.get("state") == "removed", f"после helper_remove: {item!r}")

    def s_hello_end():
        d = client.call_ok("hello")
        need(d.get("module_errors") == state["errors0"],
             f"module_errors вырос: {state['errors0']} -> {d.get('module_errors')!r}")

    try:
        if step("hello", s_hello) and step("helper_spawn", s_spawn):
            if step("reflexes set", s_set):
                step("queue churn", s_churn)
                step("watch", s_watch)
                step("repeat request", s_repeat)
            step("helper_remove", s_remove)
            step("hello_end", s_hello_end)
    finally:
        if state["spawned"]:
            try:
                client.call("helper_remove", {}, HELPER)
            except Exception:  # noqa: BLE001 — уборка
                pass
    res["ok"] = not res["failed"] and len(res["steps"]) == STEPS
    return res
