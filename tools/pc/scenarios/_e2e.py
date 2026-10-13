"""Общее для сквозных сценариев e2e_* (поток K, docs/E2E.md, TESTING.md §4).

Не сценарий: сценарии грузятся по пути (live_client.load_scenario), поэтому e2e_* подгружают этот
файл сами (`_load("_e2e")`); `run` здесь — только чтобы загрузчик не падал.

Два способа говорить с игрой, один интерфейс (`read`, `act`):
- `LiveApi` — конверты `/partner <JSON>` напрямую через live_client;
- `McpApi`  — инструменты `partner_*` настоящего пакета сервера (server_client.ServerClient):
  ключ помощника, проверки сервера, `partner_wait`, `plan` → `blob_put` — как у агента.
Поэтому честная добыча предметов (`obtain`) одна и та же в обоих видах сценариев.

Честность (PROTOCOL §6): предметы появляются у помощника только действиями `collect` (со складов базы
в сейве), `walk` к складу и `craft` из собранного. Чего на складах нет и из чего не скрафтить —
подробно пишется в результат (`missing`), сценарий честно не проходит.
Только `/partner <JSON>`; никаких /c, /sc, /silent-command.
"""
from __future__ import annotations

import base64
import json
import math
import time
import zlib

HELPER = "e2e"
JOB_TIMEOUT_S = 180.0
WALK_TIMEOUT_S = 240.0
VISIBLE_WAIT_S = 12.0
COLLECT_RADIUS = 128       # предел collect / stock
GROUP_RADIUS = 48          # склады одной группы find лежат ближе 32 клеток друг к другу
MAX_GROUPS = 3             # к скольким группам складов идти за одним предметом
WALK_TO_STORE = 8          # на сколько клеток подойти к центру группы складов
PART_BYTES = 3000          # blob_put: часть ≤ 3500 байт (PROTOCOL §4)
GAME_VERSION = (2, 0, 77, 0)
# строки мода об ошибках модулей и рефлексов (scripts/core/init.lua log_error)
LOG_MUST_NOT_MATCH = r"\[factorio-partner\] .* failed"

# Рецепты БАЗОВОЙ игры: {предмет: (ингредиенты на один крафт, выход)}. Это подсказка, что нести к
# верстаку, а не истина: в сейве с модами рецепт может быть другим. Сколько крафтов реально выйдет,
# говорит мод (`recipes` / отказ `craft` с detail.craftable), сценарий верит ему.
RECIPES = {
    "electric-mining-drill": ({"electronic-circuit": 3, "iron-gear-wheel": 5, "iron-plate": 10}, 1),
    "burner-mining-drill": ({"iron-gear-wheel": 3, "iron-plate": 3, "stone-furnace": 1}, 1),
    "transport-belt": ({"iron-plate": 1, "iron-gear-wheel": 1}, 2),
    "small-electric-pole": ({"wood": 1, "copper-cable": 2}, 2),
    "medium-electric-pole": ({"iron-stick": 4, "steel-plate": 2, "copper-cable": 2}, 1),
    "iron-gear-wheel": ({"iron-plate": 2}, 1),
    "copper-cable": ({"copper-plate": 1}, 2),
    "iron-stick": ({"iron-plate": 1}, 2),
    "stone-furnace": ({"stone": 5}, 1),
}
MINERS = ("electric-mining-drill", "burner-mining-drill", "big-mining-drill")
BELTS = ("transport-belt", "fast-transport-belt", "express-transport-belt", "turbo-transport-belt")
POLES = ("small-electric-pole", "medium-electric-pole")
# половина стороны области добычи бура (клетки от центра): для сверки «бур стоит на руде»
MINING_REACH = {"electric-mining-drill": 2.5, "burner-mining-drill": 1.0, "big-mining-drill": 6.5}
DIR_NUM = {"north": 0, "east": 4, "south": 8, "west": 12}


# ---------------------------------------------------------------- мелочи

def as_map(v):
    """Пустая таблица мода приходит как {} или [] (PROTOCOL §1)."""
    return v if isinstance(v, dict) else {}


def as_list(v):
    return v if isinstance(v, list) else []


def code_of(r):
    return ((r or {}).get("data") or {}).get("code")


def text_of(r):
    return ((r or {}).get("data") or {}).get("text")


