"""Debug CLI: one JSON object on stdin -> one JSON object on stdout, through the same ``op_*``.

    echo {"tool":"partner_state","helper":"h1","key":"..."} | python -m factorio_partner.cli
    echo {"tool":"admin_hello"} | python -m factorio_partner.cli --admin

Output: ``{"ok": true, "result": {...}}`` or ``{"ok": false, "error": "<code>", "text": "..."}``.
Exit code 0 on success, 1 on a refusal, 2 on bad input/config.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from typing import Any, TextIO

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
    "admin_raw_events": ("admin_raw_events", ("since", "helper", "limit")),
}


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


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="factorio-partner-cli")
    ap.add_argument("--admin", action="store_true")
    ns = ap.parse_args(argv)
    try:
        cfg = Config.from_env()
    except ConfigError as e:
        print(json.dumps({"ok": False, "error": "config", "text": str(e)}))
        return 2
    setup_logging(cfg)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    return asyncio.run(run(Core(cfg), sys.stdin, sys.stdout, ns.admin))


if __name__ == "__main__":
    sys.exit(main())
