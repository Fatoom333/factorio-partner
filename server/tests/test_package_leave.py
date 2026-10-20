"""Packages that take from the owner only with his leave, the texts of refusals, the step a stopped
package goes on from, the owner's words from the main chat (``partner_relay``, key ``host``) and the
new actions of the mod (docs/MCP.md «Пакеты стройки», «Хозяин через главный чат», ACTIONS.md)."""
import json

import pytest

from factorio_partner import ledger as L
from factorio_partner import roles as R
from factorio_partner import validate as V
from factorio_partner.errors import PartnerError

from conftest import KEY
from test_ledger import Body, plan_done

VKEY = "v" * 40
SKEY = "s" * 40
HKEY = "x" * 40
CHEST = {"name": "iron-chest", "pos": {"x": 10.5, "y": 20.5}}


@pytest.fixture(autouse=True)
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path / "notes"))
    monkeypatch.setenv("FP_SAVE_NAME", "stand")
    monkeypatch.delenv("FP_HELPER_NAME", raising=False)


@pytest.fixture
def home(home):
    (home / "helpers.json").write_text(json.dumps({
        "*": {"voice": VKEY, "strategist": SKEY, "host": HKEY},
        "h1": {"pilot": KEY},
    }), encoding="utf-8")
    return home


@pytest.fixture
def body(fake):
    return Body(fake.mod)


async def refused(coro) -> PartnerError:
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


def owner_said(fake, text):
    return fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": text}, helper=None)


def pkg(steps, **kw):
    p = {"name": "схемы", "anchor": {"x": 10, "y": 20}, "steps": steps,
         "verify": [{"kind": "stock", "item": "electronic-circuit", "at_least": 60}]}
    p.update(kw)
    return p


TAKE = [{"do": "extract", "args": {"target": CHEST, "items": {"electronic-circuit": 60}}},
        {"do": "insert", "args": {"target": CHEST, "items": {"electronic-circuit": 60}}}]


async def put(core, steps, **kw):
    return (await core.op_ledger("h1", SKEY, "put", pkg(steps, **kw)))["package"]


async def big_order(core, fake, text="принеси 60 схем к сборщикам"):
    await core.op_brief("h1", VKEY)
    await core.op_brief("h1", SKEY)
    ev = owner_said(fake, text)
    return (await core.op_order("h1", VKEY, ev["seq"], text, "large"))["order"]


async def answer(core, fake, qid, text="да, бери"):
    ev = owner_said(fake, text)
    return (await core.op_order("h1", VKEY, ev["seq"], text, "large", answer_to=qid))["order"]


async def ask(core, text="можно взять схемы из сундука у печей?", order=None):
    return (await core.op_ledger("h1", SKEY, "ask", text=text, order=order))["question"]


# ---------------------------------------------------------------- texts of refusals

@pytest.mark.parametrize("step,want", [
    ({"do": "walk", "args": {"x": 1, "y": 2}}, 'steps[1] (walk): unknown field "x" — ожидается to:{x,y}'),
    ({"do": "insert", "args": {"target": CHEST, "item": {"iron-plate": 5}}},
     'steps[1] (insert): unknown field "item" — ожидается items:{name:count}'),
    ({"do": "walk", "to": {"x": 1, "y": 2}}, 'steps[1] (walk): field "to" goes inside args'),
    ({"do": "insert", "args": {"target": CHEST}}, "steps[1] (insert): args.items: required"),
    ({"do": "fly", "args": {}}, 'steps[1]: unknown action "fly"; в пакете можно:'),
    ({"do": "deconstruct", "args": {"target": CHEST}}, "steps[1] (deconstruct): не шаг стройки"),
    ({"do": "extract", "args": {"target": CHEST}},
     "steps[1] (extract): забирать из машин и сундуков хозяина пакетом можно только с его разрешения: "
     "order + approved (id отвеченного вопроса)"),
    ({"do": "collect", "args": {"items": {"iron-plate": 5}}}, "steps[1] (collect): забирать из машин"),
    ({"do": "get_items", "args": {"items": {"iron-plate": 5}, "from_lines": True}},
     "steps[1] (get_items): забирать из машин"),
])
def test_step_refusals_name_the_step_and_the_field(step, want):
    with pytest.raises(PartnerError) as ei:
        V.check_package(pkg([step]))
    assert ei.value.code == "bad_args"
    assert ei.value.text.startswith(want), ei.value.text


def test_refusals_carry_an_example_that_passes():
    with pytest.raises(PartnerError) as ei:
        V.check_package(pkg([{"do": "insert", "args": {"target": CHEST, "item": {"iron-plate": 5}}}]))
    example = json.loads(ei.value.text.split("пример: ", 1)[1])
    assert V.check_package(pkg([example]))["steps"][0]["do"] == "insert"
    for do in V.PACKAGE_DO:
        assert V.check_package(pkg([json.loads(V.step_example(do))]))   # every example is a good step


