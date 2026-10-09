-- Операция `rates` (поток L). Контракт: docs/STATE.md «rates», docs/PROTOCOL.md §4, §6.7, §6.11.
--
-- scope="surface": фактическая статистика производства силы на поверхности
--   (LuaFlowStatistics.get_flow_count, count=true -> количество за весь период).
-- scope="area": номинальная оценка по машинам в прямоугольнике (в минуту, nominal=true).
--   Идея «сгруппировать машины по рецепту и сложить номинальные потоки» — как у мода
--   Rate Calculator (MIT); код написан заново, текст оттуда не брался.
--
-- Категории LuaFlowStatistics (проверено по lua-api.factorio.com/2.0.77, LuaFlowStatistics):
--   "input"  = левая колонка окна статистики = ПРОИЗВЕДЕНО;
--   "output" = правая колонка = ПОТРЕБЛЕНО.
-- (В STATE.md ревизии 2 категории перепутаны — вынесено в contract_issues.)
--
-- Только чтение: ничего не меняет в игре, в storage не пишет.
local err = require("scripts.core.err")
local owner = require("scripts.core.owner")

local M = {}

local MADE_CATEGORY = "input"
local USED_CATEGORY = "output"

local PERIODS = { ["1m"] = "one_minute", ["10m"] = "ten_minutes", ["1h"] = "one_hour" }
local KNOWN_ARGS = { scope = true, area = true, surface = true, period = true, items = true, top = true }
local TOP_DEFAULT, TOP_MAX = 20, 200
local ITEMS_MAX = 100
local NAME_MAX = 200
local AREA_SIDE_MAX = 128
local MACHINES_MAX = 100
local CHUNK = 32
local MACHINE_TYPES = { "assembling-machine", "furnace", "mining-drill", "rocket-silo" }

-- ---------------------------------------------------------------- утилиты

local function round2(x)
  if x >= 0 then return math.floor(x * 100 + 0.5) / 100 end
  return -math.floor(-x * 100 + 0.5) / 100
end

local function round1(x)
  if x >= 0 then return math.floor(x * 10 + 0.5) / 10 end
  return -math.floor(-x * 10 + 0.5) / 10
end

