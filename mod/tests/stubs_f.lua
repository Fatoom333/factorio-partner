-- Заглушки потока F («Стройка»). Дополняют stubs.lua (A) и stubs_c.lua (C), TESTING.md §1.
--
--   local S = require("stubs"); local F = require("stubs_f")
--   local W = F.setup{ items = { ["iron-chest"] = 3 } }  -- мод, хозяин, помощник h1 (как C.setup)
--   F.ghost("iron-chest", { x = 5.5, y = 0.5 })          -- призрак своей силы с revive
--   local d, kind = F.wait(F.job("build_ghosts", { radius = 20, mode = "hand" }))
--
-- Что даёт сверх stubs_c:
-- * подмену scripts.core.vis / scripts.core.target (их пишет поток X): F.vis.result, счётчики вызовов;
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

-- ===================================================================== vis / target (поток X)

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
    resolve = function(surface, t)
      F.target.calls = F.target.calls + 1
      local best, bd
      for _, e in ipairs(surface._entities) do
        if e.valid then
          if t.unit_number ~= nil then
            if e.unit_number == t.unit_number then return e end
          elseif e.name == t.name then
            local d = S.dist(e.position, t.pos)
            if d <= 2 and (bd == nil or d < bd) then best, bd = e, d end
          end
        end
      end
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
end

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
  return F.collided or {}, e, F.proxy
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
      if fl.g.valid then
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
    if g.valid and g.type == "entity-ghost" and not rawget(g, "_claimed") and g.force == h.force
        and math.abs(g.position.x - h.position.x) <= r and math.abs(g.position.y - h.position.y) <= r
        and F.blocked[F.key(g.position)] == nil and not body_at(g.position, g.ghost_name, g.direction) then
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

-- «Движок»: центр рамки чертежа ставится в position, первая сущность привязывается к сетке.
local function engine_build(bp, p)
  F.bp_calls[#F.bp_calls + 1] = p
  F.tile_ghosts = F.tile_ghosts + #(bp.tiles or {})
  local x0, y0, x1, y1
  for _, be in ipairs(bp.entities) do
    local proto = prototypes.entity[be.name] or {}
    local w, h = (proto.tile_width or 1) / 2, (proto.tile_height or 1) / 2
    x0 = math.min(x0 or be.position.x - w, be.position.x - w)
    y0 = math.min(y0 or be.position.y - h, be.position.y - h)
    x1 = math.max(x1 or be.position.x + w, be.position.x + w)
    y1 = math.max(y1 or be.position.y + h, be.position.y + h)
  end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local pos = S.norm_pos(p.position)
  local shift = F.bp_shift or { x = 0, y = 0 }
  local out = {}
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
    if same ~= nil then
      out[#out + 1] = same
    elseif allowed("blueprint_ghost", { name = be.name, position = { x = wx, y = wy }, direction = dir, force = p.force }) then
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
  function st.get_blueprint_entities() return S.copy(bp.entities) end
  function st.get_blueprint_tiles() return bp.tiles end
  function st.set_blueprint_tiles(t) bp.tiles = t end
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
  CHECK_NAMES = {}

  local W = C.setup(opts)
  F.prototypes()
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
    C.run(1)
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
