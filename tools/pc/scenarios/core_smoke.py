"""Дымовой живой сценарий ядра мода factorio-partner (поток A, волна 2).

Идёт по основным операциям протокола на сервере без окна (хозяин в сейве офлайн — спавн у его
последней позиции, PROTOCOL §4 ревизия 3) и сверяет формы ответов с docs/PROTOCOL.md и STATE.md:

 1. hello                  — proto, mod, owner, players_online, players, helpers, tick, seq
 2. helper_spawn h1        — helper, unit_number, surface, pos (хозяина нет в сейве -> стоп)
 3. state                  — STATE.md «state»
 4. map                    — bbox, axis, rows (ровные строки), legend, entities, surface, truncated
 5. resources (radius 32)  — patches[], truncated
 6. stock                  — containers, total, hidden, truncated
 7. ghosts                 — count, by_name, need, have{helper,stock}, missing, blocked
 8. recipes                — craftable{}
 9. rates                  — scope=surface, items, fluids, truncated
10. vision on, 10 с       — затем map вокруг помощника без «?» (неоткрытого не осталось)
11. say                    — ответ {} (чат проверить из сценария нельзя — смотрим журнал вручную)
12. act wait 1 с + events  — job_done для этой задачи, форма события
13. jobs                   — очередь пуста
14. helper_remove          — и helper_list: state=removed, cooldown_s > 0

Только `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [{"name", "ok", "error"?, "info"?}], "failed": [имена]}.
"""
from __future__ import annotations

MODS = ["factorio-partner"]

HELPER = "h1"
VISION_WAIT_S = 10.0       # столько ждём после vision{on:true}
VISION_EXTRA_S = 5.0       # и ещё столько терпим, пока map не очистится от «?»
JOB_TIMEOUT_S = 20.0       # act wait 1 с -> job_done
POLL_S = 0.5
MAP_RADIUS = 16
RESOURCE_RADIUS = 32


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool) or (isinstance(v, float) and v == int(v))


def is_pos(v):
    return isinstance(v, dict) and is_num(v.get("x")) and is_num(v.get("y"))


def is_map(v):
    """Объект JSON. Пустой объект и пустой массив для мода одно и то же (PROTOCOL §1)."""
    return isinstance(v, dict) or v == []


def as_map(v):
    return {} if v == [] else v


def is_list(v):
    """Массив JSON. Пустая таблица мода приходит как {} (PROTOCOL §1), поэтому {} тоже пустой список."""
    return isinstance(v, list) or v == {}


def as_list(v):
    return [] if v == {} else v


def field(d, key, pred, what):
    need(isinstance(d, dict) and key in d, f"нет поля {key}")
    need(pred(d[key]), f"{key}: ожидалось {what}, пришло {str(d[key])[:80]!r}")
    return d[key]


# ---------------------------------------------------------------- проверки форм

def check_hello(d):
    need(d.get("proto") == 1, f"proto={d.get('proto')!r}")
    mod = field(d, "mod", lambda v: isinstance(v, str), "строка")
    need(mod.startswith("0.") or mod[:1].isdigit(), f"mod: версия мода, пришло {mod!r}")
    field(d, "tick", is_int, "целое")
    field(d, "seq", is_int, "целое")
    owner = d.get("owner")
    need(isinstance(owner, str) and owner, "owner: нужен игрок-хозяин в сейве")
    field(d, "players_online", lambda v: is_int(v) and v >= 0, "целое >= 0")
    players = as_list(field(d, "players", is_list, "список"))
    for p in players:
        need(is_int(p.get("index")) and isinstance(p.get("name"), str) and isinstance(p.get("online"), bool),
             f"players[]: index/name/online, пришло {p!r}")
    need(any(p["name"] == owner for p in players), "хозяина нет в players")
    need(d["players_online"] == sum(1 for p in players if p["online"]),
         "players_online не совпадает с числом online в players")
    field(d, "helpers", is_list, "список id")


