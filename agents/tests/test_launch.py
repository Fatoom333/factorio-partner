"""Запуск напарника (agents/launch.py): порядок операций, ключи, отказы.

Скрипт ходит в мод служебными функциями ``admin_*`` настоящего ``factorio_partner.core.Core``
(docs/MCP.md); под ядром — фейковый мост, который помнит, что ушло бы в игру."""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from factorio_partner.core import Core
from factorio_partner.errors import PartnerError

import launch


class FakeBridge:
    """Мост сервера: помнит запросы, отвечает по таблице ``errors`` или успехом."""

    def __init__(self, hello=None, errors=None, helper_list=None):
        self.calls: list[tuple[str, dict, str | None]] = []
        self.hello = {"proto": 1, "owner": "Owner", "helpers": [], "module_errors": 0, **(hello or {})}
        self.errors = errors or {}
        self.helper_list = helper_list or []
        self.closed = False

    def on_reload(self, callback):
        pass

    async def close(self):
        self.closed = True

    async def request(self, op, args=None, helper=None, channel="cmd", **_):
        self.calls.append((op, dict(args or {}), helper))
        code = self.errors.get((op, helper)) or self.errors.get(op)
        if code == "transport_timeout":
            raise PartnerError(code, "no answer")
        if code:
            return {"v": 1, "ok": False, "error": {"code": code, "text": "отказ"}}
        data = {"hello": self.hello,
                "helper_list": {"helpers": self.helper_list},
                "helper_limit": {"max": (args or {}).get("max"), "alive": 0},
                "helper_spawn": {"helper": helper, "unit_number": 7, "surface": "nauvis", "pos": {"x": 1, "y": 2}},
                "helper_attach": {"helper": helper, "surface": "nauvis", "pos": {"x": 3, "y": 4}}}[op]
        return {"v": 1, "ok": True, "tick": 100, "seq": 5, "data": data}

    @property
    def ops(self):
        return [c[0] for c in self.calls]


def make_cfg(tmp_path: Path):
    home = tmp_path / "home"
    return SimpleNamespace(home=home, helpers_file=home / "helpers.json")


def run_launch(tmp_path, n=1, body="character", players=(), bridge=None, env=None, ids=None):
    said: list[str] = []
    bridge = bridge or FakeBridge()
    cfg = make_cfg(tmp_path)
    core = Core(cfg, bridge)
    result = asyncio.run(launch.launch(cfg, n, body, list(players), core=core, ids=ids,
                                       env=env or {"FP_RCON_PORT": "27015"}, python="python", say=said.append))
    return result, bridge, cfg, said


# ---- вопросы игроку -------------------------------------------------------------------

def ns(**kw):
    return argparse.Namespace(**{"helpers": None, "body": None, "players": None, "player": None, "helper": None,
                                 **kw})


def test_flags_are_used_without_questions():
    assert launch.ask_missing(ns(helpers="3", body="character"), None) == (3, "character", [])
    assert launch.ask_missing(ns(helpers="2", body="player", players="Bob, Eve"), None) == (2, "player", ["Bob", "Eve"])


def test_contract_flags_helper_and_player():
    """MCP.md: `--helper <id>` и `--player <имя>` (можно несколько раз); `--players` — то же списком."""
    parse = launch.build_parser().parse_args
    a = parse(["--body", "player", "--helper", "h2", "--player", "Bob"])
    assert launch.ask_missing(a, None) == (1, "player", ["Bob"]) and launch.parse_ids(a.helper) == ["h2"]
    a = parse(["--helpers", "3", "--body", "player", "--helper", "a", "--helper", "b", "--player", "Bob",
               "--players", "Eve"])
    assert launch.ask_missing(a, None) == (3, "player", ["Bob", "Eve"])
    with pytest.raises(launch.LaunchError, match="разрешено 1"):
        launch.ask_missing(parse(["--helpers", "1", "--body", "character", "--helper", "a", "--helper", "b"]), None)
    for bad in (["H1"], ["h1", "h1"], ["x" * 17], ["../h"], [""]):
        with pytest.raises(launch.LaunchError):
            launch.parse_ids(bad)
    assert launch.parse_ids(None) == []


