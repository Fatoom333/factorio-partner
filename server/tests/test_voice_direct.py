"""Direct ways between the owner and the roles (docs/MCP.md «Поручения», «Пакеты стройки»): one
message of the owner may become an order for several recipients, the voice takes off what the owner
says to forget (``partner_ledger forget``), the strategist and the pilot ask the owner in chat
themselves and take his answer (``ask`` said by the server, ``answer``), and the mod's last module
errors reach the roles in words."""
import json

import pytest

from factorio_partner import ledger as L
from factorio_partner import roles as R
from factorio_partner.errors import PartnerError

from test_ledger import Body

P1, P2 = "1" * 40, "2" * 40
VKEY = "v" * 40
SKEY = "s" * 40
OWN_V, OWN_S = "w" * 40, "t" * 40
CHEST = {"name": "iron-chest", "pos": {"x": 10.5, "y": 20.5}}
TAKE = [{"do": "extract", "args": {"target": CHEST, "items": {"electronic-circuit": 60}}},
        {"do": "insert", "args": {"target": CHEST, "items": {"electronic-circuit": 60}}}]
OLD = 10 * 60 * 60 + 1          # ticks: past the 10 minutes of a message of the owner


@pytest.fixture(autouse=True)
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path / "notes"))
    monkeypatch.setenv("FP_SAVE_NAME", "stand")
    monkeypatch.delenv("FP_HELPER_NAME", raising=False)


def shared_keys(home):
    (home / "helpers.json").write_text(json.dumps({
        "*": {"voice": VKEY, "strategist": SKEY}, "h1": {"pilot": P1}, "h2": {"pilot": P2},
    }), encoding="utf-8")


def own_keys(home):
    (home / "helpers.json").write_text(json.dumps({
        "h1": {"pilot": P1, "voice": OWN_V, "strategist": OWN_S}, "h2": {"pilot": P2},
    }), encoding="utf-8")


@pytest.fixture
def home(home):
    shared_keys(home)
    return home


@pytest.fixture
def body(fake):
    return Body(fake.mod)


async def refused(coro) -> PartnerError:
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


def owner_said(fake, text, **extra):
    return fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": text, **extra},
                         helper=None)["seq"]


def other_said(fake, text):
    return fake.mod.emit("player_said", {"player": "Guest", "owner": False, "text": text}, helper=None)["seq"]


async def register(core, keys=((VKEY, "h1"), (SKEY, "h1"), (P1, "h1"), (P2, "h2"))):
    for k, h in keys:
        await core.op_brief(h, k)


def says(fake, since=0):
    return [r["args"]["text"] for r in fake.mod.requests[since:] if r.get("op") == "say"]


async def events(core, h, key, kind=None):
    evs = (await core.op_wait(h, key, timeout=0))["events"]
    return [e for e in evs if kind is None or e["kind"] == kind]


def pkg(steps=None, **kw):
    p = {"name": "буры", "anchor": {"x": 10, "y": 20},
         "steps": steps or [{"do": "walk", "args": {"to": {"x": 1, "y": 2}}}],
         "verify": [{"kind": "stock", "item": "iron-plate", "at_least": 10}]}
    p.update(kw)
    return p


# ---------------------------------------------------------------- one message, several recipients

async def test_one_message_is_one_order_per_inbox(core, fake, body):
    await register(core)
    seq = owner_said(fake, "забудь про буры, иди ко мне")
    first = await core.op_order("h1", VKEY, seq, "иди ко мне", "small", to="h1")
    assert first["to"]["helper"] == "h1" and "said_for" not in first
    # the same message into the same inbox again: refused, the text names where it went
    e = await refused(core.op_order("h1", VKEY, seq, "иди ко мне", "small", to="h1"))
    assert e.code == "bad_args" and "already an order for h1" in e.text
    # into another inbox: filed, and the answer says where else it went
    second = await core.op_order("h1", VKEY, seq, "подойди тоже", "small", to="h2")
    assert second["to"]["helper"] == "h2" and second["said_for"] == ["h1", "h2"]
    third = await core.op_order("h1", VKEY, seq, "пересобери планы", "large")
    assert third["to"]["role"] == "strategist" and third["said_for"] == ["h1", "h2", "strategist"]
    assert (await refused(core.op_order("h1", VKEY, seq, "ещё раз", "large"))).code == "bad_args"
    assert len(core.orders["h1"]) == len(core.orders["h2"]) == len(core.orders[R.SHARED]) == 1


