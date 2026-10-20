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


# ---- голос и стратег на всех, пилот на каждое тело ----------------------------------------

SHARED_KEYS = {"voice": "V" * 40, "strategist": "S" * 40}
PILOT_KEYS = {"h1": "1" * 40, "h2": "2" * 40, "h3": "3" * 40}


def session(ids=("h1", "h2", "h3")):
    return {"voice": {"prompt": f"helper: h1\nkey: {SHARED_KEYS['voice']}\nроль voice"},
            "strategist": {"prompt": f"helper: h1\nkey: {SHARED_KEYS['strategist']}\nроль strategist"},
            "helpers": [{"id": h, "roles": {"pilot": {"prompt": f"helper: {h}\nkey: {PILOT_KEYS[h]}\nроль pilot"}}}
                        for h in ids]}


def by_label(out, word):
    return [c for c in out["calls"] if word in c["label"]]


@needs_node
def test_three_helpers_make_five_loops():
    out = run(dict(session(), pilot_model="haiku"))
    labels = sorted(c["label"] for c in out["calls"])
    assert labels == ["h1 пилот: смена 1", "h2 пилот: смена 1", "h3 пилот: смена 1",
                      "голос: смена 1", "стратег: смена 1"]
    for c in out["calls"]:
        assert not any(k in c["label"] for k in [*SHARED_KEYS.values(), *PILOT_KEYS.values()])
        keys = [k for k in [*SHARED_KEYS.values(), *PILOT_KEYS.values()] if k in c["prompt"]]
        assert len(keys) == 1                                  # в смене — только ключ этой петли
    pilots = [c for c in out["calls"] if c["type"] == "partner-pilot"]
    assert len(pilots) == 3 and all(c["model"] == "haiku" for c in pilots)
    assert {c["type"]: c["model"] for c in out["calls"]}["partner-voice"] == "haiku"
    res = out["result"]
    assert res["helpers"] == ["h1", "h2", "h3"] and "helper" not in res
    assert sorted((r["role"], r.get("helper")) for r in res["roles"]) == \
        [("pilot", "h1"), ("pilot", "h2"), ("pilot", "h3"), ("strategist", None), ("voice", None)]


@needs_node
def test_lost_body_ends_only_its_pilot():
    replies = {"partner-pilot": ["СМЕНА: стоп\nПричина: тела нет"] + ["СМЕНА: дальше\nПричина: x"] * 6,
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] * 2 + ["СМЕНА: стоп\nПричина: хозяин отпустил"],
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 6}
    out = run(dict(session(), max_shifts=5), replies)
    res = {(r["role"], r.get("helper")): r for r in out["result"]["roles"]}
    lost = [r for (role, _), r in res.items() if role == "pilot" and r["status"] == "стоп"]
    assert len(lost) == 1 and lost[0]["shifts"] == 1        # первый ответ достался одному пилоту
    assert len(by_label(out, "голос")) == 3                  # остальные работают, пока голос не отпустил
    others = [r for (role, _), r in res.items() if role == "pilot" and r["status"] != "стоп"]
    assert len(others) == 2 and all(r["shifts"] >= 2 for r in others)


@needs_node
def test_every_body_lost_stops_everyone():
    replies = {"partner-pilot": ["СМЕНА: стоп\nПричина: тела нет"] * 3,
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] * 8,
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 8}
    out = run(dict(session(), max_shifts=8), replies)
    assert len(by_label(out, "голос")) <= 2
    res = {r["role"]: r for r in out["result"]["roles"] if r["role"] != "pilot"}
    assert res["voice"]["status"] == "остановлено другой ролью"


@needs_node
def test_voice_stop_ends_every_loop_of_three_bodies():
    replies = {"partner-voice": ["СМЕНА: стоп\nПричина: хозяин отпустил"],
               "partner-pilot": ["СМЕНА: дальше\nПричина: x"] * 9,
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 3}
    out = run(session(), replies)
    assert len([c for c in out["calls"] if c["type"] == "partner-pilot"]) <= 6
    assert all(r["status"] in ("стоп", "остановлено другой ролью") for r in out["result"]["roles"])


