"""Сценарии build_layout_live и connect_live против фейкового RCON с маленькой моделью мода.

Модель (`World`) ведёт себя по docs/ACTIONS.md («build_layout», «connect_entities», «deconstruct»):
тело стоит на месте, земля везде свободная, постройки — словарь по unit_number. Флаги ломают отдельные
части, чтобы проверить, что сценарий замечает нарушение контракта, а не только проходит на честной модели.
"""
from __future__ import annotations

import json
import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR

SIZE = {"stone-furnace": 2}
FURNACE, CHEST, BELT, POLE, INSERTER = "stone-furnace", "wooden-chest", "transport-belt", "small-electric-pole", "inserter"
DIRS = {(1, 0): 4, (-1, 0): 12, (0, 1): 8, (0, -1): 0}


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


class World:
    def __init__(self, stock=None, no_site=False, no_grid=False, water=False, exists_as_failed=False,
                 dry_places=False, over_places=False, decon_fails=False, shift_pos=False, ghost_left=False,
                 break_chain=False, belts_no_items=False, far_poles=False, connect_fails=False,
                 belt_dry_places=False):
        self.stock = dict(stock if stock is not None else {FURNACE: 5, CHEST: 5, INSERTER: 2, BELT: 200, POLE: 20})
        self.inv = {}
        self.pos = {"x": 10.3, "y": -4.7}
        self.ents = {}
        self.unit = 100
        self.flags = dict(no_site=no_site, no_grid=no_grid, water=water, exists_as_failed=exists_as_failed,
                          dry_places=dry_places, over_places=over_places, decon_fails=decon_fails,
                          shift_pos=shift_pos, ghost_left=ghost_left, break_chain=break_chain,
                          belts_no_items=belts_no_items, far_poles=far_poles, connect_fails=connect_fails,
                          belt_dry_places=belt_dry_places)
        if not no_grid:
            self._add(POLE, 20.5, 10.5)             # опора базы: на сейве есть электричество
        self.base = dict(self.ents)
        self.events, self.seq, self.job = [], 0, 0
        self.acts = []

    # ---- сущности
    def _add(self, name, x, y, ghost=False, direction=None):
        self.unit += 1
        self.ents[self.unit] = {"name": name, "x": x, "y": y, "ghost": ghost, "dir": direction}
        return self.unit

    def _cells(self, name, x, y):
        s = SIZE.get(name, 1)
        x0, y0 = math.floor(x - s / 2 + 0.01), math.floor(y - s / 2 + 0.01)
        return {(x0 + i, y0 + j) for i in range(s) for j in range(s)}

    def _taken(self):
        out = set()
        for e in self.ents.values():
            if not e["ghost"]:
                out |= self._cells(e["name"], e["x"], e["y"])
        return out

    def _find(self, name, x, y, unit=None):
        for u, e in self.ents.items():
            if (unit is None or u == unit) and e["name"] == name and abs(e["x"] - x) <= 0.6 and abs(e["y"] - y) <= 0.6 \
                    and not e["ghost"]:
                return u
        return None

    # ---- события
    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "x", "kind": kind, "data": data, "loud": True})

    def _done(self, do, detail):
        self._emit("job_done", {"job": self.job, "do": do, "detail": detail})

    def _fail(self, do, code, detail=None, text="x"):
        self._emit("job_failed", {"job": self.job, "do": do, "code": code, "text": text, "detail": detail or {}})

    # ---- build_layout
    def _layout(self, a):
        ents = a["entities"]
        anchor = a["anchor"]
        shifts = [(0, 0)] + [(k, 0) for k in range(1, a.get("search", 0) + 1)]
        for sx, sy in shifts:
            ax, ay = anchor["x"] + sx, anchor["y"] + sy
            plan, bad = [], False
            for i, e in enumerate(ents, 1):          # как мод: номера построек с 1
                s = SIZE.get(e["name"], 1)
                x, y = ax + e["dx"] + s / 2, ay + e["dy"] + s / 2
                if self.flags["shift_pos"]:
                    x += 1
                same = self._find(e["name"], x, y)
                if same is None and self._cells(e["name"], x, y) & self._taken() and not self.flags["over_places"]:
                    bad = True
                plan.append((i, e["name"], x, y, same))
            if not bad and not self.flags["no_site"]:
                return {"x": ax, "y": ay}, sx, plan
        return None, 0, []

    def _build_layout(self, a):
        site, shift, plan = self._layout(a)
        need = {}
        for e in a["entities"]:
            need[e["name"]] = need.get(e["name"], 0) + 1
        if site is None:
            detail = {"reason": "site_not_found", "site_checked": 9, "failed": [
                {"i": i, "name": e["name"], "code": "cannot_place", "why": "occupied"} for i, e in enumerate(a["entities"], 1)]}
            if a.get("dry_run"):
                return self._done("build_layout", dict(detail, dry_run=True, placed=[], need=need))
            return self._fail("build_layout", "cannot_place", detail)
        info = {"anchor": site, "direction": 0, "shift": {"dx": shift, "dy": 0}, "checked": 1}
        if a.get("dry_run"):
            if self.flags["dry_places"]:
                for _, name, x, y, same in plan:
                    if same is None:
                        self._add(name, x, y, ghost=True)
            return self._done("build_layout", {"site": info, "placed": [], "failed": [], "need": need, "missing": {},
                                               "dry_run": True})
        missing = {n: c - self.inv.get(n, 0) for n, c in need.items() if self.inv.get(n, 0) < c}
        fresh = {}
        for _, name, *_rest in plan:
            fresh[name] = fresh.get(name, 0) + 1
        for _, name, _x, _y, same in plan:
            if same is not None:
                fresh[name] -= 1
        missing = {n: c - self.inv.get(n, 0) for n, c in fresh.items() if self.inv.get(n, 0) < c}
        if missing and not a.get("auto_supply"):
            return self._fail("build_layout", "no_items", {"missing": missing})
        placed, failed = [], []
        for i, name, x, y, same in plan:
            if same is not None:
                row = {"i": i, "name": name, "pos": {"x": x, "y": y}, "unit_number": same}
                if self.flags["exists_as_failed"]:
                    failed.append({"i": i, "name": name, "pos": {"x": x, "y": y}, "code": "exists"})
                else:
                    placed.append(row)
                continue
            self.inv[name] = self.inv.get(name, 0) - 1
            unit = self._add(name, x, y)
            placed.append({"i": i, "name": name, "pos": {"x": x, "y": y}, "unit_number": unit})
        if not placed and not failed:
            return self._fail("build_layout", "cannot_place", {"failed": []})
        return self._done("build_layout", {"site": info, "placed": placed, "failed": failed, "need": need,
                                           "missing": {}, "built": len(placed)})

    # ---- connect_entities
    def _connect(self, a):
        if self.flags["connect_fails"]:
            return self._fail("connect_entities", "path_failed", {"reason": "unreachable"})
        if a["kind"] == "belt":
            return self._connect_belt(a)
        return self._connect_power(a)

    def _connect_belt(self, a):
        fx, fy = math.floor(a["from"]["pos"]["x"]), math.floor(a["from"]["pos"]["y"])
        tx, ty = math.floor(a["to"]["pos"]["x"]), math.floor(a["to"]["pos"]["y"])
        cells, x, y = [(fx, fy)], fx, fy
        while x != tx:
            x += 1 if tx > x else -1
            cells.append((x, y))
        while y != ty:
            y += 1 if ty > y else -1
            cells.append((x, y))
        area = {"left_top": {"x": min(fx, tx) - 1, "y": min(fy, ty) - 1},
                "right_bottom": {"x": max(fx, tx) + 2, "y": max(fy, ty) + 2}}
        detail = {"kind": "belt", "length": len(cells), "path": [{"x": c[0] + .5, "y": c[1] + .5} for c in cells[:2]],
                  "area": area, "chosen": {"belt": BELT}, "ghosts": len(cells), "need": {BELT: len(cells)}}
        if a.get("dry_run"):
            if self.flags["belt_dry_places"]:
                self._add(BELT, cells[0][0] + .5, cells[0][1] + .5, ghost=True, direction=4)
            return self._done("connect_entities", dict(detail, dry_run=True))
        if self.flags["belts_no_items"] and self.stock.get(BELT, 0) < 10 ** 6:
            return self._fail("connect_entities", "no_items", {"missing": {BELT: len(cells)}})
        for i, (cx, cy) in enumerate(cells):
            if self.flags["break_chain"] and i == len(cells) // 2:
                continue
            nxt = cells[i + 1] if i + 1 < len(cells) else None
            prev = cells[i - 1] if i else None
            step = (nxt[0] - cx, nxt[1] - cy) if nxt else (cx - prev[0], cy - prev[1])
            self._add(BELT, cx + .5, cy + .5, ghost=self.flags["ghost_left"], direction=DIRS[step])
        return self._done("connect_entities", dict(detail, built=len(cells)))

    def _connect_power(self, a):
        f = a["from"]["pos"]
        t = a["to"]["target"]["pos"]
        dist = math.hypot(t["x"] - f["x"], t["y"] - f["y"])
        n = max(1, math.ceil(dist / 5))
        ts = [k / n for k in range(n)] + [(dist - 1) / dist]
        if self.flags["far_poles"]:
            ts = ts[:1]
        cells = []
        for k in ts:
            c = (math.floor(f["x"] + (t["x"] - f["x"]) * k) + .5, math.floor(f["y"] + (t["y"] - f["y"]) * k) + .5)
            if c not in cells:
                cells.append(c)
        for c in cells:
            self._add(POLE, c[0], c[1])
        area = {"left_top": {"x": min(f["x"], t["x"]) - 3, "y": min(f["y"], t["y"]) - 3},
                "right_bottom": {"x": max(f["x"], t["x"]) + 3, "y": max(f["y"], t["y"]) + 3}}
        return self._done("connect_entities", {"kind": "power", "poles": len(cells), "length": len(cells), "area": area,
                                               "chosen": {"pole": POLE}, "path": []})

    # ---- RCON
    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": self.seq, "id": env["id"], "data": data})

        if op == "hello":
            return ok({"proto": 1, "mod": "factorio-partner 0.7.0", "players_online": 0, "seq": self.seq, "module_errors": 0})
        if op == "helper_spawn":
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "vulcanus", "pos": dict(self.pos)})
        if op == "state":
            return ok({"helper": env["helper"], "pos": dict(self.pos), "inv": {k: v for k, v in self.inv.items() if v}, "queue": 0})
        if op == "stock":
            want = args.get("items")
            total = {k: v for k, v in self.stock.items() if v > 0 and (not want or k in want)}
            boxes = [{"unit": 5, "pos": {"x": 3, "y": 3}, "dist": 4, "items": dict(total)}] if total else []
            return ok({"containers": boxes, "total": total, "hidden": 0, "truncated": False})
        if op == "map":
            return ok(self._map(args))
        if op == "events":
            return ok({"seq": self.seq, "events": [e for e in self.events if e["seq"] > args["since"]] or {}, "lost": False})
        if op == "act":
            self.job += 1
            do, a = args["do"], args["args"]
            self.acts.append((do, a))
            getattr(self, "_act_" + do)(a)
            return ok({"job": self.job, "queued_before": 0})
        raise AssertionError(op)

    def _map(self, a):
        c, r = a["center"], a["radius"]
        x0, y0 = math.floor(c["x"]) - r, math.floor(c["y"]) - r
        ch = "~" if self.flags["water"] else "."
        names = a.get("names")
        ents = []
        for u, e in self.ents.items():
            if names and e["name"] not in names:
                continue
            if abs(e["x"] - c["x"]) > r or abs(e["y"] - c["y"]) > r:
                continue
            row = {"c": "E", "name": e["name"], "pos": {"x": e["x"], "y": e["y"]}, "unit": u}
            if e["dir"] is not None:
                row["dir"] = e["dir"]
            if e["ghost"]:
                row["ghost"] = True
            ents.append(row)
        return {"bbox": {"x0": x0, "y0": y0}, "rows": [ch * (2 * r + 1)] * (2 * r + 1), "legend": {}, "entities": ents,
                "truncated": False}

    # ---- действия
    def _act_collect(self, a):
        (item, n), = a["items"].items()
        take = min(n, self.stock.get(item, 0))
        self.stock[item] -= take
        self.inv[item] = self.inv.get(item, 0) + take
        self._done("collect", {"collected": {item: take}})

    def _act_get_items(self, a):
        (item, n), = a["items"].items()
        if self.stock.get(item, 0) < n:
            return self._fail("get_items", "no_items", {"have": {}})
        self.stock[item] -= n
        self.inv[item] = self.inv.get(item, 0) + n
        self._done("get_items", {"have": {item: n}})

    def _act_craft(self, a):
        self._fail("craft", "no_items")

    def _act_place(self, a):
        item, pos = a["item"], a["pos"]
        if self._cells(item, pos["x"], pos["y"]) & self._taken():
            return self._fail("place", "cannot_place")
        self.inv[item] -= 1
        self._done("place", {"unit_number": self._add(item, pos["x"], pos["y"])})

    def _act_build_layout(self, a):
        self._build_layout(a)

    def _act_connect_entities(self, a):
        self._connect(a)

    def _act_deconstruct(self, a):
        t = a["target"]
        pos = t["pos"]
        unit = self._find(t["name"], pos["x"], pos["y"]) if "name" in t else \
            next((u for u, e in self.ents.items() if u == t["unit_number"] and abs(e["x"] - pos["x"]) <= 0.6
                  and abs(e["y"] - pos["y"]) <= 0.6), None)
        if unit is None:
            return self._fail("deconstruct", "not_found")
        name = self.ents[unit]["name"]
        if not self.flags["decon_fails"]:
            del self.ents[unit]
            self.inv[name] = self.inv.get(name, 0) + 1
        self._done("deconstruct", {"removed": 1, "got": {name: 1}})


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)
    monkeypatch.setattr(lc.time, "sleep", lambda s: None)
    real_poll = lc.LiveClient.poll
    monkeypatch.setattr(lc.LiveClient, "poll", lambda self, fn, timeout, interval=1.0: real_poll(self, fn, min(timeout, 0.05), interval))


