"""Разбор журнала смены и сводка по прогонам (bench/): на журнале-заглушке в формате Claude Code."""
from __future__ import annotations

import json
import os

from conftest import PC_DIR
from bench import summary, transcript_stats

assert os.path.isdir(os.path.join(PC_DIR, "bench"))


def a(ts, mid, blocks, model="claude-sonnet-x", usage=None):
    return {"type": "assistant", "timestamp": ts,
            "message": {"id": mid, "role": "assistant", "model": model, "content": blocks,
                        "usage": usage or {"input_tokens": 10, "output_tokens": 5,
                                           "cache_read_input_tokens": 100, "cache_creation_input_tokens": 0}}}


def u(ts, results):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": results}}


def use(cid, name, **inp):
    return {"type": "tool_use", "id": cid, "name": name, "input": inp}


def res(cid, text, is_error=False):
    return {"type": "tool_result", "tool_use_id": cid, "content": text, **({"is_error": True} if is_error else {})}


def stub_lines():
    return [
        json.dumps({"type": "queue-operation", "timestamp": "2026-10-19T10:00:00Z"}),
        json.dumps(a("2026-10-19T10:00:01Z", "m1", [{"type": "text", "text": "начинаю"}])),
        # один ответ разбит на две строки с одним id и одинаковым usage — это один ход
        json.dumps(a("2026-10-19T10:00:02Z", "m2", [use("c1", "mcp__factorio-partner__get_items", items={"iron-plate": 50})])),
        json.dumps(a("2026-10-19T10:00:02Z", "m2", [use("c2", "mcp__factorio-partner__state")])),
        json.dumps(u("2026-10-19T10:00:30Z", [res("c1", '{"ok":true,"data":{"job":1}}'), res("c2", '{"ok":true}')])),
        json.dumps(a("2026-10-19T10:00:31Z", "m3", [use("c3", "mcp__factorio-partner__act", do="place")])),
        json.dumps(u("2026-10-19T10:00:40Z", [res("c3", '{"ok":false,"error":{"code":"cannot_place","text":"занято"}}')])),
        json.dumps(a("2026-10-19T10:00:41Z", "m4", [use("c4", "Bash", command="ls")])),
        json.dumps(u("2026-10-19T10:00:42Z", [res("c4", "нет доступа", is_error=True)])),
        "это не json",
        # долгая пауза (ожидание) — в рабочее время не входит
        json.dumps(a("2026-10-19T10:30:42Z", "m5", [use("c5", "mcp__factorio-partner__state")])),
        json.dumps(a("2026-10-19T10:30:50Z", "m6", [{"type": "text", "text": "готово"}], model="<synthetic>")),
    ]


def test_parse_stub_transcript():
    st = transcript_stats.parse_lines(stub_lines())
    assert st["model_turns"] == 6                     # m1..m6, m2 — один раз
    assert st["tool_calls"] == 5 and st["unanswered"] == 1
    assert st["by_tool"]["mcp__factorio-partner__state"] == 2
    assert st["by_short"] == {"state": 2, "act": 1, "get_items": 1, "Bash": 1}
    assert st["tool_errors"] == 1 and st["soft_errors"] == 1
    assert st["error_codes"] == {"cannot_place": 1}
    assert st["errors_by_tool"]["Bash"] == 1 and st["errors_by_tool"]["mcp__factorio-partner__act"] == 1
    assert st["skipped_lines"] == 1
    assert st["duration_s"] == 1850.0
    assert st["longest_gap_s"] == 1800.0
    assert st["active_s"] == 50.0
    assert st["models"] == ["claude-sonnet-x"]
    assert st["tokens"]["output_tokens"] == 30        # 6 ходов по 5, повтор строки m2 не удваивает


def test_empty_and_garbage():
    st = transcript_stats.parse_lines(["", "[1]", "{"])
    assert st["model_turns"] == 0 and st["tool_calls"] == 0 and st["duration_s"] == 0.0 and st["skipped_lines"] == 2


def test_cli_text_and_json(tmp_path, capsys):
    p = tmp_path / "agent-a1.jsonl"
    p.write_text("\n".join(stub_lines()), encoding="utf-8")
    assert transcript_stats.main([str(p), "--json"]) == 0
    assert json.loads(capsys.readouterr().out)["tool_calls"] == 5
    assert transcript_stats.main([str(p)]) == 0
    assert "ходов модели: 6" in capsys.readouterr().out
    assert transcript_stats.main([str(tmp_path / "нет.jsonl")]) == 2


