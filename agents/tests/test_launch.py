"""Запуск напарника (agents/launch.py) на фейковом мосте: порядок операций, ключи, отказы."""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

import launch


class FakeBridge:
    """Мост сервера: помнит запросы, отвечает по таблице ``errors`` или успехом."""

    def __init__(self, hello=None, errors=None, helper_list=None):
        self.calls: list[tuple[str, dict, str | None]] = []
        self.hello = {"proto": 1, "owner": "Owner", "helpers": [], "module_errors": 0, **(hello or {})}
        self.errors = errors or {}
        self.helper_list = helper_list or []

    async def request(self, op, args=None, helper=None, channel="cmd", **_):
        self.calls.append((op, dict(args or {}), helper))
        code = self.errors.get((op, helper)) or self.errors.get(op)
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


def run_launch(tmp_path, n=1, body="character", players=(), bridge=None, env=None):
    said: list[str] = []
    bridge = bridge or FakeBridge()
    cfg = make_cfg(tmp_path)
    result = asyncio.run(launch.launch(cfg, n, body, list(players), bridge=bridge,
                                       env=env or {"FP_RCON_PORT": "27015"}, python="python", say=said.append))
    return result, bridge, cfg, said


# ---- вопросы игроку -------------------------------------------------------------------

def ns(**kw):
    return argparse.Namespace(**{"helpers": None, "body": None, "players": None, **kw})


def test_flags_are_used_without_questions():
    assert launch.ask_missing(ns(helpers="3", body="character"), None) == (3, "character", [])
    assert launch.ask_missing(ns(helpers="2", body="player", players="Bob, Eve"), None) == (2, "player", ["Bob", "Eve"])


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


def test_alive_body_is_reused_dead_is_spawned(tmp_path):
    bridge = FakeBridge(hello={"helpers": ["h1", "h2"]},
                        helper_list=[{"id": "h1", "state": "alive"}, {"id": "h2", "state": "dead"}])
    _, bridge, _, said = run_launch(tmp_path, n=2, bridge=bridge)
    assert ("helper_spawn", {}, "h1") not in bridge.calls
    assert ("helper_spawn", {}, "h2") in bridge.calls
    assert any("h1" in s for s in said)


def test_helper_exists_is_fine(tmp_path):
    result, _, _, _ = run_launch(tmp_path, bridge=FakeBridge(errors={"helper_spawn": "helper_exists"}))
    assert result["helpers"] == ["h1"]


def test_module_errors_reach_the_agent(tmp_path):
    result, _, _, _ = run_launch(tmp_path, bridge=FakeBridge(hello={"module_errors": 3}))
    session = json.loads(Path(result["session"]).read_text(encoding="utf-8"))
    assert result["module_errors"] == 3 and "module_errors: 3" in session["helpers"][0]["prompt"]


@pytest.mark.parametrize("errors,n,body,match", [
    ({"helper_spawn": "cooldown"}, 1, "character", "5 минут"),
    ({"helper_spawn": "no_player"}, 1, "character", "хозяин должен быть в игре"),
    ({"helper_spawn": "limit"}, 1, "character", "helper_spawn"),
    ({"helper_attach": "no_player"}, 1, "player", "должен быть в игре"),
    ({"helper_limit": "limit"}, 1, "character", "больше живых"),
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
    """Запуск ходит в игру только операциями мода через мост (мост сам ставит /partner)."""
    _, bridge, _, _ = run_launch(tmp_path, n=3, bridge=FakeBridge(hello={"helpers": ["h9"]}))
    assert set(bridge.ops) <= {"hello", "helper_limit", "helper_list", "helper_spawn", "helper_attach"}
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
