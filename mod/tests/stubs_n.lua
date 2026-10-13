-- Заглушки потока N («Прокладка лент»). Дополняют stubs.lua (A) и stubs_c.lua (C), TESTING.md §1.
--
--   local S = require("stubs"); local X = require("stubs_n")
--   local W = X.setup()                                   -- мод, хозяин, помощник h1, прототипы лент
--   X.tiles("lava", 5, -10, 5, 10)                        -- плитки: клетки x 5..5, y -10..10
--   X.wall(8, -20, 8, 20)                                 -- постройки своей силы (сундуки) в клетках
--   local d, kind = X.plan{ from = { x = 0.5, y = 0.5 }, to = { x = 20.5, y = 0.5 } }
--   X.ghosts()                                            -- призраки {name, x, y, pos, direction, type, ...}
--
-- Мир — клетки. Правила проверки постановки (`surface.can_place_entity`) — как в игре по смыслу:
--   * плитка мешает, если её маска пересекается с маской постройки (лава и вода — слой water_tile);
--   * в клетке стоит постройка или призрак — нельзя; дерево или камень — можно только с forced;
--   * персонажи, руда и предметы на земле не мешают.
local S = require("stubs")
local C = require("stubs_c")

local X = {}

X.D = { north = 0, east = 4, south = 8, west = 12 }
local VEC = { [0] = { 0, -1 }, [4] = { 1, 0 }, [8] = { 0, 1 }, [12] = { -1, 0 } }
X.VEC = VEC

local OBJECT = { layers = { object = true, water_tile = true, is_object = true } }

-- ===================================================================== прототипы

local function buildable(name, etype, extra)
  local p = { name = name, type = etype, hidden = false, max_health = 100, collision_mask = OBJECT }
  p.items_to_place_this = { { name = name, count = 1 } }
  for k, v in pairs(extra or {}) do p[k] = v end
  prototypes.entity[name] = p
  prototypes.item[name] = prototypes.item[name] or { name = name, type = "item", stack_size = 100 }
  return p
end

function X.prototypes()
  local E = prototypes.entity
  local under = buildable("underground-belt", "underground-belt", { max_underground_distance = 5, belt_speed = 0.03125 })
  buildable("transport-belt", "transport-belt", { belt_speed = 0.03125, related_underground_belt = under })
  local fast_under = buildable("fast-underground-belt", "underground-belt", { max_underground_distance = 7, belt_speed = 0.0625 })
  buildable("fast-transport-belt", "transport-belt", { belt_speed = 0.0625, related_underground_belt = fast_under })
  buildable("iron-chest", "container")
  buildable("pipe", "pipe")
  E["tree-01"] = { name = "tree-01", type = "tree", collision_mask = { layers = { object = true, is_object = true } } }
  E["big-rock"] = { name = "big-rock", type = "simple-entity", collision_mask = { layers = { object = true, is_object = true } } }
  E["cliff"] = { name = "cliff", type = "cliff", collision_mask = { layers = { object = true, is_object = true } } }
  E["iron-ore"].collision_mask = { layers = { resource = true } }
  E["character"].collision_mask = { layers = { player = true } }
  E["small-biter"].collision_mask = { layers = { player = true } }

  prototypes.tile = {
    ["grass-1"] = { name = "grass-1", collision_mask = { layers = { ground_tile = true } } },
    -- имена плиток — только в заглушке: код мода смотрит на маски
    lava = { name = "lava", collision_mask = { layers = { water_tile = true, lava_tile = true } } },
    water = { name = "water", collision_mask = { layers = { water_tile = true } } },
    void = { name = "void", collision_mask = { layers = { water_tile = true, empty_space = true } } },
  }
  prototypes.mod_data = nil

  prototypes.get_entity_filtered = function(filters)
    local out = {}
    for name, p in pairs(prototypes.entity) do
      for _, f in ipairs(filters) do
        if f.filter == "type" and p.type == f.type then out[name] = p end
      end
    end
    return out
  end
  prototypes.get_recipe_filtered = function() return {} end
