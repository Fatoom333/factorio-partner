"""Plan-limit watchdog (docs/MCP.md «Сторож лимита»): reading the figure, the levels, the refusals
by level and the one-time warning to the voice."""
import asyncio
import json

import pytest

from factorio_partner import roles as R
from factorio_partner.budget import Budget
from factorio_partner.core import Core
from factorio_partner.errors import ConfigError, PartnerError

from conftest import KEY, make_bridge

VKEY = "v" * 40
SKEY = "s" * 40
NOW = 1_800_000_000.0


@pytest.fixture(autouse=True)
def notes_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path / "notes"))
    monkeypatch.setenv("FP_SAVE_NAME", "stand")
    monkeypatch.delenv("FP_BUDGET_FILE", raising=False)


@pytest.fixture
def home(home):
    (home / "helpers.json").write_text(json.dumps({
        "h1": {"pilot": KEY, "voice": VKEY, "strategist": SKEY},
    }), encoding="utf-8")
    return home


def write(path, five=10, week=5, age=0, **extra):
    d = {"five_hour_pct": five, "weekly_pct": week, "ts": NOW - age}
    d.update(extra)
    path.write_text(json.dumps(d), encoding="utf-8")


@pytest.fixture
def bfile(tmp_path):
    return tmp_path / "budget.json"


def mk(bfile, **kw):
    return Budget(bfile, now=lambda: NOW, **kw)


async def refused(coro) -> PartnerError:
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


# ---------------------------------------------------------------- reading the figure

@pytest.mark.parametrize("five,level", [(0, "ok"), (69.9, "ok"), (70, "strategist_off"),
                                        (84, "strategist_off"), (85, "voice_only"), (100, "voice_only")])
def test_levels(bfile, five, level):
    write(bfile, five=five)
    assert mk(bfile).level() == level


def test_weekly_limit_alone_cuts_to_voice(bfile):
    write(bfile, five=3, week=91)
    assert mk(bfile).level() == "voice_only"
    write(bfile, five=3, week=89)
    assert mk(bfile).level() == "ok"


def test_gate_hook_field_names_are_accepted(bfile):
    bfile.write_text(json.dumps({"status": "ok", "five_pct": 80, "week_pct": 1,
                                 "captured_at": NOW - 5}), encoding="utf-8")
    st = mk(bfile).status()
    assert st["level"] == "strategist_off" and st["five_hour_pct"] == 80 and st["weekly_pct"] == 1


def test_thresholds_are_settable(bfile):
    write(bfile, five=50)
    assert mk(bfile, warn=40, stop=60).level() == "strategist_off"
    assert mk(bfile, warn=30, stop=50).level() == "voice_only"
    with pytest.raises(ConfigError):
        Budget(bfile, warn=90, stop=80)


def _text(s):
    return lambda p: p.write_text(s, encoding="utf-8")


def _json(d):
    return _text(json.dumps(d))


@pytest.mark.parametrize("make", [
    lambda p: None,                                                         # no file
    _text("{not json"),
    _text("[1,2]"),
    _json({"five_hour_pct": "50", "ts": NOW}),
    _json({"five_hour_pct": True, "ts": NOW}),
    _json({"five_hour_pct": 150, "ts": NOW}),
    _json({"five_hour_pct": 50}),                                           # no ts
    _json({"five_hour_pct": 50, "ts": NOW + 9999}),
    _text("x" * 5000),
])
def test_bad_data_is_unknown(bfile, make):
    make(bfile)
    st = mk(bfile).status()
    assert st["level"] == "unknown" and st["reason"] in ("no_file", "bad_file")


def test_stale_data_is_unknown(bfile):
    write(bfile, five=99, age=601)
    assert mk(bfile).status() == {"level": "unknown", "reason": "stale"}
    write(bfile, five=99, age=599)
    assert mk(bfile).level() == "voice_only"


def test_no_file_configured_is_unknown():
    assert Budget(None).status() == {"level": "unknown", "reason": "not_configured"}


def test_from_env(bfile):
    b = Budget.from_env({"FP_BUDGET_FILE": str(bfile), "FP_BUDGET_WARN": "50", "FP_BUDGET_STOP": "60"})
    assert (b.path, b.warn, b.stop) == (bfile, 50, 60)
    assert not Budget.from_env({}).configured
    with pytest.raises(ConfigError):
        Budget.from_env({"FP_BUDGET_WARN": "lots"})
    with pytest.raises(ConfigError):
        Budget.from_env({"FP_BUDGET_WARN": "90", "FP_BUDGET_STOP": "80"})


# ---------------------------------------------------------------- the gate by role

PILOT_WRITES = [("partner_act", {"do": "walk"}), ("partner_say", {}), ("partner_plan", {}),
                ("partner_notes", {"action": "add", "kind": "memo"}), ("partner_reflex", {"set": []}),
                ("partner_inbox", {"ack": ["o1"]})]


def test_ok_and_strategist_off_leave_the_pilot_alone():
    for level in ("ok", "unknown", "strategist_off"):
        for tool, a in PILOT_WRITES:
            R.budget_gate(level, R.PILOT, tool, a)


@pytest.mark.parametrize("tool,a", PILOT_WRITES)
@pytest.mark.parametrize("role", [R.PILOT, R.STRATEGIST])
def test_voice_only_refuses_writes(role, tool, a):
    with pytest.raises(PartnerError) as ei:
        R.budget_gate("voice_only", role, tool, a)
    assert ei.value.code == "budget"


