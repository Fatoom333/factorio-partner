-- factorio-partner (stream M): replacement of mpp/builder.lua of Mining Patch Planner 1.7.19
-- (Rimbas, MIT — see ../LICENSE). Same interface (`create_entity_builder`), rewritten body:
-- * ghosts belong to the owner's force (no LuaPlayer, no undo list, no blueprint item requests);
-- * every ghost passes `can_place_entity{build_check_type = manual_ghost}` first (PROTOCOL §6.5),
--   a ghost that does not pass is skipped and counted;
-- * quality is always normal (PROTOCOL §6.11);
-- * `dry_run` — nothing is created, only counted;
-- * the deconstruction planner of the player is replaced by marking trees and rocks only.
-- All counters live in `state.partner` (plain data, the state is kept in `storage`).
local mpp_util = require("scripts.vendor.mpp.mpp.mpp_util")
local coord_revert_world = mpp_util.revert_world

local builder = {}

local NORMAL = "normal"
local OBSTACLE_TYPES = { "tree", "simple-entity" }
local min, max, floor = math.min, math.max, math.floor
local EAST, WEST = defines.direction.east, defines.direction.west

--- Engine snapping of a building along one axis: odd size — centre of a tile, even size —
--- border between tiles.
local function snap(v, size)
  if size % 2 == 1 then return floor(v) + 0.5 end
  return floor(v + 0.5)
end

local function skip(P, name)
  P.skipped = P.skipped + 1
  P.skipped_names[name] = (P.skipped_names[name] or 0) + 1
end

local function add_need(P, proto)
  local list = proto and proto.items_to_place_this
  local first = type(list) == "table" and list[1] or nil
  if first == nil then return end
  local name, count
  if type(first) == "string" then
    name, count = first, 1
  else
    name, count = first.name, tonumber(first.count) or 1
  end
  if type(name) ~= "string" then return end
  P.need[name] = (P.need[name] or 0) + count
end

local function grow(P, x, y, half_w, half_h)
  local b = P.bounds
  if b == nil then
    P.bounds = { x1 = x - half_w, y1 = y - half_h, x2 = x + half_w, y2 = y + half_h }
    return
  end
  b.x1, b.y1 = min(b.x1, x - half_w), min(b.y1, y - half_h)
  b.x2, b.y2 = max(b.x2, x + half_w), max(b.y2, y + half_h)
end

--- Returns `create(ghost)`: grid specification -> ghost of the owner's force (or nil).
---@param state State
function builder.create_entity_builder(state, opts)
  local c = state.coords
  local grid = state.grid
  local DIR = state.direction_choice
  local surface = state.surface
  local force = state.force
  local gx, gy, tw, th = c.gx, c.gy, c.tw, c.th
  local direction_conv = mpp_util.bp_direction[DIR]
  local P = state.partner
  local check_type = defines.build_check_type.manual_ghost
  local forced = P.deconstruct and true or false
  local NORTH = defines.direction.north

  return function(ghost, check_allowed)
    local name = ghost.name
    local proto = type(name) == "string" and prototypes.entity[name] or nil
    if proto == nil then
      skip(P, tostring(name))
      return nil
    end
    local grid_direction = ghost.direction or NORTH
    local direction = direction_conv[grid_direction] or grid_direction
    -- The original hands the raw point to create_entity and lets the engine snap it to the
    -- tile grid. Here the point is snapped first, so that the manual_ghost check looks at
    -- exactly the place where the ghost will stand.
    local struct = mpp_util.entity_struct(name)
    local raw = coord_revert_world(gx, gy, DIR, ghost.grid_x, ghost.grid_y, tw, th)
    local w, h = struct.w, struct.h
    if direction == EAST or direction == WEST then w, h = h, w end
    local position = { snap(raw[1], w), snap(raw[2], h) }

    -- The pole connectivity pass of the original may list the same pole twice (the engine then
    -- just refuses the second ghost). That is not a skipped building: ignore the repeat.
    local spot = name .. "@" .. position[1] .. "," .. position[2]
    if P.planned[spot] then return nil end
    P.planned[spot] = true

    if not surface.can_place_entity{
      name = name,
      position = position,
      direction = direction,
      force = force,
      build_check_type = check_type,
      forced = forced,
    } then
      skip(P, name)
      return nil
    end

    local result
    if not P.dry_run then
      result = surface.create_entity{
        name = "entity-ghost",
        inner_name = name,
        position = position,
        direction = direction,
        force = force,
        quality = NORMAL,
        raise_built = true,
        type = ghost.type, -- underground belt: "input" | "output"
      }
      if result == nil then
        skip(P, name)
        return nil
      end
    end

    P.placed = P.placed + 1
    add_need(P, proto)
    grow(P, position[1], position[2], w / 2, h / 2)
    if ghost.thing and grid then
      grid:build_specification(ghost)
    end
    return result
  end
end

--- Landfill (or another cover tile) under a planned building: tile ghost of the owner's force.
---@param state State
---@param position MapPosition tile position
---@param tile_name string
function builder.create_tile_ghost(state, position, tile_name)
  local P = state.partner
  local proto = prototypes.tile[tile_name]
  if proto == nil then return nil end
  local result
  if not P.dry_run then
    result = state.surface.create_entity{
      name = "tile-ghost",
      inner_name = tile_name,
      position = position,
      force = state.force,
      raise_built = true,
    }
    if result == nil then return nil end
  end
  P.tiles = P.tiles + 1
  add_need(P, proto)
  local x, y = position.x or position[1], position.y or position[2]
  grow(P, x + 0.5, y + 0.5, 0.5, 0.5)
  return result
end

--- Trees and rocks under the planned buildings are marked for deconstruction by the owner's
--- force — what Shift-building does. Buildings of the player are never touched.
---@param state State
---@param lists GhostSpecification[][]
function builder.mark_obstacles(state, lists)
  local P = state.partner
  if not P.deconstruct then return end
  local c, DIR = state.coords, state.direction_choice
  local surface, force = state.surface, state.force
  local seen = {}

  for _, list in pairs(lists) do
    for _, object in ipairs(list) do
      local extent_w = object.extent_w or object.radius or 0.5
      local extent_h = object.extent_h or extent_w

      local x1, y1 = object.grid_x - extent_w, object.grid_y - extent_h
      local x2, y2 = object.grid_x + extent_w, object.grid_y + extent_h
      x1, y1 = mpp_util.revert_ex(c.gx, c.gy, DIR, x1, y1, c.tw, c.th)
      x2, y2 = mpp_util.revert_ex(c.gx, c.gy, DIR, x2, y2, c.tw, c.th)

      local found = surface.find_entities_filtered{
        area = { left_top = { min(x1, x2), min(y1, y2) }, right_bottom = { max(x1, x2), max(y1, y2) } },
        type = OBSTACLE_TYPES,
        force = "neutral",
      }
      for _, e in ipairs(found) do
        if e.valid and e.minable and not e.to_be_deconstructed() then
          local p = e.position
          local key = p.x .. "," .. p.y
          if not seen[key] then
            seen[key] = true
            if P.dry_run or e.order_deconstruction(force) then
              P.marked = P.marked + 1
            end
          end
        end
      end
    end
  end
end

return builder
