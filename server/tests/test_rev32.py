"""Revision 3.2 on the server side: ``partner_find``, the bounds of ACTIONS.md «Границы чисел v1»,
``helper_limit`` / ``helper_attach`` admin calls and the launch flags of the CLI
(``--helpers N``, ``--body character|player``)."""
import io
import json

import pytest

from factorio_partner import cli
from factorio_partner import validate as V
from factorio_partner.core import Core
from factorio_partner.errors import PartnerError
from factorio_partner.server import build_server

from conftest import KEY, make_bridge
from fake_rcon import FakeModError


def last_env(fake, op=None):
    for env in reversed(fake.mod.requests):
        if op is None or env.get("op") == op:
            return env
    raise AssertionError(f"no request {op}")


def sent(fake, op):
    return [e for e in fake.mod.requests if e.get("op") == op]


async def code_of(coro):
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


FIND_ANSWER = {"item": "iron-plate", "surface": "nauvis", "total": {"producers": 2, "storage": 1}, "hidden": 0,
               "groups": [{"kind": "producers", "pos": {"x": 12, "y": 0}, "dist": 12, "count": 2,
                           "names": {"stone-furnace": 2}, "recipe": "iron-plate"}]}


def install_find(fake, answer=None):
    fake.mod.handlers["find"] = lambda args, env: dict(answer or FIND_ANSWER)


# ---------------------------------------------------------------- partner_find

async def test_find_passes_only_given_args(core, fake):
    install_find(fake)
    r = await core.op_find("h1", KEY, "iron-plate")
    assert r["groups"][0]["recipe"] == "iron-plate" and r["total"] == {"producers": 2, "storage": 1}
    env = last_env(fake, "find")
    assert env["helper"] == "h1" and env["args"] == {"item": "iron-plate"}
    await core.op_find("h1", KEY, "water", kinds=["storage", "producers", "storage"], surface="vulcanus", limit=50)
    assert last_env(fake, "find")["args"] == {"item": "water", "kinds": ["storage", "producers"],
                                              "surface": "vulcanus", "limit": 50}
    # float that is a whole number is sent as an integer
    await core.op_find("h1", KEY, "water", limit=5.0)
    assert last_env(fake, "find")["args"]["limit"] == 5


@pytest.mark.parametrize("kw,code", [
    ({"item": None}, "bad_args"),
    ({"item": 5}, "bad_args"),
    ({"item": "iron plate"}, "bad_args"),
    ({"item": "x[img=item/coal]"}, "bad_args"),
    ({"item": "iron-plate", "kinds": []}, "bad_args"),
    ({"item": "iron-plate", "kinds": "storage"}, "bad_args"),
    ({"item": "iron-plate", "kinds": ["storage", "all"]}, "bad_args"),
    ({"item": "iron-plate", "kinds": ["storage"] * 5}, "limit"),
    ({"item": "iron-plate", "limit": 0}, "bad_args"),
    ({"item": "iron-plate", "limit": 2.5}, "bad_args"),
    ({"item": "iron-plate", "limit": True}, "bad_args"),
    ({"item": "iron-plate", "limit": 51}, "limit"),
    ({"item": "iron-plate", "surface": "../x"}, "bad_args"),
    ({"item": "iron-plate", "surface": 3}, "bad_args"),
])
async def test_find_rejects_before_the_mod(core, fake, kw, code):
    install_find(fake)
    assert (await code_of(core.op_find("h1", KEY, **kw))).code == code
    assert sent(fake, "find") == []


async def test_find_needs_key_and_keeps_mod_errors(core, fake):
    def refuse(args, env):
        raise FakeModError("limit", "surface nauvis has more than 4000 chunks")
    fake.mod.handlers["find"] = refuse
    assert (await code_of(core.op_find("h1", "w" * 40, "iron-plate"))).code == "access denied"
    assert sent(fake, "find") == []
    e = await code_of(core.op_find("h1", KEY, "iron-plate"))
    assert e.code == "limit" and "4000" in e.text