def check_spawn(d):
    need(d.get("helper") == HELPER, f"helper={d.get('helper')!r}")
    field(d, "unit_number", is_int, "целое")
    field(d, "surface", lambda v: isinstance(v, str) and v, "строка")
    field(d, "pos", is_pos, "{x,y}")


def check_state(d):
    need(d.get("helper") == HELPER, f"helper={d.get('helper')!r}")
    field(d, "surface", lambda v: isinstance(v, str) and v, "строка")
    field(d, "pos", is_pos, "{x,y}")
    field(d, "health", is_num, "число")
    field(d, "max_health", is_num, "число")
    reach = field(d, "reach", lambda v: isinstance(v, dict), "объект")
    for k in ("build", "reach", "resource", "pickup"):
        need(is_num(reach.get(k)), f"reach.{k}")
    field(d, "inv", is_map, "объект {предмет: число}")
    field(d, "inv_free", lambda v: is_int(v) and v >= 0, "целое >= 0")
    need(d.get("armor") is None or isinstance(d["armor"], str), "armor: строка или нет")
    need(d.get("robots") is None or is_map(d["robots"]), "robots: объект")
    field(d, "queue", lambda v: is_int(v) and v >= 0, "целое >= 0")
    field(d, "players", is_list, "список")
    near = field(d, "near", lambda v: isinstance(v, dict), "объект")
    need(is_list(near.get("enemies")), "near.enemies: список")
    need(is_int(near.get("containers")), "near.containers: целое")
    field(d, "vision", lambda v: isinstance(v, bool), "bool")
    field(d, "tick", is_int, "целое")
    field(d, "seq", is_int, "целое")


def check_map(d):
    bbox = field(d, "bbox", lambda v: isinstance(v, dict), "объект")
    for k in ("x0", "y0", "x1", "y1"):
        need(is_num(bbox.get(k)), f"bbox.{k}")
    field(d, "axis", lambda v: isinstance(v, str), "строка")
    rows = field(d, "rows", lambda v: isinstance(v, list) and v and all(isinstance(r, str) for r in v), "список строк")
    need(len({len(r) for r in rows}) == 1, "строки карты разной длины")
    legend = field(d, "legend", lambda v: isinstance(v, dict), "объект")
    for ch in set("".join(rows)):
        need(ch in legend, f"символа {ch!r} нет в legend")
    ents = as_list(field(d, "entities", is_list, "список"))
    for e in ents[:5]:
        need(isinstance(e.get("c"), str) and isinstance(e.get("name"), str) and is_pos(e.get("pos")),
             f"entities[]: c/name/pos, пришло {e!r}")
    field(d, "surface", lambda v: isinstance(v, str), "строка")
    field(d, "truncated", lambda v: isinstance(v, bool), "bool")
    return rows


def check_resources(d):
    patches = as_list(field(d, "patches", is_list, "список"))
    for p in patches:
        need(isinstance(p.get("name"), str) and is_pos(p.get("center")) and is_int(p.get("tiles"))
             and is_num(p.get("amount")) and is_num(p.get("dist")) and isinstance(p.get("area"), dict),
             f"patches[]: name/center/area/tiles/amount/dist, пришло {str(p)[:120]!r}")
    field(d, "truncated", lambda v: isinstance(v, bool), "bool")


def check_stock(d):
    cont = as_list(field(d, "containers", is_list, "список"))
    for c in cont:
        need(is_int(c.get("unit")) and isinstance(c.get("name"), str) and is_pos(c.get("pos"))
             and is_map(c.get("items")), f"containers[]: unit/name/pos/items, пришло {str(c)[:120]!r}")
    field(d, "total", is_map, "объект")
    field(d, "hidden", lambda v: is_int(v) and v >= 0, "целое >= 0")
    field(d, "truncated", lambda v: isinstance(v, bool), "bool")


