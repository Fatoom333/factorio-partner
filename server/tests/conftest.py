from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_rcon import FakeMod, FakeRcon  # noqa: E402

from factorio_partner.bridge import Bridge  # noqa: E402
from factorio_partner.config import Config  # noqa: E402
from factorio_partner.core import Core  # noqa: E402

KEY = "k" * 40
PASSWORD = "test-password-123"


@pytest.fixture
async def fake():
    srv = await FakeRcon(FakeMod(), password=PASSWORD).start()
    yield srv
    await srv.stop()


@pytest.fixture
def home(tmp_path) -> Path:
    h = tmp_path / "fp-home"
    h.mkdir()
    (h / "helpers.json").write_text(json.dumps({"h1": KEY, "h2": "z" * 40}), encoding="utf-8")
    (h / "rcon.pw").write_text(PASSWORD + "\n", encoding="utf-8")
    return h


@pytest.fixture
def cfg(home, fake, tmp_path) -> Config:
    return Config(home=home, rcon_port=fake.port, rcon_password_file=home / "rcon.pw",
                  forge_home=tmp_path / "forge-home")


def make_bridge(cfg: Config, **kw) -> Bridge:
    kw.setdefault("cmd_timeout", 0.5)
    kw.setdefault("poll_timeout", 0.5)
    kw.setdefault("retry_delay", 0.01)
    return Bridge(cfg, **kw)


@pytest.fixture
async def bridge(cfg):
    b = make_bridge(cfg)
    yield b
    await b.close()


@pytest.fixture
async def core(cfg):
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module="tests_no_such_forge_module")
    yield c
    await c.close()


@pytest.fixture
async def started(core):
    """The server has met the game (hello): the owner's messages after this are new to it."""
    await core._ensure_started()
    return core
