"""The owner's settings of the mod (op ``settings``), his leave on single calls (``approved`` +
``order`` -> ``owner_ok``), his window (event ``owner_panel``) and the request to restart the roles on
N helpers (``partner_ledger{action:"scale"}``, ``partner_rescale``)."""
import json

import pytest

from factorio_partner import budget as B
from factorio_partner import ledger as L
from factorio_partner import roles as R
from factorio_partner import savenotes
from factorio_partner import settings as S
from factorio_partner import validate as V
from factorio_partner.core import Core
from factorio_partner.errors import PartnerError
from factorio_partner.server import build_server

from conftest import KEY, make_bridge
from test_ledger import Body

VKEY = "v" * 40
SKEY = "s" * 40
HKEY = "x" * 40
CHEST = {"name": "iron-chest", "pos": {"x": 10.5, "y": 20.5}}


@pytest.fixture(autouse=True)
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path / "notes"))
    monkeypatch.setenv("FP_SAVE_NAME", "stand")
    monkeypatch.delenv("FP_CHAT_SETTLE", raising=False)


@pytest.fixture
def home(home):
    (home / "helpers.json").write_text(json.dumps({
        "*": {"voice": VKEY, "strategist": SKEY, "host": HKEY},
        "h1": {"pilot": KEY},
        "h2": {"pilot": "p" * 40},
    }), encoding="utf-8")
    return home


@pytest.fixture
def body(fake):
    return Body(fake.mod)


def mod_settings(fake, **parts):
    """The fake mod answers ``settings`` with these parts (the rest — what the mod sends by default)."""
    fake.mod.handlers["settings"] = lambda a, e: parts


async def refused(coro) -> PartnerError:
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


def owner_said(fake, text):
    return fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": text}, helper=None)


def last(fake, op):
    return [r for r in fake.mod.requests if r.get("op") == op][-1]


async def small_order(core, fake, text="принеси руды"):
    await core.op_brief("h1", VKEY)
    ev = owner_said(fake, text)
    return (await core.op_order("h1", VKEY, ev["seq"], text, "small", to="h1"))["order"]


async def pilot_asks(core, oid, text="можно взять из ленты у печей?", perm="take_lines"):
    return (await core.op_ledger("h1", KEY, "ask", text=text, order=oid, perm=perm))["question"]


async def owner_answers(core, fake, qid, text="да"):
    ev = owner_said(fake, text)
    return (await core.op_order("h1", VKEY, ev["seq"], text, "small", answer_to=qid))["order"]


async def leave(core, fake, answer="да", perm="take_lines"):
    o = await small_order(core, fake)
    q = await pilot_asks(core, o["id"], perm=perm)
    await owner_answers(core, fake, q["id"], answer)
    return o, q


TAKE_LINES = {"items": {"iron-plate": 50}, "from_lines": True}


# ---------------------------------------------------------------- settings: reading and defaults

def test_normalize_takes_good_values_and_defaults_the_rest():
    s = S.normalize({"perms": {"take_lines": "deny", "build": "maybe", "chop": 3},
                     "limits": {"spend": 500, "far": -1},
                     "agents": {"helpers": 9, "pilot_model": "haiku", "voice_pause": 1.0, "thoughts": "yes",
                                "budget": {"strategist": 60, "voice_only": 200}},
                     "chat": {"reply_lines": 4}})
    assert s["source"] == "mod"
    assert s["perms"]["take_lines"] == "deny"
    assert s["perms"]["build"] == "auto" and s["perms"]["chop"] == "auto"      # bad -> default
    assert s["limits"] == {"spend": 500, "far": 300}
    assert s["agents"]["helpers"] == 1 and s["agents"]["pilot_model"] == "haiku"
    assert s["agents"]["voice_pause"] == 1.0 and s["agents"]["thoughts"] is False
    assert s["agents"]["budget"] == {"strategist": 60, "voice_only": 85, "weekly": 90}
    assert s["chat"] == {"answer_every": True, "reply_lines": 4}
    assert S.normalize("garbage") == S.defaults()
    assert S.perm(s, "no_such_perm") == "deny"          # an unknown permission fails closed