def write_run(tmp, name, model, verdict, calls, usage, ok_files=True):
    lines = [json.dumps(a("2026-10-19T10:00:00Z", "x%d" % i, [use("k%d" % i, "mcp__s__state")], model=model))
             for i in range(calls)]
    lines.append(json.dumps(a("2026-10-19T10:05:00Z", "last", [{"type": "text", "text": "."}], model=model)))
    (tmp / (name + ".jsonl")).write_text("\n".join(lines), encoding="utf-8")
    (tmp / (name + ".json")).write_text(json.dumps({
        "ok": verdict == "done", "verdict": verdict, "score": {"done": 1.0, "partial": 0.5, "none": 0.0}[verdict],
        "plates_gain": 50, "chests_new": 2 if verdict == "done" else 0,
        "body": {"game_minutes": 4.0, "busy_share_last": 0.6, "idle_ticks_last": 30, "busy_polls_share": 0.7},
        "module_errors": 0}), encoding="utf-8")
    return {"label": name, "model": model, "transcript": name + ".jsonl", "result": name + ".json",
            "usage_before": usage[0], "usage_after": usage[1]}


def test_summary_markdown_and_json(tmp_path):
    runs = [write_run(tmp_path, "s1", "sonnet", "done", 10, (10, 14)),
            write_run(tmp_path, "s2", "sonnet", "partial", 20, (14, 20)),
            write_run(tmp_path, "h1", "haiku", "done", 6, ({"five_hour": 20, "weekly": 40}, {"five_hour": 21, "weekly": 41.5}))]
    out = summary.summarize({"runs": runs}, str(tmp_path))
    by = {r["label"]: r for r in out["runs"]}
    assert by["s1"]["verdict"] == "done" and by["s1"]["tool_calls"] == 10 and by["s1"]["usage_five_hour"] == 4
    assert by["h1"]["usage"] == {"five_hour": 1, "weekly": 1.5}
    assert by["s1"]["game_min"] == 4.0 and by["s1"]["busy_share"] == 0.6 and by["s1"]["active_min"] == 5.0
    agg = {a["model"]: a for a in out["by_model"]}
    assert agg["sonnet"]["runs"] == 2 and agg["sonnet"]["done"] == 1 and agg["sonnet"]["partial"] == 1
    assert agg["sonnet"]["tool_calls"] == 15 and agg["sonnet"]["usage_five_hour"] == 5
    assert agg["haiku"]["score"] == 1.0
    md = summary.render_md(out)
    assert "| s1 | sonnet | доведено |" in md and "| s2 | sonnet | частично |" in md and "## По моделям" in md
    json.dumps(out)


def test_usage_reset_not_averaged_and_missing_files_reported(tmp_path):
    run = write_run(tmp_path, "r1", "haiku", "done", 3, (90, 4))
    assert summary.summarize_run(run, str(tmp_path))["usage"] == {"five_hour": {"reset": True}}
    out = summary.summarize([run, {"label": "gone", "model": "haiku", "transcript": "нет.jsonl", "result": "нет.json"}],
                            str(tmp_path))
    assert out["by_model"][0]["usage_five_hour"] is None
    gone = [r for r in out["runs"] if r["label"] == "gone"][0]
    assert "журнал" in gone["error"] and "результат" in gone["error"]
    assert "Проблемы с данными" in summary.render_md(out)


def test_setup_failed_result_is_flagged(tmp_path):
    (tmp_path / "r.json").write_text(json.dumps({"ok": False, "error": {"kind": "setup", "text": "нет пластин"}}), encoding="utf-8")
    row = summary.summarize_run({"label": "x", "result": "r.json"}, str(tmp_path))
    assert "нет пластин" in row["error"] and row.get("verdict") is None


def test_summary_cli(tmp_path):
    runs = [write_run(tmp_path, "s1", "sonnet", "done", 4, (1, 2))]
    man = tmp_path / "m.json"
    man.write_text(json.dumps(runs), encoding="utf-8")
    out = tmp_path / "out.md"
    assert summary.main([str(man), "--out", str(out)]) == 0
    assert "доведено" in out.read_text(encoding="utf-8")
    outj = tmp_path / "out.json"
    assert summary.main([str(man), "--format", "json", "--out", str(outj)]) == 0
    assert json.loads(outj.read_text(encoding="utf-8"))["runs"][0]["label"] == "s1"
    assert summary.main([str(tmp_path / "нет.json")]) == 2
