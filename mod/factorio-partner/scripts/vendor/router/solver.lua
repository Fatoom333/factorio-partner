-- Wuastbude Belt & Pipe Router: grid A* over (cell, direction) states with underground edges.
-- Author: wuast94. License: MIT (see LICENSE in this folder). Version 0.19.3,
-- https://git.wuastbude.de/Wuast94/wuastbude-pack, commit ad626eff, file wuastbude-router/scripts/solver.lua.
-- Changes for factorio-partner: none (this header only). The file does not touch the game API.
local solver = {}

local DIRECTIONS = { 0, 4, 8, 12 }
local DX = { 0, 1, 0, -1 }
local DY = { -1, 0, 1, 0 }
local DIRECTION_INDEX = { [0] = 0, [4] = 1, [8] = 2, [12] = 3 }
local STATE_SLOTS = 13
local TURN_PENALTY = 16
local COST_SCALE = 4
local HEURISTIC_SCALE = 12

local function integer(value, name)
  if type(value) ~= "number" or value ~= math.floor(value) then
    error(name .. " must be an integer", 3)
  end
  return value
end

local function heap_push(state, id, length, f_score, turns, preference, sequence)
  local heap_id = state.open_id
  local heap_f_score = state.open_f_score
  local heap_turns = state.open_turns
  local heap_length = state.open_length
  local heap_preference = state.open_preference
  local heap_sequence = state.open_sequence

  local index = #heap_id + 1

  while index > 1 do
    local parent = math.floor(index / 2)
    local pf = heap_f_score[parent]
    local pt = heap_turns[parent]
    local pl = heap_length[parent]
    local pp = heap_preference[parent]
    local ps = heap_sequence[parent]

    local new_less = false
    if f_score ~= pf then
      new_less = f_score < pf
    elseif turns ~= pt then
      new_less = turns < pt
    elseif length ~= pl then
      new_less = length < pl
    elseif preference ~= pp then
      new_less = preference < pp
    else
      new_less = sequence < ps
    end

    if not new_less then
      break
    end

    heap_id[index] = heap_id[parent]
    heap_f_score[index] = pf
    heap_turns[index] = pt
    heap_length[index] = pl
    heap_preference[index] = pp
    heap_sequence[index] = ps

    index = parent
  end

  heap_id[index] = id
  heap_f_score[index] = f_score
  heap_turns[index] = turns
  heap_length[index] = length
  heap_preference[index] = preference
  heap_sequence[index] = sequence
end

local function heap_pop(state)
  local heap_id = state.open_id
  local heap_f_score = state.open_f_score
  local heap_turns = state.open_turns
  local heap_length = state.open_length
  local heap_preference = state.open_preference
  local heap_sequence = state.open_sequence

  local size = #heap_id
  if size == 0 then
    return nil
  end

  local root_id = heap_id[1]
  local root_length = heap_length[1]
  local root_f_score = heap_f_score[1]
  local root_turns = heap_turns[1]
  local root_preference = heap_preference[1]
  local root_sequence = heap_sequence[1]

  local last_id = heap_id[size]
  local last_length = heap_length[size]
  local last_f_score = heap_f_score[size]
  local last_turns = heap_turns[size]
  local last_preference = heap_preference[size]
  local last_sequence = heap_sequence[size]

  heap_id[size] = nil
  heap_f_score[size] = nil
  heap_turns[size] = nil
  heap_length[size] = nil
  heap_preference[size] = nil
  heap_sequence[size] = nil

  size = size - 1
  if size == 0 then
    return root_id, root_length, root_f_score, root_turns, root_preference, root_sequence
  end

  local index = 1
  while true do
    local left = index * 2
    if left > size then
      break
    end
    local child = left
    if left + 1 <= size then
      local lf = heap_f_score[left]
      local rf = heap_f_score[left + 1]
      local right_less = false
      if lf ~= rf then
        right_less = rf < lf
      else
        local lt = heap_turns[left]
        local rt = heap_turns[left + 1]
        if lt ~= rt then
          right_less = rt < lt
        else
          local llen = heap_length[left]
          local rlen = heap_length[left + 1]
          if llen ~= rlen then
            right_less = rlen < llen
          else
            local lpref = heap_preference[left]
            local rpref = heap_preference[left + 1]
            if lpref ~= rpref then
              right_less = rpref < lpref
            else
              right_less = heap_sequence[left + 1] < heap_sequence[left]
            end
          end
        end
      end
      if right_less then
        child = left + 1
      end
    end

    local cf = heap_f_score[child]
    local ct = heap_turns[child]
    local clen = heap_length[child]
    local cpref = heap_preference[child]
    local cseq = heap_sequence[child]

    local last_less = false
    if last_f_score ~= cf then
      last_less = last_f_score < cf
    else
      if last_turns ~= ct then
        last_less = last_turns < ct
      else
        if last_length ~= clen then
          last_less = last_length < clen
        else
          if last_preference ~= cpref then
            last_less = last_preference < cpref
          else
            last_less = last_sequence < cseq
          end
        end
      end
    end

    if last_less then
      break
    end

    heap_id[index] = heap_id[child]
    heap_f_score[index] = cf
    heap_turns[index] = ct
    heap_length[index] = clen
    heap_preference[index] = cpref
    heap_sequence[index] = cseq

    index = child
  end

  heap_id[index] = last_id
  heap_f_score[index] = last_f_score
  heap_turns[index] = last_turns
  heap_length[index] = last_length
  heap_preference[index] = last_preference
  heap_sequence[index] = last_sequence

  return root_id, root_length, root_f_score, root_turns, root_preference, root_sequence
