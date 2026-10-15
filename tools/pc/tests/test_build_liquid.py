"""Сценарии build_liquid и build_marks против фейкового RCON с моделью мода.

Модель и запуск — из test_build_scenarios.py. Проверяется, что сценарии принимают поведение по
docs/ACTIONS.md, «build_blueprint» (клетка без подложки → чертёж не ставится, `fit`, `partial`, `rotate`; свои
пометки к сносу снимаются при сбое и отмене) и замечают каждую поломку мода по отдельности.
"""
from __future__ import annotations

import pytest

from test_build_scenarios import Model, _no_wait, fast, load, run  # noqa: F401  (fast — autouse-фикстура)

LAVA = [(x, y) for x in range(0, 4) for y in range(-20, -10)]
ROCKS = {(-5.9, -10.2): "big-volcanic-rock", (-12.3, 3.4): "big-volcanic-rock"}
STOCK = {"steel-plate": 200}


# ---------- build_liquid ----------

def test_liquid_ok(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(lava=LAVA)
    res = run("build_liquid", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    # берег: ближняя клетка лавы и суша справа от неё; чертёж серединой на границе
    assert res["anchor"] == {"x": 4.0, "y": -10.5} and res["land_cell"] == {"x": 4.5, "y": -10.5}
    d = res["dry_run"]["detail"]
    assert (d["on_liquid"], d["liquids"], d["ghosts"], d["skipped_total"]) == (1, {"lava": 1}, 1, 1)
    assert d["fit"] == {"anchor": {"x": 5.0, "y": -10.5}, "shift": {"dx": 1, "dy": 0}}
    # без partial — не встал, и в мире ничего не появилось
    assert res["refused"]["code"] == "cannot_place" and res["refused"]["after"] == {"ghosts": 0, "built": 0}
    assert res["refused"]["detail"]["fit"] == d["fit"]
    # rotate: поворот на месте, оценка в этом положении чистая
    assert res["rotate"]["rotate"]["detail"]["fit"] == {
        "anchor": {"x": 4.0, "y": -10.5}, "shift": {"dx": 0, "dy": 0}, "direction": 4, "mirror": False}
    assert res["rotate"]["proof"]["detail"]["ghosts"] == 2 and res["rotate"]["proof"]["args"]["direction"] == 4
    # по fit — целиком; потом убрано
    assert res["by_fit"]["detail"]["built"] == 2 and res["by_fit"]["items_used"] == 2
    assert res["cleanup"]["kind"] == "job_done"
    # partial — обрезанный: сундук только на суше
    cut = res["partial"]
    assert cut["args"]["partial"] is True and cut["detail"]["skipped"][0]["reason"] == "liquid"
    assert cut["after"] == {"ghosts": 0, "built_on_land": 1}
    assert m.entities == {(4.5, -10.5): "wooden-chest"}
    assert m.ghosts == {} and m.marked == set()
    # предметы честные: три сундука со склада, один стоит, два у помощника
    assert m.stock["wooden-chest"] == 2 and m.inv == {"wooden-chest": 2}
    # порядок постановок: без partial → по fit → partial; до первой настоящей — только оценки
    real = [a for do, a in m.acts if do == "build_blueprint" and not a.get("dry_run")]
    assert [(a["anchor"], bool(a.get("partial"))) for a in real] == [
        (res["anchor"], False), ({"x": 5.0, "y": -10.5}, False), (res["anchor"], True)]
    assert res["facts"]["liquids"] == {"lava": 1} and res["facts"]["refused"] == "cannot_place"


def test_liquid_no_lava_is_setup_error(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_liquid", Model(), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and "нет воды и лавы" in res["error"]["text"]
    res = run("build_liquid", Model(stock={}, lava=LAVA), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_liquid_mod_places_on_liquid_is_failure(fake_rcon, monkeypatch):
    """Старый мод без проверки подложки: ставит, что встаёт, и молчит про жидкость — сценарий не находит места для проверки."""
    _no_wait(monkeypatch)
    res = run("build_liquid", Model(lava=LAVA, place_on_liquid=True), fake_rcon)
    assert res["ok"] is False


def test_liquid_no_fit_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_liquid", Model(lava=LAVA, no_fit=True), fake_rcon)
    assert res["ok"] is False
    assert any("fit не найден" in r for r in res["reasons"]), res["reasons"]
    assert "by_fit" not in res
    # остальное проверено и без fit: отказ и обрезанный чертёж
    assert res["refused"]["code"] == "cannot_place" and res["partial"]["detail"]["built"] == 1


def test_liquid_partial_ignored_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_liquid", Model(lava=LAVA, ignore_partial=True), fake_rcon)
    assert res["ok"] is False
    assert any(r.startswith("partial: ждали job_done") for r in res["reasons"]), res["reasons"]


def test_liquid_fit_that_does_not_fit_is_failure(fake_rcon, monkeypatch):
    """Мод отдаёт сдвиг, при котором чертёж не встаёт (сдвиг на лаву)."""
    _no_wait(monkeypatch)
    m = Model(lava=LAVA)
    m._fit = lambda a: {"anchor": {"x": a["anchor"]["x"] - 2, "y": a["anchor"]["y"]}, "shift": {"dx": -2, "dy": 0}}
    res = run("build_liquid", m, fake_rcon)
    assert res["ok"] is False
    assert any(r.startswith("по fit ждали job_done") for r in res["reasons"]), res["reasons"]


def test_liquid_helpers():
    s = load("build_liquid")
    lava = [{"x": 0.5, "y": 0.5}, {"x": 1.5, "y": 0.5}]
    assert s.shores(lava) == [
        ({"x": 0.0, "y": 0.5}, {"x": 0.5, "y": 0.5}, {"x": -0.5, "y": 0.5}),
        ({"x": 2.0, "y": 0.5}, {"x": 1.5, "y": 0.5}, {"x": 2.5, "y": 0.5})]
    good = {"anchor": {"x": 1, "y": 2.5}, "shift": {"dx": 0, "dy": -1}}
    assert s.check_fit(good, False) == []
    assert len(s.check_fit(good, True)) == 2          # с rotate нужны direction и mirror
    assert s.check_fit(dict(good, direction=4, mirror=False), True) == []
    assert s.check_fit(dict(good, direction=2, mirror=False), True) == ["fit.direction: 2"]
    assert s.check_fit({"anchor": {"x": 1}, "shift": {"dx": 0.5, "dy": 0}}, False) != []
    assert s.check_fit(None, False) == ["fit не объект: None"]
    assert s.fit_args(good) == {}
    assert s.fit_args(dict(good, direction=8, mirror=True)) == {"direction": 8, "mirror": True}
    assert s.fit_args(dict(good, direction=0, mirror=False)) == {"direction": 0}
    assert s.liquid_total({"liquids": {"lava": 2, "oil": 1}}) == 3 and s.liquid_total({}) is None


# ---------- build_marks ----------

def marks_world(**kw):
    kw.setdefault("stock", dict(STOCK))
    kw.setdefault("naturals", dict(ROCKS))
    kw.setdefault("pause_far", 20)     # до дальнего камня (24 клетки) помощник «идёт», пока не отменят
    return Model(**kw)


def test_marks_ok(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = marks_world()
    res = run("build_marks", m, fake_rcon)
    assert res["ok"] is True, res.get("reasons")
    failed, cancelled = res["failed"], res["cancelled"]
    # сбой: mode robots без дронов → no_items; чертёж пометил камень, после сбоя пометки нет
    assert failed["anchor"] == {"x": -5.5, "y": -10.5} and failed["run"]["code"] == "no_items"
    assert failed["run"]["detail"]["to_remove_total"] == 1 and failed["run"]["detail"]["ghosts"] == 1
    assert failed["probe"]["marks_left"] is False and failed["probe"]["obstacle_left"] == 1
    assert failed["probe"]["detail"]["removed"] == 0
    # отмена: призрак появился, задача отменена, пометки нет
    assert cancelled["anchor"] == {"x": -12.5, "y": 3.5} and cancelled["placed"] is True
    assert cancelled["run"]["code"] == "cancelled" and cancelled["probe"]["marks_left"] is False
    # число снятых своих пометок — в detail и при сбое, и при отмене
    assert failed["run"]["detail"]["unmarked"] == 1 and cancelled["run"]["detail"]["unmarked"] == 1
    # замер: повторная постановка помечает камень заново, помощник его разбирает и строит
    assert res["recovery"]["ok"] is True and res["recovery"]["obstacle_left"] == 0 and res["recovery"]["built_on_map"] == 1
    assert m.marked == set()
    assert set(m.naturals) == {(-12.3, 3.4)}, "дальний камень цел: его пометку сняли"
    bps = [a for do, a in m.acts if do == "build_blueprint"]
    assert [(a["mode"], a["force"]) for a in bps] == [("robots", "forced"), ("hand", "forced"), ("hand", "forced")]


def test_marks_left_is_failure(fake_rcon, monkeypatch):
    """Мод не снимает свои пометки: помощник разбирает помеченное в проверке делом — сценарий это видит."""
    _no_wait(monkeypatch)
    m = marks_world(keep_marks=True)
    res = run("build_marks", m, fake_rcon)
    assert res["ok"] is False
    assert sum("пометка к сносу не снята" in r for r in res["reasons"]) == 2, res["reasons"]
    assert res["failed"]["probe"]["marks_left"] is True and res["cancelled"]["probe"]["marks_left"] is True
    assert "recovery" not in res


def test_marks_without_unmarked_count_is_failure(fake_rcon, monkeypatch):
    """Мод до 3.4: пометки снимает, но числа снятых в detail нет."""
    _no_wait(monkeypatch)
    res = run("build_marks", marks_world(no_unmarked=True), fake_rcon)
    assert res["ok"] is False
    assert sum("unmarked" in r for r in res["reasons"]) == 2, res["reasons"]


def test_marks_job_ends_before_cancel_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_marks", marks_world(pause_far=None), fake_rcon)   # стройка мгновенная — отменять нечего
    assert res["ok"] is False
    assert any("кончилась раньше отмены" in r for r in res["reasons"]), res["reasons"]


def test_marks_needs_obstacles(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_marks", marks_world(naturals={}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"
    one = marks_world(naturals={(-5.9, -10.2): "big-volcanic-rock"})
    res = run("build_marks", one, fake_rcon)
    assert res["ok"] is False and any("отмена не проверена" in r for r in res["reasons"])
    assert res["failed"]["probe"]["marks_left"] is False


def test_marks_helpers():
    s = load("build_marks")
    pos = {"x": 0, "y": 0}
    rocks = [{"name": "r", "pos": {"x": 3, "y": 0}}, {"name": "r", "pos": {"x": 5, "y": 0}},
             {"name": "r", "pos": {"x": 0, "y": 13}}, {"name": "r", "pos": {"x": 30, "y": 0}}]
    near, far = s.pick(rocks, pos)
    assert near == rocks[0] and far == rocks[2]
    assert s.pick(rocks[:2], pos) == (rocks[0], None)
    assert s.pick([], pos) == (None, None)
    assert s.box({"x": 1.5, "y": -2.5}) == {"left_top": {"x": 0.0, "y": -4.0}, "right_bottom": {"x": 3.0, "y": -1.0}}


@pytest.mark.parametrize("name", ["build_liquid", "build_marks"])
def test_scenarios_send_only_partner_envelopes(name):
    """В тексте сценариев нет ничего, кроме вызовов live_client: ни сырых команд, ни адресов."""
    import os
    from conftest import PC_DIR
    with open(os.path.join(PC_DIR, "scenarios", name + ".py"), encoding="utf-8") as f:
        text = f.read()
    assert "_send_raw" not in text and "socket" not in text and "subprocess" not in text
    assert "/c " not in text and "/sc " not in text and "silent-command" not in text
