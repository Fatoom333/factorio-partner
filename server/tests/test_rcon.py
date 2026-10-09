import json

import pytest

from factorio_partner.config import Config
from factorio_partner.errors import ConfigError
from factorio_partner.rcon import RconAuthError, RconConnection, RconError, RconTimeout, check_command

from conftest import PASSWORD


def env_cmd(rid="r-1", op="hello"):
    return "/partner " + json.dumps({"v": 1, "id": rid, "op": op, "args": {}})


async def test_roundtrip(fake):
    c = RconConnection("127.0.0.1", fake.port, lambda: PASSWORD)
    body = await c.execute(env_cmd(), 2)
    assert json.loads(body)["ok"] is True
    assert fake.connections == 1
    await c.execute(env_cmd("r-2"), 2)
    assert fake.connections == 1  # connection reused
    await c.close()


async def test_wrong_password(fake):
    c = RconConnection("127.0.0.1", fake.port, lambda: "wrong")
    with pytest.raises(RconAuthError):
        await c.execute(env_cmd(), 2)
    assert fake.auth_failures == 1


async def test_password_not_kept_on_client(fake):
    c = RconConnection("127.0.0.1", fake.port, lambda: PASSWORD)
    await c.execute(env_cmd(), 2)
    assert c._client.password == ""
    await c.close()


@pytest.mark.parametrize("cmd", [
    "/c game.print(1)", "/sc game.print(1)", "/silent-command x", "/partnerx {}", "/partner [1]",
    "/partner {}\n/c x", "/partner {\"a\":1}\r", "hello", "", "/PARTNER {}",
])
async def test_only_partner_command(cmd, fake):
    with pytest.raises(ValueError):
        check_command(cmd)
    c = RconConnection("127.0.0.1", fake.port, lambda: PASSWORD)
    with pytest.raises(ValueError):
        await c.execute(cmd, 1)
    assert fake.commands == []


def test_host_must_be_loopback():
    with pytest.raises(ValueError):
        RconConnection("0.0.0.0", 1, lambda: "x")
    with pytest.raises(ValueError):
        RconConnection("192.168.1.5", 1, lambda: "x")


async def test_bad_utf8_is_replaced(fake):
    fake.mod.handlers["hello"] = lambda a, e: {"text": "BROKEN"}
    fake.faults.append("bad_utf8")
    c = RconConnection("127.0.0.1", fake.port, lambda: PASSWORD)
    body = await c.execute(env_cmd(), 2)
    assert "�" in body
    assert json.loads(body)["ok"] is True
    await c.close()


async def test_timeout_drops_connection(fake):
    fake.faults.append("drop")
    c = RconConnection("127.0.0.1", fake.port, lambda: PASSWORD)
    with pytest.raises(RconTimeout):
        await c.execute(env_cmd(), 0.2)
    assert not c.connected
    body = await c.execute(env_cmd("r-1"), 2)  # reconnects; mod returns the stored answer
    assert json.loads(body)["id"] == "r-1"
    assert fake.connections == 2
    await c.close()


async def test_wrong_packet_id_is_error(fake):
    fake.faults.append("wrong_packet_id")
    c = RconConnection("127.0.0.1", fake.port, lambda: PASSWORD)
    with pytest.raises(RconError):
        await c.execute(env_cmd(), 2)
    assert not c.connected


async def test_connect_refused():
    c = RconConnection("127.0.0.1", 1, lambda: PASSWORD, connect_timeout=1)
    with pytest.raises(RconError):
        await c.execute(env_cmd(), 1)


async def test_oversized_packet_rejected(monkeypatch, fake):
    import factorio_partner.rcon as r
    monkeypatch.setattr(r, "MAX_PACKET", 50)
    c = RconConnection("127.0.0.1", fake.port, lambda: PASSWORD)
    with pytest.raises(RconError):
        await c.execute(env_cmd(), 2)


# ---- config ----

def test_config_host_whitelist(tmp_path):
    base = {"FP_HOME": str(tmp_path)}
    assert Config.from_env(base).rcon_host == "127.0.0.1"
    assert Config.from_env(dict(base, FP_RCON_HOST="localhost")).rcon_host == "127.0.0.1"
    for bad in ("0.0.0.0", "192.168.0.2", "::1", "example.com", "127.0.0.2"):
        with pytest.raises(ConfigError):
            Config.from_env(dict(base, FP_RCON_HOST=bad))
    with pytest.raises(ConfigError):
        Config.from_env(dict(base, FP_RCON_PORT="abc"))
    with pytest.raises(ConfigError):
        Config.from_env(dict(base, FP_RCON_PORT="70000"))


def test_config_defaults(tmp_path):
    cfg = Config.from_env({"LOCALAPPDATA": str(tmp_path), "APPDATA": str(tmp_path / "r")})
    assert cfg.home == tmp_path / "factorio-partner"
    assert cfg.rcon_port == 27015
    assert cfg.forge_home == tmp_path / "r" / "factorio-forge"


def test_password_errors_do_not_leak(tmp_path):
    cfg = Config(home=tmp_path)
    with pytest.raises(ConfigError):
        cfg.read_password()
    p = tmp_path / "pw"
    p.write_text("", encoding="utf-8")
    with pytest.raises(ConfigError):
        Config(home=tmp_path, rcon_password_file=p).read_password()
    p.write_text("secret-xyz\n", encoding="utf-8")
    assert Config(home=tmp_path, rcon_password_file=p).read_password() == "secret-xyz"
    assert "secret" not in repr(Config(home=tmp_path, rcon_password_file=p))


def test_password_keeps_spaces_drops_line_break(tmp_path):
    p = tmp_path / "pw"
    p.write_bytes(b"\xef\xbb\xbf pass word \r\n")
    assert Config(home=tmp_path, rcon_password_file=p).read_password() == " pass word "
    p.write_bytes(b"\r\n")
    with pytest.raises(ConfigError):
        Config(home=tmp_path, rcon_password_file=p).read_password()
