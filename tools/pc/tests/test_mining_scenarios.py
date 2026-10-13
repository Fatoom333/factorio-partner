"""Сценарии mining_* (поток M) против фейкового RCON с моделью мода: resources → plan_mining → сверка."""
from __future__ import annotations

import json
import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR

DIRS = {"north": 0, "east": 4, "south": 8, "west": 12}
HELPER_POS = {"x": 10.3, "y": 4.2}
PATCH = {"name": "iron-ore", "center": {"x": 30.5, "y": 10.5},
         "area": {"left_top": {"x": 24, "y": 6}, "right_bottom": {"x": 37, "y": 15}},
         "tiles": 110, "amount": 110000, "dist": 21.0}
OIL = {"name": "crude-oil", "center": {"x": 12.5, "y": 3.5},  # большое «пятно» жидкости: отсеивает сам мод
       "area": {"left_top": {"x": 10, "y": 1}, "right_bottom": {"x": 15, "y": 6}}, "tiles": 20, "amount": 9, "dist": 4.0}
GEYSER = {"name": "sulfuric-acid-geyser", "center": {"x": 14.5, "y": 8.5},
          "area": {"left_top": {"x": 14, "y": 8}, "right_bottom": {"x": 15, "y": 9}}, "tiles": 1, "amount": 9, "dist": 5.0}
HUGE = {"name": "stone", "center": {"x": 90.5, "y": 0.5},
        "area": {"left_top": {"x": 20, "y": -40}, "right_bottom": {"x": 160, "y": 40}}, "tiles": 9000, "amount": 1,
        "dist": 80.0}


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


