-- Операция `find` (поток G, ревизия 3.2): «где у нас делают / тратят / хранят X» по всей
-- поверхности. Контракт: docs/STATE.md «find», docs/PROTOCOL.md §4, §6.7 (два уровня обзора),
-- §6.11 (только качество normal).
--
-- Образец идеи — мод Factory Search (MIT, автор Xorimuth): обычный find_entities_filtered по
-- поверхности и разбор рецептов машин. Программного входа с данными у того мода нет, код
-- написан заново, текст оттуда не брался.
--
-- Что считается:
--   producers — сборщики/печи/ракетные шахты, чей рецепт даёт предмет; буры (и насосы-качалки)
--               по руде под ними (mining_target); для жидкости — ещё береговые насосы;
--   consumers — машины, чей рецепт тратит предмет; лаборатории (lab_inputs); буры, которым
--               нужна эта жидкость (required_fluid);
--   storage   — сундуки и логистические сундуки (предмет), цистерны (жидкость);
--   entities  — сами постройки с таким именем (или которые ставятся этим предметом).
-- Честность: только сущности силы помощника (хозяина) в открытых чанках; содержимое складов —
-- живое, только в видимых чанках, остальные склады считаются в `hidden`.
-- Только чтение: ничего не меняет в игре, в storage не пишет.
local err = require("scripts.core.err")
local core_owner = require("scripts.core.owner")
local C = require("scripts.perception.state").common

local M = {}

M.DEFAULT_LIMIT = 20
M.MAX_LIMIT = 50
M.GROUP_DIST = 32        -- постройки ближе 32 клеток друг к другу — одна группа
M.CELL = 16              -- сетка для группировки (см. cluster)
M.MAX_CHUNKS = 4000      -- поверхность больше — `limit`
M.MAX_ENTITIES = 20000   -- найдено больше — `limit`
M.MAX_NAMES = 8          -- имён построек в одной группе (самые частые)
M.NAME_MAX = 200

M.KINDS = { "producers", "consumers", "storage", "entities" }
M.DEFAULT_KINDS = { "producers", "consumers", "storage" }
local KIND_ORDER = { producers = 1, consumers = 2, storage = 3, entities = 4 }

local CRAFTER = { ["assembling-machine"] = true, furnace = true, ["rocket-silo"] = true }
local STORAGE_ITEM = { "container", "logistic-container" }
local STORAGE_FLUID = { "storage-tank" }

local floor, sqrt, max = math.floor, math.sqrt, math.max

-- ---------------------------------------------------------------- чтение LuaObject

