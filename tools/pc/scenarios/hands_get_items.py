"""Живой сценарий: `act get_items` — довести карманы помощника до нужного числа предметов.

Ход (сервер без окна, хозяин офлайн):
1. `hello`, `helper_spawn`; по `stock` выбирается предмет, которого нет у помощника, но есть на видимых
   складах хозяина (STORAGE_CANDIDATES, не меньше COUNT штук).
2. `act get_items {items:{<предмет>: до COUNT}}` → job_done, `detail.have` не меньше нужного,
   `detail.from.storage` > 0, инвентарь помощника вырос.
3. Второй вызов — предмет, который руками собирается из того, что уже есть (CRAFT_CANDIDATES: сырьё у
   помощника или на складах): job_done, `detail.have` не меньше нужного, `detail.from.crafted` > 0
   или `storage` > 0.
Базе нечего дать — сценарий не падает с исключением, а записывает причину в `error` (kind=setup).
Контракт: docs/ACTIONS.md («get_items»). Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
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
COUNT = 20
STORAGE_CANDIDATES = ("iron-plate", "copper-plate", "stone-brick", "coal", "steel-plate", "stone")
# (предмет, сырьё, сырья на штуку, сколько штук просим)
CRAFT_CANDIDATES = (("iron-gear-wheel", "iron-plate", 2, 5), ("pipe", "iron-plate", 1, 5),
                    ("copper-cable", "copper-plate", 1, 6))


def _ask(client, item, target, key, result, radius=64):
    # радиус — тот, в котором stock нашёл запасы (get_items по умолчанию смотрит в 64)
    r = P.act(client, "get_items", {"items": {item: target}, "radius": radius})
    result[key] = P.brief(r)
    return r, P.detail_of(r)


def _check(r, detail, item, target, reasons, key):
    if r["kind"] != "job_done":
        reasons.append(f"{key}: get_items не done: {r['kind']} {(r.get('data') or {}).get('code')}")
        return
    got = (detail.get("have") or {}).get(item, 0)
    if got < target:
        reasons.append(f"{key}: detail.have[{item}]={got} < {target}")


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    reasons = []

    # 1. со склада
    total, radius = P._stock_total(client, STORAGE_CANDIDATES, result)
    item = next((i for i in STORAGE_CANDIDATES if total.get(i, 0) >= COUNT and P.helper_count(client, i) == 0), None)
    if item is None:
        return P.setup_failed(result, "на видимых складах нет предмета из STORAGE_CANDIDATES "
                                      f"в количестве {COUNT}, которого не было бы у помощника: {total}")
    before = P.helper_count(client, item)
    r, d = _ask(client, item, before + COUNT, "storage_call", result, radius)
    _check(r, d, item, before + COUNT, reasons, "storage")
    if ((d.get("from") or {}).get("storage") or {}).get(item, 0) <= 0:
        reasons.append(f"storage: detail.from.storage не содержит {item}: {d.get('from')}")
    after = P.helper_count(client, item)
    result["storage"] = {"item": item, "before": before, "after": after}
    if after - before < COUNT:
        reasons.append(f"storage: в инвентаре {item} прибавилось {after - before} < {COUNT}")

    # 2. руками из сырья
    raw_total, raw_radius = P._stock_total(client, [c[1] for c in CRAFT_CANDIDATES], result)
    pick = None
    for name, raw, per, n in CRAFT_CANDIDATES:
        if P.helper_count(client, name) == 0 and P.helper_count(client, raw) + raw_total.get(raw, 0) >= per * n:
            pick = (name, n)
            break
    if pick is None:
        result.update(ok=False, reasons=reasons,
                      error={"kind": "setup", "text": "нет предмета для ручного крафта: сырья не хватает "
                                                      "или готовое уже лежит у помощника"})
        return result
    name, n = pick
    r, d = _ask(client, name, n, "craft_call", result, raw_radius)
    _check(r, d, name, n, reasons, "craft")
    src = d.get("from") or {}
    have = P.helper_count(client, name)
    result["craft"] = {"item": name, "from": src, "after": have}
    if not (src.get("crafted") or src.get("storage")):
        reasons.append(f"craft: в detail.from нет ни crafted, ни storage: {src}")
    if have < n:
        reasons.append(f"craft: в инвентаре {name} {have} < {n}")

    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
