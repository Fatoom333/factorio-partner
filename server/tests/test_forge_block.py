"""`partner_plan{task:"block"}`: блок рядов → постройки и порты со смещениями от угла рамки.

forge-процесс не нужен: `_run_forge` подменяется заготовленным отчётом и строкой чертежа, которую
тест собирает сам (JSON → zlib → base64 с префиксом "0").
"""

from __future__ import annotations

import base64
import json
import subprocess
import zlib
from pathlib import Path

import pytest

from factorio_partner import forge


class Cfg:
    def __init__(self, home, forge_path="forge-checkout", forge_profile=None):
        self.home, self.forge, self.forge_profile, self.forge_home = home, forge_path, forge_profile, None


def blueprint_string(entities) -> str:
    doc = {"blueprint": {"item": "blueprint", "entities": entities, "version": 1}}
    return "0" + base64.b64encode(zlib.compress(json.dumps(doc).encode())).decode()


def ent(n, name, x, y, direction=None, **extra):
    e = {"entity_number": n, "name": name, "position": {"x": x, "y": y}, **extra}
    if direction is not None:
        e["direction"] = direction
    return e


ENTITIES = [
    ent(1, "assembling-machine-1", 1.5, 3.5, recipe="iron-gear-wheel"),
    ent(2, "fast-inserter", 1.5, 1.5, 8),
    ent(3, "fast-transport-belt", 0.5, 0.5, 4),
    ent(4, "fast-transport-belt", 11.5, 6.5, 4),
    ent(5, "underground-belt", 5.5, 6.5, 12, type="input"),
    ent(6, "underground-belt", 7.5, 6.5, 12, type="output"),
    ent(7, "splitter", 9.0, 7.5, 0),
    ent(8, "medium-electric-pole", 4.5, 9.5),
]

PORTS = [
    {"kind": "belt", "io": "in", "items": ["iron-plate", ""], "x": 0, "y": 0, "direction": 4, "rate": 8.0, "index": 0},
    {"kind": "belt", "io": "out", "items": ["iron-gear-wheel", "iron-gear-wheel"], "x": 11, "y": 6,
     "direction": 4, "rate": 8.123456, "index": 1},
    {"kind": "pipe", "io": "in", "items": ["water"], "x": 3, "y": 0, "direction": 8, "rate": 12.0, "index": 2},
    {"kind": "belt", "io": "in", "items": ["copper-plate", "iron-plate"], "x": 5, "y": 12, "direction": 0,
     "rate": 2.0, "index": 3},
    {"kind": "belt", "io": "out", "items": ["x", "y"], "x": 0, "y": 5, "direction": 12, "rate": 1.0, "index": 4},
]

BLOCK = {"recipe": "iron-gear-wheel", "machine": "assembling-machine-1", "rows": [4, 4],
         "belt": "fast-transport-belt", "inserter": "fast-inserter", "pole": "medium-electric-pole"}


class FakeForge:
    def __init__(self, entities=ENTITIES, ports=PORTS, width=12, height=13, active="sample-save",
                 findings=(), rc=0, blueprint=None, blocks=None):
        self.active, self.rc, self.calls = active, rc, []
        self.blueprint = blueprint if blueprint is not None else blueprint_string(entities)
        self.report = {"label": "x", "findings": list(findings), "blocks": blocks if blocks is not None else [
            {"index": 0, "recipe": "iron-gear-wheel", "machine": "assembling-machine-1", "at": [0, 0],
             "width": width, "height": height, "machines": 8, "ports": ports,
             "notes": ["профиль 'private-save' (C:\\Users\\someone\\x)"]}]}

    def __call__(self, forge_path, argv, cwd, timeout, **kw):
        self.calls.append((forge_path, list(argv), Path(cwd), timeout))
        if argv[0] == "list-profiles":
            text = f"* {self.active} (from X) - ok\n" if self.active else "  other (from Y) - ok\n"
            return subprocess.CompletedProcess(argv, 0, text.encode(), b"")
        if argv[0] == "build":
            self.plan = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
            out = Path(argv[argv.index("-o") + 1])
            label = self.plan["label"]
            if self.rc == 0:
                out.mkdir(parents=True, exist_ok=True)
                (out / f"{label}.txt").write_text(self.blueprint, encoding="utf-8")
                (out / f"{label}.report.json").write_text(json.dumps(self.report), encoding="utf-8")
            return subprocess.CompletedProcess(argv, self.rc, b"", b"boom" if self.rc else b"")
        raise AssertionError(argv)


@pytest.fixture
def fake(monkeypatch):
    def install(**kw):
        f = FakeForge(**kw)
        monkeypatch.setattr(forge, "_run_forge", f)
        return f
    return install


