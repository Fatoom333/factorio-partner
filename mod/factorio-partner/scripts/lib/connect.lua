-- Общие части действия `connect_entities` (docs/ACTIONS.md «connect_entities»): концы, выбор
-- построек, концы трубы у машин, поиск опор, уборка своих призраков, память последней прокладки.
--
-- Лента и труба ищутся решателем scripts/vendor/router через scripts/lib/beltpath.lua (у трубы —
-- вид мира "pipe": клетки, к которым смотрит соединение чужой жидкостной коробки, запрещены).
-- Опоры — A* по клеткам, где опору можно поставить (`can_place_entity{manual_ghost}` через
-- beltpath.cell с видом мира "power"): ребро — не длиннее провода обоих концов, цена — одна опора,
-- оценка — расстояние до цели / длину провода. Работа порциями, состояние — простые таблицы (лежит
-- в задаче, то есть в storage).
local beltpath = require("scripts.lib.beltpath")
local B = require("scripts.lib.build")
local layout = require("scripts.lib.layout")
local err = require("scripts.core.err")
local inv = require("scripts.lib.inventory")

local M = {}

local floor, ceil, abs, sqrt, min, max = math.floor, math.ceil, math.abs, math.sqrt, math.min, math.max
local pread = beltpath.pread

M.VSTART = -1          -- ключ виртуального начала поиска опор (опора или потребитель на конце)
M.MAX_REMEMBERED = 400 -- клеток в storage.connect_last

local KIND_TYPE = { belt = "transport-belt", pipe = "pipe", power = "electric-pole" }
M.KIND_TYPE = KIND_TYPE

local function cell_center(x, y) return { x = x + 0.5, y = y + 0.5 } end
M.cell_center = cell_center