def test_no_flag_and_nobody_to_ask_is_refused():
    with pytest.raises(launch.LaunchError, match="спроси игрока"):
        launch.ask_missing(ns(body="character"), None)
    with pytest.raises(launch.LaunchError, match="спроси игрока"):
        launch.ask_missing(ns(helpers="1"), None)


def test_player_is_asked_for_missing_answers():
    asked: list[str] = []
    answers = iter(["2", "", ])

    def ask(q):
        asked.append(q)
        return next(answers)

    assert launch.ask_missing(ns(), ask) == (2, "character", [])
    assert len(asked) == 2 and "Сколько помощников" in asked[0] and "тела" in asked[1]


@pytest.mark.parametrize("value", ["0", "17", "-1", "два", "1.5", ""])
def test_helper_count_bounds(value):
    with pytest.raises(launch.LaunchError):
        launch.parse_helpers(value)


def test_body_and_players_checks():
    assert launch.parse_body(" Player ") == "player"
    with pytest.raises(launch.LaunchError):
        launch.parse_body("ghost")
    for bad in ("", "Bob", "Bob,Bob", 'Bob,E"ve', "Bob,E\nve"):
        with pytest.raises(launch.LaunchError):
            launch.parse_players(bad, 2)


# ---- ключи и файлы ---------------------------------------------------------------------

def test_keys_are_created_kept_and_long_enough(tmp_path):
    f = tmp_path / "home" / "helpers.json"
    first = launch.ensure_keys(f, ["h1", "h2"])
    assert all(len(k) >= 32 for k in first.values()) and first["h1"] != first["h2"]
    again = launch.ensure_keys(f, ["h1", "h2", "h3"])
    assert again["h1"] == first["h1"] and again["h2"] == first["h2"] and len(again["h3"]) >= 32
    assert set(json.loads(f.read_text(encoding="utf-8"))) == {"h1", "h2", "h3"}


def test_weak_or_broken_keys_are_replaced_and_other_entries_kept(tmp_path):
    f = tmp_path / "helpers.json"
    f.write_text(json.dumps({"h1": "short", "old": "x" * 40}), encoding="utf-8")
    keys = launch.ensure_keys(f, ["h1"])
    assert len(keys["h1"]) >= 32
    assert json.loads(f.read_text(encoding="utf-8"))["old"] == "x" * 40
    f.write_text("не json", encoding="utf-8")
    assert len(launch.ensure_keys(f, ["h1"])["h1"]) >= 32


def test_keys_of_roles_are_kept(tmp_path):
    f = tmp_path / "helpers.json"
    roles = {"pilot": "p" * 40, "voice": "v" * 40, "strategist": "s" * 40, "note": "x"}
    f.write_text(json.dumps({"h1": roles}), encoding="utf-8")
    before = f.stat().st_mtime_ns
    assert launch.ensure_keys(f, ["h1"]) == {"h1": "p" * 40}
    assert json.loads(f.read_text(encoding="utf-8"))["h1"] == roles
    assert f.stat().st_mtime_ns == before            # nothing to add: the file is not rewritten
    # a pilot key shared with another role is replaced; the other fields of the entry stay as they are
    f.write_text(json.dumps({"h1": {"pilot": "k" * 40, "voice": "k" * 40, "strategist": "short"}}),
                 encoding="utf-8")
    keys = launch.ensure_keys(f, ["h1"])
    entry = json.loads(f.read_text(encoding="utf-8"))["h1"]
    assert keys["h1"] == entry["pilot"] != "k" * 40 and len(entry["pilot"]) >= 32
    assert entry["voice"] == "k" * 40 and entry["strategist"] == "short"
    f.write_text(json.dumps({"h1": {"voice": "v" * 40}}), encoding="utf-8")
    keys = launch.ensure_keys(f, ["h1"])
    entry = json.loads(f.read_text(encoding="utf-8"))["h1"]
    assert entry == {"voice": "v" * 40, "pilot": keys["h1"]}


def test_style_is_installed_once(tmp_path):
    home = tmp_path / "home"
    assert launch.install_style(home) is True
    assert "По-русски" in (home / "style.md").read_text(encoding="utf-8")
    (home / "style.md").write_text("свой стиль", encoding="utf-8")
    assert launch.install_style(home) is False
    assert (home / "style.md").read_text(encoding="utf-8") == "свой стиль"


