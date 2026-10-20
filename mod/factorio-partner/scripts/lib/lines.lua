-- Источники предметов для `collect` и `get_items`: склады хозяина, выходы его линий и выходы машин.
-- Контракт: docs/ACTIONS.md («collect», «get_items», аргумент `from_lines`).
--
-- Виды источников:
--   chest   — контейнер или логистический сундук своей силы, в который ничего не кладут: свой склад;
--   line    — такой же сундук, но в него кладёт манипулятор (drop_target) или загрузчик на вход
--             (loader_type = "input", loader_container): выход линии хозяина;
--   machine — сборщик или печь своей силы: только выходной слот (get_output_inventory). Входы,
--             топливо и модули машины источником не бывают никогда.
-- Без from_lines берутся только chest; line и machine — с явного разрешения хозяина (from_lines).
-- Что лежит в выходах линий и машин без разрешения, собирается в сводку `lines` — для подсказки
-- агенту («есть N штук, нужно разрешение»).
-- Видимость как у `stock` (PROTOCOL §6.7): содержимое — только в видимых чанках. Машина, занятая
-- другим помощником (storage.reservations.machines), не источник.
local reserve = require("scripts.core.reserve")
local C = require("scripts.perception.state").common
local stock = require("scripts.perception.stock")

local M = {}

M.MACHINE_TYPES = { "assembling-machine", "furnace" }
M.FEEDER_TYPES = { "inserter", "loader", "loader-1x1" }
M.REACH_MIN = 2      -- наименьшая дальность, на которую ищем манипуляторы и загрузчики хозяина
M.HINT_SPOTS = 3     -- мест в подсказке на предмет
M.MAX_SPOTS = 64     -- ближних выходов в сводке (она лежит в задаче, в storage)

local function field(x, key)
  local ok, v = pcall(function() return x[key] end)
  if ok then return v end
  return nil
end

local function unit_of(e)
  if e == nil then return nil end
  local ok, u = pcall(function() return e.valid and e.unit_number or nil end)
  if ok then return u end
  return nil
end

local function vec_len(v)
  if type(v) ~= "table" then return 0 end
  local x, y = v.x or v[1], v.y or v[2]
  if type(x) ~= "number" or type(y) ~= "number" then return 0 end
  return math.sqrt(x * x + y * y)
end

-- наибольшая дальность манипуляторов из прототипов (кэш модуля, не storage; считается раз за загрузку)
local reach_cache, reach_for

--- Наибольшая дальность взятия/выброса манипуляторов из прототипов (длинные и модовые тоже).
function M.reach()
  if reach_cache ~= nil and reach_for == prototypes then return reach_cache end
  local best = M.REACH_MIN
  local ok, protos = pcall(function()
    return prototypes.get_entity_filtered{ { filter = "type", type = "inserter" } }
  end)
  if ok and type(protos) == "table" then
    for _, p in pairs(protos) do
      best = math.max(best, vec_len(field(p, "inserter_pickup_position")), vec_len(field(p, "inserter_drop_position")))
    end
  end
  reach_cache, reach_for = best, prototypes
  return best
end

--- Множество unit_number сущностей, в которые кладут манипуляторы и загрузчики своей силы,
--- в круге radius (+ дальность манипуляторов) вокруг center.
function M.fed(surface, force, center, radius)
  local out = {}
  local ok, list = pcall(function()
    return surface.find_entities_filtered{ type = M.FEEDER_TYPES, force = force, position = center,
      radius = radius + M.reach() }
  end)
  if not ok or type(list) ~= "table" then return out end
  for _, x in ipairs(list) do
    if x.valid then
      local u
      if x.type == "inserter" then
        u = unit_of(field(x, "drop_target"))
      elseif field(x, "loader_type") == "input" then
        u = unit_of(field(x, "loader_container"))
      end
      if u ~= nil then out[u] = true end
    end
  end
  return out
end

