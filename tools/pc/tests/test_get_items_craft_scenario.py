"""Сценарий hands_get_items_craft против фейкового RCON с маленькой моделью мода + инструмент hold у ServerClient."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
import server_client as sc
from conftest import PASSWORD, PC_DIR, REPO

HOLD_DOC = os.path.join(REPO, "docs", "MCP.md")


def load():
    return lc.load_scenario("hands_get_items_craft", os.path.join(PC_DIR, "scenarios"))


class World:
    def __init__(self, stock=None, furnace="own", leak=False, instant=False, bad_cancel_event=False,
                 ready=None, far=False, place_fail=False, decon_fail=False):
        self.stock = dict(stock if stock is not None else {"iron-plate": 400, "copper-plate": 400})
        self.stock.update(ready or {})      # готовые предметы на складе
        self.inv = {}
        # True: на базе есть подходящая печь; "own": плавка идёт только в печи, поставленной помощником;
        # False: печей нет совсем
        self.furnace = furnace
        self.far = far                    # склады видны только в радиусе 128
        self.place_fail = place_fail      # place всегда cannot_place
        self.decon_fail = decon_fail      # deconstruct не убирает печь
        self.placed = []
        self.leak = leak                  # cancel не снимает крафт
        self.instant = instant            # крафт кончается раньше, чем его снимают
        self.bad_cancel_event = bad_cancel_event
        self.events, self.seq, self.job = [], 0, 0
        self.active = None
        self.acts, self.cancels = [], []

    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "build", "kind": kind, "data": data,
                            "loud": True})

    def _done(self, do, detail):
        self._emit("job_done", {"job": self.job, "do": do, "detail": detail})

    def _get_items(self, items):
        (item, target), = items.items()
        have = self.inv.get(item, 0)
        if item == "electronic-circuit":
            for raw, n in (("iron-plate", target), ("copper-plate", target * 2)):
                self.stock[raw] -= max(0, n - self.inv.get(raw, 0))     # недостающее сырьё берётся со склада
                self.inv[raw] = max(0, self.inv.get(raw, 0) - n)
            self.inv[item] = target
            if self.stock.get("copper-cable", 0) >= target * 3:     # промежуточный со склада
                return self._done("get_items", {"have": {item: target}, "from": {
                    "crafted": {item: target}, "storage": {"copper-cable": target * 3}}})
            return self._done("get_items", {"have": {item: target},
                                            "from": {"crafted": {item: target, "copper-cable": target * 3}}})
        if item in ("assembling-machine-1", "small-electric-pole", "burner-mining-drill"):
            mid = {"assembling-machine-1": "electronic-circuit", "small-electric-pole": "copper-cable",
                   "burner-mining-drill": "iron-gear-wheel"}[item]
            self.inv[item] = target
            return self._done("get_items", {"have": {item: target}, "from": {"crafted": {item: target, mid: target}}})
        if item == "inserter":
            for raw, n in (("iron-plate", 4 * target), ("copper-plate", 2 * target)):
                self.stock[raw] -= max(0, n - self.inv.get(raw, 0))
                self.inv[raw] = max(0, self.inv.get(raw, 0) - n)
            self.inv[item] = target
            return self._done("get_items", {"have": {item: target},
                                            "from": {"crafted": {item: target, "electronic-circuit": target}}})
        if item in ("stone-brick", "iron-plate", "copper-plate"):
            ore, per = {"stone-brick": ("stone", 2), "iron-plate": ("iron-ore", 1), "copper-plate": ("copper-ore", 1)}[item]
            if not (self.furnace is True or (self.furnace == "own" and self.placed)):
                return self._emit("job_failed", {"job": self.job, "do": "get_items", "code": "no_items",
                                                 "detail": {"have": {}, "shortfall": [
                                                     {"item": item, "missing": target, "reason": "no_furnace"}]}})
            self.inv[ore] -= target * per
            self.inv[item] = target
            return self._done("get_items", {"have": {item: target}, "from": {"smelted": {item: target}}})
        raise AssertionError(item)

    def __call__(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": self.seq, "id": env["id"], "data": data})

        if op == "hello":
            return ok({"proto": 1, "mod": "factorio-partner 0.5.1", "players_online": 0, "seq": self.seq,
                       "module_errors": 0})
        if op == "helper_spawn":
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "vulcanus", "pos": {"x": 0, "y": 0}})
        if op == "state":
            st = {"helper": env["helper"], "pos": {"x": 0, "y": 0}, "inv": dict(self.inv), "queue": 0}
            if self.active:
                st["job"] = {"job": self.active, "do": "craft"}
            return ok(st)
        if op == "stock":
            want = args.get("items")
            if self.far and args.get("radius", 64) < 128:
                return ok({"containers": [], "total": {}, "hidden": 0, "truncated": False})
            total = {k: v for k, v in self.stock.items() if v > 0 and (not want or k in want)}
            containers = [{"unit": 5, "pos": {"x": 3, "y": 3}, "dist": 4, "items": dict(total)}] if total else []
            return ok({"containers": containers, "total": total or {}, "hidden": 0, "truncated": False})
        if op == "act":
            self.job += 1
            do, a = args["do"], args["args"]
            self.acts.append((do, a))
            if do == "get_items":
                self._get_items(a["items"])
            elif do == "mine":
                self.inv[a["item"]] = self.inv.get(a["item"], 0) + a["count"]
                self._done("mine", {"mined": {a["item"]: a["count"]}})
            elif do == "collect":
                (item, n), = a["items"].items()
                take = min(n, self.stock.get(item, 0))
                self.stock[item] -= take
                self.inv[item] = self.inv.get(item, 0) + take
                self._done("collect", {"collected": {item: take}})
            elif do == "place":
                if self.place_fail:
                    return self._emit("job_failed", {"job": self.job, "do": "place", "code": "cannot_place"})                         or ok({"job": self.job, "queued_before": 0})
                self.inv[a["item"]] -= 1
                self.placed.append({"name": a["item"], "pos": a["pos"], "unit": 100 + len(self.placed)})
                self._done("place", {"unit_number": 100 + len(self.placed) - 1})
            elif do == "deconstruct":
                t = a["target"]
                gone = [e for e in self.placed if e["unit"] == t["unit_number"]]
                if gone and not self.decon_fail:
                    self.placed.remove(gone[0])
                    self.inv[gone[0]["name"]] = self.inv.get(gone[0]["name"], 0) + 1
                self._done("deconstruct", {"removed": len(gone) if not self.decon_fail else 1, "got": {}})
            elif do == "craft" and a["recipe"] == "stone-furnace":
                self.inv["stone"] -= 5 * a["count"]
                self.inv["stone-furnace"] = self.inv.get("stone-furnace", 0) + a["count"]
                self._done("craft", {"crafted": {"stone-furnace": a["count"]}})
            elif do == "craft":
                if self.instant:
                    self.inv[a["recipe"]] = a["count"]
                    self._done("craft", {"crafted": {a["recipe"]: a["count"]}})
                else:
                    self.active = self.job
            else:
                raise AssertionError(do)
            return ok({"job": self.job, "queued_before": 0})
        if op == "map":
            names = args.get("names") or []
            return ok({"entities": [{"name": e["name"], "pos": e["pos"]} for e in self.placed
                                    if not names or e["name"] in names]})
        if op == "events":
            return ok({"seq": self.seq, "events": [e for e in self.events if e["seq"] > args["since"]] or {},
                       "lost": False})
        if op == "cancel":
            self.cancels.append(args)
            if self.active and not self.leak:
                code = "interrupted" if self.bad_cancel_event else "cancelled"
                self._emit("job_failed", {"job": self.active, "do": "craft", "code": code})
                self.active = None
            return ok({"cancelled": [self.active] if self.active else {}})
        raise AssertionError(op)


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)
    monkeypatch.setattr(lc.time, "sleep", lambda s: None)
    real_poll = lc.LiveClient.poll
    monkeypatch.setattr(lc.LiveClient, "poll", lambda self, fn, timeout, interval=1.0: real_poll(self, fn, min(timeout, 0.05), interval))


def run(world, fake_rcon, **patch):
    srv = fake_rcon(handler=world)
    sc_ = load()
    for k, v in patch.items():
        setattr(sc_, k, v)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = sc_.run(c)
    assert all(cmd.startswith("/partner {") for cmd in srv.commands)
    return res


def test_all_three_parts_pass(fake_rcon):
    w = World()
    res = run(w, fake_rcon)
    # ready-made plates лежат на складе: плавка берёт кирпич из камня, которого нет в stock
    assert res["ok"] is True, res.get("reasons") or res.get("setup_failed")
    assert res["craft"]["item"] == "electronic-circuit"
    assert "copper-cable" in res["craft"]["source"]["crafted"]
    assert res["smelt"]["item"] == "stone-brick" and res["smelt"]["source"]["smelted"]
    assert ("mine", {"item": "stone", "count": 10}) in w.acts
    assert res["cancel"]["event"] == "job_failed" and res["cancel"]["grown_after_cancel"] == 0
    assert w.cancels == [{"all": True}]
    assert w.active is None


def test_ready_item_on_storage_is_setup_failure_for_craft(fake_rcon):
    res = run(World(ready={c[0]: 10 for c in load().CRAFT_CANDIDATES}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"
    assert "готовое уже есть" in res["setup_failed"]["craft"]
    assert res["smelt"].get("item") == "stone-brick"        # остальные части шли дальше
    assert res["cancel"]["event"] == "job_failed"


def test_no_furnace_is_setup_not_a_mod_failure(fake_rcon):
    res = run(World(furnace=False), fake_rcon)
    assert res["ok"] is False and "reasons" not in res
    assert "no_furnace" in res["setup_failed"]["smelt"]


def test_plates_everywhere_but_no_ore_source_is_setup(fake_rcon):
    # пластины лежат на складе, кирпич не нужен: плавить нечего — но кирпич-то нужен, поэтому плавка идёт
    # по третьему кандидату; без печи — setup, а крафт и cancel проходят
    res = run(World(furnace=False), fake_rcon)
    assert res["craft"].get("item") == "electronic-circuit" and "setup_failed" not in res["craft"]
    assert res["cancel"]["recipe"] == "iron-gear-wheel"


def test_empty_base_everything_setup(fake_rcon):
    res = run(World(stock={}), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"
    assert set(res["setup_failed"]) >= {"craft", "cancel"}


def test_cancel_that_leaves_craft_running_fails(fake_rcon):
    res = run(World(leak=True), fake_rcon, FAIL_WAIT_S=0.05)
    assert res["ok"] is False
    assert any("job_failed{cancelled}" in r for r in res["reasons"]), res["reasons"]
    assert any("очередь" in r for r in res["reasons"]), res["reasons"]


def test_cancel_wrong_event_code_fails(fake_rcon):
    res = run(World(bad_cancel_event=True), fake_rcon, FAIL_WAIT_S=0.05)
    assert res["ok"] is False and any("job_failed{cancelled}" in r for r in res["reasons"])


def test_craft_that_never_runs_is_setup(fake_rcon):
    res = run(World(instant=True), fake_rcon)
    assert "не стала активной" in res["setup_failed"]["cancel"]


def test_smelt_places_own_furnace_and_removes_it(fake_rcon):
    w = World()
    res = run(w, fake_rcon)
    dos = [d for d, _ in w.acts]
    # печь: крафт из камня, place до get_items плавки, deconstruct после; на карте пусто
    assert dos.index("place") < max(i for i, (d, a) in enumerate(w.acts)
                                    if d == "get_items" and "stone-brick" in a["items"])
    assert dos.index("deconstruct") > dos.index("place")
    assert ("craft", {"recipe": "stone-furnace", "count": 1}) in w.acts
    assert w.placed == [] and w.inv.get("stone-furnace") == 1
    assert res["smelt_deconstruct"]["data"]["detail"]["removed"] == 1
    assert res["smelt_deconstruct"]["left_on_map"] == 0


def test_furnace_from_storage_skips_crafting(fake_rcon):
    w = World(ready={"stone-furnace": 3})
    res = run(w, fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("setup_failed")
    assert not any(d == "craft" and a.get("recipe") == "stone-furnace" for d, a in w.acts)
    assert w.placed == []


def test_furnace_removed_even_when_smelt_fails(fake_rcon):
    w = World(furnace=False)
    res = run(w, fake_rcon)
    assert "no_furnace" in res["setup_failed"]["smelt"]
    assert w.placed == []                  # печь убрана и в этом случае


def test_place_failure_is_setup_not_mod_failure(fake_rcon):
    res = run(World(place_fail=True), fake_rcon)
    assert "не ставится" in res["setup_failed"]["smelt"] and "reasons" not in res


def test_furnace_left_standing_is_a_failure(fake_rcon):
    res = run(World(decon_fail=True), fake_rcon)
    assert any("печь" in r for r in res["reasons"]), res
    assert res["ok"] is False


def test_craft_uses_radius_where_raw_was_found(fake_rcon):
    w = World(far=True)
    res = run(w, fake_rcon)
    assert res["ok"] is True, res.get("reasons") or res.get("setup_failed")
    assert res["craft"]["radius"] == 128
    assert ("get_items", {"items": {"electronic-circuit": 5}, "radius": 128}) in w.acts


def test_craft_prefers_candidate_without_middle_anywhere(fake_rcon):
    # промежуточный copper-cable лежит на складе: схема берёт кандидата, чей промежуточный придётся крафтить
    w = World(ready={"copper-cable": 50})
    res = run(w, fake_rcon)
    assert res["craft"]["item"] == "inserter", res["craft"]
    assert res["craft"]["middle_from"] == "crafted" and res["craft"]["chain_checked"] is True


def test_craft_fails_when_middle_not_crafted(fake_rcon, monkeypatch):
    # цепочку рецептов проверяем: без промежуточного в from.crafted — провал
    w = World()
    orig = w._done

    def done(do, detail):
        if do == "get_items":
            detail["from"].get("crafted", {}).pop("copper-cable", None)
        return orig(do, detail)
    monkeypatch.setattr(w, "_done", done)
    res = run(w, fake_rcon)
    assert res["ok"] is False and any("без промежуточного copper-cable" in x for x in res.get("reasons", [])), res


def test_craft_spare_candidate_with_middle_on_storage(fake_rcon):
    # у единственного кандидата промежуточный лежит на складе: он берётся запасным, промежуточный — из from.storage
    w = World(ready={"copper-cable": 50})
    cands = tuple(c for c in load().CRAFT_CANDIDATES if c[0] == "electronic-circuit")
    res = run(w, fake_rcon, CRAFT_CANDIDATES=cands)
    craft = res["craft"]
    assert craft["item"] == "electronic-circuit" and craft["middle_from"] == "storage", craft
    assert craft["chain_checked"] is False and "не проверена" in craft["note"]
    assert not any(x.startswith("craft:") for x in res.get("reasons", [])), res


def test_craft_spare_fails_when_middle_on_storage_not_taken(fake_rcon, monkeypatch):
    w = World(ready={"copper-cable": 50})
    orig = w._done

    def done(do, detail):
        if do == "get_items":
            detail["from"].pop("storage", None)
        return orig(do, detail)
    monkeypatch.setattr(w, "_done", done)
    cands = tuple(c for c in load().CRAFT_CANDIDATES if c[0] == "electronic-circuit")
    res = run(w, fake_rcon, CRAFT_CANDIDATES=cands)
    assert any("не в detail.from.storage" in x for x in res.get("reasons", [])), res


def test_craft_skipped_only_when_item_itself_is_on_storage(fake_rcon):
    w = World(ready={"electronic-circuit": 3})
    res = run(w, fake_rcon)
    assert res["craft"]["item"] == "inserter", res["craft"]


def test_smelt_asks_with_small_radius_near_own_furnace(fake_rcon):
    w = World()
    res = run(w, fake_rcon)
    asks = [a for do, a in w.acts if do == "get_items" and list(a["items"]) in (["iron-plate"], ["copper-plate"], ["stone-brick"])]
    assert asks and all(a["radius"] <= 6 for a in asks), asks
    assert res["smelt"]["radius"] == asks[-1]["radius"]
    assert res["smelt"]["furnace_dist"] <= 5


def test_new_candidates_are_reachable(fake_rcon):
    w = World(stock={"iron-plate": 400, "copper-plate": 400, "wood": 10, "stone": 20})
    sc_ = load()
    only = tuple(c for c in sc_.CRAFT_CANDIDATES if c[0] in ("assembling-machine-1", "small-electric-pole", "burner-mining-drill"))
    assert len(only) == 3
    for cand in only:
        res = run(World(stock=dict(w.stock)), fake_rcon, CRAFT_CANDIDATES=(cand,))
        assert res["craft"]["item"] == cand[0] and not res["craft"].get("setup_failed"), (cand, res["craft"])


# ---------- hold в ServerClient ----------

def test_server_client_exposes_hold():
    assert sc.TOOLS["hold"] == "op_hold"
    with open(HOLD_DOC, "r", encoding="utf-8") as f:
        assert "`partner_hold`" in f.read()


def test_hold_reaches_core_op_hold():
    seen = []

    class FakeCore:
        async def op_hold(self, helper, key, release=False, said_seq=None):
            seen.append((helper, key, release, said_seq))
            return {"hold": {}}

    loop = sc._Loop()
    try:
        client = sc.ServerClient(None, FakeCore(), loop, "h1", "k" * 48, Exception)
        client.live = type("L", (), {"time_left": staticmethod(lambda: 60.0)})()
        assert client.tool("hold") == {"hold": {}}
        client.tool("hold", release=True, said_seq=7)
    finally:
        loop.stop()
    assert seen == [("h1", "k" * 48, False, None), ("h1", "k" * 48, True, 7)]