def test_mcp_config_has_server_partner_no_admin_no_secrets():
    cfg = launch.mcp_config({"FP_RCON_PORT": "27015", "FP_RCON_PASSWORD_FILE": "pw.txt",
                             "SECRET_TOKEN": "zzz", "FP_FORGE": ""}, "py")
    server = cfg["mcpServers"]["partner"]
    assert list(cfg["mcpServers"]) == ["partner"]
    assert server["args"] == ["-m", "factorio_partner.server"] and "--admin" not in server["args"]
    assert server["env"] == {"FP_RCON_PORT": "27015", "FP_RCON_PASSWORD_FILE": "pw.txt"}



def test_mcp_config_passes_budget_and_notes_env():
    env = {"FP_BUDGET_FILE": "b.json", "FP_BUDGET_WARN": "70", "FP_BUDGET_STOP": "85",
           "FP_BUDGET_WEEK_STOP": "95", "FP_BUDGET_MAX_AGE": "600", "FP_NOTES_DIR": "notes",
           "FP_SAVE_NAME": "run-1", "FP_BUDGET_OTHER": "x"}
    assert launch.mcp_config(env, "py")["mcpServers"]["partner"]["env"] == {
        k: v for k, v in env.items() if k != "FP_BUDGET_OTHER"}

# ---- мод ---------------------------------------------------------------------------------

def test_character_launch_sequence_and_files(tmp_path, capsys):
    result, bridge, cfg, _ = run_launch(tmp_path, n=2)
    assert bridge.calls == [("hello", {}, None), ("helper_limit", {"max": 2}, None),
                            ("helper_spawn", {}, "h1"), ("helper_spawn", {}, "h2")]
    keys = json.loads(cfg.helpers_file.read_text(encoding="utf-8"))
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    assert [h["id"] for h in session["helpers"]] == ["h1", "h2"]
    for h in session["helpers"]:
        assert f"helper: {h['id']}" in h["prompt"] and f"key: {keys[h['id']]}" in h["prompt"]
        assert "module_errors: 0" in h["prompt"] and "body: character" in h["prompt"]
    mcp = Path(result["mcp_config"]).read_text(encoding="utf-8")
    assert not any(k in mcp for k in keys.values())
    # результат для печати и сама печать — без ключей
    assert not any(k in json.dumps(result, default=str) for k in keys.values())
    assert capsys.readouterr().out == ""


def test_player_body_attaches_named_players(tmp_path):
    result, bridge, _, _ = run_launch(tmp_path, n=2, body="player", players=["Bob", "Eve"])
    assert bridge.calls[2:] == [("helper_attach", {"player": "Bob"}, "h1"),
                                ("helper_attach", {"player": "Eve"}, "h2")]
    assert "helper_spawn" not in bridge.ops
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    assert session["helpers"][1]["player"] == "Eve" and "body: player" in session["helpers"][1]["prompt"]


def test_alive_body_is_reused_the_other_is_spawned(tmp_path):
    """Живое тело с этим id мод называет сам (`helper_exists`): его берём, второго не создаём."""
    bridge = FakeBridge(hello={"helpers": ["h1", "h2"]}, errors={("helper_spawn", "h1"): "helper_exists"})
    result, bridge, _, said = run_launch(tmp_path, n=2, bridge=bridge)
    assert bridge.calls[2:] == [("helper_spawn", {}, "h1"), ("helper_spawn", {}, "h2")]
    assert result["helpers"] == ["h1", "h2"] and any("h1" in s for s in said) and not any("h2" in s for s in said)


def test_explicit_helper_ids(tmp_path):
    result, bridge, cfg, _ = run_launch(tmp_path, n=3, ids=["scout", "h7"])
    assert bridge.calls == [("hello", {}, None), ("helper_limit", {"max": 3}, None),
                            ("helper_spawn", {}, "scout"), ("helper_spawn", {}, "h7")]
    assert result["helpers"] == ["scout", "h7"]
    assert set(json.loads(cfg.helpers_file.read_text(encoding="utf-8"))) == {"scout", "h7"}


