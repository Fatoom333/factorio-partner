"""Проверка с настоящим forge: запускается, только если задан FP_FORGE с готовым .venv.

    FP_FORGE="<путь к checkout factorio-forge>" python -m pytest server/tests/test_forge_live.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
from pathlib import Path

import pytest

_SRC = Path(__file__).resolve().parents[1] / "factorio_partner" / "forge.py"
_spec = importlib.util.spec_from_file_location("fp_forge_live", _SRC)
forge = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = forge
_spec.loader.exec_module(forge)

FORGE = os.environ.get("FP_FORGE", "")


def _have_forge() -> bool:
    try:
        forge._forge_python(FORGE)
        return True
    except forge.ForgeUnavailable:
        return False


pytestmark = pytest.mark.skipif(not _have_forge(), reason="FP_FORGE не задан или без .venv")

class _Cfg:
    def __init__(self, home):
        self.home, self.forge, self.forge_profile = home, FORGE, os.environ.get("FP_FORGE_PROFILE") or None
        self.forge_home = os.environ.get("FACTORIO_FORGE_HOME") or None


AREA = {"left_top": {"x": 10, "y": -20}, "right_bottom": {"x": 30, "y": -5}}


@pytest.mark.parametrize("options", [
    {},
    {"direction": "east", "pole": "medium-electric-pole"},
    {"drill": "big-mining-drill", "direction": "west"},
    {"drill": "burner-mining-drill", "direction": "south"},
])
def test_live_plan(tmp_path, options):
    out = forge.plan("mining", {"name": "iron-ore", "area": AREA}, None, options, config=_Cfg(tmp_path))
    assert "plan" in out, out
    text = forge.load_plan(out["plan"], config=_Cfg(tmp_path))
    assert text.startswith("0") and text not in json.dumps(out)
    assert out["size"]["w"] >= 20 and out["size"]["h"] >= 15


def test_live_bad_belt(tmp_path):
    out = forge.plan("mining", {"name": "iron-ore", "area": AREA}, None, {"belt": "no-such-belt"},
                     config=_Cfg(tmp_path))
    # проверяем код finding'а forge, а не его текст: текст forge может поменять
    assert out["supported"] is False and "plan" not in out
    assert "[unknown-prototypes]" in out["reason"], out


def test_live_notes(tmp_path):
    out = forge.brief_notes(_Cfg(tmp_path))
    assert out["profile"] and "reason" not in out, out
