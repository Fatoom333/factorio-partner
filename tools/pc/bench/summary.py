"""Сводка по прогонам сравнения пилотов: доведено ли, вызовы, минуты, ошибки, расход лимита, простой тела.

Запуск (из tools/pc):  python -m bench.summary manifest.json [--format md|json] [--out файл]

Манифест — JSON: список прогонов или `{"runs": [...]}`; прогон:
    {"label": "sonnet-1",              # имя строки в таблице
     "model": "sonnet",                # по какой модели группировать (иначе — модель из журнала)
     "transcript": "agent-a1.jsonl",   # журнал смены (путь от каталога манифеста)
     "until": "2026-10-20T10:15:00Z", # не считать строки журнала позже этого времени (стенд остановили)
     "result": "results-1.json",       # результат сценария pilot_bench (фаза judge или full)
     "usage_before": 12.0,             # get_usage до прогона: число (5-часовое окно, %) или
     "usage_after": 19.5}              # словарь {"five_hour": 12, "weekly": 30}
Расход лимита = after − before по каждому ключу; число считается ключом `five_hour`. Если значение
упало (окно сбросилось посреди прогона), расход помечается `reset` и в среднее не входит.
Любое из полей можно опустить — в таблице будет прочерк. Нечитаемый файл не роняет сводку: у прогона
появится `error`.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict, List, Optional

try:
    from . import transcript_stats
except ImportError:   # запуск файлом, а не пакетом
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from bench import transcript_stats  # type: ignore

VERDICT_RU = {"done": "доведено", "partial": "частично", "none": "нет"}
MEAN_FIELDS = ("score", "tool_calls", "model_turns", "active_min", "game_min", "errors", "usage_five_hour",
               "busy_share", "idle_ticks", "busy_polls_share")


def _num(v: Any) -> Optional[float]:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _usage_map(v: Any) -> Optional[Dict[str, float]]:
    if isinstance(v, dict):
        out = {str(k): float(x) for k, x in v.items() if _num(x) is not None}
        return out or None
    n = _num(v)
    return {"five_hour": n} if n is not None else None


def usage_spent(before: Any, after: Any) -> Dict[str, Any]:
    """{ключ: расход} по общим ключам; упавшее значение → {"reset": True} для этого ключа."""
    b, a = _usage_map(before), _usage_map(after)
    if b is None or a is None:
        return {}
    out: Dict[str, Any] = {}
    for key in sorted(set(b) & set(a)):
        d = round(a[key] - b[key], 2)
        out[key] = d if d >= 0 else {"reset": True}
    return out


def _read_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def summarize_run(spec: Dict[str, Any], base_dir: str = ".") -> Dict[str, Any]:
    """Один прогон → плоская строка показателей."""
    row: Dict[str, Any] = {"label": spec.get("label") or "?", "model": spec.get("model")}
    errors: List[str] = []
    if spec.get("transcript"):
        try:
            st = transcript_stats.parse_file(os.path.join(base_dir, spec["transcript"]),
                                             until=transcript_stats.parse_time(spec.get("until")))
            row.update(tool_calls=st["tool_calls"], model_turns=st["model_turns"],
                       active_min=round(st["active_s"] / 60.0, 1), wall_min=round(st["duration_s"] / 60.0, 1),
                       errors=st["tool_errors"] + st["soft_errors"], tool_errors=st["tool_errors"],
                       soft_errors=st["soft_errors"], by_short=st["by_short"], error_codes=st["error_codes"])
            if not row["model"] and st["models"]:
                row["model"] = st["models"][0]
        except (OSError, ValueError) as e:
            errors.append("журнал: %s" % (getattr(e, "strerror", None) or e))
    if spec.get("result"):
        try:
            res = _read_json(os.path.join(base_dir, spec["result"]))
            body = res.get("body") or {}
            row.update(verdict=res.get("verdict") or ("done" if res.get("ok") else None), score=res.get("score"),
                       plates_gain=res.get("plates_gain"), chests_new=res.get("chests_new"),
                       game_min=body.get("game_minutes"), busy_share=body.get("busy_share_last"),
                       idle_ticks=body.get("idle_ticks_last"), busy_polls_share=body.get("busy_polls_share"),
                       module_errors=res.get("module_errors"))
            if not row.get("verdict"):
                errors.append("результат без verdict (%s)" % ((res.get("error") or {}).get("text") or "нет причины"))
        except (OSError, ValueError, AttributeError) as e:
            errors.append("результат: %s" % (getattr(e, "strerror", None) or e))
    spent = usage_spent(spec.get("usage_before"), spec.get("usage_after"))
    if spent:
        row["usage"] = spent
        five = spent.get("five_hour")
        row["usage_five_hour"] = five if _num(five) is not None else None
    if errors:
        row["error"] = "; ".join(errors)
    return row


def _mean(values: List[Any]) -> Optional[float]:
    nums = [float(v) for v in values if _num(v) is not None]
    return round(sum(nums) / len(nums), 2) if nums else None


def aggregate(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """По модели: прогонов, доведено, частично, средние показатели."""
    groups: Dict[str, List[Dict[str, Any]]] = {}
    for r in rows:
        groups.setdefault(r.get("model") or "?", []).append(r)
    out = []
    for model, items in groups.items():
        agg = {"model": model, "runs": len(items),
               "done": sum(1 for r in items if r.get("verdict") == "done"),
               "partial": sum(1 for r in items if r.get("verdict") == "partial"),
               "none": sum(1 for r in items if r.get("verdict") == "none")}
        for f in MEAN_FIELDS:
            agg[f] = _mean([r.get(f) for r in items])
        out.append(agg)
    return sorted(out, key=lambda a: a["model"])


def summarize(manifest: Any, base_dir: str = ".") -> Dict[str, Any]:
    runs = manifest.get("runs") if isinstance(manifest, dict) else manifest
    if not isinstance(runs, list):
        raise ValueError("манифест: ждали список прогонов или {\"runs\": [...]}")
    rows = [summarize_run(r, base_dir) for r in runs if isinstance(r, dict)]
    return {"runs": rows, "by_model": aggregate(rows)}


def _cell(v: Any, fmt: str = "{}") -> str:
    if v is None:
        return "-"
    if isinstance(v, dict):
        return "сброс окна" if v.get("reset") else "-"
    return fmt.format(v)


def render_md(summary: Dict[str, Any]) -> str:
    lines = ["## Прогоны", "",
             "| Прогон | Модель | Итог | Счёт | Вызовов | Ходов | Мин (работа) | Ошибок | Лимит 5ч, п.п. | Простой: доля занятости | idle_ticks |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in summary["runs"]:
        usage = (r.get("usage") or {}).get("five_hour")
        lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["label"], _cell(r.get("model")), VERDICT_RU.get(r.get("verdict"), "-"), _cell(r.get("score")),
            _cell(r.get("tool_calls")), _cell(r.get("model_turns")), _cell(r.get("active_min")),
            _cell(r.get("errors")), _cell(usage), _cell(r.get("busy_share")), _cell(r.get("idle_ticks"))))
    problems = [r for r in summary["runs"] if r.get("error")]
    if problems:
        lines += ["", "Проблемы с данными:"] + ["- %s: %s" % (r["label"], r["error"]) for r in problems]
    lines += ["", "## По моделям (средние)", "",
              "| Модель | Прогонов | Доведено | Частично | Нет | Счёт | Вызовов | Ходов | Мин | Ошибок | Лимит 5ч, п.п. | Занятость |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for a in summary["by_model"]:
        lines.append("| %s | %d | %d | %d | %d | %s | %s | %s | %s | %s | %s | %s |" % (
            a["model"], a["runs"], a["done"], a["partial"], a["none"], _cell(a["score"]), _cell(a["tool_calls"]),
            _cell(a["model_turns"]), _cell(a["active_min"]), _cell(a["errors"]), _cell(a["usage_five_hour"]),
            _cell(a["busy_share"])))
    return "\n".join(lines) + "\n"


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("manifest")
    ap.add_argument("--format", choices=("md", "json"), default="md")
    ap.add_argument("--out", help="записать в файл вместо вывода")
    args = ap.parse_args(argv)
    try:
        summary = summarize(_read_json(args.manifest), os.path.dirname(os.path.abspath(args.manifest)))
    except (OSError, ValueError) as e:
        print("манифест: %s" % (getattr(e, "strerror", None) or e), file=sys.stderr)
        return 2
    text = json.dumps(summary, ensure_ascii=False, indent=2) + "\n" if args.format == "json" else render_md(summary)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        sys.stdout.buffer.write(text.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
