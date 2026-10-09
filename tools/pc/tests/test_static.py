"""Статические проверки стенда: никаких консольных Lua-команд, только 127.0.0.1, синтаксис."""
from __future__ import annotations

import os
import py_compile
import re
import shutil
import subprocess
import sys

import pytest

from conftest import PC_DIR, REPO

STAND_FILES = []
for root, dirs, files in os.walk(PC_DIR):
    dirs[:] = [d for d in dirs if d not in ("tests", "__pycache__")]
    for f in files:
        if f.endswith((".py", ".ps1")):
            STAND_FILES.append(os.path.join(root, f))
STAND_FILES.append(os.path.join(REPO, "mod", "partner-test", "control.lua"))

CONSOLE = re.compile(r"""(?<![\w-])/(c|sc|silent-command|command|measured-command)(?=[\s'"]|$)""", re.MULTILINE)


@pytest.mark.parametrize("path", STAND_FILES, ids=lambda p: os.path.relpath(p, REPO))
def test_no_console_commands(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        text = f.read()
    # Упоминать их можно только как запрет: в каждой такой строке должно быть слово-запрет.
    for line in text.splitlines():
        if CONSOLE.search(line):
            assert re.search(r"(никаких|Никаких|запрещ|никогда|невозможно)", line), f"{path}: {line.strip()}"


@pytest.mark.parametrize("path", [p for p in STAND_FILES if p.endswith((".py", ".ps1"))],
                         ids=lambda p: os.path.relpath(p, REPO))
def test_loopback_only(path):
    with open(path, "r", encoding="utf-8-sig") as f:
        text = f.read()
    for ip in re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", text):
        assert ip == "127.0.0.1", f"{path}: {ip}"
    assert "0.0.0.0" not in text


@pytest.mark.parametrize("path", [p for p in STAND_FILES if p.endswith(".py")], ids=lambda p: os.path.relpath(p, REPO))
def test_py_compiles(path, tmp_path):
    py_compile.compile(path, cfile=str(tmp_path / "x.pyc"), doraise=True)


def test_py39_syntax():
    """На ПК Python 3.9: никаких match/case и X | Y в рантайме (ast с feature_version)."""
    import ast
    for path in STAND_FILES:
        if path.endswith(".py"):
            with open(path, "r", encoding="utf-8") as f:
                ast.parse(f.read(), filename=path, feature_version=(3, 9))


POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")


@pytest.mark.skipif(POWERSHELL is None, reason="нет PowerShell")
@pytest.mark.parametrize("path", [p for p in STAND_FILES if p.endswith(".ps1")], ids=lambda p: os.path.relpath(p, REPO))
def test_ps1_parses(path):
    script = ("$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile("
              f"'{path}',[ref]$t,[ref]$e);$e | ForEach-Object {{ $_.ToString() }};exit $e.Count")
    r = subprocess.run([POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", script],
                       capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    assert r.returncode == 0, r.stdout + r.stderr


@pytest.mark.parametrize("path", [p for p in STAND_FILES if p.endswith(".ps1")], ids=lambda p: os.path.relpath(p, REPO))
def test_ps1_has_bom(path):
    # PowerShell 5.1 читает файл без BOM в кодировке ANSI — кириллица ломается.
    with open(path, "rb") as f:
        assert f.read(3) == b"\xef\xbb\xbf"


# Проверки «пароль не в журналах» — в test_stand_logs.py (фейковый журнал Factorio с паролем).
