"""Build packages (docs/MCP.md «Пакеты стройки»): the schema, rights of the roles, the file that
outlives the server, and the bridge that starts packages without an agent and checks them."""
import json

import pytest

from factorio_partner import ledger as L
from factorio_partner import orders as O
from factorio_partner import validate as V
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


class Body:
    """What the fake mod says about the body: its job, queue, idle time and the owner's hold."""

    def __init__(self, mod):
        self.job = None
        self.queue = 0
        self.idle = 600
        self.hold = {}
        self.stock = {}
        self.made = {}
        self.ghosts = 0
        self.acts = []
        self.cancels = []
        mod.handlers["state"] = lambda a, e: {"helper": e.get("helper"), "job": self.job, "queue": self.queue,
                                              "idle_ticks": self.idle, "body": "character", "module_errors": 0}
        mod.handlers["owner_hold"] = lambda a, e: {"hold": self.hold}
        mod.handlers["stock"] = lambda a, e: {"containers": [], "total": {k: v for k, v in self.stock.items()
                                                                          if k in a.get("items", [])}}
        mod.handlers["rates"] = lambda a, e: {"scope": "surface", "period": "1m",
                                              "items": {k: {"made": v, "used": 0} for k, v in self.made.items()}}
        mod.handlers["ghosts"] = lambda a, e: {"count": self.ghosts}

        def act(a, e):
            job = mod.next_job
            mod.next_job += 1
            self.acts.append((job, a))
            return {"job": job, "queued_before": 0}

        def cancel(a, e):
            self.cancels.append(dict(a))
            return {"cancelled": [a.get("job")]}
        mod.handlers["act"] = act
        mod.handlers["cancel"] = cancel


@pytest.fixture
def body(fake):
    return Body(fake.mod)


def walk(x, y=0):
    return {"do": "walk", "args": {"to": {"x": x, "y": y}}}


def package(name="печи", steps=None, **kw):
    p = {"name": name, "anchor": {"x": 10, "y": 20}, "steps": steps or [walk(1), walk(2), walk(3)],
         "verify": [{"kind": "stock", "item": "iron-plate", "at_least": 100}]}
    p.update(kw)
    return p


async def refused(coro) -> PartnerError:
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


async def put(core, **kw):
    return (await core.op_ledger("h1", SKEY, "put", package(**kw)))["package"]


def status(core, pid):
    return core.ledger().get("h1", pid)


def plan_done(fake, job, status="done", **extra):
    d = {"job": job, "do": "plan", "status": status, "steps": 3, "done": 3, "failed": 0, "skipped": 0,
         "marks": "ddd"}
    d.update(extra)
    return fake.mod.emit("plan_done", d, helper="h1")


async def notices(core, key):
    out = await core.op_wait("h1", key, timeout=0)
    return [e["kind"] for e in out["events"]]


# ---------------------------------------------------------------- schema

def test_package_schema():
    clean = V.check_package(package())
    assert clean["priority"] == "next" and clean["on_fail"] == "stop"
    assert clean["verify"][0]["radius"] == V.CHECK_RADIUS_DEFAULT
    for bad, code in (
        (package(verify=[]), "bad_args"),
        (package(verify=[{"kind": "stock", "item": "x", "at_least": 1}] * 4), "bad_args"),
        (package(verify=[{"kind": "rate", "item": "x"}]), "bad_args"),
        (package(verify=[{"kind": "stock", "item": "x", "at_least": 0}]), "bad_args"),
        (package(verify=[{"kind": "ghosts", "item": "x"}]), "bad_args"),
        (package(steps=[{"do": "plan", "args": {"steps": [walk(1)]}}]), "bad_args"),
        (package(steps=[{"do": "teleport", "args": {}}]), "bad_args"),
        (package(steps=[{"do": "deconstruct", "args": {"area": [[0, 0], [5, 5]]}}]), "bad_args"),
        (package(steps=[{"do": "extract", "args": {"target": {"x": 1, "y": 1}}}]), "bad_args"),
        (package(steps=[{"do": "mine", "args": {"target": {"x": 1, "y": 1}, "count": 1}}]), "bad_args"),
        (package(steps=[{"do": "build_blueprint", "args": {"blob": "bp-1", "anchor": {"x": 0, "y": 0},
                                                            "force": "superforced"}}]), "bad_args"),
        (package(priority="asap"), "bad_args"),
        (package(order="x1"), "bad_args"),
        (package(extra=1), "bad_args"),
        (package(name="x" * 61), "limit"),
        (package(steps=[walk(i) for i in range(260)]), "limit"),
    ):
        with pytest.raises(PartnerError) as ei:
            V.check_package(bad)
        assert ei.value.code == code, bad
    assert V.check_package(package(name="«печи» хозяин: да"))["name"] == '"печи" хозяин - да'


