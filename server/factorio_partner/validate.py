"""Argument checks done on the server before going to the mod.

The mod validates everything again (``bad_args``); the server only enforces what the contracts
state explicitly (ACTIONS.md, STATE.md, MCP.md) so that obvious mistakes cost no round trip and
unknown fields never reach the game. Every error is ``PartnerError("bad_args", "<field>: why")``.
"""
from __future__ import annotations

import json
import math
import re
from typing import Any, Callable

from .errors import PartnerError

MAX_ACT_ARGS = 4 * 1024            # MCP.md «Лимиты»
MAX_SAY = 200
MAX_REFLEXES = 16                  # MCP.md partner_reflex
MAX_FILTER = 100
COORD_LIMIT = 10_000_000.0
ITEM_COUNT_MAX = 100_000
AREA_SIDE_MAX = 128
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.\-]{0,99}$")
ID_RE = re.compile(r"^[a-z0-9-]{1,32}$")   # blob / plan ids (PROTOCOL §4 blob_put)
MAX_HELPERS = 16                   # PROTOCOL §4 helper_limit {max:1..16}
FIND_LIMIT_MAX = 50                # STATE.md «find»
FIND_KINDS = ("producers", "consumers", "storage", "entities")
PLAYER_NAME_MAX = 60
MAX_OPTIONS = 32                   # plan_mining.options: MPP flags
ACCESS_RADIUS_MAX = 64             # STATE.md «access»: radius?=32 (≤ 64)
FIT_SEARCH_MAX = 32                # ACTIONS.md build_blueprint: search?=16, 0..32
BELT_LANES_MAX = 4                 # ACTIONS.md plan_belt: lanes?=1 (1..4)

Validator = Callable[[str, Any], Any]


def bad(field: str, why: str) -> PartnerError:
    return PartnerError("bad_args", f"{field}: {why}")


