"""Сценарий belt_resume (поток R, ревизия 3.5) против модели мода: plan_belt → стройка на часть лент →
помеха из инвентаря → plan_belt{from:"resume"} → сверка с картой. Флаги модели ломают что-то одно —
сценарий должен это заметить."""
from __future__ import annotations

import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR
from e2e_world import DIR_OF, VEC, World

BELT = "transport-belt"
CHEST = "wooden-chest"


def load(name):
    mod = lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))
    mod.E.VISIBLE_WAIT_S = 0.05     # в модели склады видны сразу
    return mod


def stores(belts=200, chests=5):
    items = {}
    if belts:
        items[BELT] = belts
    if chests:
        items[CHEST] = chests
    return [{"unit": 101, "name": "steel-chest", "pos": {"x": 40.5, "y": 30.5}, "items": items}]


def pos_of(cell):
    return (cell[0] + 0.5, cell[1] + 0.5)


class ResumeWorld(World):
    """Модель с памятью плана ленты, действием place и перекладкой from:"resume"."""

    def __init__(self, keep_old=False, lie_built=0, lie_removed=0, eat_built=False, through=False,
                 no_memory=False, ghost_survives=False, apart=False, quiet_apart=False, place_fails=False,
                 no_detour=False, **kw):
        kw.setdefault("stores", stores())
        super().__init__(**kw)
        self.keep_old = keep_old              # старые призраки не убраны
        self.lie_built = lie_built            # ответ врёт о построенном
        self.lie_removed = lie_removed        # ответ врёт об убранном
        self.eat_built = eat_built            # перекладка сносит построенную ленту
        self.through = through                # новый путь идёт прямо через помеху
        self.no_memory = no_memory            # план не запомнен: bad_args
        self.ghost_survives = ghost_survives  # призрак под поставленным сундуком остаётся (как может быть в игре)
        self.apart = apart                    # кто-то достроил клетку дальше разрыва
        self.quiet_apart = quiet_apart        # …а перекладка об этом молчит
        self.place_fails = place_fails
        self.no_detour = no_detour            # перекладка ничего не ставит
        self.under = {}                       # призраки, оставшиеся под постройкой: клетка -> сущность

    def op_map(self, args, helper):
        data = super().op_map(args, helper)
        center, radius = self._center(args, helper), int(args.get("radius", 16))
        ents = list(data["entities"] or [])
        for pos, e in sorted(self.under.items()):
            if abs(pos[0] - center["x"]) <= radius + 0.5 and abs(pos[1] - center["y"]) <= radius + 0.5:
                ents.append({"c": "g", "name": e["name"], "pos": {"x": pos[0], "y": pos[1]}, "dir": e["dir"],
                             "ghost": True})
        data["entities"] = ents or {}
        return data

    def do_place(self, h, a):
        item, pos = a["item"], (a["pos"]["x"], a["pos"]["y"])
        if self.place_fails:
            raise self._fail("cannot_place", item + " cannot be placed here")
        if h["inv"].get(item, 0) < 1:
            raise self._fail("no_items", "no " + item + " in the inventory")
        old = self.entities.get(pos)
        if old is not None and not old["ghost"]:
            raise self._fail("cannot_place", item + " cannot be placed here")
        if old is not None and self.ghost_survives:
            self.under[pos] = old
        h["inv"][item] -= 1
        h["inv"] = {k: n for k, n in h["inv"].items() if n > 0}
        self.entities[pos] = {"name": item, "dir": 0, "ghost": False}
        h["pos"] = {"x": pos[0] + 1.0, "y": pos[1] + 1.0}
        return {"unit_number": 900, "name": item, "pos": dict(a["pos"])}

    def do_rotate(self, h, a):
        pos = (a["target"]["pos"]["x"], a["target"]["pos"]["y"])
        e = self.entities.get(pos)
        if e is None or e["ghost"] or e["name"] != a["target"]["name"]:
            raise self._fail("not_found", "no such entity near the given pos")
        num = {"north": 0, "east": 4, "south": 8, "west": 12}
        name = {v: k for k, v in num.items()}
        was = num.get(e["dir"], e["dir"])
        e["dir"] = name[a["direction"]] if isinstance(e["dir"], str) else a["direction"]
        return {"name": e["name"], "pos": dict(a["target"]["pos"]), "direction": a["direction"], "was": was}

    def do_build_ghosts(self, h, a):
        try:
            return super().do_build_ghosts(h, a)
        finally:
            if self.apart:
                cells = h.get("belt_last", {}).get("cells", [])
                left = [c for c in cells if self.entities.get(pos_of(c), {}).get("ghost")]
                if len(left) > 12:
                    self.entities[pos_of(left[10])]["ghost"] = False     # достроили дроны хозяина

    def do_plan_belt(self, h, a):
        if a.get("from") == "resume":
            return self._resume(h, a)
        detail = super().do_plan_belt(h, a)
        if not a.get("dry_run"):
            start = (int(math.floor(a["from"]["x"])), int(math.floor(a["from"]["y"])))
            to = (int(math.floor(a["to"]["x"])), int(math.floor(a["to"]["y"])))
            cells = [c for c in self._line(start, to)]
            h["belt_last"] = {"cells": cells, "to": to, "belt": a.get("belt", BELT)}
        return detail

    def _line(self, start, to):
        """Клетки поставленной ленты по порядку: идём по призракам от начала."""
        out, cur = [], start
        while pos_of(cur) in self.entities and cur not in out:
            out.append(cur)
            if cur == to:
                break
            dx, dy = VEC[self.entities[pos_of(cur)]["dir"]]
            cur = (cur[0] + dx, cur[1] + dy)
        return out

    def _resume(self, h, a):
        last = h.get("belt_last")
        if not last or self.no_memory:
            raise self._fail("bad_args", 'args.from "resume": this helper has no remembered belt plan')
        if "to" in a and (int(math.floor(a["to"]["x"])), int(math.floor(a["to"]["y"]))) != last["to"]:
            raise self._fail("bad_args", "args.to differs from the remembered plan")
        cells, belt, to = last["cells"], last["belt"], last["to"]

        def is_built(c):
            e = self.entities.get(pos_of(c))
            return e is not None and not e["ghost"] and e["name"] == belt

        n = 0
        while n < len(cells) and is_built(cells[n]):
            n += 1
        removed, kept = 0, []
        for c in cells[n:]:
            for store in (self.entities, self.under):
                e = store.get(pos_of(c))
                if e is not None and e["ghost"] and e["name"] == belt:
                    removed += 1
                    if self.keep_old:
                        kept.append((store, pos_of(c), e))
                    del store[pos_of(c)]
        apart = sum(1 for c in cells[n:] if is_built(c))
        if self.eat_built and n:
            del self.entities[pos_of(cells[0])]
        head = cells[n] if n else cells[0]
        path = None if self.no_detour else self._belt_route(head, to)
        if self.through:
            path = [c for c in cells[n:]]
        for store, pos, e in kept:
            store.setdefault(pos, e)
        if path is None and not self.no_detour:
            raise self._fail("path_failed", "no belt path to the target (unreachable)",
                             {"reason": "unreachable", "removed": removed})
        path = path or []
        last_dir = self.entities[pos_of(cells[n - 1])]["dir"] if n else 4
        for i, cell in enumerate(path):
            nxt = path[i + 1] if i + 1 < len(path) else None
            d = DIR_OF[(nxt[0] - cell[0], nxt[1] - cell[1])] if nxt else last_dir
            last_dir = d
            self.entities[pos_of(cell)] = {"name": belt, "dir": d, "ghost": True}
        last["cells"] = cells[:n] + path
        warnings = []
        if apart and not self.quiet_apart:
            warnings.append("built_apart:%d" % apart)
        detail = {"ghosts": len(path), "length": len(path), "undergrounds": 0, "turns": 0, "need": {belt: len(path)},
                  "path": [], "warnings": warnings or {}, "lanes": 1, "chosen": {"belt": belt},
                  "resumed": {"built": n + self.lie_built, "removed": removed + self.lie_removed}}
        if path:
            xs, ys = [c[0] for c in path], [c[1] for c in path]
            detail["area"] = {"left_top": {"x": min(xs), "y": min(ys)},
                              "right_bottom": {"x": max(xs) + 1, "y": max(ys) + 1}}
        return detail


