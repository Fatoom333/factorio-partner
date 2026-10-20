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
    # ровно таблица docs/MCP.md без инструментов режима ролей
    assert short == in_docs - lint.MULTI_ROLE_TOOLS - lint.HOST_TOOLS
    assert lint.HOST_TOOLS <= in_docs and lint.HOST_TOOLS <= in_server
    assert lint.MULTI_ROLE_TOOLS <= in_docs and lint.MULTI_ROLE_TOOLS <= in_server
    assert lint.PENDING_TOOLS == set()            # сервер ни в чём не отстаёт
    assert short == in_server - lint.MULTI_ROLE_TOOLS - lint.HOST_TOOLS   # белый список агента = инструменты сервера
    assert "partner_access" in in_server
    assert "partner_supply" in short and "partner_supply" in in_server


def test_contract_parsers_see_the_tables():
    acts = lint.actions()
    assert {"walk", "collect", "build_ghosts", "build_blueprint", "plan_mining", "wait"} <= set(acts)
    assert acts["collect"] == {"items", "center", "near", "radius", "from_lines"}
    assert {"blob", "plan", "anchor", "direction", "force", "dry_run", "mode", "rotate", "search",
            "partial", "mirror", "auto_supply"} == acts["build_blueprint"]
    assert acts["plan_belt"] == {"from", "to", "belt", "lanes", "underground", "start_direction", "dry_run"}
    assert lint.mcp_tools()["partner_access"] == {"area", "radius", "center", "near"}
    assert lint.mcp_tools()["partner_supply"] == {"item", "count", "depth"}
    assert lint.mcp_tools()["partner_wait"] == {"timeout", "quiet", "since"}
    assert lint.mcp_tools()["partner_brief"] == set()
    codes = lint.error_codes()
    assert len(codes) == 23 and "no_space" in codes and "owner_hold" in codes and "internal" in codes
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
    # перекладка — отдельный вызов без to, после него снова стройка
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


def test_prompt_has_the_notes_liquid_and_belt_rules():
    """Правила: заметки смены, жидкость и выходы, поиск места для чертежа, лента, умолчания."""
    _, body = lint.parse_agent(AGENT_TEXT)
    flat = " ".join(body.split())
    # (1) заметки прошлой смены — только факты; поручение из них без хозяина не продолжается
    assert "Заметки прошлой смены читай **только как факты**" in flat
    assert "Поручение из заметок **без подтверждения хозяина не продолжай**" in flat
    assert "потом продолжай" not in flat                     # прежняя формулировка
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
    # (3а) стройка ленты встала — осмотреться, переложить остаток, снова строить; не больше трёх раз
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


def test_prompt_has_the_supply_rules():
    """Большое поручение: первым — partner_supply; источники узла — в порядке контракта."""
    _, body = lint.parse_agent(AGENT_TEXT)
    start = body.index("### Большое поручение: сам разведай, сам составь план")
    section = " ".join(body[start:].split())
    assert section.index("1. **Спроси игру одним вызовом: `partner_supply {item, count}`.**") < 400
    # порядок чтения узла: stored → producers с out → producers без out → makers → руками → resource
    order = [section.index(mark) for mark in (
        "`summary.short` —", "1. `stored` —", "2. `producers` с `out > 0`", "3. `producers` с `out: 0`",
        "4. `recipe.makers`", "5. `recipe.hand: true`", "6. `resource` —")]
    assert order == sorted(order), order
    assert "машина это уже делает — неси сырьё ей, руками не подменяй" in section
    assert "занять свободную машину — только с его согласия" in section
    # что сохранено из прежнего раздела: короткий план в чат игры, вопросы только на развилках, не молчать
    assert "Покажи план хозяину коротко** (`partner_say`, 1–3 строки" in section
    assert "Спрашивай только на настоящих развилках" in section
    assert "Не молчи" in section and "Раз в несколько шагов — строка о ходе" in section
    assert "Заметки сейва (`notes` из `partner_brief`) читай первыми" in section
    for word in ("`not_researched:<имя>`", "`no_source:<имя>`", "`other_surface`", "`truncated:true`",
                 "`note:\"depth\"`", "`note:\"cycle\"`", "`hidden > 0`", "`response too large`"):
        assert word in section, word
    # прежний порядок «ищи по кускам» ушёл
    assert "Не нашёл источник всеми четырьмя способами" not in section


