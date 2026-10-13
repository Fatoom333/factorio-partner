"""Сквозные сценарии e2e_ghosts и e2e_mining (потоки K, V4) против модели мода (e2e_world.World):
настоящий LiveClient → фейковый RCON → модель. Плюс общие помощники scenarios/_e2e.py."""
from __future__ import annotations

import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR
from e2e_world import RECIPES, World, default_stores, ore_rect

MINER = "electric-mining-drill"
BELT = "fast-transport-belt"
POLE = "medium-electric-pole"


def load(name):
    mod = lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))
    if hasattr(mod, "E"):
        mod.E.VISIBLE_WAIT_S = 0.05     # в модели склады видны сразу
    return mod


@pytest.fixture
def live(fake_rcon):
    made = []

    def make(world, **kw):
        srv = fake_rcon(handler=world.handler)
        client = lc.LiveClient(srv.port, PASSWORD, timeout=5, **kw)
        client.connect()
        made.append(client)
        return client, srv

    yield make
    for c in made:
        c.close()


def built(world, name):
    return sorted(pos for pos, e in world.entities.items() if e["name"] == name and not e["ghost"])


def ghosts(world):
    return [pos for pos, e in world.entities.items() if e["ghost"]]


# ------------------------------------------------------------ e2e_ghosts

def ghost_world(**kw):
    return World(ore={"iron-ore": ore_rect(30, 0, 14, 14)}, **kw)


def test_ghosts_happy_path_crafts_drills_and_builds(live):
    world = ghost_world()
    client, srv = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is True, res
    assert res["chosen"] == {"miner": MINER, "belt": BELT}      # лента — та, что лежит на складе
    assert len(built(world, MINER)) == 2 and len(built(world, BELT)) == 3 and not ghosts(world)
    assert res["ghosts_op"]["count"] == 5 and res["ghosts_op"]["need"] == {MINER: 2, BELT: 3}
    assert res["inventory"]["before"] == {MINER: 2, BELT: 3} and res["inventory"]["after"] == {MINER: 0, BELT: 0}
    # призраки стояли ДО предметов: постановка — robots / no_items, потом сбор, потом build_ghosts
    dos = [do for do, _ in world.acts]
    place = next(i for i, (do, a) in enumerate(world.acts) if do == "build_blueprint" and not a.get("dry_run"))
    assert world.acts[place][1]["mode"] == "robots" and res["place_ghosts"]["data"]["code"] == "no_items"
    assert dos.index("collect") > place and dos.index("craft") > place and dos[-1] == "build_ghosts"
    assert world.acts[-1][1]["mode"] == "hand"
    # буров на складах нет — честный путь: схемы рядом, шестерни и пластины далеко (collect с центром
    # у дальних складов, идти туда отдельно не надо), крафт
    steps = [s["step"] for s in res["steps"]]
    assert "craft" in steps and "walk" not in steps
    assert any(s["step"] == "collect" and s.get("center") == {"x": -150.5, "y": 0.5} for s in res["steps"])
    craft = next(s for s in res["steps"] if s["step"] == "craft")
    assert craft["recipe"] == MINER and craft["crafted"] == {MINER: 2}
    assert res["log_must_not_match"]
    assert all(c.startswith("/partner {") for c in srv.commands)


def test_ghosts_takes_ready_drills_from_stock_without_craft(live):
    stores = default_stores()
    stores[0]["items"][MINER] = 10
    world = ghost_world(stores=stores)
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is True, res
    assert "craft" not in [do for do, _ in world.acts]
    assert stores[0]["items"][MINER] == 8


def test_ghosts_reports_what_is_missing_when_base_has_no_parts(live):
    stores = default_stores()
    del stores[0]["items"]["electronic-circuit"]        # схем на базе нет — бур не скрафтить
    world = ghost_world(stores=stores)
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is False
    assert res["missing"] == {MINER: 2}
    note = next(n for n in res["missing_detail"] if n.get("item") == MINER)
    assert note["craftable"] == 0 and note["recipe_guess"]["electronic-circuit"] == 3
    assert "inventory" in res["missing_detail"][-1]
    # призраки остались стоять, ничего не построено и не взято «из воздуха»
    assert len(ghosts(world)) == 5 and not built(world, MINER)
    assert "build_ghosts" not in [do for do, _ in world.acts]


