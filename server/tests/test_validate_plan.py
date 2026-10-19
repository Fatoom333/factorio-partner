"""Server side of the ``plan`` action (docs/ACTIONS.md «plan»): every step is checked as its own act."""
import pytest

from factorio_partner import validate as V
from factorio_partner.errors import PartnerError


def steps(n):
    return [{"do": "wait", "args": {"seconds": 1}} for _ in range(n)]


def test_plan_steps_are_checked_like_act():
    out = V.check_act("plan", {"steps": [{"do": "walk", "args": {"to": "player"}},
                                         {"do": "wait", "args": {"seconds": 5}, "on_fail": "continue"}],
                               "on_fail": "stop", "after": 3})
    assert out["steps"][1] == {"do": "wait", "args": {"seconds": 5}, "on_fail": "continue"}
    assert out["after"] == 3


@pytest.mark.parametrize("args, code, where", [
    ({}, "bad_args", "steps / blob"),
    ({"steps": steps(1), "blob": "abc"}, "bad_args", "only one"),
    ({"steps": []}, "bad_args", "args.steps"),
    ({"steps": [{"do": "fly"}]}, "bad_args", "args.steps[1].do"),
    ({"steps": [{"do": "plan", "args": {"steps": steps(1)}}]}, "bad_args", "plan cannot hold"),
    ({"steps": [{"do": "wait", "args": {"seconds": 0}}]}, "bad_args", "args.steps[1].args.seconds"),
    ({"steps": [{"do": "wait", "args": {"seconds": 601}}]}, "limit", "args.steps[1].args.seconds"),
    ({"steps": [{"do": "wait", "args": {"seconds": 1}, "x": 1}]}, "bad_args", "args.steps[1].x"),
    ({"steps": [{"do": "wait", "args": {"seconds": 1}, "on_fail": "maybe"}]}, "bad_args", "on_fail"),
    ({"steps": ["wait"]}, "bad_args", "args.steps[1]"),
    ({"steps": steps(201)}, "limit", ""),        # larger than act.args 4 KB, or more than 200 steps
    ({"steps": steps(2), "from_step": 201}, "limit", "from_step"),
    ({"steps": steps(2), "after": 0}, "bad_args", "after"),
    ({"blob": "Bad Id"}, "bad_args", "blob"),
])
def test_plan_refusals(args, code, where):
    with pytest.raises(PartnerError) as e:
        V.check_act("plan", args)
    assert e.value.code == code
    assert where in str(e.value)


def test_plan_from_blob_needs_no_steps():
    assert V.check_act("plan", {"blob": "pkg-1", "from_step": 2}) == {"blob": "pkg-1", "from_step": 2}
