"""One voice and one strategist for several helpers (docs/MCP.md «Роли», «Несколько помощников»):
the shared entry of ``helpers.json``, rights of the keys between the bodies, one cursor over every
helper, the address of ``partner_order``, packages put on a named body and the shared brief."""
import asyncio
import json

import pytest

from factorio_partner import address
from factorio_partner import roles as R
from factorio_partner.errors import PartnerError

P1, P2, P3 = "1" * 40, "2" * 40, "3" * 40
VKEY = "v" * 40
SKEY = "s" * 40
PILOTS = {"h1": P1, "h2": P2, "h3": P3}


@pytest.fixture(autouse=True)
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path / "notes"))
    monkeypatch.setenv("FP_SAVE_NAME", "stand")
    monkeypatch.delenv("FP_HELPER_NAME", raising=False)


def write_keys(home, extra=None):
    data = {"*": {"voice": VKEY, "strategist": SKEY}, **{h: {"pilot": k} for h, k in PILOTS.items()}}
    data.update(extra or {})
    (home / "helpers.json").write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture
def home(home):
    write_keys(home)
    return home


async def refused(coro) -> PartnerError:
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


def owner_said(fake, text):
    return fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": text}, helper=None)


def bodies(fake, jobs=None, queues=None):
    """state per helper: ``jobs`` — helpers with a running job, ``queues`` — helper -> queue length."""
    jobs, queues = set(jobs or ()), dict(queues or {})

    def state(a, e):
        h = e.get("helper")
        return {"helper": h, "body": "character", "module_errors": 0,
                "job": {"job": 9, "do": "mine", "progress": [1, 5]} if h in jobs else None,
                "queue": queues.get(h, 0)}
    fake.mod.handlers["state"] = state


async def register(core):
    await core.op_state("h1", VKEY)
    await core.op_state("h1", SKEY)
    for h, k in PILOTS.items():
        await core.op_state(h, k)


# ---------------------------------------------------------------- keys between the bodies

async def test_shared_keys_open_their_role_for_every_helper(core, fake):
    for h in PILOTS:
        assert (await core.op_brief(h, VKEY))["role"] == "voice"
        assert (await core.op_brief(h, SKEY))["role"] == "strategist"
        assert (await core.op_brief(h, PILOTS[h]))["role"] == "pilot"


@pytest.mark.parametrize("helper,key", [("h2", P1), ("h3", P1), ("h1", P2), ("h1", P3), ("h2", P3)])
async def test_pilot_of_one_body_cannot_touch_another(core, fake, helper, key):
    for call in (core.op_state(helper, key), core.op_act(helper, key, "wait", {"seconds": 1}),
                 core.op_cancel(helper, key, None, True), core.op_inbox(helper, key)):
        assert (await refused(call)).code == "access denied"
    assert fake.mod.executed["act"] == fake.mod.executed["cancel"] == 0


@pytest.mark.parametrize("helper", ["h1", "h2", "h3"])
async def test_shared_keys_keep_to_their_role(core, fake, helper):
    for call in (core.op_act(helper, VKEY, "wait", {"seconds": 1}), core.op_cancel(helper, VKEY, 5),
                 core.op_hold(helper, VKEY, True, 5), core.op_plan(helper, VKEY),
                 core.op_act(helper, SKEY, "wait", {"seconds": 1}), core.op_say(helper, SKEY, "привет"),
                 core.op_order(helper, SKEY, 1, "x", "small"), core.op_cancel(helper, SKEY, None, True)):
        assert (await refused(call)).code == "not_allowed"
    assert fake.mod.executed["act"] == fake.mod.executed["cancel"] == fake.mod.executed["say"] == 0
    await core.op_say(helper, VKEY, "Понял.")            # the voice speaks for any body
    await core.op_cancel(helper, VKEY, None, True)       # and stops any body on the owner's word


async def test_shared_key_needs_a_helper_of_this_server(core, fake, home):
    for helper in ("h9", "*", "_shared"):
        assert (await refused(core.op_state(helper, VKEY))).code == "access denied"
    # a helper with only role keys of its own (no pilot) is not a body of this server
    write_keys(home, {"h4": {"voice": "x" * 40}})
    assert (await refused(core.op_state("h4", VKEY))).code == "access denied"


