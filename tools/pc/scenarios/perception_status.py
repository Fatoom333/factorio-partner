"""Живой сценарий: `status` — что стоит и почему, рядом с базой хозяина.

Ход (сервер без окна, хозяин офлайн):
1. `hello`, `helper_spawn`.
2. `status {radius:64}` с опросом до INDEX_WAIT_S, пока `index_ready` не станет true (индекс построек
   на сейве без него заполняется раскруткой по тикам).
3. Разбор по STATE.md («status»): `machines.seen/running/stopped/hidden/ignored` — числа; `causes` —
   словарь «разряд → число»; `stopped` — список групп `{name, reason, cause, pos, dist}` с известным
   разрядом; `helper.queue`; `radius` вне предела — `limit` или `bad_args`.
В радиусе нет ни одной машины хозяина — сценарий пишет причину (kind=setup).
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import importlib.util
import os


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


P = _load("build_place")
HELPER = P.HELPER
RADIUS = 64
INDEX_WAIT_S = 30.0
CAUSES = {"power", "fuel", "resource", "input", "output", "recipe", "heat", "disabled", "other",
          "slow", "research", "rocket"}


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} else v


def as_dict(v):
    return {} if v == [] else v


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def run(client) -> dict:
    result = {}
    if not P.start(client, result):
        return result
    last = {}

    def look():
        last["data"] = client.call_ok("status", {"radius": RADIUS}, HELPER)
        return last["data"].get("index_ready") is True

    ready = bool(client.poll(look, INDEX_WAIT_S, 1.0))
    data = last["data"]
    rows = as_list(data.get("stopped"))
    result.update(index_ready=ready, machines=data.get("machines"), causes=data.get("causes"),
                  stopped_groups=len(rows) if isinstance(rows, list) else None)
    reasons = []
    if not ready:
        reasons.append(f"index_ready не стал true за {INDEX_WAIT_S:.0f} с")
    machines = as_dict(data.get("machines")) or {}
    for key in ("seen", "running", "stopped", "hidden", "ignored"):
        if not _is_int(machines.get(key)):
            reasons.append(f"machines.{key} не число: {machines.get(key)!r}")
    causes = as_dict(data.get("causes"))
    if not isinstance(causes, dict) or not all(_is_int(v) for v in causes.values()):
        reasons.append(f"causes не словарь чисел: {causes!r}")
    elif set(causes) - CAUSES:
        reasons.append(f"causes: незнакомые разряды {sorted(set(causes) - CAUSES)}")
    if not isinstance(rows, list):
        reasons.append(f"stopped не список: {rows!r}")
        rows = []
    for row in rows:
        if not (row.get("name") and row.get("reason") and row.get("cause") in CAUSES
                and isinstance(row.get("pos"), dict) and isinstance(row.get("dist"), (int, float))):
            reasons.append(f"stopped: неполная группа {row!r}")
            break
    if not _is_int((as_dict(data.get("helper")) or {}).get("queue")):
        reasons.append(f"helper.queue не число: {data.get('helper')!r}")
    if data.get("radius") != RADIUS:
        reasons.append(f"radius в ответе {data.get('radius')!r}, просили {RADIUS}")
    bad = client.call("status", {"radius": 129}, HELPER)
    code = None if bad["ok"] else (bad.get("error") or {}).get("code")
    result["radius_129"] = code
    if code not in ("limit", "bad_args"):
        reasons.append(f"radius 129: ждали limit или bad_args, пришло {code!r}")
    if not reasons and machines.get("seen") == 0:
        return P.setup_failed(result, f"в радиусе {RADIUS} нет ни одной машины хозяина: status ничего не показал")
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