def test_launch_goes_through_the_admin_functions_of_core(tmp_path):
    """MCP.md: скрипт ходит через `admin_*` функции core.py, а не мимо них."""
    seen: list[tuple] = []

    class SpyCore(Core):
        async def admin_hello(self):
            seen.append(("admin_hello",))
            return await super().admin_hello()

        async def admin_limit(self, max):  # noqa: A002
            seen.append(("admin_limit", max))
            return await super().admin_limit(max)

        async def admin_spawn(self, helper):
            seen.append(("admin_spawn", helper))
            return await super().admin_spawn(helper)

        async def admin_attach(self, helper, player):
            seen.append(("admin_attach", helper, player))
            return await super().admin_attach(helper, player)

    def go(body, players, sub):
        bridge = FakeBridge()
        cfg = make_cfg(tmp_path / sub)
        asyncio.run(launch.launch(cfg, 2, body, players, core=SpyCore(cfg, bridge), env={}, python="python",
                                  say=lambda _t: None))
        return bridge

    bridge = go("character", [], "a")
    assert seen == [("admin_hello",), ("admin_limit", 2), ("admin_spawn", "h1"), ("admin_spawn", "h2")]
    assert len(bridge.calls) == len(seen)             # в мод ушло ровно то, что прошло через ядро
    seen.clear()
    go("player", ["Bob", "Eve"], "b")
    assert seen[2:] == [("admin_attach", "h1", "Bob"), ("admin_attach", "h2", "Eve")]
    # сам скрипт моста не создаёт и запросов в мод не шлёт
    source = Path(launch.__file__).read_text(encoding="utf-8")
    assert "Bridge" not in source and ".request(" not in source


def test_core_checks_apply_before_the_mod(tmp_path):
    """Проверки ядра (имя игрока) срабатывают до похода в мод."""
    bridge = FakeBridge()
    with pytest.raises(launch.LaunchError, match="helper_attach"):
        run_launch(tmp_path, body="player", players=["Bob\tEve"], bridge=bridge)
    assert bridge.ops == ["hello", "helper_limit"]


def test_mod_unavailable_is_not_reported_as_a_refusal(tmp_path):
    for op in ("hello", "helper_limit", "helper_spawn"):
        with pytest.raises(PartnerError) as ei:
            run_launch(tmp_path / op, bridge=FakeBridge(errors={op: "transport_timeout"}))
        assert ei.value.code == "transport_timeout"
        assert not (tmp_path / op / "home" / "launch" / "session.json").exists()


def test_module_errors_reach_the_agent(tmp_path):
    result, _, _, _ = run_launch(tmp_path, bridge=FakeBridge(hello={"module_errors": 3}))
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    assert result["module_errors"] == 3 and "module_errors: 3" in session["helpers"][0]["prompt"]


@pytest.mark.parametrize("errors,n,body,match", [
    ({"helper_spawn": "cooldown"}, 1, "character", "10 секунд"),
    ({"helper_spawn": "no_player"}, 1, "character", "хозяин должен быть в игре"),
    ({"helper_spawn": "limit"}, 1, "character", "helper_spawn"),
    ({"helper_attach": "no_player"}, 1, "player", "должен быть в игре"),
    ({"helper_attach": "helper_exists"}, 1, "player", "уже заняты"),
    ({"helper_attach": "internal"}, 1, "player", "helper_attach"),
    ({"hello": "unknown_op"}, 1, "character", "hello"),
    ({"helper_limit": "limit"}, 1, "character", "больше занятых мест"),
    ({"helper_limit": "unknown_op"}, 2, "character", "helper_limit"),
    ({"helper_limit": "internal"}, 1, "character", "helper_limit"),
])
def test_mod_refusals_stop_the_launch(tmp_path, errors, n, body, match):
    bridge = FakeBridge(errors=errors)
    with pytest.raises(launch.LaunchError, match=match):
        run_launch(tmp_path, n=n, body=body, players=["Bob", "Eve"][:n], bridge=bridge)
    assert not (tmp_path / "home" / "launch" / "session.json").exists()


def test_old_mod_without_helper_limit_is_ok_for_one_helper(tmp_path):
    _, bridge, _, said = run_launch(tmp_path, bridge=FakeBridge(errors={"helper_limit": "unknown_op"}))
    assert "helper_spawn" in bridge.ops and any("helper_limit" in s for s in said)