@pytest.mark.parametrize("bad", [
    {"*": {"voice": VKEY, "strategist": VKEY}},                    # one key for two roles
    {"*": {"voice": P1, "strategist": SKEY}},                      # the pilot's key of h1
    {"*": {"voice": VKEY, "strategist": SKEY}, "h4": {"pilot": VKEY}},
    {"*": {"voice": "short", "strategist": SKEY}},
])
async def test_shared_key_that_is_not_unique_opens_nothing(core, fake, home, bad):
    write_keys(home, bad)
    data = json.loads((home / "helpers.json").read_text(encoding="utf-8"))
    voice = data["*"]["voice"]
    if voice != P1:
        assert (await refused(core.op_state("h2", voice))).code == "access denied"
    else:   # h1's own pilot key still opens h1 as its pilot, never h2 as a voice
        assert (await core.op_brief("h1", P1))["role"] == "pilot"
        assert (await refused(core.op_state("h2", P1))).code == "access denied"


async def test_a_shared_entry_cannot_carry_a_pilot(core, fake, home):
    write_keys(home, {"*": {"voice": VKEY, "strategist": SKEY, "pilot": "p" * 40}})
    for h in PILOTS:
        assert (await refused(core.op_state(h, "p" * 40))).code == "access denied"
    assert R.shared_keys_of({"*": {"pilot": "p" * 40}}, 32) == {}


# ---------------------------------------------------------------- one cursor for every body

async def test_shared_voice_hears_the_owner_once_with_three_bodies(core, fake):
    await register(core)
    said = owner_said(fake, "что нового?")
    stop = fake.mod.emit("owner_stop", {"kind": "stop", "seq": said["seq"], "helpers": ["h1", "h2", "h3"]},
                         helper=None)
    for h in PILOTS:
        fake.mod.emit("job_done", {"job": 1, "do": "wait"}, helper=h)
    got = []
    for h in ("h1", "h2", "h3", "h1"):        # whichever helper the voice names, the cursor is one
        r = await core.op_wait(h, VKEY, timeout=0)
        got += [(e["seq"], e["kind"]) for e in r["events"]]
    assert got == [(said["seq"], "player_said"), (stop["seq"], "owner_stop")]
    # every pilot still hears the owner on its own cursor
    for h, k in PILOTS.items():
        kinds = [e["kind"] for e in (await core.op_wait(h, k, timeout=0))["events"]]
        assert kinds.count("player_said") == 1 and kinds.count("job_done") == 1


async def test_shared_strategist_sees_the_events_of_every_body(core, fake):
    await register(core)
    d2 = fake.mod.emit("died", {"pos": {"x": 0, "y": 0}}, helper="h2")
    p3 = fake.mod.emit("plan_done", {"job": 4, "do": "plan", "status": "done"}, helper="h3")
    fake.mod.emit("job_done", {"job": 2, "do": "wait"}, helper="h1")       # not the strategist's
    r = await core.op_wait("h1", SKEY, timeout=0)
    assert [(e["seq"], e["helper"]) for e in r["events"]] == [(d2["seq"], "h2"), (p3["seq"], "h3")]
    assert (await core.op_wait("h3", SKEY, timeout=0))["events"] == []


async def test_old_voice_of_one_helper_keeps_its_own_cursor(core, fake, home):
    write_keys(home, {"h1": {"pilot": P1, "voice": "o" * 40}})
    await core.op_state("h1", "o" * 40)
    await core.op_state("h2", VKEY)
    # h1 has a voice of its own: the shared voice does not serve it (no mix of the two)
    assert (await refused(core.op_state("h1", VKEY))).code == "access denied"
    said = owner_said(fake, "привет")
    a = await core.op_wait("h1", "o" * 40, timeout=0)
    b = await core.op_wait("h2", VKEY, timeout=0)
    assert [e["seq"] for e in a["events"]] == [e["seq"] for e in b["events"]] == [said["seq"]]


# ---------------------------------------------------------------- partner_order: who gets it

@pytest.mark.parametrize("text,to", [
    ("Claude2, принеси 50 железа", "h2"), ("принеси 50 железа, claude h3", "h3"),
    ("Claude, принеси 50 железа", "h1"), ("h3 принеси уголь", "h3"), ("CLAUDEH2: принеси уголь", "h2"),
])
async def test_order_goes_to_the_named_helper(core, fake, text, to):
    await register(core)
    said = owner_said(fake, text)
    r = await core.op_order("h1", VKEY, said["seq"], "принести", "small")
    assert r["to"] == {"helper": to, "role": "pilot", "by": "name"} and r["order"]["helper"] == to
    for h, k in PILOTS.items():
        box = (await core.op_inbox(h, k))["orders"]
        assert [o["id"] for o in box] == ([r["order"]["id"]] if h == to else [])
        w = await core.op_wait(h, k, timeout=0)
        assert any(e["kind"] == "order" for e in w["events"]) == (h == to)
    w = await core.op_wait("h1", SKEY, timeout=0)
    ev = [e for e in w["events"] if e["kind"] == "order"]
    assert len(ev) == 1 and ev[0]["helper"] == to and w["inbox"] == 1


