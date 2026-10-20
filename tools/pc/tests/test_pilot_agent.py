"""Запуск пилота для сравнения моделей: команда, сообщение, остановка смены, манифест (без claude и без игры)."""
from __future__ import annotations

import argparse
import json
import os

import pytest

from conftest import PC_DIR, REPO
from bench import pilot_agent, summary, transcript_stats

KEY = "K" * 40


def test_command_has_no_prompt_or_key_and_pins_model_and_single_mcp():
    cmd = pilot_agent.build_command("claude", "haiku", "mcp.json", "sid-1")
    assert cmd[:2] == ["claude", "-p"]
    assert cmd[cmd.index("--model") + 1] == "haiku"
    assert cmd[cmd.index("--agent") + 1] == "partner-pilot"
    assert "--strict-mcp-config" in cmd and cmd[cmd.index("--mcp-config") + 1] == "mcp.json"
    assert cmd[cmd.index("--allowedTools") + 1] == "mcp__partner__*"
    assert cmd[cmd.index("--permission-mode") + 1] == "dontAsk"
    assert cmd[cmd.index("--setting-sources") + 1] == "project" and "--disable-slash-commands" in cmd
    assert "--effort" not in cmd and "--effort" in pilot_agent.build_command("c", "m", "x", "s", "low")


def test_prompt_joins_session_message_and_task():
    session = {"helpers": [{"id": "h2", "prompt": "x"}, {"id": "h1", "prompt": "helper: h1\nkey: " + KEY}]}
    msg = pilot_agent.compose_prompt(pilot_agent.helper_prompt(session, "h1"), "достань пластины")
    assert msg.startswith("helper: h1") and "достань пластины" in msg and pilot_agent.TASK_HEADER in msg
    with pytest.raises(ValueError):
        pilot_agent.helper_prompt(session, "h9")


def test_scenario_task_comes_from_pilot_bench():
    text = pilot_agent._scenario_task()
    assert "50" in text and "сундука" in text


@pytest.mark.parametrize("kw,expect", [
    ({}, None),
    ({"watch_gone": True}, "scenario_ended"),
    ({"stop_file_exists": True}, "stop_file"),
    ({"turns": 5}, "max_turns"),
    ({"elapsed_s": 600.0}, "timeout"),
])
def test_decide_stop(kw, expect):
    base = dict(elapsed_s=10.0, max_s=600.0, turns=0, max_turns=5, watch_gone=False, stop_file_exists=False)
    base.update(kw)
    assert pilot_agent.decide_stop(**base) == expect


def test_count_turns_groups_by_message_id_and_finds_transcript(tmp_path):
    proj = tmp_path / "proj"
    proj.mkdir()
    rows = [{"type": "assistant", "message": {"id": "a"}}, {"type": "assistant", "message": {"id": "a"}},
            {"type": "assistant", "message": {"id": "b"}}, {"type": "user", "message": {}}]
    path = proj / "sid.jsonl"
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\nмусор\n", encoding="utf-8")
    assert pilot_agent.count_turns(str(path)) == 2
    assert pilot_agent.count_turns(None) == 0 and pilot_agent.count_turns(str(tmp_path / "no")) == 0
    assert pilot_agent.find_transcript("sid", str(tmp_path)) == str(path)
    assert pilot_agent.find_transcript("other", str(tmp_path)) is None


def test_pid_alive_current_process_and_bogus():
    assert pilot_agent.pid_alive(os.getpid())
    assert not pilot_agent.pid_alive(0)


def test_record_replaces_same_label(tmp_path):
    m = str(tmp_path / "manifest.json")
    a = argparse.Namespace(manifest=m, label="sonnet-1", model="sonnet", transcript="t.jsonl", result="r.json",
                           until="2026-10-20T10:00:00Z", usage_before=1.0, usage_after=3.5)
    pilot_agent.record(a)
    a.usage_after = 4.0
    pilot_agent.record(a)
    pilot_agent.record(argparse.Namespace(manifest=m, label="haiku-1", model="haiku", transcript=None, result=None,
                                          until=None, usage_before=None, usage_after=None))
    runs = json.load(open(m, encoding="utf-8"))["runs"]
    assert [r["label"] for r in runs] == ["sonnet-1", "haiku-1"]
    assert runs[0]["usage_after"] == 4.0 and "transcript" not in runs[1]


def _row(kind, ts, mid=None, blocks=None):
    msg = {"content": blocks or []}
    if mid:
        msg["id"] = mid
    return json.dumps({"type": kind, "timestamp": ts, "message": msg})


def test_until_cuts_rows_after_stand_stop(tmp_path):
    lines = [_row("assistant", "2026-10-20T10:00:00Z", "m1", [{"type": "tool_use", "id": "c1", "name": "mcp__partner__partner_state"}]),
             _row("user", "2026-10-20T10:00:05Z", None, [{"type": "tool_result", "tool_use_id": "c1", "content": "{}"}]),
             _row("assistant", "2026-10-20T10:01:00Z", "m2", [{"type": "tool_use", "id": "c2", "name": "mcp__partner__partner_state"}]),
             _row("user", "2026-10-20T10:01:01Z", None, [{"type": "tool_result", "tool_use_id": "c2", "content": "нет связи", "is_error": True}])]
    until = transcript_stats.parse_time("2026-10-20T10:00:30Z")
    cut = transcript_stats.parse_lines(lines, until=until)
    full = transcript_stats.parse_lines(lines)
    assert cut["model_turns"] == 1 and cut["tool_errors"] == 0 and cut["duration_s"] == 5.0
    assert full["model_turns"] == 2 and full["tool_errors"] == 1
    d = tmp_path
    (d / "t.jsonl").write_text("\n".join(lines), encoding="utf-8")
    row = summary.summarize_run({"label": "x", "model": "sonnet", "transcript": "t.jsonl",
                                 "until": "2026-10-20T10:00:30Z"}, str(d))
    assert row["model_turns"] == 1 and row["errors"] == 0


def test_wrapper_script_is_generic():
    path = os.path.join(PC_DIR, "run-pilot-bench.ps1")
    text = open(path, encoding="utf-8-sig").read()
    assert open(path, "rb").read().startswith(b"\xef\xbb\xbf")        # PowerShell 5.1 читает кириллицу только с BOM
    assert "pilot_bench" in text and "-Local" in text and "bench.pilot_agent" in text
    import re
    assert not re.search(r"[A-Za-z]:[\/]+(Users|Temp)", text)       # пути машины — только в local/ и pc.local.json