async def test_own_voice_files_one_order_per_message_into_its_inbox(core, fake, body, home):
    own_keys(home)
    await core.op_brief("h1", OWN_V)
    seq = owner_said(fake, "принеси угля и построй печи")
    await core.op_order("h1", OWN_V, seq, "принести уголь", "small")
    e = await refused(core.op_order("h1", OWN_V, seq, "построить печи", "large"))
    assert e.code == "bad_args" and "already an order for h1" in e.text


async def test_a_failed_filing_does_not_spend_the_inbox(core, fake, body):
    await register(core)
    seq = owner_said(fake, "Claude2, принеси угля")
    assert (await refused(core.op_order("h1", VKEY, seq, "уголь", "small", to="h1"))).code == "bad_args"
    assert (await core.op_order("h1", VKEY, seq, "уголь", "small", to="h2"))["to"]["helper"] == "h2"


# ---------------------------------------------------------------- «забудь»: the voice takes off

async def setup_work(core, fake):
    """An order for the strategist, its package, a task, a question about the order."""
    await register(core)
    seq = owner_said(fake, "поставь буры у червя")
    o = (await core.op_order("h1", VKEY, seq, "буры у червя", "large"))["order"]
    p = (await core.op_ledger("h1", SKEY, "put", pkg(order=o["id"]), ))["package"]
    t = (await core.op_task("h1", SKEY, "give", to="h1", text="дежурь у буров", duty=True,
                            area={"center": {"x": 10, "y": 20}, "radius": 20}))["task"]
    q = (await core.op_ledger("h1", SKEY, "ask", text="ставить ещё два бура?", order=o["id"]))["question"]
    for k, h in ((SKEY, "h1"), (P1, "h1"), (VKEY, "h1")):
        await core.op_wait(h, k, timeout=0)
    return o, p, t, q


async def test_forget_takes_off_package_task_and_question(core, fake, body):
    o, p, t, q = await setup_work(core, fake)
    seq = owner_said(fake, "забудь про буры")
    out = await core.op_ledger("h1", VKEY, "forget", said_seq=seq,
                               what={"package": p["id"], "task": t["id"], "question": q["id"]})
    kinds = sorted((x["kind"], x["id"]) for x in out["forgot"])
    assert kinds == sorted([("package", p["id"]), ("task", t["id"]), ("question", q["id"])])
    assert out["owner_said"] == "забудь про буры" and "skipped" not in out
    d = core.ledger().data()
    assert core.ledger().get("h1", p["id"])["status"] == "cancelled"
    assert L.find_task(d, t["id"], ["h1"])[1]["status"] == "cancelled"
    assert L.find_task(d, t["id"], ["h1"])[1]["by"] == "owner"
    assert L.find_question(d, q["id"], [R.SHARED])[1]["status"] == "withdrawn"
    st = await events(core, "h1", SKEY, "owner_forgot")
    assert len(st) == 1 and st[0]["data"]["owner_said"] == "забудь про буры" and st[0]["loud"] is True
    pi = await events(core, "h1", P1, "owner_forgot")
    assert len(pi) == 1
    assert (await core.op_brief("h1", VKEY))["work"]["questions"] == []


async def test_forget_all_of_an_order(core, fake, body):
    o, p, t, q = await setup_work(core, fake)
    seq = owner_said(fake, "отмени всё про буры")
    out = await core.op_ledger("h1", VKEY, "forget", said_seq=seq, what={"all_of_order": o["id"]})
    got = {(x["kind"], x["id"]) for x in out["forgot"]}
    assert got == {("order", o["id"]), ("package", p["id"]), ("question", q["id"])}
    assert core.orders.get(R.SHARED) == []
    taken = core.orders_taken[R.SHARED][-1]
    assert taken["id"] == o["id"] and taken["forgotten"] is True
    assert (await refused(core.op_ledger("h1", VKEY, "forget", said_seq=owner_said(fake, "и это забудь"),
                                         what={"all_of_order": o["id"]}))).code == "not_found"