async def test_find_response_too_large_has_a_hint(core, fake):
    big = dict(FIND_ANSWER, groups=[dict(FIND_ANSWER["groups"][0], names={f"n{i}": 1 for i in range(3000)})])
    install_find(fake, big)
    e = await code_of(core.op_find("h1", KEY, "iron-plate"))
    assert e.code == "response too large" and "limit" in e.text


async def test_find_tool_and_cli(core, fake):
    install_find(fake)
    mcp = build_server(core)
    tools = {t.name: t for t in await mcp.list_tools()}
    assert "partner_find" in tools
    assert set(tools["partner_find"].inputSchema["properties"]) == {"helper", "key", "item", "kinds", "surface", "limit"}
    res = await mcp.call_tool("partner_find", {"helper": "h1", "key": KEY, "item": "iron-plate", "kinds": ["storage"]})
    assert last_env(fake, "find")["args"] == {"item": "iron-plate", "kinds": ["storage"]}
    assert res is not None
    out = io.StringIO()
    req = {"tool": "partner_find", "helper": "h1", "key": KEY, "item": "iron-plate", "limit": 3}
    rc = await cli.run(core, io.StringIO(json.dumps(req)), out, False)
    assert rc == 0 and json.loads(out.getvalue())["result"]["item"] == "iron-plate"


# ---------------------------------------------------------------- bounds of ACTIONS.md

@pytest.mark.parametrize("do,args,code", [
    # unit_number is an integer ≥ 1
    ("extract", {"target": {"unit_number": 0}}, "bad_args"),
    ("extract", {"target": {"unit_number": -4}}, "bad_args"),
    ("approach", {"target": {"unit_number": 0, "pos": {"x": 1, "y": 1}}}, "bad_args"),
    # walk.radius 0..64
    ("walk", {"to": {"x": 1, "y": 1}, "radius": -1}, "bad_args"),
    ("walk", {"to": {"x": 1, "y": 1}, "radius": 64.5}, "limit"),
    # follow.distance 1..32, duration_s 1..3600
    ("follow", {"distance": 0.5}, "bad_args"),
    ("follow", {"distance": 32.5}, "limit"),
    ("follow", {"duration_s": 0}, "bad_args"),
    ("follow", {"duration_s": 3601}, "limit"),
    # craft.count 1..10000
    ("craft", {"recipe": "pipe", "count": 0}, "bad_args"),
    ("craft", {"recipe": "pipe", "count": 10001}, "limit"),
    # collect.radius 1..128
    ("collect", {"items": {"coal": 1}, "radius": 0}, "bad_args"),
    ("collect", {"items": {"coal": 1}, "radius": 0.5}, "bad_args"),
    ("collect", {"items": {"coal": 1}, "radius": 129}, "limit"),
    # build_ghosts.radius 1..64
    ("build_ghosts", {"radius": 0}, "bad_args"),
    ("build_ghosts", {"radius": 65}, "limit"),
    # wait.seconds 1..600
    ("wait", {"seconds": 0}, "bad_args"),
    ("wait", {"seconds": 601}, "limit"),
    # build_blueprint: direction only 0/4/8/12, force one of three modes
    ("build_blueprint", {"blob": "bp-1", "anchor": {"x": 0, "y": 0}, "direction": 2}, "bad_args"),
    ("build_blueprint", {"blob": "bp-1", "anchor": {"x": 0, "y": 0}, "direction": 16}, "bad_args"),
    ("build_blueprint", {"blob": "bp-1", "anchor": {"x": 0, "y": 0}, "force": "shift"}, "bad_args"),
    # plan_mining
    ("plan_mining", {"resource": "iron-ore"}, "bad_args"),
    ("plan_mining", {"near": {"x": 1, "y": 1}, "area": {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 9, "y": 9}}},
     "bad_args"),
    ("plan_mining", {"near": {"x": 1, "y": 1}, "layout": "spiral"}, "bad_args"),
    ("plan_mining", {"near": {"x": 1, "y": 1}, "direction": 4}, "bad_args"),
    ("plan_mining", {"near": {"x": 1, "y": 1}, "options": {"lamps": {"x": 1}}}, "bad_args"),
    ("plan_mining", {"near": {"x": 1, "y": 1}, "options": {f"f{i}": True for i in range(33)}}, "limit"),
    ("plan_mining", {"area": {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 129, "y": 9}}}, "limit"),
])
async def test_act_bounds_v1(core, fake, do, args, code):
    assert (await code_of(core.op_act("h1", KEY, do, args))).code == code
    assert sent(fake, "act") == []


