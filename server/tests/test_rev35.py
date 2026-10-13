"""Revision 3.5 on the server side: ``plan_belt{from:"resume"}`` passes the whitelist (``to`` is then
optional), the ``resumed`` answer and the ``unseen`` warning reach the agent untouched, ``admin_events``
adds ``fit: null`` the same way ``partner_wait`` does, the tool description tells about the re-lay."""
import json

import pytest

from conftest import KEY
from factorio_partner import validate as V
from factorio_partner.errors import PartnerError
from factorio_partner.server import build_server

POS = {"x": 10.5, "y": -3.5}


async def code_of(coro):
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


def last_act(fake):
    return [e for e in fake.mod.requests if e.get("op") == "act"][-1]


# ---------------------------------------------------------------- plan_belt from:"resume"

@pytest.mark.parametrize("args", [
    {"from": "resume"},
    {"from": "resume", "dry_run": True},
    {"from": "resume", "to": POS, "belt": "transport-belt", "lanes": 2, "underground": "never"},
])
async def test_resume_goes_to_the_mod_as_given(core, fake, args):
    r = await core.op_act("h1", KEY, "plan_belt", args)
    assert "job" in r
    assert last_act(fake)["args"] == {"do": "plan_belt", "args": args, "replace": False}


@pytest.mark.parametrize("args", [
    {"from": POS},                         # `to` is optional only with from="resume"
    {"from": "patch"},
    {"from": "restart"},
    {"from": "RESUME"},
    {"to": POS},
    {"from": "resume", "to": "base"},
    {"from": "resume", "lanes": "two"},
    {"from": "resume", "force": "player"},
])
async def test_resume_is_checked_before_the_mod(core, fake, args):
    assert (await code_of(core.op_act("h1", KEY, "plan_belt", args))).code == "bad_args"
    assert [e for e in fake.mod.requests if e.get("op") == "act"] == [], "no action was sent to the mod"


def test_plan_belt_still_requires_to_for_a_new_plan():
    assert V.check_act("plan_belt", {"from": POS, "to": POS}) == {"from": POS, "to": POS}
    assert V.check_act("plan_belt", {"from": "resume"}) == {"from": "resume"}
    with pytest.raises(PartnerError) as e:
        V.check_act("plan_belt", {"from": "patch"})
    assert e.value.code == "bad_args"


async def wait_one(core, fake, kind, data):
    await core.op_state("h1", KEY)
    fake.mod.emit(kind, data)
    r = await core.op_wait("h1", KEY, timeout=2)
    assert [e["kind"] for e in r["events"]] == [kind]
    return r["events"][0]["data"]


async def test_resumed_and_unseen_reach_the_agent(core, fake):
    detail = {"ghosts": 14, "length": 15, "undergrounds": 0, "turns": 2, "need": {"transport-belt": 14},
              "warnings": ["unseen:9"], "lanes": 1, "resumed": {"built": 6, "removed": 15}}
    d = await wait_one(core, fake, "job_done", {"job": 7, "do": "plan_belt", "detail": detail})
    assert d["detail"] == detail
    d = await wait_one(core, fake, "job_failed", {"job": 8, "do": "plan_belt", "code": "path_failed", "text": "",
                                                  "detail": {"reason": "budget", "expanded": 5, "lane": 1,
                                                             "removed": 3}})
    assert d["detail"]["removed"] == 3 and "fit" not in d["detail"]


# ---------------------------------------------------------------- admin_events: fit null

async def test_admin_events_add_fit_null_like_wait(core, fake):
    no_fit = {"kind": "job_failed", "seq": 1, "helper": "h1",
              "data": {"job": 3, "do": "build_blueprint", "code": "cannot_place", "text": "",
                       "detail": {"on_liquid": 2, "fit_checked": 288}}}
    found = {"kind": "job_done", "seq": 2, "helper": "h1",
             "data": {"job": 4, "do": "build_blueprint",
                      "detail": {"fit": {"shift": {"dx": 1, "dy": 0}}, "fit_checked": 3}}}
    other = {"kind": "job_done", "seq": 3, "helper": "h1",
             "data": {"job": 5, "do": "plan_belt", "detail": {"ghosts": 2}}}
    fake.mod.handlers["events"] = lambda args, env: {"events": [no_fit, found, other], "next": 4}
    r = await core.admin_raw_events(0)
    events = r["data"]["events"]
    assert events[0]["data"]["detail"]["fit"] is None and "fit" in events[0]["data"]["detail"]
    assert '"fit": null' in json.dumps(events[0])
    assert events[1] == found and events[2] == other
    assert r["data"]["next"] == 4
    assert "fit" not in no_fit["data"]["detail"], "the mod's answer itself is not changed"


async def test_admin_events_survive_odd_answers(core, fake):
    fake.mod.handlers["events"] = lambda args, env: {"events": ["junk", {"kind": "job_done"}]}
    r = await core.admin_raw_events(0)
    assert r["data"]["events"] == ["junk", {"kind": "job_done"}]


# ---------------------------------------------------------------- description

async def test_act_description_tells_about_the_relay(core):
    tools = {t.name: (t.description or "") for t in await build_server(core).list_tools()}
    text = tools["partner_act"]
    assert 'from:"resume"' in text and "unseen" in text and "resumed" in text