async def test_order_without_a_name_goes_to_the_free_body(core, fake):
    await register(core)
    bodies(fake, jobs={"h1"}, queues={"h2": 2})
    r = await core.op_order("h1", VKEY, owner_said(fake, "принеси угля")["seq"], "уголь", "small")
    assert r["to"] == {"helper": "h3", "role": "pilot", "by": "free"}
    bodies(fake, jobs={"h1", "h2", "h3"}, queues={"h1": 3, "h3": 1})
    r = await core.op_order("h3", VKEY, owner_said(fake, "и камня")["seq"], "камень", "small")
    # h2: job 1; h3: job 1 + queue 1 + the order above
    assert r["to"] == {"helper": "h2", "role": "pilot", "by": "least_busy"}


async def test_order_to_the_helper_the_voice_names(core, fake):
    await register(core)
    r = await core.op_order("h1", VKEY, owner_said(fake, "принеси ему угля")["seq"], "уголь", "small", to="h3")
    assert r["to"] == {"helper": "h3", "role": "pilot", "by": "to"}
    e = await refused(core.op_order("h1", VKEY, owner_said(fake, "Claude2, принеси")["seq"], "x", "small",
                                    to="h3"))
    assert e.code == "bad_args" and "h2" in e.text
    e = await refused(core.op_order("h1", VKEY, owner_said(fake, "принеси")["seq"], "x", "small", to="h9"))
    assert e.code == "not_found"


async def test_large_order_without_a_name_goes_to_the_strategist(core, fake):
    await register(core)
    r = await core.op_order("h2", VKEY, owner_said(fake, "построй печи")["seq"], "печи", "large")
    assert r["to"] == {"helper": None, "role": "strategist", "by": "strategist"}
    assert r["order"]["helper"] is None
    for h, k in PILOTS.items():
        assert (await core.op_inbox(h, k))["orders"] == []
        assert all(e["kind"] != "order" for e in (await core.op_wait(h, k, timeout=0))["events"])
    box = (await core.op_inbox("h3", SKEY))["orders"]
    assert [(o["id"], o["helper"]) for o in box] == [(r["order"]["id"], None)]
    w = await core.op_wait("h1", SKEY, timeout=0)
    assert [e["kind"] for e in w["events"]] == ["order"] and w["inbox"] == 1
    # the strategist takes it from whichever helper he names in the call
    assert (await core.op_inbox("h1", SKEY, [r["order"]["id"]]))["acked"] == [r["order"]["id"]]
    assert (await core.op_inbox("h2", SKEY))["orders"] == []


async def test_several_names_in_one_order(core, fake):
    await register(core)
    said = owner_said(fake, "Claude2 Claude3 принесите угля")
    e = await refused(core.op_order("h1", VKEY, said["seq"], "уголь", "small"))
    assert e.code == "bad_args" and "h2, h3" in e.text
    r = await core.op_order("h1", VKEY, said["seq"], "уголь обоим", "large")    # a refusal does not use the seq
    assert r["to"]["role"] == "strategist" and r["order"]["helpers"] == ["h2", "h3"]


async def test_strategist_inbox_sees_every_body(core, fake):
    await register(core)
    a = await core.op_order("h1", VKEY, owner_said(fake, "Claude2, принеси угля")["seq"], "уголь", "small")
    b = await core.op_order("h1", VKEY, owner_said(fake, "Claude3, построй печи")["seq"], "печи", "large")
    box = (await core.op_inbox("h1", SKEY))["orders"]
    assert [(o["id"], o["helper"]) for o in box] == [(a["order"]["id"], "h2"), (b["order"]["id"], "h3")]
    assert b["to"] == {"helper": "h3", "role": "strategist", "by": "name"}
    assert (await core.op_inbox("h1", VKEY))["orders"] == box          # the voice reads the same


def test_address_rules():
    ids = ["h1", "h2", "h3", "h10"]
    assert address.named("Claude2, стоп", ids) == ["h2"]
    assert address.named("стоп, Claude h10!", ids) == ["h10"]
    assert address.named("claude, иди", ids) == ["h1"]
    assert address.named("скажи Claude2 привет", ids) == []        # a name in the middle is not an address
    assert address.named("Claude2", ids) == []                      # a name alone is not an order
    assert address.named("Ёлки, принеси", ids) == []
    assert address.named("Bot2, принеси", ids, base="Bot") == ["h2"]