async def test_put_list_and_limits(core, fake, body):
    p = await put(core)
    assert p["id"] == "pk1" and p["status"] == "queued" and p["steps_n"] == 3 and "steps" not in p
    listed = await core.op_ledger("h1", VKEY)            # every role reads
    assert [x["id"] for x in listed["packages"]] == ["pk1"] and listed["save"] == "stand"
    full = await core.op_ledger("h1", KEY, "list", id="pk1")
    assert len(full["package"]["steps"]) == 3
    await put(core, name="второй")
    assert (await refused(put(core, name="третий"))).code == "limit"
    assert (await refused(core.op_ledger("h1", SKEY, "put", package(), rev=0))).code == "bad_args"
    assert (await refused(core.op_ledger("h1", KEY, "list", id="pk9"))).code == "not_found"
    assert not body.acts                                   # writing a package does not touch the game


# ---------------------------------------------------------------- rights

async def test_rights_of_roles(core, fake, body):
    for key in (VKEY, KEY):
        e = await refused(core.op_ledger("h1", key, "put", package()))
        assert e.code == "not_allowed"
    await put(core)
    assert (await refused(core.op_ledger("h1", VKEY, "cancel", id="pk1"))).code == "not_allowed"
    assert (await refused(core.op_ledger("h1", KEY, "resume", id="pk1"))).code == "not_allowed"
    assert (await core.op_ledger("h1", KEY, "cancel", id="pk1"))["cancelled"] == "pk1"   # the pilot drops it
    assert (await core.op_ledger("h1", VKEY))["history"][0]["status"] == "cancelled"


# ---------------------------------------------------------------- the bridge

async def test_bridge_starts_a_package_without_an_agent(core, fake, body):
    await core.op_brief("h1", KEY)                         # the pilot has called: it gets notices
    p = await put(core)
    await core.packages.step()
    assert len(body.acts) == 1
    job, a = body.acts[0]
    assert a["do"] == "plan" and a["replace"] is False
    assert a["args"]["steps"] == package()["steps"] and a["args"]["on_fail"] == "stop"
    q = status(core, p["id"])
    assert q["status"] == "running" and q["job"] == job
    assert await notices(core, KEY) == ["package_started"]
    await core.packages.step()                             # one run at a time
    assert len(body.acts) == 1


@pytest.mark.parametrize("busy", ["job", "queue", "hold", "fresh_idle", "small_order"])
async def test_bridge_waits_for_a_free_body(core, fake, body, busy):
    if busy == "job":
        body.job = {"job": 3, "do": "walk"}
    elif busy == "queue":
        body.queue = 1
    elif busy == "hold":
        body.hold = {"h1": {"kind": "stop", "tick": 5, "seq": 1}}
    elif busy == "fresh_idle":
        body.idle = 30
    else:
        await core.op_brief("h1", VKEY)
        ev = fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": "принеси угля"}, helper=None)
        await core.op_order("h1", VKEY, ev["seq"], "принести уголь", "small")
    await put(core)
    await core.packages.step()
    assert not body.acts
    body.job, body.queue, body.hold, body.idle = None, 0, {}, 600
    core.orders.clear()
    await core.packages.step()
    assert len(body.acts) == 1


async def test_verify_by_game_ticks(core, fake, body):
    await core.op_brief("h1", KEY)
    await core.op_brief("h1", SKEY)
    p = await put(core, verify=[{"kind": "stock", "item": "iron-plate", "at_least": 100},
                                {"kind": "rate", "item": "iron-plate", "at_least": 30},
                                {"kind": "ghosts"}])
    await core.packages.step()
    job = status(core, p["id"])["job"]
    plan_done(fake, job)
    await core.packages.step()
    q = status(core, p["id"])
    assert q["status"] == "verifying" and q["verify_at"] == q["done_tick"] + O.VERIFY_TICKS
    body.stock, body.made = {"iron-plate": 150}, {"iron-plate": 45}
    fake.mod.tick = q["verify_at"] - 100                   # not yet two minutes of game
    core.packages._hello_at = -1e9
    await core.packages.step()
    assert status(core, p["id"])["status"] == "verifying"
    fake.mod.tick = q["verify_at"] + 1
    core.packages._hello_at = -1e9
    await core.packages.step()
    q = status(core, p["id"])
    assert q["status"] == "verified"
    assert [c["value"] for c in q["checks"]] == [150, 45, 0] and all(c["ok"] for c in q["checks"])
    assert "package_verified" in await notices(core, SKEY)
    assert "package_verified" in await notices(core, KEY)
    assert len(body.acts) == 1                             # a finished package is not started again


