"""Пароль RCON не уходит из слота: журналы Factorio копируются и печатаются только вычищенными.

Функции вычистки берутся прямо из tools/pc/remote/stand.ps1 (разбор AST PowerShell) и гоняются
на фейковом журнале с паролем — как его пишет Factorio 2.0 (строка Program arguments).
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess

import pytest

from conftest import PC_DIR

STAND = os.path.join(PC_DIR, "remote", "stand.ps1")
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")
SECRET = "9f3c2a71be0d44e8a6c15f2b7d90e3aa41c6b8d25e7f0a13"

FAKE_LOG = (
    "   0.000 2026-10-08 12:00:00; Factorio 2.0.77 (build 83340, win64, steam, space-age)\n"
    "   0.001 Operating system: Windows 11\n"
    '   0.001 Program arguments: "D:\\Program Files (x86)\\Steam\\steamapps\\common\\Factorio\\bin\\x64\\factorio.exe" '
    '"--start-server" "D:\\Temp\\fp-live-1\\data\\saves\\fp-live.zip" "-c" "D:\\Temp\\fp-live-1\\config.ini" '
    '"--bind" "127.0.0.1" "--port" "34201" "--rcon-bind" "127.0.0.1:27101" "--rcon-password" "' + SECRET + '"\n'
    "   0.002 Read data path: D:/Program Files (x86)/Steam/steamapps/common/Factorio/data\n"
    "   1.500 Info: кириллица в журнале остаётся как есть\n"
    "   2.000 Info RemoteCommandProcessor.cpp:133: Starting RCON interface at IP ADDR:({127.0.0.1:27101})\n"
    "   3.000 Warning: echo " + SECRET + " (на всякий случай — голое вхождение)\n"
)

FUNCS = ("Format-Redacted", "Get-RedactedLogText", "Copy-RedactedLog")


def _run_ps(body: str, env_extra: dict) -> subprocess.CompletedProcess:
    script = (
        "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8;"
        "$t=$null;$e=$null;"
        "$ast=[System.Management.Automation.Language.Parser]::ParseFile($env:FP_STAND,[ref]$t,[ref]$e);"
        "$want=@(" + ",".join(f"'{f}'" for f in FUNCS) + ");"
        "$defs=$ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true)"
        " | Where-Object { $want -contains $_.Name };"
        "if (@($defs).Count -ne $want.Count) { throw 'в stand.ps1 нет функций вычистки' };"
        "foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) };"
        + body
    )
    env = dict(os.environ, FP_STAND=STAND, **env_extra)
    return subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", script], env=env,
                          capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)


@pytest.mark.skipif(POWERSHELL is None, reason="нет PowerShell")
@pytest.mark.parametrize("secret_known", [True, False], ids=["with-pw-file", "without-pw-file"])
def test_copied_log_has_no_password(tmp_path, secret_known):
    src = tmp_path / "factorio-current.log"
    dst = tmp_path / "out" / "factorio-1.log"
    dst.parent.mkdir()
    src.write_bytes(FAKE_LOG.encode("utf-8"))
    r = _run_ps("Copy-RedactedLog $env:FP_SRC $env:FP_DST $env:FP_SECRET",
                {"FP_SRC": str(src), "FP_DST": str(dst), "FP_SECRET": SECRET if secret_known else ""})
    assert r.returncode == 0, r.stdout + r.stderr
    out = dst.read_bytes().decode("utf-8")
    assert '"--rcon-password" "<private>"' in out
    assert "кириллица в журнале остаётся как есть" in out
    assert "Starting RCON interface" in out
    if secret_known:
        assert SECRET not in out
    else:
        # без файла пароля голое вхождение не узнать, но строка аргументов вычищена всегда
        assert out.count(SECRET) == 1 and "Warning: echo " + SECRET in out
    assert SECRET not in r.stdout + r.stderr


@pytest.mark.skipif(POWERSHELL is None, reason="нет PowerShell")
def test_redact_in_place(tmp_path):
    """Invoke-Stop перезаписывает журнал в слоте вычищенным (на случай -Keep)."""
    src = tmp_path / "factorio-current.log"
    src.write_bytes(FAKE_LOG.encode("utf-8"))
    r = _run_ps("Copy-RedactedLog $env:FP_SRC $env:FP_SRC $env:FP_SECRET",
                {"FP_SRC": str(src), "FP_SECRET": SECRET})
    assert r.returncode == 0, r.stdout + r.stderr
    assert SECRET not in src.read_bytes().decode("utf-8")


@pytest.mark.skipif(POWERSHELL is None, reason="нет PowerShell")
@pytest.mark.parametrize("line", [
    '"--rcon-password" "abc def"',
    "--rcon-password abcdef123",
    "--rcon-password=abcdef123",
    '"--rcon-password"   "abcdef123"',
])
def test_format_redacted_variants(line):
    r = _run_ps("Write-Output (Format-Redacted $env:FP_LINE '')", {"FP_LINE": "args: " + line + " tail"})
    assert r.returncode == 0, r.stdout + r.stderr
    assert "abc" not in r.stdout and "<private>" in r.stdout and r.stdout.strip().endswith("tail")


def _stand_code():
    with open(STAND, "r", encoding="utf-8-sig") as f:
        text = f.read()
    return "\n".join(line.split("#", 1)[0] for line in text.splitlines())


def test_stand_never_copies_or_prints_raw_log():
    """Журнал сервера выносится/печатается только через функции вычистки."""
    code = _stand_code()
    assert not re.search(r"Copy-Item[^\n]*\$LogFile", code)
    assert not re.search(r"Copy-Item[^\n]*factorio-(current|previous)", code)
    assert not re.search(r"Get-Content[^\n]*\$LogFile", code)
    assert "Get-RedactedLogText $LogFile" in code  # Show-LogTail
    assert re.search(r"Copy-RedactedLog \$src \(Join-Path \$OutDir", code)  # Invoke-Stop


def test_password_never_printed():
    """Пароль не печатается: ни переменная пароля, ни командная строка сервера."""
    code = _stand_code()
    for m in re.finditer(r"Write-(Host|Output|Verbose|Information|Error|Warning)[^\n]*", code):
        assert not re.search(r"\$(pw|cmd|secret)\b", m.group(0), re.IGNORECASE), m.group(0)
    with open(os.path.join(PC_DIR, "live_client.py"), "r", encoding="utf-8") as f:
        assert "--password" not in f.read()  # пароль клиенту — только файлом