end

local function length_heuristic(state, x, y)
  return math.abs(state.goal.x - x) + math.abs(state.goal.y - y)
end

local function in_bounds(state, x, y)
  local bounds = state.bounds
  if not bounds then
    return true
  end
  return x >= bounds.min_x and x <= bounds.max_x and y >= bounds.min_y and y <= bounds.max_y
end

local function coordinate_key(x, y)
  return (x + 1048576) * 2097152 + (y + 1048576)
end

local function state_id(state, x, y, direction_slot)
  local key = coordinate_key(x, y)
  local coordinate_id = state.coordinate_ids[key]
  if not coordinate_id then
    coordinate_id = #state.coordinate_x + 1
    state.coordinate_ids[key] = coordinate_id
    state.coordinate_x[coordinate_id] = x
    state.coordinate_y[coordinate_id] = y
  end
  return (coordinate_id - 1) * STATE_SLOTS + direction_slot + 1
end

local function decode_state(state, id)
  local packed = id - 1
  local direction_slot = packed % STATE_SLOTS
  local coordinate_id = ((packed - direction_slot) / STATE_SLOTS) + 1
  return state.coordinate_x[coordinate_id], state.coordinate_y[coordinate_id], direction_slot
end

local function logical_direction(direction_slot)
  if direction_slot < 4 then
    return direction_slot
  end
  if direction_slot < 12 then
    return direction_slot % 4
  end
  return nil
end

local function turn_heuristic(state, x, y, direction_slot)
  local dx = state.goal.x - x
  local dy = state.goal.y - y
  if dx == 0 and dy == 0 then
    return 0
  end

  local current = logical_direction(direction_slot)
  local horizontal = dx > 0 and 1 or (dx < 0 and 3 or nil)
  local vertical = dy > 0 and 2 or (dy < 0 and 0 or nil)
  local goal = state.goal.direction and DIRECTION_INDEX[state.goal.direction] or nil
  local function transition(from, to)
    return from ~= nil and from ~= to and 1 or 0
  end
  local function finish(last)
    return goal ~= nil and goal ~= last and 1 or 0
  end

  if horizontal and vertical then
    return math.min(
      transition(current, horizontal) + 1 + finish(vertical),
      transition(current, vertical) + 1 + finish(horizontal)
    )
  end
  local required = horizontal or vertical
  return transition(current, required) + finish(required)
end

local function preference_cost(mode, kind, length)
  if mode == "prefer-underground" then
    return kind == "ground" and length or 0
  end
  return kind == "underground" and length or 0
end

local function edge_cache_key(edge)
  local dir_idx = DIRECTION_INDEX[edge.direction] or 0
  local length = edge.length or 1
  local base = (edge.from_x + 1048576) * 2097152 + (edge.from_y + 1048576)
  local kind_idx = edge.kind == "underground" and 1 or 0
  return (base * 128 + dir_idx * 32 + length * 2) + kind_idx
