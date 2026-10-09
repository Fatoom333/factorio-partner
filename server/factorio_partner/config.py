"""Server settings from the environment (docs/MCP.md «Доступ и настройки").

The RCON password is never stored here: only the path to the file. ``rcon.py`` reads the file
at connect time, so the password never sits in a long-lived object that could be logged.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from .errors import ConfigError

DEFAULT_RCON_PORT = 27015
# Only loopback. "localhost" is mapped to the literal 127.0.0.1 so that a hosts-file entry
# or IPv6 resolution can never send the password anywhere else.
_ALLOWED_HOSTS = {"127.0.0.1": "127.0.0.1", "localhost": "127.0.0.1"}


def _default_home(env: Mapping[str, str]) -> Path:
    base = env.get("LOCALAPPDATA")
    if base:
        return Path(base) / "factorio-partner"
    return Path.home() / ".local" / "share" / "factorio-partner"


@dataclass(frozen=True)
class Config:
    home: Path
    rcon_host: str = "127.0.0.1"
    rcon_port: int = DEFAULT_RCON_PORT
    rcon_password_file: Path | None = None
    forge: Path | None = None
    forge_profile: str | None = None
    forge_home: Path | None = None

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Config":
        env = os.environ if env is None else env
        home = Path(env["FP_HOME"]).expanduser() if env.get("FP_HOME") else _default_home(env)

        host_raw = (env.get("FP_RCON_HOST") or "127.0.0.1").strip().lower()
        host = _ALLOWED_HOSTS.get(host_raw)
        if host is None:
            raise ConfigError("FP_RCON_HOST must be 127.0.0.1 or localhost")

        port_raw = (env.get("FP_RCON_PORT") or str(DEFAULT_RCON_PORT)).strip()
        try:
            port = int(port_raw)
        except ValueError:
            raise ConfigError("FP_RCON_PORT must be an integer") from None
        if not 1 <= port <= 65535:
            raise ConfigError("FP_RCON_PORT must be 1..65535")

        pw = env.get("FP_RCON_PASSWORD_FILE")
        forge = env.get("FP_FORGE")
        profile = (env.get("FP_FORGE_PROFILE") or "").strip() or None
        fhome = env.get("FACTORIO_FORGE_HOME")
        if not fhome:
            appdata = env.get("APPDATA")
            fhome = str(Path(appdata) / "factorio-forge") if appdata else None
        return cls(
            home=home,
            rcon_host=host,
            rcon_port=port,
            rcon_password_file=Path(pw).expanduser() if pw else None,
            forge=Path(forge).expanduser() if forge else None,
            forge_profile=profile,
            forge_home=Path(fhome).expanduser() if fhome else None,
        )

    # paths under FP_HOME
    @property
    def helpers_file(self) -> Path:
        return self.home / "helpers.json"

    @property
    def logs_dir(self) -> Path:
        return self.home / "logs"

    @property
    def plans_dir(self) -> Path:
        return self.home / "plans"

    def read_password(self) -> str:
        """Read the RCON password. Errors never include the file content."""
        if self.rcon_password_file is None:
            raise ConfigError("FP_RCON_PASSWORD_FILE is not set")
        try:
            # only the line break is dropped: spaces belong to the password
            pw = self.rcon_password_file.read_text(encoding="utf-8-sig").rstrip("\r\n")
        except OSError:
            raise ConfigError("cannot read the RCON password file") from None
        if not pw:
            raise ConfigError("the RCON password file is empty")
        return pw