def test_ghosts_modded_recipe_is_explained_not_faked(live):
    recipes = dict(RECIPES)
    recipes[MINER] = ({"kr-iron-beam": 4, "electronic-circuit": 3}, 1)   # в сейве другой рецепт
    world = ghost_world(recipes=recipes)
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is False and res["missing"] == {MINER: 2}
    note = next(n for n in res["missing_detail"] if n.get("item") == MINER)
    assert "другой рецепт" in note["why"] and note["craftable"] == 0


def test_ghosts_unreachable_stores(live):
    world = ghost_world(unreachable=True)
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is False and MINER in res["missing"]
    walks = [s for s in res["steps"] if s["step"] == "walk"]
    assert len(walks) >= 5 and all(s["code"] == "path_failed" for s in walks)     # центр и точки вокруг


def test_ghosts_walks_to_stores_that_are_not_visible_from_afar(live):
    """Без радаров содержимое дальних складов не видно: collect издалека пуст, тогда — подойти самому."""
    world = ghost_world(far_invisible=True)
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is True, res
    kinds = [(s["step"], s.get("code")) for s in res["steps"]]
    far = kinds.index(("collect", "no_items"))
    assert kinds[far + 1] == ("walk", None) and kinds[far + 2] == ("collect", None)


def test_ghosts_avoids_buildings_seen_on_the_map(live):
    world = ghost_world(blocked={(x, y) for x in range(30, 44) for y in range(0, 8)})   # верх пятна застроен
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is True, res
    assert len(res["dry_run"]) == 1 and res["anchor"]["y"] > 8          # первое же окно — на свободной руде
    assert all(pos[1] > 8 for pos in built(world, MINER)) and res["ore"] == "iron-ore"


def test_ghosts_drills_go_only_on_ore_they_can_mine(live):
    """Живой замер 2026-10-13: на голой земле и на вольфраме призрак электрического бура не встаёт."""
    world = World(ore={"tungsten-ore": ore_rect(20, 0, 12, 12), "iron-ore": ore_rect(60, 40, 14, 14)})
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is True, res
    assert res["ore"] == "iron-ore"
    tung = [t for t in res["dry_run"] if t["ore"] == "tungsten-ore"]
    assert len(tung) == 2 and all(t["why"][0] == {"name": MINER, "reason": "cannot_place"} for t in tung)


def test_ghosts_ignores_buildings_that_stood_there_before(live):
    """Живой замер 2026-10-13: свободное окно нашлось на угле вплотную к чужой добыче — её буры и
    ленты в области сверки не должны считаться построенными сценарием."""
    world = World(ore={"iron-ore": ore_rect(30, 0, 9, 5)})       # руды ровно на одно окно
    for y in range(0, 5):
        for x in (29.5, 39.5):
            world.entities[(x, y + 0.5)] = {"name": BELT, "dir": 0, "ghost": False}
    for x in range(30, 39):
        for y in (-0.5, 5.5):
            world.entities[(x + 0.5, y)] = {"name": BELT, "dir": 4, "ghost": False}
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is True, res
    assert res["stood_before"] > 0 and res["on_map"]["belts"] == 3


def test_ghosts_no_ore_no_place(live):
    world = World()
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is False and "на руде" in res["reasons"][0] and not world.entities


def test_ghosts_dry_run_rejects_a_spot_the_map_called_free(live):
    """Карта показывает не всё (мелкие помехи): окончательно место подтверждает dry_run."""
    world = ghost_world()
    client, _ = live(world)
    scen = load("e2e_ghosts")
    api = scen.E.LiveApi(client)
    api.spawn()
    first = next(scen.E.ore_candidates(api, [], scen.SPOT[0], scen.SPOT[1], min_ore=scen.MIN_ORE))["area"]
    lt, rb = first["left_top"], first["right_bottom"]
    world.hidden = {(x, y) for x in range(lt["x"], rb["x"]) for y in range(lt["y"], rb["y"])}
    res = scen.run(client)
    assert res["ok"] is True, res
    assert res["dry_run"][0]["skipped"] == 5 and len(res["dry_run"]) == 2
    assert res["anchor"] != res["dry_run"][0]["anchor"]


