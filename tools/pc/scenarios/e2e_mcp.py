"""Живой сценарий: MCP-сервер с настоящим модом (поток K, TESTING.md §4, docs/E2E.md).

Идёт через настоящий пакет `server/factorio_partner` (bridge + core, без слоя stdio): клиент
сценария — `server_client.ServerClient`, его `tool(...)` — это `op_*`, стоящие за инструментами
`partner_*`. Проверяется связка «сервер ↔ мод» целиком: ключ помощника, проверки аргументов на
сервере, два RCON-соединения, курсор событий и ожидание.

 1. admin hello / spawn   — служебные операции оркестра: мод отвечает proto=1, помощник появился
 2. partner_brief         — правила для агента (заметки forge могут быть недоступны — это не ошибка)
 3. partner_state         — помощник, позиция, tick и seq
 4. partner_map           — карта 17×17 вокруг помощника
 5. partner_find          — поиск по всей базе предмета, который точно лежит на складе
 6. partner_act(walk)     — задача принята, `partner_wait` доводит до `job_done`, помощник на месте
 7. partner_wait          — без событий: `timed_out`, пустой список, курсор не уходит назад
 8. partner_reflex        — список рефлексов ставится и снимается (полная замена)
 9. отказы сервера        — чужой ключ → `access denied`; неизвестное действие и радиус сверх границы
                            не уходят в мод (`bad_args` / `limit`)
10. сверка в обход сервера — `jobs` и `helper_list` мода конвертом: очередь пуста, помощник жив
11. уборка                — admin remove
Только `/partner <JSON>` (и сервер, и стенд другого не шлют); никаких /c, /sc, /silent-command.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
RUNNER = "server"
HELPER = "e2e"
WALK_STEP = 6            # на сколько клеток отойти
WALK_RADIUS = 1
WALK_TIMEOUT_S = 90.0
FIND_FALLBACK = ("iron-plate", "steel-plate", "stone", "coal", "copper-plate", "calcite")


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


E = _load("_e2e")


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def is_pos(v):
    return isinstance(v, dict) and all(isinstance(v.get(k), (int, float)) and not isinstance(v.get(k), bool)
                                       for k in ("x", "y"))


def step_brief(client, api, ctx):
    d = client.tool("brief")
    need(isinstance(d, dict) and d.get("helper") == HELPER, f"brief.helper = {d.get('helper')!r}")
    need(isinstance(d.get("rules"), str) and "partner_act" in d["rules"], "brief.rules пуст")
    notes = d.get("notes")
    need(notes is None or isinstance(notes, str), "brief.notes: строка или null")
    need(notes is not None or isinstance(d.get("notes_missing"), str), "brief: нет ни заметок, ни причины")
    # заметки профиля — записи хозяина: в результат идут только их размер и причина, почему их нет
    return {"keys": sorted(d), "notes_chars": len(notes) if notes else 0, "notes_missing": d.get("notes_missing")}


def step_state(client, api, ctx):
    d = client.tool("state")
    need(d.get("helper") == HELPER, f"state.helper = {d.get('helper')!r}")
    need(is_pos(d.get("pos")), "state.pos")
    need(isinstance(d.get("surface"), str) and d["surface"], "state.surface")
    need(is_int(d.get("tick")) and is_int(d.get("seq")), "state: нет tick / seq")
    need(isinstance(d.get("reach"), dict), "state.reach")
    ctx["pos"], ctx["tick"] = d["pos"], d["tick"]
    return {"pos": d["pos"], "surface": d["surface"], "inv_free": d.get("inv_free")}


def step_map(client, api, ctx):
    d = client.tool("map", radius=8)
    rows = d.get("rows")
    need(isinstance(rows, list) and len(rows) == 17, f"map.rows: {len(rows) if isinstance(rows, list) else rows!r} строк, ждали 17")
    need(all(isinstance(r, str) and len(r) == 17 for r in rows), "map.rows: строки по 17 символов")
    need(any("@" in r for r in rows), "на карте нет помощника (@)")
    need(isinstance(d.get("legend"), dict) and "@" in d["legend"], "map.legend без @")
    box = d.get("bbox") or {}
    need(box.get("x1", 0) - box.get("x0", 0) == 16, f"map.bbox: {box}")
    return {"bbox": box, "entities": len(E.as_list(d.get("entities")))}


def step_find(client, api, ctx):
    stock = client.tool("stock", radius=128, limit=20)
    total = E.as_map(stock.get("total"))
    item = max(total, key=total.get) if total else None
    tried = []
    for name in ([item] if item else []) + list(FIND_FALLBACK):
        r = client.try_tool("find", item=name, kinds=["storage"], limit=5)
        tried.append({"item": name, "ok": r["ok"], "code": (r.get("error") or {}).get("code")})
        if not r["ok"]:
            continue
        d = r["data"]
        need(d.get("item") == name, f"find.item = {d.get('item')!r}")
        groups = E.as_list(d.get("groups"))
        totals = E.as_map(d.get("total"))
        need(is_int(totals.get("storage")), "find.total.storage")
        if not groups:
            continue
        g = groups[0]
        need(g.get("kind") == "storage" and is_pos(g.get("pos")) and is_int(g.get("count")), f"find: группа {g}")
        if name == item:
            need(sum(int(x.get("amount") or 0) for x in groups) > 0, "find не видит предмет, который видит stock")
        return {"item": name, "groups": len(groups), "storage": totals.get("storage"), "from_stock": name == item}
    raise Check(f"find не нашёл на складах ничего из {tried}")


def step_walk(client, api, ctx):
    start = ctx["pos"]
    last = None
    for dx, dy in ((WALK_STEP, 0), (0, WALK_STEP), (-WALK_STEP, 0), (0, -WALK_STEP)):
        to = {"x": round(start["x"] + dx, 1), "y": round(start["y"] + dy, 1)}
        last = api.act("walk", {"to": to, "radius": WALK_RADIUS}, WALK_TIMEOUT_S)
        if last["kind"] == "job_done":
            d = client.tool("state")
            gap = E.dist(d["pos"], to)
            need(gap <= WALK_RADIUS + 1.0, f"после walk помощник в {d['pos']}, до цели {gap:.1f}")
            need(E.dist(d["pos"], start) >= 1.0, "помощник не сдвинулся")
            need(d["tick"] > ctx["tick"], "tick не вырос")
            need(not d.get("job"), f"после job_done у помощника задача: {d.get('job')}")
            ctx["pos"] = d["pos"]
            return {"to": to, "pos": d["pos"], "seconds": last["seconds"], "job": last["job"],
                    "walked": E.detail_of(last).get("walked"), "kinds": last["kinds"][-4:]}
        if last["kind"] == "refused" or E.code_of(last) not in ("path_failed", "stuck", "not_charted"):
            break
    raise Check(f"walk не дошёл: {E.brief(last) if last else None}")


def step_wait(client, api, ctx):
    before = client.tool("wait", timeout=0, quiet=True)   # забрать всё накопленное
    d = client.tool("wait", timeout=2, quiet=True)
    need(d.get("timed_out") is True, f"wait без событий: timed_out = {d.get('timed_out')!r}")
    loud = [ev for ev in E.as_list(d.get("events")) if ev.get("loud")]
    need(not loud, f"wait без дел вернул важные события: {[ev.get('kind') for ev in loud]}")
    need(is_int(d.get("seq")) and d["seq"] >= before.get("seq", 0), "wait: курсор ушёл назад")
    return {"seq": d["seq"], "timed_out": True}


def step_reflex(client, api, ctx):
    want = [{"type": "watch", "radius": 16, "every_s": 30}]
    d = client.tool("reflex", set=want)
    got = E.as_list(d.get("set"))
    need(len(got) == 1 and got[0].get("type") == "watch", f"reflex.set = {d.get('set')!r}")
    need(got[0].get("radius") == 16 and got[0].get("every_s") == 30, f"параметры рефлекса: {got[0]}")
    d = client.tool("reflex", set=[])
    need(not E.as_list(d.get("set")), f"после пустого списка рефлексы остались: {d.get('set')!r}")
    r = client.try_tool("reflex", set=[{"type": "no_such_reflex"}])
    need(not r["ok"] and r["error"]["code"] == "bad_args", f"неизвестный рефлекс: {r}")
    return {"set": got, "cleared": True}


def step_refusals(client, api, ctx):
    out = {}
    try:
        client.tool_as("state", HELPER, "x" * 48)
        raise Check("чужой ключ прошёл")
    except Exception as e:
        if isinstance(e, Check):
            raise
        need(getattr(e, "code", None) == "access denied", f"чужой ключ: {e}")
        out["wrong_key"] = "access denied"
    r = client.try_tool("act", do="teleport", args={"to": {"x": 0, "y": 0}})
    need(not r["ok"] and r["error"]["code"] == "bad_args", f"неизвестное действие: {r}")
    need("unknown action" in str(r["error"].get("text")), f"отказ пришёл не от сервера: {r}")
    r = client.try_tool("map", radius=64)
    need(not r["ok"] and r["error"]["code"] == "limit", f"радиус сверх границы: {r}")
    r = client.try_tool("act", do="walk", args={"to": {"x": 0, "y": 0}, "speed": 100})
    need(not r["ok"] and r["error"]["code"] == "bad_args", f"лишнее поле действия: {r}")
    need("unknown field" in str(r["error"].get("text")), f"отказ пришёл не от сервера: {r}")
    jobs = client.call_ok("jobs", {}, HELPER)
    need(not jobs.get("active") and not E.as_list(jobs.get("queue")), f"отказанное действие попало в очередь: {jobs}")
    out["bad_requests"] = ["bad_args", "limit", "bad_args"]
    return out


def step_direct(client, api, ctx):
    jobs = client.call_ok("jobs", {}, HELPER)
    need(not jobs.get("active") and not E.as_list(jobs.get("queue")), f"после сценария в очереди: {jobs}")
    helpers = E.as_list(client.call_ok("helper_list").get("helpers"))
    mine = [h for h in helpers if h.get("id") == HELPER]
    need(len(mine) == 1 and mine[0].get("state") == "alive", f"helper_list: {mine}")
    hello = client.call_ok("hello")
    need(hello.get("module_errors") == 0, f"module_errors = {hello.get('module_errors')}")
    return {"jobs": "empty", "state": "alive", "module_errors": 0}


def step_remove(client, api, ctx):
    d = client.admin("remove", helper=HELPER)
    r = client.try_tool("state")
    need(not r["ok"] and r["error"]["code"] == "no_helper", f"state после удаления: {r}")
    return {"removed": True, "corpse": bool(E.as_map(d.get("data")).get("corpse"))}


STEPS = (("brief", step_brief), ("state", step_state), ("map", step_map), ("find", step_find),
         ("walk", step_walk), ("wait", step_wait), ("reflex", step_reflex), ("refusals", step_refusals),
         ("direct", step_direct), ("remove", step_remove))


def run(client) -> dict:
    result = {"scenario": "e2e_mcp", "steps": [], "failed": []}
    if not callable(getattr(client, "tool", None)):
        return E.fail_setup(result, "сценарию нужен настоящий пакет сервера (RUNNER = \"server\", server_client.py)")
    api = E.McpApi(client)
    if not E.start(api, result):
        return result
    ctx = {}
    for name, fn in STEPS:
        entry = {"step": name}
        try:
            entry.update(ok=True, info=fn(client, api, ctx))
        except Check as e:
            entry.update(ok=False, text=str(e))
        except Exception as e:  # отказ сервера (ToolError) или транспорта — шаг не прошёл, идём дальше
            if getattr(e, "code", None) is None and getattr(e, "kind", None) is None:
                raise
            entry.update(ok=False, text=str(e))
        result["steps"].append(entry)
        if not entry["ok"]:
            result["failed"].append(name)
            if name in ("state",):
                break
    result["server_calls"] = getattr(client, "calls", None)
    result["ok"] = not result["failed"]
    return result