async def test_withdrawn_question_gives_no_leave(core, fake, body):
    await register(core)
    seq = owner_said(fake, "принеси схемы")
    o = (await core.op_order("h1", VKEY, seq, "схемы", "large"))["order"]
    q = (await core.op_ledger("h1", SKEY, "ask", text="взять схемы из сундука?", order=o["id"]))["question"]
    await core.op_ledger("h1", VKEY, "forget", said_seq=owner_said(fake, "не надо"), what={"question": q["id"]})
    e = await refused(core.op_ledger("h1", SKEY, "put", pkg(TAKE, order=o["id"], approved=q["id"])))
    assert e.code == "bad_args" and "снял" in e.text
    # nor can the question be answered afterwards, by the voice or by the strategist
    yes = owner_said(fake, "да")
    assert (await refused(core.op_order("h1", VKEY, yes, "да", "large", answer_to=q["id"]))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes))).code == "bad_args"


async def test_forget_and_order_from_one_message(core, fake, body):
    o, p, t, q = await setup_work(core, fake)
    seq = owner_said(fake, "забудь про буры, иди ко мне")
    await core.op_ledger("h1", VKEY, "forget", said_seq=seq, what={"package": p["id"]})
    assert (await core.op_order("h1", VKEY, seq, "иди ко мне", "small", to="h1"))["to"]["helper"] == "h1"


async def test_forget_refusals(core, fake, body):
    o, p, t, q = await setup_work(core, fake)
    what = {"package": p["id"]}
    # only the voice forgets
    seq = owner_said(fake, "забудь")
    for k, h in ((SKEY, "h1"), (P1, "h1")):
        assert (await refused(core.op_ledger(h, k, "forget", said_seq=seq, what=what))).code == "not_allowed"
    # never on words that are not the owner's real message
    assert (await refused(core.op_ledger("h1", VKEY, "forget", said_seq=other_said(fake, "забудь"),
                                         what=what))).code == "bad_args"
    word = owner_said(fake, "стоп", auto_reply=True)
    assert (await refused(core.op_ledger("h1", VKEY, "forget", said_seq=word, what=what))).code == "bad_args"
    old = owner_said(fake, "забудь про буры")
    fake.mod.tick += OLD
    e = await refused(core.op_ledger("h1", VKEY, "forget", said_seq=old, what=what))
    assert e.code == "bad_args" and "10 minutes" in e.text
    assert (await refused(core.op_ledger("h1", VKEY, "forget", said_seq=99999, what=what))).code == "bad_args"
    # bad shapes
    fresh = owner_said(fake, "забудь")
    for bad in (None, {}, {"plan": "pk1"}, {"package": "PK 1"}, {"task": "q1"}, {"order": ["o1"] * 6}):
        assert (await refused(core.op_ledger("h1", VKEY, "forget", said_seq=fresh, what=bad))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", VKEY, "forget", what=what))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", VKEY, "forget", said_seq=fresh, what=what,
                                         text="x"))).code == "bad_args"
    # all or nothing: one unknown id leaves everything as it was
    e = await refused(core.op_ledger("h1", VKEY, "forget", said_seq=fresh,
                                     what={"package": p["id"], "task": "t99"}))
    assert e.code == "not_found"
    assert core.ledger().get("h1", p["id"])["status"] == "queued"
    # the message may still be used (nothing was taken off), then once only
    await core.op_ledger("h1", VKEY, "forget", said_seq=fresh, what=what)
    e = await refused(core.op_ledger("h1", VKEY, "forget", said_seq=fresh, what={"task": t["id"]}))
    assert e.code == "bad_args" and "already used" in e.text
    assert L.find_task(core.ledger().data(), t["id"], ["h1"])[1]["status"] == "open"


async def test_forget_never_takes_what_came_after_the_message(core, fake, body):
    await register(core)
    seq = owner_said(fake, "забудь про печи")
    fake.mod.tick += 100
    await core.op_state("h1", SKEY)             # the server sees the later tick
    p = (await core.op_ledger("h1", SKEY, "put", pkg()))["package"]
    e = await refused(core.op_ledger("h1", VKEY, "forget", said_seq=seq, what={"package": p["id"]}))
    assert e.code == "bad_args" and "after the owner's message" in e.text
    assert core.ledger().get("h1", p["id"])["status"] == "queued"


async def test_own_voice_forgets_only_its_body(core, fake, body, home):
    own_keys(home)
    await core.op_brief("h1", OWN_V)
    await core.op_brief("h1", OWN_S)
    p2 = (await core.op_ledger("h2", P2, "ask", text="можно взять уголь?"))["question"]
    seq = owner_said(fake, "забудь")
    e = await refused(core.op_ledger("h1", OWN_V, "forget", said_seq=seq, what={"question": p2["id"]}))
    assert e.code == "not_found"


