"""Стенд волны 3 (поток K): журнал игры по `log_must_not_match`, пакет с настоящим сервером,
запуск сценария через server_client, настройки forge без личных путей в git."""
from __future__ import annotations

import json
import os
import re
import zipfile

import pytest

import live_client as lc
import pack
import server_client as sc
from conftest import PASSWORD, PC_DIR, REPO

PATTERN = r"\[factorio-partner\] .* failed"
LOG_OK = (
    "   0.001 Program arguments: \"factorio.exe\" \"--rcon-password\" \"<private>\"\n"
    "  12.500 Script @__factorio-partner__/control.lua:1: [factorio-partner] loaded\n"
    "  13.000 Info: кириллица в журнале\n"
)
LOG_BAD = LOG_OK + (
    "  20.100 Script @__factorio-partner__/scripts/core/init.lua:52: [factorio-partner] reflex flee failed: boom\n"
    "  21.100 Script @__factorio-partner__/scripts/core/init.lua:52: [factorio-partner] on_nth 60 failed: boom\n"
)


def slot(tmp_path, result, log=None, pw=PASSWORD):
    d = tmp_path / "fp-live-3"
    (d / "out").mkdir(parents=True)
    if pw is not None:
        (d / "rcon.pw").write_text(pw, encoding="utf-8")
    (d / "out" / "results-3.json").write_text(json.dumps(result, ensure_ascii=False), encoding="utf-8")
    if log is not None:
        (d / "out" / "factorio-3.log").write_bytes(log.encode("utf-8"))
    return d


def saved(d):
    return json.loads((d / "out" / "results-3.json").read_text(encoding="utf-8"))


# ------------------------------------------------------------ log_must_not_match

def test_log_patterns_shapes():
    assert lc.log_patterns(None) == []
    assert [p.pattern for p in lc.log_patterns(PATTERN)] == [PATTERN]
    assert len(lc.log_patterns(["a", "b"])) == 2
    for bad in ("", [], [""], ["a", 5], 7, {"a": 1}, "(", ["x"] * (lc.LOG_PATTERNS_MAX + 1),
                "x" * (lc.LOG_PATTERN_MAX + 1)):
        with pytest.raises(lc.LiveClientError):
            lc.log_patterns(bad)


def test_log_matches_counts_and_keeps_first_lines():
    found = lc.log_matches(LOG_BAD + LOG_BAD.splitlines()[-1] * 1 + "\n" * 3, lc.log_patterns(PATTERN), keep=1)
    assert found["count"] == 3 and len(found["lines"]) == 1
    assert found["lines"][0]["line"] == 4 and "reflex flee failed" in found["lines"][0]["text"]
    assert lc.log_matches(LOG_OK, lc.log_patterns(PATTERN)) == {"count": 0, "lines": []}
    # очень длинная строка режется, а не вешает проверку
    long_line = "x" * (lc.LOG_LINE_MAX + 50) + " [factorio-partner] op find failed"
    assert lc.log_matches(long_line, lc.log_patterns(PATTERN))["count"] == 0


def test_check_log_clean(tmp_path):
    d = slot(tmp_path, {"ok": True, "log_must_not_match": PATTERN}, LOG_OK)
    assert lc.check_log(3, str(d)) == 0
    res = saved(d)
    assert res["ok"] is True and res["log_check"] == {"ok": True, "patterns": PATTERN, "matches": 0, "lines": []}


def test_check_log_fails_a_green_scenario(tmp_path):
    d = slot(tmp_path, {"ok": True, "log_must_not_match": [PATTERN], "steps": [1]}, LOG_BAD)
    assert lc.check_log(3, str(d)) == 1
    res = saved(d)
    assert res["ok"] is False and res["steps"] == [1]            # остальной результат цел
    assert res["log_check"]["ok"] is False and res["log_check"]["matches"] == 2
    assert res["log_check"]["lines"][0]["line"] == 4
    assert any("журнал игры" in r for r in res["reasons"])


