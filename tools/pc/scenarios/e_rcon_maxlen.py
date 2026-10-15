"""Замер максимальной длины команды `/partner <JSON>` по RCON (TESTING.md §3, PROTOCOL §2).

Метод: шлём конверт `e_echo` с полем `pad` такой длины, чтобы параметр команды (JSON) был ровно
N байт. Успех — ответ с нашим id и `len == N` (мод partner-test возвращает длину, которую увидел).
С настоящим модом `e_echo` даст `unknown_op` с нашим id — это тоже значит, что JSON
дошёл целиком (иначе был бы `bad_request` без id). Провал — обрыв соединения, таймаут,
`bad_request` или несовпадение длины.

Поиск: удвоение от 1 КБ до потолка, потом двоичный поиск между последним успехом и первым
провалом до точности RESOLUTION байт. Контракт от результата не меняется (≤ 8 КБ + blob_put).
"""
from __future__ import annotations

import json

MODS = ["partner-test"]

START = 1024
CAP = 1024 * 1024
RESOLUTION = 16
PROBE_TIMEOUT = 15.0
CONTRACT_LIMIT = 8 * 1024
# Большой ответ (e_big, только partner-test): строка такой длины, весь ответ ≤ 200 000 байт.
# Проверяет допущение live_client: ответ приходит одним RCON-пакетом (PROTOCOL §2, замер 06.10).
BIG_REPLY = 199000


def _envelope_for(client, size: int):
    """Конверт e_echo, JSON которого занимает ровно size байт (ASCII)."""
    env = client.make_envelope("e_echo", {"pad": ""})
    base = len(json.dumps(env, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    pad = size - base
    if pad < 0:
        raise ValueError(f"размер {size} меньше накладных {base}")
    env["args"]["pad"] = "x" * pad
    return env


def probe(client, size: int, mode: str) -> dict:
    """Один замер. Возвращает {size, ok, kind, ...}. Обрыв соединения чинит переподключением."""
    from_err = None
    try:
        env = _envelope_for(client, size)
        reply = client.send(env, timeout=PROBE_TIMEOUT)
    except Exception as e:  # LiveClientError из клиента стенда
        kind = getattr(e, "kind", "exception")
        from_err = {"size": size, "ok": False, "kind": kind, "text": str(e)[:200]}
    if from_err is not None:
        try:
            client.reconnect()
        except Exception as e:
            from_err["reconnect"] = str(e)[:200]
        return from_err
    if reply.get("ok"):
        seen = (reply.get("data") or {}).get("len")
        if mode == "echo" and seen != size:
            return {"size": size, "ok": False, "kind": "length_mismatch", "seen": seen}
        return {"size": size, "ok": True, "kind": "echo", "seen": seen}
    code = (reply.get("error") or {}).get("code")
    if code == "unknown_op" and reply.get("id") == env["id"]:
        return {"size": size, "ok": True, "kind": "unknown_op"}
    return {"size": size, "ok": False, "kind": code or "error"}


def check_big_reply(client) -> dict:
    """Ответ ~200 КБ должен прийти целиком одним пакетом и разобраться как JSON."""
    try:
        reply = client.call("e_big", {"bytes": BIG_REPLY}, timeout=PROBE_TIMEOUT)
    except Exception as e:  # LiveClientError: обрыв, таймаут, «ответ не JSON» (= раздробили)
        result = {"ok": False, "kind": getattr(e, "kind", "exception"), "text": str(e)[:200]}
        try:
            client.reconnect()
        except Exception:
            pass
        return result
    if not reply.get("ok"):
        return {"ok": False, "kind": (reply.get("error") or {}).get("code") or "error"}
    pad = (reply.get("data") or {}).get("pad")
    got = len(pad) if isinstance(pad, str) else None
    return {"ok": got == BIG_REPLY, "kind": "big", "bytes": got}


def search(probe_fn, start: int = START, cap: int = CAP, resolution: int = RESOLUTION) -> dict:
    """Удвоение + двоичный поиск. probe_fn(size) -> dict с ключом ok. Чистая функция для тестов."""
    probes = []

    def p(size):
        r = probe_fn(size)
        probes.append(r)
        return r

    first = p(start)
    if not first["ok"]:
        return {"max_ok": None, "first_fail": start, "fail_kind": first.get("kind"), "cap_reached": False,
                "probes": probes}
    good, bad, bad_kind = start, None, None
    size = start
    while size < cap:
        size = min(size * 2, cap)
        r = p(size)
        if r["ok"]:
            good = size
        else:
            bad, bad_kind = size, r.get("kind")
            break
    if bad is None:
        return {"max_ok": good, "first_fail": None, "fail_kind": None, "cap_reached": True, "probes": probes}
    while bad - good > resolution:
        mid = (good + bad) // 2
        r = p(mid)
        if r["ok"]:
            good = mid
        else:
            bad, bad_kind = mid, r.get("kind")
    return {"max_ok": good, "first_fail": bad, "fail_kind": bad_kind, "cap_reached": False, "probes": probes}


def run(client) -> dict:
    hello = client.call("hello")
    if not hello.get("ok"):
        return {"ok": False, "error": {"kind": "hello", "text": json.dumps(hello.get("error"), ensure_ascii=False)}}
    mod = str((hello.get("data") or {}).get("mod", ""))
    mode = "echo" if mod.startswith("partner-test") else "unknown_op"
    big = check_big_reply(client) if mode == "echo" else None
    client.max_request_bytes = CAP
    found = search(lambda size: probe(client, size, mode))
    max_ok = found["max_ok"]
    # Последний контрольный: после провалов соединение живо и обычная команда проходит.
    alive = False
    try:
        alive = bool(client.call("hello").get("ok"))
    except Exception:
        try:
            client.reconnect()
            alive = bool(client.call("hello").get("ok"))
        except Exception:
            alive = False
    probes = found.pop("probes")
    return {
        "ok": max_ok is not None and max_ok >= CONTRACT_LIMIT and (big is None or big["ok"]),
        "big_reply": big,
        "mode": mode,
        "mod": mod,
        "max_ok_param_bytes": max_ok,
        "first_fail_param_bytes": found["first_fail"],
        "fail_kind": found["fail_kind"],
        "cap_bytes": CAP,
        "cap_reached": found["cap_reached"],
        "resolution_bytes": RESOLUTION,
        "prefix_bytes": len("/partner "),
        "contract_limit_ok": max_ok is not None and max_ok >= CONTRACT_LIMIT,
        "server_alive_after": alive,
        "probes": [{k: v for k, v in pr.items() if k != "text"} for pr in probes],
        "probe_errors": [pr["text"] for pr in probes if "text" in pr][:5],
    }