def test_check_and_package_refusals():
    with pytest.raises(PartnerError) as ei:
        V.check_package(pkg(TAKE[1:], verify=[{"kind": "stock", "item": "iron-plate", "at": 5}]))
    assert ei.value.text.startswith('package.verify[1] (stock): unknown field "at" — ожидается at_least:число')
    with pytest.raises(PartnerError) as ei:
        V.check_package(dict(pkg(TAKE[1:]), step=[]))
    assert ei.value.text.startswith('package: unknown field "step" — ожидается steps')
    with pytest.raises(PartnerError) as ei:
        V.check_package(pkg(TAKE, approved="q1"))
    assert "approved: goes with order" in ei.value.text


async def test_put_refusal_reaches_the_strategist_as_text(core):
    e = await refused(core.op_ledger("h1", SKEY, "put", pkg([{"do": "walk", "args": {"x": 3}}])))
    assert e.code == "bad_args" and str(e).startswith('bad_args: steps[1] (walk): unknown field "x"')


# ---------------------------------------------------------------- the owner's leave

async def test_take_without_leave_is_refused(core, fake):
    o = await big_order(core, fake)
    e = await refused(put(core, TAKE, order=o["id"]))
    assert "order + approved" in e.text


async def test_take_with_an_open_or_unknown_question_is_refused(core, fake):
    o = await big_order(core, fake)
    assert "нет вопроса q7" in (await refused(put(core, TAKE, order=o["id"], approved="q7"))).text
    q = await ask(core, order=o["id"])
    assert "ещё не ответил" in (await refused(put(core, TAKE, order=o["id"], approved=q["id"]))).text


async def test_take_with_a_question_of_another_order_is_refused(core, fake):
    first = await big_order(core, fake, "поставь печи")
    q = await ask(core, order=first["id"])
    await answer(core, fake, q["id"])
    second = await big_order(core, fake, "принеси схем")
    e = await refused(put(core, TAKE, order=second["id"], approved=q["id"]))
    assert f"задан про поручение {first['id']}" in e.text


async def test_a_question_asked_before_the_order_is_not_its_leave(core, fake, monkeypatch):
    await core.op_brief("h1", SKEY)
    core.bridge.last_tick = 100
    q = await ask(core)                                  # no order named, asked at tick 100
    await core.op_brief("h1", VKEY)
    await answer(core, fake, q["id"])
    o = await big_order(core, fake)                      # the order comes later
    core.orders[R.SHARED][-1]["tick"] = 500
    e = await refused(put(core, TAKE, order=o["id"], approved=q["id"]))
    assert "не про поручение" in e.text


async def test_the_owners_no_is_no_leave(core, fake):
    o = await big_order(core, fake)
    q = await ask(core, order=o["id"])
    await answer(core, fake, q["id"], "нет, не трогай")
    e = await refused(put(core, TAKE, order=o["id"], approved=q["id"]))
    assert "отказом" in e.text


async def test_answered_leave_is_put_and_sent(core, fake, body):
    o = await big_order(core, fake)
    q = await ask(core, order=o["id"])
    await answer(core, fake, q["id"])
    p = await put(core, TAKE, order=o["id"], approved=q["id"])
    assert p["approved"] == q["id"] and p["leave_scope"] == R.SHARED
    await core.op_inbox("h1", SKEY, ack=[o["id"]])
    await core.packages.step()
    assert len(body.acts) == 1
    _, a = body.acts[0]
    assert [st["do"] for st in a["args"]["steps"]] == ["extract", "insert"]
    assert core.ledger().get("h1", p["id"])["status"] == "running"


async def test_a_question_after_the_order_is_its_leave(core, fake, body):
    o = await big_order(core, fake)
    q = await ask(core)                                   # no order named, asked after it
    await answer(core, fake, q["id"])
    p = await put(core, [{"do": "get_items", "args": {"items": {"electronic-circuit": 60}, "from_lines": True}}],
                  order=o["id"], approved=q["id"])
    assert p["status"] == "queued"


async def test_leave_is_checked_again_when_the_package_goes(core, fake, body):
    o = await big_order(core, fake)
    q = await ask(core, order=o["id"])
    await answer(core, fake, q["id"])
    p = await put(core, TAKE, order=o["id"], approved=q["id"])
    await core.op_inbox("h1", SKEY, ack=[o["id"]])

    def reopen(d):
        for x in L.questions_of(d, R.SHARED):
            x["status"] = "open"
    core.ledger().mutate(reopen)                          # a hand edit of the file
    await core.packages.step()
    assert body.acts == []
    got = core.ledger().get("h1", p["id"])
    assert got["status"] == "failed" and "ещё не ответил" in got["plan"]["text"]


