-- Действие `plan_belt`: прокладка конвейера призраками от точки до точки в обход преград.
-- Контракт: docs/ACTIONS.md «plan_belt», PROTOCOL.md §6.5 (постановка призрака), §6.7 (открытые
-- чанки), §6.12 (свойства мира — из игры). Поиск пути — решатель мода Wuastbude Belt & Pipe Router
-- (MIT, scripts/vendor/router), слой игры — scripts/lib/beltpath.lua.
--
-- args: from: pos │ "patch" │ "resume", to: pos (у "resume" необязателен), belt?, lanes? = 1 (1..4), underground? = "auto" │ "never" │ "prefer",
--       start_direction?: "north" │ "east" │ "south" │ "west", dry_run?
-- done.detail: {ghosts, length, undergrounds, turns, need, area, areas?, path, warnings, lanes,
--               chosen = {belt, underground?}, skipped?, dry_run?, resumed? = {built, removed, rotate?}}
-- failed: bad_args, limit (дальше 512 клеток, больше 16 выходов разметки), not_found (нет разметки
--         для "patch"), not_charted, cannot_place (начало или конец на плитке без опоры; ни один
--         призрак не встал), path_failed (пути нет или кончился бюджет поиска; detail.reached).
--
-- Тело помощника никуда не идёт: это разметка на карте, как рамка у игрока. Работа идёт по тикам:
--   search — поиск путей (WORK_PER_TICK единиц работы решателя за тик, общий бюджет на задачу);
--   scan   — предупреждения (узкие места, враги рядом);
--   place  — постановка призраков пачками.
-- Ни один призрак не ставится, пока не найдены все пути. Состояние — в task.belt (переживает сохранение).
--
-- Несколько лент (`lanes`):
--   * от точки — сначала ищется путь одной ленты. Если он без подземных участков и рядом с ним есть
--     место, остальные ленты кладутся пачкой вдоль него (квадрат lanes×lanes растёт от клетки пути в
--     сторону +x и +y). Нет места — ищется опорный путь с запасом lanes×lanes клеток, пачка кладётся
--     по нему. Не складывается и так (тесные развороты, широкого прохода нет, путь идёт под землёй) —
--     ленты ищутся по одной, каждая справа от первой (предупреждение `not_bundled`);
--   * от разметки ("patch") — выходы делятся на `lanes` соседних групп; у группы одна лента идёт до
--     цели, остальные выходы группы вливаются в неё сбоку у пятна.
--
-- Перекладка (`from = "resume"`, docs/ACTIONS.md («plan_belt»)): «планируем по карте, на месте
-- перепроверяем». Удачный план запоминается в storage.belt_last[helper] (клетки по лентам, ≤ 4096).
-- Перекладка берёт его и по каждой ленте:
--   * построенная часть — непрерывный ряд клеток от начала ленты, где уже стоит настоящая лента;
--     её конец — новое начало. Если следующая за ним клетка по ходу свободна, поиск идёт от неё
--     (построенная лента смотрит прямо в новую); иначе — от самой построенной клетки, и если путь
--     от неё поворачивает, клетка попадает в `resumed.rotate` (построенную ленту план не трогает);
--   * подземная пара, у которой построен только вход: призрак выхода на месте — он остаётся, пара
--     достраивается, путь идёт от выхода; призрака выхода нет — путь идёт от клетки перед парой
--     (предупреждение `dangling_underground:N`: построенный вход остался вне пути);
--   * свои призраки лент на остальных клетках плана убираются, пометки к сносу, поставленные планом
--     на этих клетках, снимаются; чужие призраки, призраки других построек и постройки не трогаются;
--   * клетки плана, построенные не подряд (дальше разрыва), остаются стоять и для нового пути —
--     обычная помеха (предупреждение `built_apart:N`).
-- Память после перекладки — построенная часть + новый путь (перекладывать можно снова).
local beltpath = require("scripts.lib.beltpath")
local vis = require("scripts.core.vis")

local perms = require("scripts.core.perms")

local M = {}
M.name = "plan_belt"

--- Разрешения хозяина (scripts/core/perms.lua): какие ключи задевают эти аргументы.
function M.perms(a, ctx)
  if a.dry_run then return {} end
  return { "perm-build" }
end
M.schema = {
  from = { type = { "pos", "string" }, values = { "patch", "resume" }, required = true },
  to = { type = "pos" },                         -- обязателен, кроме from = "resume"
  belt = { type = "string", max = 100 },
  lanes = { type = "int", min = 1, max = 4 },    -- по умолчанию 1 (у "resume" — как в плане)
  underground = { type = "enum", values = { "auto", "never", "prefer" } }, -- по умолчанию "auto"
  start_direction = { type = "enum", values = { "north", "east", "south", "west" } },
  dry_run = { type = "bool" },
}

M.MAX_REMEMBERED = 4096       -- клеток плана в storage.belt_last (PROTOCOL §7)

M.MAX_DISTANCE = 512          -- по прямой от начала до конца (ACTIONS.md)
M.MAX_OUTPUTS = 16            -- выходов разметки на одну задачу
M.WORK_PER_TICK = 256         -- единиц работы решателя за тик
M.BASE_EXPANSIONS = 20000     -- бюджет одного поиска: BASE + PER_TILE × расстояние
M.EXPANSIONS_PER_TILE = 100
M.TASK_BUDGETS = 4            -- на всю задачу (все ленты и притоки) — не больше стольких бюджетов поиска
M.SCAN_PER_TICK = 32
M.PLACE_PER_TICK = 50
M.MAX_TICKS = 60 * 60 * 2     -- две минуты — заведомо сбой
M.MAX_CORNERS = 40
M.MAX_AREA_SIDE = 128
M.ENEMY_RADIUS = 32
M.ENEMY_EVERY = 16            -- врагов ищем у каждой 16-й клетки пути
M.FEEDER_TRIES = 3
M.FEEDER_WINDOW = 48          -- вливаться не дальше стольких клеток от начала ленты группы
M.CONFLICT_RETRIES = 3

