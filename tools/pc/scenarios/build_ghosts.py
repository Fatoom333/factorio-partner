"""Живой сценарий потока F «Стройка»: маленький чертёж → призраки → построить руками.

Ход:
1. Как build_place: помощник и 2 одинаковых сундука честно со склада хозяина (`collect`).
2. Чертёж из двух сундуков рядом собирается здесь же (строка чертежа Factorio: «0» + base64(zlib(JSON)))
   и уходит в мод частями через `blob_put`.
3. Место: `act build_blueprint {blob, anchor, dry_run:true}` рядом с помощником, пока проверка не
   скажет ghosts = 2 без skipped.
4. `act build_blueprint {blob, anchor, mode:"hand"}` — призраки ставятся и строятся руками.
5. Сверка: job_done, ghosts = 2, built = 2, left = 0; `ghosts` в области пусто; у помощника
   стало на 2 предмета меньше; `map` видит 2 сундука.
Общие шаги — из build_place.py (загрузка по пути). Только конверты `/partner <JSON>`.
"""
from __future__ import annotations

import base64
import importlib.util
import json
import os
import time
import zlib


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


P = _load("build_place")
PART_BYTES = 3000          # blob_put: часть ≤ 3500 байт (PROTOCOL §4)
GAME_VERSION = (2, 0, 77, 0)
OFFSETS = ((4, 0), (0, 4), (-4, 0), (0, -4), (5, 5), (-5, 5), (5, -5), (-5, -5), (8, 0), (0, 8), (-8, 0), (0, -8))


def blueprint_string(item, count=2):
    """Строка чертежа: count построек item в ряд, центр рамки — в (0, 0.5)."""
    major, minor, patch, dev = GAME_VERSION
    version = (major << 48) | (minor << 32) | (patch << 16) | dev
    entities = [{"entity_number": i + 1, "name": item, "position": {"x": i - count / 2 + 0.5, "y": 0.5}}
                for i in range(count)]
    doc = {"blueprint": {"item": "blueprint", "label": "partner-live", "entities": entities, "version": version}}
    raw = json.dumps(doc, separators=(",", ":")).encode("utf-8")
    return "0" + base64.b64encode(zlib.compress(raw, 9)).decode("ascii")


def decode_blueprint(text):
    """Обратно в JSON (для офлайн-тестов)."""
    return json.loads(zlib.decompress(base64.b64decode(text[1:])).decode("utf-8"))


def put_blob(client, blob, text):
    parts = [text[i:i + PART_BYTES] for i in range(0, len(text), PART_BYTES)]
    data = None
    for i, part in enumerate(parts, 1):
        data = client.call_ok("blob_put", {"blob": blob, "part": i, "total": len(parts), "data": part})
    return data


def anchor_near(base, dx, dy):
    """Центр чертежа из двух клеток: граница клеток по x, середина клетки по y."""
    return {"x": int(base["x"] // 1) + dx, "y": int(base["y"] // 1) + dy + 0.5}


def run(client) -> dict:
    result = {}
    count = 2
    item = P.prepare(client, result, count)
    if item is None:
        return result
    before = P.helper_count(client, item)
    blob = "bp-live-%05d" % (int(time.time()) % 100000)
    result["blob"] = put_blob(client, blob, blueprint_string(item, count))

    reasons = []
    base = P.helper_state(client)["pos"]
    anchor = None
    dry_log = []
    for dx, dy in OFFSETS:
        a = anchor_near(base, dx, dy)
        r = P.act(client, "build_blueprint", {"blob": blob, "anchor": a, "dry_run": True})
        d = P.detail_of(r)
        dry_log.append({"anchor": a, "kind": r["kind"], "code": P.code_of(r), "ghosts": d.get("ghosts"),
                        "skipped": d.get("skipped_total")})
        if r["kind"] == "job_done" and d.get("ghosts") == count and not d.get("skipped"):
            anchor = a
            break
        if r["kind"] != "job_done" and P.code_of(r) not in ("cannot_place", "not_charted"):
            break
    result["dry_run"] = dry_log
    if anchor is None:
        result.update(ok=False, reasons=[f"dry_run не нашёл места для чертежа: {dry_log[-1] if dry_log else None}"])
        return result
    result["anchor"] = anchor

    r = P.act(client, "build_blueprint", {"blob": blob, "anchor": anchor, "mode": "hand"})
    result["build"] = P.brief(r)
    detail = P.detail_of(r)
    if r["kind"] != "job_done":
        reasons.append(f"build_blueprint не done: {result['build']}")
    else:
        for key, want in (("ghosts", count), ("built", count), ("left", 0)):
            if detail.get(key) != want:
                reasons.append(f"{key} = {detail.get(key)}, а не {want}")

    area = {"left_top": {"x": anchor["x"] - 3, "y": anchor["y"] - 3},
            "right_bottom": {"x": anchor["x"] + 3, "y": anchor["y"] + 3}}
    left = client.call_ok("ghosts", {"area": area}, P.HELPER)
    result["ghosts_left"] = left.get("count")
    if left.get("count") != 0:
        reasons.append(f"в области осталось призраков: {left.get('count')}")
    after = P.helper_count(client, item)
    result["inventory"] = {"before": before, "after": after}
    if before - after != count:
        reasons.append(f"у помощника убыло {before - after}, а не {count}")
    data = client.call_ok("map", {"center": anchor, "radius": 3, "names": [item]}, P.HELPER)
    built = [e for e in data.get("entities", []) if e.get("name") == item and not e.get("ghost")
             and abs(e["pos"]["x"] - anchor["x"]) <= count / 2 + 0.6 and abs(e["pos"]["y"] - anchor["y"]) <= 1.6]
    result["on_map"] = len(built)
    if len(built) != count:
        reasons.append(f"на карте построек {item}: {len(built)}, а не {count}")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