async def test_old_mod_gives_the_defaults(core, fake):
    st = await core.settings()                          # the fake mod has no `settings` op
    assert st == S.defaults()


async def test_settings_are_cached(core, fake):
    calls = []
    fake.mod.handlers["settings"] = lambda a, e: calls.append(1) or {"perms": {"shoot": "deny"}}
    assert (await core.settings())["perms"]["shoot"] == "deny"
    await core.settings()
    assert len(calls) == 1
    await core.settings(fresh=True)
    assert len(calls) == 2


async def test_brief_carries_perms_and_chat(core, fake, body):
    mod_settings(fake, perms={"take_lines": "deny", "shoot": "ask"}, chat={"reply_lines": 3})
    b = await core.op_brief("h1", KEY)
    p = b["perms"]
    assert "take_lines" in p["deny"] and "shoot" in p["ask"] and "build" not in p["ask"] + p["deny"]
    assert p["limits"] == {"spend": 200, "far": 300} and p["source"] == "mod"
    assert b["chat"] == {"answer_every": True, "reply_lines": 3}
    assert "rescale" not in b


# ---------------------------------------------------------------- the owner's leave on single calls

async def test_answered_leave_sends_owner_ok(core, fake, body):
    o, q = await leave(core, fake)
    await core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"])
    assert last(fake, "act")["owner_ok"] == ["take_lines"]
    # without the leave the same act goes without it (the mod asks for it: needs_owner_ok)
    await core.op_act("h1", KEY, "get_items", TAKE_LINES)
    assert "owner_ok" not in last(fake, "act") and "owner_ok" not in last(fake, "act")["args"]


async def test_leave_works_for_a_plan_and_reflexes(core, fake, body):
    o, q = await leave(core, fake, perm=["take-lines", "perm-shoot"])
    steps = [{"do": "get_items", "args": TAKE_LINES}, {"do": "walk", "args": {"to": "player"}}]
    await core.op_act("h1", KEY, "plan", {"steps": steps}, approved=q["id"], order=o["id"])
    assert last(fake, "act")["owner_ok"] == ["take_lines", "shoot"]
    await core.op_reflex("h1", KEY, [{"type": "shoot"}], approved=q["id"], order=o["id"])
    assert last(fake, "reflexes")["args"] == {"set": [{"type": "shoot"}]}
    assert last(fake, "reflexes")["owner_ok"] == ["take_lines", "shoot"]
    await core.op_reflex("h1", KEY, [{"type": "shoot"}])
    assert "owner_ok" not in last(fake, "reflexes")


@pytest.mark.parametrize("where", ["args", "step", "reflex", "package"])
async def test_agent_supplied_owner_ok_is_refused(core, fake, body, where):
    n = len(fake.mod.requests)
    if where == "args":
        e = await refused(core.op_act("h1", KEY, "get_items", dict(TAKE_LINES, owner_ok=True)))
    elif where == "step":
        e = await refused(core.op_act("h1", KEY, "plan", {"steps": [
            {"do": "get_items", "args": dict(TAKE_LINES, owner_ok=True)}]}))
    elif where == "reflex":
        e = await refused(core.op_reflex("h1", KEY, [{"type": "shoot", "owner_ok": True}]))
    else:
        e = await refused(core.op_ledger("h1", SKEY, "put", {
            "name": "x", "anchor": {"x": 0, "y": 0}, "owner_ok": True,
            "steps": [{"do": "walk", "args": {"to": {"x": 1, "y": 1}}}],
            "verify": [{"kind": "ghosts", "at_most": 0}]}))
    assert e.code == "bad_args" and "owner_ok" in e.text
    assert not [r for r in fake.mod.requests[n:] if r.get("op") in ("act", "reflexes")]