# ---------------------------------------------------------------- the server asks in chat itself

async def test_strategist_question_is_said_in_chat_by_the_server(core, fake, body):
    await register(core)
    n = len(fake.mod.requests)
    out = await core.op_ledger("h1", SKEY, "ask", text="ставить печи [item=iron-plate] у [gps=10,20] "
                                                       "[color=red]шины[/color]?")
    assert out["in_chat"] is True
    assert says(fake, n) == ["ставить печи у [gps=10,20] шины?"]
    assert [r["args"].get("as") for r in fake.mod.requests[n:] if r.get("op") == "say"] == ["Стратег"]
    q = out["question"]
    assert L.find_question(core.ledger().data(), q["id"], [R.SHARED])[1]["in_chat"] is True
    ev = await events(core, "h1", VKEY, "strategist_question")
    assert len(ev) == 1 and ev[0]["loud"] is False and ev[0]["data"]["in_chat"] is True


async def test_quiet_question_does_not_wake_the_voice(core, fake, body):
    await register(core)
    await core.op_ledger("h1", SKEY, "ask", text="какой ширины шина?")
    clock = {"t": 0.0}
    core.clock = lambda: clock["t"]

    async def sleep(s):
        clock["t"] += s
    core.sleep = sleep
    out = await core.op_wait("h1", VKEY, timeout=5)
    assert out["timed_out"] is True                     # nothing woke it before the timeout
    assert [e["kind"] for e in out["events"]] == ["strategist_question"]


async def test_pilot_question_is_said_under_its_body(core, fake, body):
    await register(core)
    n = len(fake.mod.requests)
    out = await core.op_ledger("h2", P2, "ask", text="можно взять уголь из сундука?", perm=["take_chests"])
    assert out["in_chat"] is True
    said = [r for r in fake.mod.requests[n:] if r.get("op") == "say"]
    assert len(said) == 1 and said[0]["helper"] == "h2"
    assert said[0]["args"]["text"].startswith("можно взять уголь из сундука?")
    assert not said[0]["args"]["text"].startswith("Стратег")


async def test_failed_chat_wakes_the_voice_to_ask(core, fake, body):
    await register(core)

    def down(a, e):
        from fake_rcon import FakeModError
        raise FakeModError("internal", "boom")
    fake.mod.handlers["say"] = down
    out = await core.op_ledger("h1", SKEY, "ask", text="ставить печи?")
    assert out["in_chat"] is False and out["question"]["status"] == "open"
    ev = await events(core, "h1", VKEY, "strategist_question")
    assert ev and ev[0]["loud"] is True and ev[0]["data"]["in_chat"] is False


async def test_no_question_in_chat_while_a_rule_waits(core, fake, body):
    await register(core)
    seq = owner_said(fake, "запомни: мусор в бак")
    await core.op_notes("h1", VKEY, "rules", "add", "мусор — в бак", said_seq=seq)
    n = len(fake.mod.requests)
    e = await refused(core.op_ledger("h1", SKEY, "ask", text="ставить печи?"))
    assert e.code == "bad_args" and "rule" in e.text
    assert says(fake, n) == [] and L.open_questions(core.ledger().data(), R.SHARED) == []


async def test_strategist_hears_the_owner_only_while_it_asks(core, fake, body):
    await register(core)
    owner_said(fake, "привет")
    assert await events(core, "h1", SKEY, "player_said") == []
    q = (await core.op_ledger("h1", SKEY, "ask", text="ставить печи?"))["question"]
    other_said(fake, "да")
    seq = owner_said(fake, "да, ставь")
    got = await events(core, "h1", SKEY, "player_said")
    assert [e["seq"] for e in got] == [seq]               # the owner's, not the guest's
    await core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=seq)
    owner_said(fake, "ещё что-то")
    assert await events(core, "h1", SKEY, "player_said") == []


async def test_pilot_question_does_not_open_the_chat_to_the_strategist(core, fake, body):
    await register(core)
    await core.op_ledger("h1", P1, "ask", text="можно взять уголь?")
    owner_said(fake, "да")
    # the own strategist of h1 is not asking: no player_said for it (shared: scope "*")
    assert await events(core, "h1", SKEY, "player_said") == []


# ---------------------------------------------------------------- the asker takes the answer