class Model:
    """Модель мода: пятна руды, призраки на карте, действие plan_mining с простой раскладкой."""

    def __init__(self, patches=None, mod="factorio-partner 0.1.0", belt_dir=None, lose=0, uncovered=0,
                 shift=0, bad_modes=("logistics", "compact_logistics", "sparse_logistics"), broken_mode=None,
                 occupied=False, existing=0, sparse_drills=None, no_underground=False, never_done=False):
        self.mod = mod
        self.patches = list(patches if patches is not None else [OIL, PATCH])
        self.ghosts = {}      # (x, y) -> (имя, dir)
        self.events = []
        self.seq = 0
        self.job = 0
        self.acts = []
        self.resource_queries = 0
        self.belt_dir = belt_dir          # лента смотрит не туда
        self.lose = lose                  # столько призраков «потерять» (ответ больше, чем на карте)
        self.uncovered = uncovered
        self.shift = shift                # сдвиг раскладки от пятна
        self.bad_modes = set(bad_modes)   # режимы, которым не хватает исследований (bad_args)
        self.broken_mode = broken_mode    # режим падает с internal
        self.occupied = occupied          # всё занято: cannot_place
        self.sparse_drills = sparse_drills
        self.no_underground = no_underground
        self.never_done = never_done
        for i in range(existing):         # чужие призраки, стоявшие до разметки
            self.ghosts[(24.5 + i, 5.5)] = ("stone-furnace", 0)

    # ---- события
    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "mining", "kind": kind, "data": data, "loud": True})

    def _failed(self, code, text, detail=None):
        self._emit("job_failed", {"job": self.job, "do": "plan_mining", "code": code, "text": text, "detail": detail or {}})

    # ---- раскладка
    def _layout(self, patch, layout, direction):
        a = patch["area"]
        x0, y0 = a["left_top"]["x"] + self.shift, a["left_top"]["y"]
        cols = max(1, int((a["right_bottom"]["x"] - a["left_top"]["x"]) // 3))
        drills = cols * 2
        if layout.startswith("sparse"):
            drills = self.sparse_drills if self.sparse_drills is not None else cols
        out = []
        for i in range(drills):
            out.append(("electric-mining-drill", (x0 + 1.5 + 3 * (i % cols), y0 + 1.5 + 4 * (i // cols)), 0))
        belt_dir = DIRS[direction] if self.belt_dir is None else self.belt_dir
        if layout.endswith("logistics"):
            for i in range(cols):
                out.append(("passive-provider-chest", (x0 + 1.5 + 3 * i, y0 + 3.5), 0))
        else:
            for i in range(cols * 3):
                out.append(("transport-belt", (x0 + 0.5 + i, y0 + 3.5), belt_dir))
            if layout in ("compact", "super_compact") and not self.no_underground:
                out.append(("underground-belt", (x0 - 0.5, y0 + 3.5), belt_dir))
                out.append(("underground-belt", (x0 - 1.5, y0 + 3.5), belt_dir))
        for i in range(cols):
            out.append(("small-electric-pole", (x0 + 0.5 + 3 * i, y0 + 7.5), 0))
        return out, drills

    def _plan(self, a):
        self.job += 1
        self.acts.append(a)
        if self.never_done:
            return
        assert ("near" in a) != ("area" in a)
        patch = None
        for p in self.patches:
            if p["name"] != a.get("resource"):
                continue
            if "area" in a:
                # окно внутри крупного пятна: раскладка ложится в окно
                w = a["area"]
                assert w["right_bottom"]["x"] - w["left_top"]["x"] <= 128
                if w["left_top"]["x"] <= p["center"]["x"] <= w["right_bottom"]["x"]:
                    patch = dict(p, area={"left_top": {"x": w["left_top"]["x"] + 6, "y": w["left_top"]["y"] + 6},
                                          "right_bottom": {"x": w["right_bottom"]["x"] - 6, "y": w["right_bottom"]["y"] - 6}})
            elif p["center"] == a.get("near"):
                patch = p
        if patch is None:
            return self._failed("not_found", "no ore within 10 tiles of args.near")
        if patch["name"] in ("crude-oil", "sulfuric-acid-geyser"):
            return self._failed("bad_args", "args.resource: " + patch["name"] + " is not a solid ore")
        if patch["name"] == "tungsten-ore":
            return self._failed("bad_args", "no researched mining drill fits layout simple and tungsten-ore")
        if patch is HUGE:
            return self._failed("limit", "ore patch is larger than 128x128, use args.area")
        layout, direction = a.get("layout", "simple"), a.get("direction", "north")
        if layout == self.broken_mode:
            return self._failed("internal", "attempt to index a nil value")
        if layout in self.bad_modes:
            return self._failed("bad_args", "layout " + layout + " needs passive-provider-chest, it is not researched")
        plan, drills = self._layout(patch, layout, direction)
        if self.occupied:
            return self._failed("cannot_place", "MPP: unable to place a mining layout here",
                                {"ghosts": 0, "skipped": len(plan), "need": {}, "layout": layout, "warnings": []})
        need = {}
        xs, ys = [], []
        for name, (x, y), _ in plan:
            need[name] = need.get(name, 0) + 1
            xs.append(x)
            ys.append(y)
        warnings = ["uncovered_ore_tiles:%d" % self.uncovered] if self.uncovered else []
        chosen = {"miner": "electric-mining-drill", "pole": "small-electric-pole"}
        if layout.endswith("logistics"):
            chosen["chest"] = "passive-provider-chest"
        else:
            chosen["belt"] = "transport-belt"
        detail = {"ghosts": len(plan), "need": need, "layout": layout, "warnings": warnings, "drills": drills,
                  "skipped": 0, "tiles": 0, "chosen": chosen,
                  "area": {"left_top": {"x": int(min(xs) - 2), "y": int(min(ys) - 2)},
                           "right_bottom": {"x": int(max(xs) + 2), "y": int(max(ys) + 2)}}}
        if a.get("dry_run"):
            detail["dry_run"] = True
        else:
            for name, pos, d in plan[self.lose:]:
                self.ghosts[pos] = (name, d)
        self._emit("job_done", {"job": self.job, "do": "plan_mining", "detail": detail})

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
            return ok({"helper": env["helper"], "unit_number": 7, "surface": "nauvis", "pos": dict(HELPER_POS)})
        if op == "state":
            return ok({"helper": env["helper"], "surface": "nauvis", "pos": dict(HELPER_POS)})
        if op == "resources":
            assert args["radius"] == 128
            self.resource_queries += 1
            c = args.get("center") or HELPER_POS
            near = [p for p in self.patches
                    if math.hypot(p["center"]["x"] - c["x"], p["center"]["y"] - c["y"]) <= args["radius"]]
            name = args.get("name")
            if name is None:
                # как мод: не больше 20 ближайших пятен
                return ok({"patches": near[:20], "truncated": len(near) > 20})
            if name not in ("iron-ore", "copper-ore", "coal", "stone", "calcite", "tungsten-ore"):
                return fail("bad_args")   # такой руды в этой игре нет
            return ok({"patches": [p for p in near if p["name"] == name][:20], "truncated": False})
        if op == "ghosts":
            a = args["area"]
            assert a["right_bottom"]["x"] - a["left_top"]["x"] <= 128
            inside = [v for k, v in self.ghosts.items()
                      if a["left_top"]["x"] <= k[0] <= a["right_bottom"]["x"] and a["left_top"]["y"] <= k[1] <= a["right_bottom"]["y"]]
            by_name = {}
            for name, _ in inside:
                by_name[name] = by_name.get(name, 0) + 1
            return ok({"count": len(inside), "by_name": by_name, "need": dict(by_name), "blocked": [], "blocked_total": 0})
        if op == "map":
            assert args["radius"] <= 32
            c, r = args["center"], args["radius"]
            ents = [{"c": "g", "name": v[0], "pos": {"x": k[0], "y": k[1]}, "dir": v[1], "ghost": True}
                    for k, v in self.ghosts.items()
                    if v[0] in args.get("names", [v[0]]) and abs(k[0] - c["x"]) <= r and abs(k[1] - c["y"]) <= r]
            return ok({"entities": ents[:100], "rows": [], "truncated": len(ents) > 100})
        if op == "act":
            assert args["do"] == "plan_mining"
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
    return res


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    """Паузы сценариев (опрос событий) в офлайн-тестах не нужны."""
    monkeypatch.setattr(lc.LiveClient, "sleep", lambda self, s: None)


# ---------- mining_plan ----------

def test_plan_ok(fake_rcon):
    m = Model()
    res = run("mining_plan", m, fake_rcon)
    assert res["ok"] is True, res
    # нефть отсеялась сухим прогоном, руда выбрана
    assert [t["code"] for t in res["dry_run"]] == ["bad_args", None]
    assert res["patch"]["name"] == "iron-ore"
    # сухие прогоны (нефть, руда, справка про отсыпку), настоящий, повтор
    assert [bool(a.get("dry_run")) for a in m.acts] == [True, True, True, False, False]
    assert m.acts[2]["options"] == {"landfill": True} and res["landfill_probe"]["kind"] == "job_done"
    real = m.acts[3]
    assert real == {"near": PATCH["center"], "resource": "iron-ore", "layout": "simple", "direction": "east"}
    assert res["scan"] == [{"ring": 0, "queries": 1, "fit": 2, "big": 0}]
    assert res["uncovered"] == {"tiles": 0, "allowed": 1}
    assert res["belts"]["dirs"] == [4] and res["belts"]["seen"] > 0
    assert res["drills"]["on_map"] == res["drills"]["detail"] > 0
    assert res["ghosts_op"]["after"] - res["ghosts_op"]["before"] == res["plan"]["data"]["detail"]["ghosts"]
    assert res["repeat"]["kind"] == "job_done"


def test_plan_counts_only_new_ghosts(fake_rcon):
    res = run("mining_plan", Model(existing=3), fake_rcon)
    assert res["ok"] is True, res
    assert res["ghosts_op"]["before"] == 3


def test_plan_skips_geysers_and_fluids(fake_rcon):
    """Живой замер 2026-10-13 (Vulcanus): 20 ближайших «пятен» — гейзеры кислоты по одной клетке."""
    oil2 = dict(OIL, center={"x": 40.5, "y": 40.5},
                area={"left_top": {"x": 38, "y": 38}, "right_bottom": {"x": 43, "y": 43}})
    m = Model(patches=[GEYSER] * 12 + [OIL, oil2, PATCH])
    res = run("mining_plan", m, fake_rcon)
    assert res["ok"] is True, res
    assert res["scan"] == [{"ring": 0, "queries": 1, "fit": 3, "big": 0}]
    # гейзеры отсеяны по размеру, второе пятно нефти — по имени после первого отказа
    assert [t["name"] for t in res["dry_run"]] == ["crude-oil", "iron-ore"]


def test_plan_finds_ore_by_name_when_reply_is_all_geysers(fake_rcon):
    """20 ближайших «пятен» — гейзеры: общий ответ resources руды не содержит, ищем по именам."""
    m = Model(patches=[GEYSER] * 25 + [PATCH])
    res = run("mining_plan", m, fake_rcon)
    assert res["ok"] is True, res
    # общий запрос + 8 имён руд
    assert res["scan"] == [{"ring": 0, "queries": 9, "swamped": ["sulfuric-acid-geyser"], "fit": 1, "big": 0}]
    assert res["patch"]["name"] == "iron-ore"


def test_plan_searches_rings_when_no_ore_near(fake_rcon):
    """Живой замер 2026-10-13: в 128 клетках от хозяина руды нет вовсе — ищем кольцами дальше."""
    far = dict(PATCH, center={"x": -150.5, "y": 220.5},
               area={"left_top": {"x": -157, "y": 216}, "right_bottom": {"x": -144, "y": 225}})
    tungsten = dict(far, name="tungsten-ore", center={"x": 250.5, "y": 30.5},
                    area={"left_top": {"x": 244, "y": 26}, "right_bottom": {"x": 257, "y": 35}})
    m = Model(patches=[GEYSER] * 25 + [tungsten, far])
    res = run("mining_plan", m, fake_rcon)
    assert res["ok"] is True, res
    assert [s["ring"] for s in res["scan"]] == [0, 1]
    assert res["scan"][0]["fit"] == 0 and res["scan"][1]["fit"] == 2
    # ближнее пятно вольфрама буру не по зубам (bad_args) — берётся следующее
    assert [(t["name"], t["code"]) for t in res["dry_run"]] == [("tungsten-ore", "bad_args"), ("iron-ore", None)]
    assert res["patch"]["dist"] == pytest.approx(269.5, abs=0.2)
    assert m.acts[-1]["near"] == far["center"]


def test_plan_prefers_fitting_patch_over_huge(fake_rcon):
    m = Model(patches=[HUGE, PATCH])
    res = run("mining_plan", m, fake_rcon)
    assert res["ok"] is True, res
    assert res["scan"] == [{"ring": 0, "queries": 1, "fit": 1, "big": 1}]
    assert all(a["resource"] == "iron-ore" and "near" in a for a in m.acts)


def test_plan_huge_patch_uses_area_window(fake_rcon):
    m = Model(patches=[HUGE])
    res = run("mining_plan", m, fake_rcon)
    assert res["ok"] is True, res
    window = res["patch"]["window"]
    assert window == {"left_top": {"x": 66, "y": -24}, "right_bottom": {"x": 114, "y": 24}}
    assert all(a["area"] == window and "near" not in a for a in m.acts)


def test_plan_no_patches_is_setup_error(fake_rcon):
    m = Model(patches=[])
    res = run("mining_plan", m, fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"
    assert [s["ring"] for s in res["scan"]] == [0, 1, 2]
    assert m.resource_queries == 1 + 8 + 16
    assert m.acts == []


def test_plan_wrong_mod(fake_rcon):
    res = run("mining_plan", Model(mod="partner-test 0.3.0"), fake_rcon)
    assert res["ok"] is False and res["error"]["kind"] == "setup"


def test_plan_nothing_fits(fake_rcon):
    res = run("mining_plan", Model(patches=[OIL]), fake_rcon)
    assert res["ok"] is False and res["reasons"]
    res = run("mining_plan", Model(occupied=True), fake_rcon)
    assert res["ok"] is False and res["reasons"]
    assert res["dry_run"][-1]["code"] == "cannot_place"


@pytest.mark.parametrize("kw, word", [
    ({"belt_dir": 0}, "лента"),            # лента смотрит на север вместо востока
    ({"lose": 2}, "ghosts"),               # действие сообщило больше, чем стоит на карте
    ({"uncovered": 5}, "покрыта"),         # руда покрыта не вся
    ({"shift": 40}, "не внутри"),          # разметка мимо пятна
])
def test_plan_failures(fake_rcon, kw, word):
    res = run("mining_plan", Model(**kw), fake_rcon)
    assert res["ok"] is False, res
    assert any(word in r for r in res["reasons"]), res["reasons"]
    assert "repeat" not in res


def test_plan_job_never_finishes(fake_rcon, monkeypatch):
    mod = load("mining_plan")
    monkeypatch.setattr(lc.LiveClient, "time_left", lambda self: 0.05)
    srv = fake_rcon(handler=Model(never_done=True))
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = mod.run(c)
    assert res["ok"] is False and res["reasons"]
    assert res["dry_run"][0]["kind"] is None and len(res["dry_run"]) == 1


# ---------- mining_modes ----------

def test_modes_ok(fake_rcon):
    m = Model()
    res = run("mining_modes", m, fake_rcon)
    assert res["ok"] is True, res
    assert set(res["modes"]) == {"simple", "compact", "super_compact", "sparse", "logistics", "compact_logistics",
                                 "sparse_logistics"}
    assert res["modes"]["compact"]["kind"] == "job_done"
    assert res["modes"]["logistics"]["code"] == "bad_args"
    assert res["extra_items"] == ["underground-belt"]
    # по-настоящему ставится только compact
    real = [a for a in m.acts if not a.get("dry_run")]
    assert [a["layout"] for a in real] == ["compact"]
    assert res["drills"]["on_map"] == res["drills"]["detail"]


def test_modes_all_researched(fake_rcon):
    res = run("mining_modes", Model(bad_modes=()), fake_rcon)
    assert res["ok"] is True, res
    assert res["modes"]["sparse_logistics"]["chosen"]["chest"] == "passive-provider-chest"


@pytest.mark.parametrize("kw, word", [
    ({"bad_modes": ("compact",)}, "compact"),          # обязательный режим не встал
    ({"broken_mode": "super_compact"}, "bad_args"),    # необязательный упал не с bad_args
    ({"sparse_drills": 99}, "sparse"),                 # sparse ставит больше буров, чем simple
    ({"no_underground": True}, "подземной"),           # compact без подземной ленты
    ({"lose": 1}, "ghosts"),
])
def test_modes_failures(fake_rcon, kw, word):
    res = run("mining_modes", Model(**kw), fake_rcon)
    assert res["ok"] is False, res
    assert any(word in r for r in res["reasons"]), res["reasons"]


def test_modes_no_patch(fake_rcon):
    res = run("mining_modes", Model(patches=[OIL]), fake_rcon)
    assert res["ok"] is False and res["reasons"]
