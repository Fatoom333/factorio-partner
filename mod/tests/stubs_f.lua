-- Заглушки потока F («Стройка»). Дополняют stubs.lua (A) и stubs_c.lua (C), TESTING.md §1.
--
--   local S = require("stubs"); local F = require("stubs_f")
--   local W = F.setup{ items = { ["iron-chest"] = 3 } }  -- мод, хозяин, помощник h1 (как C.setup)
--   F.ghost("iron-chest", { x = 5.5, y = 0.5 })          -- призрак своей силы с revive
--   local d, kind = F.wait(F.job("build_ghosts", { radius = 20, mode = "hand" }))
--
-- Что даёт сверх stubs_c:
-- * подмену scripts.core.vis / scripts.core.target (ядро, поток A): F.vis.result, счётчики вызовов;
-- * плитки: прототипы плиток и их предметов, F.tile_ghost(имя, клетка), F.set_tile, F.tile_at,
--   F.tile_revive_fails; вода — помеха постройке (ghost_revive = false, пока не положена плитка);
-- * снос: F.mark(e) помечает сущность (to_be_deconstructed), find_entities_filtered понимает
--   фильтр to_be_deconstructed; стоящая сущность мешает постройке на своём месте;
-- * режимы постановки чертежа в «движке»: normal — помеха → призрака нет; forced — деревья и камни
--   помечаются, под постройкой на воде встаёт призрак плитки-подложки (если рецепт её предмета
--   открыт силе); superforced — помечаются ещё и постройки своей силы;
-- * F.reach_only_openable = true — камни и деревья тело достаёт только с resource_reach_distance
--   (как в игре: с 5–9 клеток can_reach_entity = false и добыча не идёт); «движок» добычи
--   в F.run для камней и деревьев тоже требует эту дистанцию;
-- * прототипы построек: place_result, items_to_place_this, collision_box, размеры в клетках;
-- * проверки постановки: F.blocked["x,y"] = true (нельзя ничего) │ { ghost_revive = true, ... };
--   тело персонажа мешает постройке на своём месте (F.body_blocks); журнал проверок F.checks;
-- * призраки с revive{raise_revive} (F.revive_nil, F.collided, F.proxy — третий результат revive),
--   remove_item у тела (F.remove_fails), призрак от скрипта create_entity{entity-ghost, inner_name}
--   (F.ghost_restored); F.bp_return_existing — build_blueprint возвращает уже стоявший призрак;
-- * личные дроны: F.give_robots(h, n, radius) + «движок» в F.run (F.flight_ticks, F.robots_stalled);
-- * чертежи: F.blueprints[строка] = {entities, tiles?, kind?, rc?}, фейковый game.create_inventory
--   со стаком (import_stack, build_blueprint, ...), журнал F.bp_calls, F.bp_created/F.bp_destroyed.
local S = require("stubs")
local C = require("stubs_c")

local F = {}

-- ===================================================================== vis / target (ядро)

F.vis = { calls = 0, result = true }
F.target = { calls = 0 }

package.preload["scripts.core.vis"] = function()
  return {
    visible = function(helper_id, surface, pos)
      F.vis.calls = F.vis.calls + 1
      F.vis.last = { helper = helper_id, surface = surface and surface.name, pos = S.norm_pos(pos) }
      if type(F.vis.result) == "function" then return F.vis.result(helper_id, surface, pos) end
      return F.vis.result
    end,
  }
end

package.preload["scripts.core.target"] = function()
  return {
    -- как scripts.core.target: → сущность │ nil, "not_found" │ "foreign"
    resolve = function(surface, t, force)
      F.target.calls = F.target.calls + 1
      local best, bd
      for _, e in ipairs(surface._entities) do
        if e.valid then
          if t.unit_number ~= nil then
            if e.unit_number == t.unit_number then best = e break end
          elseif e.name == t.name then
            local d = S.dist(e.position, t.pos)
            if d <= 2 and (bd == nil or d < bd) then best, bd = e, d end
          end
        end
      end
      if best == nil then return nil, "not_found" end
      local mine = force and (type(force) == "string" and force or force.name) or "player"
      local f = best.force and best.force.name
      if f ~= mine and f ~= "neutral" then return nil, "foreign" end
      return best
    end,
  }
