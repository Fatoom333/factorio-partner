"""Сценарии build_* (поток F) против фейкового RCON с моделью мода: collect → place / чертёж / разбор."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


class Model:
    """Модель мода: склад хозяина, инвентарь помощника, постройки и призраки на карте."""

    def __init__(self, stock=None, blocked=(), mod="factorio-partner 0.1.0", break_place=None,
                 keep_ghosts=False, lose_item=False, decon_fails=False):
        self.mod = mod
        self.stock = dict(stock if stock is not None else {"wooden-chest": 5})
        self.inv = {}
        self.pos = {"x": 10.3, "y": -4.7}
        self.blocked = {tuple(b) for b in blocked}
        self.entities = {}       # (x, y) -> name
        self.ghosts = {}         # (x, y) -> name
        self.blobs = {}
        self.events = []
        self.seq = 0
        self.job = 0
        self.unit = 100
        self.acts = []
        self.break_place = break_place
        self.keep_ghosts = keep_ghosts
        self.lose_item = lose_item
        self.decon_fails = decon_fails
        self.spawned = False

    # ---- события
    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "build", "kind": kind, "data": data, "loud": True})

    def _done(self, do, detail):
        self._emit("job_done", {"job": self.job, "do": do, "detail": detail})

    def _failed(self, do, code, detail=None):
        self._emit("job_failed", {"job": self.job, "do": do, "code": code, "text": code, "detail": detail or {}})

    # ---- действия
    def _take(self, name, n):
        self.inv[name] = self.inv.get(name, 0) - n
        if self.inv[name] <= 0:
            del self.inv[name]

    def _act(self, do, a):
        self.job += 1
        self.acts.append((do, a))
        if do == "collect":
            got = {}
            for name, n in a["items"].items():
                k = min(n, self.stock.get(name, 0))
                if k:
                    got[name] = k
                    self.stock[name] -= k
                    self.inv[name] = self.inv.get(name, 0) + k
            return self._done(do, {"collected": got, "missing": {}, "from": [1]})
        if do == "craft":
            per = {"iron-chest": ("iron-plate", 8), "wooden-chest": ("wood", 2)}[a["recipe"]]
            self._take(per[0], per[1] * a["count"])
            self.inv[a["recipe"]] = self.inv.get(a["recipe"], 0) + a["count"]
            return self._done(do, {"crafted": {a["recipe"]: a["count"]}})
        if do == "place":
            key = (a["pos"]["x"], a["pos"]["y"])
            if self.break_place:
                return self._failed(do, self.break_place)
            if key in self.blocked or key in self.entities:
                return self._failed(do, "cannot_place")
            if self.inv.get(a["item"], 0) < 1:
                return self._failed(do, "no_items")
            if not self.lose_item:
                self._take(a["item"], 1)
            self.entities[key] = a["item"]
            self.unit += 1
            return self._done(do, {"unit_number": self.unit, "name": a["item"], "pos": a["pos"]})
        if do == "deconstruct":
            t = a["target"]
            key = (t["pos"]["x"], t["pos"]["y"])
            if self.decon_fails or self.entities.get(key) != t["name"]:
                return self._failed(do, "not_found")
            del self.entities[key]
            self.inv[t["name"]] = self.inv.get(t["name"], 0) + 1
            return self._done(do, {"removed": 1, "got": {t["name"]: 1}})
        if do == "build_blueprint":
            text = self.blobs.get(a["blob"])
            if text is None:
                return self._failed(do, "bad_args")
            bp = load("build_ghosts").decode_blueprint(text)["blueprint"]
            ents = bp["entities"]
            cx = sum(e["position"]["x"] for e in ents) / len(ents)
            cy = sum(e["position"]["y"] for e in ents) / len(ents)
            cells = [((a["anchor"]["x"] + e["position"]["x"] - cx, a["anchor"]["y"] + e["position"]["y"] - cy), e["name"])
                     for e in ents]
            ok = [(k, n) for k, n in cells if k not in self.blocked and k not in self.entities]
            skipped = [{"name": n, "pos": {"x": k[0], "y": k[1]}, "reason": "cannot_place"}
                       for k, n in cells if (k, n) not in ok]
            if a.get("dry_run"):
                return self._done(do, {"ghosts": len(ok), "skipped": skipped, "skipped_total": len(skipped), "missing": {}})
            if not ok:
                return self._failed(do, "cannot_place", {"ghosts": 0, "skipped": skipped})
            built = 0
            for k, n in ok:
                if self.keep_ghosts or self.inv.get(n, 0) < 1:
                    self.ghosts[k] = n
                else:
                    self._take(n, 1)
                    self.entities[k] = n
                    built += 1
            detail = {"ghosts": len(ok), "skipped": skipped, "skipped_total": len(skipped), "built": built,
                      "left": len(ok) - built, "blocked": [], "blocked_total": 0, "missing": {}}
            if built < len(ok):
                return self._failed(do, "no_items", detail)
            return self._done(do, detail)
        raise AssertionError(do)

    # ---- конверты
    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": self.seq, "id": env["id"], "data": data})

        def fail(code):
            return json.dumps({"v": 1, "ok": False, "tick": 1, "seq": self.seq, "id": env["id"],
                               "error": {"code": code, "text": code}})

        if op == "hello":
            return ok({"proto": 1, "mod": self.mod, "players_online": 0, "seq": self.seq})
        if op == "helper_spawn":
            if self.spawned:
                return fail("helper_exists")
            self.spawned = True
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "nauvis", "pos": self.pos})
        if op == "stock":
            names = args.get("items") or list(self.stock)
            total = {n: self.stock[n] for n in names if self.stock.get(n, 0) > 0}
            return ok({"containers": [], "total": total, "hidden": 0, "truncated": False})
        if op == "state":
            return ok({"helper": env["helper"], "pos": self.pos, "inv": dict(self.inv)})
        if op == "map":
            c, r = args["center"], args.get("radius", 16)
            ents = [{"c": "C", "name": n, "pos": {"x": k[0], "y": k[1]}, "dir": 0}
                    for k, n in self.entities.items()
                    if n in args.get("names", [n]) and abs(k[0] - c["x"]) <= r and abs(k[1] - c["y"]) <= r]
            return ok({"entities": ents, "rows": [], "truncated": False})
        if op == "ghosts":
            a = args["area"]
            n = sum(1 for k in self.ghosts
                    if a["left_top"]["x"] <= k[0] <= a["right_bottom"]["x"] and a["left_top"]["y"] <= k[1] <= a["right_bottom"]["y"])
            return ok({"count": n})
        if op == "blob_put":
            parts = self.blobs.setdefault("_" + args["blob"], {})
            parts[args["part"]] = args["data"]
            assert len(args["data"].encode()) <= 3500
            if len(parts) == args["total"]:
                self.blobs[args["blob"]] = "".join(parts[i] for i in range(1, args["total"] + 1))
            return ok({"blob": args["blob"], "received": len(parts), "total": args["total"]})
        if op == "act":
            self._act(args["do"], args["args"])
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
    return res


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    """Паузы сценариев (опрос событий) в офлайн-тестах не нужны."""
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)


def _no_wait(monkeypatch):
    monkeypatch.setattr(lc.LiveClient, "poll", lambda self, fn, timeout, interval=1.0: fn())


# ---------- build_place ----------

def test_place_ok(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model()
    res = run("build_place", m, fake_rcon)
    assert res["ok"] is True, res
    assert res["item"] == "wooden-chest"
    assert res["inventory"] == {"before": 1, "after": 0}
    assert res["on_map"] == 1
    dos = [d for d, _ in m.acts]
    assert dos == ["collect", "place"]
    # сундук взят со склада, а не из воздуха
    assert m.stock["wooden-chest"] == 4
    assert m.acts[1][1]["pos"] == {"x": 13.5, "y": -4.5}


def test_place_tries_next_spot(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(blocked=[(13.5, -4.5), (10.5, -1.5)])
    res = run("build_place", m, fake_rcon)
    assert res["ok"] is True, res
    assert [t["code"] for t in res["place"]["tries"]] == ["cannot_place", "cannot_place", None]
    assert res["place"]["pos"] == {"x": 7.5, "y": -4.5}


def test_place_crafts_when_no_chests(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock={"iron-plate": 100})
    res = run("build_place", m, fake_rcon)
    assert res["ok"] is True, res
    assert [d for d, _ in m.acts] == ["collect", "craft", "place"]
    assert m.acts[0][1]["items"] == {"iron-plate": 8}
    assert res["item"] == "iron-chest"


def test_place_no_stock_is_setup_error(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_place", Model(stock={}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_place_wrong_mod(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_place", Model(mod="partner-test 0.3.0"), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


@pytest.mark.parametrize("kw", [{"break_place": "path_failed"}, {"lose_item": True}])
def test_place_failures(fake_rcon, monkeypatch, kw):
    _no_wait(monkeypatch)
    res = run("build_place", Model(**kw), fake_rcon)
    assert res["ok"] is False and res["reasons"], res


def test_place_stops_on_other_error(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(break_place="path_failed")
    run("build_place", m, fake_rcon)
    assert [d for d, _ in m.acts] == ["collect", "place"]  # не перебирает места при чужой ошибке


# ---------- build_decon ----------

def test_decon_ok(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model()
    res = run("build_decon", m, fake_rcon)
    assert res["ok"] is True, res
    assert [d for d, _ in m.acts] == ["collect", "place", "deconstruct"]
    assert m.acts[2][1] == {"target": {"name": "wooden-chest", "pos": {"x": 13.5, "y": -4.5}}}
    assert res["inventory"] == {"before_place": 1, "after_deconstruct": 1}
    assert res["on_map"] == 0 and m.entities == {}


def test_decon_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_decon", Model(decon_fails=True), fake_rcon)
    assert res["ok"] is False
    assert any("deconstruct" in r for r in res["reasons"])
    assert any("осталась" in r for r in res["reasons"])


def test_decon_needs_place(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_decon", Model(break_place="stuck"), fake_rcon)
    assert res["ok"] is False and "deconstruct" not in res


# ---------- build_ghosts ----------

def test_blueprint_string_roundtrip():
    g = load("build_ghosts")
    text = g.blueprint_string("wooden-chest", 2)
    assert text[0] == "0"
    bp = g.decode_blueprint(text)["blueprint"]
    assert bp["item"] == "blueprint"
    assert [(e["entity_number"], e["name"], e["position"]) for e in bp["entities"]] == [
        (1, "wooden-chest", {"x": -0.5, "y": 0.5}), (2, "wooden-chest", {"x": 0.5, "y": 0.5})]
    assert bp["version"] == (2 << 48) | (77 << 16)
    assert len(text) < 3500


def test_put_blob_splits(fake_rcon):
    g = load("build_ghosts")
    m = Model()
    srv = fake_rcon(handler=m)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        data = g.put_blob(c, "bp-x", "A" * 7000)
    assert data == {"blob": "bp-x", "received": 3, "total": 3}
    assert m.blobs["bp-x"] == "A" * 7000


def test_ghosts_ok(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model()
    res = run("build_ghosts", m, fake_rcon)
    assert res["ok"] is True, res
    dos = [(d, a.get("dry_run", False)) for d, a in m.acts]
    assert dos == [("collect", False), ("build_blueprint", True), ("build_blueprint", False)]
    assert m.acts[0][1]["items"] == {"wooden-chest": 2}
    assert m.acts[2][1]["mode"] == "hand"
    assert res["anchor"] == {"x": 14, "y": -4.5}
    assert sorted(m.entities) == [(13.5, -4.5), (14.5, -4.5)]
    assert res["inventory"] == {"before": 2, "after": 0}
    assert res["ghosts_left"] == 0 and res["on_map"] == 2


def test_ghosts_dry_run_picks_free_place(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(blocked=[(14.5, -4.5)])
    res = run("build_ghosts", m, fake_rcon)
    assert res["ok"] is True, res
    assert [d["ghosts"] for d in res["dry_run"]] == [1, 2]
    assert res["anchor"] == {"x": 10, "y": -0.5}


def test_ghosts_left_unbuilt_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    res = run("build_ghosts", Model(keep_ghosts=True), fake_rcon)
    assert res["ok"] is False
    assert res["ghosts_left"] == 2
    assert any("build_blueprint не done" in r for r in res["reasons"])


def test_ghosts_no_place(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    g = load("build_ghosts")
    blocked = []
    for dx, dy in g.OFFSETS:
        blocked.append((10 + dx - 0.5, -5 + dy + 0.5))
    res = run("build_ghosts", Model(blocked=blocked), fake_rcon)
    assert res["ok"] is False and "dry_run" in res["reasons"][0]