def detail_of(r):
    return as_map(((r or {}).get("data") or {}).get("detail"))


def brief(r):
    return {"do": r.get("do"), "job": r.get("job"), "seconds": r.get("seconds"), "kind": r.get("kind"),
            "data": r.get("data")}


def dist(a, b):
    return math.hypot(a["x"] - b["x"], a["y"] - b["y"])


def area_around(center, half_w, half_h=None):
    half_h = half_w if half_h is None else half_h
    return {"left_top": {"x": center["x"] - half_w, "y": center["y"] - half_h},
            "right_bottom": {"x": center["x"] + half_w, "y": center["y"] + half_h}}


def area_center(area):
    return {"x": (area["left_top"]["x"] + area["right_bottom"]["x"]) / 2,
            "y": (area["left_top"]["y"] + area["right_bottom"]["y"]) / 2}


def area_side(area):
    return (area["right_bottom"]["x"] - area["left_top"]["x"], area["right_bottom"]["y"] - area["left_top"]["y"])


def _refused(do, args, error, t0):
    error = error or {}
    return {"do": do, "args": args, "job": None, "seconds": round(time.monotonic() - t0, 1), "kind": "refused",
            "data": {"code": error.get("code"), "text": error.get("text")}, "kinds": []}


def _outcome(do, args, job, t0, ev, kinds):
    return {"do": do, "args": args, "job": job, "seconds": round(time.monotonic() - t0, 1),
            "kind": ev and ev.get("kind"), "data": ev and ev.get("data"), "kinds": kinds[-30:]}


# ---------------------------------------------------------------- два транспорта

class LiveApi:
    """Конверты `/partner <JSON>` напрямую (live_client.LiveClient)."""

    kind = "live"

    def __init__(self, client, helper=HELPER):
        self.client = client
        self.helper = helper

    def hello(self):
        return self.client.call_ok("hello")

    def spawn(self):
        """→ (ok, сведения | ошибка)."""
        r = self.client.call("helper_spawn", {}, self.helper)
        if r["ok"]:
            return True, r["data"]
        err = r.get("error") or {}
        if err.get("code") == "helper_exists":
            return True, {"reused": True}
        return False, {"code": err.get("code"), "text": err.get("text")}

    def read(self, op, args=None):
        return self.client.call_ok(op, args or {}, self.helper)

    def try_read(self, op, args=None):
        r = self.client.call(op, args or {}, self.helper)
        if r["ok"]:
            return {"ok": True, "data": r.get("data") or {}}
        return {"ok": False, "error": r.get("error") or {}}

    def act(self, do, args, timeout=JOB_TIMEOUT_S):
        """Поставить задачу и дождаться итога (нет итога — cancel).
        → {do, args, job, seconds, kind: job_done│job_failed│refused│None, data, kinds}."""
        t0 = time.monotonic()
        since = self.client.call("hello")["seq"]   # seq конверта — последнее событие в буфере
        r = self.client.call("act", {"do": do, "args": args}, self.helper)
        if not r["ok"]:
            return _refused(do, args, r.get("error"), t0)
        job = r["data"]["job"]
        end = time.monotonic() + min(timeout, self.client.time_left())
        kinds = []
        while time.monotonic() < end:
            data = self.client.call_ok("events", {"since": since, "helper": self.helper, "limit": 200})
            for ev in as_list(data.get("events")):
                kinds.append(ev.get("kind"))
                if ev.get("kind") in ("job_done", "job_failed") and as_map(ev.get("data")).get("job") == job:
                    return _outcome(do, args, job, t0, ev, kinds)
            since = data.get("seq", since)
            self.client.sleep(0.5)
        self.client.call("cancel", {"job": job}, self.helper)
        return _outcome(do, args, job, t0, None, kinds)