end

-- ===================================================================== прототипы

local function buildable(name, etype, w, h, extra)
  local E, I = prototypes.entity, prototypes.item
  local p = E[name] or { name = name, type = etype }
  E[name] = p
  p.type = etype
  p.items_to_place_this = { { name = name, count = 1 } }
  p.collision_box = {
    left_top = { x = -w / 2 + 0.1, y = -h / 2 + 0.1 }, right_bottom = { x = w / 2 - 0.1, y = h / 2 - 0.1 },
  }
  p.tile_width, p.tile_height = w, h
  p.collision_mask = { layers = { object = true, water_tile = true, is_object = true } }
  p.mineable_properties = p.mineable_properties
      or { minable = true, mining_time = 0.2, products = { { type = "item", name = name, amount = 1 } } }
  for k, v in pairs(extra or {}) do p[k] = v end
  I[name] = I[name] or { name = name, type = "item", stack_size = 50 }
  I[name].place_result = p
  return p
end

function F.prototypes()
  buildable("iron-chest", "container", 1, 1)
  buildable("wooden-chest", "container", 1, 1)
  buildable("transport-belt", "transport-belt", 1, 1)
  buildable("stone-furnace", "furnace", 2, 2)
  buildable("assembling-machine-1", "assembling-machine", 3, 3, { crafting_categories = { crafting = true } })
  buildable("electric-mining-drill", "mining-drill", 3, 3)
  -- постройка без предмета (её нельзя поставить из инвентаря)
  prototypes.entity["infinity-chest"].items_to_place_this = nil
  -- некопаемая постройка
  prototypes.entity["bedrock"] = { name = "bedrock", type = "simple-entity-with-owner",
    mineable_properties = { minable = false } }
  -- предмет с данными
  prototypes.item["car"].place_result = prototypes.entity["car"]
  prototypes.entity["car"].items_to_place_this = { { name = "car", count = 1 } }
  -- камень (neutral, копается руками)
  prototypes.entity["big-rock"] = { name = "big-rock", type = "simple-entity",
    count_as_rock_for_filtered_deconstruction = true,
    mineable_properties = { minable = true, mining_time = 0.5, products = { { type = "item", name = "stone", amount = 3 } } } }
  prototypes.item["stone"] = prototypes.item["stone"] or { name = "stone", type = "item", stack_size = 50 }
  -- плитки: земля, вода (подложка — отсыпка), каменная дорожка, отсыпка
  local T, I = prototypes.tile, prototypes.item
  local function tile_item(item, tile, condition)
    I[item] = I[item] or { name = item, type = "item", stack_size = 100 }
    I[item].place_as_tile_result = { result = T[tile], condition_size = 1, condition = { layers = condition } }
    T[tile].items_to_place_this = { { name = item, count = 1 } }
  end
  T["grass-1"] = { name = "grass-1", collision_mask = { layers = { ground_tile = true } } }
  T["stone-path"] = { name = "stone-path", collision_mask = { layers = { ground_tile = true } } }
  T["landfill"] = { name = "landfill", collision_mask = { layers = { ground_tile = true } } }
  -- жидкости: по ним не ходят (слой player, как у тела) и на них не строят (слой water_tile)
  T["water"] = { name = "water", collision_mask = { layers = { water_tile = true, player = true } }, default_cover_tile = T["landfill"] }
  T["lava"] = { name = "lava", collision_mask = { layers = { water_tile = true, lava_tile = true, player = true } } }
  prototypes.entity["character"].collision_mask = { layers = { player = true } }
  tile_item("stone-brick", "stone-path", { water_tile = true })
  tile_item("landfill", "landfill", { ground_tile = true })
  -- отсыпка кладётся только на воду (на лаву — нет), как в игре
  I["landfill"].place_as_tile_result.tile_condition = { "water" }
