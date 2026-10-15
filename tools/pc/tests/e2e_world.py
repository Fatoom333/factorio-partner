"""Модель мода для офлайн-тестов сквозных сценариев e2e_*.

Маленький «мир»: помощник с инвентарём, склады базы, руда, постройки и призраки, очередь событий.
Действия исполняются сразу (итог — событие `job_done` / `job_failed`), но по тем же правилам, что у
мода: предметы берутся только со складов в радиусе, крафт тратит ингредиенты, стройка списывает
предметы, призрак без предмета остаётся стоять. Отвечает конвертом протокола v1 — годится и для
`live_client.LiveClient`, и для настоящего `Core` сервера (оба ходят в `conftest.FakeRcon`).
"""
from __future__ import annotations

import base64
import json
import math
import zlib

SIZE = {"electric-mining-drill": 3, "burner-mining-drill": 2, "big-mining-drill": 5}
RECIPES = {
    "electric-mining-drill": ({"electronic-circuit": 3, "iron-gear-wheel": 5, "iron-plate": 10}, 1),
    "transport-belt": ({"iron-plate": 1, "iron-gear-wheel": 1}, 2),
    "medium-electric-pole": ({"iron-stick": 4, "steel-plate": 2, "copper-cable": 2}, 1),
    "small-electric-pole": ({"wood": 1, "copper-cable": 2}, 2),
    "iron-gear-wheel": ({"iron-plate": 2}, 1),
}
KNOWN_ORES = ("iron-ore", "copper-ore", "coal", "stone", "tungsten-ore")
VEC = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}
DIR_OF = {v: k for k, v in VEC.items()}
SIDE_NUM = {"north": 0, "east": 4, "south": 8, "west": 12}
LIQUID_TILE = "lava"            # имя плитки в модели; сценарии его не знают — читают из ответов
ACCESS_FRAME = 8                # STATE.md «access»: рамка = участок + 8 клеток
BELT_SEARCH_MARGIN = 48         # рамка поиска пути ленты вокруг начала и конца


class ModError(Exception):
    def __init__(self, code, text=""):
        super().__init__(code)
        self.code, self.text = code, text


def default_stores():
    """Как в живом сейве: рядом — схемы, далеко — пластины, шестерни, ленты и столбы; буров нет нигде."""
    return [
        {"unit": 101, "name": "steel-chest", "pos": {"x": 40.5, "y": 10.5}, "items": {"electronic-circuit": 200}},
        {"unit": 102, "name": "steel-chest", "pos": {"x": -150.5, "y": 0.5},
         "items": {"iron-plate": 5000, "iron-gear-wheel": 3000, "fast-transport-belt": 400,
                   "medium-electric-pole": 100, "steel-plate": 500}},
    ]


