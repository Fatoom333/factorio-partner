-- Заглушки потока M («Разметка добычи»). Дополняют stubs.lua (A) и stubs_c.lua (C), TESTING.md §1.
--
--   local S = require("stubs"); local X = require("stubs_m")
--   local W = X.setup{ research = { "electric-mining-drill", "transport-belt" } }
--   X.patch("iron-ore", 0, 0, 12, 9)                 -- прямоугольник руды: клетки x 0..11, y 0..8
--   local d, kind = X.plan{ near = { x = 5, y = 4 } } -- act plan_mining + ожидание итога
--   X.ghosts("electric-mining-drill")                 -- поставленные призраки {name, pos, direction, ...}
--
-- Что даёт сверх stubs_c:
-- * прототипы буров, лент, столбов, труб, сундука, лампы с полями, которые читает код MPP
--   (collision_box, mining_drill_radius, vector_to_place_result, fluidbox_prototypes, ...);
-- * `prototypes.get_entity_filtered{{filter="type"}}`, `prototypes.get_recipe_filtered` (пусто),
--   `prototypes.tile`; рецепты силы (X.research / X.forget);
-- * проверка постановки: X.blocked["x,y"] = true, призрак на занятом призраком месте не встаёт,
--   журнал X.checks; вода X.water{...}; деревья X.tree(pos) с пометкой к сносу;
-- * `script.register_metatable` (журнал X.metatables) и `script.feature_flags`.
local S = require("stubs")
local C = require("stubs_c")

local X = {}

local D = { north = 0, east = 4, south = 8, west = 12 }

-- ===================================================================== прототипы

local function buildable(name, etype, w, h, extra)
  local E, I = prototypes.entity, prototypes.item
  local p = { name = name, type = etype }
  p.flags = { ["player-creation"] = true, ["placeable-player"] = true }
  p.hidden = false
  p.items_to_place_this = { { name = name, count = 1 } }
  p.collision_box = {
    left_top = { x = -w / 2 + 0.1, y = -h / 2 + 0.1 }, right_bottom = { x = w / 2 - 0.1, y = h / 2 - 0.1 },
  }
  p.tile_width, p.tile_height = w, h
  p.max_health = 100
  for k, v in pairs(extra or {}) do p[k] = v end
  E[name] = p
  I[name] = I[name] or { name = name, type = "item", stack_size = 50 }
  I[name].place_result = p
  return p
end

local function pipes(off)
  return { {
    production_type = "input-output",
    pipe_connections = {
      { direction = D.west, positions = { { x = -off, y = 0 } } },
      { direction = D.east, positions = { { x = off, y = 0 } } },
      { direction = D.south, positions = { { x = 0, y = off } } },
    },
  } }
end

local function pole(name, size, supply, wire)
  return buildable(name, "electric-pole", size, size, {
    get_supply_area_distance = function() return supply end,
    get_max_wire_distance = function() return wire end,
  })
end

local function belt(name, speed, under_name, reach)
  local under = buildable(under_name, "underground-belt", 1, 1, { max_underground_distance = reach, belt_speed = speed })
  return buildable(name, "transport-belt", 1, 1, { belt_speed = speed, related_underground_belt = under })
end

