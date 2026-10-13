"""Сценарии build_modes и build_tiles (поток F) против фейкового RCON с моделью мода.

Модель и запуск — из test_build_scenarios.py. Проверяется, что сценарии: честно берут предметы,
правильно записывают факты о режимах постановки (и видят, когда «движок» ведёт себя иначе),
замечают поломки мода (помеченное не разобрано, плитки после построек, плитки не поставлены).
"""
from __future__ import annotations

import pytest

from test_build_scenarios import Model, _no_wait, fast, load, run  # noqa: F401  (fast — autouse-фикстура)

ROCKS = {(-5.9, -10.2): "big-volcanic-rock", (-12.3, 3.4): "big-volcanic-rock"}
LAVA = [(x, y) for x in range(0, 4) for y in range(-20, -10)]
STOCK = {"steel-plate": 200, "stone": 200}


def world(**kw):
    kw.setdefault("stock", dict(STOCK))
    kw.setdefault("lava", LAVA)
    kw.setdefault("naturals", dict(ROCKS))
    return Model(**kw)


# ---------- build_modes ----------

def test_modes_records_engine_facts(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = world()
    res = run("build_modes", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    # предметы честные: сырьё со склада, постройки — крафт
    assert m.stock["steel-plate"] == 200 - 48 and m.stock["stone"] == 200 - 10
    assert [(t["place"], t["force"]) for t in res["trials"]] == [
        (p, f) for p in ("lava", "rock", "own") for f in ("normal", "forced", "superforced")]
    # каждому режиму на лаве — своя клетка
    cells = [(t["anchor"]["x"], t["anchor"]["y"]) for t in res["trials"] if t["place"] == "lava"]
    assert len(set(cells)) == 3
    assert res["contract"] == {
        "normal_marks_nothing": True,
        "normal_on_obstacle_places_no_ghost": True,
        "normal_on_lava_skips_cell": True,
        "forced_on_lava_puts_tile_ghosts": False,
        "forced_on_lava_refuses_whole": True,
        "forced_on_lava_liquids": {"lava": 1},
        "forced_on_lava_gives_fit": True,
        "forced_marks_rock": True,
        "forced_marks_tree": None,
        "forced_marks_own_building": False,
        "superforced_marks_own_building": True,
    }
    assert res["dry_run_mismatch"] == {}
    facts = res["facts"]
    assert facts["rock"]["normal"]["result"] == "cannot_place" and facts["rock"]["normal"]["obstacle_left"] == 1
    assert facts["rock"]["forced"] == {
        "result": "job_done", "ghosts": 1, "tiles": 0, "marked": 1, "marked_names": ["big-volcanic-rock"],
        "removed": 1, "built": 1, "missing": {}, "skipped": [], "obstacle_left": 0, "built_on_map": 1}
    # лава: forced не ставит чертёж вовсе и предлагает сдвиг; normal пропускает клетку
    lava = facts["lava"]
    assert lava["forced"]["result"] == "cannot_place" and lava["forced"]["on_liquid"] == 1
    assert lava["forced"]["fit"]["shift"] in ({"dx": 1, "dy": 0}, {"dx": 0, "dy": 1})
    assert lava["normal"]["result"] == "cannot_place" and lava["normal"]["skipped"] == ["liquid"]
    assert lava["superforced"]["liquids"] == {"lava": 1}
    assert facts["own"]["forced"]["result"] == "cannot_place"
    assert facts["own"]["superforced"]["marked_names"] == ["stone-furnace"]
    assert facts["own"]["superforced"]["removed"] == 1 and facts["own"]["superforced"]["built_on_map"] == 1
    # normal и forced — на одном камне, superforced — на втором
    rock = [t["obstacle"]["pos"] for t in res["trials"] if t["place"] == "rock"]
    assert rock[0] == rock[1] != rock[2]
    assert m.naturals == {} and m.marked == set()
    # каждая постановка — с явным режимом; dry_run перед настоящей
    bps = [a for d, a in m.acts if d == "build_blueprint"]
    assert [a["force"] for a in bps] == [f for _ in range(3) for f in ("normal", "normal", "forced", "forced", "superforced", "superforced")]
    assert [bool(a.get("dry_run")) for a in bps] == [True, False] * 9


def test_modes_other_engine_behaviour_is_recorded_not_failed(fake_rcon, monkeypatch):
    """«Движок» ставит подложку на лаве и сносит свои постройки уже с Shift — это факты, а не сбой сценария."""
    _no_wait(monkeypatch)
    m = world(lava_cover="foundation", forced_marks_own=True)
    res = run("build_modes", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    c = res["contract"]
    assert c["forced_on_lava_puts_tile_ghosts"] is True and c["forced_on_lava_refuses_whole"] is False
    assert c["forced_on_lava_gives_fit"] is False and c["forced_on_lava_liquids"] is None
    assert c["forced_marks_own_building"] is True and c["superforced_marks_own_building"] is True
    lava = res["facts"]["lava"]["forced"]
    assert lava["result"] == "no_items" and lava["missing"] == {"foundation": 1} and lava["ghosts"] == 1
    # печь снесли на forced — для superforced сценарий поставил вторую
    assert len(res["own_placed"]) == 2


def test_modes_with_trees(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    naturals = dict(ROCKS)
    naturals[(20.4, 3.1)] = "ashland-lichen-tree"
    res = run("build_modes", world(naturals=naturals), fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["contract"]["forced_marks_tree"] is True
    assert [t["force"] for t in res["trials"] if t["place"] == "tree"] == ["normal", "forced", "superforced"]


def test_modes_marked_but_not_removed_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_modes", world(dig_fails=True), fake_rcon)
    assert res["ok"] is False
    assert any("помечено 1, разобрано 0" in r for r in res["reasons"]), res["reasons"]
    assert any("остались призраки" in r for r in res["reasons"])


def test_modes_missing_places_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_modes", Model(stock=dict(STOCK)), fake_rcon)
    assert res["ok"] is False
    assert sum("не нашлось места" in r for r in res["reasons"]) == 2   # лавы и камня нет, своя постройка есть
    assert [t["place"] for t in res["trials"]] == ["own"] * 3


def test_modes_no_stock_is_setup_error(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_modes", world(stock={}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"
    assert "trials" not in res


def test_modes_helpers():
    s = load("build_modes")
    assert s.cell({"x": -66.1, "y": 45}) == {"x": -66.5, "y": 45.5}
    cells = [{"x": 0.5, "y": 0.5}, {"x": 1.5, "y": 0.5}, {"x": 3.5, "y": 0.5}, {"x": 3.5, "y": 4.5}]
    assert s.spread(cells, 3) == [cells[0], cells[2], cells[3]]
    t = {"dry_run": {"detail": {"ghosts": 1, "tiles": 1, "to_remove_total": 0}},
         "run": {"detail": {"ghosts": 0, "tiles": 0, "skipped_total": 1, "on_liquid": 1}}}
    assert s.mismatch(t) == {"ghosts": {"dry_run": 1, "run": 0}, "tiles": {"dry_run": 1, "run": 0},
                             "skipped_total": {"dry_run": None, "run": 1}, "on_liquid": {"dry_run": None, "run": 1}}
    same = {"dry_run": {"detail": {"ghosts": 1, "tiles": 0, "skipped": {}}}, "run": {"detail": {"ghosts": 1, "tiles": 0}}}
    assert s.mismatch(same) == {}


def test_survey_finds_lava_rocks_trees(fake_rcon):
    import live_client as lc
    from conftest import PASSWORD
    p = load("build_place")
    m = world(naturals={(-5.9, -10.2): "big-volcanic-rock", (70.5, 0.5): "big-volcanic-rock", (12.2, -3.3): "ashland-lichen-tree"})
    srv = fake_rcon(handler=m)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        result = {}
        around = p.survey(c, result)
    assert result["survey"] == {"pos": m.pos, "lava_cells": len(LAVA), "rocks": 2, "trees": 1}
    assert [e["pos"]["x"] for e in around["rocks"]] == [-5.9, 70.5]   # ближние первыми
    assert around["lava"][0] == {"x": 3.5, "y": -10.5}
    # нейтральное запрошено явно
    maps = [c for c in srv.commands if '"op": "map"' in c or '"op":"map"' in c]
    assert len(maps) == 9 and all("simple-entity" in c and "tree" in c for c in maps)


# ---------- build_tiles ----------

TILE_STOCK = {"refined-concrete": 50, "steel-plate": 100}


def test_tiles_ok(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock=dict(TILE_STOCK))
    res = run("build_tiles", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert (res["tile_item"], res["tile"], res["item"]) == ("refined-concrete", "refined-concrete", "steel-chest")
    assert res["anchor"] == {"x": 14.5, "y": -4.5}
    d = res["build"]["data"]["detail"]
    assert (d["ghosts"], d["tiles"], d["built"], d["tiles_built"], d["tiles_first"]) == (1, 3, 4, 3, True)
    assert res["inventory"]["before"] == {"refined-concrete": 5, "steel-chest": 1}
    assert res["inventory"]["after"] == {"refined-concrete": 2, "steel-chest": 0}
    # плитки лежат под сундуком и по бокам, плюс две от чертежа из одних плиток
    assert {c for c, n in m.tiles.items() if n == "refined-concrete"} == {(13, -5), (14, -5), (15, -5), (14, -3), (15, -3)}
    assert m.entities == {(14.5, -4.5): "steel-chest"}
    assert res["dry_run_again"]["detail"]["tiles"] == 0 and res["dry_run_again"]["detail"]["ghosts"] == 0
    assert res["tiles_only"]["data"]["detail"]["tiles_built"] == 2
    assert m.stock["refined-concrete"] == 45


def test_tiles_liquid_probe_records_engine_answer(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    stock = dict(TILE_STOCK, landfill=10)
    # «движок» как на Вулканусе: отсыпка на лаву не кладётся, постройка не встаёт
    m = Model(stock=stock, lava=LAVA)
    res = run("build_tiles", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    liquid = res["liquid"]
    assert liquid["anchor"] == {"x": 3.5, "y": -10.5} and liquid["run"]["code"] == "cannot_place"
    assert liquid["facts"] == {"tile_ghost_placed": False, "entity_ghost_placed": False, "tiles_built": 0, "built": 0,
                               "tiles_first": None, "on_liquid": 1, "liquids": {"lava": 1}}
    assert liquid["dry_run"]["detail"]["tiles_skipped"] == 1 and liquid["dry_run"]["kind"] == "job_done"
    # ничего из воздуха: отсыпка взята со склада и осталась у помощника
    assert m.inv.get("landfill") == 1 and m.stock["landfill"] == 9


def test_tiles_liquid_probe_skipped_without_lava_or_landfill(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_tiles", Model(stock=dict(TILE_STOCK, landfill=10)), fake_rcon)
    assert res["ok"] is True and "нет воды и лавы" in res["liquid"]["skipped"]
    res = run("build_tiles", Model(stock=dict(TILE_STOCK), lava=LAVA), fake_rcon)
    assert res["ok"] is True and "landfill" in res["liquid"]["skipped"]


def test_tiles_second_choice_of_tile(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock={"stone-brick": 30, "steel-plate": 100})
    res = run("build_tiles", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert (res["tile_item"], res["tile"]) == ("stone-brick", "stone-path")
    assert set(m.tiles.values()) == {"stone-path"}


def test_tiles_after_entities_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_tiles", Model(stock=dict(TILE_STOCK), tiles_last=True), fake_rcon)
    assert res["ok"] is False
    assert any("tiles_first" in r for r in res["reasons"]), res["reasons"]


def test_tiles_not_placed_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_tiles", Model(stock=dict(TILE_STOCK), ignore_tiles=True), fake_rcon)
    assert res["ok"] is False and "dry_run" in res["reasons"][0]


def test_tiles_dry_run_skips_dirty_place(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock=dict(TILE_STOCK), naturals={(14.4, -4.6): "big-volcanic-rock"})   # камень на первом месте: чистым оно не считается
    res = run("build_tiles", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["anchor"] != {"x": 14.5, "y": -4.5}
    assert m.naturals, "камень рядом с первым местом не тронут"


def test_tiles_no_tile_items_is_setup_error(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_tiles", Model(stock={"steel-plate": 100}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_tile_blueprints():
    s, g = load("build_tiles"), load("build_ghosts")
    bp = g.decode_blueprint(s.tile_blueprint("steel-chest", "refined-concrete"))["blueprint"]
    assert [(e["entity_number"], e["name"], e["position"]) for e in bp["entities"]] == [(1, "steel-chest", {"x": 0.5, "y": 0.5})]
    assert bp["tiles"] == [{"name": "refined-concrete", "position": {"x": dx, "y": 0}} for dx in (-1, 0, 1)]
    only = g.decode_blueprint(s.tiles_only_blueprint("concrete"))["blueprint"]
    assert "entities" not in only and len(only["tiles"]) == 2
    assert only["version"] == (2 << 48) | (77 << 16)


@pytest.mark.parametrize("name", ["build_modes", "build_tiles", "build_2x2", "build_robots"])
def test_scenarios_send_only_partner_envelopes(name):
    """В тексте сценариев нет ничего, кроме вызовов live_client: ни сырых команд, ни адресов."""
    import os
    from conftest import PC_DIR
    with open(os.path.join(PC_DIR, "scenarios", name + ".py"), encoding="utf-8") as f:
        text = f.read()
    assert "_send_raw" not in text and "socket" not in text and "subprocess" not in text