class McpApi:
    """Инструменты `partner_*` настоящего пакета сервера (server_client.ServerClient)."""

    kind = "mcp"
    WAIT_STEP_S = 20

    def __init__(self, client):
        self.client = client
        self.helper = client.helper

    def hello(self):
        return as_map(self.client.admin("hello").get("data"))

    def spawn(self):
        r = self._try(lambda: self.client.admin("spawn", helper=self.helper))
        if r["ok"]:
            return True, as_map(r["data"].get("data"))
        if r["error"].get("code") == "helper_exists":
            return True, {"reused": True}
        return False, r["error"]

    @staticmethod
    def _try(fn):
        try:
            return {"ok": True, "data": fn()}
        except Exception as e:  # ToolError сервера: у него есть code
            code = getattr(e, "code", None)
            if code is None:
                raise
            return {"ok": False, "error": {"code": code, "text": getattr(e, "text", None)}}

    def read(self, op, args=None):
        return self.client.tool(op, **(args or {}))

    def try_read(self, op, args=None):
        return self.client.try_tool(op, **(args or {}))

    def act(self, do, args, timeout=JOB_TIMEOUT_S):
        """`partner_act` + `partner_wait` до итога задачи — как это делает агент."""
        t0 = time.monotonic()
        r = self.client.try_tool("act", do=do, args=args)
        if not r["ok"]:
            return _refused(do, args, r["error"], t0)
        job = r["data"].get("job")
        end = time.monotonic() + min(timeout, self.client.time_left())
        kinds = []
        while time.monotonic() < end:
            step = max(1, min(self.WAIT_STEP_S, int(end - time.monotonic())))
            w = self.client.tool("wait", timeout=step, quiet=True)
            for ev in as_list(w.get("events")):
                kinds.append(ev.get("kind"))
                if ev.get("kind") in ("job_done", "job_failed") and as_map(ev.get("data")).get("job") == job:
                    return _outcome(do, args, job, t0, ev, kinds)
        self.client.try_tool("cancel", job=job)
        return _outcome(do, args, job, t0, None, kinds)


def api_for(client):
    """Сценарий под server_client получает клиента с `tool` — тогда идём через сервер."""
    return McpApi(client) if callable(getattr(client, "tool", None)) else LiveApi(client)


# ---------------------------------------------------------------- начало сценария

def start(api, result):
    """hello + проверка мода + помощник. → bool (ошибка — в result)."""
    hello = api.hello()
    result.update(mod=str(hello.get("mod", "")), players_online=hello.get("players_online"), transport=api.kind,
                  log_must_not_match=LOG_MUST_NOT_MATCH)
    mod = str(hello.get("mod", ""))
    if mod.startswith("partner-test") or hello.get("proto") != 1:
        result.update(ok=False, error={"kind": "setup", "text": f"нужен мод factorio-partner, ответил {mod!r}"})
        return False
    ok, info = api.spawn()
    result["spawn"] = info
    if not ok:
        result.update(ok=False, error={"kind": "spawn", "code": info.get("code"), "text": info.get("text")})
        return False
    settle(api, result)
    return True


def fail_setup(result, text, **extra):
    result.update(ok=False, error=dict({"kind": "setup", "text": text}, **extra))
    return result


def finish(result, reasons):
    result["ok"] = not reasons
    if reasons:
        result["reasons"] = reasons
    return result


# ---------------------------------------------------------------- инвентарь и честная добыча предметов

def state(api):
    return api.read("state")


def inventory(api):
    return dict(as_map(state(api).get("inv")))


def lack(api, want):
    """Чего не хватает в инвентаре помощника до want. → {item: n}."""
    inv = inventory(api)
    return {k: n - inv.get(k, 0) for k, n in want.items() if inv.get(k, 0) < n}


def settle(api, result):
    """Склады становятся видны не сразу после появления тела (обзор помощника, PROTOCOL §6.7):
    один раз ждём, пока `stock` увидит хоть что-то рядом. Пусто — не ошибка (склады могут быть далеко)."""
    last = {}

    def look():
        data = api.read("stock", {"radius": COLLECT_RADIUS, "limit": 5})
        last.update(hidden=data.get("hidden", 0), kinds=len(as_map(data.get("total"))))
        return last["kinds"]

    t0 = time.monotonic()
    api.client.poll(look, VISIBLE_WAIT_S, 1.0)
    result["stock_near"] = dict(last, waited_s=round(time.monotonic() - t0, 1))


def stock_total(api, items, radius=COLLECT_RADIUS):
    """Сколько нужного лежит на видимых складах в радиусе. → ({item: n}, сколько складов не видно)."""
    data = api.read("stock", {"radius": radius, "items": list(items), "limit": 50})
    return as_map(data.get("total")), data.get("hidden", 0)


