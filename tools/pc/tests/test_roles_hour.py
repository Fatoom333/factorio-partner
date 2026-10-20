"""Сценарий roles_hour против фейкового RCON: модель мода с «ролями» внутри (пакеты пишутся в файл сейва)."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    return lc.load_scenario("roles_hour", os.path.join(PC_DIR, "scenarios"))


class World:
    """Помощник и сундуки. `script` — что «роли» делают при очередном опросе state (по одному шагу)."""

    def __init__(self, chests=None, script=None, errors_grow=False, mod="factorio-partner 0.6.0"):
        self.chests = list(chests or [])
        self.script = list(script or [])
        self.errors_grow = errors_grow
        self.mod = mod
        self.tick = 1000
        self.state_calls = 0
        self.idle = 0
        self.job = None
        self.module_errors = 0
        self.ops, self.commands = [], []
        self.ledger_path = None

    def __call__(self, cmd):
        self.commands.append(cmd)
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}
        self.ops.append(op)

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": self.tick, "seq": 0, "id": env["id"], "data": data})

        if op == "hello":
            return ok({"proto": 1, "mod": self.mod, "players_online": 0, "seq": 0, "module_errors": self.module_errors})
        if op == "helper_spawn":
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "vulcanus", "pos": {"x": 10, "y": 20}})
        if op == "state":
            self.state_calls += 1
            if self.script and self.state_calls > 1:      # первый state — снимок начала, роли ещё не начали
                self.script.pop(0)(self)
            self.tick += 3600
            if self.errors_grow:
                self.module_errors += 1
            st = {"helper": env["helper"], "pos": {"x": 10.5, "y": 20.5}, "idle_ticks": self.idle,
                  "tick": self.tick, "busy_share": 0.4 if self.job else 0.1}
            if self.job:
                st["job"] = {"job": 1, "do": self.job}
            return ok(st)
        if op == "map":
            assert args["radius"] <= 32 and set(args["names"]) <= {"wooden-chest", "iron-chest", "steel-chest"}
            ents = [{"c": "C", "name": c["name"], "pos": c["pos"]} for c in self.chests]
            return ok({"entities": ents or [], "rows": [], "bbox": {}})
        raise AssertionError(op)


def write_ledger(world, packages=(), history=()):
    with open(world.ledger_path, "w", encoding="utf-8") as f:
        json.dump({"version": 1, "rev": 1, "next": 9, "packages": list(packages), "history": list(history)}, f)


def package(pid, status):
    return {"id": pid, "name": "сундуки", "status": status}


def strategist_puts(pid="pk1"):
    def step(w):
        write_ledger(w, [package(pid, "running")])
        w.job = "plan"
    return step


def verified(pid="pk1"):
    def step(w):
        write_ledger(w, [], [package(pid, "verified")])
        w.job = None
    return step


def place(name, x):
    def step(w):
        w.chests.append({"name": name, "pos": {"x": x, "y": 20.5}})
        w.job = "place"
    return step


def settle(w):
    w.job = None
    w.idle = 900


@pytest.fixture(autouse=True)
def fast(monkeypatch, tmp_path):
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)
    monkeypatch.setattr(lc.time, "sleep", lambda s: None)
    monkeypatch.setenv("FP_BENCH_DIR", str(tmp_path / "bench"))
    monkeypatch.setenv("FP_NOTES_DIR", str(tmp_path / "notes"))
    monkeypatch.setenv("FP_SAVE_NAME", "roles-test")
    monkeypatch.delenv("FP_BENCH_PHASE", raising=False)


def run(world, fake_rcon, tmp_path, **patch):
    sc = load()
    sc.WAIT_S = 2.0
    for k, v in patch.items():
        setattr(sc, k, v)
    world.ledger_path = str(tmp_path / "notes" / "roles-test" / "packages.json")
    srv = fake_rcon(handler=world)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = sc.run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)
    return res


def test_done_settles_early(fake_rcon, tmp_path):
    w = World(script=[strategist_puts(), place("wooden-chest", 12.5), place("wooden-chest", 13.5), verified(), settle])
    res = run(w, fake_rcon, tmp_path)
    assert res["ok"] is True and res["verdict"] == "done", res
    assert res["chests_new"] == 2 and res["score"] == 1.0 and res["ended_by"] == "settled"
    assert res["packages"]["verified"] == 1 and res["packages"]["total"] == 1 and res["packages"]["open"] == 0
    assert res["packages"]["first_package_min"] == 1.0 and res["packages"]["first_verified_min"] == 4.0
    assert res["body"]["game_minutes"] > 0 and 0 < res["body"]["busy_share_mean"] < 1
    assert res["module_errors"] == 0 and "goal" in res


def test_prepare_writes_auto_rule_into_notes(fake_rcon, tmp_path):
    w = World()
    res = run(w, fake_rcon, tmp_path, WAIT_S=0.05)
    text = (tmp_path / "notes" / "roles-test" / "rules.md").read_text(encoding="utf-8")
    assert text.splitlines()[2].startswith("1. AUTO: ") and res["rule"] in text
    # цель короче лимита самостоятельного режима (savenotes.MAX_GOAL = 100)
    assert len(res["rule"]) - len("AUTO: ") <= 100


def test_owner_words_are_marked_for_the_owner(fake_rcon, tmp_path):
    res = run(World(), fake_rcon, tmp_path, WAIT_S=0.05)
    assert res["owner_words"]["status"] == "проверяется хозяином в игре" and res["owner_words"]["items"]


def test_unmet_and_failed_counted_and_verdict_partial(fake_rcon, tmp_path):
    def mixed(w):
        write_ledger(w, [package("pk3", "queued")], [package("pk1", "unmet"), package("pk2", "failed")])
    res = run(World(script=[mixed]), fake_rcon, tmp_path, WAIT_S=0.05)
    p = res["packages"]
    assert (p["total"], p["unmet"], p["failed"], p["open"], p["verified"]) == (3, 1, 1, 1, 0)
    assert res["verdict"] == "partial" and res["ok"] is False


def test_chests_without_verified_package_is_partial(fake_rcon, tmp_path):
    res = run(World(script=[place("wooden-chest", 12.5), place("wooden-chest", 13.5)]), fake_rcon, tmp_path, WAIT_S=0.05)
    assert res["chests_new"] == 2 and res["verdict"] == "partial" and res["score"] == 0.5


def test_none_when_nobody_did_anything(fake_rcon, tmp_path):
    res = run(World(), fake_rcon, tmp_path, WAIT_S=0.05)
    assert res["verdict"] == "none" and res["score"] == 0.0 and res["packages"]["total"] == 0


def test_old_packages_do_not_count(fake_rcon, tmp_path):
    w = World()
    path = tmp_path / "notes" / "roles-test"
    path.mkdir(parents=True)
    (path / "packages.json").write_text(json.dumps(
        {"version": 1, "rev": 3, "next": 4, "packages": [], "history": [package("pk0", "verified")]}), encoding="utf-8")
    res = run(w, fake_rcon, tmp_path, WAIT_S=0.05)
    assert res["packages"]["total"] == 0 and res["verdict"] == "none"


def test_existing_chests_do_not_count(fake_rcon, tmp_path):
    old = [{"name": "wooden-chest", "pos": {"x": 11.5, "y": 20.5}}]
    res = run(World(chests=old), fake_rcon, tmp_path, WAIT_S=0.05)
    assert res["chests_new"] == 0


def test_stop_file_ends_wait(fake_rcon, tmp_path):
    def stop(w):
        open(os.path.join(str(tmp_path / "bench"), "stop"), "w").close()
    res = run(World(script=[strategist_puts(), stop]), fake_rcon, tmp_path)
    assert res["ended_by"] == "stop_file" and res["verdict"] == "partial"


def test_broken_ledger_fails_the_run(fake_rcon, tmp_path):
    def broken(w):
        with open(w.ledger_path, "w", encoding="utf-8") as f:
            f.write("{не json")
    res = run(World(script=[broken]), fake_rcon, tmp_path, WAIT_S=0.05)
    assert res["ok"] is False and any("packages.json" in r for r in res["reasons"])


def test_module_errors_growth_fails_even_when_done(fake_rcon, tmp_path):
    w = World(script=[strategist_puts(), place("wooden-chest", 12.5), place("wooden-chest", 13.5), verified(), settle],
              errors_grow=True)
    res = run(w, fake_rcon, tmp_path)
    assert res["verdict"] == "done" and res["ok"] is False
    assert any("module_errors" in r for r in res["reasons"])


def test_no_notes_dir_is_setup_failure(fake_rcon, tmp_path, monkeypatch):
    monkeypatch.delenv("FP_NOTES_DIR")
    res = run(World(), fake_rcon, tmp_path)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and "FP_NOTES_DIR" in res["error"]["text"]


def test_bad_save_name_is_setup_failure(fake_rcon, tmp_path, monkeypatch):
    monkeypatch.setenv("FP_SAVE_NAME", "../x")
    res = run(World(), fake_rcon, tmp_path)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_wrong_mod_is_setup_failure(fake_rcon, tmp_path):
    res = run(World(mod="partner-test 0.1.0"), fake_rcon, tmp_path)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_prepare_then_judge_phases(fake_rcon, tmp_path, monkeypatch):
    w = World()
    monkeypatch.setenv("FP_BENCH_PHASE", "prepare")
    res = run(w, fake_rcon, tmp_path)
    assert res["ok"] is True and res["phase"] == "prepare" and res["goal"] and w.ops.count("state") == 1
    assert os.path.exists(tmp_path / "bench" / "ready")
    w.chests += [{"name": "wooden-chest", "pos": {"x": 12.5, "y": 20.5}}, {"name": "iron-chest", "pos": {"x": 14.5, "y": 20.5}}]
    write_ledger(w, [], [package("pk1", "verified")])
    monkeypatch.setenv("FP_BENCH_PHASE", "judge")
    res = run(w, fake_rcon, tmp_path)
    assert res["verdict"] == "done" and res["ok"] is True


def test_judge_without_baseline_is_setup_failure(fake_rcon, tmp_path, monkeypatch):
    monkeypatch.setenv("FP_BENCH_PHASE", "judge")
    res = run(World(), fake_rcon, tmp_path)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_bad_phase_is_refused(fake_rcon, tmp_path, monkeypatch):
    monkeypatch.setenv("FP_BENCH_PHASE", "хм")
    res = run(World(), fake_rcon, tmp_path)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_package_counts_is_pure():
    sc = load()
    pk = [package("a", "verified"), package("a", "verified"), package("b", "paused"), package("c", "weird")]
    c = sc.package_counts(pk, known={"c"})
    assert c["total"] == 2 and c["verified"] == 1 and c["open"] == 1
    base = {"chests": {"x": "wooden-chest"}}
    assert sc.evaluate(base, {"x": 1, "y": 1, "z": 1}, c)["verdict"] == "done"
    assert sc.evaluate(base, {"x": 1, "y": 1, "z": 1}, dict(c, verified=0))["verdict"] == "partial"
