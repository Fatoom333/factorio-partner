-- Заглушки потока C («Руки»). Дополняют mod/tests/stubs.lua потока A (TESTING.md §1).
--
--   local S = require("stubs"); local C = require("stubs_c")
--   local W = C.setup()            -- мод с фейковым path, хозяин в (0,0), помощник h1 в (2,0)
--   C.run(60)                      -- 60 тиков: сначала «движок» (добыча, крафт), потом S.tick
--   C.act("mine", {...})           -- act для h1 → data; C.events() — события
--
-- Что даёт сверх stubs.lua:
-- * C.inventory{size, items={name=count}│{{name,count,quality,data}}} — инвентарь со стаками
--   (inv[i] → LuaItemStack: transfer_stack/swap_stack/clear/count), find_empty_stack, #inv;
-- * у тела помощника — такие инвентари, «движок» добычи (selected + mining_state: время, выход,
--   истощение руды, полный инвентарь; дерево и камень — только с resource_reach_distance, как в
--   игре: C.near_only) и ручного крафта (begin_crafting тратит ингредиенты,
--   очередь, cancel_crafting возвращает их);
-- * game.get_entity_by_unit_number; прототипы руд/деревьев/рецептов с mineable_properties;
-- * фейковый scripts.lib.path: шаг 1 клетка за тик к цели, журнал вызовов, W.path.fail = result.
local S = require("stubs")

local C = {}

-- типы, которые рука добывает только вплотную (как scripts/lib/inventory.lua NEAR_ONLY)
C.NEAR = { tree = true, ["simple-entity"] = true, fish = true }

-- ===================================================================== объекты

local function bind(obj, m)
  return function(a, ...)
    if a == obj then return m(obj, ...) end
    return m(obj, a, ...)
  end
end

local function stack_size(name)
  local p = prototypes.item[name]
  return (p and p.stack_size) or 50
end

-- ---------------------------------------------------------------- стак

local Stack = {}

local function new_stack(owner)
  local d = { owner = owner }
  local st = {}
  local mt = {
    __lua_object = true,
    __index = function(t, k)
      if k == "valid_for_read" then return d.name ~= nil and (d.count or 0) > 0 end
      if k == "valid" then return true end
      if k == "object_name" then return "LuaItemStack" end
      if k == "name" or k == "count" or k == "data" then
        if not (d.name ~= nil and (d.count or 0) > 0) then
          if k == "data" then return nil end
          error("LuaItemStack: stack is empty (" .. k .. ")", 2)
        end
        return d[k]
      end
      if k == "quality" then
        if d.name == nil then error("LuaItemStack: stack is empty (quality)", 2) end
        return { name = d.quality or "normal" }
      end
      if k == "_d" then return d end
      local m = Stack[k]
      if type(m) == "function" then return bind(t, m) end
      return nil
    end,
    __newindex = function(t, k, v)
      if k == "count" then
        if type(v) ~= "number" or v < 0 then error("bad count", 2) end
        if v == 0 then d.name, d.count, d.quality, d.data = nil, nil, nil, nil; emptied(d)
        else d.count = v end
        return
      end
      error("LuaItemStack: field " .. tostring(k) .. " is read-only in the stub", 2)
    end,
  }
  return setmetatable(st, mt)
end

local function sd(st) return st._d end

-- стак опустел: у предмета на земле движок сам убирает item-entity (on_empty из C.ground)
local function emptied(d)
  if d.name == nil and d.on_empty then d.on_empty() end
end

function Stack.clear(self)
  local d = sd(self)
  d.name, d.count, d.quality, d.data = nil, nil, nil, nil
  emptied(d)
end

function Stack.set(self, name, count, quality, data)
  local d = sd(self)
  d.name, d.count, d.quality, d.data = name, count, quality or "normal", data
end