async def test_owner_ok_as_a_tool_argument_never_reaches_the_mod(core, fake, body):
    mcp = build_server(core, packages=False)
    await mcp.call_tool("partner_act", {"helper": "h1", "key": KEY, "do": "get_items",
                                        "args": TAKE_LINES, "owner_ok": True})
    assert "owner_ok" not in last(fake, "act") and "owner_ok" not in last(fake, "act")["args"]


async def test_leave_for_another_order_is_refused(core, fake, body):
    o, q = await leave(core, fake)
    other = await small_order(core, fake, "принеси угля")
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=other["id"]))
    assert e.code == "bad_args" and f"не про поручение {other['id']}" in e.text


async def test_unanswered_question_is_no_leave(core, fake, body):
    o = await small_order(core, fake)
    q = await pilot_asks(core, o["id"])
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"]))
    assert e.code == "bad_args" and "ещё не ответил" in e.text


async def test_the_owners_no_is_no_leave(core, fake, body):
    o, q = await leave(core, fake, "нет, не трогай")
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"]))
    assert "не явное «да»" in e.text


async def test_unknown_order_question_or_half_a_leave_is_refused(core, fake, body):
    o, q = await leave(core, fake)
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order="o999"))
    assert "нет поручения o999" in e.text
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved="q99", order=o["id"]))
    assert "нет вопроса q99" in e.text
    assert (await refused(core.op_act("h1", KEY, "walk", {"to": "player"}, approved=q["id"]))).code == "bad_args"
    assert (await refused(core.op_act("h1", KEY, "walk", {"to": "player"}, order=o["id"]))).code == "bad_args"
    assert (await refused(core.op_act("h1", KEY, "walk", {"to": "player"}, approved="x", order=o["id"]))).code \
        == "bad_args"


async def test_stale_leave_is_refused(core, fake, body, monkeypatch):
    o, q = await leave(core, fake)
    t = L.now()
    monkeypatch.setattr(L, "now", lambda: t + L.APPROVED_MAX_AGE + 1)
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"]))
    assert "старше" in e.text


async def test_another_bodys_question_is_no_leave(core, fake, body):
    o, q = await leave(core, fake)
    # the pilot of h2 cannot use h1's question (it is not in its scope, nor is the order its own)
    e = await refused(core.op_act("h2", "p" * 40, "get_items", TAKE_LINES, approved=q["id"], order=o["id"]))
    assert e.code == "bad_args"


async def test_pilot_question_reaches_the_voice_and_its_answer_the_pilot(core, fake, body):
    await core.op_wait("h1", KEY, timeout=0)
    o = await small_order(core, fake)
    q = await pilot_asks(core, o["id"])
    assert q["from"] == "pilot"
    w = await core.op_wait("h1", VKEY, timeout=0)
    ev = [e for e in w["events"] if e["kind"] == "strategist_question"][-1]
    assert ev["data"]["from"] == "pilot" and ev["data"]["helper"] == "h1"
    work = (await core.op_brief("h1", VKEY))["work"]
    assert [x["id"] for x in work["questions"]] == [q["id"]] and work["questions"][0]["from"] == "pilot"
    ans = await owner_answers(core, fake, q["id"])
    inbox = await core.op_inbox("h1", KEY)
    assert ans["id"] in [x["id"] for x in inbox["orders"]]
    assert L.questions_of(core.ledger().data(), "h1")[0]["status"] == "answered"


async def test_leave_names_its_permissions_and_the_voice_hears_them(core, fake, body):
    await core.op_wait("h1", KEY, timeout=0)
    o = await small_order(core, fake)
    q = await pilot_asks(core, o["id"], perm=["take_lines", "take_lines"])
    assert q["perm"] == ["take_lines"]
    assert q["text"].endswith("(разрешение: " + S.label("take_lines") + ")")
    w = await core.op_wait("h1", VKEY, timeout=0)
    ev = [e for e in w["events"] if e["kind"] == "strategist_question"][-1]
    assert ev["data"]["perm"] == ["take_lines"] and S.label("take_lines") in ev["data"]["text"]


