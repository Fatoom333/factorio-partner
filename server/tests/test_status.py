"""Server side: ``partner_status`` (docs/STATE.md «status», docs/MCP.md)."""
import io
import json

import pytest

from factorio_partner import cli
from factorio_partner.errors import PartnerError
from factorio_partner.server import build_server

from conftest import KEY

ANSWER = {
    "surface": "nauvis", "center": {"x": 2, "y": 0}, "radius": 64,
    "machines": {"seen": 5, "running": 3, "stopped": 2, "hidden": 0},
    "causes": {"power": 2},
    "stopped": [{"name": "assembling-machine-1", "reason": "no_power", "cause": "power",
                 "recipe": "iron-gear-wheel", "count": 2, "pos": {"x": 14, "y": 0}, "dist": 12}],
    "index_ready": True,
}


def last_env(fake, op):
    for env in reversed(fake.mod.requests):
        if env.get("op") == op:
            return env
    raise AssertionError(f"no request {op}")


def install(fake, answer=None):
    fake.mod.handlers["status"] = lambda args, env: dict(answer or ANSWER)


async def code_of(coro):
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


async def test_status_passes_only_given_args(core, fake):
    install(fake)
    r = await core.op_status("h1", KEY)
    assert r["machines"]["stopped"] == 2 and r["stopped"][0]["cause"] == "power"
    env = last_env(fake, "status")
    assert env["helper"] == "h1" and env["args"] == {}
    await core.op_status("h1", KEY, radius=96, limit=5, center={"x": 4, "y": -2})
    assert last_env(fake, "status")["args"] == {"radius": 96, "limit": 5, "center": {"x": 4, "y": -2}}
    await core.op_status("h1", KEY, near="player")
    assert last_env(fake, "status")["args"] == {"near": "player"}
    # a whole-number float becomes an integer
    await core.op_status("h1", KEY, limit=7.0)
    assert last_env(fake, "status")["args"]["limit"] == 7


@pytest.mark.parametrize("kwargs,code", [
    ({"radius": 0}, "bad_args"),
    ({"radius": 129}, "limit"),
    ({"limit": 0}, "bad_args"),
    ({"limit": 51}, "limit"),
    ({"limit": 2.5}, "bad_args"),
    ({"center": {"x": 1, "y": 1}, "near": "player"}, "bad_args"),
    ({"near": "helper"}, "bad_args"),
])
async def test_status_bounds(core, fake, kwargs, code):
    install(fake)
    e = await code_of(core.op_status("h1", KEY, **kwargs))
    assert e.code == code
    assert not [r for r in fake.mod.requests if r.get("op") == "status"]


async def test_status_too_large_has_hint(core, fake):
    big = dict(ANSWER, stopped=[dict(ANSWER["stopped"][0], name="m" * 200, recipe="r" * 200) for _ in range(300)])
    install(fake, big)
    e = await code_of(core.op_status("h1", KEY))
    assert e.code == "response too large" and "radius" in e.text


async def test_status_tool_and_cli(core, fake):
    install(fake)
    mcp = build_server(core)
    tools = {t.name: t for t in await mcp.list_tools()}
    assert set(tools["partner_status"].inputSchema["properties"]) == {
        "helper", "key", "radius", "limit", "center", "near"}
    await mcp.call_tool("partner_status", {"helper": "h1", "key": KEY, "radius": 30})
    assert last_env(fake, "status")["args"] == {"radius": 30}
    out = io.StringIO()
    req = {"tool": "partner_status", "helper": "h1", "key": KEY, "limit": 3}
    rc = await cli.run(core, io.StringIO(json.dumps(req)), out, False)
    assert rc == 0 and json.loads(out.getvalue())["result"]["index_ready"] is True
    assert last_env(fake, "status")["args"] == {"limit": 3}
