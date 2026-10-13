"""Сценарии build_2x2 и build_robots (поток F) против фейкового RCON с моделью мода.

Модель и запуск — из test_build_scenarios.py.
"""
from __future__ import annotations

from test_build_scenarios import Model, _no_wait, fast, load, run  # noqa: F401  (fast — autouse-фикстура)

STOCK = {"stone": 100, "steel-plate": 100}


# ---------- build_2x2 ----------

def test_2x2_ok(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock=dict(STOCK))
    res = run("build_2x2", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    # печь 2×2 ставится центром на стык клеток и разбирается по {unit_number, pos}
    place = [a for d, a in m.acts if d == "place"]
    assert place == [{"item": "stone-furnace", "pos": {"x": 15, "y": -5}}]
    assert res["place"]["on_map"] == [{"x": 15, "y": -5}]
    first_decon = [a for d, a in m.acts if d == "deconstruct"][0]
    assert first_decon == {"target": {"unit_number": 101, "pos": {"x": 15, "y": -5}}}
    # четыре поворота, вектор «печь → сундук» повёрнут вместе с чертежом
    assert [t["direction"] for t in res["turns"]] == [0, 4, 8, 12]
    assert [tuple(t["vector"]["built"]) for t in res["turns"]] == [(1.5, -0.5), (0.5, 1.5), (-1.5, 0.5), (-0.5, -1.5)]
    for t in res["turns"]:
        assert tuple(t["vector"]["built"]) == tuple(t["vector"]["expected"])
        assert set(t["mod_layout"]) == {"stone-furnace", "steel-chest"}
    # сверка раскладки — dry_run в режиме normal поверх построенного
    checks = [a for d, a in m.acts if d == "build_blueprint" and a.get("force") == "normal"]
    assert [a["direction"] for a in checks] == [0, 4, 8, 12] and all(a["dry_run"] for a in checks)
    # после каждого поворота всё разобрано, предметы у помощника
    assert m.entities == {} and m.inv == {"stone-furnace": 1, "steel-chest": 1}


def test_2x2_layout_mismatch_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_2x2", Model(stock=dict(STOCK), layout_shift=1.0), fake_rcon)
    assert res["ok"] is False
    assert any("расчёт мода" in r for r in res["reasons"]), res["reasons"]


def test_2x2_picks_place_clean_for_all_turns(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    # камень мешает только одному из поворотов на первом месте
    m = Model(stock=dict(STOCK), naturals={(15.5, -3.4): "big-volcanic-rock"})
    res = run("build_2x2", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["anchor"] != {"x": 15, "y": -5}
    assert m.naturals and not m.marked, "камень не помечен и не тронут"


def test_2x2_no_stone_is_setup_error(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_2x2", Model(stock={"steel-plate": 100}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_2x2_place_failure_is_reported(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_2x2", Model(stock=dict(STOCK), break_place="path_failed"), fake_rcon)
    assert res["ok"] is False
    assert any("place печи" in r for r in res["reasons"])


def test_rotate():
    s = load("build_2x2")
    assert [s.rotate(1.5, -0.5, d) for d in (0, 4, 8, 12)] == [(1.5, -0.5), (0.5, 1.5), (-1.5, 0.5), (-0.5, -1.5)]


# ---------- build_robots ----------

def test_robots_absent_checks_contract_fallbacks(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model()
    res = run("build_robots", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["robots_available"] is False and "не проверен" in res["limitation"]
    assert res["robots"]["kind"] == "job_failed" and res["robots"]["data"]["code"] == "no_items"
    assert res["ghosts_after_robots"] == 2
    assert res["auto"]["data"]["detail"]["built"] == 2
    assert res["inventory"] == {"before": 2, "after": 0} and res["on_map"] == 2 and res["ghosts_left"] == 0
    builds = [(d, a.get("mode")) for d, a in m.acts if d in ("build_blueprint", "build_ghosts") and not a.get("dry_run")]
    assert builds == [("build_blueprint", "robots"), ("build_ghosts", "auto")]
    # дронов и броню сценарий из воздуха не берёт
    assert not any(d == "extract" for d, _ in m.acts)


def test_robots_present_builds_with_robots(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock={"wooden-chest": 5, "power-armor": 1, "construction-robot": 10}, armor="power-armor", robots=5)
    res = run("build_robots", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["robots_available"] is True and "limitation" not in res
    armor = [a for d, a in m.acts if d == "extract"][0]
    assert armor == {"target": {"unit_number": 55, "pos": {"x": 20.5, "y": 0.5}}, "items": {"power-armor": 1}, "equip": True}
    assert res["robots"]["kind"] == "job_done" and "auto" not in res
    assert m.inv.get("construction-robot") == 5


def test_robots_armor_without_roboport_is_limitation(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock={"wooden-chest": 5, "modular-armor": 1, "construction-robot": 10}, armor="modular-armor", robots=0)
    res = run("build_robots", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    assert res["robots_available"] is False and "робопорта" in res["limitation"]


def test_robots_auto_failure_is_reported(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_robots", Model(keep_ghosts=True), fake_rcon)
    assert res["ok"] is False
    assert any("build_ghosts auto" in r for r in res["reasons"])
    assert res["ghosts_left"] == 2
