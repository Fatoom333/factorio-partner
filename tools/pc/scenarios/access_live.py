"""Живой сценарий `access` (поток V3, ревизия 3.3): суша и выходы с участка. Контракт — STATE.md «access».

Где смотреть, сценарий берёт из самого сейва: участок с жидкостью (на Вулканусе — лава) и участок без
неё он ищет операцией `access` вокруг помощника и кольцами дальше. Имён плиток в сценарии нет:
что считается жидкостью, решает мод по правилам игры (PROTOCOL §6.12), сценарий сверяет ответы
`access` и `map` между собой.

 1. hello / helper_spawn — помощник у последней позиции хозяина
 2. access по умолчанию — участок 64×64 вокруг помощника: форма ответа, `reachable`
 3. поиск участков       — точки вокруг помощника: с жидкостью (`liquid > 0` и есть суша) и без неё
 4. участок у жидкости   — land, liquid, liquids, exits с neck, best; имена плиток те же, что в `map`
 5. участок без жидкости — выходы есть, лучший — wide, предупреждений о выходах нет
 6. форма area           — тот же участок через `area`: те же числа
 7. отказы               — radius 65, radius 0, area вместе с radius/center, сторона 129, лишнее поле
 8. без помощника        — `access {center}`: ответ либо no_player (хозяин офлайн)
 9. только чтение        — задач и призраков не появилось, module_errors не вырос
10. helper_remove

Только `/partner <JSON>` через client.call; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [...], "failed": [имена], "found": {...}}.
"""
from __future__ import annotations

MODS = ["factorio-partner"]

HELPER = "access1"
RADIUS = 32
SIDES = ("north", "east", "south", "west")
NECKS = ("wide", "medium", "narrow")
NECK_RANK = {"wide": 3, "medium": 2, "narrow": 1}
MAX_EXITS = 8
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] op (access|map) failed"
# точки поиска: у помощника, потом кольца (участки 64×64 почти вплотную)
OFFSETS = ((0, 0),) + tuple(
    (dx * step, dy * step)
    for step in (64, 128, 192)
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (-1, 1), (1, -1), (-1, -1))
)


class Check(AssertionError):
    pass


def need(cond, text):
    if not cond:
        raise Check(text)


def is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def is_int(v):
    return (isinstance(v, int) and not isinstance(v, bool)) or (isinstance(v, float) and v == int(v))


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def as_map(v):
    return {} if v == [] else v


def side_of(area):
    return (area["right_bottom"]["x"] - area["left_top"]["x"], area["right_bottom"]["y"] - area["left_top"]["y"])


def check_access(d):
    """Форма ответа `access` (STATE.md). → (выходы, предупреждения)."""
    need(isinstance(d, dict), f"ответ не объект: {str(d)[:80]}")
    area = d.get("area")
    need(isinstance(area, dict) and all(is_int((area.get(k) or {}).get(c)) for k in ("left_top", "right_bottom")
                                        for c in ("x", "y")), f"area: {str(area)[:120]}")
    w, h = side_of(area)
    need(1 <= w <= 128 and 1 <= h <= 128, f"сторона area: {w}x{h}")
    need(is_int(d.get("land")) and d["land"] >= 0, f"land={d.get('land')!r}")
    need(is_int(d.get("liquid")) and d["liquid"] >= 0, f"liquid={d.get('liquid')!r}")
    need(d["land"] + d["liquid"] <= w * h, f"land+liquid={d['land'] + d['liquid']} больше площади {w * h}")
    liquids = as_map(d.get("liquids"))
    need(isinstance(liquids, dict), "liquids: объект")
    need(all(isinstance(k, str) and k and is_int(n) and n > 0 for k, n in liquids.items()), f"liquids: {liquids!r}")
    need(sum(liquids.values()) <= d["liquid"], f"liquids в сумме больше liquid: {liquids!r}")
    need((d["liquid"] > 0) == bool(liquids), f"liquid={d['liquid']}, а liquids={liquids!r}")
    need(isinstance(d.get("enclosed"), bool), f"enclosed={d.get('enclosed')!r}")
    exits = as_list(d.get("exits"))
    need(isinstance(exits, list) and len(exits) <= MAX_EXITS, f"exits: {str(exits)[:120]}")
    warnings = as_list(d.get("warnings"))
    need(isinstance(warnings, list) and all(isinstance(x, str) for x in warnings), f"warnings: {warnings!r}")
    fx0, fy0 = area["left_top"]["x"] - 8, area["left_top"]["y"] - 8
    fx1, fy1 = area["right_bottom"]["x"] + 7, area["right_bottom"]["y"] + 7
    last = None
    for e in exits:
        need(isinstance(e, dict) and e.get("side") in SIDES and e.get("neck") in NECKS, f"exits[]: {str(e)[:120]}")
        need(is_int(e.get("width")) and e["width"] >= 1, f"exits[].width: {str(e)[:120]}")
        pos = e.get("pos") or {}
        need(is_int(pos.get("x")) and is_int(pos.get("y")), f"exits[].pos: {str(e)[:120]}")
        on_frame = {"north": pos["y"] == fy0, "south": pos["y"] == fy1,
                    "west": pos["x"] == fx0, "east": pos["x"] == fx1}[e["side"]]
        need(on_frame and fx0 <= pos["x"] <= fx1 and fy0 <= pos["y"] <= fy1,
             f"выход не на рамке (участок + 8 клеток): {str(e)[:120]}")
        # neck — самое узкое место по дороге до выхода (STATE.md «access»), а width — ширина по рамке:
        # между собой они не связаны (wide при ширине по рамке 4 — законно), порядок проверяется ниже.
        key = (NECK_RANK[e["neck"]], e["width"])
        need(last is None or key <= last, "выходы не по порядку: широкие первыми")
        last = key
    if d["enclosed"]:
        need(not exits and "best" not in d, "enclosed, а выходы или best есть")
        need("enclosed" in warnings, f"enclosed без предупреждения: {warnings!r}")
    else:
        need(exits and d.get("best") == exits[0]["side"], f"best={d.get('best')!r}, первый выход {exits[:1]!r}")
        need("enclosed" not in warnings, "предупреждение enclosed при выходах")
        need(("narrow_access" in warnings) == (exits[0]["neck"] == "narrow"),
             f"narrow_access={warnings!r} при лучшем выходе {exits[0]['neck']}")
    need("reachable" not in d or isinstance(d["reachable"], bool), f"reachable={d.get('reachable')!r}")
    for x in warnings:
        need(x in ("enclosed", "narrow_access") or x.startswith(("narrow_access:", "not_charted:")),
             f"неизвестное предупреждение {x!r}")
    return exits, warnings


