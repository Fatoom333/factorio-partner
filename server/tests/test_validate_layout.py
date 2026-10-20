"""Argument checks of build_layout and connect_entities (docs/ACTIONS.md), done on the server."""
import copy

import pytest

from factorio_partner import validate as V
from factorio_partner.errors import PartnerError

A = {"x": 10, "y": 20}
FURNACE = {"name": "stone-furnace", "dx": 0, "dy": 0}


def layout(**kw):
    a = {"anchor": A, "entities": [dict(FURNACE)]}
    a.update(kw)
    return a


def refused(do, args, code):
    with pytest.raises(PartnerError) as ei:
        V.check_act(do, args)
    assert ei.value.code == code, (args, ei.value.text)
    return ei.value


# ---------------------------------------------------------------- build_layout

def test_layout_minimal_and_full():
    assert V.check_act("build_layout", layout())["entities"] == [dict(FURNACE)]
    full = layout(
        entities=[{"name": "assembling-machine-1", "cx": 1.5, "cy": -2.5, "direction": 15,
                   "recipe": "iron-gear-wheel", "insert": {"coal": 5}},
                  {"name": "underground-belt", "dx": -64, "dy": 64, "type": "output"}],
        direction=12, search=32, rotate=True, on_resource="iron-ore", tag="smelt-1", mode="hand",
        auto_supply=True, keep_ghosts=True, dry_run=True,
        ports=[{"id": "in_0", "dx": 0, "dy": 3, "kind": "belt", "io": "in", "dir": 8,
                "items": ["iron-ore", "copper-ore"]},
               {"id": "w", "dx": -1, "dy": 0, "kind": "pipe", "io": "out", "fluid": "water"},
               {"id": "p", "dx": 2, "dy": 2, "kind": "power", "io": "in"}])
    assert V.check_act("build_layout", copy.deepcopy(full)) == full


def test_layout_entities_or_plan_exactly_one():
    refused("build_layout", {"anchor": A}, "bad_args")
    refused("build_layout", layout(plan="block-1"), "bad_args")
    assert V.check_act("build_layout", {"anchor": A, "plan": "block-1"})["plan"] == "block-1"
    refused("build_layout", {"plan": "block-1"}, "bad_args")                    # anchor is required


def test_layout_blob_is_closed_to_the_agent():
    refused("build_layout", {"anchor": A, "blob": "bp-1"}, "bad_args")
    refused("build_layout", {"anchor": A, "plan": "x", "blob": "bp-1"}, "bad_args")
    refused("build_layout", {"anchor": A, "plan": "BAD ID"}, "bad_args")


@pytest.mark.parametrize("ent,code", [
    ({"name": "stone-furnace"}, "bad_args"),                                    # no offsets
    ({"name": "stone-furnace", "dx": 1}, "bad_args"),                           # dx without dy
    ({"name": "stone-furnace", "cy": 1}, "bad_args"),
    ({"name": "stone-furnace", "dx": 1, "dy": 1, "cx": 1, "cy": 1}, "bad_args"),
    ({"name": "stone-furnace", "dx": 1, "cy": 1}, "bad_args"),
    ({"name": "stone-furnace", "dx": 0.5, "dy": 0}, "bad_args"),                # whole cells
    ({"name": "stone-furnace", "dx": 65, "dy": 0}, "limit"),
    ({"name": "stone-furnace", "dx": 0, "dy": -65}, "bad_args"),
    ({"name": "stone-furnace", "cx": 64.5, "cy": 0}, "limit"),
    ({"name": "stone-furnace", "cx": -64.5, "cy": 0}, "bad_args"),
    ({"dx": 0, "dy": 0}, "bad_args"),
    ({"name": "bad name", "dx": 0, "dy": 0}, "bad_args"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "direction": 16}, "limit"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "direction": -1}, "bad_args"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "type": "both"}, "bad_args"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "recipe": 5}, "bad_args"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "insert": {}}, "bad_args"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "insert": {"a": 1, "b": 1, "c": 1, "d": 1, "e": 1}}, "limit"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "insert": {"coal": 0}}, "bad_args"),
    ({"name": "stone-furnace", "dx": 0, "dy": 0, "blob": 1}, "bad_args"),
    ("stone-furnace", "bad_args"),
])
def test_layout_entity_bounds(ent, code):
    refused("build_layout", layout(entities=[ent]), code)


