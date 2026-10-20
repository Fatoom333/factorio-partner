"""Самостоятельный режим: правило сейва с маркером AUTO, признак в partner_brief."""
import pytest

from factorio_partner import savenotes as N
from factorio_partner.brief import build_brief
from factorio_partner.config import Config
from factorio_partner.errors import PartnerError

from conftest import KEY


@pytest.fixture
def notes_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path))
    monkeypatch.delenv("FP_SAVE_NAME", raising=False)
    return tmp_path


def test_off_by_default(notes_dir):
    assert N.auto_state("s") == {"on": False, "goal": None, "rule": None}
    N.op("s", "rules", "add", "мусор — в бак")
    assert N.auto_state("s")["on"] is False


def test_on_without_goal_and_with_goal(notes_dir):
    N.op("s", "rules", "add", "мусор — в бак")
    N.op("s", "rules", "add", "AUTO", quote="играй сам")
    assert N.auto_state("s") == {"on": True, "goal": None, "rule": 2}
    N.op("s", "rules", "remove", n=2)
    N.op("s", "rules", "add", "AUTO: развивай науку до синей", quote="развивай науку")
    st = N.auto_state("s")
    assert st["on"] and st["goal"] == "развивай науку до синей" and st["rule"] == 2


def test_remove_turns_off(notes_dir):
    N.op("s", "rules", "add", "AUTO: иди к ракете")
    assert N.auto_state("s")["goal"] == "иди к ракете"
    N.op("s", "rules", "remove", n=1)
    assert N.auto_state("s")["on"] is False


def test_second_auto_rule_refused(notes_dir):
    N.op("s", "rules", "add", "AUTO")
    with pytest.raises(PartnerError) as e:
        N.op("s", "rules", "add", "AUTO: другое")
    assert e.value.code == "bad_args"


@pytest.mark.parametrize("text", [
    "automatic belts — да", "autosort включить", "не AUTO, а ручной режим",
    "auto refuel turrets", "Auto craft ammo when low", "AUTO-sort", "auto", "Auto: к ракете",
    "AUTO — иди к ракете", "AUTO refuel", "AUTO:"])
def test_lookalikes_do_not_turn_on(notes_dir, text):
    N.op("s", "rules", "add", text)
    assert N.auto_state("s")["on"] is False


def test_memo_never_turns_on(notes_dir):
    N.op("s", "memo", "add", "AUTO")
    assert N.auto_state("s")["on"] is False


def test_owner_quote_does_not_leak_into_goal(notes_dir):
    N.op("s", "rules", "add", "AUTO: к ракете", quote="иди к ракете")
    assert N.auto_state("s")["goal"] == "к ракете"


def test_brief_has_auto(notes_dir, tmp_path):
    cfg = Config(home=tmp_path)
    assert build_brief(cfg, {"profile": "s"})["auto"]["on"] is False
    N.op("s", "rules", "add", "AUTO: развивай базу")
    b = build_brief(cfg, {"profile": "s"})
    assert b["auto"] == {"on": True, "goal": "развивай базу", "rule": 1}
    assert build_brief(cfg, None)["auto"]["on"] is False   # другой сейв (default)


async def test_auto_rule_question_names_the_mode(core, fake, notes_dir):
    own = fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": "иди к ракете сам"})
    await core.op_notes("h1", KEY, "rules", "add", "AUTO: иди к ракете", said_seq=own["seq"])
    said = [r for r in fake.mod.requests if r.get("op") == "say"][-1]["args"]["text"]
    assert said == "Включить самостоятельный режим (стратег сам ставит цели) с целью «иди к ракете»? Ответь «да»."
    yes = fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": "да"})
    await core.op_notes("h1", KEY, "rules", "confirm", said_seq=yes["seq"])
    assert N.auto_state(N.save_name(core.cfg))["goal"] == "иди к ракете"


async def test_plain_rule_question_unchanged(core, fake, notes_dir):
    own = fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": "заправляй турели"})
    await core.op_notes("h1", KEY, "rules", "add", "auto refuel turrets", said_seq=own["seq"])
    said = [r for r in fake.mod.requests if r.get("op") == "say"][-1]["args"]["text"]
    assert said == "Запомнить правило: «auto refuel turrets»? Ответь «да»."