def test_ghosts_no_place_at_all(live):
    world = ghost_world(blocked={(x, y) for x in range(-30, 50) for y in range(-30, 50)})
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is False and "нет свободного места" in res["reasons"][0]
    assert not world.entities


def test_ghosts_needs_the_real_mod(live):
    world = ghost_world(mod="partner-test 0.2.0")
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_ghosts_detects_wrong_build(live):
    """Сверка идёт с картой, а не с ответом действия: если мод «построил» не то — сценарий красный."""
    world = ghost_world()
    orig = world.do_build_ghosts

    def lying(h, a):
        detail = orig(h, a)
        pos = built(world, MINER)[0]
        world.entities[pos]["dir"] = 0          # бур смотрит не на ленту
        return detail

    world.do_build_ghosts = lying
    client, _ = live(world)
    res = load("e2e_ghosts").run(client)
    assert res["ok"] is False and any("смотрят" in r for r in res["reasons"])


# ------------------------------------------------------------ e2e_mining

def mining_world(**kw):
    return World(ore={"iron-ore": ore_rect(30, 0, 14, 14)}, **kw)


def test_mining_happy_path(live):
    world = mining_world()
    client, srv = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is True, res
    assert res["chosen"] == {"miner": MINER, "belt": BELT, "pole": POLE}
    assert res["patch"]["name"] == "iron-ore" and res["patch"]["ore_in_window"] == 81
    route = res["belt"]["length"]
    need = res["inventory"]["need"]
    assert route > 0 and need == {MINER: 6, BELT: 9 + route, POLE: 1} and res["inventory"]["spent"] == need
    assert len(built(world, MINER)) == 6 and len(built(world, BELT)) == 9 + route and not ghosts(world)
    assert res["on_map"]["drills"] == 6 and res["coverage"]["drills_off_ore"] == []
    assert res["coverage"]["covered_share"] >= 0.6 and res["belt_dirs"] == [0]
    plans = [a for do, a in world.acts if do == "plan_mining"]
    assert plans[0].get("dry_run") is True and not plans[-1].get("dry_run")
    assert all(p["miner"] == MINER and p["belt"] == BELT and p["pole"] == POLE for p in plans)
    assert [do for do, _ in world.acts][-1] == "build_ghosts"
    assert all(c.startswith("/partner {") for c in srv.commands)
    # порядок поручения: access → plan_mining → plan_belt (от выходов разметки) → collect → build_ghosts
    belts = [a for do, a in world.acts if do == "plan_belt"]
    assert belts[0].get("dry_run") is True and not belts[-1].get("dry_run")
    assert all(b["from"] == "patch" and b["belt"] == BELT and b["underground"] == "never" for b in belts)
    dos = [do for do, a in world.acts if not a.get("dry_run")]
    assert [d for d in dos if d in ("plan_mining", "plan_belt", "collect", "build_ghosts")][:2] == ["plan_mining",
                                                                                                   "plan_belt"]
    assert dos.index("plan_belt") < dos.index("collect") < dos.index("build_ghosts")
    assert world.ops.index("access") < world.ops.index("act") or "access" in world.ops
    assert res["access"]["enclosed"] is False and res["access"]["liquid"] == 0 and res["access"]["exits"]
    # лента непрерывна: конец стоит севернее разметки, все ленты разметки и трассы доезжают до него
    info = res["belt"]
    assert info["laid"] == route and info["laid_lost"] == [] and info["mining_belts"] == 9 and info["mining_cut"] == []
    assert info["to"][1] < res["patch"]["window"]["left_top"]["y"]
    assert res["built"] == {"total": 16 + route, "expected": 16 + route}


