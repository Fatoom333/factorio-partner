-- factorio-partner (stream M): adapter between the action `plan_mining` and the vendored layouts
-- of Mining Patch Planner 1.7.19 (Rimbas, MIT — see ../LICENSE, ../README.md).
--
-- The original mod takes its input from a LuaPlayer: the selection tool event, the settings
-- window (`storage.players[i].choices`) and per-player mod settings. Here the same state table is
-- built from plain arguments and a force:
--   adapter.prepare{surface, force, resources, layout, direction, miner?, belt?, pole?, pipe?,
--                   options?, dry_run?}  -> state │ nil, code, text
--   adapter.step(state)                  -> true when the layout has finished (one callback per call,
--                                           exactly like one tick of the original task runner)
--   adapter.summary(state)               -> {ok, ghosts, tiles, need, area, warnings, ...}
-- The state is plain data plus LuaObjects and tables with registered metatables, so the action
-- keeps it in `storage` (task) between ticks.
require("scripts.vendor.mpp.mpp.global_extends")
local mpp_util = require("scripts.vendor.mpp.mpp.mpp_util")
local common = require("scripts.vendor.mpp.layouts.common")
local tiles = require("scripts.perception.tiles")

local M = {}

M.VERSION = "1.7.19"
M.LAYOUT_NAMES = {
  "simple", "compact", "super_compact", "sparse", "logistics", "compact_logistics", "sparse_logistics",
}
M.DIRECTIONS = { "north", "east", "south", "west" }

local layouts = {}
for _, name in ipairs(M.LAYOUT_NAMES) do
  layouts[name] = require("scripts.vendor.mpp.layouts." .. name)
end
M.layouts = layouts

--- Flags of `options` (ACTIONS.md «plan_mining»): schema for the core validator.
M.OPTIONS_SCHEMA = {
  lamps = { type = "bool" },         -- lamps next to the power poles
  coverage = { type = "bool" },      -- more drills: cover every ore tile (MPP «overfill»)
  landfill = { type = "bool" },      -- tile ghosts (landfill) under buildings planned on water
  avoid_water = { type = "bool" },   -- no drills on tiles without support: water, lava, ... (default true)
  avoid_cliffs = { type = "bool" },  -- no drills on cliffs (default true)
  deconstruct = { type = "bool" },   -- mark trees and rocks in the way (default true)
  force_pipes = { type = "bool" },   -- pipes between drills even if the ore needs no fluid
  belt_merge = { type = "bool" },    -- merge half-empty output belts
  chest = { type = "string", max = 100 }, -- logistics layouts: chest name
}

local DEFAULT_CHEST = "passive-provider-chest"
local CHEST_TYPES = { ["logistic-container"] = true, ["container"] = true }
local MAX_WARNINGS = 20
local MAX_OUTPUTS = 16
local OUT_VECTOR = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }

local floor, ceil = math.floor, math.ceil

local function fail(code, text) return nil, code, text end

-- ------------------------------------------------------------------ research

