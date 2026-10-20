"""The owner's settings of the mod (op ``settings``, PROTOCOL §4; README «Настройки»).

The owner sets them in the game (map settings of the mod, tab «Карта»); the server only reads them:

- ``perms`` — what the helpers may do: ``auto`` (by themselves), ``ask`` (only after the owner's
  «да»: the call carries ``approved`` + ``order``, the server checks the question and adds
  ``owner_ok``) or ``deny`` (never; the mod refuses with ``owner_forbids``);
- ``limits`` — the numbers behind two of them (``spend``, ``far``);
- ``agents`` — how many helpers and which models to start, the strategist's thoughts by default,
  the voice's pause, the thresholds of the plan-limit watchdog;
- ``combat``, ``chat`` — read by the mod and by the roles' rules.

Every value is checked here: a missing, malformed or out-of-range one is the default of this file,
so an old mod (no ``settings`` op) or a broken answer works as the defaults. ``normalize`` never
raises.
"""
from __future__ import annotations

import copy
import math
from typing import Any

from . import validate as V

PERM_VALUES = ("auto", "ask", "deny")

# perm key (without "perm-", "-" -> "_") -> its default
PERM_DEFAULTS: dict[str, str] = {
    "take_chests": "auto",
    "take_lines": "ask",
    "take_inputs": "deny",
    "build": "auto",
    "superforced": "ask",
    "deconstruct_own": "auto",
    "deconstruct_owner": "ask",
    "set_recipe": "ask",
    "chop": "auto",
    "smelt": "auto",
    "spend": "ask",
    "shoot": "ask",
    "turrets": "auto",
    "upkeep": "ask",
    "attack_nests": "deny",
    "walk_far": "auto",
    "leave_planet": "deny",
    "auto": "ask",
}

# what each permission is about, as the owner reads it in a refusal
PERM_LABELS: dict[str, str] = {
    "take_chests": "брать из свободных сундуков хозяина",
    "take_lines": "брать из выходов линий и машин хозяина",
    "take_inputs": "брать из входов и топлива машин хозяина",
    "build": "строить",
    "superforced": "строить чертёж с заменой построек (superforced)",
    "deconstruct_own": "разбирать постройки помощников",
    "deconstruct_owner": "разбирать постройки хозяина",
    "set_recipe": "менять рецепт в машине хозяина",
    "chop": "рубить деревья и бить камни",
    "smelt": "плавить в свободных печах хозяина",
    "spend": "тратить на одну стройку больше предела предметов",
    "shoot": "стрелять (рефлекс shoot)",
    "turrets": "заправлять турели (рефлекс ammo)",
    "upkeep": "обслуживать постройки (рефлекс upkeep)",
    "attack_nests": "нападать на гнёзда и червей",
    "walk_far": "уходить далеко от хозяина",
    "leave_planet": "действовать на другой поверхности",
    "auto": "самостоятельный режим AUTO",
}

WHERE = "настройки мода, вкладка «Карта»"

# (section, key) -> (kind, default, lo, hi); kind: int | num | bool | enum values
_FIELDS: dict[tuple[str, str], tuple[Any, Any, Any, Any]] = {
    ("limits", "spend"): ("int", 200, 1, 1_000_000),
    ("limits", "far"): ("int", 300, 1, 1_000_000),
    ("agents", "helpers"): ("int", 1, 1, 5),
    ("agents", "pilot_model"): (("sonnet", "haiku"), "sonnet", None, None),
    ("agents", "strategist_model"): (("sonnet", "opus"), "sonnet", None, None),
    ("agents", "thoughts"): ("bool", False, None, None),
    ("agents", "voice_pause"): ("num", 2.5, 0, 6),
    ("combat", "flee_health"): ("int", 40, 5, 95),
    ("combat", "auto_armor"): ("bool", True, None, None),
    ("combat", "turret_standoff"): ("bool", True, None, None),
    ("combat", "turret_gap"): ("int", 3, 1, 10),
    ("chat", "answer_every"): ("bool", True, None, None),
    ("chat", "reply_lines"): ("int", 2, 1, 6),
}
_BUDGET: dict[str, tuple[int, int, int]] = {      # agents.budget.<key> -> (default, lo, hi)
    "strategist": (70, 1, 100),
    "voice_only": (85, 1, 100),
    "weekly": (90, 1, 101),
}


def _defaults() -> dict:
    out: dict = {"perms": dict(PERM_DEFAULTS)}
    for (sec, key), (_kind, default, _lo, _hi) in _FIELDS.items():
        out.setdefault(sec, {})[key] = default
    out["agents"]["budget"] = {k: d for k, (d, _lo, _hi) in _BUDGET.items()}
    return out


DEFAULTS = _defaults()


def defaults() -> dict:
    """A fresh copy of the defaults (``source: "default"``)."""
    return dict(copy.deepcopy(DEFAULTS), source="default")


def _num(v: Any, integer: bool, lo: float, hi: float) -> float | int | None:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if isinstance(v, float):
        if not math.isfinite(v):
            return None
        if integer:
            if not v.is_integer():
                return None
            v = int(v)
    if not lo <= v <= hi:
        return None
    return v