def test_layout_entity_bounds_inclusive():
    for ent in ({"name": "e", "dx": 64, "dy": -64}, {"name": "e", "cx": 64, "cy": -64.0},
                {"name": "e", "dx": 0, "dy": 0, "direction": 0}, {"name": "e", "dx": 0, "dy": 0, "direction": 15},
                {"name": "e", "dx": 0, "dy": 0, "insert": {"a": 1, "b": 1, "c": 1, "d": 1}}):
        V.check_act("build_layout", layout(entities=[ent]))


def test_layout_entity_count():
    many = [{"name": "wooden-chest", "dx": i - 50, "dy": 0} for i in range(100)]
    assert len(V.check_act("build_layout", layout(entities=many))["entities"]) == 100
    refused("build_layout", layout(entities=many + [FURNACE]), "limit")
    refused("build_layout", layout(entities=[]), "bad_args")


def test_layout_args_size_is_16_kb():
    big = [{"name": "wooden-chest", "dx": i % 60, "dy": 0, "insert": {"iron-plate": 100_000}}
           for i in range(100)]
    n = V.json_size(layout(entities=big))
    assert V.MAX_ACT_ARGS < n < V.MAX_LAYOUT_ARGS
    V.check_act("build_layout", layout(entities=big))               # more than 4 KB is fine for this one
    refused("build_layout", layout(entities=big, on_resource="x" * 99, tag="t",
                                   ports=[{"id": "a", "dx": 0, "dy": 0, "kind": "belt", "io": "in"}] * 2),
            "bad_args")                                           # (duplicate port id, not size)
    over = layout(entities=big)
    over["on_resource"] = "a" * 99
    over["ports"] = [{"id": f"p{i}", "dx": 0, "dy": 0, "kind": "pipe", "io": "in",
                      "items": ["a" * 99, "b" * 99]} for i in range(16)]
    over["ports"] = over["ports"]
    # 16 KB wall: build a payload that is certainly over it
    huge = layout(entities=[{"name": "n" * 99, "dx": 0, "dy": 0, "insert": {("i%d" % k) * 20: 99_999
                                                                              for k in range(4)}}
                            for _ in range(100)])
    assert V.json_size(huge) > V.MAX_LAYOUT_ARGS
    refused("build_layout", huge, "limit")
    # the other actions keep the old 4 KB wall
    refused("walk", {"to": A, "pad": "x" * 5000}, "limit")


@pytest.mark.parametrize("field,val,code", [
    ("direction", 2, "bad_args"), ("direction", 16, "bad_args"),
    ("search", 33, "limit"), ("search", -1, "bad_args"), ("search", 1.5, "bad_args"),
    ("rotate", "yes", "bad_args"), ("on_resource", "bad name", "bad_args"),
    ("tag", "UPPER", "bad_args"), ("tag", "a" * 33, "bad_args"), ("mode", "fast", "bad_args"),
    ("auto_supply", 1, "bad_args"), ("keep_ghosts", "true", "bad_args"), ("dry_run", 1, "bad_args"),
    ("replace", True, "bad_args"),
])
def test_layout_scalar_fields(field, val, code):
    refused("build_layout", layout(**{field: val}), code)


def test_layout_scalar_bounds_inclusive():
    for k, v in (("search", 0), ("search", 32), ("direction", 0), ("tag", "a" * 32)):
        assert V.check_act("build_layout", layout(**{k: v}))[k] == v