def test_check_log_nothing_to_check(tmp_path):
    d = slot(tmp_path, {"ok": True}, LOG_BAD)
    before = (d / "out" / "results-3.json").read_text(encoding="utf-8")
    assert lc.check_log(3, str(d)) == 0
    assert (d / "out" / "results-3.json").read_text(encoding="utf-8") == before


def test_check_log_missing_log_or_bad_pattern_is_red(tmp_path):
    d = slot(tmp_path, {"ok": True, "log_must_not_match": PATTERN}, None)
    assert lc.check_log(3, str(d)) == 1
    assert saved(d)["ok"] is False and "не вынесен" in saved(d)["log_check"]["text"]
    d2 = slot(tmp_path / "b", {"ok": True, "log_must_not_match": "("}, LOG_OK)
    assert lc.check_log(3, str(d2)) == 1
    assert saved(d2)["ok"] is False and "regex" in saved(d2)["log_check"]["text"]


def test_check_log_no_results(tmp_path):
    d = tmp_path / "fp-live-3"
    (d / "out").mkdir(parents=True)
    assert lc.check_log(3, str(d)) == 2
    assert lc.main(["check-log", "--slot", "3", "--dir", str(d)]) == 2


def test_check_log_never_writes_the_password(tmp_path):
    # журнал вычищает stand.ps1, но если пароль всё же просочился в совпавшую строку — в results его нет
    leaky = LOG_OK + "  30.0 [factorio-partner] op x failed: " + PASSWORD + "\n"
    d = slot(tmp_path, {"ok": True, "log_must_not_match": PATTERN}, leaky)
    assert lc.main(["check-log", "--slot", "3", "--dir", str(d)]) == 1
    raw = (d / "out" / "results-3.json").read_text(encoding="utf-8")
    assert PASSWORD not in raw and "<private>" in raw


def test_scrub_many_secrets():
    data = {"a": "pw=AAAA key=BBBB", "BBBB": ["AAAA", 1, None], "n": 5}
    assert lc._scrub(data, ["AAAA", "", "BBBB"]) == {"a": "pw=<private> key=<private>",
                                                    "<private>": ["<private>", 1, None], "n": 5}
    assert lc._scrub(data, "") is data and lc._scrub(data, []) is data
    assert lc._scrub("xAAAAx", "AAAA") == "x<private>x"


def test_every_scenario_pattern_compiles():
    """Образцы `LOG_MUST_NOT_MATCH` всех сценариев стенда — рабочие regex."""
    seen = 0
    for n in sorted(os.listdir(os.path.join(PC_DIR, "scenarios"))):
        if not n.endswith(".py"):
            continue
        with open(os.path.join(PC_DIR, "scenarios", n), "r", encoding="utf-8") as f:
            m = re.search(r'^LOG_MUST_NOT_MATCH = r"(.*)"$', f.read(), re.MULTILINE)
        if m:
            seen += 1
            assert lc.log_patterns(m.group(1)), n
    assert seen >= 4


# ------------------------------------------------------------ stand.ps1 / run-live.ps1 (статически)

