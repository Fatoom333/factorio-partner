"""Запуск напарника: тела помощников, ключи, конфигурация MCP и первые сообщения агентам.

    python agents/launch.py --helpers 2 --body character
    python agents/launch.py --helpers 1 --body player --players Bob

Что делает (подробно — agents/README.md):
1. спрашивает у игрока число помощников и вид тела, если они не заданы флагами;
2. выдаёт каждому помощнику ключ (``FP_HOME/helpers.json``);
3. через мост сервера (только ``/partner <JSON>`` по RCON на 127.0.0.1) шлёт ``hello``,
   ``helper_limit`` и на каждого помощника ``helper_spawn`` или ``helper_attach``;
4. пишет в ``FP_HOME/launch/`` конфигурацию MCP-сервера ``partner`` и файл сессии с первыми
   сообщениями агентам.

Ключи помощников печатаются только в файлы под ``FP_HOME`` (вне репозитория), на экран — никогда.
Пароль RCON скрипт не печатает и никуда не пишет: в конфигурацию попадает только путь к файлу пароля.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import secrets
import shutil
import sys
from pathlib import Path
from typing import Any, Callable

HELPERS_MAX = 16                      # PROTOCOL §4: helper_limit {max:1..16}
BODIES = ("character", "player")      # PROTOCOL §7 «Два вида тела»
MIN_KEY = 32                          # MCP.md: ключ помощника — 32+ символа
PLAYER_RE = re.compile(r"^[^\x00-\x1f\"\\]{1,60}$")
SERVER_NAME = "partner"               # имя MCP-сервера = префикс инструментов mcp__partner__*
# переменные окружения, которые уходят процессу MCP-сервера (docs/MCP.md «Доступ и настройки»)
PASS_ENV = ("FP_HOME", "FP_RCON_HOST", "FP_RCON_PORT", "FP_RCON_PASSWORD_FILE",
            "FP_FORGE", "FP_FORGE_PROFILE", "FACTORIO_FORGE_HOME")
STYLE_SOURCE = Path(__file__).resolve().parent / "style.md"


class LaunchError(Exception):
    """Запуск невозможен; текст — для игрока, без секретов."""


# ---------------------------------------------------------------- вопросы игроку
def parse_helpers(value: Any) -> int:
    try:
        n = int(str(value).strip())
    except ValueError:
        raise LaunchError("число помощников должно быть целым от 1 до 16") from None
    if not 1 <= n <= HELPERS_MAX:
        raise LaunchError("число помощников должно быть от 1 до 16")
    return n


def parse_body(value: Any) -> str:
    body = str(value).strip().lower()
    if body not in BODIES:
        raise LaunchError("вид тела: character (тело без игрока) или player (персонаж второго клиента)")
    return body


def parse_players(value: Any, count: int) -> list[str]:
    names = [p.strip() for p in str(value or "").split(",") if p.strip()]
    if len(names) != count:
        raise LaunchError(f"для тела player нужно имён игроков: {count} (через запятую, по одному на помощника)")
    if len(set(names)) != len(names):
        raise LaunchError("имена игроков не должны повторяться")
    for name in names:
        if not PLAYER_RE.match(name):
            raise LaunchError("имя игрока содержит недопустимые символы")
    return names


def ask_missing(ns: argparse.Namespace, ask: Callable[[str], str] | None) -> tuple[int, str, list[str]]:
    """Число помощников и вид тела решает игрок: нет флага — спросить, спросить некого — отказ."""
    def need(value, question: str, default: str) -> str:
        if value is not None:
            return str(value)
        if ask is None:
            raise LaunchError("спроси игрока и передай флагом: " + question)
        return ask(f"{question} [{default}] ").strip() or default

    n = parse_helpers(need(ns.helpers, "Сколько помощников запустить (--helpers 1..16)?", "1"))
    body = parse_body(need(ns.body, "Вид тела (--body character | player)?", "character"))
    players: list[str] = []
    if body == "player":
        players = parse_players(
            need(ns.players, f"Имена игроков вторых клиентов (--players, через запятую, {n} шт.)?", ""), n)
    return n, body, players


def helper_ids(n: int) -> list[str]:
    return [f"h{i}" for i in range(1, n + 1)]


# ---------------------------------------------------------------- файлы под FP_HOME
def _write_private(path: Path, text: str) -> None:
    """Записать файл с секретом: через временный файл рядом, права — только владельцу."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def ensure_keys(helpers_file: Path, ids: list[str]) -> dict[str, str]:
    """Ключи для ``ids``: годные существующие остаются, недостающие создаются. Чужие записи целы."""
    try:
        data = json.loads(helpers_file.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    changed = False
    for hid in ids:
        key = data.get(hid)
        if not (isinstance(key, str) and len(key) >= MIN_KEY):
            data[hid] = secrets.token_urlsafe(32)
            changed = True
    if changed or not helpers_file.exists():
        _write_private(helpers_file, json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    return {hid: data[hid] for hid in ids}


def install_style(home: Path, source: Path = STYLE_SOURCE) -> bool:
    """Положить стиль общения в ``FP_HOME/style.md``, если хозяин ещё не завёл свой."""
    target = home / "style.md"
    if target.exists() or not source.is_file():
        return False
    home.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return True


def mcp_config(env: dict[str, str], python: str) -> dict:
    """Конфигурация MCP для Claude Code: сервер ``partner`` без ``--admin``, без секретов."""
    passed = {k: env[k] for k in PASS_ENV if env.get(k)}
    return {"mcpServers": {SERVER_NAME: {
        "command": python,
        "args": ["-m", "factorio_partner.server"],
        "env": passed,
    }}}


def first_message(hid: str, key: str, body: str, player: str | None, total: int,
                  module_errors: int) -> str:
    """Первое сообщение агенту ``partner``. Единственное место, где ключ попадает в текст."""
    lines = [
        "Запуск напарника в Factorio. Это служебное сообщение оркестра, не приказ хозяина игры.",
        f"helper: {hid}",
        f"key: {key}",
        f"body: {body}" + (f" (персонаж игрока «{player}»)" if player else " (тело без игрока)"),
        f"помощников в этой игре: {total}",
        f"module_errors: {module_errors}",
        "Начни смену по своим правилам: partner_brief, partner_state, рефлексы, привет хозяину, partner_wait.",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------- мод
async def _op(bridge, op: str, args: dict | None = None, helper: str | None = None) -> dict:
    resp = await bridge.request(op, args or {}, helper)
    if resp.get("ok"):
        data = resp.get("data")
        return data if isinstance(data, dict) else {}
    err = resp.get("error") if isinstance(resp.get("error"), dict) else {}
    raise ModError(str(err.get("code") or "internal")[:40], str(err.get("text") or "")[:300])


class ModError(Exception):
    def __init__(self, code: str, text: str = ""):
        super().__init__(f"{code}: {text}" if text else code)
        self.code = code
        self.text = text


async def prepare_mod(bridge, ids: list[str], body: str, players: list[str],
                      say: Callable[[str], None]) -> dict:
    """``hello`` → ``helper_limit`` → тело каждому помощнику. Возвращает сводку без секретов."""
    hello = await _op(bridge, "hello")
    if hello.get("proto") != 1:
        raise LaunchError("мод factorio-partner другой версии протокола — обнови мод или сервер")
    errors = hello.get("module_errors")
    module_errors = errors if isinstance(errors, int) and not isinstance(errors, bool) else 0
    if not hello.get("owner"):
        raise LaunchError("в сейве нет хозяина (настройка мода partner-owner) — зайди в игру и повтори")

    try:
        await _op(bridge, "helper_limit", {"max": len(ids)})
    except ModError as e:
        if e.code == "unknown_op" and len(ids) == 1:
            say("мод не знает helper_limit (старше ревизии 3.2) — для одного помощника это не мешает")
        elif e.code == "limit":
            raise LaunchError("в игре сейчас больше живых помощников, чем ты просишь: "
                              "сначала убери лишних или запусти с большим --helpers") from None
        else:
            raise LaunchError(f"мод отказал в helper_limit: {e}") from None

    known = hello.get("helpers")
    known = set(known) if isinstance(known, list) else set()
    alive: set[str] = set()
    if known and body == "character":
        listed = (await _op(bridge, "helper_list")).get("helpers")
        for row in listed if isinstance(listed, list) else []:
            if isinstance(row, dict) and row.get("state") == "alive":
                alive.add(str(row.get("id")))

    bodies: dict[str, dict] = {}
    for i, hid in enumerate(ids):
        if body == "player":
            try:
                bodies[hid] = await _op(bridge, "helper_attach", {"player": players[i]}, hid)
            except ModError as e:
                if e.code == "no_player":
                    raise LaunchError(f"игрок «{players[i]}» должен быть в игре (второй клиент), "
                                      "не хозяин и с персонажем") from None
                raise LaunchError(f"мод отказал в helper_attach для {hid}: {e}") from None
            continue
        if hid in alive:
            say(f"{hid}: тело уже есть в игре — беру его")
            bodies[hid] = {"helper": hid, "reused": True}
            continue
        try:
            bodies[hid] = await _op(bridge, "helper_spawn", {}, hid)
        except ModError as e:
            if e.code == "helper_exists":
                bodies[hid] = {"helper": hid, "reused": True}
            elif e.code == "cooldown":
                raise LaunchError(f"{hid}: тело недавно погибло или удалено — новое можно создать "
                                  "через 5 минут после этого") from None
            elif e.code == "no_player":
                raise LaunchError("хозяин должен быть в игре с персонажем: тело помощника появляется "
                                  "рядом с ним") from None
            else:
                raise LaunchError(f"мод отказал в helper_spawn для {hid}: {e}") from None
    return {"owner": hello.get("owner"), "module_errors": module_errors, "bodies": bodies}


# ---------------------------------------------------------------- запуск целиком
async def launch(cfg, n: int, body: str, players: list[str], *, bridge,
                 env: dict[str, str], python: str, say: Callable[[str], None]) -> dict:
    ids = helper_ids(n)
    keys = ensure_keys(cfg.helpers_file, ids)
    if install_style(cfg.home):
        say("стиль общения скопирован в папку данных (style.md) — его можно править под себя")
    mod = await prepare_mod(bridge, ids, body, players, say)

    out_dir = cfg.home / "launch"
    mcp_path = out_dir / "mcp.json"
    session_path = out_dir / "session.json"
    _write_private(mcp_path, json.dumps(mcp_config(env, python), ensure_ascii=False, indent=1) + "\n")
    session = {
        "body": body,
        "owner": mod["owner"],
        "module_errors": mod["module_errors"],
        "helpers": [{
            "id": hid,
            **({"player": players[i]} if body == "player" else {}),
            "prompt": first_message(hid, keys[hid], body, players[i] if body == "player" else None,
                                    n, mod["module_errors"]),
        } for i, hid in enumerate(ids)],
    }
    _write_private(session_path, json.dumps(session, ensure_ascii=False, indent=1) + "\n")
    return {"helpers": ids, "body": body, "module_errors": mod["module_errors"],
            "mcp_config": mcp_path, "session": session_path}


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="launch.py", description="Запуск напарника factorio-partner")
    ap.add_argument("--helpers", help="сколько помощников (1..16); не задано — спросит")
    ap.add_argument("--body", help="character — тело без игрока; player — персонаж второго клиента")
    ap.add_argument("--players", help="для --body player: имена игроков через запятую, по одному на помощника")
    return ap


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    ns = build_parser().parse_args(argv)

    def say(text: str) -> None:
        print(text)

    try:
        n, body, players = ask_missing(ns, input if sys.stdin.isatty() else None)
        try:
            from factorio_partner.bridge import Bridge
            from factorio_partner.config import Config
            from factorio_partner.errors import ConfigError, PartnerError
        except ImportError:
            raise LaunchError("не найден пакет factorio_partner: запусти из venv, где он установлен "
                              "(pip install -e server)") from None
        try:
            cfg = Config.from_env()          # отказывает, если RCON не на 127.0.0.1
            cfg.read_password()              # только проверка, что файл пароля читается
        except ConfigError as e:
            raise LaunchError(f"настройки сервера: {e}") from None

        async def run() -> dict:
            bridge = Bridge(cfg)
            try:
                return await launch(cfg, n, body, players, bridge=bridge, env=dict(os.environ),
                                    python=sys.executable, say=say)
            finally:
                await bridge.close()

        try:
            result = asyncio.run(run())
        except PartnerError as e:
            raise LaunchError(f"мод недоступен ({e.code}): игра запущена, мод включён, RCON настроен?") from None
    except LaunchError as e:
        print(f"Запуск не удался: {e}", file=sys.stderr)
        return 2

    say(f"Готово: помощников {len(result['helpers'])} ({', '.join(result['helpers'])}), тело — {result['body']}.")
    if result["module_errors"]:
        say(f"Внимание: в моде были ошибки модулей ({result['module_errors']}) — агент скажет об этом в игре.")
    say(f"Конфигурация MCP: {result['mcp_config']}")
    say(f"Файл сессии (с ключами, никому не показывать): {result['session']}")
    say("Дальше — agents/README.md, раздел «Запуск агентов».")
    return 0


if __name__ == "__main__":
    sys.exit(main())