@needs_node
def test_pilot_link_lost_restarts_its_shift_with_three_bodies():
    replies = {"partner-pilot": ["СМЕНА: стоп\nПричина: нет связи, инструментов нет"]
               + ["СМЕНА: стоп\nПричина: поручение выполнено"] * 3,
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] * 3 + ["СМЕНА: стоп\nПричина: отбой"],
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 4}
    out = run(session(), replies)
    assert any("пилот — связь пропала" in line for line in out["logs"])
    assert len([c for c in out["calls"] if c["type"] == "partner-pilot"]) == 4      # 3 + одна повторная
    assert all(r["status"] == "стоп" for r in out["result"]["roles"] if r["role"] == "pilot")


@needs_node
def test_shared_budget_stop_and_cursor():
    out = run(dict(session(("h1", "h2")), budget_stop=True, cursor=11))
    assert not by_label(out, "стратег")
    assert all("since=11" in c["prompt"] for c in out["calls"])
    res = {r["role"]: r for r in out["result"]["roles"] if r["role"] != "pilot"}
    assert res["strategist"]["status"] == "лимит"


@needs_node
def test_shared_session_checks():
    bad = session()
    del bad["strategist"]
    assert "strategist" in run(bad)["error"]
    bad = session()
    bad["helpers"][1]["id"] = "h1"
    assert "свой id" in run(bad)["error"]
    bad = session()
    del bad["helpers"][2]["roles"]["pilot"]
    assert "h3" in run(bad)["error"]
    assert "от 1" in run(dict(session(), helpers=[]))["error"]
    # одно тело в новом виде — три петли, как раньше
    out = run(session(("h1",)))
    assert sorted(c["type"] for c in out["calls"]) == ["partner-pilot", "partner-strategist", "partner-voice"]


@needs_node
def test_voice_and_strategist_end_when_no_pilot_is_left():
    # пилоты кончились сами (поручения выполнены, не потеря тела): голосу и стратегу некому передавать работу
    replies = {"partner-pilot": ["СМЕНА: стоп\nПричина: поручение выполнено"] * 2,
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] * 20,
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 20}
    out = run(dict(session(("h1", "h2")), max_shifts=20), replies)
    assert len(by_label(out, "голос")) <= 3 and len(by_label(out, "стратег")) <= 3     # не 20
    assert any("пилотов не осталось" in line for line in out["logs"])
    res = {r["role"]: r for r in out["result"]["roles"] if r["role"] != "pilot"}
    assert res["voice"]["status"] == res["strategist"]["status"] == "остановлено другой ролью"


@needs_node
def test_pilots_at_the_shift_limit_end_the_shared_loops():
    replies = {"partner-pilot": ["СМЕНА: дальше\nПричина: x"] * 4,
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] * 20,
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 20}
    out = run(dict(session(("h1", "h2")), max_shifts=2), replies)
    res = {r["role"]: r for r in out["result"]["roles"] if r["role"] != "pilot"}
    assert all(r["status"] in ("предел смен", "остановлено другой ролью") for r in res.values())


@needs_node
def test_host_key_never_reaches_an_agent():
    """Ключ диспетчера из файла сессии (host) не идёт ни в одну смену и вычищается из выжимок."""
    host = "H" * 40
    replies = {"partner-pilot": ["СМЕНА: дальше\nПричина: x\nчужой " + host] + ["СМЕНА: дальше\nПричина: x"] * 4,
               "partner-voice": ["СМЕНА: дальше\nПричина: x"] + ["СМЕНА: стоп\nПричина: хозяин отпустил"],
               "partner-strategist": ["СМЕНА: дальше\nПричина: x"] * 4}
    out = run(dict(session(ids=("h1",)), host={"key": host, "helper": "h1", "tool": "partner_relay"}), replies)
    assert out["calls"]
    for c in out["calls"]:
        assert host not in c["prompt"] and host not in c["label"]
