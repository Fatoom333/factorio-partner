"""Сценарии build_place / build_decon / build_ghosts (поток F) против фейкового RCON с моделью мода.

Модель (`Model`) — общая для всех офлайн-тестов сценариев build_*: её же берут test_build_modes.py
и test_build_shapes.py.
"""
from __future__ import annotations

import json
import math
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load(name):
    return lc.load_scenario(name, os.path.join(PC_DIR, "scenarios"))


class Model:
    """Модель мода и мира для офлайн-тестов сценариев build_*.

    Мир: склад хозяина, инвентарь помощника, постройки, призраки построек и плиток, уложенные
    плитки, лава, камни и деревья, пометки к сносу. «Движок» постановки чертежа ведёт себя так, как
    показал живой прогон 2026-10-13 (2.0.77): normal — помеха → призрака нет; forced — камни и
    деревья помечаются, свои постройки нет, на лаве без исследованной подложки ничего не встаёт;
    superforced — помечаются ещё и свои постройки. Мод — по ACTIONS.md ревизии 3.3: клетка на лаве
    без возможной подложки в forced/superforced → чертёж не ставится вовсе (`cannot_place`,
    `on_liquid`, `liquids`, `fit`), с `partial` — обрезанный, в normal — пропуск клетки; свои пометки
    к сносу снимаются при сбое и отмене. Флаги ломают отдельные части (для тестов «сценарий
    замечает поломку»).
    """

    SIZE = {"stone-furnace": 2}
    RECIPES = {"iron-chest": ("iron-plate", 8), "wooden-chest": ("wood", 2), "steel-chest": ("steel-plate", 8),
               "stone-wall": ("stone-brick", 5), "stone-furnace": ("stone", 5)}
    TILE_ITEM = {"refined-concrete": "refined-concrete", "concrete": "concrete", "stone-path": "stone-brick",
                 "landfill": "landfill", "foundation": "foundation"}
    YIELD = {"big-volcanic-rock": {"stone": 5}, "ashland-lichen-tree": {"wood": 2}}
    TYPES = {"stone-furnace": "furnace", "big-volcanic-rock": "simple-entity", "ashland-lichen-tree": "tree"}

    def __init__(self, stock=None, blocked=(), mod="factorio-partner 0.1.0", break_place=None,
                 keep_ghosts=False, lose_item=False, decon_fails=False, collect_blind=False,
                 lava=(), naturals=None, lava_cover=None, forced_marks_own=False, dig_fails=False,
                 tiles_last=False, ignore_tiles=False, layout_shift=0.0, robots=0, armor=None,
                 keep_marks=False, pause_far=None, no_fit=False, ignore_partial=False, place_on_liquid=False):
        self.mod = mod
        self.stock = dict(stock if stock is not None else {"wooden-chest": 5})
        self.inv = {}
        self.pos = {"x": 10.3, "y": -4.7}
        self.blocked = {tuple(b) for b in blocked}
        self.entities = {}       # (x, y) центра -> имя
        self.units = {}          # (x, y) -> unit_number
        self.ghosts = {}         # (x, y) -> имя
        self.tile_ghosts = {}    # (cx, cy) клетки -> плитка
        self.tiles = {}          # (cx, cy) -> уложенная плитка
        self.lava = {tuple(c) for c in lava}                 # клетки лавы
        self.naturals = dict(naturals or {})                 # (x, y) -> имя камня/дерева
        self.marked = set()      # ключи (x, y) помеченного к сносу
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
        self.collect_blind = collect_blind   # collect ничего не видит (нет обзора), extract работает
        self.lava_cover = lava_cover         # плитка-подложка, которую «движок» ставит на лаве (None — не ставит)
        self.forced_marks_own = forced_marks_own
        self.dig_fails = dig_fails           # помощник не может разобрать помеченное
        self.tiles_last = tiles_last         # мод строит плитки после построек
        self.ignore_tiles = ignore_tiles     # мод не ставит плитки чертежа
        self.layout_shift = layout_shift     # расчёт мода (pos в skipped) сдвинут относительно «движка»
        self.robots = robots
        self.armor = armor
        self.rot_shift = 0
        self.spawned = False
        self.keep_marks = keep_marks         # мод не снимает свои пометки к сносу при сбое и отмене
        self.pause_far = pause_far           # стройка руками дальше стольких клеток «идёт», пока её не отменят
        self.no_fit = no_fit                 # мод не ищет сдвиг
        self.ignore_partial = ignore_partial # мод не ставит обрезанный чертёж
        self.place_on_liquid = place_on_liquid   # мод ставит чертёж, хотя под клеткой нет подложки
        self.pending = None                  # (job, do, свои пометки) — задача, которая ещё идёт

    # ---- события
    def _emit(self, kind, data):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.seq, "helper": "build", "kind": kind, "data": data, "loud": True})

    def _done(self, do, detail):
        self._emit("job_done", {"job": self.job, "do": do, "detail": detail})

    def _failed(self, do, code, detail=None):
        self._emit("job_failed", {"job": self.job, "do": do, "code": code, "text": code, "detail": detail or {}})

    # ---- геометрия
    def _cells(self, name, key):
        """Клетки, которые занимает постройка с центром key."""
        if self.SIZE.get(name, 1) == 2:
            x, y = int(round(key[0])), int(round(key[1]))
            return {(x - 1, y - 1), (x, y - 1), (x - 1, y), (x, y)}
        return {(math.floor(key[0]), math.floor(key[1]))}

    def _occupied(self):
        out = {}
        for key, name in self.entities.items():
            for c in self._cells(name, key):
                out[c] = ("own", key, name)
        for key, name in self.naturals.items():
            out[(math.floor(key[0]), math.floor(key[1]))] = ("natural", key, name)
        return out

    def _layout(self, bp, anchor, direction):
        """Места сущностей и плиток чертежа: центр рамки в anchor, поворот, привязка первой к сетке."""
        ents, tiles = bp.get("entities") or [], bp.get("tiles") or []
        boxes = []
        for e in ents:
            h = self.SIZE.get(e["name"], 1) / 2
            boxes.append((e["position"]["x"] - h, e["position"]["y"] - h, e["position"]["x"] + h, e["position"]["y"] + h))
        for t in tiles:
            boxes.append((t["position"]["x"], t["position"]["y"], t["position"]["x"] + 1, t["position"]["y"] + 1))
        cx = (min(b[0] for b in boxes) + max(b[2] for b in boxes)) / 2
        cy = (min(b[1] for b in boxes) + max(b[3] for b in boxes)) / 2

        def rot(dx, dy):
            return {0: (dx, dy), 4: (-dy, dx), 8: (-dx, -dy), 12: (dy, -dx)}[direction]

        def snap(v, size):
            return math.floor(v) + 0.5 if size % 2 else math.floor(v + 0.5)

        shift, out, tout = None, [], []
        for e in ents:
            dx, dy = rot(e["position"]["x"] - cx, e["position"]["y"] - cy)
            wx, wy = anchor["x"] + dx, anchor["y"] + dy
            if shift is None:
                size = self.SIZE.get(e["name"], 1)
                shift = (snap(wx, size) - wx, snap(wy, size) - wy)
            x = wx + shift[0] + (self.rot_shift if direction == 4 else 0)
            out.append(((x, wy + shift[1]), e["name"]))
        for t in tiles:
            dx, dy = rot(t["position"]["x"] + 0.5 - cx, t["position"]["y"] + 0.5 - cy)
            wx, wy = anchor["x"] + dx, anchor["y"] + dy
            if shift is None:
                shift = (snap(wx, 1) - wx, snap(wy, 1) - wy)
            tout.append(((math.floor(wx + shift[0]), math.floor(wy + shift[1])), t["name"]))
        return out, tout

    # ---- действия
    def _take(self, name, n):
        self.inv[name] = self.inv.get(name, 0) - n
        if self.inv[name] <= 0:
            del self.inv[name]

    def _give(self, name, n=1):
        self.inv[name] = self.inv.get(name, 0) + n

    def _plan(self, a, anchor=None, direction=None):
        """Что «движок» поставит по чертежу в режиме force:
        (ghosts, skipped, tiles, tiles_skipped, to_mark, wet) — wet: клетки без возможной подложки."""
        bp = load("build_ghosts").decode_blueprint(self.blobs[a["blob"]])["blueprint"]
        mode = a.get("force", "forced")
        ents, tiles = self._layout(bp, anchor or a["anchor"], a.get("direction", 0) if direction is None else direction)
        occupied = self._occupied()
        tile_ghosts, tiles_skipped, wet = {}, 0, set()
        if not self.ignore_tiles:
            for cell, name in tiles:
                if self.tiles.get(cell) == name:
                    continue
                if cell in self.lava:
                    tiles_skipped += 1
                    wet.add(cell)
                else:
                    tile_ghosts[cell] = name
        ghosts, skipped, to_mark = [], [], {}
        for key, name in ents:
            cells = self._cells(name, key)
            reason, marks = None, {}
            if key in self.blocked:
                reason = "cannot_place"
            for c in cells:
                hit = occupied.get(c)
                if hit:
                    kind, okey, oname = hit
                    if mode == "normal":
                        reason = "cannot_place"
                    elif kind == "own" and okey == key and oname == name:
                        reason = "exists"
                    elif kind == "own" and mode != "superforced" and not self.forced_marks_own:
                        reason = "cannot_place"
                    else:
                        marks[okey] = oname
                if c in self.lava and c not in tile_ghosts:
                    if mode == "normal" or self.lava_cover is None:
                        reason = "liquid"
                        wet.add(c)
                    else:
                        tile_ghosts[c] = self.lava_cover
            if reason:
                skipped.append({"name": name, "reason": reason,
                                "pos": {"x": key[0] + self.layout_shift, "y": key[1] + self.layout_shift}})
            else:
                ghosts.append((key, name))
                to_mark.update(marks)
        return ghosts, skipped, tile_ghosts, tiles_skipped, to_mark, wet

    def _summary(self, ghosts, skipped, tile_ghosts, tiles_skipped, to_mark, wet=()):
        tiles = {}
        for name in tile_ghosts.values():
            tiles[name] = tiles.get(name, 0) + 1
        need = {}
        for _, name in ghosts:
            need[name] = need.get(name, 0) + 1
        for name, n in tiles.items():
            item = self.TILE_ITEM[name]
            need[item] = need.get(item, 0) + n
        missing = {k: n - self.inv.get(k, 0) for k, n in need.items() if n > self.inv.get(k, 0)}
        s = {"ghosts": len(ghosts), "skipped": skipped, "skipped_total": len(skipped), "tiles": len(tile_ghosts),
             "tiles_skipped": tiles_skipped, "missing": missing, "to_remove_total": len(to_mark),
             "on_liquid": len(wet),
             "to_remove": [{"name": n, "pos": {"x": k[0], "y": k[1]}} for k, n in to_mark.items()]}
        if wet:
            s["liquids"] = {"lava": len(wet)}
        return s

    def _fit(self, a):
        """Ближайший сдвиг, при котором чертёж встаёт целиком: кольца вокруг anchor в пределах search;
        с rotate — ещё повороты (зеркала в модели нет: mirror всегда false). → fit | None."""
        search = a.get("search", 16)
        base = a.get("direction", 0)
        dirs = [base] + ([(base + 4 * k) % 16 for k in (1, 2, 3)] if a.get("rotate") else [])
        if self.no_fit:
            return None
        for r in range(0, search + 1):
            ring = [(dx, dy) for dx in range(-r, r + 1) for dy in range(-r, r + 1) if max(abs(dx), abs(dy)) == r]
            ring.sort(key=lambda c: (c[0] ** 2 + c[1] ** 2, c[1], c[0]))
            for dx, dy in ring:
                for d in dirs:
                    if r == 0 and d == base:
                        continue
                    anchor = {"x": a["anchor"]["x"] + dx, "y": a["anchor"]["y"] + dy}
                    _, skipped, _, tiles_skipped, _, wet = self._plan(a, anchor, d)
                    if not skipped and not tiles_skipped and not wet:
                        fit = {"anchor": anchor, "shift": {"dx": dx, "dy": dy}}
                        if a.get("rotate"):
                            fit.update(direction=d, mirror=False)
                        return fit
        return None

    def _unmark(self, own):
        if not self.keep_marks:
            self.marked -= set(own)

    def _build(self, area, mode):
        """Стройка призраков области: снос помеченного → плитки → постройки. → (code | None, detail)."""
        def inside(x, y):
            return (area is None or (area["left_top"]["x"] <= x <= area["right_bottom"]["x"]
                                     and area["left_top"]["y"] <= y <= area["right_bottom"]["y"]))

        ghosts = {k: n for k, n in self.ghosts.items() if inside(*k)}
        tile_ghosts = {c: n for c, n in self.tile_ghosts.items() if inside(c[0] + 0.5, c[1] + 0.5)}
        total = len(ghosts) + len(tile_ghosts)
        detail = {"built": 0, "tiles_built": 0, "left": total, "removed": 0, "not_removed": 0,
                  "blocked": [], "blocked_total": 0, "missing": {}}
        if mode == "robots" and not self.robots:
            return "no_items", detail
        if self.keep_ghosts:
            return "no_items", detail
        removed, missing, blocked, built, tiles_built = 0, {}, [], 0, 0
        # снос помеченного, которое мешает призракам
        for key, name in ghosts.items():
            for c in self._cells(name, key):
                hit = self._occupied().get(c)
                if hit and hit[1] in self.marked and not self.dig_fails:
                    _, okey, oname = hit
                    self.marked.discard(okey)
                    if hit[0] == "own":
                        del self.entities[okey]
                        self._give(oname)
                    else:
                        del self.naturals[okey]
                        for item, n in self.YIELD.get(oname, {}).items():
                            self._give(item, n)
                    removed += 1
        # плитки
        for c, name in sorted(tile_ghosts.items()):
            item = self.TILE_ITEM[name]
            if self.inv.get(item, 0) >= 1:
                self._take(item, 1)
                del self.tile_ghosts[c]
                self.tiles[c] = name
                self.lava.discard(c)
                built += 1
                tiles_built += 1
            else:
                missing[item] = missing.get(item, 0) + 1
        # постройки
        for key, name in sorted(ghosts.items()):
            cells = self._cells(name, key)
            occupied = self._occupied()
            if any(c in occupied for c in cells):
                blocked.append({"name": name, "pos": {"x": key[0], "y": key[1]}, "reason": "obstacle"})
                continue
            if any(c in self.lava or c in self.tile_ghosts for c in cells):
                continue    # ждёт плитку
            if self.inv.get(name, 0) >= 1:
                self._take(name, 1)
                del self.ghosts[key]
                self.entities[key] = name
                self.unit += 1
                self.units[key] = self.unit
                built += 1
            else:
                missing[name] = missing.get(name, 0) + 1
        detail = {"built": built, "tiles_built": tiles_built, "left": total - built - len(blocked),
                  "removed": removed, "not_removed": 0, "blocked": blocked,
                  "blocked_total": len(blocked), "missing": missing}
        if tiles_built:
            detail["tiles_first"] = not self.tiles_last
        return (None if detail["left"] == 0 else "no_items"), detail

    def _act(self, do, a):
        self.job += 1
        self.acts.append((do, a))
        if do == "collect" and self.collect_blind:
            return self._failed(do, "no_items", {"collected": {}, "missing": dict(a["items"]), "from": {}})
        if do == "extract":
            t = a["target"]
            if t.get("unit_number") != 55 or t.get("pos") != {"x": 20.5, "y": 0.5}:
                return self._failed(do, "not_found")   # цель — только {unit_number, pos}
            got = {}
            for name, n in a["items"].items():
                k = min(n, self.stock.get(name, 0))
                if k:
                    got[name] = k
                    self.stock[name] -= k
                    self._give(name, k)
                    if a.get("equip") and name == self.armor:
                        self._take(name, k)
            return self._done(do, {"extracted": got})
        if do == "collect":
            got = {}
            for name, n in a["items"].items():
                k = min(n, self.stock.get(name, 0))
                if k:
                    got[name] = k
                    self.stock[name] -= k
                    self._give(name, k)
            return self._done(do, {"collected": got, "missing": {}, "from": [1]})
        if do == "craft":
            raw, per = self.RECIPES[a["recipe"]]
            self._take(raw, per * a["count"])
            self._give(a["recipe"], a["count"])
            return self._done(do, {"crafted": {a["recipe"]: a["count"]}})
        if do == "place":
            key = (a["pos"]["x"], a["pos"]["y"])
            if self.break_place:
                return self._failed(do, self.break_place)
            occupied = self._occupied()
            if key in self.blocked or any(c in occupied or c in self.lava for c in self._cells(a["item"], key)):
                return self._failed(do, "cannot_place")
            if self.inv.get(a["item"], 0) < 1:
                return self._failed(do, "no_items")
            if not self.lose_item:
                self._take(a["item"], 1)
            self.entities[key] = a["item"]
            self.unit += 1
            self.units[key] = self.unit
            return self._done(do, {"unit_number": self.unit, "name": a["item"], "pos": a["pos"]})
        if do == "deconstruct" and "area" in a:
            ar, names = a["area"], a.get("filter")
            hit = [k for k, n in self.entities.items()
                   if ar["left_top"]["x"] <= k[0] <= ar["right_bottom"]["x"]
                   and ar["left_top"]["y"] <= k[1] <= ar["right_bottom"]["y"] and (names is None or n in names)]
            got = {}
            for k in hit:
                n = self.entities.pop(k)
                got[n] = got.get(n, 0) + 1
                self._give(n)
            return self._done(do, {"removed": len(hit), "got": got})
        if do == "deconstruct":
            t = a["target"]
            key = (t["pos"]["x"], t["pos"]["y"])
            if self.decon_fails or key not in self.entities or self.units.get(key) != t.get("unit_number"):
                return self._failed(do, "not_found")
            name = self.entities.pop(key)
            self._give(name)
            return self._done(do, {"removed": 1, "got": {name: 1}})
        if do == "build_blueprint":
            if a["blob"] not in self.blobs:
                return self._failed(do, "bad_args")
            ghosts, skipped, tile_ghosts, tiles_skipped, to_mark, wet = self._plan(a)
            s = self._summary(ghosts, skipped, tile_ghosts, tiles_skipped, to_mark, wet)
            partial = a.get("partial") and not self.ignore_partial
            if wet and not partial and not self.place_on_liquid:
                # клетки без возможной подложки: чертёж не ставится вовсе, в detail — сдвиг (ACTIONS.md)
                fit = self._fit(a)
                if fit:
                    s["fit"] = fit
                return self._done(do, s) if a.get("dry_run") else self._failed(do, "cannot_place", s)
            if a.get("dry_run"):
                return self._done(do, s)
            if not ghosts and not tile_ghosts:
                return self._failed(do, "cannot_place", s)
            self.ghosts.update(dict(ghosts))
            self.tile_ghosts.update(tile_ghosts)
            own = set(to_mark) - self.marked
            self.marked.update(to_mark)
            xs = [k[0] for k, _ in ghosts] + [c[0] + 0.5 for c in tile_ghosts]
            ys = [k[1] for k, _ in ghosts] + [c[1] + 0.5 for c in tile_ghosts]
            area = {"left_top": {"x": min(xs) - 1.5, "y": min(ys) - 1.5}, "right_bottom": {"x": max(xs) + 1.5, "y": max(ys) + 1.5}}
            far = math.hypot(a["anchor"]["x"] - self.pos["x"], a["anchor"]["y"] - self.pos["y"])
            if self.pause_far is not None and a.get("mode", "auto") == "hand" and far > self.pause_far:
                self.pending = (self.job, do, own)   # помощник ещё идёт: итога нет, пока задачу не отменят
                return None
            code, detail = self._build(area, a.get("mode", "auto"))
            detail.update({k: s[k] for k in s if k != "missing"})
            if code:
                self._unmark(own)
            return self._failed(do, code, detail) if code else self._done(do, detail)
        if do == "build_ghosts":
            code, detail = self._build(a.get("area"), a.get("mode", "auto"))
            return self._failed(do, code, detail) if code else self._done(do, detail)
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
            boxes = [{"unit": 55, "name": "steel-chest", "pos": {"x": 20.5, "y": 0.5}, "dist": 12.0, "items": total}] if total else []
            return ok({"containers": boxes, "total": total, "hidden": 0, "truncated": False})
        if op == "state":
            worn = self.armor is not None and self.stock.get(self.armor, 1) == 0
            return ok({"helper": env["helper"], "pos": self.pos, "inv": dict(self.inv),
                       "robots": {"construction": self.robots if worn else 0, "available": self.robots if worn else 0}})
        if op == "map":
            c, r = args["center"], args.get("radius", 16)
            names, types = args.get("names"), args.get("types")
            ents = []

            def want(n):
                if names is None and types is None:
                    return n not in self.naturals.values()
                return (names is not None and n in names) or (types is not None and self.TYPES.get(n) in types)

            for src, ch in ((self.entities, "C"), (self.naturals, None)):
                for k, n in src.items():
                    if want(n) and abs(k[0] - c["x"]) <= r and abs(k[1] - c["y"]) <= r:
                        e = {"c": ch or ("T" if self.TYPES.get(n) == "tree" else "#"), "name": n,
                             "pos": {"x": k[0], "y": k[1]}, "dir": 0}
                        if k in self.units:
                            e["unit"] = self.units[k]
                        ents.append(e)
            x0, y0 = math.floor(c["x"]) - r, math.floor(c["y"]) - r
            rows = ["".join("~" if (x0 + i, y0 + j) in self.lava else "." for i in range(2 * r + 1))
                    for j in range(2 * r + 1)]
            return ok({"entities": ents, "rows": rows, "truncated": False,
                       "bbox": {"x0": x0, "y0": y0, "x1": x0 + 2 * r, "y1": y0 + 2 * r}})
        if op == "ghosts":
            a = args["area"]
            keys = [k for k in self.ghosts
                    if a["left_top"]["x"] <= k[0] <= a["right_bottom"]["x"] and a["left_top"]["y"] <= k[1] <= a["right_bottom"]["y"]]
            occupied = self._occupied()
            blocked = sum(1 for k in keys if any(c in occupied for c in self._cells(self.ghosts[k], k)))
            return ok({"count": len(keys), "blocked_total": blocked})
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
            if self.pending and self.pending[0] == args.get("job"):
                job, do, own = self.pending
                self.pending = None
                self._unmark(own)
                self._emit("job_failed", {"job": job, "do": do, "code": "cancelled", "text": "cancelled", "detail": {}})
                return ok({"cancelled": [job]})
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


