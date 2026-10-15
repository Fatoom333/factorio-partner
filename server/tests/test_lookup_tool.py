"""Server side: ``partner_lookup`` — arguments are checked before the mod, only the
given ones are sent, the mod's answer reaches the agent untouched, name suggestions of ``not_found``
also go to ``detail.suggest``, an answer over the response limit is refused with a hint, the tool is
served by MCP and by the debug CLI."""
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


RECIPE = {"name": "plate", "enabled": False, "category": "smelting", "hand": False, "time": 3.2,
          "ingredients": [{"name": "ore", "type": "item", "amount": 1}],
          "products": [{"name": "plate", "type": "item", "amount": 1}],
          "machines": ["smelter"], "machines_total": 1, "unlocked_by": ["t-smelting"]}
LOOKUP_ANSWER = {"kind": "item", "name": "plate", "type": "item", "stack_size": 100,
                 "made_by": [RECIPE], "made_by_total": 1, "used_in": {}, "used_in_total": 0,
                 "mined_from": {}, "researched_any": False}


def install_lookup(fake, answer=None):
    fake.mod.handlers["lookup"] = lambda args, env: json.loads(json.dumps(answer or LOOKUP_ANSWER))


async def test_lookup_passes_only_given_args_and_keeps_the_answer(core, fake):
    install_lookup(fake)
    r = await core.op_lookup("h1", KEY, "plate")
    assert r == LOOKUP_ANSWER, "the mod's answer is passed as is"
    env = last_env(fake, "lookup")
    assert env["args"] == {"name": "plate"} and env["helper"] == "h1"
    await core.op_lookup("h1", KEY, "plate", kind="technology", limit=50)
    assert last_env(fake, "lookup")["args"] == {"name": "plate", "kind": "technology", "limit": 50}
    await core.op_lookup("h1", KEY, "plate", limit=3.0)
    assert last_env(fake, "lookup")["args"] == {"name": "plate", "limit": 3}
    assert V.LOOKUP_LIMIT_MAX == 50
    assert V.LOOKUP_KINDS == ("item", "fluid", "recipe", "technology", "entity")


@pytest.mark.parametrize("kw,code", [
    ({"name": None}, "bad_args"),
    ({"name": 5}, "bad_args"),
    ({"name": "iron plate"}, "bad_args"),
    ({"name": "x[img=item/coal]"}, "bad_args"),
    ({"name": "../x"}, "bad_args"),
    ({"name": "plate", "kind": "thing"}, "bad_args"),
    ({"name": "plate", "kind": "Item"}, "bad_args"),
    ({"name": "plate", "kind": 1}, "bad_args"),
    ({"name": "plate", "limit": 0}, "bad_args"),
    ({"name": "plate", "limit": 2.5}, "bad_args"),
    ({"name": "plate", "limit": True}, "bad_args"),
    ({"name": "plate", "limit": "3"}, "bad_args"),
    ({"name": "plate", "limit": 51}, "limit"),
])
async def test_lookup_rejects_before_the_mod(core, fake, kw, code):
    install_lookup(fake)
    assert (await code_of(core.op_lookup("h1", KEY, **kw))).code == code
    assert sent(fake, "lookup") == []


async def test_lookup_not_found_keeps_suggestions(core, fake):
    def refuse(args, env):
        raise FakeModError("not_found", "no item, fluid, recipe, technology or entity named plat; "
                                        "suggest: plate, plate-from-rock, bad name")
    fake.mod.handlers["lookup"] = refuse
    assert (await code_of(core.op_lookup("h1", "w" * 40, "plat"))).code == "access denied"
    assert sent(fake, "lookup") == []
    e = await code_of(core.op_lookup("h1", KEY, "plat"))
    assert e.code == "not_found" and "suggest: plate" in str(e), "the agent sees the suggestions"
    assert e.detail == {"suggest": ["plate", "plate-from-rock"]}, "only prototype-like names"

    def bare(args, env):
        raise FakeModError("not_found", "no item named zzz")
    fake.mod.handlers["lookup"] = bare
    e = await code_of(core.op_lookup("h1", KEY, "zzz"))
    assert e.code == "not_found" and e.detail is None


async def test_lookup_response_too_large_has_a_hint(core, fake):
    big = json.loads(json.dumps(LOOKUP_ANSWER))
    big["made_by"] = [dict(RECIPE, name="r" * 90, machines=["m" * 90] * 10) for _ in range(50)]
    assert V.json_size(big) > MAX_RESPONSE
    install_lookup(fake, big)
    e = await code_of(core.op_lookup("h1", KEY, "plate"))
    assert e.code == "response too large" and "limit" in e.text


async def test_lookup_tool_and_cli(core, fake):
    install_lookup(fake)
    mcp = build_server(core)
    tools = {t.name: t for t in await mcp.list_tools()}
    assert "partner_lookup" in tools
    tool = tools["partner_lookup"]
    assert set(tool.inputSchema["properties"]) == {"helper", "key", "name", "kind", "limit"}
    assert set(tool.inputSchema["required"]) == {"helper", "key", "name"}
    for word in ("made_by", "used_in", "unlocked_by", "missing", "trigger", "suggest", "limit", "partner_supply"):
        assert word in tool.description
    res = await mcp.call_tool("partner_lookup", {"helper": "h1", "key": KEY, "name": "plate", "kind": "item"})
    assert last_env(fake, "lookup")["args"] == {"name": "plate", "kind": "item"}
    assert res is not None
    out = io.StringIO()
    req = {"tool": "partner_lookup", "helper": "h1", "key": KEY, "name": "plate", "limit": 5}
    rc = await cli.run(core, io.StringIO(json.dumps(req)), out, False)
    assert rc == 0 and json.loads(out.getvalue())["result"]["name"] == "plate"
    assert last_env(fake, "lookup")["args"] == {"name": "plate", "limit": 5}
    assert cli.TOOLS["partner_lookup"] == ("op_lookup", ("name", "kind", "limit"))
