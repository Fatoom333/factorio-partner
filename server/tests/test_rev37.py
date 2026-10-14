"""Revision 3.7 on the server side: ``partner_supply`` — arguments are checked before the mod, only the
given ones are sent, the mod's answer reaches the agent untouched, an answer over the response limit
is refused with a hint, the tool is served by MCP and by the debug CLI."""
import io
import json

import pytest

from factorio_partner import cli
from factorio_partner import validate as V
from factorio_partner.core import MAX_RESPONSE
from factorio_partner.errors import PartnerError
from factorio_partner.server import build_server

from conftest import KEY
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


PLATE = {"name": "plate", "kind": "item", "need": 20, "have": 0, "short": 20, "note": "depth",
         "stored": {"total": 1150, "pos": {"x": 6, "y": 0.5}, "dist": 6, "n": 150},
         "producers": {"count": 2, "pos": {"x": 12, "y": 0}, "dist": 12, "names": {"smelter": 2},
                       "recipe": "plate", "out": 12}}
SUPPLY_ANSWER = {
    "item": "gear", "count": 10, "surface": "nauvis", "nodes": 2, "hidden": 1,
    "tree": {"name": "gear", "kind": "item", "need": 10, "have": 0, "short": 10,
             "recipe": {"name": "gear", "hand": True, "category": "crafting", "yield": 1, "crafts": 10,
                        "time": 5, "ingredients": [PLATE]}},
    "summary": {"short": [{"name": "gear", "n": 10}, {"name": "plate", "n": 20}], "raw": {}},
    "warnings": {},
}


def install_supply(fake, answer=None):
    fake.mod.handlers["supply"] = lambda args, env: json.loads(json.dumps(answer or SUPPLY_ANSWER))


async def test_supply_passes_only_given_args_and_keeps_the_answer(core, fake):
    install_supply(fake)
    r = await core.op_supply("h1", KEY, "gear")
    assert r == SUPPLY_ANSWER, "the mod's answer is passed as is"
    env = last_env(fake, "supply")
    assert env["args"] == {"item": "gear"} and env["helper"] == "h1"
    await core.op_supply("h1", KEY, "gear", count=10000, depth=5)
    assert last_env(fake, "supply")["args"] == {"item": "gear", "count": 10000, "depth": 5}
    await core.op_supply("h1", KEY, "gear", count=3.0, depth=1.0)
    assert last_env(fake, "supply")["args"] == {"item": "gear", "count": 3, "depth": 1}
    assert (V.SUPPLY_COUNT_MAX, V.SUPPLY_DEPTH_MAX) == (10000, 5)


@pytest.mark.parametrize("kw,code", [
    ({"item": None}, "bad_args"),
    ({"item": 5}, "bad_args"),
    ({"item": "iron plate"}, "bad_args"),
    ({"item": "x[img=item/coal]"}, "bad_args"),
    ({"item": "../x"}, "bad_args"),
    ({"item": "gear", "count": 0}, "bad_args"),
    ({"item": "gear", "count": -1}, "bad_args"),
    ({"item": "gear", "count": 2.5}, "bad_args"),
    ({"item": "gear", "count": True}, "bad_args"),
    ({"item": "gear", "count": "3"}, "bad_args"),
    ({"item": "gear", "count": 10001}, "limit"),
    ({"item": "gear", "depth": 0}, "bad_args"),
    ({"item": "gear", "depth": 1.5}, "bad_args"),
    ({"item": "gear", "depth": 6}, "limit"),
])
async def test_supply_rejects_before_the_mod(core, fake, kw, code):
    install_supply(fake)
    assert (await code_of(core.op_supply("h1", KEY, **kw))).code == code
    assert sent(fake, "supply") == []


async def test_supply_needs_key_and_keeps_mod_errors(core, fake):
    def refuse(args, env):
        raise FakeModError("not_found", "item: no item or fluid named gear")
    fake.mod.handlers["supply"] = refuse
    assert (await code_of(core.op_supply("h1", "w" * 40, "gear"))).code == "access denied"
    assert sent(fake, "supply") == []
    e = await code_of(core.op_supply("h1", KEY, "gear"))
    assert e.code == "not_found" and "gear" in e.text


async def test_supply_response_too_large_has_a_hint(core, fake):
    # 60 nodes with every source can outgrow the response limit: refused like map / find, with a hint
    node = dict(PLATE, name="n" * 90)
    big = json.loads(json.dumps(SUPPLY_ANSWER))
    big["tree"]["recipe"]["ingredients"] = [dict(node) for _ in range(120)]
    assert V.json_size(big) > MAX_RESPONSE
    install_supply(fake, big)
    e = await code_of(core.op_supply("h1", KEY, "gear"))
    assert e.code == "response too large" and "depth" in e.text


async def test_supply_tool_and_cli(core, fake):
    install_supply(fake)
    mcp = build_server(core)
    tools = {t.name: t for t in await mcp.list_tools()}
    assert "partner_supply" in tools
    tool = tools["partner_supply"]
    assert set(tool.inputSchema["properties"]) == {"helper", "key", "item", "count", "depth"}
    assert set(tool.inputSchema["required"]) == {"helper", "key", "item"}
    for word in ("summary", "stored", "producers", "makers", "hand", "resource", "depth"):
        assert word in tool.description
    res = await mcp.call_tool("partner_supply", {"helper": "h1", "key": KEY, "item": "gear", "count": 10})
    assert last_env(fake, "supply")["args"] == {"item": "gear", "count": 10}
    assert res is not None
    out = io.StringIO()
    req = {"tool": "partner_supply", "helper": "h1", "key": KEY, "item": "gear", "depth": 2}
    rc = await cli.run(core, io.StringIO(json.dumps(req)), out, False)
    assert rc == 0 and json.loads(out.getvalue())["result"]["tree"]["name"] == "gear"
    assert last_env(fake, "supply")["args"] == {"item": "gear", "depth": 2}
    assert cli.TOOLS["partner_supply"] == ("op_supply", ("item", "count", "depth"))
