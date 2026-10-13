-- Wuastbude Belt & Pipe Router: index of underground belt runs and endpoints, conflict checks.
-- Author: wuast94. License: MIT (see LICENSE in this folder). Version 0.19.3,
-- https://git.wuastbude.de/Wuast94/wuastbude-pack, commit ad626eff, file wuastbude-router/scripts/underground_network.lua.
-- Changes for factorio-partner are marked [partner]: require path; live_conflict and
-- live_external_input removed. The module reads `underground_belt_neighbour`, which LuaEntity of
-- Factorio 2.0 does not have: scripts/lib/beltpath.lua feeds add_entities with plain tables instead.
local entity_policy = require("scripts.vendor.router.entity_policy") -- [partner] require path

local underground_network = {}

local vectors = {
  [0] = { 0, -1 },
  [4] = { 1, 0 },
  [8] = { 0, 1 },
  [12] = { -1, 0 },
}

local function tile(position)
  return math.floor(position.x), math.floor(position.y)
end

local function entity_name(entity)
  if entity.type == "underground-belt" then
    return entity.name
  end
  if entity.type == "entity-ghost" and entity.ghost_type == "underground-belt" then
    return entity.ghost_name
  end
  return nil
end

local function axis_for(direction)
  if direction == 4 or direction == 12 then
    return "x"
  end
  if direction == 0 or direction == 8 then
    return "y"
  end
  return nil
end

local function run_key(run)
  local axis_idx = run.axis == "y" and 1 or 0
  local length = run.maximum - run.minimum
  local lane_part = run.lane + 1048576
  local min_part = run.minimum + 1048576
  return ((lane_part * 2097152 + min_part) * 256 + length) * 2 + axis_idx
end

local function endpoint_key(endpoint)
  return (endpoint.x + 1048576) * 2097152 + (endpoint.y + 1048576)
end

local function position_key(x, y)
  return (x + 1048576) * 2097152 + (y + 1048576)
end

local function lane_index(index, name, axis, lane, create)
  local by_name = index[name]
  if not by_name then
    if not create then
      return nil
    end
    by_name = {}
    index[name] = by_name
  end
  local by_axis = by_name[axis]
  if not by_axis then
    if not create then
      return nil
    end
    by_axis = {}
    by_name[axis] = by_axis
  end
  local result = by_axis[lane]
  if not result and create then
    result = {}
    by_axis[lane] = result
  end
  return result
end

local function add_to_coordinate_index(index, name, axis, lane, coordinate, key, value)
  local lane_coordinates = lane_index(index, name, axis, lane, true)
  local bucket = lane_coordinates[coordinate]
  if not bucket then
    bucket = {}
    lane_coordinates[coordinate] = bucket
  end
  bucket[key] = value
end

local function count_lookup(statistics, name)
  if statistics then
    statistics[name] = (statistics[name] or 0) + 1
  end
end

local function source_key(entity)
  if entity.unit_number then
    return entity.unit_number
  end
  local x, y = tile(entity.position)
  return (x + 1048576) * 2097152 + (y + 1048576)
end

local function surface_output(entity)
  local entity_type = entity.type
  if entity_type == "entity-ghost" then
    entity_type = entity.ghost_type
  end
  if entity_type ~= "transport-belt" and entity_type ~= "underground-belt" then
    return nil
  end
  if entity_type == "underground-belt" and entity.belt_to_ground_type ~= "output" then
    return nil
  end
  local vector = vectors[entity.direction]
  if not vector then
    return nil
  end
  local x, y = tile(entity.position)
  return x + vector[1], y + vector[2]
end

function underground_network.empty()
  return {
    runs = {},
    run_keys = {},
    run_index = {},
    endpoints = {},
    endpoint_keys = {},
    endpoint_index = {},
    untyped_endpoint_index = {},
    belt_inputs = {},
    spatial_index_ready = true,
  }
end

function underground_network.from_edge(name, edge)
  local axis = axis_for(edge.direction)
  if not axis then
    return nil
  end
  local same_lane = axis == "x" and edge.from_y == edge.to_y or axis == "y" and edge.from_x == edge.to_x
  if not same_lane then
    return nil
  end
  local from_coordinate = axis == "x" and edge.from_x or edge.from_y
  local to_coordinate = axis == "x" and edge.to_x or edge.to_y
  return {
    name = name,
    axis = axis,
    lane = axis == "x" and edge.from_y or edge.from_x,
    minimum = math.min(from_coordinate, to_coordinate),
    maximum = math.max(from_coordinate, to_coordinate),
    direction = edge.direction,
    from_x = edge.from_x,
    from_y = edge.from_y,
    to_x = edge.to_x,
    to_y = edge.to_y,
  }
end

local function index_run(network, run, key)
  network.run_index = network.run_index or {}
  for coordinate = run.minimum, run.maximum do
    add_to_coordinate_index(network.run_index, run.name, run.axis, run.lane, coordinate, key, run)
  end
end

