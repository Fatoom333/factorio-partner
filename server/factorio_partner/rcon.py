"""RCON connection to the game (PROTOCOL.md §1, §5).

Built on ``factorio-rcon-py`` (``AsyncRCONClient``). Two small overrides:
  * responses are decoded as UTF-8 with ``errors="replace"`` (the library is strict and would
    drop a whole response for one broken byte);
  * the declared packet length is bounded, so a broken peer cannot make us allocate gigabytes.

One connection = one command at a time (``asyncio.Lock``); RCON packet ids are checked by the
library. Any failure closes the socket; the next call reconnects.

This is the single place that sends anything to the game, and it only sends the mod command
``/partner <one line of JSON>``. Anything else is refused before touching the socket.
"""
from __future__ import annotations

import asyncio
import logging
import struct
from typing import Callable

from factorio_rcon import (AsyncRCONClient, InvalidPassword, InvalidResponse, RCONBaseError,
                           RCONMessage)

from .errors import ConfigError

log = logging.getLogger("factorio_partner.rcon")

PARTNER_PREFIX = "/partner "
# PROTOCOL §2: mod response ≤ 200 000 bytes. Leave headroom for the envelope.
MAX_PACKET = 1024 * 1024
CONNECT_TIMEOUT = 3.0


class RconError(Exception):
    """Transport failure (connection, timeout, broken packet). Text is safe to log."""


class RconAuthError(RconError):
    """Wrong RCON password; retrying will not help."""


class RconTimeout(RconError):
    pass


class _Client(AsyncRCONClient):
    @classmethod
    def parse_message(cls, message: bytes, length: int) -> RCONMessage:
        try:
            data = struct.unpack(cls.message_format.format(length - cls.fixed_length), message)
        except struct.error as exc:
            raise InvalidResponse("unparsable RCON packet") from exc
        body = data[3].decode("utf-8", errors="replace") if data[3] else None
        return RCONMessage(data[1], data[2], body)

    @staticmethod
    async def receive_exactly(rcon_socket, size: int) -> bytes:
        if size < 0 or size > MAX_PACKET:
            raise InvalidResponse("RCON packet length out of bounds")
        return await AsyncRCONClient.receive_exactly(rcon_socket, size)


def check_command(command: str) -> None:
    """Allow only ``/partner <single-line JSON object>``."""
    if not isinstance(command, str) or not command.startswith(PARTNER_PREFIX):
        raise ValueError("only the /partner mod command may be sent")
    rest = command[len(PARTNER_PREFIX):]
    if not rest.startswith("{") or any(c in command for c in "\r\n\x00"):
        raise ValueError("the /partner parameter must be one line of JSON")


class RconConnection:
    """One authenticated RCON socket, used strictly sequentially."""

    def __init__(self, host: str, port: int, password: Callable[[], str], name: str = "cmd",
                 connect_timeout: float = CONNECT_TIMEOUT):
        if host != "127.0.0.1":
            # config.py already maps localhost -> 127.0.0.1; this is a second fence.
            raise ValueError("RCON host must be 127.0.0.1")
        self.host = host
        self.port = port
        self._password = password
        self.name = name
        self.connect_timeout = connect_timeout
        self._client: _Client | None = None
        self._lock = asyncio.Lock()

    @property
    def connected(self) -> bool:
        c = self._client
        return c is not None and c.rcon_socket is not None and not c.rcon_failure

    async def _connect(self) -> None:
        await self._drop()
        try:
            password = self._password()
        except ConfigError as exc:
            # a config problem (password file missing/empty): retrying will not help.
            # ConfigError texts never include the file content.
            raise RconAuthError(f"server config: {exc}") from None
        client = _Client(self.host, self.port, password)
        del password
        try:
            async with asyncio.timeout(self.connect_timeout):
                await client.connect()
        except InvalidPassword:
            await _safe_close(client)
            raise RconAuthError("RCON authentication failed") from None
        except (TimeoutError, RCONBaseError, OSError) as exc:
            await _safe_close(client)
            raise RconError(f"connect failed ({type(exc).__name__})") from None
        finally:
            # do not keep the password on the client object longer than needed
            client.password = ""
        self._client = client
        log.info("rcon %s connected to %s:%s", self.name, self.host, self.port)

    async def _drop(self) -> None:
        c, self._client = self._client, None
        if c is not None:
            await _safe_close(c)

    async def close(self) -> None:
        async with self._lock:
            await self._drop()

    async def execute(self, command: str, timeout: float) -> str:
        """Send one command and return the response body (may be empty)."""
        check_command(command)
        async with self._lock:
            try:
                if not self.connected:
                    await self._connect()
                assert self._client is not None
                async with asyncio.timeout(timeout):
                    body = await self._client.send_command(command)
                return body or ""
            except RconError:
                await self._drop()
                raise
            except TimeoutError:
                await self._drop()
                raise RconTimeout(f"no response within {timeout:g}s") from None
            except (RCONBaseError, OSError) as exc:
                await self._drop()
                raise RconError(f"{type(exc).__name__}") from None
            except BaseException:
                # cancelled by the caller: the response is still in flight, so this socket
                # must not be reused (the next command would read a stale reply)
                await self._drop()
                raise


async def _safe_close(client: AsyncRCONClient) -> None:
    try:
        await client.close()
    except Exception:  # noqa: BLE001 - closing a broken socket must never fail the caller
        client.rcon_socket = None