def run(name, world, fake_rcon):
    srv = fake_rcon(handler=world)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load(name).run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)      # только конверты, никаких /c
    return res


def reasons(res):
    return " | ".join(res.get("reasons") or [])


# ---------------------------------------------------------------- build_layout_live
def test_layout_ok_and_base_untouched(fake_rcon):
    w = World()
    res = run("build_layout_live", w, fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("error")
    assert w.ents == w.base
    builds = [a for d, a in w.acts if d == "build_layout"]
    assert [bool(a.get("dry_run")) for a in builds] == [True, False, False, False]
    assert builds[0]["search"] == 8 and builds[1]["auto_supply"] is True and builds[1]["tag"]
    assert builds[2]["search"] == 0
    assert len(res["cleanup"]) == 3
    assert res["build_status"] == {1: "placed", 2: "placed", 3: "placed"}     # мод считает постройки с 1
    decon = [a["target"] for d, a in w.acts if d == "deconstruct"]
    assert len(decon) == 3 and all("unit_number" in t for t in decon)
    assert res["log_must_not_match"]


def test_layout_repeat_uses_found_anchor(fake_rcon):
    w = World()
    run("build_layout_live", w, fake_rcon)
    builds = [a for d, a in w.acts if d == "build_layout"]
    assert builds[2]["anchor"] == builds[1]["anchor"] and builds[2]["entities"] == builds[1]["entities"]


def test_layout_found_site_shift_is_followed(fake_rcon):
    # место занято в якоре: сценарий берёт site.anchor из ответа, а не свой якорь
    w = World()
    base = {"x": 10, "y": -5}
    w._add(FURNACE, base["x"] + 2, base["y"] + 2)
    w.base = dict(w.ents)
    res = run("build_layout_live", w, fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("error")
    builds = [a for d, a in w.acts if d == "build_layout"]
    assert builds[2]["anchor"] != builds[1]["anchor"]
    assert w.ents == w.base


def test_layout_exists_in_failed_list_is_accepted(fake_rcon):
    res = run("build_layout_live", World(exists_as_failed=True), fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("error")


def test_layout_no_stock_is_setup(fake_rcon):
    res = run("build_layout_live", World(stock={}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and "reasons" not in res


def test_layout_no_site_is_setup(fake_rcon):
    res = run("build_layout_live", World(no_site=True), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and "reasons" not in res
    assert "места" in res["error"]["text"]


def test_layout_dry_run_that_places_is_a_failure(fake_rcon):
    res = run("build_layout_live", World(dry_places=True), fake_rcon)
    assert res["ok"] is False and "dry_run изменил карту" in reasons(res)


def test_layout_block_over_own_building_must_not_place(fake_rcon):
    res = run("build_layout_live", World(over_places=True), fake_rcon)
    assert res["ok"] is False and "поверх своей печи" in reasons(res)


def test_layout_wrong_position_is_failure(fake_rcon):
    res = run("build_layout_live", World(shift_pos=True), fake_rcon)
    assert res["ok"] is False and "на карте в" in reasons(res)


def test_layout_not_cleaned_is_failure(fake_rcon):
    res = run("build_layout_live", World(decon_fails=True), fake_rcon)
    assert res["ok"] is False and "карта другая" in reasons(res)


# ---------------------------------------------------------------- connect_live
def test_connect_ok_and_base_untouched(fake_rcon):
    w = World()
    res = run("connect_live", w, fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("setup_failed")
    assert w.ents == w.base
    calls = [a for d, a in w.acts if d == "connect_entities"]
    assert [(a["kind"], bool(a.get("dry_run")), bool(a.get("build"))) for a in calls] == \
        [("belt", True, False), ("belt", False, True), ("power", False, True)]
    assert all(a.get("auto_supply") for a in calls[1:])
    assert 15 <= res["belt"]["points"]["span"] <= 25
    assert res["belt"]["chain"]["walked"] == res["belt"]["built"] >= 16
    assert res["power"]["poles"]["on_map"] >= 2 and res["power"]["covers"] >= 1


def test_connect_no_grid_power_is_setup_but_belt_runs(fake_rcon):
    w = World(no_grid=True)
    res = run("connect_live", w, fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and "reasons" not in res
    assert set(res["setup_failed"]) == {"power"} and res["belt"]["built"] >= 16
    assert w.ents == w.base


def test_connect_water_everywhere_is_setup(fake_rcon):
    res = run("connect_live", World(water=True), fake_rcon)
    assert set(res["setup_failed"]) == {"belt", "power"} and "reasons" not in res


def test_connect_belts_unavailable_is_setup(fake_rcon):
    res = run("connect_live", World(belts_no_items=True), fake_rcon)
    assert "belt" in res["setup_failed"] and "reasons" not in res


def test_connect_dry_run_that_places_is_failure(fake_rcon):
    res = run("connect_live", World(belt_dry_places=True), fake_rcon)
    assert res["ok"] is False and "dry_run изменил карту" in reasons(res)


def test_connect_broken_chain_is_failure(fake_rcon):
    res = run("connect_live", World(break_chain=True), fake_rcon)
    assert res["ok"] is False and "belt:" in reasons(res)
    assert any("рвётся" in r or "направления" in r or "кончается" in r for r in res["reasons"]), res["reasons"]


def test_connect_ghosts_left_is_failure(fake_rcon):
    res = run("connect_live", World(ghost_left=True), fake_rcon)
    assert res["ok"] is False and "призраки" in reasons(res)


def test_connect_poles_that_do_not_cover_consumer_is_failure(fake_rcon):
    res = run("connect_live", World(far_poles=True), fake_rcon)
    assert res["ok"] is False and "не накрывает" in reasons(res)


def test_connect_failed_action_is_failure_not_setup(fake_rcon):
    res = run("connect_live", World(connect_fails=True), fake_rcon)
    assert res["ok"] is False and "не done" in reasons(res) and "setup_failed" not in res.get("belt", {})


def test_connect_not_cleaned_is_failure(fake_rcon):
    res = run("connect_live", World(decon_fails=True), fake_rcon)
    assert res["ok"] is False and "belt: после разбора карта другая" in reasons(res)