def port(**kw):
    p = {"id": "in0", "dx": 0, "dy": 0, "kind": "belt", "io": "in"}
    p.update(kw)
    return p


@pytest.mark.parametrize("p,code", [
    (port(id="UP"), "bad_args"), (port(id="a" * 17), "bad_args"), (port(id=""), "bad_args"),
    (port(kind="wire"), "bad_args"), (port(io="inout"), "bad_args"),
    (port(dir=2), "bad_args"), (port(dir=16), "bad_args"),
    (port(dx=65), "limit"), (port(dy=0.5), "bad_args"),
    (port(items=[]), "bad_args"), (port(items=["a", "b", "c"]), "limit"), (port(items="a"), "bad_args"),
    (port(items=["a"], fluid="water"), "bad_args"),
    (port(fluid="bad name"), "bad_args"),
    (port(rate=-1), "bad_args"), (port(rate=True), "bad_args"), (port(rate="3"), "bad_args"),
    (port(items=["", "bad name"]), "bad_args"),
    ({"id": "a", "dx": 0, "dy": 0, "kind": "belt"}, "bad_args"),                # io is missing
    ("x", "bad_args"),
])
def test_layout_port_bounds(p, code):
    refused("build_layout", layout(ports=[p]), code)


def test_layout_ports_list():
    for d in (0, 4, 8, 12):
        V.check_act("build_layout", layout(ports=[port(dir=d)]))
    V.check_act("build_layout", layout(ports=[port(id=f"p{i}") for i in range(16)]))
    refused("build_layout", layout(ports=[port(id=f"p{i}") for i in range(17)]), "limit")
    refused("build_layout", layout(ports=[]), "bad_args")
    refused("build_layout", layout(ports=[port(), port()]), "bad_args")           # same id twice
    refused("build_layout", layout(ports="in0"), "bad_args")


def test_layout_port_of_forge_shape():
    # a port copied from partner_plan{task:"block"}: both lanes (one empty) and a rate
    p = port(items=["iron-plate", ""], rate=7.5)
    out = V.check_act("build_layout", layout(ports=[p]))
    assert out["ports"][0]["items"] == ["iron-plate", ""] and out["ports"][0]["rate"] == 7.5


# ---------------------------------------------------------------- connect_entities

def conn(**kw):
    a = {"kind": "belt", "from": {"pos": {"x": 0, "y": 0}}, "to": {"pos": {"x": 5, "y": 0}}}
    a.update(kw)
    return a


def test_connect_minimal_and_full():
    assert V.check_act("connect_entities", conn()) == conn()
    full = conn(via=[{"x": 1, "y": 1}], max_length=200, belt="fast-transport-belt",
                underground="prefer", build=False, mode="robots", auto_supply=True, dry_run=True)
    assert V.check_act("connect_entities", copy.deepcopy(full)) == full
    assert V.check_act("connect_entities", conn(kind="pipe", pipe="pipe", fluid="water"))["fluid"] == "water"
    assert V.check_act("connect_entities", conn(kind="power", pole="medium-electric-pole"))["pole"]


@pytest.mark.parametrize("end", [
    {"pos": {"x": 1, "y": 2}},
    {"pos": {"x": 1, "y": 2}, "dir": 8},
    {"target": {"unit_number": 7, "pos": {"x": 1, "y": 2}}},
    {"target": {"name": "assembling-machine-1", "pos": {"x": 1, "y": 2}}},
    {"layout": "smelt-1", "port": "out0"},
    {"layout": "smelt-1", "i": 3},
])
def test_connect_endpoint_forms(end):
    a = V.check_act("connect_entities", conn(**{"from": end, "to": end}))
    assert a["from"] == end


