"""Plan-limit watchdog (docs/MCP.md «Сторож лимита»).

The server does not know how much of the plan limit is spent: the figure comes from outside, as a
small JSON file whose path is in ``FP_BUDGET_FILE``::

    {"five_hour_pct": 62, "weekly_pct": 40, "ts": 1790000000}

(``five_pct`` / ``week_pct`` / ``captured_at`` are accepted as the same fields: that is what the
usual limit-gate hook of the Claude Code setup writes, so its file can be used as it is). ``ts`` is
Unix seconds. The file is only read, never written, and holds no secrets.

Levels (``Budget.level``):

- ``ok`` — the five-hour window is below the first threshold;
- ``strategist_off`` — at or above ``warn`` (default 70 %): the strategist leaves the auto mode;
- ``voice_only`` — at or above ``stop`` (default 85 %), or the weekly figure at or above
  ``week_stop`` (default 90 %): only the mod and the voice are left;
The thresholds come from ``FP_BUDGET_WARN`` / ``FP_BUDGET_STOP`` / ``FP_BUDGET_WEEK_STOP`` when set;
else from the mod's settings (``agents.budget``: strategist, voice_only, weekly — ``apply_settings``);
else the defaults below.

- ``unknown`` — no file, an unreadable or malformed one, or data older than ``max_age`` (default
  10 minutes). Unknown limits nothing: a missing figure must not stop the helper.
"""
from __future__ import annotations

import json
import math
import time
from pathlib import Path
from typing import Any, Callable, Mapping

from .errors import ConfigError

OK = "ok"
STRATEGIST_OFF = "strategist_off"
VOICE_ONLY = "voice_only"
UNKNOWN = "unknown"
LEVELS = (OK, STRATEGIST_OFF, VOICE_ONLY, UNKNOWN)

DEFAULT_WARN = 70.0
DEFAULT_STOP = 85.0
DEFAULT_WEEK_STOP = 90.0
DEFAULT_MAX_AGE = 600.0
MAX_FILE = 4096                 # the file is a few dozen bytes; anything bigger is not ours
FUTURE_SLACK = 120.0            # a timestamp this far ahead is a broken clock: counts as bad

_FIVE = ("five_hour_pct", "five_pct")
_WEEK = ("weekly_pct", "week_pct")
_TS = ("ts", "captured_at")


def _pct(raw: Any) -> float | None:
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return None
    v = float(raw)
    return v if math.isfinite(v) and 0 <= v <= 100 else None


def _first(d: Mapping, names: tuple[str, ...]) -> Any:
    for n in names:
        if n in d:
            return d[n]
    return None


def _env_num(env: Mapping[str, str], name: str, default: float | None, lo: float, hi: float) -> float | None:
    raw = (env.get(name) or "").strip()
    if not raw:
        return default
    try:
        v = float(raw)
    except ValueError:
        raise ConfigError(f"{name} must be a number") from None
    if not (math.isfinite(v) and lo <= v <= hi):
        raise ConfigError(f"{name} must be {lo:g}..{hi:g}")
    return v


class Budget:
    def __init__(self, path: Path | None = None, *, warn: float | None = None,
                 stop: float | None = None, week_stop: float | None = None,
                 max_age: float = DEFAULT_MAX_AGE, now: Callable[[], float] = time.time):
        # a threshold given here (or by the environment) is fixed: the mod's settings do not move it
        self.fixed = {n for n, v in (("warn", warn), ("stop", stop), ("week_stop", week_stop)) if v is not None}
        warn = DEFAULT_WARN if warn is None else warn
        stop = DEFAULT_STOP if stop is None else stop
        week_stop = DEFAULT_WEEK_STOP if week_stop is None else week_stop
        if not 0 < warn < stop <= 100:
            raise ConfigError("budget thresholds need 0 < warn < stop <= 100")
        self.path = path
        self.warn, self.stop, self.week_stop, self.max_age = warn, stop, week_stop, max_age
        self.now = now

    def apply_settings(self, budget: Mapping[str, Any] | None) -> bool:
        """Thresholds from the mod's settings (``agents.budget``) for those not fixed by the
        environment. A set that breaks 0 < warn < stop <= 100 changes nothing. True — applied."""
        if not isinstance(budget, Mapping):
            return False
        want = {"warn": budget.get("strategist"), "stop": budget.get("voice_only"),
                "week_stop": budget.get("weekly")}
        new = {"warn": self.warn, "stop": self.stop, "week_stop": self.week_stop}
        for k, v in want.items():
            if k in self.fixed:
                continue
            p = _pct(v) if k != "week_stop" else (float(v) if isinstance(v, (int, float))
                                                  and not isinstance(v, bool) and math.isfinite(v)
                                                  and 1 <= v <= 101 else None)
            if p is not None:
                new[k] = p
        if not 0 < new["warn"] < new["stop"] <= 100:
            return False
        self.warn, self.stop, self.week_stop = new["warn"], new["stop"], new["week_stop"]
        return True

    @classmethod
    def from_env(cls, env: Mapping[str, str], now: Callable[[], float] = time.time) -> "Budget":
        raw = (env.get("FP_BUDGET_FILE") or "").strip()
        return cls(Path(raw).expanduser() if raw else None,
                   warn=_env_num(env, "FP_BUDGET_WARN", None, 1, 100),
                   stop=_env_num(env, "FP_BUDGET_STOP", None, 1, 100),
                   week_stop=_env_num(env, "FP_BUDGET_WEEK_STOP", None, 1, 101),
                   max_age=_env_num(env, "FP_BUDGET_MAX_AGE", DEFAULT_MAX_AGE, 1, 86400),
                   now=now)

    @property
    def configured(self) -> bool:
        return self.path is not None

    def _unknown(self, reason: str) -> dict:
        return {"level": UNKNOWN, "reason": reason}

    def status(self) -> dict:
        """``{"level", "five_hour_pct", "weekly_pct", "age_s"}``, or ``{"level":"unknown","reason"}``
        (reason: not_configured, no_file, bad_file, stale)."""
        if self.path is None:
            return self._unknown("not_configured")
        try:
            with open(self.path, "rb") as f:
                blob = f.read(MAX_FILE + 1)
        except OSError:
            return self._unknown("no_file")
        if len(blob) > MAX_FILE:
            return self._unknown("bad_file")
        try:
            d = json.loads(blob.decode("utf-8-sig"))
        except (ValueError, UnicodeDecodeError):
            return self._unknown("bad_file")
        if not isinstance(d, dict):
            return self._unknown("bad_file")
        five = _pct(_first(d, _FIVE))
        week = _pct(_first(d, _WEEK))
        ts = _first(d, _TS)
        if five is None or isinstance(ts, bool) or not isinstance(ts, (int, float)) \
                or not math.isfinite(ts):
            return self._unknown("bad_file")
        ts = float(ts)
        if ts > 1e11:               # milliseconds
            ts /= 1000
        age = self.now() - ts
        if age < -FUTURE_SLACK:
            return self._unknown("bad_file")
        if age > self.max_age:
            return self._unknown("stale")
        level = OK
        if five >= self.stop or (week is not None and week >= self.week_stop):
            level = VOICE_ONLY
        elif five >= self.warn:
            level = STRATEGIST_OFF
        out: dict = {"level": level, "five_hour_pct": five, "age_s": max(0, int(age))}
        if week is not None:
            out["weekly_pct"] = week
        return out

    def level(self) -> str:
        return self.status()["level"]