@pytest.mark.parametrize("do,args", [
    ("extract", {"target": {"unit_number": 1}}),
    ("walk", {"to": "player", "radius": 0}),
    ("walk", {"to": "player", "radius": 64}),
    ("follow", {"distance": 1, "duration_s": 3600}),
    ("follow", {"distance": 32, "duration_s": 1}),
    ("craft", {"recipe": "pipe", "count": 10000}),
    ("collect", {"items": {"coal": 1}, "radius": 1}),
    ("collect", {"items": {"coal": 1}, "radius": 128}),
    ("build_ghosts", {"radius": 1}),
    ("build_ghosts", {"radius": 64, "mode": "hand"}),
    ("wait", {"seconds": 600}),
    ("build_blueprint", {"blob": "bp-1", "anchor": {"x": 0, "y": 0}, "direction": 12, "force": "superforced",
                         "dry_run": True}),
    ("build_blueprint", {"blob": "bp-1", "anchor": {"x": 0, "y": 0}, "force": "normal"}),
    ("plan_mining", {"resource": "iron-ore", "near": {"x": 5, "y": 5}, "layout": "compact", "direction": "east",
                     "miner": "electric-mining-drill", "belt": "transport-belt", "pole": "small-electric-pole",
                     "options": {"lamps": True, "coverage": 0.5, "pipe_type": "pipe"}, "dry_run": True}),
    ("plan_mining", {"area": {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 64, "y": 64}}}),
])
async def test_act_bounds_v1_accepts_the_edges(core, fake, do, args):
    await core.op_act("h1", KEY, do, args)
    assert last_env(fake, "act")["args"] == {"do": do, "args": args, "replace": False}


def test_actions_whitelist_is_the_list_of_actions_md():
    assert set(V.ACTIONS) == {"walk", "approach", "follow", "mine", "craft", "insert", "extract", "collect",
                              "pickup", "place", "rotate", "set_recipe", "build_blueprint", "build_ghosts", "deconstruct", "plan_mining",
                              "plan_belt", "wait"}


# ---------------------------------------------------------------- helper_limit / helper_attach

def install_admin(fake, state=None):
    state = state if state is not None else {"max": 1, "bodies": []}

    def limit(args, env):
        if args["max"] < len(state["bodies"]):
            raise FakeModError("limit", "below the number of helpers alive")
        state["max"] = args["max"]
        return {"max": args["max"], "alive": len(state["bodies"])}

    def spawn(args, env):
        if len(state["bodies"]) >= state["max"]:
            raise FakeModError("limit", f"at most {state['max']} helpers")
        state["bodies"].append(env["helper"])
        return {"helper": env["helper"], "unit_number": 7, "surface": "nauvis", "pos": {"x": 0, "y": 0}}

    def attach(args, env):
        if args["player"] == "Nobody":
            raise FakeModError("no_player", "player is not online")
        state["bodies"].append(env["helper"])
        return {"helper": env["helper"], "surface": "nauvis", "pos": {"x": 3, "y": 4}}

    fake.mod.handlers.update(helper_limit=limit, helper_spawn=spawn, helper_attach=attach)
    return state


