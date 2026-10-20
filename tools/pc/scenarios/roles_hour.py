"""Живой сценарий-замер: три роли (голос, пилот, стратег) ведут одного помощника на стенде без игрока.

Сценарий сам ничего не делает руками помощника и не пишет пакеты: он готовит сейв-правило самостоятельного
режима, ждёт, пока роли (их запускает tools/pc/run-roles-hour.ps1) сделают дело, и меряет итог. Игрока на
стенде нет, поэтому слова хозяина («стоп», «иди сюда», «что делаешь», «продолжай»), вопросы хозяина голосу
и крупные поручения стенд честно подать не может: они в `owner_words` с пометкой «проверяется хозяином в
игре». Проверяется то, что не требует игрока: стратег (самостоятельный режим по правилу сейва) пишет
пакеты стройки, мост ставит их телу, пилот исполняет мелкое, голос молчит.

Цель (GOAL): поставить 2 сундука в CHEST_RADIUS клетках от места старта помощника. Правило сейва
`AUTO: <цель>` сценарий кладёт в `<FP_NOTES_DIR>/<FP_SAVE_NAME>/rules.md` (хозяин правит этот файл и руками,
docs/MCP.md «Пакеты стройки», раздел про самостоятельный режим в правилах стратега).
Итог `verdict`: `done` — новых сундуков не меньше цели и хотя бы один пакет `verified`; `partial` — что-то
сделано (сундук, пакет любого состояния); `none` — ничего. `ok` — только при `done` и без роста module_errors.

Метрики в ответе:
- `packages` — пакеты, появившиеся за прогон (по файлу пакетов `packages.json` сейва, его ведёт мост):
  `total`, `verified`, `unmet`, `failed`, `cancelled`, `open`, `by_status`; `first_package_min` и
  `first_verified_min` — игровые минуты от начала до первого пакета и до первого `verified`;
- `body` — занятость тела: игровые минуты, `busy_share_last`/`busy_share_mean` (доля времени с задачей по
  `state.busy_share`), `idle_ticks_*`, `busy_polls_share`;
- `module_errors` — рост за прогон; `ended_by` — `stop_file`, `settled` или `timeout`.
Ходы и вызовы каждой роли, ошибки инструментов и минуты считает обвязка по журналам смен
(`python -m bench.transcript_stats`); сценарию журналы не нужны.

Фазы (FP_BENCH_PHASE): `prepare` — hello, помощник, правило сейва, снимок начала, файл `ready`; `judge` —
итог сейчас; `full` (по умолчанию) — `prepare`, ожидание до WAIT_S секунд, `judge`. Ожидание кончается раньше:
когда цель достигнута и тело простаивает SETTLE_TICKS тиков, либо когда в каталоге замера появился файл `stop`.
Переменные: FP_NOTES_DIR (обязательна: каталог заметок прогона, не репозиторий), FP_SAVE_NAME (по умолчанию
`roles-hour`), FP_BENCH_HELPER (по умолчанию h1), FP_BENCH_WAIT_S, FP_BENCH_DIR.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3).
"""
from __future__ import annotations

import importlib.util
import json
import os
import re
import tempfile
import time


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


PB = _load("pilot_bench")      # общие вещи замера: разбор карты, простой тела
H = PB.H


