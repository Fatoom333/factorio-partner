"""Сквозной сценарий «поставь добычу», путь «чертёж из forge» (TESTING.md §4, docs/E2E.md).

Идёт через настоящий пакет сервера (`RUNNER = "server"`) и НАСТОЯЩИЙ forge на машине, где запущен
стенд: `partner_plan` (MCP.md) зовёт CLI forge из его же `.venv`, сервер хранит строку чертежа и сам
грузит её в мод частями (`blob_put`), когда агент просит `build_blueprint {plan}`.

1. admin hello / spawn. Лента и столб выбираются по складам базы (`partner_find`).
2. Руда: `partner_resources` по именам руд; на карте пятна ищется свободное окно 9×4 — ровно одна
   пара буров с лентой и столбами (раскладку считает сервер, forge проверяет её по данным профиля,
   соединяет столбы и кодирует чертёж). Окно — только на руде, которую берёт электрический бур:
   призрак бура на голой земле движок не ставит (`cannot_place`, замер 2.0.77).
3. `partner_plan {task: "mining", resource: {name, area}, options}` → `{plan, anchor, direction,
   items, size, summary}`. Если forge не может (`supported: false`) — причина записывается дословно,
   сценарий не проходит: это и есть результат проверки, forge сценарий не чинит и профили не трогает.
   Старый forge без нужных команд даёт причину `forge_too_old` — и у `partner_plan`, и у
   `partner_brief` (пустые заметки), без сырого вывода forge: сценарий сверяет и это.
4. `partner_act build_blueprint {plan, anchor, direction, dry_run}` — привязка чертежа к месту:
   призраков столько же, сколько предметов в `items`, без пропусков.
5. Предметы честно (`collect` со складов, поход к складам, сырьё и `craft`) — ровно `items`.
6. `partner_act build_blueprint {plan, anchor, direction, mode: "hand"}`.
7. Сверка: призраков 0; на карте 2 бура, лента и столбы лежат внутри того окна, которое просили
   покрыть (так проверяется привязка `anchor` чертежа forge к месту); убыло ровно `items`; строка
   чертежа агенту не показывалась.
Только `/partner <JSON>`; никаких /c, /sc, /silent-command.
"""
from __future__ import annotations

import importlib.util
import os

MODS = ["factorio-partner"]
RUNNER = "server"
HELPER = "e2e"
MINER = "electric-mining-drill"
WINDOW = (9, 4)                    # одна пара буров 3×3: столб | бур | лента | бур | столб, ряд перемычек
FLOW = "north"
MIN_ORE = 24                       # руды в окне 9×4 — чтобы под обоими бурами она была наверняка
# руды, которые берёт электрический бур без жидкости (вольфрам и уран раскладка forge.py отдаёт
# другим бурам или не берёт вовсе — это был бы отказ не про forge, а про выбор руды)
ORES = ("iron-ore", "copper-ore", "coal", "stone", "calcite", "scrap")
MAX_PLANS = 3
BUILD_TIMEOUT_S = 420.0
PLAN_KEYS = {"plan", "anchor", "direction", "items", "size", "summary"}
FORGE_TOO_OLD = "forge_too_old"    # MCP.md: старый forge без нужных команд — у partner_plan и partner_brief


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


E = _load("_e2e")


def candidate_windows(api, log):
    """Свободные окна 9×4 на руде, ближние пятна первыми. Только на руде: призрак бура на голой земле
    движок не ставит (`cannot_place`, замер 2.0.77)."""
    out = []
    for win in E.ore_candidates(api, log, WINDOW[0], WINDOW[1], min_ore=MIN_ORE, names=ORES):
        out.append({"name": win["patch"]["name"], "area": win["area"], "ore": win["ore"]})
        if len(out) >= MAX_PLANS:
            break
    return out


def check_plan(plan):
    """Форма ответа `partner_plan` (MCP.md). → список замечаний."""
    bad = []
    if set(plan) != PLAN_KEYS:
        bad.append(f"поля ответа {sorted(plan)}, по контракту {sorted(PLAN_KEYS)}")
        return bad
    if not (isinstance(plan["plan"], str) and plan["plan"].startswith("p-")):
        bad.append(f"plan: {plan['plan']!r}")
    if plan["direction"] != 0:
        bad.append(f"direction = {plan['direction']} (чертёж уже повёрнут, должно быть 0)")
    if plan["size"] != {"w": WINDOW[0], "h": WINDOW[1]}:
        bad.append(f"size = {plan['size']}, ждали {WINDOW[0]}×{WINDOW[1]}")
    if E.as_map(plan["items"]).get(MINER) != 2:
        bad.append(f"items = {plan['items']}: ждали 2 бура")
    if any(isinstance(v, str) and len(v) > 400 and v.startswith("0e") for v in plan.values()):
        bad.append("в ответе похоже на строку чертежа")
    return bad