async def test_ask_order_only_with_ask(core):
    assert (await refused(core.op_ledger("h1", SKEY, "note", text="x", order="o1"))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", SKEY, "ask", text="x", order="q1"))).code == "bad_args"


def test_said_no():
    for t in ("нет", "Нет, не надо", "не бери их", "нельзя", "no"):
        assert L.said_no(t)
    for t in ("да", "бери", "конечно, забирай", None):
        assert not L.said_no(t)


# ---------------------------------------------------------------- where a stopped package goes on

STEPS = [{"do": "get_items", "args": {"items": {"electronic-circuit": 30}}},
         {"do": "get_items", "args": {"items": {"electronic-circuit": 30}}},
         {"do": "insert", "args": {"target": CHEST, "items": {"electronic-circuit": 60}}},
         {"do": "walk", "args": {"to": {"x": 1, "y": 1}}}]


def test_restart_step():
    steps = V.check_package(pkg(STEPS))["steps"]
    assert V.restart_step(steps, 3) == 1        # the items of the insert are fetched again
    assert V.restart_step(steps, 4) == 1
    assert V.restart_step(steps, 1) == 1
    walk_first = [{"do": "walk", "args": {"to": {"x": 0, "y": 0}}}] + steps
    assert V.restart_step(walk_first, 4) == 2
    walks = [{"do": "walk", "args": {"to": {"x": i, "y": 0}}} for i in range(4)]
    assert V.restart_step(walks, 3) == 3


async def test_resume_starts_from_the_steps_that_bring_the_items(core, fake, body):
    await core.op_brief("h1", SKEY)
    p = await put(core, STEPS)
    await core.packages.step()
    job = core.ledger().get("h1", p["id"])["job"]
    plan_done(fake, job, status="failed", code="cancelled", marks="ddss", done=2, skipped=2, at=2, steps=4)
    await core.packages.step()
    got = core.ledger().get("h1", p["id"])
    assert got["status"] == "paused" and got["from_step"] == 3
    await core.op_ledger("h1", SKEY, "resume", id=p["id"])
    await core.packages.step()
    _, a = body.acts[1]
    assert "from_step" not in a["args"]        # from the first get_items, not from the insert


async def test_a_new_put_always_starts_from_the_first_step(core, fake, body):
    await core.op_brief("h1", SKEY)
    p = await put(core, STEPS)
    await core.packages.step()
    job = core.ledger().get("h1", p["id"])["job"]
    await core.op_ledger("h1", SKEY, "cancel", id=p["id"])
    plan_done(fake, job, status="failed", code="cancelled", marks="ddss", at=3, steps=4)
    await core.packages.step()
    again = await put(core, STEPS)
    assert again["from_step"] == 1
    await core.packages.step()
    _, a = body.acts[-1]
    assert "from_step" not in a["args"]


# ---------------------------------------------------------------- new actions of the mod

def test_new_actions():
    assert V.check_act("equip", {"item": "modular-armor"}) == {"item": "modular-armor"}
    assert V.check_act("armor_grid", {"put": {"battery-equipment": 1}})
    assert V.check_act("armor_grid", {"take": {"battery-equipment": 1}, "put": {"solar-panel-equipment": 2}})
    assert V.check_act("insert", {"target": "armor", "items": {"battery-equipment": 1}, "auto_supply": True})
    assert V.check_act("get_items", {"items": {"iron-plate": 5}, "from_lines": True})["from_lines"] is True
    assert V.check_act("collect", {"items": {"iron-plate": 5}, "from_lines": False})
    assert V.check_act("pickup", {"corpse": True}) == {"corpse": True}
    for do, args in (("equip", {}), ("armor_grid", {}), ("insert", {"target": "body", "items": {"x": 1}}),
                     ("get_items", {"items": {"x": 1}, "from_lines": 1}), ("pickup", {"corpse": False}),
                     ("pickup", {}), ("pickup", {"corpse": True, "area": {"left_top": {"x": 0, "y": 0},
                                                                         "right_bottom": {"x": 2, "y": 2}}})):
        with pytest.raises(PartnerError) as ei:
            V.check_act(do, args)
        assert ei.value.code == "bad_args", (do, args)


def test_armour_steps_go_in_a_package():
    clean = V.check_package(pkg([{"do": "equip", "args": {"item": "modular-armor"}},
                                 {"do": "armor_grid", "args": {"put": {"solar-panel-equipment": 2}}},
                                 {"do": "insert", "args": {"target": "armor", "items": {"battery-equipment": 1}}}]))
    assert [s["do"] for s in clean["steps"]] == ["equip", "armor_grid", "insert"]
    with pytest.raises(PartnerError):
        V.check_package(pkg([{"do": "pickup", "args": {"corpse": True}}]))


def test_ammo_reflex_bounds():
    ok = [{"type": "ammo", "turret_gap": 16, "behind": 0, "keep_away": 96}]
    assert V.check_reflexes(ok) == ok
    for k, v, code in (("turret_gap", 17, "limit"), ("behind", -1, "bad_args"), ("keep_away", "far", "bad_args")):
        with pytest.raises(PartnerError) as ei:
            V.check_reflexes([{"type": "ammo", k: v}])
        assert ei.value.code == code


# ---------------------------------------------------------------- the owner through the main chat

async def test_host_opens_only_relay(core, fake):
    assert R.allowed(R.HOST, "partner_relay") and not R.allowed(R.HOST, "partner_brief")
    for call in (core.op_brief("h1", HKEY), core.op_state("h1", HKEY), core.op_inbox("h1", HKEY),
                 core.op_act("h1", HKEY, "wait", {"seconds": 1}), core.op_cancel("h1", HKEY, None, True),
                 core.op_ledger("h1", HKEY), core.op_say("h1", HKEY, "привет")):
        assert (await refused(call)).code == R.NOT_ALLOWED


@pytest.mark.parametrize("key", [VKEY, SKEY, KEY])
async def test_roles_cannot_relay(core, key):
    assert (await refused(core.op_relay("h1", key, "pilot", "иди сюда"))).code == R.NOT_ALLOWED


async def test_relay_needs_a_role_and_a_short_text(core):
    assert (await refused(core.op_relay("h1", HKEY, None, "сделай"))).code == "bad_args"
    assert (await refused(core.op_relay("h1", HKEY, "owner", "сделай"))).code == "bad_args"
    assert (await refused(core.op_relay("h1", HKEY, "pilot", "  "))).code == "bad_args"
    assert (await refused(core.op_relay("h1", HKEY, "pilot", "x" * 601))).code == "limit"
    assert (await refused(core.op_relay("h9", HKEY, "pilot", "x"))).code == "access denied"


async def test_relay_to_the_strategist_is_an_order_of_the_owner(core, fake):
    await core.op_brief("h1", VKEY)
    await core.op_brief("h1", SKEY)
    out = await core.op_relay("h1", HKEY, "strategist", "поставь ещё 4 печи у железа")
    o = out["order"]
    assert o["from"] == "host" and o["size"] == "large" and o["owner_said"] == "поставь ещё 4 печи у железа"
    assert "said_seq" not in o
    inbox = (await core.op_inbox("h1", SKEY))["orders"]
    assert [x["id"] for x in inbox] == [o["id"]] and inbox[0]["from"] == "host"
    kinds = [e["kind"] for e in (await core.op_wait("h1", SKEY, timeout=0))["events"]]
    assert "order" in kinds
    evs = (await core.op_wait("h1", VKEY, timeout=0))["events"]
    msg = [e for e in evs if e["kind"] == "host_message"]
    assert msg and msg[0]["data"]["to"] == "strategist" and msg[0]["data"]["order"] == o["id"]
    work = (await core.op_brief("h1", VKEY))["work"]
    assert any(x.get("from") == "host" for x in work["orders"])


async def test_relay_to_the_pilot_and_to_the_voice(core, fake):
    await core.op_brief("h1", VKEY)
    await core.op_brief("h1", KEY)
    o = (await core.op_relay("h1", HKEY, "pilot", "принеси 50 железа"))["order"]
    assert o["size"] == "small"
    assert [x["id"] for x in (await core.op_inbox("h1", KEY))["orders"]] == [o["id"]]
    out = await core.op_relay("h1", HKEY, "voice", "скажи, что я отойду на 5 минут")
    assert "order" not in out
    evs = [e for e in (await core.op_wait("h1", VKEY, timeout=0))["events"] if e["kind"] == "host_message"]
    assert [e["data"]["to"] for e in evs] == ["pilot", "voice"]
    assert all(e["loud"] for e in evs)


def test_host_key_is_not_a_role_key():
    data = {"*": {"voice": VKEY, "host": HKEY}, "h1": {"pilot": KEY}}
    assert R.shared_keys_of(data, 32) == {"voice": VKEY, "host": HKEY}
    assert R.keys_of({"host": HKEY, "pilot": KEY}, 32) == {"pilot": KEY}
    data["*"]["host"] = KEY                     # the same as a pilot's key: opens nothing
    assert "host" not in R.shared_keys_of(data, 32)