async def test_unmet_and_failed(core, fake, body):
    await core.op_brief("h1", SKEY)
    p1 = await put(core, name="a")
    await core.packages.step()
    plan_done(fake, status(core, p1["id"])["job"])
    await core.packages.step()
    fake.mod.tick += O.VERIFY_TICKS + 10
    core.packages._hello_at = -1e9
    body.stock = {"iron-plate": 40}
    await core.packages.step()                             # measures pk1, starts pk2? none queued
    q = status(core, p1["id"])
    assert q["status"] == "unmet" and q["checks"][0]["value"] == 40 and q["checks"][0]["ok"] is False
    p2 = await put(core, name="b")
    await core.packages.step()
    plan_done(fake, status(core, p2["id"])["job"], status="failed", code="no_items", at=2,
              text="step 2 (walk): no", marks="dfs", done=1, failed=1, skipped=1)
    await core.packages.step()
    q = status(core, p2["id"])
    assert q["status"] == "failed" and q["plan"]["code"] == "no_items"
    kinds = await notices(core, SKEY)
    assert "package_unmet" in kinds and "package_failed" in kinds


async def test_big_plan_goes_as_a_blob(core, fake, body):
    steps = [walk(i, i) for i in range(150)]
    assert V.json_size(steps) > V.MAX_ACT_ARGS
    await put(core, steps=steps)
    await core.packages.step()
    _, a = body.acts[0]
    assert "steps" not in a["args"] and a["args"]["blob"].startswith("bp-")
    assert json.loads(fake.mod.blob_text(a["args"]["blob"])) == steps
    assert V.json_size(a["args"]) <= V.MAX_ACT_ARGS


async def test_large_order_pauses_at_the_step_boundary(core, fake, body):
    await core.op_brief("h1", VKEY)
    await core.op_brief("h1", SKEY)
    old = await put(core, name="старый")
    await core.packages.step()
    job = status(core, old["id"])["job"]
    ev = fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": "сделай науку"}, helper=None)
    order = (await core.op_order("h1", VKEY, ev["seq"], "сделать науку", "large"))["order"]
    assert body.cancels == [{"job": job, "at_boundary": True}]
    assert status(core, old["id"])["status"] == "pausing"
    plan_done(fake, job, status="failed", code="cancelled", marks="dds", done=2, skipped=1, at=2)
    await core.packages.step()
    q = status(core, old["id"])
    assert q["status"] == "paused" and q["paused_reason"] == "owner_order" and q["from_step"] == 3
    assert "package_paused" in await notices(core, SKEY)
    # while the order is open nothing older starts; the package for the order goes first
    await core.packages.step()
    assert len(body.acts) == 1
    new = await put(core, name="наука", priority="now", order=order["id"])
    await core.op_inbox("h1", SKEY, ack=[order["id"]])
    await core.packages.step()
    assert len(body.acts) == 2 and status(core, new["id"])["status"] == "running"
    plan_done(fake, status(core, new["id"])["job"])
    await core.packages.step()
    # the new one is checked; the old one goes on from the step after the boundary
    assert len(body.acts) == 3
    _, a = body.acts[2]
    assert a["args"]["from_step"] == 3
    assert status(core, old["id"])["status"] == "running"


@pytest.mark.parametrize("text", [True, False])
async def test_owner_stop_and_resume(core, fake, body, text):
    p = await put(core)
    await core.packages.step()
    job = status(core, p["id"])["job"]
    # the mod's order: jobs.fail_all sends plan_done first, owner_stop comes after it
    extra = {"text": "step 2 (walk): stopped by owner",
             "failures": [{"step": 2, "do": "walk", "code": "cancelled", "text": "stopped by owner"}]} if text else {}
    plan_done(fake, job, status="failed", code="cancelled", marks="dfs", at=2, done=1, failed=1, skipped=1,
              **extra)
    fake.mod.emit("owner_stop", {"kind": "stop", "seq": 1, "helpers": ["h1"]}, helper=None)
    await core.packages.step()
    q = status(core, p["id"])
    assert q["status"] == "paused" and q["paused_reason"] == "owner_stop" and q["from_step"] == 2
    body.hold = {"h1": {"kind": "stop"}}
    await core.packages.step()
    assert len(body.acts) == 1
    body.hold = {}
    fake.mod.emit("owner_resume", {"seq": 2, "helpers": ["h1"]}, helper=None)
    await core.packages.step()
    assert len(body.acts) == 2 and body.acts[1][1]["args"]["from_step"] == 2