def _step(log, name, r=None, **extra):
    entry = {"step": name}
    if r is not None:
        entry.update(kind=r.get("kind"), code=code_of(r), seconds=r.get("seconds"))
        d = detail_of(r)
        for key in ("collected", "missing", "crafted", "craftable", "walked", "pos", "reason"):
            if d.get(key) not in (None, {}, []):
                entry[key] = d[key]
        if r.get("kind") not in ("job_done", "job_failed"):
            entry["text"] = text_of(r)
    entry.update(extra)
    log.append(entry)
    return entry


def storage_groups(api, item):
    """Группы складов с предметом по всей базе (`find`, ближние первыми). → [{pos, amount, dist}]."""
    r = api.try_read("find", {"item": item, "kinds": ["storage"], "limit": 8})
    if not r["ok"]:
        return [], r["error"]
    groups = [g for g in as_list(r["data"].get("groups")) if g.get("kind") == "storage" and g.get("pos")]
    return groups, None


def fetch(api, want, log):
    """Довести инвентарь помощника до want со складов базы: `collect` рядом, потом поход к складам,
    которые нашёл `find`. → чего всё ещё не хватает {item: n}."""
    need = lack(api, want)
    if not need:
        return {}
    total, hidden = stock_total(api, need)
    take = {k: min(n, total.get(k, 0)) for k, n in need.items() if total.get(k, 0) > 0}
    _step(log, "stock", near=total, hidden=hidden, need=dict(need))
    if take:
        _step(log, "collect", api.act("collect", {"items": take, "radius": COLLECT_RADIUS}), items=take)
        need = lack(api, want)
    for item in sorted(need):
        if item not in need:
            continue
        groups, err = storage_groups(api, item)
        _step(log, "find", item=item, groups=[{"pos": g["pos"], "amount": g.get("amount"), "dist": g.get("dist")}
                                               for g in groups[:MAX_GROUPS]], error=err)
        for g in groups[:MAX_GROUPS]:
            if api.client.time_left() < 60:
                _step(log, "out_of_time", item=item)
                return lack(api, want)
            # collect сам подходит к каждому складу; заодно берём всё остальное недостающее — склады
            # базы обычно стоят кучно
            _step(log, "collect", api.act("collect", {"items": dict(need), "center": g["pos"], "radius": GROUP_RADIUS},
                                          WALK_TIMEOUT_S), items=dict(need), center=g["pos"])
            need = lack(api, want)
            if item not in need:
                break
            # не взял: содержимое складов видно только в видимых чанках (PROTOCOL §6.7) — подойти
            # самому и собрать вокруг себя. Центр группы бывает внутри постройки, поэтому точек несколько.
            for to in approach_points(g["pos"]):
                w = api.act("walk", {"to": to, "radius": WALK_TO_STORE}, WALK_TIMEOUT_S)
                _step(log, "walk", w, to=to)
                if w.get("kind") != "job_done":
                    continue
                _step(log, "collect", api.act("collect", {"items": dict(need), "radius": GROUP_RADIUS}),
                      items=dict(need))
                need = lack(api, want)
                break
            if item not in need:
                break
    return lack(api, want)


def approach_points(pos, step=10):
    """Куда идти к группе складов: её центр, потом точки вокруг (центр бывает внутри постройки)."""
    return [dict(pos)] + [{"x": pos["x"] + dx, "y": pos["y"] + dy}
                          for dx, dy in ((step, 0), (0, step), (-step, 0), (0, -step))]


def craftable(api, item):
    """Сколько крафтов рецепта item выйдет из инвентаря помощника (`recipes`)."""
    r = api.try_read("recipes", {"filter": item})
    if not r["ok"]:
        return 0
    return int(as_map(r["data"].get("craftable")).get(item, 0) or 0)


def _ingredients(missing):
    """Сырьё на крафт недостающего по RECIPES. → ({ингредиент: n}, {предмет: число крафтов}, [без рецепта])."""
    need, runs, unknown = {}, {}, []
    for item, n in missing.items():
        recipe = RECIPES.get(item)
        if recipe is None:
            unknown.append(item)
            continue
        ings, per = recipe
        runs[item] = int(math.ceil(n / per))
        for k, c in ings.items():
            need[k] = need.get(k, 0) + c * runs[item]
    return need, runs, unknown


