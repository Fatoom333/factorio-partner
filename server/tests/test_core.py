import asyncio
import json
import sys
import types

import pytest

from factorio_partner.core import Core
from factorio_partner.errors import PartnerError

from conftest import KEY, PASSWORD, make_bridge

BP = "0" + "eNqrVkrOzytJzSsJqQQAMhkGBA==" * 600   # ~17 KB fake blueprint string (base64 charset)


def last_env(fake, op=None):
    envs = [json.loads(c[len("/partner "):]) for c in fake.commands]
    if op:
        envs = [e for e in envs if e["op"] == op]
    return envs[-1]


def install_forge(monkeypatch, name="fake_forge_mod", **funcs):
    """A fake forge module with the Python contract of MCP.md (plan / load_plan / brief_notes)."""
    mod = types.ModuleType(name)
    for k, v in funcs.items():
        setattr(mod, k, v)
    monkeypatch.setitem(sys.modules, name, mod)
    return name


def file_load_plan(plan_id, *, config):
    """Like forge.load_plan: FP_HOME/plans/<id>.txt of the server's Config."""
    p = config.plans_dir / f"{plan_id}.txt"
    if not p.is_file():
        raise PartnerError("bad_args", "plan: no such plan")
    return p.read_text(encoding="utf-8")


async def code_of(coro):
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


# ---------------------------------------------------------------- access

@pytest.mark.parametrize("helper,key", [
    ("h1", "w" * 40), ("h9", KEY), ("H1", KEY), ("h1", "short"), ("h1", None), (None, KEY),
    ("h1/../x", KEY), ("h1", KEY + "x"), ("h1", KEY[:-1]),
])
async def test_access_denied_same_text(core, fake, helper, key):
    e = await code_of(core.op_state(helper, key))
    assert str(e) == "access denied"
    assert fake.commands == []   # nothing reached the game


async def test_access_no_helpers_file(core, home):
    (home / "helpers.json").unlink()
    e = await code_of(core.op_state("h1", KEY))
    assert str(e) == "access denied"


async def test_access_short_key_in_file_refused(core, home):
    (home / "helpers.json").write_text(json.dumps({"h1": "abc"}), encoding="utf-8")
    e = await code_of(core.op_state("h1", "abc" + "x" * 29))
    assert str(e) == "access denied"


# ---------------------------------------------------------------- state / read ops

async def test_state_has_tick_seq(core, fake):
    r = await core.op_state("h1", KEY)
    assert r["helper"] == "h1" and "tick" in r and "seq" in r
    assert last_env(fake)["op"] == "state" and last_env(fake)["helper"] == "h1"


async def test_map_args(core, fake):
    await core.op_map("h1", KEY, radius=20, center={"x": 1, "y": 2}, types=["inserter"])
    env = last_env(fake, "map")
    assert env["args"] == {"radius": 20, "center": {"x": 1, "y": 2}, "types": ["inserter"]}
    e = await code_of(core.op_map("h1", KEY, radius=33))
    assert e.code == "limit"
    assert (await code_of(core.op_map("h1", KEY, radius=0))).code == "bad_args"


async def test_map_near_player(core, fake):
    await core.op_map("h1", KEY, near="player")
    assert last_env(fake, "map")["args"] == {"radius": 16, "near": "player"}
    assert (await code_of(core.op_map("h1", KEY, center={"x": 0, "y": 0}, near="player"))).code == "bad_args"
    assert (await code_of(core.op_map("h1", KEY, near="helper"))).code == "bad_args"


async def test_resources_stock_near_player(core, fake):
    await core.op_resources("h1", KEY, radius=100, name="iron-ore", near="player")
    assert last_env(fake, "resources")["args"] == {"radius": 100, "name": "iron-ore", "near": "player"}
    await core.op_stock("h1", KEY, items=["iron-plate"])
    assert last_env(fake, "stock")["args"] == {"items": ["iron-plate"]}
    e = await code_of(core.op_resources("h1", KEY, radius=129))
    assert e.code == "limit"


async def test_resources_stock_ghosts_center_or_near(core, fake):
    c = {"x": 5, "y": -3}
    await core.op_resources("h1", KEY, center=c)
    assert last_env(fake, "resources")["args"] == {"center": c}
    await core.op_stock("h1", KEY, center=c, limit=10)
    assert last_env(fake, "stock")["args"] == {"limit": 10, "center": c}
    await core.op_stock("h1", KEY, near="player")
    assert last_env(fake, "stock")["args"] == {"near": "player"}
    await core.op_ghosts("h1", KEY, radius=20, center=c)
    assert last_env(fake, "ghosts")["args"] == {"radius": 20, "center": c}
    await core.op_ghosts("h1", KEY, near="player")
    assert last_env(fake, "ghosts")["args"] == {"near": "player"}
    for call in (core.op_resources("h1", KEY, center=c, near="player"),
                 core.op_stock("h1", KEY, center=c, near="player"),
                 core.op_ghosts("h1", KEY, center=c, near="player")):
        assert (await code_of(call)).code == "bad_args"
    assert (await code_of(core.op_stock("h1", KEY, near="helper"))).code == "bad_args"
    assert (await code_of(core.op_stock("h1", KEY, limit=201))).code == "limit"