def plan_block(tmp_path, block=BLOCK, **cfg):
    return forge.plan("block", block=block, config=Cfg(tmp_path, **cfg))


# --- результат ------------------------------------------------------------------------

def test_block_result_entities_and_ports(tmp_path, fake):
    f = fake()
    out = plan_block(tmp_path)
    assert forge.PLAN_ID_RE.match(out["plan"])
    assert set(out) == {"plan", "size", "items", "ports", "entities_n", "summary"}
    assert out["size"] == {"w": 12, "h": 13} and out["entities_n"] == 8
    assert out["items"]["fast-transport-belt"] == 2 and out["items"]["splitter"] == 1
    # в forge ушёл один блок рядов с углом в (0, 0)
    assert f.plan["blocks"] == [{"type": "rows", "recipe": "iron-gear-wheel", "machine": "assembling-machine-1",
                                 "rows": [4, 4], "belt": "fast-transport-belt", "inserter": "fast-inserter",
                                 "pole": "medium-electric-pole", "rotate": 0, "at": [0, 0]}]
    assert [c[1][0] for c in f.calls] == ["list-profiles", "build"] and f.calls[1][1][-1] == "--no-render"

    by_id = {p["id"]: p for p in out["ports"]}
    assert list(by_id) == ["in0", "out1", "in2", "in3", "out4"]
    assert by_id["in0"] == {"id": "in0", "kind": "belt", "io": "in", "dx": 0, "dy": 0, "dir": 4,
                            "items": ["iron-plate", ""], "rate": 8.0}
    assert by_id["out1"]["rate"] == 8.1235 and by_id["out1"]["items"] == ["iron-gear-wheel", "iron-gear-wheel"]
    assert by_id["in2"] == {"id": "in2", "kind": "pipe", "io": "in", "dx": 3, "dy": 0, "dir": 8,
                            "fluid": "water", "rate": 12.0}
    # все четыре направления порта
    assert {p["dir"] for p in out["ports"]} == {0, 4, 8, 12}
    assert (by_id["in3"]["dx"], by_id["in3"]["dy"]) == (5, 12) and by_id["out4"]["dir"] == 12


def test_block_layout_file_offsets_in_every_direction(tmp_path, fake):
    fake()
    out = plan_block(tmp_path)
    lay = forge.load_layout(out["plan"], config=Cfg(tmp_path))
    assert set(lay) == {"entities", "ports"}
    by_name = {}
    for e in lay["entities"]:
        by_name.setdefault(e["name"], []).append(e)
    assert by_name["assembling-machine-1"] == [
        {"name": "assembling-machine-1", "cx": 1.5, "cy": 3.5, "direction": 0, "recipe": "iron-gear-wheel"}]
    assert by_name["fast-inserter"][0]["direction"] == 8
    belts = by_name["fast-transport-belt"]
    assert [(b["cx"], b["cy"], b["direction"]) for b in belts] == [(0.5, 0.5, 4), (11.5, 6.5, 4)]
    # подземные: направление 12 (запад) и тип сохранены
    unders = {e["type"]: e for e in by_name["underground-belt"]}
    assert unders["input"]["direction"] == 12 and unders["output"]["cx"] == 7.5
    # сплиттер — центр на целой координате; столб — направления нет в чертеже → 0
    assert by_name["splitter"][0]["cx"] == 9.0 and by_name["splitter"][0]["cy"] == 7.5
    assert by_name["medium-electric-pole"][0]["direction"] == 0
    assert "type" not in by_name["fast-inserter"][0] and "recipe" not in by_name["fast-inserter"][0]
    assert lay["ports"] == out["ports"]
    # сырой строки чертежа агенту нет, а файл рядом с остальными
    assert (tmp_path / "plans" / f"{out['plan']}.layout.json").is_file()
    assert (tmp_path / "plans" / f"{out['plan']}.txt").is_file()
    assert out["plan"] not in out["summary"] and "private-save" not in json.dumps(out)


@pytest.mark.parametrize("direction", [0, 4, 8, 12])
def test_block_each_direction_survives(tmp_path, fake, direction):
    ents = [ent(1, "fast-transport-belt", 2.5, 1.5, direction), ent(2, "assembling-machine-1", 4.5, 4.5)]
    fake(entities=ents, ports=[{**PORTS[0], "direction": direction, "x": 2, "y": 1}])
    out = plan_block(tmp_path)
    lay = forge.load_layout(out["plan"], config=Cfg(tmp_path))
    belt = next(e for e in lay["entities"] if e["name"] == "fast-transport-belt")
    assert (belt["cx"], belt["cy"], belt["direction"]) == (2.5, 1.5, direction)
    assert (out["ports"][0]["dx"], out["ports"][0]["dy"], out["ports"][0]["dir"]) == (2, 1, direction)


