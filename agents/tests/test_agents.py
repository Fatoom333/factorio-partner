"""Формат агента partner и примеров: сверка с сервером и контрактами (без игры)."""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

import lint

AGENT_TEXT = lint.AGENT_FILE.read_text(encoding="utf-8").replace("\r\n", "\n")


def test_repo_is_clean():
    assert lint.lint_all() == []


def test_frontmatter():
    meta, body = lint.parse_agent(AGENT_TEXT)
    assert meta["name"] == "partner"
    assert meta["model"] == "sonnet"
    assert set(meta) == {"name", "description", "model", "tools"}
    assert body.strip()


def test_whitelist_is_only_partner_tools():
    meta, _ = lint.parse_agent(AGENT_TEXT)
    tools = lint.agent_tools(meta)
    assert tools and all(t.startswith("mcp__partner__partner_") for t in tools)
    assert not any("admin" in t or "*" in t for t in tools)


def test_whitelist_matches_server_and_contract():
    meta, _ = lint.parse_agent(AGENT_TEXT)
    short = {t[len(lint.TOOL_PREFIX):] for t in lint.agent_tools(meta)}
    in_server, admin = lint.server_tools()
    in_docs = set(lint.mcp_tools())
    assert admin and not (short & admin)
    assert short == in_docs                       # ровно таблица docs/MCP.md
    assert short - in_server <= lint.PENDING_TOOLS  # отстаёт только добавляемое потоком Y
    assert in_server <= short                     # и ни один инструмент сервера не забыт


def test_contract_parsers_see_the_tables():
    acts = lint.actions()
    assert {"walk", "collect", "build_ghosts", "build_blueprint", "plan_mining", "wait"} <= set(acts)
    assert acts["collect"] == {"items", "center", "near", "radius"}
    assert {"blob", "plan", "anchor", "direction", "force", "dry_run", "mode"} == acts["build_blueprint"]
    assert lint.mcp_tools()["partner_wait"] == {"timeout", "quiet", "since"}
    assert lint.mcp_tools()["partner_brief"] == set()
    codes = lint.error_codes()
    assert len(codes) == 22 and "no_space" in codes and "internal" in codes
    assert {"job_failed", "player_said", "game_reloaded", "helper_lost"} <= set(lint.loud_events())
    reflexes = lint.reflex_types()
    assert reflexes["flee"]["radius"] == (4.0, 32.0) and reflexes["watch"]["every_s"] == (1.0, 600.0)


def test_prompt_handles_every_error_code_in_a_table_row():
    _, body = lint.parse_agent(AGENT_TEXT)
    rows = [line for line in body.splitlines() if line.startswith("|")]
    for code in lint.error_codes() + list(lint.SERVER_ERRORS):
        hits = [r for r in rows if f"`{code}`" in r.split("|")[1]]
        assert hits, code
        assert len(hits[0].split("|")[2].strip()) > 20, code   # есть, что делать


def test_examples_have_calls_for_the_whole_order():
    text = (lint.AGENTS_DIR / "examples" / "mining-order.md").read_text(encoding="utf-8")
    calls = lint.call_blocks(text.replace("\r\n", "\n"))
    tools = [t for t, _ in calls]
    for tool in ("partner_brief", "partner_state", "partner_reflex", "partner_resources", "partner_ghosts",
                 "partner_stock", "partner_act", "partner_wait", "partner_say", "partner_plan"):
        assert tool in tools, tool
    does = [raw for t, raw in calls if t == "partner_act"]
    for do in ("plan_mining", "collect", "build_ghosts", "build_blueprint"):
        assert any(f'"do":"{do}"' in raw for raw in does), do
    # superforced в примере — сначала только пробно
    forced = [raw for raw in does if "superforced" in raw]
    assert forced and all('"dry_run":true' in raw for raw in forced)


# ---- линтер ловит поломки -----------------------------------------------------------

def _lint_with(tmp_path: Path, text: str) -> list[str]:
    agent = tmp_path / "partner.md"
    agent.write_text(text, encoding="utf-8")
    return lint.lint_agent(agent_file=agent)