def _env_float(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return float(default)


HELPER = os.environ.get("FP_BENCH_HELPER") or "h1"
WAIT_S = _env_float("FP_BENCH_WAIT_S", 3600)
POLL_S = 5.0
SETTLE_TICKS = 600          # простой после достигнутой цели — и можно завершать
FINISH_MARGIN_S = 30.0
CHESTS_GOAL = 2
CHEST_RADIUS = PB.CHEST_RADIUS
SAVE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
GOAL = "поставить %d сундука в %d клетках от места старта помощника" % (CHESTS_GOAL, CHEST_RADIUS)
RULE = "AUTO: " + GOAL
SAMPLES_KEPT = 20
CLOSED = ("verified", "unmet", "failed", "cancelled")
STATUSES = ("queued", "posting", "running", "pausing", "paused", "verifying") + CLOSED

# То, что в этом сценарии подать нельзя: игрока нет.
OWNER_WORDS = {
    "status": "проверяется хозяином в игре",
    "items": [
        "слова «стоп», «иди сюда», «что делаешь», «продолжай» (мод принимает их только от хозяина)",
        "10 вопросов голосу и время его ответа",
        "3 поручения хозяина (мелкое и крупное: пауза пакета owner_order и возврат)",
        "правило сейва, записанное с подтверждением «да» в чате",
    ],
}


def bench_dir():
    path = os.environ.get("FP_BENCH_DIR") or os.path.join(tempfile.gettempdir(), "fp-bench")
    os.makedirs(path, exist_ok=True)
    return path


def baseline_path():
    return os.path.join(bench_dir(), "baseline-roles-" + HELPER + ".json")


def save_name():
    name = os.environ.get("FP_SAVE_NAME") or "roles-hour"
    return name if SAVE_NAME_RE.match(name) else None


def notes_dir():
    """Папка заметок прогона. Обязательна: иначе правило легло бы в save-notes репозитория."""
    path = os.environ.get("FP_NOTES_DIR")
    return path if path else None


def save_dir():
    base, save = notes_dir(), save_name()
    return os.path.join(base, save) if base and save else None


def rules_text(save):
    return "# Правила хозяина для помощника (%s)\n\n1. %s\n" % (save, RULE)


def write_rule(result):
    """Правило самостоятельного режима в заметки сейва. → bool (ошибка — в result)."""
    if not notes_dir():
        result.update(ok=False, error={"kind": "setup", "text": "нет FP_NOTES_DIR: каталог заметок прогона обязателен"})
        return False
    if not save_name():
        result.update(ok=False, error={"kind": "setup", "text": "FP_SAVE_NAME: латиница, цифры, . _ -, до 64 знаков"})
        return False
    path = os.path.join(save_dir(), "rules.md")
    try:
        os.makedirs(save_dir(), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(rules_text(save_name()))
    except OSError as e:
        result.update(ok=False, error={"kind": "setup", "text": "не записать правило сейва: %s" % (e.strerror or e)})
        return False
    result["rule"] = RULE
    return True


def read_ledger():
    """Файл пакетов сейва → (открытые+законченные пакеты, ошибка|None). Нет файла — пакетов нет."""
    base = save_dir()
    if not base:
        return [], "нет каталога заметок"
    path = os.path.join(base, "packages.json")
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
    except FileNotFoundError:
        return [], None
    except (OSError, ValueError) as e:
        return [], "не прочитать packages.json: %s" % (getattr(e, "strerror", None) or e)
    if not isinstance(data, dict):
        return [], "packages.json: не объект"
    out = []
    for key in ("packages", "history"):
        for p in data.get(key) or []:
            if isinstance(p, dict) and isinstance(p.get("id"), str):
                out.append(p)
    return out, None


def package_counts(pkgs, known=()):
    """Чистая функция: пакеты (без тех, чей id в known) → счётчики по состояниям."""
    by = {}
    seen = set()
    for p in pkgs:
        pid = p.get("id")
        if pid in known or pid in seen:
            continue
        seen.add(pid)
        st = p.get("status") if p.get("status") in STATUSES else "other"
        by[st] = by.get(st, 0) + 1
    closed = sum(by.get(s, 0) for s in CLOSED)
    return {"total": len(seen), "verified": by.get("verified", 0), "unmet": by.get("unmet", 0),
            "failed": by.get("failed", 0), "cancelled": by.get("cancelled", 0),
            "open": len(seen) - closed, "by_status": dict(sorted(by.items()))}


def snapshot(client, center=None):
    st = client.call_ok("state", {}, HELPER)
    pos = center or st.get("pos") or {"x": 0, "y": 0}
    return {"pos": pos, "chests": PB.scan_chests(client, pos), "tick": st.get("tick")}


def evaluate(base, chests_now, counts):
    """Чистая функция: сундуки и пакеты → {verdict, chests_new, score, ...}."""
    chests_new = sum(1 for k in chests_now if k not in base["chests"])
    if chests_new >= CHESTS_GOAL and counts["verified"] >= 1:
        verdict = "done"
    elif chests_new > 0 or counts["total"] > 0:
        verdict = "partial"
    else:
        verdict = "none"
    score = round((min(chests_new / CHESTS_GOAL, 1) + (1 if counts["verified"] >= 1 else 0)) / 2, 2)
    return {"verdict": verdict, "chests_new": chests_new, "chests_goal": CHESTS_GOAL, "score": score}


def _minutes(tick, start):
    if isinstance(tick, (int, float)) and isinstance(start, (int, float)):
        return round((tick - start) / 3600.0, 2)
    return None


def _sample(st, counts):
    return {"tick": st.get("tick"), "busy": bool(st.get("job")), "idle_ticks": st.get("idle_ticks") or 0,
            "busy_share": st.get("busy_share"), "packages": counts["total"], "verified": counts["verified"]}


def body_stats(samples):
    """Занятость тела: общая выборка pilot_bench плюс среднее busy_share."""
    out = PB.body_stats(samples)
    shares = [s["busy_share"] for s in samples if isinstance(s.get("busy_share"), (int, float))]
    if shares:
        out["busy_share_mean"] = round(sum(shares) / len(shares), 2)
    return out


def timeline(samples, start):
    """Игровые минуты первого пакета и первого verified по выборке."""
    out = {"first_package_min": None, "first_verified_min": None}
    for s in samples:
        if out["first_package_min"] is None and s.get("packages", 0) > 0:
            out["first_package_min"] = _minutes(s.get("tick"), start)
        if out["first_verified_min"] is None and s.get("verified", 0) > 0:
            out["first_verified_min"] = _minutes(s.get("tick"), start)
    return out


def prepare(client, result):
    """hello, помощник, правило сейва, снимок начала. → baseline | None (ошибка — в result)."""
    hello = client.call_ok("hello")
    result.update(mod=str(hello.get("mod", "")), helper=HELPER, save=save_name())
    if not H.check_mod(hello, result):
        return None
    if not write_rule(result):
        return None
    if not H.spawn(client, result, HELPER):
        result["ok"] = False
        return None
    base = snapshot(client)
    pkgs, err = read_ledger()
    if err:
        result.update(ok=False, error={"kind": "setup", "text": err})
        return None
    base["packages_known"] = sorted(p["id"] for p in pkgs)
    base["module_errors"] = hello.get("module_errors", 0)
    with open(baseline_path(), "w", encoding="utf-8") as f:
        json.dump(base, f, ensure_ascii=False)
    try:
        os.remove(os.path.join(bench_dir(), "stop"))
    except OSError:
        pass
    with open(os.path.join(bench_dir(), "ready"), "w", encoding="utf-8") as f:
        f.write(HELPER)
    result["goal"] = GOAL
    result["baseline"] = {"pos": base["pos"], "chests": len(base["chests"]), "tick": base["tick"],
                          "packages_known": len(base["packages_known"])}
    return base


def load_baseline(result):
    try:
        with open(baseline_path(), "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        result.update(ok=False, error={"kind": "setup", "text": "нет снимка начала (запустите фазу prepare)"})
        return None


def current_counts(base):
    pkgs, err = read_ledger()
    return package_counts(pkgs, set(base.get("packages_known") or [])), err


def judge(client, base, result, samples):
    now = snapshot(client, base["pos"])
    counts, ledger_err = current_counts(base)
    verdict = evaluate(base, now["chests"], counts)
    result.update(verdict)
    result["ok"] = verdict["verdict"] == "done"
    result["packages"] = dict(counts, **timeline(samples, base.get("tick")))
    result["body"] = body_stats(samples)
    result["samples"] = samples[-SAMPLES_KEPT:]
    result["owner_words"] = OWNER_WORDS
    hello = client.call_ok("hello")
    grown = hello.get("module_errors", 0) - base.get("module_errors", 0)
    result["module_errors"] = grown
    reasons = []
    if verdict["verdict"] != "done":
        reasons.append("%s: новых сундуков %d из %d, пакетов verified %d из %d записанных"
                       % (verdict["verdict"], verdict["chests_new"], CHESTS_GOAL, counts["verified"], counts["total"]))
    if ledger_err:
        result["ok"] = False
        reasons.append(ledger_err)
    if grown > 0:
        result["ok"] = False
        reasons.append("module_errors вырос на %d" % grown)
    if reasons:
        result["reasons"] = reasons
    return result


def wait_roles(client, base, samples):
    """Опрашивать тело и файл пакетов, пока роли работают. → причина окончания."""
    end = time.monotonic() + max(0.0, min(WAIT_S, client.time_left() - FINISH_MARGIN_S))
    stop_file = os.path.join(bench_dir(), "stop")
    while time.monotonic() < end:
        st = client.call_ok("state", {}, HELPER)
        counts, _ = current_counts(base)
        samples.append(_sample(st, counts))
        if os.path.exists(stop_file):
            return "stop_file"
        if (samples[-1]["idle_ticks"] >= SETTLE_TICKS and counts["verified"] >= 1
                and evaluate(base, snapshot(client, base["pos"])["chests"], counts)["verdict"] == "done"):
            return "settled"
        client.sleep(POLL_S)
    return "timeout"


def run(client) -> dict:
    result = {}
    phase = os.environ.get("FP_BENCH_PHASE") or "full"
    if phase not in ("prepare", "judge", "full"):
        result.update(ok=False, error={"kind": "setup", "text": "FP_BENCH_PHASE: prepare, judge или full, не %r" % phase})
        return result
    result["phase"] = phase
    samples = []
    if phase == "judge":
        hello = client.call_ok("hello")
        if not H.check_mod(hello, result):
            return result
        if not save_name() or not notes_dir():
            result.update(ok=False, error={"kind": "setup", "text": "нужны FP_NOTES_DIR и FP_SAVE_NAME прогона"})
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
    result["ended_by"] = wait_roles(client, base, samples)
    return judge(client, base, result, samples)
