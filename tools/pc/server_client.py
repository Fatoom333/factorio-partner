"""Запуск живого сценария через НАСТОЯЩИЙ пакет сервера (docs/TESTING.md §4, docs/E2E.md).

Сценарий с `RUNNER = "server"` получает не голого LiveClient, а `ServerClient`: его `tool(...)` зовёт
`op_*` из `server/factorio_partner/core.py` — тот же код, что стоит за инструментами MCP `partner_*`
(ключ помощника, проверка аргументов, bridge с двумя RCON-соединениями, курсоры событий, blob_put,
forge), только без слоя stdio. Так проверяется MCP-сервер с настоящим модом.

Что остаётся в силе:
- в игру уходит только `/partner <JSON>`: и `rcon.py` сервера, и `live_client.py` другого не шлют;
  никаких /c, /sc, /silent-command;
- RCON только 127.0.0.1 (это проверяют и Config сервера, и LiveClient);
- пароль RCON читается из `<dir>/rcon.pw`, ключ помощника создаётся на один запуск в
  `<dir>/fp-home/helpers.json`; ни тот, ни другой не попадают в results и журналы;
- forge подключается только путями из `stand.json` (их туда кладёт pack.py из pc.local.json или
  окружения запуска); профиль forge сервер не активирует (MCP.md).

Запуск (на ПК это делает stand.ps1, Python ≥ 3.11 с `factorio-rcon-py[async]`):
    python server_client.py run --slot N --dir <папка слота> --scenario NAME [--timeout 600]
Сценарию, кроме `tool`, доступно всё, что есть у LiveClient (`call`, `call_ok`, `poll`, `sleep`,
`time_left`) — для сверки с игрой в обход сервера.
Синтаксис — совместимый с Python 3.9 (общая проверка стенда), сам запуск требует 3.11+.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import re
import secrets
import shutil
import sys
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:      # python -I не кладёт папку скрипта в sys.path
    sys.path.insert(0, HERE)

import live_client as lc  # noqa: E402

DEFAULT_HELPER = "e2e"
HELPER_RE = re.compile(r"^[a-z0-9_-]{1,16}$")
MIN_PYTHON = (3, 11)
# инструмент агента (MCP.md) -> метод Core; служебные — только те, что нужны стенду
TOOLS = {
    "brief": "op_brief", "state": "op_state", "map": "op_map", "resources": "op_resources",
    "stock": "op_stock", "status": "op_status", "find": "op_find", "access": "op_access", "ghosts": "op_ghosts", "rates": "op_rates",
    "recipes": "op_recipes", "act": "op_act", "cancel": "op_cancel", "wait": "op_wait",
    "reflex": "op_reflex", "say": "op_say", "plan": "op_plan",
}
ADMIN = {"hello": "admin_hello", "spawn": "admin_spawn", "remove": "admin_remove", "limit": "admin_limit"}
CALL_MARGIN_S = 15.0          # запас к самому долгому вызову (partner_wait ≤ 55 с)
SLOW_TOOLS = {"wait": 55.0 + CALL_MARGIN_S, "plan": 260.0, "brief": 90.0, "act": 60.0}
DEFAULT_CALL_S = 45.0


class ToolError(Exception):
    """Отказ сервера или мода: `code` — как видит агент (PROTOCOL §3, MCP.md «Ошибки сервера»)."""

    def __init__(self, code: str, text: Optional[str] = None):
        super().__init__(code if not text else f"{code}: {text}")
        self.code = code
        self.text = text


def server_dir() -> str:
    """Где лежит пакет `factorio_partner`: рядом (пакет стенда) или в репозитории (`server/`)."""
    for cand in (os.path.join(HERE, "server"), os.path.normpath(os.path.join(HERE, "..", "..", "server"))):
        if os.path.isfile(os.path.join(cand, "factorio_partner", "core.py")):
            return cand
    raise lc.LiveClientError("refused", "нет пакета сервера factorio_partner рядом со стендом")


ENV_KEYS = {"FP_FORGE": "forge", "FACTORIO_FORGE_HOME": "forge_home", "FP_FORGE_PROFILE": "forge_profile"}


def load_stand_config(slot_dir: str, env: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    """`stand/stand.json` слота (кладёт pack.py).

    Файла нет — запуск не из пакета стенда (`run-live.ps1 -Local` или руками): настройки forge тогда
    берутся из окружения `env`, теми же переменными, что читает сам сервер (MCP.md); env=None — {}."""
    for path in (os.path.join(HERE, "stand.json"), os.path.join(slot_dir, "stand", "stand.json")):
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if isinstance(data, dict):
            return data
    return {key: env[var] for var, key in ENV_KEYS.items() if env.get(var)} if env else {}


def forge_settings(stand: Dict[str, Any]) -> Dict[str, Optional[str]]:
    """Пути forge из stand.json → {forge, forge_home, forge_profile} (None — не задано).

    `forge` — checkout с `.venv` (FP_FORGE), `forge_home` — дом forge с профилями
    (FACTORIO_FORGE_HOME). Если `forge` пуст, а `forge_home` сам оказался checkout'ом (в нём есть
    `.venv`), он и берётся как checkout, дом forge тогда стандартный: так работает запись «одним
    ключом forge_home»."""
    def text(key: str) -> Optional[str]:
        v = stand.get(key)
        return v if isinstance(v, str) and v.strip() else None

    forge, home, profile = text("forge"), text("forge_home"), text("forge_profile")
    if forge is None and home is not None and _has_venv(home):
        forge, home = home, None
    return {"forge": forge, "forge_home": home, "forge_profile": profile}


def _has_venv(path: str) -> bool:
    return any(os.path.isfile(os.path.join(path, ".venv", *tail))
               for tail in (("Scripts", "python.exe"), ("bin", "python")))


def forge_info(settings: Dict[str, Optional[str]]) -> Dict[str, Any]:
    """Что о forge можно положить в results: признаки без путей."""
    forge = settings.get("forge")
    return {"configured": forge is not None,
            "checkout_found": bool(forge and os.path.isdir(forge)),
            "venv_found": bool(forge and _has_venv(forge)),
            "home_set": settings.get("forge_home") is not None,
            "profile_set": settings.get("forge_profile") is not None}


class _Loop:
    """Цикл asyncio в отдельной нити: сценарии синхронные, Core — нет."""

    def __init__(self) -> None:
        self.loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._run, name="fp-core-loop", daemon=True)
        self._thread.start()

    def _run(self) -> None:
        asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def run(self, coro: Any, timeout: float) -> Any:
        fut = asyncio.run_coroutine_threadsafe(coro, self.loop)
        try:
            return fut.result(timeout)
        except BaseException:
            fut.cancel()
            raise

    def stop(self) -> None:
        self.loop.call_soon_threadsafe(self.loop.stop)
        self._thread.join(timeout=5.0)
        if not self._thread.is_alive():
            self.loop.close()


class ServerClient:
    """Клиент сценария поверх настоящего `Core`. Ключ помощника подставляется сам."""

    def __init__(self, live: Any, core: Any, loop: _Loop, helper: str, key: str,
                 partner_error: type, forge: Optional[Dict[str, Any]] = None):
        self.live = live
        self.core = core
        self.helper = helper
        self.forge = forge or forge_info({})
        self._key = key
        self._loop = loop
        self._partner_error = partner_error
        self.calls = 0
        self.log_handler: Optional[logging.Handler] = None
        self._closed = False

    def __repr__(self) -> str:  # без ключа
        return f"ServerClient(helper={self.helper!r})"

    # ---- то же, что у LiveClient: сверка с игрой в обход сервера ----
    def call(self, *a: Any, **kw: Any) -> Dict[str, Any]:
        return self.live.call(*a, **kw)

    def call_ok(self, *a: Any, **kw: Any) -> Any:
        return self.live.call_ok(*a, **kw)

    def poll(self, *a: Any, **kw: Any) -> Any:
        return self.live.poll(*a, **kw)

    def sleep(self, seconds: float) -> None:
        self.live.sleep(seconds)

    def time_left(self) -> float:
        return self.live.time_left()

    @property
    def sent(self) -> int:
        return self.live.sent

    # ---- сервер ----
    def _budget(self, name: str) -> float:
        want = SLOW_TOOLS.get(name, DEFAULT_CALL_S)
        left = self.live.time_left()
        if left <= 0:
            raise lc.LiveClientError("transport", "время сценария вышло")
        return max(1.0, min(want, left))

    def _invoke(self, name: str, method: Any, /, *a: Any, **kw: Any) -> Any:
        budget = self._budget(name)      # до создания корутины: вышло время — её не будет вовсе
        self.calls += 1
        try:
            return self._loop.run(method(*a, **kw), budget)
        except self._partner_error as e:
            raise ToolError(str(getattr(e, "code", "internal")), getattr(e, "text", None)) from None
        except TimeoutError:
            raise lc.LiveClientError("transport", f"сервер не ответил на {name} вовремя") from None

    def tool(self, name: str, /, **args: Any) -> Dict[str, Any]:
        """Инструмент агента `partner_<name>` (MCP.md). Отказ — ToolError с кодом."""
        return self.tool_as(name, self.helper, self._key, **args)

    def tool_as(self, name: str, helper: Any, key: Any, /, **args: Any) -> Dict[str, Any]:
        """То же с явными `helper` и `key` — для проверки отказа в доступе."""
        method = TOOLS.get(name)
        if method is None:
            raise lc.LiveClientError("refused", f"нет инструмента partner_{name}")
        return self._invoke(name, getattr(self.core, method), helper, key, **args)

    def try_tool(self, name: str, /, **args: Any) -> Dict[str, Any]:
        """`{"ok": True, "data": ...}` или `{"ok": False, "error": {"code", "text"}}`."""
        try:
            return {"ok": True, "data": self.tool(name, **args)}
        except ToolError as e:
            return {"ok": False, "error": {"code": e.code, "text": e.text}}

    def admin(self, name: str, /, **args: Any) -> Dict[str, Any]:
        """Служебная операция оркестра (`admin_<name>`): hello, spawn, remove, limit."""
        method = ADMIN.get(name)
        if method is None:
            raise lc.LiveClientError("refused", f"нет служебной операции admin_{name}")
        return self._invoke(name, getattr(self.core, method), **args)

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        try:
            self._loop.run(self.core.close(), 10.0)
        except Exception:  # закрытие не должно портить итог сценария
            pass
        self._loop.stop()
        handler, self.log_handler = self.log_handler, None
        if handler is not None:
            logging.getLogger("factorio_partner").removeHandler(handler)
            handler.close()


def make_client(live: Any, module: Any, secrets_out: List[str], slot_dir: str, port: int,
                stand: Optional[Dict[str, Any]] = None, log_file: Optional[str] = None) -> ServerClient:
    """Поднять настоящий `Core` против RCON слота и вернуть клиента сценария."""
    if sys.version_info < MIN_PYTHON:
        raise lc.LiveClientError("refused", "пакету сервера нужен Python ≥ %d.%d" % MIN_PYTHON)
    helper = getattr(module, "HELPER", DEFAULT_HELPER)
    if not isinstance(helper, str) or not HELPER_RE.match(helper):
        raise lc.LiveClientError("refused", "HELPER сценария: ^[a-z0-9_-]{1,16}$")
    sdir = server_dir()
    if sdir not in sys.path:
        sys.path.insert(0, sdir)
    try:
        from factorio_partner.config import Config
        from factorio_partner.core import Core
        from factorio_partner.errors import PartnerError
    except ImportError as e:
        raise lc.LiveClientError(
            "refused", f"пакет сервера не импортируется ({e.name or type(e).__name__}): нужен Python с "
                       "factorio-rcon-py[async] — docs/E2E.md «Подготовка ПК»") from None

    home = Path(slot_dir) / "fp-home"
    home.mkdir(parents=True, exist_ok=True)
    key = secrets.token_hex(24)
    secrets_out.append(key)
    helpers_file = home / "helpers.json"
    helpers_file.write_text(json.dumps({helper: key}), encoding="utf-8")
    settings = forge_settings(stand or {})
    cfg = Config(home=home, rcon_host=lc.RCON_HOST, rcon_port=port,
                 rcon_password_file=Path(slot_dir) / "rcon.pw",
                 forge=Path(settings["forge"]) if settings["forge"] else None,
                 forge_profile=settings["forge_profile"],
                 forge_home=Path(settings["forge_home"]) if settings["forge_home"] else None)
    handler = None
    if log_file:
        handler = logging.FileHandler(log_file, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
        root = logging.getLogger("factorio_partner")
        root.addHandler(handler)
        root.setLevel(logging.INFO)

    loop = _Loop()

    async def build() -> Any:
        return Core(cfg)

    try:
        core = loop.run(build(), 10.0)
    except BaseException:
        loop.stop()
        if handler is not None:
            logging.getLogger("factorio_partner").removeHandler(handler)
            handler.close()
        raise
    client = ServerClient(live, core, loop, helper, key, PartnerError, forge_info(settings))
    client.log_handler = handler
    return client


def collect_logs(slot: int, slot_dir: str, helper: str) -> None:
    """Журнал вызовов помощника (`FP_HOME/logs/<helper>.jsonl`, без ключа и без чертежей) → out/."""
    src = os.path.join(slot_dir, "fp-home", "logs", helper + ".jsonl")
    if os.path.isfile(src):
        try:
            shutil.copyfile(src, os.path.join(slot_dir, "out", f"calls-{slot}.jsonl"))
        except OSError:
            pass


def run_scenario(slot: int, slot_dir: str, scenario: str, timeout: float,
                 scenario_directory: Optional[str] = None, port: Optional[int] = None) -> Dict[str, Any]:
    """Как `live_client.run_scenario`, но сценарию отдаётся `ServerClient`."""
    stand = load_stand_config(slot_dir, os.environ)
    out_dir = os.path.join(slot_dir, "out")
    os.makedirs(out_dir, exist_ok=True)
    made: List[ServerClient] = []

    def wrap(live: Any, module: Any, secrets_out: List[str]) -> ServerClient:
        client = make_client(live, module, secrets_out, slot_dir, port or lc.rcon_port(slot), stand,
                             os.path.join(out_dir, f"server-{slot}.log"))
        made.append(client)
        return client

    try:
        return lc.run_scenario(slot, slot_dir, scenario, timeout, scenario_directory, wrap=wrap)
    finally:
        for client in made:
            collect_logs(slot, slot_dir, client.helper)
        try:  # ключ жил один запуск
            os.remove(os.path.join(slot_dir, "fp-home", "helpers.json"))
        except OSError:
            pass


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description="Живой сценарий через настоящий пакет сервера factorio_partner")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("run")
    p.add_argument("--slot", type=int, required=True)
    p.add_argument("--dir", required=True)
    p.add_argument("--scenario", required=True)
    p.add_argument("--timeout", type=float, default=600.0)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, ValueError):
            pass
    ns = parser.parse_args(argv)
    try:
        lc._check_slot(ns.slot)
    except lc.LiveClientError as e:
        print(e.message, file=sys.stderr)
        return 2
    result = run_scenario(ns.slot, ns.dir, ns.scenario, ns.timeout)
    print(json.dumps({"ok": result.get("ok"), "error": result.get("error")}, ensure_ascii=False))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
