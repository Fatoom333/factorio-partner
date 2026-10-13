"""Живой сценарий потока N «Прокладка лент»: лента в обход жидкости (`plan_belt`).

Ход:
1. `hello`, помощник (`helper_spawn`), съёмка местности вокруг него операцией `map` (25 окон).
2. Поиск двух точек свободной земли в 40–80 клетках друг от друга на одной прямой, между которыми по
   прямой лежит жидкость (на Вулкане — лава), а по земле путь есть. Первая точка — по возможности у руды.
3. Сухой прогон `act plan_belt {from, to, dry_run:true}`, затем настоящий.
4. Сверка с игрой, а не с ответом действия:
   - призраков ленты на карте (`map`) столько же, сколько в ответе (и по операции `ghosts`, если
     область не больше 128);
   - цепочка непрерывна: от начала каждая следующая лента стоит по направлению предыдущей, после
     подземного входа — его выход на той же линии; цепочка приходит в конечную точку;
   - ни одного призрака на жидкости, под землёй жидкости нет;
   - путь длиннее прямой (это обход), `need` сходится с числом призраков.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3). Сейв — копия стенда.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


B = _load("_belt")


def side(area):
    return (area["right_bottom"]["x"] - area["left_top"]["x"], area["right_bottom"]["y"] - area["left_top"]["y"])


def run(client) -> dict:
    result = {}
    origin = B.prepare(client, result)
    if origin is None:
        return result
    t = B.scan(client, origin)
    result["terrain"] = {"maps": t.maps, "cells": len(t.cells), "liquid": t.count(t.liquid), "land": t.count(t.land)}
    pair = B.find_detour_pair(t, origin)
    if pair is None:
        result.update(ok=False, error={"kind": "setup", "text": "в 160 клетках от помощника нет двух точек земли "
                                       "по разные стороны жидкости с обходом по суше"})
        return result
    a, b, info = pair
    result["points"] = {"from": list(a), "to": list(b), **info}
    args = {"from": B.center(a), "to": B.center(b)}

    reasons = []
    dry = B.act(client, "plan_belt", dict(args, dry_run=True))
    dd = B.detail_of(dry)
    result["dry"] = {"kind": dry["kind"], "code": B.code_of(dry), "text": B.text_of(dry), "seconds": dry["seconds"],
                     "ghosts": dd.get("ghosts"), "length": dd.get("length"), "need": dd.get("need"),
                     "warnings": dd.get("warnings")}
    if dry["kind"] != "job_done":
        reasons.append(f"сухой прогон не done: {B.code_of(dry)} {B.text_of(dry)}")
    old = B.snapshot(client, dd)
    result["ghosts_before"] = len(old)
    before = None
    if dd.get("area") and max(side(dd["area"])) <= 128:
        before = client.call_ok("ghosts", {"area": dd["area"]}, B.HELPER)

    real = B.act(client, "plan_belt", args)
    result["plan"] = B.brief(real)
    detail = B.detail_of(real)
    if real["kind"] != "job_done":
        reasons.append(f"plan_belt не done: {B.code_of(real)} {B.text_of(real)}")
    else:
        if detail.get("dry_run"):
            reasons.append("настоящий прогон ответил dry_run")
        if dry["kind"] == "job_done" and (detail.get("ghosts"), detail.get("need")) != (dd.get("ghosts"), dd.get("need")):
            reasons.append(f"призраков {detail.get('ghosts')}, сухой прогон обещал {dd.get('ghosts')}")
        if sum((detail.get("need") or {}).values()) != detail.get("ghosts"):
            reasons.append(f"need {detail.get('need')} не сходится с числом призраков {detail.get('ghosts')}")
        if (detail.get("length") or 0) <= info["span"] + 1:
            reasons.append(f"длина {detail.get('length')} не больше прямой {info['span'] + 1}: это не обход")
        path = detail.get("path") or []
        if not path or path[0] != B.center(a) or path[-1] != B.center(b):
            reasons.append(f"path не от начала до конца: {path[:1]} … {path[-1:]}")
        chain, _ = B.verify_chain(client, t, real, a, b, reasons, before=old)
        result["chain"] = chain
        if before is not None and detail.get("area") == dd.get("area"):
            after = client.call_ok("ghosts", {"area": detail["area"]}, B.HELPER)
            delta = (after.get("count") or 0) - (before.get("count") or 0)
            result["ghosts_op"] = {"before": before.get("count"), "after": after.get("count")}
            if delta != detail.get("ghosts"):
                reasons.append(f"операция ghosts видит прирост {delta}, а действие сообщило {detail.get('ghosts')}")

    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