def normalize(raw: Any) -> dict:
    """The mod's answer -> the full settings: every good value taken, every other one the default."""
    out = defaults()
    if not isinstance(raw, dict):
        return out
    out["source"] = "mod"
    perms = raw.get("perms")
    if isinstance(perms, dict):
        for k in PERM_DEFAULTS:
            v = perms.get(k)
            if v in PERM_VALUES:
                out["perms"][k] = v
    for (sec, key), (kind, _default, lo, hi) in _FIELDS.items():
        part = raw.get(sec)
        if not isinstance(part, dict) or key not in part:
            continue
        v = part[key]
        if kind == "bool":
            good = v if isinstance(v, bool) else None
        elif kind in ("int", "num"):
            good = _num(v, kind == "int", lo, hi)
        else:
            good = v if v in kind else None
        if good is not None:
            out[sec][key] = good
    agents = raw.get("agents")
    budget = agents.get("budget") if isinstance(agents, dict) else None
    if isinstance(budget, dict):
        for k, (_d, lo, hi) in _BUDGET.items():
            v = _num(budget.get(k), True, lo, hi)
            if v is not None:
                out["agents"]["budget"][k] = v
    return out


def perm(settings: dict, key: str) -> str:
    """auto | ask | deny of one permission (an unknown key is ``deny``: fail closed)."""
    v = (settings.get("perms") or {}).get(key) if isinstance(settings, dict) else None
    return v if v in PERM_VALUES else ("deny" if key not in PERM_DEFAULTS else PERM_DEFAULTS[key])


def label(key: str) -> str:
    return PERM_LABELS.get(key, key)


PERM_ASK_MAX = 4   # permission keys one question to the owner may ask for


def perm_keys(field: str, v: Any) -> list[str]:
    """``perm`` of a question to the owner: one key or a list of keys ("take_lines", "take-lines" or
    "perm-take-lines"), each a known permission, at most PERM_ASK_MAX -> normalized keys, no repeats."""
    items = [v] if isinstance(v, str) else v
    if not isinstance(items, list) or not items or len(items) > PERM_ASK_MAX:
        raise V.bad(field, f"one permission key or a list of 1..{PERM_ASK_MAX} (partner_brief.perms.ask)")
    out: list[str] = []
    for i, k in enumerate(items):
        if not isinstance(k, str) or len(k) > 40:
            raise V.bad(f"{field}[{i}]", "must be a permission key, e.g. take_lines")
        key = k.strip().lower().replace("-", "_")
        if key.startswith("perm_"):
            key = key[len("perm_"):]
        if key not in PERM_DEFAULTS:
            raise V.bad(f"{field}[{i}]", f"unknown permission {k!r}; known: " + ", ".join(PERM_DEFAULTS))
        if key not in out:
            out.append(key)
    return out


def ask_suffix(keys: list[str]) -> str:
    """What a question asks leave for, as the voice reads it to the owner."""
    return " (разрешение: " + "; ".join(label(k) for k in keys) + ")"


def forbids_text(key: str) -> str:
    """The refusal of a ``deny`` permission, as the owner and the agent read it."""
    return f"запрещено в настройках мода: {label(key)} ({WHERE}, perm-{key.replace('_', '-')})"


def brief_perms(settings: dict) -> dict:
    """``partner_brief.perms``: only what is not ``auto`` (ask / deny) and the limits."""
    p = settings.get("perms") or {}
    return {"ask": sorted(k for k in PERM_DEFAULTS if p.get(k) == "ask"),
            "deny": sorted(k for k in PERM_DEFAULTS if p.get(k) == "deny"),
            "limits": dict(settings.get("limits") or {}),
            "source": settings.get("source", "default"),
            "how": "ask — сначала вопрос хозяину (partner_ledger ask с order и perm — ключи, о которых "
                   "спрашиваешь), после его «да» тот же вызов с approved:\"q<N>\" и order:\"o<N>\": «да» "
                   "снимает только эти ключи и годится на 3 вызова за 30 минут; deny — не пытайся, скажи "
                   "хозяину, что это запрещено в " + WHERE}


def brief_chat(settings: dict) -> dict:
    c = settings.get("chat") or {}
    return {"answer_every": c.get("answer_every", True), "reply_lines": c.get("reply_lines", 2)}


# ---------------------------------------------------------------- what a package step touches
# The server checks the permissions of package steps only where the arguments tell for sure; the mod
# checks every action itself (perms.check). A package step that takes (TAKE_DO, from_lines) takes
# from the owner by definition.
BUILD_DO = ("place", "build_blueprint", "build_layout", "build_ghosts", "connect_entities",
            "plan_mining", "plan_belt")


def step_perms(do: str, args: Any) -> list[str]:
    a = args if isinstance(args, dict) else {}
    keys: list[str] = []
    if do in V.TAKE_DO:
        keys.append("take_chests")
    if do in ("get_items", "collect") and a.get("from_lines") is True:
        keys.append("take_lines")
    if do in BUILD_DO and a.get("dry_run") is not True:
        keys.append("build")
    if do == "build_blueprint" and a.get("force") == "superforced":
        keys.append("superforced")
    return keys


def denied_step(settings: dict, steps: list) -> tuple[int, str, str] | None:
    """The first package step whose permission is ``deny`` -> (step number, do, perm key)."""
    for i, st in enumerate(steps, 1):
        if not isinstance(st, dict):
            continue
        for k in step_perms(st.get("do"), st.get("args")):
            if perm(settings, k) == "deny":
                return i, str(st.get("do")), k
    return None
