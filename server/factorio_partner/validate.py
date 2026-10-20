"""Argument checks done on the server before going to the mod.

The mod validates everything again (``bad_args``); the server only enforces what the contracts
state explicitly (ACTIONS.md, STATE.md, MCP.md) so that obvious mistakes cost no round trip and
unknown fields never reach the game. Every error is ``PartnerError("bad_args", "<field>: why")``.
"""
from __future__ import annotations

import difflib
import json
import math
import re
from typing import Any, Callable

from .errors import PartnerError

MAX_ACT_ARGS = 4 * 1024            # MCP.md «Лимиты»
MAX_LAYOUT_ARGS = 16 * 1024        # build_layout.args on the server; above 4 KB the mod gets a blob
LAYOUT_ENTITIES_MAX = 100          # ACTIONS.md build_layout: entities 1..100
LAYOUT_OFFSET_MAX = 64             # dx/dy/cx/cy from the anchor cell: -64..64
LAYOUT_PORTS_MAX = 16
LAYOUT_PORT_ITEMS_MAX = 2
LAYOUT_INSERT_KINDS_MAX = 4
CONNECT_VIA_MAX = 8
CONNECT_LENGTH_MAX = 200
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
STATUS_RADIUS_MAX = 128            # STATE.md «status»
STATUS_LIMIT_MAX = 50
FIND_KINDS = ("producers", "consumers", "storage", "entities")
PLAYER_NAME_MAX = 60
MAX_OPTIONS = 32                   # plan_mining.options: MPP flags
ACCESS_RADIUS_MAX = 64             # STATE.md «access»: radius?=32 (≤ 64)
FIT_SEARCH_MAX = 32                # ACTIONS.md build_blueprint: search?=16, 0..32
BELT_LANES_MAX = 4                 # ACTIONS.md plan_belt: lanes?=1 (1..4)
SUPPLY_COUNT_MAX = 10_000          # STATE.md «supply»: count?=1 (1..10000)
SUPPLY_DEPTH_MAX = 5               # STATE.md «supply»: depth?=3 (1..5)
LOOKUP_LIMIT_MAX = 50              # STATE.md «lookup»: limit?=20 (1..50)
LOOKUP_KINDS = ("item", "fluid", "recipe", "technology", "entity")

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
    """``plan_belt.from``: a tile, ``"patch"`` — the outputs of this helper's last plan_mining, or
    ``"resume"`` — re-lay the unbuilt rest of this helper's last belt plan."""
    if isinstance(v, str):
        if v not in ("patch", "resume"):
            raise bad(field, 'must be {x, y}, "patch" or "resume"')
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


def only_true(field: str, v: Any):
    """A switch that exists only as ``true`` (``pickup.corpse``): false is a mistake, not a no."""
    if v is not True:
        raise bad(field, "only true (leave it out otherwise)")
    return v


def target_or_armor(field: str, v: Any):
    """``insert.target``: a building, or ``"armor"`` — the grid of the helper's own armour."""
    if v == "armor":
        return v
    return target(field, v)


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



# ---- build_layout / connect_entities ----------------------------------------------

PORT_ID_RE = re.compile(r"^[a-z0-9_-]{1,16}$")
LAYOUT_TAG_RE = re.compile(r"^[a-z0-9-]{1,32}$")
PORT_KINDS = ("belt", "pipe", "power")
_ENTITY_FIELDS = ("name", "dx", "dy", "cx", "cy", "direction", "recipe", "type", "insert")
_PORT_FIELDS = ("id", "dx", "dy", "kind", "io", "dir", "items", "fluid", "rate")


def _port_id(field: str, v: Any):
    if not isinstance(v, str) or not PORT_ID_RE.match(v):
        raise bad(field, "must match ^[a-z0-9_-]{1,16}$")
    return v


def _layout_tag(field: str, v: Any):
    if not isinstance(v, str) or not LAYOUT_TAG_RE.match(v):
        raise bad(field, "must match ^[a-z0-9-]{1,32}$")
    return v


def layout_entity(field: str, v: Any) -> dict:
    """One building of ``build_layout.entities``: ``dx, dy`` (whole cells, top-left cell from the
    anchor) or ``cx, cy`` (the centre, as in a blueprint) - exactly one pair."""
    if not isinstance(v, dict):
        raise bad(field, "must be an object {name, dx, dy, ...}")
    for k in v:
        if k not in _ENTITY_FIELDS:
            raise bad(f"{field}.{k}", "unknown field; allowed: " + ", ".join(_ENTITY_FIELDS))
    if "name" not in v:
        raise bad(f"{field}.name", "required")
    out: dict = {"name": name(f"{field}.name", v["name"])}
    cell = [k for k in ("dx", "dy") if k in v]
    centre = [k for k in ("cx", "cy") if k in v]
    if cell and centre:
        raise bad(field, "use either dx, dy or cx, cy, not both")
    if cell:
        if len(cell) != 2:
            raise bad(field, "dx and dy go together")
        c = integer(-LAYOUT_OFFSET_MAX, LAYOUT_OFFSET_MAX)
        for k in cell:
            out[k] = c(f"{field}.{k}", v[k])
    elif centre:
        if len(centre) != 2:
            raise bad(field, "cx and cy go together")
        c = number(-LAYOUT_OFFSET_MAX, LAYOUT_OFFSET_MAX)
        for k in centre:
            out[k] = c(f"{field}.{k}", v[k])
    else:
        raise bad(field, "dx, dy or cx, cy is required")
    if "direction" in v:
        out["direction"] = DIRECTION(f"{field}.direction", v["direction"])
    if "recipe" in v:
        out["recipe"] = name(f"{field}.recipe", v["recipe"])
    if "type" in v:
        out["type"] = enum("input", "output")(f"{field}.type", v["type"])
    if "insert" in v:
        ins = items(f"{field}.insert", v["insert"])
        if len(ins) > LAYOUT_INSERT_KINDS_MAX:
            raise PartnerError("limit", f"{field}.insert: at most {LAYOUT_INSERT_KINDS_MAX} item kinds")
        out["insert"] = ins
    return out


