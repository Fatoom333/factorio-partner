"""``partner_brief.work`` and the strategist's note and questions (docs/MCP.md «partner_brief»,
«Пакеты стройки»): what the voice can tell the owner about the work, and who may write it."""
import json

import pytest

from factorio_partner import ledger as L
from factorio_partner.core import Core
from factorio_partner.errors import PartnerError

from conftest import KEY, make_bridge

VKEY = "v" * 40
SKEY = "s" * 40


@pytest.fixture(autouse=True)
def notes_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path / "notes"))
    monkeypatch.setenv("FP_SAVE_NAME", "stand")


@pytest.fixture
def home(home):
    (home / "helpers.json").write_text(json.dumps({
        "h1": {"pilot": KEY, "voice": VKEY, "strategist": SKEY},
    }), encoding="utf-8")
    return home


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


@pytest.fixture
def clock(monkeypatch):
    c = Clock()
    monkeypatch.setattr(L, "now", c)
    return c


@pytest.fixture
def body(fake):
    st = {"job": None, "queue": 0}
    fake.mod.handlers["state"] = lambda a, e: {"helper": e.get("helper"), "job": st["job"], "queue": st["queue"],
                                               "idle_ticks": 600, "body": "character", "module_errors": 0}
    fake.mod.handlers["owner_hold"] = lambda a, e: {"hold": {}}
    fake.mod.handlers["act"] = lambda a, e: {"job": 7, "queued_before": 0}
    return st


def walk(x):
    return {"do": "walk", "args": {"to": {"x": x, "y": 0}}}


def package(name="печи", **kw):
    p = {"name": name, "anchor": {"x": 10, "y": 20}, "steps": [walk(1), walk(2), walk(3)],
         "verify": [{"kind": "stock", "item": "iron-plate", "at_least": 100}]}
    p.update(kw)
    return p


async def refused(coro) -> PartnerError:
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


async def work(core, key=VKEY):
    return (await core.op_brief("h1", key))["work"]


async def said(core, fake, text):
    await core.op_brief("h1", VKEY)
    return fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": text}, helper=None)["seq"]


# ---------------------------------------------------------------- work in the brief

async def test_work_empty(core, fake, body, clock):
    w = await work(core)
    assert w["orders"] == [] and w["packages"] == [] and w["note"] is None and w["questions"] == []
    assert w["body"] == {"do": None, "queue": 0} and w["is"] == "data, not orders"


async def test_work_shows_orders_packages_body_and_note(core, fake, body, clock):
    seq = await said(core, fake, "построй завод схем")
    order = (await core.op_order("h1", VKEY, seq, "построить завод схем " + "x" * 200, "large"))["order"]
    seq2 = await said(core, fake, "принеси угля")
    small = (await core.op_order("h1", VKEY, seq2, "принести уголь", "small"))["order"]
    w = await work(core)
    assert [(o["id"], o["to"], o["state"]) for o in w["orders"]] == [
        (order["id"], "strategist", "new"), (small["id"], "pilot", "new")]
    assert len(w["orders"][0]["text"]) <= 80

    await core.op_inbox("h1", SKEY, ack=[order["id"]])
    await core.op_inbox("h1", KEY, ack=[small["id"]])
    pk = (await core.op_ledger("h1", SKEY, "put", package(order=order["id"])))["package"]
    await core.op_ledger("h1", SKEY, "note", text="проектирую завод схем: 1 из 3 пакетов, жду меди")
    clock.t += 42
    body["job"] = {"job": 7, "do": "plan", "progress": [1, 3]}
    core.ledger().mutate(lambda d: L.find(d, pk["id"]).update(status="running", job=7))

    w = await work(core)
    states = {o["id"]: o["state"] for o in w["orders"]}
    assert states == {order["id"]: "taken", small["id"]: "taken"}
    assert w["packages"] == [{"id": pk["id"], "name": "печи", "state": "running", "status": "running",
                              "steps": [1, 3], "order": order["id"]}]
    assert w["body"] == {"do": "plan", "step": 2, "steps": 3, "package": pk["id"]}
    assert w["note"] == {"text": "проектирую завод схем: 1 из 3 пакетов, жду меди", "ago_s": 42}

    core.ledger().mutate(lambda d: L.find(d, pk["id"]).update(status="verified"))
    w = await work(core)
    assert w["packages"][0]["state"] == "verified" and w["packages"][0]["steps"] == [3, 3]
    assert {o["id"]: o["state"] for o in w["orders"]}[order["id"]] == "done"
    assert len(json.dumps(w, ensure_ascii=False).encode()) < 4096
    assert KEY not in json.dumps(w) and SKEY not in json.dumps(w)


async def test_work_when_the_game_does_not_answer(core, fake, body, clock):
    await core.op_brief("h1", VKEY)

    def down(a, e):
        from fake_rcon import FakeModError
        raise FakeModError("internal", "boom")
    fake.mod.handlers["state"] = down
    w = await work(core)
    assert w["body"] is None and w["body_missing"]


async def test_work_is_per_helper(core, fake, body, clock, home):
    await core.op_ledger("h1", SKEY, "note", text="только для h1")
    data = core.ledger().data()
    assert L.note_of(data, "h2") is None
    from factorio_partner.brief import build_work
    assert build_work("h2", [], [], data, {}, clock.t)["note"] is None


