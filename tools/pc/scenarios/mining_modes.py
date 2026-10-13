"""Живой сценарий потока M: режимы раскладки `plan_mining` на настоящем пятне руды.

Ход:
1. Как mining_plan: помощник, ближайшее пятно, где встаёт раскладка `simple` (сухой прогон).
2. Сухой прогон всех семи режимов на этом пятне: `simple`, `compact`, `super_compact`, `sparse`,
   `logistics`, `compact_logistics`, `sparse_logistics`. Режим может не подойти базе (нет подземной
   ленты, сундуков снабжения, бура 3×3) — тогда допустим только отказ `bad_args` с объяснением.
   Обязаны встать `compact` и `sparse`; `sparse` ставит не больше буров, чем `simple`.
3. `compact` ставится по-настоящему и сверяется с игрой (операция `ghosts`, число буров, покрытие —
   функция `verify` из mining_plan); в `need` есть что-то сверх бура, ленты и столба (подземная лента).
4. Ревизия 3.3 (на Вулканусе жидкость — лава): предупреждения всех режимов — только известного вида,
   область каждого `done` не больше 128; у поставленного `compact` ни один бур не стоит на клетке,
   которую карта до разметки рисовала жидкостью (`~` или `,`), а `enclosed` / `narrow_access` /
   `access_side` согласны с операцией `access` по рамке пятна; сухой и настоящий прогон дают одни и те
   же предупреждения. Имён плиток в сценарии нет.
Общие шаги — из mining_plan.py (загрузка по пути). Только конверты `/partner <JSON>`.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
LAYOUTS = ("simple", "compact", "super_compact", "sparse", "logistics", "compact_logistics", "sparse_logistics")
MUST = ("simple", "compact", "sparse")
REAL = "compact"
DIRECTION = "north"


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


P = _load("mining_plan")


def run(client) -> dict:
    result = {"direction": DIRECTION, "real": REAL}
    if not P.prepare(client, result):
        return result
    patches = P.find_patches(client, result)
    if not patches:
        result.update(ok=False, error={"kind": "setup", "text": "в 400 клетках от помощника нет открытых пятен руды (resources)"})
        return result
    picked = P.pick_patch(client, patches, "simple", DIRECTION, result)
    if picked is None:
        result.update(ok=False, reasons=["сухой прогон simple не встал ни на одном пятне"])
        return result
    patch, _ = picked
    result["patch"] = {"name": patch["name"], "center": patch["center"], "area": patch["area"], "tiles": patch.get("tiles"),
                       "dist": patch.get("dist"), "window": patch.get("window")}

    reasons = []
    modes = {}
    dry = {}
    for layout in LAYOUTS:
        r = P.act(client, "plan_mining", P.plan_args(patch, layout, DIRECTION, dry_run=True))
        d = P.detail_of(r)
        dry[layout] = r
        modes[layout] = {"kind": r["kind"], "code": P.code_of(r), "text": P.text_of(r), "ghosts": d.get("ghosts"),
                         "drills": d.get("drills"), "need": d.get("need"), "chosen": d.get("chosen"),
                         "skipped": d.get("skipped"), "warnings": d.get("warnings"), "seconds": r["seconds"]}
        if r["kind"] == "job_done":
            if not (d.get("ghosts") or 0) > 0 or not d.get("need") or d.get("layout") != layout:
                reasons.append(f"{layout}: done, но ответ пустой или не того режима: {modes[layout]}")
            P.check_warnings(d, reasons)
            if d.get("area") and max(P.side(d["area"])) > 128:
                reasons.append(f"{layout}: done с областью больше 128: {d['area']}")
        elif layout in MUST:
            reasons.append(f"{layout}: обязан встать, а итог {r['kind']} {P.code_of(r)} {P.text_of(r)}")
        elif r["kind"] != "job_failed" or P.code_of(r) != "bad_args":
            reasons.append(f"{layout}: допустим только отказ bad_args, а итог {r['kind']} {P.code_of(r)} {P.text_of(r)}")
    result["modes"] = modes

    if not reasons:
        simple, sparse = P.detail_of(dry["simple"]), P.detail_of(dry["sparse"])
        if (sparse.get("drills") or 0) > (simple.get("drills") or 0):
            reasons.append(f"sparse ставит буров {sparse.get('drills')}, больше, чем simple ({simple.get('drills')})")

    if not reasons:
        dry_detail = P.detail_of(dry[REAL])
        area = dry_detail.get("area")
        area_ok = bool(area) and max(P.side(area)) <= 128
        before = P.ghosts_in(client, area) if area_ok else {}
        # жидкость снимаем с карты до разметки: призраки закрашивают клетки под собой
        cells, tile_names = P.liquid_cells(client, area) if area_ok else (set(), [])
        result["liquid_tiles"] = tile_names
        real = P.act(client, "plan_mining", P.plan_args(patch, REAL, DIRECTION))
        result["plan"] = P.brief(real)
        detail = P.detail_of(real)
        # сборные ленты compact идут поперёк — сторону ленты сверяет mining_plan (simple)
        P.verify(client, patch, before, real, result, reasons, direction=DIRECTION, belts=False)
        if real["kind"] == "job_done":
            # ревизия 3.3: буры не стоят на жидкости (на Вулканусе — на лаве), предупреждения о
            # жидкости и выходах известного вида и согласны с операцией access
            P.check_liquid_and_access(client, patch, detail, cells, result, reasons)
            if detail.get("warnings") != dry_detail.get("warnings"):
                reasons.append(f"{REAL}: предупреждения {detail.get('warnings')}, а сухой прогон обещал {dry_detail.get('warnings')}")
            if detail.get("ghosts") != dry_detail.get("ghosts"):
                reasons.append(f"{REAL}: призраков {detail.get('ghosts')}, а сухой прогон обещал {dry_detail.get('ghosts')}")
            chosen = detail.get("chosen") or {}
            extra = sorted(set(detail.get("need") or {}) - {chosen.get("miner"), chosen.get("belt"), chosen.get("pole"),
                                                           chosen.get("pipe")})
            result["extra_items"] = extra
            if not extra:
                reasons.append(f"{REAL}: в need нет подземной ленты: {detail.get('need')}")

    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result
