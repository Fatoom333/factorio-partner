"""Сценарий трёх петель (agents/workflows/partner-roles.js): запуск под node с заглушками agent/parallel/log."""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

SRC = Path(__file__).resolve().parent.parent / "workflows" / "partner-roles.js"
NODE = shutil.which("node")

HARNESS = r"""
const fs = require('fs')
const src = fs.readFileSync(process.argv[1], 'utf8').replace(/^export const meta/m, 'const meta')
const input = JSON.parse(fs.readFileSync(0, 'utf8'))
const calls = [], logs = []
const queue = input.replies            // role -> список ответов подряд
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
const fn = new AsyncFunction('args', 'agent', 'parallel', 'phase', 'log', src)
const agent = async (prompt, opts) => {
  calls.push({ type: opts.agentType, model: opts.model, label: opts.label, prompt })
  const q = queue[opts.agentType] || []
  return q.length ? q.shift() : 'СМЕНА: стоп\nПричина: нечего'
}
const parallel = fns => Promise.all(fns.map(f => f()))
fn(input.args, agent, parallel, () => {}, t => logs.push(t)).then(
  result => console.log(JSON.stringify({ result, calls, logs })),
  e => console.log(JSON.stringify({ error: String(e.message) })))
"""

KEYS = {"voice": "V" * 40, "pilot": "P" * 40, "strategist": "S" * 40}


def helper(hid="h1"):
    return {"id": hid, "roles": {r: {"prompt": f"helper: {hid}\nkey: {k}\nроль {r}"} for r, k in KEYS.items()}}


def run(args, replies=None, tmp_path=None):
    proc = subprocess.run([NODE, "-e", HARNESS, str(SRC)], input=json.dumps({"args": args, "replies": replies or {}}),
                          capture_output=True, text=True, encoding="utf-8", timeout=60)
    assert proc.returncode == 0, proc.stderr
    return json.loads(proc.stdout)


needs_node = pytest.mark.skipif(NODE is None, reason="нет node")


def test_script_text_rules():
    text = SRC.read_text(encoding="utf-8")
    assert text.startswith("export const meta = {")
    for agent_type, model in (("partner-voice", "haiku"), ("partner-pilot", "pilot"), ("partner-strategist", "sonnet")):
        assert agent_type in text
    assert "Date.now" not in text and "Math.random" not in text and "new Date()" not in text
    for line in text.splitlines():
        if ("log(" in line or "label:" in line) and not line.lstrip().startswith("//"):
            assert "prompt" not in line and "key" not in line, line


@needs_node
def test_three_loops_models_and_labels():
    out = run({"helpers": [helper()], "pilot_model": "haiku"})
    types = {c["type"]: c for c in out["calls"]}
    assert set(types) == {"partner-voice", "partner-pilot", "partner-strategist"}
    assert types["partner-voice"]["model"] == "haiku"
    assert types["partner-pilot"]["model"] == "haiku"
    assert types["partner-strategist"]["model"] == "sonnet"
    # у каждой роли в запуске только её ключ
    for role, call in zip(("voice", "pilot", "strategist"), (types["partner-voice"], types["partner-pilot"], types["partner-strategist"])):
        assert KEYS[role] in call["prompt"]
        assert all(k not in call["prompt"] for r, k in KEYS.items() if r != role)
        assert "key" not in call["label"] and KEYS[role] not in call["label"]
    assert out["result"]["pilot_model"] == "haiku"


@needs_node
def test_pilot_model_default_and_validation():
    out = run({"helpers": [helper()]})
    assert {c["type"]: c["model"] for c in out["calls"]}["partner-pilot"] == "sonnet"
    assert "pilot_model" in run({"helpers": [helper()], "pilot_model": "opus"})["error"]


@needs_node
def test_shift_restarts_with_notes_and_cursor():
    replies = {"partner-pilot": ["СМЕНА: дальше\nПричина: контекст\nКурсор: 42\nkey: " + KEYS["pilot"],
                                 "СМЕНА: стоп\nПричина: поручение выполнено\nКурсор: 50"],
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] * 4,
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 4}
    out = run({"helpers": [helper()], "cursor": 7}, replies)
    pilot = [c for c in out["calls"] if c["type"] == "partner-pilot"]
    assert len(pilot) == 2
    assert "since=7" in pilot[0]["prompt"]
    assert "since=42" in pilot[1]["prompt"] and "Причина: контекст" in pilot[1]["prompt"]
    assert KEYS["pilot"] not in pilot[1]["prompt"].split("<<<")[1]       # ключ из выжимки вычищен
    res = {r["role"]: r for r in out["result"]["roles"]}
    assert res["pilot"]["status"] == "стоп" and res["pilot"]["shifts"] == 2


