"""Сценарий core_respawn против фейкового RCON с моделью общей перезарядки helper_spawn."""
from __future__ import annotations

import json
import os

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    m = lc.load_scenario("core_respawn", os.path.join(PC_DIR, "scenarios"))
    m.POLL_S = 0.0       # время модели идёт по запросам, ждать незачем
    return m


class Model:
    """PROTOCOL §4: перезарядка 10 с общая; 10 с..5 мин — точка возрождения, позже — хозяин."""

    def __init__(self, tick_step=100, cooldown=600, per_id=False, at_owner=False, no_at=False, frozen=False,
                 last_gone=None, crash=False):
        self.tick = 1000
        self.tick_step = tick_step          # столько тиков проходит за один hello
        self.cooldown = cooldown            # 18000 — старый мод с пятью минутами
        self.per_id = per_id                # ошибка: перезарядка только у того же id
        self.at_owner = at_owner            # ошибка: после 10 с тело ставится у хозяина
        self.no_at = no_at                  # мод до 3.4: поля at нет
        self.frozen = frozen                # игра на паузе: тик не идёт
        self.last_gone = last_gone          # тик последнего удаления / смерти любого тела
        self.gone = {}                      # id -> тик удаления
        self.crash = crash
        self.alive = []
        self.module_errors = 0
        self.ops = []

    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {")
        env = json.loads(cmd[len("/partner "):])
        op, helper = env["op"], env.get("helper")
        self.ops.append((op, helper))

        def ok(data):
            return json.dumps({"v": 1, "id": env["id"], "ok": True, "tick": self.tick, "seq": 0, "data": data})

        def fail(code, text=""):
            return json.dumps({"v": 1, "id": env["id"], "ok": False, "tick": self.tick, "seq": 0,
                               "error": {"code": code, "text": text}})

        if op == "hello":
            if not self.frozen:
                self.tick += self.tick_step
            return ok({"proto": 1, "mod": "0.4.1", "owner": "Tartaluga", "module_errors": self.module_errors})
        if op == "helper_list":
            out = [{"id": h, "state": "alive", "body": "character", "surface": "nauvis"} for h in self.alive]
            for h, t in self.gone.items():
                left = self.cooldown - (self.tick - t)
                rec = {"id": h, "state": "removed"}
                if left > 0:
                    rec["cooldown_s"] = -(-left // 60)
                out.append(rec)
            return ok({"helpers": out})
        if op == "helper_spawn":
            if helper in self.alive:
                return fail("helper_exists")
            since = self.gone.get(helper) if self.per_id else self.last_gone
            recent = since is not None and self.tick - since < 18000
            if since is not None and self.tick - since < self.cooldown:
                reply = fail("cooldown", "wait")
                if not self.frozen:
                    self.tick += self.tick_step
                return reply
            self.alive.append(helper)
            self.gone.pop(helper, None)
            if self.crash:
                self.module_errors += 1
            data = {"helper": helper, "unit_number": 100 + len(self.ops), "surface": "nauvis",
                    "pos": {"x": 0.5, "y": 0.5} if recent else {"x": 40.5, "y": -3.5}}
            if not self.no_at:
                data["at"] = "respawn_point" if recent and not self.at_owner else "owner"
            return ok(data)
        if op == "helper_remove":
            if helper not in self.alive:
                return fail("no_helper")
            self.alive.remove(helper)
            self.gone[helper] = self.last_gone = self.tick
            return ok({})
        return fail("unknown_op", op)


def run(fake_rcon, **kw):
    model = Model(**kw)
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load().run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)  # только /partner <JSON>
    return res, model


def errors(res):
    return {s["name"]: s.get("error", "") for s in res["steps"] if not s["ok"]}


def test_respawn_ok(fake_rcon):
    res, model = run(fake_rcon)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == [
        "hello", "first_spawn", "remove", "cooldown_same", "cooldown_other", "wait_10s", "respawn_point",
        "cleanup", "hello_end"]
    info = {s["name"]: s.get("info") for s in res["steps"]}
    assert info["first_spawn"]["at"] == "owner" and info["remove"]["cooldown_s"] == 10
    assert info["wait_10s"]["ticks_after_remove"] >= 630
    assert info["respawn_point"]["at"] == "respawn_point" and info["respawn_point"]["from_first_spawn"] == 44.0
    # оба id спрошены до границы; тело после сценария убрано
    assert [h for op, h in model.ops if op == "helper_spawn"] == ["rsp-a", "rsp-a", "rsp-b", "rsp-a"]
    assert model.alive == [] and res["log_must_not_match"]


def test_respawn_waits_out_a_cooldown_left_in_the_save(fake_rcon):
    # сейв сохранён сразу после чьей-то смерти: первый spawn ждёт её перезарядку и встаёт в точке возрождения
    res, model = run(fake_rcon, last_gone=900)
    assert res["ok"] is True, res
    first = res["steps"][1]["info"]
    assert first["at"] == "respawn_point" and first["waited_s"] >= 1


def test_respawn_old_five_minute_cooldown_fails(fake_rcon):
    res, model = run(fake_rcon, cooldown=18000)
    bad = errors(res)
    assert res["ok"] is False and "remove" in bad and "cooldown_s" in bad["remove"], res
    assert model.alive == []


def test_respawn_cooldown_must_be_shared(fake_rcon):
    res, model = run(fake_rcon, per_id=True)
    bad = errors(res)
    assert "cooldown_other" in bad and "cooldown" in bad["cooldown_other"], res
    assert model.alive == [], "лишний помощник убран и при провале"


def test_respawn_must_be_at_the_respawn_point(fake_rcon):
    res, model = run(fake_rcon, at_owner=True)
    bad = errors(res)
    assert list(bad) == ["respawn_point"] and "точке возрождения" in bad["respawn_point"], res
    assert model.alive == []


def test_respawn_needs_the_at_field(fake_rcon):
    res, model = run(fake_rcon, no_at=True)
    assert res["ok"] is False and res["failed"] == ["first_spawn"] and "aborted" in res
    assert model.alive == []


def test_respawn_paused_game_is_reported(fake_rcon):
    m = load()
    m.WAIT_REAL_S = 1.0
    model = Model(frozen=True)
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = m.run(c)
    bad = errors(res)
    assert list(bad) == ["wait_10s"] and "пауз" in bad["wait_10s"], res
    assert "respawn_point" not in [s["name"] for s in res["steps"]]


def test_respawn_module_errors_growth_fails(fake_rcon):
    res, _ = run(fake_rcon, crash=True)
    assert res["failed"] == ["hello_end"]