@pytest.mark.parametrize("end,code", [
    ({}, "bad_args"),
    ({"pos": {"x": 1, "y": 2}, "target": {"unit_number": 1}}, "bad_args"),      # two at once
    ({"pos": {"x": 1, "y": 2}, "layout": "a"}, "bad_args"),
    ({"layout": "a"}, "bad_args"),
    ({"layout": "a", "port": "p", "i": 1}, "bad_args"),
    ({"layout": "A", "port": "p"}, "bad_args"),
    ({"layout": "a", "port": "BAD"}, "bad_args"),
    ({"layout": "a", "i": 0}, "bad_args"),
    ({"layout": "a", "i": 101}, "limit"),
    ({"layout": "a", "i": 1.5}, "bad_args"),
    ({"pos": {"x": 1}}, "bad_args"),
    ({"pos": {"x": 1, "y": 2}, "dir": 2}, "bad_args"),
    ({"pos": {"x": 1, "y": 2}, "dir": True}, "bad_args"),
    ({"layout": "a", "port": "p", "dir": 4}, "bad_args"),                       # dir only with pos
    ({"target": {"x": 1, "y": 2}}, "bad_args"),
    ("here", "bad_args"),
])
def test_connect_endpoint_refusals(end, code):
    refused("connect_entities", conn(**{"from": end}), code)
    refused("connect_entities", conn(to=end), code)


def test_connect_required_and_bounds():
    for k in ("kind", "from", "to"):
        a = conn()
        del a[k]
        refused("connect_entities", a, "bad_args")
    refused("connect_entities", conn(kind="wire"), "bad_args")
    refused("connect_entities", conn(max_length=0), "bad_args")
    refused("connect_entities", conn(max_length=201), "limit")
    V.check_act("connect_entities", conn(max_length=1))
    refused("connect_entities", conn(underground="always"), "bad_args")
    refused("connect_entities", conn(via=[]), "bad_args")
    refused("connect_entities", conn(via=[{"x": 0, "y": 0}] * 9), "limit")
    V.check_act("connect_entities", conn(via=[{"x": i, "y": 0} for i in range(8)]))
    refused("connect_entities", conn(via=[{"x": 0}]), "bad_args")
    refused("connect_entities", conn(build="yes"), "bad_args")
    refused("connect_entities", conn(replace=True), "bad_args")


@pytest.mark.parametrize("kind,field", [
    ("belt", "pipe"), ("belt", "pole"), ("pipe", "belt"), ("pipe", "pole"),
    ("power", "belt"), ("power", "pipe"),
])
def test_connect_prototype_of_another_kind(kind, field):
    refused("connect_entities", conn(kind=kind, **{field: "something"}), "bad_args")


# ---------------------------------------------------------------- packages

def pkg(steps):
    return {"name": "блок", "anchor": A, "steps": steps,
            "verify": [{"kind": "ghosts"}]}


def test_package_allows_the_two_steps():
    assert "build_layout" in V.PACKAGE_DO and "connect_entities" in V.PACKAGE_DO
    out = V.check_package(pkg([
        {"do": "build_layout", "args": layout(tag="b1", dry_run=False, keep_ghosts=False)},
        {"do": "connect_entities", "args": conn(**{"from": {"layout": "b1", "port": "out0"}})}]))
    assert [s["do"] for s in out["steps"]] == ["build_layout", "connect_entities"]


def test_package_refuses_keep_ghosts():
    e = refused_pkg(pkg([{"do": "build_layout", "args": layout(keep_ghosts=True)}]))
    assert "keep_ghosts" in e.text and "steps[1]" in e.text


def test_package_refuses_connect_without_build():
    e = refused_pkg(pkg([{"do": "connect_entities", "args": conn(build=False)}]))
    assert "build" in e.text and "steps[1]" in e.text


def refused_pkg(p):
    with pytest.raises(PartnerError) as ei:
        V.check_package(p)
    assert ei.value.code == "bad_args"
    return ei.value


def test_package_step_errors_name_the_step():
    e = refused_pkg(pkg([{"do": "build_layout", "args": layout(entities=[{"name": "x"}])}]))
    assert "steps[1]" in e.text