def find_sites(client, base, helper, want_dry=True):
    """Участки вокруг base: первый с жидкостью и сушей и первый без жидкости. → (у жидкости, сухой, журнал)."""
    wet = dry = None
    log = []
    for dx, dy in OFFSETS:
        center = {"x": base["x"] + dx, "y": base["y"] + dy}
        r = client.call("access", {"center": center, "radius": RADIUS}, helper)
        if not r.get("ok"):
            log.append({"center": center, "code": (r.get("error") or {}).get("code")})
            continue
        d = r["data"]
        charted = not any(str(x).startswith("not_charted") for x in as_list(d.get("warnings")))
        log.append({"center": center, "land": d.get("land"), "liquid": d.get("liquid"), "charted": charted})
        if wet is None and (d.get("liquid") or 0) > 0 and (d.get("land") or 0) > 0:
            wet = (center, d)
        if dry is None and d.get("liquid") == 0 and charted and (d.get("land") or 0) > 0:
            dry = (center, d)
        if wet and (dry or not want_dry):
            break
    return wet, dry, log


def run(client) -> dict:
    c = client
    steps = []
    found = {}
    st = {"spawned": False, "errors0": 0, "online": 0, "base": None, "wet": None, "dry": None}

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

    def code_of(args, helper=HELPER):
        reply = c.call("access", args, helper)
        return None if reply.get("ok") else (reply.get("error") or {}).get("code")

    def hello():
        d = c.call_ok("hello")
        need(d.get("proto") == 1, f"proto={d.get('proto')!r}")
        need(is_int(d.get("module_errors")), f"module_errors={d.get('module_errors')!r}")
        st["errors0"] = d["module_errors"]
        st["online"] = d.get("players_online") or 0
        return {"mod": d.get("mod"), "owner": d.get("owner"), "players_online": st["online"]}

    def spawn():
        d = c.call_ok("helper_spawn", {}, HELPER)
        st["spawned"] = True
        st["base"] = c.call_ok("state", {}, HELPER)["pos"]
        return {"surface": d.get("surface"), "pos": st["base"]}

    def default():
        d = c.call_ok("access", {}, HELPER)
        exits, warnings = check_access(d)
        need(side_of(d["area"]) == (2 * RADIUS, 2 * RADIUS), f"участок по умолчанию: {d['area']!r}")
        a, b = d["area"], st["base"]
        need(a["left_top"]["x"] <= b["x"] < a["right_bottom"]["x"] and a["left_top"]["y"] <= b["y"] < a["right_bottom"]["y"],
             "помощник не внутри участка по умолчанию")
        need(isinstance(d.get("reachable"), bool), "помощник внутри рамки, а reachable нет")
        return {"land": d["land"], "liquid": d["liquid"], "exits": len(exits), "best": d.get("best"),
                "reachable": d["reachable"], "warnings": warnings}

    def search():
        wet, dry, log = find_sites(c, st["base"], HELPER)
        st["wet"], st["dry"] = wet, dry
        found["sites"] = log
        need(wet is not None, "рядом с помощником (до 192 клеток) нет участка с жидкостью и сушей")
        need(dry is not None, "рядом с помощником нет открытого участка без жидкости")
        return {"wet": wet[0], "dry": dry[0], "tried": len(log)}

    def wet_site():
        center, d = st["wet"]
        exits, warnings = check_access(d)
        need(d["liquid"] > 0 and d["land"] > 0, f"land={d['land']}, liquid={d['liquid']}")
        liquids = as_map(d["liquids"])
        # те же плитки называет карта (окно карты 65×65 накрывает участок 64×64)
        m = c.call_ok("map", {"center": center, "radius": RADIUS}, HELPER)
        on_map = as_map(m.get("liquids"))
        need(isinstance(on_map, dict) and on_map, f"map.liquids пуст рядом с жидкостью: {str(on_map)[:120]}")
        missing = sorted(set(liquids) - set(on_map))
        need(not missing, f"access называет плитки {missing}, которых нет в map.liquids {sorted(on_map)}")
        need(any("~" in row for row in as_list(m.get("rows"))), "на карте участка с жидкостью нет ни одной `~`")
        found["wet"] = {"center": center, "land": d["land"], "liquid": d["liquid"], "liquids": liquids,
                        "exits": exits, "best": d.get("best"), "enclosed": d["enclosed"], "warnings": warnings}
        return found["wet"]

    def dry_site():
        center, d = st["dry"]
        exits, warnings = check_access(d)
        need(d["liquid"] == 0 and not as_map(d["liquids"]), f"liquid={d['liquid']}")
        need(not d["enclosed"] and exits, "участок без жидкости, а выходов нет")
        found["dry"] = {"center": center, "land": d["land"], "exits": exits, "best": d.get("best"), "warnings": warnings}
        need(exits[0]["neck"] == "wide", f"лучший выход участка без жидкости — {exits[0]['neck']}: {exits[0]!r}")
        need("narrow_access" not in warnings, f"narrow_access на участке без жидкости: {warnings!r}")
        return found["dry"]

    def area_form():
        _, d = st["wet"]
        again = c.call_ok("access", {"area": d["area"]}, HELPER)
        check_access(again)
        for k in ("area", "land", "liquid", "enclosed"):
            need(again[k] == d[k], f"через area {k}={again[k]!r}, через center — {d[k]!r}")
        need(as_map(again["liquids"]) == as_map(d["liquids"]), "liquids через area другие")
        need(len(as_list(again["exits"])) == len(as_list(d["exits"])), "число выходов через area другое")
        return {"land": again["land"], "liquid": again["liquid"]}

    def refusals():
        area = st["wet"][1]["area"] if st["wet"] else {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 8, "y": 8}}
        big = {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 129, "y": 8}}
        cases = [
            ({"radius": 65}, "limit"),
            ({"radius": 0}, "bad_args"),
            ({"radius": 2.5}, "bad_args"),
            ({"area": area, "radius": 8}, "bad_args"),
            ({"area": area, "center": {"x": 0, "y": 0}}, "bad_args"),
            ({"area": big}, "limit"),
            ({"center": {"x": 0, "y": 0}, "near": "player"}, "bad_args"),
            ({"zoom": 2}, "bad_args"),
        ]
        for args, want in cases:
            got = code_of(args)
            need(got == want, f"access {args!r}: ждали {want}, пришло {got!r}")
        return {"checked": len(cases)}

    def without_helper():
        center = (st["wet"] or st["dry"] or (st["base"], None))[0]
        reply = c.call("access", {"center": center, "radius": 8})
        if reply.get("ok"):
            check_access(reply["data"])
            return {"ok": True, "land": reply["data"]["land"]}
        code = (reply.get("error") or {}).get("code")
        need(code == "no_player" and not st["online"], f"без помощника: {code!r} при players_online={st['online']}")
        return {"code": code}

    def read_only():
        j = c.call_ok("jobs", {}, HELPER)
        need(as_list(j.get("queue")) == [] and j.get("active") is None, "access поставил задачу")
        g = c.call_ok("ghosts", {"radius": 64}, HELPER)
        found["ghosts_near"] = g.get("count")
        d = c.call_ok("hello")
        need(d.get("module_errors") == st["errors0"], f"module_errors вырос до {d.get('module_errors')!r}")

    def remove():
        c.call_ok("helper_remove", {}, HELPER)
        st["spawned"] = False

    try:
        if not step("hello", hello):
            return finish(steps, found, aborted="hello не прошёл")
        if not step("helper_spawn", spawn):
            return finish(steps, found, aborted="helper_spawn не удался")
        step("default", default)
        step("search", search)
        if st["wet"]:
            step("wet_site", wet_site)
            step("area_form", area_form)
        if st["dry"]:
            step("dry_site", dry_site)
        step("refusals", refusals)
        step("without_helper", without_helper)
        step("read_only", read_only)
        step("helper_remove", remove)
        return finish(steps, found)
    finally:
        if st["spawned"]:
            try:
                c.call("helper_remove", {}, HELPER)
            except Exception:  # уборка не прячет основной результат
                pass


def finish(steps, found, aborted=None):
    failed = [s["name"] for s in steps if not s["ok"]]
    out = {"ok": not failed and aborted is None, "steps": steps, "failed": failed, "found": found,
           "log_must_not_match": LOG_MUST_NOT_MATCH}
    if aborted:
        out["aborted"] = aborted
    return out