def obtain(api, want, log):
    """Честно добыть want в инвентарь помощника: склады базы, а чего на них нет — сырьё со складов
    и ручной крафт. → (чего не хватило {item: n}, пояснения [{item, ...}])."""
    missing = fetch(api, want, log)
    if not missing:
        return {}, []
    need, runs, unknown = _ingredients(missing)
    notes = [{"item": i, "missing": missing[i], "why": "нет на складах базы, рецепт сценарию неизвестен"}
             for i in unknown]
    if need:
        # сырьё — сверх того, что нужно само по себе
        target = {k: n + want.get(k, 0) for k, n in need.items()}
        short = fetch(api, target, log)
        if short:
            # нет готового промежуточного (шестерни, кабель) — несём сырьё для него: движок скрафтит сам
            deeper, _, _ = _ingredients({k: n for k, n in short.items() if k in RECIPES})
            if deeper:
                inv = inventory(api)
                fetch(api, {k: n + inv.get(k, 0) for k, n in deeper.items()}, log)
    for item in sorted(runs):
        can = craftable(api, item)
        n = min(runs[item], can)
        if n <= 0:
            notes.append({"item": item, "missing": missing[item], "craftable": can, "recipe_guess": RECIPES[item][0],
                          "why": "на складах нет, а из собранного не крафтится (другой рецепт в сейве или нет сырья)"})
            continue
        r = api.act("craft", {"recipe": item, "count": n})
        _step(log, "craft", r, recipe=item, count=n)
        if n < runs[item]:
            notes.append({"item": item, "missing": missing[item], "craftable": can, "wanted_crafts": runs[item],
                          "why": "сырья хватило не на все крафты"})
    left = lack(api, want)
    for item in left:
        if not any(nt.get("item") == item for nt in notes):
            notes.append({"item": item, "missing": left[item], "why": "не хватило после сбора и крафта"})
    if left:
        notes.append({"inventory": inventory(api)})
    return left, (notes if left else [])


def pick_available(api, candidates, log, key):
    """Первый из candidates, который лежит на складах базы (`find`); нет ни одного — первый с известным
    рецептом (его скрафтит `obtain`). → имя | None."""
    seen = {}
    for name in candidates:
        groups, _ = storage_groups(api, name)
        seen[name] = sum(int(g.get("amount") or 0) for g in groups)
        if seen[name] > 0:
            _step(log, "pick", what=key, chosen=name, stored=seen)
            return name
    for name in candidates:
        if name in RECIPES:
            _step(log, "pick", what=key, chosen=name, stored=seen, craft=True)
            return name
    _step(log, "pick", what=key, chosen=None, stored=seen)
    return None


# ---------------------------------------------------------------- чертёж и карта

def encode_blueprint(entities, label="partner-e2e"):
    """Строка чертежа Factorio: «0» + base64(zlib(JSON)). entities: [{name, position{x,y}, direction?}]."""
    major, minor, patch, dev = GAME_VERSION
    version = (major << 48) | (minor << 32) | (patch << 16) | dev
    body = {"item": "blueprint", "label": label, "version": version,
            "entities": [dict(e, entity_number=i + 1) for i, e in enumerate(entities)]}
    raw = json.dumps({"blueprint": body}, separators=(",", ":")).encode("utf-8")
    return "0" + base64.b64encode(zlib.compress(raw, 9)).decode("ascii")


def decode_blueprint(text):
    return json.loads(zlib.decompress(base64.b64decode(text[1:])).decode("utf-8"))


def put_blob(client, text, tag="e2e"):
    """Отправить строку чертежа в мод частями (`blob_put`, PROTOCOL §4). → id blob."""
    blob = "%s-%05d-%04x" % (tag, int(time.time()) % 100000, int(time.monotonic() * 1000) % 65536)
    parts = [text[i:i + PART_BYTES] for i in range(0, len(text), PART_BYTES)]
    for i, part in enumerate(parts, 1):
        client.call_ok("blob_put", {"blob": blob, "part": i, "total": len(parts), "data": part})
    return blob


def drill_pair_blueprint(miner, belt):
    """Маленький чертёж «как рамка игрока»: два бура 3×3 лицом к ленте из трёх клеток между ними.
    Рамка 7×3, центр — в (0, 0)."""
    ents = [{"name": miner, "position": {"x": -2, "y": 0}, "direction": 4},
            {"name": miner, "position": {"x": 2, "y": 0}, "direction": 12}]
    ents += [{"name": belt, "position": {"x": 0, "y": y}, "direction": 0} for y in (-1, 0, 1)]
    return ents