@pytest.mark.parametrize("perm", ["fly", [], ["a", "b", "c", "d", "e"], [3], {"k": "take_lines"}])
async def test_ask_with_a_bad_perm_is_refused(core, fake, body, perm):
    o = await small_order(core, fake)
    e = await refused(core.op_ledger("h1", KEY, "ask", text="можно?", order=o["id"], perm=perm))
    assert e.code == "bad_args" and "perm" in e.text
    assert not L.questions_of(core.ledger().data(), "h1")


async def test_perm_goes_only_with_ask(core, fake, body):
    e = await refused(core.op_ledger("h1", SKEY, "note", text="иду", perm="take_lines"))
    assert e.code == "bad_args" and "perm" in e.text


async def test_question_without_perm_gives_no_leave_to_a_call(core, fake, body):
    o, q = await leave(core, fake, perm=None)
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"]))
    assert e.code == "bad_args" and "не называет, что разрешить" in e.text


async def test_leave_is_used_up_after_a_few_calls(core, fake, body):
    o, q = await leave(core, fake)
    for _ in range(L.CALL_LEAVE_USES):
        await core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"])
    n = len(fake.mod.requests)
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"]))
    assert e.code == "bad_args" and "уже использовано" in e.text
    assert not [r for r in fake.mod.requests[n:] if r.get("op") == "act"]


async def test_a_refused_call_does_not_spend_the_leave(core, fake, body):
    o, q = await leave(core, fake)
    for _ in range(2):
        await refused(core.op_act("h1", KEY, "get_items", {"items": {"iron-plate": 0}}, approved=q["id"],
                                  order=o["id"]))
    for _ in range(L.CALL_LEAVE_USES):
        await core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"])


# ---------------------------------------------------------------- packages

async def test_package_with_a_denied_step_is_refused_at_put(core, fake, body):
    mod_settings(fake, perms={"build": "deny"})
    e = await refused(core.op_ledger("h1", SKEY, "put", {
        "name": "печи", "anchor": {"x": 0, "y": 0},
        "steps": [{"do": "walk", "args": {"to": {"x": 1, "y": 1}}},
                  {"do": "place", "args": {"item": "stone-furnace", "pos": {"x": 1, "y": 1}}}],
        "verify": [{"kind": "ghosts", "at_most": 0}]}))
    assert e.code == "owner_forbids" and e.text.startswith("steps[2] (place): запрещено в настройках мода")
    assert e.detail == {"perm": "build"}


async def test_approved_package_runs_with_owner_ok(core, fake, body):
    await core.op_brief("h1", SKEY)
    await core.op_brief("h1", VKEY)
    ev = owner_said(fake, "принеси 60 схем")
    o = (await core.op_order("h1", VKEY, ev["seq"], "принеси 60 схем", "large", to="h1"))["order"]
    q = (await core.op_ledger("h1", SKEY, "ask", text="можно из сундука?", order=o["id"]))["question"]
    yes = owner_said(fake, "да")
    await core.op_order("h1", VKEY, yes["seq"], "да", "large", answer_to=q["id"])
    steps = [{"do": "extract", "args": {"target": CHEST, "items": {"electronic-circuit": 60}}}]
    p = (await core.op_ledger("h1", SKEY, "put", {"name": "схемы", "anchor": {"x": 0, "y": 0}, "steps": steps,
                                                  "verify": [{"kind": "ghosts", "at_most": 0}],
                                                  "order": o["id"], "approved": q["id"]}))["package"]
    await core.op_inbox("h1", SKEY, ack=[o["id"]])
    await core.packages.step()
    assert core.ledger().get("h1", p["id"])["status"] == "running"
    # a question without perm is about taking from the owner: only those keys are lifted
    assert last(fake, "act")["owner_ok"] == ["take_chests", "take_lines"]