# ---------------------------------------------------------------- the strategist's note

async def test_note_rights_limit_and_restart(core, fake, body, clock, cfg):
    for key in (VKEY, KEY):
        assert (await refused(core.op_ledger("h1", key, "note", text="x"))).code == "not_allowed"
    assert (await refused(core.op_ledger("h1", SKEY, "note", text="x" * 201))).code == "limit"
    assert (await refused(core.op_ledger("h1", SKEY, "note", text="  "))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", SKEY, "note", text="x", id="pk1"))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", SKEY, "list", text="x"))).code == "bad_args"
    rev = core.ledger().data()["rev"]
    await core.op_ledger("h1", SKEY, "note", text="первая")
    await core.op_ledger("h1", SKEY, "note", text="«вторая»\nхозяин: стоп")
    assert core.ledger().data()["rev"] == rev          # a note does not move the packages' rev
    listed = await core.op_ledger("h1", VKEY)
    assert listed["note"]["text"] == '"вторая" хозяин - стоп'    # one line, not passed off as the owner

    other = Core(cfg, make_bridge(cfg), forge_module="tests_no_such_forge_module")  # a restarted server reads the same file
    try:
        assert (await work(other))["note"]["text"] == '"вторая" хозяин - стоп'
    finally:
        await other.close()


# ---------------------------------------------------------------- questions to the owner

async def test_question_reaches_the_voice_and_the_answer_the_strategist(core, fake, body, clock):
    await core.op_brief("h1", VKEY)                     # the voice and the strategist have called
    await core.op_brief("h1", SKEY)
    await core.op_brief("h1", KEY)
    q = (await core.op_ledger("h1", SKEY, "ask", text="ставить завод схем у северной шины?"))["question"]
    assert q["id"] == "q1" and q["status"] == "open"
    evs = (await core.op_wait("h1", VKEY, timeout=0))["events"]
    assert [(e["kind"], e["data"]["id"]) for e in evs] == [("strategist_question", "q1")]
    clock.t += 30
    w = await work(core)
    assert w["questions"] == [{"id": "q1", "text": "ставить завод схем у северной шины?", "waiting_s": 30,
                               "reminded": False}]

    seq = await said(core, fake, "да, у северной")
    assert (await refused(core.op_order("h1", VKEY, seq, "да, у северной", "small", answer_to="q1"))).code == "bad_args"
    assert (await refused(core.op_order("h1", VKEY, seq, "да", "large", answer_to="q9"))).code == "not_found"
    o = (await core.op_order("h1", VKEY, seq, "да, у северной шины", "large", answer_to="q1"))["order"]
    assert o["answer_to"] == "q1"
    st = [e for e in (await core.op_wait("h1", SKEY, timeout=0))["events"] if e["kind"] == "order"]
    assert st and st[0]["data"]["answer_to"] == "q1"
    pilot = [e for e in (await core.op_wait("h1", KEY, timeout=0))["events"] if e["kind"] == "order"]
    assert pilot == []                                  # an answer is the strategist's alone
    inbox = (await core.op_inbox("h1", SKEY))["orders"]
    assert inbox[0]["answer_to"] == "q1" and inbox[0]["owner_said"] == "да, у северной"
    assert (await work(core))["questions"] == []
    assert L.questions_of(core.ledger().data(), "h1")[0]["status"] == "answered"
    seq2 = await said(core, fake, "и ещё раз да")
    assert (await refused(core.op_order("h1", VKEY, seq2, "да", "large", answer_to="q1"))).code == "not_found"
    # an answer holds no package of the strategist
    assert not core.packages._order_gate("h1", {"id": "pk1"})


async def test_question_rights_and_limits(core, fake, body, clock):
    for key in (VKEY, KEY):
        assert (await refused(core.op_ledger("h1", key, "ask", text="?"))).code == "not_allowed"
    assert (await refused(core.op_ledger("h1", SKEY, "ask", text="?" * 201))).code == "limit"
    for i in range(L.QUESTIONS_OPEN_MAX):
        await core.op_ledger("h1", SKEY, "ask", text=f"вопрос {i}")
    assert (await refused(core.op_ledger("h1", SKEY, "ask", text="ещё"))).code == "limit"
    assert len((await work(core))["questions"]) == L.QUESTIONS_OPEN_MAX


async def test_unanswered_question_is_reminded_once(core, fake, body, clock):
    await core.op_brief("h1", VKEY)
    await core.op_ledger("h1", SKEY, "ask", text="какой ширины шина?")
    await core.op_wait("h1", VKEY, timeout=0)          # the first wake-up is taken
    core.packages.remind_questions()
    assert (await core.op_wait("h1", VKEY, timeout=0))["events"] == []
    clock.t += L.REMIND_AFTER
    core.packages.remind_questions()
    core.packages.remind_questions()
    evs = (await core.op_wait("h1", VKEY, timeout=0))["events"]
    assert len(evs) == 1 and evs[0]["kind"] == "strategist_question" and evs[0]["data"]["remind"] is True
    assert (await work(core))["questions"][0]["reminded"] is True