--- transfer_stack(src) как в 2.0 (только стак, без count): в пустой — перенос (с данными), в
--- такой же простой — слияние. Лишний аргумент — ошибка стаба (в игре молча игнорируется).
function Stack.transfer_stack(self, src, extra)
  if extra ~= nil then error("stub: LuaItemStack.transfer_stack takes only a stack (2.0)", 2) end
  local a, b = sd(self), sd(src)
  if b.name == nil then return false end
  local want = b.count
  if a.name == nil then
    local n = math.min(want, stack_size(b.name))
    a.name, a.count, a.quality, a.data = b.name, n, b.quality, b.data
    b.count = b.count - n
    if b.count <= 0 then b.name, b.count, b.quality, b.data = nil, nil, nil, nil; emptied(b)
    elseif b.data ~= nil then error("stub: partial transfer of a stack with data", 2) end
    C.log[#C.log + 1] = "transfer_stack:" .. a.name .. ":" .. n
    return n == want
  end
  if a.name == b.name and a.quality == b.quality and a.data == nil and b.data == nil then
    local n = math.min(want, stack_size(a.name) - a.count)
    a.count = a.count + n
    b.count = b.count - n
    if b.count <= 0 then b.name, b.count, b.quality, b.data = nil, nil, nil, nil; emptied(b) end
    return n == want
  end
  return false
end

function Stack.swap_stack(self, other)
  local a, b = sd(self), sd(other)
  a.name, b.name = b.name, a.name
  a.count, b.count = b.count, a.count
  a.quality, b.quality = b.quality, a.quality
  a.data, b.data = b.data, a.data
  C.log[#C.log + 1] = "swap_stack"
  return true
end

-- ---------------------------------------------------------------- инвентарь со стаками

local Inv = {}

local function q_of(x) return (type(x) == "table" and x.name) or x or "normal" end

local function ident(st)
  if type(st) == "string" then return st, 1, "normal" end
  return st.name, st.count or 1, q_of(st.quality)
end

function Inv.get_item_count(self, item)
  local name, quality
  if item ~= nil then
    if type(item) == "table" then name, quality = item.name, q_of(item.quality) else name = item end
  end
  local n = 0
  for _, s in ipairs(self._slots) do
    local d = sd(s)
    if d.name and (name == nil or (d.name == name and (quality == nil or d.quality == quality))) then
      n = n + d.count
    end
  end
  return n
end

function Inv.get_contents(self)
  local acc, order = {}, {}
  for _, s in ipairs(self._slots) do
    local d = sd(s)
    if d.name then
      local k = d.name .. "@" .. d.quality
      if not acc[k] then acc[k] = { name = d.name, count = 0, quality = d.quality }; order[#order + 1] = k end
      acc[k].count = acc[k].count + d.count
    end
  end
  table.sort(order)
  local out = {}
  for _, k in ipairs(order) do out[#out + 1] = acc[k] end
  return out
end

function Inv.insert(self, st)
  local name, count, quality = ident(st)
  if prototypes.item[name] == nil then error("Unknown item name: " .. tostring(name), 2) end
  local size = stack_size(name)
  local left = count
  for _, s in ipairs(self._slots) do
    if left <= 0 then break end
    local d = sd(s)
    if d.name == name and d.quality == quality and d.data == nil and d.count < size then
      local n = math.min(left, size - d.count)
      d.count = d.count + n
      left = left - n
    end
  end
  for _, s in ipairs(self._slots) do
    if left <= 0 then break end
    local d = sd(s)
    if d.name == nil then
      local n = math.min(left, size)
      d.name, d.count, d.quality = name, n, quality
      left = left - n
    end
  end
  C.log[#C.log + 1] = "insert:" .. name .. ":" .. (count - left)
  return count - left
end

function Inv.can_insert(self, st)
  local name, _, quality = ident(st)
  for _, s in ipairs(self._slots) do
    local d = sd(s)
    if d.name == nil then return true end
    if d.name == name and d.quality == quality and d.data == nil and d.count < stack_size(name) then return true end
  end
  return false
end

function Inv.remove(self, st)
  local name, count, quality = ident(st)
  local left = count
  for i = #self._slots, 1, -1 do
    if left <= 0 then break end
    local d = sd(self._slots[i])
    if d.name == name and d.quality == quality then
      if d.data ~= nil then C.data_destroyed = (C.data_destroyed or 0) + 1 end
      local n = math.min(left, d.count)
      d.count = d.count - n
      left = left - n
      if d.count <= 0 then d.name, d.count, d.quality, d.data = nil, nil, nil, nil end
    end
  end
  C.log[#C.log + 1] = "remove_item:" .. name .. ":" .. (count - left)
  return count - left
end

function Inv.find_empty_stack(self)
  for i, s in ipairs(self._slots) do
    if sd(s).name == nil then return s, i end
  end
  return nil
end

function Inv.count_empty_stacks(self)
  local n = 0
  for _, s in ipairs(self._slots) do if sd(s).name == nil then n = n + 1 end end
  return n
end

function Inv.is_empty(self) return self:count_empty_stacks() == #self._slots end
function Inv.clear(self) for _, s in ipairs(self._slots) do s.clear() end end

--- C.inventory{size=10, items={["iron-plate"]=100} │ {{name=,count=,quality=,data=}, ...}}
function C.inventory(opts)
  opts = opts or {}
  local inv = { _slots = {}, valid = true, object_name = "LuaInventory" }
  local mt
  mt = {
    __lua_object = true,
    __index = function(t, k)
      if type(k) == "number" then
        local s = rawget(t, "_slots")[k]
        if s == nil then error("LuaInventory: index " .. k .. " out of range", 2) end
        return s
      end
      local m = Inv[k]
      if type(m) == "function" then return bind(t, m) end
      return nil
    end,
    __len = function(t) return #rawget(t, "_slots") end,
  }
  setmetatable(inv, mt)
  for i = 1, opts.size or 10 do inv._slots[i] = new_stack(inv) end
  local items = opts.items or {}
  if items[1] ~= nil then
    for _, it in ipairs(items) do
      local slot = inv.find_empty_stack()
      slot.set(it.name, it.count or 1, it.quality, it.data)
    end
  else
    local names = {}
    for k in pairs(items) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do inv.insert{ name = k, count = items[k] } end
  end
  return inv
end

-- ===================================================================== прототипы

local function minable(proto, products, time, extra)
  proto.mineable_properties = { minable = true, mining_time = time or 1, products = products }
  for k, v in pairs(extra or {}) do proto.mineable_properties[k] = v end
  return proto
end

local function item_product(name, n) return { { type = "item", name = name, amount = n or 1 } } end

function C.prototypes()
  local E = prototypes.entity
  E.character.resource_categories = { ["basic-solid"] = true }
  E.character.mining_categories = nil
  E.character.mining_speed = 0.5
  E.character.crafting_categories = { crafting = true }
  for _, n in ipairs({ "iron-ore", "copper-ore", "coal", "stone" }) do
    minable(E[n], item_product(n), 1)
    E[n].resource_category = "basic-solid"
  end
  E["calcite"] = minable({ name = "calcite", type = "resource", resource_category = "basic-solid" }, item_product("calcite"), 1)
  E["tungsten-ore"] = minable({ name = "tungsten-ore", type = "resource", resource_category = "hard-solid" }, item_product("tungsten-ore"), 5)
  E["uranium-ore"] = minable({ name = "uranium-ore", type = "resource", resource_category = "basic-solid" },
    item_product("uranium-ore"), 2, { required_fluid = "sulfuric-acid" })
  minable(E["tree-01"], item_product("wood", 4), 0.5)
  minable(E["iron-chest"], item_product("iron-chest"), 0.2)
  minable(E["wooden-chest"], item_product("wooden-chest"), 0.2)
  E["car"] = { name = "car", type = "car" }
  E["infinity-chest"] = { name = "infinity-chest", type = "infinity-container" }
  for _, n in ipairs({ "calcite", "tungsten-ore", "uranium-ore", "car", "rocket-part", "fusion-reactor-equipment" }) do
    prototypes.item[n] = { name = n, type = "item", stack_size = 50 }
  end
  prototypes.item["car"].type = "item-with-entity-data"
  prototypes.item["car"].stack_size = 1
  prototypes.item["power-armor-mk2"].stack_size = 1
  prototypes.item["blueprint"].stack_size = 1
  prototypes.item["modular-armor"] = { name = "modular-armor", type = "armor", stack_size = 1 }
  prototypes.item["yumako"] = { name = "yumako", type = "capsule", stack_size = 50,
    get_spoil_ticks = function() return 3600 end }
end

local RECIPES = {
  { name = "iron-gear-wheel", ingredients = { { "iron-plate", 2 } }, product = "iron-gear-wheel", energy = 0.5 },
  { name = "wooden-chest", ingredients = { { "wood", 2 } }, product = "wooden-chest", energy = 0.5 },
  { name = "iron-chest", ingredients = { { "iron-plate", 8 } }, product = "iron-chest", energy = 0.5 },
  { name = "stone-furnace", ingredients = { { "stone", 5 } }, product = "stone-furnace", energy = 0.5 },
  { name = "pipe", ingredients = { { "iron-plate", 1 } }, product = "pipe", energy = 0.5, amount = 1 },
  { name = "sulfuric-acid", ingredients = { { "iron-plate", 1 } }, product = "pipe", energy = 1, category = "chemistry" },
  { name = "electric-mining-drill", ingredients = { { "iron-plate", 10 } }, product = "electric-mining-drill", energy = 2, enabled = false },
  -- в категории crafting, но скрыт от ручного крафта (флаг только у прототипа)
  { name = "hand-hidden", ingredients = { { "iron-plate", 1 } }, product = "pipe", energy = 0.5, hidden_from_player_crafting = true },
  -- два продукта, основной — второй (main_product только у прототипа)
  { name = "gear-and-stone", ingredients = { { "iron-plate", 2 } }, product = "stone", extra = "iron-gear-wheel",
    main = "iron-gear-wheel", energy = 0.5 },
}

-- Поля LuaRecipe / LuaRecipePrototype 2.0, которые бывают у стаба; чтение любого другого ключа —
-- ошибка, как у настоящего LuaObject («LuaRecipe doesn't contain key …»).
local RECIPE_KEYS = {
  name = true, valid = true, object_name = true, enabled = true, hidden = true, category = true,
  energy = true, ingredients = true, products = true, prototype = true, force = true,
  localised_name = true, order = true, group = true, subgroup = true, productivity_bonus = true,
}
local RECIPE_PROTO_KEYS = {
  name = true, valid = true, object_name = true, enabled = true, hidden = true, category = true,
  energy = true, ingredients = true, products = true, main_product = true,
  hidden_from_player_crafting = true, localised_name = true, order = true, group = true, subgroup = true,
}

local function strict(object_name, fields, keys)
  return setmetatable({}, {
    __lua_object = true,
    __index = function(_, k)
      if not keys[k] then error(object_name .. " doesn't contain key " .. tostring(k) .. ".", 2) end
      return fields[k]
    end,
    __newindex = function(_, k, v)
      if k == "enabled" and object_name == "LuaRecipe" then fields.enabled = v return end
      error(object_name .. ": field " .. tostring(k) .. " is read-only in the stub", 2)
    end,
    __pairs = function() return next, fields, nil end,
  })
end

function C.recipes(force)
  for _, r in ipairs(RECIPES) do
    local ingredients = {}
    for _, ing in ipairs(r.ingredients) do ingredients[#ingredients + 1] = { type = "item", name = ing[1], amount = ing[2] } end
    local products = { { type = "item", name = r.product, amount = r.amount or 1 } }
    if r.extra then products[#products + 1] = { type = "item", name = r.extra, amount = 1 } end
    local main
    if r.main then
      for _, p in ipairs(products) do if p.name == r.main then main = p end end
    elseif #products == 1 then
      main = products[1]
    end
    local proto = strict("LuaRecipePrototype", {
      name = r.name, valid = true, object_name = "LuaRecipePrototype", enabled = r.enabled ~= false,
      hidden = false, category = r.category or "crafting", energy = r.energy, ingredients = ingredients,
      products = products, main_product = main, hidden_from_player_crafting = r.hidden_from_player_crafting or false,
    }, RECIPE_PROTO_KEYS)
    force.recipes[r.name] = strict("LuaRecipe", {
      name = r.name, valid = true, object_name = "LuaRecipe", enabled = r.enabled ~= false, hidden = false,
      category = r.category or "crafting", energy = r.energy, ingredients = ingredients, products = products,
      prototype = proto, force = force,
    }, RECIPE_KEYS)
  end
end

-- ===================================================================== тело помощника и «движок»

local function craftable(h, recipe)
  local inv = h.inventories[defines.inventory.character_main]
  local n = math.huge
  for _, ing in ipairs(recipe.ingredients) do
    n = math.min(n, math.floor(inv.get_item_count{ name = ing.name, quality = "normal" } / ing.amount))
  end
  return n == math.huge and 0 or n
end

local function refresh_queue(h)
  local q = {}
  local size = 0
  for i, e in ipairs(h._queue) do
    q[i] = { index = i, recipe = e.recipe, count = e.count, prerequisite = false }
    size = size + e.count
  end
  rawset(h, "crafting_queue", #q > 0 and q or nil)
  rawset(h, "crafting_queue_size", size)
end

--- Подготовить тело: инвентари со стаками, крафт, добыча.
function C.equip(h, opts)
  opts = opts or {}
  h.inventories = {
    [defines.inventory.character_main] = C.inventory{ size = opts.size or 20, items = opts.items },
    [defines.inventory.character_armor] = C.inventory{ size = 1, items = opts.armor },
    [defines.inventory.character_guns] = C.inventory{ size = 3 },
    [defines.inventory.character_ammo] = C.inventory{ size = 3 },
    [defines.inventory.character_trash] = C.inventory{ size = 10 },
  }
  h._queue = {}
  h._craft_progress = 0
  h._mine_progress = 0
  rawset(h, "crafting_queue_progress", 0)
  refresh_queue(h)
  rawset(h, "get_craftable_count", function(name)
    if type(name) == "table" then name = name.name end
    local r = h.force.recipes[name]
    return r and craftable(h, r) or 0
  end)
  rawset(h, "begin_crafting", function(p)
    local r = h.force.recipes[p.recipe]
    if not r then error("Unknown recipe", 2) end
    local n = p.count or 1
    if craftable(h, r) < n then error("not enough ingredients", 2) end
    local inv = h.inventories[defines.inventory.character_main]
    for _, ing in ipairs(r.ingredients) do inv.remove{ name = ing.name, count = ing.amount * n } end
    h._queue[#h._queue + 1] = { recipe = p.recipe, count = n }
    refresh_queue(h)
    C.log[#C.log + 1] = "begin_crafting:" .. p.recipe .. ":" .. n
    return n
  end)
  rawset(h, "cancel_crafting", function(p)
    local e = h._queue[p.index]
    if not e then error("bad crafting queue index", 2) end
    local n = math.min(p.count or e.count, e.count)
    local r = h.force.recipes[e.recipe]
    local inv = h.inventories[defines.inventory.character_main]
    for _, ing in ipairs(r.ingredients) do inv.insert{ name = ing.name, count = ing.amount * n } end
    e.count = e.count - n
    if e.count <= 0 then table.remove(h._queue, p.index) end
    refresh_queue(h)
    C.log[#C.log + 1] = "cancel_crafting:" .. r.name .. ":" .. n
    return true
  end)
  rawset(h, "clear_selected_entity", function() rawset(h, "selected", nil) end)
  -- как в игре (живой замер 2026-10-13): до дерева, камня и рыбы рука достаёт только с
  -- resource_reach_distance; C.near_only = false возвращает прежнее «всё с reach_distance»
  local can_reach = h.can_reach_entity
  rawset(h, "can_reach_entity", function(e)
    if C.near_only and C.NEAR[e.type] then
      return S.dist(h.position, e.position) <= h.resource_reach_distance
    end
    return can_reach(e)
  end)
  return h
end

local function engine_craft(h)
  local e = h._queue[1]
  if not e then rawset(h, "crafting_queue_progress", 0) return end
  local r = h.force.recipes[e.recipe]
  local inv = h.inventories[defines.inventory.character_main]
  local prod = r.products[1]
  if C.craft_blocked_when_full and not inv.can_insert{ name = prod.name } then return end
  h._craft_progress = h._craft_progress + 1 / (r.energy * 60)
  if h._craft_progress >= 1 then
    h._craft_progress = 0
    for _, p in ipairs(r.products) do inv.insert{ name = p.name, count = p.amount } end
    e.count = e.count - 1
    if e.count <= 0 then table.remove(h._queue, 1) end
    refresh_queue(h)
  end
  rawset(h, "crafting_queue_progress", h._craft_progress)
end

local function engine_mine(h)
  local ms = h.mining_state
  local t = h.selected
  if C.mining_disabled then return end
  if not (ms and ms.mining and t and t.valid) then h._mine_progress = 0 return end
  local near = t.type == "resource" or (C.near_only and C.NEAR[t.type])
  local reach = near and h.resource_reach_distance or h.reach_distance
  if S.dist(h.position, t.position) > reach then h._mine_progress = 0 return end
  local mp = t.prototype.mineable_properties
  local inv = h.inventories[defines.inventory.character_main]
  local prods = mp.products
  if not inv.can_insert{ name = prods[1].name } then return end
  h._mine_progress = h._mine_progress + 0.5 / 60
  if h._mine_progress < mp.mining_time then return end
  h._mine_progress = 0
  for _, p in ipairs(prods) do inv.insert{ name = p.name, count = p.amount } end
  C.mined = (C.mined or 0) + 1
  if t.type == "resource" then
    t.amount = (t.amount or 1) - 1
    if t.amount <= 0 then t.destroy() rawset(h, "selected", nil) end
  else
    t.destroy()
    rawset(h, "selected", nil)
  end
end

--- Прокрутить n тиков: «движок» персонажей, затем S.tick.
function C.run(n)
  for _ = 1, n or 1 do
    for _, s in ipairs(S._surfaces_list) do
      for _, e in ipairs(s._entities) do
        if e.valid and e.type == "character" and rawget(e, "_queue") then
          engine_mine(e)
          engine_craft(e)
        end
      end
    end
    S.tick(1)
  end
end

-- ===================================================================== фейковый path

function C.fake_path()
  local P = { calls = {}, cancels = 0, speed = 1, fail = nil }
  function P.step(task, ctx, goal, dist)
    P.calls[#P.calls + 1] = { x = goal.x, y = goal.y, dist = dist }
    if P.fail then return P.fail end
    local e = ctx.entity
    local p = S.norm_pos(e.position)
    local d = S.dist(p, goal)
    if d <= dist then return true end
    local stepl = math.min(P.speed, d - dist + 0.01)
    S.move(e, { x = p.x + (goal.x - p.x) / d * stepl, y = p.y + (goal.y - p.y) / d * stepl })
    if S.dist(S.norm_pos(e.position), goal) <= dist then return true end
    return nil
  end
  function P.cancel(task, ctx)
    P.cancels = P.cancels + 1
    if ctx.entity and ctx.entity.valid then ctx.entity.walking_state = { walking = false } end
  end
  P.events = {}
  return P
end

-- ===================================================================== мир

--- Мод + хозяин + помощник h1 с инвентарями C. opts.items, opts.size, opts.armor.
function C.setup(opts)
  opts = opts or {}
  C.log = {}
  C.mined = 0
  C.data_destroyed = 0
  C.mining_disabled = false
  C.near_only = true
  C.craft_blocked_when_full = true
  local W = { path = C.fake_path() }
  S.load_mod{ replace = { ["scripts.lib.path"] = W.path } }
  C.prototypes()
  game.get_entity_by_unit_number = function(n)
    for _, s in ipairs(S._surfaces_list) do
      for _, e in ipairs(s._entities) do
        if e.valid and e.unit_number == n then return e end
      end
    end
    return nil
  end
  W.player = S.add_player{ name = "Tartaluga", position = { x = 0, y = 0 } }
  C.recipes(game.forces.player)
  local r = S.req("helper_spawn", {}, "h1")
  S.okr(r)
  W.h = storage.helpers.h1.entity
  C.equip(W.h, opts)
  W.main = W.h.inventories[defines.inventory.character_main]
  W.armor = W.h.inventories[defines.inventory.character_armor]
  C.W = W
  return W
end

--- Сундук своей силы (или force) с предметами.
function C.chest(pos, items, opts)
  opts = opts or {}
  local e = (opts.surface or S.nauvis).create_entity{ name = opts.name or "iron-chest", position = pos, force = opts.force or "player" }
  e.inventories = { [defines.inventory.chest] = C.inventory{ size = opts.size or 32, items = items } }
  return e
end

function C.resource(name, pos, amount)
  local e = S.nauvis.create_entity{ name = name, position = pos, force = "neutral" }
  e.amount = amount or 1000
  return e
end

function C.ground(pos, name, count, opts)
  opts = opts or {}
  local e = S.nauvis.create_entity{ name = "item-on-ground", position = pos, force = opts.force or "neutral" }
  local holder = C.inventory{ size = 1, items = { { name = name, count = count, quality = opts.quality, data = opts.data } } }
  e.stack = holder[1]
  sd(holder[1]).on_empty = function() if e.valid then e.destroy() end end
  return e
end

function C.act(d, args, extra)
  local a = { ["do"] = d, args = args }
  for k, v in pairs(extra or {}) do a[k] = v end
  return S.req("act", a, "h1")
end

function C.events(kind)
  local all = S.okr(S.req("events", { since = 0, limit = 200 })).events
  if kind == nil then return all end
  local out = {}
  for _, e in ipairs(all) do if e.kind == kind then out[#out + 1] = e end end
  return out
end

--- Последний итог задачи job: событие job_done/job_failed (data) и kind.
function C.result(job)
  for _, e in ipairs(C.events()) do
    if (e.kind == "job_done" or e.kind == "job_failed") and e.data.job == job then return e.data, e.kind end
  end
  return nil
end

--- Ждать итога задачи до n тиков; → data, kind.
function C.wait(job, n)
  for _ = 1, n or 6000 do
    C.run(1)
    local d, k = C.result(job)
    if d then return d, k end
  end
  error("задача " .. tostring(job) .. " не завершилась", 2)
end

function C.counts(inv)
  local out = {}
  for _, c in ipairs(inv.get_contents()) do
    local k = c.quality == "normal" and c.name or (c.name .. "@" .. c.quality)
    out[k] = (out[k] or 0) + c.count
  end
  return out
end

return C