local floor, abs, min, max = math.floor, math.abs, math.min, math.max
local VEC = beltpath.VEC

local function failed(code, text, detail)
  return { status = "failed", code = code, text = text, detail = detail or {} }
end

local function center(c) return { x = c.x + 0.5, y = c.y + 0.5 } end

local function right_of(dir)
  local v = VEC[dir]
  return -v[2], v[1]
end

local function dir_from(dx, dy)
  if abs(dx) >= abs(dy) then return dx >= 0 and 4 or 12 end
  return dy >= 0 and 8 or 0
end

local function norm_dir(d)
  if type(d) == "string" then return beltpath.DIR_NAMES[d] end
  if d == 0 or d == 4 or d == 8 or d == 12 then return d end
  return nil
end

-- ------------------------------------------------------------------ начало

--- Выходы последней разметки помощника → список {x, y, direction?} │ nil, code, text.
local function patch_outputs(helper_id, surface)
  local all = storage.mining_last
  local rec = type(all) == "table" and all[helper_id] or nil
  if type(rec) ~= "table" or type(rec.outputs) ~= "table" or #rec.outputs == 0 then
    return nil, "not_found", "no mining layout of this helper: run plan_mining first or give args.from as a position"
  end
  local s = rec.surface
  if type(s) == "table" then s = s.index end
  if s ~= nil and s ~= surface.index and s ~= surface.name then
    return nil, "not_found", "the last mining layout is on another surface"
  end
  if #rec.outputs > M.MAX_OUTPUTS then
    return nil, "limit", "the mining layout has more than " .. M.MAX_OUTPUTS .. " outputs, give args.from as a position"
  end
  local out, seen = {}, {}
  for _, o in ipairs(rec.outputs) do
    local p = type(o) == "table" and o.pos or nil
    if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
      local x, y = floor(p.x), floor(p.y)
      local k = beltpath.key(x, y)
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = { x = x, y = y, direction = norm_dir(o.direction) }
      end
    end
  end
  if #out == 0 then return nil, "not_found", "the last mining layout has no outputs" end
  return out
end

