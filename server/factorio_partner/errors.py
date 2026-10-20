"""Errors shown to the agent. The text must never contain keys, passwords or blueprint strings."""


class PartnerError(Exception):
    """A refusal or failure with a code from PROTOCOL.md §3 or MCP.md «Ошибки сервера».

    ``str(err)`` is what the agent sees: ``code`` alone, or ``code: text``.
    """

    def __init__(self, code: str, text: str | None = None, detail: dict | None = None):
        self.code = code
        self.text = text
        self.detail = detail
        super().__init__(code if not text else f"{code}: {text}")


class ConfigError(Exception):
    """Bad server configuration (refuse to start)."""


ACCESS_DENIED = "access denied"
TRANSPORT_TIMEOUT = "transport_timeout"
GAME_PAUSED = "game_paused"
RESPONSE_TOO_LARGE = "response too large"
REPEATED_FAILURE = "repeated_failure"
# the owner's settings of the mod (perm-* in the map settings): «нельзя» and «спросить» without his «да»
OWNER_FORBIDS = "owner_forbids"
NEEDS_OWNER_OK = "needs_owner_ok"