function X.prototypes()
  local E = prototypes.entity
  buildable("electric-mining-drill", "mining-drill", 3, 3, {
    mining_speed = 0.5, mining_drill_radius = 2.49, module_inventory_size = 3,
    resource_categories = { ["basic-solid"] = true },
    vector_to_place_result = { 0, -1.85 },
    fluidbox_prototypes = pipes(1),
    electric_energy_source_prototype = { valid = true },
    uses_force_mining_productivity_bonus = true,
  })
  buildable("burner-mining-drill", "mining-drill", 2, 2, {
    mining_speed = 0.25, mining_drill_radius = 0.99, module_inventory_size = 0,
    resource_categories = { ["basic-solid"] = true },
    vector_to_place_result = { -0.5, -1.3 },
    fluidbox_prototypes = {},
    burner_prototype = { fuel_categories = { chemical = true } },
    uses_force_mining_productivity_bonus = true,
  })
  buildable("big-mining-drill", "mining-drill", 5, 5, {
    mining_speed = 2.5, mining_drill_radius = 6.49, module_inventory_size = 4,
    resource_categories = { ["basic-solid"] = true, ["hard-solid"] = true },
    vector_to_place_result = { 0, -2.85 },
    fluidbox_prototypes = pipes(2),
    electric_energy_source_prototype = { valid = true },
    uses_force_mining_productivity_bonus = true,
  })
  -- насос: добывает только жидкость
  buildable("pumpjack", "mining-drill", 3, 3, {
    mining_speed = 1, mining_drill_radius = 0.49, module_inventory_size = 2,
    resource_categories = { ["basic-fluid"] = true },
    vector_to_place_result = { 0, 0 },
    fluidbox_prototypes = {},
    electric_energy_source_prototype = { valid = true },
  })
  belt("transport-belt", 0.03125, "underground-belt", 5)
  belt("fast-transport-belt", 0.0625, "fast-underground-belt", 7)
  pole("small-electric-pole", 1, 2.5, 7.5)
  pole("medium-electric-pole", 1, 3.5, 9)
  pole("big-electric-pole", 2, 2, 32)
  buildable("pipe", "pipe", 1, 1)
  buildable("pipe-to-ground", "pipe-to-ground", 1, 1, { max_underground_distance = 10 })
  buildable("small-lamp", "lamp", 1, 1)
  buildable("passive-provider-chest", "logistic-container", 1, 1)

  E["crude-oil"] = {
    name = "crude-oil", type = "resource", resource_category = "basic-fluid",
    mineable_properties = { minable = true, mining_time = 1, products = { { type = "fluid", name = "crude-oil", amount = 10 } } },
  }
  E["tree-01"].type = "tree"
  E["big-rock"] = { name = "big-rock", type = "simple-entity",
    mineable_properties = { minable = true, mining_time = 2, products = { { type = "item", name = "stone", amount = 20 } } } }

  prototypes.tile = {
    water = { name = "water", default_cover_tile = { name = "landfill" } },
    landfill = { name = "landfill", items_to_place_this = { { name = "landfill", count = 1 } } },
  }
  prototypes.item["landfill"] = { name = "landfill", type = "item", stack_size = 100 }
  prototypes.quality = { normal = { name = "normal", level = 0 } }

  prototypes.get_entity_filtered = function(filters)
    local out = {}
    for name, p in pairs(prototypes.entity) do
      for _, f in ipairs(filters) do
        if f.filter == "type" and p.type == f.type then out[name] = p end
      end
    end
    return out
  end
  -- рецептов с другим именем, чем у предмета, в заглушках нет
  X.recipe_searches = 0
  prototypes.get_recipe_filtered = function()
    X.recipe_searches = X.recipe_searches + 1
    return X.extra_recipes or {}
  end
end

--- Открыть исследованием (включить рецепт предмета постройки).
function X.research(...)
  local force = game.forces.player
  for _, name in ipairs({ ... }) do
    force.recipes[name] = { name = name, enabled = true, valid = true }
  end
end

function X.forget(...)
  local force = game.forces.player
  for _, name in ipairs({ ... }) do
    force.recipes[name] = { name = name, enabled = false, valid = true }
  end
end

X.BASIC = { "electric-mining-drill", "transport-belt", "underground-belt", "small-electric-pole", "pipe" }

-- ===================================================================== мир

function X.key(pos)
  local p = S.norm_pos(pos)
  return string.format("%g,%g", p.x, p.y)
end

local CHECK_NAMES

local function check_name(id)
  if CHECK_NAMES == nil then
    CHECK_NAMES = {}
    for k, v in pairs(defines.build_check_type) do CHECK_NAMES[v] = k end
  end
  return CHECK_NAMES[id] or tostring(id)
end

