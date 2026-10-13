"""Revision 3.4 on the server side: ``partner_reflex`` without ``set`` reads the current set, a
``build_blueprint`` result with no shift found carries ``fit: null``, ``unmarked`` and the ``at`` of
``helper_spawn`` pass through untouched."""
import json

from conftest import KEY

SET = [{"type": "flee", "radius": 20}]


def sent(fake, op):
    return [e for e in fake.mod.requests if e.get("op") == op]


# ---------------------------------------------------------------- partner_reflex

async def test_reflex_without_set_only_reads(core, fake):
    fake.mod.handlers["reflexes"] = lambda args, env: {"set": args.get("set", SET)}
    r = await core.op_reflex("h1", KEY, None)
    assert r["set"] == SET
    assert sent(fake, "reflexes")[-1]["args"] == {}
    # an empty list is still «remove all», not a read
    r = await core.op_reflex("h1", KEY, [])
    assert r["set"] == [] and sent(fake, "reflexes")[-1]["args"] == {"set": []}


# ---------------------------------------------------------------- build_blueprint: fit / unmarked

async def wait_one(core, fake, kind, data):
    await core.op_state("h1", KEY)
    fake.mod.emit(kind, data)
    r = await core.op_wait("h1", KEY, timeout=2)
    assert [e["kind"] for e in r["events"]] == [kind]
    return r["events"][0]["data"]


async def test_fit_null_when_no_shift_found(core, fake):
    detail = {"on_liquid": 2, "liquids": {"lava": 2}, "fit_checked": 288, "ghosts": 0}
    d = await wait_one(core, fake, "job_failed", {"job": 1, "do": "build_blueprint", "code": "cannot_place",
                                                  "text": "", "detail": detail})
    assert "fit" in d["detail"] and d["detail"]["fit"] is None
    assert d["detail"]["fit_checked"] == 288 and d["detail"]["liquids"] == {"lava": 2}
    assert '"fit": null' in json.dumps(d)


async def test_fit_null_for_dry_run_and_search_zero(core, fake):
    d = await wait_one(core, fake, "job_done", {"job": 2, "do": "build_blueprint",
                                                "detail": {"on_liquid": 1, "fit_checked": 0}})
    assert d["detail"]["fit"] is None


async def test_found_fit_and_other_results_are_untouched(core, fake):
    fit = {"anchor": {"x": 20, "y": -0.5}, "shift": {"dx": 0, "dy": -1}}
    d = await wait_one(core, fake, "job_failed", {"job": 3, "do": "build_blueprint", "code": "cannot_place",
                                                  "text": "", "detail": {"on_liquid": 1, "fit": fit,
                                                                         "fit_checked": 5}})
    assert d["detail"]["fit"] == fit


async def test_no_fit_field_without_a_search(core, fake):
    # the blueprint stood (or failed for another reason): no shift search, no `fit` field
    d = await wait_one(core, fake, "job_failed", {"job": 4, "do": "build_blueprint", "code": "stuck",
                                                  "text": "", "detail": {"ghosts": 2, "unmarked": 3}})
    assert "fit" not in d["detail"] and d["detail"]["unmarked"] == 3
    d = await wait_one(core, fake, "job_failed", {"job": 5, "do": "plan_belt", "code": "path_failed",
                                                  "text": "", "detail": {"reason": "budget", "fit_checked": 1}})
    assert "fit" not in d["detail"] and d["detail"]["reason"] == "budget"


# ---------------------------------------------------------------- helper_spawn: at

async def test_admin_spawn_passes_at(core, fake):
    fake.mod.handlers["helper_spawn"] = lambda args, env: {
        "helper": env["helper"], "unit_number": 7, "surface": "nauvis", "pos": {"x": 0, "y": 0},
        "at": "respawn_point"}
    r = await core.admin_spawn("h3")
    assert r["data"]["at"] == "respawn_point"
