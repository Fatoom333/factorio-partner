-- Заглушки API Factorio 2.0 для юнит-тестов мода (docs/TESTING.md §1). Владелец — поток A.
-- Другие потоки дополняют заглушки только в своих mod/tests/stubs_<поток>.lua, например:
--   local S = require("stubs"); S.add_prototype("entity", {name="burner-mining-drill", type="mining-drill"})
--
-- Как пользоваться (пример — mod/tests/core_dispatch.lua):
--   local S = require("stubs")
--   S.suite("мой модуль", {
--     { "название случая", function()
--         S.load_mod()                                   -- reset + control.lua + on_init
--         local p = S.add_player{ name = "Tartaluga" }   -- игрок с телом на nauvis
--         local r = S.call{ v = 1, id = "a1", op = "hello", args = {} }
--         S.eq(r.ok, true)
--     end },
--   })
-- S.suite сам вызывает S.reset() перед каждым случаем и бросает error() при провалах.
--
-- Полезное для других потоков:
--   S.load_mod{ replace = { ["scripts.lib.path"] = fake } } — подменить модуль мода тестовым;
--   S.req(op, args, helper) / S.call(envelope)            — вызов /partner через JSON-мост;
--   S.okr(resp) -> data, S.err(resp, code)                 — проверки ответа;
--   S.tick(n), S.fire(defines.events.X, data), S.chat(i, text), S.reload{changed=...};
--   S.surface{name=}, S.add_player{...}, S.inventory{...}, surface.create_entity{...}, S.move(e, pos);
--   управление миром: surface.can_place / surface.non_colliding / force.uncharted[S.chunk_key(s, {x,y})] /
--   force.invisible[...] / S.character_can_place / S.craftable[recipe].
--
-- Принципы:
-- * Все фейковые LuaObject (сущности, поверхности, силы, игроки, инвентари) — таблицы с
--   метатаблицей, где __lua_object=true: JSON-мост раннера откажется их сериализовать
--   (ловит утечку LuaEntity в ответ, PROTOCOL §1).
-- * `teleport` и `mine_entity` у фейков бросают ошибку (PROTOCOL §6).
-- * Время идёт только через S.tick(n): game.tick += 1, on_tick, on_nth_tick, затем
--   отложенные on_object_destroyed (как в игре — в конце тика).

local S = {}

S.verbose = rawget(_G, "__fp_verbose") and true or false

-- ===================================================================== утилиты

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

