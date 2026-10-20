-- Операция `status`: «что стоит и почему». Контракт: docs/STATE.md «status», PROTOCOL §6.7, §6.11.
-- Машины силы хозяина в радиусе (из индекса scripts.core.index, без скана силы), у каждой —
-- статус движка (`entity.status`); те, что не работают, собираются в группы «имя + причина».
-- Причина — имя статуса из defines.entity_status как есть (`reason`) и грубый разряд (`cause`):
-- power, fuel, resource, input, output, recipe, heat, disabled, other; а также «мягкие» разряды —
-- slow (low_power: машина работает, но медленно), research (нет исследования: лаборатории нечего
-- делать), rocket (этапы пуска ракетной шахты). Мягкие не считаются остановкой: у них свои
-- счётчики `slow` и `waiting`, в `stopped` они не входят. Имён прототипов и
-- рецептов в коде нет: рецепт, имена построек и статусы читаются у самой сущности.
-- У групп с причиной input добавляется `missing` — каких ингредиентов рецепта не хватает на один цикл
-- ({name, type, have, need}; have — минимум по проверенным машинам группы, не больше MISSING_SAMPLE
-- ближайших), `ok` — имена ингредиентов, которых хватает, `checked` — сколько машин проверено.
-- Живое (статус машины) — только в видимых чанках; остальные машины считаются в `hidden`.
-- Только чтение: ничего не меняет в игре и не пишет в storage.
-- Разбор отказа «почему стоит» — идея factory_status из factorio-codex (MIT); код написан заново.
local index = require("scripts.core.index")
local C = require("scripts.perception.state").common

local M = {}

M.DEFAULT_RADIUS = 64
M.MAX_RADIUS = 128
M.DEFAULT_LIMIT = 20
M.MAX_LIMIT = 50

-- Статусы, при которых машина считается работающей, и те, что в разбор не входят.
local RUNNING = { working = true, normal = true }
local IGNORED = { marked_for_deconstruction = true, ghost = true }

-- Статус → разряд причины. Незнакомый статус (новая версия игры) → other, имя остаётся в reason.
local CAUSE = {
  no_power = "power", not_plugged_in_electric_network = "power",
  low_power = "slow",
  no_research_in_progress = "research",
  preparing_rocket_for_launch = "rocket", waiting_to_launch_rocket = "rocket", launching_rocket = "rocket",
  no_fuel = "fuel",
  no_minable_resources = "resource",
  no_ingredients = "input", no_input_fluid = "input", low_input_fluid = "input", item_ingredient_shortage = "input",
  fluid_ingredient_shortage = "input", missing_required_fluid = "input", missing_science_packs = "input",
  waiting_for_source_items = "input",
  full_output = "output", full_burnt_result_output = "output", waiting_for_space_in_destination = "output",
  no_recipe = "recipe",
  low_temperature = "heat",
  disabled = "disabled", disabled_by_control_behavior = "disabled", disabled_by_script = "disabled",
}
local CAUSE_RANK = {
  power = 1, fuel = 2, resource = 3, input = 4, output = 5, recipe = 6, heat = 7, disabled = 8, other = 9,
  slow = 10, research = 11, rocket = 12,
}
-- Разряд → счётчик в `machines` вместо `stopped` (не остановка).
local SOFT = { slow = "slow", research = "waiting", rocket = "waiting" }

local status_names
local function status_name(v)
  if status_names == nil then
    status_names = {}
    for name, value in pairs(defines.entity_status or {}) do status_names[value] = name end
  end
  return status_names[v]
end