--- Выходной слот машины (готовая продукция) или nil.
function M.output_inventory(e)
  local ok, i = pcall(function() return e.get_output_inventory() end)
  if ok and i ~= nil and i.valid then return i end
  return nil
end

local function machines(surface, force, center, radius, filter, helper_id)
  local view = C.chunk_view(force, surface, helper_id)
  local out = {}
  local ok, list = pcall(function()
    return surface.find_entities_filtered{ type = M.MACHINE_TYPES, force = force, position = center, radius = radius }
  end)
  if not ok or type(list) ~= "table" then return out end
  for _, e in ipairs(list) do
    if e.valid and view.visible(e.position)
        and not (e.unit_number ~= nil and reserve.machine_holder(helper_id, e.unit_number) ~= nil) then
      local items = C.inv_counts(M.output_inventory(e), filter)
      if next(items) ~= nil then
        out[#out + 1] = {
          unit = e.unit_number, name = e.name, pos = C.rpos(e.position), dist = C.dist(e.position, center),
          items = items, kind = "machine",
        }
      end
    end
  end
  return out
end

local function by_dist(a, b)
  if a.dist ~= b.dist then return a.dist < b.dist end
  return (a.unit or 0) < (b.unit or 0)
end

--- Источники вокруг center. opts.from_lines — брать и выходы линий, и выходы машин;
--- opts.hint — без from_lines собрать сводку того, что лежит в выходах (для подсказки).
--- → {containers = [{unit, name, pos, dist, items, kind}] (разрешённые, по возрастанию dist),
---    total = {name = count} (по разрешённым), hidden,
---    lines = {total = {name = count}, spots = [{unit, name, pos, items, kind}]} (только без from_lines и с hint)}
function M.scan(surface, force, center, radius, filter, helper_id, opts)
  opts = opts or {}
  local scan = stock.scan(surface, force, center, radius, filter, helper_id)
  local fed = next(scan.containers) ~= nil and M.fed(surface, force, center, radius) or {}
  local allowed, excluded, total = {}, {}, {}
  for _, c in ipairs(scan.containers) do
    c.kind = (c.unit ~= nil and fed[c.unit]) and "line" or "chest"
    if c.kind == "chest" or opts.from_lines then
      allowed[#allowed + 1] = c
    else
      excluded[#excluded + 1] = c
    end
  end
  if opts.from_lines or opts.hint then
    for _, m in ipairs(machines(surface, force, center, radius, filter, helper_id)) do
      if opts.from_lines then allowed[#allowed + 1] = m else excluded[#excluded + 1] = m end
    end
  end
  table.sort(allowed, by_dist)
  for _, c in ipairs(allowed) do C.add_counts(total, c.items) end
  local out = { containers = allowed, total = total, hidden = scan.hidden }
  if opts.hint and not opts.from_lines then
    table.sort(excluded, by_dist)
    local lt, spots = {}, {}
    for i, c in ipairs(excluded) do
      C.add_counts(lt, c.items)
      if i <= M.MAX_SPOTS then spots[i] = c end
    end
    out.lines = { total = lt, spots = spots }
  end
  return out
end

--- Подсказка по предмету name из сводки lines: nil, если в выходах его нет; иначе
--- {count, at = [{pos, count, kind}] (до HINT_SPOTS ближних), hint = текст}.
function M.hint(lines, name)
  if lines == nil then return nil end
  local n = lines.total[name] or 0
  if n <= 0 then return nil end
  local at = {}
  for _, c in ipairs(lines.spots) do
    local k = c.items[name] or 0
    if k > 0 then
      at[#at + 1] = { pos = c.pos, count = k, kind = c.kind }
      if #at >= M.HINT_SPOTS then break end
    end
  end
  return {
    count = n, at = at,
    hint = "есть " .. n .. " шт. в выходах линий хозяина (нужно разрешение: from_lines)",
  }
end

return M