@pytest.fixture
def live(fake_rcon):
    made = []

    def make(world, **kw):
        srv = fake_rcon(handler=world.handler)
        client = lc.LiveClient(srv.port, PASSWORD, timeout=5, **kw)
        client.connect()
        made.append(client)
        return client, srv

    yield make
    for c in made:
        c.close()


def run(live, **flags):
    world = ResumeWorld(**flags)
    client, _ = live(world)
    return load("belt_resume").run(client), world


def text(res):
    return " | ".join(res.get("reasons", [])) + " " + str((res.get("error") or {}).get("text", ""))


def acts(world, do):
    return [a for d, a in world.acts if d == do]


def test_happy_path_relays_around_the_obstacle(live):
    res, world = run(live)
    assert res["ok"] is True, res
    cells = res["points"]["cells"]
    assert 30 <= cells <= 60
    belts = res["items"]["belts"]
    assert res["before"] == {"built": belts, "prefix": belts, "apart": 0, "ghosts": cells - belts}
    # помеха — на недостроенной клетке, честно из инвентаря
    place = acts(world, "place")
    assert len(place) == 1 and place[0]["item"] == CHEST
    cell = tuple(res["obstacle"]["cell"])
    assert world.entities[(cell[0] + 0.5, cell[1] + 0.5)] == {"name": CHEST, "dir": 0, "ghost": False}
    assert CHEST not in world.helpers["e2e"]["inv"]
    # перекладка — один вызов, без to
    plans = acts(world, "plan_belt")
    assert plans[-1] == {"from": "resume"} and len(plans) == 2
    assert plans[0]["underground"] == "never" and "dry_run" not in plans[0]
    after = res["after"]
    assert after["reached"] is True
    assert after["resumed"] == {"built": belts, "removed": cells - belts - 1}   # призрак под сундуком игра убрала
    assert after["ghosts"] > cells - belts - 1, "обход длиннее прямой"
    assert after["chain"] == belts + after["ghosts"]
    assert res["obstacle"]["ghost_under"] is False


