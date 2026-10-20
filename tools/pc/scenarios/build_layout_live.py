"""Живой сценарий: постройка блока по списку со смещениями (`build_layout`).

Блок — две каменные печи (2×2) и деревянный сундук (1×1) в один ряд; смещения `dx, dy` — левая верхняя
клетка постройки от клетки якоря. Ход (сервер без окна, хозяин офлайн):
1. Помощник; в карманах две печи и два сундука честно (склад хозяина, иначе ручной крафт из сырья склада).
2. `dry_run` с `search: 8` у тела: `done`, в ответе `site` (якорь найденного места), `need` с двумя печами и
   сундуком, `missing` пуст, `placed` пуст; `map` до и после одинаков — ничего не поставлено и призраков нет.
3. Настоящая постройка с `auto_supply` и `tag`: `done`, поставлено 3, в ответе нет отказов (кроме `exists`),
   `map` подтверждает каждую постройку в расчётной клетке (якорь из `site` + смещение + половина размера).
4. Тот же вызов в `site.anchor` с `search: 0`: всё `exists` (в `placed` или в `failed` с кодом `exists`), новых
   построек нет.
5. Сундук поверх своей печи с `search: 0`: `failed{cannot_place}` (или `done` с `failed[]` кода
   `cannot_place`); сундук не поставлен, призраков не осталось, карманы те же.
6. В конце (в `finally`) помощник разбирает свои три постройки (`deconstruct` по `{unit_number, pos}`),
   и `map` совпадает с тем, что было до прогона: база осталась как была.
Нет места для блока, нет печей и сундуков на складах и сырья для них — `setup_failed` (error.kind=setup),
это подготовка стенда, а не отказ мода.
Контракт: docs/ACTIONS.md («build_layout», «deconstruct»). Только конверты `/partner <JSON>` через
live_client (TESTING.md §3). Сейв — копия стенда.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] op (act|map|state) failed"


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


P = _load("build_place")
FURNACE = "stone-furnace"
CHEST = "wooden-chest"
TAG = "fp-live-block"
SEARCH = 8
# (имя, dx, dy, сторона): левая верхняя клетка от клетки якоря; печи 2×2 не касаются друг друга
BLOCK = ((FURNACE, 0, 0, 2), (FURNACE, 3, 0, 2), (CHEST, 6, 0, 1))
SNAP_HALF = 24                # половина стороны окна снимка вокруг тела: поиск места (±8) + размер блока
SNAP_STEP = 10                # окна `map` радиуса 10: в ответе не больше 100 сущностей


def _use_chest(name):
    """Какой именно сундук (или другая постройка 1×1) ставится в блоке: зависит от запасов стенда."""
    global CHEST, BLOCK
    CHEST = name
    BLOCK = ((FURNACE, 0, 0, 2), (FURNACE, 3, 0, 2), (CHEST, 6, 0, 1))


def _entities(block=None):
    block = BLOCK if block is None else block
    return [{"name": n, "dx": dx, "dy": dy} for n, dx, dy, _ in block]


def _center(anchor, item):
    """Расчётный центр постройки: клетка якоря + смещение + половина стороны."""
    name, dx, dy, size = item
    return {"x": int(anchor["x"] // 1) + dx + size / 2, "y": int(anchor["y"] // 1) + dy + size / 2}


def _snapshot(client, center):
    """Печи и сундуки (в том числе призраки) вокруг center, как их видит `map`. → (множество, обрезано)."""
    out, truncated = set(), False
    step = 2 * SNAP_STEP + 1
    cx, cy = int(center["x"] // 1), int(center["y"] // 1)
    for ox in range(-SNAP_HALF, SNAP_HALF + 1, step):
        for oy in range(-SNAP_HALF, SNAP_HALF + 1, step):
            c = {"x": cx + ox + 0.5, "y": cy + oy + 0.5}
            data = client.call_ok("map", {"center": c, "radius": SNAP_STEP, "names": [FURNACE, CHEST]}, P.HELPER)
            truncated = truncated or bool(data.get("truncated"))
            for e in data.get("entities", []):
                out.add((e["name"], e["pos"]["x"], e["pos"]["y"], bool(e.get("ghost"))))
    return out, truncated


def _statuses(detail, count):
    """Что сказано про каждую из count построек блока: {i: "placed" | код отказа}; i у мода — с 1."""
    out = {}
    for p in detail.get("placed") or []:
        out[p.get("i")] = "placed"
    for f in detail.get("failed") or []:
        out.setdefault(f.get("i"), f.get("code"))
    return {i: out.get(i) for i in range(1, count + 1)}


def _ids(detail):
    """unit_number поставленных построек блока по индексу: {i: unit}."""
    return {p.get("i"): p.get("unit_number") for p in detail.get("placed") or [] if p.get("unit_number")}


def _cleanup(client, anchor, units, result, reasons):
    """Разобрать три свои постройки по `{unit_number, pos}` (номер — из `placed`, иначе из `map`)."""
    removed = []
    for i, item in enumerate(BLOCK, 1):          # номера построек в ответе мода — с 1
        pos = _center(anchor, item)
        found = P.entities_at(client, item[0], pos)
        if not found:
            continue
        unit = units.get(i) or found[0].get("unit")
        target = {"unit_number": unit, "pos": pos} if unit else {"name": item[0], "pos": pos}
        r = P.act(client, "deconstruct", {"target": target})
        removed.append(dict(P.brief(r), i=i))
        if r["kind"] != "job_done" or P.detail_of(r).get("removed") != 1:
            reasons.append(f"cleanup: постройка {item[0]} в {pos} не разобрана: {P.code_of(r)}")
    result["cleanup"] = removed


def run(client) -> dict:
    result = {"log_must_not_match": LOG_MUST_NOT_MATCH}
    if not P.start(client, result):
        return result
    if not P.get_item(client, FURNACE, 2, result, "get_furnace"):
        return P.setup_failed(result, "на складах хозяина нет ни печей, ни камня для них")
    chest = P.get_chests(client, result, 2)       # сундук любого вида из того, что есть (дерево, железо, сталь)
    if chest is None:
        return P.setup_failed(result, "на складах хозяина нет ни сундуков, ни сырья для них")
    _use_chest(chest)
    base = P.helper_state(client)["pos"]
    anchor0 = {"x": int(base["x"] // 1), "y": int(base["y"] // 1)}
    pockets = {n: P.helper_count(client, n) for n in (FURNACE, CHEST)}
    result["pockets"] = pockets
    before, trunc = _snapshot(client, anchor0)
    result["snapshot_before"] = {"entities": len(before), "truncated": trunc}
    reasons = []
    units, state = {}, {"anchor": None}      # state["anchor"] — якорь найденного места, как только он известен
    try:
        _run_steps(client, anchor0, before, pockets, result, reasons, units, state)
    finally:
        _cleanup(client, state["anchor"] or anchor0, units, result, reasons)
    if "setup_failed" not in result:
        final, _ = _snapshot(client, anchor0)
        result["snapshot_after"] = {"entities": len(final)}
        if final != before:
            reasons.append(f"после разбора карта другая: добавилось {sorted(final - before)[:5]}, "
                           f"пропало {sorted(before - final)[:5]}")
    result["ok"] = not reasons and "setup_failed" not in result
    if reasons:
        result["reasons"] = reasons
    if "setup_failed" in result:
        result.update(ok=False, error={"kind": "setup", "text": result["setup_failed"]})
    return result


def _run_steps(client, anchor0, before, pockets, result, reasons, units, state):
    """Шаги 2–5. Нет места под блок — в result setup_failed."""
    args = {"anchor": anchor0, "entities": _entities(), "search": SEARCH}

    # 2. сухой прогон
    dry = P.act(client, "build_layout", dict(args, dry_run=True))
    dd = P.detail_of(dry)
    result["dry"] = P.brief(dry)
    if dry["kind"] != "job_done":
        if P.code_of(dry) == "cannot_place" and dd.get("reason") == "site_not_found":
            result["setup_failed"] = f"в {SEARCH} клетках от тела нет места под блок: {dd.get('site_checked')} проверено"
        else:
            reasons.append(f"dry_run не done: {P.code_of(dry)} {(dry.get('data') or {}).get('text')}")
        return
    site = dd.get("site") or {}
    if not isinstance(site.get("anchor"), dict):
        if dd.get("reason") == "site_not_found":
            result["setup_failed"] = "в сухом прогоне места под блок не нашлось (site_not_found)"
        else:
            reasons.append(f"dry_run: в ответе нет site.anchor: {dd}")
        return
    anchor = state["anchor"] = site["anchor"]
    if site.get("direction", 0) != 0:
        reasons.append(f"dry_run: поворот {site.get('direction')} без rotate")
    need = dd.get("need") or {}
    if need.get(FURNACE) != 2 or need.get(CHEST) != 1:
        reasons.append(f"dry_run: need={need}, ждали две печи и сундук")
    if dd.get("missing"):
        reasons.append(f"dry_run: missing={dd.get('missing')} при полных карманах")
    if dd.get("placed"):
        reasons.append(f"dry_run: placed не пуст: {dd.get('placed')}")
    after_dry, _ = _snapshot(client, anchor0)
    if after_dry != before:
        reasons.append(f"dry_run изменил карту: {sorted(after_dry ^ before)[:5]}")

    # 3. постройка
    real = P.act(client, "build_layout", dict(args, auto_supply=True, tag=TAG))
    rd = P.detail_of(real)
    result["build"] = P.brief(real)
    if real["kind"] != "job_done":
        reasons.append(f"build_layout не done: {P.code_of(real)} {(real.get('data') or {}).get('text')}")
        return
    placed_site = (rd.get("site") or {}).get("anchor") or anchor
    anchor = state["anchor"] = placed_site
    units.update(_ids(rd))
    status = _statuses(rd, len(BLOCK))
    result["build_status"] = status
    bad = {i: s for i, s in status.items() if s not in ("placed", "exists")}
    if bad:
        reasons.append(f"build_layout: не встали {bad}: {rd.get('failed')}")
    if len(rd.get("placed") or []) != len(BLOCK) and rd.get("placed_total") != len(BLOCK):
        reasons.append(f"build_layout: placed {len(rd.get('placed') or [])}, ждали {len(BLOCK)}")
    for i, item in enumerate(BLOCK):
        pos = _center(anchor, item)
        found = P.entities_at(client, item[0], pos)
        if len(found) != 1:
            reasons.append(f"на карте в {pos} построек {item[0]}: {len(found)}")
    after_build, _ = _snapshot(client, anchor0)
    placed_snapshot = after_build - before
    result["after_build"] = {"new": len(placed_snapshot)}
    if len(placed_snapshot) != len(BLOCK) or any(g for *_, g in placed_snapshot):
        reasons.append(f"после постройки на карте новых {sorted(placed_snapshot)}, ждали три настоящие постройки")
    pockets_left = {n: P.helper_count(client, n) for n in (FURNACE, CHEST)}
    if pockets_left[FURNACE] != pockets[FURNACE] - 2 or pockets_left[CHEST] != pockets[CHEST] - 1:
        reasons.append(f"карманы после постройки {pockets_left}, было {pockets}")

    # 4. повтор в найденном месте: всё уже стоит
    again = P.act(client, "build_layout", dict(args, anchor=anchor, search=0))
    ad = P.detail_of(again)
    result["again"] = P.brief(again)
    if again["kind"] != "job_done":
        reasons.append(f"повтор не done: {P.code_of(again)} {(again.get('data') or {}).get('text')}")
    else:
        not_exists = {i: s for i, s in _statuses(ad, len(BLOCK)).items() if s not in ("placed", "exists")}
        if not_exists:
            reasons.append(f"повтор: не все exists: {not_exists}")
        for p in ad.get("placed") or []:
            if (p.get("unit_number") or 0) and p.get("unit_number") != units.get(p.get("i")):
                reasons.append(f"повтор поставил новую постройку {p}")
    after_again, _ = _snapshot(client, anchor0)
    if after_again != after_build:
        reasons.append(f"повтор изменил карту: {sorted(after_again ^ after_build)[:5]}")

    # 5. сундук поверх своей печи
    chests = P.helper_count(client, CHEST)
    over = P.act(client, "build_layout", {"anchor": anchor, "search": 0,
                                          "entities": [{"name": CHEST, "dx": 0, "dy": 0}]})
    od = P.detail_of(over)
    result["over"] = P.brief(over)
    codes = {f.get("code") for f in od.get("failed") or []}
    if over["kind"] == "job_failed":
        if P.code_of(over) != "cannot_place":
            reasons.append(f"поверх своей печи: код {P.code_of(over)}, ждали cannot_place")
    elif "cannot_place" not in codes or od.get("placed"):
        reasons.append(f"поверх своей печи: kind={over['kind']}, failed={od.get('failed')}, placed={od.get('placed')}")
    after_over, _ = _snapshot(client, anchor0)
    if after_over != after_build:
        reasons.append(f"поверх своей печи карта изменилась: {sorted(after_over ^ after_build)[:5]}")
    if P.helper_count(client, CHEST) != chests:
        reasons.append("поверх своей печи: сундук из карманов потрачен")
