"""Живой сценарий ядра: число помощников задаёт игрок — `helper_limit`.

PROTOCOL §4: занятых мест (живые + ждущие возрождения + `away`) ≤ max_helpers, по умолчанию 1;
`helper_limit {max:1..16}` -> `{max, alive}`; ниже числа уже занятых мест опустить нельзя (`limit`),
`alive` в ответе — только живые. Ждущих возрождения и `away` на стенде без окна не получить (нет
урона и второго клиента) — эти слагаемые проверены юнит-тестами (core_helpers, attach_away).
В `helper_list` у каждой записи есть `body`.

 1. hello                  — мод отвечает, в ответе есть module_errors
 2. по умолчанию один      — spawn a ок, spawn b -> limit (max_helpers = 1)
 3. helper_limit 2         — {max: 2, alive: 1}
 4. второй spawn           — spawn b ок
 5. третий spawn           — spawn c -> limit, в helper_list его нет
 6. границы                — max 0 -> bad_args, max 17 -> limit, без max -> bad_args, лишнее поле -> bad_args
 7. ниже занятого нельзя   — helper_limit 1 при двух живых -> limit, лимит остался 2
 8. больше — можно         — helper_limit 3 -> {max: 3, alive: 2}, spawn c ок
 9. уборка                 — helper_remove всех, helper_limit 1 -> {max: 1, alive: 0}
10. hello                  — module_errors не вырос

Только `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [{"name", "ok", "error"?, "info"?}], "failed": [имена]}.
"""
from __future__ import annotations

MODS = ["factorio-partner"]

A, B, C = "lim-a", "lim-b", "lim-c"
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] .* failed"


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def is_int(v):
    return (isinstance(v, int) and not isinstance(v, bool)) or (isinstance(v, float) and v == int(v))


def run(client) -> dict:
    c = client
    steps = []
    spawned = []
    state = {"errors0": None, "touched": False}

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

    def code_of(op, args=None, helper=None):
        """Код ошибки ответа или None, если ответ ok."""
        reply = c.call(op, args, helper)
        if reply.get("ok"):
            if op == "helper_spawn":
                spawned.append(helper)  # неожиданно появился — убрать в конце
            if op == "helper_limit":
                state["touched"] = True
            return None
        return (reply.get("error") or {}).get("code")

    def spawn(helper):
        d = c.call_ok("helper_spawn", {}, helper)
        spawned.append(helper)
        need(d.get("helper") == helper and is_int(d.get("unit_number")), f"helper_spawn: {str(d)[:120]}")
        return d

    def alive_ids():
        alive = [h for h in as_list(c.call_ok("helper_list")["helpers"]) if h.get("state") == "alive"]
        for h in alive:
            # вид тела в каждой записи; сценарий заводит только тела без игрока
            need(h.get("body") == "character", f"helper_list: у {h.get('id')} body={h.get('body')!r}")
        return sorted(h["id"] for h in alive)

    def limit(n):
        state["touched"] = True
        d = c.call_ok("helper_limit", {"max": n})
        need(set(d) == {"max", "alive"}, f"helper_limit: ждали {{max, alive}}, пришло {str(d)[:120]}")
        need(is_int(d["max"]) and is_int(d["alive"]), f"helper_limit: {d!r}")
        return int(d["max"]), int(d["alive"])

    def hello():
        d = c.call_ok("hello")
        need(d.get("proto") == 1, f"proto={d.get('proto')!r}")
        need(is_int(d.get("module_errors")) and d["module_errors"] >= 0, f"module_errors={d.get('module_errors')!r}")
        need(alive_ids() == [], "в сейве уже есть живые помощники — сценарий рассчитан на чистую копию")
        state["errors0"] = d["module_errors"]
        return {"mod": d.get("mod"), "owner": d.get("owner"), "module_errors": d["module_errors"]}

    def default_one():
        spawn(A)
        need(code_of("helper_spawn", {}, B) == "limit", "второй помощник при лимите по умолчанию должен дать limit")
        need(alive_ids() == [A], f"живые: {alive_ids()}")

    def limit_two():
        need(limit(2) == (2, 1), "helper_limit 2 при одном живом: ждали {max:2, alive:1}")

    def second():
        spawn(B)
        need(alive_ids() == sorted([A, B]), f"живые: {alive_ids()}")

    def third():
        need(code_of("helper_spawn", {}, C) == "limit", "третий помощник при max=2 должен дать limit")
        need(alive_ids() == sorted([A, B]), f"живые: {alive_ids()}")

    def bounds():
        need(code_of("helper_limit", {"max": 0}) == "bad_args", "max 0 -> bad_args")
        need(code_of("helper_limit", {"max": 17}) == "limit", "max 17 -> limit")
        need(code_of("helper_limit", {"max": 1.5}) == "bad_args", "max 1.5 -> bad_args")
        need(code_of("helper_limit", {}) == "bad_args", "без max -> bad_args")
        need(code_of("helper_limit", {"max": 2, "force": True}) == "bad_args", "лишнее поле -> bad_args")

    def not_below():
        need(code_of("helper_limit", {"max": 1}) == "limit", "ниже числа живых опустить нельзя (limit)")
        need(limit(2) == (2, 2), "лимит должен остаться 2 при двух живых")

    def raise_it():
        need(limit(3) == (3, 2), "helper_limit 3: ждали {max:3, alive:2}")
        spawn(C)
        need(alive_ids() == sorted([A, B, C]), f"живые: {alive_ids()}")
        need(code_of("helper_spawn", {}, "lim-d") == "limit", "четвёртый при max=3 -> limit")

    def cleanup():
        for h in list(spawned):
            c.call_ok("helper_remove", {}, h)
            spawned.remove(h)
        need(alive_ids() == [], f"после уборки живые: {alive_ids()}")
        need(limit(1) == (1, 0), "helper_limit 1 после уборки: ждали {max:1, alive:0}")

    def hello_end():
        d = c.call_ok("hello")
        need(d.get("module_errors") == state["errors0"],
             f"module_errors вырос: {state['errors0']} -> {d.get('module_errors')!r}")

    try:
        if not step("hello", hello):
            return finish(steps, aborted="hello не прошёл")
        if not step("default_one", default_one):
            return finish(steps, aborted="первый помощник не появился")
        for name, fn in (("limit_2", limit_two), ("second_spawn", second), ("third_limit", third),
                         ("bounds", bounds), ("not_below_alive", not_below), ("limit_3", raise_it)):
            step(name, fn)
        step("cleanup", cleanup)
        step("hello_end", hello_end)
        return finish(steps)
    finally:
        for h in list(spawned):
            try:
                c.call("helper_remove", {}, h)
            except Exception:  # уборка не прячет основной результат
                pass
        if state["touched"]:
            try:
                c.call("helper_limit", {"max": 1})  # лимит по умолчанию: сценарий не оставляет следов
            except Exception:
                pass


def finish(steps, aborted=None):
    failed = [s["name"] for s in steps if not s["ok"]]
    out = {"ok": not failed and aborted is None, "steps": steps, "failed": failed,
           "log_must_not_match": LOG_MUST_NOT_MATCH}
    if aborted:
        out["aborted"] = aborted
    return out