def test_mining_belt_goes_around_liquid(live):
    """Перед разметкой с севера лежит полоса жидкости: лента обходит её, а не идёт напрямик."""
    lava = {(x, y) for x in range(20, 50) for y in range(-6, -3)}
    world = mining_world(liquid=lava)
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is True, res
    route = [pos for pos, e in world.entities.items() if e["name"] == BELT and pos[1] < 0]
    assert route and not any((int(x), int(y) if y >= 0 else int(y) - 1) in lava for x, y in route)
    assert not any((int(pos[0]), int(pos[1] // 1)) in lava for pos in world.entities)
    assert res["belt"]["length"] > 20 and res["belt"]["laid_lost"] == []      # обход длиннее прямой
    assert res["access"]["liquid"] == 0 and res["belt_plan"]["data"]["detail"]["turns"] >= 2


def test_mining_detects_a_gap_in_the_belt(live):
    world = mining_world()
    orig = world.do_plan_belt

    def gap(h, a):
        detail = orig(h, a)
        if not a.get("dry_run"):
            cells = sorted(pos for pos, e in world.entities.items() if e["ghost"] and e["name"] == BELT
                           and pos[1] < 0)
            world.entities.pop(cells[len(cells) // 2])        # одна клетка трассы не встала
        return detail

    world.do_plan_belt = gap
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False
    assert any("лента рвётся" in r for r in res["reasons"]) and res["belt"]["laid_lost"]
    assert any("не соединена" in r for r in res["reasons"]) and len(res["belt"]["mining_cut"]) > 0


def test_mining_detects_a_belt_that_does_not_start_at_the_patch(live):
    """Лента проложена, но не от выхода разметки: руда с буров до конца не доедет."""
    world = mining_world()
    orig = world.do_plan_belt

    def aside(h, a):
        shifted = dict(a, **{"from": {"x": a["to"]["x"] + 6.0, "y": a["to"]["y"]}})
        return orig(h, shifted)

    world.do_plan_belt = aside
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False and any("не соединена" in r for r in res["reasons"])
    assert res["belt"]["laid_lost"] == [] and len(res["belt"]["mining_cut"]) > 0


def test_mining_detects_a_belt_turned_the_wrong_way(live):
    world = mining_world()
    orig = world.do_plan_belt

    def turned(h, a):
        detail = orig(h, a)
        if not a.get("dry_run"):
            cells = sorted(pos for pos, e in world.entities.items() if e["ghost"] and e["name"] == BELT
                           and pos[1] < 0)
            world.entities[cells[len(cells) // 2]]["dir"] = 8          # лента посреди трассы едет назад
        return detail

    world.do_plan_belt = turned
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False and any("лента рвётся" in r for r in res["reasons"])


def test_mining_belt_has_no_route(live):
    """Разметка окружена жидкостью со всех сторон вплотную к рамке: ленте некуда — честный отказ."""
    ring = {(x, y) for x in range(18, 56) for y in range(-12, 26)
            if not (24 <= x < 50 and -6 <= y < 20)}
    world = mining_world(liquid=ring)
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False
    assert any("enclosed" in r or "plan_belt" in r for r in res["reasons"])
    assert not built(world, MINER)                      # без ленты добычу не строим


def test_mining_island_is_not_marked(live):
    """Остров в жидкости: `access` говорит enclosed — сценарий не размечает и не строит."""
    # суша — пятно руды и две клетки вокруг: рамка access (участок + 8 клеток) вся в жидкости
    moat = {(x, y) for x in range(10, 64) for y in range(-20, 34) if not (28 <= x < 46 and -2 <= y < 16)}
    world = mining_world(liquid=moat, helper_pos={"x": 37.5, "y": 14.5})
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False and res["access"]["enclosed"] is True
    assert any("enclosed" in r for r in res["reasons"])
    assert not ghosts(world) and all(do != "plan_belt" for do, _ in world.acts)


def test_mining_access_refusal_is_a_reason(live):
    world = mining_world()

    def refuse(args, helper):
        from e2e_world import ModError
        raise ModError("unknown_op", "access")

    world.op_access = refuse
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False and any("access" in r for r in res["reasons"]) and not ghosts(world)


def test_mining_belt_longer_than_the_run_can_carry(live):
    world = mining_world()
    scen = load("e2e_mining")
    scen.MAX_BELT = 3
    client, _ = live(world)
    res = scen.run(client)
    assert res["ok"] is False and any("plan_belt (dry_run)" in r for r in res["reasons"])
    assert res["belt_dry_run"] and all(t["kind"] == "job_done" for t in res["belt_dry_run"])
    assert not built(world, MINER)


def test_mining_skips_ore_the_drill_cannot_mine(live):
    """Живой замер 2026-10-13: ближайшая руда на Вулканусе — вольфрам, электрический бур её не берёт."""
    world = World(ore={"tungsten-ore": ore_rect(20, 0, 12, 12), "iron-ore": ore_rect(60, 40, 14, 14)})
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is True, res
    assert res["ore_skipped"] == ["tungsten-ore"] and res["patch"]["name"] == "iron-ore"
    assert res["dry_run"][0]["code"] == "bad_args" and "can't mine" in res["dry_run"][0]["text"]
    assert [t["resource"] for t in res["dry_run"]].count("tungsten-ore") == 1     # одного отказа достаточно


def test_mining_only_unminable_ore(live):
    world = World(ore={"tungsten-ore": ore_rect(20, 0, 12, 12)})
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False and "tungsten-ore" in res["reasons"][0]
    assert not ghosts(world)


def test_mining_no_ore_is_a_setup_error(live):
    world = World()
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and "руды" in res["error"]["text"]
    assert not world.acts or all(do != "plan_mining" for do, _ in world.acts)


def test_mining_ore_under_buildings_has_no_free_window(live):
    world = mining_world(blocked={(x, y) for x in range(30, 44, 3) for y in range(0, 14)})
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False and "свободном окне" in res["reasons"][0]
    assert not ghosts(world)


def test_belt_helpers(E, live):
    belts = {(0, 3): {"dir": 0}, (0, 2): {"dir": 0}, (0, 1): {"dir": 4}, (1, 1): {"dir": 4}, (2, 1): {"dir": 4},
             (5, 5): {"dir": 12}, (4, 5): {"dir": 4}, (9, 9): {"dir": 2}}
    assert E.flows_to(belts, (0, 3), (2, 1)) == (True, (2, 1))
    assert E.flows_to(belts, (2, 1), (2, 1)) == (True, (2, 1))
    assert E.flows_to(belts, (0, 3), (1, 1))[0] is True
    assert E.flows_to(belts, (1, 1), (0, 3)) == (False, (3, 1))         # лента кончилась
    assert E.flows_to(belts, (5, 5), (0, 0))[0] is False                # две ленты друг в друга — круг
    assert E.flows_to(belts, (9, 9), (0, 0)) == (False, (9, 9))         # диагональ: не лента
    assert E.flows_to(belts, (7, 7), (7, 7)) == (False, (7, 7))         # в начале ленты нет
    assert E.cell_of({"x": -0.5, "y": 3.5}) == (-1, 3) and E.cell_center((-1, 3)) == {"x": -0.5, "y": 3.5}
    # клетки лент читаются с карты окнами; призраки и постройки различаются
    world = World()
    for i in range(30):
        world.entities[(i + 0.5, 0.5)] = {"name": BELT, "dir": 4, "ghost": i % 2 == 0}
    world.entities[(3.5, 5.5)] = {"name": MINER, "dir": 0, "ghost": False}
    client, _ = live(world)
    client.call_ok("helper_spawn", {}, "e2e")
    area = {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 30, "y": 1}}
    cells, truncated = E.belt_cells(E.LiveApi(client), [area, area], [BELT])
    assert len(cells) == 30 and not truncated and cells[(4, 0)] == {"name": BELT, "dir": 4, "ghost": True}
    assert cells[(5, 0)]["ghost"] is False and (3, 5) not in cells
    assert world.ops.count("map") == 2                                   # одна и та же область дважды не читается


def test_belt_targets_are_ahead_of_the_patch_on_bare_ground(E, live):
    world = World(ore={"iron-ore": ore_rect(0, -50, 80, 48)})          # к северу от участка — сплошная руда
    client, _ = live(world)
    client.call_ok("helper_spawn", {}, "e2e")
    area = {"left_top": {"x": 29, "y": -1}, "right_bottom": {"x": 40, "y": 10}}
    log = []
    assert E.belt_targets(E.LiveApi(client), area, "north", log) == []   # впереди только руда: голой земли нет
    east = E.belt_targets(E.LiveApi(client), area, "east", log)
    assert east and all(x >= 40 + 3 for x, y in east) and len(east) <= 4
    assert log[-1]["step"] == "belt_target" and log[-1]["ahead"] >= len(east)


def test_mining_missing_items_leaves_ghosts_and_explains(live):
    stores = default_stores()
    stores[1]["items"].pop(POLE)                      # столбов нет и скрафтить не из чего
    world = mining_world(stores=stores)
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False
    # столб выбран тот, что сценарий умеет скрафтить, но сырья (дерево, кабель) на базе нет
    assert res["chosen"]["pole"] == "small-electric-pole"
    assert res["missing"] == {"small-electric-pole": 1}
    assert ghosts(world) and not built(world, MINER)


def test_mining_detects_drill_off_ore(live):
    world = mining_world()
    orig = world.do_plan_mining

    def shifted(h, a):
        detail = orig(h, a)
        if not a.get("dry_run"):
            pos = next(p for p, e in world.entities.items() if e["name"] == MINER)
            world.entities[(pos[0], pos[1] - 40)] = world.entities.pop(pos)   # бур уехал с руды
        return detail

    world.do_plan_mining = shifted
    client, _ = live(world)
    res = load("e2e_mining").run(client)
    assert res["ok"] is False


# ------------------------------------------------------------ помощники _e2e

@pytest.fixture
def E():
    return load("e2e_ghosts").E


def test_blueprint_roundtrip(E):
    ents = E.drill_pair_blueprint(MINER, BELT)
    bp = E.decode_blueprint(E.encode_blueprint(ents))["blueprint"]
    assert bp["item"] == "blueprint" and len(bp["entities"]) == 5
    assert [e["entity_number"] for e in bp["entities"]] == [1, 2, 3, 4, 5]
    assert {e["name"] for e in bp["entities"]} == {MINER, BELT}
    assert bp["version"] >> 48 == 2


def test_ingredients(E):
    need, runs, unknown = E._ingredients({MINER: 2, "transport-belt": 3, "big-mining-drill": 1})
    assert runs == {MINER: 2, "transport-belt": 2}              # лента выходит по 2 за крафт
    assert need == {"electronic-circuit": 6, "iron-gear-wheel": 12, "iron-plate": 22}
    assert unknown == ["big-mining-drill"]


def test_free_windows_and_ore_cells(E):
    data = {"bbox": {"x0": 10, "y0": 20, "x1": 15, "y1": 23},
            "legend": {".": "земля", "i": "руда: iron-ore", "c": "руда: copper-ore", "D": "бур"},
            "rows": ["iiii.c",
                     "iiiD.c",
                     "iiii..",
                     "......"]}
    assert E.ore_cells(data, "iron-ore") == {(10, 20), (11, 20), (12, 20), (13, 20), (10, 21), (11, 21), (12, 21),
                                             (10, 22), (11, 22), (12, 22), (13, 22)}
    wins = E.free_windows(data, "iron-ore", 3, 3, min_ore=1)
    assert wins[0] == {"ore": 9, "area": {"left_top": {"x": 10, "y": 20}, "right_bottom": {"x": 13, "y": 23}}}
    # окно не может накрыть бур, чужую руду и выйти за карту
    assert E.free_windows(data, "iron-ore", 4, 3, min_ore=1) == []
    assert E.free_windows(data, "iron-ore", 7, 1) == []
    assert E.free_windows({}, "iron-ore", 2, 2) == []
    # свободная земля без руды (для forge, когда руды рядом нет)
    assert E.free_windows(data, "", 6, 1, min_ore=0)[0]["area"]["left_top"] == {"x": 10, "y": 23}


def test_drill_on_ore_and_coverage(E):
    cells = {(0, 0), (1, 0), (10, 10)}
    assert E.drill_on_ore({"x": 2.5, "y": 1.5}, 2.5, cells)          # область 5×5: клетки 0..4 × -1..3
    assert not E.drill_on_ore({"x": 5.5, "y": 5.5}, 2.5, cells)
    assert E.covered_share([{"x": 2.5, "y": 1.5}], 2.5, cells) == round(2 / 3, 3)
    assert E.covered_share([], 2.5, cells) == 0.0 and E.covered_share([{"x": 0, "y": 0}], 1, set()) == 0.0


def test_act_refused_and_timeout_cancels(E, live):
    world = World()
    client, srv = live(world)
    api = E.LiveApi(client)
    assert api.spawn()[0] is True and api.spawn() == (True, {"reused": True})
    r = api.act("fly", {})
    assert r["kind"] == "refused" and r["data"]["code"] == "bad_args" and r["job"] is None
    world._emit = lambda *a, **k: None            # итог задачи не приходит
    r = api.act("walk", {"to": {"x": 1, "y": 1}}, timeout=0.6)
    assert r["kind"] is None and r["job"] == 1
    assert '"op":"cancel"' in srv.commands[-1]


def test_fetch_collects_only_what_is_there(E, live):
    world = World()
    client, _ = live(world)
    api = E.LiveApi(client)
    api.spawn()
    log = []
    missing = E.fetch(api, {"electronic-circuit": 5, "iron-plate": 7, "uranium-235": 1}, log)
    assert missing == {"uranium-235": 1}
    assert E.inventory(api) == {"electronic-circuit": 5, "iron-plate": 7}
    assert world.stores[0]["items"]["electronic-circuit"] == 195 and world.stores[1]["items"]["iron-plate"] == 4993
    assert [s["step"] for s in log][:2] == ["stock", "collect"]
    assert E.approach_points({"x": 1, "y": 2})[0] == {"x": 1, "y": 2} and len(E.approach_points({"x": 1, "y": 2})) == 5


def test_find_ore_skips_unknown_names_and_small_patches(E, live):
    world = World(ore={"iron-ore": ore_rect(30, 0, 6, 6), "coal": ore_rect(-20, -20, 2, 2)})
    client, _ = live(world)
    api = E.LiveApi(client)
    api.spawn()
    log = []
    patches = E.find_ore(api, log)
    assert [p["name"] for p in patches] == ["iron-ore"]          # уголь 2×2 — огрызок, не пятно
    # имена, которых в игре нет (tungsten-ore и т.п. в модели неизвестны), спрашиваются один раз
    asked = [c for c in world.ops if c == "resources"]
    assert len(asked) == len(E.ORE_NAMES)
    assert [p["name"] for p in log[-1]["patches"]] == ["iron-ore"]
    assert E.find_ore(api, [], ["coal", "stone"]) == []


def test_api_for_picks_transport(E):
    class Plain:
        pass

    class WithTool:
        helper = "e2e"

        def tool(self, *a, **k):
            return {}

    assert isinstance(E.api_for(Plain()), E.LiveApi)
    assert isinstance(E.api_for(WithTool()), E.McpApi)


def test_scenarios_declare_runner_and_mods():
    import pack
    assert pack.scenario_runner("e2e_ghosts") == "live" and pack.scenario_runner("e2e_mining") == "live"
    assert pack.scenario_runner("e2e_mcp") == "server" and pack.scenario_runner("e2e_forge") == "server"
    for name in ("e2e_ghosts", "e2e_mining", "e2e_mcp", "e2e_forge"):
        assert pack.scenario_mods(name) == ["factorio-partner"]