local function prop(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

-- Рецепт машины (строка) или nil: у типа сущности метода может не быть.
local function recipe_name(e)
  local ok, r = pcall(function() return e.get_recipe() end)
  if not ok or r == nil then return nil end
  local n = prop(r, "name")
  if type(n) == "string" then return n end
  return nil
end

-- Входной инвентарь машины по типу сущности (имя набора — из defines.inventory).
local INPUT_INV = {
  ["assembling-machine"] = "assembling_machine_input", furnace = "furnace_source",
  ["rocket-silo"] = "rocket_silo_input",
}
M.MISSING_SAMPLE = 8 -- сколько машин группы проверяется на нехватку ингредиентов

-- Ингредиенты рецепта машины: список {type, name, amount} или nil. Рецепт — текущий, а у печи без сырья
-- (get_recipe пуст) — прошлый (previous_recipe); состав берётся у рецепта или из его прототипа.
local function recipe_ingredients(e)
  local ok, r = pcall(function() return e.get_recipe() end)
  if not ok then r = nil end
  local name = r ~= nil and prop(r, "name") or nil
  if type(name) ~= "string" then
    local prev = prop(e, "previous_recipe")
    if type(prev) == "table" or type(prev) == "userdata" then prev = prop(prev, "name") end
    if type(prev) ~= "string" then return nil end
    name, r = prev, nil
  end
  local ingr = r ~= nil and prop(r, "ingredients") or nil
  if type(ingr) ~= "table" then
    local proto = prop(prototypes.recipe, name)
    ingr = proto ~= nil and prop(proto, "ingredients") or nil
  end
  if type(ingr) ~= "table" then return nil end
  return ingr
end

-- Сколько жидкости с таким именем лежит в ящиках жидкости машины (0, если не читается).
local function fluid_have(e, fname)
  local fb = prop(e, "fluidbox")
  if fb == nil then return 0 end
  local ok, n = pcall(function() return #fb end)
  if not ok or type(n) ~= "number" then return 0 end
  local have = 0
  for i = 1, n do
    local okf, f = pcall(function() return fb[i] end)
    if okf and type(f) == "table" and f.name == fname and type(f.amount) == "number" then
      have = have + f.amount
    end
  end
  return have
end

-- Что есть в машине из ингредиентов рецепта: { {name, type, have, need}, ... } или nil, если рецепта
-- нет или входной инвентарь не прочитать.
local function ingredient_levels(e)
  local ingr = recipe_ingredients(e)
  if ingr == nil then return nil end
  local key = INPUT_INV[prop(e, "type")] or "assembling_machine_input"
  local okv, inv = pcall(function() return e.get_inventory(defines.inventory[key]) end)
  if not okv then inv = nil end
  local items
  local out = {}
  for _, i in ipairs(ingr) do
    local name, need = prop(i, "name"), prop(i, "amount")
    if type(name) == "string" and type(need) == "number" then
      if prop(i, "type") == "fluid" then
        out[#out + 1] = { name = name, type = "fluid", have = fluid_have(e, name), need = need }
      else
        if items == nil then
          local okc, c = pcall(C.inv_counts, inv)
          items = okc and c or {}
        end
        out[#out + 1] = { name = name, type = "item", have = items[name] or 0, need = need }
      end
    end
  end
  if #out == 0 then return nil end
  return out
end

-- Добавляет показания одной машины к группе: у каждого ингредиента — минимум по проверенным машинам.
local function sample_machine(g, e)
  local levels = ingredient_levels(e)
  if levels == nil then return end
  g.checked = (g.checked or 0) + 1
  g.levels = g.levels or {}
  for _, l in ipairs(levels) do
    local cur = g.levels[l.name]
    if cur == nil then
      g.levels[l.name] = l
      g.lorder = g.lorder or {}
      g.lorder[#g.lorder + 1] = l.name
    elseif l.have < cur.have then
      cur.have = l.have
    end
  end
end

-- Делит ингредиенты группы на missing (меньше, чем на один цикл) и ok (имена тех, кого хватает).
local function split_levels(g)
  local missing, ok = {}, {}
  for _, name in ipairs(g.lorder) do
    local l = g.levels[name]
    if l.have < l.need then
      missing[#missing + 1] = { name = l.name, type = l.type, have = C.round(l.have), need = l.need }
    else
      ok[#ok + 1] = l.name
    end
  end
  return missing, ok
end

local function status_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { center = true, near = true, radius = true, limit = true })
  local radius = C.check_num(args.radius, "radius", 1, M.MAX_RADIUS, M.DEFAULT_RADIUS)
  local limit = C.check_int(args.limit, "limit", 1, M.MAX_LIMIT, M.DEFAULT_LIMIT)
  local where = C.resolve(args, ctx)

  local view = C.chunk_view(where.force, where.surface, where.helper_id)
  local found = index.near("machine", where.surface.index, where.center, radius, where.force.name)

  local seen, running, hidden, unknown, ignored = 0, 0, 0, 0, 0
  local groups, order, causes = {}, {}, {}
  for _, m in ipairs(found) do
    if not view.visible(m.pos) then
      hidden = hidden + 1
    else
      seen = seen + 1
      local name = status_name(prop(m.entity, "status"))
      if name == nil then
        unknown = unknown + 1
      elseif RUNNING[name] then
        running = running + 1
      elseif IGNORED[name] then
        ignored = ignored + 1
      else
        local cause = CAUSE[name] or "other"
        causes[cause] = (causes[cause] or 0) + 1
        local recipe = recipe_name(m.entity)
        local key = m.name .. "|" .. name .. "|" .. (recipe or "")
        local g = groups[key]
        if g == nil then
          g = { name = m.name, reason = name, cause = cause, recipe = recipe, count = 0, pos = m.pos, dist = m.dist }
          groups[key] = g
          order[#order + 1] = key
        end
        g.count = g.count + 1
        if cause == "input" and (g.checked or 0) < M.MISSING_SAMPLE then sample_machine(g, m.entity) end
        -- found идёт по возрастанию расстояния: pos и dist группы — у ближайшей машины
      end
    end
  end

  local rows = {}
  for _, key in ipairs(order) do rows[#rows + 1] = groups[key] end
  table.sort(rows, function(a, b)
    local ra, rb = CAUSE_RANK[a.cause], CAUSE_RANK[b.cause]
    if ra ~= rb then return ra < rb end
    if a.count ~= b.count then return a.count > b.count end
    if a.dist ~= b.dist then return a.dist < b.dist end
    if a.name ~= b.name then return a.name < b.name end
    return a.reason < b.reason
  end)
  local truncated = #rows > limit
  local out = {}
  for i = 1, math.min(#rows, limit) do
    local g = rows[i]
    out[i] = {
      name = g.name, reason = g.reason, cause = g.cause, recipe = g.recipe, count = g.count,
      pos = C.rpos(g.pos), dist = C.round(g.dist),
    }
    if g.lorder ~= nil then
      out[i].missing, out[i].ok = split_levels(g)
      out[i].checked = g.checked
    end
  end

  local stopped, soft = 0, {}
  for cause, n in pairs(causes) do
    local counter = SOFT[cause]
    if counter ~= nil then soft[counter] = (soft[counter] or 0) + n else stopped = stopped + n end
  end
  local result = {
    surface = where.surface.name,
    center = C.rpos(where.center),
    radius = radius,
    machines = { seen = seen, running = running, stopped = stopped, hidden = hidden },
    causes = causes,
    stopped = out,
    index_ready = index.ready(),
  }
  if soft.slow then result.machines.slow = soft.slow end
  if soft.waiting then result.machines.waiting = soft.waiting end
  if unknown > 0 then result.machines.unknown = unknown end
  if ignored > 0 then result.machines.ignored = ignored end
  if truncated then result.truncated = true end
  if where.helper_id ~= nil then
    local job, queue = C.job_summary(where.helper_id)
    result.helper = { job = job, queue = queue }
  end
  return result
end

M.ops = {
  status = status_op,
}

-- Для тестов.
M._internal = { CAUSE = CAUSE, RUNNING = RUNNING, SOFT = SOFT }

return M