local function is_finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- Чтение свойства LuaObject, которое у этого типа может отсутствовать (API бросает ошибку).
local function prop(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

-- Вызов метода без аргументов (стиль Factorio — через точку), nil если у типа его нет.
local function call0(obj, method)
  local ok, a, b = pcall(function() return obj[method]() end)
  if ok then return a, b end
  return nil
end

local function add(t, name, v)
  t[name] = (t[name] or 0) + v
end

local function round_map(t)
  local out = {}
  for k, v in pairs(t) do
    local r = round2(v)
    if r ~= 0 then out[k] = r end
  end
  return out
end

-- ---------------------------------------------------------------- аргументы

local function bad(text) err.raise("bad_args", text) end

local function check_name(s, field)
  if type(s) ~= "string" or s == "" or #s > NAME_MAX then bad(field .. ": ожидается непустая строка") end
end

local function parse_pos(p, field)
  if type(p) ~= "table" or not is_finite(p.x) or not is_finite(p.y) then
    bad(field .. ": ожидается {x:number, y:number}")
  end
  return { x = p.x, y = p.y }
end

local function parse_area(a)
  if type(a) ~= "table" then bad("area: ожидается {left_top, right_bottom}") end
  local lt = parse_pos(a.left_top, "area.left_top")
  local rb = parse_pos(a.right_bottom, "area.right_bottom")
  if rb.x <= lt.x or rb.y <= lt.y then bad("area: right_bottom должен быть правее и ниже left_top") end
  if rb.x - lt.x > AREA_SIDE_MAX or rb.y - lt.y > AREA_SIDE_MAX then
    err.raise("limit", "area: сторона больше " .. AREA_SIDE_MAX)
  end
  return { left_top = lt, right_bottom = rb }
end

local function parse_args(args)
  if args == nil then args = {} end
  if type(args) ~= "table" then bad("args: ожидается объект") end
  for k in pairs(args) do
    if not KNOWN_ARGS[k] then bad("неизвестное поле: " .. tostring(k)) end
  end
  local a = {}

  a.scope = args.scope == nil and "surface" or args.scope
  if a.scope ~= "surface" and a.scope ~= "area" then bad('scope: "surface" или "area"') end

  a.period = args.period == nil and "1m" or args.period
  if type(a.period) ~= "string" or not PERIODS[a.period] then bad('period: "1m", "10m" или "1h"') end

  if args.top == nil then
    a.top = TOP_DEFAULT
  else
    local t = args.top
    if not is_finite(t) or t ~= math.floor(t) or t < 1 or t > TOP_MAX then
      bad("top: целое 1.." .. TOP_MAX)
    end
    a.top = t
  end

  if args.items ~= nil then
    local list = args.items
    if type(list) ~= "table" then bad("items: ожидается список имён") end
    local n = 0
    for _ in pairs(list) do n = n + 1 end
    if n > ITEMS_MAX then err.raise("limit", "items: больше " .. ITEMS_MAX .. " имён") end
    a.items = {}
    for i = 1, n do
      local name = list[i]
      if name == nil then bad("items: ожидается список имён") end
      check_name(name, "items[" .. i .. "]")
      a.items[#a.items + 1] = name
    end
  end

  if args.surface ~= nil then
    check_name(args.surface, "surface")
    a.surface = args.surface
  end

  if a.scope == "area" then
    if args.area == nil then bad("area: обязательно при scope=\"area\"") end
    a.area = parse_area(args.area)
  elseif args.area ~= nil then
    bad("area: только при scope=\"area\"")
  end
  return a
end

-- ---------------------------------------------------------------- поверхность и сила

local function resolve(a, ctx)
  local helper = ctx and ctx.entity
  if helper ~= nil and not helper.valid then helper = nil end
  local force, surface
  if helper then
    force, surface = helper.force, helper.surface
  end
  if a.surface then
    surface = game.surfaces[a.surface]
    if not surface then err.raise("not_found", "surface: нет поверхности " .. a.surface) end
  end
  if not force or not surface then
    local p = owner.present()
    if p then
      force = force or p.force
      surface = surface or p.physical_surface
    end
  end
  if not surface then err.raise("no_player", "нет помощника, хозяина онлайн и surface") end
  if not force then force = game.forces["player"] end
  if not force then err.raise("internal", "нет силы") end
  return force, surface
end

-- ---------------------------------------------------------------- scope = surface

local function flow_table(stats, kind, a, precision)
  local proto = (kind == "item") and prototypes.item or prototypes.fluid
  local names = {}
  if a.items then
    for _, n in ipairs(a.items) do
      if proto[n] then names[#names + 1] = n end
    end
  else
    local seen = {}
    for n in pairs(stats.input_counts) do
      if not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    for n in pairs(stats.output_counts) do
      if not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
  end

  local rows = {}
  for _, n in ipairs(names) do
    -- Имя-строка = качество normal (ItemWithQualityID), PROTOCOL §6.11.
    -- Ошибка API не прячется за нулями: пустой ответ выглядел бы как «ничего не производится».
    local function flow(category)
      local ok, v = pcall(function()
        return stats.get_flow_count { name = n, category = category, precision_index = precision, count = true }
      end)
      if not ok or not is_finite(v) then
        err.raise("internal", "get_flow_count(" .. n .. ", " .. category .. "): " .. tostring(ok and "не число" or v))
      end
      return round2(v)
    end
    local made, used = flow(MADE_CATEGORY), flow(USED_CATEGORY)
    if a.items or made ~= 0 or used ~= 0 then
      rows[#rows + 1] = { name = n, made = made, used = used, turn = made + used }
    end
  end

  local truncated = false
  if not a.items then
    table.sort(rows, function(x, y)
      if x.turn ~= y.turn then return x.turn > y.turn end
      return x.name < y.name
    end)
    if #rows > a.top then truncated = true end
  end

  local out, limit = {}, a.items and #rows or math.min(#rows, a.top)
  for i = 1, limit do
    local r = rows[i]
    out[r.name] = { made = r.made, used = r.used }
  end
  return out, truncated
end

local function rates_surface(a, force, surface)
  local precision = defines.flow_precision_index[PERIODS[a.period]]
  local istats = force.get_item_production_statistics(surface)
  local fstats = force.get_fluid_production_statistics(surface)
  local items, t1 = flow_table(istats, "item", a, precision)
  local fluids, t2 = flow_table(fstats, "fluid", a, precision)
  return {
    scope = "surface", surface = surface.name, period = a.period,
    items = items, fluids = fluids, truncated = (t1 or t2) and true or false,
  }
end

-- ---------------------------------------------------------------- scope = area

-- Ожидаемое число продукта за один цикл и его продуктивная часть.
local function product_amounts(p)
  local base
  if p.amount ~= nil then
    base = p.amount
  elseif p.amount_min ~= nil and p.amount_max ~= nil then
    base = (p.amount_min + p.amount_max) / 2
  else
    base = 0
  end
  local prob = p.probability or 1
  local expected = base * prob + (p.extra_count_fraction or 0)
  local ignored = math.min(base, p.ignored_by_productivity or 0) * prob
  return expected, math.max(0, expected - ignored)
end

local function name_of(x)
  if type(x) == "string" then return x end
  if type(x) == "table" or type(x) == "userdata" then return prop(x, "name") end
  return nil
end

local function quality_name(q)
  if q == nil then return "normal" end
  return name_of(q) or "normal"
end

-- Рецепт машины (LuaRecipe) или nil. Печь без текущего рецепта — последний рецепт.
local function machine_recipe(e)
  local recipe, quality = call0(e, "get_recipe")
  if recipe == nil and e.type == "furnace" then
    local prev = prop(e, "previous_recipe")
    if prev then
      local rname = name_of(prev.name) or name_of(prev)
      quality = prev.quality
      if rname then recipe = e.force.recipes[rname] end
    end
  end
  return recipe, quality_name(quality)
end

-- Бонус продуктивности машины, ограниченный maximum_productivity рецепта (по умолчанию в игре 3 = +300%).
local MAX_PRODUCTIVITY_DEFAULT = 3
local function capped_productivity(e, recipe)
  local prod = prop(e, "productivity_bonus")
  if not is_finite(prod) or prod < 0 then prod = 0 end
  local cap = prop(recipe, "maximum_productivity")
  if not is_finite(cap) then cap = MAX_PRODUCTIVITY_DEFAULT end
  return math.min(prod, cap)
end

-- Номинальный поток в минуту. Возвращает key, recipe_name, in{}, out{} или nil (машина не считается).
local function crafter_flow(e)
  local recipe, q = machine_recipe(e)
  if not recipe then return nil end
  if q ~= "normal" then return nil end -- §6.11: не-normal продукты не видим
  local energy = recipe.energy
  local speed = prop(e, "crafting_speed")
  if not is_finite(energy) or energy <= 0 or not is_finite(speed) or speed <= 0 then return nil end
  local prod = capped_productivity(e, recipe)
  local cpm = speed / energy * 60 -- циклов в минуту
  local fin, fout = {}, {}
  for _, ing in ipairs(recipe.ingredients or {}) do
    if ing.name and is_finite(ing.amount) then add(fin, ing.name, cpm * ing.amount) end
  end
  for _, p in ipairs(recipe.products or {}) do
    if p.name then
      local expected, productive = product_amounts(p)
      add(fout, p.name, cpm * (expected + productive * prod))
    end
  end
  return recipe.name, fin, fout
end

local function drill_flow(e)
  local target = prop(e, "mining_target")
  if not target or not target.valid then return nil end
  local rp = target.prototype
  local mp = rp and rp.mineable_properties
  if not mp or not mp.minable then return nil end
  local mining_time = mp.mining_time
  local base_speed = e.prototype and e.prototype.mining_speed
  if not is_finite(mining_time) or mining_time <= 0 or not is_finite(base_speed) or base_speed <= 0 then
    return nil
  end
  local speed = base_speed * (1 + (prop(e, "speed_bonus") or 0))
  local prod = prop(e, "productivity_bonus") or 0
  local cpm = speed / mining_time * 60
  -- Бесконечные ресурсы (нефть и т.п.): выход пропорционален amount / normal_resource_amount.
  local yield = 1
  if prop(rp, "infinite_resource") then
    local normal = prop(rp, "normal_resource_amount")
    if is_finite(normal) and normal > 0 and is_finite(target.amount) then
      yield = target.amount / normal
    end
  end
  local fin, fout = {}, {}
  for _, p in ipairs(mp.products or {}) do
    if p.name then
      local expected, productive = product_amounts(p)
      add(fout, p.name, cpm * yield * (expected + productive * prod))
    end
  end
  -- fluid_amount в прототипе ресурса задан на 10 циклов добычи (урановая руда: 10 -> 1 кислоты на руду).
  if mp.required_fluid and is_finite(mp.fluid_amount) and mp.fluid_amount > 0 then
    add(fin, mp.required_fluid, cpm * mp.fluid_amount / 10)
  end
  return target.name, fin, fout
end

local function rates_area(a, force, surface)
  local wanted
  if a.items then
    wanted = {}
    for _, n in ipairs(a.items) do wanted[n] = true end
  end

  local entities = surface.find_entities_filtered { area = a.area, force = force, type = MACHINE_TYPES }

  local visible_cache = {}
  local function visible(pos)
    local cx, cy = math.floor(pos.x / CHUNK), math.floor(pos.y / CHUNK)
    local key = cx .. ":" .. cy
    local v = visible_cache[key]
    if v == nil then
      v = force.is_chunk_visible(surface, { x = cx, y = cy }) and true or false
      visible_cache[key] = v
    end
    return v
  end

  local groups, order, hidden, idle = {}, {}, 0, 0
  for _, e in ipairs(entities) do
    if e.valid then
      if not visible(e.position) then
        hidden = hidden + 1
      else
        local rname, fin, fout
        if e.type == "mining-drill" then
          rname, fin, fout = drill_flow(e)
        else
          rname, fin, fout = crafter_flow(e)
        end
        if not rname then
          idle = idle + 1
        else
          local key = e.name .. "|" .. rname
          local g = groups[key]
          if not g then
            g = { name = e.name, recipe = rname, count = 0, ["in"] = {}, out = {} }
            groups[key] = g
            order[#order + 1] = key
          end
          g.count = g.count + 1
          for n, v in pairs(fin) do add(g["in"], n, v) end
          for n, v in pairs(fout) do add(g.out, n, v) end
        end
      end
    end
  end

  local function touches(g)
    if not wanted then return true end
    for n in pairs(g["in"]) do if wanted[n] then return true end end
    for n in pairs(g.out) do if wanted[n] then return true end end
    return false
  end

  local list, net = {}, {}
  for _, key in ipairs(order) do
    local g = groups[key]
    if touches(g) then
      for n, v in pairs(g.out) do add(net, n, v) end
      for n, v in pairs(g["in"]) do add(net, n, -v) end
      list[#list + 1] = g
    end
  end
  table.sort(list, function(x, y)
    if x.count ~= y.count then return x.count > y.count end
    if x.name ~= y.name then return x.name < y.name end
    return x.recipe < y.recipe
  end)

  local machines = {}
  for i = 1, math.min(#list, MACHINES_MAX) do
    local g = list[i]
    machines[i] = { name = g.name, recipe = g.recipe, count = g.count, ["in"] = round_map(g["in"]), out = round_map(g.out) }
  end

  if wanted then
    local filtered = {}
    for n, v in pairs(net) do if wanted[n] then filtered[n] = v end end
    net = filtered
  end

  return {
    scope = "area", surface = surface.name,
    area = {
      left_top = { x = round1(a.area.left_top.x), y = round1(a.area.left_top.y) },
      right_bottom = { x = round1(a.area.right_bottom.x), y = round1(a.area.right_bottom.y) },
    },
    machines = machines, net = round_map(net), nominal = true, per = "1m",
    hidden = hidden, idle = idle, truncated = #list > MACHINES_MAX,
  }
end

-- ---------------------------------------------------------------- операция

M.ops = {
  rates = function(args, ctx)
    local a = parse_args(args)
    if a.items then
      for _, n in ipairs(a.items) do
        if not prototypes.item[n] and not prototypes.fluid[n] then bad("items: нет предмета или жидкости " .. n) end
      end
    end
    local force, surface = resolve(a, ctx)
    if a.scope == "surface" then return rates_surface(a, force, surface) end
    return rates_area(a, force, surface)
  end,
}

-- Для тестов.
M._internal = { parse_args = parse_args, product_amounts = product_amounts, round2 = round2 }

return M
