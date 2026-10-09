"""Общие штуки для тестов стенда: путь к tools/pc и фейковый RCON-сервер Factorio."""
from __future__ import annotations

import json
import os
import socket
import struct
import sys
import threading
import time

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
PC_DIR = os.path.dirname(HERE)
REPO = os.path.normpath(os.path.join(PC_DIR, "..", ".."))
if PC_DIR not in sys.path:
    sys.path.insert(0, PC_DIR)

PASSWORD = "s3cr3t-test-pw-0123456789abcdef"


def _pack(pid, ptype, body: bytes) -> bytes:
    payload = struct.pack("<ii", pid, ptype) + body + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def _recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError
        buf += chunk
    return buf


class FakeRcon:
    """Мини-RCON как у Factorio. handler(command:str) -> str | None (None = закрыть соединение).

    Опции: password, max_packet (больше — закрыть соединение, как неизвестный предел),
    stale_first (перед ответом прислать запоздавший ответ с чужим id), empty_before_auth.
    """

    def __init__(self, handler=None, password=PASSWORD, max_packet=None, stale_first=False,
                 empty_before_auth=False, delay=0.0):
        self.handler = handler or self.default_handler
        self.password = password
        self.max_packet = max_packet
        self.stale_first = stale_first
        self.empty_before_auth = empty_before_auth
        self.delay = delay
        self.commands = []
        self.auth_attempts = []
        self.connections = 0
        self._srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind(("127.0.0.1", 0))
        self._srv.listen(8)
        self.port = self._srv.getsockname()[1]
        self._stop = False
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    @staticmethod
    def default_handler(command):
        if command == "/quit":
            return None
        env = json.loads(command[len("/partner "):])
        return json.dumps({"v": 1, "id": env["id"], "ok": True, "tick": 100, "seq": 0,
                           "data": {"op": env["op"], "len": len(command[len("/partner "):].encode())}})

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
            self.connections += 1
            threading.Thread(target=self._client, args=(conn,), daemon=True).start()

    def _client(self, conn):
        authed = False
        try:
            while True:
                (size,) = struct.unpack("<i", _recv_exact(conn, 4))
                if self.max_packet is not None and size > self.max_packet:
                    conn.close()
                    return
                data = _recv_exact(conn, size)
                pid, ptype = struct.unpack("<ii", data[:8])
                body = data[8:-2].decode("utf-8")
                if ptype == 3:
                    self.auth_attempts.append(body)
                    if self.empty_before_auth:
                        conn.sendall(_pack(pid, 0, b""))
                    ok = body == self.password
                    authed = ok
                    conn.sendall(_pack(pid if ok else -1, 2, b""))
                    continue
                if not authed:
                    conn.close()
                    return
                self.commands.append(body)
                if self.delay:
                    time.sleep(self.delay)
                reply = self.handler(body)
                if reply is None:
                    conn.close()
                    return
                if self.stale_first:
                    conn.sendall(_pack(pid + 1000, 0, b'{"id":"old","ok":true}'))
                conn.sendall(_pack(pid, 0, reply if isinstance(reply, bytes) else reply.encode("utf-8")))
        except (ConnectionError, OSError, struct.error):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def close(self):
        self._stop = True
        try:
            self._srv.close()
        except OSError:
            pass


@pytest.fixture
def fake_rcon():
    servers = []

    def make(**kw):
        s = FakeRcon(**kw)
        servers.append(s)
        return s

    yield make
    for s in servers:
        s.close()