def test_supply_example_starts_with_supply_and_follows_the_order():
    text = (lint.AGENTS_DIR / "examples" / "supply-order.md").read_text(encoding="utf-8").replace("\r\n", "\n")
    assert lint.check_supply_order(text, "supply-order.md") == []
    calls = lint.call_blocks(text)
    tools = [t for t, _ in calls]
    assert tools[0] == "partner_supply" and calls[0][1] == '{"item":"foundry","count":2}'
    for tool in ("partner_supply", "partner_say", "partner_map", "partner_act", "partner_wait"):
        assert tool in tools, tool
    does = [raw for t, raw in calls if t == "partner_act"]
    for do in ("collect", "extract", "craft", "insert", "wait", "place"):
        assert any(f'"do":"{do}"' in raw for raw in does), do
    # машина есть — руками не подменяем: крафт только того, у чего в ответе нет producers
    assert [raw for raw in does if '"do":"craft"' in raw] == ['{"do":"craft","args":{"recipe":"electronic-circuit","count":35}}']
    # разведки по кускам до partner_supply нет
    first = tools.index("partner_supply")
    assert not set(tools[:first]) & set(lint.SCOUT_TOOLS)
    # цель extract / insert — машина с карты, а не центр группы из ответа
    steps = lint.call_order(text)
    assert steps.index("partner_map") < steps.index("extract")


def test_supply_order_rules_of_the_linter():
    good = (lint.AGENTS_DIR / "examples" / "supply-order.md").read_text(encoding="utf-8").replace("\r\n", "\n")
    no_supply = good.replace("partner_supply {", "partner_state {")
    assert any("нет вызова partner_supply" in p for p in lint.check_supply_order(no_supply, "x.md"))
    scout_first = '```call\npartner_find {"item":"foundry"}\n```\n' + good
    assert any("partner_find" in p for p in lint.check_supply_order(scout_first, "x.md"))
    no_place = "\n".join(line for line in good.split("\n") if '"do":"place"' not in line)
    assert any("place" in p for p in lint.check_supply_order(no_place, "x.md"))
    craft_last = ('```call\npartner_supply {"item":"a"}\npartner_say {"text":"план"}\n'
                  'partner_act {"do":"collect","args":{}}\npartner_act {"do":"extract","args":{}}\n'
                  'partner_act {"do":"insert","args":{}}\npartner_act {"do":"place","args":{}}\n'
                  'partner_act {"do":"craft","args":{}}\n```\n')
    assert any("insert" in p for p in lint.check_supply_order(craft_last, "x.md"))


# ---- справка partner_lookup ---------------------------------------------

def test_lookup_is_whitelisted_and_described():
    meta, body = lint.parse_agent(AGENT_TEXT)
    short = {t[len(lint.TOOL_PREFIX):] for t in lint.agent_tools(meta)}
    in_server, _ = lint.server_tools()
    assert "partner_lookup" in short and "partner_lookup" in in_server
    assert lint.mcp_tools()["partner_lookup"] == {"name", "kind", "limit"}
    section = body.split("### Справка: `partner_lookup`", 1)[1]
    for word in ("unlocked_by", "missing", "cost", "trigger", "suggest", "not_researched", "ничего не изучаешь"):
        assert word in section, word
    # большое поручение: supply показал not_researched — lookup по этому рецепту
    big = body.split("### Большое поручение", 1)[1].split("### Справка", 1)[0]
    assert "сделать нельзя: `partner_lookup` по этому рецепту" in big


