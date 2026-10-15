"""Сценарии belt_* против фейкового RCON с моделью мода: map → plan_belt → сверка с картой."""
from __future__ import annotations

import json
import os
from collections import deque

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR

HELPER_POS = {"x": 10.3, "y": 4.2}
VEC = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}
WORLD = 200             # мир модели: клетки -200..200, дальше — не открыто


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


def default_tiles():
    """Полоса жидкости поперёк (x 20..23, y -30..30), руда у её края и остров в озере."""
    tiles = {}
    for x in range(20, 24):
        for y in range(-30, 31):
            tiles[(x, y)] = "~"
    for x in range(14, 17):
        for y in range(1, 4):
            tiles[(x, y)] = "i"
    for x in range(47, 78):
        for y in range(87, 118):
            tiles[(x, y)] = "~"
    for x in range(60, 65):
        for y in range(100, 105):
            tiles[(x, y)] = "."
    return tiles


class Model:
    """Модель мода: местность символами, призраки, действие plan_belt (поиск в ширину по земле,
    подземный — только через призраки). Флаги ломают что-то одно — сценарий должен это заметить."""

    def __init__(self, tiles=None, mod="factorio-partner 0.1.0", gap=False, wet=False, miscount=0,
                 no_under=False, tunnel_liquid=False, island_reached=False, never_fails=False,
                 no_reached=False, eats_first=False):
        self.mod = mod
        self.tiles = default_tiles() if tiles is None else tiles
        self.ghosts = {}      # (x, y) -> (имя, dir)
        self.events = []
        self.seq = 0
        self.job = 0
        self.acts = []
        self.gap = gap                      # один призрак «не встал» (дыра в цепочке)
        self.wet = wet                      # путь идёт по прямой, не глядя на жидкость
        self.miscount = miscount            # ответ врёт о числе призраков
        self.no_under = no_under            # через призраки не идёт под землёй, а обходит
        self.tunnel_liquid = tunnel_liquid  # подземный под жидкостью
        self.island_reached = island_reached
        self.never_fails = never_fails
        self.no_reached = no_reached
        self.eats_first = eats_first        # вторая лента сносит призрак первой

    # ---- местность
    def ch(self, c):
        if abs(c[0]) > WORLD or abs(c[1]) > WORLD:
            return "?"
        if c in self.ghosts:
            return "g"
        return self.tiles.get(c, ".")

    def free(self, c):
        return self.ch(c) in ".i"

    # ---- события
    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "belt", "kind": kind, "data": data, "loud": True})

    def _failed(self, code, text, detail=None):
        self._emit("job_failed", {"job": self.job, "do": "plan_belt", "code": code, "text": text, "detail": detail or {}})

    # ---- путь
    def _search(self, a, b, underground):
        """→ список шагов (клетка, имя, dir) | None, ближайшая к цели клетка."""
        prev = {a: None}
        queue = deque([a])
        best = a
        while queue:
            cur = queue.popleft()
            if abs(cur[0] - b[0]) + abs(cur[1] - b[1]) < abs(best[0] - b[0]) + abs(best[1] - b[1]):
                best = cur
            if cur == b:
                break
            for d, (dx, dy) in VEC.items():
                n = (cur[0] + dx, cur[1] + dy)
                jump = None
                if self.free(n) or (self.wet and self.ch(n) == "~"):
                    jump = (n, d, False)
                elif underground and self.ch(n) == "g" and self.free((n[0] + dx, n[1] + dy)):
                    jump = ((n[0] + dx, n[1] + dy), d, True)
                elif self.tunnel_liquid and self.ch(n) == "~":
                    k = 1
                    while self.ch((cur[0] + dx * k, cur[1] + dy * k)) == "~" and k < 8:
                        k += 1
                    far = (cur[0] + dx * k, cur[1] + dy * k)
                    if self.free(far):
                        jump = (far, d, True)
                if jump and jump[0] not in prev and (abs(jump[0][0] - a[0]) + abs(jump[0][1] - a[1])) < 400:
                    prev[jump[0]] = (cur, jump[1], jump[2])
                    queue.append(jump[0])
        if b not in prev:
            return None, best
        steps = []
        cur, out_dir, out_under = b, None, False
        came_under = False
        while cur is not None:
            p = prev[cur]
            came_under = bool(p and p[2])
            d = out_dir if out_dir is not None else (p[1] if p else 4)
            name = "underground-belt" if (out_under or came_under) else "transport-belt"
            if came_under and not out_under:
                d = p[1]
            steps.append((cur, name, d))
            if p is None:
                break
            cur, out_dir, out_under = p[0], p[1], p[2]
        steps.reverse()
        return steps, best

    def _plan(self, a):
        self.job += 1
        self.acts.append(a)
        src = (int(a["from"]["x"] // 1), int(a["from"]["y"] // 1))
        dst = (int(a["to"]["x"] // 1), int(a["to"]["y"] // 1))
        if self.ch(dst) == "~" and not self.never_fails:
            return self._failed("cannot_place", "the end is on a tile where a belt cannot stand")
        mode = a.get("underground", "auto")
        steps, best = self._search(src, dst, mode != "never" and not self.no_under)
        if steps is None:
            if self.never_fails:
                steps = [(src, "transport-belt", 4)]
            else:
                reached = dst if self.island_reached else best
                detail = {} if self.no_reached else {"reached": {"x": reached[0] + 0.5, "y": reached[1] + 0.5},
                                                     "reason": "unreachable", "expanded": 100}
                return self._failed("path_failed", "no belt path to the target (unreachable)", detail)
        need = {}
        for _, name, _ in steps:
            need[name] = need.get(name, 0) + 1
        xs = [c[0] for c, _, _ in steps]
        ys = [c[1] for c, _, _ in steps]
        under = need.get("underground-belt", 0) // 2
        length = len(steps)
        for i in range(len(steps) - 1):
            if steps[i][1] == "underground-belt" and steps[i + 1][1] == "underground-belt":
                (x1, y1), (x2, y2) = steps[i][0], steps[i + 1][0]
                length += abs(x2 - x1) + abs(y2 - y1) - 1
        detail = {"ghosts": len(steps) + self.miscount, "length": length, "undergrounds": under, "turns": 0,
                  "need": need, "lanes": 1, "warnings": [],
                  "chosen": {"belt": "transport-belt", "underground": "underground-belt"},
                  "path": [{"x": src[0] + 0.5, "y": src[1] + 0.5}, {"x": dst[0] + 0.5, "y": dst[1] + 0.5}],
                  "area": {"left_top": {"x": min(xs), "y": min(ys)}, "right_bottom": {"x": max(xs) + 1, "y": max(ys) + 1}}}
        if a.get("dry_run"):
            detail["dry_run"] = True
        else:
            placed = steps[:len(steps) // 2] + steps[len(steps) // 2 + 1:] if self.gap else steps
            if self.eats_first and self.ghosts:
                del self.ghosts[next(iter(self.ghosts))]
            for cell, name, d in placed:
                self.ghosts[cell] = (name, d)
        self._emit("job_done", {"job": self.job, "do": "plan_belt", "detail": detail})

    # ---- RCON
    def __call__(self, command):
        if command == "/quit":
            return None
        assert command.startswith("/partner ")
        env = json.loads(command[len("/partner "):])
        op, args = env["op"], env.get("args") or {}

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": self.seq, "id": env["id"], "data": data})

        def fail(code):
            return json.dumps({"v": 1, "ok": False, "tick": 1, "seq": self.seq, "id": env["id"],
                               "error": {"code": code, "text": code}})

        if op == "hello":
            return ok({"owner": "Tartaluga", "mod": self.mod, "proto": 1, "players_online": 0})
        if op == "helper_spawn":
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "vulcanus", "pos": dict(HELPER_POS)})
        if op == "state":
            return ok({"helper": env["helper"], "surface": "vulcanus", "pos": dict(HELPER_POS)})
        if op == "map":
            assert args["radius"] <= 32
            c, r = args["center"], int(args["radius"])
            x0, y0 = int(c["x"] // 1) - r, int(c["y"] // 1) - r
            x1, y1 = x0 + 2 * r, y0 + 2 * r
            names = args.get("names")
            data = {"bbox": {"x0": x0, "y0": y0, "x1": x1, "y1": y1}, "entities": [], "truncated": False}
            if names is None:
                data["rows"] = ["".join(self.ch((x, y)) for x in range(x0, x1 + 1)) for y in range(y0, y1 + 1)]
                data["legend"] = {".": "земля", "~": "не пройти: lava", "i": "руда: iron-ore", "g": "призрак", "?": "не открыто"}
            else:
                ents = [{"c": "g", "name": v[0], "pos": {"x": k[0] + 0.5, "y": k[1] + 0.5}, "dir": v[1], "ghost": True}
                        for k, v in self.ghosts.items() if v[0] in names and x0 <= k[0] <= x1 and y0 <= k[1] <= y1]
                data["entities"] = ents[:100]
                data["truncated"] = len(ents) > 100
                data["rows"] = []
            return ok(data)
        if op == "ghosts":
            if "area" in args:
                a = args["area"]
                assert a["right_bottom"]["x"] - a["left_top"]["x"] <= 128
                inside = [k for k in self.ghosts if a["left_top"]["x"] <= k[0] < a["right_bottom"]["x"]
                          and a["left_top"]["y"] <= k[1] < a["right_bottom"]["y"]]
            else:
                c, r = args["center"], args["radius"]
                inside = [k for k in self.ghosts if abs(k[0] - c["x"]) <= r and abs(k[1] - c["y"]) <= r]
            return ok({"count": len(inside), "by_name": {}, "need": {}, "blocked": [], "blocked_total": 0})
        if op == "act":
            assert args["do"] == "plan_belt"
            self._plan(args["args"])
            return ok({"job": self.job, "queued_before": 0})
        if op == "events":
            evs = [e for e in self.events if e["seq"] > args["since"]]
            return ok({"seq": self.seq, "events": evs, "lost": False})
        if op == "cancel":
            return ok({"cancelled": []})
        return fail("unknown_op")


def run(name, model, fake_rcon):
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load(name).run(c)
    # всё, что ушло в игру, — конверты /partner
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)
    json.dumps(res)  # итог сценария пишется в results-N.json
    return res


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    """Паузы сценариев (опрос событий) в офлайн-тестах не нужны."""
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)


# ---------- belt_plan ----------

def test_plan_ok(fake_rcon):
    m = Model()
    res = run("belt_plan", m, fake_rcon)
    assert res["ok"] is True, res
    assert res["terrain"]["maps"] == 25 and res["terrain"]["liquid"] > 0
    p = res["points"]
    assert p["near_ore"] is True
    assert 40 <= p["span"] <= 80 and p["liquid"] == 4 and p["land_path"] > p["span"]
    assert p["from"][1] == p["to"][1] and p["from"][0] < 20 and p["to"][0] > 23
    assert [bool(a.get("dry_run")) for a in m.acts] == [True, False]
    assert set(m.acts[1]) == {"from", "to"}
    assert res["chain"]["on_map"] == res["chain"]["chain"] == res["plan"]["data"]["detail"]["ghosts"]
    assert res["chain"]["on_liquid"] == 0 and res["chain"]["under_liquid"] == 0
    assert res["ghosts_op"]["after"] - res["ghosts_op"]["before"] == res["chain"]["on_map"]


@pytest.mark.parametrize("flags, text", [
    ({"gap": True}, "лента рвётся"),
    ({"wet": True}, "призраки на жидкости"),
    ({"miscount": 2}, "в ответе"),
    ({"tunnel_liquid": True}, "подземный участок под жидкостью"),
])
def test_plan_notices_broken_belt(fake_rcon, flags, text):
    res = run("belt_plan", Model(**flags), fake_rcon)
    assert res["ok"] is False
    assert any(text in r for r in res["reasons"]), res["reasons"]


def test_plan_straight_line_is_not_a_detour(fake_rcon):
    res = run("belt_plan", Model(wet=True), fake_rcon)
    assert any("не обход" in r for r in res["reasons"]), res["reasons"]


def test_plan_no_liquid_is_setup_error(fake_rcon):
    res = run("belt_plan", Model(tiles={}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_plan_wrong_mod(fake_rcon):
    res = run("belt_plan", Model(mod="partner-test 0.1.0"), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_plan_failed_job_is_reported(fake_rcon):
    m = Model()
    m._search = lambda a, b, u: (None, a)
    res = run("belt_plan", m, fake_rcon)
    assert res["ok"] is False
    assert any("path_failed" in r for r in res["reasons"]), res["reasons"]


# ---------- belt_under ----------

def test_under_ok(fake_rcon):
    m = Model()
    res = run("belt_under", m, fake_rcon)
    assert res["ok"] is True, res
    assert m.acts[0]["underground"] == "never" and "underground" not in m.acts[1]
    assert m.acts[1]["dry_run"] is True and "underground" not in m.acts[1]   # проба: берёт ли auto подземный
    assert "underground" not in m.acts[2] and "dry_run" not in m.acts[2]
    assert m.acts[3]["underground"] == "prefer" and m.acts[3]["dry_run"] is True
    assert m.acts[4]["underground"] == "prefer" and "dry_run" not in m.acts[4]
    assert res["first_chain"]["on_map"] == 41
    assert res["second_chain"]["undergrounds"] == 1
    pair = res["second_chain"]["pairs"][0]
    side = res["square"]["corner"]
    assert pair[0][0] < side[0] + 20 < pair[1][0]
    assert res["liquid"]["found"] is True and res["prefer_chain"]["under_liquid"] == 0


@pytest.mark.parametrize("flags, text", [
    ({"no_under": True}, "без подземного участка"),
    ({"eats_first": True}, "призраки первой ленты изменились"),
    ({"gap": True}, "лента рвётся"),
    ({"tunnel_liquid": True}, "подземный участок под жидкостью"),
])
def test_under_notices(fake_rcon, flags, text):
    res = run("belt_under", Model(**flags), fake_rcon)
    assert res["ok"] is False
    assert any(text in r for r in res["reasons"]), res["reasons"]


def test_under_without_liquid_cannot_check_part_two(fake_rcon):
    res = run("belt_under", Model(tiles={}), fake_rcon)
    assert res["ok"] is False and res["liquid"] == {"found": False}
    assert res["second_chain"]["undergrounds"] == 1   # часть 1 при этом прошла


# ---------- belt_fail ----------

def test_fail_ok(fake_rcon):
    m = Model()
    res = run("belt_fail", m, fake_rcon)
    assert res["ok"] is True, res
    assert res["points"]["island_cells"] == 25
    assert 60 <= res["points"]["to"][0] <= 64 and 100 <= res["points"]["to"][1] <= 104
    assert res["plan"]["kind"] == "job_failed" and res["plan"]["data"]["code"] == "path_failed"
    assert res["ghosts_op"]["before"] == res["ghosts_op"]["after"] == 0
    assert res["on_liquid"]["code"] == "cannot_place"
    assert not m.ghosts


@pytest.mark.parametrize("flags, text", [
    ({"never_fails": True}, "ждали job_failed{path_failed}"),
    ({"no_reached": True}, "нет reached"),
    ({"island_reached": True}, "на острове"),
])
def test_fail_notices(fake_rcon, flags, text):
    res = run("belt_fail", Model(**flags), fake_rcon)
    assert res["ok"] is False
    assert any(text in r for r in res["reasons"]), res["reasons"]


def test_fail_never_fails_leaves_ghosts(fake_rcon):
    res = run("belt_fail", Model(never_fails=True), fake_rcon)
    assert any("призраков стало" in r for r in res["reasons"]), res["reasons"]


def test_fail_no_island_is_setup_error(fake_rcon):
    tiles = {k: v for k, v in default_tiles().items() if k[1] < 80}
    m = Model(tiles=tiles)
    res = run("belt_fail", m, fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_fail_narrow_moat_is_not_an_island(fake_rcon):
    """Ров уже, чем достаёт подземный конвейер, — не остров с подземным; сценарий берёт его только
    запретив подземные (`underground: never`) и помечает это в результате."""
    tiles = default_tiles()
    for x in range(47, 78):
        for y in range(87, 118):
            if not (55 <= x <= 69 and 95 <= y <= 109):
                tiles.pop((x, y), None)
    m = Model(tiles=tiles)
    res = run("belt_fail", m, fake_rcon)
    assert "moat" in res
    assert any(a.get("underground") == "never" for a in m.acts if a.get("from")), m.acts


# ---------- общий модуль ----------

def test_follow_and_between():
    B = load("belt_plan").B
    ghosts = {(0, 0): {"name": "b", "dir": 4}, (1, 0): {"name": "u", "dir": 4}, (4, 0): {"name": "u", "dir": 4},
              (5, 0): {"name": "b", "dir": 8}, (5, 1): {"name": "b", "dir": 8}}
    path, pairs, why = B.follow(ghosts, (0, 0), "u")
    assert why is None and path == [(0, 0), (1, 0), (4, 0), (5, 0), (5, 1)]
    assert pairs == [((1, 0), (4, 0))]
    assert B.between((1, 0), (4, 0)) == [(2, 0), (3, 0)]
    del ghosts[(4, 0)]
    path, pairs, why = B.follow(ghosts, (0, 0), "u")
    assert "нет выхода" in why and path == [(0, 0), (1, 0)]
    # петля не зацикливает
    loop = {(0, 0): {"name": "b", "dir": 4}, (1, 0): {"name": "b", "dir": 12}}
    path, _, why = B.follow(loop, (0, 0), "u")
    assert path == [(0, 0), (1, 0)] and why is None
