"""Связка сервер → настоящий forge.py: core зовёт forge так, как в бою.

forge-процесс не нужен: подменяется только `_run_forge`. Тест ловит разъезд сигнатур
`core._forge_plan` ↔ `forge.plan` и `core._load_plan` ↔ `forge.load_plan`.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from conftest import KEY, make_bridge
from factorio_partner import forge
from factorio_partner.core import Core
from factorio_partner.errors import PartnerError

BP = "0eNqrVkrKKU0tKsrMK1GyqlYqLU7NUbJSSs4vzUtRqq0FAHhoCfo="
AREA = {"left_top": {"x": 10, "y": -20}, "right_bottom": {"x": 30, "y": -5}}


def _fake_forge(monkeypatch, calls: list, active="sample-save"):
    def run(forge_path, argv, cwd, timeout, **kw):
        calls.append((forge_path, list(argv)))
        if argv[0] == "list-profiles":
            return subprocess.CompletedProcess(argv, 0, f"* {active} (from X) — ok\n".encode(), b"")
        if argv[0] == "build":
            import json
            data = json.loads(Path(argv[1]).read_text(encoding="utf-8"))
            out = Path(argv[argv.index("-o") + 1])
            out.mkdir(parents=True, exist_ok=True)
            (out / f"{data['label']}.txt").write_text(BP, encoding="utf-8")
            (out / f"{data['label']}.report.json").write_text(json.dumps({"findings": []}), encoding="utf-8")
            return subprocess.CompletedProcess(argv, 0, b"", b"")
        raise AssertionError(argv)
    monkeypatch.setattr(forge, "_run_forge", run)


@pytest.fixture
def forge_cfg(cfg, tmp_path):
    return type(cfg)(**{**cfg.__dict__, "forge": tmp_path / "forge-checkout", "forge_profile": "sample-save"})


async def test_core_plan_then_build_with_real_forge_module(forge_cfg, fake, monkeypatch, tmp_path):
    calls: list = []
    _fake_forge(monkeypatch, calls)
    # окружение процесса указывает в другое место: всё должно браться из Config
    monkeypatch.setenv("FP_HOME", str(tmp_path / "wrong-home"))
    monkeypatch.setenv("FP_FORGE", str(tmp_path / "wrong-forge"))
    monkeypatch.setenv("FP_FORGE_PROFILE", "krastorio2")
    c = Core(forge_cfg, make_bridge(forge_cfg), poll_interval=0.01, forge_module="factorio_partner.forge")
    try:
        r = await c.op_plan("h1", KEY, "mining", resource={"name": "iron-ore", "area": AREA},
                            options={"direction": "east"})
        assert r.get("supported") is not False, r
        assert forge.PLAN_ID_RE.match(r["plan"]) and BP not in str(r)
        assert set(r) >= {"plan", "anchor", "direction", "items", "size", "summary"}
        assert calls and all(fp == str(forge_cfg.forge) for fp, _ in calls)
        assert (forge_cfg.plans_dir / f"{r['plan']}.txt").is_file()
        assert not (tmp_path / "wrong-home").exists()

        # build_blueprint{plan}: core находит чертёж в своём FP_HOME, хотя os.environ — другой
        a = await c.op_act("h1", KEY, "build_blueprint", {"plan": r["plan"], "anchor": r["anchor"]})
        assert a.get("job") is not None or a, a
        blobs = list(fake.mod.blobs)
        assert blobs and fake.mod.blob_text(blobs[-1]) == BP
    finally:
        await c.close()


async def test_core_plan_bad_area_is_bad_args(forge_cfg, fake, monkeypatch):
    calls: list = []
    _fake_forge(monkeypatch, calls)
    c = Core(forge_cfg, make_bridge(forge_cfg), poll_interval=0.01, forge_module="factorio_partner.forge")
    try:
        with pytest.raises(PartnerError) as ei:
            await c.op_plan("h1", KEY, "mining", resource={"name": "iron-ore", "area": {"left_top": {}}})
        assert ei.value.code == "bad_args"
        assert calls == []
    finally:
        await c.close()


async def test_core_plan_profile_mismatch_from_config(forge_cfg, fake, monkeypatch):
    calls: list = []
    _fake_forge(monkeypatch, calls, active="krastorio2")
    c = Core(forge_cfg, make_bridge(forge_cfg), poll_interval=0.01, forge_module="factorio_partner.forge")
    try:
        r = await c.op_plan("h1", KEY, "mining", resource={"name": "iron-ore", "area": AREA})
        assert r["supported"] is False and "sample-save" in r["reason"] and "TypeError" not in r["reason"]
    finally:
        await c.close()


def test_config_forge_home_from_env(tmp_path):
    from factorio_partner.config import Config
    c = Config.from_env({"FP_HOME": str(tmp_path), "FACTORIO_FORGE_HOME": str(tmp_path / "fh"),
                         "FP_FORGE": str(tmp_path / "f"), "FP_FORGE_PROFILE": "sample-save"})
    assert c.forge_home == tmp_path / "fh" and c.forge == tmp_path / "f" and c.forge_profile == "sample-save"


async def test_core_brief_notes_with_real_forge_module(forge_cfg, fake, monkeypatch):
    seen = []

    def run(forge_path, argv, cwd, timeout, **kw):
        seen.append((argv, kw.get("forge_home")))
        prof = forge_cfg.forge_home / "profiles" / "sample-save"
        prof.mkdir(parents=True, exist_ok=True)
        (prof / "notes.md").write_text("ленты слева", encoding="utf-8")
        return subprocess.CompletedProcess(argv, 0, f"profile: {prof}\nnotes: {prof / 'notes.md'}\n".encode(), b"")
    monkeypatch.setattr(forge, "_run_forge", run)
    c = Core(forge_cfg, make_bridge(forge_cfg), poll_interval=0.01, forge_module="factorio_partner.forge")
    try:
        r = await c.op_brief("h1", KEY)
        assert r["notes"] == "ленты слева" and r["profile"] == "sample-save"
        assert seen == [(["notes", "sample-save"], forge_cfg.forge_home)]
    finally:
        await c.close()
