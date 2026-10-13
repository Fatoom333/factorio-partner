"""Debug CLI: one JSON object on stdin -> one JSON object on stdout, through the same ``op_*``.

    echo {"tool":"partner_state","helper":"h1","key":"..."} | python -m factorio_partner.cli
    echo {"tool":"admin_hello"} | python -m factorio_partner.cli --admin

Launch mode (PROTOCOL §4 «helper_limit», §7 «Два вида тела») — what the script that starts the
partner runs after asking the player; nothing is read from stdin:

    python -m factorio_partner.cli --helpers 2
        helper_limit {max: 2}: how many helpers the player allowed
    python -m factorio_partner.cli --helpers 2 --body character --helper h1 --helper h2
        ...and a body for each: helper_spawn next to the owner
    python -m factorio_partner.cli --body player --helper h1 --player Second
        the body is the character of the second connected client: helper_attach {player}

Output: ``{"ok": true, "result": {...}}`` or ``{"ok": false, "error": "<code>", "text": "..."}``.
Exit code 0 on success, 1 on a refusal, 2 on bad input/config.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from typing import Any, TextIO

from . import validate as V
from .bridge import HELPER_RE
from .config import Config
from .core import Core
from .errors import ConfigError, PartnerError
from .server import setup_logging

# tool -> (method name, allowed argument names besides helper/key)
TOOLS: dict[str, tuple[str, tuple[str, ...]]] = {
    "partner_brief": ("op_brief", ()),
    "partner_state": ("op_state", ()),
    "partner_map": ("op_map", ("radius", "center", "near", "types", "names")),
    "partner_resources": ("op_resources", ("radius", "name", "center", "near")),
    "partner_stock": ("op_stock", ("radius", "items", "limit", "center", "near")),
    "partner_find": ("op_find", ("item", "kinds", "surface", "limit")),
    "partner_access": ("op_access", ("area", "radius", "center", "near")),
    "partner_ghosts": ("op_ghosts", ("radius", "area", "center", "near")),
    "partner_rates": ("op_rates", ("scope", "period", "area", "items", "top", "surface")),
    "partner_recipes": ("op_recipes", ("filter",)),
    "partner_act": ("op_act", ("do", "args", "replace")),
    "partner_cancel": ("op_cancel", ("job", "all")),
    "partner_wait": ("op_wait", ("timeout", "quiet", "since")),
    "partner_reflex": ("op_reflex", ("set",)),
    "partner_say": ("op_say", ("text",)),
    "partner_plan": ("op_plan", ("task", "resource", "patch", "options")),
}
ADMIN = {
    "admin_hello": ("admin_hello", ()),
    "admin_spawn": ("admin_spawn", ("helper",)),
    "admin_remove": ("admin_remove", ("helper",)),
    "admin_limit": ("admin_limit", ("max",)),
    "admin_attach": ("admin_attach", ("helper", "player")),
    "admin_raw_events": ("admin_raw_events", ("since", "helper", "limit")),
}

BODIES = ("character", "player")
DEFAULT_HELPER = "h1"


async def dispatch(core: Core, req: Any, admin: bool) -> dict:
    if not isinstance(req, dict) or not isinstance(req.get("tool"), str):
        raise PartnerError("bad_request", "expected {\"tool\": ..., ...}")
    tool = req["tool"]
    table = dict(TOOLS, **(ADMIN if admin else {}))
    if tool not in table:
        raise PartnerError("bad_request", "unknown tool")
    method, allowed = table[tool]
    base = {"tool"} if tool in ADMIN else {"tool", "helper", "key"}
    extra = set(req) - base - set(allowed)
    if extra:
        raise PartnerError("bad_args", "unknown fields: " + ", ".join(sorted(map(str, extra))))
    kwargs = {k: req[k] for k in allowed if k in req}
    fn = getattr(core, method)
    if tool in ADMIN:
        return await fn(**kwargs)
    return await fn(req.get("helper"), req.get("key"), **kwargs)


async def run(core: Core, stdin: TextIO, stdout: TextIO, admin: bool) -> int:
    try:
        req = json.loads(stdin.read())
    except ValueError:
        out, rc = {"ok": False, "error": "bad_request", "text": "stdin is not JSON"}, 2
    else:
        try:
            out, rc = {"ok": True, "result": await dispatch(core, req, admin)}, 0
        except PartnerError as e:
            out, rc = {"ok": False, "error": e.code, "text": e.text}, 1
        finally:
            await core.close()
    stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return rc


# ---- launch mode ---------------------------------------------------------------

def launch_plan(helpers: int | None, body: str | None, ids: list[str] | None,
                players: list[str] | None) -> list[tuple[str, dict]]:
    """Check the launch flags and turn them into admin calls, in order: the limit first, then
    one body per helper. Nothing is sent to the mod until every flag is valid."""
    ids = list(ids or [])
    players = list(players or [])
    steps: list[tuple[str, dict]] = []
    if helpers is not None:
        steps.append(("admin_limit", {"max": V.helper_max("--helpers", helpers)}))
    if body is None:
        if ids or players:
            raise V.bad("--body", "is required with --helper / --player")
        return steps
    if body not in BODIES:
        raise V.bad("--body", "must be one of " + ", ".join(BODIES))
    ids = ids or [DEFAULT_HELPER]
    for h in ids:
        if not isinstance(h, str) or not HELPER_RE.match(h):
            raise V.bad("--helper", "must match ^[a-z0-9_-]{1,16}$")
    if len(set(ids)) != len(ids):
        raise V.bad("--helper", "helper ids must differ")
    if len(ids) > V.MAX_HELPERS:
        raise PartnerError("limit", f"--helper: at most {V.MAX_HELPERS} helpers")
    if helpers is not None and len(ids) > helpers:
        raise PartnerError("limit", f"--helper: {len(ids)} bodies asked, but --helpers allows {helpers}")
    if body == "character":
        if players:
            raise V.bad("--player", "only with --body player")
        steps += [("admin_spawn", {"helper": h}) for h in ids]
        return steps
    # body == "player": every helper takes the character of its own connected player
    if len(players) != len(ids):
        raise V.bad("--player", "pass one --player for every --helper")
    names = [V.player_name("--player", p) for p in players]
    if len(set(names)) != len(names):
        raise V.bad("--player", "player names must differ")
    steps += [("admin_attach", {"helper": h, "player": p}) for h, p in zip(ids, names)]
    return steps


async def launch(core: Core, stdout: TextIO, helpers: int | None, body: str | None,
                 ids: list[str] | None, players: list[str] | None) -> int:
    """Run the launch steps. The first refusal stops the rest (a body is not created past a
    failed limit); what was done before it is reported in ``done``."""
    done: list[dict] = []
    try:
        steps = launch_plan(helpers, body, ids, players)
        for method, kwargs in steps:
            res = await getattr(core, method)(**kwargs)
            done.append({"call": method, **kwargs, "data": res.get("data")})
        out, rc = {"ok": True, "result": {"steps": done}}, 0
    except PartnerError as e:
        out, rc = {"ok": False, "error": e.code, "text": e.text, "done": done}, 1
    finally:
        await core.close()
    stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
    return rc


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="factorio-partner-cli")
    ap.add_argument("--admin", action="store_true")
    ap.add_argument("--helpers", type=int, metavar="N",
                    help="launch: how many helpers the player allowed (helper_limit, 1..16)")
    ap.add_argument("--body", choices=BODIES,
                    help="launch: body of each --helper — character (helper_spawn next to the owner) "
                         "or player (helper_attach to the character of a second connected client)")
    ap.add_argument("--helper", action="append", metavar="ID",
                    help="launch: helper id for --body (repeatable; default h1)")
    ap.add_argument("--player", action="append", metavar="NAME",
                    help="launch: player whose character becomes the body (--body player), one per --helper")
    return ap


def main(argv: list[str] | None = None) -> int:
    ns = build_parser().parse_args(argv)
    try:
        cfg = Config.from_env()
    except ConfigError as e:
        print(json.dumps({"ok": False, "error": "config", "text": str(e)}))
        return 2
    setup_logging(cfg)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if ns.helpers is not None or ns.body is not None or ns.helper or ns.player:
        return asyncio.run(launch(Core(cfg), sys.stdout, ns.helpers, ns.body, ns.helper, ns.player))
    return asyncio.run(run(Core(cfg), sys.stdin, sys.stdout, ns.admin))


if __name__ == "__main__":
    sys.exit(main())