async def test_admin_limit_and_attach(core, fake):
    install_admin(fake)
    r = await core.admin_limit(3)
    assert r["data"] == {"max": 3, "alive": 0}
    env = last_env(fake, "helper_limit")
    assert env["args"] == {"max": 3} and "helper" not in env
    r = await core.admin_attach("h2", "Second Player")
    assert r["data"]["helper"] == "h2"
    env = last_env(fake, "helper_attach")
    assert env["helper"] == "h2" and env["args"] == {"player": "Second Player"}
    assert set(env) == {"v", "id", "op", "helper", "args"}, "в конверте нет лишних полей (ключа помощника)"


@pytest.mark.parametrize("value,code", [(0, "bad_args"), (17, "limit"), (1.5, "bad_args"), ("2", "bad_args"),
                                        (True, "bad_args"), (None, "bad_args")])
async def test_admin_limit_bounds(core, fake, value, code):
    install_admin(fake)
    assert (await code_of(core.admin_limit(value))).code == code
    assert sent(fake, "helper_limit") == []


@pytest.mark.parametrize("helper,player", [("BAD!", "Second"), ("h1", ""), ("h1", " Second"), ("h1", "a\nb"),
                                           ("h1", "x" * 61), ("h1", 5), ("h1", None)])
async def test_admin_attach_rejects(core, fake, helper, player):
    install_admin(fake)
    assert (await code_of(core.admin_attach(helper, player))).code == "bad_args"
    assert sent(fake, "helper_attach") == []


async def test_admin_attach_without_the_op_in_the_mod(core, fake):
    # the operation is written by another stream: an older mod answers unknown_op, the server passes it on
    assert (await code_of(core.admin_attach("h1", "Second"))).code == "unknown_op"


async def test_admin_tools_listed_only_with_admin(core):
    plain = {t.name for t in await build_server(core).list_tools()}
    admin = {t.name for t in await build_server(core, admin=True).list_tools()}
    assert not {"admin_limit", "admin_attach"} & plain
    assert {"admin_limit", "admin_attach"} <= admin


# ---------------------------------------------------------------- launch flags of the CLI

async def run_launch(cfg, **kw):
    c = Core(cfg, make_bridge(cfg), forge_module="tests_no_such_forge_module")
    out = io.StringIO()
    rc = await cli.launch(c, out, kw.get("helpers"), kw.get("body"), kw.get("helper"), kw.get("player"))
    return rc, json.loads(out.getvalue())


async def test_launch_helpers_sends_helper_limit(cfg, fake):
    state = install_admin(fake)
    rc, r = await run_launch(cfg, helpers=2)
    assert rc == 0 and r["ok"]
    assert r["result"]["steps"] == [{"call": "admin_limit", "max": 2, "data": {"max": 2, "alive": 0}}]
    assert state["max"] == 2
    assert [e["op"] for e in fake.mod.requests] == ["helper_limit"]


async def test_launch_body_character_spawns_each_helper(cfg, fake):
    state = install_admin(fake)
    rc, r = await run_launch(cfg, helpers=2, body="character", helper=["h1", "h2"])
    assert rc == 0, r
    assert [s["call"] for s in r["result"]["steps"]] == ["admin_limit", "admin_spawn", "admin_spawn"]
    assert [e["op"] for e in fake.mod.requests] == ["helper_limit", "helper_spawn", "helper_spawn"]
    assert state["bodies"] == ["h1", "h2"]
    # the default helper id
    fake.mod.requests.clear()
    state["bodies"].clear()
    rc, r = await run_launch(cfg, body="character")
    assert rc == 0 and last_env(fake, "helper_spawn")["helper"] == "h1"


async def test_launch_body_player_sends_helper_attach(cfg, fake):
    install_admin(fake)
    rc, r = await run_launch(cfg, helpers=2, body="player", helper=["h1", "h2"], player=["Second", "Third"])
    assert rc == 0, r
    att = sent(fake, "helper_attach")
    assert [(e["helper"], e["args"]) for e in att] == [("h1", {"player": "Second"}), ("h2", {"player": "Third"})]
    assert sent(fake, "helper_spawn") == [], "тело-игрок не создаётся через helper_spawn"