end

function X.research(...)
  local force = game.forces.player
  for _, name in ipairs({ ... }) do force.recipes[name] = { name = name, enabled = true, valid = true } end
end

function X.forget(...)
  local force = game.forces.player
  for _, name in ipairs({ ... }) do force.recipes[name] = { name = name, enabled = false, valid = true } end
end

--- Маски подземных конвейеров, как их отдала бы стадия данных мода (прототип mod-data).
function X.underground_masks(masks)
  prototypes.mod_data = { ["factorio-partner-underground-masks"] = { data = masks } }
end

-- ===================================================================== мир

local function cell_of(pos)
  local p = S.norm_pos(pos)
  return math.floor(p.x), math.floor(p.y)
end

function X.key(x, y) return x .. "," .. y end

local function overlaps(a, b)
  if not (a and b) then return false end
  for layer in pairs(a.layers) do
    if b.layers[layer] then return true end
  end
  return false
end

local function natural(e)
  return e.type == "tree" or (e.type == "simple-entity" and e.force and e.force.name == "neutral")
end

local IGNORED = { character = true, resource = true, ["item-entity"] = true, unit = true }

local function can_place(_, params)
  local x, y = cell_of(params.position)
  X.checks[#X.checks + 1] = {
    name = params.name, x = x, y = y, kind = params.build_check_type, force = params.force, forced = params.forced,
  }
  if X.blocked[X.key(x, y)] then return false end
  local proto = prototypes.entity[params.name]
  local tile = prototypes.tile[S.nauvis.tiles[X.key(x, y)] or "grass-1"]
  if overlaps(proto.collision_mask, tile.collision_mask) then return false end
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and not IGNORED[e.type] then
      local ex, ey = cell_of(e.position)
      if ex == x and ey == y then
        if not natural(e) then return false end
        if not params.forced then return false end
      end
    end
  end
  return true
end

--- X.setup{ research = {...} } → W (как C.setup): мод, хозяин, помощник h1 в (0, 0).
function X.setup(opts)
  opts = opts or {}
  X.blocked, X.checks, X.marked = {}, {}, {}
  local W = C.setup(opts)
  X.prototypes()
  X.W = W
  S.nauvis.tiles = {}
  S.nauvis.can_place = can_place
  local force = game.forces.player
  force.is_enemy = function(other) return other ~= nil and other.name == "enemy" end
  X.forget("fast-transport-belt", "fast-underground-belt")
  X.research(table.unpack(opts.research or { "transport-belt", "underground-belt" }))
  storage.mining_last = nil
  return W
end

--- Плитки name в клетках x1..x2 × y1..y2.
function X.tiles(name, x1, y1, x2, y2)
  for x = x1, x2 or x1 do
    for y = y1, y2 or y1 do S.nauvis.tiles[X.key(x, y)] = name end
  end
end