async def test_plain_package_runs_without_owner_ok(core, fake, body):
    await core.op_ledger("h1", SKEY, "put", {"name": "иди", "anchor": {"x": 0, "y": 0},
                                             "steps": [{"do": "walk", "args": {"to": {"x": 1, "y": 1}}}],
                                             "verify": [{"kind": "ghosts", "at_most": 0}]})
    await core.packages.step()
    assert "owner_ok" not in last(fake, "act")


async def strategist_leave(core, fake, perm=None):
    await core.op_brief("h1", SKEY)
    await core.op_brief("h1", VKEY)
    ev = owner_said(fake, "принеси 60 схем")
    o = (await core.op_order("h1", VKEY, ev["seq"], "принеси 60 схем", "large", to="h1"))["order"]
    q = (await core.op_ledger("h1", SKEY, "ask", text="можно из сундука?", order=o["id"], perm=perm))["question"]
    yes = owner_said(fake, "да")
    await core.op_order("h1", VKEY, yes["seq"], "да", "large", answer_to=q["id"])
    return o, q


def take_package(o, q):
    return {"name": "схемы", "anchor": {"x": 0, "y": 0},
            "steps": [{"do": "extract", "args": {"target": CHEST, "items": {"electronic-circuit": 60}}}],
            "verify": [{"kind": "ghosts", "at_most": 0}], "order": o["id"], "approved": q["id"]}


async def test_package_leave_lifts_the_keys_of_its_question(core, fake, body):
    o, q = await strategist_leave(core, fake, perm=["take_chests"])
    await core.op_ledger("h1", SKEY, "put", take_package(o, q))
    await core.op_inbox("h1", SKEY, ack=[o["id"]])
    await core.packages.step()
    assert last(fake, "act")["owner_ok"] == ["take_chests"]


async def test_stale_package_leave_is_refused_at_put(core, fake, body, monkeypatch):
    o, q = await strategist_leave(core, fake)
    t = L.now()
    monkeypatch.setattr(L, "now", lambda: t + L.PACKAGE_LEAVE_MAX_AGE + 1)
    e = await refused(core.op_ledger("h1", SKEY, "put", take_package(o, q)))
    assert e.code == "bad_args" and "старше" in e.text


async def test_package_leave_expires_while_it_waits(core, fake, body, monkeypatch):
    o, q = await strategist_leave(core, fake)
    p = (await core.op_ledger("h1", SKEY, "put", take_package(o, q)))["package"]
    await core.op_inbox("h1", SKEY, ack=[o["id"]])
    n = len(fake.mod.requests)
    t = L.now()
    monkeypatch.setattr(L, "now", lambda: t + L.PACKAGE_LEAVE_MAX_AGE + 1)
    await core.packages.step()
    got = core.ledger().get("h1", p["id"])
    assert got["status"] == "failed" and "старше" in got["plan"]["text"]
    assert not [r for r in fake.mod.requests[n:] if r.get("op") == "act"]


# ---------------------------------------------------------------- AUTO, pause, thoughts, budget

async def auto_rule(core, fake):
    own = owner_said(fake, "играй сам")
    return await core.op_notes("h1", KEY, "rules", "add", "AUTO: к ракете", said_seq=own["seq"])


async def test_auto_setting_auto_writes_without_a_question(core, fake, body):
    mod_settings(fake, perms={"auto": "auto"})
    out = await auto_rule(core, fake)
    assert out["auto"] == "written"
    assert savenotes.auto_state("stand")["goal"] == "к ракете"
    assert not [r for r in fake.mod.requests if r.get("op") == "say"]


async def test_auto_setting_deny_refuses(core, fake, body):
    mod_settings(fake, perms={"auto": "deny"})
    e = await refused(auto_rule(core, fake))
    assert e.code == "owner_forbids" and "AUTO запрещён в настройках мода" in e.text
    assert savenotes.auto_state("stand")["on"] is False


async def test_auto_setting_ask_asks_as_before(core, fake, body):
    out = await auto_rule(core, fake)
    assert out["pending"] == "AUTO: к ракете" and savenotes.auto_state("stand")["on"] is False