async def test_launch_stops_at_the_first_refusal(cfg, fake):
    state = install_admin(fake)
    # the limit stays 1: the second body is refused by the mod, the third is never tried
    rc, r = await run_launch(cfg, body="character", helper=["h1", "h2", "h3"])
    assert rc == 1 and r["error"] == "limit"
    assert [s["helper"] for s in r["done"]] == ["h1"]
    assert [e["helper"] for e in sent(fake, "helper_spawn")] == ["h1", "h2"]
    rc, r = await run_launch(cfg, body="player", helper=["h4"], player=["Nobody"])
    assert rc == 1 and r["error"] == "no_player" and r["done"] == []
    assert state["bodies"] == ["h1"]


@pytest.mark.parametrize("kw,code", [
    ({"helpers": 0}, "bad_args"),
    ({"helpers": 17}, "limit"),
    ({"helper": ["h1"]}, "bad_args"),                                   # --helper without --body
    ({"player": ["Second"]}, "bad_args"),
    ({"body": "robot"}, "bad_args"),
    ({"body": "character", "helper": ["H1"]}, "bad_args"),
    ({"body": "character", "helper": ["h1", "h1"]}, "bad_args"),
    ({"body": "character", "player": ["Second"]}, "bad_args"),
    ({"body": "character", "helpers": 1, "helper": ["h1", "h2"]}, "limit"),
    ({"body": "player"}, "bad_args"),                                   # no --player
    ({"body": "player", "helper": ["h1", "h2"], "player": ["Second"]}, "bad_args"),
    ({"body": "player", "helper": ["h1", "h2"], "player": ["Same", "Same"]}, "bad_args"),
    ({"body": "player", "player": ["a\tb"]}, "bad_args"),
])
async def test_launch_bad_flags_send_nothing(cfg, fake, kw, code):
    install_admin(fake)
    rc, r = await run_launch(cfg, **kw)
    assert rc == 1 and r["error"] == code, r
    assert fake.mod.requests == [], "пока флаги не проверены, в мод ничего не уходит"


def test_launch_flags_parse():
    ns = cli.build_parser().parse_args(["--helpers", "3", "--body", "player", "--helper", "h1", "--player", "Second"])
    assert (ns.helpers, ns.body, ns.helper, ns.player, ns.admin) == (3, "player", ["h1"], ["Second"], False)
    with pytest.raises(SystemExit):
        cli.build_parser().parse_args(["--body", "ghost"])
    with pytest.raises(SystemExit):
        cli.build_parser().parse_args(["--helpers", "two"])
    ns = cli.build_parser().parse_args([])
    assert (ns.helpers, ns.body, ns.helper, ns.player) == (None, None, None, None)


def test_main_uses_launch_mode_only_with_launch_flags(monkeypatch, home):
    calls = []

    async def fake_launch(core, stdout, helpers, body, ids, players):
        calls.append(("launch", helpers, body, ids, players))
        await core.close()
        return 0

    async def fake_run(core, stdin, stdout, admin):
        calls.append(("run", admin))
        await core.close()
        return 0

    monkeypatch.setenv("FP_HOME", str(home))
    monkeypatch.setenv("FP_RCON_HOST", "127.0.0.1")
    monkeypatch.setattr(cli, "launch", fake_launch)
    monkeypatch.setattr(cli, "run", fake_run)
    monkeypatch.setattr(cli, "setup_logging", lambda cfg: None)
    assert cli.main(["--helpers", "2"]) == 0
    assert cli.main(["--admin"]) == 0
    assert cli.main(["--body", "character", "--helper", "h2"]) == 0
    assert calls == [("launch", 2, None, None, None), ("run", True), ("launch", None, "character", ["h2"], None)]
    # launch mode obeys the same loopback-only rule
    monkeypatch.setenv("FP_RCON_HOST", "10.0.0.1")
    assert cli.main(["--helpers", "2"]) == 2
    assert len(calls) == 3