def on_map(api, names, center, radius):
    """Свои постройки и призраки с такими именами вокруг точки. → (построено [...], призраки [...], обрезано)."""
    data = api.read("map", {"center": center, "radius": max(1, min(32, int(math.ceil(radius)))),
                            "names": list(names)})
    ents = [e for e in as_list(data.get("entities")) if e.get("name") in names]
    return ([e for e in ents if not e.get("ghost")], [e for e in ents if e.get("ghost")],
            bool(data.get("truncated")))


def ore_cells(data, resource):
    """Клетки руды resource из ответа `map` (до постановки призраков: они рисуются поверх). → {(x, y)}."""
    letters = {ch for ch, text in as_map(data.get("legend")).items() if text == "руда: " + resource}
    box = as_map(data.get("bbox"))
    cells = set()
    for r, row in enumerate(as_list(data.get("rows"))):
        for c, ch in enumerate(row):
            if ch in letters:
                cells.add((box["x0"] + c, box["y0"] + r))
    return cells


def drill_on_ore(pos, reach, cells):
    """Есть ли клетка руды в области добычи бура с центром pos."""
    x0, x1 = int(math.floor(pos["x"] - reach)), int(math.ceil(pos["x"] + reach))
    y0, y1 = int(math.floor(pos["y"] - reach)), int(math.ceil(pos["y"] + reach))
    return any((x, y) in cells for x in range(x0, x1) for y in range(y0, y1))


def covered_share(drills, reach, cells):
    """Доля клеток руды, до которых достаёт хотя бы один бур."""
    if not cells:
        return 0.0
    hit = 0
    for (x, y) in cells:
        cx, cy = x + 0.5, y + 0.5
        if any(abs(cx - d["x"]) <= reach and abs(cy - d["y"]) <= reach for d in drills):
            hit += 1
    return round(hit / len(cells), 3)


# ---------------------------------------------------------------- лента: клетки и непрерывность

VEC = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}     # defines.direction 2.0 → шаг по клеткам
BELT_WINDOW = 10        # окно карты 21×21: в ответе `map` не больше 100 сущностей
BELT_AHEAD = 12         # на сколько клеток от края разметки искать конец ленты
BELT_SPOT = 3           # свободная площадка BELT_SPOT×BELT_SPOT под конец ленты


def cell_of(pos):
    return (int(math.floor(pos["x"])), int(math.floor(pos["y"])))


def cell_center(cell):
    return {"x": cell[0] + 0.5, "y": cell[1] + 0.5}


def belt_cells(api, areas, names):
    """Ленты с такими именами в областях, как их видит игра (`map`, окнами 21×21).
    → ({клетка: {"name", "dir", "ghost"}}, обрезан ли хоть один ответ)."""
    out, truncated, seen = {}, False, set()
    step = 2 * BELT_WINDOW + 1
    for area in areas:
        x0, y0 = int(math.floor(area["left_top"]["x"])), int(math.floor(area["left_top"]["y"]))
        x1, y1 = int(math.ceil(area["right_bottom"]["x"])), int(math.ceil(area["right_bottom"]["y"]))
        y = y0
        while y <= y1:
            x = x0
            while x <= x1:
                key = (x, y)
                if key not in seen:
                    seen.add(key)
                    center = {"x": x + BELT_WINDOW + 0.5, "y": y + BELT_WINDOW + 0.5}
                    data = api.read("map", {"center": center, "radius": BELT_WINDOW, "names": list(names)})
                    truncated = truncated or bool(data.get("truncated"))
                    for e in as_list(data.get("entities")):
                        if e.get("name") in names and e.get("pos"):
                            out[cell_of(e["pos"])] = {"name": e["name"], "dir": e.get("dir"),
                                                      "ghost": bool(e.get("ghost"))}
                x += step
            y += step
    return out, truncated


def flows_to(belts, start, end, limit=4000):
    """Доходит ли предмет по лентам от клетки start до клетки end: каждая лента передаёт в клетку,
    на которую смотрит. → (дошёл ли, где остановился)."""
    cur, seen = start, set()
    while cur in belts and cur not in seen and len(seen) < limit:
        if cur == end:
            return True, cur
        seen.add(cur)
        v = VEC.get(belts[cur].get("dir"))
        if v is None:
            return False, cur
        cur = (cur[0] + v[0], cur[1] + v[1])
    return False, cur       # лента кончилась (или пошла по кругу), не дойдя до end