@needs_node
def test_voice_stop_is_global():
    # голос ушёл «стоп» сразу, остальные не начинают вторую смену
    replies = {"partner-voice": ["СМЕНА: стоп\nПричина: хозяин отпустил"],
               "partner-pilot": ["СМЕНА: дальше\nПричина: x", "СМЕНА: дальше\nПричина: y"],
               "partner-strategist": ["СМЕНА: дальше\nПричина: x", "СМЕНА: дальше\nПричина: y"]}
    out = run({"helpers": [helper()]}, replies)
    assert len([c for c in out["calls"] if c["type"] == "partner-pilot"]) <= 2
    res = {r["role"]: r for r in out["result"]["roles"]}
    assert res["voice"]["status"] == "стоп"
    assert res["pilot"]["status"] == "остановлено другой ролью" or res["pilot"]["shifts"] <= 2


@needs_node
def test_pilot_stop_without_global_reason_keeps_others():
    replies = {"partner-pilot": ["СМЕНА: стоп\nПричина: поручение выполнено"],
               "partner-voice": ["СМЕНА: дальше\nПричина: контекст", "СМЕНА: стоп\nПричина: отбой"]}
    out = run({"helpers": [helper()]}, replies)
    assert len([c for c in out["calls"] if c["type"] == "partner-voice"]) == 2


@needs_node
def test_lost_body_stops_everyone():
    replies = {"partner-pilot": ["СМЕНА: стоп\nПричина: тела нет"],
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] * 3,
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 3}
    out = run({"helpers": [helper()], "max_shifts": 5}, replies)
    res = {r["role"]: r for r in out["result"]["roles"]}
    assert res["pilot"]["status"] == "стоп"
    assert all(r["shifts"] <= 3 for r in res.values())


@needs_node
def test_budget_stop_ends_only_strategist():
    out = run({"helpers": [helper()], "budget_stop": True})
    assert not [c for c in out["calls"] if c["type"] == "partner-strategist"]
    res = {r["role"]: r for r in out["result"]["roles"]}
    assert res["strategist"]["status"] == "лимит" and res["strategist"]["shifts"] == 0
    assert [c for c in out["calls"] if c["type"] == "partner-voice"]


@needs_node
def test_interrupted_shift_and_shift_limit():
    out = run({"helpers": [helper()], "max_shifts": 2},
              {"partner-voice": ["СМЕНА: дальше\nПричина: a", "СМЕНА: дальше\nПричина: b", "СМЕНА: дальше\nПричина: c"]})
    assert len([c for c in out["calls"] if c["type"] == "partner-voice"]) <= 2


@needs_node
def test_bad_args():
    assert "один помощник" in run({"helpers": []})["error"]
    assert "один помощник" in run({"helpers": [helper("h1"), helper("h2")]})["error"]
    assert run({"helpers": [helper("h1"), helper("h2")], "helper": "h2"})["result"]["helper"] == "h2"
    bad = helper()
    del bad["roles"]["strategist"]
    assert "strategist" in run({"helpers": [bad]})["error"]


@needs_node
def test_link_lost_restarts_the_shift():
    # сервер перезапускался: голос ушёл «стоп, нет связи» — смена голоса начинается заново, остальные не стоят
    replies = {"partner-voice": ["СМЕНА: стоп\nПричина: нет связи, инструментов нет",
                                 "СМЕНА: стоп\nПричина: хозяин отпустил"],
               "partner-pilot": ["СМЕНА: дальше\nПричина: x", "СМЕНА: стоп\nПричина: отбой"],
               "partner-strategist": ["СМЕНА: дальше\nПричина: x", "СМЕНА: стоп\nПричина: отбой"]}
    out = run({"helpers": [helper()]}, replies)
    assert len([c for c in out["calls"] if c["type"] == "partner-voice"]) == 2
    assert any("связь пропала" in line for line in out["logs"])
    res = {r["role"]: r for r in out["result"]["roles"]}
    assert res["voice"]["status"] == "стоп" and res["voice"]["shifts"] == 2


@needs_node
def test_link_lost_gives_up_after_retries():
    replies = {"partner-voice": ["СМЕНА: стоп\nПричина: связь пропала, перезапуск"] * 6,
               "partner-pilot": ["СМЕНА: дальше\nПричина: x"] * 6,
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 6}
    out = run({"helpers": [helper()]}, replies)
    assert len([c for c in out["calls"] if c["type"] == "partner-voice"]) == 4   # 1 + 3 повтора
    res = {r["role"]: r for r in out["result"]["roles"]}
    assert res["voice"]["status"] == "стоп"
