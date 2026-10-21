"""Роли для других клиентов (agents/roles_export.py и agents/launch.py --client): формат файлов."""
from __future__ import annotations

import asyncio
import json
import tomllib
from pathlib import Path

import pytest

import launch
import roles_export as rx
from test_launch import FakeBridge, make_cfg
from factorio_partner.core import Core

NAMES = ("partner-voice", "partner-pilot", "partner-strategist", "partner")
SOURCES = dict(zip(NAMES, rx.SOURCES))


def source(name):
    text = (rx.SOURCE_DIR / SOURCES[name]).read_text(encoding="utf-8").replace("\r\n", "\n")
    return rx.parse_source(text)


def split_md(text):
    """Frontmatter (одно-двухуровневый YAML, значения — JSON) и тело после комментария «generated»."""
    assert text.startswith("---\n")
    end = text.index("\n---\n", 4)
    meta, stack = {}, None
    for line in text[4:end].splitlines():
        if line.startswith("  "):
            k, _, v = line.strip().partition(":")
            meta[stack][k] = v.strip()
            continue
        k, _, v = line.partition(":")
        v = v.strip()
        if v:
            meta[k] = json.loads(v) if v[0] in '"0123456789' or v in ("true", "false") else v
        else:
            meta[k], stack = {}, k
    rest = text[end + 5:]
    comment, _, body = rest.partition("\n")
    return meta, comment, body


@pytest.fixture(scope="module")
def files():
    return rx.expected()


def test_every_client_gets_every_role(files):
    for client in rx.CLIENTS:
        for name in NAMES:
            assert f"{rx.OUT_DIRS[client]}/{name}{rx.EXT[client]}" in files
    assert len(files) == len(rx.CLIENTS) * len(NAMES)


@pytest.mark.parametrize("name", NAMES)
def test_codex_toml_is_valid_and_carries_the_body(files, name):
    meta, body = source(name)
    text = files[f".codex/agents/{name}.toml"]
    assert text.startswith("# generated from .claude/agents/")
    data = tomllib.loads(text)
    assert set(data) == {"name", "description", "developer_instructions", "features"}
    assert data["features"] == {"shell_tool": False, "apps": False, "plugins": False}
    assert data["name"] == name and data["description"] == meta["description"]
    assert data["developer_instructions"] == body


def test_codex_toml_survives_a_body_with_triple_quotes():
    text = "---\nname: x\ndescription: y\n---\na '''b''' \"\"\"c\"\"\" \\d\n"
    data = tomllib.loads(rx.render("codex", "x.md", text))
    assert data["developer_instructions"] == "a '''b''' \"\"\"c\"\"\" \\d\n"


@pytest.mark.parametrize("client", ("gemini", "opencode", "cursor"))
@pytest.mark.parametrize("name", NAMES)
def test_markdown_clients_have_frontmatter_and_the_same_body(files, client, name):
    src_meta, body = source(name)
    meta, comment, got = split_md(files[f"{rx.OUT_DIRS[client]}/{name}.md"])
    assert comment.startswith("<!-- generated from .claude/agents/") and "do not edit" in comment
    assert got == body
    assert meta["description"] == src_meta["description"]
    # ни инструментов mcp__partner__*, ни моделей Claude у других клиентов
    assert "tools" not in meta and "mcp__partner__" not in files[f"{rx.OUT_DIRS[client]}/{name}.md"].split("-->")[0]
    assert meta.get("model", "inherit") == "inherit"


def test_client_specific_keys(files):
    g, _, _ = split_md(files[".gemini/agents/partner-pilot.md"])
    assert g["name"] == "partner-pilot" and g["max_turns"] >= 100 and g["timeout_mins"] >= 60
    o, _, _ = split_md(files[".opencode/agents/partner-voice.md"])
    assert o["mode"] == "subagent" and o["permission"] == {"edit": "deny", "bash": "deny", "webfetch": "deny", "task": "deny"}
    assert "name" not in o
    c, _, _ = split_md(files[".cursor/agents/partner-strategist.md"])
    assert c["is_background"] is True and c["readonly"] is True and c["model"] == "inherit"


def test_repository_copies_are_fresh():
    assert rx.check() == []


