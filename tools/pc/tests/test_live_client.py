from __future__ import annotations

import json
import os
import textwrap

import pytest

import live_client as lc
from conftest import PASSWORD


def client_for(server, **kw):
    return lc.LiveClient(server.port, PASSWORD, **kw)


# ---------- отправка: только конверты /partner ----------

def test_call_sends_partner_envelope(fake_rcon):
    srv = fake_rcon()
    with client_for(srv) as c:
        reply = c.call("hello")
    assert reply["ok"] is True
    assert len(srv.commands) == 1
    cmd = srv.commands[0]
    assert cmd.startswith("/partner {")
    env = json.loads(cmd[len("/partner "):])
    assert env["v"] == 1 and env["op"] == "hello" and env["args"] == {}
    assert lc.ID_RE.match(env["id"])


@pytest.mark.parametrize("bad", ["/c game.print(1)", "/sc x", "/silent-command x", "/partner {}", "hello", b"/c"])
def test_send_rejects_strings(fake_rcon, bad):
    srv = fake_rcon()
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.send(bad)
        assert ei.value.kind == "refused"
    assert srv.commands == []


@pytest.mark.parametrize("raw", ["/c game.print(1)", "/sc game.print(1)", "/silent-command game.print(1)",
                                 "/partner-ping", "/partner game.print(1)", "/QUIT", "/quit now", "/partner{}"])
def test_send_raw_blocks_everything_but_partner_and_quit(fake_rcon, raw):
    srv = fake_rcon()
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c._send_raw(raw)
        assert ei.value.kind == "refused"
    assert srv.commands == []


@pytest.mark.parametrize("env, field", [
    ({"v": 1, "id": "x", "op": "hello", "args": {}, "lua": "x"}, "лишние"),
    ({"v": "1", "id": "x", "op": "hello"}, "v"),
    ({"v": True, "id": "x", "op": "hello"}, "v"),
    ({"v": 1, "id": "", "op": "hello"}, "id"),
    ({"v": 1, "id": "a" * 41, "op": "hello"}, "id"),
    ({"v": 1, "id": "a b", "op": "hello"}, "id"),
    ({"v": 1, "id": "x", "op": "/c"}, "op"),
    ({"v": 1, "id": "x", "op": "Hello"}, "op"),
    ({"v": 1, "id": "x", "op": "hello", "helper": "H1"}, "helper"),
    ({"v": 1, "id": "x", "op": "hello", "helper": "h" * 17}, "helper"),
    ({"v": 1, "id": "x", "op": "hello", "args": []}, "args"),
])
def test_validate_envelope_rejects(env, field):
    with pytest.raises(lc.LiveClientError) as ei:
        lc.validate_envelope(env)
    assert ei.value.kind == "refused"
    assert field in ei.value.message


def test_build_command_escapes_newlines_and_keeps_utf8():
    cmd = lc.build_command({"v": 1, "id": "a1", "op": "say", "helper": "h1", "args": {"text": "при\nвет"}})
    assert "\n" not in cmd
    assert cmd.startswith("/partner ")
    assert "при\\nвет" in cmd


def test_quit_is_separate(fake_rcon):
    srv = fake_rcon()
    c = client_for(srv)
    c.connect()
    assert c.quit() == ""  # фейк закрывает соединение, как Factorio
    assert srv.commands == ["/quit"]
    assert not c.connected


def test_only_loopback_host():
    with pytest.raises(lc.LiveClientError):
        lc.LiveClient(27101, PASSWORD, host="0.0.0.0")
    with pytest.raises(lc.LiveClientError):
        lc.LiveClient(27101, PASSWORD, host="192.168.1.5")


def test_request_size_limit(fake_rcon):
    srv = fake_rcon()
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.call("e_echo", {"pad": "x" * 9000})
        assert ei.value.kind == "refused"
        c.max_request_bytes = 20000
        reply = c.call("e_echo", {"pad": "x" * 9000})
        assert reply["ok"] and reply["data"]["len"] > 9000


# ---------- транспорт ----------

def test_auth_failure(fake_rcon):
    srv = fake_rcon(password="other")
    c = client_for(srv)
    with pytest.raises(lc.LiveClientError) as ei:
        c.connect()
    assert ei.value.kind == "auth"
    assert not c.connected


def test_auth_with_empty_packet_first(fake_rcon):
    srv = fake_rcon(empty_before_auth=True)
    with client_for(srv) as c:
        assert c.call("hello")["ok"]


def test_stale_reply_is_skipped(fake_rcon):
    srv = fake_rcon(stale_first=True)
    with client_for(srv) as c:
        r1 = c.call("hello")
        r2 = c.call("hello")
    assert r1["ok"] and r2["ok"] and r1["id"] != r2["id"]


