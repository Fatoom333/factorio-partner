-- Заглушки блоков построек (build_layout). Дополняют stubs.lua, stubs_c.lua и stubs_f.lua,
-- TESTING.md §1.
--
--   local S = require("stubs"); local F = require("stubs_f"); local K = require("stubs_k")
--   local W = K.setup{ items = { ["iron-chest"] = 3 } }   -- как F.setup + прототипы и «движок» чертежа
--   local d, kind = F.wait(K.job{ anchor = { x = 20, y = 0 }, entities = { ... } })
--
-- Что даёт сверх stubs_f:
-- * прототипы: test-2x3 (постройка 2×3), underground-belt (тип underground-belt), у бура —
--   mining_drill_radius;
-- * «движок» пустого чертежа: game.create_inventory(1) → стак с set_stack{name="blueprint"},
--   set_blueprint_entities (журнал K.bp_entities), build_blueprint (журнал K.bp_calls). Раскладка —
--   как у движка 2.0.77: центр рамки по клеткам построек (с учётом их поворота) ставится в
--   position, первая постройка привязывается к сетке по своей ширине и высоте, остальные — тем же
--   сдвигом; K.bp_shift — лишний сдвиг всех призраков (проверка сверки), K.bp_shift_once — только
--   при первой постановке. Помехи — как у F (деревья и камни помечаются, вода с открытой
--   подложкой — призрак подложки, чужое и своё — призрака нет);
-- * призрак несёт recipe и type из чертежа (g._recipe, g._type); K.ghost_keeps_recipe = true —
--   постройка после revive отдаёт этот рецепт через get_recipe (как если бы призрак его донёс).
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

local K = {}

local function rot(dx, dy, dir)
  if dir == 4 then return -dy, dx end
  if dir == 8 then return -dx, -dy end
  if dir == 12 then return dy, -dx end
  return dx, dy
end

local function size_of(name, dir)
  local proto = prototypes.entity[name] or {}
  local w, h = proto.tile_width or 1, proto.tile_height or 1
  if dir == 4 or dir == 12 then w, h = h, w end
  return w, h
end
K.size_of = size_of

local function snap(v, n)
  if n % 2 == 1 then return math.floor(v) + 0.5 end
  return math.floor(v + 0.5)
end

local function liquid_at(pos, name, dir)
  local w, h = size_of(name, dir)
  for cx = math.floor(pos.x - w / 2 + 0.05), math.floor(pos.x + w / 2 - 0.05) do
    for cy = math.floor(pos.y - h / 2 + 0.05), math.floor(pos.y + h / 2 - 0.05) do
      local t = prototypes.tile[F.tile_at(cx, cy)]
      if t and t.collision_mask.layers.water_tile then return true, cx, cy, t end
    end
  end
  return false
end

--- Постройки name, стоящие на месте (с учётом поворота) — кроме мягких сущностей.
local SOFT = { ["entity-ghost"] = true, ["tile-ghost"] = true, character = true, resource = true,
  ["item-entity"] = true, ["character-corpse"] = true }

