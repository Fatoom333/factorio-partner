-- Заглушки «Соединений» (connect_entities). Дополняют stubs.lua, stubs_c.lua и stubs_n.lua, TESTING.md §1.
--
--   local S = require("stubs"); local X = require("stubs_n"); local J = require("stubs_j")
--   local W = J.setup{ items = { pipe = 50 } }         -- мир лент stubs_n + трубы, опоры, память блоков
--   J.port("blk", "out0", { pos = {x=5.5, y=0.5}, kind = "belt", io = "out", dir = 4 })
--   J.machine(10, 0, { size = 3, boxes = { { targets = { {12, 0} }, fluid = "water" } } })
--   local d, kind = J.connect{ kind = "pipe", from = { pos = ... }, to = { target = ... } }
--
-- Что даёт сверх stubs_n:
-- * подмену scripts.lib.layout (J.ports, J.blocks — что вернут layout.port / layout.entity);
-- * регистрацию действия connect_entities, если control.lua его ещё не знает;
-- * прототипы труб, подземной трубы, опор, машин; жидкости;
-- * поиск по области учитывает bounding_box сущности (машины больше клетки, как в игре);
-- * машины с жидкостными коробками (LuaFluidBox: #, get_pipe_connections, get_filter,
--   get_locked_fluid, fb[i]), опоры, потребители;
-- * призраки с revive и ghost_prototype; проверка ghost_revive не считает помехой сам призрак.
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_n")

local J = {}

J.ports, J.blocks = {}, {}

J.layout = {
  port = function(_, tag, id)
    local p = J.ports[tag .. ":" .. id]
    if p == nil then return nil, "not_found", "layout " .. tostring(tag) .. " has no port " .. tostring(id) end
    local out = {}
    for k, v in pairs(p) do out[k] = v end
    out.surface = out.surface or 1
    return out
  end,
  entity = function(_, tag, i)
    local b = J.blocks[tag .. ":" .. i]
    if b == nil then return nil, "not_found", "layout " .. tostring(tag) .. " has no building " .. tostring(i) end
    return { name = b.name, pos = b.pos, surface = b.surface or 1 }
  end,
}

function J.port(tag, id, p) J.ports[tag .. ":" .. id] = p end
function J.block(tag, i, b) J.blocks[tag .. ":" .. i] = b end

-- ===================================================================== прототипы

local OBJECT = { layers = { object = true, water_tile = true, is_object = true } }

local function proto(name, etype, extra)
  local p = { name = name, type = etype, hidden = false, max_health = 100, collision_mask = OBJECT }
  p.items_to_place_this = { { name = name, count = 1 } }
  for k, v in pairs(extra or {}) do p[k] = v end
  prototypes.entity[name] = p
  prototypes.item[name] = prototypes.item[name] or { name = name, type = "item", stack_size = 100 }
  return p
end

local function box(n)
  local h = n / 2 - 0.1
  return { left_top = { x = -h, y = -h }, right_bottom = { x = h, y = h } }
end

function J.prototypes()
  proto("pipe", "pipe", {
    collision_box = box(1),
    fluidbox_prototypes = { { pipe_connections = {}, max_pipeline_extent = 320 } },
  })
  proto("pipe-to-ground", "pipe-to-ground", {
    collision_box = box(1),
    fluidbox_prototypes = { { pipe_connections = {
      { connection_type = "normal" }, { connection_type = "underground", max_underground_distance = 10 },
    } } },
  })
  proto("small-electric-pole", "electric-pole", { collision_box = box(1), max_wire_distance = 7.5, supply_area_distance = 2.5 })
  proto("medium-electric-pole", "electric-pole", { collision_box = box(1), max_wire_distance = 9, supply_area_distance = 3.5 })
  proto("big-electric-pole", "electric-pole", { collision_box = box(2), max_wire_distance = 30, supply_area_distance = 2 })
  proto("assembling-machine-1", "assembling-machine", { collision_box = box(3) })
  proto("chemical-plant", "assembling-machine", { collision_box = box(3), fluidbox_prototypes = { {}, {} } })
  proto("offshore-pump", "offshore-pump", { collision_box = box(1) })
  proto("storage-tank", "storage-tank", { collision_box = box(3) })
  prototypes.fluid = { water = { name = "water" }, ["crude-oil"] = { name = "crude-oil" }, steam = { name = "steam" } }
