"""Сценарии access_live и map_liquid (поток V3) против фейкового RCON с маленькой моделью мира.

Мир модели: суша, а восточнее x = 50 — «лава» (имя плитки — данные модели, сценарии его не знают).
Модель проверяет не алгоритм мода, а то, что сценарии ловят ошибки в ответах.
"""
from __future__ import annotations

import json
import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR

HELPER_POS = {"x": 10.3, "y": 4.2}
SHORE = 50          # клетки с x >= SHORE — жидкость
TILE = "magma-sea"  # выдуманное имя: сценарии не должны на него опираться


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


class Model:
    def __init__(self, shore=SHORE, online=False, no_liquid=False, bad_exit=False, bad_best=False, no_tilde=False,
                 other_tile_on_map=False, cover_ok=False, legend=None, area_differs=False, accepts_bad=False,
                 crash=False, narrow_dry=False, liquid_without_names=False, queued=False, unknown_warning=False):
        self.shore = 10 ** 9 if no_liquid else shore
        self.online = online
        self.bad_exit = bad_exit
        self.bad_best = bad_best
        self.no_tilde = no_tilde
        self.other_tile_on_map = other_tile_on_map
        self.cover_ok = cover_ok
        self.legend = legend
        self.area_differs = area_differs
        self.accepts_bad = accepts_bad
        self.crash = crash
        self.narrow_dry = narrow_dry
        self.liquid_without_names = liquid_without_names
        self.queued = queued
        self.unknown_warning = unknown_warning
        self.alive = False
        self.module_errors = 0
        self.ops = []

    def liquid(self, x, y):
        return x >= self.shore

    def access(self, args, helper):
        if set(args) - {"area", "center", "near", "radius"}:
            return "bad_args"
        if "center" in args and "near" in args:
            return "bad_args"
        if "area" in args:
            if "radius" in args or "center" in args or "near" in args:
                return "bad_args"
            a = args["area"]
            if a["right_bottom"]["x"] - a["left_top"]["x"] > 128 or a["right_bottom"]["y"] - a["left_top"]["y"] > 128:
                return "limit"
            x0, y0, x1, y1 = a["left_top"]["x"], a["left_top"]["y"], a["right_bottom"]["x"], a["right_bottom"]["y"]
            via_area = True
        else:
            r = args.get("radius", 32)
            if not self.accepts_bad:
                if r > 64:
                    return "limit"
                if r < 1 or r != int(r):
                    return "bad_args"
            if helper is None and "center" in args and not self.online:
                return "no_player"
            c = args.get("center") or HELPER_POS
            cx, cy = math.floor(c["x"]), math.floor(c["y"])
            x0, y0, x1, y1 = cx - r, cy - r, cx + r, cy + r
            via_area = False
        cells = [(x, y) for x in range(x0, x1) for y in range(y0, y1)]
        liquid = sum(1 for x, y in cells if self.liquid(x, y))
        if via_area and self.area_differs:
            liquid += 1
        land = len(cells) - liquid
        w, h = x1 - x0 + 16, y1 - y0 + 16
        mx, my = x0 - 8 + (w - 1) // 2, y0 - 8 + (h - 3) // 2 + 1
        if liquid == 0:
            neck = "narrow" if self.narrow_dry else "wide"
            exits = [{"side": "north", "pos": {"x": mx, "y": y0 - 8}, "width": w, "neck": neck},
                     {"side": "south", "pos": {"x": mx, "y": y1 + 7}, "width": w, "neck": neck},
                     {"side": "east", "pos": {"x": x1 + 7, "y": my}, "width": h - 2, "neck": neck},
                     {"side": "west", "pos": {"x": x0 - 8, "y": my}, "width": h - 2, "neck": neck}]
        elif land == 0:
            exits = []
        else:
            exits = [{"side": "west", "pos": {"x": x0 - 8, "y": my}, "width": h - 2, "neck": "wide"},
                     {"side": "north", "pos": {"x": x0 - 4, "y": y0 - 8}, "width": 3, "neck": "medium"}]
        if self.bad_exit and exits:
            exits[0] = dict(exits[0], pos={"x": exits[0]["pos"]["x"] + 3, "y": exits[0]["pos"]["y"] + 3})
        warnings = []
        if not exits:
            warnings.append("enclosed")
        elif exits[0]["neck"] == "narrow":
            warnings.append("narrow_access")
        if self.unknown_warning:
            warnings.append("looks_fine")
        data = {"surface": "vulcanus", "area": {"left_top": {"x": x0, "y": y0}, "right_bottom": {"x": x1, "y": y1}},
                "land": land, "liquid": liquid,
                "liquids": {TILE: liquid} if liquid and not self.liquid_without_names else {},
                "enclosed": not exits, "exits": exits, "warnings": warnings}
        if exits:
            data["best"] = "south" if self.bad_best else exits[0]["side"]
        hx, hy = math.floor(HELPER_POS["x"]), math.floor(HELPER_POS["y"])
        if helper is not None and x0 - 8 <= hx <= x1 + 7 and y0 - 8 <= hy <= y1 + 7:
            data["reachable"] = True
        return data

    def map(self, args):
        c, r = args.get("center") or HELPER_POS, args.get("radius", 16)
        x0, y0 = math.floor(c["x"]) - r, math.floor(c["y"]) - r
        n = 0
        rows = []
        for y in range(y0, y0 + 2 * r + 1):
            row = ""
            for x in range(x0, x0 + 2 * r + 1):
                wet = self.liquid(x, y)
                n += 1 if wet else 0
                row += "~" if wet and not self.no_tilde else "."
            rows.append(row)
        name = "other-sea" if self.other_tile_on_map else TILE
        legend = {".": "земля"}
        liquids = {}
        if n:
            liquids[name] = {"n": n, "cover": "foundation", "cover_ok": self.cover_ok}
            if not self.no_tilde:
                legend["~"] = self.legend or ("не пройти: " + name)
        return {"surface": "vulcanus", "bbox": {"x0": x0, "y0": y0, "x1": x0 + 2 * r, "y1": y0 + 2 * r},
                "rows": rows, "legend": legend, "liquids": liquids, "entities": [], "truncated": False}

    def __call__(self, command):
        if command == "/quit":
            return None
        assert command.startswith("/partner ")
        env = json.loads(command[len("/partner "):])
        op, args, helper = env["op"], env.get("args") or {}, env.get("helper")
        self.ops.append(op)

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": 0, "id": env["id"], "data": data})

        def fail(code):
            return json.dumps({"v": 1, "ok": False, "tick": 1, "seq": 0, "id": env["id"],
                               "error": {"code": code, "text": code}})

        if op == "hello":
            return ok({"owner": "Tartaluga", "mod": "factorio-partner 0.1.0", "proto": 1,
                       "players_online": 1 if self.online else 0, "module_errors": self.module_errors})
        if op == "helper_spawn":
            self.alive = True
            return ok({"helper": helper, "unit_number": 7, "surface": "vulcanus", "pos": dict(HELPER_POS)})
        if op == "helper_remove":
            self.alive = False
            return ok({})
        if op == "state":
            return ok({"helper": helper, "surface": "vulcanus", "pos": dict(HELPER_POS)})
        if op == "access":
            if self.crash:
                self.module_errors += 1
                return fail("internal")
            r = self.access(args, helper)
            return fail(r) if isinstance(r, str) else ok(r)
        if op == "map":
            return ok(self.map(args))
        if op == "jobs":
            return ok({"queue": [{"job": 1, "do": "walk"}] if self.queued else []})
        if op == "ghosts":
            return ok({"count": 0, "by_name": {}, "need": {}, "tiles": 0})
        return fail("unknown_op")