# ---------------------------------------------------------------- the strategist shares the work

def package(name="печи"):
    return {"name": name, "anchor": {"x": 10, "y": 20},
            "steps": [{"do": "walk", "args": {"to": {"x": 1, "y": 0}}}],
            "verify": [{"kind": "stock", "item": "iron-plate", "at_least": 100}]}


async def test_strategist_puts_packages_on_the_named_body(core, fake):
    await register(core)
    p2 = (await core.op_ledger("h2", SKEY, "put", package("печи")))["package"]
    p3 = (await core.op_ledger("h3", SKEY, "put", package("шахта")))["package"]
    assert p2["helper"] == "h2" and p3["helper"] == "h3"
    listed = await core.op_ledger("h1", SKEY)
    assert {(p["id"], p["helper"]) for p in listed["packages"]} == {(p2["id"], "h2"), (p3["id"], "h3")}
    # a pilot sees and drops only the packages of its own body
    assert [p["id"] for p in (await core.op_ledger("h2", P2))["packages"]] == [p2["id"]]
    assert (await refused(core.op_ledger("h1", P1, "cancel", id=p2["id"]))).code == "not_found"
    assert (await core.op_ledger("h1", SKEY, "list", id=p3["id"]))["package"]["helper"] == "h3"
    # the strategist cancels a package of any body, whichever helper he names in the call
    out = await core.op_ledger("h1", SKEY, "cancel", id=p3["id"])
    assert core.ledger().get("h3", p3["id"])["status"] == "cancelled", out


async def test_questions_and_notes_of_the_shared_strategist_are_shared(core, fake):
    await register(core)
    q = (await core.op_ledger("h2", SKEY, "ask", text="Печи ставить у шины?"))["question"]
    await core.op_ledger("h3", SKEY, "note", text="Делю: h2 — печи, h3 — шахта")
    w = await core.op_wait("h1", VKEY, timeout=0)
    ev = [e for e in w["events"] if e["kind"] == "strategist_question"]
    assert len(ev) == 1 and ev[0]["data"]["id"] == q["id"]
    for h in PILOTS:     # the same note and questions whichever helper the voice names
        work = (await core.op_brief(h, VKEY))["work"]
        assert work["note"]["text"].startswith("Делю") and [x["id"] for x in work["questions"]] == [q["id"]]
    r = await core.op_order("h3", VKEY, owner_said(fake, "да, у шины")["seq"], "у шины", "large",
                            answer_to=q["id"])
    assert r["to"]["by"] == "answer"
    assert (await core.op_ledger("h1", SKEY))["questions"][0]["status"] == "answered"


async def test_shared_thoughts_wake_the_voice_once(core, fake):
    await register(core)
    said = owner_said(fake, "показывай мысли")
    await core.op_ledger("h2", VKEY, "thoughts", on=True, said_seq=said["seq"])
    await core.op_wait("h1", VKEY, timeout=0)
    await core.op_ledger("h3", SKEY, "note", text="Сначала уголь")
    ev = [e for e in (await core.op_wait("h1", VKEY, timeout=0))["events"] if e["kind"] == "strategist_note"]
    assert len(ev) == 1 and ev[0]["data"] == {"text": "Сначала уголь", "helper": None}


# ---------------------------------------------------------------- the brief of every body

async def test_shared_brief_tells_what_each_body_does(core, fake):
    await register(core)
    bodies(fake, jobs={"h2"}, queues={"h3": 1})
    await core.op_order("h1", VKEY, owner_said(fake, "Claude3, принеси угля")["seq"], "уголь", "small")
    await core.op_order("h1", VKEY, owner_said(fake, "построй печи")["seq"], "печи", "large")
    for key in (VKEY, SKEY):
        b = (await core.op_brief("h1", key))["bodies"]
        rows = {r["helper"]: r for r in b["helpers"]}
        assert list(rows) == ["h1", "h2", "h3"]
        assert rows["h1"]["do"] is None and rows["h2"]["do"] == "mine" and rows["h2"]["progress"] == [1, 5]
        assert rows["h3"]["orders"] == 1 and rows["h3"]["queue"] == 1
        assert [o["text"] for o in b["waiting"]] == ["печи"]
    # a pilot gets its own work only
    assert "bodies" not in await core.op_brief("h2", P2)


# ---------------------------------------------------------------- races, held and lost bodies, mixes