end

-- ===================================================================== плитки и пометки к сносу

function F.set_tile(x, y, name)
  S.nauvis.tiles = S.nauvis.tiles or {}
  S.nauvis.tiles[math.floor(x) .. "," .. math.floor(y)] = name
end

function F.tile_at(x, y)
  return S.nauvis.get_tile(x, y).name
end

local function liquid_at(pos, name)
  local proto = prototypes.entity[name] or {}
  local hx, hy = (proto.tile_width or 1) / 2, (proto.tile_height or 1) / 2
  for cx = math.floor(pos.x - hx + 0.05), math.floor(pos.x + hx - 0.05) do
    for cy = math.floor(pos.y - hy + 0.05), math.floor(pos.y + hy - 0.05) do
      local t = prototypes.tile[F.tile_at(cx, cy)]
      if t and t.collision_mask.layers.water_tile then return true, cx, cy, t end
    end
  end
  return false
end

--- Пометить сущность к сносу (как планировщик сноса игрока или постановка с Shift).
function F.mark(e)
  rawset(e, "_marked", true)
  rawset(e, "to_be_deconstructed", function() return rawget(e, "_marked") == true end)
  rawset(e, "cancel_deconstruction", function(force)
    if force == nil then error("cancel_deconstruction: force is required", 2) end
    rawset(e, "_marked", false)
    F.unmarked[#F.unmarked + 1] = { name = e.name, force = force.name or force }
  end)
  return e
end

local SOFT = { ["entity-ghost"] = true, ["tile-ghost"] = true, character = true, resource = true,
  ["item-entity"] = true, ["character-corpse"] = true }

--- Настоящие сущности, стоящие на месте постройки name в точке pos (кроме ignore).
local function solid_at(pos, name, dir, ignore)
  local proto = prototypes.entity[name] or {}
  local hx, hy = (proto.tile_width or 1) / 2, (proto.tile_height or 1) / 2
  if dir == 4 or dir == 12 then hx, hy = hy, hx end
  local out = {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and e ~= ignore and not SOFT[e.type]
        and math.abs(e.position.x - pos.x) < hx + 0.3 and math.abs(e.position.y - pos.y) < hy + 0.3 then
      out[#out + 1] = e
    end
  end
  return out
end
F.solid_at = solid_at

-- ===================================================================== проверки постановки

function F.key(pos)
  local p = S.norm_pos(pos)
  return string.format("%g,%g", p.x, p.y)
end

local CHECK_NAMES = {}

local function check_name(id)
  if next(CHECK_NAMES) == nil then
    for k, v in pairs(defines.build_check_type) do CHECK_NAMES[v] = k end
  end
  return CHECK_NAMES[id] or tostring(id)
end

local function body_at(pos, name, dir)
  if not F.body_blocks then return false end
  local proto = prototypes.entity[name] or {}
  local hx, hy = (proto.tile_width or 1) / 2, (proto.tile_height or 1) / 2
  if dir == 4 or dir == 12 then hx, hy = hy, hx end
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and e.type == "character"
        and math.abs(e.position.x - pos.x) < hx + 0.2 and math.abs(e.position.y - pos.y) < hy + 0.2 then
      return true
    end
  end
  return false
end

local function allowed(kind, params)
  local pos = S.norm_pos(params.position)
  F.checks[#F.checks + 1] = { kind = kind, name = params.name, pos = pos, direction = params.direction, force = params.force }
  local b = F.blocked[F.key(pos)]
  if b == true or (type(b) == "table" and b[kind]) then return false end
  if kind ~= "manual_ghost" and kind ~= "blueprint_ghost" and body_at(pos, params.name, params.direction) then
    return false
  end
  if F.physics then
    -- стоящая сущность и вода мешают постройке; призраку с forced не мешает то, что можно снести
    local solid = solid_at(pos, params.name, params.direction)
    if kind == "manual_ghost" and params.forced then
      for _, e in ipairs(solid) do
        local f = e.force and e.force.name
        if f ~= "neutral" and f ~= (params.force and (params.force.name or params.force)) then return false end
      end
    elseif #solid > 0 then
      return false
    end
    if liquid_at(pos, params.name) then return false end
  end
  return true
end

-- ===================================================================== призраки

function F.revive(g, p)
  F.revive_calls = F.revive_calls + 1
  if F.revive_nil then return nil end
  local surf, pos, name, dir, force = g.surface, S.norm_pos(g.position), g.ghost_name, g.direction, g.force
  g.destroy()
  local e = surf.create_entity{ name = name, position = pos, direction = dir, force = force }
  if p and p.raise_revive then
    F.raised_revive = F.raised_revive + 1
    S.fire(defines.events.script_raised_revive, { entity = e })
  end
  F.revived[#F.revived + 1] = e
  F.revive_log[#F.revive_log + 1] = { name = name, tick = game.tick }
  return F.collided or {}, e, F.proxy
end

--- Призрак плитки name в клетке (x, y — любая точка клетки). revive кладёт плитку на поверхность.
function F.tile_ghost(name, pos, opts)
  opts = opts or {}
  local p = S.norm_pos(pos)
  local cx, cy = math.floor(p.x), math.floor(p.y)
  local g = S.nauvis.create_entity{
    name = "tile-ghost", type = "tile-ghost", position = { x = cx + 0.5, y = cy + 0.5 },
    force = opts.force or "player",
    fields = { ghost_name = name, ghost_prototype = prototypes.tile[name] },
  }
  rawset(g, "type", "tile-ghost")
  if opts.quality then g.quality = { name = opts.quality } end
  rawset(g, "revive", function(rp)
    F.tile_revive_calls = F.tile_revive_calls + 1
    if F.tile_revive_fails then return nil end
    g.destroy()
    F.set_tile(cx, cy, name)
    F.tile_log[#F.tile_log + 1] = { name = name, x = cx, y = cy, tick = game.tick }
    if rp and rp.raise_revive then F.raised_revive = F.raised_revive + 1 end
    return F.collided or {}, nil, nil
  end)
  return g
end

function F.tile_ghosts_left()
  local out = {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and e.type == "tile-ghost" then out[#out + 1] = e end
  end
  return out
end

--- Призрак постройки name: F.ghost("iron-chest", {x=, y=}, {force=, direction=, quality=}).
function F.ghost(name, pos, opts)
  opts = opts or {}
  local g = (opts.surface or S.nauvis).create_entity{
    name = "entity-ghost", position = pos, force = opts.force or "player", direction = opts.direction or 0,
    fields = { ghost_name = name, ghost_prototype = prototypes.entity[name] },
  }
  if opts.quality then g.quality = { name = opts.quality } end
  rawset(g, "revive", function(p) return F.revive(g, p) end)
  return g
end

function F.ghosts()
  local out = {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and e.type == "entity-ghost" then out[#out + 1] = e end
  end
  return out
end

--- Настоящие (не призраки) сущности name; pos — только в этой точке.
function F.built(name, pos)
  local out = {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and e.name == name and (pos == nil or S.dist(e.position, pos) < 0.01) then out[#out + 1] = e end
  end
  return out
end

-- ===================================================================== личные дроны

function F.give_robots(h, n, radius)
  local net = { valid = true, all_construction_robots = n, available_construction_robots = n }
  h.logistic_cell = { valid = true, mobile = true, construction_radius = radius or 10, logistic_network = net }
  h.allow_dispatching_robots = true
  F.net = net
  return net
end

local function robots_engine(h)
  local cell = rawget(h, "logistic_cell")
  if cell == nil then return end
  local net = cell.logistic_network
  local main = h.inventories[defines.inventory.character_main]
  for i = #F.flights, 1, -1 do
    local fl = F.flights[i]
    fl.t = fl.t - 1
    if fl.t <= 0 then
      table.remove(F.flights, i)
      net.available_construction_robots = net.available_construction_robots + 1
      if fl.g.valid and fl.g.type == "tile-ghost" then
        local pos, name = S.norm_pos(fl.g.position), fl.g.ghost_name
        fl.g.destroy()
        F.set_tile(pos.x, pos.y, name)
        F.robot_built = F.robot_built + 1
      elseif fl.g.valid then
        local surf, pos, name, dir, force = fl.g.surface, S.norm_pos(fl.g.position), fl.g.ghost_name, fl.g.direction, fl.g.force
        fl.g.destroy()
        surf.create_entity{ name = name, position = pos, direction = dir, force = force }
        F.robot_built = F.robot_built + 1
      else
        main.insert{ name = fl.item, count = 1 }
      end
    end
  end
  if F.robots_stalled or h.allow_dispatching_robots == false then return end
  if net.available_construction_robots <= 0 then return end
  local r = cell.construction_radius
  for _, g in ipairs(S.nauvis._entities) do
    local tile = g.valid and g.type == "tile-ghost"
    if g.valid and (g.type == "entity-ghost" or tile) and not rawget(g, "_claimed") and g.force == h.force
        and math.abs(g.position.x - h.position.x) <= r and math.abs(g.position.y - h.position.y) <= r
        and (tile or (F.blocked[F.key(g.position)] == nil and not body_at(g.position, g.ghost_name, g.direction)
          and #F.solid_at(g.position, g.ghost_name, g.direction) == 0 and not liquid_at(g.position, g.ghost_name))) then
      local item = (g.ghost_prototype.items_to_place_this or {})[1]
      if item and main.get_item_count(item.name) >= 1 then
        main.remove{ name = item.name, count = 1 }
        rawset(g, "_claimed", true)
        net.available_construction_robots = net.available_construction_robots - 1
        F.flights[#F.flights + 1] = { g = g, t = F.flight_ticks, item = item.name }
        return
      end
    end
  end
end

-- ===================================================================== чертежи

local function bp_rot(dx, dy, dir)
  if dir == 4 then return -dy, dx end
  if dir == 8 then return -dx, -dy end
  if dir == 12 then return dy, -dx end
  return dx, dy
end

-- проверка «движка» для призрака чертежа: только ручные запреты F.blocked (помехи он решает сам)
local function allowed_bp(params)
  local pos = S.norm_pos(params.position)
  F.checks[#F.checks + 1] = { kind = "blueprint_ghost", name = params.name, pos = pos, direction = params.direction, force = params.force }
  local b = F.blocked[F.key(pos)]
  return not (b == true or (type(b) == "table" and b.blueprint_ghost))
end

-- «Движок»: центр рамки чертежа ставится в position, первая сущность привязывается к сетке.
local function engine_build(bp, p)
  F.bp_calls[#F.bp_calls + 1] = p
  local x0, y0, x1, y1
  for _, be in ipairs(bp.entities) do
    local proto = prototypes.entity[be.name] or {}
    local w, h = (proto.tile_width or 1) / 2, (proto.tile_height or 1) / 2
    x0 = math.min(x0 or be.position.x - w, be.position.x - w)
    y0 = math.min(y0 or be.position.y - h, be.position.y - h)
    x1 = math.max(x1 or be.position.x + w, be.position.x + w)
    y1 = math.max(y1 or be.position.y + h, be.position.y + h)
  end
  for _, bt in ipairs(bp.tiles or {}) do
    x0 = math.min(x0 or bt.position.x, bt.position.x)
    y0 = math.min(y0 or bt.position.y, bt.position.y)
    x1 = math.max(x1 or bt.position.x + 1, bt.position.x + 1)
    y1 = math.max(y1 or bt.position.y + 1, bt.position.y + 1)
  end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local pos = S.norm_pos(p.position)
  local shift = F.bp_shift or { x = 0, y = 0 }
  local out = {}
  local mode = p.build_mode or defines.build_mode.normal
  local bp_cells = {}
  -- плитки чертежа: призрак плитки, если её можно положить и там ещё не такая
  for _, bt in ipairs(bp.tiles or {}) do
    local dx, dy = bp_rot(bt.position.x + 0.5 - cx, bt.position.y + 0.5 - cy, p.direction or 0)
    local tx, ty = math.floor(pos.x + dx + shift.x), math.floor(pos.y + dy + shift.y)
    local item = prototypes.tile[bt.name].items_to_place_this[1].name
    local cond = prototypes.item[item].place_as_tile_result.condition.layers
    local now = prototypes.tile[F.tile_at(tx, ty)]
    local fits = now.name ~= bt.name
    for layer in pairs(cond) do
      if now.collision_mask.layers[layer] then fits = false end
    end
    local only = prototypes.item[item].place_as_tile_result.tile_condition
    if only then
      local allowed = false
      for _, n in ipairs(only) do
        if n == now.name then allowed = true end
      end
      fits = fits and allowed
    end
    if fits then
      out[#out + 1] = F.tile_ghost(bt.name, { x = tx, y = ty }, { force = p.force })
      F.tile_ghosts = F.tile_ghosts + 1
      bp_cells[tx .. "," .. ty] = true
    end
  end
  for _, be in ipairs(bp.entities) do
    local proto = prototypes.entity[be.name] or {}
    local dx, dy = bp_rot(be.position.x - cx, be.position.y - cy, p.direction or 0)
    local wx, wy = pos.x + dx, pos.y + dy
    local w = proto.tile_width or 1
    if w % 2 == 1 then
      wx, wy = math.floor(wx) + 0.5, math.floor(wy) + 0.5
    else
      wx, wy = math.floor(wx + 0.5), math.floor(wy + 0.5)
    end
    wx, wy = wx + shift.x, wy + shift.y
    local dir = ((be.direction or 0) + (p.direction or 0)) % 16
    local same
    if F.bp_return_existing then
      -- наложение на уже стоящий одинаковый призрак: «движок» возвращает его самого
      for _, g in ipairs(S.nauvis._entities) do
        if g.valid and g.type == "entity-ghost" and g.ghost_name == be.name
            and S.dist(g.position, { x = wx, y = wy }) < 0.01 then same = g break end
      end
    end
    local ok = true
    local to_mark, cover = {}, nil
    if F.physics and same == nil then
      -- помехи на месте: normal — призрака нет; forced — природное помечается; superforced — и своё
      for _, e in ipairs(solid_at({ x = wx, y = wy }, be.name, dir)) do
        local f = e.force and e.force.name
        if mode == defines.build_mode.normal then
          ok = false
        elseif f == "neutral" or (mode == defines.build_mode.superforced and f == p.force.name) then
          to_mark[#to_mark + 1] = e
        else
          ok = false
        end
      end
      local wet, lx, ly, lt = liquid_at({ x = wx, y = wy }, be.name)
      if wet and not bp_cells[lx .. "," .. ly] then
        local cover_item = lt.default_cover_tile and lt.default_cover_tile.items_to_place_this[1].name
        local known = cover_item and p.force.recipes[cover_item] and p.force.recipes[cover_item].enabled
        if mode == defines.build_mode.normal or not known then
          ok = false
        else
          cover = { name = lt.default_cover_tile.name, x = lx, y = ly }
        end
      end
    end
    if same ~= nil then
      out[#out + 1] = same
    elseif ok and allowed_bp({ name = be.name, position = { x = wx, y = wy }, direction = dir, force = p.force }) then
      for _, e in ipairs(to_mark) do F.mark(e) end
      if cover then
        out[#out + 1] = F.tile_ghost(cover.name, cover, { force = p.force })
        F.tile_ghosts = F.tile_ghosts + 1
      end
      out[#out + 1] = F.ghost(be.name, { x = wx, y = wy }, { direction = dir, quality = be.quality, force = p.force, surface = p.surface })
    end
  end
  return out
end

local function fake_script_inventory(size)
  F.bp_created = F.bp_created + 1
  local st = { valid = true, valid_for_read = false, is_blueprint = false }
  local bp
  function st.import_stack(str)
    F.imported[#F.imported + 1] = str
    local src = F.blueprints[str]
    if src == nil then return 1 end
    bp = S.copy(src)
    bp.entities = bp.entities or {}
    st.valid_for_read = true
    st.is_blueprint = (bp.kind or "blueprint") == "blueprint"
    return bp.rc or 0
  end
  function st.is_blueprint_setup() return #bp.entities > 0 or #(bp.tiles or {}) > 0 end
  function st.get_blueprint_entity_count() return bp.count or #bp.entities end
  function st.get_blueprint_entities()
    if #bp.entities == 0 then return nil end
    return S.copy(bp.entities)
  end
  function st.get_blueprint_tiles() return bp.tiles end
  function st.set_blueprint_tiles(t) bp.tiles = t end
  function st.set_blueprint_entities(t)
    bp.entities = t
    F.bp_set_entities = F.bp_set_entities + 1
  end
  function st.build_blueprint(p) return engine_build(bp, p) end
  local binv = { valid = true, [1] = st }
  function binv.destroy()
    binv.valid = false
    F.bp_destroyed = F.bp_destroyed + 1
  end
  return binv
end

--- Положить строку чертежа в blob (частями по n байт).
function F.blob(id, str, part_size)
  part_size = part_size or #str
  local parts = {}
  for i = 1, #str, part_size do parts[#parts + 1] = str:sub(i, i + part_size - 1) end
  for i, data in ipairs(parts) do
    S.okr(S.req("blob_put", { blob = id, part = i, total = #parts, data = data }))
  end
end

-- ===================================================================== мир

--- Мод + хозяин + помощник h1 (C.setup) + мир стройки. opts — как у C.setup.
function F.setup(opts)
  F.vis.calls, F.vis.result, F.vis.last = 0, true, nil
  F.target.calls = 0
  F.blocked, F.checks, F.revived = {}, {}, {}
  F.revive_calls, F.raised_revive, F.revive_nil, F.collided = 0, 0, false, nil
  F.remove_fails, F.create_nil, F.body_blocks = false, false, true
  F.flights, F.flight_ticks, F.robots_stalled, F.robot_built, F.net = {}, 30, false, 0, nil
  F.blueprints, F.bp_calls, F.imported = {}, {}, {}
  F.bp_created, F.bp_destroyed, F.tile_ghosts, F.bp_shift = 0, 0, 0, nil
  F.proxy, F.bp_return_existing, F.ghost_restored = nil, false, 0
  F.unmarked, F.bp_set_entities = {}, 0
  F.physics = true
  -- как в игре (живой замер 2026-10-13): камни и деревья достаются только с resource_reach_distance
  F.reach_only_openable = false
  F.tile_revive_calls, F.tile_revive_fails, F.tile_log, F.revive_log = 0, false, {}, {}
  CHECK_NAMES = {}

  -- предметы кладутся после F.prototypes(): среди них бывают предметы плиток, которых в C нет
  local base = {}
  for k, v in pairs(opts or {}) do base[k] = v end
  base.items = nil
  local W = C.setup(base)
  F.prototypes()
  for name, n in pairs(opts and opts.items or {}) do W.main.insert{ name = name, count = n } end
  F.W = W
  S.nauvis.can_place = function(_, params)
    return allowed(check_name(params.build_check_type), params)
  end
  S.character_can_place = function(h, params)
    if S.dist(h.position, S.norm_pos(params.position)) > h.build_distance then
      F.checks[#F.checks + 1] = { kind = "manual", name = params.name, pos = S.norm_pos(params.position), far = true }
      return false
    end
    return allowed("manual", params)
  end
  S.nauvis.tiles = {}
  -- фильтр to_be_deconstructed (в общей заглушке его нет)
  local find = S.nauvis.find_entities_filtered
  rawset(S.nauvis, "find_entities_filtered", function(f)
    local list = find(f)
    if f == nil or f.to_be_deconstructed == nil then return list end
    local out = {}
    for _, e in ipairs(list) do
      if (rawget(e, "_marked") == true) == f.to_be_deconstructed then out[#out + 1] = e end
    end
    return out
  end)
  local create = S.nauvis.create_entity
  rawset(S.nauvis, "create_entity", function(params)
    if params.name == "entity-ghost" and params.inner_name ~= nil then
      -- призрак, поставленный скриптом (откат постройки руками)
      F.ghost_restored = F.ghost_restored + 1
      return F.ghost(params.inner_name, params.position, {
        direction = params.direction, force = params.force and (params.force.name or params.force),
      })
    end
    if F.create_nil and params.raise_built then return nil end
    local e = create(params)
    if e.type == "assembling-machine" then
      rawset(e, "set_recipe", function(recipe, quality) e.recipe_set = { recipe = recipe, quality = quality } end)
    end
    return e
  end)
  -- рецепт отсыпки открыт (от него зависит, ставит ли «движок» подложку на воде)
  game.forces.player.recipes["landfill"] = { name = "landfill", enabled = true, category = "crafting" }
  local can_reach = W.h.can_reach_entity
  rawset(W.h, "can_reach_entity", function(e)
    if F.reach_only_openable and e.type ~= "container" and e.type ~= "assembling-machine" and e.type ~= "furnace" then
      return S.dist(W.h.position, e.position) <= W.h.resource_reach_distance
    end
    return can_reach(e)
  end)
  rawset(W.h, "remove_item", function(st)
    if F.remove_fails then return 0 end
    return W.main.remove(st)
  end)
  game.create_inventory = fake_script_inventory
  return W
end

--- Прокрутить n тиков: дроны, «движок» stubs_c (добыча, крафт), S.tick.
function F.run(n)
  for _ = 1, n or 1 do
    if F.W and F.W.h.valid then robots_engine(F.W.h) end
    -- как в игре: камень и дерево добываются только с resource_reach_distance
    local h = F.W and F.W.h
    local sel = h and h.valid and h.selected
    local too_far = F.reach_only_openable and sel and sel.valid
      and (sel.type == "tree" or sel.type == "simple-entity")
      and S.dist(h.position, sel.position) > h.resource_reach_distance
    if too_far then
      local was = C.mining_disabled
      C.mining_disabled = true
      C.run(1)
      C.mining_disabled = was
    else
      C.run(1)
    end
  end
end

--- Поставить задачу помощнику h1 → номер задачи.
function F.job(d, args, extra)
  return S.okr(C.act(d, args, extra)).job
end

--- Ждать итога задачи до n тиков; → data, kind.
function F.wait(job, n)
  for _ = 1, n or 8000 do
    F.run(1)
    local d, k = C.result(job)
    if d then return d, k end
  end
  error("задача " .. tostring(job) .. " не завершилась", 2)
end

--- Создания настоящих сущностей через create_entity с raise_built (журнал поверхности).
function F.script_built(name)
  local out = {}
  for _, p in ipairs(S.nauvis.created or {}) do
    if p.raise_built and (name == nil or p.name == name) then out[#out + 1] = p end
  end
  return out
end

return F