def layout_entities(field: str, v: Any) -> list:
    if not isinstance(v, list) or not v:
        raise bad(field, f"must be a non-empty list of 1..{LAYOUT_ENTITIES_MAX} buildings")
    if len(v) > LAYOUT_ENTITIES_MAX:
        raise PartnerError("limit", f"{field}: at most {LAYOUT_ENTITIES_MAX} buildings")
    return [layout_entity(f"{field}[{i}]", e) for i, e in enumerate(v)]


def layout_port(field: str, v: Any) -> dict:
    """One port of a block: where a belt / pipe / power line enters or leaves it."""
    if not isinstance(v, dict):
        raise bad(field, "must be an object {id, dx, dy, kind, io, ...}")
    for k in v:
        if k not in _PORT_FIELDS:
            raise bad(f"{field}.{k}", "unknown field; allowed: " + ", ".join(_PORT_FIELDS))
    for k in ("id", "dx", "dy", "kind", "io"):
        if k not in v:
            raise bad(f"{field}.{k}", "required")
    c = integer(-LAYOUT_OFFSET_MAX, LAYOUT_OFFSET_MAX)
    out: dict = {"id": _port_id(f"{field}.id", v["id"]), "dx": c(f"{field}.dx", v["dx"]),
                 "dy": c(f"{field}.dy", v["dy"]), "kind": enum(*PORT_KINDS)(f"{field}.kind", v["kind"]),
                 "io": enum("in", "out")(f"{field}.io", v["io"])}
    if "dir" in v:
        d = integer()(f"{field}.dir", v["dir"])
        if d not in (0, 4, 8, 12):
            raise bad(f"{field}.dir", "must be 0, 4, 8 or 12")
        out["dir"] = d
    if "items" in v and "fluid" in v:
        raise bad(field, "use either items or fluid")
    if "items" in v:
        its = v["items"]
        if not isinstance(its, list) or not its:
            raise bad(f"{field}.items", f"must be a non-empty list of up to {LAYOUT_PORT_ITEMS_MAX} names")
        if len(its) > LAYOUT_PORT_ITEMS_MAX:
            raise PartnerError("limit", f"{field}.items: at most {LAYOUT_PORT_ITEMS_MAX} names")
        # "" is an empty lane (a forge port carries both lanes, one may be unused)
        out["items"] = [x if x == "" else name(f"{field}.items[{i}]", x) for i, x in enumerate(its)]
    if "fluid" in v:
        out["fluid"] = name(f"{field}.fluid", v["fluid"])
    if "rate" in v:
        r = v["rate"]
        if isinstance(r, bool) or not isinstance(r, (int, float)) or not math.isfinite(r) or r < 0 or r > 1e6:
            raise bad(f"{field}.rate", "must be a number 0..1000000 (items or fluid per second)")
        out["rate"] = r
    return out


def layout_ports(field: str, v: Any) -> list:
    if not isinstance(v, list) or not v:
        raise bad(field, f"must be a non-empty list of up to {LAYOUT_PORTS_MAX} ports")
    if len(v) > LAYOUT_PORTS_MAX:
        raise PartnerError("limit", f"{field}: at most {LAYOUT_PORTS_MAX} ports")
    out = [layout_port(f"{field}[{i}]", p) for i, p in enumerate(v)]
    seen: set = set()
    for i, p in enumerate(out):
        if p["id"] in seen:
            raise bad(f"{field}[{i}].id", "duplicate port id")
        seen.add(p["id"])
    return out


