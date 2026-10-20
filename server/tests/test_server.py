import io
import json
import re
from pathlib import Path

import pytest
from mcp.server.fastmcp.exceptions import ToolError

from factorio_partner import cli
from factorio_partner.server import build_server

from conftest import KEY

PKG = Path(__file__).resolve().parent.parent / "factorio_partner"
AGENT_TOOLS = {"partner_brief", "partner_state", "partner_map", "partner_resources", "partner_stock",
               "partner_ghosts", "partner_rates", "partner_act", "partner_cancel", "partner_wait",
               "partner_reflex", "partner_say", "partner_plan", "partner_recipes", "partner_find",
               "partner_access", "partner_supply", "partner_lookup", "partner_notes", "partner_status",
               "partner_hold", "partner_order", "partner_inbox", "partner_ledger", "partner_relay",
               "partner_rescale", "partner_task"}
ADMIN_TOOLS = {"admin_hello", "admin_spawn", "admin_remove", "admin_raw_events", "admin_limit", "admin_attach",
               "admin_settings"}


def _payload(result):
    # FastMCP.call_tool returns (content, structured) in mcp>=1.10
    if isinstance(result, tuple):
        content, structured = result
        if structured is not None:
            return structured.get("result", structured)
        result = content
    return json.loads(result[0].text)


async def test_tool_list(core):
    names = {t.name for t in await build_server(core).list_tools()}
    assert names == AGENT_TOOLS
    names = {t.name for t in await build_server(core, admin=True).list_tools()}
    assert names == AGENT_TOOLS | ADMIN_TOOLS


async def test_call_tool(core, fake):
    mcp = build_server(core)
    r = _payload(await mcp.call_tool("partner_act", {"helper": "h1", "key": KEY, "do": "wait",
                                                     "args": {"seconds": 2}}))
    assert r["job"] == 1


async def test_tool_errors(core):
    mcp = build_server(core)
    with pytest.raises(ToolError, match="access denied"):
        await mcp.call_tool("partner_state", {"helper": "h1", "key": "w" * 40})
    # a short key or a malformed helper id gives the same single text, not a pydantic error
    for helper, key in (("h1", "short"), ("H1", KEY), ("h1", "x" * 300), ("", KEY)):
        with pytest.raises(ToolError) as ei:
            await mcp.call_tool("partner_state", {"helper": helper, "key": key})
        msg = str(ei.value)       # FastMCP prefixes "Error executing tool ...: "
        assert msg.endswith(": access denied") and "validation" not in msg.lower()
    with pytest.raises(ToolError, match="bad_args"):
        await mcp.call_tool("partner_act", {"helper": "h1", "key": KEY, "do": "fly"})
    with pytest.raises(ToolError):
        await mcp.call_tool("partner_wait", {"helper": "h1", "key": KEY, "timeout": 100})


async def test_cli(core, fake):
    out = io.StringIO()
    rc = await cli.run(core, io.StringIO(json.dumps({"tool": "partner_state", "helper": "h1", "key": KEY})), out, False)
    res = json.loads(out.getvalue())
    assert rc == 0 and res["ok"] and res["result"]["helper"] == "h1"


async def test_cli_errors(cfg, fake):
    from conftest import make_bridge
    from factorio_partner.core import Core

    async def call(req, admin=False):
        c = Core(cfg, make_bridge(cfg), forge_module="tests_no_such_forge_module")
        out = io.StringIO()
        rc = await cli.run(c, io.StringIO(req if isinstance(req, str) else json.dumps(req)), out, admin)
        return rc, json.loads(out.getvalue())

    assert (await call("not json"))[0] == 2
    rc, r = await call({"tool": "admin_hello"})
    assert rc == 1 and r["error"] == "bad_request"
    rc, r = await call({"tool": "admin_hello"}, admin=True)
    assert rc == 0 and r["result"]["data"]["proto"] == 1
    rc, r = await call({"tool": "partner_say", "helper": "h1", "key": KEY, "text": "x", "evil": 1})
    assert rc == 1 and r["error"] == "bad_args"
    rc, r = await call({"tool": "partner_state", "helper": "h1", "key": "bad"})
    assert rc == 1 and r["error"] == "access denied"


def test_no_console_commands_in_package():
    """PROTOCOL §1/§6.10: the server never sends /c, /sc, /silent-command or Lua."""
    pat = re.compile(r"""["']/(c|sc|silent-command|command|measured-command)\b""")
    for f in PKG.rglob("*.py"):
        text = f.read_text(encoding="utf-8")
        assert not pat.search(text), f
        assert "loadstring" not in text and "game.print" not in text, f


def test_server_main_refuses_remote_host(monkeypatch, capsys):
    from factorio_partner import server
    monkeypatch.setenv("FP_RCON_HOST", "10.0.0.1")
    assert server.main([]) == 2
    assert "127.0.0.1" in capsys.readouterr().err