--- X.setup{ research = {...} | nil (X.BASIC), fluid = bool } → W (как C.setup): мод, хозяин, помощник h1.
function X.setup(opts)
  opts = opts or {}
  X.blocked, X.checks, X.water_tiles, X.marked, X.extra_recipes = {}, {}, {}, {}, nil
  X.block_all = false
  CHECK_NAMES = nil
  local W = C.setup(opts)
  X.prototypes()
  X.W = W
  local force = game.forces.player
  force.mining_with_fluid = opts.fluid and true or false
  force.mining_drill_productivity_bonus = 0
  for _, name in ipairs({ "burner-mining-drill", "big-mining-drill", "fast-transport-belt", "fast-underground-belt",
    "medium-electric-pole", "big-electric-pole", "pipe-to-ground", "small-lamp", "passive-provider-chest" }) do
    X.forget(name)
  end
  X.forget(table.unpack(X.BASIC))
  X.research(table.unpack(opts.research or X.BASIC))

  S.nauvis.can_place = function(_, params)
    local pos = S.norm_pos(params.position)
    X.checks[#X.checks + 1] = {
      kind = check_name(params.build_check_type), name = params.name, pos = pos,
      direction = params.direction, force = params.force, forced = params.forced,
    }
    if X.block_all or X.blocked[X.key(pos)] then return false end
    for _, e in ipairs(S.nauvis._entities) do
      if e.valid and e.name == "entity-ghost" and e.position.x == pos.x and e.position.y == pos.y then
        return false
      end
    end
    return true
  end
  X.tile_masks = {}
  S.nauvis.find_tiles_filtered = function(f)
    X.tile_masks[#X.tile_masks + 1] = f.collision_mask
    local area = S.norm_area(f.area)
    local out = {}
    for _, t in ipairs(X.water_tiles) do
      if t.x >= area.left_top.x and t.x < area.right_bottom.x and t.y >= area.left_top.y and t.y < area.right_bottom.y then
        out[#out + 1] = { name = "water", position = { x = t.x, y = t.y }, prototype = prototypes.tile.water, valid = true }
      end
    end
    return out
  end
  return W
end

--- Прямоугольник руды: клетки x0..x0+w-1, y0..y0+h-1 (сущности в центрах клеток).
function X.patch(name, x0, y0, w, h, amount)
  local out = {}
  for y = y0, y0 + h - 1 do
    for x = x0, x0 + w - 1 do
      out[#out + 1] = C.resource(name, { x = x + 0.5, y = y + 0.5 }, amount or 1000)
    end
  end
  return out
end

--- Вода в клетках (левый верхний угол клетки).
function X.water(tiles)
  for _, t in ipairs(tiles) do X.water_tiles[#X.water_tiles + 1] = { x = t.x or t[1], y = t.y or t[2] } end
end

--- Дерево (или камень) нейтральной силы; пометки к сносу — X.marked.
function X.tree(pos, name)
  local e
  local marked = false
  e = S.nauvis.create_entity{ name = name or "tree-01", position = pos, force = "neutral", fields = {
    minable = true,
    to_be_deconstructed = function() return marked end,
    order_deconstruction = function(force)
      marked = true
      X.marked[#X.marked + 1] = { name = e.name, pos = S.norm_pos(e.position), force = force }
      return true
    end,
  } }
  return e
end

-- ===================================================================== задача и призраки

--- act plan_mining → data, kind (ждёт итога); extra — поля конверта act.
function X.plan(args, n)
  local job = S.okr(C.act("plan_mining", args)).job
  local d, kind = C.wait(job, n or 2000)
  return d, kind, job
end

--- Созданные скриптом призраки: {name (inner), pos, direction, force, quality, raise_built, kind (entity-ghost│tile-ghost), type}.
function X.ghosts(name)
  local out = {}
  for _, p in ipairs(S.nauvis.created or {}) do
    if (p.name == "entity-ghost" or p.name == "tile-ghost") and (name == nil or p.inner_name == name) then
      out[#out + 1] = {
        kind = p.name, name = p.inner_name, pos = S.norm_pos(p.position), direction = p.direction,
        force = p.force, quality = p.quality, raise_built = p.raise_built, type = p.type,
      }
    end
  end
  return out
end

--- Число призраков по именам.
function X.ghost_counts()
  local out = {}
  for _, g in ipairs(X.ghosts()) do out[g.name] = (out[g.name] or 0) + 1 end
  return out
end

--- Каждая клетка руды попадает в зону хотя бы одного бура? → bool, число непокрытых.
function X.covered(ore, miner_name)
  local proto = prototypes.entity[miner_name]
  local r = proto.mining_drill_radius
  local drills = X.ghosts(miner_name)
  local missed = 0
  for _, o in ipairs(ore) do
    local ok = false
    for _, g in ipairs(drills) do
      if math.abs(o.position.x - g.pos.x) <= r and math.abs(o.position.y - g.pos.y) <= r then ok = true break end
    end
    if not ok then missed = missed + 1 end
  end
  return missed == 0, missed
end

X.D = D

return X