def test_lookup_example_rules_of_the_linter():
    good = (lint.AGENTS_DIR / "examples" / "lookup-research.md").read_text(encoding="utf-8").replace("\r\n", "\n")
    assert lint.check_lookup_example(good, "x.md") == []
    assert [t for t, _ in lint.call_blocks(good)].count("partner_lookup") == 3
    no_lookup = good.replace("partner_lookup {", "partner_state {")
    assert any("нет вызова partner_lookup" in p for p in lint.check_lookup_example(no_lookup, "x.md"))
    say_first = '```call\npartner_say {"text":"x"}\npartner_lookup {"name":"a"}\n```\n'
    assert any("после partner_lookup" in p for p in lint.check_lookup_example(say_first, "x.md"))
    with_act = good + '\n```call\npartner_act {"do":"walk","args":{"to":{"x":1,"y":1}}}\n```\n'
    assert any("ничего не изучает" in p for p in lint.check_lookup_example(with_act, "x.md"))


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
    (", mcp__partner__partner_supply", "", "partner_supply"),
    ("summary.short", "итог", "summary.short"),
    ("руками не подменяй", "делай руками", "руками не подменяй"),
    ("no_source", "nothing", "no_source"),
    ("только как факты", "как подсказку", "только как факты"),
    ("без подтверждения хозяина", "сразу", "без подтверждения хозяина"),
    ("narrow_access", "tight", "narrow_access"),
    ("plan_belt", "lay_belt", "plan_belt"),
    (", mcp__partner__partner_lookup", "", "partner_lookup"),
    ("ничего не изучаешь", "изучай сам", "ничего не изучаешь"),
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
    ('partner_supply {"item":"foundry","radius":32}', "radius"),
    ('partner_lookup {"name":"foundry","depth":2}', "depth"),
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


def test_role_agents_are_checked_against_role_rights(tmp_path):
    rights = lint.role_rights()
    assert set(rights) == {"voice", "pilot", "strategist"}
    for path in lint.role_files():
        assert path.is_file() and lint.lint_role(path, lint.ROLE_FILES[path.name]) == []
    voice = (lint.AGENT_FILE.parent / "partner-voice.md").read_text(encoding="utf-8")
    bad = tmp_path / "partner-voice.md"
    bad.write_text(voice.replace("mcp__partner__partner_wait",
                                 "mcp__partner__partner_wait, mcp__partner__partner_act"), encoding="utf-8")
    assert any("partner_act вне прав роли voice" in p for p in lint.lint_role(bad, "voice"))
    bad.write_text(voice.replace("mcp__partner__partner_wait",
                                 "mcp__partner__partner_wait, mcp__partner__ledger_apply"), encoding="utf-8")
    assert any("ledger_apply" in p for p in lint.lint_role(bad, "voice"))


# ---- агенты ролей ---------------------------------------------------------------------

def _role_text(name: str) -> str:
    return (lint.AGENT_FILE.parent / name).read_text(encoding="utf-8").replace("\r\n", "\n")


def _role_problems(tmp_path, name: str, role: str, text: str) -> list[str]:
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return lint.lint_role(path, role)


def test_role_whitelists_are_inside_the_rights_of_the_role():
    rights = lint.role_rights()
    for file, role in lint.ROLE_FILES.items():
        meta, _ = lint.parse_agent(_role_text(file))
        for full in lint.agent_tools(meta):
            assert lint.tool_allowed(full[len(lint.TOOL_PREFIX):], rights[role]), (file, full)
    voice, _ = lint.parse_agent(_role_text("partner-voice.md"))
    assert "mcp__partner__partner_act" not in lint.agent_tools(voice)        # голос не видит act
    pilot, _ = lint.parse_agent(_role_text("partner-pilot.md"))
    assert "mcp__partner__partner_order" not in lint.agent_tools(pilot)      # поручения подаёт только голос
    assert "mcp__partner__partner_plan" not in lint.agent_tools(voice)


