"""Живой сценарий ядра (ревизия 3.4): общая перезарядка `helper_spawn` — 10 секунд.

PROTOCOL «Уточнения ревизии 3.4»: перезарядка считается от последнего удаления или смерти ЛЮБОГО
тела-персонажа, а не по id. Раньше 10 с — `cooldown`; от 10 с до 5 мин тело появляется в точке
возрождения силы (`at: "respawn_point"`); позже 5 мин — у хозяина (`at: "owner"`). Сверка только по
ответам мода (время — по `tick` ответов, 60 тиков = 1 с); позже 5 минут на стенде не ждём — это
слагаемое проверено юнит-тестами (core_helpers).

 1. hello            — мод отвечает, живых помощников нет
 2. first_spawn      — helper_spawn a ок, в ответе at ("owner" │ "respawn_point") и pos
 3. remove           — helper_remove a; helper_list: запись removed с cooldown_s 1..10
 4. cooldown_same    — сразу helper_spawn a -> cooldown
 5. cooldown_other   — helper_spawn b (другой id) -> cooldown: перезарядка общая
 6. wait_10s         — ждём 10 с игрового времени (по tick ответов hello)
 7. respawn_point    — helper_spawn a ок, at = "respawn_point", pos и surface есть, тело живо
 8. cleanup          — helper_remove a
 9. hello_end        — module_errors не вырос

Только `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [{"name", "ok", "error"?, "info"?}], "failed": [имена]}.
"""
from __future__ import annotations

import time

MODS = ["factorio-partner"]

A, B = "rsp-a", "rsp-b"
COOLDOWN_TICKS = 10 * 60          # PROTOCOL, уточнения 3.4
MARGIN_TICKS = 30                 # запас после границы: ровно на 600-м тике не спрашиваем
FIRST_SPAWN_TRIES = 15            # сейв мог быть сохранён сразу после чьей-то смерти: ждём её перезарядку
WAIT_REAL_S = 90.0                # столько реального времени ждём 10 игровых секунд
POLL_S = 1.0
AT = ("owner", "respawn_point")
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] .* failed"


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_pos(v):
    return isinstance(v, dict) and is_num(v.get("x")) and is_num(v.get("y"))