def test_check_detects_drift_missing_and_orphans(tmp_path):
    rx.write(tmp_path, rx.SOURCE_DIR)
    assert rx.check(tmp_path, rx.SOURCE_DIR) == []
    victim = tmp_path / ".codex/agents/partner-voice.toml"
    victim.write_text(victim.read_text(encoding="utf-8") + "# lost\n", encoding="utf-8")
    (tmp_path / ".gemini/agents/partner-pilot.md").unlink()
    (tmp_path / ".cursor/agents/partner-old.md").write_text("x", encoding="utf-8")
    problems = rx.check(tmp_path, rx.SOURCE_DIR)
    assert any("partner-voice.toml" in p and "устарел" in p for p in problems)
    assert any("partner-pilot.md" in p and "нет файла" in p for p in problems)
    assert any("partner-old.md" in p for p in problems)
    rx.write(tmp_path, rx.SOURCE_DIR)
    assert [p for p in rx.check(tmp_path, rx.SOURCE_DIR) if "partner-old" not in p] == []


def test_check_notices_a_changed_source(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    for name in rx.SOURCES:
        (src / name).write_text((rx.SOURCE_DIR / name).read_text(encoding="utf-8"), encoding="utf-8")
    out = tmp_path / "out"
    rx.write(out, src)
    (src / "partner-voice.md").write_text(
        (src / "partner-voice.md").read_text(encoding="utf-8") + "\nновое правило\n", encoding="utf-8")
    assert any("partner-voice" in p for p in rx.check(out, src))


# ---- launch.py --client ---------------------------------------------------------------

def run_client(tmp_path, client, n=2):
    cfg = make_cfg(tmp_path)
    env = {"FP_RCON_PORT": "27015", "FP_RCON_PASSWORD_FILE": "/x/rcon.pw", "FP_HOME": str(cfg.home)}
    result = asyncio.run(launch.launch(cfg, n, "character", [], core=Core(cfg, FakeBridge()), env=env,
                                       python="python", say=lambda _t: None, client=client))
    return result, cfg


def keys_of(cfg):
    data = json.loads(cfg.helpers_file.read_text(encoding="utf-8"))
    return data, [k for e in data.values() for k in ([e] if isinstance(e, str) else e.values())]


@pytest.mark.parametrize("client", ("codex", "gemini", "opencode", "cursor"))
def test_launch_client_writes_parseable_config_and_first_message(tmp_path, client):
    result, cfg = run_client(tmp_path, client)
    path = Path(result["mcp_config"])
    assert path.name == launch.CLIENT_MCP_FILE[client] and path.parent == cfg.home / "launch"
    text = path.read_text(encoding="utf-8")
    if client == "codex":
        server = tomllib.loads(text)["mcp_servers"]["partner"]
        assert server["command"] == "python" and server["args"] == ["-m", "factorio_partner.server"]
        assert server["env"]["FP_RCON_PORT"] == "27015"
    else:
        data = json.loads(text)
        if client == "opencode":
            s = data["mcp"]["partner"]
            assert s["type"] == "local" and s["command"] == ["python", "-m", "factorio_partner.server"]
            assert s["environment"]["FP_RCON_PORT"] == "27015"
        else:
            s = data["mcpServers"]["partner"]
            assert s["command"] == "python" and s["args"] == ["-m", "factorio_partner.server"]
            assert s["env"]["FP_RCON_PASSWORD_FILE"] == "/x/rcon.pw"
        if client == "gemini":
            assert data["experimental"] == {"enableAgents": True}
            assert {"run_shell_command", "write_file", "web_fetch"} <= set(data["excludeTools"])
    # без служебного режима и без пароля
    assert "--admin" not in text and "admin" not in text.lower().replace("administrator", "")
    data, keys = keys_of(cfg)
    assert not any(k in text for k in keys)
    message = Path(result["first_message"]).read_text(encoding="utf-8")
    assert "--admin" not in message
    for role in ("partner-voice", "partner-strategist", "partner-pilot, тело h1", "partner-pilot, тело h2"):
        assert role in message
    # каждый ключ роли — один раз; ключа диспетчера в сообщении нет
    for k in (data["*"]["voice"], data["*"]["strategist"], data["h1"]["pilot"], data["h2"]["pilot"]):
        assert message.count(k) == 1
    assert data["*"]["host"] not in message
    assert f".{client}/agents/" in message


def test_launch_client_implies_roles_and_claude_is_unchanged(tmp_path):
    result, _ = run_client(tmp_path / "a", "codex")
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    assert session["mode"] == "roles"
    result, _ = run_client(tmp_path / "b", "claude")
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    assert "mode" not in session and "first_message" not in result
    assert Path(result["mcp_config"]).name == "mcp.json"


def test_launch_rejects_an_unknown_client(tmp_path):
    with pytest.raises(launch.LaunchError, match="клиент"):
        run_client(tmp_path, "vim")
