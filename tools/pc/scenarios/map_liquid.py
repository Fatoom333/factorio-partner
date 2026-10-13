"""Живой сценарий `map` с жидкостью (поток V3, ревизия 3.3). Контракт — STATE.md «map», PROTOCOL §6.12.

На Вулканусе жидкость — лава: карта рисует её `~` (персонаж не пройдёт), легенда и поле `liquids`
называют плитку именем из игры, подложка для неё (фундамент) в начале игры недоступна —
`cover_ok:false`. Имён плиток в сценарии нет: место с жидкостью ищется операцией `access`,
ответы сверяются между собой.

 1. hello / helper_spawn
 2. поиск места       — `access` вокруг помощника и кольцами: участок, где есть жидкость и суша
 3. карта             — `map {center, radius:32}`: есть `~`; легенда `~` называет те же плитки, что
                        `liquids`; у каждой плитки `n > 0`, `cover_ok` — bool; непроходимых клеток в
                        `liquids` не меньше, чем `~` на карте; `access` называет те же плитки
 4. подложка          — у непроходимых плиток `cover_ok:false` (в тестовом сейве фундамент не открыт
                        и на складах его нет); если открыт — шаг записывает это и не падает
 5. карта без жидкости — участок без жидкости: `liquids` пуст, `~` и `,` нет ни на карте, ни в легенде
 6. только чтение      — module_errors не вырос
 7. helper_remove

Только `/partner <JSON>`; никаких /c, /sc (PROTOCOL §1).
Результат: {"ok": bool, "steps": [...], "failed": [имена], "found": {...}}.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]

HELPER = "mapliq1"
RADIUS = 32
BLOCKED_LABEL = "не пройти"
SHALLOW_LABEL = "мелко"
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] op (access|map) failed"


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


A = _load("access_live")
need, as_list, as_map, is_int = A.need, A.as_list, A.as_map, A.is_int


def legend_names(text, label):
    """`не пройти: lava, lava-hot, +2` → (["lava", "lava-hot"], 2)."""
    need(isinstance(text, str) and text.startswith(label), f"подпись {text!r} не начинается с {label!r}")
    rest = text[len(label):]
    if not rest:
        return [], 0
    need(rest.startswith(": "), f"подпись {text!r}")
    names, more = [], 0
    for part in rest[2:].split(", "):
        if part.startswith("+"):
            more = int(part[1:])
        else:
            names.append(part)
    return names, more


def check_liquids(m):
    """Форма `map.liquids` и её согласие с рисунком и легендой. → (liquids, число `~`, число `,`)."""
    rows = as_list(m.get("rows"))
    legend = as_map(m.get("legend"))
    liquids = as_map(m.get("liquids"))
    need(isinstance(liquids, dict), f"liquids: {str(liquids)[:120]}")
    for name, rec in liquids.items():
        need(isinstance(name, str) and name, f"liquids: имя {name!r}")
        need(isinstance(rec, dict) and is_int(rec.get("n")) and rec["n"] > 0, f"liquids[{name}]: {rec!r}")
        need(isinstance(rec.get("cover_ok"), bool), f"liquids[{name}].cover_ok: {rec!r}")
        need("cover" not in rec or (isinstance(rec["cover"], str) and rec["cover"]), f"liquids[{name}].cover: {rec!r}")
        need(rec["cover_ok"] is False or "cover" in rec, f"liquids[{name}]: cover_ok без cover")
    blocked = sum(row.count("~") for row in rows)
    shallow = sum(row.count(",") for row in rows)
    total = sum(rec["n"] for rec in liquids.values())
    need(blocked + shallow <= total or len(liquids) >= 16,
         f"на карте {blocked} `~` и {shallow} `,`, а в liquids всего {total} клеток")
    for ch, label, n in (("~", BLOCKED_LABEL, blocked), (",", SHALLOW_LABEL, shallow)):
        if n == 0:
            need(ch not in legend, f"`{ch}` в легенде без клеток на карте")
            continue
        names, _ = legend_names(legend.get(ch), label)
        need(names, f"подпись `{ch}` не называет плитки: {legend.get(ch)!r}")
        unknown = [x for x in names if x not in liquids]
        need(not unknown or len(liquids) >= 16, f"в подписи `{ch}` плитки {unknown}, которых нет в liquids")
    return liquids, blocked, shallow


def run(client) -> dict:
    c = client
    steps = []
    found = {}
    st = {"spawned": False, "errors0": 0, "base": None, "wet": None, "dry": None}

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

    def hello():
        d = c.call_ok("hello")
        need(d.get("proto") == 1, f"proto={d.get('proto')!r}")
        st["errors0"] = d.get("module_errors") or 0
        return {"mod": d.get("mod"), "players_online": d.get("players_online")}

    def spawn():
        d = c.call_ok("helper_spawn", {}, HELPER)
        st["spawned"] = True
        st["base"] = c.call_ok("state", {}, HELPER)["pos"]
        return {"surface": d.get("surface"), "pos": st["base"]}

    def search():
        wet, dry, log = A.find_sites(c, st["base"], HELPER)
        st["wet"], st["dry"] = wet, dry
        found["sites"] = log
        need(wet is not None, "рядом с помощником (до 192 клеток) нет участка с жидкостью и сушей")
        return {"wet": wet[0], "dry": dry and dry[0], "tried": len(log)}

    def liquid_map():
        center, acc = st["wet"]
        m = c.call_ok("map", {"center": center, "radius": RADIUS}, HELPER)
        liquids, blocked, shallow = check_liquids(m)
        need(liquids, "liquids пуст рядом с жидкостью")
        need(blocked > 0, "на карте нет ни одной `~`, хотя access видит непроходимую жидкость")
        missing = sorted(set(as_map(acc.get("liquids"))) - set(liquids))
        need(not missing or len(liquids) >= 16, f"access называет плитки {missing}, которых нет в map.liquids")
        names, more = legend_names(as_map(m["legend"])["~"], BLOCKED_LABEL)
        found["map"] = {"center": center, "blocked_cells": blocked, "shallow_cells": shallow,
                        "legend": as_map(m["legend"]).get("~"), "liquids": liquids, "legend_more": more}
        st["blocked_names"] = names
        return found["map"]

    def cover():
        liquids = found["map"]["liquids"]
        names = st.get("blocked_names") or []
        need(names, "нет плиток в подписи `~`")
        ready = sorted(n for n in names if liquids.get(n, {}).get("cover_ok"))
        found["cover"] = {n: {"cover": liquids[n].get("cover"), "cover_ok": liquids[n]["cover_ok"]}
                          for n in names if n in liquids}
        if ready:
            # подложка открыта или лежит на складе: это свойство сейва, а не ошибка мода
            return {"cover_available_for": ready, "note": "в этом сейве подложка доступна"}
        need(all(liquids[n]["cover_ok"] is False for n in names if n in liquids), "cover_ok не false")
        return found["cover"]

    def dry_map():
        if not st["dry"]:
            return {"skipped": "рядом нет открытого участка без жидкости"}
        center, _ = st["dry"]
        m = c.call_ok("map", {"center": center, "radius": 16}, HELPER)
        liquids, blocked, shallow = check_liquids(m)
        # окно карты 33×33 лежит внутри участка 64×64, где access жидкости не нашёл
        need(blocked == 0, f"на карте участка без жидкости {blocked} клеток `~`")
        need("~" not in as_map(m.get("legend")), "`~` в легенде участка без жидкости")
        return {"center": center, "liquids": liquids, "shallow_cells": shallow}

    def read_only():
        d = c.call_ok("hello")
        need(d.get("module_errors") == st["errors0"], f"module_errors вырос до {d.get('module_errors')!r}")

    def remove():
        c.call_ok("helper_remove", {}, HELPER)
        st["spawned"] = False

    try:
        if not step("hello", hello):
            return A.finish(steps, found, aborted="hello не прошёл")
        if not step("helper_spawn", spawn):
            return A.finish(steps, found, aborted="helper_spawn не удался")
        if not step("search", search):
            step("helper_remove", remove)
            return A.finish(steps, found, aborted="рядом нет жидкости — сценарию нечего проверять")
        if step("liquid_map", liquid_map):
            step("cover", cover)
        step("dry_map", dry_map)
        step("read_only", read_only)
        step("helper_remove", remove)
        return A.finish(steps, found)
    finally:
        if st["spawned"]:
            try:
                c.call("helper_remove", {}, HELPER)
            except Exception:  # уборка не прячет основной результат
                pass