async def test_rates_stock_items_up_to_100(core, fake):
    names = [f"item-{i}" for i in range(100)]
    await core.op_rates("h1", KEY, items=names, top=100)
    assert last_env(fake, "rates")["args"]["items"] == names
    await core.op_stock("h1", KEY, items=names)
    assert last_env(fake, "stock")["args"]["items"] == names
    too_many = names + ["one-more"]
    assert (await code_of(core.op_rates("h1", KEY, items=too_many))).code == "limit"
    assert (await code_of(core.op_stock("h1", KEY, items=too_many))).code == "limit"
    assert (await code_of(core.op_rates("h1", KEY, top=101))).code == "limit"


async def test_act_target_with_pos_and_follow_bounds(core, fake):
    t = {"unit_number": 77, "pos": {"x": 1.5, "y": 2.5}}
    await core.op_act("h1", KEY, "extract", {"target": t})
    assert last_env(fake, "act")["args"]["args"]["target"] == t
    e = await code_of(core.op_act("h1", KEY, "extract", {"target": {"unit_number": 5, "name": "x"}}))
    assert e.code == "bad_args"
    e = await code_of(core.op_act("h1", KEY, "follow", {"duration_s": 3601}))
    assert e.code == "limit"
    e = await code_of(core.op_act("h1", KEY, "follow", {"distance": 33}))
    assert e.code == "limit"
    e = await code_of(core.op_act("h1", KEY, "follow", {"distance": 0}))
    assert e.code == "bad_args"


async def test_ghosts_and_rates(core, fake):
    area = {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 10, "y": 10}}
    await core.op_ghosts("h1", KEY, area=area)
    assert last_env(fake, "ghosts")["args"] == {"area": area}
    assert (await code_of(core.op_ghosts("h1", KEY, radius=5, area=area))).code == "bad_args"
    big = {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 200, "y": 10}}
    assert (await code_of(core.op_ghosts("h1", KEY, area=big))).code == "limit"
    await core.op_rates("h1", KEY, scope="area", period="10m", area=area, top=5)
    assert last_env(fake, "rates")["args"] == {"scope": "area", "period": "10m", "area": area, "top": 5}
    assert (await code_of(core.op_rates("h1", KEY, scope="area"))).code == "bad_args"
    assert (await code_of(core.op_rates("h1", KEY, period="2h"))).code == "bad_args"
    assert (await code_of(core.op_rates("h1", KEY, top=101))).code == "limit"
    assert (await code_of(core.op_rates("h1", KEY, top=0))).code == "bad_args"


async def test_rates_surface(core, fake):
    await core.op_rates("h1", KEY, surface="vulcanus", period="10m")
    assert last_env(fake, "rates")["args"] == {"scope": "surface", "period": "10m", "surface": "vulcanus"}
    assert (await code_of(core.op_rates("h1", KEY, surface="../x"))).code == "bad_args"
    assert (await code_of(core.op_rates("h1", KEY, surface=5))).code == "bad_args"


async def test_recipes(core, fake):
    fake.mod.handlers["recipes"] = lambda a, e: {"craftable": {"iron-gear-wheel": 20}}
    r = await core.op_recipes("h1", KEY, filter="gear")
    assert r["craftable"] == {"iron-gear-wheel": 20} and "tick" in r and "seq" in r
    env = last_env(fake, "recipes")
    assert env["args"] == {"filter": "gear"} and env["helper"] == "h1"
    await core.op_recipes("h1", KEY)
    assert last_env(fake, "recipes")["args"] == {}
    await core.op_recipes("h1", KEY, filter="")
    assert last_env(fake, "recipes")["args"] == {"filter": ""}
    for bad in (5, "a b", "x" * 101, "/c"):
        assert (await code_of(core.op_recipes("h1", KEY, filter=bad))).code == "bad_args"


async def test_recipes_on_paused_game_warns(cfg, fake):
    now = [0.0]
    c = Core(cfg, make_bridge(cfg, clock=lambda: now[0]), poll_interval=0.01,
             forge_module="tests_no_such_forge_module", clock=lambda: now[0])
    fake.mod.handlers["recipes"] = lambda a, e: {"craftable": {}}
    await c.op_state("h1", KEY)
    fake.mod.tick_step = 0
    for _ in range(3):
        now[0] += 2.0
        await c.op_state("h1", KEY)
    r = await c.op_recipes("h1", KEY)
    assert r["warning"] == "game_paused"
    await c.close()