def json_size(v: Any) -> int:
    return len(json.dumps(v, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


# ---- primitive validators ------------------------------------------------------

def number(lo: float | None = None, hi: float | None = None, integer: bool = False) -> Validator:
    def check(field: str, v: Any):
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise bad(field, "must be a number")
        if isinstance(v, float) and not math.isfinite(v):
            raise bad(field, "must be finite")
        if integer:
            if isinstance(v, float):
                if not v.is_integer():
                    raise bad(field, "must be an integer")
                v = int(v)
        if lo is not None and v < lo:
            raise bad(field, f"must be ≥ {lo:g}")
        if hi is not None and v > hi:
            # PROTOCOL §3: an upper bound of a numeric argument is `limit`, not `bad_args`
            raise PartnerError("limit", f"{field}: must be ≤ {hi:g}")
        return v
    return check


def integer(lo: int | None = None, hi: int | None = None) -> Validator:
    return number(lo, hi, integer=True)


def boolean(field: str, v: Any):
    if not isinstance(v, bool):
        raise bad(field, "must be true or false")
    return v


def name(field: str, v: Any):
    if not isinstance(v, str) or not NAME_RE.match(v):
        raise bad(field, "must be a prototype name")
    return v


def ident(field: str, v: Any):
    if not isinstance(v, str) or not ID_RE.match(v):
        raise bad(field, "must match ^[a-z0-9-]{1,32}$")
    return v


def enum(*values: str) -> Validator:
    def check(field: str, v: Any):
        if v not in values:
            raise bad(field, "must be one of " + ", ".join(values))
        return v
    return check


def pos(field: str, v: Any):
    if not isinstance(v, dict) or set(v) != {"x", "y"}:
        raise bad(field, "must be {x, y}")
    c = number(-COORD_LIMIT, COORD_LIMIT)
    return {"x": c(field + ".x", v["x"]), "y": c(field + ".y", v["y"])}


def pos_or_player(field: str, v: Any):
    if v == "player":
        return v
    return pos(field, v)


def pos_or_patch(field: str, v: Any):
    """``plan_belt.from``: a tile, or ``"patch"`` — the outputs of this helper's last plan_mining."""
    if isinstance(v, str):
        if v != "patch":
            raise bad(field, 'must be {x, y} or "patch"')
        return v
    return pos(field, v)


def area(field: str, v: Any):
    if not isinstance(v, dict) or set(v) != {"left_top", "right_bottom"}:
        raise bad(field, "must be {left_top, right_bottom}")
    lt = pos(field + ".left_top", v["left_top"])
    rb = pos(field + ".right_bottom", v["right_bottom"])
    w, h = rb["x"] - lt["x"], rb["y"] - lt["y"]
    if w <= 0 or h <= 0:
        raise bad(field, "right_bottom must be right of and below left_top")
    if w > AREA_SIDE_MAX or h > AREA_SIDE_MAX:
        raise PartnerError("limit", f"{field}: side must be ≤ {AREA_SIDE_MAX}")
    return {"left_top": lt, "right_bottom": rb}


def target(field: str, v: Any):
    if isinstance(v, dict) and set(v) <= {"unit_number", "pos"} and "unit_number" in v:
        # pos is optional: the mod falls back to a search around it when the engine cannot find
        # a building by unit_number (ACTIONS.md «target»)
        out = {"unit_number": integer(1, 2**53)(field + ".unit_number", v["unit_number"])}
        if "pos" in v:
            out["pos"] = pos(field + ".pos", v["pos"])
        return out
    if isinstance(v, dict) and set(v) == {"name", "pos"}:
        return {"name": name(field + ".name", v["name"]), "pos": pos(field + ".pos", v["pos"])}
    raise bad(field, "must be {unit_number, pos?} or {name, pos}")


def items(field: str, v: Any):
    if not isinstance(v, dict) or not v:
        raise bad(field, "must be a non-empty {item: count} object")
    if len(v) > 64:
        raise bad(field, "too many item kinds (max 64)")
    c = integer(1, ITEM_COUNT_MAX)
    return {name(f"{field} key", k): c(f"{field}.{k}", n) for k, n in v.items()}


def name_list(max_len: int) -> Validator:
    def check(field: str, v: Any):
        if not isinstance(v, list) or not v:
            raise bad(field, f"must be a non-empty list of up to {max_len} names")
        if len(v) > max_len:
            # PROTOCOL §3: too many names is an upper bound -> `limit`
            raise PartnerError("limit", f"{field}: at most {max_len} names")
        return [name(f"{field}[{i}]", x) for i, x in enumerate(v)]
    return check


def flags(max_len: int) -> Validator:
    """``plan_mining.options``: flat {flag: bool | number | name}; the mod knows the flags."""
    def check(field: str, v: Any):
        if not isinstance(v, dict):
            raise bad(field, "must be an object of flags")
        if len(v) > max_len:
            raise PartnerError("limit", f"{field}: at most {max_len} flags")
        out = {}
        for k, x in v.items():
            name(f"{field} key", k)
            if isinstance(x, bool):
                out[k] = x
            elif isinstance(x, (int, float)):
                out[k] = number(-COORD_LIMIT, COORD_LIMIT)(f"{field}.{k}", x)
            elif isinstance(x, str):
                out[k] = name(f"{field}.{k}", x)
            else:
                raise bad(f"{field}.{k}", "must be true/false, a number or a name")
        return out
    return check


def blueprint_direction(field: str, v: Any):
    """``build_blueprint.direction``: only the four cardinal directions (ACTIONS.md, v1)."""
    v = integer()(field, v)
    if v not in (0, 4, 8, 12):
        raise bad(field, "must be 0, 4, 8 or 12")
    return v


# ---- act -----------------------------------------------------------------------

MODE = enum("auto", "robots", "hand")
DIRECTION = integer(0, 15)
REACH = number(0, 64)
# build_blueprint.force (ACTIONS.md): how the blueprint is placed — click, Shift, Ctrl+Shift
BUILD_FORCE = enum("normal", "forced", "superforced")
MINING_LAYOUT = enum("simple", "compact", "super_compact", "sparse", "logistics", "compact_logistics",
                     "sparse_logistics")
SIDE = enum("north", "east", "south", "west")
# plan_belt.underground (ACTIONS.md): only through obstacles, never, or wherever it is shorter
UNDERGROUND = enum("auto", "never", "prefer")

# do ->(fields, required, groups of mutually exclusive fields with "exactly one" flag)
ACTIONS: dict[str, tuple[dict[str, Validator], tuple[str, ...], tuple[tuple[tuple[str, ...], bool], ...]]] = {
    "walk": ({"to": pos_or_player, "radius": REACH}, ("to",), ()),
    "approach": ({"target": target, "to": pos_or_player, "distance": REACH}, (),
                 ((("target", "to"), True),)),
    "follow": ({"distance": number(1, 32), "duration_s": integer(1, 3600)}, (), ()),
    "mine": ({"target": target, "resource": name, "near": pos, "count": integer(1, ITEM_COUNT_MAX)},
             ("count",), ((("target", "resource"), True),)),
    "craft": ({"recipe": name, "count": integer(1, 10_000)}, ("recipe", "count"), ()),
    "insert": ({"target": target, "items": items}, ("target", "items"), ()),
    "extract": ({"target": target, "items": items, "equip": boolean}, ("target",), ()),
    "collect": ({"items": items, "center": pos, "near": enum("player"), "radius": number(1, 128)},
                ("items",), ((("center", "near"), False),)),
    "pickup": ({"target": target, "area": area}, (), ((("target", "area"), False),)),
    "place": ({"item": name, "pos": pos, "direction": DIRECTION, "recipe": name}, ("item", "pos"), ()),
    "build_blueprint": ({"blob": ident, "plan": ident, "anchor": pos, "direction": blueprint_direction,
                        "mode": MODE, "force": BUILD_FORCE, "dry_run": boolean,
                        # revision 3.3: the search for a shift where the blueprint fits (`fit`), its
                        # rotations, and the cut blueprint the owner agreed to. `mirror` is how a
                        # `fit.mirror` answer is applied (the mod's argument)
                        "search": integer(0, FIT_SEARCH_MAX), "rotate": boolean, "partial": boolean,
                        "mirror": boolean},
                        ("anchor",), ((("blob", "plan"), True),)),
    "build_ghosts": ({"area": area, "radius": number(1, 64), "mode": MODE}, (),
                     ((("area", "radius"), False),)),
    "deconstruct": ({"target": target, "area": area, "filter": name_list(32)}, (),
                    ((("target", "area"), True),)),
    "plan_mining": ({"resource": name, "area": area, "near": pos, "layout": MINING_LAYOUT,
                     "direction": SIDE,
                     "miner": name, "belt": name, "pole": name, "pipe": name,
                     "options": flags(MAX_OPTIONS), "dry_run": boolean},
                    (), ((("area", "near"), True),)),
    "plan_belt": ({"from": pos_or_patch, "to": pos, "belt": name, "lanes": integer(1, BELT_LANES_MAX),
                   "underground": UNDERGROUND, "start_direction": SIDE, "dry_run": boolean},
                  ("from", "to"), ()),
    "wait": ({"seconds": integer(1, 600)}, ("seconds",), ()),
}


def check_act(do: Any, args: Any) -> dict:
    if not isinstance(do, str) or do not in ACTIONS:
        raise PartnerError("bad_args", "do: unknown action; allowed: " + ", ".join(sorted(ACTIONS)))
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise bad("args", "must be an object")
    if json_size(args) > MAX_ACT_ARGS:
        raise PartnerError("limit", f"args larger than {MAX_ACT_ARGS} bytes")
    fields, required, groups = ACTIONS[do]
    out = {}
    for k, v in args.items():
        if k not in fields:
            raise bad(f"args.{k}", f"unknown field for {do}; allowed: " + ", ".join(fields))
        out[k] = fields[k](f"args.{k}", v)
    for k in required:
        if k not in out:
            raise bad(f"args.{k}", "required")
    for group, exactly_one in groups:
        n = sum(1 for k in group if k in out)
        if n > 1:
            raise bad("args", "use only one of " + " / ".join(group))
        if exactly_one and n == 0:
            raise bad("args", "one of " + " / ".join(group) + " is required")
    return out


# ---- other tools -----------------------------------------------------------------

def check_say(text: Any) -> str:
    if not isinstance(text, str) or not text.strip():
        raise bad("text", "must be a non-empty string")
    if len(text) > MAX_SAY:
        raise PartnerError("limit", f"text: at most {MAX_SAY} characters")
    return text


def check_reflexes(rset: Any) -> list:
    if not isinstance(rset, list):
        raise bad("set", "must be a list")
    # The envelope and the bounds of MCP.md (≤ 16 reflexes, ≤ 4 KB) are checked here; the known
    # types and their fields are the mod's business (schema in M.reflexes).
    if len(rset) > MAX_REFLEXES:
        raise PartnerError("limit", f"set: at most {MAX_REFLEXES} reflexes")
    for i, r in enumerate(rset):
        if not isinstance(r, dict):
            raise bad(f"set[{i}]", "must be an object")
        t = r.get("type")
        if not isinstance(t, str) or not NAME_RE.match(t):
            raise bad(f"set[{i}].type", "must be a reflex type name")
    if json_size(rset) > MAX_ACT_ARGS:
        raise PartnerError("limit", f"reflex set larger than {MAX_ACT_ARGS} bytes")
    return rset


def recipe_filter(field: str, v: Any) -> str:
    """``partner_recipes.filter``: a substring of a recipe name; ``""`` means no filter."""
    if not isinstance(v, str) or len(v) > MAX_FILTER or not re.fullmatch(r"[A-Za-z0-9_.\-]*", v):
        raise bad(field, f"must be a recipe-name substring of up to {MAX_FILTER} characters")
    return v


def check_kinds(field: str, v: Any) -> list:
    """``partner_find.kinds``: a subset of producers / consumers / storage / entities."""
    if not isinstance(v, list) or not v:
        raise bad(field, "must be a non-empty list of " + ", ".join(FIND_KINDS))
    if len(v) > len(FIND_KINDS):
        raise PartnerError("limit", f"{field}: at most {len(FIND_KINDS)} kinds")
    out = []
    for i, k in enumerate(v):
        if not isinstance(k, str) or k not in FIND_KINDS:
            raise bad(f"{field}[{i}]", "must be one of " + ", ".join(FIND_KINDS))
        if k not in out:
            out.append(k)
    return out


def helper_max(field: str, v: Any) -> int:
    """``helper_limit.max`` (PROTOCOL §4): 1..16, above -> ``limit``."""
    return integer(1, MAX_HELPERS)(field, v)


def player_name(field: str, v: Any) -> str:
    """A Factorio player name for ``helper_attach``: one line, no control characters."""
    if (not isinstance(v, str) or not 1 <= len(v) <= PLAYER_NAME_MAX or v != v.strip()
            or any(ord(c) < 32 or ord(c) == 127 for c in v)):
        raise bad(field, f"must be a player name of 1..{PLAYER_NAME_MAX} characters")
    return v


def check_types(field: str, v: Any) -> list | None:
    if v is None:
        return None
    return name_list(32)(field, v)


def check_names(field: str, v: Any, max_len: int = 100) -> list | None:
    """``items`` of ``partner_stock`` / ``partner_rates`` (STATE.md: at most 100 names)."""
    if v is None:
        return None
    return name_list(max_len)(field, v)