def test_reply_for_other_id_is_protocol_error(fake_rcon):
    srv = fake_rcon(handler=lambda cmd: json.dumps({"v": 1, "id": "zzz", "ok": True, "tick": 1, "seq": 0}))
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.call("hello")
    assert ei.value.kind == "protocol"


def test_bad_request_without_id_is_returned(fake_rcon):
    srv = fake_rcon(handler=lambda cmd: '{"v":1,"ok":false,"tick":1,"seq":0,"error":{"code":"bad_request","text":"x"}}')
    with client_for(srv) as c:
        reply = c.call("hello")
    assert reply["ok"] is False and reply["error"]["code"] == "bad_request"


@pytest.mark.parametrize("text", ["", "Unknown command \"partner\".", "[1,2]", '{"id":null}'])
def test_non_envelope_reply_is_protocol_error(fake_rcon, text):
    srv = fake_rcon(handler=lambda cmd: text)
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.call("hello")
    assert ei.value.kind == "protocol"


def test_broken_utf8_does_not_crash(fake_rcon):
    # Factorio обрезает кириллицу посреди символа: байт 0xD0 без пары. Клиент не падает.
    def handler(cmd):
        rid = json.loads(cmd[len("/partner "):])["id"]
        return (b'{"v":1,"id":"' + rid.encode() + b'","ok":false,"tick":1,"seq":0,'
                b'"error":{"code":"internal","text":"\xd0"}}')

    srv = fake_rcon(handler=handler)
    with client_for(srv) as c:
        reply = c.call("hello")
    assert reply["ok"] is False and reply["error"]["code"] == "internal"

def test_connection_drop_then_reconnect(fake_rcon):
    calls = {"n": 0}

    def handler(cmd):
        calls["n"] += 1
        if calls["n"] == 1:
            return None  # обрыв
        return json.dumps({"v": 1, "id": json.loads(cmd[9:])["id"], "ok": True, "tick": 1, "seq": 0})

    srv = fake_rcon(handler=handler)
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.call("hello")
        assert ei.value.kind == "transport"
        assert not c.connected
        assert c.call("hello")["ok"]  # переподключается сам
    assert srv.connections == 2


def test_timeout(fake_rcon):
    srv = fake_rcon(delay=1.5)
    with client_for(srv, timeout=0.3) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.call("hello")
    assert ei.value.kind == "transport"


def test_call_ok_raises_on_mod_error(fake_rcon):
    srv = fake_rcon(handler=lambda cmd: json.dumps({"v": 1, "id": json.loads(cmd[9:])["id"], "ok": False, "tick": 1,
                                                    "seq": 0, "error": {"code": "unknown_op", "text": "x"}}))
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.call_ok("nope")
    assert "unknown_op" in ei.value.message


def test_repr_and_log_have_no_password(fake_rcon, tmp_path):
    srv = fake_rcon()
    log = tmp_path / "live.log"
    with client_for(srv, log_path=str(log)) as c:
        c.call("hello")
        assert PASSWORD not in repr(c)
    assert PASSWORD not in log.read_text(encoding="utf-8")
    assert "op=hello" in log.read_text(encoding="utf-8")


def test_ports():
    assert lc.rcon_port(0) == 27100 and lc.rcon_port(9) == 27109
    assert lc.game_port(3) == 34203
    for bad in (-1, 10, "1", True, 1.0):
        with pytest.raises(lc.LiveClientError):
            lc.rcon_port(bad)


# ---------- сценарии и CLI ----------

def _slot_dir(tmp_path, pw=PASSWORD):
    d = tmp_path / "fp-live-1"
    d.mkdir()
    (d / "rcon.pw").write_text(pw + "\n", encoding="utf-8")
    return d


def _scen(tmp_path, name, body):
    sd = tmp_path / "scen"
    sd.mkdir(exist_ok=True)
    (sd / f"{name}.py").write_text(textwrap.dedent(body), encoding="utf-8")
    return str(sd)


def test_run_scenario_writes_results(fake_rcon, tmp_path, monkeypatch):
    srv = fake_rcon()
    monkeypatch.setattr(lc, "RCON_BASE_PORT", srv.port - 1)
    d = _slot_dir(tmp_path)
    sd = _scen(tmp_path, "s_ok", """
        def run(client):
            r = client.call("hello")
            return {"ok": r["ok"], "echo": "%s"}
    """ % PASSWORD)
    res = lc.run_scenario(1, str(d), "s_ok", 30, scenario_directory=sd)
    assert res["ok"] is True
    saved = json.loads((d / "out" / "results-1.json").read_text(encoding="utf-8"))
    assert saved["ok"] is True and saved["meta"]["slot"] == 1 and saved["meta"]["scenario"] == "s_ok"
    # Пароль вычищен даже если сценарий сам положил его в результат.
    raw = (d / "out" / "results-1.json").read_text(encoding="utf-8")
    assert PASSWORD not in raw and "<private>" in raw
    assert PASSWORD not in (d / "out" / "live-1.log").read_text(encoding="utf-8")