local function place_item_names(proto)
  local out = {}
  local list = proto and proto.items_to_place_this
  if type(list) ~= "table" then return out end
  for _, it in ipairs(list) do
    local name = type(it) == "string" and it or (type(it) == "table" and it.name) or nil
    if type(name) == "string" then out[#out + 1] = name end
  end
  return out
end

--- Is there an enabled recipe of the force that makes the item of this entity?
function M.unlocked(force, entity_name)
  for _, item in ipairs(place_item_names(prototypes.entity[entity_name])) do
    local recipe = force.recipes[item]
    if recipe and recipe.enabled then return true end
    -- the recipe may be named differently from the item
    local ok, found = pcall(prototypes.get_recipe_filtered, {
      { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } },
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

--- Best researched entity of a type: highest score, ties by name.
local function best_of(force, type_name, accept, score)
  local names = {}
  for name in pairs(prototypes.get_entity_filtered{ { filter = "type", type = type_name } }) do
    names[#names + 1] = name
  end
  table.sort(names)
  local best, best_score
  for _, name in ipairs(names) do
    local proto = prototypes.entity[name]
    if proto and not proto.hidden and accept(name, proto) == nil and M.unlocked(force, name) then
      local s = score(name, proto)
      if best == nil or s > best_score then best, best_score = name, s end
    end
  end
  return best
end

-- ------------------------------------------------------------------ what fits a layout
-- Each `*_problem` returns nil (fits) or a text (why not) — the checks the settings window of
-- the original makes before it lets the player pick an entity.

local function miner_problem(layout, name, categories)
  local proto = prototypes.entity[name]
  if proto == nil or proto.type ~= "mining-drill" then return "unknown mining drill " .. name end
  local cats = proto.resource_categories
  if cats == nil or proto.vector_to_place_result == nil then
    return "mining drill " .. name .. " has no output position"
  end
  for category, resource in pairs(categories) do
    if not cats[category] then
      return "mining drill " .. name .. " can't mine " .. resource
    end
  end
  local struct = mpp_util.miner_struct(name)
  if struct.filtered then return "mining drill " .. name .. " can't be planned" end
  if common.is_miner_restricted(struct, layout.restrictions) or not layout:restriction_miner(struct) then
    return "layout " .. layout.name .. " doesn't support mining drill " .. name
      .. " (size " .. struct.size .. ", area " .. struct.area .. ")"
  end
  return nil
end

local function belt_problem(layout, name)
  local proto = prototypes.entity[name]
  if proto == nil or proto.type ~= "transport-belt" then return "unknown transport belt " .. name end
  local struct = mpp_util.belt_struct(name)
  if common.is_belt_restricted(struct, layout.restrictions) then
    return "layout " .. layout.name .. " needs an underground belt, " .. name .. " has none"
  end
  return nil
end

local function pole_problem(layout, name)
  local proto = prototypes.entity[name]
  if proto == nil or proto.type ~= "electric-pole" then return "unknown electric pole " .. name end
  local struct = mpp_util.pole_struct(name, "normal")
  if struct.filtered then return "electric pole " .. name .. " can't be planned" end
  if common.is_pole_restricted(struct, layout.restrictions) then
    return "layout " .. layout.name .. " doesn't support electric pole " .. name
      .. " (size " .. struct.size .. ", supply " .. struct.supply_area_distance .. ", wire " .. struct.wire .. ")"
  end
  return nil
end

-- ------------------------------------------------------------------ resources

local function is_solid(proto)
  local mp = proto and proto.mineable_properties
  local products = mp and mp.products
  if type(products) ~= "table" or #products == 0 then return false end
  for _, product in ipairs(products) do
    if product.type == "fluid" then return false end
  end
  return true
end
M.is_solid = is_solid

--- Bounds of the patch and resource statistics (algorithm.lua `process_entities` of the original).
local function process_entities(entities)
  local counts, categories = {}, {}
  local x1, y1 = math.huge, math.huge
  local x2, y2 = -math.huge, -math.huge
  for _, entity in ipairs(entities) do
    local name = entity.name
    counts[name] = 1 + (counts[name] or 0)
    local position = entity.position
    local x, y = position.x, position.y
    if x < x1 then x1 = x end
    if y < y1 then y1 = y end
    if x2 < x then x2 = x end
    if y2 < y then y2 = y end
  end

  local resource_counts = {}
  for name, count in pairs(counts) do
    resource_counts[#resource_counts + 1] = { name = name, count = count }
    categories[prototypes.entity[name].resource_category] = name
  end
  table.sort(resource_counts, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name < b.name
  end)

  local coords = {
    x1 = x1, y1 = y1, x2 = x2, y2 = y2,
    ix1 = floor(x1), iy1 = floor(y1),
    ix2 = ceil(x2), iy2 = ceil(y2),
    gx = x1 - 1, gy = y1 - 1,
  }
  coords.w, coords.h = coords.ix2 - coords.ix1, coords.iy2 - coords.iy1
  return coords, resource_counts, categories
end

-- ------------------------------------------------------------------ prepare

--- Build the state of a layout run. `p.resources` — solid resource entities of the patch.
---@return table|nil state
---@return string|nil code
---@return string|nil text
function M.prepare(p)
  local layout = layouts[p.layout]
  if layout == nil then return fail("bad_args", "args.layout: unknown layout " .. tostring(p.layout)) end
  local restrictions = layout.restrictions
  local force, surface = p.force, p.surface
  local options = p.options or {}
  local warnings = {}

  if #p.resources == 0 then return fail("not_found", "no ore to plan") end
  local coords, resource_counts, categories = process_entities(p.resources)

  local requires_fluid = false
  for _, t in ipairs(resource_counts) do
    if prototypes.entity[t.name].mineable_properties.required_fluid then requires_fluid = true end
  end
  if requires_fluid and not force.mining_with_fluid then
    return fail("bad_args", "mining with fluid is not researched (" .. resource_counts[1].name .. ")")
  end

  -- mining drill
  local miner = p.miner
  if miner ~= nil then
    local problem = miner_problem(layout, miner, categories)
    if problem then return fail("bad_args", "args.miner: " .. problem) end
    if not M.unlocked(force, miner) then warnings[#warnings + 1] = "not_researched:" .. miner end
  else
    miner = best_of(force, "mining-drill",
      function(name) return miner_problem(layout, name, categories) end,
      function(name, proto) return (proto.mining_speed or 0) * 1000 + mpp_util.miner_struct(name).area end)
    if miner == nil then
      return fail("bad_args", "no researched mining drill fits layout " .. layout.name
        .. " and " .. resource_counts[1].name)
    end
  end
  local miner_proto = prototypes.entity[miner]

  -- belt (the base layout reads the belt prototype even for the chest layouts)
  local belt = p.belt
  if belt ~= nil then
    local problem = belt_problem(layout, belt)
    if problem then return fail("bad_args", "args.belt: " .. problem) end
    if restrictions.belt_available and not M.unlocked(force, belt) then
      warnings[#warnings + 1] = "not_researched:" .. belt
    end
  elseif restrictions.belt_available then
    belt = best_of(force, "transport-belt",
      function(name)
        local problem = belt_problem(layout, name)
        if problem then return problem end
        local under = mpp_util.belt_struct(name).related_underground_belt
        if restrictions.uses_underground_belts and not M.unlocked(force, under) then
          return "underground belt is not researched"
        end
        return nil
      end,
      function(_, proto) return proto.belt_speed or 0 end)
    if belt == nil then
      return fail("bad_args", "no researched transport belt fits layout " .. layout.name)
    end
  else
    belt = "transport-belt"
    if prototypes.entity[belt] == nil then
      belt = best_of(force, "transport-belt", function() return nil end, function() return 0 end)
      if belt == nil then return fail("bad_args", "no transport belt prototype") end
    end
  end

  -- chest of the logistics layouts
  local chest = options.chest
  if restrictions.logistics_available then
    chest = chest or DEFAULT_CHEST
    local proto = prototypes.entity[chest]
    if proto == nil or not CHEST_TYPES[proto.type] then
      return fail("bad_args", "args.options.chest: unknown chest " .. chest)
    end
    if not M.unlocked(force, chest) then
      if options.chest == nil then
        return fail("bad_args", "layout " .. layout.name .. " needs " .. chest .. ", it is not researched")
      end
      warnings[#warnings + 1] = "not_researched:" .. chest
    end
  elseif chest ~= nil then
    return fail("bad_args", "args.options.chest: layout " .. layout.name .. " has no chests")
  else
    chest = DEFAULT_CHEST
  end

  -- power pole
  local pole = p.pole
  if pole == "none" then
    if not restrictions.pole_omittable then
      return fail("bad_args", "args.pole: layout " .. layout.name .. " needs power poles")
    end
  elseif pole == "zero_gap" then
    if not restrictions.pole_zero_gap then
      return fail("bad_args", "args.pole: layout " .. layout.name .. " has no zero_gap mode")
    end
  elseif pole ~= nil then
    local problem = pole_problem(layout, pole)
    if problem then return fail("bad_args", "args.pole: " .. problem) end
    if not M.unlocked(force, pole) then warnings[#warnings + 1] = "not_researched:" .. pole end
  elseif miner_proto.electric_energy_source_prototype == nil then
    pole = "none" -- burner drill: nothing to power
  else
    pole = best_of(force, "electric-pole",
      function(name) return pole_problem(layout, name) end,
      function(name)
        local s = mpp_util.pole_struct(name, "normal")
        return s.supply_area_distance * 100 + s.wire
      end)
    if pole == nil then
      pole = "none"
      warnings[#warnings + 1] = "no_pole_researched"
    end
  end

  -- pipe
  local pipe = p.pipe
  if pipe == "none" then
    -- as asked
  elseif pipe ~= nil then
    local proto = prototypes.entity[pipe]
    if proto == nil or proto.type ~= "pipe" then return fail("bad_args", "args.pipe: unknown pipe " .. pipe) end
    if not M.unlocked(force, pipe) then warnings[#warnings + 1] = "not_researched:" .. pipe end
  else
    pipe = best_of(force, "pipe", function() return nil end,
      function(name) return name == "pipe" and 1 or 0 end) or "none"
  end

  local lamps = options.lamps and true or false
  if lamps then
    if not restrictions.lamp_available then
      return fail("bad_args", "args.options.lamps: layout " .. layout.name .. " has no lamps")
    end
    if prototypes.entity["small-lamp"] == nil then
      return fail("bad_args", "args.options.lamps: no small-lamp prototype")
    end
    if not M.unlocked(force, "small-lamp") then warnings[#warnings + 1] = "not_researched:small-lamp" end
  end
  if options.coverage and not restrictions.coverage_tuning then
    return fail("bad_args", "args.options.coverage: layout " .. layout.name .. " has no coverage tuning")
  end
  if options.belt_merge and not restrictions.belt_merging_available then
    return fail("bad_args", "args.options.belt_merge: layout " .. layout.name .. " can't merge belts")
  end
  if options.force_pipes and not restrictions.pipe_available then
    return fail("bad_args", "args.options.force_pipes: layout " .. layout.name .. " places no pipes")
  end

  -- `avoid_water` (default true) means any tile the drill can't stand on without a cover tile
  -- (PROTOCOL 6.12: the rule is the collision mask of the tile against the mask of the drill, no
  -- tile names). Only an explicit `landfill = true` turns the default off: cover tiles are then
  -- planned under the buildings instead.
  local landfill = options.landfill and true or false
  local avoid_water = options.avoid_water
  if avoid_water == nil then avoid_water = not landfill end
  local avoid_layers = tiles.layer_list(tiles.entity_layers(miner))
  local avoid_cliffs = options.avoid_cliffs
  if avoid_cliffs == nil then avoid_cliffs = true end
  local deconstruct = options.deconstruct
  if deconstruct == nil then deconstruct = true end

  local direction = p.direction
  coords.is_horizontal = direction == "east" or direction == "west"
  coords.is_vertical = not coords.is_horizontal

  local state = {
    type = "layout",
    _callback = "start",
    tick = 0,
    mod_version = M.VERSION,
    _collected_ghosts = {},
    _render_objects = {},
    _lane_info_rendering = {},
    performance_scaling = 1,
    debug_dump = false,

    surface = surface,
    force = force,
    is_space = false,

    -- what the settings window of the original keeps in `choices`
    layout_choice = layout.name,
    direction_choice = direction,
    miner_choice = miner,
    miner_quality_choice = "normal",
    pole_choice = pole,
    pole_quality_choice = "normal",
    belt_choice = belt,
    belt_quality_choice = "normal",
    lamp_choice = lamps,
    logistics_choice = chest,
    logistics_quality_choice = "normal",
    landfill_choice = not landfill, -- in the original the flag means «omit landfill»
    coverage_choice = options.coverage and true or false,
    start_choice = false,
    deconstruction_choice = false,
    pipe_choice = pipe,
    pipe_quality_choice = "normal",
    module_choice = "none",
    module_quality_choice = "normal",
    ore_filtering_choice = false,
    belt_planner_choice = false,
    belt_merge_choice = options.belt_merge and true or false,
    balancer_choice = false,
    avoid_water_choice = avoid_water and true or false,
    avoid_cliffs_choice = avoid_cliffs and true or false,
    force_pipe_placement_choice = options.force_pipes and true or false,
    print_placement_info_choice = false,
    display_lane_filling_choice = false,

    coords = coords,
    resources = p.resources,
    found_resources = categories,
    requires_fluid = requires_fluid,
    resource_counts = resource_counts,

    -- counters of builder.lua
    partner = {
      dry_run = p.dry_run and true or false,
      deconstruct = deconstruct and true or false,
      placed = 0, tiles = 0, marked = 0,
      skipped = 0, skipped_names = {},
      need = {}, planned = {},
      warnings = warnings,
      avoid_layers = avoid_layers, -- mpp_util.unsupported_tiles
      belts = {},                  -- placed belt ghosts {x, y, direction, kind}: ends of the output lanes
    },
  }

  local ok, problem = layout:validate(state)
  if not ok then
    return fail("bad_args", "layout " .. layout.name .. ": " .. tostring(problem or "selection is not valid"))
  end
  layout:initialize(state)

  if requires_fluid and (state.pipe_choice == "none" or not state.miner.supports_fluids
      or not restrictions.pipe_available) then
    warnings[#warnings + 1] = "fluid_needed_no_pipes"
  end
  return state
end

-- ------------------------------------------------------------------ step

--- One callback of the layout state machine (mpp/task_runner.lua of the original).
---@return boolean finished
function M.step(state)
  local layout = layouts[state.layout_choice]
  local last_callback = state._callback
  local result = layout:tick(state)
  if result == last_callback then
    error("MPP layout " .. state.layout_choice .. " step " .. tostring(result) .. " called itself again", 0)
  elseif result == nil then
    error("MPP layout " .. state.layout_choice .. " step " .. tostring(last_callback) .. " has no result", 0)
  elseif result == false then
    return true
  elseif result ~= true then
    state._callback = result
  end
  return false
end

-- ------------------------------------------------------------------ summary

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

--- Result of a finished (or abandoned) run.
function M.summary(state)
  local P = state.partner
  local warnings = {}
  local function warn(text)
    if #warnings < MAX_WARNINGS then warnings[#warnings + 1] = text end
  end
  for _, w in ipairs(P.warnings) do warn(w) end

  local failed = false
  local seen = {}
  for _, message in ipairs(state.partner_messages or {}) do
    if message == "unable_to_create_a_layout" then failed = true end
    if not seen[message] then
      seen[message] = true
      warn(message)
    end
  end

  local attempt = state.best_attempt
  local drills = attempt and attempt.miners and #attempt.miners or 0
  local unconsumed = attempt and attempt.heuristics and attempt.heuristics.unconsumed or 0
  if unconsumed > 0 then warn("uncovered_ore_tiles:" .. unconsumed) end
  for _, name in ipairs(sorted_keys(P.skipped_names)) do
    warn("skipped:" .. name .. ":" .. P.skipped_names[name])
  end
  if P.marked > 0 then warn("marked_for_deconstruction:" .. P.marked) end

  local area
  local b = P.bounds
  if b then
    area = {
      left_top = { x = floor(b.x1), y = floor(b.y1) },
      right_bottom = { x = ceil(b.x2), y = ceil(b.y2) },
    }
  end

  local need = {}
  for _, name in ipairs(sorted_keys(P.need)) do need[name] = P.need[name] end

  -- Ends of the output belts: a belt that looks towards the output side and has no belt in the
  -- next tile. (An underground entrance continues under the ground — not an end.)
  local outputs = {}
  local out_dir = defines.direction[state.direction_choice]
  local vec = OUT_VECTOR[state.direction_choice]
  if out_dir ~= nil and vec ~= nil then
    local at = {}
    for _, b in ipairs(P.belts or {}) do at[b[1] .. "," .. b[2]] = true end
    for _, b in ipairs(P.belts or {}) do
      if b[3] == out_dir and b[4] ~= "input" and not at[(b[1] + vec[1]) .. "," .. (b[2] + vec[2])] then
        outputs[#outputs + 1] = { pos = { x = b[1], y = b[2] }, direction = out_dir }
      end
    end
    table.sort(outputs, function(a, b)
      if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
      return a.pos.y < b.pos.y
    end)
    while #outputs > MAX_OUTPUTS do outputs[#outputs] = nil end
  end

  return {
    ok = not failed and attempt ~= nil and P.placed > 0,
    ghosts = P.placed + P.tiles,
    entities = P.placed,
    tiles = P.tiles,
    drills = drills,
    skipped = P.skipped,
    need = need,
    area = area,
    warnings = warnings,
    outputs = outputs,
    choices = {
      miner = state.miner_choice, belt = state.belt_choice, pole = state.pole_choice,
      pipe = state.pipe_choice, chest = state.logistics_choice,
    },
  }
end

return M
