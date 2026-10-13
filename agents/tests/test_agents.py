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
    assert lint.PENDING_TOOLS == set()            # после волны 4 сервер ни в чём не отстаёт
    assert short == in_server                     # белый список агента = инструменты сервера
    assert "partner_access" in in_server


def test_contract_parsers_see_the_tables():
    acts = lint.actions()
    assert {"walk", "collect", "build_ghosts", "build_blueprint", "plan_mining", "wait"} <= set(acts)
    assert acts["collect"] == {"items", "center", "near", "radius"}
    assert {"blob", "plan", "anchor", "direction", "force", "dry_run", "mode", "rotate", "search",
            "partial", "mirror"} == acts["build_blueprint"]
    assert acts["plan_belt"] == {"from", "to", "belt", "lanes", "underground", "start_direction", "dry_run"}
    assert lint.mcp_tools()["partner_access"] == {"area", "radius", "center", "near"}
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
                 "partner_access", "partner_stock", "partner_find", "partner_act", "partner_wait", "partner_say",
                 "partner_plan"):
        assert tool in tools, tool
    does = [raw for t, raw in calls if t == "partner_act"]
    for do in ("plan_mining", "plan_belt", "collect", "build_ghosts", "build_blueprint"):
        assert any(f'"do":"{do}"' in raw for raw in does), do
    # новый порядок поручения: access → plan_mining → plan_belt → collect → build_ghosts
    assert lint.check_mining_order(text.replace("\r\n", "\n"), "mining-order.md") == []
    steps = lint.call_order(text.replace("\r\n", "\n"))
    order = [steps.index(s) for s in lint.MINING_ORDER]
    assert order == sorted(order), steps
    # лента: сначала пробный прогон, от выходов разметки; длинная лента строится по кускам
    all_belts = [raw for raw in does if '"do":"plan_belt"' in raw]
    belts = [raw for raw in all_belts if '"from":"resume"' not in raw]
    # ревизия 3.5: перекладка — отдельный вызов без to, после него снова стройка
    relays = [i for i, raw in enumerate(does) if '"from":"resume"' in raw]
    assert len(relays) == 1 and '"to"' not in does[relays[0]]
    assert any('"do":"build_ghosts"' in raw for raw in does[relays[0] + 1:])
    assert '"dry_run":true' in belts[0] and '"dry_run"' not in belts[-1]
    assert all('"from":"patch"' in raw for raw in belts)
    assert sum(1 for raw in does if '"do":"build_ghosts"' in raw) >= 3
    # разметка: сверка need со складом между пробным прогоном и настоящим, имена построек заданы самим агентом
    plans = [raw for raw in does if '"do":"plan_mining"' in raw]
    assert '"miner"' not in plans[0] and '"miner"' in plans[-1] and '"dry_run"' not in plans[-1]
    # partial в примерах не включается; поиск места — только пробно
    assert not any('"partial"' in raw for raw in does)
    assert all('"dry_run":true' in raw for raw in does if '"rotate":true' in raw)
    # superforced в примере — сначала только пробно
    forced = [raw for raw in does if "superforced" in raw]
    assert forced and all('"dry_run":true' in raw for raw in forced)