async def test_strategist_answers_its_question_and_the_yes_gives_leave(core, fake, body):
    await register(core)
    seq = owner_said(fake, "принеси схемы")
    o = (await core.op_order("h1", VKEY, seq, "схемы", "large"))["order"]
    q = (await core.op_ledger("h1", SKEY, "ask", text="взять схемы из сундука?", order=o["id"]))["question"]
    yes = owner_said(fake, "да, бери")
    out = await core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes)
    assert out["question"]["status"] == "answered" and out["question"]["said"] == "да, бери"
    assert out["question"]["answered_by"] == "strategist" and out["owner_said"] == "да, бери"
    p = (await core.op_ledger("h1", SKEY, "put", pkg(TAKE, order=o["id"], approved=q["id"])))["package"]
    assert p["approved"] == q["id"]
    # one «да» — one package
    e = await refused(core.op_ledger("h1", SKEY, "put", pkg(TAKE, order=o["id"], approved=q["id"])))
    assert e.code == "bad_args"
    seen = await events(core, "h1", VKEY, "question_answered")
    assert seen and seen[0]["loud"] is False and seen[0]["data"]["id"] == q["id"]
    # the voice comes second: «already answered»
    again = owner_said(fake, "да")
    e = await refused(core.op_order("h1", VKEY, again, "да", "large", answer_to=q["id"]))
    assert e.code == "bad_args" and "already answered" in e.text


async def test_a_no_answer_gives_no_leave(core, fake, body):
    await register(core)
    o = (await core.op_order("h1", VKEY, owner_said(fake, "схемы"), "схемы", "large"))["order"]
    q = (await core.op_ledger("h1", SKEY, "ask", text="взять из сундука?", order=o["id"]))["question"]
    await core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=owner_said(fake, "нет, не бери"))
    e = await refused(core.op_ledger("h1", SKEY, "put", pkg(TAKE, order=o["id"], approved=q["id"])))
    assert e.code == "bad_args" and "не явное «да»" in e.text


async def test_answer_refusals(core, fake, body):
    await register(core)
    before = owner_said(fake, "да")
    sq = (await core.op_ledger("h1", SKEY, "ask", text="ставить печи?"))["question"]
    pq = (await core.op_ledger("h1", P1, "ask", text="можно взять уголь?"))["question"]
    yes = owner_said(fake, "да")
    # the voice cannot answer for the strategist, with its words or with the owner's
    assert (await refused(core.op_ledger("h1", VKEY, "answer", id=sq["id"], said_seq=yes))).code == "not_allowed"
    assert (await refused(core.op_ledger("h1", VKEY, "answer", id=sq["id"], text="да"))).code == "not_allowed"
    # nor answer a question with words that are not the owner's real message
    guest = other_said(fake, "да")
    assert (await refused(core.op_order("h1", VKEY, guest, "да", "large", answer_to=sq["id"]))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", SKEY, "answer", id=sq["id"], said_seq=guest))).code == "bad_args"
    # the pilot cannot answer the strategist's question, the strategist not the pilot's
    assert (await refused(core.op_ledger("h1", P1, "answer", id=sq["id"], said_seq=yes))).code == "not_found"
    assert (await refused(core.op_ledger("h1", SKEY, "answer", id=pq["id"], said_seq=yes))).code == "not_found"
    # nor the pilot of another body
    assert (await refused(core.op_ledger("h2", P2, "answer", id=pq["id"], said_seq=yes))).code == "not_found"
    # a message from before the question, a word the mod answered, an old message
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=sq["id"], said_seq=before))
    assert e.code == "bad_args" and "before question" in e.text
    word = owner_said(fake, "да", auto_reply=True)
    assert (await refused(core.op_ledger("h1", SKEY, "answer", id=sq["id"], said_seq=word))).code == "bad_args"
    # shapes
    for kw in ({"id": sq["id"]}, {"said_seq": yes}, {"id": "pk1", "said_seq": yes},
               {"id": sq["id"], "said_seq": yes, "order": "o1"}):
        assert (await refused(core.op_ledger("h1", SKEY, "answer", **kw))).code == "bad_args"
    # one message answers one question
    await core.op_ledger("h1", SKEY, "answer", id=sq["id"], said_seq=yes)
    e = await refused(core.op_ledger("h1", P1, "answer", id=pq["id"], said_seq=yes))
    assert e.code == "bad_args" and "one message answers one question" in e.text
    # and a question answered twice is refused
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=sq["id"], said_seq=owner_said(fake, "да")))
    assert e.code == "bad_args" and "already answered" in e.text
    await core.op_ledger("h1", P1, "answer", id=pq["id"], said_seq=owner_said(fake, "да"))