local function index_endpoint(network, endpoint, key)
  network.endpoint_index = network.endpoint_index or {}
  add_to_coordinate_index(
    network.endpoint_index,
    endpoint.name,
    endpoint.axis,
    endpoint.lane,
    endpoint.coordinate,
    key,
    endpoint
  )
  if endpoint.belt_to_ground_type ~= "input" and endpoint.belt_to_ground_type ~= "output" then
    network.untyped_endpoint_index = network.untyped_endpoint_index or {}
    local by_name = network.untyped_endpoint_index[endpoint.name]
    if not by_name then
      by_name = {}
      network.untyped_endpoint_index[endpoint.name] = by_name
    end
    by_name[endpoint.direction] = by_name[endpoint.direction] or endpoint
  end
end

local function add_run(network, run)
  if not run or run.minimum == run.maximum then
    return
  end
  local key = run_key(run)
  if not network.run_keys[key] then
    network.run_keys[key] = true
    network.runs[#network.runs + 1] = run
    index_run(network, run, key)
  end
end

local function add_endpoint(network, endpoint)
  local key = endpoint_key(endpoint)
  local existing = network.endpoint_keys[key]
  if existing then
    existing.paired = existing.paired or endpoint.paired
    return
  end
  network.endpoint_keys[key] = endpoint
  network.endpoints[#network.endpoints + 1] = endpoint
  index_endpoint(network, endpoint, key)
end

local function ensure_spatial_indexes(network)
  if network.spatial_index_ready then
    return
  end
  network.run_index = {}
  network.endpoint_index = {}
  network.untyped_endpoint_index = {}
  for _, run in ipairs(network.runs or {}) do
    index_run(network, run, run_key(run))
  end
  for _, endpoint in ipairs(network.endpoints or {}) do
    index_endpoint(network, endpoint, endpoint_key(endpoint))
  end
  network.spatial_index_ready = true
end

function underground_network.add_entities(network, entities, expected_name)
  network.belt_inputs = network.belt_inputs or {}
  for _, entity in pairs(entities) do
    local active = entity.valid ~= false and not entity_policy.is_ignored_blocker(entity)
    if active then
      local output_x, output_y = surface_output(entity)
      if output_x then
        local key = position_key(output_x, output_y)
        network.belt_inputs[key] = network.belt_inputs[key] or {}
        network.belt_inputs[key][source_key(entity)] = true
      end
    end
    local name = active and entity_name(entity) or nil
    if name and (not expected_name or name == expected_name) then
      local x, y = tile(entity.position)
      local axis = axis_for(entity.direction)
      if axis then
        local neighbour = entity.underground_belt_neighbour
        local paired = neighbour
          and neighbour.valid
          and entity_name(neighbour) == name
          and not entity_policy.is_ignored_blocker(neighbour)
        add_endpoint(network, {
          name = name,
          axis = axis,
          lane = axis == "x" and y or x,
          coordinate = axis == "x" and x or y,
          x = x,
          y = y,
          direction = entity.direction,
          belt_to_ground_type = entity.belt_to_ground_type,
          paired = paired == true,
        })
        if paired then
          local neighbour_x, neighbour_y = tile(neighbour.position)
          add_run(
            network,
            underground_network.from_edge(name, {
              from_x = x,
              from_y = y,
              to_x = neighbour_x,
              to_y = neighbour_y,
              direction = entity.direction,
            })
          )
        end
      end
    end
  end
end

function underground_network.merge(target, source)
  ensure_spatial_indexes(target)
  for _, run in ipairs(source.runs) do
    add_run(target, run)
  end
  for _, endpoint in ipairs(source.endpoints) do
    add_endpoint(target, endpoint)
  end
  target.belt_inputs = target.belt_inputs or {}
  for target_position, sources in pairs(source.belt_inputs or {}) do
    target.belt_inputs[target_position] = target.belt_inputs[target_position] or {}
    for source in pairs(sources) do
      target.belt_inputs[target_position][source] = true
    end
  end
end

local function has_belt_input(network, x, y, ignored_sources)
  local sources = network.belt_inputs and network.belt_inputs[position_key(x, y)]
  if not sources then
    return false
  end
  for source in pairs(sources) do
    if not (ignored_sources and ignored_sources[source]) then
      return true
    end
  end
  return false
end

local function overlaps(left, right)
  return left.name == right.name
    and left.axis == right.axis
    and left.lane == right.lane
    and left.minimum <= right.maximum
    and right.minimum <= left.maximum
end

local function lies_inside(endpoint, run)
  return endpoint.name == run.name
    and endpoint.axis == run.axis
    and endpoint.lane == run.lane
    and endpoint.coordinate >= run.minimum
    and endpoint.coordinate <= run.maximum
end

local function is_ahead(from_x, from_y, to_x, to_y, direction, maximum_distance)
  local vector = vectors[direction]
  if not vector then
    return false
  end
  local dx, dy = to_x - from_x, to_y - from_y
  local distance = math.abs(dx) + math.abs(dy)
  return distance >= 1 and distance <= maximum_distance and dx == vector[1] * distance and dy == vector[2] * distance
end

local function can_pair_with_candidate(endpoint, run, maximum_distance)
  if endpoint.name ~= run.name or endpoint.direction ~= run.direction then
    return false
  end
  if endpoint.belt_to_ground_type == "output" then
    return is_ahead(run.from_x, run.from_y, endpoint.x, endpoint.y, run.direction, maximum_distance)
  end
  if endpoint.belt_to_ground_type == "input" then
    return is_ahead(endpoint.x, endpoint.y, run.to_x, run.to_y, run.direction, maximum_distance)
  end
  return true
end

local function indexed_run_conflict(network, candidate, statistics)
  local coordinates = lane_index(network.run_index or {}, candidate.name, candidate.axis, candidate.lane, false)
  if not coordinates then
    return false
  end
  local seen = {}
  for coordinate = candidate.minimum, candidate.maximum do
    count_lookup(statistics, "run_bucket_lookups")
    local bucket = coordinates[coordinate]
    if bucket then
      for key, existing in pairs(bucket) do
        if not seen[key] then
          seen[key] = true
          count_lookup(statistics, "run_candidates")
          if overlaps(candidate, existing) then
            return true
          end
        end
      end
    end
  end
  return false
end

local function indexed_endpoint_conflict(network, candidate, maximum_distance, statistics)
  local coordinates = lane_index(network.endpoint_index or {}, candidate.name, candidate.axis, candidate.lane, false)
  local seen_endpoints = {}
  local seen_coordinates = {}

  local function inspect_coordinate(coordinate)
    if seen_coordinates[coordinate] then
      return false
    end
    seen_coordinates[coordinate] = true
    count_lookup(statistics, "endpoint_bucket_lookups")
    local bucket = coordinates and coordinates[coordinate] or nil
    if not bucket then
      return false
    end
    for key, endpoint in pairs(bucket) do
      if not seen_endpoints[key] then
        seen_endpoints[key] = true
        count_lookup(statistics, "endpoint_candidates")
        if lies_inside(endpoint, candidate) or can_pair_with_candidate(endpoint, candidate, maximum_distance) then
          return true
        end
      end
    end
    return false
  end

  for coordinate = candidate.minimum, candidate.maximum do
    if inspect_coordinate(coordinate) then
      return true
    end
  end

  local vector = vectors[candidate.direction]
  local from_coordinate = candidate.axis == "x" and candidate.from_x or candidate.from_y
  local to_coordinate = candidate.axis == "x" and candidate.to_x or candidate.to_y
  local coordinate_step = candidate.axis == "x" and vector[1] or vector[2]
  for distance = 1, maximum_distance do
    if inspect_coordinate(from_coordinate + coordinate_step * distance) then
      return true
    end
    if inspect_coordinate(to_coordinate - coordinate_step * distance) then
      return true
    end
  end

  local by_name = (network.untyped_endpoint_index or {})[candidate.name]
  local untyped = by_name and by_name[candidate.direction] or nil
  if untyped and not seen_endpoints[endpoint_key(untyped)] then
    count_lookup(statistics, "endpoint_candidates")
    return true
  end
  return false
end

function underground_network.conflicts(network, name, edge, maximum_distance, statistics)
  ensure_spatial_indexes(network)
  local candidate = underground_network.from_edge(name, edge)
  if not candidate then
    return true
  end
  if
    has_belt_input(network, candidate.from_x, candidate.from_y)
    or has_belt_input(network, candidate.to_x, candidate.to_y)
  then
    return true
  end
  return indexed_run_conflict(network, candidate, statistics)
    or indexed_endpoint_conflict(network, candidate, maximum_distance, statistics)
end

function underground_network.route_conflict(name, edges)
  local occupied = {}
  for _, edge in ipairs(edges) do
    if edge.kind == "underground" then
      local run = underground_network.from_edge(name, edge)
      if not run then
        return edge, edge
      end
      for coordinate = run.minimum, run.maximum do
        local key = table.concat({ run.name, run.axis, run.lane, coordinate }, ":")
        if occupied[key] then
          return occupied[key], edge
        end
        occupied[key] = edge
      end
    end
  end
  return nil
end

function underground_network.edge_key(name, edge)
  local run = underground_network.from_edge(name, edge)
  return run and run_key(run) or nil
end

-- [partner] live_conflict and live_external_input removed (they query the surface)

function underground_network.source_key(entity)
  return source_key(entity)
end

function underground_network.pair_error(input, output, run)
  if not (input and input.valid and output and output.valid) then
    return "an endpoint disappeared"
  end
  if input.direction ~= run.direction or output.direction ~= run.direction then
    return "Factorio changed an endpoint direction"
  end
  if input.belt_to_ground_type ~= "input" or output.belt_to_ground_type ~= "output" then
    return "Factorio changed an endpoint type"
  end
  if input.underground_belt_neighbour ~= output or output.underground_belt_neighbour ~= input then
    return "endpoints are not reciprocal neighbours"
  end
  return nil
end

function underground_network.pair_is_exact(input, output, run)
  return underground_network.pair_error(input, output, run) == nil
end

return underground_network