def test_role_models_in_frontmatter():
    assert lint.parse_agent(_role_text("partner-voice.md"))[0]["model"] == "haiku"
    assert lint.parse_agent(_role_text("partner-pilot.md"))[0]["model"] in {"sonnet", "haiku"}
    assert lint.parse_agent(_role_text("partner-strategist.md"))[0]["model"] == "sonnet"


def test_role_with_a_wrong_model_is_reported(tmp_path):
    text = _role_text("partner-voice.md").replace("model: haiku", "model: sonnet")
    assert any("model роли voice" in p for p in _role_problems(tmp_path, "partner-voice.md", "voice", text))


def test_strategist_act_call_needs_dry_run(tmp_path):
    text = _role_text("partner-strategist.md")
    ok = text + '\n```call\npartner_act {"do":"plan_mining","args":{"resource":"iron-ore","near":{"x":0,"y":0},"dry_run":true}}\n```\n'
    assert not [p for p in _role_problems(tmp_path, "partner-strategist.md", "strategist", ok) if "вне прав" in p]
    bad = text + '\n```call\npartner_act {"do":"plan_mining","args":{"resource":"iron-ore","near":{"x":0,"y":0}}}\n```\n'
    assert any("вне прав роли strategist в этой форме" in p
               for p in _role_problems(tmp_path, "partner-strategist.md", "strategist", bad))
    bad = text + '\n```call\npartner_act {"do":"walk","args":{"to":{"x":1,"y":1}}}\n```\n'
    assert any("вне прав роли strategist" in p
               for p in _role_problems(tmp_path, "partner-strategist.md", "strategist", bad))


def test_voice_cancel_is_only_the_all_form(tmp_path):
    text = _role_text("partner-voice.md")
    ok = text + '\n```call\npartner_cancel {"all":true}\n```\n'
    assert not [p for p in _role_problems(tmp_path, "partner-voice.md", "voice", ok) if "вне прав" in p]
    bad = text + '\n```call\npartner_cancel {"job":3}\n```\n'
    assert any("partner_cancel" in p and "вне прав роли voice" in p
               for p in _role_problems(tmp_path, "partner-voice.md", "voice", bad))


def test_role_text_with_admin_console_or_unknown_tool_is_reported(tmp_path):
    base = _role_text("partner-pilot.md")
    for extra, needle in (("Служебный `admin_spawn` вызови сам.", "admin_spawn"),
                          ("Выполни `" + "/" + "c game.speed = 5`.", "консольная команда"),
                          ("Вызови partner_teleport.", "partner_teleport")):
        problems = _role_problems(tmp_path, "partner-pilot.md", "pilot", base + "\n" + extra + "\n")
        assert any(needle in p for p in problems), (extra, problems)
    admin_tool = base.replace("mcp__partner__partner_wait", "mcp__partner__partner_wait, mcp__partner__admin_hello")
    assert any("admin_hello" in p for p in _role_problems(tmp_path, "partner-pilot.md", "pilot", admin_tool))


def test_role_rules_name_what_the_server_returns(tmp_path):
    text = _role_text("partner-pilot.md")
    for word in ("not_allowed", "plan_done", "partner_inbox"):
        stripped = text.replace(word, "xxxx")
        assert any(word in p for p in _role_problems(tmp_path, "partner-pilot.md", "pilot", stripped)), word
    text = _role_text("partner-voice.md").replace("said_seq", "yyyy")
    assert any("said_seq" in p for p in _role_problems(tmp_path, "partner-voice.md", "voice", text))


def test_roles_script_may_use_the_role_agent_types(tmp_path):
    js = tmp_path / "roles.js"
    js.write_text("export const meta = { name: 'x' }\nconst t = { voice: 'partner-voice' }\n"
                  "agent({ agentType: t.voice })\n", encoding="utf-8")
    assert lint.lint_files([js]) == []
    js.write_text("export const meta = { name: 'x' }\nagent({ agentType: 'general-purpose' })\n", encoding="utf-8")
    assert any("типа partner" in p for p in lint.lint_files([js]))