async def test_the_owners_yes_to_a_rule_answers_no_question(core, fake, body):
    await register(core)
    q = (await core.op_ledger("h1", SKEY, "ask", text="взять схемы из сундука?"))["question"]
    await core.op_notes("h1", VKEY, "rules", "add", "мусор — в бак", said_seq=owner_said(fake, "запомни правило"))
    yes = owner_said(fake, "да")
    # while the rule question waits, nobody answers a question with the owner's messages
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes))
    assert e.code == "bad_args" and "rule" in e.text
    await core.op_notes("h1", VKEY, "rules", "confirm", said_seq=yes)
    # his «да» went to the rule: it answers no question afterwards
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes))
    assert e.code == "bad_args" and "rule" in e.text
    assert (await refused(core.op_order("h1", VKEY, yes, "да", "large", answer_to=q["id"]))).code == "bad_args"
    assert L.open_questions(core.ledger().data(), R.SHARED)[0]["id"] == q["id"]


async def test_old_message_does_not_answer(core, fake, body):
    await register(core)
    q = (await core.op_ledger("h1", SKEY, "ask", text="ставить печи?"))["question"]
    yes = owner_said(fake, "да")
    fake.mod.tick += OLD
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes))
    assert e.code == "bad_args" and "10 minutes" in e.text
    assert L.open_questions(core.ledger().data(), R.SHARED)[0]["id"] == q["id"]


async def test_answer_and_forget_are_role_capabilities():
    for act, ok in (("answer", {R.PILOT, R.STRATEGIST}), ("forget", {R.VOICE})):
        for role in R.ROLES:
            assert R.allowed(role, "partner_ledger", {"action": act}) == (role in ok)
        assert not R.allowed(R.HOST, "partner_ledger", {"action": act})


# ---------------------------------------------------------------- the mod's last module errors

LAST = [{"where": "reflex ammo", "text": "attempt to index nil\nstack", "tick": 900},
        {"where": "x" * 80, "text": "y" * 300, "tick": 950}, "junk"]


async def test_module_errors_last_in_state_and_brief(core, fake, body):
    fake.mod.handlers["state"] = lambda a, e: {"helper": e.get("helper"), "job": None, "queue": 0,
                                               "body": "character", "module_errors": 2,
                                               "module_errors_last": LAST}
    hello = fake.mod.op_hello

    def hello2(a, e):
        return dict(hello(a, e), module_errors=2, module_errors_last=LAST)
    fake.mod.handlers["hello"] = hello2
    st = await core.op_state("h1", P1)
    rows = st["module_errors_last"]
    assert rows[0] == {"where": "reflex ammo", "text": "attempt to index nil stack", "tick": 900}
    assert len(rows) == 2 and len(rows[1]["where"]) == 60 and len(rows[1]["text"]) == 200
    br = await core.op_brief("h1", VKEY)
    assert br["module_errors"] == 2 and br["module_errors_last"] == rows


async def test_old_mod_without_module_errors_last(core, fake, body):
    st = await core.op_state("h1", P1)
    assert "module_errors_last" not in st
    assert "module_errors_last" not in await core.op_brief("h1", VKEY)


# ---------------------------------------------------------------- an answer is bound to its question

async def leave_question(core, fake, key=SKEY, h="h1", text="брать с линий?"):
    o = (await core.op_order("h1", VKEY, owner_said(fake, "бери схемы"), "схемы", "large"))["order"]
    return o, (await core.op_ledger(h, key, "ask", text=text, order=o["id"], perm=["take_lines"]))["question"]


async def test_a_yes_meant_for_another_question_gives_no_leave(core, fake, body):
    await register(core)
    o, q1 = await leave_question(core, fake)
    q2 = (await core.op_ledger("h1", P1, "ask", text="можно взять уголь?", perm=["take_chests"],
                               order=o["id"]))["question"]
    yes = owner_said(fake, "да")                # said after q2: the owner answers the pilot
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q1["id"], said_seq=yes))
    assert e.code == "bad_args" and "another line" in e.text
    assert L.find_question(core.ledger().data(), q1["id"], [R.SHARED])[1]["status"] == "open"
    out = await core.op_ledger("h1", P1, "answer", id=q2["id"], said_seq=yes)
    assert out["question"]["status"] == "answered"
    e = await refused(core.op_ledger("h1", SKEY, "put", pkg(TAKE, order=o["id"], approved=q1["id"])))
    assert e.code == "bad_args"