--- Группы выходов → ленты до цели (trunks) с вливающимися выходами (feeders).
local function group_outputs(outputs, to, lanes)
  local cx, cy = 0, 0
  for _, o in ipairs(outputs) do cx, cy = cx + o.x, cy + o.y end
  cx, cy = cx / #outputs, cy / #outputs
  local heading = dir_from(to.x - cx, to.y - cy)
  local rx, ry = right_of(heading)
  table.sort(outputs, function(a, b)
    local pa, pb = a.x * rx + a.y * ry, b.x * rx + b.y * ry
    if pa ~= pb then return pa < pb end
    if a.x ~= b.x then return a.x < b.x end
    return a.y < b.y
  end)
  local n = min(lanes, #outputs)
  local trunks = {}
  local i = 1
  for g = 1, n do
    local size = floor((#outputs - i + 1) / (n - g + 1) + 0.5)
    if size < 1 then size = 1 end
    local best, best_d
    for j = i, i + size - 1 do
      local o = outputs[j]
      local d = abs(o.x - to.x) + abs(o.y - to.y)
      if best == nil or d < best_d then best, best_d = j, d end
    end
    local trunk = { start = outputs[best], feeders = {} }
    for j = i, i + size - 1 do
      if j ~= best then trunk.feeders[#trunk.feeders + 1] = outputs[j] end
    end
    trunks[#trunks + 1] = trunk
    i = i + size
  end
  return trunks
end

--- Подземный конвейер для ленты belt в режиме mode │ nil (не нужен, нет или не исследован).
local function pick_under(force, belt, mode, warnings)
  if mode == "never" then return nil end
  local up = prototypes.entity[belt].related_underground_belt
  if up == nil then return nil end
  if beltpath.unlocked(force, up.name) then return up.name end
  if mode == "prefer" then
    warnings[#warnings + 1] = "not_researched:" .. up.name
    return up.name
  end
  return nil
end

-- ------------------------------------------------------------------ перекладка: память и начало

local function cell_ok(c)
  return type(c) == "table" and type(c.x) == "number" and type(c.y) == "number"
end

--- Запись плана цела? (storage переживает версии мода: читаем осторожно.)
local function plan_ok(rec)
  if type(rec) ~= "table" or type(rec.cells) ~= "table" or type(rec.ends) ~= "table" then return false end
  if not cell_ok(rec.to) or type(rec.belt) ~= "string" then return false end
  local total = 0
  for li, cells in ipairs(rec.cells) do
    local e = rec.ends[li]
    if type(cells) ~= "table" or type(e) ~= "table" or not cell_ok(e.start) or not cell_ok(e.goal) then return false end
    for _, c in ipairs(cells) do
      if not cell_ok(c) or VEC[c.d] == nil then return false end
    end
    total = total + #cells
  end
  return #rec.cells > 0 and total <= M.MAX_REMEMBERED
end

--- plan_belt{from = "resume"}: разобрать запомненный план, убрать недостроенное, подготовить поиск.
local function start_resume(task, ctx)
  local a = task.args
  local h = ctx.entity
  local surface, force = h.surface, h.force
  local all = storage.belt_last
  local rec = type(all) == "table" and all[ctx.helper_id] or nil
  if not plan_ok(rec) then
    return failed("bad_args", 'args.from "resume": this helper has no remembered belt plan (run plan_belt first)')
  end
  if rec.surface_index ~= surface.index then
    return failed("bad_args", 'args.from "resume": the remembered belt plan is on another surface')
  end
  local to = { x = floor(rec.to.x), y = floor(rec.to.y) }
  if a.to ~= nil and (floor(a.to.x) ~= to.x or floor(a.to.y) ~= to.y) then
    return failed("bad_args", 'args.to differs from the remembered plan (omit it with from "resume")')
  end
  if a.belt ~= nil and a.belt ~= rec.belt then
    return failed("bad_args", 'args.belt differs from the remembered plan (omit it with from "resume")')
  end
  if a.lanes ~= nil and a.lanes ~= rec.lanes then
    return failed("bad_args", 'args.lanes differs from the remembered plan (omit it with from "resume")')
  end
  local proto = prototypes.entity[rec.belt]
  if proto == nil or proto.type ~= "transport-belt" then
    return failed("bad_args", 'args.from "resume": the belt of the remembered plan no longer exists')
  end

  local warnings = {}
  local mode = a.underground or rec.underground or "auto"
  local under = pick_under(force, rec.belt, mode, warnings)
  local W = beltpath.new_world(rec.belt, under)
  local env = beltpath.env(W, surface, force)
  local dry = a.dry_run and true or false
  local built, removed, apart, dangling = 0, 0, 0, 0
  local kept, trunks, trunk_of, pending, heads = {}, {}, {}, {}, {}

  for li, cells in ipairs(rec.cells) do
    local e = rec.ends[li]
    local n = #cells
    local L = 0 -- построенная часть: клетки 1..L
    while L < n and beltpath.built_at(env, cells[L + 1].x, cells[L + 1].y, cells[L + 1].u ~= nil) do L = L + 1 end
    built = built + L
    local keep = L -- клетки 1..keep остаются в плане
    if L > 0 and L < n and cells[L].u == "input" then
      -- построен только вход подземной пары
      local out = cells[L + 1]
      if out.u == "output" and beltpath.own_ghost(env, out.x, out.y, true) ~= nil then
        keep = L + 1 -- призрак выхода на месте: пара достраивается
      else
        keep = L - 1
        dangling = dangling + 1
      end
    end
    for i = max(keep, L) + 1, n do
      local c = cells[i]
      if beltpath.built_at(env, c.x, c.y, c.u ~= nil) then
        apart = apart + 1
      elseif dry then
        if beltpath.own_ghost(env, c.x, c.y, c.u ~= nil) ~= nil then
          removed = removed + 1
          beltpath.assume_free(env, c.x, c.y, c.n)
        end
      else
        if beltpath.remove_ghost(env, c.x, c.y, c.u ~= nil) then removed = removed + 1 end
        if c.n then beltpath.unmark(env, c.x, c.y) end
      end
    end
    kept[li] = {}
    for i = 1, keep do kept[li][i] = cells[i] end

    -- (e.open — прошлая перекладка оборвала эту ленту и пути не нашла: в памяти только построенное)
    local done = keep >= n and not e.open
    if not done and not dry then e.open = true end
    local start
    if keep == 0 then
      start = { x = floor(e.start.x), y = floor(e.start.y), direction = norm_dir(e.start.direction) }
    else
      -- built — куда смотрит построенная лента; направление начала решателю не задаём: оно для
      -- него жёсткое (первый шаг только туда), а путь от свободной клетки волен повернуть сразу
      start = { x = cells[keep].x, y = cells[keep].y, built = cells[keep].d }
    end
    local goal = { x = floor(e.goal.x), y = floor(e.goal.y), direction = norm_dir(e.goal.direction) }
    if e.feeder == nil then
      trunks[#trunks + 1] = { start = start, goal = goal, feeders = {}, lane = li, done = done }
      trunk_of[li] = #trunks
      if not done then heads[#heads + 1] = { start = start, goal = goal } end
    elseif not done then
      start.lane = li
      start.old_goal = { x = goal.x, y = goal.y, final_dir = norm_dir(e.final_dir) }
      pending[#pending + 1] = { start = start, group = e.feeder }
      heads[#heads + 1] = { start = start, goal = goal }
    end
  end
  for _, p in ipairs(pending) do
    local g = trunk_of[p.group]
    if g ~= nil then
      local list = trunks[g].feeders
      list[#list + 1] = p.start
    end
  end

  -- построенная лента смотрит в следующую клетку: если она свободна, новый путь начинается с неё
  local far = 0
  local x1, y1, x2, y2 = to.x, to.y, to.x, to.y
  for _, hd in ipairs(heads) do
    local s, g = hd.start, hd.goal
    if s.built then
      local v = VEC[s.built]
      local ax, ay = s.x + v[1], s.y + v[2]
      if not (ax == g.x and ay == g.y) and beltpath.cell(env, ax, ay) > 0 then
        s.x, s.y, s.built = ax, ay, nil
      end
    end
    far = max(far, abs(s.x - g.x) + abs(s.y - g.y))
    x1, y1, x2, y2 = min(x1, s.x, g.x), min(y1, s.y, g.y), max(x2, s.x, g.x), max(y2, s.y, g.y)
  end
  local margin = 48 + floor(far / 4)

  if not dry then
    -- память сразу сходится с миром: в плане осталась только построенная часть
    rec.cells = kept
    rec.tick = ctx.tick
  end
  if apart > 0 then warnings[#warnings + 1] = "built_apart:" .. apart end
  if dangling > 0 then warnings[#warnings + 1] = "dangling_underground:" .. dangling end

  task.belt = {
    W = W,
    mode = under and mode or "never",
    umode = mode,
    dry = dry,
    lanes = rec.lanes,
    to = to,
    bounds = { min_x = x1 - margin, min_y = y1 - margin, max_x = x2 + margin, max_y = y2 + margin },
    stage = "search",
    routes = {},
    warnings = warnings,
    expansions = 0,
    total = M.TASK_BUDGETS * (M.BASE_EXPANSIONS + M.EXPANSIONS_PER_TILE * far),
    ticks = 0,
    phase = "trunk",
    trunks = trunks,
    ti = 1, fi = 1,
    resumed = { built = built, removed = removed },
  }
  task.progress_tick = ctx.tick
  return nil
end

function M.start(task, ctx)
  local a = task.args
  if a.from == "resume" then return start_resume(task, ctx) end
  if a.to == nil then return failed("bad_args", "args.to: required") end
  a.lanes = a.lanes or 1
  a.underground = a.underground or "auto"
  local h = ctx.entity
  local surface, force = h.surface, h.force
  local to = { x = floor(a.to.x), y = floor(a.to.y) }
  local start_dir = a.start_direction and beltpath.DIR_NAMES[a.start_direction] or nil

  local starts, code, text
  local from_patch = a.from == "patch"
  if from_patch then
    starts, code, text = patch_outputs(ctx.helper_id, surface)
    if starts == nil then return failed(code, text) end
  else
    starts = { { x = floor(a.from.x), y = floor(a.from.y), direction = start_dir } }
  end

  -- расстояние, открытые чанки, рамка поиска
  local far = 0
  local x1, y1, x2, y2 = to.x, to.y, to.x, to.y
  local function is_charted(c)
    return force.is_chunk_charted(surface, { x = floor(c.x / 32), y = floor(c.y / 32) })
  end
  if not is_charted(to) then return failed("not_charted", "args.to is not charted") end
  for _, s in ipairs(starts) do
    local dx, dy = s.x - to.x, s.y - to.y
    if dx == 0 and dy == 0 then return failed("bad_args", "args.from and args.to are the same tile") end
    if dx * dx + dy * dy > M.MAX_DISTANCE * M.MAX_DISTANCE then
      return failed("limit", "args.to is farther than " .. M.MAX_DISTANCE .. " tiles from the start")
    end
    if not is_charted(s) then return failed("not_charted", "the start is not charted") end
    far = max(far, abs(dx) + abs(dy))
    x1, y1, x2, y2 = min(x1, s.x), min(y1, s.y), max(x2, s.x), max(y2, s.y)
  end
  local margin = 48 + floor(far / 4)

  -- лента: названная, иначе та, что уже стоит в начале, иначе лучшая из открытого
  local probe = { surface = surface, force = force }
  local belt = a.belt
  if belt ~= nil then
    local proto = prototypes.entity[belt]
    if proto == nil or proto.type ~= "transport-belt" then
      return failed("bad_args", "args.belt: " .. belt .. " is not a transport belt")
    end
  end
  for _, s in ipairs(starts) do
    local name, dir = beltpath.belt_at(probe, s.x, s.y)
    if name ~= nil then
      belt = belt or name
      if s.direction == nil then s.direction = norm_dir(dir) end
    end
  end
  belt = belt or beltpath.default_belt(force)
  if belt == nil then return failed("bad_args", "no transport belt is researched, set args.belt") end

  local warnings = {}
  local under = pick_under(force, belt, a.underground, warnings)

  local B = {
    W = beltpath.new_world(belt, under),
    mode = under and a.underground or "never",
    umode = a.underground,
    dry = a.dry_run and true or false,
    lanes = a.lanes,
    to = to,
    bounds = { min_x = x1 - margin, min_y = y1 - margin, max_x = x2 + margin, max_y = y2 + margin },
    stage = "search",
    routes = {},       -- найденные ленты: {steps, stats, feeder?}
    warnings = warnings,
    expansions = 0,
    total = M.TASK_BUDGETS * (M.BASE_EXPANSIONS + M.EXPANSIONS_PER_TILE * far),
    ticks = 0,
  }
  if from_patch then
    B.phase = "trunk"
    B.trunks = group_outputs(starts, to, a.lanes)
  elseif a.lanes > 1 then
    B.phase = "trunk"
    B.origin = starts[1]
    B.trunks = { { start = starts[1], feeders = {} } }
    B.bundle = true -- первая найденная лента — проба для пачки
  else
    B.phase = "trunk"
    B.trunks = { { start = starts[1], feeders = {} } }
  end
  B.ti, B.fi = 1, 1
  task.belt = B
  task.progress_tick = ctx.tick
  return nil
end

-- ------------------------------------------------------------------ поиск

local END_TEXT = {
  [beltpath.TILE] = "is on a tile where a belt cannot stand",
  [beltpath.UNCHARTED] = "is not charted",
  [beltpath.PLANNED] = "is taken by another belt of this plan",
}

--- Запустить поиск по заданию spec = {start, goal, kind, clearance?, final_dir?}. → nil │ result (ошибка).
local function launch(B, env, spec, retries)
  local s, g = spec.start, spec.goal
  if s.x == g.x and s.y == g.y then
    return failed("path_failed", "the start and the end of a belt are the same tile",
      { reason = "unreachable", reached = center(s), left = 0, expanded = B.expansions })
  end
  local sc, gc = beltpath.cell(env, s.x, s.y), beltpath.cell(env, g.x, g.y)
  if END_TEXT[sc] then
    return failed(sc == beltpath.UNCHARTED and "not_charted" or "cannot_place", "the start " .. END_TEXT[sc],
      { pos = center(s) })
  end
  if END_TEXT[gc] then
    return failed(gc == beltpath.UNCHARTED and "not_charted" or "cannot_place", "the end " .. END_TEXT[gc],
      { pos = center(g) })
  end
  local left = B.total - B.expansions
  if left < 1 then
    return failed("path_failed", "the search budget of the task is exhausted",
      { reason = "budget", expanded = B.expansions, reached = center(s) })
  end
  local dist = abs(s.x - g.x) + abs(s.y - g.y)
  B.job = {
    kind = spec.kind,
    start = { x = s.x, y = s.y, direction = s.direction },
    goal = { x = g.x, y = g.y, direction = g.direction },
    underground = B.mode,
    clearance = spec.clearance,
    final_dir = spec.final_dir,
    skip_first = sc == beltpath.ENTITY, -- там уже что-то стоит (конец ленты): ведём от него
    skip_last = gc == beltpath.ENTITY,  -- там уже что-то стоит (лента, сундук): ведём до него
    retries = retries or 0,
  }
  local budget = min(M.BASE_EXPANSIONS + M.EXPANSIONS_PER_TILE * dist, left)
  B.search = beltpath.new_search(B.W, B.job, budget, B.bounds)
  return nil
end

local function point(p)
  return { x = p.x, y = p.y, direction = p.direction }
end

--- meta = {start, goal, final_dir?, group?, lane?}: концы ленты — для памяти плана (перекладка).
local function add_route(B, steps, stats, meta)
  beltpath.commit(B.W, steps)
  B.routes[#B.routes + 1] = {
    steps = steps, stats = stats,
    start = point(meta.start), goal = point(meta.goal),
    final_dir = meta.final_dir, group = meta.group, lane = meta.lane,
  }
  return #B.routes
end

--- Перекладка: путь начался от построенной ленты (start.built) и сразу повернул — эту ленту надо
--- повернуть руками (план построенное не трогает).
local function note_turn(B, start, route)
  local first = route.edges[1]
  if start.built and first ~= nil and first.direction ~= start.built then
    B.rotate = B.rotate or {}
    B.rotate[#B.rotate + 1] = { pos = center(start), direction = first.direction }
  end
end

--- Пачка не сложилась: проба становится первой лентой, остальные ищутся по одной справа от неё.
local function split_lanes(B)
  local p = B.probe
  local route = p.route
  local o = B.origin
  local heading = route.edges[1].direction
  local rx, ry = right_of(heading)
  B.trunks = {}
  for i = 0, B.lanes - 1 do
    B.trunks[#B.trunks + 1] = {
      start = { x = o.x + rx * i, y = o.y + ry * i, direction = i == 0 and o.direction or heading },
      feeders = {},
    }
  end
  local steps, stats = beltpath.route_steps(B.W, route, { skip_first = p.skip_first, skip_last = p.skip_last })
  B.trunks[1].route = add_route(B, steps, stats, { start = o, goal = B.to })
  B.arrival = route.edges[#route.edges].direction
  B.phase, B.ti, B.probe = "trunk", 2, nil
  B.warnings[#B.warnings + 1] = "not_bundled"
end

--- Куда может влиться выход feeder: клетки рядом с лентами его группы (лента до цели и уже влитые
--- выходы), ближние первыми. Сбоку от прямой ленты — боковая загрузка; сзади угловой ленты — она
--- становится прямой, а прежний вход остаётся боковым.
local function feeder_goals(B, env, feeder)
  local out = {}
  local function offer(x, y, final_dir)
    if beltpath.cell(env, x, y) > 0 then
      out[#out + 1] = {
        x = x, y = y, final_dir = final_dir,
        d = abs(feeder.start.x - x) + abs(feeder.start.y - y),
      }
    end
  end
  for _, index in ipairs(B.trunks[feeder.group].routes) do
    local steps = B.routes[index].steps
    for i = 2, min(#steps - 1, M.FEEDER_WINDOW) do
      local s, prev = steps[i], steps[i - 1]
      if s.utype == nil and (prev.utype == nil or prev.utype == "output") then
        if prev.dir == s.dir then
          local rx, ry = right_of(s.dir)
          for side = -1, 1, 2 do
            offer(s.x + rx * side, s.y + ry * side, dir_from(-rx * side, -ry * side))
          end
        else
          local v = VEC[s.dir]
          offer(s.x - v[1], s.y - v[2], s.dir)
        end
      end
    end
  end
  table.sort(out, function(p, q)
    if p.d ~= q.d then return p.d < q.d end
    if p.x ~= q.x then return p.x < q.x end
    return p.y < q.y
  end)
  for i = #out, M.FEEDER_TRIES + 1, -1 do out[i] = nil end
  -- перекладка: последним — прежнее место вливания (лента группы могла не меняться)
  local old = feeder.start.old_goal
  if old ~= nil and beltpath.cell(env, old.x, old.y) > 0 then
    out[#out + 1] = { x = old.x, y = old.y, final_dir = old.final_dir }
  end
  return out
end

--- Выбрать следующее задание. → nil │ result; когда заданий больше нет — B.stage = "scan".
local function next_job(B, env)
  if B.phase == "corridor" then
    if launch(B, env, { kind = "corridor", start = B.origin, goal = B.to, clearance = B.lanes }) == nil then
      return nil
    end
    split_lanes(B) -- широкий проход искать не на что: ленты по одной
  end
  if B.phase == "trunk" then
    local trunk = B.trunks[B.ti]
    while trunk ~= nil and trunk.done do -- перекладка: эта лента уже построена целиком
      B.ti = B.ti + 1
      trunk = B.trunks[B.ti]
    end
    if trunk ~= nil then
      local goal = { x = B.to.x, y = B.to.y }
      if trunk.goal ~= nil then
        goal = trunk.goal -- перекладка: цель каждой ленты — как в плане
      elseif B.ti > 1 then
        -- следующие ленты приходят к цели так же, как первая, и встают справа от неё
        local rx, ry = right_of(B.arrival)
        goal = { x = B.to.x + rx * (B.ti - 1), y = B.to.y + ry * (B.ti - 1), direction = B.arrival }
      end
      return launch(B, env, { kind = "trunk", start = trunk.start, goal = goal })
    end
    -- все ленты до цели найдены: выходы, которые в них вливаются
    B.feeders = {}
    for gi, t in ipairs(B.trunks) do
      t.routes = { t.route }
      -- ближние к ленте группы выходы — первыми: дальние вольются уже в них
      table.sort(t.feeders, function(p, q)
        local dp = abs(p.x - t.start.x) + abs(p.y - t.start.y)
        local dq = abs(q.x - t.start.x) + abs(q.y - t.start.y)
        if dp ~= dq then return dp < dq end
        if p.x ~= q.x then return p.x < q.x end
        return p.y < q.y
      end)
      for _, f in ipairs(t.feeders) do B.feeders[#B.feeders + 1] = { start = f, group = gi } end
    end
    B.phase, B.fi = "feeder", 1
  end
  if B.phase == "feeder" then
    while true do
      local f = B.feeders[B.fi]
      if f == nil then break end
      if f.goals == nil then f.goals, f.gi = feeder_goals(B, env, f), 1 end
      local g = f.goals[f.gi]
      if g ~= nil then
        local r = launch(B, env, {
          kind = "feeder", start = f.start, goal = { x = g.x, y = g.y }, final_dir = g.final_dir,
        })
        if r == nil then return nil end
        f.gi = f.gi + 1 -- это место не годится — следующее
      else
        B.unmerged = (B.unmerged or 0) + 1
        B.fi = B.fi + 1
      end
    end
  end
  B.stage, B.job, B.search = "scan", nil, nil
  return nil
end

--- Опорный путь найден: сложить пачку. → true, если сложилась.
local function bundle(B, env, route)
  local lanes = beltpath.derive_lanes(route, B.lanes)
  if lanes == nil then return false end
  local plans = {}
  for _, lane in ipairs(lanes) do
    local n = #lane.nodes
    local opts = {}
    for i, node in ipairs(lane.nodes) do
      local c = beltpath.cell(env, node.x, node.y)
      if c <= 0 then
        if c == beltpath.ENTITY and i == 1 then
          opts.skip_first = true
        elseif c == beltpath.ENTITY and i == n then
          opts.skip_last = true
        else
          return false
        end
      end
    end
    plans[#plans + 1] = { lane = lane, opts = opts }
  end
  for _, p in ipairs(plans) do
    local steps, stats = beltpath.route_steps(B.W, p.lane, p.opts)
    local nodes, first = p.lane.nodes, p.lane.edges[1]
    add_route(B, steps, stats, {
      start = { x = nodes[1].x, y = nodes[1].y, direction = first and first.direction or nil },
      goal = { x = nodes[#nodes].x, y = nodes[#nodes].y },
    })
  end
  return true
end

local function on_result(B, env, status, route)
  local job = B.job
  local kind = job.kind
  if status == "found" and beltpath.reject_conflict(B.W, route) then
    -- два своих подземных участка легли на одну линию: второй запрещён, ищем заново
    if job.retries < M.CONFLICT_RETRIES then
      return launch(B, env, {
        kind = kind, start = job.start, goal = job.goal, clearance = job.clearance, final_dir = job.final_dir,
      }, job.retries + 1)
    end
    status = "unreachable"
  end

  if kind == "corridor" then
    -- широкий обход годится, только если он не намного длиннее пути одной ленты
    local fits = status == "found" and #route.edges <= 1.5 * B.probe.length + 8
    if fits and bundle(B, env, route) then
      B.stage, B.job, B.probe = "scan", nil, nil
    else
      split_lanes(B)
    end
    return nil
  end

  if kind == "trunk" then
    if status ~= "found" then
      local reached = job.reached or job.start
      return failed("path_failed", "no belt path to the target (" .. status .. ")", {
        reached = center(reached),
        left = abs(reached.x - job.goal.x) + abs(reached.y - job.goal.y),
        expanded = B.expansions,
        lane = B.ti,
        reason = status == "limit" and "budget" or "unreachable",
      })
    end
    local steps, stats = beltpath.route_steps(B.W, route, { skip_first = job.skip_first, skip_last = job.skip_last })
    if B.bundle then
      -- несколько лент от точки: сначала пробуем положить пачку вдоль найденного пути
      B.bundle = nil
      if stats.undergrounds == 0 and bundle(B, env, route) then
        B.stage, B.job = "scan", nil
        return nil
      end
      B.probe = { route = route, skip_first = job.skip_first, skip_last = job.skip_last, length = stats.length }
      if stats.undergrounds == 0 then
        B.phase = "corridor"
      else
        split_lanes(B)
      end
      return nil
    end
    local trunk = B.trunks[B.ti]
    note_turn(B, trunk.start, route)
    trunk.route = add_route(B, steps, stats, { start = job.start, goal = job.goal, lane = trunk.lane })
    if B.ti == 1 then
      local last = route.edges[#route.edges]
      B.arrival = last and last.direction or job.start.direction or dir_from(B.to.x - job.start.x, B.to.y - job.start.y)
    end
    B.ti = B.ti + 1
    return nil
  end

  -- feeder
  local f = B.feeders[B.fi]
  if status == "found" then
    local steps, stats = beltpath.route_steps(B.W, route, { skip_first = job.skip_first, final_dir = job.final_dir })
    note_turn(B, f.start, route)
    local index = add_route(B, steps, stats, {
      start = job.start, goal = job.goal, final_dir = job.final_dir, group = f.group, lane = f.start.lane,
    })
    B.routes[index].feeder = true
    local routes = B.trunks[f.group].routes
    routes[#routes + 1] = index
    B.merged = (B.merged or 0) + 1
    B.fi = B.fi + 1
  else
    f.gi = f.gi + 1
  end
  return nil
end

local function search_tick(B, env)
  if B.search == nil then
    local r = next_job(B, env)
    if r ~= nil then return r end
    if B.search == nil then return nil end
  end
  local status, route = beltpath.step(B.search, env, B.job, M.WORK_PER_TICK)
  if status == "running" then return nil end
  B.expansions = B.expansions + (B.search.expansions or 0)
  B.search = nil
  return on_result(B, env, status, route)
end

-- ------------------------------------------------------------------ предупреждения

local function enemy_forces(force)
  local out = {}
  for name, f in pairs(game.forces) do
    if name ~= force.name and name ~= "neutral" and force.is_enemy(f) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function scan_tick(B, env, ctx)
  if B.flat == nil then
    -- все шаги всех лент одним списком: по нему идут и проверки, и постановка
    B.flat = {}
    for _, r in ipairs(B.routes) do
      for _, s in ipairs(r.steps) do B.flat[#B.flat + 1] = s end
    end
    B.scan_i = 1
  end
  local enemies
  local last = min(#B.flat, B.scan_i + M.SCAN_PER_TICK - 1)
  for i = B.scan_i, last do
    local s = B.flat[i]
    if beltpath.unseen(env, s.x, s.y) then B.unseen = (B.unseen or 0) + 1 end
    if not B.narrow and s.utype == nil and beltpath.width_at(env, s) <= 2 then B.narrow = true end
    if not B.near_enemy and (i - 1) % M.ENEMY_EVERY == 0 then
      enemies = enemies or enemy_forces(env.force)
      if #enemies > 0 then
        local found = env.surface.find_entities_filtered{
          position = center(s), radius = M.ENEMY_RADIUS, force = enemies, is_military_target = true, limit = 20,
        }
        for _, e in ipairs(found) do
          if e.valid and vis.visible(ctx.helper_id, env.surface, e.position) then
            B.near_enemy = true
            break
          end
        end
      end
    end
  end
  B.scan_i = last + 1
  if B.scan_i > #B.flat then
    B.stage, B.place_i = "place", 1
    B.placed, B.skipped, B.marked, B.need = 0, 0, 0, {}
  end
  return nil
end

-- ------------------------------------------------------------------ постановка и итог

local function grow(box, x, y)
  if box.x1 == nil then
    box.x1, box.y1, box.x2, box.y2 = x, y, x + 1, y + 1
    return
  end
  box.x1, box.y1 = min(box.x1, x), min(box.y1, y)
  box.x2, box.y2 = max(box.x2, x + 1), max(box.y2, y + 1)
end

local function as_area(box)
  return { left_top = { x = box.x1, y = box.y1 }, right_bottom = { x = box.x2, y = box.y2 } }
end

local function detail_of(B)
  local first = B.routes[1]
  local stats = first and first.stats or { length = 0, turns = 0, corners = {} }
  local undergrounds = 0
  for _, r in ipairs(B.routes) do undergrounds = undergrounds + r.stats.undergrounds end

  local path = {}
  local corners = stats.corners
  for i, c in ipairs(corners) do
    if i < M.MAX_CORNERS or i == #corners then path[#path + 1] = center(c) end
  end

  local warnings = B.warnings
  local start = corners[1]
  local finish = corners[#corners]
  if start and finish and stats.length > 2 * (abs(start.x - finish.x) + abs(start.y - finish.y) + 1) then
    warnings[#warnings + 1] = "long_detour"
  end
  if B.narrow then warnings[#warnings + 1] = "narrow" end
  if B.near_enemy then warnings[#warnings + 1] = "near_enemy" end
  if B.marked > 0 then warnings[#warnings + 1] = "marked_for_deconstruction:" .. B.marked end
  if B.skipped > 0 then warnings[#warnings + 1] = "skipped:" .. B.skipped end
  if (B.unmerged or 0) > 0 then warnings[#warnings + 1] = "unmerged_outputs:" .. B.unmerged end
  if (B.unseen or 0) > 0 then warnings[#warnings + 1] = "unseen:" .. B.unseen end
  if B.rotate ~= nil then warnings[#warnings + 1] = "rotate_needed:" .. #B.rotate end

  local lanes = 0
  for _, r in ipairs(B.routes) do
    if not r.feeder then lanes = lanes + 1 end
  end
  local d = {
    ghosts = B.placed,
    length = stats.length,
    undergrounds = undergrounds,
    turns = stats.turns,
    need = B.need,
    path = path,
    warnings = warnings,
    lanes = lanes,
    chosen = { belt = B.W.belt, underground = B.W.under },
    dry_run = B.dry or nil,
  }
  if B.resumed ~= nil then
    d.resumed = { built = B.resumed.built, removed = B.resumed.removed, rotate = B.rotate }
  end
  if #corners > #path then d.path_total = #corners end
  if B.skipped > 0 then d.skipped = B.skipped end
  if (B.merged or 0) > 0 then d.merged = B.merged end
  if B.box and B.box.x1 ~= nil then
    d.area = as_area(B.box)
    if B.box.x2 - B.box.x1 > M.MAX_AREA_SIDE or B.box.y2 - B.box.y1 > M.MAX_AREA_SIDE then
      -- длинная лента: куски не больше 128×128 для build_ghosts
      d.areas = {}
      local keys = {}
      for k in pairs(B.parts) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do d.areas[#d.areas + 1] = as_area(B.parts[k]) end
    end
  end
  return d
end

local function plan_cell(s)
  return { x = s.x, y = s.y, d = s.dir, u = s.utype, n = s.natural or nil }
end

--- Запомнить поставленный план в storage.belt_last[helper] (PROTOCOL §7): его читает from = "resume".
--- План длиннее MAX_REMEMBERED клеток не запоминается (и прежний забывается: он уже не последний).
local function remember(B, ctx)
  if type(storage.belt_last) ~= "table" then storage.belt_last = {} end
  local mem, id = storage.belt_last, ctx.helper_id
  if B.resumed ~= nil then
    -- перекладка: в памяти осталась построенная часть — к ней дописывается новый путь
    local rec = mem[id]
    if type(rec) ~= "table" or type(rec.cells) ~= "table" then return end
    for _, r in ipairs(B.routes) do
      local cells = r.lane and rec.cells[r.lane] or nil
      if cells ~= nil then
        for _, s in ipairs(r.steps) do cells[#cells + 1] = plan_cell(s) end
        rec.ends[r.lane].open = nil
        if r.group ~= nil then
          rec.ends[r.lane].goal, rec.ends[r.lane].final_dir = r.goal, r.final_dir
        end
      end
    end
    local total = 0
    for _, cells in ipairs(rec.cells) do total = total + #cells end
    if total > M.MAX_REMEMBERED then
      mem[id] = nil
      return
    end
    rec.underground, rec.tick = B.umode, ctx.tick
    return
  end
  local total = 0
  for _, r in ipairs(B.routes) do total = total + #r.steps end
  if total > M.MAX_REMEMBERED then
    mem[id] = nil
    return
  end
  local cells, ends = {}, {}
  for i, r in ipairs(B.routes) do
    cells[i] = {}
    for j, s in ipairs(r.steps) do cells[i][j] = plan_cell(s) end
    local trunk = r.group and B.trunks[r.group] or nil
    ends[i] = { start = r.start, goal = r.goal, final_dir = r.final_dir, feeder = trunk and trunk.route or nil }
  end
  mem[id] = {
    surface_index = ctx.entity.surface.index, to = center(B.to), belt = B.W.belt, underground = B.umode,
    lanes = B.lanes, cells = cells, ends = ends, tick = ctx.tick,
  }
end

--- Убрать призраки, которые эта задача уже поставила (отказ по времени). → сколько убрано.
local function unplace(B, env)
  local n = 0
  if B.dry or B.flat == nil or B.place_i == nil then return 0 end
  for i = 1, min(#B.flat, B.place_i - 1) do
    local s = B.flat[i]
    if s.placed then
      if beltpath.remove_ghost(env, s.x, s.y, s.utype ~= nil) then n = n + 1 end
      if s.natural then beltpath.unmark(env, s.x, s.y) end
    end
  end
  return n
end

local function place_tick(B, env, ctx)
  B.box = B.box or {}
  B.parts = B.parts or {}
  local last = min(#B.flat, B.place_i + M.PLACE_PER_TICK - 1)
  for i = B.place_i, last do
    local s = B.flat[i]
    local ok, marked = beltpath.place(env, s, B.dry)
    B.marked = B.marked + marked
    if ok then
      if not B.dry then s.placed = true end
      B.placed = B.placed + 1
      local item, count = beltpath.item_of(s.name)
      if item then B.need[item] = (B.need[item] or 0) + count end
      grow(B.box, s.x, s.y)
      local px, py = floor((s.x - B.bounds.min_x) / M.MAX_AREA_SIDE), floor((s.y - B.bounds.min_y) / M.MAX_AREA_SIDE)
      local pk = px * 1024 + py
      B.parts[pk] = B.parts[pk] or {}
      grow(B.parts[pk], s.x, s.y)
    else
      B.skipped = B.skipped + 1
    end
  end
  B.place_i = last + 1
  if B.place_i <= #B.flat then return nil end
  local detail = detail_of(B)
  if B.placed == 0 and not (B.resumed ~= nil and #B.flat == 0) then
    -- (перекладка, которой нечего достраивать, — не отказ: ghosts = 0)
    return failed("cannot_place", "no belt ghost could be placed", detail)
  end
  if not B.dry then remember(B, ctx) end
  return { status = "done", detail = detail }
end

-- ------------------------------------------------------------------ действие

function M.tick(task, ctx)
  local B = task.belt
  if B == nil then return failed("internal", "plan_belt: state is lost") end
  B.ticks = B.ticks + 1
  task.progress_tick = ctx.tick -- расчёт идёт, тело стоит: «пульс» (ACTIONS.md)
  local h = ctx.entity
  local env = beltpath.env(B.W, h.surface, h.force)
  if B.ticks > M.MAX_TICKS then
    task.belt = nil
    -- дольше лимита времени — тот же отказ, что исчерпанный бюджет поиска (ACTIONS.md, уточнения 3.4);
    -- призраки, которые задача успела поставить, она убирает сама (уточнения 3.5)
    local running = B.stage == "search" and type(B.search) == "table" and tonumber(B.search.expansions) or 0
    local removed = unplace(B, env) + (B.resumed and B.resumed.removed or 0)
    return failed("path_failed", "plan_belt did not finish in time",
      { reason = "budget", expanded = B.expansions + running, lane = B.ti, removed = removed })
  end
  local result
  if B.stage == "search" then
    result = search_tick(B, env)
  elseif B.stage == "scan" then
    result = scan_tick(B, env, ctx)
    if result == nil and B.stage == "place" and not B.dry then
      -- трата: по предмету на клетку разметки (perm-spend; по задаче: perm_gate и owner_ok)
      local pcode, ptext, pdata = perms.refusal(perms.add_spend({}, #B.flat), task)
      if pcode ~= nil then result = failed(pcode, ptext, pdata) end
    end
  else
    result = place_tick(B, env, ctx)
  end
  if result ~= nil then
    task.belt = nil
    if result.status == "failed" and B.resumed ~= nil then
      -- старые призраки уже убраны (иначе дроны достроят ленту в тупик): сказать, сколько
      result.detail = result.detail or {}
      result.detail.removed = B.resumed.removed
    end
  end
  return result
end

function M.stop(task, ctx)
  ctx.cancel_approach(task)
  task.belt = nil
end

return M