class World:
    def __init__(self, stores=None, ore=None, recipes=None, helper_pos=None, blocked=None, hidden=None,
                 mod="0.1.0", unreachable=False, hard_ores=("tungsten-ore",), far_invisible=False,
                 liquid=None, body="character", underground="underground-belt", belt_lanes=None):
        self.mod = mod
        self.tick = 1000
        self.seq = 0
        self.events = []
        self.recent = {}
        self.job = 0
        self.helpers = {}                 # id -> {"pos", "inv", "state"}
        self.spawn_pos = dict(helper_pos or {"x": 10.5, "y": 10.5})
        self.stores = default_stores() if stores is None else stores
        self.ore = {} if ore is None else ore       # имя руды -> множество клеток (x, y)
        self.recipes = RECIPES if recipes is None else recipes
        self.entities = {}                # (x, y) центра -> {"name", "dir", "ghost"}
        self.blocked = set(blocked or ())  # клетки с чужими постройками (на карте «O»)
        self.hidden = set(hidden or ())    # помехи, которых на карте не видно (стройке мешают)
        self.hard_ores = set(hard_ores)    # руда, которую электрический бур не берёт
        self.blobs = {}
        self.reflexes = []
        self.acts = []
        self.ops = []
        self.unreachable = unreachable
        self.far_invisible = far_invisible   # склады дальше 32 клеток от тела не видны (нет радаров)
        self.module_errors = 0
        self.liquid = set(liquid or ())    # клетки жидкости: не пройти, не построить, под землёй не пройти
        self.body = body
        self.underground = underground     # исследованный подземный конвейер (None — не исследован)
        self.belt_lanes = belt_lanes       # что отвечать в `lanes` на пачку (None — сколько просили)

    # ------------------------------------------------------------ RCON
    def handler(self, cmd):
        if cmd == "/quit":
            return None
        assert cmd.startswith("/partner {"), cmd
        env = json.loads(cmd[len("/partner "):])
        rid = env.get("id")
        if rid in self.recent:
            return self.recent[rid]
        self.tick += 7
        op = env.get("op")
        self.ops.append(op)
        try:
            fn = getattr(self, "op_" + str(op), None)
            if fn is None:
                raise ModError("unknown_op", str(op))
            data = fn(env.get("args") or {}, env.get("helper"))
            resp = {"v": 1, "id": rid, "ok": True, "tick": self.tick, "seq": self.seq, "data": data}
        except ModError as e:
            resp = {"v": 1, "id": rid, "ok": False, "tick": self.tick, "seq": self.seq,
                    "error": {"code": e.code, "text": e.text}}
        text = json.dumps(resp, ensure_ascii=False)
        self.recent[rid] = text
        return text

    def _emit(self, helper, kind, data, loud=True):
        self.seq += 1
        self.events.append({"seq": self.seq, "tick": self.tick, "helper": helper, "kind": kind, "data": data,
                            "loud": loud})

    def _helper(self, helper):
        h = self.helpers.get(helper)
        if h is None or h["state"] != "alive":
            raise ModError("no_helper", "no such helper")
        return h

    # ------------------------------------------------------------ ядро
    def op_hello(self, args, helper):
        return {"proto": 1, "mod": self.mod, "tick": self.tick, "seq": self.seq, "owner": "owner",
                "players_online": 0, "players": [], "helpers": sorted(self.helpers),
                "module_errors": self.module_errors}

    def op_helper_spawn(self, args, helper):
        if helper in self.helpers and self.helpers[helper]["state"] == "alive":
            raise ModError("helper_exists", helper)
        self.helpers[helper] = {"pos": dict(self.spawn_pos), "inv": {}, "state": "alive"}
        return {"helper": helper, "unit_number": 7, "surface": "nauvis", "pos": dict(self.spawn_pos)}

    def op_helper_remove(self, args, helper):
        h = self.helpers.get(helper)
        if h is None:
            raise ModError("no_helper", helper)
        h["state"] = "removed"
        return {"corpse": dict(h["pos"])}

    def op_helper_list(self, args, helper):
        return {"helpers": [{"id": k, "state": v["state"], "pos": v["pos"]} for k, v in sorted(self.helpers.items())
                            if v["state"] != "removed"]}

    def op_jobs(self, args, helper):
        self._helper(helper)
        return {"queue": {}}

    def op_events(self, args, helper):
        since, who, limit = args.get("since", 0), args.get("helper"), args.get("limit", 100)
        evs = [e for e in self.events if e["seq"] > since and (who is None or e["helper"] in (who, None))]
        return {"seq": self.seq, "events": evs[:limit], "lost": False}

    def op_cancel(self, args, helper):
        self._helper(helper)
        return {"cancelled": {}}

    def op_reflexes(self, args, helper):
        self._helper(helper)
        out = []
        for r in args.get("set", []):
            if r.get("type") not in ("watch", "flee"):
                raise ModError("bad_args", "set: unknown reflex type")
            out.append(dict(r))
        self.reflexes = out
        return {"set": out if out else {}}

    def op_blob_put(self, args, helper):
        parts = self.blobs.setdefault(args["blob"], {})
        parts[args["part"]] = args["data"]
        parts["total"] = args["total"]
        return {"blob": args["blob"], "received": len(parts) - 1, "total": args["total"]}

    # ------------------------------------------------------------ чтение
    def op_state(self, args, helper):
        h = self._helper(helper)
        return {"helper": helper, "surface": "nauvis", "pos": dict(h["pos"]), "health": 250, "max_health": 250,
                "reach": {"build": 10, "reach": 10, "resource": 2.7, "pickup": 1},
                "inv": dict(h["inv"]) if h["inv"] else {}, "inv_free": 80,
                "robots": {"construction": 0, "available": 0}, "queue": 0, "body": self.body,
                "module_errors": self.module_errors, "tick": self.tick, "seq": self.seq}

    def _center(self, args, helper):
        if "center" in args:
            return args["center"]
        return self._helper(helper)["pos"]

    def _near(self, pos, center, radius):
        return math.hypot(pos["x"] - center["x"], pos["y"] - center["y"]) <= radius

    def op_stock(self, args, helper):
        center, radius = self._center(args, helper), args.get("radius", 64)
        if radius > 128:
            raise ModError("limit", "radius")
        items = args.get("items")
        total, boxes = {}, []
        for s in self.stores:
            if not self._near(s["pos"], center, radius):
                continue
            have = {k: n for k, n in s["items"].items() if n > 0 and (items is None or k in items)}
            if have:
                boxes.append({"unit": s["unit"], "name": s["name"], "pos": s["pos"], "items": have})
                for k, n in have.items():
                    total[k] = total.get(k, 0) + n
        return {"containers": boxes or {}, "total": total or {}, "hidden": 0, "truncated": False}

    def op_find(self, args, helper):
        item = args.get("item")
        center = self._helper(helper)["pos"]
        groups = []
        if "storage" in args.get("kinds", ["producers", "consumers", "storage"]):
            for s in self.stores:
                if s["items"].get(item, 0) > 0:
                    groups.append({"kind": "storage", "pos": dict(s["pos"]), "count": 1, "names": {s["name"]: 1},
                                   "amount": s["items"][item],
                                   "dist": round(math.hypot(s["pos"]["x"] - center["x"], s["pos"]["y"] - center["y"]), 1)})
        groups.sort(key=lambda g: g["dist"])
        return {"item": item, "surface": "nauvis", "groups": groups[:args.get("limit", 20)] or {},
                "total": {"producers": 0, "consumers": 0, "storage": len(groups), "entities": 0}, "hidden": 0}

    def _craftable(self, inv, item):
        recipe = self.recipes.get(item)
        if recipe is None:
            return 0
        inv = dict(inv)
        n = 0
        while n < 1000:
            for k, c in recipe[0].items():
                lacking = c - inv.get(k, 0)
                sub = self.recipes.get(k)
                if lacking > 0 and sub is not None:      # промежуточное движок крафтит сам
                    runs = int(math.ceil(lacking / sub[1]))
                    if all(inv.get(i, 0) >= q * runs for i, q in sub[0].items()):
                        for i, q in sub[0].items():
                            inv[i] -= q * runs
                        inv[k] = inv.get(k, 0) + runs * sub[1]
            if any(inv.get(k, 0) < c for k, c in recipe[0].items()):
                break
            for k, c in recipe[0].items():
                inv[k] -= c
            n += 1
        return n

    def op_recipes(self, args, helper):
        h = self._helper(helper)
        flt = args.get("filter", "")
        out = {}
        for item in self.recipes:
            if flt in item:
                n = self._craftable(h["inv"], item)
                if n:
                    out[item] = n
        return {"craftable": out or {}}

    def op_resources(self, args, helper):
        name = args.get("name")
        if name is not None and name not in KNOWN_ORES:
            raise ModError("bad_args", "args.name: unknown resource")
        center, radius = self._center(args, helper), args.get("radius", 64)
        patches = []
        for ore, cells in self.ore.items():
            if (name is not None and ore != name) or not cells:
                continue
            xs, ys = [c[0] for c in cells], [c[1] for c in cells]
            c = {"x": (min(xs) + max(xs) + 1) / 2, "y": (min(ys) + max(ys) + 1) / 2}
            if not self._near(c, center, radius + 40):
                continue
            patches.append({"name": ore, "center": c, "tiles": len(cells), "amount": 1000 * len(cells),
                            "area": {"left_top": {"x": min(xs), "y": min(ys)},
                                     "right_bottom": {"x": max(xs) + 1, "y": max(ys) + 1}},
                            "dist": round(math.hypot(c["x"] - center["x"], c["y"] - center["y"]), 1)})
        return {"patches": patches or {}, "truncated": False}

    def _cells(self, pos, name):
        s = SIZE.get(name, 1)
        x0, y0 = int(math.floor(pos[0] - s / 2 + 0.01)), int(math.floor(pos[1] - s / 2 + 0.01))
        return [(x, y) for x in range(x0, x0 + s) for y in range(y0, y0 + s)]

    def _occupied(self):
        taken = set(self.blocked) | self.hidden | self.liquid
        for pos, e in self.entities.items():
            taken.update(self._cells(pos, e["name"]))
        return taken

    def op_map(self, args, helper):
        center, radius = self._center(args, helper), int(args.get("radius", 16))
        if radius > 32:
            raise ModError("limit", "radius")
        x0, y0 = int(math.floor(center["x"])) - radius, int(math.floor(center["y"])) - radius
        side = 2 * radius + 1
        grid = [["."] * side for _ in range(side)]
        legend = {".": "земля", "@": "помощник"}

        def put(x, y, ch):
            if 0 <= x - x0 < side and 0 <= y - y0 < side:
                grid[y - y0][x - x0] = ch

        letters = {}
        for ore in sorted(self.ore):
            ch = next(c for c in ore if c.isalpha() and c not in letters.values() and c not in "gO")
            letters[ore] = ch
            for (x, y) in self.ore[ore]:
                put(x, y, ch)
                if 0 <= x - x0 < side and 0 <= y - y0 < side:
                    legend[ch] = "руда: " + ore
        for (x, y) in self.blocked:
            put(x, y, "O")
        wet = 0
        for (x, y) in self.liquid:
            if 0 <= x - x0 < side and 0 <= y - y0 < side:
                put(x, y, "~")
                wet += 1
        if wet:
            legend["~"] = "не пройти: " + LIQUID_TILE
        ents = []
        names = args.get("names")
        for pos, e in sorted(self.entities.items()):
            ch = "g" if e["ghost"] else ("D" if e["name"] in SIZE else "B" if "belt" in e["name"] else "E")
            for (x, y) in self._cells(pos, e["name"]):
                put(x, y, ch)
            if abs(pos[0] - center["x"]) <= radius + 0.5 and abs(pos[1] - center["y"]) <= radius + 0.5:
                if e["ghost"] or names is None or e["name"] in names:
                    item = {"c": ch, "name": e["name"], "pos": {"x": pos[0], "y": pos[1]}, "dir": e["dir"]}
                    if e["ghost"]:
                        item["ghost"] = True
                    ents.append(item)
        if helper in self.helpers:
            h = self.helpers[helper]["pos"]
            put(int(math.floor(h["x"])), int(math.floor(h["y"])), "@")
        return {"surface": "nauvis", "bbox": {"x0": x0, "y0": y0, "x1": x0 + side - 1, "y1": y0 + side - 1},
                "rows": ["".join(r) for r in grid], "legend": legend, "entities": ents[:100] or {},
                "liquids": {LIQUID_TILE: {"n": wet, "cover_ok": False}} if wet else {},
                "truncated": len(ents) > 100}

    def op_access(self, args, helper):
        """Суша, жидкость и выходы с участка (STATE.md «access»), упрощённо: преграда — жидкость и
        чужие постройки; выход — самый длинный отрезок суши на стороне рамки, связанный с сушей участка."""
        area = args.get("area")
        if area is None:
            c, r = self._center(args, helper), int(args.get("radius", 32))
            if r > 64:
                raise ModError("limit", "radius")
            cx, cy = int(math.floor(c["x"])), int(math.floor(c["y"]))
            area = {"left_top": {"x": cx - r, "y": cy - r}, "right_bottom": {"x": cx + r, "y": cy + r}}
        elif any(k in args for k in ("center", "near", "radius")):
            raise ModError("bad_args", "area: use either area or center/near with radius")
        ax0, ay0 = int(area["left_top"]["x"]), int(area["left_top"]["y"])
        ax1, ay1 = int(area["right_bottom"]["x"]) - 1, int(area["right_bottom"]["y"]) - 1
        if ax1 - ax0 + 1 > 128 or ay1 - ay0 + 1 > 128:
            raise ModError("limit", "area")
        fx0, fy0, fx1, fy1 = ax0 - ACCESS_FRAME, ay0 - ACCESS_FRAME, ax1 + ACCESS_FRAME, ay1 + ACCESS_FRAME
        wall = self.liquid | self.blocked
        inside = [(x, y) for x in range(ax0, ax1 + 1) for y in range(ay0, ay1 + 1)]
        liquid = sum(1 for c in inside if c in self.liquid)
        land = [c for c in inside if c not in wall]
        seen = set(land)
        todo = list(land)
        while todo:
            x, y = todo.pop()
            for dx, dy in VEC.values():
                n = (x + dx, y + dy)
                if n not in seen and n not in wall and fx0 <= n[0] <= fx1 and fy0 <= n[1] <= fy1:
                    seen.add(n)
                    todo.append(n)
        sides = {"north": [(x, fy0) for x in range(fx0, fx1 + 1)], "south": [(x, fy1) for x in range(fx0, fx1 + 1)],
                 "west": [(fx0, y) for y in range(fy0, fy1 + 1)], "east": [(fx1, y) for y in range(fy0, fy1 + 1)]}
        exits = []
        for name, cells in sides.items():
            best, run = [], []
            for c in cells + [None]:
                if c is not None and c in seen:
                    run.append(c)
                    continue
                if len(run) > len(best):
                    best = run
                run = []
            if best:
                mid = best[len(best) // 2]
                width = len(best)
                neck = "wide" if width >= 5 else "medium" if width >= 3 else "narrow"
                exits.append({"side": name, "pos": {"x": mid[0], "y": mid[1]}, "width": width, "neck": neck})
        rank = {"wide": 3, "medium": 2, "narrow": 1}
        exits.sort(key=lambda e: (-rank[e["neck"]], -e["width"]))
        out = {"area": {"left_top": {"x": ax0, "y": ay0}, "right_bottom": {"x": ax1 + 1, "y": ay1 + 1}},
               "surface": "nauvis", "land": len(land), "liquid": liquid,
               "liquids": {LIQUID_TILE: liquid} if liquid else {}, "enclosed": not exits,
               "exits": exits[:8] or {}}
        warnings = []
        if exits:
            out["best"] = exits[0]["side"]
            if exits[0]["neck"] == "narrow":
                warnings.append("narrow_access")
        else:
            warnings.append("enclosed")
        if helper in self.helpers:
            h = self.helpers[helper]["pos"]
            cell = (int(math.floor(h["x"])), int(math.floor(h["y"])))
            if fx0 <= cell[0] <= fx1 and fy0 <= cell[1] <= fy1:
                out["reachable"] = cell in seen
        out["warnings"] = warnings or {}
        return out

    def _ghosts_in(self, area):
        lt, rb = area["left_top"], area["right_bottom"]
        return [(pos, e) for pos, e in sorted(self.entities.items())
                if e["ghost"] and lt["x"] <= pos[0] <= rb["x"] and lt["y"] <= pos[1] <= rb["y"]]

    def op_ghosts(self, args, helper):
        area = args.get("area")
        if area is None:
            c, r = self._center(args, helper), args.get("radius", 64)
            area = {"left_top": {"x": c["x"] - r, "y": c["y"] - r}, "right_bottom": {"x": c["x"] + r, "y": c["y"] + r}}
        need = {}
        found = self._ghosts_in(area)
        for _, e in found:
            need[e["name"]] = need.get(e["name"], 0) + 1
        return {"count": len(found), "by_name": dict(need) or {}, "need": need or {}, "missing": {}, "blocked": {},
                "blocked_total": 0, "area": area}

    # ------------------------------------------------------------ действия
    def op_act(self, args, helper):
        h = self._helper(helper)
        do, a = args.get("do"), args.get("args") or {}
        fn = getattr(self, "do_" + str(do), None)
        if fn is None:
            raise ModError("bad_args", "do: unknown action")
        self.job += 1
        job = self.job
        self.acts.append((do, a))
        try:
            detail = fn(h, a)
            self._emit(helper, "job_done", {"job": job, "do": do, "detail": detail})
        except ModError as e:
            detail = getattr(e, "detail", None) or {}
            self._emit(helper, "job_failed", {"job": job, "do": do, "code": e.code, "text": e.text, "detail": detail})
        return {"job": job, "queued_before": 0}

    @staticmethod
    def _fail(code, text="", detail=None):
        e = ModError(code, text)
        e.detail = detail
        return e

    def do_walk(self, h, a):
        if self.unreachable:
            raise self._fail("path_failed", "no path")
        to = a["to"]
        walked = math.hypot(to["x"] - h["pos"]["x"], to["y"] - h["pos"]["y"])
        h["pos"] = {"x": to["x"], "y": to["y"]}
        return {"pos": dict(h["pos"]), "walked": round(walked, 1)}

    def do_collect(self, h, a):
        radius = a.get("radius", 64)
        center = a.get("center") or h["pos"]
        collected, missing, units = {}, {}, []
        for item, n in a["items"].items():
            left = n
            for s in self.stores:
                if left <= 0:
                    break
                if not self._near(s["pos"], center, radius):
                    continue
                if self.far_invisible and not self._near(s["pos"], h["pos"], 32):
                    continue                      # содержимое видно только рядом с телом
                take = min(left, s["items"].get(item, 0))
                if take > 0:
                    if self.unreachable and not self._near(s["pos"], h["pos"], 10):
                        raise self._fail("path_failed", "no path")
                    s["items"][item] -= take
                    h["inv"][item] = h["inv"].get(item, 0) + take
                    collected[item] = collected.get(item, 0) + take
                    left -= take
                    units.append(s["unit"])
                    h["pos"] = {"x": s["pos"]["x"] + 1.0, "y": s["pos"]["y"] + 1.0}   # подошёл к складу
            if left > 0:
                missing[item] = left
        detail = {"collected": collected or {}, "missing": missing or {}, "from": units or {}}
        if not collected:
            raise self._fail("no_items", "nothing to collect", detail)
        return detail

    def do_craft(self, h, a):
        item, count = a["recipe"], a["count"]
        if item not in self.recipes:
            raise self._fail("bad_args", "args.recipe: unknown recipe " + item)
        can = self._craftable(h["inv"], item)
        if can < count:
            raise self._fail("no_items", "not enough ingredients", {"craftable": can})
        ings, per = self.recipes[item]
        for _ in range(count):
            for k, c in ings.items():
                lacking = c - h["inv"].get(k, 0)
                if lacking > 0:
                    sub, sper = self.recipes[k]
                    runs = int(math.ceil(lacking / sper))
                    for i, q in sub.items():
                        h["inv"][i] -= q * runs
                    h["inv"][k] = h["inv"].get(k, 0) + runs * sper
                h["inv"][k] -= c
        h["inv"][item] = h["inv"].get(item, 0) + count * per
        h["inv"] = {k: n for k, n in h["inv"].items() if n > 0}
        return {"crafted": {item: count * per}}

    def _blueprint(self, blob):
        parts = self.blobs.get(blob)
        if not parts or len(parts) - 1 != parts["total"]:
            raise self._fail("bad_args", "args.blob: unknown blob")
        text = "".join(parts[i] for i in range(1, parts["total"] + 1))
        return json.loads(zlib.decompress(base64.b64decode(text[1:])).decode("utf-8"))["blueprint"]["entities"]

    def _layout(self, entities, anchor):
        """Центр рамки чертежа (по клеткам) — в anchor; первая постройка привязывается к сетке."""
        x0 = min(e["position"]["x"] - SIZE.get(e["name"], 1) / 2 for e in entities)
        x1 = max(e["position"]["x"] + SIZE.get(e["name"], 1) / 2 for e in entities)
        y0 = min(e["position"]["y"] - SIZE.get(e["name"], 1) / 2 for e in entities)
        y1 = max(e["position"]["y"] + SIZE.get(e["name"], 1) / 2 for e in entities)
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        out, shift = [], None
        for e in entities:
            wx, wy = anchor["x"] + e["position"]["x"] - cx, anchor["y"] + e["position"]["y"] - cy
            if shift is None:
                s = SIZE.get(e["name"], 1)
                snap = (lambda v: math.floor(v) + 0.5) if s % 2 == 1 else (lambda v: math.floor(v + 0.5))
                shift = (snap(wx) - wx, snap(wy) - wy)
            out.append((e["name"], (wx + shift[0], wy + shift[1]), e.get("direction", 0)))
        return out

    def _build(self, h, ghosts):
        """Построить призраки руками, пока хватает предметов. → (построено, осталось, не хватило)."""
        built, missing = 0, {}
        for pos, e in ghosts:
            if h["inv"].get(e["name"], 0) > 0:
                h["inv"][e["name"]] -= 1
                e["ghost"] = False
                built += 1
            else:
                missing[e["name"]] = missing.get(e["name"], 0) + 1
        h["inv"] = {k: n for k, n in h["inv"].items() if n > 0}
        if built and ghosts:
            h["pos"] = {"x": ghosts[0][0][0] + 2.0, "y": ghosts[0][0][1] + 2.0}   # подошёл к стройке
        return built, len(ghosts) - built, missing

    def _drill_has_ore(self, name, pos):
        """Бур ставится только на руду, которую он добывает (как движок 2.0.77)."""
        if name not in SIZE:
            return True
        reach = SIZE[name] / 2 + 1
        for ore, cells in self.ore.items():
            if ore in self.hard_ores and name != "big-mining-drill":
                continue
            if any(abs(x + 0.5 - pos[0]) <= reach and abs(y + 0.5 - pos[1]) <= reach for (x, y) in cells):
                return True
        return False

    def do_build_blueprint(self, h, a):
        plan = self._layout(self._blueprint(a["blob"]), a["anchor"])
        taken = self._occupied()
        ok, skipped = [], []
        for name, pos, d in plan:
            if any(c in taken for c in self._cells(pos, name)) or not self._drill_has_ore(name, pos):
                skipped.append({"name": name, "pos": {"x": pos[0], "y": pos[1]}, "reason": "cannot_place"})
            else:
                ok.append((name, pos, d))
        detail = {"ghosts": len(ok), "skipped": skipped or {}, "skipped_total": len(skipped), "tiles": {},
                  "tiles_skipped": 0, "to_remove": {}, "to_remove_total": 0, "missing": {}}
        if a.get("dry_run"):
            return detail
        if not ok:
            raise self._fail("cannot_place", "nothing placed", detail)
        placed = []
        for name, pos, d in ok:
            self.entities[pos] = {"name": name, "dir": d, "ghost": True}
            placed.append((pos, self.entities[pos]))
        if a.get("mode") == "robots":
            raise self._fail("no_items", "no personal robots", dict(detail, built=0, left=len(ok)))
        built, left, missing = self._build(h, placed)
        detail.update(built=built, left=left, blocked={}, blocked_total=0, missing=missing or {})
        if left:
            raise self._fail("no_items", "out of items", detail)
        return detail

    def do_build_ghosts(self, h, a):
        area = a.get("area")
        if area is None:
            r = a.get("radius", 64)
            area = {"left_top": {"x": h["pos"]["x"] - r, "y": h["pos"]["y"] - r},
                    "right_bottom": {"x": h["pos"]["x"] + r, "y": h["pos"]["y"] + r}}
        built, left, missing = self._build(h, self._ghosts_in(area))
        detail = {"built": built, "left": left, "blocked": {}, "blocked_total": 0, "missing": missing or {}}
        if left:
            raise self._fail("no_items", "out of items", detail)
        return detail

    def do_plan_mining(self, h, a):
        """Простая раскладка в окне, как у MPP `simple`: буры по обе стороны одной ленты во всю длину
        окна, один столб. Лента течёт в `direction`; её последняя клетка — выход разметки
        (`storage.mining_last` мода: его читает `plan_belt {from: "patch"}`). Раскладка считается для
        ленты на север и поворачивается вокруг центра окна."""
        area = a["area"]
        x0, y0 = int(area["left_top"]["x"]), int(area["left_top"]["y"])
        w, hh = int(area["right_bottom"]["x"]) - x0, int(area["right_bottom"]["y"]) - y0
        ore = self.ore.get(a.get("resource"), set())
        if not any(x0 <= x < x0 + w and y0 <= y < y0 + hh for (x, y) in ore):
            raise self._fail("not_found", "no ore in args.area")
        miner, belt, pole = a.get("miner", "electric-mining-drill"), a.get("belt", "transport-belt"), \
            a.get("pole", "small-electric-pole")
        if a.get("resource") in self.hard_ores and miner != "big-mining-drill":
            raise self._fail("bad_args", "args.miner: mining drill %s can't mine %s" % (miner, a.get("resource")))
        side = a.get("direction", "north")
        direction = SIDE_NUM[side]
        turns = direction // 4
        # каноника (лента на север): длина ленты — вдоль y
        cw, ch = (w, hh) if turns % 2 == 0 else (hh, w)
        rows = ch // 3
        canon = []
        if cw >= 7:
            canon += [(miner, (1.5, 1.5 + 3 * i), 4) for i in range(rows)]
            canon += [(miner, (5.5, 1.5 + 3 * i), 12) for i in range(rows)]
        canon += [(belt, (3.5, 0.5 + i), 0) for i in range(ch)]
        canon += [(pole, (7.5, 0.5), None)]

        def turn(cx, cy):
            if turns == 0:
                return cx, cy
            if turns == 1:
                return ch - cy, cx
            if turns == 2:
                return cw - cx, ch - cy
            return cy, cw - cx

        plan = []
        for name, (cx, cy), d in canon:
            rx, ry = turn(cx, cy)
            plan.append((name, (x0 + rx, y0 + ry), 0 if d is None else (d + direction) % 16))
        ex, ey = turn(3.5, 0.5)
        drills = sum(1 for name, _, _ in plan if name == miner)
        taken = self._occupied()
        skipped = sum(1 for name, pos, _ in plan if any(c in taken for c in self._cells(pos, name)))
        need = {}
        for name, _, _ in plan:
            need[name] = need.get(name, 0) + 1
        wet = sum(1 for c in ore if c in self.liquid and x0 <= c[0] < x0 + w and y0 <= c[1] < y0 + hh)
        detail = {"ghosts": len(plan) - skipped, "need": need, "layout": a.get("layout", "simple"),
                  "warnings": ["on_liquid:%d" % wet] if wet else {},
                  "drills": drills, "skipped": skipped, "tiles": 0,
                  "chosen": {"miner": miner, "belt": belt, "pole": pole},
                  "area": {"left_top": {"x": x0 - 1, "y": y0 - 1}, "right_bottom": {"x": x0 + w + 1, "y": y0 + hh + 1}}}
        if a.get("dry_run"):
            return dict(detail, dry_run=True)
        for name, pos, d in plan:
            if not any(c in taken for c in self._cells(pos, name)):
                self.entities[pos] = {"name": name, "dir": d, "ghost": True}
        h["mining_last"] = [{"pos": {"x": x0 + ex, "y": y0 + ey}, "direction": direction, "side": side}]
        return detail

    def _belt_route(self, start, goal):
        """Кратчайший путь по свободным клеткам (4 соседа) от start до goal. → [клетки] | None."""
        taken = self._occupied()
        if start in taken or goal in taken:
            return None
        lo_x, hi_x = min(start[0], goal[0]) - BELT_SEARCH_MARGIN, max(start[0], goal[0]) + BELT_SEARCH_MARGIN
        lo_y, hi_y = min(start[1], goal[1]) - BELT_SEARCH_MARGIN, max(start[1], goal[1]) + BELT_SEARCH_MARGIN
        prev = {start: None}
        queue = [start]
        i = 0
        while i < len(queue):
            cur = queue[i]
            i += 1
            if cur == goal:
                path = []
                while cur is not None:
                    path.append(cur)
                    cur = prev[cur]
                return path[::-1]
            for dx, dy in VEC.values():
                n = (cur[0] + dx, cur[1] + dy)
                if n in prev or n in taken or not (lo_x <= n[0] <= hi_x and lo_y <= n[1] <= hi_y):
                    continue
                prev[n] = cur
                queue.append(n)
        return None

    def do_plan_belt(self, h, a):
        """Лента призраками от начала до `to` в обход жидкости и построек (ACTIONS.md «plan_belt»).
        `from: "patch"` — от выхода последней разметки этого помощника: путь начинается с клетки, в
        которую смотрит её последняя лента."""
        to = (int(math.floor(a["to"]["x"])), int(math.floor(a["to"]["y"])))
        belt = a.get("belt", "transport-belt")
        if a.get("from") == "patch":
            outs = h.get("mining_last")
            if not outs:
                raise self._fail("not_found", "no mining layout of this helper: run plan_mining first")
            o = outs[0]
            vx, vy = VEC[o["direction"]]
            start = (int(math.floor(o["pos"]["x"])) + vx, int(math.floor(o["pos"]["y"])) + vy)
        else:
            start = (int(math.floor(a["from"]["x"])), int(math.floor(a["from"]["y"])))
        if start == to:
            raise self._fail("bad_args", "args.from and args.to are the same tile")
        if abs(start[0] - to[0]) > 512 or abs(start[1] - to[1]) > 512:
            raise self._fail("limit", "args.to is farther than 512 tiles from the start")
        path = self._belt_route(start, to)
        if path is None:
            raise self._fail("path_failed", "no route for the belt", {"reached": {"x": start[0], "y": start[1]}})
        plan, turns, last = [], 0, None
        for i, cell in enumerate(path):
            nxt = path[i + 1] if i + 1 < len(path) else None
            d = DIR_OF[(nxt[0] - cell[0], nxt[1] - cell[1])] if nxt else last
            if last is not None and d != last:
                turns += 1
            last = d
            plan.append((belt, (cell[0] + 0.5, cell[1] + 0.5), d))
        xs, ys = [c[0] for c in path], [c[1] for c in path]
        straight = abs(start[0] - to[0]) + abs(start[1] - to[1]) + 1
        detail = {"ghosts": len(plan), "length": len(plan), "undergrounds": 0, "turns": turns, "need": {belt: len(plan)},
                  "area": {"left_top": {"x": min(xs), "y": min(ys)}, "right_bottom": {"x": max(xs) + 1, "y": max(ys) + 1}},
                  "path": [{"x": path[0][0] + 0.5, "y": path[0][1] + 0.5}, {"x": to[0] + 0.5, "y": to[1] + 0.5}],
                  "warnings": ["long_detour"] if len(plan) > 2 * straight else {}, "lanes": 1,
                  "chosen": {"belt": belt}}
        lanes = a.get("lanes", 1)
        if lanes > 1:
            # пачка: ленты рядом, той же длины (модель не раскладывает их по клеткам — только сухой прогон)
            if not a.get("dry_run"):
                raise self._fail("internal", "the model lays a bundle only as a dry run")
            detail.update(ghosts=len(plan) * lanes, need={belt: len(plan) * lanes},
                          lanes=lanes if self.belt_lanes is None else self.belt_lanes)
        if a.get("underground", "auto") != "never" and self.underground:
            detail["chosen"]["underground"] = self.underground
        if a.get("dry_run"):
            return dict(detail, dry_run=True)
        for name, pos, d in plan:
            self.entities[pos] = {"name": name, "dir": d, "ghost": True}
        return detail


def ore_rect(x0, y0, w, h):
    return {(x, y) for x in range(x0, x0 + w) for y in range(y0, y0 + h)}