async def test_a_leave_question_takes_only_the_first_message_after_it(core, fake, body):
    await register(core)
    o, q = await leave_question(core, fake)
    owner_said(fake, "погоди")
    yes = owner_said(fake, "да")
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes))
    assert e.code == "bad_args" and "first message" in e.text


async def test_the_voices_line_between_unbinds_the_answer(core, fake, body):
    await register(core)
    o, q = await leave_question(core, fake)
    await core.op_say("h1", VKEY, "Тортик, можно я возьму руду из сундука?")
    yes = owner_said(fake, "да")
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes))
    assert e.code == "bad_args" and "another line" in e.text
    # the voice, who heard the whole chat, still decides
    out = await core.op_order("h1", VKEY, yes, "да", "large", answer_to=q["id"])
    assert out["order"]["answer_to"] == q["id"]


async def test_a_reminder_of_another_question_unbinds_the_answer(core, fake, body, monkeypatch):
    await register(core)
    clock = {"t": 1000.0}
    monkeypatch.setattr(L, "now", lambda: clock["t"])
    await core.op_ledger("h1", SKEY, "ask", text="какой ширины шина?")
    clock["t"] += L.REMIND_AFTER - 1
    o, q2 = await leave_question(core, fake)
    clock["t"] += 2
    n = len(fake.mod.requests)
    await core.packages.remind_questions()            # the first question is said again after q2
    assert says(fake, n) == ["Напоминаю: какой ширины шина?"]
    yes = owner_said(fake, "да")
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q2["id"], said_seq=yes))
    assert e.code == "bad_args" and "another line" in e.text


async def test_a_leave_question_not_said_in_chat_is_answered_by_the_voice(core, fake, body):
    await register(core)

    def down(a, e):
        from fake_rcon import FakeModError
        raise FakeModError("internal", "boom")
    fake.mod.handlers["say"] = down
    o, q = await leave_question(core, fake)
    fake.mod.handlers.pop("say")
    yes = owner_said(fake, "да")
    e = await refused(core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=yes))
    assert e.code == "bad_args" and "not said in chat" in e.text
    await core.op_order("h1", VKEY, yes, "да", "large", answer_to=q["id"])


async def test_a_plain_question_still_takes_a_later_message(core, fake, body):
    await register(core)
    q = (await core.op_ledger("h1", SKEY, "ask", text="ставить печи?"))["question"]
    owner_said(fake, "погоди")
    out = await core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=owner_said(fake, "ставь"))
    assert out["question"]["status"] == "answered"


# ---------------------------------------------------------------- «забудь» takes back a given «да»

async def answered_leave(core, fake):
    o, q = await leave_question(core, fake)
    await core.op_ledger("h1", SKEY, "answer", id=q["id"], said_seq=owner_said(fake, "да, бери"))
    return o, q


async def test_forget_all_of_an_order_takes_back_the_owners_yes(core, fake, body):
    await register(core)
    o, q = await answered_leave(core, fake)
    d = core.ledger().data()
    assert L.call_leave_problem(d, [R.SHARED], q["id"], o["id"]) is None
    out = await core.op_ledger("h1", VKEY, "forget", said_seq=owner_said(fake, "забудь, не надо"),
                               what={"all_of_order": o["id"]})
    got = {x["id"]: x for x in out["forgot"]}
    assert got[q["id"]]["kind"] == "question" and got[q["id"]]["revoked"] is True
    d = core.ledger().data()
    qq = L.find_question(d, q["id"], [R.SHARED])[1]
    assert qq["status"] == "withdrawn" and qq["revoked"] is True and qq["said"] == "да, бери"
    assert "снял" in L.call_leave_problem(d, [R.SHARED], q["id"], o["id"])
    e = await refused(core.op_ledger("h1", SKEY, "put", pkg(TAKE, order=o["id"], approved=q["id"])))
    assert e.code == "bad_args" and "снял" in e.text


async def test_forget_names_an_answered_question(core, fake, body):
    await register(core)
    o, q = await answered_leave(core, fake)
    out = await core.op_ledger("h1", VKEY, "forget", said_seq=owner_said(fake, "не бери"),
                               what={"question": q["id"]})
    assert out["forgot"] == [{"kind": "question", "id": q["id"], "helper": None, "revoked": True}]