async def test_voice_pause_precedence(cfg, fake, monkeypatch):
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module="tests_no_such_forge_module")
    assert c.chat_settle == 2.5
    mod_settings(fake, agents={"voice_pause": 1.5})
    await c.settings()
    assert c.chat_settle == 1.5
    await c.close()
    monkeypatch.setenv("FP_CHAT_SETTLE", "0.5")
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module="tests_no_such_forge_module")
    await c.settings()
    assert c.chat_settle == 0.5
    await c.close()


async def test_thoughts_default_from_settings_unless_the_owner_switched(core, fake, body):
    mod_settings(fake, agents={"thoughts": True})
    assert (await core.op_brief("h1", VKEY))["work"]["thoughts"] == "on"
    ev = owner_said(fake, "хватит мыслей")
    await core.op_ledger("h1", VKEY, "thoughts", on=False, said_seq=ev["seq"])
    assert (await core.op_brief("h1", VKEY))["work"]["thoughts"] == "off"
    assert L.thoughts_on({"thoughts": {"*": False}}, "*", True) is False
    assert L.thoughts_on({}, "*", True) is True


def test_budget_thresholds_from_settings_unless_env():
    b = B.Budget.from_env({})
    assert b.apply_settings({"strategist": 50, "voice_only": 60, "weekly": 95})
    assert (b.warn, b.stop, b.week_stop) == (50, 60, 95)
    assert not b.apply_settings({"strategist": 90, "voice_only": 60})      # warn ≥ stop: nothing changes
    assert (b.warn, b.stop) == (50, 60)
    b = B.Budget.from_env({"FP_BUDGET_WARN": "40"})
    b.apply_settings({"strategist": 50, "voice_only": 60})
    assert (b.warn, b.stop) == (40, 60)


async def test_core_applies_budget_settings(core, fake):
    mod_settings(fake, agents={"budget": {"strategist": 55, "voice_only": 75, "weekly": 80}})
    await core.settings()
    assert (core.budget.warn, core.budget.stop, core.budget.week_stop) == (55, 75, 80)


# ---------------------------------------------------------------- the owner's window

def panel(fake, **data):
    return fake.mod.emit("owner_panel", data, helper=None)


async def test_panel_thoughts_auto_scale_and_combat(core, fake, body):
    await core.op_brief("h1", VKEY)
    panel(fake, action="thoughts", on=True)
    panel(fake, action="auto", on=True, goal="развивай науку")
    panel(fake, action="combat", on=True)
    panel(fake, action="scale", n=3)
    await core.panel_poll()
    d = core.ledger().data()
    assert L.thoughts_on(d, R.SHARED) and L.thoughts_on(d, "h1") and L.thoughts_on(d, "h2")
    assert savenotes.auto_state("stand")["goal"] == "развивай науку"
    assert L.rescale_of(d)["n"] == 3 and L.rescale_of(d)["from"] == "panel"
    b = await core.op_brief("h1", VKEY)
    assert b["rescale"] == {"n": 3, "tasks": []}
    assert [p["action"] for p in b["work"]["panel"]] == ["thoughts", "auto", "combat", "scale"]
    panel(fake, action="auto", on=False)
    await core.panel_poll()
    assert savenotes.auto_state("stand")["on"] is False


async def test_panel_auto_respects_deny(core, fake, body):
    mod_settings(fake, perms={"auto": "deny"})
    await core.op_brief("h1", VKEY)
    panel(fake, action="auto", on=True)
    await core.panel_poll()
    assert savenotes.auto_state("stand")["on"] is False
    assert core._panel_log[-1]["refused"] == "owner_forbids"


async def test_panel_ignores_malformed_helper_and_repeated_events(core, fake, body):
    await core.op_brief("h1", VKEY)
    panel(fake, action="scale", n="many")
    panel(fake, action="explode")
    fake.mod.emit("owner_panel", {"action": "scale", "n": 4}, helper="h1")    # not from the owner's window
    await core.panel_poll()
    assert L.rescale_of(core.ledger().data()) is None
    ev = panel(fake, action="scale", n=2)
    await core.panel_poll()
    core.ledger().mutate(L.clear_rescale)
    core._on_panel(ev)                                          # the same event seen again by a wait
    assert L.rescale_of(core.ledger().data()) is None