def endpoint(field: str, v: Any) -> dict:
    """An end of ``connect_entities``: exactly one of ``{pos, dir?}``, ``{target}``, ``{layout, port}``,
    ``{layout, i}`` (a building of a remembered block). ``dir`` (0/4/8/12) is the direction of the
    end, as a port has it: a probe through ``{pos, dir}`` lays the same path as through the port."""
    if not isinstance(v, dict):
        raise bad(field, "must be {pos, dir?} | {target} | {layout, port} | {layout, i}")
    keys = set(v)
    if keys in ({"pos"}, {"pos", "dir"}):
        out = {"pos": pos(f"{field}.pos", v["pos"])}
        if "dir" in v:
            d = integer()(f"{field}.dir", v["dir"])
            if d not in (0, 4, 8, 12):
                raise bad(f"{field}.dir", "must be 0, 4, 8 or 12")
            out["dir"] = d
        return out
    if keys == {"target"}:
        return {"target": target(f"{field}.target", v["target"])}
    if keys == {"layout", "port"}:
        return {"layout": _layout_tag(f"{field}.layout", v["layout"]),
                "port": _port_id(f"{field}.port", v["port"])}
    if keys == {"layout", "i"}:
        return {"layout": _layout_tag(f"{field}.layout", v["layout"]),
                "i": integer(1, LAYOUT_ENTITIES_MAX)(f"{field}.i", v["i"])}
    raise bad(field, "must be exactly one of {pos, dir?} | {target} | {layout, port} | {layout, i}")


def via_list(field: str, v: Any) -> list:
    if not isinstance(v, list) or not v:
        raise bad(field, f"must be a non-empty list of up to {CONNECT_VIA_MAX} positions")
    if len(v) > CONNECT_VIA_MAX:
        raise PartnerError("limit", f"{field}: at most {CONNECT_VIA_MAX} positions")
    return [pos(f"{field}[{i}]", p) for i, p in enumerate(v)]


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

PLAN_STEPS_MAX = 200               # ACTIONS.md plan: steps 1..200 (inline ones also fit act.args ≤ 4 KB)


def plan_steps(field: str, v: Any) -> list:
    """``plan.steps``: [{do, args?, on_fail?}], each step checked as its own ``act`` (no nested plan)."""
    if not isinstance(v, list) or not v:
        raise bad(field, "must be a non-empty list of steps")
    if len(v) > PLAN_STEPS_MAX:
        raise PartnerError("limit", f"{field}: at most {PLAN_STEPS_MAX} steps")
    out = []
    for i, s in enumerate(v, 1):
        f = f"{field}[{i}]"
        if not isinstance(s, dict):
            raise bad(f, "must be an object {do, args?, on_fail?}")
        for k in s:
            if k not in ("do", "args", "on_fail"):
                raise bad(f"{f}.{k}", "unknown field; allowed: do, args, on_fail")
        if s.get("do") == "plan":
            raise bad(f"{f}.do", "a plan cannot hold a plan")
        try:
            step = {"do": s.get("do"), "args": check_act(s.get("do"), s.get("args"))}
        except PartnerError as e:
            raise PartnerError(e.code, f"{f}.{e.text}" if e.text else f) from None
        if "on_fail" in s:
            step["on_fail"] = enum("stop", "continue")(f"{f}.on_fail", s["on_fail"])
        out.append(step)
    return out