end

local function can_place(state, callbacks, edge)
  local key = edge_cache_key(edge)
  local cached = state.placement_cache[key]
  if cached ~= nil then
    return cached
  end
  local result = callbacks.can_place(edge.kind, edge.to_x, edge.to_y, edge.direction, edge)
  if result == nil then
    return nil
  end
  local allowed = result == true
  state.placement_cache[key] = allowed
  return allowed
end

local function underground_edges(state, callbacks, x, y, direction)
  local dir_idx = DIRECTION_INDEX[direction] or 0
  local key = ((x + 1048576) * 2097152 + (y + 1048576)) * 4 + dir_idx
  local cached = state.underground_cache[key]
  if cached then
    return cached
  end

  local supplied = callbacks.underground_edges(x, y, direction) or {}
  local result = {}
  for index = 1, #supplied do
    local candidate = supplied[index]
    local to_x = integer(candidate.x, "underground edge x")
    local to_y = integer(candidate.y, "underground edge y")
    local candidate_direction = candidate.direction == nil and direction or candidate.direction
    local direction_index = DIRECTION_INDEX[candidate_direction]
    local length = candidate.length or (math.abs(to_x - x) + math.abs(to_y - y))
    if
      direction_index == DIRECTION_INDEX[direction]
      and integer(length, "underground edge length") > 0
      and math.abs(to_x - x) + math.abs(to_y - y) == length
      and to_x - x == DX[direction_index + 1] * length
      and to_y - y == DY[direction_index + 1] * length
      and in_bounds(state, to_x, to_y)
    then
      result[#result + 1] = {
        kind = "underground",
        from_x = x,
        from_y = y,
        to_x = to_x,
        to_y = to_y,
        direction = candidate_direction,
        length = length,
        metadata = candidate.metadata,
      }
    end
  end
  table.sort(result, function(a, b)
    if a.length ~= b.length then
      return a.length < b.length
    end
    if a.to_x ~= b.to_x then
      return a.to_x < b.to_x
    end
    if a.to_y ~= b.to_y then
      return a.to_y < b.to_y
    end
    return a.direction < b.direction
  end)
  state.underground_cache[key] = result
  return result
end

local function relax(state, from_id, from_direction_slot, edge)
  local direction_index = DIRECTION_INDEX[edge.direction]
  local destination_slot = edge.kind == "underground" and direction_index + 8 or direction_index
  local id = state_id(state, edge.to_x, edge.to_y, destination_slot)
  local length = state.best_length[from_id] + edge.length
  local turns = state.best_turns[from_id]
  local from_direction_index = logical_direction(from_direction_slot)
  if from_direction_index ~= nil and from_direction_index ~= direction_index then
    turns = turns + 1
  end
  local preference = state.best_preference[from_id] + preference_cost(state.mode, edge.kind, edge.length)
  local score = length + turns * TURN_PENALTY

  local old_score = state.best_score[id]
  local improves = old_score == nil
    or score < old_score
    or (score == old_score and turns < state.best_turns[id])
    or (score == old_score and turns == state.best_turns[id] and preference < state.best_preference[id])
  if not improves then
    return
  end

  state.best_length[id] = length
  state.best_turns[id] = turns
  state.best_preference[id] = preference
  state.best_score[id] = score
  state.parent[id] = from_id
  state.parent_edge[id] = edge
  state.sequence = state.sequence + 1

  local f_score = score * COST_SCALE
    + (
        length_heuristic(state, edge.to_x, edge.to_y)
        + turn_heuristic(state, edge.to_x, edge.to_y, destination_slot) * TURN_PENALTY
      )
      * HEURISTIC_SCALE
  heap_push(state, id, length, f_score, turns, preference, state.sequence)
end

local function begin_reconstruction(state, goal_id)
  state.reconstruction = {
    goal_id = goal_id,
    id = goal_id,
    phase = "trace",
    reversed_nodes = {},
    reversed_edges = {},
  }
end