async def test_panel_event_seen_by_a_wait_is_applied(core, fake, body):
    await core.op_wait("h1", KEY, timeout=0)
    panel(fake, action="scale", n=2)
    w = await core.op_wait("h1", VKEY, timeout=0)
    assert any(e["kind"] == "owner_panel" for e in w["events"])
    assert L.rescale_of(core.ledger().data())["n"] == 2


def test_panel_event_schema():
    assert V.panel_event({"action": "scale", "n": 9}) == {"action": "scale", "n": 5}
    assert V.panel_event({"action": "auto", "on": True, "goal": "«к ракете»"})["goal"] == '"к ракете"'
    assert V.panel_event({"action": "thoughts", "on": "yes"}) is None
    assert V.panel_event({"action": "hold"}) == {"action": "hold"}


# ---------------------------------------------------------------- «запусти N» from the game chat

async def test_voice_scale_on_a_fresh_owner_message(core, fake, body):
    await core.op_wait("h1", KEY, timeout=0)
    ev = owner_said(fake, "добавь двух: один на руду, другой на печи")
    out = await core.op_ledger("h1", VKEY, "scale", n=3, tasks=[{"to": "h2", "text": "руда"}, {"text": "печи"}],
                               said_seq=ev["seq"])
    assert out["rescale"] == {"n": 3, "tasks": [{"text": "руда", "to": "h2"}, {"text": "печи"}], "from": "chat"}
    for key in (KEY, VKEY, SKEY):
        assert (await core.op_brief("h1", key))["rescale"]["n"] == 3
    w = await core.op_wait("h1", KEY, timeout=0)
    assert any(e["kind"] == "rescale" for e in w["events"])
    # the dispatcher sees the owner's own words next to the voice's n and tasks
    got = await core.op_rescale("h1", HKEY, "get")
    assert got["rescale"]["owner_said"] == "добавь двух: один на руду, другой на печи"
    # one message — one restart
    e = await refused(core.op_ledger("h1", VKEY, "scale", n=2, said_seq=ev["seq"]))
    assert e.code == "bad_args" and "already" in e.text


async def test_owner_message_from_before_the_start_is_not_scale(core, fake, body):
    ev = owner_said(fake, "запусти двух")            # said before the server started
    assert (await refused(core.op_ledger("h1", VKEY, "scale", n=2, said_seq=ev["seq"]))).code == "bad_args"


async def test_voice_scale_without_the_owners_message_is_refused(core, fake, body):
    await core.op_wait("h1", KEY, timeout=0)
    e = await refused(core.op_ledger("h1", VKEY, "scale", n=2))
    assert e.code == "bad_args" and "said_seq" in e.text
    other = fake.mod.emit("player_said", {"player": "Other", "owner": False, "text": "запусти пять"}, helper=None)
    assert (await refused(core.op_ledger("h1", VKEY, "scale", n=5, said_seq=other["seq"]))).code == "bad_args"
    # a message of the owner about something else is no request to restart
    chat = owner_said(fake, "как дела?")
    e = await refused(core.op_ledger("h1", VKEY, "scale", n=5, said_seq=chat["seq"]))
    assert e.code == "bad_args" and "does not ask" in e.text
    old = owner_said(fake, "запусти двух")
    fake.mod.tick += 121 * 60
    e = await refused(core.op_ledger("h1", VKEY, "scale", n=2, said_seq=old["seq"]))
    assert e.code == "bad_args" and "2 minutes" in e.text
    assert L.rescale_of(core.ledger().data()) is None