# do ->(fields, required, groups of mutually exclusive fields with "exactly one" flag)
ACTIONS: dict[str, tuple[dict[str, Validator], tuple[str, ...], tuple[tuple[tuple[str, ...], bool], ...]]] = {
    "walk": ({"to": pos_or_player, "radius": REACH}, ("to",), ()),
    "approach": ({"target": target, "to": pos_or_player, "distance": REACH}, (),
                 ((("target", "to"), True),)),
    "follow": ({"distance": number(1, 32), "duration_s": integer(1, 3600)}, (), ()),
    # `item` — gather this item from rocks, trees and hand-minable ore
    "mine": ({"target": target, "resource": name, "item": name, "near": pos,
              "count": integer(1, ITEM_COUNT_MAX)},
             ("count",), ((("target", "resource", "item"), True),)),
    # wait=false — queue the craft and go on (craft_done comes when it is ready)
    "craft": ({"recipe": name, "count": integer(1, 10_000), "wait": boolean}, ("recipe", "count"), ()),
    # target "armor" — modules into the grid of the worn armour (like armor_grid{put})
    "insert": ({"target": target_or_armor, "items": items, "auto_supply": boolean}, ("target", "items"), ()),
    "extract": ({"target": target, "items": items, "equip": boolean}, ("target",), ()),
    # from_lines — the owner's leave to take from the outputs of his lines and machines too
    "collect": ({"items": items, "center": pos, "near": enum("player"), "radius": number(1, 128),
                 "from_lines": boolean},
                ("items",), ((("center", "near"), False),)),
    # bring the items up to these counts in the pockets: storages -> craft -> smelt -> mine by hand
    "get_items": ({"items": items, "radius": number(1, 128), "from_lines": boolean}, ("items",), ()),
    # the helper's own armour: wear one from the pockets; modules into / out of its grid
    "equip": ({"item": name}, ("item",), ()),
    "armor_grid": ({"put": items, "take": items}, (), ()),     # at least one of them (check_act)
    # corpse:true — the helper's own last corpse (only true); exactly one of the three
    "pickup": ({"target": target, "area": area, "corpse": only_true}, (),
               ((("target", "area", "corpse"), True),)),
    "place": ({"item": name, "pos": pos, "direction": DIRECTION, "recipe": name, "auto_supply": boolean},
              ("item", "pos"), ()),
    # turn an own building like the R key (the last built belt of a re-planned belt)
    "rotate": ({"target": target, "direction": blueprint_direction}, ("target", "direction"), ()),
    # change the recipe of a standing assembling machine, like the machine window
    "set_recipe": ({"target": target, "recipe": name}, ("target",), ()),
    "build_blueprint": ({"blob": ident, "plan": ident, "anchor": pos, "direction": blueprint_direction,
                        "mode": MODE, "force": BUILD_FORCE, "dry_run": boolean,
                        # the search for a shift where the blueprint fits (`fit`), its
                        # rotations, and the cut blueprint the owner agreed to. `mirror` is how a
                        # `fit.mirror` answer is applied (the mod's argument)
                        "search": integer(0, FIT_SEARCH_MAX), "rotate": boolean, "partial": boolean,
                        "mirror": boolean, "auto_supply": boolean},
                        ("anchor",), ((("blob", "plan"), True),)),
    "build_ghosts": ({"area": area, "radius": number(1, 64), "mode": MODE, "auto_supply": boolean}, (),
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
                  ("from",), ()),   # `to` is required too, except with from="resume" (check_act)
    # a block of buildings by offsets from an anchor cell (no blueprint). `blob` is closed to the
    # agent: the server makes it from `plan` or from a large `entities`
    "build_layout": ({"anchor": pos, "entities": layout_entities, "plan": ident,
                      "direction": blueprint_direction, "search": integer(0, FIT_SEARCH_MAX),
                      "rotate": boolean, "on_resource": name, "ports": layout_ports,
                      "tag": _layout_tag, "mode": MODE, "auto_supply": boolean,
                      "keep_ghosts": boolean, "dry_run": boolean},
                     ("anchor",), ((("entities", "plan"), True),)),
    # a belt, pipe or power line laid and built between two ends
    "connect_entities": ({"kind": enum(*PORT_KINDS), "from": endpoint, "to": endpoint, "via": via_list,
                          "max_length": integer(1, CONNECT_LENGTH_MAX), "belt": name, "pipe": name,
                          "pole": name, "underground": UNDERGROUND, "fluid": name, "build": boolean,
                          "mode": MODE, "auto_supply": boolean, "dry_run": boolean},
                         ("kind", "from", "to"), ()),
    "wait": ({"seconds": integer(1, 600)}, ("seconds",), ()),
    # a long plan: up to 200 ordinary steps in one job; one plan_done at the end. `blob` — the
    # steps as a JSON list sent with blob_put; `after` — queue right behind that job (a successor)
    "plan": ({"steps": plan_steps, "blob": ident, "on_fail": enum("stop", "continue"),
              "from_step": integer(1, PLAN_STEPS_MAX), "after": integer(1)},
             (), ((("steps", "blob"), True),)),
}


def check_act(do: Any, args: Any) -> dict:
    if not isinstance(do, str) or do not in ACTIONS:
        raise PartnerError("bad_args", "do: unknown action; allowed: " + ", ".join(sorted(ACTIONS)))
    if args is None:
        args = {}
    if not isinstance(args, dict):
        raise bad("args", "must be an object")
    cap = MAX_LAYOUT_ARGS if do == "build_layout" else MAX_ACT_ARGS
    if json_size(args) > cap:
        raise PartnerError("limit", f"args larger than {cap} bytes")
    fields, required, groups = ACTIONS[do]
    out = {}
    for k, v in args.items():
        if k not in fields:
            raise bad(f"args.{k}", f"unknown field for {do}; allowed: " + ", ".join(fields))
        out[k] = fields[k](f"args.{k}", v)
    for k in required:
        if k not in out:
            raise bad(f"args.{k}", "required")
    if do == "plan_belt" and out["from"] != "resume" and "to" not in out:
        # from="resume" takes the target from the remembered plan (docs/ACTIONS.md, «plan_belt»)
        raise bad("args.to", 'required (optional only with from="resume")')
    if do == "armor_grid" and not out:
        raise bad("args", "put or take is required (at least one)")
    if do == "connect_entities":
        # a prototype of another kind of line would be ignored by the mod: say so here
        want = {"belt": "belt", "pipe": "pipe", "power": "pole"}[out["kind"]]
        for fld in ("belt", "pipe", "pole"):
            if fld in out and fld != want:
                raise bad(f"args.{fld}", f"is not for kind {out['kind']} (use {want})")
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


# the ammo reflex: the gap to the turrets' frames, how far behind their line, how far from any enemy
AMMO_BOUNDS = {"turret_gap": (0, 16), "behind": (0, 12), "keep_away": (0, 96)}


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
        if t == "ammo":
            # where the helper may stand to fill the turrets (EVENTS.md «ammo»): checked here so a
            # wrong bound costs no round trip; the mod checks the rest of the schema
            for k, (lo, hi) in AMMO_BOUNDS.items():
                if k in r:
                    number(lo, hi)(f"set[{i}].{k}", r[k])
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