local function dist(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return sqrt(dx * dx + dy * dy)
end

local function surface_matches(s, surface)
  if s == nil then return true end
  if type(s) == "table" then s = pread(s, "index") or pread(s, "name") end
  return s == surface.index or s == surface.name
end

-- ------------------------------------------------------------------ прототипы

local function unlocked_of_type(force, etype)
  local names = {}
  for name in pairs(prototypes.get_entity_filtered{ { filter = "type", type = etype } }) do
    names[#names + 1] = name
  end
  table.sort(names)
  local out, all = {}, {}
  for _, name in ipairs(names) do
    local proto = prototypes.entity[name]
    if proto and not proto.hidden then
      all[#all + 1] = name
      if beltpath.unlocked(force, name) then out[#out + 1] = name end
    end
  end
  return out, all
end

--- Сторона постройки в клетках (по collision_box), не меньше 1.
function M.size_of(proto)
  local box = pread(proto, "collision_box")
  if type(box) ~= "table" then return 1 end
  local lt, rb = box.left_top or box[1], box.right_bottom or box[2]
  if lt == nil or rb == nil then return 1 end
  local w = ceil(((rb.x or rb[1]) - (lt.x or lt[1])) - 0.01)
  return max(1, w)
end

--- Длина провода опоры (2.0: get_max_wire_distance; иначе поле).
function M.reach_of(proto)
  if proto == nil then return 0 end
  local ok, v = pcall(function() return proto.get_max_wire_distance("normal") end)
  if ok and type(v) == "number" then return v end
  return tonumber(pread(proto, "max_wire_distance")) or 0
end

--- Радиус области снабжения опоры (2.0: get_supply_area_distance; иначе поле).
function M.supply_of(proto)
  if proto == nil then return 0 end
  local ok, v = pcall(function() return proto.get_supply_area_distance("normal") end)
  if ok and type(v) == "number" then return v end
  return tonumber(pread(proto, "supply_area_distance")) or 0
end

--- Имя постройки нужного вида: названное (проверка вида); для опор — та, что у тела в карманах
--- (больше всего штук); стоящее на конце; лучшее открытое.
--- at — имена построек этого вида на концах (по порядку); carried — name -> штук в карманах тела.
--- → имя │ raise bad_args.
function M.pick(kind, force, named, at, carried)
  local etype = KIND_TYPE[kind]
  if named ~= nil then
    local proto = prototypes.entity[named]
    if proto == nil or proto.type ~= etype then
      err.raise("bad_args", "args." .. (kind == "power" and "pole" or kind) .. ": " .. named .. " is not " .. etype)
    end
    return named
  end
  if kind == "power" and type(carried) == "table" then
    local best, most
    for name, n in pairs(carried) do
      local proto = prototypes.entity[name]
      if proto ~= nil and proto.type == "electric-pole" and n > 0 and M.reach_of(proto) > 0
          and (most == nil or n > most or (n == most and name < best)) then
        best, most = name, n
      end
    end
    if best ~= nil then return best end
  end
  for _, name in ipairs(at or {}) do
    if name ~= nil then return name end
  end
  if kind == "belt" then
    local belt = beltpath.default_belt(force)
    if belt == nil then err.raise("bad_args", "no transport belt is researched, set args.belt") end
    return belt
  end
  local open = unlocked_of_type(force, etype)
  if #open == 0 then err.raise("bad_args", "no " .. etype .. " is researched, set args." .. (kind == "power" and "pole" or kind)) end
  if kind == "pipe" then return open[1] end
  -- опора: самая длинная по проводу среди одноклеточных, иначе любая
  local best, best_r, best_small
  for _, name in ipairs(open) do
    local proto = prototypes.entity[name]
    local small = M.size_of(proto) == 1
    local r = M.reach_of(proto)
    if best == nil or (small and not best_small) or (small == best_small and r > best_r) then
      best, best_r, best_small = name, r, small
    end
  end
  return best
end

--- Подземная пара для ленты или трубы в режиме mode │ nil. warnings — список предупреждений.
function M.pick_under(kind, force, main, mode, warnings)
  if mode == "never" then return nil end
  if kind == "belt" then
    local up = prototypes.entity[main].related_underground_belt
    if up == nil then return nil end
    if beltpath.unlocked(force, up.name) then return up.name end
    if mode == "prefer" then
      warnings[#warnings + 1] = "not_researched:" .. up.name
      return up.name
    end
    return nil
  end
  local open, all = unlocked_of_type(force, "pipe-to-ground")
  local function longest(list)
    local best, best_d
    for _, name in ipairs(list) do
      local d = beltpath.pipe_under_distance(prototypes.entity[name])
      if d >= 2 and (best == nil or d > best_d) then best, best_d = name, d end
    end
    return best
  end
  local name = longest(open)
  if name ~= nil then return name end
  if mode == "prefer" then
    name = longest(all)
    if name ~= nil then warnings[#warnings + 1] = "not_researched:" .. name end
    return name
  end
  return nil
end

-- ------------------------------------------------------------------ концы

local function find_named(surface, name, pos)
  for _, e in ipairs(surface.find_entities_filtered{ name = name, position = pos, radius = 0.5 }) do
    if e.valid then return e end
  end
  return nil
end

--- Конец из аргументов: {cell = {x, y}, dir?, entity?, port?} (сущность — только на время тика).
--- Ошибки: bad_args (вид порта, сущность у ленты), not_found (тег, порт, постройка), not_charted.
function M.raw_end(ctx, ep, kind, field)
  local h = ctx.entity
  local surface = h.surface
  local n = (ep.pos ~= nil and 1 or 0) + (ep.target ~= nil and 1 or 0) + (ep.layout ~= nil and 1 or 0)
  if n ~= 1 or (ep.layout ~= nil and (ep.port == nil) == (ep.i == nil))
      or (ep.layout == nil and (ep.port ~= nil or ep.i ~= nil)) then
    err.raise("bad_args", "args." .. field .. ": give exactly one of pos, target, {layout, port}, {layout, i}")
  end
  if ep.dir ~= nil and ep.pos == nil then err.raise("bad_args", "args." .. field .. ".dir: only with pos") end
  local out = {}
  if ep.pos ~= nil then
    out.cell = { x = floor(ep.pos.x), y = floor(ep.pos.y) }
    out.dir = ep.dir
  elseif ep.target ~= nil then
    if kind == "belt" then
      err.raise("bad_args", "args." .. field .. ": a belt end is a tile or a belt port, not a building")
    end
    out.entity = B.resolve(ctx, ep.target)
  elseif ep.port ~= nil then
    local p, code, text = layout.port(ctx.helper_id, ep.layout, ep.port)
    if p == nil then err.raise(code or "not_found", text or ("layout " .. ep.layout .. " has no port " .. ep.port)) end
    if not surface_matches(p.surface, surface) then
      err.raise("not_found", "args." .. field .. ": layout " .. ep.layout .. " is on another surface")
    end
    if p.kind ~= kind then
      err.raise("bad_args", "args." .. field .. ": port " .. ep.port .. " is a " .. tostring(p.kind) .. " port, not " .. kind)
    end
    out.cell = { x = floor(p.pos.x), y = floor(p.pos.y) }
    if p.dir == 0 or p.dir == 4 or p.dir == 8 or p.dir == 12 then out.dir = p.dir end
    out.port = { fluid = p.fluid, io = p.io }
  else
    if kind == "belt" then
      err.raise("bad_args", "args." .. field .. ": a belt end is a tile or a belt port, not a building")
    end
    local rec, code, text = layout.entity(ctx.helper_id, ep.layout, ep.i)
    if rec == nil then err.raise(code or "not_found", text or ("layout " .. ep.layout .. " has no building")) end
    if not surface_matches(rec.surface, surface) then
      err.raise("not_found", "args." .. field .. ": layout " .. ep.layout .. " is on another surface")
    end
    local e = find_named(surface, rec.name, rec.pos)
    if e == nil then
      err.raise("not_found", "args." .. field .. ": building " .. ep.i .. " of layout " .. ep.layout .. " (" .. rec.name .. ") is gone")
    end
    out.entity = e
  end
  local p = out.cell and cell_center(out.cell.x, out.cell.y) or out.entity.position
  if not B.charted(h, p) then err.raise("not_charted", "args." .. field .. " is not charted") end
  return out
end

--- Где конец (точка для расстояний).
function M.raw_pos(r)
  if r.cell then return cell_center(r.cell.x, r.cell.y) end
  local p = r.entity.position
  return { x = p.x, y = p.y }
end

--- Что стоит в клетке своей силы (или neutral) нужного типа: сущность │ nil.
function M.entity_of_type(surface, x, y, etype)
  for _, e in ipairs(surface.find_entities_filtered{ area = { left_top = { x = x + 0.05, y = y + 0.05 },
      right_bottom = { x = x + 0.95, y = y + 0.95 } } }) do
    if e.valid and e.type == etype then return e end
  end
  return nil
end

-- ------------------------------------------------------------------ труба: концы у машин

--- Жидкость коробки i: фильтр, закреплённая жидкость или то, что в ней сейчас │ nil.
function M.box_fluid(fb, i)
  local ok, f = pcall(function() return fb.get_filter(i) end)
  if ok and type(f) == "table" and type(f.name) == "string" then return f.name end
  local ok2, locked = pcall(function() return fb.get_locked_fluid(i) end)
  if ok2 and type(locked) == "string" then return locked end
  local ok3, c = pcall(function() return fb[i] end)
  if ok3 and type(c) == "table" and type(c.name) == "string" then return c.name end
  return nil
end

--- Конец трубы у сущности e с жидкостными коробками: клетка свободного соединения коробки с
--- подходящей жидкостью, ближайшая к toward. → {x, y, unit, box, fluid?} │ nil, reason
--- ("fluid_mix" │ "no_free_port" │ "no_fluidbox").
function M.pipe_port(surface, force, pipe, e, fluid, toward)
  local n, fb = beltpath.boxes(e)
  if n == 0 then return nil, "no_fluidbox" end
  local best, mix
  for i = 1, n do
    local bf = M.box_fluid(fb, i)
    if fluid ~= nil and bf ~= nil and bf ~= fluid then
      mix = true
    else
      local W = beltpath.new_world(pipe, nil, "pipe")
      W.allow = { [e.unit_number] = i }
      local env = beltpath.env(W, surface, force)
      for _, t in ipairs(beltpath.box_targets(fb, i) or {}) do
        if beltpath.cell(env, t.x, t.y) > 0 then
          local d = dist(t.x + 0.5, t.y + 0.5, toward.x, toward.y)
          if best == nil or d < best.d or (d == best.d and (t.x < best.x or (t.x == best.x and t.y < best.y))) then
            best = { x = t.x, y = t.y, unit = e.unit_number, box = i, fluid = bf, d = d }
          end
        end
      end
    end
  end
  if best == nil then return nil, mix and "fluid_mix" or "no_free_port" end
  best.d = nil
  return best
end

-- ------------------------------------------------------------------ опоры

--- Сведения об опоре: {w, reach, supply}.
function M.pole_info(name)
  local proto = prototypes.entity[name]
  return { w = M.size_of(proto), reach = M.reach_of(proto), supply = M.supply_of(proto) }
end

--- Конец для опор. r — сырой конец. → {kind = "cell", x, y} │ {kind = "pole", pos, reach} │
--- {kind = "consumer", pos, box = {x1, y1, x2, y2}}.
function M.power_end(r)
  if r.cell then return { kind = "cell", x = r.cell.x, y = r.cell.y } end
  local e = r.entity
  local p = { x = e.position.x, y = e.position.y }
  if e.type == "electric-pole" then
    return { kind = "pole", pos = p, reach = M.reach_of(e.prototype), name = e.name }
  end
  local box = pread(e, "bounding_box")
  local x1, y1, x2, y2 = p.x - 0.5, p.y - 0.5, p.x + 0.5, p.y + 0.5
  if type(box) == "table" then
    local lt, rb = box.left_top or box[1], box.right_bottom or box[2]
    x1, y1, x2, y2 = lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2]
  end
  return { kind = "consumer", pos = p, box = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 } }
end

local function center_of(P, x, y) return x + P.w / 2, y + P.w / 2 end

local function covers(P, cx, cy, box)
  local s = P.supply
  return cx - s < box.x2 and cx + s > box.x1 and cy - s < box.y2 and cy + s > box.y1
end

--- Опора в клетке (x, y) достигает цели goal?
local function at_goal(P, goal, x, y)
  local cx, cy = center_of(P, x, y)
  if goal.kind == "cell" then return x == goal.x and y == goal.y end
  if goal.kind == "pole" then return dist(cx, cy, goal.pos.x, goal.pos.y) <= min(P.reach, goal.reach) end
  return covers(P, cx, cy, goal.box)
end
M.at_goal = at_goal

--- Цель уже под током той же сети, что опора from: стоит опора этой сети, чья зона покрывает клетку
--- цели, или потребитель цели уже в этой сети. Повторная прокладка тогда построила бы вторую линию.
function M.powered(surface, from_pole, goal_r)
  local id = from_pole and pread(from_pole, "electric_network_id")
  if id == nil then return false end
  local e = goal_r.entity
  if e ~= nil then
    return e.valid and pread(e, "electric_network_id") == id
  end
  local c = goal_r.cell
  if c == nil then return false end
  local cx, cy = c.x + 0.5, c.y + 0.5
  local near = surface.find_entities_filtered{ type = "electric-pole", position = { x = cx, y = cy }, radius = 20 }
  for _, p in ipairs(near) do
    if p.valid and pread(p, "electric_network_id") == id then
      local s = M.supply_of(p.prototype)
      local pp = p.position
      if math.abs(pp.x - cx) <= s + 0.5 and math.abs(pp.y - cy) <= s + 0.5 then return true end
    end
  end
  return false
end

--- Опора на конце from уже достаёт цель (ставить нечего)?
function M.already(P, from, goal)
  if from.kind ~= "pole" then return false end
  if goal.kind == "pole" then
    return dist(from.pos.x, from.pos.y, goal.pos.x, goal.pos.y) <= min(from.reach, goal.reach)
  end
  if goal.kind == "consumer" then
    local fp = prototypes.entity[from.name]
    local s = fp and M.supply_of(fp) or 0
    local b = goal.box
    return from.pos.x - s < b.x2 and from.pos.x + s > b.x1 and from.pos.y - s < b.y2 and from.pos.y + s > b.y1
  end
  return false
end

local function heuristic(P, goal, x, y)
  local cx, cy = center_of(P, x, y)
  local d, slack
  if goal.kind == "cell" then
    local gx, gy = center_of(P, goal.x, goal.y)
    d, slack = dist(cx, cy, gx, gy), 0
  elseif goal.kind == "pole" then
    d, slack = dist(cx, cy, goal.pos.x, goal.pos.y), min(P.reach, goal.reach)
  else
    local b = goal.box
    d = dist(cx, cy, (b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2)
    slack = P.supply + sqrt((b.x2 - b.x1) ^ 2 + (b.y2 - b.y1) ^ 2) / 2
  end
  return max(0, d - slack) / max(1, P.reach)
end

-- куча: массивы ключей, f, h, порядка
local function push(S, k, f, h)
  local n = #S.hk + 1
  S.seq = S.seq + 1
  S.hk[n], S.hf[n], S.hh[n], S.hs[n] = k, f, h, S.seq
  local function less(a, b)
    if S.hf[a] ~= S.hf[b] then return S.hf[a] < S.hf[b] end
    if S.hh[a] ~= S.hh[b] then return S.hh[a] < S.hh[b] end
    return S.hs[a] < S.hs[b]
  end
  local i = n
  while i > 1 do
    local p = floor(i / 2)
    if less(i, p) then
      S.hk[i], S.hk[p] = S.hk[p], S.hk[i]
      S.hf[i], S.hf[p] = S.hf[p], S.hf[i]
      S.hh[i], S.hh[p] = S.hh[p], S.hh[i]
      S.hs[i], S.hs[p] = S.hs[p], S.hs[i]
      i = p
    else
      break
    end
  end
end

local function pop(S)
  local n = #S.hk
  if n == 0 then return nil end
  local k = S.hk[1]
  S.hk[1], S.hf[1], S.hh[1], S.hs[1] = S.hk[n], S.hf[n], S.hh[n], S.hs[n]
  S.hk[n], S.hf[n], S.hh[n], S.hs[n] = nil, nil, nil, nil
  n = n - 1
  local function less(a, b)
    if S.hf[a] ~= S.hf[b] then return S.hf[a] < S.hf[b] end
    if S.hh[a] ~= S.hh[b] then return S.hh[a] < S.hh[b] end
    return S.hs[a] < S.hs[b]
  end
  local i = 1
  while true do
    local l, r, m = 2 * i, 2 * i + 1, i
    if l <= n and less(l, m) then m = l end
    if r <= n and less(r, m) then m = r end
    if m == i then break end
    S.hk[i], S.hk[m] = S.hk[m], S.hk[i]
    S.hf[i], S.hf[m] = S.hf[m], S.hf[i]
    S.hh[i], S.hh[m] = S.hh[m], S.hh[i]
    S.hs[i], S.hs[m] = S.hs[m], S.hs[i]
    i = m
  end
  return k
end

--- Новый поиск опор. start: {kind="cell", x, y, placed?} (placed — опора уже в пути, не считается)
--- │ {kind="pole"│"consumer", ...}; goal — конец (M.power_end); budget — раскрытий; left — сколько
--- опор ещё можно поставить; bounds — рамка.
function M.power_new(P, start, goal, budget, left, bounds)
  local S = {
    hk = {}, hf = {}, hh = {}, hs = {}, seq = 0, g = {}, parent = {}, closed = {},
    goal = goal, start = start, budget = budget, left = left, bounds = bounds,
    expansions = 0, best_h = nil, reached = nil,
  }
  if start.kind == "cell" then
    local k = beltpath.key(start.x, start.y)
    local g0 = start.placed and 0 or 1
    S.g[k] = g0
    S.start_key = k
    push(S, k, g0 + heuristic(P, goal, start.x, start.y), heuristic(P, goal, start.x, start.y))
  else
    S.g[M.VSTART] = 0
    push(S, M.VSTART, 0, 0)
  end
  return S
end

local function in_bounds(S, x, y)
  local b = S.bounds
  return x >= b.min_x and x <= b.max_x and y >= b.min_y and y <= b.max_y
end

--- Клетки-кандидаты от виртуального начала (опора или потребитель на конце from).
local function start_cells(P, start)
  local out = {}
  local w = P.w
  if start.kind == "pole" then
    local r = min(P.reach, start.reach)
    for x = floor(start.pos.x - r - w), ceil(start.pos.x + r) do
      for y = floor(start.pos.y - r - w), ceil(start.pos.y + r) do
        local cx, cy = center_of(P, x, y)
        if dist(cx, cy, start.pos.x, start.pos.y) <= r then out[#out + 1] = { x, y } end
      end
    end
  else
    local b, s = start.box, P.supply
    for x = floor(b.x1 - s - w), ceil(b.x2 + s) do
      for y = floor(b.y1 - s - w), ceil(b.y2 + s) do
        local cx, cy = center_of(P, x, y)
        -- опора не встаёт на сам потребитель (это решит движок), но покрыть его должна
        if covers(P, cx, cy, b) then out[#out + 1] = { x, y } end
      end
    end
  end
  return out
end

--- Смещения соседей в пределах провода (не пересекаются с самой опорой).
local function offsets(P)
  local out = {}
  local r = P.reach
  local R = floor(r)
  for dx = -R, R do
    for dy = -R, R do
      if max(abs(dx), abs(dy)) >= P.w and dx * dx + dy * dy <= r * r then out[#out + 1] = { dx, dy } end
    end
  end
  return out
end

local function reconstruct(S, k)
  local cells = {}
  while k ~= nil and k ~= M.VSTART do
    local x, y = beltpath.unkey(k)
    table.insert(cells, 1, { x = x, y = y })
    k = S.parent[k]
  end
  if S.start.kind == "cell" and S.start.placed and cells[1] ~= nil
      and cells[1].x == S.start.x and cells[1].y == S.start.y then
    table.remove(cells, 1)
  end
  return cells
end

--- Шаг поиска опор: work проверок клеток за тик.
--- → "running" │ "found", cells │ "unreachable" │ "limit" (бюджет) │ "too_long".
function M.power_step(S, env, P, work)
  local goal = S.goal
  local offs
  local function consider(k0, g0, x, y)
    if not in_bounds(S, x, y) then return nil end
    local k = beltpath.key(x, y)
    if S.closed[k] then return nil end
    local ng = g0 + 1
    if S.g[k] ~= nil and S.g[k] <= ng then return nil end
    if beltpath.cell(env, x, y) <= 0 then return nil end
    if ng > S.left then
      S.cut = true
      return nil
    end
    S.g[k] = ng
    S.parent[k] = k0
    local h = heuristic(P, goal, x, y)
    if S.best_h == nil or h < S.best_h then
      S.best_h = h
      S.reached = { x = x, y = y }
    end
    if at_goal(P, goal, x, y) then return k end
    push(S, k, ng + h, h)
    return nil
  end
  while work > 0 do
    local k = pop(S)
    if k == nil then return S.cut and "too_long" or "unreachable" end
    if not S.closed[k] then
      S.closed[k] = true
      S.expansions = S.expansions + 1
      if S.expansions > S.budget then return "limit" end
      local g0 = S.g[k]
      if k == M.VSTART then
        for _, c in ipairs(start_cells(P, S.start)) do
          work = work - 1
          local found = consider(k, g0, c[1], c[2])
          if found then return "found", reconstruct(S, found) end
        end
      else
        local x, y = beltpath.unkey(k)
        if k == S.start_key and at_goal(P, goal, x, y) then return "found", reconstruct(S, k) end
        offs = offs or offsets(P)
        for _, o in ipairs(offs) do
          work = work - 1
          local found = consider(k, g0, x + o[1], y + o[2])
          if found then return "found", reconstruct(S, found) end
        end
      end
    end
  end
  return "running"
end

-- ------------------------------------------------------------------ постановка и уборка

local function foot(x, y, w) return beltpath.foot_area(x, y, w or 1) end

--- Проверить (dry) или поставить призрак опоры. → ok, marked.
function M.place_pole(env, step, w, dry)
  local surface, force = env.surface, env.force
  local marked = 0
  if step.natural then
    for _, e in ipairs(surface.find_entities_filtered{ area = foot(step.x, step.y, w) }) do
      if e.valid and beltpath.is_natural(e) and not e.to_be_deconstructed() then
        if dry then
          marked = marked + 1
        elseif e.order_deconstruction(force) then
          marked = marked + 1
          beltpath.note_mark(step, e)
        end
      end
    end
  end
  local position = { x = step.x + w / 2, y = step.y + w / 2 }
  env.W.checks = env.W.checks + 1
  if not surface.can_place_entity{
    name = step.name, position = position, direction = defines.direction.north, force = force,
    build_check_type = defines.build_check_type.manual_ghost, forced = step.natural and true or false,
  } then
    return false, marked
  end
  if dry then return true, marked end
  local ghost = surface.create_entity{
    name = "entity-ghost", inner_name = step.name, position = position, direction = defines.direction.north,
    force = force, quality = "normal", raise_built = true,
  }
  return ghost ~= nil, marked
end

--- Свой призрак постройки name в клетке (опора — на месте w×w) │ nil.
function M.own_ghost(surface, force_name, x, y, name, w)
  for _, e in ipairs(surface.find_entities_filtered{ area = foot(x, y, w), type = "entity-ghost" }) do
    if e.valid and e.type == "entity-ghost" and e.ghost_name == name and e.force ~= nil
        and e.force.name == force_name then
      return e
    end
  end
  return nil
end

--- Стоит ли в клетке постройка name своей силы.
function M.built_at(surface, force_name, x, y, name, w)
  for _, e in ipairs(surface.find_entities_filtered{ area = foot(x, y, w), name = name }) do
    if e.valid and e.type ~= "entity-ghost" and e.name == name and e.force ~= nil and e.force.name == force_name then
      return true
    end
  end
  return false
end

--- Снять свои пометки к сносу шага (step.marks — что пометила сама задача). → сколько снято.
function M.unmark(surface, force, step)
  local n = 0
  for _, m in ipairs(step.marks or {}) do
    local found = surface.find_entities_filtered{ name = m.name, position = { x = m.x, y = m.y }, limit = 1 }
    local e = found[1]
    if e ~= nil and e.valid and e.to_be_deconstructed() then
      if pcall(function() e.cancel_deconstruction(force) end) then n = n + 1 end
    end
  end
  step.marks = nil
  return n
end

--- Убрать свои непостроенные призраки шагов (s.placed) и снять их пометки. Тело не нужно.
--- → removed, unmarked.
function M.cleanup(cn)
  local surface = game.surfaces[cn.surface]
  local force = game.forces[cn.force]
  if surface == nil or force == nil then return 0, 0 end
  local removed, unmarked = 0, 0
  for _, s in ipairs(cn.flat or {}) do
    if s.placed then
      local g = M.own_ghost(surface, cn.force, s.x, s.y, s.name, s.w or 1)
      if g ~= nil then
        g.destroy{ raise_destroy = true }
        removed = removed + 1
      end
      s.placed = nil
    end
    -- и у шага, призрак которого не встал после пометки
    if s.marks ~= nil then unmarked = unmarked + M.unmark(surface, force, s) end
  end
  return removed, unmarked
end

-- ------------------------------------------------------------------ память последней прокладки

local function ser(v, out)
  local t = type(v)
  if t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    out[#out + 1] = "{"
    for _, k in ipairs(keys) do
      out[#out + 1] = k .. "="
      local x = v[k]
      if x == nil then x = v[tonumber(k)] end
      ser(x, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  else
    out[#out + 1] = tostring(v)
  end
end

--- Подпись аргументов прокладки (без build, mode, auto_supply, dry_run).
function M.signature(a)
  local out = {}
  ser({
    kind = a.kind, from = a.from, to = a.to, via = a.via, max_length = a.max_length,
    belt = a.belt, pipe = a.pipe, pole = a.pole, underground = a.underground, fluid = a.fluid,
  }, out)
  return table.concat(out)
end

--- Запись помощника │ nil (ключа нет — ядро его ещё не создало: тогда ничего не помним).
function M.last(helper_id)
  local mem = storage.connect_last
  if type(mem) ~= "table" then return nil end
  local rec = mem[helper_id]
  if type(rec) ~= "table" or type(rec.cells) ~= "table" or type(rec.sig) ~= "string" then return nil end
  return rec
end

function M.remember(helper_id, rec)
  local mem = storage.connect_last
  if type(mem) ~= "table" then return end
  if rec ~= nil and #rec.cells > M.MAX_REMEMBERED then rec = nil end
  mem[helper_id] = rec
end

function M.forget(helper_id, sig)
  local mem = storage.connect_last
  if type(mem) ~= "table" then return end
  local rec = mem[helper_id]
  if type(rec) == "table" and (sig == nil or rec.sig == sig) then mem[helper_id] = nil end
end

-- ------------------------------------------------------------------ счёт предметов

--- Чего не хватает в карманах: need − есть │ {}.
function M.missing(h, need)
  local main = h.get_main_inventory()
  local out = {}
  for name, n in pairs(need) do
    local have = main and inv.count(main, name) or 0
    if have < n then out[name] = n - have end
  end
  return out
end

return M