def test_place_extracts_when_collect_is_blind(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model(stock={"steel-plate": 100}, collect_blind=True)
    res = run("build_place", m, fake_rcon)
    assert res["ok"] is True, res
    assert [d for d, _ in m.acts] == ["collect", "extract", "craft", "place"]
    # цель — {unit_number, pos} (ACTIONS «target»): без pos движок 2.0 находит не все сущности
    assert m.acts[1][1] == {"target": {"unit_number": 55, "pos": {"x": 20.5, "y": 0.5}}, "items": {"steel-plate": 8}}
    assert res["item"] == "steel-chest"
    assert m.stock["steel-plate"] == 92


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
    assert m.acts[2][1] == {"target": {"unit_number": 101, "pos": {"x": 13.5, "y": -4.5}}}
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
    assert dos == [("collect", False), ("build_blueprint", True), ("build_blueprint", False),
                   ("deconstruct", False), ("build_blueprint", False)]
    assert m.acts[0][1]["items"] == {"wooden-chest": 2}
    assert m.acts[2][1]["mode"] == "hand"
    assert res["anchor"] == {"x": 14, "y": -4.5}
    assert res["cells"]["built"] == [[13.5, -4.5], [14.5, -4.5]] or res["cells"]["built"] == [(13.5, -4.5), (14.5, -4.5)]
    assert m.acts[3][1]["filter"] == ["wooden-chest"]
    assert m.acts[4][1]["direction"] == 4
    assert sorted(m.entities) == [(14.5, -4.5), (14.5, -3.5)]
    assert res["inventory"] == {"before": 2, "after": 0}
    assert res["ghosts_left"] == 0 and res["on_map"] == 2


def test_ghosts_rotation_mismatch_is_failure(fake_rcon, monkeypatch):
    _no_wait(monkeypatch)
    m = Model()
    m.rot_shift = -1   # «движок» поставил столбик на клетку левее расчёта
    res = run("build_ghosts", m, fake_rcon)
    assert res["ok"] is False
    assert any("поворот 4" in r for r in res["reasons"]), res


def test_expected_cells():
    g = load("build_ghosts")
    a = {"x": 18, "y": 58.5}
    assert g.expected_cells(a, 2, 0) == [(17.5, 58.5), (18.5, 58.5)]
    assert g.expected_cells(a, 2, 4) == [(18.5, 58.5), (18.5, 59.5)]
    assert g.expected_cells(a, 2, 8) == [(17.5, 58.5), (18.5, 58.5)]


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