def _code(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        return "\n".join(line.split("#", 1)[0] for line in f.read().splitlines())


def test_stand_checks_log_after_redacted_copy():
    code = _code(os.path.join(PC_DIR, "remote", "stand.ps1"))
    stop = code[code.index("function Invoke-Stop"):]
    assert stop.index("Copy-RedactedLog $src (Join-Path $OutDir") < stop.index("'check-log'")
    assert "'check-log', '--slot'" in stop


def test_stand_runs_server_scenarios_with_server_python():
    code = _code(os.path.join(PC_DIR, "remote", "stand.ps1"))
    run = code[code.index("function Invoke-Run"):code.index("function Invoke-Stop")]
    assert "Test-ServerRunner" in run and "'server_client.py' (Get-ServerPython)" in run
    # Python сервера проверяется до запуска игры, и чужой скрипт клиенту не подсунуть
    deploy = code[code.index("function Invoke-Deploy"):code.index("function Invoke-Run")]
    assert deploy.index("Get-ServerPython") < deploy.index("Invoke-CimMethod")
    assert "@('live_client.py', 'server_client.py') -notcontains $Script" in code


def test_run_live_fetches_server_logs():
    code = _code(os.path.join(PC_DIR, "run-live.ps1"))
    assert '"server-$Slot.log"' in code and '"calls-$Slot.jsonl"' in code


def test_local_mode_keeps_rcon_on_loopback_and_cleans_the_password():
    """-Local: сценарий на этой машине, RCON ПК — только через SSH-туннель 127.0.0.1 <-> 127.0.0.1."""
    code = _code(os.path.join(PC_DIR, "run-live.ps1"))
    run = code[code.index("function Invoke-LocalRun"):code.index("function Close-LocalRun")]
    assert '"127.0.0.1:${port}:127.0.0.1:${port}"' in run and "ExitOnForwardFailure=yes" in run
    assert "-WindowStyle Hidden" in run                       # без всплывающего окна
    assert run.index("Start-Process") < run.index("--scenario $Scenario")
    close = code[code.index("function Close-LocalRun"):code.index("$CleanScript = @")]
    assert "Stop-Process -Id $script:Tunnel.Id" in close and "'rcon.pw'" in close and "helpers.json" in close
    # уборка — в finally, что бы ни случилось; проверка журнала — до удаления пароля (он нужен вычистке)
    fin = code[code.rindex("\nfinally {"):]
    assert fin.index("check-log --slot $Slot --dir $LocalDir") < fin.index("Close-LocalRun")
    # пароль не печатается и не уходит в аргументы
    for m in re.finditer(r"Write-Host[^\n]*", code):
        assert "rcon.pw" not in m.group(0)
    assert "--password" not in code


# ------------------------------------------------------------ pack.py

def test_scenario_runner_cli(capsys):
    assert pack.main(["scenario-runner", "--name", "e2e_forge"]) == 0
    assert capsys.readouterr().out.strip() == "server"
    assert pack.main(["scenario-runner", "--name", "e2e_mining"]) == 0
    assert capsys.readouterr().out.strip() == "live"
    assert pack.main(["scenario-runner", "--name", "no_such_scenario"]) == 2


def test_scenario_runner_from_ast(tmp_path):
    (tmp_path / "s_a.py").write_text('RUNNER = "server"\nraise SystemExit("не выполнять")\n', encoding="utf-8")
    (tmp_path / "s_b.py").write_text("def run(c):\n    return {}\n", encoding="utf-8")
    (tmp_path / "s_c.py").write_text('RUNNER = "shell"\n', encoding="utf-8")
    (tmp_path / "s_d.py").write_text("RUNNER = open('x')\n", encoding="utf-8")
    assert pack.scenario_runner("s_a", str(tmp_path)) == "server"
    assert pack.scenario_runner("s_b", str(tmp_path)) == "live"
    for bad in ("s_c", "s_d", "../s_a", "nope"):
        with pytest.raises(pack.PackError):
            pack.scenario_runner(bad, str(tmp_path))


def test_payload_carries_the_real_server_package(tmp_path):
    out = tmp_path / "p.zip"
    cfg = pack.build_payload(4, "e2e_mcp", str(out))
    assert cfg["runner"] == "server" and cfg["forge"] == "" and cfg["forge_home"] == ""
    with zipfile.ZipFile(out) as z:
        names = set(z.namelist())
        stand = json.loads(z.read("stand/stand.json"))
        core = z.read("stand/server/factorio_partner/core.py")
    assert {"stand/server_client.py", "stand/live_client.py", "stand/scenarios/_e2e.py",
            "stand/scenarios/e2e_mcp.py", "stand/scenarios/e2e_forge.py",
            "stand/server/factorio_partner/__init__.py", "stand/server/factorio_partner/bridge.py",
            "stand/server/factorio_partner/rcon.py", "stand/server/factorio_partner/forge.py"} <= names
    with open(os.path.join(REPO, "server", "factorio_partner", "core.py"), "rb") as f:
        assert core == f.read()                     # тот же файл, что в репозитории, без правок
    assert not any("tests/" in n or n.endswith(".pyc") or "__pycache__" in n for n in names)
    assert stand["runner"] == "server" and stand["server_python"].endswith("python.exe")
    assert pack.build_payload(4, "e2e_ghosts", str(tmp_path / "q.zip"))["runner"] == "live"


def test_forge_paths_come_only_from_local_config_env_or_cli(tmp_path):
    forge = "D:\\Игры\\forge checkout"
    local = tmp_path / "pc.local.json"
    local.write_text(json.dumps({"forge": forge, "forge_profile": "my-save"}), encoding="utf-8")
    cfg = pack.build_payload(1, "e2e_forge", str(tmp_path / "a.zip"), local_config=str(local))
    assert cfg["forge"] == forge and cfg["forge_profile"] == "my-save" and cfg["forge_home"] == ""
    with zipfile.ZipFile(tmp_path / "a.zip") as z:
        assert json.loads(z.read("stand/stand.json").decode("utf-8"))["forge"] == forge   # кириллица цела
    # окружение запуска слабее файла, ключ командной строки сильнее всех
    env = {"FP_FORGE": "E:\\env", "FACTORIO_FORGE_HOME": "E:\\home", "FP_FORGE_PROFILE": "", "OTHER": "x"}
    cfg = pack.build_payload(1, "e2e_forge", str(tmp_path / "b.zip"), local_config=str(local), env=env)
    assert cfg["forge"] == forge and cfg["forge_home"] == "E:\\home" and cfg["forge_profile"] == "my-save"
    cfg = pack.build_payload(1, "e2e_forge", str(tmp_path / "c.zip"), env=env, forge="F:\\cli")
    assert cfg["forge"] == "F:\\cli" and cfg["forge_profile"] == ""
    assert pack.env_config({"FP_FORGE": ""}) == {}


@pytest.mark.parametrize("key,value", [
    ("forge", "relative\\path"), ("forge", 'D:\\a"b'), ("forge_home", "D:\\a;b"), ("forge", "D:\\a`whoami`"),
    ("forge_profile", "bad name"), ("forge_profile", "../x"), ("server_python", "python"), ("server_python", ""),
])
def test_bad_forge_and_python_settings_are_refused(tmp_path, key, value):
    with pytest.raises(pack.PackError):
        pack.build_payload(1, "e2e_forge", str(tmp_path / "p.zip"), **{key: value})


def test_pack_cli_does_not_print_forge_paths(tmp_path, capsys, monkeypatch):
    monkeypatch.setenv("FP_FORGE", "D:\\secret place\\forge")
    out = tmp_path / "p.zip"
    assert pack.main(["payload", "--slot", "2", "--scenario", "e2e_forge", "--out", str(out),
                      "--local-config", str(tmp_path / "none.json")]) == 0
    printed = capsys.readouterr().out
    info = json.loads(printed)
    assert info["runner"] == "server" and info["forge"] is True and "secret place" not in printed


def test_repo_defaults_have_no_forge_path():
    """Путь к forge — личный: в DEFAULTS репозитория его нет, только в pc.local.json / окружении."""
    assert pack.DEFAULTS["forge"] == "" and pack.DEFAULTS["forge_home"] == "" and pack.DEFAULTS["forge_profile"] == ""
    with open(os.path.join(PC_DIR, ".gitignore"), "r", encoding="utf-8") as f:
        assert "pc.local.json" in f.read()


# ------------------------------------------------------------ server_client: настройки forge

def checkout(tmp_path, name="forge"):
    d = tmp_path / name
    (d / ".venv" / "Scripts").mkdir(parents=True)
    (d / ".venv" / "Scripts" / "python.exe").write_bytes(b"")
    return d


def test_forge_settings(tmp_path):
    co = checkout(tmp_path)
    home = tmp_path / "home"
    home.mkdir()
    empty = {"forge": None, "forge_home": None, "forge_profile": None}
    assert sc.forge_settings({}) == empty
    assert sc.forge_settings({"forge": "", "forge_home": "  ", "forge_profile": None}) == empty
    assert sc.forge_settings({"forge": str(co), "forge_home": str(home), "forge_profile": "p"}) == {
        "forge": str(co), "forge_home": str(home), "forge_profile": "p"}
    # одним ключом forge_home задан сам checkout — он и берётся как checkout
    assert sc.forge_settings({"forge_home": str(co)}) == {"forge": str(co), "forge_home": None, "forge_profile": None}
    # настоящий дом forge (без .venv) остаётся домом
    assert sc.forge_settings({"forge_home": str(home)}) == {"forge": None, "forge_home": str(home),
                                                           "forge_profile": None}


def test_forge_info_has_no_paths(tmp_path):
    co = checkout(tmp_path, "очень личная папка")
    info = sc.forge_info(sc.forge_settings({"forge": str(co), "forge_profile": "p"}))
    assert info == {"configured": True, "checkout_found": True, "venv_found": True, "home_set": False,
                    "profile_set": True}
    assert "личная" not in json.dumps(info, ensure_ascii=False)
    assert sc.forge_info(sc.forge_settings({"forge": str(tmp_path / "нет")}))["checkout_found"] is False


def test_stand_config_is_read_from_the_slot(tmp_path):
    assert sc.load_stand_config(str(tmp_path)) == {}
    (tmp_path / "stand").mkdir()
    (tmp_path / "stand" / "stand.json").write_text('\ufeff{"forge": "D:\\\\x", "slot": 1}', encoding="utf-8")
    assert sc.load_stand_config(str(tmp_path)) == {"forge": "D:\\x", "slot": 1}
    (tmp_path / "stand" / "stand.json").write_text("[1, 2]", encoding="utf-8")
    assert sc.load_stand_config(str(tmp_path)) == {}


def test_forge_from_environment_only_without_a_stand_package(tmp_path):
    """Запуск не из пакета стенда (-Local): forge — из окружения; в пакете окружение не читается."""
    env = {"FP_FORGE": "X:\\forge", "FACTORIO_FORGE_HOME": "", "FP_FORGE_PROFILE": "save", "FP_HOME": "nope"}
    assert sc.load_stand_config(str(tmp_path), env) == {"forge": "X:\\forge", "forge_profile": "save"}
    (tmp_path / "stand").mkdir()
    (tmp_path / "stand" / "stand.json").write_text('{"forge": "", "slot": 1}', encoding="utf-8")
    assert sc.load_stand_config(str(tmp_path), env) == {"forge": "", "slot": 1}
    assert sc.ENV_KEYS == pack.ENV_KEYS


def test_server_dir_is_the_repo_package():
    assert os.path.samefile(sc.server_dir(), os.path.join(REPO, "server"))


def test_tools_match_the_mcp_contract():
    """Имена инструментов — как в MCP.md; служебных `admin_*` среди инструментов агента нет."""
    with open(os.path.join(REPO, "docs", "MCP.md"), "r", encoding="utf-8") as f:
        doc = f.read()
    for name in sc.TOOLS:
        assert f"`partner_{name}`" in doc, name
    assert not any(m.startswith("admin") for m in sc.TOOLS.values())
    assert all(m.startswith("admin_") for m in sc.ADMIN.values())


# ------------------------------------------------------------ docs/E2E.md

def test_e2e_doc_covers_scenarios_and_has_no_personal_paths():
    with open(os.path.join(REPO, "docs", "E2E.md"), "r", encoding="utf-8") as f:
        doc = f.read()
    for name in ("e2e_mcp", "e2e_ghosts", "e2e_mining", "e2e_forge", "log_must_not_match", "pc.local.json",
                 "Финал с игроком", "--body player", "game.print(1)", "Vulkan-Start-test"):
        assert name in doc, name
    # личных путей и адресов в публичном документе нет
    assert not re.search(r"[A-Za-z]:[\\/](Us" + r"ers|Т" + r"орт)", doc)
    assert not re.search(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", doc.replace("127.0.0.1", ""))
