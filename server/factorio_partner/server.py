"""MCP server ``factorio-partner`` (stdio): thin tools over ``core.Core`` (docs/MCP.md).

Run: ``python -m factorio_partner.server [--admin]``. One process serves every helper.
FastMCP handles each request as its own task; the bridge keeps two RCON connections so that
``partner_wait`` (poll) never blocks ``partner_act`` (cmd).
stdout belongs to the MCP protocol: logs go only to ``FP_HOME/logs/server.log``.
"""
from __future__ import annotations

import argparse
import logging
import sys
from typing import Annotated, Any, Literal

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from pydantic import Field

from .config import Config
from .core import Core
from .errors import ConfigError, PartnerError

# No shape limits here: core.check_access checks helper and key and gives every failure the
# same text ``access denied`` (MCP.md); a pydantic error would leak which part was wrong.
Helper = Annotated[str, Field(description="id помощника, например h1")]
Key = Annotated[str, Field(description="ключ помощника")]
Pos = dict[str, float]
Area = dict[str, dict[str, float]]

INSTRUCTIONS = ("Управление помощником (вторым персонажем) в Factorio через мод factorio-partner. "
                "Каждому инструменту нужны helper и key. Первым вызови partner_brief.")


async def _run(coro):
    try:
        return await coro
    except PartnerError as e:
        raise ToolError(str(e)) from None