def test_wrong_protocol_or_no_owner_is_refused(tmp_path):
    for hello in ({"proto": 2}, {"owner": None}):
        bridge = FakeBridge(hello=hello)
        with pytest.raises(launch.LaunchError):
            run_launch(tmp_path, bridge=bridge)
        assert bridge.ops == ["hello"]


def test_only_mod_operations_are_sent(tmp_path):
    """Запуск ходит в игру только операциями мода (их шлёт ядро сервера, мост сам ставит /partner)."""
    _, bridge, _, _ = run_launch(tmp_path, n=3, bridge=FakeBridge(hello={"helpers": ["h9"]}))
    assert set(bridge.ops) <= {"hello", "helper_limit", "helper_spawn", "helper_attach"}
    source = Path(launch.__file__).read_text(encoding="utf-8")
    assert "RconConnection" not in source and ".execute(" not in source and "subprocess" not in source


def test_main_refuses_non_loopback_rcon(tmp_path, monkeypatch, capsys):
    pytest.importorskip("factorio_partner")
    monkeypatch.setenv("FP_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("FP_RCON_HOST", "example.org")
    assert launch.main(["--helpers", "1", "--body", "character"]) == 2
    assert "127.0.0.1" in capsys.readouterr().err
    assert not (tmp_path / "home").exists()


def test_main_without_answers_exits_with_question(monkeypatch, capsys):
    monkeypatch.setattr("sys.stdin", SimpleNamespace(isatty=lambda: False))
    assert launch.main([]) == 2
    assert "спроси игрока" in capsys.readouterr().err


# ---- режим ролей ---------------------------------------------------------------------

def run_roles(tmp_path, n=1, pilot_model="sonnet", ids=None, body="character", players=()):
    said: list[str] = []
    cfg = make_cfg(tmp_path)
    core = Core(cfg, FakeBridge())
    result = asyncio.run(launch.launch(cfg, n, body, list(players), core=core, ids=ids, roles=True,
                                       pilot_model=pilot_model, env={"FP_RCON_PORT": "27015"},
                                       python="python", say=said.append))
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    return result, session, cfg


def all_keys(cfg):
    data = json.loads(cfg.helpers_file.read_text(encoding="utf-8"))
    return [k for e in data.values() for k in ([e] if isinstance(e, str) else e.values())]


def test_role_keys_one_voice_one_strategist_a_pilot_per_body(tmp_path):
    f = tmp_path / "helpers.json"
    f.write_text(json.dumps({"h1": "o" * 40, "other": "x" * 40}), encoding="utf-8")
    keys = launch.ensure_role_keys(f, ["h1", "h2", "h3"])
    assert keys["pilots"]["h1"] == "o" * 40 and set(keys["pilots"]) == {"h1", "h2", "h3"}
    every = [keys["voice"], keys["strategist"], keys["host"], *keys["pilots"].values()]
    assert len(set(every)) == 6 and all(len(k) >= 32 for k in every)
    data = json.loads(f.read_text(encoding="utf-8"))
    assert data["*"] == {"voice": keys["voice"], "strategist": keys["strategist"], "host": keys["host"]}
    assert data["other"] == "x" * 40 and data["h2"] == {"pilot": keys["pilots"]["h2"]}
    assert launch.ensure_role_keys(f, ["h1", "h2", "h3"]) == keys     # второй запуск ключей не меняет


def test_role_keys_from_an_old_file_of_three_roles_per_helper(tmp_path):
    f = tmp_path / "helpers.json"
    old = {"pilot": "p" * 40, "voice": "v" * 40, "strategist": "s" * 40, "note": "x"}
    f.write_text(json.dumps({"h1": old, "*": {"voice": "v" * 40}}), encoding="utf-8")
    keys = launch.ensure_role_keys(f, ["h1"])
    data = json.loads(f.read_text(encoding="utf-8"))
    # ключи ролей самого помощника убраны (их заменяет общая запись), ключ пилота остался
    assert data["h1"] == {"note": "x", "pilot": "p" * 40} == {"note": "x", "pilot": keys["pilots"]["h1"]}
    # общий ключ, совпавший с другим ключом файла, негоден — выдан новый
    assert keys["voice"] not in ("p" * 40, "v" * 40) and keys["strategist"] != "s" * 40


def test_roles_launch_session_one_voice_one_strategist_three_pilots(tmp_path):
    result, session, cfg = run_roles(tmp_path, n=3, body="player", players=["Bob", "Eve", "Ann"])
    data = json.loads(cfg.helpers_file.read_text(encoding="utf-8"))
    assert session["mode"] == "roles" and session["pilot_model"] == "sonnet"
    assert [h["id"] for h in session["helpers"]] == ["h1", "h2", "h3"]
    for role in ("voice", "strategist"):
        entry = session[role]
        assert entry["agent"] == f"partner-{role}" and f"role: {role}" in entry["prompt"]
        assert f"key: {data['*'][role]}" in entry["prompt"]
        assert "helpers: h1 «Claude», h2 «Claude h2», h3 «Claude h3»" in entry["prompt"]
        assert Path(entry["mcp_config"]).name == f"mcp-{role}.json" and Path(entry["mcp_config"]).is_file()
    for h in session["helpers"]:
        assert "prompt" not in h and set(h["roles"]) == {"pilot"}
        pilot = h["roles"]["pilot"]
        assert pilot["agent"] == "partner-pilot" and f"helper: {h['id']}" in pilot["prompt"]
        assert f"key: {data[h['id']]['pilot']}" in pilot["prompt"]
    # в сообщении каждого агента — только его ключ
    prompts = [session["voice"]["prompt"], session["strategist"]["prompt"]] + \
        [h["roles"]["pilot"]["prompt"] for h in session["helpers"]]
    for text in prompts:
        assert sum(k in text for k in all_keys(cfg)) == 1
    assert "персонаж игрока «Eve»" in session["helpers"][1]["roles"]["pilot"]["prompt"]
    assert [(a["helper"], a["role"]) for a in result["agents"]] == \
        [("*", "voice"), ("*", "strategist"), ("h1", "pilot"), ("h2", "pilot"), ("h3", "pilot")]


def test_roles_launch_for_one_helper(tmp_path):
    _, session, cfg = run_roles(tmp_path)
    assert [h["id"] for h in session["helpers"]] == ["h1"]
    assert "helper: h1" in session["voice"]["prompt"] and "helpers: h1 «Claude»" in session["voice"]["prompt"]
    assert set(json.loads(cfg.helpers_file.read_text(encoding="utf-8"))) == {"*", "h1"}


def test_roles_models_and_launch_summary_have_no_keys(tmp_path):
    result, session, cfg = run_roles(tmp_path, pilot_model="haiku")
    models = {a["role"]: a["model"] for a in result["agents"]}
    assert models == {"voice": "haiku", "pilot": "haiku", "strategist": "sonnet"}
    assert {a["agent"] for a in result["agents"]} == {"partner-voice", "partner-pilot", "partner-strategist"}
    assert not any(k in json.dumps(result, default=str) for k in all_keys(cfg))
    result, _, _ = run_roles(tmp_path / "again")
    assert {a["role"]: a["model"] for a in result["agents"]}["pilot"] == "sonnet"


def test_role_mcp_configs_have_no_secrets_and_no_admin(tmp_path):
    result, session, cfg = run_roles(tmp_path, n=2)
    entries = [session["voice"], session["strategist"]] + [h["roles"]["pilot"] for h in session["helpers"]]
    for entry in entries:
        text = Path(entry["mcp_config"]).read_text(encoding="utf-8")
        assert not any(k in text for k in all_keys(cfg)) and "--admin" not in text
        assert list(json.loads(text)["mcpServers"]) == ["partner"]


def test_strategist_gets_the_knowledge_others_do_not(tmp_path):
    _, session, _ = run_roles(tmp_path)
    assert "=== справка: factory-math.md ===" in session["strategist"]["prompt"]
    assert "=== справка: forge-blocks.md ===" in session["strategist"]["prompt"]
    assert "справка" not in session["voice"]["prompt"]
    assert "справка" not in session["helpers"][0]["roles"]["pilot"]["prompt"]


def test_role_keys_open_the_server(tmp_path):
    """Ключи, выданные запуском, сервер принимает в их ролях: общий голос — для любого тела."""
    _, session, cfg = run_roles(tmp_path, n=3)
    core = Core(SimpleNamespace(helpers_file=cfg.helpers_file), FakeBridge())
    data = json.loads(cfg.helpers_file.read_text(encoding="utf-8"))
    for hid in ("h1", "h2", "h3"):
        assert core.check_access(hid, data["*"]["voice"]) == "voice"
        assert core.check_access(hid, data["*"]["strategist"]) == "strategist"
        assert core.check_access(hid, data[hid]["pilot"]) == "pilot"
    with pytest.raises(PartnerError):
        core.check_access("h2", data["h1"]["pilot"])


def test_plain_launch_is_unchanged_by_the_roles_mode(tmp_path):
    result, _, cfg, _ = run_launch(tmp_path)
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    assert "mode" not in session and result["agents"] == [] and "prompt" in session["helpers"][0]
    assert isinstance(json.loads(cfg.helpers_file.read_text(encoding="utf-8"))["h1"], str)
    assert not (Path(result["session"]).parent / "mcp-voice.json").exists()


def test_pilot_model_is_checked():
    assert launch.parse_pilot_model(" Haiku ") == "haiku"
    with pytest.raises(launch.LaunchError):
        launch.parse_pilot_model("opus")
    ap = launch.build_parser()
    assert ap.parse_args(["--roles", "--pilot-model", "haiku"]).roles is True
    assert ap.parse_args([]).roles is False and ap.parse_args([]).pilot_model == "sonnet"


def test_role_message_refuses_an_unknown_role():
    with pytest.raises(launch.LaunchError):
        launch.role_message("admin", "h1", "k" * 40, "character", None, 1, 0)


def test_launch_roles_match_the_agent_files():
    """Тип агента и модель по умолчанию в launch.py совпадают с файлами правил."""
    import lint
    for role, (agent, model) in launch.ROLE_AGENTS.items():
        path = lint.AGENT_FILE.parent / f"{agent}.md"
        meta, _ = lint.parse_agent(path.read_text(encoding="utf-8").replace("\r\n", "\n"))
        assert meta["name"] == agent and meta["model"] == model
        assert launch.ROLE_AGENTS[role][1] in lint.ROLE_MODELS[role]
    assert set(launch.PILOT_MODELS) == lint.ROLE_MODELS["pilot"]


def test_plain_launch_drops_the_shared_entry_of_a_roles_launch(tmp_path):
    f = tmp_path / "helpers.json"
    keys = launch.ensure_role_keys(f, ["h1", "h2"])
    plain = launch.ensure_keys(f, ["h1"])
    data = json.loads(f.read_text(encoding="utf-8"))
    assert "*" not in data                                  # общих голоса и стратега больше нет
    assert plain["h1"] == keys["pilots"]["h1"] and data["h2"] == {"pilot": keys["pilots"]["h2"]}


def test_display_name_is_cleaned_as_in_the_mod(monkeypatch):
    monkeypatch.setenv("FP_HELPER_NAME", " [Bot] ")
    assert launch.display_name("h1") == "Bot" and launch.display_name("h2") == "Bot h2"
    monkeypatch.setenv("FP_HELPER_NAME", "Помощникдлинный")   # 30 байт: мод оставляет 24
    assert launch.display_name("h1") == "Помощникдлин"
    monkeypatch.setenv("FP_HELPER_NAME", "[]")
    assert launch.display_name("h1") == "Claude"


def test_host_key_goes_to_the_session_apart_from_the_roles(tmp_path):
    """Ключ диспетчера (главный чат): в общей записи и в файле сессии отдельно, ни в одном первом
    сообщении ролей; сервер принимает его только как host."""
    _, session, cfg = run_roles(tmp_path, n=2)
    data = json.loads(cfg.helpers_file.read_text(encoding="utf-8"))
    host = data["*"]["host"]
    assert session["host"]["key"] == host and session["host"]["tool"] == "partner_relay"
    assert session["host"]["helper"] == "h1"
    prompts = [session["voice"]["prompt"], session["strategist"]["prompt"]] + \
        [h["roles"]["pilot"]["prompt"] for h in session["helpers"]]
    assert not any(host in p for p in prompts)
    core = Core(SimpleNamespace(helpers_file=cfg.helpers_file), FakeBridge())
    assert core.check_access("h2", host) == "host"