ORDER_SIZES = ("small", "large")     # MCP.md partner_order: small — the pilot, large — the strategist
ORDER_TEXT_MAX = 300


def check_order_text(v: Any) -> str:
    """``text`` of ``partner_order``: one line, ≤ 300 characters. « » become ``"`` and «хозяин:»
    becomes «хозяин -», so that the voice's wording never passes itself off as the owner's own
    words (those come with the order separately, as ``owner_said``)."""
    if not isinstance(v, str):
        raise bad("text", "must be a string")
    t = " ".join(v.split())
    if not t:
        raise bad("text", "must not be empty")
    if len(t) > ORDER_TEXT_MAX:
        raise PartnerError("limit", f"text: at most {ORDER_TEXT_MAX} characters")
    t = t.replace("«", '"').replace("»", '"')
    return re.sub(r"(?i)хозяин\s*:", "хозяин -", t)


# ---- build packages (MCP.md «Пакеты стройки») ---------------------------------------

PACKAGE_MAX = 8 * 1024             # the whole package as JSON
PACKAGE_NAME_MAX = 60
PACKAGE_NOTE_MAX = 300
PACKAGE_PRIORITIES = ("now", "next", "later")
PACKAGE_CHECKS_MAX = 3
CHECK_RADIUS_DEFAULT = 32
CHECK_VALUE_MAX = 10_000_000
ORDER_ID_RE = re.compile(r"^o[0-9]{1,9}$")
_PACKAGE_FIELDS = ("name", "anchor", "priority", "steps", "on_fail", "verify", "note", "order", "approved")
_CHECK_FIELDS = {
    "stock": {"kind", "item", "at_least", "radius", "center"},
    "rate": {"kind", "item", "at_least", "surface"},
    "ghosts": {"kind", "at_most", "radius", "center"},
}


def _line(field: str, v: Any, limit: int) -> str:
    """One line of text the voice may read to the owner: « » become ``"`` (as in orders)."""
    if not isinstance(v, str):
        raise bad(field, "must be a string")
    t = " ".join(v.split())
    if not t:
        raise bad(field, "must not be empty")
    if len(t) > limit:
        raise PartnerError("limit", f"{field}: at most {limit} characters")
    t = t.replace("«", '"').replace("»", '"')
    return re.sub(r"(?i)хозяин\s*:", "хозяин -", t)


def check_line(field: str, v: Any, limit: int) -> str:
    """One line the voice may read to the owner (the strategist's note and questions)."""
    return _line(field, v, limit)


# a package runs on the body without the pilot's turn: only building steps and the helper's own
# armour. Nothing that breaks the owner's buildings (deconstruct, pickup, mine{target}, rotate,
# set_recipe), no superforced or partial blueprint (only with the owner's word, given to the pilot).
# Taking from the owner's chests and machines (TAKE_DO, get_items/collect with from_lines) only with
# his leave: the package names the order and the answered question (``order`` + ``approved``)
PACKAGE_DO = ("walk", "approach", "get_items", "craft", "mine", "insert", "place", "build_blueprint",
              "build_layout", "connect_entities", "build_ghosts", "plan_mining", "plan_belt", "wait",
              "equip", "armor_grid")
TAKE_DO = ("collect", "extract")
GET_DO = ("get_items",) + TAKE_DO     # steps that bring items into the pockets
QUESTION_ID_RE = re.compile(r"^q[0-9]{1,9}$")

