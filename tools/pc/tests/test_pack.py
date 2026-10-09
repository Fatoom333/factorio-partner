from __future__ import annotations

import json
import os
import zipfile

import pytest

import pack
from conftest import REPO


def test_mod_zip_layout(tmp_path):
    out = pack.build_mod(os.path.join(REPO, "mod", "partner-test"), str(tmp_path))
    info = pack.read_info(os.path.join(REPO, "mod", "partner-test"))
    top = f"{info['name']}_{info['version']}"
    assert os.path.basename(out) == top + ".zip"
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
    assert f"{top}/info.json" in names and f"{top}/control.lua" in names
    assert all(n.startswith(top + "/") and "\\" not in n for n in names)


def test_real_mod_zip_includes_scripts(tmp_path):
    out = pack.build_mod(os.path.join(REPO, "mod", "factorio-partner"), str(tmp_path))
    with zipfile.ZipFile(out) as z:
        names = z.namelist()
    assert any(n.endswith("/scripts/core/init.lua") for n in names)
    assert not any("/tests/" in n or n.endswith(".zip") for n in names)


def test_mod_zip_is_deterministic(tmp_path):
    a = pack.build_mod(os.path.join(REPO, "mod", "partner-test"), str(tmp_path / "a"))
    b = pack.build_mod(os.path.join(REPO, "mod", "partner-test"), str(tmp_path / "b"))
    with open(a, "rb") as fa, open(b, "rb") as fb:
        assert fa.read() == fb.read()


def test_bad_info_json(tmp_path):
    (tmp_path / "info.json").write_text('{"name": "../x", "version": "1.0.0"}', encoding="utf-8")
    with pytest.raises(pack.PackError):
        pack.read_info(str(tmp_path))
    (tmp_path / "info.json").write_text('{"name": "x", "version": "1.0"}', encoding="utf-8")
    with pytest.raises(pack.PackError):
        pack.read_info(str(tmp_path))


def test_scenario_mods_from_ast(tmp_path):
    (tmp_path / "s_a.py").write_text('MODS = ["partner-test"]\nraise SystemExit("не выполнять")\n', encoding="utf-8")
    (tmp_path / "s_b.py").write_text("def run(c):\n    return {}\n", encoding="utf-8")
    (tmp_path / "s_c.py").write_text('MODS = ["evil-mod"]\n', encoding="utf-8")
    assert pack.scenario_mods("s_a", str(tmp_path)) == ["partner-test"]
    assert pack.scenario_mods("s_b", str(tmp_path)) == ["factorio-partner"]
    with pytest.raises(pack.PackError):
        pack.scenario_mods("s_c", str(tmp_path))
    with pytest.raises(pack.PackError):
        pack.scenario_mods("../s_a", str(tmp_path))


def test_e_scenarios_need_partner_test():
    assert pack.scenario_mods("e_chart") == ["partner-test"]
    assert pack.scenario_mods("e_rcon_maxlen") == ["partner-test"]


def test_payload(tmp_path):
    out = tmp_path / "p.zip"
    cfg = pack.build_payload(3, "e_chart", str(out))
    assert cfg["rcon_port"] == 27103 and cfg["game_port"] == 34203
    with zipfile.ZipFile(out) as z:
        names = set(z.namelist())
        stand = json.loads(z.read("stand/stand.json"))
    assert {"stand/live_client.py", "stand/stand.ps1", "stand/scenarios/e_chart.py",
            "stand/scenarios/e_rcon_maxlen.py"} <= names
    assert any(n.startswith("stand/mods/partner-test_") for n in names)
    assert not any(n.startswith("stand/mods/factorio-partner_") for n in names)
    assert stand["slot"] == 3 and stand["scenario"] == "e_chart"
    assert [m["name"] for m in stand["mods"]] == ["partner-test"]
    # в пакете нет ничего похожего на пароль
    assert not any("pw" in k or "password" in k for k in stand)
    assert not os.path.exists(str(out) + ".mods")


def test_payload_both_mods(tmp_path):
    cfg = pack.build_payload(1, "e_chart", str(tmp_path / "p.zip"), mods=["factorio-partner", "partner-test"])
    assert [m["name"] for m in cfg["mods"]] == ["factorio-partner", "partner-test"]