--- Короткая сериализация для сообщений (порядок ключей стабильный).
function S.dump(v, depth, seen)
  if type(depth) ~= "number" then depth = 0 end
  seen = seen or {}
  local tv = type(v)
  if tv == "string" then return string.format("%q", v) end
  if tv ~= "table" then return tostring(v) end
  local mt = getmetatable(v)
  if mt and rawget(mt, "__lua_object") then
    return "<" .. tostring(rawget(v, "object_name") or "LuaObject") .. " " ..
        tostring(rawget(v, "name") or rawget(v, "index") or "") .. ">"
  end
  if seen[v] then return "<cycle>" end
  if depth > 6 then return "{...}" end
  seen[v] = true
  local parts = {}
  local n = #v
  for i = 1, n do parts[#parts + 1] = S.dump(v[i], depth + 1, seen) end
  for _, k in ipairs(sorted_keys(v)) do
    if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
      local ks = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. S.dump(k, depth + 1, seen) .. "]")
      parts[#parts + 1] = ks .. "=" .. S.dump(v[k], depth + 1, seen)
    end
  end
  seen[v] = nil
  return "{" .. table.concat(parts, ", ") .. "}"
end

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
S.deep_eq = deep_eq

function S.copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = S.copy(x) end
  return out
end

-- ===================================================================== проверки

function S.eq(actual, expected, msg)
  if not deep_eq(actual, expected) then
    error((msg and (msg .. ": ") or "") .. "ожидалось " .. S.dump(expected) .. ", получено " .. S.dump(actual), 2)
  end
end

function S.ok(v, msg)
  if not v then error(msg or "ожидалось истинное значение", 2) end
  return v
end

function S.near(a, b, eps, msg)
  eps = eps or 1e-6
  if type(a) ~= "number" or math.abs(a - b) > eps then
    error((msg and (msg .. ": ") or "") .. "ожидалось ≈" .. tostring(b) .. ", получено " .. tostring(a), 2)
  end
end

--- Ожидает ошибку; pattern (необязательно) — подстрока текста ошибки (plain).
function S.raises(fn, pattern, msg)
  local ok, e = pcall(fn)
  if ok then error((msg or "ожидалась ошибка") .. " (ошибки не было)", 2) end
  local text = type(e) == "table" and (tostring(e.code) .. " " .. tostring(e.text)) or tostring(e)
  if pattern and not text:find(pattern, 1, true) then
    error((msg or "не та ошибка") .. ": ждали «" .. pattern .. "», получено «" .. text .. "»", 2)
  end
  return e
end

--- Ответ конверта с ошибкой нужного кода.
function S.err(resp, code, msg)
  if type(resp) ~= "table" or resp.ok ~= false or type(resp.error) ~= "table" or resp.error.code ~= code then
    error((msg and (msg .. ": ") or "") .. "ожидалась ошибка " .. code .. ", ответ " .. S.dump(resp), 2)
  end
  return resp.error
end

--- Успешный ответ конверта; возвращает data.
function S.okr(resp, msg)
  if type(resp) ~= "table" or resp.ok ~= true then
    error((msg and (msg .. ": ") or "") .. "ожидался ok, ответ " .. S.dump(resp), 2)
  end
  return resp.data
end

-- ===================================================================== defines

local EVENT_NAMES = {
  "on_tick", "on_console_chat", "on_console_command", "on_entity_died", "on_post_entity_died",
  "on_entity_damaged", "on_object_destroyed", "on_script_path_request_finished",
  "on_player_mined_entity", "on_pre_player_mined_item", "on_player_mined_item", "on_robot_mined_entity",
  "on_built_entity", "on_robot_built_entity", "script_raised_built", "script_raised_destroy",
  "script_raised_revive", "script_raised_teleported", "on_player_joined_game", "on_player_left_game",
  "on_player_died", "on_player_respawned", "on_player_created", "on_player_removed",
  "on_player_changed_surface", "on_player_changed_position", "on_chunk_charted", "on_chunk_generated",
  "on_runtime_mod_setting_changed", "on_player_crafted_item", "on_pre_player_crafted_item",
  "on_player_cancelled_crafting", "on_character_corpse_expired", "on_marked_for_deconstruction",
  "on_cancelled_deconstruction", "on_player_main_inventory_changed", "on_player_cursor_stack_changed",
  "on_selected_entity_changed", "on_research_finished", "on_surface_created", "on_surface_deleted",
  "on_pre_surface_deleted", "on_ai_command_completed", "on_entity_spawned", "on_sector_scanned",
  "on_trigger_created_entity", "on_picked_up_item", "on_player_used_capsule", "on_pre_build",
  "on_post_entity_died", "on_worker_robot_expired", "on_player_driving_changed_state",
  "on_player_toggled_map_editor", "on_gui_click", "on_string_translated", "on_tick_paused",
}

local function table_size_impl(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function make_events()
  local ev, nextid = {}, 0
  for _, n in ipairs(EVENT_NAMES) do
    if ev[n] == nil then ev[n] = nextid; nextid = nextid + 1 end
  end
  S.unknown_events = {}
  -- Незнакомое имя получает новый номер (чтобы файлы других потоков грузились),
  -- но запоминается в S.unknown_events — тест может это проверить.
  return setmetatable(ev, {
    __index = function(t, k)
      if type(k) ~= "string" then return nil end
      S.unknown_events[k] = true
      local id = 1000 + table_size_impl(S.unknown_events)
      rawset(t, k, id)
      return id
    end,
  })
end

local function make_defines()
  return {
    events = make_events(),
    direction = {
      north = 0, northnortheast = 1, northeast = 2, eastnortheast = 3, east = 4, eastsoutheast = 5,
      southeast = 6, southsoutheast = 7, south = 8, southsouthwest = 9, southwest = 10,
      westsouthwest = 11, west = 12, westnorthwest = 13, northwest = 14, northnorthwest = 15,
    },
    inventory = {
      fuel = 1, burnt_result = 6, chest = 1, character_main = 1, character_guns = 3,
      character_ammo = 4, character_armor = 5, character_vehicle = 7, character_trash = 8,
      character_corpse = 1, item_main = 1, furnace_source = 2, furnace_result = 3,
      assembling_machine_input = 2, assembling_machine_output = 3, roboport_robot = 1,
      roboport_material = 2, car_trunk = 2, spider_trunk = 2,
    },
    build_check_type = {
      script = 0, manual = 1, manual_ghost = 2, script_ghost = 3, blueprint_ghost = 4, ghost_revive = 5,
    },
    build_mode = { normal = 0, forced = 1, superforced = 2 },
    flow_precision_index = {
      five_seconds = 0, one_minute = 1, ten_minutes = 2, one_hour = 3, ten_hours = 4,
      fifty_hours = 5, two_hundred_fifty_hours = 6, one_thousand_hours = 7,
    },
    controllers = { ghost = 0, character = 1, god = 2, editor = 3, cutscene = 4, spectator = 5, remote = 6 },
    target_type = { entity = 1, equipment = 2, equipment_grid = 3, item = 4, player = 5, surface = 6 },
    riding = {
      acceleration = { nothing = 0, accelerating = 1, braking = 2, reversing = 3 },
      direction = { left = 0, straight = 1, right = 2 },
    },
    entity_status = { working = 1, no_power = 2, no_fuel = 3, no_ingredients = 4, no_recipe = 5,
      waiting_for_space_in_destination = 6, no_minable_resources = 7, low_power = 8, disabled = 9 },
    print_skip = { never = 0, if_redundant = 1, if_visible = 2 },
    print_sound = { always = 0, never = 1, use_player_settings = 2 },
    alert_type = { entity_destroyed = 0, entity_under_attack = 1 },
    difficulty = { easy = 0, normal = 1, hard = 2 },
  }
end

-- ===================================================================== прототипы

local function default_prototypes()
  local entity = {
    character = {
      name = "character", type = "character", max_health = 250,
      crafting_categories = { crafting = true },
      mining_categories = { basic_solid = true },
      collision_box = { left_top = { x = -0.2, y = -0.2 }, right_bottom = { x = 0.2, y = 0.2 } },
    },
    ["character-corpse"] = { name = "character-corpse", type = "character-corpse" },
    ["iron-chest"] = { name = "iron-chest", type = "container", max_health = 200 },
    ["wooden-chest"] = { name = "wooden-chest", type = "container", max_health = 100 },
    ["stone-furnace"] = { name = "stone-furnace", type = "furnace", max_health = 200 },
    ["transport-belt"] = { name = "transport-belt", type = "transport-belt", max_health = 150 },
    ["electric-mining-drill"] = { name = "electric-mining-drill", type = "mining-drill", max_health = 300 },
    ["assembling-machine-1"] = { name = "assembling-machine-1", type = "assembling-machine", max_health = 300 },
    ["iron-ore"] = { name = "iron-ore", type = "resource" },
    ["copper-ore"] = { name = "copper-ore", type = "resource" },
    ["coal"] = { name = "coal", type = "resource" },
    ["stone"] = { name = "stone", type = "resource" },
    ["tree-01"] = { name = "tree-01", type = "tree" },
    ["small-biter"] = { name = "small-biter", type = "unit", max_health = 15 },
    ["entity-ghost"] = { name = "entity-ghost", type = "entity-ghost" },
    ["item-on-ground"] = { name = "item-on-ground", type = "item-entity" },
  }
  local item = {}
  for _, n in ipairs({ "iron-plate", "copper-plate", "iron-gear-wheel", "coal", "stone", "iron-ore",
    "copper-ore", "wood", "iron-chest", "wooden-chest", "stone-furnace", "transport-belt",
    "electric-mining-drill", "pipe", "blueprint", "power-armor-mk2", "construction-robot" }) do
    item[n] = { name = n, type = "item", stack_size = 50 }
  end
  item["blueprint"].type = "blueprint"
  item["power-armor-mk2"].type = "armor"
  return {
    entity = entity, item = item, recipe = {}, fluid = {}, tile = {}, quality = { normal = { name = "normal", level = 0 } },
    technology = {}, surface = {}, space_location = {}, mod_setting = {},
  }
end

--- Добавить прототип: S.add_prototype("entity", {name=..., type=...}).
function S.add_prototype(kind, proto)
  prototypes[kind] = prototypes[kind] or {}
  prototypes[kind][proto.name] = proto
  return proto
end

-- ===================================================================== фейковые объекты

-- Методы LuaObject в Factorio вызываются через точку: entity.insert{...}. Заглушка
-- возвращает привязанную функцию; вызов через двоеточие тоже работает.
local function bind(obj, m)
  return function(a, ...)
    if a == obj then return m(obj, ...) end
    return m(obj, a, ...)
  end
end

local function lua_object(object_name, fields, methods)
  local obj = fields
  obj.object_name = object_name
  if obj.valid == nil then obj.valid = true end
  return setmetatable(obj, {
    __lua_object = true,
    __index = function(t, k)
      local m = methods[k]
      if type(m) == "function" then return bind(t, m) end
      return m
    end,
    __tostring = function(o) return "<" .. object_name .. " " .. tostring(rawget(o, "name")) .. ">" end,
  })
end

function S.is_lua_object(v)
  local mt = type(v) == "table" and getmetatable(v)
  return mt and rawget(mt, "__lua_object") and true or false
end

local function norm_pos(p)
  if p == nil then return nil end
  if p.x ~= nil then return { x = p.x, y = p.y } end
  return { x = p[1], y = p[2] }
end
S.norm_pos = norm_pos

local function norm_area(a)
  if a == nil then return nil end
  local lt = a.left_top or a[1]
  local rb = a.right_bottom or a[2]
  return { left_top = norm_pos(lt), right_bottom = norm_pos(rb) }
end
S.norm_area = norm_area

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end
S.dist = dist

-- ---------------------------------------------------------------- инвентарь

local Inventory = {}

local function stack_of(st)
  if type(st) == "string" then return st, 1, "normal" end
  return st.name, st.count or 1, st.quality or "normal"
end

local function inv_key(name, quality)
  if quality == nil or quality == "normal" then return name end
  return name .. "@" .. (type(quality) == "table" and quality.name or quality)
end

function Inventory.get_item_count(self, item)
  if item == nil then
    local n = 0
    for _, c in pairs(self.contents) do n = n + c end
    return n
  end
  local name, quality = item, "normal"
  if type(item) == "table" then name, quality = item.name, item.quality or "normal" end
  return self.contents[inv_key(name, quality)] or 0
end

function Inventory.insert(self, st)
  local name, count, quality = stack_of(st)
  local total = self:get_item_count()
  local room = math.max(0, (self.cap or math.huge) - total)
  local n = math.min(count, room)
  if n > 0 then
    local k = inv_key(name, quality)
    self.contents[k] = (self.contents[k] or 0) + n
  end
  return n
end

function Inventory.can_insert(self, st)
  local _, count = stack_of(st)
  return (self.cap or math.huge) - self:get_item_count() >= 1 and count > 0
end

function Inventory.remove_item(self, st)
  local name, count, quality = stack_of(st)
  local k = inv_key(name, quality)
  local have = self.contents[k] or 0
  local n = math.min(have, count)
  if n > 0 then
    local left = have - n
    self.contents[k] = left > 0 and left or nil
  end
  return n
end

function Inventory.get_contents(self)
  local out = {}
  for _, k in ipairs(sorted_keys(self.contents)) do
    local name, q = k:match("^(.-)@(.+)$")
    out[#out + 1] = { name = name or k, count = self.contents[k], quality = q or "normal" }
  end
  return out
end

function Inventory.is_empty(self) return next(self.contents) == nil end
function Inventory.clear(self) self.contents = {} end
function Inventory.count_empty_stacks(self)
  local used = 0
  for _ in pairs(self.contents) do used = used + 1 end
  return math.max(0, (self.size or 80) - used)
end
function Inventory.get_item_count_filtered(self) return self:get_item_count() end
function Inventory.destroy(self) self.valid = false end
function Inventory.supports_bar() return false end

--- Фейковый LuaInventory: S.inventory{size=80, cap=nil, contents={["iron-plate"]=10}}.
function S.inventory(opts)
  opts = opts or {}
  return lua_object("LuaInventory", {
    size = opts.size or 80, cap = opts.cap, contents = S.copy(opts.contents or {}), index = opts.index,
  }, Inventory)
end

-- ---------------------------------------------------------------- регистрация уничтожений

local function invalidate(obj)
  if not rawget(obj, "valid") then return end
  rawset(obj, "valid", false)
  local reg = S._registrations[obj]
  if reg then
    S._pending_destroyed[#S._pending_destroyed + 1] = {
      registration_number = reg, useful_id = rawget(obj, "unit_number"), type = defines.target_type.entity,
    }
    S._registrations[obj] = nil
  end
end
S.invalidate = invalidate

-- ---------------------------------------------------------------- сущность

local Entity = {}

local function check_valid(self)
  if not rawget(self, "valid") then error("LuaEntity was invalid.", 3) end
end

function Entity.teleport() error("teleport запрещён (PROTOCOL §6.1)", 2) end
function Entity.mine_entity() error("mine_entity запрещён (PROTOCOL §6.5)", 2) end

function Entity.get_main_inventory(self)
  check_valid(self)
  return self.inventories and self.inventories[defines.inventory.character_main]
end

function Entity.get_inventory(self, idx)
  check_valid(self)
  return self.inventories and self.inventories[idx]
end

function Entity.get_item_count(self, item)
  local inv = self:get_main_inventory()
  return inv and inv:get_item_count(item) or 0
end

function Entity.insert(self, st)
  local inv = self:get_main_inventory()
  return inv and inv:insert(st) or 0
end

function Entity.can_insert(self, st)
  local inv = self:get_main_inventory()
  return inv and inv:can_insert(st) or false
end

function Entity.remove_item(self, st)
  local inv = self:get_main_inventory()
  return inv and inv:remove_item(st) or 0
end

function Entity.destroy(self, opts)
  check_valid(self)
  local surf = self.surface
  if opts and opts.raise_destroy then
    S.fire(defines.events.script_raised_destroy, { entity = self })
  end
  if surf then surf:_remove(self) end
  invalidate(self)
  return true
end

function Entity.die(self, force, cause)
  check_valid(self)
  local surf = self.surface
  local pos = norm_pos(self.position)
  S.fire(defines.events.on_entity_died, { entity = self, force = force, cause = cause })
  if not rawget(self, "valid") then return true end -- обработчик мог уничтожить
  local corpses = {}
  if self.type == "character" and surf then
    local corpse = surf.create_entity{ name = "character-corpse", position = pos, force = self.force }
    corpse.character_corpse_tick_of_death = game.tick
    corpse.inventories = { [defines.inventory.character_corpse] = S.inventory() }
    local main = self:get_main_inventory()
    if main then
      for k, c in pairs(main.contents) do corpse.inventories[defines.inventory.character_corpse].contents[k] = c end
      main:clear()
    end
    corpses[1] = corpse
  end
  if surf then surf:_remove(self) end
  local proto = prototypes.entity[self.name] or { name = self.name, type = self.type }
  local unit = self.unit_number
  invalidate(self)
  S.fire(defines.events.on_post_entity_died, {
    position = pos, prototype = proto, unit_number = unit, surface_index = surf and surf.index,
    corpses = corpses, force = force, ghost = nil,
  })
  return true
end

function Entity.begin_crafting(self, params)
  check_valid(self)
  self.crafting_log = self.crafting_log or {}
  local n = params.count or 1
  self.crafting_log[#self.crafting_log + 1] = { recipe = params.recipe, count = n }
  self.crafting_queue_size = (self.crafting_queue_size or 0) + n
  return n
end

function Entity.cancel_crafting(self, params)
  self.crafting_queue_size = math.max(0, (self.crafting_queue_size or 0) - (params.count or 1))
  return true
end

function Entity.get_craftable_count(self, recipe)
  local name = type(recipe) == "table" and recipe.name or recipe
  return (S.craftable and S.craftable[name]) or 0
end

function Entity.can_place_entity(self, params)
  check_valid(self)
  local f = S.character_can_place
  if type(f) == "function" then return f(self, params) end
  if f == nil then return true end
  return f
end

function Entity.can_reach_entity(self, other)
  return dist(self.position, other.position) <= (self.reach_distance or 10)
end

function Entity.get_health_ratio(self)
  local max = self.max_health or 1
  return (self.health or max) / max
end

function Entity.clear_items_inside(self)
  for _, inv in pairs(self.inventories or {}) do inv:clear() end
end

--- Фейковый LuaEntity. Обычно создаётся через surface.create_entity{...}.
function S.entity(surface, opts)
  local proto = prototypes.entity[opts.name] or {}
  S._next_unit = S._next_unit + 1
  local e = {
    name = opts.name,
    type = opts.type or proto.type or opts.name,
    position = norm_pos(opts.position) or { x = 0, y = 0 },
    direction = opts.direction or 0,
    surface = surface,
    force = opts.force and S.force_of(opts.force) or nil,
    unit_number = opts.unit_number or S._next_unit,
    health = opts.health or proto.max_health,
    max_health = proto.max_health,
    quality = { name = "normal", level = 0 },
    prototype = proto,
  }
  if e.type == "character" then
    e.inventories = {
      [defines.inventory.character_main] = S.inventory{ size = 80 },
      [defines.inventory.character_guns] = S.inventory{ size = 3 },
      [defines.inventory.character_ammo] = S.inventory{ size = 3 },
      [defines.inventory.character_armor] = S.inventory{ size = 1 },
      [defines.inventory.character_trash] = S.inventory{ size = 10 },
    }
    e.walking_state = { walking = false, direction = defines.direction.north }
    e.mining_state = { mining = false }
    e.reach_distance = 10
    e.build_distance = 10
    e.resource_reach_distance = 2.7
    e.item_pickup_distance = 1
    e.loot_pickup_distance = 2
    e.crafting_queue_size = 0
    e.crafting_queue_progress = 0
    e.character_running_speed = 0.15
    e.health = opts.health or 250
    e.max_health = 250
  end
  for k, v in pairs(opts.fields or {}) do e[k] = v end
  return lua_object("LuaEntity", e, Entity)
end

--- Сдвинуть сущность (замена ходьбы в тестах; телепорта в моде нет).
function S.move(entity, pos)
  entity.position = norm_pos(pos)
end

-- ---------------------------------------------------------------- поверхность

local Surface = {}

function Surface._remove(self, e)
  for i, x in ipairs(self._entities) do
    if x == e then table.remove(self._entities, i) return end
  end
end

function Surface.create_entity(self, params)
  local e = S.entity(self, params)
  self._entities[#self._entities + 1] = e
  self.created = self.created or {}
  self.created[#self.created + 1] = params
  if params.raise_built then
    S.fire(defines.events.script_raised_built, { entity = e })
  end
  return e
end

local function match_filter_value(v, want)
  if want == nil then return true end
  if type(want) == "table" and not S.is_lua_object(want) then
    for _, w in ipairs(want) do if match_filter_value(v, w) then return true end end
    return false
  end
  return v == want
end

local function force_name(f)
  if f == nil then return nil end
  if type(f) == "string" then return f end
  return f.name
end

local function in_area(p, a)
  return p.x >= a.left_top.x and p.x <= a.right_bottom.x and p.y >= a.left_top.y and p.y <= a.right_bottom.y
end

function Surface.find_entities_filtered(self, f)
  f = f or {}
  local area = norm_area(f.area)
  local pos = norm_pos(f.position)
  local forces
  if f.force then
    forces = {}
    local list = (type(f.force) == "table" and not S.is_lua_object(f.force)) and f.force or { f.force }
    for _, x in ipairs(list) do forces[#forces + 1] = force_name(x) end
  end
  local out = {}
  for _, e in ipairs(self._entities) do
    local ok = rawget(e, "valid")
    if ok and area then ok = in_area(e.position, area) end
    if ok and pos then
      local r = f.radius or 0.5
      ok = dist(e.position, pos) <= r
    end
    if ok and f.name then ok = match_filter_value(e.name, f.name) end
    if ok and f.type then ok = match_filter_value(e.type, f.type) end
    if ok and forces then ok = match_filter_value(force_name(e.force), forces) end
    if f.invert then ok = not ok and rawget(e, "valid") end
    if ok then
      out[#out + 1] = e
      if f.limit and #out >= f.limit then break end
    end
  end
  return out
end

function Surface.count_entities_filtered(self, f)
  return #self:find_entities_filtered(f)
end

function Surface.find_entity(self, name, position)
  local p = norm_pos(position)
  for _, e in ipairs(self._entities) do
    if e.valid and e.name == name and dist(e.position, p) < 0.5 then return e end
  end
  return nil
end

--- По умолчанию возвращает center; S.non_colliding = function(surface, name, center, radius) | false.
function Surface.find_non_colliding_position(self, name, center, radius, precision)
  local f = self.non_colliding
  if f == false then return nil end
  if type(f) == "function" then return f(self, name, norm_pos(center), radius, precision) end
  return norm_pos(center)
end

function Surface.can_place_entity(self, params)
  local f = self.can_place
  if type(f) == "function" then return f(self, params) end
  if f == nil then return true end
  return f
end

function Surface.is_chunk_generated(self, chunk)
  local c = norm_pos(chunk)
  return not (self.ungenerated and self.ungenerated[c.x .. "," .. c.y])
end

function Surface.request_path(self, params)
  S._next_path = S._next_path + 1
  self.path_requests = self.path_requests or {}
  self.path_requests[S._next_path] = params
  return S._next_path
end

function Surface.get_tile(self, x, y)
  if type(x) == "table" then x, y = x.x or x[1], x.y or x[2] end
  local name = (self.tiles and self.tiles[math.floor(x) .. "," .. math.floor(y)]) or "grass-1"
  return { name = name, position = { x = math.floor(x), y = math.floor(y) }, valid = true }
end

function Surface.find_tiles_filtered() return {} end

function Surface.spill_item_stack() return {} end

--- Фейковая поверхность: S.surface{name="vulcanus"} (index назначается сам).
function S.surface(opts)
  opts = opts or {}
  local index = opts.index or (#S._surfaces_list + 1)
  local s = lua_object("LuaSurface", { name = opts.name or ("surface-" .. index), index = index, _entities = {} }, Surface)
  S._surfaces_list[#S._surfaces_list + 1] = s
  rawset(game.surfaces, s.name, s)
  return s
end

-- ---------------------------------------------------------------- сила

local Force = {}

local function chunk_key(surface, chunk)
  local c = norm_pos(chunk)
  return (type(surface) == "table" and surface.name or tostring(surface)) .. ":" .. c.x .. "," .. c.y
end
S.chunk_key = chunk_key

--- По умолчанию все чанки открыты и видимы; force.uncharted[key]/force.invisible[key] = true (key = S.chunk_key).
function Force.is_chunk_charted(self, surface, chunk)
  return not self.uncharted[chunk_key(surface, chunk)]
end

function Force.is_chunk_visible(self, surface, chunk)
  return self:is_chunk_charted(surface, chunk) and not self.invisible[chunk_key(surface, chunk)]
end

function Force.chart(self, surface, area)
  self.charted_log[#self.charted_log + 1] = { surface = type(surface) == "table" and surface.name or surface, area = norm_area(area) }
end

--- Объект игры в заглушке: методы в метатаблице, как у LuaObject (в storage класть можно).
local GameObject = { __index = function(t, k)
  if k == "destroy" then return function() rawset(t, "valid", false) end end -- obj.destroy(), как в игре
end }
function S.game_object(fields)
  fields.valid = true
  return setmetatable(fields, GameObject)
end

--- Метка на карте силы (nameplate).
function Force.add_chart_tag(self, surface, t)
  return S.game_object{ surface = surface, position = { x = t.position.x, y = t.position.y }, text = t.text }
end

function Force.get_spawn_position(self, surface)
  local s = type(surface) == "table" and surface.name or surface
  return S.copy(self.spawn[s] or { x = 0, y = 0 })
end

function Force.set_spawn_position(self, pos, surface)
  local s = type(surface) == "table" and surface.name or surface
  self.spawn[s] = norm_pos(pos)
end

function S.force(opts)
  opts = opts or {}
  local index = #S._forces_list + 1
  local f = lua_object("LuaForce", {
    name = opts.name, index = index, uncharted = {}, invisible = {}, charted_log = {}, spawn = {},
    recipes = {}, players = {}, character_reach_distance_bonus = 0, character_build_distance_bonus = 0,
    character_resource_reach_distance_bonus = 0, character_item_pickup_distance_bonus = 0,
  }, Force)
  S._forces_list[index] = f
  rawset(game.forces, f.name, f)
  return f
end

function S.force_of(f)
  if type(f) == "string" then return game.forces[f] or S.force{ name = f } end
  return f
end

-- ---------------------------------------------------------------- игрок

local Player = {}
local PlayerDynamic = {
  physical_position = function(p) return p.character and p.character.valid and norm_pos(p.character.position) or norm_pos(p.position) end,
  physical_surface = function(p) return p.character and p.character.valid and p.character.surface or p.surface end,
}

function Player.print(self, msg) self.printed[#self.printed + 1] = msg end
function Player.mine_entity() error("mine_entity запрещён", 2) end
function Player.teleport() error("teleport запрещён", 2) end

--- Игрок: S.add_player{name="Tartaluga", connected=true, surface=..., position={x,y}, character=true|false}.
function S.add_player(opts)
  opts = opts or {}
  local index = opts.index or (#S._players_list + 1)
  local surface = opts.surface or game.surfaces["nauvis"]
  local force = S.force_of(opts.force or "player")
  local p = {
    index = index, name = opts.name or ("player" .. index), connected = opts.connected ~= false,
    surface = surface, position = norm_pos(opts.position) or { x = 0, y = 0 }, force = force,
    printed = {}, selected = opts.selected, admin = opts.admin or false, valid = true,
    object_name = "LuaPlayer",
  }
  setmetatable(p, {
    __lua_object = true,
    __index = function(t, k)
      local d = PlayerDynamic[k]
      if d then return d(t) end
      local m = Player[k]
      if type(m) == "function" then return bind(t, m) end
      return m
    end,
  })
  if opts.character ~= false then
    local ch = surface.create_entity{ name = "character", position = p.position, force = force }
    ch.player = p
    p.character = ch
  end
  S._players_list[index] = p
  rawset(game.players, index, p)
  force.players[#force.players + 1] = p
  return p
end

-- ===================================================================== глобальные заглушки

local function make_game()
  local g = {
    tick = 0, ticks_played = 0, tick_paused = false, speed = 1,
    printed = {},
  }
  -- Как LuaCustomTable: players перебираются по индексу (доступ и по имени),
  -- surfaces/forces — по имени (доступ и по индексу).
  local function alt_lookup(field)
    return setmetatable({}, { __index = function(t, k)
      for _, v in pairs(t) do if v[field] == k then return v end end
      return nil
    end })
  end
  g.players = alt_lookup("name")
  g.surfaces = alt_lookup("index")
  g.forces = alt_lookup("index")
  function g.get_player(x)
    local p = g.players[x]
    return p
  end
  function g.get_surface(x) return g.surfaces[x] end
  function g.print(msg, opts) g.printed[#g.printed + 1] = msg end
  function g.is_multiplayer() return false end
  function g.create_inventory(size) return S.inventory{ size = size } end
  return setmetatable(g, {
    __index = function(t, k)
      if k == "connected_players" then
        local out = {}
        for _, p in ipairs(S._players_list) do if p.connected then out[#out + 1] = p end end
        return out
      end
      return nil
    end,
  })
end

local function make_script()
  local sc = {
    mod_name = "factorio-partner",
    active_mods = { base = "2.0.77", ["factorio-partner"] = "0.4.1" },
    level = { level_name = "test", mod_name = nil },
  }
  function sc.on_event(ev, fn, filters)
    local list = type(ev) == "table" and ev or { ev }
    for _, id in ipairs(list) do
      if id == nil then error("script.on_event: id события nil", 2) end
      if fn == nil then S.handlers[id] = nil
      else S.handlers[id] = { fn = fn, filters = filters } end
    end
  end
  function sc.on_nth_tick(n, fn)
    if n == nil then S.nth = {} return end
    local list = type(n) == "table" and n or { n }
    for _, k in ipairs(list) do
      if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then error("on_nth_tick: n должно быть целым ≥ 1", 2) end
      S.nth[k] = fn
    end
  end
  function sc.on_init(fn) S.lifecycle.on_init = fn end
  function sc.on_load(fn) S.lifecycle.on_load = fn end
  function sc.on_configuration_changed(fn) S.lifecycle.on_configuration_changed = fn end
  function sc.register_on_object_destroyed(obj)
    if not S.is_lua_object(obj) then error("register_on_object_destroyed: не LuaObject", 2) end
    local reg = S._registrations[obj]
    if not reg then
      S._next_reg = S._next_reg + 1
      reg = S._next_reg
      S._registrations[obj] = reg
    end
    return reg, rawget(obj, "unit_number") or 0, defines.target_type.entity
  end
  function sc.raise_event(id, data)
    local e = S.copy(data or {})
    S.fire(id, e)
  end
  function sc.generate_event_name()
    S._next_custom = S._next_custom + 1
    return 5000 + S._next_custom
  end
  function sc.get_event_handler(id)
    local h = S.handlers[id]
    return h and h.fn
  end
  return sc
end

local function make_helpers()
  return {
    table_to_json = function(t)
      if type(t) ~= "table" then error("table_to_json: ожидалась таблица", 2) end
      local ok, res = pcall(__py_table_to_json, t)
      if not ok then error(tostring(res), 2) end
      return res
    end,
    json_to_table = function(s)
      if type(s) ~= "string" then return nil end
      return __py_json_to_table(s)
    end,
    is_valid_sound_path = function() return true end,
    is_valid_sprite_path = function() return true end,
    send_udp = function() error("helpers.send_udp вешает игру на 11 с — не использовать", 2) end,
    write_file = function() error("helpers.write_file не используется ядром", 2) end,
  }
end

-- ===================================================================== события и время

local function filter_target(e)
  return e.entity or e.created_entity or e.prototype
end

local function match_one(f, obj)
  if obj == nil then return true end
  local m
  if f.filter == "type" then m = match_filter_value(obj.type, f.type)
  elseif f.filter == "name" then m = match_filter_value(obj.name, f.name)
  elseif f.filter == "ghost" then m = obj.type == "entity-ghost"
  else m = true end
  if f.invert then m = not m end
  return m
end

--- Применяет EventFilter (type/name/ghost, mode="and"/"or", invert) как игра.
function S.match_filters(filters, e)
  if filters == nil or #filters == 0 then return true end
  local obj = filter_target(e)
  local res
  for i, f in ipairs(filters) do
    local m = match_one(f, obj)
    if i == 1 then res = m
    elseif f.mode == "and" then res = res and m
    else res = res or m end
  end
  return res
end

--- Вызвать обработчик события (как игра): e.name, e.tick заполняются; фильтр применяется.
function S.fire(id, data)
  local h = S.handlers[id]
  data = data or {}
  data.name = id
  data.tick = game.tick
  if not h then return false end
  if not S.match_filters(h.filters, data) then return false end
  h.fn(data)
  return true
end

function S.flush_destroyed()
  local list = S._pending_destroyed
  S._pending_destroyed = {}
  for _, ev in ipairs(list) do S.fire(defines.events.on_object_destroyed, ev) end
end

--- Прокрутить n тиков (по умолчанию 1).
function S.tick(n)
  for _ = 1, (n or 1) do
    game.tick = game.tick + 1
    game.ticks_played = game.tick
    S.fire(defines.events.on_tick, {})
    for k, fn in pairs(S.nth) do
      if game.tick % k == 0 then fn({ tick = game.tick, nth_tick = k }) end
    end
    S.flush_destroyed()
  end
end

-- ===================================================================== команды и RCON

--- Вызвать /partner как из RCON; возвращает строку ответа (или nil, если мод ничего не напечатал).
function S.rcon(parameter)
  local cmd = S.commands["partner"]
  if not cmd then error("команда /partner не зарегистрирована", 2) end
  local before = #S.rcon_out
  cmd.fn({ name = "partner", tick = game.tick, player_index = nil, parameter = parameter })
  local n = #S.rcon_out - before
  if n == 0 then return nil end
  if n ~= 1 then error("мод напечатал в RCON " .. n .. " строк, а надо одну (PROTOCOL §1)", 2) end
  return S.rcon_out[#S.rcon_out]
end

--- Конверт (Lua-таблица) -> ответ (Lua-таблица), через настоящий JSON-мост.
function S.call(env)
  local line = S.rcon(helpers.table_to_json(env))
  if line == nil then error("мод не ответил в RCON", 2) end
  if line:find("\n", 1, true) then error("в ответе перевод строки (PROTOCOL §1)", 2) end
  local t = helpers.json_to_table(line)
  if type(t) ~= "table" then error("ответ не JSON: " .. line, 2) end
  return t, line
end

--- Короткая форма: S.req("act", {do="wait", args={seconds=1}}, "h1") — id генерируется сам.
function S.req(op, args, helper, id)
  S._next_req = S._next_req + 1
  local t = S.call{ v = 1, id = id or ("t-" .. S._next_req), op = op, helper = helper, args = args or {} }
  return t
end

--- /partner из чата игрока.
function S.chat_command(player_index, parameter)
  local cmd = S.commands["partner"]
  local before = #S.rcon_out
  cmd.fn({ name = "partner", tick = game.tick, player_index = player_index, parameter = parameter })
  return #S.rcon_out - before
end

--- Сообщение игрока в чат (on_console_chat).
function S.chat(player_index, message)
  return S.fire(defines.events.on_console_chat, { player_index = player_index, message = message })
end

function S.set_setting(name, value)
  settings.global[name] = { value = value }
  S.fire(defines.events.on_runtime_mod_setting_changed, { setting = name, setting_type = "runtime-global" })
end

-- ===================================================================== сброс и загрузка мода

--- Свежий «мир»: глобалы game/storage/defines/... и поверхность nauvis, силы player/enemy/neutral.
function S.reset()
  S.handlers = {}
  S.nth = {}
  S.lifecycle = {}
  S.commands = {}
  S.rcon_out = {}
  S.logs = {}
  S._registrations = setmetatable({}, { __mode = "k" })
  S._pending_destroyed = {}
  S._next_unit = 100
  S._next_reg = 0
  S._next_path = 0
  S._next_custom = 0
  S._next_req = 0
  S._surfaces_list = {}
  S._forces_list = {}
  S._players_list = {}
  S.craftable = {}
  S.character_can_place = nil

  _G.defines = make_defines()
  _G.prototypes = default_prototypes()
  _G.game = make_game()
  _G.storage = {}
  _G.script = make_script()
  _G.commands = {
    commands = {},
    game_commands = {},
    add_command = function(name, help, fn)
      if S.commands[name] then error("команда " .. name .. " уже есть", 2) end
      if type(fn) ~= "function" then error("add_command: нет функции", 2) end
      S.commands[name] = { help = help, fn = fn }
      commands.commands[name] = help
    end,
    remove_command = function(name) S.commands[name] = nil return true end,
  }
  _G.rcon = {
    print = function(s)
      if type(s) ~= "string" then error("rcon.print: ожидалась строка", 2) end
      S.rcon_out[#S.rcon_out + 1] = s
    end,
  }
  _G.helpers = make_helpers()
  _G.serpent = {
    line = function(v) return S.dump(v) end,
    block = function(v) return S.dump(v) end,
    dump = function(v) return S.dump(v) end,
  }
  _G.log = function(s) S.logs[#S.logs + 1] = tostring(s) end
  _G.localised_print = function(s) S.logs[#S.logs + 1] = tostring(s) end
  _G.table_size = table_size_impl
  _G.settings = {
    global = { ["partner-owner"] = { value = "" } },
    startup = {},
    player = {},
  }
  _G.remote = {
    interfaces = {},
    add_interface = function(name, fns) remote.interfaces[name] = fns end,
    remove_interface = function(name) remote.interfaces[name] = nil end,
    call = function(name, fn, ...)
      local i = remote.interfaces[name]
      if not i or not i[fn] then error("нет remote-интерфейса " .. tostring(name) .. "." .. tostring(fn), 2) end
      return i[fn](...)
    end,
  }
  _G.rendering = setmetatable({}, { __index = function() return function() return nil end end })

  for _, n in ipairs({ "player", "enemy", "neutral" }) do S.force{ name = n } end
  S.nauvis = S.surface{ name = "nauvis" }
end

local function unload_mod_modules()
  for k in pairs(package.loaded) do
    if type(k) == "string" and (k:find("^scripts%.") or k == "control") then package.loaded[k] = nil end
  end
end

local function load_control(replace)
  unload_mod_modules()
  -- подмена модулей мода тестовыми: { ["scripts.reflexes.flee"] = M, ... }
  for k, v in pairs(replace or {}) do package.loaded[k] = v end
  local env = __fp_test_env
  local src = env.read(env.mod_dir .. "/control.lua")
  local fn, e = load(src, "@__" .. env.mod_name .. "__/control.lua", "t")
  if not fn then error(e, 2) end
  fn()
end

--- Загрузить мод как новую игру: S.reset() (если opts.reset ~= false), control.lua, on_init.
--- opts.replace = { ["scripts.perception.state"] = M } — подменить модули тестовыми.
--- opts.init = false — не вызывать on_init.
function S.load_mod(opts)
  opts = opts or {}
  if opts.reset ~= false then S.reset() end
  S._replace = opts.replace
  load_control(opts.replace)
  if opts.init ~= false and S.lifecycle.on_init then S.lifecycle.on_init() end
end

--- Сохранение/загрузка: storage сохраняется (глубокая копия без функций), регистрации и
--- обработчики пропадают, control.lua грузится заново, вызывается on_load.
--- opts.changed = ConfigurationChangedData → вместо on_load вызывается on_configuration_changed.
function S.reload(opts)
  opts = opts or {}
  local saved = storage
  local function check(v, path, seen)
    if type(v) == "function" then error("в storage функция: " .. path, 3) end
    if type(v) == "table" and not S.is_lua_object(v) and not seen[v] then
      seen[v] = true
      for k, x in pairs(v) do check(x, path .. "." .. tostring(k), seen) end
    end
  end
  check(saved, "storage", {})
  S.handlers = {}
  S.nth = {}
  S.lifecycle = {}
  S.commands = {}
  commands.commands = {}
  _G.storage = saved
  load_control(opts.replace or S._replace)
  if opts.changed then
    if S.lifecycle.on_configuration_changed then S.lifecycle.on_configuration_changed(opts.changed) end
  elseif S.lifecycle.on_load then
    S.lifecycle.on_load()
  end
end

-- ===================================================================== набор тестов

--- S.suite(имя, { {"случай", fn}, ... }) — каждый случай на свежем S.reset().
--- Ошибка любого случая → в конце error() со списком.
function S.suite(name, cases)
  local failed = {}
  for _, c in ipairs(cases) do
    S.reset()
    local ok, e = xpcall(c[2], debug.traceback)
    if ok then
      if S.verbose then print("  ok   " .. name .. " / " .. c[1]) end
    else
      failed[#failed + 1] = c[1]
      print("  FAIL " .. name .. " / " .. c[1] .. "\n" .. tostring(e))
      if #S.logs > 0 then print("  log:\n    " .. table.concat(S.logs, "\n    ")) end
    end
  end
  if #failed > 0 then
    error(name .. ": провалено " .. #failed .. " из " .. #cases .. ": " .. table.concat(failed, "; "), 0)
  end
  if S.verbose then print("  " .. name .. ": " .. #cases .. " ok") end
end

return S