# the shape of each action and of each field, for the texts of refusals (one place: the strategist
# reads them and fixes the field instead of trying variants)
STEP_EXAMPLES: dict[str, dict] = {
    "walk": {"to": {"x": 10, "y": 20}},
    "approach": {"target": {"name": "iron-chest", "pos": {"x": 10.5, "y": 20.5}}},
    "follow": {"distance": 4},
    "mine": {"resource": "iron-ore", "count": 50},
    "craft": {"recipe": "iron-gear-wheel", "count": 20},
    "insert": {"target": {"name": "assembling-machine-1", "pos": {"x": 10.5, "y": 20.5}},
               "items": {"electronic-circuit": 60}},
    "extract": {"target": {"name": "iron-chest", "pos": {"x": 10.5, "y": 20.5}},
                "items": {"electronic-circuit": 60}},
    "collect": {"items": {"electronic-circuit": 60}, "radius": 32},
    "get_items": {"items": {"transport-belt": 50}},
    "pickup": {"corpse": True},
    "place": {"item": "stone-furnace", "pos": {"x": 10, "y": 20}, "direction": 0},
    "rotate": {"target": {"name": "transport-belt", "pos": {"x": 10.5, "y": 20.5}}, "direction": 4},
    "set_recipe": {"target": {"name": "assembling-machine-1", "pos": {"x": 10.5, "y": 20.5}},
                   "recipe": "iron-gear-wheel"},
    "build_blueprint": {"plan": "mining-1", "anchor": {"x": 10, "y": 20}},
    "build_ghosts": {"radius": 16},
    "deconstruct": {"target": {"name": "wooden-chest", "pos": {"x": 10.5, "y": 20.5}}},
    "plan_mining": {"resource": "iron-ore", "near": {"x": 10, "y": 20}},
    "plan_belt": {"from": "patch", "to": {"x": 40, "y": 20}},
    "build_layout": {"anchor": {"x": 10, "y": 20},
                     "entities": [{"name": "stone-furnace", "dx": 0, "dy": 0}]},
    "connect_entities": {"kind": "belt", "from": {"pos": {"x": 10, "y": 20}},
                         "to": {"pos": {"x": 30, "y": 20}}},
    "wait": {"seconds": 10},
    "equip": {"item": "modular-armor"},
    "armor_grid": {"put": {"solar-panel-equipment": 2}},
}
FIELD_FORMS: dict[str, str] = {
    "to": 'to:{x,y} или "player"', "pos": "pos:{x,y}", "anchor": "anchor:{x,y}", "center": "center:{x,y}",
    "near": "near:{x,y}", "target": "target:{name, pos:{x,y}} или {unit_number, pos?}",
    "items": "items:{name:count}", "item": "item:имя предмета", "count": "count:число",
    "recipe": "recipe:имя рецепта", "resource": "resource:имя ресурса", "radius": "radius:число",
    "direction": "direction:0|4|8|12", "seconds": "seconds:число", "put": "put:{name:count}",
    "take": "take:{name:count}", "from_lines": "from_lines:true|false", "at_least": "at_least:число",
    "at_most": "at_most:число", "kind": "kind:stock|rate|ghosts", "area": "area:{left_top, right_bottom}",
    "plan": "plan:id из partner_plan", "corpse": "corpse:true", "from": 'from:{x,y}, "patch" или "resume"',
}
# fields agents mix up -> the field they meant
FIELD_MIXUPS: dict[str, str] = {"x": "to", "y": "to", "position": "pos", "item": "items", "name": "item",
                                "amount": "count", "n": "count", "qty": "count", "at": "at_least",
                                "min": "at_least", "max": "at_most", "entity": "target", "where": "pos"}
CHECK_EXAMPLES: dict[str, dict] = {
    "stock": {"kind": "stock", "item": "iron-plate", "at_least": 100},
    "rate": {"kind": "rate", "item": "iron-plate", "at_least": 30},
    "ghosts": {"kind": "ghosts", "at_most": 0},
}


def _compact(v: Any) -> str:
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def step_example(do: str) -> str:
    """One step of ``do`` as a package carries it; "" — no example for this action."""
    ex = STEP_EXAMPLES.get(do)
    return _compact({"do": do, "args": ex}) if ex else ""


def _meant(bad_field: str, allowed) -> str | None:
    """The field an agent most likely meant by an unknown one."""
    allowed = list(allowed)
    want = FIELD_MIXUPS.get(bad_field)
    if want in allowed:
        return want
    if bad_field + "s" in allowed:
        return bad_field + "s"
    if bad_field.endswith("s") and bad_field[:-1] in allowed:
        return bad_field[:-1]
    close = difflib.get_close_matches(bad_field, allowed, n=1, cutoff=0.75)
    return close[0] if close else None


def unknown_field_text(head: str, bad_field: str, allowed, example: str = "") -> str:
    """«<head>: unknown field "item" — ожидается items:{name:count}; пример: {...}»."""
    want = _meant(bad_field, allowed)
    if want is not None:
        text = f'{head}: unknown field "{bad_field}" — ожидается {FIELD_FORMS.get(want, want)}'
    else:
        text = f'{head}: unknown field "{bad_field}" — можно: ' + ", ".join(allowed)
    return text + (f"; пример: {example}" if example else "")


def explain_step(head: str, do: Any, args: Any, err: PartnerError) -> PartnerError:
    """A refusal of one step as the strategist should read it: «steps[3] (insert): unknown field
    "item" — ожидается items:{name:count}; пример: {...}». The code stays the same."""
    known = isinstance(do, str) and do in ACTIONS
    ex = step_example(do) if known else ""
    if known and isinstance(args, dict):
        fields = list(ACTIONS[do][0])
        for k in args:
            if k not in fields:
                return PartnerError(err.code, unknown_field_text(f"{head} ({do})", str(k)[:40], fields, ex))
    label = f"{head} ({do})" if known else head
    out = f"{label}: {err.text}" if err.text else label
    if known:
        fields, required, _ = ACTIONS[do]
        out += "; форма: " + ", ".join(FIELD_FORMS.get(k, k) + ("" if k in required else "?") for k in fields)
        if ex:
            out += f"; пример: {ex}"
    return PartnerError(err.code, out)


def takes_from_owner(do: str, args: Any) -> bool:
    """A step that takes from the owner's chests and machines: only with his leave in a package."""
    a = args if isinstance(args, dict) else {}
    return do in TAKE_DO or (do in ("get_items", "collect") and a.get("from_lines") is True)


TAKE_REFUSAL = ("забирать из машин и сундуков хозяина пакетом можно только с его разрешения: order + "
                "approved (id отвеченного вопроса) — спроси хозяина partner_ledger{action:\"ask\"}, после "
                "его ответа поставь пакет с order и approved:\"q<N>\"")


