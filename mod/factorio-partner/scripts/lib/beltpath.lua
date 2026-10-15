-- Слой игры для прокладки лент. Контракт: docs/ACTIONS.md «plan_belt», PROTOCOL §6.5, §6.12.
--
-- Поиск пути — решатель мода Wuastbude Belt & Pipe Router (scripts/vendor/router/solver.lua, MIT):
-- A* по состояниям «клетка + направление» с ценой поворотов и подземными участками. Решатель к игре
-- не обращается: всё, что он знает о мире, он спрашивает у обратных вызовов. Этот файл — те самые
-- вызовы под Factorio 2.0.77 и правила проекта:
--   * клетка годна, если там можно поставить ленту: `can_place_entity{build_check_type = manual_ghost}`;
--   * плитки без опоры обходятся; что «без опоры» — решает маска столкновений плитки против маски
--     ленты (прототипы игры, имён плиток в коде нет — PROTOCOL §6.12);
--   * подземный участок разрешён, только если ни одна клетка под ним не запрещена маской подземного
--     конвейера, длина — не больше `max_underground_distance` прототипа;
--   * деревья и камни — не преграда (их пометят к сносу при постановке), всё остальное — преграда.
--
-- Мир запоминается в таблице `W` (только числа, строки и bool — лежит в задаче, то есть в `storage`):
-- клетка проверяется один раз за задачу.
local solver = require("scripts.vendor.router.solver")
local network = require("scripts.vendor.router.underground_network")

local M = {}

local floor, abs, min, max = math.floor, math.abs, math.min, math.max

-- Коды клетки: > 0 — ленту поставить можно.
M.FREE = 1        -- свободно
M.NATURAL = 2     -- свободно после сноса дерева или камня
M.TILE = 0        -- плитка без опоры (жидкость, пустота) или место, где движок строить не даёт
M.ENTITY = -1     -- чужая или своя постройка, призрак, скала
M.UNCHARTED = -2  -- неоткрытый чанк
M.PLANNED = -3    -- занято лентой, которую эта же задача уже проложила

M.VEC = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }
M.DIR_NAMES = { north = 0, east = 4, south = 8, west = 12 }

-- Маски подземных конвейеров (`underground_collision_mask`) в 2.0.77 видны только на стадии данных.
-- Если стадия данных мода положила их в прототип `mod-data` с этим именем
-- (`data = { [имя подземного конвейера] = { layers = { [слой] = true } } }`), берём оттуда; иначе —
-- осторожное правило: под плиткой, на которой сам конвейер стоять не может, подземный не идёт.
M.MASKS_MOD_DATA = "factorio-partner-underground-masks"

local SOLVER_MODE = { auto = "prefer-surface", prefer = "prefer-underground", never = "surface-only" }
local BLOCK = 32
local OFF, MUL = 1048576, 2097152

local function key(x, y) return (x + OFF) * MUL + (y + OFF) end
M.key = key

local function overlaps(a, b)
  if not (a and b) then return false end
  local la, lb = a.layers or a, b.layers or b
  for layer, on in pairs(la) do
    if on and lb[layer] then return true end
  end
  return false
end
M.overlaps = overlaps

-- ------------------------------------------------------------------ прототипы

