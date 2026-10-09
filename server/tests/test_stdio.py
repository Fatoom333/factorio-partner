"""End-to-end: the real MCP server process over stdio, talking to the fake RCON server."""
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from conftest import KEY

SERVER_DIR = Path(__file__).resolve().parent.parent


async def test_stdio_roundtrip(fake, home):
    env = dict(os.environ)
    env.update({
        "FP_HOME": str(home),
        "FP_RCON_HOST": "localhost",
        "FP_RCON_PORT": str(fake.port),
        "FP_RCON_PASSWORD_FILE": str(home / "rcon.pw"),
        "PYTHONPATH": str(SERVER_DIR),
        "PYTHONIOENCODING": "utf-8",
    })
    params = StdioServerParameters(command=sys.executable, args=["-m", "factorio_partner.server", "--admin"],
                                   env=env, cwd=str(SERVER_DIR))
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = {t.name for t in (await s.list_tools()).tools}
            assert "partner_act" in tools and "admin_hello" in tools
            res = await s.call_tool("partner_act", {"helper": "h1", "key": KEY, "do": "walk",
                                                    "args": {"to": {"x": 3, "y": 4}}})
            assert not res.isError
            data = res.structuredContent or json.loads(res.content[0].text)
            data = data.get("result", data)
            assert data["job"] == 1
            res = await s.call_tool("partner_state", {"helper": "h1", "key": "q" * 40})
            assert res.isError and "access denied" in res.content[0].text
    assert (home / "logs" / "server.log").exists()
    assert fake.mod.executed["act"] == 1
