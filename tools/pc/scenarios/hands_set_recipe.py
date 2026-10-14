"""Живой сценарий ревизии 3.13: смена рецепта стоящей машины (`act set_recipe`) и метки в чате.

Ход (сервер без окна, копия сейва):
1. `hello`, `helper_spawn`; ближайшая сборочная машина хозяина по `map` (types=[assembling-machine]).
2. `act set_recipe {target, recipe:"iron-gear-wheel"}` → job_done, `detail.recipe`; если уже стоял он —
   сначала на `pipe`. Потом возврат прежнего рецепта (`detail.was`; не было — снять).
3. `say` с местом «(x,y)» и меткой `[gps]` — мод принял (текст чата сервер без игроков не читает;
   сборку метки проверяет юнит-тест core_misc).
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import importlib.util
import os


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


P = _load("build_place")
HELPER = P.HELPER


def nearest_machine(client, result):
    pos = P.helper_state(client)["pos"]
    best = None
    for dx in (0, -64, 64):
        for dy in (0, -64, 64):
            data = client.call_ok("map", {"center": {"x": pos["x"] + dx, "y": pos["y"] + dy}, "radius": 32,
                                          "types": ["assembling-machine"]}, HELPER)
            for e in data.get("entities", []):
                if e.get("ghost") or not e.get("name", "").startswith("assembling-machine"):
                    continue
                d = P.dist(e["pos"], pos)
                if best is None or d < best[0]:
                    best = (d, e)
    result["machine"] = best and {"name": best[1]["name"], "pos": best[1]["pos"], "dist": round(best[0], 1)}
    return best and best[1]


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    m = nearest_machine(client, result)
    if m is None:
        return P.setup_failed(result, "рядом со стартом нет сборочных машин хозяина")
    target = {"name": m["name"], "pos": m["pos"]}
    reasons = []
    r = P.act(client, "set_recipe", {"target": target, "recipe": "iron-gear-wheel"})
    result["set"] = P.brief(r)
    d = P.detail_of(r)
    if r["kind"] == "job_done" and d.get("was") == "iron-gear-wheel":
        r = P.act(client, "set_recipe", {"target": target, "recipe": "pipe"})
        result["set_pipe"] = P.brief(r)
    if r["kind"] != "job_done":
        reasons.append(f"set_recipe не done: {result.get('set_pipe') or result['set']}")
    else:
        was = d.get("was")
        back = P.act(client, "set_recipe", {"target": target, **({"recipe": was} if was else {})})
        result["restore"] = P.brief(back)
        if back["kind"] != "job_done" or P.detail_of(back).get("recipe") != was:
            reasons.append(f"прежний рецепт не вернулся: {result['restore']}")
    say = client.call("say", {"text": f"тест метки ({int(m['pos']['x'])},{int(m['pos']['y'])}) "
                                      f"[gps={int(m['pos']['x'])},{int(m['pos']['y'])}]"}, HELPER)
    result["say"] = say
    if not (isinstance(say, dict) and say.get("ok") is True):
        reasons.append(f"say не принят: {say}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