async def test_pilot_cancel_stops_the_running_plan(core, fake, body):
    p = await put(core)
    await core.packages.step()
    job = status(core, p["id"])["job"]
    out = await core.op_ledger("h1", KEY, "cancel", id=p["id"])
    assert out["was"] == "running" and out["job"] == job and body.cancels == [{"job": job}]
    plan_done(fake, job, status="failed", code="cancelled", marks="dss")
    await core.packages.step()
    assert len(body.acts) == 1 and status(core, p["id"])["status"] == "cancelled"


async def test_packages_outlive_a_restart_of_the_server(cfg, fake, body):
    c1 = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module="tests_no_such_forge_module")
    p = (await c1.op_ledger("h1", SKEY, "put", package()))["package"]
    await c1.packages.step()
    job = c1.ledger().get("h1", p["id"])["job"]
    await c1.close()
    body.job = {"job": job, "do": "plan"}
    plan_done(fake, job)                                   # the plan ends while no server runs
    body.job = None
    c2 = Core(cfg, make_bridge(cfg), poll_interval=0.01, forge_module="tests_no_such_forge_module")
    try:
        c2.packages.owner = c1.packages.owner              # the same lease owner: no 15 s wait in a test
        await c2.packages.step()
        assert c2.ledger().get("h1", p["id"])["status"] == "verifying"
        assert len(body.acts) == 1
    finally:
        await c2.close()


async def test_lost_plan_done_falls_back_to_the_checks(core, fake, body):
    p = await put(core)
    await core.packages.step()
    core.packages._state_at.clear()
    await core.packages.step()                             # the job is gone, no plan_done seen
    assert status(core, p["id"])["status"] == "verifying"


async def test_reload_reconciles(core, fake, body):
    p = await put(core)
    await core.packages.step()
    core._on_reload(5, 0)
    await core.packages.step()
    q = status(core, p["id"])
    assert q["status"] == "paused" and q["paused_reason"] == "reloaded"
    assert (await core.op_ledger("h1", SKEY, "resume", id=p["id"]))["package"]["status"] == "queued"
    await core.packages.step()
    assert len(body.acts) == 2


async def test_reload_keeps_a_plan_the_save_still_runs(core, fake, body):
    p = await put(core)
    await core.packages.step()
    job = status(core, p["id"])["job"]
    body.job = {"job": job, "do": "plan"}
    core._on_reload(5, 0)
    await core.packages.step()
    assert status(core, p["id"])["status"] == "running"


async def test_cancel_all_stops_the_waiting_packages(core, fake, body):
    await core.op_brief("h1", SKEY)
    first = await put(core, name="первый")
    second = await put(core, name="второй")
    await core.packages.step()
    job = status(core, first["id"])["job"]
    await core.op_cancel("h1", VKEY, all=True)               # the voice: «хватит» in free form
    assert status(core, second["id"])["paused_reason"] == "cancel_all"
    plan_done(fake, job, status="failed", code="cancelled", text="cancelled", marks="dss", at=1)
    await core.packages.step()
    await core.packages.step()
    assert len(body.acts) == 1                               # nothing more starts on the freed body
    assert status(core, first["id"])["paused_reason"] == "cancelled"
    assert "package_paused" in await notices(core, SKEY)
    await core.op_ledger("h1", SKEY, "cancel", id=first["id"])
    await core.op_ledger("h1", SKEY, "resume", id=second["id"])
    await core.packages.step()
    assert len(body.acts) == 2 and status(core, second["id"])["status"] == "running"


async def test_a_plan_cancelled_past_the_bridge_holds_the_others(core, fake, body):
    first = await put(core, name="первый")
    await put(core, name="второй")
    await core.packages.step()
    job = status(core, first["id"])["job"]
    await core.op_cancel("h1", KEY, job=job)                 # the pilot cut the package's job
    plan_done(fake, job, status="failed", code="cancelled", text="cancelled", marks="dss", at=1)
    await core.packages.step()
    await core.packages.step()
    assert len(body.acts) == 1 and status(core, first["id"])["paused_reason"] == "cancelled"


async def test_small_ack_gives_the_pilot_a_moment(core, fake, body):
    await core.op_brief("h1", VKEY)
    ev = fake.mod.emit("player_said", {"player": "Owner", "owner": True, "text": "принеси угля"}, helper=None)
    order = (await core.op_order("h1", VKEY, ev["seq"], "принести уголь", "small"))["order"]
    await put(core)
    await core.op_inbox("h1", KEY, ack=[order["id"]])
    await core.packages.step()
    assert not body.acts
    fake.mod.tick += O.ACK_GRACE_TICKS + 1
    await core.packages.step()
    assert len(body.acts) == 1