async def test_scale_is_clamped_and_voice_only(core, fake, body):
    await core.op_wait("h1", KEY, timeout=0)
    ev = owner_said(fake, "запусти десять")
    out = await core.op_ledger("h1", VKEY, "scale", n=10, said_seq=ev["seq"])
    assert out["rescale"]["n"] == 5 and out["clamped"] is True
    for key in (KEY, SKEY):
        ev = owner_said(fake, "убери всех")
        assert (await refused(core.op_ledger("h1", key, "scale", n=1, said_seq=ev["seq"]))).code == "not_allowed"
    ev = owner_said(fake, "запусти")
    assert (await refused(core.op_ledger("h1", VKEY, "scale", n="два", said_seq=ev["seq"]))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", VKEY, "list", n=2))).code == "bad_args"


async def test_rescale_is_host_only(core, fake, body):
    await core.op_wait("h1", KEY, timeout=0)
    ev = owner_said(fake, "запусти троих")
    await core.op_ledger("h1", VKEY, "scale", n=3, said_seq=ev["seq"])
    for key in (KEY, VKEY, SKEY):
        assert (await refused(core.op_rescale("h1", key, "get"))).code == "not_allowed"
    got = await core.op_rescale("h1", HKEY, "get")
    assert got["rescale"]["n"] == 3 and got["helpers_now"] == 2
    done = await core.op_rescale("h1", HKEY, "done")
    assert done["done"] is True
    assert (await core.op_rescale("h1", HKEY, "get"))["rescale"] is None
    assert "rescale" not in await core.op_brief("h1", VKEY)
    assert (await refused(core.op_rescale("h1", HKEY, "maybe"))).code == "bad_args"
    # the dispatcher still drives nothing
    assert (await refused(core.op_act("h1", HKEY, "walk", {"to": "player"}))).code == "not_allowed"


async def test_admin_settings_passes_the_mods_answer(core, fake):
    mod_settings(fake, agents={"helpers": 3})
    assert (await core.admin_settings())["data"] == {"agents": {"helpers": 3}}


# ---------------------------------------------------------------- one «да» — one use

async def test_one_yes_gives_leave_to_one_open_package(core, fake, body):
    o, q = await strategist_leave(core, fake, perm=["take_lines"])
    p = (await core.op_ledger("h1", SKEY, "put", take_package(o, q)))["package"]
    e = await refused(core.op_ledger("h1", SKEY, "put", dict(take_package(o, q), name="ещё схемы")))
    assert e.code == "bad_args" and "уже отдано пакету" in e.text
    # the same «да» is no leave for a single call either
    e = await refused(core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"]))
    assert e.code == "bad_args" and "отдано пакету" in e.text
    # once the package is closed the owner's answer may go to its corrected copy
    await core.op_ledger("h1", SKEY, "cancel", id=p["id"])
    await core.op_ledger("h1", SKEY, "put", dict(take_package(o, q), name="схемы, ещё раз"))


async def test_yes_spent_on_calls_gives_no_leave_to_a_package(core, fake, body):
    o, q = await strategist_leave(core, fake, perm=["take_lines"])
    await core.op_act("h1", KEY, "get_items", TAKE_LINES, approved=q["id"], order=o["id"])
    e = await refused(core.op_ledger("h1", SKEY, "put", take_package(o, q)))
    assert e.code == "bad_args" and "отдельных вызовов" in e.text


async def test_package_leave_bound_to_another_package_is_refused_when_it_goes(core, fake, body):
    o, q = await strategist_leave(core, fake, perm=["take_chests"])
    p = (await core.op_ledger("h1", SKEY, "put", take_package(o, q)))["package"]
    # the file is edited by hand: the question now names another package
    scope = core.ledger().get("h1", p["id"])["leave_scope"]
    core.ledger().mutate(lambda d: L.bind_package(d, scope, q["id"], "pk999"))
    await core.op_inbox("h1", SKEY, ack=[o["id"]])
    await core.packages.step()
    assert not [r for r in fake.mod.requests if r.get("op") == "act" and r.get("owner_ok")]
    assert core.ledger().get("h1", p["id"])["status"] != "running"