def test_block_rotate_goes_to_forge(tmp_path, fake):
    f = fake()
    plan_block(tmp_path, {**BLOCK, "rotate": 90, "rows": 2, "per_row": 4, "at": [50, 50], "id": "x1"})
    blk = f.plan["blocks"][0]
    assert blk["rotate"] == 90 and blk["at"] == [0, 0] and blk["rows"] == [4, 4] and "per_row" not in blk
    assert "id" not in blk


def test_block_wrapper_with_one_block(tmp_path, fake):
    f = fake()
    plan_block(tmp_path, {"label": "x", "blocks": [BLOCK]})
    assert f.plan["blocks"][0]["recipe"] == "iron-gear-wheel"


def test_block_summary_limit_and_ports_listed(tmp_path, fake):
    fake(findings=[{"severity": "suspect", "summary": "s" * 3000, "code": "x"}])
    out = plan_block(tmp_path)
    assert len(out["summary"]) <= 2000
    assert "in0: belt in (0,0) dir 4" in out["summary"] and "in2: pipe in (3,0) dir 8 water" in out["summary"]


# --- load_layout ----------------------------------------------------------------------

@pytest.mark.parametrize("bad", [None, 5, "", "p-123", "../x", "p-" + "0" * 16 + ".txt"])
def test_load_layout_bad_id(tmp_path, bad):
    with pytest.raises(forge.PlanArgsError):
        forge.load_layout(bad, config=Cfg(tmp_path))


def test_load_layout_unknown_and_damaged(tmp_path):
    pid = "p-" + "ab" * 8
    with pytest.raises(forge.PlanArgsError, match="нет такой"):
        forge.load_layout(pid, config=Cfg(tmp_path))
    plans = tmp_path / "plans"
    plans.mkdir()
    (plans / f"{pid}.layout.json").write_text("{не json", encoding="utf-8")
    with pytest.raises(forge.PlanArgsError, match="не читается"):
        forge.load_layout(pid, config=Cfg(tmp_path))
    (plans / f"{pid}.layout.json").write_text(json.dumps({"entities": [], "ports": []}), encoding="utf-8")
    with pytest.raises(forge.PlanArgsError, match="повреждена"):
        forge.load_layout(pid, config=Cfg(tmp_path))


def test_mining_plan_has_no_layout(tmp_path, fake):
    fake(blueprint="0eNqrVkrKKU0tKsrMK1GyqlYqLU7NUbJSSs4vzUtRqq0FAHhoCfo=")
    area = {"left_top": {"x": 10, "y": -20}, "right_bottom": {"x": 30, "y": -5}}
    out = forge.plan("mining", {"name": "iron-ore", "area": area}, config=Cfg(tmp_path))
    with pytest.raises(forge.PlanArgsError):
        forge.load_layout(out["plan"], config=Cfg(tmp_path))


def test_prune_removes_layout_with_plan(tmp_path, fake):
    fake()
    first = plan_block(tmp_path)["plan"]
    plans = tmp_path / "plans"
    import os
    os.utime(plans / f"{first}.txt", (1, 1))
    for _ in range(3):
        plan_block(tmp_path)
    forge._prune(plans, keep=2)
    assert not (plans / f"{first}.layout.json").exists() and not (plans / f"{first}.txt").exists()
    assert len(list(plans.glob("*.layout.json"))) == 2


# --- отказы ---------------------------------------------------------------------------

@pytest.mark.parametrize("block", [
    None, [], "x", 5,
    {},
    {"recipe": "r"},
    {**BLOCK, "rows": []},
    {**BLOCK, "rows": [0]},
    {**BLOCK, "rows": [True]},
    {**BLOCK, "rows": ["4"]},
    {**BLOCK, "rows": [100]},
    {**BLOCK, "rows": list(range(1, 40))},
    {**BLOCK, "rows": [64, 64, 64]},
    {**BLOCK, "rows": 3},
    {**BLOCK, "rows": 2, "per_row": 0},
    {**BLOCK, "rows": [4], "per_row": 4},
    {**BLOCK, "extra": 1},
    {**BLOCK, "library": "gears"},
    {**BLOCK, "type": "library"},
    {**BLOCK, "recipe": "Iron Gear"},
    {**BLOCK, "machine": "../x"},
    {**BLOCK, "stack": "weird"},
    {**BLOCK, "align": "left"},
    {**BLOCK, "rotate": 45},
    {**BLOCK, "rotate": True},
    {**BLOCK, "input_belts": 9},
    {**BLOCK, "speed_bonus": -1},
    {**BLOCK, "planned": -1},
    {**BLOCK, "planned": "3"},
    {"blocks": [BLOCK, BLOCK]},
    {"blocks": []},
    {**BLOCK, "note": "x" * 5000},
])
def test_block_bad_args(tmp_path, fake, block):
    f = fake()
    with pytest.raises(forge.PlanArgsError):
        plan_block(tmp_path, block)
    assert f.calls == []


