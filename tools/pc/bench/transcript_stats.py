"""Разбор журнала смены агента (*.jsonl субагента Claude Code): ходы модели, вызовы, ошибки, время.

Запуск (из tools/pc):  python -m bench.transcript_stats <журнал.jsonl> [--json]

Что считается:
- `model_turns` — ответы модели: строки `assistant`, сгруппированные по `message.id` (один ответ
  журнал может разбить на несколько строк по блокам содержимого); без id каждая строка — свой ответ.
- `tool_calls` — блоки `tool_use`; `by_tool` — по полному имени (`mcp__сервер__инструмент`),
  `by_short` — по короткому (последний отрезок после `__`).
- `tool_errors` — результаты (`tool_result`) с `is_error: true`; `soft_errors` — результаты без этого
  флага, чей текст — JSON с `"ok": false` (отказ самого мода/сервера, например `cannot_place`).
  `error_codes` — их `error.code`, где он есть. `unanswered` — вызовы без результата.
- `duration_s` — от первой до последней отметки времени; `active_s` — то же без пауз длиннее
  GAP_S (ожидание хозяина, сон ПК); `longest_gap_s` — самая длинная пауза.
- `tokens` — сумма `usage` по ответам модели (вход, выход, чтение/запись кэша); `models` — модели.
Битые строки пропускаются и считаются в `skipped_lines`. Файл читается построчно, целиком в память не грузится.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import datetime
from typing import Any, Dict, Iterable, List, Optional

GAP_S = 300.0
USAGE_KEYS = ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")


def _parse_time(value: Any) -> Optional[float]:
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _blocks(message: Any) -> List[Dict[str, Any]]:
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def _result_text(block: Dict[str, Any]) -> str:
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(p.get("text", "") for p in content if isinstance(p, dict) and p.get("type") == "text")
    return ""


def _soft_error(text: str) -> Optional[Dict[str, Any]]:
    """Текст результата — JSON с ok:false → {code}; иначе None."""
    text = text.strip()
    if not text.startswith("{"):
        return None
    try:
        data = json.loads(text)
    except ValueError:
        return None
    if isinstance(data, dict) and data.get("ok") is False:
        err = data.get("error")
        return {"code": err.get("code") if isinstance(err, dict) else None}
    return None


def short_name(name: str) -> str:
    return name.rsplit("__", 1)[-1] if "__" in name else name


def parse_lines(lines: Iterable[str], gap_s: float = GAP_S) -> Dict[str, Any]:
    """Разобрать строки журнала → словарь показателей (см. docstring модуля)."""
    turns: Dict[str, Dict[str, int]] = {}
    anon_turns = 0
    calls: Dict[str, str] = {}
    answered = set()
    by_tool: Counter = Counter()
    errors: Counter = Counter()
    codes: Counter = Counter()
    soft = 0
    hard = 0
    models = set()
    stamps: List[float] = []
    skipped = 0
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            row = json.loads(raw)
        except ValueError:
            skipped += 1
            continue
        if not isinstance(row, dict):
            skipped += 1
            continue
        ts = _parse_time(row.get("timestamp"))
        if ts is not None:
            stamps.append(ts)
        msg = row.get("message")
        kind = row.get("type")
        if kind == "assistant" and isinstance(msg, dict):
            mid = msg.get("id")
            usage = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
            if not (isinstance(mid, str) and mid):
                anon_turns += 1
                mid = "anon-%d" % anon_turns
            slot = turns.setdefault(mid, {})
            for key in USAGE_KEYS:
                v = usage.get(key)
                if isinstance(v, int) and not isinstance(v, bool):
                    slot[key] = max(slot.get(key, 0), v)   # строки одного ответа повторяют usage
            if isinstance(msg.get("model"), str) and msg["model"] != "<synthetic>":
                models.add(msg["model"])
            for b in _blocks(msg):
                if b.get("type") == "tool_use" and isinstance(b.get("name"), str):
                    cid = b.get("id") if isinstance(b.get("id"), str) else "call-%d" % len(calls)
                    if cid not in calls:
                        calls[cid] = b["name"]
                        by_tool[b["name"]] += 1
        elif kind == "user" and isinstance(msg, dict):
            for b in _blocks(msg):
                if b.get("type") != "tool_result":
                    continue
                cid = b.get("tool_use_id")
                answered.add(cid)
                name = calls.get(cid, "?")
                if b.get("is_error") is True:
                    hard += 1
                    errors[name] += 1
                else:
                    se = _soft_error(_result_text(b))
                    if se is not None:
                        soft += 1
                        errors[name] += 1
                        if se["code"]:
                            codes[str(se["code"])] += 1
    n_turns = len(turns)
    tokens = {k: sum(t.get(k, 0) for t in turns.values()) for k in USAGE_KEYS}
    stamps.sort()
    gaps = [b - a for a, b in zip(stamps, stamps[1:])]
    duration = (stamps[-1] - stamps[0]) if len(stamps) >= 2 else 0.0
    active = sum(g for g in gaps if g <= gap_s)
    by_short: Counter = Counter()
    for name, n in by_tool.items():
        by_short[short_name(name)] += n
    return {
        "model_turns": n_turns,
        "tool_calls": sum(by_tool.values()),
        "by_tool": dict(sorted(by_tool.items(), key=lambda kv: (-kv[1], kv[0]))),
        "by_short": dict(sorted(by_short.items(), key=lambda kv: (-kv[1], kv[0]))),
        "tool_errors": hard,
        "soft_errors": soft,
        "errors_by_tool": dict(sorted(errors.items(), key=lambda kv: (-kv[1], kv[0]))),
        "error_codes": dict(sorted(codes.items(), key=lambda kv: (-kv[1], kv[0]))),
        "unanswered": len([c for c in calls if c not in answered]),
        "duration_s": round(duration, 1),
        "active_s": round(active, 1),
        "longest_gap_s": round(max(gaps), 1) if gaps else 0.0,
        "tokens": tokens,
        "models": sorted(models),
        "skipped_lines": skipped,
    }


def parse_file(path: str, gap_s: float = GAP_S) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return parse_lines(f, gap_s)


def format_text(stats: Dict[str, Any]) -> str:
    out = [f"ходов модели: {stats['model_turns']}",
           f"вызовов инструментов: {stats['tool_calls']} (без ответа: {stats['unanswered']})",
           f"ошибок: {stats['tool_errors']} флагом + {stats['soft_errors']} отказов мода",
           f"время: {stats['duration_s'] / 60:.1f} мин всего, {stats['active_s'] / 60:.1f} мин без пауз",
           f"модели: {', '.join(stats['models']) or '-'}"]
    for name, n in list(stats["by_short"].items())[:15]:
        out.append(f"  {name}: {n}")
    return "\n".join(out)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("transcript")
    ap.add_argument("--json", action="store_true", help="вывести JSON")
    ap.add_argument("--gap", type=float, default=GAP_S, help="пауза, длиннее которой время не считается рабочим, с")
    args = ap.parse_args(argv)
    try:
        stats = parse_file(args.transcript, args.gap)
    except OSError as e:
        print("не прочитать журнал: %s" % e.strerror, file=sys.stderr)
        return 2
    print(json.dumps(stats, ensure_ascii=False, indent=2) if args.json else format_text(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