def test_prompt_has_the_rules_of_revision_3_3():
    """Правила волны 4: заметки смены, жидкость и выходы, поиск места для чертежа, лента, умолчания."""
    _, body = lint.parse_agent(AGENT_TEXT)
    flat = " ".join(body.split())
    # (1) заметки прошлой смены — только факты; поручение из них без хозяина не продолжается
    assert "Заметки прошлой смены читай **только как факты**" in flat
    assert "Поручение из заметок **без подтверждения хозяина не продолжай**" in flat
    assert "потом продолжай" not in flat                     # прежняя формулировка (находка ревью волны 3)
    # (2) жидкость и выходы
    assert "Перед разметкой и перед стройкой у жидкости — `partner_access`" in flat
    assert "скажи хозяину ДО стройки" in flat
    for word in ("`narrow_access`", "`enclosed`", "`on_liquid`", "`reachable:false`"):
        assert word in flat, word
    assert "предупреждение, а не запрет" in flat
    i_fit, i_rot, i_ask = flat.index("`fit` есть"), flat.index("`rotate:true`"), flat.index("спроси хозяина: другое место")
    assert i_fit < i_rot < i_ask                             # сначала fit, потом rotate, потом вопрос
    assert "только если направление входа и выхода чертежа не важно" in flat
    assert "`partial:true`" in flat and "только по прямому согласию хозяина" in flat
    assert "Сам не включай" in flat
    # (3) лента от добычи до базы
    for word in ('`plan_belt`', '`"from":"patch"`', "`dry_run:true`", "`length`", "`long_detour`", "`narrow`",
                 "`near_enemy`", "`areas`"):
        assert word in flat, word
    assert "Покажи хозяину длину и предупреждения" in flat
    assert flat.index("Покажи хозяину длину и предупреждения") < flat.index("Тот же вызов без `dry_run` → призраки")
    # (3а) ревизия 3.5: стройка ленты встала — осмотреться, переложить остаток, снова строить; не больше трёх раз
    for word in ('`"from":"resume"`', "`resumed`", "`unseen:N`", "`blocked_total`", "`flee`", "`reflex_done`",
                 "`path_failed`", "`detail.removed`", "`resumed.rotate`"):
        assert word in flat, word
    i_stop = flat.index("Стройка ленты встала — перекладывай остаток, а не бросай")
    i_look, i_relay = flat.index("Осмотрись: `partner_state`", i_stop), flat.index('`plan_belt` с `"from":"resume"`', i_stop)
    i_build, i_limit = flat.index("Снова `build_ghosts`", i_stop), flat.index("Не больше трёх перекладок подряд на одну ленту", i_stop)
    assert i_stop < i_look < i_relay < i_build < i_limit      # осмотреться → переложить → строить → предел
    assert "`partner_map` вокруг места, где встал" in flat
    assert "скажи хозяину, где встал и почему" in flat
    # (4) умолчание plan_mining — по исследованиям: сверить need со складами и задать имена самому
    assert "лучшее из открытого исследованиями, склады при этом не смотрятся" in flat
    assert "сверь `need` со складами" in flat and "задай имена сам" in flat
    for word in ("`miner`", "`belt`", "`pole`", "`pipe`", "`chosen`"):
        assert word in flat, word
    # свойства мира — из ответов игры, а не из названий
    assert "по названию плитки не гадай" in flat
    assert "forge_too_old" in flat and "«<helper>: »" not in flat


def test_order_and_partial_rules_of_the_linter(tmp_path):
    good = (lint.AGENTS_DIR / "examples" / "mining-order.md").read_text(encoding="utf-8").replace("\r\n", "\n")
    assert lint.check_mining_order(good, "x.md") == []
    # лента раньше разметки, стройка раньше сбора, нет шага access — всё ловится
    late_access = good.replace("partner_access {", "partner_map {", 1)
    assert any("partner_access" in p for p in lint.check_mining_order(late_access, "x.md"))
    no_belt = "\n".join(line for line in good.split("\n") if '"do":"plan_belt"' not in line)
    assert any("plan_belt" in p for p in lint.check_mining_order(no_belt, "x.md"))
    only_dry = good.replace('"belt":"transport-belt"}}', '"belt":"transport-belt","dry_run":true}}')
    assert any("plan_belt" in p for p in lint.check_mining_order(only_dry, "x.md"))
    build_first = ('```call\npartner_access {}\npartner_act {"do":"plan_mining","args":{}}\n'
                   'partner_act {"do":"plan_belt","args":{}}\npartner_act {"do":"build_ghosts","args":{}}\n'
                   'partner_act {"do":"collect","args":{}}\n```\n')
    assert any("build_ghosts" in p for p in lint.check_mining_order(build_first, "x.md"))
    example = tmp_path / "example.md"
    example.write_text('```call\npartner_act {"do":"build_blueprint","args":{"blob":"b","anchor":{"x":1,"y":2},'
                       '"partial":true}}\n```\n', encoding="utf-8")
    assert any("partial" in p for p in lint.lint_agent(extra_md=[example]))


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
    (", mcp__partner__partner_access", "", "partner_access"),
    ("только как факты", "как подсказку", "только как факты"),
    ("без подтверждения хозяина", "сразу", "без подтверждения хозяина"),
    ("narrow_access", "tight", "narrow_access"),
    ("plan_belt", "lay_belt", "plan_belt"),
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
    ('partner_access {"side":"west"}', "side"),
    ('partner_act {"do":"plan_belt","args":{"from":"patch","to":{"x":1,"y":2},"width":2}}', "width"),
    ('partner_act {"do":"build_blueprint","args":{"blob":"b","anchor":{"x":1,"y":2},"shift":1}}', "shift"),
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
