"""Живой сценарий: `act get_items` — ручной крафт с промежуточными, плавка и снятие очереди крафта.

Ход (сервер без окна, хозяин офлайн; три части, у каждой своё «не вышло подготовить»; части идут в порядке
плавка → крафт → снятие очереди):
1. Плавка (SMELT_CANDIDATES): на тестовой базе все печи хозяина подключены к манипуляторам, и
   `get_items` честно отвечает `no_furnace`. Поэтому помощник сам ставит свою каменную печь рядом
   (печь со склада или крафт из камня, `place` на свободном стыке клеток не дальше 6 клеток от тела:
   печь 2×2). Продукта (пластины, кирпич) нет ни у помощника, ни на складах в радиусе 128; руду помощник
   получает честно — со склада или `mine {item}` (тело при этом уходит от печи), затем `approach` к своей
   печи (`target {unit_number, pos}`, distance 3) и только после подхода считается радиус `get_items`.
   `get_items` продукта: job_done, `from.smelted` > 0, `have` не меньше нужного; топливо в пустую горелку
   кладёт сам `get_items`. Нет печи или топлива (`shortfall` с `no_furnace` / `no_fuel`) — это
   подготовка стенда, а не отказ мода. Печь остаётся стоять до конца прогона.
2. Крафт с промежуточными (CRAFT_CANDIDATES): выбирается предмет, готового которого нет ни у помощника,
   ни на складах радиуса. Сырьё (пластины, камень, дерево) сценарий приносит сам: `get_items` сырья со
   склада, а при нехватке — руда (склад или `mine {item}`) и плавка в своей печи из части 1; камень и
   дерево — `mine {item}`. Кандидат годен, если после подготовки сырья в карманах хватает. Предпочитается
   кандидат, промежуточного продукта которого нет ни в карманах, ни на складах радиуса: тогда
   `from.crafted` обязан содержать и промежуточный — это проверка цепочки рецептов
   (`middle_from: crafted`). Если такого кандидата нет, берётся запасной: промежуточный на складе — он
   обязан быть в `from.storage` (`middle_from: storage`), в карманах — он не проверяется
   (`middle_from: pockets`); в обоих случаях в результате `chain_checked: false`.
   `get_items` → job_done, `detail.have` не меньше нужного, `detail.from.crafted` содержит сам предмет,
   `from.storage` самого предмета нет.
3. «Стоп» хозяина на стенде не проверить (игрока нет). Вместо него: `craft` большой партии, посреди
   крафта `cancel {all:true}` — задача кончается `job_failed{cancelled}`, активной задачи и очереди нет,
   поле `crafting` в `state` (если оно есть) пусто, а продукта после снятия не прибавляется.
В конце прогона (в `finally`) помощник разбирает свою печь (`deconstruct` по `{unit_number, pos}`), и `map`
подтверждает, что печи нет: база остаётся как была.
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
# (не дальше 6 клеток по прямой: дальше помощник и печь вместе в радиус get_items не помещаются)
CORNERS = ((3, 0), (0, 3), (-3, 0), (0, -3), (4, 4), (-4, 4), (4, -4), (-4, -4), (5, 0), (0, 5), (-5, 0), (0, -5),
           (4, 0), (0, 4), (-4, 0), (0, -4), (6, 0), (0, 6), (-6, 0), (0, -6))
# пластины, которые сценарий умеет выплавить сам: (руда, руды на штуку)
PLATE_ORE = {"iron-plate": ("iron-ore", 1), "copper-plate": ("copper-ore", 1)}
APPROACH_DISTANCE = 3         # на сколько подойти к своей печи перед get_items плавки (2–3 клетки)
# (рецепт, сырьё, сырья на крафт, сколько крафтов): долгая партия, чтобы было что снимать
CANCEL_CANDIDATES = (("iron-gear-wheel", "iron-plate", 2, 40), ("pipe", "iron-plate", 1, 60),
                     ("copper-cable", "copper-plate", 1, 80))
CANCEL_AFTER_S = 2.5          # сколько крафту идти до снятия
SETTLE_S = 3.0                # сколько ждать после снятия, что продукт не растёт
JOB_START_WAIT_S = 20.0
FAIL_WAIT_S = 20.0
SETUP_SHORTFALL = ("no_furnace", "no_fuel")
SMELT_MAX_RADIUS = 12         # дальше печь «вплотную» уже не считается


def _ask(client, item, target, radius, result, key):
    r = P.act(client, "get_items", {"items": {item: target}, "radius": radius})
    result[key] = P.brief(r)
    return r, P.detail_of(r)


def _total_128(client, items):
    return client.call_ok("stock", {"radius": 128, "items": list(items), "limit": 50}, HELPER).get("total") or {}


def _shortfall_codes(detail):
    return {s.get("reason") for s in (detail.get("shortfall") or []) if isinstance(s, dict)}


# ---------------------------------------------------------------- своя печь и плавка
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


def _smelt_radius(base, pos):
    """Маленький радиус для `get_items` плавки: только-только до своей печи (центр на `pos`) и ни метром
    дальше, чтобы чужие склады и печи базы не участвовали. Запас на размер печи 2×2 и клетку помощника."""
    dist = ((pos["x"] - base["x"]) ** 2 + (pos["y"] - base["y"]) ** 2) ** 0.5
    return max(1, min(SMELT_MAX_RADIUS, int(dist) + 2)), round(dist, 1)


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


def _ensure_furnace(client, result, ctx):
    """Своя печь стоит (ctx["furnace"] = (unit, pos)); нет — достать и поставить. → None | текст причины."""
    if ctx.get("furnace"):
        return None
    # печь ставится до добычи руды: крафт печи тратит камень, который нужен кирпичу
    if not _get_furnace(client, result):
        return "своя каменная печь: ни на складе, ни из камня её не достать"
    unit, pos = _place_furnace(client, result)
    if pos is None:
        return f"своя печь не ставится рядом: {result.get('smelt_place')}"
    ctx["furnace"] = (unit, pos)
    return None


def _approach_furnace(client, ctx, result):
    """Подойти к своей печи (тело ходило за рудой и могло уйти далеко). → bool."""
    unit, pos = ctx["furnace"]
    r = P.act(client, "approach", {"target": {"unit_number": unit, "pos": pos}, "distance": APPROACH_DISTANCE})
    result["smelt_approach"] = P.brief(r)
    return r["kind"] == "job_done"


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


def _smelt_into(client, product, ore, per, n, result, ctx, key):
    """Довести `product` в карманах до n плавкой в своей печи: печь → руда → подход → get_items с малым
    радиусом, посчитанным после подхода. → {"setup": текст} | {"skip": текст} (руды не достать) |
    {"r", "d", "radius", "dist", "ore"} (ответ get_items)."""
    why = _ensure_furnace(client, result, ctx)
    if why:
        return {"setup": why}
    ore_need = per * max(0, n - P.helper_count(client, product))
    if not _get_ore(client, ore, ore_need, result):
        return {"skip": f"{product}: руду {ore} достать не удалось"}
    if not _approach_furnace(client, ctx, result):
        return {"setup": f"не удалось подойти к своей печи: {result.get('smelt_approach')}"}
    radius, dist = _smelt_radius(P.helper_state(client)["pos"], ctx["furnace"][1])
    r, d = _ask(client, product, n, radius, result, key)
    return {"r": r, "d": d, "radius": radius, "dist": dist, "ore": P.helper_count(client, ore)}


def part_smelt(client, result, reasons, ctx):
    part = result.setdefault("smelt", {})
    seen = []
    for product, ore, per, n in SMELT_CANDIDATES:
        ready = P.helper_count(client, product) + _total_128(client, [product]).get(product, 0)
        if ready:
            seen.append(f"{product}: готовое уже есть ({ready})")
            continue
        out = _smelt_into(client, product, ore, per, n, result, ctx, "smelt_call")
        if "setup" in out:
            part["setup_failed"] = out["setup"]
            return
        if "skip" in out:
            seen.append(out["skip"])
            continue
        r, d, radius, dist = out["r"], out["d"], out["radius"], out["dist"]
        part.update(radius=radius, furnace_dist=dist)
        src = d.get("from") or {}
        have = P.helper_count(client, product)
        part.update(item=product, ore=ore, source=src, after=have)
        if r["kind"] != "job_done":
            if _shortfall_codes(d) & set(SETUP_SHORTFALL):
                part["setup_failed"] = (f"плавка {product}: {d.get('shortfall')} (radius {radius}, своя печь "
                                        f"в {dist} клетках, руда {ore} в карманах: {out['ore']})")
            else:
                reasons.append(f"smelt: get_items не done: {r['kind']} {P.code_of(r)}")
            return
        if (d.get("have") or {}).get(product, 0) < n or have < n:
            reasons.append(f"smelt: detail.have={d.get('have')}, в инвентаре {product} {have} < {n}")
        if (src.get("smelted") or {}).get(product, 0) <= 0:
            reasons.append(f"smelt: detail.from.smelted без {product}: {src}")
        return
    part["setup_failed"] = "нет продукта для плавки: " + "; ".join(seen)


# ---------------------------------------------------------------- крафт с промежуточными
def _scan(client, item, middle, raw):
    """Склады вокруг: радиус 64, а если там пусто, то 128. → (total, radius)."""
    names = [item, middle, *raw]
    total = {}
    for radius in (64, 128):
        total = client.call_ok("stock", {"radius": radius, "items": names, "limit": 50}, HELPER).get("total") or {}
        if total:
            return total, radius
    return total, 128


def _prepare_raw(client, name, need, radius, total, result, ctx):
    """Довести сырьё `name` в карманах до need: склад (`get_items` сырья) → руда и плавка в своей печи
    (пластины) → `mine {item}` (камень, дерево). → None | текст, почему не вышло."""
    log = result.setdefault("craft_prep", {}).setdefault(name, {})
    if P.helper_count(client, name) >= need:
        return None
    if total.get(name, 0) >= need - P.helper_count(client, name):
        r, _ = _ask(client, name, need, radius, result, "craft_prep_" + name)
        log["storage"] = r["kind"]
        if P.helper_count(client, name) >= need:
            return None
    if name in PLATE_ORE:
        ore, per = PLATE_ORE[name]
        out = _smelt_into(client, name, ore, per, need, result, ctx, "craft_prep_" + name)
        log["smelt"] = out.get("r", {}).get("kind") or out.get("setup") or out.get("skip")
        if "setup" in out or "skip" in out:
            return out.get("setup") or out.get("skip")
    else:
        r = P.act(client, "mine", {"item": name, "count": need - P.helper_count(client, name)})
        log["mine"] = r["kind"]
    have = P.helper_count(client, name)
    return None if have >= need else f"{name}: после подготовки {have} < {need}"


def _pick_craft(client, result, ctx, seen):
    """Кандидат, у которого после подготовки сырья хватает, а самого предмета нет ни в карманах, ни на
    складах радиуса. Первым — тот, у кого и промежуточного нет нигде (его крафт проверяет цепочку
    рецептов); иначе первый запасной.
    → (item, middle, n, radius, middle_from) | None; middle_from — crafted | storage | pockets."""
    options = []
    for item, middle, raw, n in CRAFT_CANDIDATES:
        if P.helper_count(client, item):
            seen.append(f"{item}: готовое уже в карманах")
            continue
        total, radius = _scan(client, item, middle, raw)
        if total.get(item, 0):
            seen.append(f"{item}: готовое уже есть на складе ({total.get(item, 0)})")
            continue
        if P.helper_count(client, middle):
            middle_from = "pockets"
        elif total.get(middle, 0):
            middle_from = "storage"
        else:
            middle_from = "crafted"
        options.append((item, middle, raw, n, radius, total, middle_from))
    options.sort(key=lambda o: o[6] != "crafted")        # устойчиво: «crafted» вперёд, остальные как были
    for item, middle, raw, n, radius, total, middle_from in options:
        failed = []
        for name, need in raw.items():
            why = _prepare_raw(client, name, need, radius, total, result, ctx)
            if why:
                failed.append(why)
                break
        result.setdefault("scan", []).append({"radius": radius, "total": total, "for": item})
        if failed:
            seen.append(f"{item}: сырьё не подготовлено ({'; '.join(failed)})")
            continue
        if middle_from != "crafted":
            seen.append(f"{item}: {middle} уже есть ({middle_from}) — запасной")
        return item, middle, n, radius, middle_from
    return None


def part_craft(client, result, reasons, ctx):
    part = result.setdefault("craft", {})
    seen = []
    pick = _pick_craft(client, result, ctx, seen)
    if pick is None:
        part["setup_failed"] = "нет предмета для крафта с промежуточными: " + "; ".join(seen)
        return
    item, middle, n, radius, middle_from = pick
    part.update(middle_from=middle_from, chain_checked=middle_from == "crafted")
    if middle_from != "crafted":
        part["note"] = (f"промежуточный {middle} уже был ({middle_from}): цепочка рецептов этим прогоном "
                        "не проверена; " + "; ".join(seen))
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
    if middle_from == "crafted" and crafted.get(middle, 0) <= 0:
        reasons.append(f"craft: detail.from.crafted без промежуточного {middle}: {src}")
    if middle_from == "storage" and (src.get("storage") or {}).get(middle, 0) <= 0:
        reasons.append(f"craft: промежуточный {middle} лежал на складе, но не в detail.from.storage: {src}")
    if (src.get("storage") or {}).get(item):
        reasons.append(f"craft: {item} взят со склада, хотя его там не было: {src}")


# ---------------------------------------------------------------- cancel{all} посреди крафта
def _queue_empty(st):
    return not st.get("job") and not st.get("queue") and not st.get("crafting")


def part_cancel(client, result, reasons, ctx):
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


def _release_furnace(client, ctx, result, reasons):
    """Разобрать свою печь, если она стоит; сбой разбора не прячет исходную ошибку прогона."""
    placed, ctx["furnace"] = ctx.get("furnace"), None
    if placed is None:
        return
    try:
        _remove_furnace(client, placed[0], placed[1], result, reasons)
    except Exception as exc:                      # noqa: BLE001 — важнее довести отчёт, чем упасть второй раз
        reasons.append(f"smelt: своя печь не разобрана: {exc!r}")


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    reasons = []
    ctx = {"furnace": None}          # своя печь живёт до конца прогона
    try:
        for part in (part_smelt, part_craft, part_cancel):
            part(client, result, reasons, ctx)
    finally:
        _release_furnace(client, ctx, result, reasons)
    setups = {k: v["setup_failed"] for k, v in result.items() if isinstance(v, dict) and v.get("setup_failed")}
    result["ok"] = not reasons and not setups
    if reasons:
        result["reasons"] = reasons
    if setups:
        result["setup_failed"] = setups
        result["error"] = {"kind": "setup", "text": "; ".join(f"{k}: {v}" for k, v in setups.items())}
    return result