def check_ghosts(d):
    field(d, "count", lambda v: is_int(v) and v >= 0, "целое >= 0")
    for k in ("by_name", "need", "missing"):
        field(d, k, is_map, "объект")
    have = field(d, "have", lambda v: isinstance(v, dict), "объект")
    need(is_map(have.get("helper")) and is_map(have.get("stock")), "have.helper / have.stock")
    field(d, "blocked", is_list, "список")


def check_recipes(d):
    craft = field(d, "craftable", is_map, "объект {рецепт: число}")
    for k, v in as_map(craft).items():
        need(is_int(v) and v > 0, f"craftable.{k}: целое > 0 (нули не выводятся)")


def check_rates(d):
    need(d.get("scope") == "surface", f"scope={d.get('scope')!r}")
    field(d, "surface", lambda v: isinstance(v, str), "строка")
    need(d.get("period") == "1m", f"period={d.get('period')!r}")
    for k in ("items", "fluids"):
        m = field(d, k, is_map, "объект")
        for name, v in as_map(m).items():
            need(isinstance(v, dict) and is_num(v.get("made")) and is_num(v.get("used")),
                 f"{k}.{name}: made/used")
    field(d, "truncated", lambda v: isinstance(v, bool), "bool")


def check_event(ev, job):
    need(ev.get("kind") == "job_done", f"kind={ev.get('kind')!r}")
    need(is_int(ev.get("seq")) and is_int(ev.get("tick")), "seq/tick события")
    need(ev.get("helper") == HELPER, f"helper события={ev.get('helper')!r}")
    need(ev.get("loud") is True, "job_done должно быть loud")
    data = ev.get("data")
    need(isinstance(data, dict) and data.get("job") == job and data.get("do") == "wait",
         f"data={str(data)[:100]!r}, ждали job={job}, do=wait")


# ---------------------------------------------------------------- сценарий

class Run:
    def __init__(self, client):
        self.c = client
        self.steps = []
        self.info = {}

    def step(self, name, fn):
        rec = {"name": name, "ok": True}
        try:
            out = fn()
            if isinstance(out, dict) and out:
                rec["info"] = out
        except (Check, KeyError, TypeError, AttributeError) as e:
            rec["ok"] = False
            rec["error"] = f"{type(e).__name__}: {e}"[:300]
        except Exception as e:  # LiveClientError и т.п.: сбой транспорта/ответа тоже шаг, не падение сценария
            rec["ok"] = False
            rec["error"] = f"{type(e).__name__}: {e}"[:300]
        self.steps.append(rec)
        return rec["ok"]

    def ok_call(self, op, args=None, helper=None):
        return self.c.call_ok(op, args, helper)