local function place_items(proto)
  local out = {}
  local list = proto and proto.items_to_place_this
  if type(list) ~= "table" then return out end
  for _, it in ipairs(list) do
    local name = type(it) == "string" and it or (type(it) == "table" and it.name) or nil
    if type(name) == "string" then
      out[#out + 1] = { name = name, count = type(it) == "table" and tonumber(it.count) or 1 }
    end
  end
  return out
end

--- Предмет, которым ставится постройка: имя, число │ nil.
function M.item_of(entity_name)
  local first = place_items(prototypes.entity[entity_name])[1]
  if first == nil then return nil end
  return first.name, first.count
end

--- Открыт ли силе рецепт предмета этой постройки.
function M.unlocked(force, entity_name)
  for _, it in ipairs(place_items(prototypes.entity[entity_name])) do
    local recipe = force.recipes[it.name]
    if recipe and recipe.enabled then return true end
    local ok, found = pcall(prototypes.get_recipe_filtered, {
      { filter = "has-product-item", elem_filters = { { filter = "name", name = it.name } } },
    })
    if ok and found then
      for recipe_name in pairs(found) do
        local r = force.recipes[recipe_name]
        if r and r.enabled then return true end
      end
    end
  end
  return false
end

--- Лучшая лента из открытого исследованиями (самая быстрая, при равенстве — по имени) │ nil.
function M.default_belt(force)
  local names = {}
  for name in pairs(prototypes.get_entity_filtered{ { filter = "type", type = "transport-belt" } }) do
    names[#names + 1] = name
  end
  table.sort(names)
  local best, best_speed
  for _, name in ipairs(names) do
    local proto = prototypes.entity[name]
    if proto and not proto.hidden and M.unlocked(force, name) then
      local speed = proto.belt_speed or 0
      if best == nil or speed > best_speed then best, best_speed = name, speed end
    end
  end
  return best
end

local function underground_mask(under_name)
  local all = prototypes.mod_data
  local md = all and all[M.MASKS_MOD_DATA]
  local data = md and md.data
  local mask = type(data) == "table" and data[under_name] or nil
  if type(mask) == "table" then return mask end
  local proto = prototypes.entity[under_name]
  return proto and proto.collision_mask or nil
end

-- ------------------------------------------------------------------ мир

--- Новая память о мире. belt — имя ленты; under — имя подземного конвейера или nil (подземных нет).
function M.new_world(belt, under)
  local up = under and prototypes.entity[under] or nil
  return {
    belt = belt,
    under = under,
    max_under = up and tonumber(up.max_underground_distance) or 0,
    cells = {},      -- [key] = код клетки
    ucells = {},     -- [key] = можно ли поставить конец подземного конвейера
    charted = {},    -- [ключ чанка] = bool
    blocks = {},     -- [ключ блока 32×32] = true: подземные конвейеры блока учтены в net
    net = network.empty(),
    tile_g = {},     -- [имя плитки] = мешает ленте
    tile_u = {},     -- [имя плитки] = мешает подземному участку
    tile_c = {},     -- [key] = флаги плитки клетки: 0 │ 1 (мешает ленте) + 2 (мешает подземному)
    rejected = {},   -- [ключ подземного участка] = true: отвергнут (сам себе мешает)
    seen = {},       -- [ключ чанка] = есть ли у силы текущий обзор чанка (предупреждение unseen)
    checks = 0,      -- сколько раз спросили движок (для отчёта и тестов)
  }
end

--- Живые объекты тика + память: не хранить (LuaObject и маски — заново каждый тик).
function M.env(W, surface, force)
  local belt_proto = prototypes.entity[W.belt]
  return {
    W = W, surface = surface, force = force,
    belt_mask = belt_proto and belt_proto.collision_mask or nil,
    under_mask = W.under and underground_mask(W.under) or nil,
    check = defines.build_check_type.manual_ghost,
  }
end

local function charted(env, x, y)
  local cx, cy = floor(x / 32), floor(y / 32)
  local k = key(cx, cy)
  local W = env.W
  local v = W.charted[k]
  if v == nil then
    v = env.force.is_chunk_charted(env.surface, { x = cx, y = cy }) and true or false
    W.charted[k] = v
  end
  return v
end
M.charted = charted

--- Клетка лежит в чанке без текущего обзора (план там — «по карте», docs/ACTIONS.md, «plan_belt»).
function M.unseen(env, x, y)
  local cx, cy = floor(x / 32), floor(y / 32)
  local k = key(cx, cy)
  local W = env.W
  if W.seen == nil then W.seen = {} end
  local v = W.seen[k]
  if v == nil then
    v = env.force.is_chunk_visible(env.surface, { x = cx, y = cy }) and true or false
    W.seen[k] = v
  end
  return not v
end

--- Плитка клетки: мешает ленте, мешает подземному участку, имя.
--- Клетка спрашивается у движка один раз за задачу (кэш W.tile_c): повторный вызов — например, из
--- underground_ok, который проходит одни и те же клетки для многих участков, — имени не отдаёт.
local function tile_flags(env, x, y)
  local W = env.W
  local tc = W.tile_c
  local k = key(x, y)
  if tc ~= nil then
    local f = tc[k]
    if f ~= nil then return f % 2 == 1, f >= 2 end
  end
  local name = env.surface.get_tile(x, y).name
  local g = W.tile_g[name]
  if g == nil then
    local proto = prototypes.tile and prototypes.tile[name] or nil
    local mask = proto and proto.collision_mask or nil
    g = overlaps(env.belt_mask, mask)
    W.tile_g[name] = g
    W.tile_u[name] = overlaps(env.under_mask, mask)
  end
  if tc ~= nil then tc[k] = (g and 1 or 0) + (W.tile_u[name] and 2 or 0) end
  return g, W.tile_u[name], name
end
M.tile_flags = tile_flags

local function cell_area(x, y)
  return { left_top = { x = x + 0.05, y = y + 0.05 }, right_bottom = { x = x + 0.95, y = y + 0.95 } }
end

local function is_natural(e)
  local t = e.type
  if t == "tree" then return e.minable and true or false end
  if t == "simple-entity" then
    return (e.force ~= nil and e.force.name == "neutral" and e.minable) and true or false
  end
  return false
end

--- Что стоит в клетке и мешает ленте: список помех, все ли они — деревья и камни.
local function blockers(env, x, y)
  local out, all_natural = {}, true
  for _, e in ipairs(env.surface.find_entities_filtered{ area = cell_area(x, y) }) do
    if e.valid and e.type ~= "character" then
      local blocks
      if e.type == "entity-ghost" then
        blocks = true
      else
        local proto = e.prototype
        local mask = proto and proto.collision_mask or nil
        -- без масок (неизвестный прототип) считаем помехой: лучше обойти, чем упереться
        blocks = (env.belt_mask == nil or mask == nil) or overlaps(env.belt_mask, mask)
      end
      if blocks then
        out[#out + 1] = e
        if not is_natural(e) then all_natural = false end
      end
    end
  end
  return out, all_natural
end

local function can_place(env, name, x, y, forced)
  env.W.checks = env.W.checks + 1
  return env.surface.can_place_entity{
    name = name,
    position = { x = x + 0.5, y = y + 0.5 },
    direction = defines.direction.north,
    force = env.force,
    build_check_type = env.check,
    forced = forced and true or false,
  } and true or false
end

--- Код клетки (M.FREE … M.PLANNED); движок спрашивается один раз за задачу.
function M.cell(env, x, y)
  local W = env.W
  local k = key(x, y)
  local c = W.cells[k]
  if c ~= nil then return c end
  if not charted(env, x, y) then
    c = M.UNCHARTED
  elseif tile_flags(env, x, y) then
    c = M.TILE
  elseif can_place(env, W.belt, x, y, false) then
    -- can_place_entity(manual_ghost) разрешает «поставить» ленту поверх призрака или ленты
    -- (поворот / замена), а проложить поверх чужой ленты нельзя: смотрим, нет ли в клетке помехи.
    local _, all_natural = blockers(env, x, y)
    c = all_natural and M.FREE or M.ENTITY
  else
    local found, all_natural = blockers(env, x, y)
    if #found == 0 then
      c = M.TILE
    elseif all_natural and can_place(env, W.belt, x, y, true) then
      c = M.NATURAL
    else
      c = M.ENTITY
    end
  end
  W.cells[k] = c
  return c
end

--- Можно ли поставить в клетке конец подземного конвейера.
local function ucell(env, x, y)
  local W = env.W
  local k = key(x, y)
  local v = W.ucells[k]
  if v ~= nil then return v end
  local c = M.cell(env, x, y)
  v = c > 0 and can_place(env, W.under, x, y, c == M.NATURAL)
  W.ucells[k] = v
  return v
end

-- ------------------------------------------------------------------ существующие подземные конвейеры

-- Решатель сети (vendor) читает у сущностей поле `underground_belt_neighbour`, которого в 2.0 нет
-- (пара — `LuaEntity.neighbours`). Поэтому сети отдаются простые таблицы с нужными полями.
local function proxy(e, with_pair)
  local ghost = e.type == "entity-ghost"
  local p = e.position
  local out = {
    valid = true, type = e.type, name = e.name, direction = e.direction,
    position = { x = p.x, y = p.y }, unit_number = e.unit_number,
  }
  if ghost then
    out.ghost_type, out.ghost_name = e.ghost_type, e.ghost_name
  end
  local ok, kind = pcall(function() return e.belt_to_ground_type end)
  out.belt_to_ground_type = ok and kind or nil
  local marked = false
  if not ghost then
    local ok2, m = pcall(function() return e.to_be_deconstructed() end)
    marked = ok2 and m == true
  end
  out.to_be_deconstructed = function() return marked end
  if with_pair and not ghost then
    local ok3, other = pcall(function() return e.neighbours end)
    if ok3 and other ~= nil and type(other) ~= "number" and other.valid and other.type == "underground-belt" then
      out.underground_belt_neighbour = proxy(other, false)
    end
  end
  return out
end

local function load_block(env, bx, by)
  local W = env.W
  local k = key(bx, by)
  if W.blocks[k] then return end
  W.blocks[k] = true
  local area = {
    left_top = { x = bx * BLOCK, y = by * BLOCK },
    right_bottom = { x = (bx + 1) * BLOCK, y = (by + 1) * BLOCK },
  }
  local list = {}
  for _, e in ipairs(env.surface.find_entities_filtered{ area = area, type = "underground-belt" }) do
    if e.valid and e.type == "underground-belt" then list[#list + 1] = proxy(e, true) end
  end
  for _, e in ipairs(env.surface.find_entities_filtered{ area = area, ghost_type = "underground-belt" }) do
    if e.valid and e.type == "entity-ghost" and e.ghost_type == "underground-belt" then
      list[#list + 1] = proxy(e, false)
    end
  end
  if #list > 0 then network.add_entities(W.net, list, nil) end
end

local function load_blocks(env, x1, y1, x2, y2)
  for bx = floor(x1 / BLOCK), floor(x2 / BLOCK) do
    for by = floor(y1 / BLOCK), floor(y2 / BLOCK) do
      load_block(env, bx, by)
    end
  end
end

-- ------------------------------------------------------------------ подземный участок

--- Разрешён ли подземный участок edge (вход в from, выход в to) для задания job.
function M.underground_ok(env, job, edge)
  local W = env.W
  if W.under == nil then return false end
  local fx, fy, tx, ty, len = edge.from_x, edge.from_y, edge.to_x, edge.to_y, edge.length
  if len < 2 or len > W.max_under then return false end
  if tx == job.goal.x and ty == job.goal.y then return false end
  if fx == job.start.x and fy == job.start.y then return false end
  if M.cell(env, fx, fy) <= 0 or M.cell(env, tx, ty) <= 0 then return false end
  local v = M.VEC[edge.direction]
  local auto = job.underground == "auto"
  for i = 1, len - 1 do
    local x, y = fx + v[1] * i, fy + v[2] * i
    local c = M.cell(env, x, y)
    if c == M.UNCHARTED then return false end
    -- "auto": подземный только через помеху и вплотную к ней — вход прямо перед помехой, выход сразу
    -- за ней, а не вместо свободной земли
    if auto and (i == 1 or i == len - 1) and c > 0 then return false end
    local _, under_blocked = tile_flags(env, x, y)
    if under_blocked then return false end
  end
  if not ucell(env, fx, fy) or not ucell(env, tx, ty) then return false end
  local ek = network.edge_key(W.under, edge)
  if ek == nil or W.rejected[ek] then return false end
  local pad = W.max_under + 1
  load_blocks(env, min(fx, tx) - pad, min(fy, ty) - pad, max(fx, tx) + pad, max(fy, ty) + pad)
  if network.conflicts(W.net, W.under, edge, W.max_under) then return false end
  return true
end

-- ------------------------------------------------------------------ поиск

--- Обратные вызовы решателя для задания job = {start={x,y,direction?}, goal={x,y,direction?},
--- underground="auto"|"never"|"prefer", clearance=n?}. В job пишется best_d и reached — ближайшая
--- к цели раскрытая клетка.
function M.callbacks(env, job)
  local W = env.W
  local gx, gy = job.goal.x, job.goal.y
  local n = job.clearance or 1
  local cb = {}

  function cb.prepare(x, y)
    local d = abs(gx - x) + abs(gy - y)
    if job.best_d == nil or d < job.best_d then
      job.best_d = d
      job.reached = { x = x, y = y }
    end
    return true
  end

  function cb.can_place(kind, x, y, _, edge)
    if kind == "underground" then return M.underground_ok(env, job, edge) end
    if x == gx and y == gy then return true end -- цель проверена до поиска
    if n == 1 then return M.cell(env, x, y) > 0 end
    for dx = 0, n - 1 do
      for dy = 0, n - 1 do
        if M.cell(env, x + dx, y + dy) <= 0 then return false end
      end
    end
    return true
  end

  function cb.underground_edges(x, y, direction)
    local out = {}
    if W.under == nil or job.underground == "never" or n > 1 then return out end
    local v = M.VEC[direction]
    if v == nil then return out end
    for len = 2, W.max_under do
      out[#out + 1] = { x = x + v[1] * len, y = y + v[2] * len, direction = direction, length = len }
    end
    return out
  end

  return cb
end

--- Начать поиск. budget — сколько раскрытий осталось у задачи; bounds — рамка поиска.
function M.new_search(W, job, budget, bounds)
  local mode = SOLVER_MODE[job.underground] or "surface-only"
  if W.under == nil or (job.clearance or 1) > 1 then mode = "surface-only" end
  local state = solver.new{
    starts = { job.start },
    goal = job.goal,
    mode = mode,
    allow_reverse = false,
    max_total_expansions = max(1, floor(budget)),
    bounds = bounds,
  }
  -- «Быстрый путь» решателя (прямая, угол, зигзаг) держит таблицы с ключами-bool, а состояние поиска
  -- лежит в storage и должно пережить сохранение. A* находит те же прямые сам.
  state.fast_path_attempted = true
  return state
end

--- Шаг поиска: work единиц работы за тик. → "running" │ "found", route │ "unreachable" │ "limit".
function M.step(search, env, job, work)
  local status, route = solver.step(search, M.callbacks(env, job), work)
  if status == "waiting" then status = "running" end
  return status, route
end

--- Два подземных участка маршрута легли на одну линию друг на друга → второй запрещается (true),
--- поиск надо повторить.
function M.reject_conflict(W, route)
  if W.under == nil then return false end
  local _, second = network.route_conflict(W.under, route.edges)
  if second == nil then return false end
  local ek = network.edge_key(W.under, second)
  if ek == nil then return false end
  W.rejected[ek] = true
  return true
end

-- ------------------------------------------------------------------ маршрут → постройки

--- Маршрут решателя → список шагов постановки и счёт.
--- opts: skip_first / skip_last — концы уже заняты (существующая лента, сундук): туда не ставим;
---       final_dir — куда смотрит последняя лента (иначе — как пришла).
--- → steps = { {x, y, dir, name, utype?, edge?} }, stats = {length, turns, undergrounds, corners = {{x,y}}}
function M.route_steps(W, route, opts)
  opts = opts or {}
  local nodes, edges = route.nodes, route.edges
  local steps, corners = {}, {}
  local turns, undergrounds, length = 0, 0, 1
  local n = #nodes
  for i = 1, n do
    local node = nodes[i]
    local inc, out = edges[i - 1], edges[i]
    local dir = out and out.direction or (opts.final_dir or (inc and inc.direction) or 0)
    local name, utype, edge = W.belt, nil, nil
    if out and out.kind == "underground" then
      name, utype, edge = W.under, "input", out
      undergrounds = undergrounds + 1
    elseif inc and inc.kind == "underground" then
      name, utype = W.under, "output"
      dir = inc.direction
    end
    if out then length = length + out.length end
    local turned = inc ~= nil and inc.direction ~= dir
    if turned then turns = turns + 1 end
    if i == 1 or i == n or turned then corners[#corners + 1] = { x = node.x, y = node.y } end
    if not ((i == 1 and opts.skip_first) or (i == n and opts.skip_last)) then
      steps[#steps + 1] = { x = node.x, y = node.y, dir = dir, name = name, utype = utype, edge = edge }
    end
  end
  return steps, { length = length, turns = turns, undergrounds = undergrounds, corners = corners }
end

--- Занять клетки шагов (следующие ленты их обойдут) и учесть свои подземные участки в сети.
function M.commit(W, steps)
  for _, s in ipairs(steps) do
    local k = key(s.x, s.y)
    if W.cells[k] == M.NATURAL then s.natural = true end
    W.cells[k] = M.PLANNED
    W.ucells[k] = false
    if s.edge then
      local run = network.from_edge(W.under, s.edge)
      if run then
        local function endpoint(x, y, kind)
          return {
            name = W.under, axis = run.axis, lane = run.lane,
            coordinate = run.axis == "x" and x or y, x = x, y = y,
            direction = run.direction, belt_to_ground_type = kind, paired = true,
          }
        end
        network.merge(W.net, {
          runs = { run },
          endpoints = { endpoint(run.from_x, run.from_y, "input"), endpoint(run.to_x, run.to_y, "output") },
          belt_inputs = {},
        })
      end
      s.edge = nil -- в storage не нужен
    end
  end
end

-- ------------------------------------------------------------------ пачка параллельных лент

--- Смещение ленты o (0 — самая левая по ходу) в квадрате n×n при движении в сторону dir.
function M.lane_offset(o, dir, n)
  if dir == 4 then return 0, o end
  if dir == 12 then return 0, n - 1 - o end
  if dir == 0 then return o, 0 end
  return n - 1 - o, 0
end

--- Опорный маршрут (только наземный, найден с запасом n×n) → n параллельных маршрутов.
--- nil, если пачка не складывается (два поворота в одну сторону ближе n клеток).
function M.derive_lanes(route, n)
  local nodes, edges = route.nodes, route.edges
  if #edges == 0 then return nil end
  local segs = {}
  for _, e in ipairs(edges) do
    if e.kind ~= "ground" then return nil end
    local last = segs[#segs]
    if last and last.dir == e.direction then
      last.len = last.len + 1
    else
      segs[#segs + 1] = { dir = e.direction, len = 1 }
    end
  end
  -- углы опорного маршрута
  local ref = { { x = nodes[1].x, y = nodes[1].y } }
  for j, s in ipairs(segs) do
    local v = M.VEC[s.dir]
    ref[j + 1] = { x = ref[j].x + v[1] * s.len, y = ref[j].y + v[2] * s.len }
  end
  local lanes = {}
  for o = 0, n - 1 do
    local pts = {}
    local dx, dy = M.lane_offset(o, segs[1].dir, n)
    pts[1] = { x = ref[1].x + dx, y = ref[1].y + dy }
    for j = 1, #segs - 1 do
      local a, b = segs[j].dir, segs[j + 1].dir
      local horizontal = (a == 4 or a == 12) and a or b
      local vertical = (a == 0 or a == 8) and a or b
      if horizontal == vertical or not (horizontal == 4 or horizontal == 12) then return nil end
      local px = M.lane_offset(o, vertical, n)
      local _, py = M.lane_offset(o, horizontal, n)
      pts[j + 1] = { x = ref[j + 1].x + px, y = ref[j + 1].y + py }
    end
    dx, dy = M.lane_offset(o, segs[#segs].dir, n)
    pts[#segs + 1] = { x = ref[#segs + 1].x + dx, y = ref[#segs + 1].y + dy }

    local lane = { nodes = { { x = pts[1].x, y = pts[1].y } }, edges = {} }
    for j, s in ipairs(segs) do
      local v = M.VEC[s.dir]
      local ddx, ddy = pts[j + 1].x - pts[j].x, pts[j + 1].y - pts[j].y
      local len = ddx * v[1] + ddy * v[2]
      if len < 1 or ddx ~= v[1] * len or ddy ~= v[2] * len then return nil end
      for i = 1, len do
        local fx, fy = pts[j].x + v[1] * (i - 1), pts[j].y + v[2] * (i - 1)
        lane.edges[#lane.edges + 1] = {
          kind = "ground", direction = s.dir, length = 1,
          from_x = fx, from_y = fy, to_x = fx + v[1], to_y = fy + v[2],
        }
        lane.nodes[#lane.nodes + 1] = { x = fx + v[1], y = fy + v[2], direction = s.dir }
      end
    end
    lanes[#lanes + 1] = lane
  end
  return lanes
end

-- ------------------------------------------------------------------ постановка

--- Поставить призрак шага (или только проверить при dry). → поставлен ли, сколько помечено к сносу.
function M.place(env, step, dry)
  local surface, force = env.surface, env.force
  local marked = 0
  if step.natural then
    for _, e in ipairs(surface.find_entities_filtered{ area = cell_area(step.x, step.y) }) do
      if e.valid and is_natural(e) and not e.to_be_deconstructed() then
        if dry or e.order_deconstruction(force) then marked = marked + 1 end
      end
    end
  end
  local position = { x = step.x + 0.5, y = step.y + 0.5 }
  if dry and env.W.assumed and env.W.assumed[key(step.x, step.y)] then return true, marked end
  env.W.checks = env.W.checks + 1
  if not surface.can_place_entity{
    name = step.name, position = position, direction = step.dir, force = force,
    build_check_type = env.check, forced = step.natural and true or false,
  } then
    return false, marked
  end
  if dry then return true, marked end
  local ghost = surface.create_entity{
    name = "entity-ghost",
    inner_name = step.name,
    position = position,
    direction = step.dir,
    force = force,
    quality = "normal",
    raise_built = true,
    type = step.utype, -- подземный конвейер: "input" │ "output"
  }
  return ghost ~= nil, marked
end

-- ------------------------------------------------------------------ перекладка (plan_belt from:"resume")

local BELT_TYPES = { ["transport-belt"] = true, ["underground-belt"] = true }

--- Свой (силы хозяина) призрак ленты в клетке │ nil. under: true — только подземного конвейера,
--- false — только ленты, nil — любой из двух.
function M.own_ghost(env, x, y, under)
  local want
  if under ~= nil then want = under and "underground-belt" or "transport-belt" end
  for _, e in ipairs(env.surface.find_entities_filtered{ area = cell_area(x, y), type = "entity-ghost" }) do
    if e.valid and e.type == "entity-ghost" and e.force ~= nil and e.force.name == env.force.name
      and BELT_TYPES[e.ghost_type] and (want == nil or e.ghost_type == want) then
      return e
    end
  end
  return nil
end

--- Убрать свой призрак ленты в клетке (under — как у own_ghost). Чужие призраки, призраки других
--- построек и сами постройки не трогает. → убран ли.
function M.remove_ghost(env, x, y, under)
  local g = M.own_ghost(env, x, y, under)
  if g == nil then return false end
  g.destroy{ raise_destroy = true }
  return true
end

--- Стоит ли в клетке настоящая (построенная) лента своей силы; under — ждём подземный конвейер.
function M.built_at(env, x, y, under)
  local want = under and "underground-belt" or "transport-belt"
  for _, e in ipairs(env.surface.find_entities_filtered{ area = cell_area(x, y), type = want }) do
    if e.valid and e.type == want and e.force ~= nil and e.force.name == env.force.name then return true end
  end
  return false
end

--- Снять пометки к сносу с деревьев и камней клетки (их ставил план). → сколько снято.
function M.unmark(env, x, y)
  local n = 0
  for _, e in ipairs(env.surface.find_entities_filtered{ area = cell_area(x, y) }) do
    if e.valid and is_natural(e) and e.to_be_deconstructed() then
      if pcall(function() e.cancel_deconstruction(env.force) end) then n = n + 1 end
    end
  end
  return n
end

--- Считать клетку свободной, не спрашивая движок: сухой прогон перекладки — призрак, который
--- настоящий прогон убрал бы, помехой не считается.
function M.assume_free(env, x, y, natural)
  local W = env.W
  W.cells[key(x, y)] = natural and M.NATURAL or M.FREE
  W.assumed = W.assumed or {}
  W.assumed[key(x, y)] = true
end

--- Ширина прохода поперёк хода в клетке шага (сама клетка + свободные соседи, до 2 с каждой стороны).
function M.width_at(env, step)
  local v = M.VEC[step.dir]
  local px, py = -v[2], v[1]
  local width = 1
  for side = -1, 1, 2 do
    for i = 1, 2 do
      local c = M.cell(env, step.x + px * side * i, step.y + py * side * i)
      if c > 0 or c == M.PLANNED then width = width + 1 else break end
    end
  end
  return width
end

--- Лента (или её призрак) своей силы в клетке: имя, направление │ nil.
function M.belt_at(env, x, y)
  for _, e in ipairs(env.surface.find_entities_filtered{ area = cell_area(x, y) }) do
    if e.valid and e.force ~= nil and e.force.name == env.force.name then
      local t, name = e.type, e.name
      if t == "entity-ghost" then t, name = e.ghost_type, e.ghost_name end
      if t == "transport-belt" then return name, e.direction end
    end
  end
  return nil
end

return M