def run(name, model, fake_rcon):
    srv = fake_rcon(handler=model)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load(name).run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)
    assert model.alive is False, "сценарий убрал за собой помощника"
    return res


def failed(res):
    return {s["name"]: s.get("error", "") for s in res["steps"] if not s["ok"]}


# ---------- access_live ----------

def test_access_ok(fake_rcon):
    m = Model()
    res = run("access_live", m, fake_rcon)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == ["hello", "helper_spawn", "default", "search", "wet_site", "area_form",
                                                 "dry_site", "refusals", "without_helper", "read_only", "helper_remove"]
    wet, dry = res["found"]["wet"], res["found"]["dry"]
    assert wet["liquid"] > 0 and wet["land"] > 0 and wet["liquids"] == {TILE: wet["liquid"]}
    assert wet["best"] == "west" and [e["neck"] for e in wet["exits"]] == ["wide", "medium"]
    assert dry["best"] == "north" and len(dry["exits"]) == 4
    # участок у помощника сухой, жидкость нашлась на первом кольце
    assert res["found"]["sites"][0]["liquid"] == 0 and res["steps"][3]["info"]["tried"] == 2
    assert res["steps"][8]["info"] == {"code": "no_player"}
    assert res["log_must_not_match"]


def test_access_owner_online(fake_rcon):
    res = run("access_live", Model(online=True), fake_rcon)
    assert res["ok"] is True, res
    assert res["steps"][8]["info"]["ok"] is True