end

-- ===================================================================== мир

local function inter(b, a)
  return b.left_top.x < a.right_bottom.x and b.right_bottom.x > a.left_top.x
    and b.left_top.y < a.right_bottom.y and b.right_bottom.y > a.left_top.y
end

--- Поиск по области: сущность с bounding_box попадает, если её рамка пересекает область.
local function wrap_find(surface)
  local orig = surface.find_entities_filtered
  surface.find_entities_filtered = function(f)
    f = f or {}
    if f.area == nil then return orig(f) end
    local area = S.norm_area(f.area)
    local f2 = {}
    for k, v in pairs(f) do
      if k ~= "area" and k ~= "limit" then f2[k] = v end
    end
    local out = {}
    for _, e in ipairs(orig(f2)) do
      local p = e.position
      local b = rawget(e, "bounding_box")
      local ok
      if b ~= nil then
        ok = inter(b, area)
      else
        ok = p.x >= area.left_top.x and p.x <= area.right_bottom.x and p.y >= area.left_top.y and p.y <= area.right_bottom.y
      end
      if ok then
        out[#out + 1] = e
        if f.limit and #out >= f.limit then break end
      end
    end
    return out
  end
end

local function wrap_can_place(surface)
  local base = surface.can_place
  surface.can_place = function(s, params)
    if params.build_check_type == defines.build_check_type.ghost_revive then
      -- сам призрак постройке не мешает: прячем призраки клетки на время проверки
      local x, y = math.floor(S.norm_pos(params.position).x), math.floor(S.norm_pos(params.position).y)
      local hidden = {}
      for _, e in ipairs(s._entities) do
        if e.valid and e.type == "entity-ghost" and math.floor(e.position.x) == x and math.floor(e.position.y) == y then
          hidden[#hidden + 1] = e
          rawset(e, "valid", false)
        end
      end
      local ok = base(s, params)
      for _, e in ipairs(hidden) do rawset(e, "valid", true) end
      return ok
    end
    -- опора 2×2 занимает четыре клетки
    local p = prototypes.entity[params.name]
    local cb = p and p.collision_box
    if cb and cb.right_bottom.x - cb.left_top.x > 1.5 then
      local pos = S.norm_pos(params.position)
      for dx = -1, 0 do
        for dy = -1, 0 do
          local q = { name = "pipe", position = { x = pos.x + dx + 0.5, y = pos.y + dy + 0.5 }, force = params.force,
            build_check_type = params.build_check_type, forced = params.forced }
          if not base(s, q) then return false end
        end
      end
      return true
    end
    return base(s, params)
  end
end

--- J.setup(opts) → W: мод (действие и подменённый layout), хозяин, помощник h1, прототипы.
function J.setup(opts)
  opts = opts or {}
  J.ports, J.blocks = {}, {}
  local orig = S.load_mod
  S.load_mod = function(o)
    o = o or {}
    o.replace = o.replace or {}
    o.replace["scripts.lib.layout"] = J.layout
    return orig(o)
  end
  local items = opts.items
  local o2 = {}
  for k, v in pairs(opts) do if k ~= "items" then o2[k] = v end end
  local ok, W = pcall(X.setup, o2)
  S.load_mod = orig
  if not ok then error(W, 0) end
  J.prototypes()
  -- предметы — после прототипов (опоры и трубы заглушка stubs_c не знает)
  for name, n in pairs(items or {}) do W.main.insert{ name = name, count = n } end
  local jobs = require("scripts.core.jobs")
  if jobs.actions.connect_entities == nil then
    jobs.register(require("scripts.actions.connect_entities"))
  end
  X.research("pipe", "pipe-to-ground", "small-electric-pole", "medium-electric-pole")
  X.forget("big-electric-pole")
  if not opts.no_memory then
    storage.connect_last = storage.connect_last or {}
    storage.connect_fled = storage.connect_fled or {}
  end
  wrap_find(S.nauvis)
  wrap_can_place(S.nauvis)
  local create = S.nauvis.create_entity
  S.nauvis.create_entity = function(params)
    local e = create(params)
    if e ~= nil and params.name == "entity-ghost" then
      e.ghost_prototype = prototypes.entity[params.inner_name]
      e.revive = function()
        local surf, pos, name, dir, force = e.surface, S.norm_pos(e.position), e.ghost_name, e.direction, e.force
        e.destroy()
        local built = surf.create_entity{ name = name, position = pos, direction = dir, force = force }
        return {}, built
      end
    end
    return e
  end
  rawset(W.h, "remove_item", function(st) return W.main.remove(st) end)
  J.W = W
  return W
end

local function fluidbox(boxes)
  local fb = {}
  for i, b in ipairs(boxes) do
    if b.amount ~= nil or b.content ~= nil then rawset(fb, i, { name = b.content or b.fluid, amount = b.amount or 10 }) end
  end
  fb.get_pipe_connections = function(i)
    local out = {}
    for _, t in ipairs(boxes[i].targets or {}) do
      out[#out + 1] = { connection_type = t.type or "normal", target_position = { x = t[1] + 0.5, y = t[2] + 0.5 } }
    end
    return out
  end
  fb.get_filter = function(i)
    local f = boxes[i].filter
    return f and { name = f } or nil
  end
  fb.get_locked_fluid = function(i) return boxes[i].fluid end
  return setmetatable(fb, { __len = function() return #boxes end })
end

--- Машина size×size с левой верхней клеткой (x, y); boxes = {{targets = {{x, y}, ...}, fluid?,
--- filter?, content?}}. Клетки машины заняты (X.blocked).
function J.machine(x, y, opts)
  opts = opts or {}
  local n = opts.size or 3
  local e = S.nauvis.create_entity{
    name = opts.name or "chemical-plant", position = { x = x + n / 2, y = y + n / 2 }, force = opts.force or "player",
  }
  e.bounding_box = { left_top = { x = x + 0.1, y = y + 0.1 }, right_bottom = { x = x + n - 0.1, y = y + n - 0.1 } }
  if opts.boxes then e.fluidbox = fluidbox(opts.boxes) end
  for dx = 0, n - 1 do
    for dy = 0, n - 1 do X.blocked[X.key(x + dx, y + dy)] = true end
  end
  return e
end

--- Стоящая труба своей силы (соединения на все четыре стороны) с жидкостью fluid.
function J.pipe(x, y, fluid, force)
  local e = S.nauvis.create_entity{ name = "pipe", position = { x = x + 0.5, y = y + 0.5 }, force = force or "player" }
  e.fluidbox = fluidbox({ { targets = { { x + 1, y }, { x - 1, y }, { x, y + 1 }, { x, y - 1 } }, content = fluid } })
  return e
end

--- Стоящая опора своей силы.
function J.pole(x, y, name)
  return S.nauvis.create_entity{
    name = name or "small-electric-pole", position = { x = x + 0.5, y = y + 0.5 }, force = "player",
  }
end

--- act connect_entities → data, kind, job (ждёт итога).
function J.connect(args, n)
  local job = S.okr(C.act("connect_entities", args)).job
  local d, kind = C.wait(job, n or 4000)
  return d, kind, job
end

--- Живые призраки своей силы сейчас (X.live_ghosts) с именем name (или все).
function J.ghosts(name)
  local out = {}
  for _, g in ipairs(X.live_ghosts()) do
    if name == nil or g.name == name then out[#out + 1] = g end
  end
  return out
end

--- Опоры-призраки: центры.
function J.pole_ghosts(name)
  local out = {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and e.type == "entity-ghost" and (name == nil or e.ghost_name == name) then
      out[#out + 1] = { x = e.position.x, y = e.position.y, name = e.ghost_name }
    end
  end
  return out
end

return J