@pytest.mark.parametrize("kw", [
    {"slot": 10}, {"slot": -1},
    {"save": "../x.zip"}, {"save": "a b.zip"}, {"save": "x.sav"},
    {"factorio_exe": "relative\\f.exe"}, {"factorio_exe": "D:\\x\" & calc"}, {"pc_python": "C:\\a;b"},
    {"timeout_sec": 5}, {"timeout_sec": "600"},
    {"unknown_key": 1},
])
def test_payload_validation(tmp_path, kw):
    slot = kw.pop("slot", 1)
    with pytest.raises(pack.PackError):
        pack.build_payload(slot, "e_chart", str(tmp_path / "p.zip"), **kw)


def test_payload_unknown_scenario(tmp_path):
    with pytest.raises(pack.PackError):
        pack.build_payload(1, "no_such_scenario", str(tmp_path / "p.zip"), mods=["partner-test"])


def test_cli(tmp_path, capsys):
    assert pack.main(["scenario-mods", "--name", "e_chart", "--plain"]) == 0
    assert capsys.readouterr().out.strip() == "partner-test"
    assert pack.main(["payload", "--slot", "2", "--scenario", "e_chart", "--out", str(tmp_path / "p.zip"),
                      "--mods", "partner-test", "--save", "Vulkan-Start.zip", "--timeout-sec", "300"]) == 0
    assert pack.main(["payload", "--slot", "2", "--scenario", "e_chart", "--out", str(tmp_path / "q.zip"),
                      "--mods", "evil"]) == 2


def test_local_config_overrides_defaults(tmp_path):
    local = tmp_path / "pc.local.json"
    local.write_text(json.dumps({"factorio_exe": r"E:\Games\Factorio\bin\x64\factorio.exe",
                                 "pc_python": r"E:\venv\Scripts\python.exe"}), encoding="utf-8")
    cfg = pack.build_payload(1, "e_chart", str(tmp_path / "p.zip"), local_config=str(local))
    assert cfg["factorio_exe"] == r"E:\Games\Factorio\bin\x64\factorio.exe"
    assert cfg["pc_python"] == r"E:\venv\Scripts\python.exe"
    assert cfg["factorio_data"] == pack.DEFAULTS["factorio_data"]
    # ключ командной строки сильнее локального файла
    cfg = pack.build_payload(1, "e_chart", str(tmp_path / "q.zip"), local_config=str(local),
                             pc_python=r"F:\py\python.exe")
    assert cfg["pc_python"] == r"F:\py\python.exe"


def test_local_config_missing_is_ok(tmp_path):
    cfg = pack.build_payload(1, "e_chart", str(tmp_path / "p.zip"), local_config=str(tmp_path / "nope.json"))
    assert cfg["factorio_exe"] == pack.DEFAULTS["factorio_exe"]


@pytest.mark.parametrize("content", [
    '{"rcon_password": "x"}', json.dumps({"factorio_exe": 'D:\\x" & calc'}), '[1]', 'not json',
], ids=["unknown-key", "injection", "not-object", "not-json"])
def test_local_config_validation(tmp_path, content):
    local = tmp_path / "pc.local.json"
    local.write_text(content, encoding="utf-8")
    with pytest.raises(pack.PackError):
        pack.build_payload(1, "e_chart", str(tmp_path / "p.zip"), local_config=str(local))


def test_local_config_is_gitignored():
    with open(os.path.join(os.path.dirname(pack.__file__), ".gitignore"), encoding="utf-8") as f:
        assert "pc.local.json" in f.read().split()


def test_default_save_is_test_copy(tmp_path):
    """Стенд по умолчанию берёт копию Vulkan-Start-test.zip, а не рабочий сейв игрока."""
    assert pack.DEFAULTS["save"] == "Vulkan-Start-test.zip"
    cfg = pack.build_payload(1, "e_chart", str(tmp_path / "p.zip"), local_config=str(tmp_path / "none.json"))
    assert cfg["save"] == "Vulkan-Start-test.zip"
    with open(os.path.join(os.path.dirname(pack.__file__), "run-live.ps1"), encoding="utf-8") as f:
        assert "Vulkan-Start-test.zip" in f.read()
