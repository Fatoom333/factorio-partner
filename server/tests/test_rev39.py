"""Revision 3.9: `mine{item}` — gather an item from rocks, trees and hand-minable ore (ACTIONS.md)."""
import pytest

from factorio_partner import validate as V
from factorio_partner.errors import PartnerError


def test_mine_item_is_accepted_with_count_and_near():
    out = V.check_act("mine", {"item": "tungsten-ore", "count": 50, "near": {"x": 1, "y": 2}})
    assert out["item"] == "tungsten-ore"
    assert out["count"] == 50


@pytest.mark.parametrize("args", [
    {"item": "tungsten-ore"},                                         # count is required
    {"item": "tungsten-ore", "resource": "iron-ore", "count": 1},     # only one of target/resource/item
    {"item": "tungsten-ore", "target": {"unit_number": 5}, "count": 1},
    {"count": 1},                                                     # one of them is required
    {"item": "", "count": 1},
])
def test_mine_item_bad_args(args):
    with pytest.raises(PartnerError) as e:
        V.check_act("mine", args)
    assert e.value.code == "bad_args"