def body_gone(fake, gone):
    from fake_rcon import FakeModError
    base = fake.mod.handlers["state"]

    def state(a, e):
        if e.get("helper") == gone:
            raise FakeModError("no_helper", "the body is gone")
        return base(a, e)
    fake.mod.handlers["state"] = state


async def test_one_message_is_one_order_under_parallel_calls(core, fake):
    await register(core)
    bodies(fake)
    seq = owner_said(fake, "принеси угля")["seq"]
    got = await asyncio.gather(*(core.op_order("h1", VKEY, seq, "уголь", "small") for _ in range(3)),
                               return_exceptions=True)
    ok = [r for r in got if isinstance(r, dict)]
    bad = [r for r in got if isinstance(r, PartnerError)]
    assert len(ok) == 1 and len(bad) == 2 and all(e.code == "bad_args" for e in bad)
    total = sum([len((await core.op_inbox(h, k))["orders"]) for h, k in PILOTS.items()])
    assert total == 1


async def test_a_refused_call_gives_the_seq_back(core, fake, monkeypatch):
    await register(core)
    bodies(fake)
    seq = owner_said(fake, "принеси угля")["seq"]
    real = core._order_target
    calls = {"n": 0}

    async def flaky(*a):
        calls["n"] += 1
        if calls["n"] == 1:
            raise PartnerError("not_found", "x")
        return await real(*a)
    monkeypatch.setattr(core, "_order_target", flaky)
    assert (await refused(core.op_order("h1", VKEY, seq, "уголь", "small"))).code == "not_found"
    assert (await core.op_order("h1", VKEY, seq, "уголь", "small"))["order"]["said_seq"] == seq


async def test_free_body_skips_a_held_body_and_one_the_game_lost(core, fake):
    await register(core)
    bodies(fake, queues={"h3": 1})
    body_gone(fake, "h2")
    fake.mod.handlers["owner_hold"] = lambda a, e: {"hold": {"h1": {"kind": "stop", "tick": 1, "seq": 1}}}
    r = await core.op_order("h1", VKEY, owner_said(fake, "принеси угля")["seq"], "уголь", "small")
    assert r["to"] == {"helper": "h3", "role": "pilot", "by": "least_busy"}
    fake.mod.handlers["owner_hold"] = lambda a, e: {"hold": {"h1": {"kind": "stop"}, "h3": {"kind": "come"}}}
    e = await refused(core.op_order("h1", VKEY, owner_said(fake, "и камня")["seq"], "камень", "small"))
    assert e.code == "not_found"


async def test_named_body_the_game_does_not_answer_for_is_refused(core, fake):
    await register(core)
    bodies(fake)
    body_gone(fake, "h2")
    for text, to in (("Claude2, принеси угля", None), ("принеси ему угля", "h2")):
        e = await refused(core.op_order("h1", VKEY, owner_said(fake, text)["seq"], "уголь", "small", to=to))
        assert e.code == "not_found" and "h2" in e.text
    assert all([(await core.op_inbox(h, k))["orders"] == [] for h, k in PILOTS.items()])


@pytest.mark.parametrize("own", [{"voice": "o" * 40}, {"strategist": "t" * 40}])
async def test_shared_keys_do_not_mix_with_own_role_keys(core, fake, home, own):
    write_keys(home, {"h2": {"pilot": P2, **own}})
    for key in (VKEY, SKEY):
        assert (await refused(core.op_state("h2", key))).code == "access denied"
        assert (await core.op_brief("h1", key))["role"] in ("voice", "strategist")
    (role, k), = own.items()
    assert (await core.op_brief("h2", k))["role"] == role
    assert core.helper_ids() == ["h1", "h2", "h3"]


def test_address_cuts_the_name_by_bytes_as_the_mod(monkeypatch):
    long_name = "Помощникдлинный"                   # 15 letters, 30 bytes: the mod keeps 24 bytes
    monkeypatch.setenv("FP_HELPER_NAME", f" [{long_name}] ")
    assert address.base_name() == long_name[:12]
    assert address.named(long_name[:12] + "2, принеси", ["h1", "h2"]) == ["h2"]
    monkeypatch.setenv("FP_HELPER_NAME", "Ж" * 12 + "x")   # 25 bytes: the cut letter is dropped
    assert address.base_name() == "Ж" * 12
    monkeypatch.setenv("FP_HELPER_NAME", "[]")
    assert address.base_name() == "Claude"
    assert address.lower("ÄБЁЙ Z") == "Äбей z"
    assert address.tokens("ΣΑΣ, Привет") == ["ΣΑΣ", "привет"]   # other alphabets keep their case