async def test_forget_never_takes_back_a_yes_said_after_it(core, fake, body):
    await register(core)
    o, q = await leave_question(core, fake)
    no = owner_said(fake, "забудь")
    # the voice is slow: the owner changed his mind and said «да» after the «забудь»
    await core.op_order("h1", VKEY, owner_said(fake, "да, бери"), "да", "large", answer_to=q["id"])
    e = await refused(core.op_ledger("h1", VKEY, "forget", said_seq=no, what={"question": q["id"]}))
    assert e.code == "bad_args" and "after the owner's message" in e.text
    out = await core.op_ledger("h1", VKEY, "forget", said_seq=no, what={"all_of_order": o["id"]})
    assert q["id"] not in {x["id"] for x in out["forgot"]}
    assert L.find_question(core.ledger().data(), q["id"], [R.SHARED])[1]["status"] == "answered"


# ---------------------------------------------------------------- old messages after a load

async def test_rule_remove_wants_a_message_after_the_load(core, fake, body):
    await register(core)
    old = owner_said(fake, "убери правило про бак")
    core._on_reload(5, fake.mod.seq)          # the save is loaded: its event ring comes back
    e = await refused(core.op_notes("h1", VKEY, "rules", "remove", n=1, said_seq=old))
    assert e.code == "bad_args" and "before the server started or the save was loaded" in e.text
    e = await refused(core.op_notes("h1", VKEY, "rules", "add", "мусор — в бак", said_seq=old))
    assert e.code == "bad_args" and "loaded" in e.text


# ---------------------------------------------------------------- one message, one question: every process

async def test_one_message_answers_one_question_across_processes(core, fake, body):
    await register(core)
    q1 = (await core.op_ledger("h1", SKEY, "ask", text="ставить печи?"))["question"]
    q2 = (await core.op_ledger("h1", P1, "ask", text="можно взять уголь?"))["question"]
    yes = owner_said(fake, "да")
    await core.op_ledger("h1", SKEY, "answer", id=q1["id"], said_seq=yes)
    core._answer_used.clear()                 # another server process: its memory never saw it
    e = await refused(core.op_order("h1", VKEY, yes, "да", "small", answer_to=q2["id"]))
    assert e.code == "bad_args" and "one message answers one question" in e.text
    e = await refused(core.op_ledger("h1", P1, "answer", id=q2["id"], said_seq=yes))
    assert e.code == "bad_args" and "one message answers one question" in e.text
    assert L.find_question(core.ledger().data(), q2["id"], ["h1"])[1]["status"] == "open"


def test_ledger_tells_one_message_by_seq_and_tick():
    d = {}
    a = L.ask(d, "h1", "a?", 10)
    b = L.ask(d, "h2", "b?", 10)
    c = L.ask(d, "h2", "c?", 10)
    L.answer(d, "h1", a["id"], None, "да", said_seq=7, said_tick=100)
    with pytest.raises(PartnerError) as ei:
        L.answer(d, "h2", b["id"], None, "да", said_seq=7, said_tick=100)
    assert "one message answers one question" in ei.value.text
    # the same seq in another timeline (a load) with another tick is another message
    assert L.answer(d, "h2", b["id"], None, "да", said_seq=7, said_tick=300)["status"] == "answered"
    L.withdraw(d, "h2", c["id"], "забудь", said_seq=9, said_tick=400)
    e = L.ask(d, "h1", "e?", 10)
    with pytest.raises(PartnerError):
        L.answer(d, "h1", e["id"], None, "да", said_seq=9, said_tick=400)


# ---------------------------------------------------------------- reminders wait for the rule question

async def test_reminder_waits_while_a_rule_question_waits(core, fake, body, monkeypatch):
    await register(core)
    clock = {"t": 1000.0}
    monkeypatch.setattr(L, "now", lambda: clock["t"])
    await core.op_ledger("h1", SKEY, "ask", text="какой ширины шина?")
    await core.op_notes("h1", VKEY, "rules", "add", "мусор — в бак", said_seq=owner_said(fake, "запомни"))
    clock["t"] += L.REMIND_AFTER + 1
    n = len(fake.mod.requests)
    await core.packages.remind_questions()
    assert says(fake, n) == []
    assert not L.open_questions(core.ledger().data(), R.SHARED)[0].get("reminded")
    await core.op_notes("h1", VKEY, "rules", "confirm", said_seq=owner_said(fake, "да"))
    await core.packages.remind_questions()
    assert says(fake, n) == ["Напоминаю: какой ширины шина?"]
