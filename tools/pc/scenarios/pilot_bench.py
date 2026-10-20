"""Живой сценарий-замер: одно и то же поручение помощнику, которое выполняет агент (не сценарий).

Сценарий сам ничего не делает руками помощника: он готовит фиксированную задачу, ждёт, пока агент
(сменой на любой модели) её выполнит, и проверяет результат в игре. Так одно поручение прогоняют
разными моделями и сравнивают.

Поручение (TASK): достать 50 железных пластин и поставить 2 сундука рядом со стартовой точкой.
Счёт: `plates_gain` = прибавка пластин в карманах + 8 за каждый новый железный сундук (пластины,
ушедшие в крафт сундуков, не вычитаются); `chests_new` = новые сундуки (деревянный, железный,
стальной) в CHEST_RADIUS клеток от старта (по `map`, сравнение с тем, что стояло до начала).
Итог `verdict`: `done` — оба условия; `partial` — хоть что-то (пластины прибавились или стоит сундук);
`none` — ничего. `ok` — только при `done`.

Фазы (переменная окружения FP_BENCH_PHASE):
- `prepare` — `hello`, `helper_spawn`, проверка, что на видимых складах есть пластины, снимок начала
  (карманы, сундуки, тик) в файл `baseline-<помощник>.json`, готовое поручение в `task`; файл `ready`.
- `judge` — прочитать снимок и проверить результат сейчас (агент уже закончил).
- `full` (по умолчанию) — `prepare`, затем ожидание до WAIT_S секунд и `judge`. Ожидание кончается
  раньше, когда цель достигнута и помощник простаивает SETTLE_TICKS тиков, либо когда в каталоге
  замера появился файл `stop` (его кладёт тот, кто запустил агента, когда смена закончилась).
Каждый опрос пишет в выборку состояние тела (`state`: задача, idle_ticks, busy_share, tick). В ответе:
`body` (игровые минуты, последние idle_ticks/busy_share, доля опросов с задачей), `module_errors`
(рост за прогон).
Остальные переменные: FP_BENCH_ITEM (какие пластины достают, по умолчанию iron-plate), FP_BENCH_HELPER (имя помощника, по умолчанию h1), FP_BENCH_WAIT_S,
FP_BENCH_DIR (каталог снимка, по умолчанию временный).
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import time


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


H = _load("_hands")


def _env_float(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


HELPER = os.environ.get("FP_BENCH_HELPER") or "h1"
WAIT_S = _env_float("FP_BENCH_WAIT_S", 900)
POLL_S = 5.0
STOCK_WAIT_S = 60.0          # сколько ждать видимости пластин на складах хозяина
SETTLE_TICKS = 120          # столько тиков простоя после достигнутой цели — и можно завершать
FINISH_MARGIN_S = 30.0      # запас до конца времени сценария на итоговую проверку
PLATE = os.environ.get("FP_BENCH_ITEM") or "iron-plate"   # на сейве без железа — другой предмет (steel-plate)
ITEM_RU = {"iron-plate": "железных пластин", "steel-plate": "стальных пластин", "copper-plate": "медных пластин"}
PLATES_GOAL = 50
CHESTS_GOAL = 2
CHEST_NAMES = ("wooden-chest", "iron-chest", "steel-chest")
IRON_CHEST_PLATES = 8 if PLATE == "iron-plate" else 0   # только железо уходит в железный сундук
CHEST_RADIUS = 16           # `map` отдаёт не больше 32
SAMPLES_KEPT = 20

TASK = ("Поручение: достань {plates} {item_ru} (бери со складов хозяина) и поставь {chests} сундука "
        "рядом с тем местом, где ты сейчас стоишь (в пределах {radius} клеток). Сундуки — любые: готовые "
        "со склада или собранные руками. Закончишь — коротко напиши, что сделано.")


def task_text():
    return TASK.format(plates=PLATES_GOAL, chests=CHESTS_GOAL, radius=CHEST_RADIUS,
                       item_ru=ITEM_RU.get(PLATE, PLATE))


def bench_dir():
    path = os.environ.get("FP_BENCH_DIR") or os.path.join(tempfile.gettempdir(), "fp-bench")
    os.makedirs(path, exist_ok=True)
    return path


def baseline_path():
    return os.path.join(bench_dir(), "baseline-" + HELPER + ".json")


def as_list(v):
    """Пустая таблица мода приходит как {} (PROTOCOL §1)."""
    return [] if v == {} or v is None else v


def as_dict(v):
    return {} if v == [] or v is None else v


def _chest_key(e):
    pos = e.get("pos") or {}
    return "%s@%s,%s" % (e.get("name"), pos.get("x"), pos.get("y"))


def scan_chests(client, center):
    """Сундуки рядом с center по `map`: {ключ: имя}. Призраки не в счёт."""
    data = client.call_ok("map", {"center": center, "radius": CHEST_RADIUS, "names": list(CHEST_NAMES)}, HELPER)
    out = {}
    for e in as_list(as_dict(data).get("entities")):
        if e.get("name") in CHEST_NAMES and not e.get("ghost"):
            out[_chest_key(e)] = e["name"]
    return out


def snapshot(client, center=None):
    """Состояние начала/конца: позиция, пластины в карманах, сундуки рядом, тик."""
    st = client.call_ok("state", {}, HELPER)
    pos = center or st.get("pos") or {"x": 0, "y": 0}
    inv = as_dict(st.get("inv"))
    return {"pos": pos, "plates": inv.get(PLATE, 0), "chests": scan_chests(client, pos), "tick": st.get("tick")}


def evaluate(base, now):
    """Чистая функция: сравнение снимков → {verdict, plates_gain, chests_new, score, ...}."""
    new_chests = {k: n for k, n in now["chests"].items() if k not in base["chests"]}
    iron_chests = sum(1 for n in new_chests.values() if n == "iron-chest")
    plates_gain = now["plates"] - base["plates"] + IRON_CHEST_PLATES * iron_chests
    chests_new = len(new_chests)
    if plates_gain >= PLATES_GOAL and chests_new >= CHESTS_GOAL:
        verdict = "done"
    elif plates_gain > 0 or chests_new > 0:
        verdict = "partial"
    else:
        verdict = "none"
    score = round((min(max(plates_gain, 0) / PLATES_GOAL, 1) + min(chests_new / CHESTS_GOAL, 1)) / 2, 2)
    return {"verdict": verdict, "plates_gain": plates_gain, "chests_new": chests_new, "score": score,
            "plates_goal": PLATES_GOAL, "chests_goal": CHESTS_GOAL}


def _sample(st):
    return {"tick": st.get("tick"), "busy": bool(st.get("job")), "idle_ticks": st.get("idle_ticks") or 0,
            "busy_share": st.get("busy_share")}


def body_stats(samples):
    """Простой тела по выборке опросов `state`."""
    if not samples:
        return {"samples": 0}
    ticks = [s["tick"] for s in samples if isinstance(s.get("tick"), (int, float))]
    last = samples[-1]
    out = {"samples": len(samples),
           "idle_ticks_last": last["idle_ticks"],
           "idle_ticks_max": max(s["idle_ticks"] for s in samples),
           "busy_share_last": last.get("busy_share"),
           "busy_polls_share": round(sum(1 for s in samples if s["busy"]) / len(samples), 2)}
    if len(ticks) >= 2:
        out["game_minutes"] = round((ticks[-1] - ticks[0]) / 3600.0, 2)
    return out


def prepare(client, result):
    """hello, помощник, склад, снимок начала. → baseline | None (ошибка — в result)."""
    hello = client.call_ok("hello")
    result.update(mod=str(hello.get("mod", "")), helper=HELPER)
    if not H.check_mod(hello, result):
        return None
    if not H.spawn(client, result, HELPER):
        result["ok"] = False
        return None
    # индекс складов строится постепенно после появления помощника: ждём, пока пластины станут видны
    have = 0
    for radius, wait_s in ((64, STOCK_WAIT_S), (128, 20.0)):
        def look(radius=radius):
            data = client.call_ok("stock", {"radius": radius, "items": [PLATE], "limit": 50}, HELPER)
            look.n = as_dict(data.get("total")).get(PLATE, 0)
            return look.n >= PLATES_GOAL
        look.n = 0
        client.poll(look, wait_s, 2.0)
        have = max(have, look.n)
        result.setdefault("stock_scan", []).append({"radius": radius, "plates": look.n})
        if have >= PLATES_GOAL:
            break
    result["stock_plates"] = have
    base = snapshot(client)
    if have + base["plates"] < PLATES_GOAL:
        result.update(ok=False, error={"kind": "setup", "text":
                                       f"на видимых складах {have} пластин, у помощника {base['plates']}: поручение невыполнимо"})
        return None
    base["module_errors"] = hello.get("module_errors", 0)
    with open(baseline_path(), "w", encoding="utf-8") as f:
        json.dump(base, f, ensure_ascii=False)
    try:
        os.remove(os.path.join(bench_dir(), "stop"))
    except OSError:
        pass
    with open(os.path.join(bench_dir(), "ready"), "w", encoding="utf-8") as f:
        f.write(HELPER)
    result["task"] = task_text()
    result["baseline"] = {"pos": base["pos"], "plates": base["plates"], "chests": len(base["chests"]), "tick": base["tick"]}
    return base


def load_baseline(result):
    try:
        with open(baseline_path(), "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        result.update(ok=False, error={"kind": "setup", "text": "нет снимка начала (запустите фазу prepare)"})
        return None


def judge(client, base, result, samples):
    now = snapshot(client, base["pos"])
    verdict = evaluate(base, now)
    result.update(verdict)
    result["ok"] = verdict["verdict"] == "done"
    result["body"] = body_stats(samples)
    result["samples"] = samples[-SAMPLES_KEPT:]
    hello = client.call_ok("hello")
    grown = hello.get("module_errors", 0) - base.get("module_errors", 0)
    result["module_errors"] = grown
    reasons = []
    if verdict["verdict"] != "done":
        reasons.append(f"{verdict['verdict']}: пластин +{verdict['plates_gain']} из {PLATES_GOAL}, "
                       f"новых сундуков {verdict['chests_new']} из {CHESTS_GOAL}")
    if grown > 0:
        result["ok"] = False
        reasons.append(f"module_errors вырос на {grown}")
    if reasons:
        result["reasons"] = reasons
    return result


def wait_agent(client, base, samples):
    """Опрашивать тело, пока агент работает. → причина окончания."""
    end = time.monotonic() + max(0.0, min(WAIT_S, client.time_left() - FINISH_MARGIN_S))
    stop_file = os.path.join(bench_dir(), "stop")
    while time.monotonic() < end:
        st = client.call_ok("state", {}, HELPER)
        samples.append(_sample(st))
        if os.path.exists(stop_file):
            return "stop_file"
        if samples[-1]["idle_ticks"] >= SETTLE_TICKS and evaluate(base, snapshot(client, base["pos"]))["verdict"] == "done":
            return "settled"
        client.sleep(POLL_S)
    return "timeout"


def run(client) -> dict:
    result = {}
    phase = os.environ.get("FP_BENCH_PHASE") or "full"
    if phase not in ("prepare", "judge", "full"):
        result.update(ok=False, error={"kind": "setup", "text": f"FP_BENCH_PHASE: prepare, judge или full, не {phase!r}"})
        return result
    result["phase"] = phase
    samples = []
    if phase == "judge":
        hello = client.call_ok("hello")
        if not H.check_mod(hello, result):
            return result
        base = load_baseline(result)
        if base is None:
            return result
        return judge(client, base, result, samples)
    base = prepare(client, result)
    if base is None:
        return result
    if phase == "prepare":
        result["ok"] = True
        return result
    result["ended_by"] = wait_agent(client, base, samples)
    return judge(client, base, result, samples)