async def test_one_package_goes_to_the_body_once(core, fake, body):
    p = await put(core)
    other = O.PackageBridge(core)                            # a second server process on the save
    pkg = core.ledger().open_of("h1")[0]
    assert other._claim(p["id"], "queued")
    assert not core.packages._claim(p["id"], "queued")      # the loser does not send it
    await core.packages._maybe_post("h1")
    assert not body.acts and core.packages._candidate("h1") is None
    assert other._unclaim(p["id"], status=pkg["status"])["status"] == "queued"


async def test_a_failed_write_after_act_does_not_start_the_plan_again(core, fake, body, monkeypatch):
    p = await put(core)
    led = core.ledger()
    real = led.mutate
    calls = {"n": 0}

    def flaky(fn):
        calls["n"] += 1
        if calls["n"] == 2:                                   # 1 — the claim, 2 — the write after act
            raise PartnerError("internal", "the packages file is locked by another server process")
        return real(fn)
    monkeypatch.setattr(led, "mutate", flaky)
    await core.packages.step()
    assert len(body.acts) == 1 and status(core, p["id"])["status"] == "posting"
    await core.packages.step()
    q = status(core, p["id"])
    assert len(body.acts) == 1 and q["status"] == "running" and q["job"] == body.acts[0][0]


async def test_cancel_while_posting_cancels_the_plan(core, fake, body):
    p = await put(core)
    real = fake.mod.handlers["act"]

    def act_then_cancel(a, e):
        out = real(a, e)
        core.ledger().mutate(lambda d: L.find(d, p["id"]).update(status="cancelled"))
        return out
    fake.mod.handlers["act"] = act_then_cancel
    await core.packages.step()
    assert body.cancels == [{"job": body.acts[0][0]}]
    assert status(core, p["id"])["status"] == "cancelled"


async def test_a_package_left_in_posting_by_a_dead_process(core, fake, body):
    p = await put(core)
    core.ledger().mutate(lambda d: L.find(d, p["id"]).update(status="posting", posting_from="queued",
                                                           posting_by="dead", posting_at=0))
    await core.packages.step()                             # the body is idle: it never went, so it goes now
    assert len(body.acts) == 1 and status(core, p["id"])["status"] == "running"


def test_lease_waits_for_the_lock(tmp_path, monkeypatch):
    led = L.Ledger("stand")
    led.path.parent.mkdir(parents=True, exist_ok=True)
    led._lock_path.write_text("1", encoding="utf-8")
    monkeypatch.setattr(L, "LOCK_WAIT", 0.05)
    assert not led.take_lease("a", now=100.0)             # another process holds the file
    led._lock_path.unlink()
    assert led.take_lease("a", now=100.0)


def test_lease_is_one_process_at_a_time(tmp_path):
    led = L.Ledger("stand")
    assert led.take_lease("a", now=100.0)
    assert not led.take_lease("b", now=101.0)
    assert led.take_lease("a", now=102.0)
    assert led.take_lease("b", now=102.0 + L.LEASE_TTL + 1)


def test_resume_step():
    assert O.resume_step({"marks": "dds", "at": 2}, 1) == 3
    assert O.resume_step({"marks": "dfs", "at": 2}, 1) == 2
    assert O.resume_step({"marks": "--dds"}, 3) == 5
    assert O.resume_step({"marks": "ddd"}, 1) is None


async def test_hand_edited_file_is_checked_again(core, fake, body):
    await core.op_brief("h1", SKEY)
    p = await put(core)
    led = core.ledger()

    def spoil(d):
        L.find(d, p["id"])["steps"] = [{"do": "teleport", "args": {"to": {"x": 0, "y": 0}}}]
    led.mutate(spoil)
    await core.packages.step()
    assert not body.acts
    q = status(core, p["id"])
    assert q["status"] == "failed" and q["plan"]["code"] == "bad_args"
    assert "package_failed" in await notices(core, SKEY)


async def test_server_runs_the_bridge_while_it_lives(core, monkeypatch):
    import asyncio

    from factorio_partner.server import build_server
    ran, stopped = asyncio.Event(), asyncio.Event()

    async def fake_run():
        ran.set()
        try:
            await asyncio.sleep(3600)
        finally:
            stopped.set()
    monkeypatch.setattr(core.packages, "run", fake_run)
    srv = build_server(core)
    async with srv._mcp_server.lifespan(srv._mcp_server):
        await asyncio.wait_for(ran.wait(), 1)
    assert stopped.is_set()