def build_server(core: Core, admin: bool = False) -> FastMCP:
    mcp = FastMCP("factorio-partner", instructions=INSTRUCTIONS, log_level="WARNING")

    @mcp.tool()
    async def partner_brief(helper: Helper, key: Key) -> dict:
        """Правила, заметки хозяина о сейве (notes.md профиля forge) и стиль. Вызови первым."""
        return await _run(core.op_brief(helper, key))

    @mcp.tool()
    async def partner_state(helper: Helper, key: Key) -> dict:
        """Состояние помощника: позиция, здоровье, инвентарь, задача и очередь, игроки рядом, tick/seq."""
        return await _run(core.op_state(helper, key))

    @mcp.tool()
    async def partner_map(helper: Helper, key: Key,
                          radius: float = 16,
                          center: Pos | None = None,
                          near: Literal["player"] | None = None,
                          types: list[str] | None = None,
                          names: list[str] | None = None) -> dict:
        """Текстовая карта вокруг помощника, center или хозяина (near="player"; center и near
        вместе нельзя): строки символов, легенда, сущности."""
        return await _run(core.op_map(helper, key, radius, center, types, names, near))

    @mcp.tool()
    async def partner_resources(helper: Helper, key: Key,
                                radius: float | None = None,
                                name: str | None = None,
                                near_player: bool = False) -> dict:
        """Пятна руды рядом с помощником (near_player=true — рядом с хозяином)."""
        return await _run(core.op_resources(helper, key, radius, name, near_player))

    @mcp.tool()
    async def partner_stock(helper: Helper, key: Key,
                            radius: float | None = None,
                            items: list[str] | None = None,
                            near_player: bool = False) -> dict:
        """Склады своей силы и их содержимое (только видимые чанки)."""
        return await _run(core.op_stock(helper, key, radius, items, near_player))

    @mcp.tool()
    async def partner_ghosts(helper: Helper, key: Key,
                             radius: float | None = None,
                             area: Area | None = None) -> dict:
        """Призраки в радиусе или области: сколько, что нужно, что есть, что заблокировано."""
        return await _run(core.op_ghosts(helper, key, radius, area))

    @mcp.tool()
    async def partner_rates(helper: Helper, key: Key,
                            scope: Literal["surface", "area"] = "surface",
                            period: Literal["1m", "10m", "1h"] = "1m",
                            area: Area | None = None,
                            items: list[str] | None = None,
                            top: int | None = None,
                            surface: str | None = None) -> dict:
        """Производство: по поверхности (статистика) или номинально по машинам в области.
        surface — имя поверхности (другая планета); без него — поверхность помощника."""
        return await _run(core.op_rates(helper, key, scope, period, area, items, top, surface))

    @mcp.tool()
    async def partner_recipes(helper: Helper, key: Key, filter: str | None = None) -> dict:  # noqa: A002
        """Что помощник может скрафтить из своего инвентаря: {craftable:{рецепт:сколько}}.
        filter — подстрока имени рецепта."""
        return await _run(core.op_recipes(helper, key, filter))

    @mcp.tool()
    async def partner_act(helper: Helper, key: Key, do: str,
                          args: dict[str, Any] | None = None, replace: bool = False) -> dict:
        """Поставить задачу в очередь: walk, approach, follow, mine, craft, insert, extract, collect,
        pickup, place, build_blueprint, build_ghosts, deconstruct, wait. Ответ — {job, queued_before};
        итог придёт событием job_done / job_failed. Для build_blueprint вместо blob передай plan
        (id из partner_plan). replace=true отменяет текущую задачу и очередь."""
        return await _run(core.op_act(helper, key, do, args, replace))

    @mcp.tool()
    async def partner_cancel(helper: Helper, key: Key,
                             job: int | None = None,
                             all: bool = False) -> dict:  # noqa: A002
        """Отменить задачу по номеру или все (all=true)."""
        return await _run(core.op_cancel(helper, key, job, all))

    @mcp.tool()
    async def partner_wait(helper: Helper, key: Key,
                           timeout: float = 30,
                           quiet: bool = True,
                           since: int | None = None) -> dict:
        """Ждать событий до timeout секунд (≤55). quiet=true — только важные будят.
        Ответ {seq, events, timed_out}. Пустой ответ = ничего нового: просто жди снова."""
        return await _run(core.op_wait(helper, key, timeout, quiet, since))

    @mcp.tool()
    async def partner_reflex(helper: Helper, key: Key, set: list[dict[str, Any]]) -> dict:  # noqa: A002
        """Рефлексы тела: полный список заменяет прежний, [] снимает все."""
        return await _run(core.op_reflex(helper, key, set))

    @mcp.tool()
    async def partner_say(helper: Helper, key: Key,
                          text: str) -> dict:
        """Сказать в чат игры (до 200 символов), с префиксом [helper]."""
        return await _run(core.op_say(helper, key, text))

    @mcp.tool()
    async def partner_plan(helper: Helper, key: Key, task: Literal["mining"] = "mining",
                           resource: dict[str, Any] | None = None,
                           patch: dict[str, Any] | None = None,
                           options: dict[str, Any] | None = None) -> dict:
        """Спроектировать добычу через forge: resource {name, area} или patch из partner_resources.
        Ответ {plan, anchor, direction, items, size, summary} или {supported:false, reason}."""
        return await _run(core.op_plan(helper, key, task, resource, patch, options))

    if admin:
        @mcp.tool()
        async def admin_hello() -> dict:
            """(оркестр) hello: версия мода, тик, игроки, помощники."""
            return await _run(core.admin_hello())

        @mcp.tool()
        async def admin_spawn(helper: Helper) -> dict:
            """(оркестр) создать тело помощника рядом с хозяином."""
            return await _run(core.admin_spawn(helper))

        @mcp.tool()
        async def admin_remove(helper: Helper) -> dict:
            """(оркестр) удалить тело помощника (вещи останутся в трупе)."""
            return await _run(core.admin_remove(helper))

        @mcp.tool()
        async def admin_raw_events(since: int = 0,
                                   helper: Helper | None = None,
                                   limit: int = 100) -> dict:
            """(отладка) сырые события буфера мода после since."""
            return await _run(core.admin_raw_events(since, helper, limit))

    return mcp


def setup_logging(cfg: Config) -> None:
    cfg.logs_dir.mkdir(parents=True, exist_ok=True)
    h = logging.FileHandler(cfg.logs_dir / "server.log", encoding="utf-8")
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
    lg = logging.getLogger("factorio_partner")
    lg.setLevel(logging.INFO)
    lg.addHandler(h)
    lg.propagate = False


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="factorio-partner-mcp")
    ap.add_argument("--admin", action="store_true", help="also expose admin_* tools (orchestrator/debug)")
    ns = ap.parse_args(argv)
    try:
        cfg = Config.from_env()
    except ConfigError as e:
        print(f"factorio-partner: {e}", file=sys.stderr)
        return 2
    setup_logging(cfg)
    core = Core(cfg)
    build_server(core, admin=ns.admin).run("stdio")
    return 0


if __name__ == "__main__":
    sys.exit(main())
