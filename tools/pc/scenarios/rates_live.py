"""Живой сценарий: `rates` без помощника (STATE.md «rates», PROTOCOL §4 «h? без помощника»).

Ход:
1. `hello` — находим хозяина (`owner`) и его последнюю позицию/поверхность.
2. `rates{scope:"surface", period:"1m"}` и `"10m"` на поверхности хозяина (без помощника).
   Хозяин онлайн — без `surface` (проверяем выбор через core.owner); офлайн — с явным `surface`.
3. `rates{scope:"area"}` — квадрат 64×64 вокруг позиции хозяина.
Проверяется только форма ответа и отсутствие ошибок (числа зависят от сейва); только чтение.
"""
from __future__ import annotations

PERIODS = ("1m", "10m")
AREA_HALF = 32


def _num(x) -> bool:
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def _check_table(t, what, problems):
    if not isinstance(t, dict):
        problems.append(f"{what}: не объект")
        return
    for name, row in t.items():
        if not (isinstance(row, dict) and _num(row.get("made")) and _num(row.get("used"))):
            problems.append(f"{what}[{name}]: нет числовых made/used")
            return


def check_surface(data, period, surface, problems):
    if data.get("scope") != "surface":
        problems.append(f"scope={data.get('scope')!r}")
    if data.get("period") != period:
        problems.append(f"period={data.get('period')!r}")
    if surface is not None and data.get("surface") != surface:
        problems.append(f"surface={data.get('surface')!r}, ждали {surface!r}")
    _check_table(data.get("items"), "items", problems)
    _check_table(data.get("fluids"), "fluids", problems)
    if not isinstance(data.get("truncated"), bool):
        problems.append("truncated не bool")


def check_area(data, surface, problems):
    if data.get("scope") != "area":
        problems.append(f"scope={data.get('scope')!r}")
    if surface is not None and data.get("surface") != surface:
        problems.append(f"surface={data.get('surface')!r}, ждали {surface!r}")
    if data.get("per") != "1m":
        problems.append(f"per={data.get('per')!r}")
    if data.get("nominal") is not True:
        problems.append("nominal не true")
    area = data.get("area")
    try:
        ok_area = all(_num(area[k][c]) for k in ("left_top", "right_bottom") for c in ("x", "y"))
    except (TypeError, KeyError):
        ok_area = False
    if not ok_area:
        problems.append("area без left_top/right_bottom")
    for key in ("hidden", "idle"):
        if not (isinstance(data.get(key), int) and not isinstance(data.get(key), bool) and data[key] >= 0):
            problems.append(f"{key} не целое >= 0")
    if not isinstance(data.get("truncated"), bool):
        problems.append("truncated не bool")
    machines = data.get("machines")
    if not isinstance(machines, list):
        problems.append("machines не список")
    else:
        for m in machines:
            if not (isinstance(m, dict) and isinstance(m.get("name"), str) and isinstance(m.get("recipe"), str)
                    and isinstance(m.get("count"), int) and isinstance(m.get("in"), dict)
                    and isinstance(m.get("out"), dict)):
                problems.append(f"машина неверной формы: {str(m)[:80]}")
                break
    if not isinstance(data.get("net"), dict):
        problems.append("net не объект")


def run(client) -> dict:
    hello = client.call_ok("hello")
    owner = hello.get("owner")
    players = hello.get("players") or []
    me = None
    for p in players:
        if p.get("name") == owner or (not owner and p.get("index") == 1):
            me = p
            break
    result = {"owner": owner, "mod": hello.get("mod")}
    if me is None or not isinstance(me.get("pos"), dict):
        return {**result, "ok": False,
                "error": {"kind": "setup", "text": "хозяин не найден в hello.players (нужна его позиция)"}}
    online = bool(me.get("online"))
    surface = me.get("surface")
    x, y = float(me["pos"]["x"]), float(me["pos"]["y"])
    result.update(owner_online=online, surface=surface)

    problems = []
    steps = {}
    base = {} if online else {"surface": surface}  # офлайн: поверхность задаём явно

    for period in PERIODS:
        reply = client.call("rates", {"scope": "surface", "period": period, **base})
        steps[f"surface_{period}"] = {"ok": reply["ok"]}
        if not reply["ok"]:
            problems.append(f"surface {period}: {reply.get('error')}")
            continue
        n0 = len(problems)
        check_surface(reply["data"], period, surface, problems)
        steps[f"surface_{period}"]["items"] = len(reply["data"].get("items") or {})
        steps[f"surface_{period}"]["problems"] = problems[n0:]

    area = {"left_top": {"x": x - AREA_HALF, "y": y - AREA_HALF},
            "right_bottom": {"x": x + AREA_HALF, "y": y + AREA_HALF}}
    reply = client.call("rates", {"scope": "area", "period": "1m", "area": area, **base})
    steps["area"] = {"ok": reply["ok"]}
    if not reply["ok"]:
        problems.append(f"area: {reply.get('error')}")
    else:
        n0 = len(problems)
        check_area(reply["data"], surface, problems)
        d = reply["data"]
        steps["area"].update(groups=len(d.get("machines") or []), hidden=d.get("hidden"),
                             idle=d.get("idle"), problems=problems[n0:])

    result["steps"] = steps
    result["ok"] = not problems
    if problems:
        result["reasons"] = problems
    return result
