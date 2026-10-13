"""Общее для живых сценариев потока N «Прокладка лент» (belt_*): съёмка местности операцией `map`,
поиск подходящих точек и сверка поставленных призраков с игрой.

Не сценарий (загрузчик пропускает файлы `_*`); belt_* подгружают его по пути рядом с собой.
Только конверты `/partner <JSON>` через live_client (TESTING.md §3). Сейв — копия стенда.

Местность. `map` рисует клетки символами (STATE.md): `~` и `,` — жидкость (лава, вода, мазут: строить
без подложки нельзя), `?` — не открыто, `.` — земля, строчная буква из легенды «руда: …» — руда,
остальное — постройки, деревья, скалы, призраки. Имён плиток сценарии не знают: жидкость — то, что
мод нарисовал жидкостью.
"""
from __future__ import annotations

import importlib.util
import os
from collections import deque

HELPER = "belt"
JOB_TIMEOUT_S = 120.0
LIQUID = "~,"
UNKNOWN = "?"
VEC = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}
SCAN_STEP = 64          # окна карты радиуса 32 (65 × 65 клеток) с шагом 64
SCAN_RINGS = 2          # 5 × 5 окон: ± 160 клеток от помощника
MAP_WINDOW = 10         # окно сверки призраков: 21 × 21 клетка (в ответе `map` не больше 100 сущностей)
MAX_UNDERGROUND = 12    # дальше подземный конвейер не достаёт ни у одной ленты игры и модов с запасом
MAX_PATH_SEARCHES = 300 # сколько пар точек проверять на проходимость по земле


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")
    spec = importlib.util.spec_from_file_location("fp_scenario_" + name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


H = _load("_hands")


def act(client, do, args, timeout=JOB_TIMEOUT_S):
    return H.act(client, do, args, timeout, HELPER)


def code_of(r):
    return ((r or {}).get("data") or {}).get("code")


def text_of(r):
    return ((r or {}).get("data") or {}).get("text")


def detail_of(r):
    return ((r or {}).get("data") or {}).get("detail") or {}


def brief(r):
    return {"job": r["job"], "seconds": r["seconds"], "kind": r["kind"], "data": r["data"]}


def center(cell):
    return {"x": cell[0] + 0.5, "y": cell[1] + 0.5}


def prepare(client, result):
    """hello + мод + помощник. → клетка помощника | None (ошибка — в result)."""
    hello = client.call_ok("hello")
    result.update(mod=str(hello.get("mod", "")), players_online=hello.get("players_online"))
    if not H.check_mod(hello, result):
        return None
    if not H.spawn(client, result, HELPER):
        result["ok"] = False
        return None
    pos = client.call_ok("state", {}, HELPER)["pos"]
    return (int(pos["x"] // 1), int(pos["y"] // 1))


# ---------------------------------------------------------------- местность

class Terrain:
    """Клетки, снятые операцией `map`: символ на клетку + какие символы — руда."""

    def __init__(self):
        self.cells = {}
        self.ore = set()
        self.maps = 0

    def add(self, data):
        self.maps += 1
        box = data["bbox"]
        for ch, text in (data.get("legend") or {}).items():
            if str(text).startswith("руда"):
                self.ore.add(ch)
        for j, row in enumerate(data.get("rows") or []):
            y = box["y0"] + j
            for i, ch in enumerate(row):
                self.cells[(box["x0"] + i, y)] = ch

    def ch(self, cell):
        return self.cells.get(cell, UNKNOWN)

    def liquid(self, cell):
        return self.ch(cell) in LIQUID

    def land(self, cell):
        """Свободная земля или руда: ленту поставить можно наверняка."""
        ch = self.ch(cell)
        return ch == "." or ch in self.ore

    def passable(self, cell):
        """Не жидкость и открыто: суша, пусть и с постройками и деревьями."""
        ch = self.ch(cell)
        return ch != UNKNOWN and ch not in LIQUID

    def count(self, pred):
        return sum(1 for c in self.cells if pred(c))


def scan(client, origin, rings=SCAN_RINGS):
    """Снять местность вокруг клетки origin. → Terrain."""
    t = Terrain()
    for j in range(-rings, rings + 1):
        for i in range(-rings, rings + 1):
            c = {"x": origin[0] + 0.5 + i * SCAN_STEP, "y": origin[1] + 0.5 + j * SCAN_STEP}
            r = client.call("map", {"center": c, "radius": 32}, HELPER)
            if r.get("ok"):
                t.add(r["data"])
    return t


def neighbours(cell):
    x, y = cell
    return ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1))


def component(start, ok, limit=200000):
    """Связная область клеток с ok(cell) от start (4 соседа). → множество."""
    seen = {start}
    queue = deque([start])
    while queue and len(seen) < limit:
        cur = queue.popleft()
        for n in neighbours(cur):
            if n not in seen and ok(n):
                seen.add(n)
                queue.append(n)
    return seen


def reachable(t, a, b, margin=40):
    """Есть ли путь по свободной земле от a до b внутри рамки вокруг них. → длина пути | None."""
    x0, x1 = min(a[0], b[0]) - margin, max(a[0], b[0]) + margin
    y0, y1 = min(a[1], b[1]) - margin, max(a[1], b[1]) + margin
    dist = {a: 0}
    queue = deque([a])
    while queue:
        cur = queue.popleft()
        if cur == b:
            return dist[cur]
        for n in neighbours(cur):
            if n not in dist and x0 <= n[0] <= x1 and y0 <= n[1] <= y1 and t.land(n):
                dist[n] = dist[cur] + 1
                queue.append(n)
    return None


def near_ore(t, cell, radius=3):
    for dx in range(-radius, radius + 1):
        for dy in range(-radius, radius + 1):
            if t.ch((cell[0] + dx, cell[1] + dy)) in t.ore:
                return True
    return False


def find_detour_pair(t, origin, lo=40, hi=80, min_liquid=3):
    """Две клетки свободной земли на одной прямой в lo..hi клетках друг от друга: между ними по прямой
    жидкость, а по земле путь есть. Первая — по возможности у руды. → (a, b, сведения) | None."""
    best = None
    searches = 0
    cells = sorted((c for c in t.cells if t.ch(c) in LIQUID),
                   key=lambda c: abs(c[0] - origin[0]) + abs(c[1] - origin[1]))
    tried = set()
    for lq in cells[:4000]:
        for dx, dy in ((1, 0), (0, 1)):
            # полоса жидкости вдоль оси: её края
            lo_c, hi_c = lq, lq
            while t.liquid((lo_c[0] - dx, lo_c[1] - dy)):
                lo_c = (lo_c[0] - dx, lo_c[1] - dy)
            while t.liquid((hi_c[0] + dx, hi_c[1] + dy)):
                hi_c = (hi_c[0] + dx, hi_c[1] + dy)
            key = (lo_c, dx)
            if key in tried:
                continue
            tried.add(key)
            width = (hi_c[0] - lo_c[0]) + (hi_c[1] - lo_c[1]) + 1
            if width < min_liquid or width > hi - 10:
                continue
            for back in range(3, 30):
                a = (lo_c[0] - dx * back, lo_c[1] - dy * back)
                if not t.land(a):
                    continue
                for fwd in range(3, 60):
                    b = (hi_c[0] + dx * fwd, hi_c[1] + dy * fwd)
                    span = abs(b[0] - a[0]) + abs(b[1] - a[1])
                    if span < lo:
                        continue
                    if span > hi:
                        break
                    if not t.land(b):
                        continue
                    searches += 1
                    if searches > MAX_PATH_SEARCHES:
                        return best
                    length = reachable(t, a, b)
                    if length is None:
                        continue
                    info = {"span": span, "liquid": width, "land_path": length, "near_ore": near_ore(t, a)}
                    if info["near_ore"]:
                        return a, b, info
                    if best is None:
                        best = (a, b, info)
                    break
        if best is not None and len(tried) > 400:
            return best      # у руды такой пары рядом нет — берём первую найденную
    return best


def find_free_square(t, origin, side):
    """Квадрат side × side свободной земли, ближайший к origin. → левая верхняя клетка | None."""
    cells = sorted((c for c in t.cells if t.ch(c) == "."),
                   key=lambda c: abs(c[0] - origin[0]) + abs(c[1] - origin[1]))
    bad = set()
    for c in cells[::7]:
        ok = True
        for dy in range(side):
            for dx in range(side):
                n = (c[0] + dx, c[1] + dy)
                if n in bad or t.ch(n) != ".":
                    bad.add(n)
                    ok = False
                    break
            if not ok:
                break
        if ok:
            return c
    return None


def find_island(t, origin, moat=MAX_UNDERGROUND, min_size=1, max_size=4000):
    """Остров: суша, со всех сторон окружённая жидкостью шире moat клеток (подземным не пройти),
    целиком внутри снятой местности. → (клетка свободной земли на острове, размер, клетка «большой
    земли» рядом с помощником) | None."""
    home = None
    for c in sorted(t.cells, key=lambda c: abs(c[0] - origin[0]) + abs(c[1] - origin[1])):
        if t.land(c):
            home = c
            break
    if home is None:
        return None
    mainland = component(home, t.passable)
    seen = set(mainland)
    candidates = sorted((c for c in t.cells if t.land(c) and c not in mainland),
                        key=lambda c: abs(c[0] - home[0]) + abs(c[1] - home[1]))
    for c in candidates:
        if c in seen:
            continue
        island = component(c, t.passable, limit=max_size + 1)
        seen |= island
        if len(island) < min_size or len(island) > max_size:
            continue
        closed = True
        for cell in island:
            for dx, dy in VEC.values():
                for k in range(1, moat + 1):
                    n = (cell[0] + dx * k, cell[1] + dy * k)
                    if n in island:
                        break
                    if not t.liquid(n):      # суша или неснятое ближе moat — не остров
                        closed = False
                        break
                if not closed:
                    break
            if not closed:
                break
        if closed:
            return c, len(island), home
    return None


# ---------------------------------------------------------------- призраки на карте

def area_of(cells, pad=1):
    xs = [c[0] for c in cells]
    ys = [c[1] for c in cells]
    return {"left_top": {"x": min(xs) - pad, "y": min(ys) - pad},
            "right_bottom": {"x": max(xs) + 1 + pad, "y": max(ys) + 1 + pad}}


def belt_ghosts(client, area, names):
    """Призраки лент и подземных конвейеров в области, как их видит игра (`map`).
    → ({клетка: {"name", "dir"}}, обрезано ли)."""
    out, truncated = {}, False
    step = 2 * MAP_WINDOW + 1
    x0, y0 = int(area["left_top"]["x"]), int(area["left_top"]["y"])
    x1, y1 = int(area["right_bottom"]["x"]), int(area["right_bottom"]["y"])
    y = y0
    while y <= y1:
        x = x0
        while x <= x1:
            c = {"x": x + MAP_WINDOW + 0.5, "y": y + MAP_WINDOW + 0.5}
            data = client.call_ok("map", {"center": c, "radius": MAP_WINDOW, "names": list(names)}, HELPER)
            truncated = truncated or bool(data.get("truncated"))
            for e in data.get("entities", []):
                if e.get("ghost") and e.get("name") in names:
                    cell = (int(e["pos"]["x"] // 1), int(e["pos"]["y"] // 1))
                    out[cell] = {"name": e["name"], "dir": e.get("dir")}
            x += step
        y += step
    return out, truncated


def snapshot(client, detail):
    """Призраки лент, которые уже стоят в области будущей ленты (detail — ответ сухого прогона):
    их сверка не считает. → {клетка: призрак}."""
    chosen = detail.get("chosen") or {}
    names = [n for n in (chosen.get("belt"), chosen.get("underground")) if n]
    if not detail.get("area") or not names:
        return {}
    return belt_ghosts(client, detail["area"], names)[0]


def follow(ghosts, start, underground=None, limit=20000):
    """Пройти цепочку призраков от клетки start: каждая следующая стоит по направлению предыдущей;
    после подземного конвейера — его пара дальше по той же линии.
    → (пройденные клетки, пары подземных [(вход, выход)], причина остановки | None)."""
    path, pairs = [], []
    cur = start
    seen = set()
    expect_exit = False
    while cur in ghosts and cur not in seen and len(path) < limit:
        seen.add(cur)
        path.append(cur)
        g = ghosts[cur]
        v = VEC.get(g["dir"])
        if v is None:
            return path, pairs, f"призрак {cur} смотрит в {g['dir']}"
        nxt = (cur[0] + v[0], cur[1] + v[1])
        if g["name"] == underground and not expect_exit:
            # вход: выход — следующий подземный конвейер на этой линии
            found = None
            for k in range(2, MAX_UNDERGROUND + 1):
                n = (cur[0] + v[0] * k, cur[1] + v[1] * k)
                if n in ghosts and ghosts[n]["name"] == underground and ghosts[n]["dir"] == g["dir"]:
                    found = n
                    break
            if found is None:
                return path, pairs, f"у подземного входа {cur} нет выхода на линии"
            pairs.append((cur, found))
            expect_exit = True
            cur = found
            continue
        expect_exit = False
        cur = nxt
    return path, pairs, None


def between(a, b):
    """Клетки строго между двумя клетками одной линии."""
    dx = (b[0] > a[0]) - (b[0] < a[0])
    dy = (b[1] > a[1]) - (b[1] < a[1])
    out = []
    cur = (a[0] + dx, a[1] + dy)
    while cur != b:
        out.append(cur)
        cur = (cur[0] + dx, cur[1] + dy)
    return out


def verify_chain(client, t, real, start, end, reasons, before=None):
    """Сверка одной проложенной ленты с игрой: призраков столько, сколько в ответе; цепочка от start
    непрерывна и приходит в end; ни одного призрака на жидкости; под землёй жидкости нет.
    → (сведения для отчёта, {клетка: призрак})."""
    detail = detail_of(real)
    chosen = detail.get("chosen") or {}
    names = [n for n in (chosen.get("belt"), chosen.get("underground")) if n]
    area = detail.get("area")
    if not area or not names:
        reasons.append(f"в ответе нет area или chosen: {detail}")
        return {}, {}
    ghosts, truncated = belt_ghosts(client, area, names)
    for cell in before or {}:
        ghosts.pop(cell, None)
    info = {"on_map": len(ghosts), "detail": detail.get("ghosts"), "truncated": truncated}
    if truncated:
        reasons.append("карта обрезала список призраков — сверка неполная")
    if len(ghosts) != detail.get("ghosts"):
        reasons.append(f"на карте {len(ghosts)} призраков ленты, в ответе {detail.get('ghosts')}")
    path, pairs, why = follow(ghosts, start, chosen.get("underground"))
    info.update(chain=len(path), undergrounds=len(pairs))
    if why:
        reasons.append(why)
    if len(path) != len(ghosts):
        reasons.append(f"цепочка от начала прошла {len(path)} призраков из {len(ghosts)} — лента рвётся "
                       f"у {path[-1] if path else start}")
    elif path and path[-1] != end:
        reasons.append(f"лента кончается в {path[-1]}, а не в {end}")
    wet = [c for c in ghosts if t.liquid(c)]
    info["on_liquid"] = len(wet)
    if wet:
        reasons.append(f"призраки на жидкости: {wet[:5]}")
    under = [c for a, b in pairs for c in between(a, b) if t.liquid(c)]
    info["under_liquid"] = len(under)
    if under:
        reasons.append(f"подземный участок под жидкостью: {under[:5]}")
    if len(pairs) != (detail.get("undergrounds") or 0):
        reasons.append(f"подземных пар на карте {len(pairs)}, в ответе {detail.get('undergrounds')}")
    info["pairs"] = [[list(a), list(b)] for a, b in pairs[:10]]
    return info, ghosts


def run(client) -> dict:
    return {"ok": False, "error": {"kind": "setup", "text": "_belt — общий модуль сценариев belt_*, не сценарий"}}