async def test_mod_error_becomes_partner_error(core, fake):
    from fake_rcon import FakeModError

    def boom(a, e):
        raise FakeModError("not_charted", "chunk not charted")
    fake.mod.handlers["state"] = boom
    e = await code_of(core.op_state("h1", KEY))
    assert e.code == "not_charted" and "chunk not charted" in str(e)


async def test_response_too_large(core, fake):
    fake.mod.handlers["map"] = lambda a, e: {"rows": ["x" * 1000] * 30}
    e = await code_of(core.op_map("h1", KEY, radius=32))
    assert e.code == "response too large" and "radius" in str(e)


async def test_empty_table_as_list(core, fake):
    fake.mod.handlers["say"] = lambda a, e: []
    assert await core.op_say("h1", KEY, "привет") == {}


# ---------------------------------------------------------------- act

async def test_act_ok(core, fake):
    r = await core.op_act("h1", KEY, "walk", {"to": {"x": 10, "y": -4}})
    assert r["job"] == 1 and "tick" in r and "seq" in r
    env = last_env(fake, "act")
    assert env["args"] == {"do": "walk", "args": {"to": {"x": 10, "y": -4}}, "replace": False}
    await core.op_act("h1", KEY, "walk", {"to": "player"}, replace=True)
    assert last_env(fake, "act")["args"]["replace"] is True


@pytest.mark.parametrize("do,args", [
    ("teleport", {"to": {"x": 1, "y": 1}}),
    ("walk", {"to": {"x": 1}}),
    ("walk", {"to": {"x": 1, "y": 1}, "speed": 9}),
    ("walk", {}),
    ("walk", {"to": {"x": float("nan"), "y": 1}}),
    ("mine", {"resource": "iron-ore"}),
    ("mine", {"resource": "iron-ore", "target": {"unit_number": 5}, "count": 1}),
    ("craft", {"recipe": "gear", "count": 0}),
    ("craft", {"recipe": "gear", "count": 1.5}),
    ("craft", {"recipe": "x[1]", "count": 1}),
    ("insert", {"target": {"unit_number": 1}, "items": {"iron-plate": 100001}}),
    ("insert", {"target": {"unit_number": True}, "items": {"iron-plate": 1}}),
    ("place", {"item": "chest", "pos": {"x": 1, "y": 1}, "direction": 16}),
    ("build_blueprint", {"anchor": {"x": 0, "y": 0}}),
    ("build_blueprint", {"anchor": {"x": 0, "y": 0}, "blob": "a", "plan": "b"}),
    ("build_blueprint", {"anchor": {"x": 0, "y": 0}, "blob": "a", "mode": "forced"}),
    ("deconstruct", {}),
    ("wait", {"seconds": 601}),
    ("collect", {"items": {"coal": 5}, "center": {"x": 0, "y": 0}, "near": "player"}),
    ("walk", "to=1,1"),
])
async def test_act_rejects(core, fake, do, args):
    e = await code_of(core.op_act("h1", KEY, do, args))
    assert e.code in ("bad_args", "limit")
    assert not any('"op":"act"' in c for c in fake.commands)


async def test_act_args_too_large(core):
    e = await code_of(core.op_act("h1", KEY, "deconstruct",
                                  {"area": {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 1, "y": 1}},
                                   "filter": ["a" * 99] * 32 + ["b"]}))
    assert e.code in ("bad_args", "limit")
    e = await code_of(core.op_act("h1", KEY, "collect", {"items": {f"item-{i:03d}-" + "x" * 80: 1 for i in range(60)}}))
    assert e.code == "limit"


async def test_act_float_int_normalised(core, fake):
    await core.op_act("h1", KEY, "craft", {"recipe": "iron-gear-wheel", "count": 3.0})
    assert last_env(fake, "act")["args"]["args"]["count"] == 3