local function reconstruct(state, budget)
  local reconstruction = state.reconstruction
  local used = 0
  while used < budget do
    if reconstruction.phase == "trace" then
      if reconstruction.id then
        local id = reconstruction.id
        local x, y, direction_slot = decode_state(state, id)
        local direction_index = logical_direction(direction_slot)
        reconstruction.reversed_nodes[#reconstruction.reversed_nodes + 1] = {
          x = x,
          y = y,
          direction = direction_index ~= nil and DIRECTIONS[direction_index + 1] or nil,
        }
        local edge = state.parent_edge[id]
        if edge then
          reconstruction.reversed_edges[#reconstruction.reversed_edges + 1] = edge
        end
        reconstruction.id = state.parent[id]
        used = used + 1
      else
        reconstruction.route = {
          strategy = "astar",
          cost = {
            length = state.best_length[reconstruction.goal_id],
            turns = state.best_turns[reconstruction.goal_id],
            preference = state.best_preference[reconstruction.goal_id],
            score = state.best_score[reconstruction.goal_id],
          },
          nodes = {},
          edges = {},
        }
        reconstruction.phase = "nodes"
        reconstruction.index = #reconstruction.reversed_nodes
      end
    elseif reconstruction.phase == "nodes" then
      if reconstruction.index > 0 then
        reconstruction.route.nodes[#reconstruction.route.nodes + 1] =
          reconstruction.reversed_nodes[reconstruction.index]
        reconstruction.index = reconstruction.index - 1
        used = used + 1
      else
        reconstruction.phase = "edges"
        reconstruction.index = #reconstruction.reversed_edges
      end
    elseif reconstruction.index > 0 then
      reconstruction.route.edges[#reconstruction.route.edges + 1] = reconstruction.reversed_edges[reconstruction.index]
      reconstruction.index = reconstruction.index - 1
      used = used + 1
    else
      state.route = reconstruction.route
      state.reconstruction = nil
      state.status = "found"
      return used, true
    end
  end
  return used, false
end

local function route_less(a, b)
  if not b then
    return true
  end
  if a.cost.score ~= b.cost.score then
    return a.cost.score < b.cost.score
  end
  if a.cost.length ~= b.cost.length then
    return a.cost.length < b.cost.length
  end
  return a.cost.preference < b.cost.preference
end

local function candidate_key(runs)
  local parts = {}
  for index = 1, #runs do
    parts[#parts + 1] = runs[index].direction .. ":" .. runs[index].length
  end
  return table.concat(parts, ",")
end

local function add_candidate(fast, start, goal, runs)
  if #runs == 0 or (start.direction ~= nil and runs[1].direction ~= start.direction) then
    return
  end
  if goal.direction ~= nil and runs[#runs].direction ~= goal.direction then
    return
  end
  local key = candidate_key(runs)
  if fast.candidate_keys[key] then
    return
  end
  fast.candidate_keys[key] = true
  local length = 0
  for index = 1, #runs do
    length = length + runs[index].length
  end
  fast.candidates[#fast.candidates + 1] = {
    runs = runs,
    length = length,
    turns = #runs - 1,
  }
end

local function begin_fast_path(state)
  local fast = { candidates = {}, candidate_keys = {}, candidate_index = 1 }
  local start = state.fast_start
  if not start then
    return fast
  end
  local dx = state.goal.x - start.x
  local dy = state.goal.y - start.y
  if dx == 0 and dy == 0 then
    return fast
  end
  local horizontal = dx >= 0 and 4 or 12
  local vertical = dy >= 0 and 8 or 0
  local horizontal_length = math.abs(dx)
  local vertical_length = math.abs(dy)
  if horizontal_length == 0 then
    add_candidate(fast, start, state.goal, { { direction = vertical, length = vertical_length } })
  elseif vertical_length == 0 then
    add_candidate(fast, start, state.goal, { { direction = horizontal, length = horizontal_length } })
  else
    add_candidate(fast, start, state.goal, {
      { direction = horizontal, length = horizontal_length },
      { direction = vertical, length = vertical_length },
    })
    add_candidate(fast, start, state.goal, {
      { direction = vertical, length = vertical_length },
      { direction = horizontal, length = horizontal_length },
    })
    for _, outer in ipairs({
      {
        direction = horizontal,
        length = horizontal_length,
        inner_direction = vertical,
        inner_length = vertical_length,
      },
      {
        direction = vertical,
        length = vertical_length,
        inner_direction = horizontal,
        inner_length = horizontal_length,
      },
    }) do
      if outer.length >= 2 and start.direction == outer.direction and state.goal.direction == outer.direction then
        local splits = { math.floor(outer.length / 2), 1, outer.length - 1 }
        local seen = {}
        for index = 1, #splits do
          local split = splits[index]
          if split >= 1 and split < outer.length and not seen[split] then
            seen[split] = true
            add_candidate(fast, start, state.goal, {
              { direction = outer.direction, length = split },
              { direction = outer.inner_direction, length = outer.inner_length },
              { direction = outer.direction, length = outer.length - split },
            })
          end
        end
      end
    end
  end
  local minimum_turns = math.huge
  for index = 1, #fast.candidates do
    minimum_turns = math.min(minimum_turns, fast.candidates[index].turns)
  end
  fast.minimum_turns = minimum_turns
  return fast
end

local function candidate_position(state, candidate, index)
  local x, y = state.fast_start.x, state.fast_start.y
  local remaining = index - 1
  for run_index = 1, #candidate.runs do
    local run = candidate.runs[run_index]
    local distance = math.min(remaining, run.length)
    local direction_index = DIRECTION_INDEX[run.direction]
    x = x + DX[direction_index + 1] * distance
    y = y + DY[direction_index + 1] * distance
    remaining = remaining - distance
    if remaining == 0 then
      break
    end
  end
  return x, y
end

local function candidate_direction(candidate, edge_index)
  local remaining = edge_index
  for run_index = 1, #candidate.runs do
    local run = candidate.runs[run_index]
    if remaining <= run.length then
      return run.direction
    end
    remaining = remaining - run.length
  end
  return nil
end

local function fast_improve(search, to_index, locked, preference, from_index, from_locked, edge)
  search.best[to_index] = search.best[to_index] or {}
  local old = search.best[to_index][locked]
  if old == nil or preference < old then
    search.best[to_index][locked] = preference
    local key = to_index * 2 + (locked and 1 or 0)
    search.parent_index[key] = from_index
    search.parent_locked[key] = from_locked
    search.parent_edge[key] = edge
  end
end

local function begin_fast_candidate(candidate)
  return {
    candidate = candidate,
    count = candidate.length + 1,
    best = { [1] = { [false] = 0 } },
    parent_index = {},
    parent_locked = {},
    parent_edge = {},
    index = 1,
    locked_index = 1,
    phase = "select",
  }
end

local function advance_fast_state(search)
  search.locked_index = search.locked_index + 1
  if search.locked_index > 2 then
    search.locked_index = 1
    search.index = search.index + 1
  end
  search.phase = "select"
end

local function finish_fast_candidate(state, search)
  local final = search.best[search.count]
  local locked = false
  local preference = final and final[false] or nil
  if final and final[true] ~= nil and (preference == nil or final[true] < preference) then
    locked = true
    preference = final[true]
  end
  if preference == nil then
    return false
  end
  search.final_preference = preference
  search.trace_index = search.count
  search.trace_locked = locked
  search.reversed = {}
  search.phase = "trace"
  return true
end

local function step_fast_candidate(state, callbacks, search, budget)
  local used = 0
  while used < budget do
    if search.phase == "select" then
      used = used + 1
      if search.index >= search.count then
        if not finish_fast_candidate(state, search) then
          return used, "failed"
        end
      else
        search.locked = search.locked_index == 2
        search.current_preference = search.best[search.index] and search.best[search.index][search.locked]
        if search.current_preference == nil then
          advance_fast_state(search)
        else
          local from_x, from_y = candidate_position(state, search.candidate, search.index)
          local to_x, to_y = candidate_position(state, search.candidate, search.index + 1)
          local direction = candidate_direction(search.candidate, search.index)
          search.from_x = from_x
          search.from_y = from_y
          search.direction = direction
          search.ground = {
            kind = "ground",
            from_x = from_x,
            from_y = from_y,
            to_x = to_x,
            to_y = to_y,
            direction = direction,
            length = 1,
          }
          search.phase = "ground"
        end
      end
    elseif search.phase == "ground" then
      local allowed = can_place(state, callbacks, search.ground)
      if allowed == nil then
        return used, "waiting"
      end
      used = used + 1
      if allowed then
        fast_improve(
          search,
          search.index + 1,
          false,
          search.current_preference + preference_cost(state.mode, "ground", 1),
          search.index,
          search.locked,
          search.ground
        )
      end
      local previous_direction = search.index > 1 and candidate_direction(search.candidate, search.index - 1) or nil
      if
        search.index > 1
        and previous_direction == search.direction
        and not search.locked
        and state.mode ~= "surface-only"
        and callbacks.underground_edges
      then
        search.phase = "underground-fetch"
      else
        advance_fast_state(search)
      end
    elseif search.phase == "underground-fetch" then
      search.underground = underground_edges(state, callbacks, search.from_x, search.from_y, search.direction)
      search.underground_index = 1
      search.phase = "underground"
      used = used + 1
    elseif search.phase == "underground" then
      local edge = search.underground[search.underground_index]
      if not edge then
        advance_fast_state(search)
      else
        search.underground_index = search.underground_index + 1
        local destination_index = search.index + edge.length
        local destination_x, destination_y = candidate_position(state, search.candidate, destination_index)
        local has_straight_exit = destination_index == search.count
          or (
            destination_index < search.count
            and candidate_direction(search.candidate, destination_index) == search.direction
          )
        local matches = destination_index <= search.count
          and has_straight_exit
          and destination_x == edge.to_x
          and destination_y == edge.to_y
        local allowed = false
        if matches then
          allowed = can_place(state, callbacks, edge)
          if allowed == nil then
            search.underground_index = search.underground_index - 1
            return used, "waiting"
          end
        end
        used = used + 1
        if allowed then
          fast_improve(
            search,
            destination_index,
            true,
            search.current_preference + preference_cost(state.mode, "underground", edge.length),
            search.index,
            search.locked,
            edge
          )
        end
      end
    elseif search.phase == "trace" then
      if search.trace_index <= 1 then
        search.edges = {}
        search.nodes = {
          { x = state.fast_start.x, y = state.fast_start.y, direction = state.fast_start.direction },
        }
        search.reverse_index = #search.reversed
        search.phase = "reverse"
      else
        local key = search.trace_index * 2 + (search.trace_locked and 1 or 0)
        local parent_idx = search.parent_index[key]
        if not parent_idx then
          return used, "failed"
        end
        search.reversed[#search.reversed + 1] = search.parent_edge[key]
        search.trace_index = parent_idx
        search.trace_locked = search.parent_locked[key]
        used = used + 1
      end
    elseif search.phase == "reverse" then
      if search.reverse_index < 1 then
        return used,
          "found",
          {
            strategy = "fast-path",
            cost = {
              length = search.candidate.length,
              turns = search.candidate.turns,
              preference = search.final_preference,
              score = search.candidate.length + search.candidate.turns * TURN_PENALTY,
            },
            nodes = search.nodes,
            edges = search.edges,
          }
      end
      local edge = search.reversed[search.reverse_index]
      search.reverse_index = search.reverse_index - 1
      search.edges[#search.edges + 1] = edge
      search.nodes[#search.nodes + 1] = { x = edge.to_x, y = edge.to_y, direction = edge.direction }
      used = used + 1
    end
  end
  return used, "running"
end

local function step_fast_path(state, callbacks, budget)
  state.fast_path = state.fast_path or begin_fast_path(state)
  local fast = state.fast_path
  local used = 0
  while used < budget do
    local candidate = fast.candidates[fast.candidate_index]
    if not candidate then
      state.fast_path_attempted = true
      state.fast_path = nil
      return used, "completed", fast.best_route
    end
    if candidate.turns ~= fast.minimum_turns then
      fast.candidate_index = fast.candidate_index + 1
    else
      fast.search = fast.search or begin_fast_candidate(candidate)
      local spent, status, route = step_fast_candidate(state, callbacks, fast.search, budget - used)
      used = used + spent
      if status == "waiting" then
        return used, status
      end
      if status == "found" then
        if route_less(route, fast.best_route) then
          fast.best_route = route
        end
        if state.mode ~= "prefer-underground" and route.cost.preference == 0 then
          state.fast_path_attempted = true
          state.fast_path = nil
          return used, "completed", route
        end
        fast.search = nil
        fast.candidate_index = fast.candidate_index + 1
      elseif status == "failed" then
        fast.search = nil
        fast.candidate_index = fast.candidate_index + 1
      else
        return used, status
      end
    end
  end
  return used, "running"
end

function solver.new(spec)
  if type(spec) ~= "table" then
    error("solver spec must be a table", 2)
  end
  local normalized_bounds
  if spec.bounds then
    normalized_bounds = {
      min_x = integer(spec.bounds.min_x, "bounds.min_x"),
      max_x = integer(spec.bounds.max_x, "bounds.max_x"),
      min_y = integer(spec.bounds.min_y, "bounds.min_y"),
      max_y = integer(spec.bounds.max_y, "bounds.max_y"),
    }
    if normalized_bounds.min_x > normalized_bounds.max_x or normalized_bounds.min_y > normalized_bounds.max_y then
      error("bounds are empty", 2)
    end
  end

  local mode = spec.mode or "prefer-underground"
  if mode ~= "prefer-underground" and mode ~= "prefer-surface" and mode ~= "surface-only" then
    error("invalid routing mode", 2)
  end
  local goal = spec.goal or error("goal is required", 2)
  local goal_direction = goal.direction
  if goal_direction ~= nil and DIRECTION_INDEX[goal_direction] == nil then
    error("invalid goal direction", 2)
  end

  local state = {
    bounds = normalized_bounds,
    goal = {
      x = integer(goal.x, "goal.x"),
      y = integer(goal.y, "goal.y"),
      direction = goal_direction,
    },
    mode = mode,
    allow_reverse = spec.allow_reverse == true,
    max_total_expansions = spec.max_total_expansions or 100000,
    expansions = 0,
    heap_pops = 0,
    sequence = 0,
    status = "running",
    open_id = {},
    open_f_score = {},
    open_turns = {},
    open_length = {},
    open_preference = {},
    open_sequence = {},
    best_length = {},
    best_turns = {},
    best_preference = {},
    best_score = {},
    parent = {},
    parent_edge = {},
    placement_cache = {},
    underground_cache = {},
    coordinate_ids = {},
    coordinate_x = {},
    coordinate_y = {},
    fast_path_attempted = false,
  }
  integer(state.max_total_expansions, "max_total_expansions")
  if state.max_total_expansions < 1 then
    error("max_total_expansions must be positive", 2)
  end
  if not in_bounds(state, state.goal.x, state.goal.y) then
    error("goal is outside bounds", 2)
  end

  local starts = spec.starts or (spec.start and { spec.start }) or error("start or starts is required", 2)
  if #starts == 0 then
    error("starts must not be empty", 2)
  end
  for index = 1, #starts do
    local start = starts[index]
    local x = integer(start.x, "start.x")
    local y = integer(start.y, "start.y")
    if not in_bounds(state, x, y) then
      error("start is outside bounds", 2)
    end
    local direction_index = 12
    if start.direction ~= nil then
      local fixed_direction = DIRECTION_INDEX[start.direction]
      if fixed_direction == nil then
        error("invalid start direction", 2)
      end
      direction_index = fixed_direction + 4
    end
    local id = state_id(state, x, y, direction_index)
    if state.best_length[id] == nil then
      state.best_length[id] = 0
      state.best_turns[id] = 0
      state.best_preference[id] = 0
      state.best_score[id] = 0
      state.sequence = state.sequence + 1
      local f_score = (length_heuristic(state, x, y) + turn_heuristic(state, x, y, direction_index) * TURN_PENALTY)
        * HEURISTIC_SCALE
      heap_push(state, id, 0, f_score, 0, 0, state.sequence)
    end
    if #starts == 1 then
      state.fast_start = { x = x, y = y, direction = start.direction }
    end
  end
  return state
end

function solver.step(state, callbacks, budget)
  if state.status ~= "running" then
    return state.status, state.route
  end
  if type(callbacks) ~= "table" or type(callbacks.can_place) ~= "function" then
    error("callbacks.can_place is required", 2)
  end
  if state.mode ~= "surface-only" and type(callbacks.underground_edges) ~= "function" then
    error("callbacks.underground_edges is required", 2)
  end
  budget = budget or 256
  integer(budget, "budget")
  if budget < 1 then
    error("budget must be positive", 2)
  end

  if state.reconstruction then
    reconstruct(state, budget)
    return state.status, state.route
  end

  local work = 0
  if not state.fast_path_attempted then
    local fast_work, fast_status, fast_route = step_fast_path(state, callbacks, budget)
    work = work + fast_work
    if fast_status == "waiting" then
      return "waiting"
    end
    if fast_status == "completed" and fast_route then
      state.route = fast_route
      state.status = "found"
      return state.status, state.route
    end
    if work >= budget then
      return "running"
    end
  end

  while work < budget do
    local item_id, item_length, item_f_score, item_turns, item_preference, item_sequence = heap_pop(state)
    if not item_id then
      state.status = state.expansions >= state.max_total_expansions and "limit" or "unreachable"
      return state.status
    end
    work = work + 1
    state.heap_pops = (state.heap_pops or 0) + 1

    if
      item_length == state.best_length[item_id]
      and item_turns == state.best_turns[item_id]
      and item_preference == state.best_preference[item_id]
      and item_length + item_turns * TURN_PENALTY == state.best_score[item_id]
    then
      local x, y, direction_slot = decode_state(state, item_id)
      local direction_index = logical_direction(direction_slot)
      if
        x == state.goal.x
        and y == state.goal.y
        and (
          state.goal.direction == nil
          or (direction_index ~= nil and state.goal.direction == DIRECTIONS[direction_index + 1])
        )
      then
        begin_reconstruction(state, item_id)
        if work < budget then
          local _, done = reconstruct(state, budget - work)
          if done then
            return state.status, state.route
          end
        end
        return "running"
      end

      if callbacks.prepare and callbacks.prepare(x, y) ~= true then
        heap_push(state, item_id, item_length, item_f_score, item_turns, item_preference, item_sequence)
        return "waiting"
      end

      if state.expansions >= state.max_total_expansions then
        state.status = "limit"
        return state.status
      end
      state.expansions = state.expansions + 1
      for move_index = 1, 4 do
        local to_x = x + DX[move_index]
        local to_y = y + DY[move_index]
        local fixed_start = direction_slot >= 4 and direction_slot < 8
        local locked_underground_exit = direction_slot >= 8 and direction_slot < 12
        local reverse = direction_index ~= nil and (move_index - 1) == ((direction_index + 2) % 4)
        local transition_allowed = (not fixed_start or move_index - 1 == direction_index)
          and (not locked_underground_exit or move_index - 1 == direction_index)
          and (state.allow_reverse or not reverse)
        if transition_allowed and in_bounds(state, to_x, to_y) then
          local edge = {
            kind = "ground",
            from_x = x,
            from_y = y,
            to_x = to_x,
            to_y = to_y,
            direction = DIRECTIONS[move_index],
            length = 1,
          }
          if can_place(state, callbacks, edge) then
            relax(state, item_id, direction_slot, edge)
          end
        end
      end

      if state.mode ~= "surface-only" and direction_slot < 4 then
        local first_move = direction_index == nil and 1 or direction_index + 1
        local last_move = direction_index == nil and 4 or direction_index + 1
        for move_index = first_move, last_move do
          local reverse = direction_index ~= nil and (move_index - 1) == ((direction_index + 2) % 4)
          local edges = underground_edges(state, callbacks, x, y, DIRECTIONS[move_index])
          if state.allow_reverse or not reverse then
            for edge_index = 1, #edges do
              local edge = edges[edge_index]
              if can_place(state, callbacks, edge) then
                relax(state, item_id, direction_slot, edge)
              end
            end
          end
        end
      end
    end
  end
  return "running"
end

function solver.run(state, callbacks, budget)
  while state.status == "running" do
    local status, route = solver.step(state, callbacks, budget)
    if status == "waiting" then
      return status, route
    end
  end
  return state.status, state.route
end

return solver