def belt_targets(api, area, direction, log, limit=4):
    """Куда вести ленту от разметки: свободные площадки голой земли в BELT_AHEAD клетках за краем
    области разметки со стороны direction (ближние к точке напротив середины края — первыми).
    → [клетка]."""
    vx, vy = VEC[DIR_NUM[direction]]
    c = area_center(area)
    half_w, half_h = area_side(area)[0] / 2, area_side(area)[1] / 2
    ideal = {"x": c["x"] + vx * (half_w + BELT_AHEAD), "y": c["y"] + vy * (half_h + BELT_AHEAD)}
    data = api.read("map", {"center": ideal, "radius": 16})
    wins = free_windows(data, "", BELT_SPOT, BELT_SPOT, min_ore=0, limit=limit * 3, near=ideal)
    cells = []
    for win in wins:
        cell = cell_of(area_center(win["area"]))
        ahead = (cell[0] + 0.5 - c["x"]) * vx + (cell[1] + 0.5 - c["y"]) * vy
        if ahead >= (half_w if vx else half_h) + 3:      # за краем разметки, а не сбоку и не внутри
            cells.append(cell)
    _step(log, "belt_target", ideal=ideal, spots=len(wins), ahead=len(cells))
    return cells[:limit]


# ---------------------------------------------------------------- поиск руды и свободного места

ORE_NAMES =("iron-ore", "copper-ore", "coal", "stone", "tungsten-ore", "calcite", "scrap", "uranium-ore")
MIN_ORE_TILES = 16      # меньше — не пятно (огрызок под старыми бурами)
SEARCH_RADIUS = 128     # предел операции resources
_R1, _R2 = 200, 400
# точки поиска: у помощника, затем кольца на 200 и 400 клеток (круги радиуса 128 перекрываются)
SEARCH_RINGS = (
    ((0, 0),),
    ((_R1, 0), (-_R1, 0), (0, _R1), (0, -_R1), (_R1, _R1), (-_R1, _R1), (_R1, -_R1), (-_R1, -_R1)),
    ((_R2, 0), (-_R2, 0), (0, _R2), (0, -_R2), (_R2, _R2), (-_R2, _R2), (_R2, -_R2), (-_R2, -_R2),
     (_R2, _R1), (_R2, -_R1), (-_R2, _R1), (-_R2, -_R1), (_R1, _R2), (-_R1, _R2), (_R1, -_R2), (-_R1, -_R2)),
)


def find_ore(api, log, names=ORE_NAMES):
    """Пятна твёрдой руды от ближнего к дальнему: вокруг помощника, потом кольцами дальше.

    Запрос — по именам руд: общий ответ `resources` (20 ближайших пятен) на базе бывает целиком забит
    одиночными гейзерами. Имя, которого нет в игре (другой набор модов), — `bad_args`, пропускается."""
    base = state(api)["pos"]
    known = list(names)
    for i, ring in enumerate(SEARCH_RINGS):
        found, seen, queries = [], set(), 0
        for dx, dy in ring:
            center = {"x": base["x"] + dx, "y": base["y"] + dy}
            for name in list(known):
                r = api.try_read("resources", {"radius": SEARCH_RADIUS, "name": name, "center": center})
                queries += 1
                if not r["ok"]:
                    if r["error"].get("code") == "bad_args":
                        known.remove(name)
                    continue
                for p in as_list(r["data"].get("patches")):
                    key = (p["name"], p["area"]["left_top"]["x"], p["area"]["left_top"]["y"])
                    if key in seen or (p.get("tiles") or 0) < MIN_ORE_TILES:
                        continue
                    seen.add(key)
                    found.append(dict(p, dist=round(dist(p["center"], base), 1)))
        found.sort(key=lambda p: p["dist"])
        _step(log, "find_ore", ring=i, queries=queries,
              patches=[{"name": p["name"], "tiles": p.get("tiles"), "dist": p["dist"]} for p in found[:12]])
        if found:
            return found
    return []