def verify(api, plan, window, before, result, reasons):
    """Сверка с игрой. Главное — привязка: forge просили покрыть окно `window`, значит, всё построенное
    обязано лежать внутри него (а не просто «вокруг anchor» — туда чертёж ставит сам мод)."""
    items = E.as_map(plan["items"])
    center = E.area_center(window)
    w, h = E.area_side(window)
    left = api.read("ghosts", {"area": E.area_around(center, w / 2 + 3, h / 2 + 3)})
    result["ghosts_left"] = left.get("count")
    if left.get("count") != 0:
        reasons.append(f"в области осталось призраков: {left.get('count')}")
    built, _, _ = E.on_map(api, list(items), center, max(w, h) / 2 + 4)
    lt, rb = window["left_top"], window["right_bottom"]
    inside, outside = [], []
    for e in built:
        (inside if lt["x"] <= e["pos"]["x"] <= rb["x"] and lt["y"] <= e["pos"]["y"] <= rb["y"] else outside).append(e)
    counts = {}
    for e in inside:
        counts[e["name"]] = counts.get(e["name"], 0) + 1
    result["on_map"] = {"inside_window": counts, "outside_window": len(outside),
                        "drills": [{"pos": e["pos"], "dir": e.get("dir")} for e in inside if e["name"] == MINER]}
    if counts != items:
        reasons.append(f"внутри окна на карте {counts}, а в плане {items} — чертёж встал не туда (привязка anchor)")
    dirs = sorted(e.get("dir") for e in inside if e["name"] == MINER)
    if dirs and dirs != [4, 12]:
        reasons.append(f"буры смотрят в {dirs}, а должны на ленту между ними (4 и 12)")
    after = E.inventory(api)
    spent = {k: before.get(k, 0) - after.get(k, 0) for k in items}
    result["inventory"] = {"items": items, "spent": spent}
    if spent != items:
        reasons.append(f"у помощника убыло {spent}, а в плане {items}")