def test_ghost_surviving_under_the_obstacle_is_counted_and_removed(live):
    res, world = run(live, ghost_survives=True)
    assert res["ok"] is True, res
    assert res["obstacle"]["ghost_under"] is True
    assert res["after"]["resumed"]["removed"] == res["points"]["cells"] - res["items"]["belts"]
    assert world.under == {}


def test_only_envelopes_and_honest_actions(live):
    res, world = run(live)
    assert res["ok"] is True
    assert set(world.ops) <= {"hello", "helper_spawn", "state", "stock", "find", "map", "act", "events", "recipes",
                              "cancel"}
    assert {d for d, _ in world.acts} <= {"collect", "craft", "walk", "plan_belt", "build_ghosts", "place", "rotate"}


@pytest.mark.parametrize("flags,needle", [
    ({"keep_old": True}, "призрак"),
    ({"lie_built": 1}, "resumed.built"),
    ({"lie_removed": -2}, "resumed.removed"),
    ({"eat_built": True}, "не цела"),
    ({"through": True}, "помех"),
    ({"no_memory": True}, "resume не done"),
    ({"no_detour": True}, "не доходит до цели"),
    ({"apart": True, "quiet_apart": True}, "built_apart"),
])
def test_broken_mod_is_noticed(live, flags, needle):
    res, _ = run(live, **flags)
    assert res["ok"] is False, res
    assert needle in text(res), text(res)


def test_built_apart_is_a_warning_not_a_failure(live):
    res, _ = run(live, apart=True)
    assert res["ok"] is True, res
    assert res["before"]["apart"] == 1
    assert any(str(w).startswith("built_apart:") for w in res["after"]["warnings"])


@pytest.mark.parametrize("flags,needle", [
    ({"belts": 0}, "не удалось честно взять предметы"),      # ленту можно бы скрафтить, да не из чего
    ({"chests": 0}, "ленты или сундука"),
    ({"place_fails": True}, "помеху поставить не удалось"),
    ({"liquid": {(x, y) for x in range(-40, 60) for y in range(-40, 60) if (x + y) % 4 == 0}}, "полосы земли"),
])
def test_setup_problems_are_reported_as_setup(live, flags, needle):
    flags = dict(flags)
    if "belts" in flags or "chests" in flags:
        flags = {"stores": stores(belts=flags.get("belts", 200), chests=flags.get("chests", 5))}
    res, _ = run(live, **flags)
    assert res["ok"] is False
    assert res["error"]["kind"] == "setup" and needle in res["error"]["text"], res


def test_scenario_declares_the_mod_and_is_documented():
    mod = load("belt_resume")
    assert mod.MODS == ["factorio-partner"] and callable(mod.run)
    doc = mod.__doc__ or ""
    for word in ('from: "resume"', "place", "build_ghosts", "resumed.built", "resumed.removed"):
        assert word in doc, word
    src = open(os.path.join(PC_DIR, "scenarios", "belt_resume.py"), encoding="utf-8").read()
    for bad in ('"/c ', '"/sc ', "silent-command", "teleport"):
        assert bad not in src
