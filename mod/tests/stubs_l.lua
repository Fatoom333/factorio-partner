-- Заглушки op `rates`. Дополняют mod/tests/stubs.lua (TESTING.md §1):
-- если stubs.lua есть — подгружается первым, дальше L ставит только своё (game, prototypes,
-- settings на время теста и нужные константы defines). Без stubs.lua тоже работает.
pcall(require, "stubs")

local L = {}

-- ---------------------------------------------------------------- defines

defines = defines or {}
defines.flow_precision_index = defines.flow_precision_index or {}
do
  local fpi = defines.flow_precision_index
  fpi.five_seconds = fpi.five_seconds or 0
  fpi.one_minute = fpi.one_minute or 1
  fpi.ten_minutes = fpi.ten_minutes or 2
  fpi.one_hour = fpi.one_hour or 3
  fpi.ten_hours = fpi.ten_hours or 4
end

-- ---------------------------------------------------------------- «LuaObject»

-- Объект, который, как LuaObject, бросает ошибку при чтении несуществующего свойства.
local function strict(fields, kind)
  return setmetatable(fields, {
    __index = function(_, k)
      error("LuaObject " .. kind .. " doesn't contain key " .. tostring(k), 2)
    end,
  })
end
L.strict = strict

-- Статистика: flows[precision][category][name] = число. Журнал вызовов — в .calls.
function L.stats(spec)
  spec = spec or {}
  local flows = spec.flows or {}
  local s
  s = strict({
    valid = true,
    input_counts = spec.input_counts or {},
    output_counts = spec.output_counts or {},
    calls = {},
    get_flow_count = function(a)
      assert(type(a) == "table", "get_flow_count: ожидается таблица")
      s.calls[#s.calls + 1] = a
      if spec.throw_on and spec.throw_on[a.name] then error("bad name " .. a.name) end
      local byp = flows[a.precision_index] or {}
      local byc = byp[a.category] or {}
      return byc[a.name] or 0
    end,
  }, "LuaFlowStatistics")
  return s
end

function L.surface(spec)
  spec = spec or {}
  local surf
  surf = strict({
    valid = true,
    name = spec.name or "nauvis",
    index = spec.index or 1,
    entities = spec.entities or {},
    last_filter = nil,
    find_entities_filtered = function(f)
      surf.last_filter = f
      local out = {}
      local types = {}
      for _, t in ipairs(f.type or {}) do types[t] = true end
      for _, e in ipairs(surf.entities) do
        local p = e.position
        local a = f.area
        local inside = (not a) or (p.x >= a.left_top.x and p.x <= a.right_bottom.x
          and p.y >= a.left_top.y and p.y <= a.right_bottom.y)
        local tok = (not f.type) or types[e.type]
        local fok = (not f.force) or e.force == f.force
        if inside and tok and fok then out[#out + 1] = e end
      end
      return out
    end,
  }, "LuaSurface")
  return surf
end

-- spec.item_stats / fluid_stats: {[surface_name] = L.stats(...)}; spec.visible(cx, cy) -> bool.
function L.force(spec)
  spec = spec or {}
  local f
  f = strict({
    valid = true,
    name = spec.name or "player",
    recipes = spec.recipes or {},
    stats_calls = {},
    get_item_production_statistics = function(surface)
      f.stats_calls[#f.stats_calls + 1] = { kind = "item", surface = surface.name }
      return (spec.item_stats or {})[surface.name] or L.stats()
    end,
    get_fluid_production_statistics = function(surface)
      f.stats_calls[#f.stats_calls + 1] = { kind = "fluid", surface = surface.name }
      return (spec.fluid_stats or {})[surface.name] or L.stats()
    end,
    is_chunk_visible = function(surface, chunk)
      assert(type(chunk) == "table" and chunk.x and chunk.y, "chunk {x,y}")
      if spec.visible then return spec.visible(chunk.x, chunk.y) end
      return true
    end,
  }, "LuaForce")
  return f
end

-- Рецепт (LuaRecipe): energy, ingredients, products.
function L.recipe(name, energy, ingredients, products, max_productivity)
  return strict({ valid = true, name = name, energy = energy, ingredients = ingredients, products = products,
    maximum_productivity = max_productivity }, "LuaRecipe")
end

-- Машина-сборщик/печь. spec: name, type, pos, force, recipe, recipe_quality, crafting_speed,
-- productivity_bonus, previous_recipe.
function L.crafter(spec)
  local fields = {
    valid = true,
    name = spec.name or "assembling-machine-2",
    type = spec.type or "assembling-machine",
    position = spec.pos or { x = 0.5, y = 0.5 },
    force = spec.force,
    crafting_speed = spec.crafting_speed or 0.75,
    productivity_bonus = spec.productivity_bonus or 0,
    get_recipe = function()
      if spec.recipe then
        return spec.recipe, spec.recipe_quality and strict({ name = spec.recipe_quality }, "LuaQualityPrototype") or nil
      end
      return nil
    end,
  }
  if fields.type == "furnace" then fields.previous_recipe = spec.previous_recipe end
  return strict(fields, "LuaEntity")
end

-- Ресурс (LuaEntity type=resource) с прототипом.
function L.resource(spec)
  local mp = {
    minable = true,
    mining_time = spec.mining_time or 1,
    products = spec.products or { { type = "item", name = spec.name or "iron-ore", amount = 1 } },
    required_fluid = spec.required_fluid,
    fluid_amount = spec.fluid_amount,
  }
  local proto = strict({
    name = spec.name or "iron-ore",
    mineable_properties = mp,
    infinite_resource = spec.infinite or false,
    normal_resource_amount = spec.normal_amount or 0,
  }, "LuaEntityPrototype")
  return strict({ valid = true, name = spec.name or "iron-ore", type = "resource",
    amount = spec.amount or 1000, prototype = proto }, "LuaEntity")
end

-- Бур. spec: name, pos, force, mining_speed, speed_bonus, productivity_bonus, target.
function L.drill(spec)
  local proto = strict({ name = spec.name or "electric-mining-drill", mining_speed = spec.mining_speed or 0.5 },
    "LuaEntityPrototype")
  return strict({
    valid = true,
    name = spec.name or "electric-mining-drill",
    type = "mining-drill",
    position = spec.pos or { x = 0.5, y = 0.5 },
    force = spec.force,
    prototype = proto,
    speed_bonus = spec.speed_bonus or 0,
    productivity_bonus = spec.productivity_bonus or 0,
    mining_target = spec.target,
  }, "LuaEntity")
end

-- Персонаж помощника.
function L.character(force, surface, pos)
  return strict({ valid = true, name = "character", type = "character", force = force, surface = surface,
    position = pos or { x = 0, y = 0 } }, "LuaEntity")
end

-- Ставит глобальные game / prototypes / settings для одного теста.
-- world: surfaces = {L.surface...}, forces = {player = L.force...}, players = {[1|name] = player},
-- items = {"iron-plate", ...}, fluids = {"water", ...}, owner = "имя" | nil.
function L.install(world)
  world = world or {}
  local surfaces = {}
  for _, s in ipairs(world.surfaces or {}) do surfaces[s.name] = s end
  local players = world.players or {}
  game = game or {}
  game.surfaces = surfaces
  game.forces = world.forces or {}
  game.tick = world.tick or 1000
  game.get_player = function(key) return players[key] end
  local items, fluids = {}, {}
  for _, n in ipairs(world.items or {}) do items[n] = { name = n } end
  for _, n in ipairs(world.fluids or {}) do fluids[n] = { name = n } end
  prototypes = prototypes or {}
  prototypes.item = items
  prototypes.fluid = fluids
  settings = settings or {}
  settings.global = settings.global or {}
  settings.global["partner-owner"] = { value = world.owner or "" }
end

function L.player(spec)
  -- core.owner.present() требует character.valid
  if type(spec.character) == "table" and spec.character.valid == nil then spec.character.valid = true end
  return {
    valid = true, name = spec.name or "Tartaluga", connected = spec.connected ~= false,
    character = spec.character, force = spec.force, physical_surface = spec.surface,
  }
end

-- ---------------------------------------------------------------- проверки

function L.eq(a, b, msg)
  if a ~= b then error((msg or "eq") .. ": ожидалось " .. tostring(b) .. ", получено " .. tostring(a), 2) end
end

function L.near(a, b, msg, eps)
  eps = eps or 1e-6
  if type(a) ~= "number" or math.abs(a - b) > eps then
    error((msg or "near") .. ": ожидалось " .. tostring(b) .. ", получено " .. tostring(a), 2)
  end
end

function L.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- Ожидает ошибку мода с кодом code; возвращает текст.
function L.raises(code, fn)
  local ok, e = pcall(fn)
  if ok then error("ожидалась ошибка " .. code .. ", а вызов прошёл", 2) end
  if type(e) ~= "table" or not e.partner_error then
    error("ожидалась ошибка " .. code .. ", получено: " .. tostring(e), 2)
  end
  if e.code ~= code then error("ожидался код " .. code .. ", получен " .. tostring(e.code) .. " (" .. tostring(e.text) .. ")", 2) end
  return e.text
end

-- Ответ сериализуем (PROTOCOL §1): только числа/строки/bool/таблицы, без метатаблиц и
-- без смешанных ключей.
function L.plain(v, path)
  path = path or "data"
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error(path .. ": не конечное число") end
    return
  end
  if t == "string" or t == "boolean" then return end
  if t ~= "table" then error(path .. ": тип " .. t) end
  if getmetatable(v) ~= nil then error(path .. ": таблица с метатаблицей (LuaObject?)") end
  local has_num, has_str = false, false
  for k, x in pairs(v) do
    if type(k) == "number" then has_num = true elseif type(k) == "string" then has_str = true
    else error(path .. ": ключ типа " .. type(k)) end
    L.plain(x, path .. "." .. tostring(k))
  end
  if has_num and has_str then error(path .. ": смешанные ключи") end
end

-- Мини-набор: L.case(name, fn) ... L.finish() — error() при любом провале (TESTING.md §1).
local cases, failed = 0, {}
function L.case(name, fn)
  cases = cases + 1
  local ok, e = pcall(fn)
  if not ok then
    if type(e) == "table" then e = tostring(e.code) .. ": " .. tostring(e.text) end
    failed[#failed + 1] = name .. " -> " .. tostring(e)
  end
end

function L.finish(file)
  local summary = (file or "rates") .. ": " .. (cases - #failed) .. "/" .. cases .. " ok"
  if #failed > 0 then error(summary .. "\n  " .. table.concat(failed, "\n  "), 0) end
  if print then print(summary) end
  cases, failed = 0, {}
end

return L