def run(client) -> dict:
    result = {"scenario": "e2e_forge"}
    if not callable(getattr(client, "tool", None)):
        return E.fail_setup(result, "сценарию нужен настоящий пакет сервера (RUNNER = \"server\", server_client.py)")
    api = E.McpApi(client)
    result["forge_setup"] = getattr(client, "forge", None)
    if not E.start(api, result):
        return result
    log = []
    result["steps"] = log
    belt = E.pick_available(api, E.BELTS, log, "belt")
    pole = E.pick_available(api, E.POLES, log, "pole")
    if belt is None or pole is None:
        return E.fail_setup(result, "на складах базы нет ленты или столба и скрафтить нечем")
    options = {"drill": MINER, "belt": belt, "pole": pole, "direction": FLOW}
    result["options"] = options

    windows = candidate_windows(api, log)
    if not windows:
        return E.fail_setup(result, "в 400 клетках от помощника нет свободного окна 9×4 на руде, которую "
                                    f"берёт {MINER} (искали: {', '.join(ORES)})")
    plans = []
    result["plans"] = plans
    plan = win = None
    for cand in windows[:MAX_PLANS]:
        r = client.try_tool("plan", task="mining", resource={"name": cand["name"], "area": cand["area"]},
                            options=options)
        entry = {"window": cand["area"], "resource": cand["name"], "ore": cand["ore"], "ok": r["ok"]}
        plans.append(entry)
        if not r["ok"]:
            entry["error"] = r["error"]
            return E.finish(result, [f"partner_plan отказал: {r['error']}"])
        answer = r["data"]
        if answer.get("supported") is False:
            # forge не может: это итог проверки, а не сбой стенда. Причина — дословно, как её увидит агент.
            entry.update(supported=False, reason=answer.get("reason"))
            too_old = answer.get("reason") == FORGE_TOO_OLD
            result.update(ok=False, outcome="forge_unsupported",
                          forge={"supported": False, "reason": answer.get("reason"), "too_old": too_old},
                          reasons=["partner_plan: forge не дал чертёж — " + str(answer.get("reason"))],
                          next_step=("forge на этой машине старый (нет нужных команд): хозяину — обновить forge и "
                                     "активировать профиль сейва; агент тем временем размечает сам (plan_mining, "
                                     "сценарий e2e_mining)") if too_old else
                                    ("по MCP.md агент просит хозяина поставить призраки и строит build_ghosts "
                                     "(этот путь проверяет сценарий e2e_ghosts)"))
            # заметки профиля при старом forge: пустые, с тем же кодом, без сырого вывода forge
            b = client.try_tool("brief")
            if b["ok"]:
                missing = str(b["data"].get("notes_missing") or "")
                result["brief"] = {"notes": b["data"].get("notes") is not None, "reason": b["data"].get("reason"),
                                   "raw_forge_output": "usage:" in missing.lower() or "invalid choice" in missing.lower()}
                if result["brief"]["raw_forge_output"]:
                    result["reasons"].append("partner_brief отдал агенту сырой вывод forge (usage)")
                if too_old and b["data"].get("reason") != FORGE_TOO_OLD:
                    result["reasons"].append(f"partner_plan сказал forge_too_old, а partner_brief — "
                                             f"{b['data'].get('reason')!r}")
            return result
        notes = check_plan(answer)
        if not notes and answer["anchor"] != E.area_center(cand["area"]):
            notes.append(f"anchor = {answer['anchor']}, а центр окна раскладки — {E.area_center(cand['area'])}")
        entry.update(supported=True, anchor=answer.get("anchor"), size=answer.get("size"), items=answer.get("items"),
                     summary=answer.get("summary"), shape=notes or "ok")
        if notes:
            return E.finish(result, ["ответ partner_plan не по контракту: " + "; ".join(notes)])
        total = sum(E.as_map(answer["items"]).values())
        dry = api.act("build_blueprint", {"plan": answer["plan"], "anchor": answer["anchor"],
                                           "direction": answer["direction"], "dry_run": True})
        d = E.detail_of(dry)
        entry["dry_run"] = {"kind": dry["kind"], "code": E.code_of(dry), "text": E.text_of(dry), "ghosts": d.get("ghosts"),
                            "skipped": d.get("skipped"), "skipped_total": d.get("skipped_total"),
                            "to_remove_total": d.get("to_remove_total"), "tiles": d.get("tiles")}
        if dry["kind"] == "job_done" and d.get("ghosts") == total and not d.get("skipped_total") \
                and not d.get("to_remove_total") and not E.as_map(d.get("tiles")):
            plan, win = answer, cand
            break
        if dry["kind"] not in ("job_done", "job_failed"):
            return E.finish(result, [f"dry_run чертежа из плана не завершился: {entry['dry_run']}"])
    if plan is None:
        return E.finish(result, ["dry_run: чертёж из partner_plan не встал целиком ни в одном окне "
                                 "(привязка anchor или помехи) — см. plans"])
    result.update(outcome="planned", forge={"supported": True}, resource=win["name"],
                  plan={k: plan[k] for k in ("anchor", "direction", "items", "size", "summary")})
    reasons = []

    items = E.as_map(plan["items"])
    missing, notes = E.obtain(api, items, log)
    if missing:
        result["missing"] = missing
        result["missing_detail"] = notes
        reasons.append(f"не удалось честно добыть предметы: {missing}")
        return E.finish(result, reasons)
    before = E.inventory(api)

    r = api.act("build_blueprint", {"plan": plan["plan"], "anchor": plan["anchor"], "direction": plan["direction"],
                                    "mode": "hand"}, BUILD_TIMEOUT_S)
    result["build"] = E.brief(r)
    d = E.detail_of(r)
    total = sum(items.values())
    if r["kind"] != "job_done":
        reasons.append(f"build_blueprint не done: {E.code_of(r)} {E.text_of(r)}")
    elif d.get("built") != total or d.get("left"):
        reasons.append(f"построено {d.get('built')} из {total}, осталось {d.get('left')}")
    verify(api, plan, win["area"], before, result, reasons)
    result["server_calls"] = getattr(client, "calls", None)
    return E.finish(result, reasons)
