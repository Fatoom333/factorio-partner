"""Revision 3.12: partner_notes — the owner's standing rules and the helper's memo per save."""
import pytest

from factorio_partner import savenotes as N
from factorio_partner.errors import PartnerError


@pytest.fixture
def notes_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path))
    monkeypatch.delenv("FP_SAVE_NAME", raising=False)
    return tmp_path


def test_add_list_remove_and_file_on_disk(notes_dir):
    N.op("vulkan-start", "rules", "add", "мусор (камень, уголь) — в бак у [gps=10,20]")
    N.op("vulkan-start", "rules", "add", "  ночью\nне ходить   на север  ")
    out = N.op("vulkan-start", "rules", "list")
    assert [i["n"] for i in out["items"]] == [1, 2]
    assert out["items"][1]["text"].startswith("ночью не ходить на север (")
    text = (notes_dir / "vulkan-start" / "rules.md").read_text(encoding="utf-8")
    assert text.startswith("# Правила хозяина для помощника (vulkan-start)")
    assert "1. мусор" in text
    out = N.op("vulkan-start", "rules", "remove", n=1)
    assert len(out["items"]) == 1 and out["items"][0]["n"] == 1
    assert N.load("vulkan-start", "memo") == []


def test_hand_edited_file_is_read(notes_dir):
    d = notes_dir / "s1"
    d.mkdir()
    (d / "memo.md").write_text("# что угодно\n\nтекст\n1. бак у входа\n  2.   сундук с патронами  \n", encoding="utf-8")
    assert N.load("s1", "memo") == ["бак у входа", "сундук с патронами"]


@pytest.mark.parametrize("args", [
    ("rules", "add", ""), ("rules", "add", "x" * 301), ("rules", "add", None),
    ("nope", "list", None), ("rules", "drop", None),
])
def test_bad_args(notes_dir, args):
    with pytest.raises(PartnerError):
        N.op("s", *args)


def test_remove_bad_number(notes_dir):
    N.op("s", "memo", "add", "a")
    for n in (0, 2, True, "1", None):
        with pytest.raises(PartnerError):
            N.op("s", "memo", "remove", n=n)


def test_limit(notes_dir):
    for i in range(N.MAX_ITEMS["rules"]):
        N.op("s", "rules", "add", f"r{i}")
    with pytest.raises(PartnerError) as e:
        N.op("s", "rules", "add", "one more")
    assert e.value.code == "limit"


def test_save_name_never_leaves_the_folder(monkeypatch):
    class Cfg:
        forge_profile = None
    monkeypatch.delenv("FP_SAVE_NAME", raising=False)
    assert N.save_name(Cfg(), "..") == "default"
    assert N.save_name(Cfg(), "../x") == "default"
    assert N.save_name(Cfg(), "vulkan-start") == "vulkan-start"
    monkeypatch.setenv("FP_SAVE_NAME", "my.save_1")
    assert N.save_name(Cfg(), "vulkan-start") == "my.save_1"