def test_voice_only_keeps_reads_cancel_hold_and_the_voice():
    for role in (R.PILOT, R.STRATEGIST):
        for tool, a in [("partner_brief", {}), ("partner_wait", {}), ("partner_state", {}),
                        ("partner_cancel", {"job": 3}), ("partner_cancel", {"all": True}),
                        ("partner_hold", {}), ("partner_hold", {"release": True}),
                        ("partner_ledger", {"action": "list"}), ("partner_notes", {"action": "list"})]:
            R.budget_gate("voice_only", role, tool, a)
    for tool, a in [("partner_say", {}), ("partner_order", {}), ("partner_cancel", {"all": True})]:
        R.budget_gate("voice_only", R.VOICE, tool, a)


def test_strategist_off_refuses_new_goals_only():
    for act in ("put", "resume"):
        with pytest.raises(PartnerError) as ei:
            R.budget_gate("strategist_off", R.STRATEGIST, "partner_ledger", {"action": act})
        assert ei.value.code == "budget"
    for tool, a in [("partner_ledger", {"action": "list"}), ("partner_ledger", {"action": "cancel"}),
                    ("partner_wait", {}), ("partner_plan", {}), ("partner_inbox", {"ack": ["o1"]})]:
        R.budget_gate("strategist_off", R.STRATEGIST, tool, a)
    R.budget_gate("strategist_off", R.PILOT, "partner_ledger", {"action": "cancel"})


# ---------------------------------------------------------------- through the server

@pytest.fixture
async def bcore(cfg, bfile):
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module="tests_no_such_forge_module",
             budget=mk(bfile))
    yield c
    await c.bridge.close()


async def test_brief_and_wait_show_the_budget(bcore, fake, bfile):
    write(bfile, five=72)
    b = await bcore.op_brief("h1", KEY)
    assert b["budget"]["level"] == "strategist_off" and b["budget"]["five_hour_pct"] == 72
    w = await bcore.op_wait("h1", KEY, 0)
    assert w["budget"]["level"] == "strategist_off"


async def test_unconfigured_wait_has_no_budget_field(core, fake):
    assert "budget" not in await core.op_wait("h1", KEY, 0)
    assert (await core.op_brief("h1", KEY))["budget"] == {"level": "unknown", "reason": "not_configured"}


async def test_strategist_off_refuses_put(bcore, fake, bfile):
    write(bfile, five=75)
    pkg = {"name": "x", "anchor": {"x": 1, "y": 1},
           "steps": [{"do": "walk", "args": {"to": {"x": 1, "y": 2}}}],
           "verify": [{"kind": "stock", "item": "iron-plate", "at_least": 1}]}
    e = await refused(bcore.op_ledger("h1", SKEY, "put", pkg))
    assert e.code == "budget"
    assert (await bcore.op_ledger("h1", SKEY))["packages"] == []       # reading still works
    write(bfile, five=10)
    assert (await bcore.op_ledger("h1", SKEY, "put", pkg))["package"]["name"] == "x"


async def test_voice_only_refuses_the_body_but_not_a_stop(bcore, fake, bfile):
    write(bfile, five=90)
    e = await refused(bcore.op_act("h1", KEY, "wait", {"seconds": 1}))
    assert e.code == "budget" and fake.mod.executed["act"] == 0
    assert (await refused(bcore.op_say("h1", KEY, "привет"))).code == "budget"
    await bcore.op_cancel("h1", KEY, None, True)                       # a stop goes through
    assert fake.mod.executed["cancel"] == 1
    await bcore.op_say("h1", VKEY, "лимит почти кончился")             # the voice speaks
    write(bfile, five=10)
    await bcore.op_act("h1", KEY, "wait", {"seconds": 1})
    assert fake.mod.executed["act"] == 1


async def test_voice_gets_budget_low_once(bcore, fake, bfile):
    write(bfile, five=10)
    await bcore.op_wait("h1", VKEY, 0)                                 # the voice is known
    write(bfile, five=90)
    await bcore.op_state("h1", KEY)                                    # any call sees the level
    w = await bcore.op_wait("h1", VKEY, 0)
    assert [e["kind"] for e in w["events"]] == ["budget_low"]
    assert w["events"][0]["loud"] and w["budget"]["level"] == "voice_only"
    await bcore.op_state("h1", KEY)
    assert (await bcore.op_wait("h1", VKEY, 0))["events"] == []        # once per spell
    write(bfile, five=3)
    await bcore.op_state("h1", KEY)                                    # the spell ends...
    write(bfile, five=95)
    await bcore.op_state("h1", KEY)                                    # ...and a new one warns again
    assert [e["kind"] for e in (await bcore.op_wait("h1", VKEY, 0))["events"]] == ["budget_low"]


async def test_unknown_reading_neither_blocks_nor_ends_the_spell(bcore, fake, bfile):
    await bcore.op_wait("h1", VKEY, 0)
    write(bfile, five=90)
    await bcore.op_state("h1", KEY)
    await bcore.op_wait("h1", VKEY, 0)
    bfile.unlink()                                                     # no figure: nothing is cut
    await bcore.op_act("h1", KEY, "wait", {"seconds": 1})
    write(bfile, five=90)
    await bcore.op_state("h1", KEY)
    assert (await bcore.op_wait("h1", VKEY, 0))["events"] == []


async def test_sleeping_voice_wakes_on_budget_low(bcore, fake, bfile):
    write(bfile, five=10)
    await bcore.op_wait("h1", VKEY, 0)
    write(bfile, five=90)
    w = await asyncio.wait_for(bcore.op_wait("h1", VKEY, 20, True), 5)
    assert [e["kind"] for e in w["events"]] == ["budget_low"] and not w["timed_out"]
