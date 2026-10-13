"""Fake RCON server + fake mod for tests (docs/TESTING.md §2).

``FakeRcon`` speaks the RCON wire protocol on 127.0.0.1 (random port) and passes every
``/partner <json>`` to ``FakeMod``. Per-command faults (``faults`` queue) simulate a lost reply,
a slow reply, out-of-order / stale replies, garbage and broken UTF-8.
``FakeMod`` mimics the mod's envelope, ``recent`` idempotency ring, tick/seq and event buffer.
"""
from __future__ import annotations

import asyncio
import json
import struct
from collections import Counter, deque
from typing import Any, Callable

AUTH, AUTH_RESPONSE, EXEC, RESPONSE = 3, 2, 2, 0


class FakeModError(Exception):
    def __init__(self, code: str, text: str = ""):
        self.code, self.text = code, text


class FakeMod:
    def __init__(self):
        self.tick = 1000
        self.tick_step = 1          # tick grows by this on every executed request
        self.seq = 0
        self.events: list[dict] = []
        self.recent: dict[str, dict] = {}
        self.executed: Counter = Counter()
        self.requests: list[dict] = []
        self.handlers: dict[str, Callable[[dict, dict], Any]] = {}
        self.next_job = 1
        self.blobs: dict[str, dict[int, str]] = {}
        self.blob_totals: dict[str, int] = {}

    # events
    def emit(self, kind: str, data: dict | None = None, helper: str | None = "h1", loud: bool = True) -> dict:
        self.seq += 1
        ev = {"seq": self.seq, "tick": self.tick, "helper": helper, "kind": kind,
              "data": data or {}, "loud": loud}
        self.events.append(ev)
        return ev

    def handle(self, env: dict) -> dict:
        rid = env.get("id")
        if rid in self.recent:
            return self.recent[rid]
        self.requests.append(env)
        op = env.get("op")
        self.executed[op] += 1
        self.tick += self.tick_step
        try:
            fn = self.handlers.get(op) or getattr(self, "op_" + str(op), None)
            if fn is None:
                raise FakeModError("unknown_op", str(op))
            data = fn(env.get("args") or {}, env)
            resp = {"v": 1, "id": rid, "ok": True, "tick": self.tick, "seq": self.seq, "data": data}
        except FakeModError as e:
            resp = {"v": 1, "id": rid, "ok": False, "tick": self.tick, "seq": self.seq,
                    "error": {"code": e.code, "text": e.text}}
        self.recent[rid] = resp
        return resp

    # default ops
    def op_hello(self, args, env):
        return {"proto": 1, "mod": "0.1.0", "tick": self.tick, "seq": self.seq, "owner": "Tartaluga",
                "players": [], "helpers": ["h1"]}

    def op_events(self, args, env):
        since = args.get("since", 0)
        helper = args.get("helper")
        limit = args.get("limit", 100)
        evs = [e for e in self.events if e["seq"] > since and (helper is None or e["helper"] in (helper, None))]
        lost = bool(self.events) and since < self.events[0]["seq"] - 1
        return {"seq": self.seq, "events": evs[:limit], "lost": lost}

    def op_act(self, args, env):
        job = self.next_job
        self.next_job += 1
        return {"job": job, "queued_before": 0}

    def op_state(self, args, env):
        return {"helper": env.get("helper"), "pos": {"x": 1.5, "y": 2.5}, "body": "character",
                "module_errors": 0, "tick": self.tick, "seq": self.seq}

    def op_blob_put(self, args, env):
        b = args["blob"]
        self.blobs.setdefault(b, {})[args["part"]] = args["data"]
        self.blob_totals[b] = args["total"]
        return {"blob": b, "received": len(self.blobs[b]), "total": args["total"]}

    def op_cancel(self, args, env):
        return {"cancelled": [args["job"]] if "job" in args else []}

    def op_say(self, args, env):
        return {}

    def op_reflexes(self, args, env):
        return {"set": args.get("set", [])}

    def op_map(self, args, env):
        return {"rows": ["..."], "truncated": False}

    op_resources = op_stock = op_ghosts = op_rates = op_map

    def op_helper_spawn(self, args, env):
        return {"helper": env.get("helper"), "unit_number": 7, "surface": "nauvis", "pos": {"x": 0, "y": 0}}

    def op_helper_remove(self, args, env):
        return {}

    def blob_text(self, blob: str) -> str:
        parts = self.blobs[blob]
        return "".join(parts[i] for i in range(1, self.blob_totals[blob] + 1))


class FakeRcon:
    """RCON server on 127.0.0.1. ``faults`` — queue of per-command faults:
    ``"drop"`` (execute, never reply), ``("delay", s)``, ``"wrong_packet_id"``,
    ``"stale"`` (reply with the previous envelope), ``"garbage"``, ``"bad_utf8"``, ``"close"``,
    ``"empty"``.
    """

    def __init__(self, mod: FakeMod | None = None, password: str = "test-password-123"):
        self.mod = mod or FakeMod()
        self.password = password
        self.faults: deque = deque()
        self.commands: list[str] = []
        self.connections = 0
        self.auth_failures = 0
        self._server: asyncio.base_events.Server | None = None
        self._last_resp: dict | None = None
        self.port = 0

    async def start(self) -> "FakeRcon":
        self._server = await asyncio.start_server(self._client, "127.0.0.1", 0)
        self.port = self._server.sockets[0].getsockname()[1]
        return self

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            try:
                await asyncio.wait_for(self._server.wait_closed(), 1)
            except (asyncio.TimeoutError, TimeoutError):
                pass

    @staticmethod
    def packet(pid: int, ptype: int, body: bytes) -> bytes:
        return struct.pack("<iii", 10 + len(body), pid, ptype) + body + b"\0\0"

    async def _client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.connections += 1
        try:
            while True:
                head = await reader.readexactly(4)
                length = int.from_bytes(head, "little")
                rest = await reader.readexactly(length)
                pid, ptype = struct.unpack("<ii", rest[:8])
                body = rest[8:-2].decode("utf-8")
                if ptype == AUTH:
                    ok = body == self.password
                    if not ok:
                        self.auth_failures += 1
                    writer.write(self.packet(pid if ok else -1, AUTH_RESPONSE, b""))
                    await writer.drain()
                    continue
                await self._exec(pid, body, writer)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def _exec(self, pid: int, body: str, writer: asyncio.StreamWriter) -> None:
        self.commands.append(body)
        fault = self.faults.popleft() if self.faults else None
        assert body.startswith("/partner "), body
        env = json.loads(body[len("/partner "):])
        resp = self.mod.handle(env)
        prev, self._last_resp = self._last_resp, resp
        if fault == "drop":
            return
        if fault == "close":
            writer.close()
            return
        if isinstance(fault, tuple) and fault[0] == "delay":
            await asyncio.sleep(fault[1])
        out = json.dumps(resp, ensure_ascii=False).encode("utf-8")
        if fault == "wrong_packet_id":
            pid = pid + 1000
        elif fault == "stale":
            out = json.dumps(prev or {"v": 1, "id": "old", "ok": True}, ensure_ascii=False).encode("utf-8")
        elif fault == "garbage":
            out = b"Unknown command \"partner\"."
        elif fault == "empty":
            out = b""
        elif fault == "bad_utf8":
            out = out.replace(b"BROKEN", b"\xff\xfe")
        try:
            writer.write(self.packet(pid, RESPONSE, out))
            await writer.drain()
        except ConnectionError:
            pass