@pytest.mark.parametrize("old,new,expect", [
    ("model: sonnet", "model: opus", "model"),
    ("name: partner", "name: other", "name"),
    ("mcp__partner__partner_say", "mcp__partner__partner_teleport", "partner_teleport"),
    ("mcp__partner__partner_say", "mcp__partner__admin_spawn", "служебный"),
    ("mcp__partner__partner_say", "Bash", "Bash"),
    ("mcp__partner__partner_brief,", "mcp__partner__*,", "явные имена"),
    (", mcp__partner__partner_plan", "", "partner_plan"),
    ("| `no_space` |", "| `nospace` |", "no_space"),
    ("| `repeated_failure` |", "| `again` |", "repeated_failure"),
    ("`helper_lost`", "`gone`", "helper_lost"),
    ("`super_compact`", "`tiny`", "super_compact"),
    ('"radius":20', '"radius":99', "вне границ"),
    ('"type":"watch"', '"type":"shoot"', "неизвестный тип"),
    ("owner:true", "owner", "owner:true"),
])
def test_lint_catches(tmp_path, old, new, expect):
    assert old in AGENT_TEXT
    problems = _lint_with(tmp_path, AGENT_TEXT.replace(old, new))
    assert any(expect in p for p in problems), problems


def test_lint_catches_broken_frontmatter(tmp_path):
    assert _lint_with(tmp_path, AGENT_TEXT[4:])
    assert _lint_with(tmp_path, AGENT_TEXT.replace("\n---\n", "\n", 1))
    assert any("пустой" in p for p in _lint_with(
        tmp_path, "\n".join(l for l in AGENT_TEXT.split("\n") if not l.startswith("tools:"))))


@pytest.mark.parametrize("call,expect", [
    ('partner_act {"do":"teleport","args":{}}', "teleport"),
    ('partner_act {"do":"walk","args":{"to":{"x":1,"y":2},"speed":9}}', "speed"),
    ('partner_act {"do":"plan_mining","args":{"near":{"x":1,"y":2},"layout":"huge"}}', "раскладки"),
    ('partner_map {"zoom":3}', "zoom"),
    ('partner_wait {"timeout":120}', "55"),
    ('partner_say {"text":"' + "я" * 201 + '"}', "200"),
    ('partner_state {"helper":"h1"}', "helper"),
    ('admin_spawn {"helper":"h2"}', "белом списке"),
    ("partner_state {oops", "JSON"),
    ('partner_reflex {"set":[{"type":"flee","speed":2}]}', "speed"),
])
def test_lint_catches_bad_calls(tmp_path, call, expect):
    example = tmp_path / "example.md"
    example.write_text("```call\n" + call + "\n```\n", encoding="utf-8")
    problems = lint.lint_agent(extra_md=[example])
    assert any(expect in p for p in problems), problems


def test_lint_files_catches_private_paths_and_console(tmp_path):
    drive = tmp_path / "a.md"
    drive.write_text("лежит в D" + ":/Games/Factorio\n", encoding="utf-8")
    addr = tmp_path / "b.md"
    addr.write_text("сервер 10.1" + ".2.3\n", encoding="utf-8")
    local = tmp_path / "c.md"
    local.write_text("RCON только 127.0.0.1, версия 2.0.77\n", encoding="utf-8")
    code = tmp_path / "d.py"
    code.write_text('cmd = "/' + 'sc game.print(1)"\n', encoding="utf-8")
    assert lint.lint_files([drive]) and lint.lint_files([addr]) and lint.lint_files([code])
    assert lint.lint_files([local]) == []


def test_workflow_script_rules(tmp_path):
    src = lint.AGENTS_DIR / "workflows" / "partner-play.js"
    text = src.read_text(encoding="utf-8")
    assert text.startswith("export const meta = {")
    assert "agentType: 'partner'" in text and "model: 'sonnet'" in text
    # ключ не уходит в журнал и подписи: в log() и label — только id помощника
    for line in text.splitlines():
        if ("log(" in line or "label:" in line) and not line.lstrip().startswith("//"):
            assert "prompt" not in line and "key" not in line, line
    bad = tmp_path / "x.js"
    shutil.copyfile(src, bad)
    bad.write_text(text.replace("agentType: 'partner'", "agentType: 'general-purpose'") + "\nDate.now()\n",
                   encoding="utf-8")
    problems = lint.lint_files([bad])
    assert any("partner" in p for p in problems) and any("Date.now" in p for p in problems)