local function solid_at(pos, name, dir)
  local w, h = size_of(name, dir)
  local out = {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and not SOFT[e.type] then
      local ew, eh = size_of(e.name, e.direction)
      if math.abs(e.position.x - pos.x) < (w + ew) / 2 - 0.05 and math.abs(e.position.y - pos.y) < (h + eh) / 2 - 0.05 then
        out[#out + 1] = e
      end
    end
  end
  return out
end
K.solid_at = solid_at

local function engine_build(bp, p)
  K.bp_calls[#K.bp_calls + 1] = p
  local x0, y0, x1, y1
  for _, be in ipairs(bp.entities) do
    local w, h = size_of(be.name, be.direction or 0)
    x0 = math.min(x0 or be.position.x - w / 2, be.position.x - w / 2)
    y0 = math.min(y0 or be.position.y - h / 2, be.position.y - h / 2)
    x1 = math.max(x1 or be.position.x + w / 2, be.position.x + w / 2)
    y1 = math.max(y1 or be.position.y + h / 2, be.position.y + h / 2)
  end
  local out = {}
  if x0 == nil then return out end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local pos = S.norm_pos(p.position)
  local shift = K.bp_shift or { x = 0, y = 0 }
  if K.bp_shift_once then
    shift = K.bp_shift_once
    K.bp_shift_once = nil
  end
  local mode = p.build_mode or defines.build_mode.normal
  local sx, sy
  for _, be in ipairs(bp.entities) do
    local dir = ((be.direction or 0) + (p.direction or 0)) % 16
    local dx, dy = rot(be.position.x - cx, be.position.y - cy, p.direction or 0)
    local wx, wy = pos.x + dx, pos.y + dy
    if sx == nil then
      local w, h = size_of(be.name, dir)
      sx, sy = snap(wx, w) - wx, snap(wy, h) - wy
    end
    wx, wy = wx + sx + shift.x, wy + sy + shift.y
    local ok, to_mark, cover = true, {}, nil
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
    local wet, lx, ly, lt = liquid_at({ x = wx, y = wy }, be.name, dir)
    if wet then
      local cover_item = lt.default_cover_tile and lt.default_cover_tile.items_to_place_this[1].name
      local known = cover_item and p.force.recipes[cover_item] and p.force.recipes[cover_item].enabled
      if mode == defines.build_mode.normal or not known or K.no_cover then
        ok = false
      else
        cover = { name = lt.default_cover_tile.name, x = lx, y = ly }
      end
    end
    local key = F.key({ x = wx, y = wy })
    F.checks[#F.checks + 1] = { kind = "blueprint_ghost", name = be.name, pos = { x = wx, y = wy }, direction = dir }
    local b = F.blocked[key]
    if b == true or (type(b) == "table" and b.blueprint_ghost) then ok = false end
    if ok then
      for _, e in ipairs(to_mark) do F.mark(e) end
      if cover then
        out[#out + 1] = F.tile_ghost(cover.name, cover, { force = p.force })
      end
      local g = F.ghost(be.name, { x = wx, y = wy }, { direction = dir, force = p.force, surface = p.surface })
      rawset(g, "_recipe", be.recipe)
      rawset(g, "_type", be.type)
      out[#out + 1] = g
    end
  end
  return out
end

local function fake_inventory()
  K.inv_created = K.inv_created + 1
  local st = { valid = true, valid_for_read = false }
  local bp
  function st.set_stack(spec)
    K.set_stack[#K.set_stack + 1] = spec
    bp = { entities = {} }
    st.valid_for_read = true
    st.is_blueprint = spec and spec.name == "blueprint"
    return true
  end
  function st.set_blueprint_entities(list)
    if bp == nil then error("set_blueprint_entities: empty stack", 2) end
    bp.entities = S.copy(list)
    K.bp_entities = S.copy(list)
  end
  function st.build_blueprint(p)
    if bp == nil then error("build_blueprint: empty stack", 2) end
    return engine_build(bp, p)
  end
  local binv = { valid = true, [1] = st }
  function binv.destroy()
    binv.valid = false
    K.inv_destroyed = K.inv_destroyed + 1
  end
  return binv
end

--- Мир стройки F.setup + прототипы и «движок» пустого чертежа.
function K.setup(opts)
  -- предметы кладутся после своих прототипов (среди них test-2x3, которого в F нет)
  local base = {}
  for k, v in pairs(opts or {}) do base[k] = v end
  base.items = nil
  local W = F.setup(base)
  K.bp_calls, K.bp_entities, K.set_stack = {}, nil, {}
  K.inv_created, K.inv_destroyed = 0, 0
  K.bp_shift, K.bp_shift_once, K.no_cover, K.ghost_keeps_recipe = nil, nil, false, false
  local E, I = prototypes.entity, prototypes.item
  local function clone(from, name, etype, w, h)
    local p = {}
    for k, v in pairs(E[from]) do p[k] = v end
    p.name, p.type = name, etype or p.type
    p.items_to_place_this = { { name = name, count = 1 } }
    if w then
      p.tile_width, p.tile_height = w, h
      p.collision_box = { left_top = { x = -w / 2 + 0.1, y = -h / 2 + 0.1 }, right_bottom = { x = w / 2 - 0.1, y = h / 2 - 0.1 } }
    end
    E[name] = p
    I[name] = { name = name, type = "item", stack_size = 50, place_result = p }
    return p
  end
  clone("iron-chest", "test-2x3", "container", 2, 3)
  clone("transport-belt", "underground-belt", "underground-belt")
  E["electric-mining-drill"].mining_drill_radius = 2.49
  game.create_inventory = function() return fake_inventory() end
  -- постройка после revive: рецепт призрака (если K.ghost_keeps_recipe) и set_recipe
  local revive = F.revive
  F.revive = function(g, p)
    local recipe = rawget(g, "_recipe")
    local collided, e, proxy = revive(g, p)
    if e ~= nil and (e.type == "furnace" or e.type == "container") and rawget(e, "inventories") == nil then
      e.inventories = { [defines.inventory.chest] = C.inventory{ size = 16 } }
    end
    if e ~= nil and e.type == "assembling-machine" then
      if K.ghost_keeps_recipe and recipe ~= nil then e.recipe_set = { recipe = recipe, quality = "normal" } end
      rawset(e, "get_recipe", function()
        local r = rawget(e, "recipe_set") or e.recipe_set
        return r and { name = r.recipe } or nil
      end)
      rawset(e, "set_recipe", function(name, quality)
        if K.set_recipe_fails then error("set_recipe failed") end
        e.recipe_set = { recipe = name, quality = quality }
        K.set_recipe_calls = (K.set_recipe_calls or 0) + 1
      end)
    end
    return collided, e, proxy
  end
  K.set_recipe_calls, K.set_recipe_fails = 0, false
  for name, n in pairs(opts and opts.items or {}) do W.main.insert{ name = name, count = n } end
  return W
end

--- Поставить build_layout помощнику h1 → номер задачи.
function K.job(args, extra)
  return F.job("build_layout", args, extra)
end

--- Сущности name своей силы (не призраки) в точке pos.
function K.built(name, pos)
  local out = {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and e.name == name and e.type ~= "entity-ghost" and (pos == nil or S.dist(e.position, pos) < 0.01) then
      out[#out + 1] = e
    end
  end
  return out
end

--- Клетки, которые занимает постройка с центром pos (размер с учётом поворота) — множество "x,y".
function K.cells(name, pos, dir)
  local w, h = size_of(name, dir)
  local out = {}
  for x = math.floor(pos.x - w / 2 + 0.05), math.floor(pos.x + w / 2 - 0.05) do
    for y = math.floor(pos.y - h / 2 + 0.05), math.floor(pos.y + h / 2 - 0.05) do out[x .. "," .. y] = true end
  end
  return out
end

return K