def test_block_arg_mixing(tmp_path, fake):
    fake()
    with pytest.raises(forge.PlanArgsError):
        forge.plan("block", options={"drill": "x"}, block=BLOCK, config=Cfg(tmp_path))
    with pytest.raises(forge.PlanArgsError):
        forge.plan("mining", block=BLOCK, config=Cfg(tmp_path))
    with pytest.raises(forge.PlanArgsError):
        forge.plan("block", config=Cfg(tmp_path))


def test_forge_failures_are_unsupported(tmp_path, fake):
    fake(rc=1)
    out = plan_block(tmp_path)
    assert out["supported"] is False and "boom" in out["reason"]
    assert not list((tmp_path / "plans").glob("p-*"))


def test_wrong_profile_and_no_profile(tmp_path, fake):
    fake(active="other")
    assert plan_block(tmp_path, forge_profile="sample-save")["supported"] is False
    fake(active=None)
    assert "активного профиля" in plan_block(tmp_path)["reason"]


def test_problems_from_forge(tmp_path, fake):
    fake(findings=[{"severity": "problem", "summary": "belt breaks", "code": "belt-gap"}])
    out = plan_block(tmp_path)
    assert out["supported"] is False and "belt breaks" in out["reason"]


def test_report_without_block_or_ports(tmp_path, fake):
    fake(blocks=[])
    assert plan_block(tmp_path)["supported"] is False
    fake(blocks=[{"index": 0, "width": 3, "height": 3}])
    assert plan_block(tmp_path)["supported"] is False


def test_bad_blueprint_string(tmp_path, fake):
    fake(blueprint="0%%%not-base64")
    assert plan_block(tmp_path)["supported"] is False
    fake(blueprint="0" + base64.b64encode(zlib.compress(b'{"x": 1}')).decode())
    assert plan_block(tmp_path)["supported"] is False
    fake(blueprint="0" + base64.b64encode(zlib.compress(b"not json")).decode())
    assert plan_block(tmp_path)["supported"] is False


def test_entity_before_corner_is_rejected(tmp_path, fake):
    fake(entities=[ent(1, "fast-transport-belt", -3.5, 0.5, 4)])
    out = plan_block(tmp_path)
    assert out["supported"] is False and "сдвинут" in out["reason"]


def test_entity_past_the_frame_is_rejected(tmp_path, fake):
    # чертёж сдвинут вправо-вниз: постройка выходит за рамку 12×13 из отчёта
    fake(entities=[ent(1, "fast-transport-belt", 12.5, 0.5, 4)])
    out = plan_block(tmp_path)
    assert out["supported"] is False and "сдвинут" in out["reason"]


def test_frame_over_64_is_rejected(tmp_path, fake):
    fake(width=65, height=13)
    out = plan_block(tmp_path)
    assert out["supported"] is False and "65×13" in out["reason"]


def test_too_many_entities_and_ports(tmp_path, fake):
    fake(entities=[ent(i, "fast-transport-belt", 0.5 + i % 20, 0.5 + i // 20, 4) for i in range(101)])
    out = plan_block(tmp_path)
    assert out["supported"] is False and "101" in out["reason"]
    many = [{**PORTS[0], "index": i} for i in range(17)]
    fake(ports=many)
    out = plan_block(tmp_path)
    assert out["supported"] is False and "17" in out["reason"]


def test_bad_port_in_report(tmp_path, fake):
    fake(ports=[{**PORTS[0], "direction": 6}])
    assert plan_block(tmp_path)["supported"] is False
    fake(ports=[{**PORTS[0], "kind": "wire"}])
    assert plan_block(tmp_path)["supported"] is False


def test_zip_bomb_is_refused(tmp_path, fake, monkeypatch):
    monkeypatch.setattr(forge, "MAX_BLUEPRINT_JSON_BYTES", 1000)
    fake(blueprint="0" + base64.b64encode(zlib.compress(b'{"blueprint":{"entities":[]}}' + b" " * 5000)).decode())
    assert plan_block(tmp_path)["supported"] is False