def run(client) -> dict:
    r = Run(client)
    c = client
    state = {"spawned": False, "seq0": 0}

    def hello():
        d = r.ok_call("hello")
        check_hello(d)
        state["seq0"] = d["seq"]
        return {"owner": d["owner"], "players_online": d["players_online"], "mod": d["mod"]}

    def spawn():
        d = r.ok_call("helper_spawn", {}, HELPER)
        state["spawned"] = True
        check_spawn(d)
        return {"surface": d["surface"], "pos": d["pos"]}

    def helper_list_alive():
        lst = as_list(r.ok_call("helper_list")["helpers"])
        mine = [h for h in lst if h.get("id") == HELPER]
        need(len(mine) == 1 and mine[0].get("state") == "alive", f"helper_list: {lst!r}"[:200])

    def st():
        check_state(r.ok_call("state", {}, HELPER))

    def map_before():
        rows = check_map(r.ok_call("map", {"radius": MAP_RADIUS}, HELPER))
        need(any("@" in row for row in rows), "на карте нет помощника «@»")
        return {"unknown_cells_before_vision": sum(row.count("?") for row in rows)}

    def resources():
        check_resources(r.ok_call("resources", {"radius": RESOURCE_RADIUS}, HELPER))

    def stock():
        check_stock(r.ok_call("stock", {}, HELPER))

    def ghosts():
        check_ghosts(r.ok_call("ghosts", {}, HELPER))

    def recipes():
        check_recipes(r.ok_call("recipes", {}, HELPER))

    def rates():
        check_rates(r.ok_call("rates", {}, HELPER))

    def vision():
        d = r.ok_call("vision", {"on": True}, HELPER)
        need(d.get("on") is True, f"vision: {d!r}")
        c.sleep(VISION_WAIT_S)
        last = {}

        def clean():
            rows = check_map(r.ok_call("map", {"radius": MAP_RADIUS}, HELPER))
            last["unknown"] = sum(row.count("?") for row in rows)
            return last["unknown"] == 0

        clean_now = clean()
        late = False
        if not clean_now:
            late = True
            clean_now = c.poll(clean, VISION_EXTRA_S, POLL_S)
        need(clean_now, f"после {VISION_WAIT_S:.0f} с обзора на карте осталось «?»: {last['unknown']} клеток")
        return {"late": late}

    def say():
        d = r.ok_call("say", {"text": "core_smoke: hello from the live test"}, HELPER)
        need(is_map(d), f"say: {d!r}")

    def wait_job():
        d = r.ok_call("act", {"do": "wait", "args": {"seconds": 1}}, HELPER)
        job = field(d, "job", is_int, "целое")
        need(d.get("queued_before") == 0, f"queued_before={d.get('queued_before')!r}")
        found = {}
        since = {"v": state["seq0"]}

        def got():
            ev = r.ok_call("events", {"since": since["v"], "helper": HELPER})
            need(is_int(ev.get("seq")) and is_list(ev.get("events")), "events: seq/events")
            since["v"] = ev["seq"]  # дальше с seq из ответа (EVENTS.md), иначе >100 событий вытеснят job_done
            for e in as_list(ev["events"]):
                if e.get("kind") in ("job_done", "job_failed") and (e.get("data") or {}).get("job") == job:
                    found["event"] = e
                    return True
            return False

        c.sleep(1.0)
        need(c.poll(got, JOB_TIMEOUT_S, POLL_S), f"за {JOB_TIMEOUT_S:.0f} с нет job_done для задачи {job}")
        check_event(found["event"], job)
        return {"job": job}

    def jobs():
        d = r.ok_call("jobs", {}, HELPER)
        need(as_list(d.get("queue")) == [] and d.get("active") is None, f"jobs: {d!r}"[:200])

    def remove():
        d = r.ok_call("helper_remove", {}, HELPER)
        state["spawned"] = False
        need(isinstance(d, dict) or d == [], f"helper_remove: {d!r}")
        lst = as_list(r.ok_call("helper_list")["helpers"])
        mine = [h for h in lst if h.get("id") == HELPER]
        need(len(mine) == 1 and mine[0].get("state") == "removed", f"helper_list: {lst!r}"[:200])
        need(is_int(mine[0].get("cooldown_s")) and mine[0]["cooldown_s"] > 0, "после remove нужен cooldown_s > 0")

    try:
        r.step("hello", hello)
        if not r.step("helper_spawn", spawn):
            return finish(r, aborted="helper_spawn не удался: дальше без помощника нельзя")
        for name, fn in (("helper_list", helper_list_alive), ("state", st), ("map", map_before),
                         ("resources", resources), ("stock", stock), ("ghosts", ghosts),
                         ("recipes", recipes), ("rates", rates), ("vision", vision), ("say", say),
                         ("act_wait_events", wait_job), ("jobs", jobs)):
            r.step(name, fn)
        r.step("helper_remove", remove)
        return finish(r)
    finally:
        if state["spawned"]:
            try:
                c.call("helper_remove", {}, HELPER)
            except Exception:  # уборка не прячет основной результат
                pass


def finish(r, aborted=None):
    failed = [s["name"] for s in r.steps if not s["ok"]]
    out = {"ok": not failed and aborted is None, "steps": r.steps, "failed": failed}
    if aborted:
        out["aborted"] = aborted
    return out