def test_access_no_liquid_nearby(fake_rcon):
    res = run("access_live", Model(no_liquid=True), fake_rcon)
    assert res["ok"] is False
    assert "жидкостью" in failed(res)["search"]
    assert len(res["found"]["sites"]) == 25  # обошли все точки


@pytest.mark.parametrize("kw, step, word", [
    ({"bad_exit": True}, "default", "не на рамке"),
    ({"bad_best": True}, "default", "best="),
    ({"narrow_dry": True}, "dry_site", "лучший выход"),
    ({"liquid_without_names": True}, "search", "liquids"),
    ({"other_tile_on_map": True}, "wet_site", "map.liquids"),
    ({"no_tilde": True}, "wet_site", "`~`"),
    ({"area_differs": True}, "area_form", "через area"),
    ({"accepts_bad": True}, "refusals", "ждали limit"),
    ({"queued": True}, "read_only", "задачу"),
    ({"unknown_warning": True}, "default", "неизвестное предупреждение"),
])
def test_access_failures(fake_rcon, kw, step, word):
    res = run("access_live", Model(**kw), fake_rcon)
    assert res["ok"] is False, res
    errors = failed(res)
    if kw.get("liquid_without_names"):
        # форма ломается уже в ответе с жидкостью: шаг её разбора
        assert any("liquid" in e for e in errors.values()), errors
        return
    assert step in errors and word in errors[step], errors


def test_access_crash_is_caught(fake_rcon):
    res = run("access_live", Model(crash=True), fake_rcon)
    assert res["ok"] is False
    assert "default" in failed(res) and "read_only" in failed(res)


def test_check_access_unit():
    mod = load("access_live")
    good = Model().access({"center": {"x": 30, "y": 0}, "radius": 32}, "h")
    mod.check_access(good)
    for patch, word in [
        ({"land": -1}, "land"),
        ({"liquid": 10 ** 6}, "больше площади"),
        ({"enclosed": "no"}, "enclosed"),
        ({"exits": [dict(good["exits"][0], neck="huge")]}, "exits"),
        ({"exits": [dict(good["exits"][1]), dict(good["exits"][0])], "best": "north"}, "широкие первыми"),
        ({"exits": [dict(good["exits"][0], neck="wide", width=3)]}, "wide при ширине"),
        ({"enclosed": True}, "enclosed"),
        ({"reachable": 1}, "reachable"),
    ]:
        with pytest.raises(AssertionError, match=word):
            mod.check_access(dict(good, **patch))


# ---------- map_liquid ----------

def test_map_liquid_ok(fake_rcon):
    res = run("map_liquid", Model(), fake_rcon)
    assert res["ok"] is True, res
    assert [s["name"] for s in res["steps"]] == ["hello", "helper_spawn", "search", "liquid_map", "cover", "dry_map",
                                                 "read_only", "helper_remove"]
    m = res["found"]["map"]
    assert m["blocked_cells"] > 0 and m["legend"] == "не пройти: " + TILE
    assert m["liquids"][TILE]["cover_ok"] is False and m["liquids"][TILE]["n"] == m["blocked_cells"]
    assert res["found"]["cover"] == {TILE: {"cover": "foundation", "cover_ok": False}}


def test_map_liquid_cover_available_is_not_a_failure(fake_rcon):
    res = run("map_liquid", Model(cover_ok=True), fake_rcon)
    assert res["ok"] is True, res
    assert res["steps"][4]["info"]["cover_available_for"] == [TILE]


def test_map_liquid_no_liquid_is_aborted(fake_rcon):
    res = run("map_liquid", Model(no_liquid=True), fake_rcon)
    assert res["ok"] is False and "aborted" in res


@pytest.mark.parametrize("kw, word", [
    ({"no_tilde": True}, "`~`"),
    ({"legend": "вода/лава"}, "не начинается"),
    ({"legend": "не пройти"}, "не называет плитки"),
    ({"legend": "не пройти: something-else"}, "нет в liquids"),
    ({"other_tile_on_map": True}, "access называет плитки"),
])
def test_map_liquid_failures(fake_rcon, kw, word):
    res = run("map_liquid", Model(**kw), fake_rcon)
    assert res["ok"] is False, res
    assert word in failed(res)["liquid_map"], failed(res)


def test_legend_names_unit():
    mod = load("map_liquid")
    assert mod.legend_names("не пройти: lava, lava-hot, +2", "не пройти") == (["lava", "lava-hot"], 2)
    assert mod.legend_names("мелко: oil-ocean-shallow", "мелко") == (["oil-ocean-shallow"], 0)
    assert mod.legend_names("не пройти", "не пройти") == ([], 0)
    with pytest.raises(AssertionError):
        mod.legend_names("вода", "не пройти")
