"""Живой сценарий: `act get_items` — ручной крафт с промежуточными, плавка и снятие очереди крафта.

Ход (сервер без окна, хозяин офлайн; три независимые части, у каждой своё «не вышло подготовить»):
1. Крафт с промежуточными (CRAFT_CANDIDATES): выбирается предмет, готового которого нет ни у помощника,
   ни на складах, и промежуточного продукта тоже нет, при том что сырья (у помощника и на складах)
   хватает. Радиус берётся тот (64 или 128), в котором `stock` нашёл всё сырьё, и тот же радиус
   передаётся в `get_items`. `get_items` → job_done, `detail.have` не меньше нужного,
   `detail.from.crafted` содержит и сам предмет, и промежуточный продукт, `from.storage` самого
   предмета нет.
2. Плавка (SMELT_CANDIDATES): на тестовой базе все печи хозяина подключены к манипуляторам, и
   `get_items` честно отвечает `no_furnace`. Поэтому помощник сам ставит свою каменную печь рядом
   (печь со склада или крафт из камня, `place` на свободном стыке клеток: печь 2×2). Продукта
   (пластины, кирпич) нет ни у помощника, ни на складах в радиусе 128; руду помощник получает
   честно — со склада или `mine {item}`. Затем `get_items` продукта: job_done, `from.smelted` > 0,
   `have` не меньше нужного; топливо в пустую горелку кладёт сам `get_items`. В конце помощник
   разбирает свою печь (`deconstruct` по `{unit_number, pos}`), и `map` подтверждает, что печи нет:
   база остаётся как была. Нет печи или топлива (`shortfall` с `no_furnace` / `no_fuel`) — это
   подготовка стенда, а не отказ мода.
3. «Стоп» хозяина на стенде не проверить (игрока нет). Вместо него: `craft` большой партии, посреди
   крафта `cancel {all:true}` — задача кончается `job_failed{cancelled}`, активной задачи и очереди нет,
   поле `crafting` в `state` (если оно есть) пусто, а продукта после снятия не прибавляется.
Часть, у которой на базе нет нужного (всё уже лежит на складах, нет сырья, печи), пишет в результат
`setup_failed` и не считается провалом мода; общий `ok` тогда False с error.kind=setup.
Контракт: docs/ACTIONS.md («get_items», «craft», «deconstruct»), docs/PROTOCOL.md («cancel»).
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
H = P.H
HELPER = P.HELPER
# (предмет, промежуточный продукт, сырьё {имя: сколько нужно на всю партию}, сколько штук просим)
CRAFT_CANDIDATES = (
    ("electronic-circuit", "copper-cable", {"iron-plate": 6, "copper-plate": 10}, 5),
    ("inserter", "electronic-circuit", {"iron-plate": 12, "copper-plate": 6}, 2),
    ("assembling-machine-1", "electronic-circuit", {"iron-plate": 30, "copper-plate": 8}, 1),
    ("small-electric-pole", "copper-cable", {"wood": 2, "copper-plate": 2}, 2),
    ("burner-mining-drill", "iron-gear-wheel", {"iron-plate": 12, "stone": 6}, 1),
)
# (продукт, руда, руды на штуку, сколько штук просим)
SMELT_CANDIDATES = (("iron-plate", "iron-ore", 1, 5), ("copper-plate", "copper-ore", 1, 5),
                    ("stone-brick", "stone", 2, 5))
FURNACE = "stone-furnace"
# где искать место для печи 2×2 (её центр на стыке клеток): смещения от клетки помощника
CORNERS = ((5, 0), (0, 5), (-5, 0), (0, -5), (6, 6), (-6, 6), (6, -6), (-6, -6), (9, 0), (0, 9), (-9, 0), (0, -9))
# (рецепт, сырьё, сырья на крафт, сколько крафтов): долгая партия, чтобы было что снимать
CANCEL_CANDIDATES = (("iron-gear-wheel", "iron-plate", 2, 40), ("pipe", "iron-plate", 1, 60),
                     ("copper-cable", "copper-plate", 1, 80))
CANCEL_AFTER_S = 2.5          # сколько крафту идти до снятия
SETTLE_S = 3.0                # сколько ждать после снятия, что продукт не растёт
JOB_START_WAIT_S = 20.0
FAIL_WAIT_S = 20.0
SETUP_SHORTFALL = ("no_furnace", "no_fuel")


def _ask(client, item, target, radius, result, key):
    r = P.act(client, "get_items", {"items": {item: target}, "radius": radius})
    result[key] = P.brief(r)
    return r, P.detail_of(r)


def _total_128(client, items):
    return client.call_ok("stock", {"radius": 128, "items": list(items), "limit": 50}, HELPER).get("total") or {}


def _shortfall_codes(detail):
    return {s.get("reason") for s in (detail.get("shortfall") or []) if isinstance(s, dict)}


# ---------------------------------------------------------------- 1. крафт с промежуточными
def _pick_craft(client, result, seen):
    """Первый кандидат, у которого сырья хватает, а готового и промежуточного нет ни в карманах, ни на
    складах радиуса. → (item, middle, n, radius) | None."""
    for item, middle, raw, n in CRAFT_CANDIDATES:
        if P.helper_count(client, item) or P.helper_count(client, middle):
            seen.append(f"{item}: готовое или {middle} уже в карманах")
            continue
        for radius in (64, 128):
            total = client.call_ok("stock", {"radius": radius, "items": [item, middle, *raw], "limit": 50},
                                   HELPER).get("total") or {}
            if total.get(item, 0) or total.get(middle, 0):
                seen.append(f"{item}: готовое уже есть ({total.get(item, 0)}) или {middle} ({total.get(middle, 0)})")
                break
            short = [r for r, need in raw.items() if P.helper_count(client, r) + total.get(r, 0) < need]
            if not short:
                result.setdefault("scan", []).append({"radius": radius, "total": total, "for": item})
                return item, middle, n, radius
        else:
            seen.append(f"{item}: не хватает сырья")
    return None


def part_craft(client, result, reasons):
    part = result.setdefault("craft", {})
    seen = []
    pick = _pick_craft(client, result, seen)
    if pick is None:
        part["setup_failed"] = "нет предмета для крафта с промежуточными: " + "; ".join(seen)
        return
    item, middle, n, radius = pick
    r, d = _ask(client, item, n, radius, result, "craft_call")
    src = d.get("from") or {}
    have = P.helper_count(client, item)
    part.update(item=item, middle=middle, radius=radius, source=src, after=have)
    if r["kind"] != "job_done":
        reasons.append(f"craft: get_items не done: {r['kind']} {P.code_of(r)}")
        return
    if (d.get("have") or {}).get(item, 0) < n or have < n:
        reasons.append(f"craft: detail.have={d.get('have')}, в инвентаре {item} {have} < {n}")
    crafted = src.get("crafted") or {}
    if crafted.get(item, 0) <= 0:
        reasons.append(f"craft: detail.from.crafted без {item}: {src}")
    if middle not in crafted:
        reasons.append(f"craft: detail.from.crafted без промежуточного {middle}: {src}")
    if (src.get("storage") or {}).get(item):
        reasons.append(f"craft: {item} взят со склада, хотя его там не было: {src}")


# ---------------------------------------------------------------- 2. плавка в своей печи
def _get_ore(client, ore, count, result):
    """Руда в карманы честно: со склада, иначе `mine {item}`. → bool."""
    before = P.helper_count(client, ore)
    if before >= count:
        return True
    total, radius = P._stock_total(client, [ore], result)
    if total.get(ore, 0) >= count - before and P.obtain(client, ore, count - before, radius, result, "smelt_ore"):
        return True
    r = P.act(client, "mine", {"item": ore, "count": count - P.helper_count(client, ore)})
    result["smelt_mine"] = P.brief(r)
    return P.helper_count(client, ore) >= count


def _get_furnace(client, result):
    """Каменная печь в карманы: склад, крафт из камня склада, иначе камень руками. → bool."""
    if P.get_item(client, FURNACE, 1, result, "smelt_furnace"):
        return True
    need = 5 - P.helper_count(client, "stone")
    if need > 0:
        result["smelt_furnace_mine"] = P.brief(P.act(client, "mine", {"item": "stone", "count": need}))
    if P.helper_count(client, "stone") >= 5:
        result["smelt_furnace_craft"] = P.brief(P.act(client, "craft", {"recipe": FURNACE, "count": 1}))
    return P.helper_count(client, FURNACE) >= 1


def _place_furnace(client, result):
    """`place` печи на стыке клеток рядом с помощником (2×2). → (unit, pos) | (None, None)."""
    base = P.helper_state(client)["pos"]
    tries, last = [], None
    for dx, dy in CORNERS:
        pos = {"x": int(base["x"] // 1) + dx, "y": int(base["y"] // 1) + dy}
        last = P.act(client, "place", {"item": FURNACE, "pos": pos})
        tries.append({"pos": pos, "kind": last["kind"], "code": P.code_of(last)})
        if last["kind"] == "job_done":
            result["smelt_place"] = {"pos": pos, "tries": tries}
            return P.detail_of(last).get("unit_number"), pos
        if P.code_of(last) != "cannot_place":
            break
    result["smelt_place"] = {"tries": tries}
    return None, None


def _remove_furnace(client, unit, pos, result, reasons):
    """Разобрать свою печь и убедиться по `map`, что её нет: база остаётся как была."""
    r = P.act(client, "deconstruct", {"target": {"unit_number": unit, "pos": pos}})
    result["smelt_deconstruct"] = P.brief(r)
    if r["kind"] != "job_done" or P.detail_of(r).get("removed") != 1:
        reasons.append(f"smelt: своя печь не разобрана: {result['smelt_deconstruct']}")
        return
    left = P.entities_at(client, FURNACE, pos, 2)
    result["smelt_deconstruct"]["left_on_map"] = len(left)
    if left:
        reasons.append(f"smelt: после deconstruct печь всё ещё на карте в {pos}")


def part_smelt(client, result, reasons):
    part = result.setdefault("smelt", {})
    seen = []
    placed = None                  # (unit, pos) своей печи
    try:
        for product, ore, per, n in SMELT_CANDIDATES:
            ready = P.helper_count(client, product) + _total_128(client, [product]).get(product, 0)
            if ready:
                seen.append(f"{product}: готовое уже есть ({ready})")
                continue
            if placed is None:
                # печь ставится до добычи руды: крафт печи тратит камень, который нужен кирпичу
                if not _get_furnace(client, result):
                    part["setup_failed"] = "своя каменная печь: ни на складе, ни из камня её не достать"
                    return
                unit, pos = _place_furnace(client, result)
                if pos is None:
                    part["setup_failed"] = f"своя печь не ставится рядом: {result.get('smelt_place')}"
                    return
                placed = (unit, pos)
            if not _get_ore(client, ore, per * n, result):
                seen.append(f"{product}: руду {ore} достать не удалось")
                continue
            r, d = _ask(client, product, n, 64, result, "smelt_call")
            src = d.get("from") or {}
            have = P.helper_count(client, product)
            part.update(item=product, ore=ore, source=src, after=have)
            if r["kind"] != "job_done":
                if _shortfall_codes(d) & set(SETUP_SHORTFALL):
                    part["setup_failed"] = f"плавка {product}: {d.get('shortfall')}"
                else:
                    reasons.append(f"smelt: get_items не done: {r['kind']} {P.code_of(r)}")
                return
            if (d.get("have") or {}).get(product, 0) < n or have < n:
                reasons.append(f"smelt: detail.have={d.get('have')}, в инвентаре {product} {have} < {n}")
            if (src.get("smelted") or {}).get(product, 0) <= 0:
                reasons.append(f"smelt: detail.from.smelted без {product}: {src}")
            return
        part["setup_failed"] = "нет продукта для плавки: " + "; ".join(seen)
    finally:
        if placed is not None:
            _remove_furnace(client, placed[0], placed[1], result, reasons)


# ---------------------------------------------------------------- 3. cancel{all} посреди крафта
def _queue_empty(st):
    return not st.get("job") and not st.get("queue") and not st.get("crafting")


def part_cancel(client, result, reasons):
    part = result.setdefault("cancel", {})
    pick = None
    for recipe, raw, per, n in CANCEL_CANDIDATES:
        need = per * n
        have = P.helper_count(client, raw)
        if have < need:
            total, radius = P._stock_total(client, [raw], result)
            if total.get(raw, 0) < need - have or not P.obtain(client, raw, need - have, radius, result, "cancel_raw"):
                continue
        if P.helper_count(client, raw) >= need:
            pick = (recipe, raw, per, n)
            break
    if pick is None:
        part["setup_failed"] = "нет сырья на долгую партию крафта: " + ", ".join(c[0] for c in CANCEL_CANDIDATES)
        return
    recipe, raw, per, n = pick
    before = P.helper_count(client, recipe)
    since = client.call("hello")["seq"]
    job = client.call_ok("act", {"do": "craft", "args": {"recipe": recipe, "count": n}}, HELPER)["job"]
    running = client.poll(lambda: P.helper_state(client).get("job"), JOB_START_WAIT_S, 0.5)
    if not running:
        part["setup_failed"] = "задача крафта не стала активной (кончилась сразу?)"
        return
    client.sleep(CANCEL_AFTER_S)
    cancelled = client.call_ok("cancel", {"all": True}, HELPER)
    ev, _, _ = H.wait_job(client, job, since, FAIL_WAIT_S, HELPER)
    done = P.helper_count(client, recipe) - before
    part.update(recipe=recipe, count=n, cancel=cancelled, event=ev and ev.get("kind"), done_before_settle=done)
    if ev is None or ev.get("kind") != "job_failed" or (ev.get("data") or {}).get("code") != "cancelled":
        reasons.append(f"cancel: задача не кончилась job_failed{{cancelled}}: {ev}")
    if done >= n:
        part["setup_failed"] = "крафт успел закончиться до снятия очереди"
        return
    client.sleep(SETTLE_S)
    st = P.helper_state(client)
    grown = P.helper_count(client, recipe) - before - done
    part.update(state_after={k: st.get(k) for k in ("job", "queue", "crafting")}, grown_after_cancel=grown)
    if not _queue_empty(st):
        reasons.append(f"cancel: после cancel{{all}} остались задача или очередь крафта: "
                       f"job={st.get('job')} queue={st.get('queue')} crafting={st.get('crafting')}")
    if grown > 0:
        reasons.append(f"cancel: после снятия {recipe} прибавилось ещё {grown}: очередь крафта жива")


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    reasons = []
    for part in (part_craft, part_smelt, part_cancel):
        part(client, result, reasons)
    setups = {k: v["setup_failed"] for k, v in result.items() if isinstance(v, dict) and v.get("setup_failed")}
    result["ok"] = not reasons and not setups
    if reasons:
        result["reasons"] = reasons
    if setups:
        result["setup_failed"] = setups
        result["error"] = {"kind": "setup", "text": "; ".join(f"{k}: {v}" for k, v in setups.items())}
    return result