def free_windows(data, resource, w, h, min_ore=1, limit=4, near=None):
    """Свободные окна w×h на карте (`map`): только земля и руда resource, без построек, воды и камней.
    → [{area, ore}] — сначала те, где руды больше, при равенстве — ближе к точке near; окна не
    пересекаются. resource = "" — окна на голой земле."""
    letters = {ch for ch, text in as_map(data.get("legend")).items() if text == "руда: " + resource}
    rows = as_list(data.get("rows"))
    box = as_map(data.get("bbox"))
    if not rows or not box:
        return []
    width = min(len(r) for r in rows)

    def far(r, c):
        if near is None:
            return 0.0
        return math.hypot(box["x0"] + c + w / 2 - near["x"], box["y0"] + r + h / 2 - near["y"])

    cand = []
    for r in range(0, len(rows) - h + 1):
        for c in range(0, width - w + 1):
            ore, ok = 0, True
            for rr in range(r, r + h):
                seg = rows[rr][c:c + w]
                for ch in seg:
                    if ch in letters:
                        ore += 1
                    elif ch != ".":
                        ok = False
                        break
                if not ok:
                    break
            if ok and ore >= min_ore:
                cand.append((ore, r, c))
    cand.sort(key=lambda t: (-t[0], far(t[1], t[2]), t[1], t[2]))
    out, taken = [], []
    for ore, r, c in cand:
        if any(abs(r - tr) < h and abs(c - tc) < w for tr, tc in taken):
            continue
        taken.append((r, c))
        x, y = box["x0"] + c, box["y0"] + r
        out.append({"ore": ore, "area": {"left_top": {"x": x, "y": y}, "right_bottom": {"x": x + w, "y": y + h}}})
        if len(out) >= limit:
            break
    return out


def patch_windows(api, patch, w, h, log, min_ore=None, limit=3):
    """Свободные окна w×h на руде одного пятна. → [{patch, area, ore, map}] (карта снята до
    постановки призраков — по ней потом сверяется покрытие)."""
    min_ore = max(1, (w * h) // 3) if min_ore is None else min_ore
    data = api.read("map", {"center": patch["center"], "radius": 32, "names": [patch["name"]]})
    wins = free_windows(data, patch["name"], w, h, min_ore, limit, near=patch["center"])
    _step(log, "ore_window", resource=patch["name"], center=patch["center"], dist=patch.get("dist"),
          size=[w, h], windows=len(wins), best=wins[0]["ore"] if wins else 0)
    return [{"patch": patch, "area": win["area"], "ore": win["ore"], "map": data} for win in wins]


def ore_windows(api, patches, w, h, log, min_ore=None, tries=4):
    """Свободные окна w×h на руде: первое из tries ближних пятен, где такие окна есть."""
    for patch in patches[:tries]:
        wins = patch_windows(api, patch, w, h, log, min_ore)
        if wins:
            return wins
    return []


def ore_candidates(api, log, w, h, min_ore=None, names=ORE_NAMES, bad=None, per_name=2, limit=2):
    """Свободные окна w×h на руде по всем найденным видам руды, ближние пятна первыми (генератор).

    Бур ставится только на руду, которую он добывает (замер 2.0.77: призрак электрического бура на
    голой земле и на вольфраме — `cannot_place`), а какая руда годится, знает только игра. Поэтому
    вызывающий пробует окно сухим прогоном и негодную руду кладёт в `bad` — её пятна дальше не смотрим."""
    bad = set() if bad is None else bad
    used = {}
    for patch in find_ore(api, log, names):
        name = patch["name"]
        if name in bad or used.get(name, 0) >= per_name:
            continue
        used[name] = used.get(name, 0) + 1
        for win in patch_windows(api, patch, w, h, log, min_ore, limit):
            if name in bad:
                break
            yield win


def ground_windows(api, w, h, log, limit=4):
    """Свободные окна w×h на голой земле рядом с помощником (ближние первыми). → [area]."""
    base = state(api)["pos"]
    data = api.read("map", {"center": base, "radius": 32})
    wins = free_windows(data, "", w, h, min_ore=0, limit=limit, near=base)
    _step(log, "ground_window", size=[w, h], windows=len(wins))
    return [win["area"] for win in wins]


def run(client) -> dict:
    return {"ok": False, "error": {"kind": "setup", "text": "_e2e — общий модуль сценариев e2e_*, не сценарий"}}
