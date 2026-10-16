"""Server side: ``partner_hold`` -> op ``owner_hold`` (docs/EVENTS.md «Слово хозяина», docs/MCP.md)."""
import io
import json

import pytest

from factorio_partner import cli
from factorio_partner.core import Core
from factorio_partner.errors import PartnerError
from factorio_partner.server import build_server

from conftest import KEY, make_bridge
from fake_rcon import FakeModError


def last_env(fake, op):
    for env in reversed(fake.mod.requests):
        if env.get("op") == op:
            return env
    raise AssertionError(f"no request {op}")


def install(fake):
    def owner_hold(args, env):
        if args.get("release"):
            if args.get("seq") == 7:
                raise FakeModError("bad_args", "args.seq: the owner addressed this message to another helper")
            return {"released": [env["helper"]]}
        return {"hold": {"h1": {"kind": "stop", "tick": 10, "seq": 3}}}
    fake.mod.handlers["owner_hold"] = owner_hold


async def code_of(coro):
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


async def test_read_and_release(core, fake):
    install(fake)
    r = await core.op_hold("h1", KEY)
    assert r["hold"]["h1"]["kind"] == "stop"
    env = last_env(fake, "owner_hold")
    assert env["helper"] == "h1" and env["args"] == {}
    r = await core.op_hold("h1", KEY, release=True, said_seq=5)
    assert r["released"] == ["h1"]
    assert last_env(fake, "owner_hold")["args"] == {"release": True, "seq": 5}


async def test_mod_refusal_reaches_the_agent(core, fake):
    install(fake)
    e = await code_of(core.op_hold("h1", KEY, release=True, said_seq=7))
    assert e.code == "bad_args" and "another helper" in e.text


@pytest.mark.parametrize("kwargs", [
    {"release": True},                       # release needs the owner's message
    {"release": True, "said_seq": 0},
    {"release": True, "said_seq": 1.5},
    {"release": True, "said_seq": True},
    {"release": "yes", "said_seq": 5},
    {"said_seq": 5},                         # said_seq only with release
])
async def test_bad_args_never_reach_the_mod(core, fake, kwargs):
    install(fake)
    e = await code_of(core.op_hold("h1", KEY, **kwargs))
    assert e.code == "bad_args"
    assert not [r for r in fake.mod.requests if r.get("op") == "owner_hold"]


async def test_release_is_refused_on_a_paused_game_but_reading_works(cfg, fake):
    install(fake)
    now = [0.0]
    c = Core(cfg, make_bridge(cfg, clock=lambda: now[0]), poll_interval=0.01,
             forge_module="tests_no_such_forge_module", clock=lambda: now[0])
    await c.op_hold("h1", KEY)
    fake.mod.tick_step = 0
    for _ in range(3):
        now[0] += 2.0
        await c.op_hold("h1", KEY)
    assert (await c.op_hold("h1", KEY))["warning"] == "game_paused"
    e = await code_of(c.op_hold("h1", KEY, release=True, said_seq=5))
    assert e.code == "game_paused"
    assert not [r for r in fake.mod.requests if r.get("op") == "owner_hold" and r["args"].get("release")]
    await c.close()


async def test_tool_and_cli(core, fake):
    install(fake)
    mcp = build_server(core)
    tools = {t.name: t for t in await mcp.list_tools()}
    assert set(tools["partner_hold"].inputSchema["properties"]) == {"helper", "key", "release", "said_seq"}
    await mcp.call_tool("partner_hold", {"helper": "h1", "key": KEY, "release": True, "said_seq": 9})
    assert last_env(fake, "owner_hold")["args"] == {"release": True, "seq": 9}
    out = io.StringIO()
    req = {"tool": "partner_hold", "helper": "h1", "key": KEY}
    rc = await cli.run(core, io.StringIO(json.dumps(req)), out, False)
    assert rc == 0 and json.loads(out.getvalue())["result"]["hold"]["h1"]["seq"] == 3


async def test_act_docstring_names_the_new_actions(core):
    mcp = build_server(core)
    tools = {t.name: t for t in await mcp.list_tools()}
    doc = tools["partner_act"].description
    assert "get_items" in doc and "auto_supply" in doc and "owner_hold" in doc
