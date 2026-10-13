-- Заглушки потока G (восприятие). Дополняют mod/tests/stubs.lua потока A (TESTING.md §1):
-- G.reset() сначала вызывает S.reset() (defines, helpers.table_to_json, log и т.д.), затем
-- ставит свой простой мир для тестов восприятия. Ошибка загрузки stubs.lua — провал тестов G.
--
-- Мир: G.reset() → world; фабрики G.surface/G.force/G.entity/G.character/G.player/G.inventory.
-- Методы фейков вызываются через точку, как в Factorio API (entity.get_inventory(i)).
local S = require("stubs")

local G = {}

local floor = math.floor

local function chunk_key(cx, cy) return cx .. ":" .. cy end
G.chunk_key = chunk_key

local function as_list(v)
  if v == nil then return nil end
  if type(v) == "table" and v.object_name == nil then return v end
  return { v }
end

local function force_name(f)
  if type(f) == "string" then return f end
  return f.name
end

local function xy(p) return p.x or p[1], p.y or p[2] end

---------------------------------------------------------------------------
-- Инвентарь
---------------------------------------------------------------------------
-- items: {name=count} (normal) или массив {name,count,quality}; slots — размер
function G.inventory(items, slots)
  local contents = {}
  if items then
    if items[1] ~= nil then
      for _, v in ipairs(items) do contents[#contents + 1] = v end
    else
      local names = {}
      for k in pairs(items) do names[#names + 1] = k end
      table.sort(names)
      for _, k in ipairs(names) do contents[#contents + 1] = { name = k, count = items[k], quality = "normal" } end
    end
  end
  local inv = { valid = true, object_name = "LuaInventory", _contents = contents, _slots = slots or 80 }
  inv.get_contents = function() return inv._contents end
  inv.count_empty_stacks = function() return math.max(0, inv._slots - #inv._contents) end
  return inv
end

---------------------------------------------------------------------------
-- Сила
---------------------------------------------------------------------------
function G.force(name)
  local f = { valid = true, object_name = "LuaForce", name = name or "player",
              uncharted = {}, invisible = {}, charts = {}, recipes = {} }
  f.is_chunk_charted = function(surface, c)
    local cx, cy = xy(c)
    return not f.uncharted[chunk_key(cx, cy)]
  end
  f.is_chunk_visible = function(surface, c)
    local cx, cy = xy(c)
    return (not f.uncharted[chunk_key(cx, cy)]) and not f.invisible[chunk_key(cx, cy)]
  end
  f.chart = function(surface, area)
    f.charts[#f.charts + 1] = { surface = surface.name, area = area }
  end
  f.set_charted = function(cx, cy, v) f.uncharted[chunk_key(cx, cy)] = (v == false) or nil end
  f.set_visible = function(cx, cy, v) f.invisible[chunk_key(cx, cy)] = (v == false) or nil end
  return f
end

---------------------------------------------------------------------------
-- Поверхность
---------------------------------------------------------------------------
local surface_index = 0

local LIQUID = { water = "water_tile", deepwater = "water_tile", lava = "lava_tile", ["lava-hot"] = "lava_tile" }
function G.tile_proto(name)
  local layers = { ground_tile = true }
  if LIQUID[name] then layers = { [LIQUID[name]] = true } end
  return { name = name, collision_mask = { layers = layers } }
end

function G.surface(name)
  surface_index = surface_index + 1
  local s = { valid = true, object_name = "LuaSurface", name = name or "nauvis", index = surface_index,
              entities = {}, tiles = {}, ungenerated = {}, blocked = {}, calls = {} }

  local function in_filter(e, f)
    if not e.valid then return false end
    if f.type then
      local ok = false
      for _, t in ipairs(as_list(f.type)) do if e.type == t then ok = true end end
      if not ok then return false end
    end
    if f.name then
      local ok = false
      for _, n in ipairs(as_list(f.name)) do if e.name == n then ok = true end end
      if not ok then return false end
    end
    if f.force then
      local ok = false
      for _, fr in ipairs(as_list(f.force)) do if force_name(fr) == e.force.name then ok = true end end
      if not ok then return false end
    end
    local bb = e.bounding_box
    if f.area then
      local lx, ly = xy(f.area.left_top or f.area[1])
      local rx, ry = xy(f.area.right_bottom or f.area[2])
      if bb.right_bottom.x <= lx or bb.left_top.x >= rx or bb.right_bottom.y <= ly or bb.left_top.y >= ry then
        return false
      end
    end
    if f.position then
      local px, py = xy(f.position)
      local r = f.radius or 0
      local dx, dy = e.position.x - px, e.position.y - py
      if dx * dx + dy * dy > r * r then return false end
    end
    return true
  end

  s.find_entities_filtered = function(f)
    s.calls[#s.calls + 1] = { "find_entities_filtered", f }
    local out = {}
    for _, e in ipairs(s.entities) do if in_filter(e, f) then out[#out + 1] = e end end
    return out
  end
  s.count_entities_filtered = function(f) return #s.find_entities_filtered(f) end

  -- tiles["x:y"] = name; по умолчанию "grass-1"
  s.find_tiles_filtered = function(f)
    local lx, ly = xy(f.area.left_top or f.area[1])
    local rx, ry = xy(f.area.right_bottom or f.area[2])
    local out = {}
    for y = floor(ly), math.ceil(ry) - 1 do
      for x = floor(lx), math.ceil(rx) - 1 do
        local name = s.tiles[x .. ":" .. y] or "grass-1"
        out[#out + 1] = { valid = true, name = name, position = { x = x, y = y }, prototype = G.tile_proto(name) }
      end
    end
    return out
  end
  s.set_tile = function(x, y, name) s.tiles[x .. ":" .. y] = name end

  s.is_chunk_generated = function(c)
    local cx, cy = xy(c)
    return not s.ungenerated[chunk_key(cx, cy)]
  end

  -- Итератор чанков, как LuaSurface.get_chunks(): s.chunk_count — сколько чанков у поверхности.
  s.chunk_count = 9
  s.get_chunks = function()
    local i = 0
    return function()
      if i >= s.chunk_count then return nil end
      i = i + 1
      return { x = i, y = 0, area = { left_top = { x = i * 32, y = 0 }, right_bottom = { x = i * 32 + 32, y = 32 } } }
    end
  end

  -- blocked["x:y"] = true → can_place_entity = false в этой позиции
  s.can_place_entity = function(p)
    s.calls[#s.calls + 1] = { "can_place_entity", p }
    local x, y = xy(p.position)
    return not s.blocked[x .. ":" .. y]
  end

  s.add = function(e)
    e.surface = s
    s.entities[#s.entities + 1] = e
    return e
  end
  return s
end

---------------------------------------------------------------------------
-- Сущности
---------------------------------------------------------------------------
local next_unit = 1000

-- o: {name, type, pos, force, size (w,h | число), direction, amount, ghost_name,
--     place_item, place_count, item_requests, inventory, rock=bool, unit=false (без unit_number)}
function G.entity(o)
  local pos = { x = o.pos.x or o.pos[1], y = o.pos.y or o.pos[2] }
  local w, h
  if type(o.size) == "table" then w, h = o.size[1], o.size[2] else w = o.size or 1; h = w end
  local e = {
    valid = true, object_name = "LuaEntity",
    name = o.name, type = o.type or o.name, position = pos,
    force = o.force, direction = o.direction or 0, amount = o.amount,
    bounding_box = {
      left_top = { x = pos.x - w / 2 + 0.1, y = pos.y - h / 2 + 0.1 },
      right_bottom = { x = pos.x + w / 2 - 0.1, y = pos.y + h / 2 - 0.1 },
    },
    prototype = { name = o.name, type = o.type or o.name,
                  count_as_rock_for_filtered_deconstruction = o.rock or false },
  }
  if o.unit ~= false then
    next_unit = next_unit + 1
    e.unit_number = o.unit or next_unit
  end
  if e.type == "entity-ghost" then
    e.ghost_name = o.ghost_name
    e.ghost_type = o.ghost_type or o.ghost_name
    local item = o.place_item or o.ghost_name
    e.ghost_prototype = { name = o.ghost_name, items_to_place_this = { { name = item, count = o.place_count or 1 } } }
    e.item_requests = o.item_requests or {}
  end
  local inv = o.inventory
  e.get_inventory = function(i) return inv end
  return e
end

-- Персонаж помощника.
function G.character(o)
  local e = G.entity { name = "character", type = "character", pos = o.pos, force = o.force, size = 0.4 }
  e.health = o.health or 250
  e.max_health = o.max_health or 250
  e.build_distance = o.build_distance or 10
  e.reach_distance = o.reach_distance or 10
  e.resource_reach_distance = o.resource_reach_distance or 2.7
  e.item_pickup_distance = o.item_pickup_distance or 1
  e.prototype.crafting_categories = o.crafting_categories or { crafting = true }
  e.prototype.get_max_health = function() return e.max_health end
  local invs = {
    main = o.main or G.inventory({}, 80),
    armor = o.armor or G.inventory({}, 1),
  }
  e.get_inventory = function(i)
    if i == defines.inventory.character_main then return invs.main end
    if i == defines.inventory.character_armor then return invs.armor end
    return nil
  end
  local craftable = o.craftable or {}
  e.get_craftable_count = function(name) return craftable[name] or 0 end
  if o.robots then
    e.logistic_cell = { valid = true, logistic_network = { valid = true,
      all_construction_robots = o.robots[1], available_construction_robots = o.robots[2] } }
  end
  return e
end

-- Инвентарь брони с одним стаком.
function G.armor_inventory(name)
  local inv = G.inventory({}, 1)
  inv[1] = { valid_for_read = name ~= nil, name = name }
  return inv
end

function G.player(o)
  local character = nil
  if o.character ~= false then character = o.character or { valid = true } end
  return {
    valid = true, object_name = "LuaPlayer",
    index = o.index, name = o.name, connected = o.connected ~= false,
    character = character,
    physical_surface = o.surface, physical_position = o.pos, force = o.force,
  }
end

---------------------------------------------------------------------------
-- Глобальный мир
---------------------------------------------------------------------------
-- Сбрасывает глобалы игры для теста восприятия. → world {surface, force, enemy, neutral, players}
function G.reset(opts)
  opts = opts or {}
  S.reset()
  _G.defines = _G.defines or {}
  defines.inventory = defines.inventory or {}
  defines.inventory.character_main = defines.inventory.character_main or 1
  defines.inventory.character_armor = defines.inventory.character_armor or 5
  defines.inventory.chest = defines.inventory.chest or 1
  defines.build_check_type = defines.build_check_type or {}
  defines.build_check_type.manual_ghost = defines.build_check_type.manual_ghost or 3
  defines.build_check_type.ghost_revive = defines.build_check_type.ghost_revive or 2
  defines.events = defines.events or {}

  if type(_G.storage) == "table" then
    for k in pairs(storage) do storage[k] = nil end
  else
    _G.storage = {}
  end

  local world = {}
  world.surface = G.surface(opts.surface or "nauvis")
  world.force = G.force("player")
  world.enemy = G.force("enemy")
  world.neutral = G.force("neutral")
  world.players = {}

  _G.game = {}
  game.tick = opts.tick or 1000
  game.players = world.players
  game.surfaces = { [world.surface.name] = world.surface }
  game.get_player = function(k)
    if type(k) == "number" then return world.players[k] end
    for _, p in pairs(world.players) do if p.name == k then return p end end
    return nil
  end

  _G.settings = { global = {} }
  settings.global["partner-owner"] = { value = opts.owner or "" }

  _G.prototypes = { entity = { character = { crafting_categories = { crafting = true } } } }

  -- свежие модули восприятия
  for _, n in ipairs { "state", "map", "resources", "stock", "ghosts", "recipes", "vision", "find" } do
    package.loaded["scripts.perception." .. n] = nil
  end
  return world
end

-- Помощник в storage.helpers и ctx для операций. → entity, ctx
function G.add_helper(world, id, o)
  o = o or {}
  o.force = o.force or world.force
  local e = world.surface.add(G.character(o))
  storage.helpers = storage.helpers or {}
  storage.helpers[id] = { entity = e, unit_number = e.unit_number, state = o.state or "alive" }
  return e, { helper_id = id, entity = e }
end

function G.add_player(world, o)
  o.index = o.index or (#world.players + 1)
  o.surface = o.surface or world.surface
  o.force = o.force or world.force
  local p = G.player(o)
  world.players[o.index] = p
  return p
end

---------------------------------------------------------------------------
-- Проверки
---------------------------------------------------------------------------
local function show(v)
  if type(v) == "table" then
    local parts = {}
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. "=" .. show(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  if type(v) == "number" and v == floor(v) and v > -1e15 and v < 1e15 then
    return string.format("%d", v) -- 3 и 3.0 одинаково (Lua 5.2/5.3)
  end
  return tostring(v)
end
G.show = show

function G.eq(a, b, msg)
  if show(a) ~= show(b) then
    error((msg or "eq") .. ": expected " .. show(b) .. ", got " .. show(a), 2)
  end
end

function G.ok(v, msg)
  if not v then error((msg or "ok") .. ": expected truthy", 2) end
end

-- Ожидаем ошибку мода с кодом code; → текст ошибки.
function G.raises(code, fn, msg)
  local ok, e = pcall(fn)
  if ok then error((msg or "raises") .. ": expected error " .. code .. ", got success", 2) end
  if type(e) ~= "table" or e.code ~= code then
    error((msg or "raises") .. ": expected " .. code .. ", got " .. show(e), 2)
  end
  return e.text
end

-- Ответ через настоящий JSON-мост раннера (helpers.table_to_json заглушки A, правила Factorio).
-- → строка JSON; несериализуемое (функции, LuaObject, nan/inf) — ошибка.
function G.json(v)
  return helpers.table_to_json(v)
end

-- Ответ сериализуем: только числа, строки, bool и таблицы из них, без смешанных ключей
-- и без Lua-объектов (PROTOCOL §1).
function G.plain(v, path)
  path = path or "data"
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" then return end
  if t ~= "table" then error(path .. ": not serializable (" .. t .. ")", 2) end
  if v.object_name ~= nil or v.valid ~= nil then error(path .. ": looks like a Lua object", 2) end
  local has_num, has_str = false, false
  for k, val in pairs(v) do
    if type(k) == "number" then has_num = true else has_str = true end
    G.plain(val, path .. "." .. tostring(k))
  end
  if has_num and has_str then error(path .. ": mixed keys", 2) end
end

return G