local function with_marks(e)
  local marked = false
  e.minable = true
  e.to_be_deconstructed = function() return marked end
  e.order_deconstruction = function(force)
    marked = true
    X.marked[#X.marked + 1] = { name = e.name, x = math.floor(e.position.x), y = math.floor(e.position.y), force = force }
    return true
  end
  return e
end

--- Постройка в клетке (по умолчанию сундук своей силы).
function X.thing(x, y, name, force, fields)
  return with_marks(S.nauvis.create_entity{
    name = name or "iron-chest", position = { x = x + 0.5, y = y + 0.5 }, force = force or "player", fields = fields,
  })
end

--- Стена построек своей силы: клетки x1..x2 × y1..y2.
function X.wall(x1, y1, x2, y2, name)
  for x = x1, x2 or x1 do
    for y = y1, y2 or y1 do X.thing(x, y, name) end
  end
end

function X.tree(x, y, name) return X.thing(x, y, name or "tree-01", "neutral") end

--- Существующая лента своей силы.
function X.belt(x, y, direction, name)
  return S.nauvis.create_entity{
    name = name or "transport-belt", position = { x = x + 0.5, y = y + 0.5 }, direction = direction, force = "player",
    fields = { to_be_deconstructed = function() return false end },
  }
end

--- Существующий подземный конвейер; pair — его пара (LuaEntity.neighbours в 2.0).
function X.underground(x, y, direction, kind, pair, name)
  local e = S.nauvis.create_entity{
    name = name or "underground-belt", position = { x = x + 0.5, y = y + 0.5 }, direction = direction, force = "player",
    fields = { belt_to_ground_type = kind, to_be_deconstructed = function() return false end },
  }
  if pair then
    e.neighbours = pair
    pair.neighbours = e
  end
  return e
end

-- ===================================================================== задача и призраки

--- act plan_belt → data, kind, job (ждёт итога).
function X.plan(args, n)
  local job = S.okr(C.act("plan_belt", args)).job
  local d, kind = C.wait(job, n or 3000)
  return d, kind, job
end

--- Призраки, созданные скриптом: {name (inner), x, y (клетка), pos, direction, type, force, quality, raise_built}.
function X.ghosts(name)
  local out = {}
  for _, p in ipairs(S.nauvis.created or {}) do
    if p.name == "entity-ghost" and (name == nil or p.inner_name == name) then
      local pos = S.norm_pos(p.position)
      out[#out + 1] = {
        name = p.inner_name, x = math.floor(pos.x), y = math.floor(pos.y), pos = pos, direction = p.direction,
        type = p.type, force = p.force, quality = p.quality, raise_built = p.raise_built,
      }
    end
  end
  return out
end

--- Цепочка призраков непрерывна: каждая следующая стоит по направлению предыдущей (после входа
--- подземного — его выход на той же линии не дальше max). Берёт призраки в порядке постановки.
--- → true │ false, текст.
function X.continuous(ghosts, max_under)
  for i = 1, #ghosts - 1 do
    local a, b = ghosts[i], ghosts[i + 1]
    local v = VEC[a.direction]
    if v == nil then return false, "direction " .. tostring(a.direction) .. " at #" .. i end
    local dx, dy = b.x - a.x, b.y - a.y
    if a.type == "input" then
      local len = dx * v[1] + dy * v[2]
      if b.type ~= "output" or b.direction ~= a.direction or len < 2 or len > (max_under or 5)
        or dx ~= v[1] * len or dy ~= v[2] * len then
        return false, "underground pair broken at #" .. i .. ": " .. S.dump(a) .. " -> " .. S.dump(b)
      end
    elseif dx ~= v[1] or dy ~= v[2] then
      return false, "gap at #" .. i .. ": " .. S.dump(a) .. " -> " .. S.dump(b)
    end
  end
  return true
end

--- Клетка есть среди призраков?
function X.at(ghosts, x, y)
  for _, g in ipairs(ghosts) do
    if g.x == x and g.y == y then return g end
  end
  return nil
end

--- В таблице только числа, строки, bool и таблицы с ключами-числами и строками (годится для storage
--- без метатаблиц). → true │ false, путь.
function X.plain(v, path, seen)
  path, seen = path or "task", seen or {}
  local t = type(v)
  if t == "number" or t == "string" or t == "boolean" or t == "nil" then return true end
  if t ~= "table" then return false, path .. ": " .. t end
  if seen[v] then return true end
  seen[v] = true
  if getmetatable(v) ~= nil then return false, path .. ": metatable" end
  for k, x in pairs(v) do
    if type(k) ~= "number" and type(k) ~= "string" then return false, path .. ": key " .. type(k) end
    local ok, where = X.plain(x, path .. "." .. tostring(k), seen)
    if not ok then return false, where end
  end
  return true
end

return X