async def test_act_with_plan_uploads_blob(cfg, fake, home, monkeypatch):
    seen = {}

    def load_plan(plan_id, *, config):
        seen["call"] = (plan_id, config)
        return file_load_plan(plan_id, config=config)
    (home / "plans").mkdir()
    (home / "plans" / "mine-1.txt").write_text(BP, encoding="utf-8")
    name = install_forge(monkeypatch, "fake_forge_load", load_plan=load_plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    r = await c.op_act("h1", KEY, "build_blueprint", {"plan": "mine-1", "anchor": {"x": 5, "y": 5}, "direction": 4})
    assert r["job"] == 1
    assert seen["call"] == ("mine-1", cfg)       # exactly load_plan(id, config=Config)
    act = last_env(fake, "act")["args"]
    blob = act["args"]["blob"]
    assert "plan" not in act["args"] and act["args"]["direction"] == 4
    assert fake.mod.blob_text(blob) == BP
    for cmd in fake.commands:
        assert len(cmd.encode()) <= 8 * 1024 + len("/partner ")
    for env in [json.loads(cmd[9:]) for cmd in fake.commands if '"op":"blob_put"' in cmd]:
        assert len(env["args"]["data"].encode()) <= 3500
    # the helper log never holds the blueprint
    log = (home / "logs" / "h1.jsonl").read_text(encoding="utf-8")
    assert BP[:200] not in log and KEY not in log
    await c.close()


async def test_act_plan_has_no_fallback_loader(core, home):
    """No forge module -> no plan; the server does not read FP_HOME/plans itself any more."""
    (home / "plans").mkdir()
    (home / "plans" / "p2.txt").write_text(BP, encoding="utf-8")
    (home / "plans" / "p3.json").write_text(json.dumps({"blueprint": BP}), encoding="utf-8")
    for pid in ("p2", "p3"):
        e = await code_of(core.op_act("h1", KEY, "build_blueprint", {"plan": pid, "anchor": {"x": 0, "y": 0}}))
        assert e.code == "not_found"


async def test_act_plan_missing_and_bad(cfg, fake, home, monkeypatch):
    (home / "plans").mkdir()
    (home / "plans" / "evil.txt").write_text("/c game.print(1)", encoding="utf-8")
    (home / "plans" / "big.txt").write_text("0" + "A" * (1024 * 1024 + 10), encoding="utf-8")
    name = install_forge(monkeypatch, "fake_forge_load2", load_plan=file_load_plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    e = await code_of(c.op_act("h1", KEY, "build_blueprint", {"plan": "nope", "anchor": {"x": 0, "y": 0}}))
    assert e.code == "bad_args"            # the forge's PlanArgsError, as is
    e = await code_of(c.op_act("h1", KEY, "build_blueprint", {"plan": "evil", "anchor": {"x": 0, "y": 0}}))
    assert e.code == "bad_args"
    e = await code_of(c.op_act("h1", KEY, "build_blueprint", {"plan": "big", "anchor": {"x": 0, "y": 0}}))
    assert e.code == "limit"
    assert not any('"op":"blob_put"' in cmd for cmd in fake.commands)
    await c.close()


async def test_act_plan_loader_crash_is_not_found(cfg, fake, monkeypatch):
    def load_plan(plan_id, *, config):
        raise RuntimeError("C:/secret/path")
    name = install_forge(monkeypatch, "fake_forge_load3", load_plan=load_plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    e = await code_of(c.op_act("h1", KEY, "build_blueprint", {"plan": "p1", "anchor": {"x": 0, "y": 0}}))
    assert e.code == "not_found" and "secret" not in str(e)
    await c.close()


async def test_plan_id_no_path_traversal(core):
    e = await code_of(core.op_act("h1", KEY, "build_blueprint", {"plan": "../x", "anchor": {"x": 0, "y": 0}}))
    assert e.code == "bad_args"


# ---------------------------------------------------------------- cancel / say / reflex

async def test_cancel(core, fake):
    await core.op_cancel("h1", KEY, job=3)
    assert last_env(fake, "cancel")["args"] == {"job": 3}
    await core.op_cancel("h1", KEY, all=True)
    assert last_env(fake, "cancel")["args"] == {"all": True}
    assert (await code_of(core.op_cancel("h1", KEY))).code == "bad_args"
    assert (await code_of(core.op_cancel("h1", KEY, job=1, all=True))).code == "bad_args"


async def test_say_limits(core, fake):
    await core.op_say("h1", KEY, "готово")
    assert last_env(fake, "say")["args"] == {"text": "готово"}
    assert (await code_of(core.op_say("h1", KEY, "x" * 201))).code == "limit"
    assert (await code_of(core.op_say("h1", KEY, "  "))).code == "bad_args"


async def test_reflex_validation(core, fake):
    await core.op_reflex("h1", KEY, [{"type": "flee", "health": 0.3}])
    assert last_env(fake, "reflexes")["args"] == {"set": [{"type": "flee", "health": 0.3}]}
    await core.op_reflex("h1", KEY, [])
    for bad in ("x", [{"no": 1}], [{"type": "Bad Type"}], [1]):
        assert (await code_of(core.op_reflex("h1", KEY, bad))).code == "bad_args"
    # MCP.md: at most 16 reflexes, everything up to 4 KB; the known types are the mod's business
    await core.op_reflex("h1", KEY, [{"type": "flee"}] * 16)
    assert (await code_of(core.op_reflex("h1", KEY, [{"type": "flee"}] * 17))).code == "limit"
    assert (await code_of(core.op_reflex("h1", KEY, [{"type": "flee", "x": "y" * 5000}]))).code == "limit"


# ---------------------------------------------------------------- wait

async def test_wait_returns_loud(core, fake):
    await core.op_state("h1", KEY)      # cursor starts at the current seq
    fake.mod.emit("arrived", {"job": 1}, loud=False)
    fake.mod.emit("job_done", {"job": 1, "do": "walk", "detail": {}})
    r = await core.op_wait("h1", KEY, timeout=2)
    kinds = [e["kind"] for e in r["events"]]
    assert kinds == ["arrived", "job_done"] and r["timed_out"] is False
    assert r["seq"] == 2
    r = await core.op_wait("h1", KEY, timeout=0.1)
    assert r["events"] == [] and r["timed_out"] is True


async def test_wait_old_events_before_start_not_replayed(core, fake):
    fake.mod.emit("job_done", {"job": 1})
    await core.op_state("h1", KEY)        # first call: cursor = current seq (1)
    r = await core.op_wait("h1", KEY, timeout=0.05)
    assert r["events"] == []


async def test_wait_quiet_false_wakes_on_noise(core, fake):
    await core.op_state("h1", KEY)

    async def later():
        await asyncio.sleep(0.05)
        fake.mod.emit("job_progress", {"job": 1, "done": 1, "total": 2}, loud=False)
    t = asyncio.create_task(later())
    r = await core.op_wait("h1", KEY, timeout=2, quiet=False)
    await t
    assert [e["kind"] for e in r["events"]] == ["job_progress"]
    assert r["timed_out"] is False


async def test_wait_keeps_last_six_noisy(core, fake):
    await core.op_state("h1", KEY)
    for i in range(10):
        fake.mod.emit("job_progress", {"job": 1, "done": i, "total": 10}, loud=False)
    r = await core.op_wait("h1", KEY, timeout=0.05)
    assert r["timed_out"] and len(r["events"]) == 6
    assert r["events"][-1]["data"]["done"] == 9
    assert r["seq"] == 10


async def test_wait_filters_other_helpers(core, fake):
    await core.op_state("h1", KEY)
    fake.mod.emit("job_done", {"job": 1}, helper="h2")
    fake.mod.emit("player_said", {"player": "T", "owner": True, "text": "hi"}, helper=None)
    r = await core.op_wait("h1", KEY, timeout=1)
    assert [e["kind"] for e in r["events"]] == ["player_said"]
    assert last_env(fake, "events")["args"]["helper"] == "h1"


async def test_wait_since_zero_means_now(core, fake):
    await core.op_state("h1", KEY)
    fake.mod.emit("job_done", {"job": 1})
    r = await core.op_wait("h1", KEY, timeout=0.05, since=0)
    assert r["events"] == [] and r["seq"] == 1


async def test_wait_explicit_since(core, fake):
    fake.mod.emit("job_done", {"job": 1})
    fake.mod.emit("job_done", {"job": 2})
    r = await core.op_wait("h1", KEY, timeout=1, since=1)
    assert [e["data"]["job"] for e in r["events"]] == [2]


async def test_wait_lost_flag(core, fake):
    for i in range(5):
        fake.mod.emit("job_progress", {}, loud=False)
    fake.mod.events = fake.mod.events[3:]
    r = await core.op_wait("h1", KEY, timeout=0.05, since=1)
    assert r.get("lost") is True


async def test_wait_bounds(core):
    assert (await code_of(core.op_wait("h1", KEY, timeout=56))).code == "limit"
    assert (await code_of(core.op_wait("h1", KEY, timeout=-1))).code == "bad_args"
    assert (await code_of(core.op_wait("h1", KEY, since=-5))).code == "bad_args"


async def test_wait_many_loud_paged(core, fake):
    await core.op_state("h1", KEY)
    for i in range(50):
        fake.mod.emit("job_done", {"job": i})
    r1 = await core.op_wait("h1", KEY, timeout=1)
    assert len(r1["events"]) == 40 and r1["seq"] == 40
    r2 = await core.op_wait("h1", KEY, timeout=1)
    assert len(r2["events"]) == 10 and r2["events"][0]["seq"] == 41


async def test_wait_game_paused(cfg, fake):
    now = [0.0]
    c = Core(cfg, make_bridge(cfg, clock=lambda: now[0]), poll_interval=0.01,
             forge_module="tests_no_such_forge_module", clock=lambda: now[0])

    async def tick_clock(dt):
        now[0] += 1.0
        await asyncio.sleep(0)
    c.sleep = tick_clock
    await c.op_state("h1", KEY)
    fake.mod.tick_step = 0
    r = await c.op_wait("h1", KEY, timeout=30)
    # reading a paused game is safe: the answer comes with a warning
    assert r["timed_out"] is True and r["warning"] == "game_paused"
    r = await c.op_state("h1", KEY)
    assert r["warning"] == "game_paused" and r["helper"] == "h1"
    # a mutating call is refused while still paused, without reaching the mod
    before = fake.mod.executed["act"]
    e = await code_of(c.op_act("h1", KEY, "wait", {"seconds": 1}))
    assert e.code == "game_paused" and fake.mod.executed["act"] == before
    fake.mod.tick_step = 1
    r = await c.op_act("h1", KEY, "wait", {"seconds": 1})
    assert "job" in r
    await c.close()


async def test_game_reloaded(core, fake):
    await core.op_state("h1", KEY)
    fake.mod.emit("job_done", {"job": 1})
    await core.op_wait("h1", KEY, timeout=1)
    # older save loaded: tick and seq go back
    fake.mod.tick = 50
    fake.mod.events = []
    fake.mod.seq = 0
    r = await core.op_wait("h1", KEY, timeout=1)
    assert [e["kind"] for e in r["events"]] == ["game_reloaded"]
    assert r["seq"] == 0
    fake.mod.emit("job_done", {"job": 9})
    r = await core.op_wait("h1", KEY, timeout=1)
    assert [e["data"]["job"] for e in r["events"]] == [9]


async def test_game_reloaded_seen_by_other_call(core, fake):
    await core.op_state("h1", KEY)
    fake.mod.tick = 5
    await core.op_state("h1", KEY)      # reload detected on the cmd channel
    r = await core.op_wait("h1", KEY, timeout=0.05)
    assert [e["kind"] for e in r["events"]] == ["game_reloaded"]


# ---------------------------------------------------------------- repeated_failure

async def test_repeated_failure(core, fake):
    await core.op_state("h1", KEY)
    args = {"to": {"x": 100, "y": 100}}
    for _ in range(3):
        r = await core.op_act("h1", KEY, "walk", args)
        fake.mod.emit("job_failed", {"job": r["job"], "do": "walk", "code": "path_failed", "text": ""})
        await core.op_wait("h1", KEY, timeout=1)
    e = await code_of(core.op_act("h1", KEY, "walk", args))
    assert e.code == "repeated_failure"
    # other args are fine
    await core.op_act("h1", KEY, "walk", {"to": {"x": 1, "y": 1}})
    # other helper is not affected
    await core.op_act("h2", "z" * 40, "walk", args)


async def test_repeated_failure_reset_and_cancelled(core, fake):
    await core.op_state("h1", KEY)
    args = {"seconds": 5}
    for code in ("stuck", "stuck", "cancelled", "cancelled"):
        r = await core.op_act("h1", KEY, "wait", args)
        fake.mod.emit("job_failed", {"job": r["job"], "do": "wait", "code": code})
        await core.op_wait("h1", KEY, timeout=1)
    r = await core.op_act("h1", KEY, "wait", args)    # cancelled is not a failure
    fake.mod.emit("job_done", {"job": r["job"], "do": "wait"})
    await core.op_wait("h1", KEY, timeout=1)
    for _ in range(2):
        r = await core.op_act("h1", KEY, "wait", args)
        fake.mod.emit("job_failed", {"job": r["job"], "do": "wait", "code": "stuck"})
        await core.op_wait("h1", KEY, timeout=1)
    await core.op_act("h1", KEY, "wait", args)        # done reset the counter


async def test_repeated_failure_of_a_plan(core, fake):
    await core.op_state("h1", KEY)
    args = {"steps": [{"do": "walk", "args": {"to": {"x": 100, "y": 100}}}]}
    for _ in range(3):
        r = await core.op_act("h1", KEY, "plan", args)
        fake.mod.emit("plan_done", {"job": r["job"], "do": "plan", "status": "failed", "code": "path_failed"})
        await core.op_wait("h1", KEY, timeout=1)
    assert (await code_of(core.op_act("h1", KEY, "plan", args))).code == "repeated_failure"


async def test_plan_done_resets_and_cancel_is_not_a_failure(core, fake):
    await core.op_state("h1", KEY)
    args = {"steps": [{"do": "wait", "args": {"seconds": 5}}]}
    for status, code in (("failed", "stuck"), ("failed", "stuck"), ("failed", "cancelled"),
                         ("done", None), ("failed", "stuck"), ("failed", "stuck")):
        r = await core.op_act("h1", KEY, "plan", args)
        data = {"job": r["job"], "do": "plan", "status": status}
        if code:
            data["code"] = code
        fake.mod.emit("plan_done", data)
        await core.op_wait("h1", KEY, timeout=1)
    await core.op_act("h1", KEY, "plan", args)        # done reset the counter


async def test_plan_step_with_a_forge_plan_uploads_blob(cfg, fake, home, monkeypatch):
    (home / "plans").mkdir()
    (home / "plans" / "mine-1.txt").write_text(BP, encoding="utf-8")
    name = install_forge(monkeypatch, "fake_forge_load_steps", load_plan=file_load_plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    await c.op_act("h1", KEY, "plan", {"steps": [
        {"do": "walk", "args": {"to": {"x": 5, "y": 5}}},
        {"do": "build_blueprint", "args": {"plan": "mine-1", "anchor": {"x": 5, "y": 5}}}]})
    steps = last_env(fake, "act")["args"]["args"]["steps"]
    bp = steps[1]["args"]
    assert "plan" not in bp and fake.mod.blob_text(bp["blob"]) == BP
    assert steps[0] == {"do": "walk", "args": {"to": {"x": 5, "y": 5}}}
    await c.close()


# ---------------------------------------------------------------- plan (forge)

async def test_plan_without_forge(core):
    r = await core.op_plan("h1", KEY, "mining", resource={"name": "iron-ore"})
    assert r["supported"] is False and r["reason"]


async def test_plan_validation(core):
    assert (await code_of(core.op_plan("h1", KEY, "smelting", resource={}))).code == "bad_args"
    assert (await code_of(core.op_plan("h1", KEY, "mining"))).code == "bad_args"
    assert (await code_of(core.op_plan("h1", KEY, "mining", resource={}, patch={}))).code == "bad_args"


async def test_plan_with_fake_forge(cfg, fake, monkeypatch):
    calls = {}

    def plan(task, resource=None, patch=None, options=None, *, config):
        calls.update(task=task, resource=resource, patch=patch, options=options, config=config)
        return {"plan": "p1", "anchor": {"x": 1, "y": 2}, "direction": 0, "items": {},
                "size": {"w": 10, "h": 10}, "summary": "ok", "blueprint": BP}
    name = install_forge(monkeypatch, plan=plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    r = await c.op_plan("h1", KEY, "mining", patch={"name": "iron-ore"}, options={"drill": "x"})
    assert r["plan"] == "p1" and "blueprint" not in r
    assert calls["patch"] == {"name": "iron-ore"} and calls["options"] == {"drill": "x"}
    assert calls["config"] is cfg and calls["resource"] is None
    await c.close()


async def test_plan_forge_with_wrong_signature_is_not_adapted(cfg, fake, monkeypatch):
    """No signature guessing: a forge that does not follow the contract fails, visibly."""
    def plan(args, fp_home=None):
        return {}
    name = install_forge(monkeypatch, "fake_forge_old", plan=plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    r = await c.op_plan("h1", KEY, "mining", resource={"name": "iron-ore"})
    assert r["supported"] is False and "TypeError" in r["reason"]
    await c.close()


async def test_plan_bad_args_error_from_forge_passes_through(cfg, fake, monkeypatch):
    def plan(task, resource=None, patch=None, options=None, *, config):
        raise PartnerError("bad_args", "resource.area: wrong")
    name = install_forge(monkeypatch, "fake_forge_badargs", plan=plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    e = await code_of(c.op_plan("h1", KEY, "mining", resource={"name": "iron-ore"}))
    assert e.code == "bad_args"
    await c.close()


async def test_plan_forge_raises(cfg, fake, monkeypatch):
    def plan(task, resource=None, patch=None, options=None, *, config):
        raise RuntimeError("no drills")
    name = install_forge(monkeypatch, "fake_forge_bad", plan=plan)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    r = await c.op_plan("h1", KEY, "mining", resource={"name": "iron-ore"})
    # forge's own message (may hold paths / profile names) stays in server.log
    assert r["supported"] is False and "RuntimeError" in r["reason"] and "no drills" not in r["reason"]
    await c.close()


@pytest.mark.parametrize("answer,ok", [
    ({"plan": "p1", "anchor": {"x": 1, "y": 2}, "direction": 4, "items": {"electric-mining-drill": 8},
      "size": {"w": 10, "h": 12}, "summary": "8 drills", "blueprint": BP, "path": "C:/Users/x/forge",
      "profile": "secret-base"}, True),
    ({"plan": "../p1", "anchor": {"x": 1, "y": 2}, "direction": 0, "items": {}, "size": {"w": 1, "h": 1},
      "summary": ""}, False),
    ({"plan": "p1", "anchor": {"x": 1}, "direction": 0, "items": {}, "size": {"w": 1, "h": 1},
      "summary": ""}, False),
    ({"plan": "p1", "anchor": {"x": 1, "y": 1}, "direction": 16, "items": {}, "size": {"w": 1, "h": 1},
      "summary": ""}, False),
    ({"plan": "p1", "anchor": {"x": 1, "y": 1}, "direction": 0, "items": {"a": -1},
      "size": {"w": 1, "h": 1}, "summary": ""}, False),
    ({"supported": False, "reason": "no drill fits", "extra": 1}, False),
    ("not a dict", False),
])
async def test_plan_answer_shape(cfg, fake, monkeypatch, answer, ok):
    name = install_forge(monkeypatch, "fake_forge_shape",
                         plan=lambda task, resource=None, patch=None, options=None, *, config: answer)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    r = await c.op_plan("h1", KEY, "mining", resource={"name": "iron-ore"})
    if ok:
        assert set(r) == {"plan", "anchor", "direction", "items", "size", "summary"}
        assert r["items"] == {"electric-mining-drill": 8}
    else:
        assert set(r) == {"supported", "reason"} and r["supported"] is False
    await c.close()


# ---------------------------------------------------------------- brief / logs

async def test_brief_notes_come_only_from_forge(cfg, fake, monkeypatch):
    got = {}

    def brief_notes(config):
        got["config"] = config
        return {"profile": "vulkan-start", "notes": "Люблю ровные ряды буров.", "truncated": False}
    name = install_forge(monkeypatch, "fake_forge_notes", brief_notes=brief_notes)
    # a notes.md lying in forge_home must NOT be picked up by the server itself
    prof = cfg.forge_home / "profiles" / "other"
    prof.mkdir(parents=True)
    (prof / "notes.md").write_text("чужое", encoding="utf-8")
    c = Core(type(cfg)(**{**cfg.__dict__, "forge_profile": "other"}), make_bridge(cfg),
             poll_interval=0.01, forge_module=name)
    r = await c.op_brief("h1", KEY)
    assert "Честность" in r["rules"] and r["notes"] == "Люблю ровные ряды буров."
    assert r["profile"] == "vulkan-start" and r["helper"] == "h1" and "notes_missing" not in r
    assert got["config"] is c.cfg
    await c.close()


async def test_brief_notes_truncated_and_reason(cfg, fake, monkeypatch):
    answers = [{"profile": "p", "notes": "abc", "truncated": True},
               {"profile": "p", "notes": "", "truncated": False, "reason": "у профиля нет notes.md"},
               "junk"]
    name = install_forge(monkeypatch, "fake_forge_notes2", brief_notes=lambda config: answers.pop(0))
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    r = await c.op_brief("h1", KEY)
    assert r["notes"].startswith("abc") and "обрезано" in r["notes"]
    r = await c.op_brief("h1", KEY)
    assert r["notes"] is None and "нет notes.md" in r["notes_missing"] and r["profile"] == "p"
    r = await c.op_brief("h1", KEY)
    assert r["notes"] is None and r["notes_missing"]
    await c.close()


async def test_brief_without_forge_has_no_profile_guessing(core, cfg, tmp_path):
    # even a forge checkout with an active-profile marker and a notes.md is not looked at
    prof = cfg.forge_home / "profiles" / "vulkan-start"
    prof.mkdir(parents=True)
    (prof / "notes.md").write_text("не читать", encoding="utf-8")
    r = await core.op_brief("h1", KEY)
    assert r["notes"] is None and r["notes_missing"] and "profile" not in r
    assert "Честность" in r["rules"]


async def test_brief_forge_crash(cfg, fake, monkeypatch):
    def brief_notes(config):
        raise RuntimeError("C:/secret")
    name = install_forge(monkeypatch, "fake_forge_notes3", brief_notes=brief_notes)
    c = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module=name)
    r = await c.op_brief("h1", KEY)
    assert r["notes"] is None and "secret" not in json.dumps(r, ensure_ascii=False)
    await c.close()


async def test_logs_have_no_secrets(core, home):
    await core.op_state("h1", KEY)
    await core.op_say("h1", KEY, "hi")
    with pytest.raises(PartnerError):
        await core.op_state("h1", "w" * 40)
    lines = (home / "logs" / "h1.jsonl").read_text(encoding="utf-8").splitlines()
    recs = [json.loads(l) for l in lines]
    assert [r["tool"] for r in recs] == ["partner_state", "partner_say"]
    assert all({"t", "tool", "args", "code", "ms"} <= set(r) for r in recs)
    blob = "".join(lines)
    assert KEY not in blob and PASSWORD not in blob


async def test_admin_ops(core, fake):
    r = await core.admin_hello()
    assert r["data"]["proto"] == 1
    r = await core.admin_spawn("h3")
    assert r["data"]["helper"] == "h3"
    await core.admin_remove("h3")
    r = await core.admin_raw_events(0)
    assert "events" in r["data"]
    assert (await code_of(core.admin_spawn("BAD!"))).code == "bad_args"