-- Свойство, которого у этого типа сущности может не быть (API бросает ошибку).
local function prop(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

-- Метод без аргументов (стиль Factorio — через точку); nil, если у типа его нет.
local function call0(obj, method)
  local ok, a, b = pcall(function() return obj[method]() end)
  if ok then return a, b end
  return nil
end

local function name_of(x)
  if type(x) == "string" then return x end
  if type(x) == "table" or type(x) == "userdata" then return prop(x, "name") end
  return nil
end

-- ---------------------------------------------------------------- аргументы

local function parse_kinds(v)
  if v == nil then
    local set = {}
    for _, k in ipairs(M.DEFAULT_KINDS) do set[k] = true end
    return set
  end
  if type(v) ~= "table" then C.bad("kinds", "must be a list") end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n > #M.KINDS then err.raise("limit", "kinds: at most " .. #M.KINDS .. " kinds") end
  local set = {}
  for i = 1, n do
    local k = v[i]
    if type(k) ~= "string" or KIND_ORDER[k] == nil then
      C.bad("kinds", "must be a list of " .. table.concat(M.KINDS, ", "))
    end
    set[k] = true
  end
  if next(set) == nil then C.bad("kinds", "must not be empty") end
  return set
end

local function parse_args(args)
  args = C.check_args(args)
  C.allow_only(args, { item = true, kinds = true, surface = true, limit = true })
  local a = {}
  if args.item == nil then C.bad("item", "required") end
  a.item = C.check_string(args.item, "item", M.NAME_MAX)
  a.kinds = parse_kinds(args.kinds)
  a.surface = C.check_string(args.surface, "surface", M.NAME_MAX)
  a.limit = C.check_int(args.limit, "limit", 1, M.MAX_LIMIT, M.DEFAULT_LIMIT)
  return a
end

-- Что это за имя: предмет, жидкость, постройка (для kinds=entities).
local function classify(a)
  local is_item = prototypes.item ~= nil and prototypes.item[a.item] ~= nil
  local is_fluid = prototypes.fluid ~= nil and prototypes.fluid[a.item] ~= nil
  local entity_name
  if prototypes.entity ~= nil and prototypes.entity[a.item] ~= nil then
    entity_name = a.item
  elseif is_item then
    local placed = prop(prototypes.item[a.item], "place_result")
    entity_name = name_of(placed)
  end
  if not is_item and not is_fluid and not (a.kinds.entities and entity_name ~= nil) then
    C.bad("item", "no item or fluid named " .. a.item)
  end
  return is_item, is_fluid, entity_name
end

-- ---------------------------------------------------------------- где искать

-- → surface, force, center|nil, helper_id|nil. Явный `surface` сильнее; без помощника —
-- поверхность и сила хозяина (PROTOCOL §4 «h? без помощника»: хозяина нет онлайн → no_player).
local function resolve(a, ctx)
  local e = C.helper_entity(ctx, false)
  local owner = C.owner_player()
  local present = core_owner.present() ~= nil
  local surface, force, center

  if a.surface ~= nil then
    surface = game.surfaces[a.surface]
    if surface == nil or surface.valid == false then
      err.raise("not_found", "surface: no surface named " .. a.surface)
    end
  end
  if e ~= nil then
    force = e.force
    surface = surface or e.surface
    if e.surface.index == surface.index then center = e.position end
  else
    if surface == nil then
      if not present then err.raise("no_player", "no helper given, owner is not online and no surface given") end
      surface = owner.physical_surface
    end
    force = owner ~= nil and owner.force or nil
  end
  if force == nil then force = game.forces and game.forces["player"] or nil end
  if force == nil then err.raise("internal", "no force to search for") end
  if center == nil and present and owner.physical_surface.index == surface.index then
    center = owner.physical_position
  end
  if center ~= nil then center = { x = center.x or center[1], y = center.y or center[2] } end
  return surface, force, center, ctx and ctx.helper_id or nil
end

-- ---------------------------------------------------------------- рецепты и машины

local function is_normal(q)
  if q == nil then return true end
  return (name_of(q) or "normal") == "normal"
end

-- Рецепт машины и его качество. Печь без текущего рецепта — последний рецепт.
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
  return recipe, quality
end

local function lists(list, item)
  if type(list) ~= "table" then return false end
  for _, p in ipairs(list) do
    if type(p) == "table" and p.name == item then return true end
  end
  return false
end

local function contains(list, item)
  if type(list) ~= "table" then return false end
  for _, n in ipairs(list) do
    if n == item then return true end
  end
  return false
end

-- Машина → делает ли предмет, тратит ли, и подпись рецепта (или nil).
local function machine_role(e, item)
  local t = e.type
  if CRAFTER[t] then
    local recipe, quality = machine_recipe(e)
    if recipe == nil or not is_normal(quality) then return false, false end
    return lists(prop(recipe, "products"), item), lists(prop(recipe, "ingredients"), item), name_of(recipe)
  end
  if t == "mining-drill" then
    local target = prop(e, "mining_target")
    if target == nil or target.valid == false then return false, false end
    local mp = prop(prop(target, "prototype") or {}, "mineable_properties")
    if type(mp) ~= "table" then return false, false end
    return lists(mp.products, item), mp.required_fluid == item, nil
  end
  if t == "lab" then
    return false, contains(prop(prop(e, "prototype") or {}, "lab_inputs"), item), nil
  end
  if t == "offshore-pump" then
    local fluid = name_of(call0(e, "get_fluid_source_fluid"))
    if fluid ~= nil then return fluid == item, false, nil end
    local contents = call0(e, "get_fluid_contents")
    return type(contents) == "table" and (contents[item] or 0) > 0, false, nil
  end
  return false, false
end

-- ---------------------------------------------------------------- сбор

-- Считает до поиска (count_entities_filtered дешевле таблицы на десятки тысяч сущностей) и
-- копит общий счёт: больше MAX_ENTITIES → limit.
local function search(surface, filter, budget)
  local n = surface.count_entities_filtered(filter)
  budget.n = budget.n + n
  if budget.n > M.MAX_ENTITIES then
    err.raise("limit", "more than " .. M.MAX_ENTITIES .. " entities to look through: narrow kinds")
  end
  if n == 0 then return {} end
  return surface.find_entities_filtered(filter)
end

local function check_surface_size(surface)
  local n = 0
  for _ in surface.get_chunks() do
    n = n + 1
    if n > M.MAX_CHUNKS then
      err.raise("limit", "surface " .. surface.name .. " has more than " .. M.MAX_CHUNKS .. " chunks")
    end
  end
end

local function machine_types(kinds, is_item, is_fluid)
  local types = { "assembling-machine", "furnace", "rocket-silo", "mining-drill" }
  if kinds.consumers and is_item then types[#types + 1] = "lab" end
  if kinds.producers and is_fluid then types[#types + 1] = "offshore-pump" end
  return types
end

local function rec(e, kind)
  local p = e.position
  return { kind = kind, x = p.x or p[1], y = p.y or p[2], name = e.name }
end

-- → recs = {[kind] = {{kind,x,y,name,recipe?,amount?}, ...}}, hidden (склады вне обзора)
local function collect(a, surface, force, helper_id, is_item, is_fluid, entity_name)
  local view = C.chunk_view(force, surface, helper_id)
  local budget = { n = 0 }
  local recs = {}
  for kind in pairs(a.kinds) do recs[kind] = {} end
  local hidden = 0
  local item = a.item

  if (a.kinds.producers or a.kinds.consumers) and (is_item or is_fluid) then
    local found = search(surface, { force = force, type = machine_types(a.kinds, is_item, is_fluid) }, budget)
    for _, e in ipairs(found) do
      if e.valid and view.charted(e.position) then
        local makes, uses, recipe = machine_role(e, item)
        if makes and a.kinds.producers then
          local r = rec(e, "producers")
          r.recipe = recipe
          recs.producers[#recs.producers + 1] = r
        end
        if uses and a.kinds.consumers then
          local r = rec(e, "consumers")
          r.recipe = recipe
          recs.consumers[#recs.consumers + 1] = r
        end
      end
    end
  end

  if a.kinds.storage then
    if is_item then
      local filter = { [item] = true }
      for _, e in ipairs(search(surface, { force = force, type = STORAGE_ITEM }, budget)) do
        if e.valid and view.charted(e.position) then
          if not view.visible(e.position) then
            hidden = hidden + 1
          else
            local n = C.inv_counts(e.get_inventory(defines.inventory.chest), filter)[item]
            if n ~= nil and n > 0 then
              local r = rec(e, "storage")
              r.amount = n
              recs.storage[#recs.storage + 1] = r
            end
          end
        end
      end
    end
    if is_fluid then
      for _, e in ipairs(search(surface, { force = force, type = STORAGE_FLUID }, budget)) do
        if e.valid and view.charted(e.position) then
          if not view.visible(e.position) then
            hidden = hidden + 1
          else
            local ok, n = pcall(function() return e.get_fluid_count(item) end)
            if ok and type(n) == "number" and n > 0 then
              local r = rec(e, "storage")
              r.amount = n
              recs.storage[#recs.storage + 1] = r
            end
          end
        end
      end
    end
  end

  if a.kinds.entities and entity_name ~= nil then
    for _, e in ipairs(search(surface, { force = force, name = entity_name }, budget)) do
      if e.valid and view.charted(e.position) and is_normal(prop(e, "quality")) then
        recs.entities[#recs.entities + 1] = rec(e, "entities")
      end
    end
  end
  return recs, hidden
end

-- ---------------------------------------------------------------- группы

-- Одиночная связь с порогом GROUP_DIST, но без перебора пар: записи раскладываются по клеткам
-- сетки CELL = 16 (внутри клетки все ближе 23 — одна группа), клетки сливаются, если их
-- прямоугольники (по реальным записям) ближе GROUP_DIST. Клетки дальше двух шагов сетки
-- заведомо не ближе 32, поэтому хватает окна 5×5. Прямоугольники чуть щедрее настоящих пар
-- точек — группа может вобрать соседа на 32..45 клеток; для ответа «где это» этого довольно.
local function cluster(list)
  local cells, order = {}, {}
  for _, r in ipairs(list) do
    local cx, cy = floor(r.x / M.CELL), floor(r.y / M.CELL)
    local key = cx * 4194304 + cy -- |cx|, |cy| < 2^21
    local c = cells[key]
    if c == nil then
      c = { cx = cx, cy = cy, x0 = r.x, x1 = r.x, y0 = r.y, y1 = r.y, list = {} }
      cells[key] = c
      order[#order + 1] = c
    else
      if r.x < c.x0 then c.x0 = r.x end
      if r.x > c.x1 then c.x1 = r.x end
      if r.y < c.y0 then c.y0 = r.y end
      if r.y > c.y1 then c.y1 = r.y end
    end
    c.list[#c.list + 1] = r
  end

  local function root(c)
    while c.parent ~= nil do
      if c.parent.parent ~= nil then c.parent = c.parent.parent end -- сжатие пути
      c = c.parent
    end
    return c
  end
  for _, c in ipairs(order) do
    for dx = -2, 2 do
      for dy = -2, 2 do
        if dx ~= 0 or dy ~= 0 then
          local o = cells[(c.cx + dx) * 4194304 + c.cy + dy]
          if o ~= nil then
            local gx = max(0, o.x0 - c.x1, c.x0 - o.x1)
            local gy = max(0, o.y0 - c.y1, c.y0 - o.y1)
            if sqrt(gx * gx + gy * gy) < M.GROUP_DIST then
              local ra, rb = root(c), root(o)
              if ra ~= rb then rb.parent = ra end
            end
          end
        end
      end
    end
  end

  local groups, by_root = {}, {}
  for _, c in ipairs(order) do
    local r = root(c)
    local g = by_root[r]
    if g == nil then
      g = { count = 0, sx = 0, sy = 0, names = {}, recipes = {}, amount = 0, has_amount = false }
      by_root[r] = g
      groups[#groups + 1] = g
    end
    for _, x in ipairs(c.list) do
      g.count = g.count + 1
      g.sx = g.sx + x.x
      g.sy = g.sy + x.y
      g.names[x.name] = (g.names[x.name] or 0) + 1
      if x.recipe ~= nil then g.recipes[x.recipe] = (g.recipes[x.recipe] or 0) + 1 end
      if x.amount ~= nil then
        g.amount = g.amount + x.amount
        g.has_amount = true
      end
    end
  end
  return groups
end

-- Самые частые ключи счётчика: → {name=count} (не больше n), сколько имён не вошло.
local function top_counts(counts, n)
  local keys = {}
  for k in pairs(counts) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if counts[a] ~= counts[b] then return counts[a] > counts[b] end
    return a < b
  end)
  local out = {}
  for i = 1, math.min(#keys, n) do out[keys[i]] = counts[keys[i]] end
  return out, math.max(0, #keys - n), keys[1]
end

local function find_op(args, ctx)
  local a = parse_args(args)
  local is_item, is_fluid, entity_name = classify(a)
  local surface, force, center, helper_id = resolve(a, ctx)
  check_surface_size(surface)

  local recs, hidden = collect(a, surface, force, helper_id, is_item, is_fluid, entity_name)

  local groups, total = {}, {}
  for _, kind in ipairs(M.KINDS) do
    if a.kinds[kind] then
      total[kind] = #recs[kind]
      for _, g in ipairs(cluster(recs[kind])) do
        local x, y = g.sx / g.count, g.sy / g.count
        local names, more = top_counts(g.names, M.MAX_NAMES)
        local _, _, recipe = top_counts(g.recipes, 1)
        local out = { kind = kind, pos = C.rpos({ x = x, y = y }), count = g.count, names = names, recipe = recipe }
        if more > 0 then out.names_more = more end
        if g.has_amount then out.amount = C.round(g.amount) end
        if center ~= nil then out._d = C.dist({ x = x, y = y }, center) end
        groups[#groups + 1] = out
      end
    end
  end
  table.sort(groups, function(p, q)
    if p._d ~= q._d then return (p._d or 0) < (q._d or 0) end -- ближайшие первыми
    if p.count ~= q.count then return p.count > q.count end
    if p.kind ~= q.kind then return KIND_ORDER[p.kind] < KIND_ORDER[q.kind] end
    if p.pos.x ~= q.pos.x then return p.pos.x < q.pos.x end
    return p.pos.y < q.pos.y
  end)

  local out = {}
  for i = 1, math.min(#groups, a.limit) do
    local g = groups[i]
    if g._d ~= nil then g.dist = C.round(g._d) end
    g._d = nil
    out[i] = g
  end
  local data = { item = a.item, surface = surface.name, groups = out, total = total }
  if #groups > #out then data.truncated = true end
  if a.kinds.storage then data.hidden = hidden end
  return data
end

M.ops = {
  find = find_op,
}

-- Для тестов.
M._internal = { cluster = cluster, parse_args = parse_args }

return M