def run(client) -> dict:
    c = client
    steps = []
    spawned = []
    state = {"errors0": None, "removed_tick": None, "first": None}

    def step(name, fn):
        rec = {"name": name, "ok": True}
        try:
            out = fn()
            if isinstance(out, dict) and out:
                rec["info"] = out
        except Exception as e:  # сбой транспорта или проверки — это шаг, а не падение сценария
            rec["ok"] = False
            rec["error"] = f"{type(e).__name__}: {e}"[:300]
        steps.append(rec)
        return rec["ok"]

    def tick_now():
        reply = c.call("hello")
        need(reply.get("ok") and is_num(reply.get("tick")), f"hello без tick: {str(reply)[:120]}")
        return int(reply["tick"])

    def try_spawn(helper):
        """→ (data | None, код ошибки | None, tick ответа)."""
        reply = c.call("helper_spawn", {}, helper)
        if reply.get("ok"):
            spawned.append(helper)
            return reply.get("data") or {}, None, reply.get("tick")
        return None, (reply.get("error") or {}).get("code"), reply.get("tick")

    def listed(helper):
        for h in as_list(c.call_ok("helper_list")["helpers"]):
            if h.get("id") == helper:
                return h
        return None

    def check_body(d, helper):
        need(d.get("helper") == helper, f"helper_spawn: {str(d)[:160]}")
        need(d.get("at") in AT, f"helper_spawn: at={d.get('at')!r}, ждали одно из {AT}")
        need(is_pos(d.get("pos")) and isinstance(d.get("surface"), str) and d["surface"],
             f"helper_spawn: нет pos / surface: {str(d)[:160]}")

    def hello():
        d = c.call_ok("hello")
        need(d.get("proto") == 1, f"proto={d.get('proto')!r}")
        alive = [h.get("id") for h in as_list(c.call_ok("helper_list")["helpers"]) if h.get("state") == "alive"]
        need(alive == [], f"в сейве уже есть живые помощники ({alive}) — сценарий рассчитан на чистую копию")
        state["errors0"] = d.get("module_errors")
        return {"mod": d.get("mod"), "owner": d.get("owner"), "module_errors": d.get("module_errors")}

    def first_spawn():
        waited = 0
        while True:
            d, code, _ = try_spawn(A)
            if d is not None:
                break
            need(code == "cooldown" and waited < FIRST_SPAWN_TRIES, f"helper_spawn: {code}")
            waited += 1
            c.sleep(POLL_S)
        check_body(d, A)
        state["first"] = d
        return {"at": d["at"], "pos": d["pos"], "surface": d["surface"], "waited_s": waited}

    def remove():
        reply = c.call("helper_remove", {}, A)
        need(reply.get("ok"), f"helper_remove: {str(reply)[:160]}")
        spawned.remove(A)
        need(is_num(reply.get("tick")), "в ответе helper_remove нет tick")
        state["removed_tick"] = int(reply["tick"])
        rec = listed(A)
        need(rec is not None and rec.get("state") == "removed", f"helper_list: {rec!r}")
        cd = rec.get("cooldown_s")
        need(is_num(cd) and 1 <= cd <= 10, f"cooldown_s={cd!r}, ждали 1..10 (перезарядка 10 с)")
        return {"tick": state["removed_tick"], "cooldown_s": cd}

    def cooldown(helper):
        def fn():
            d, code, tick = try_spawn(helper)
            # раньше 10 с — только cooldown; проверка честна, пока граница не пройдена
            late = is_num(tick) and state["removed_tick"] is not None and \
                tick - state["removed_tick"] >= COOLDOWN_TICKS
            need(not late, f"стенд слишком медленный: до helper_spawn прошло {tick - state['removed_tick']} тиков")
            need(d is None and code == "cooldown", f"helper_spawn {helper} раньше 10 с: ждали cooldown, "
                                                    f"пришло {code if d is None else 'ok'}")
            return {"ticks_after_remove": tick - state["removed_tick"] if is_num(tick) else None}
        return fn

    def wait_10s():
        target = state["removed_tick"] + COOLDOWN_TICKS + MARGIN_TICKS
        end = time.monotonic() + WAIT_REAL_S
        now = tick_now()
        while now < target:
            need(time.monotonic() < end,
                 f"игра не дошла до тика {target} за {WAIT_REAL_S:.0f} с (сейчас {now}): она на паузе?")
            c.sleep(POLL_S)
            now = tick_now()
        return {"ticks_after_remove": now - state["removed_tick"]}

    def respawn_point():
        d, code, tick = try_spawn(A)
        need(d is not None, f"helper_spawn после 10 с: {code}")
        check_body(d, A)
        need(d["at"] == "respawn_point", f"после 10 с тело должно появиться в точке возрождения, at={d['at']!r}")
        rec = listed(A)
        need(rec is not None and rec.get("state") == "alive" and rec.get("body") == "character",
             f"helper_list: {rec!r}")
        need(rec.get("surface") == d["surface"], f"поверхность тела {rec.get('surface')!r} != {d['surface']!r}")
        first = state["first"] or {}
        info = {"at": d["at"], "pos": d["pos"], "surface": d["surface"],
                "ticks_after_remove": tick - state["removed_tick"] if is_num(tick) else None}
        if is_pos(first.get("pos")):
            info["first_at"] = first.get("at")
            info["from_first_spawn"] = round(abs(first["pos"]["x"] - d["pos"]["x"])
                                             + abs(first["pos"]["y"] - d["pos"]["y"]), 1)
        return info

    def cleanup():
        for h in list(spawned):
            c.call_ok("helper_remove", {}, h)
            spawned.remove(h)

    def hello_end():
        d = c.call_ok("hello")
        need(d.get("module_errors") == state["errors0"],
             f"module_errors вырос: {state['errors0']} -> {d.get('module_errors')!r}")

    try:
        if not step("hello", hello):
            return finish(steps, aborted="hello не прошёл")
        if not step("first_spawn", first_spawn):
            return finish(steps, aborted="первый помощник не появился")
        if not step("remove", remove):
            return finish(steps, aborted="helper_remove не прошёл")
        step("cooldown_same", cooldown(A))
        step("cooldown_other", cooldown(B))
        if step("wait_10s", wait_10s):
            step("respawn_point", respawn_point)
        step("cleanup", cleanup)
        step("hello_end", hello_end)
        return finish(steps)
    finally:
        for h in list(spawned):
            try:
                c.call("helper_remove", {}, h)
            except Exception:  # уборка не прячет основной результат
                pass


def finish(steps, aborted=None):
    failed = [s["name"] for s in steps if not s["ok"]]
    out = {"ok": not failed and aborted is None, "steps": steps, "failed": failed,
           "log_must_not_match": LOG_MUST_NOT_MATCH}
    if aborted:
        out["aborted"] = aborted
    return out