def package_steps(field: str, v: Any, approved: bool = False) -> list:
    """``package.steps``: ``plan_steps`` limited to ``PACKAGE_DO``; steps of ``TAKE_DO`` and
    ``from_lines:true`` only with ``approved`` (the package carries the owner's leave; the caller
    checks it against the answered question). Every refusal names the step and its action
    (``explain_step``): «steps[3] (insert): …»."""
    if not isinstance(v, list) or not v:
        raise bad(field, "must be a non-empty list of steps {do, args?, on_fail?}; пример: "
                  + step_example("walk"))
    if len(v) > PLAN_STEPS_MAX:
        raise PartnerError("limit", f"{field}: at most {PLAN_STEPS_MAX} steps")
    out = []
    for i, s in enumerate(v, 1):
        head = f"steps[{i}]"
        if not isinstance(s, dict):
            raise PartnerError("bad_args", f"{head}: must be an object {{do, args?, on_fail?}}; пример: "
                               + step_example("walk"))
        do, args = s.get("do"), s.get("args")
        for k in s:
            if k not in ("do", "args", "on_fail"):
                ex = step_example(do) if isinstance(do, str) else ""
                ex = ex or step_example("walk")
                if isinstance(do, str) and do in ACTIONS and k in ACTIONS[do][0]:
                    text = f'{head} ({do}): field "{k}" goes inside args — {{do, args:{{{k}: …}}}}; пример: {ex}'
                else:
                    text = unknown_field_text(head, str(k)[:40], ("do", "args", "on_fail"), ex)
                raise PartnerError("bad_args", text)
        if not isinstance(do, str) or do not in ACTIONS:
            raise PartnerError("bad_args", f'{head}: unknown action "{str(do)[:40]}"; в пакете можно: '
                               + ", ".join(PACKAGE_DO) + "; с разрешения хозяина ещё " + ", ".join(TAKE_DO))
        if do == "plan":
            raise PartnerError("bad_args", f"{head} (plan): a package is a plan already, steps cannot hold one")
        take = takes_from_owner(do, args)
        if do not in PACKAGE_DO and not take:
            raise PartnerError("bad_args", f"{head} ({do}): не шаг стройки — разбирать, подбирать, вращать и "
                               "перенастраивать постройки хозяина пакет не может, это работа пилота; в пакете "
                               "можно: " + ", ".join(PACKAGE_DO) + "; с разрешения хозяина ещё "
                               + ", ".join(TAKE_DO) + " и from_lines:true")
        if take and not approved:
            raise PartnerError("bad_args", f"{head} ({do}): {TAKE_REFUSAL}")
        try:
            step = {"do": do, "args": check_act(do, args)}
            if "on_fail" in s:
                step["on_fail"] = enum("stop", "continue")("on_fail", s["on_fail"])
        except PartnerError as e:
            raise explain_step(head, do, args, e) from None
        a = step["args"]
        if do == "mine" and "target" in a:
            raise PartnerError("bad_args", f"{head} (mine): a package mines only by resource or item, not "
                               "target (that breaks a building of the owner); пример: " + step_example("mine"))
        if do == "build_blueprint" and (a.get("force") == "superforced" or a.get("partial")):
            raise PartnerError("bad_args", f"{head} (build_blueprint): superforced and partial need the "
                               "owner's word: not in a package")
        if do == "build_layout" and a.get("keep_ghosts"):
            raise PartnerError("bad_args", f"{head} (build_layout): a package must not leave ghosts behind "
                               "(the owner's drones would build them): drop keep_ghosts")
        if do == "connect_entities" and a.get("build") is False:
            raise PartnerError("bad_args", f"{head} (connect_entities): a package must not leave ghosts "
                               "behind (the owner's drones would build them): drop build:false")
        out.append(step)
    return out


def needs_leave(steps: list) -> bool:
    """Whether checked ``steps`` take from the owner (need ``order`` + ``approved``)."""
    return any(takes_from_owner(st.get("do"), st.get("args")) for st in steps if isinstance(st, dict))


def restart_step(steps: list, from_step: int) -> int:
    """The step a stopped package goes on from: its first unfinished step, or — when steps that get
    items (get_items, collect, extract) stand before it — the first of the last run of such steps:
    what they brought may be gone by now (another job took it), so they run again."""
    j = None
    for i in range(min(from_step, len(steps) + 1) - 1, 0, -1):
        if isinstance(steps[i - 1], dict) and steps[i - 1].get("do") in GET_DO:
            j = i
            break
    if j is None:
        return from_step
    while j > 1 and isinstance(steps[j - 2], dict) and steps[j - 2].get("do") in GET_DO:
        j -= 1
    return j