def test_run_scenario_exception_is_reported(fake_rcon, tmp_path, monkeypatch):
    srv = fake_rcon()
    monkeypatch.setattr(lc, "RCON_BASE_PORT", srv.port - 1)
    d = _slot_dir(tmp_path)
    sd = _scen(tmp_path, "s_boom", """
        def run(client):
            raise RuntimeError("бум")
    """)
    res = lc.run_scenario(1, str(d), "s_boom", 30, scenario_directory=sd)
    assert res["ok"] is False and res["error"]["kind"] == "exception" and "бум" in res["error"]["text"]


def test_run_scenario_bad_password(fake_rcon, tmp_path, monkeypatch):
    srv = fake_rcon()
    monkeypatch.setattr(lc, "RCON_BASE_PORT", srv.port - 1)
    d = _slot_dir(tmp_path, pw="wrong")
    sd = _scen(tmp_path, "s_ok", "def run(client):\n    return {'ok': True}\n")
    res = lc.run_scenario(1, str(d), "s_ok", 30, scenario_directory=sd)
    assert res["ok"] is False and res["error"]["kind"] == "auth"


@pytest.mark.parametrize("name", ["../evil", "a/b", "A", "", "x" * 65, "e_chart.py"])
def test_load_scenario_rejects_bad_names(name, tmp_path):
    with pytest.raises(lc.LiveClientError):
        lc.load_scenario(name, str(tmp_path))


def test_cli_wait_ready_and_quit(fake_rcon, tmp_path, monkeypatch):
    srv = fake_rcon()
    monkeypatch.setattr(lc, "RCON_BASE_PORT", srv.port - 1)
    d = _slot_dir(tmp_path)
    assert lc.main(["wait-ready", "--slot", "1", "--dir", str(d), "--timeout", "5"]) == 0
    assert lc.main(["quit", "--slot", "1", "--dir", str(d)]) == 0
    assert srv.commands == ["/quit"]
    assert lc.main(["quit", "--slot", "12", "--dir", str(d)]) == 2


def test_cli_wait_ready_wrong_password_fails_fast(fake_rcon, tmp_path, monkeypatch):
    srv = fake_rcon(password="other")
    monkeypatch.setattr(lc, "RCON_BASE_PORT", srv.port - 1)
    d = _slot_dir(tmp_path)
    assert lc.main(["wait-ready", "--slot", "1", "--dir", str(d), "--timeout", "5"]) == 1
    assert len(srv.auth_attempts) == 1


def test_missing_password_file(tmp_path):
    with pytest.raises(lc.LiveClientError) as ei:
        lc.read_password(str(tmp_path))
    assert ei.value.kind == "auth"


def test_poll_and_deadline(fake_rcon):
    srv = fake_rcon()
    c = client_for(srv)
    seq = iter([0, 0, 3])
    assert c.poll(lambda: next(seq), timeout=5, interval=0.01) == 3
    import time as _t
    c.deadline = _t.monotonic() + 0.05
    assert c.poll(lambda: 0, timeout=10, interval=0.01) == 0
    assert c.time_left() <= 0.05


@pytest.mark.parametrize("value", [0, -1, lc.HARD_REQUEST_CAP + 1, 1.5, "8192", True, None])
def test_max_request_bytes_is_capped(value):
    c = lc.LiveClient(27101, "pw")
    with pytest.raises(lc.LiveClientError) as ei:
        c.max_request_bytes = value
    assert ei.value.kind == "refused"
    assert c.max_request_bytes == lc.DEFAULT_MAX_REQUEST_BYTES
    c.max_request_bytes = lc.HARD_REQUEST_CAP
    assert c.max_request_bytes == lc.HARD_REQUEST_CAP


def test_oversized_packet_is_refused(fake_rcon):
    """Пакет больше MAX_RESPONSE_BYTES (1 МБ) не читается — ошибка protocol, а не мегабайты мусора."""
    assert lc.MAX_RESPONSE_BYTES == 1024 * 1024
    srv = fake_rcon(handler=lambda cmd: "x" * (lc.MAX_RESPONSE_BYTES + 10))
    with client_for(srv) as c:
        with pytest.raises(lc.LiveClientError) as ei:
            c.call("hello")
        assert ei.value.kind == "protocol" and "размер" in ei.value.message