def check_package_check(field: str, v: Any) -> dict:
    """One check of ``verify``: ``stock`` — at least N of an item in the stores around ``center``
    (the anchor by default); ``rate`` — at least N made per minute on the surface (statistics of the
    last minute); ``ghosts`` — at most N ghosts left around ``center``."""
    if not isinstance(v, dict):
        raise bad(field, "must be an object {kind, ...}; пример: " + _compact(CHECK_EXAMPLES["stock"]))
    kind = v.get("kind")
    if not isinstance(kind, str) or kind not in _CHECK_FIELDS:
        raise bad(f"{field}.kind", "must be one of " + ", ".join(_CHECK_FIELDS) + "; пример: "
                  + _compact(CHECK_EXAMPLES["stock"]))
    for k in v:
        if k not in _CHECK_FIELDS[kind]:
            raise PartnerError("bad_args", unknown_field_text(f"{field} ({kind})", str(k)[:40],
                                                              sorted(_CHECK_FIELDS[kind]),
                                                              _compact(CHECK_EXAMPLES[kind])))
    out: dict = {"kind": kind}
    if kind in ("stock", "rate"):
        if "item" not in v:
            raise bad(f"{field}.item", "required")
        out["item"] = name(f"{field}.item", v["item"])
        if "at_least" not in v:
            raise bad(f"{field}.at_least", "required")
        out["at_least"] = number(0, CHECK_VALUE_MAX)(f"{field}.at_least", v["at_least"])
        if out["at_least"] <= 0:
            raise bad(f"{field}.at_least", "must be > 0")
    if kind == "ghosts":
        out["at_most"] = integer(0, CHECK_VALUE_MAX)(f"{field}.at_most", v.get("at_most", 0))
    if kind in ("stock", "ghosts"):
        out["radius"] = number(1, AREA_SIDE_MAX)(f"{field}.radius", v.get("radius", CHECK_RADIUS_DEFAULT))
        if "center" in v:
            out["center"] = pos(f"{field}.center", v["center"])
    if kind == "rate" and "surface" in v:
        out["surface"] = name(f"{field}.surface", v["surface"])
    return out


PACKAGE_EXAMPLE = _compact({"name": "печи", "anchor": {"x": 10, "y": 20},
                            "steps": [{"do": "get_items", "args": {"items": {"stone-furnace": 4}}},
                                      {"do": "place", "args": {"item": "stone-furnace",
                                                               "pos": {"x": 10, "y": 20}}}],
                            "verify": [{"kind": "ghosts", "at_most": 0}]})


def check_package(v: Any) -> dict:
    """``partner_ledger{action:"put", package}``: a named plan of ``plan`` steps with an anchor, a
    priority and 1..3 checks; the whole package ≤ 8 KB of JSON. Each step is checked as its own act
    (``plan_steps``), so a package the server accepts is a plan the mod would accept; only building
    steps (``PACKAGE_DO``). Steps that take from the owner (``TAKE_DO``, ``from_lines:true``) need
    ``order`` + ``approved`` (q<N>); whether that question is answered and belongs to the order, the
    caller checks (core.Core.check_leave)."""
    if not isinstance(v, dict):
        raise bad("package", "must be an object")
    if json_size(v) > PACKAGE_MAX:
        raise PartnerError("limit", f"package: larger than {PACKAGE_MAX} bytes of JSON")
    for k in v:
        if k not in _PACKAGE_FIELDS:
            raise PartnerError("bad_args", unknown_field_text("package", str(k)[:40], _PACKAGE_FIELDS,
                                                              PACKAGE_EXAMPLE))
    for k in ("name", "anchor", "steps", "verify"):
        if k not in v:
            raise bad(f"package.{k}", "required; пример: " + PACKAGE_EXAMPLE)
    if "approved" in v and "order" not in v:
        raise bad("package.approved", "goes with order: the owner's order (o<N>) the leave is for")
    out: dict = {"name": _line("package.name", v["name"], PACKAGE_NAME_MAX),
                 "anchor": pos("package.anchor", v["anchor"]),
                 "priority": enum(*PACKAGE_PRIORITIES)("package.priority", v.get("priority", "next")),
                 "steps": package_steps("package.steps", v["steps"],
                                        approved=bool(v.get("approved")) and bool(v.get("order"))),
                 "on_fail": enum("stop", "continue")("package.on_fail", v.get("on_fail", "stop"))}
    checks = v["verify"]
    if not isinstance(checks, list) or not 1 <= len(checks) <= PACKAGE_CHECKS_MAX:
        raise bad("package.verify", f"must be a list of 1..{PACKAGE_CHECKS_MAX} checks")
    out["verify"] = [check_package_check(f"package.verify[{i}]", c) for i, c in enumerate(checks, 1)]
    if "note" in v:
        out["note"] = _line("package.note", v["note"], PACKAGE_NOTE_MAX)
    if "order" in v:
        if not isinstance(v["order"], str) or not ORDER_ID_RE.match(v["order"]):
            raise bad("package.order", "must be an order id from partner_inbox (o<N>)")
        out["order"] = v["order"]
    if "approved" in v:
        if not isinstance(v["approved"], str) or not QUESTION_ID_RE.match(v["approved"]):
            raise bad("package.approved", "must be the id of the strategist's question the owner "
                                          "answered (q<N>)")
        if "order" not in out:
            raise bad("package.approved", "goes with order: the owner's order (o<N>) the leave is for")
        out["approved"] = v["approved"]
    return out
