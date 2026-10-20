-- Рефлекс `evacuate` — разобрать постройки области, пока к ней идут враги, и поставить их обратно,
-- когда станет тихо. Контракт: docs/EVENTS.md (evacuate_started, evacuated, evacuate_missing,
-- evacuate_restored, reflex_resumed), docs/ACTIONS.md (deconstruct, place, insert, walk),
-- PROTOCOL.md §6.5 (только честная игра), §6.7 (живое — только видимое), §6.11 (качество).
--
--   evacuate { area:{left_top, right_bottom} (сторона ≤ 128) │ center:{x, y} + radius (1..64),
--              names?:[имя постройки] (≤ 32; только эти, в этом порядке), threat_radius?=40 (10..120),
--              return_after_s?=180 (30..1800), rebuild?=true }
--   Один на помощника. Включить или сменить при hold хозяина нельзя (owner_hold); убрать или сменить
--   область, пока идёт эвакуация или постройки в карманах ждут возврата (фаза не watch), — bad_args.
--   Включить или сменить область запросом агента можно, только если центр области не дальше MAX_DIST
--   клеток от тела (too_far с расстоянием). Кнопка «Охранять здесь» в окне хозяина (M.owner_guard) —
--   слово хозяина: без этого предела, без hold, «спросить» не нужно, «нельзя» всё равно запрещает.
--
-- * Снимок. При включении (и при смене области или names) мод запоминает постройки своей силы в
--   области: имя, предмет, позиция, направление, вход/выход подземной ленты и погрузчика, рецепт
--   (сборочные машины), качество, модули внутри (с качеством) и настройки, которые игрок может
--   скопировать (Shift+ПКМ/ЛКМ) или унести чертежом: фильтры и режим фильтра манипуляторов и
--   погрузчиков, приоритеты и фильтр разделителей, логистические секции сундуков-запросчиков и буферов,
--   параметры комбинаторов, условия цепей, ограничение сундука, качество рецепта, провода (красный,
--   зелёный, медный — к каким постройкам и разъёмам, в том числе к себе же).
--   Без предмета для постановки, некопаемое, техника с водителем и персонажи в снимок не идут.
--   Больше MAX_ENTITIES — отказ limit. Снимок — простые таблицы в storage.evacuate[helper], сейв он
--   переживает.
-- * Угроза — враг силы, враждебной силе тела (кусаки, пентаподы, разрушитель и его сегменты; черви
--   стоят на месте, гнёзда сами не ходят — не угроза), ближе threat_radius к краю области и видимый
--   помощнику. Любой такой враг считается, в том числе кусаки, что стоят у своего гнезда: у гнёзд
--   threat_radius берут меньше. Пока всё спокойно, проверка — раз в WATCH_EVERY тиков, во время
--   эвакуации и возврата — раз в 10; сначала дешёвый подсчёт (count_entities_filtered), список
--   враждебных сил — из storage, раз в FORCES_EVERY.
-- * Эвакуация. Задачи тела снимаются (как у flee: что было, запоминается для возврата; если
--   перед этим уже было отступление flee и его возврат к делу ещё ждёт, эвакуация забирает его себе),
--   тело обычными задачами `deconstruct` (req "reflex:evacuate") подходит и разбирает постройки
--   снимка — ценные первыми (порядок names, иначе машины и буры, потом турели и энергия, сундуки,
--   манипуляторы, трубы, ленты, столбы). Не трогаются (kept): постройки, разбор которых хозяин
--   теперь запретил (perms «нельзя»), и сундуки с содержимым (оно не влезет в карманы). Постройки,
--   которой уже нет, — lost; если её взял другой помощник (она у него в storage.evacuate как taken
--   или его задача разбора её ждёт) — молча пропускается: области двух помощников могут пересекаться,
--   каждый возвращает своё. После — отступление обычной ходьбой прочь от врага (точки — как у flee).
--   Идёт и при hold хозяина: это защита, как flee. Пока идёт отступление flee, разбор ждёт; flee
--   прервал разбор больше MAX_FLEE_CUTS раз — враг уже у построек, эвакуация кончается (reason
--   "threatened"), остальное — left. Агент снял задачи разбора сам — эвакуация кончается (reason
--   "cancelled", его дело он решает сам; "owner_stop" — их снял «стоп» хозяина).
-- * Возврат. Врага нет return_after_s подряд, hold нет → (rebuild) задачи `place` по снимку из
--   карманов (рецепт и качество — тем же place), модули — задачами `insert` (по качеству). Ставится
--   только то, что разобрало это тело (taken); разрушенное (lost) не ставится и не просится. Карманы
--   считаются по (имя, качество): чего нет — evacuate_missing{items} (ключ "имя" или "имя@качество").
--   Стройку хозяин запретил (build «нельзя») — ничего не ставится, всё в left. Настройки снимка
--   мод возвращает поставленной постройке сам, провода — когда весь возврат кончился и обе постройки
--   стоят (вернул или не трогал); провод к постройке, которой больше нет, и настройка, которую движок
--   не принял, — постройка в reset (почему — reset_why). «Стоп» хозяина посреди возврата — возврат ждёт
--   его слова и потом продолжается с того, что осталось. Потом снятые задачи ставятся снова:
--   reflex_resumed{type:"evacuate"} (как после flee: агент поставил своё — возврат молча отменяется;
--   hold — reason "owner_hold"). Враг снова у области во время возврата — задачи постановки
--   снимаются, эвакуация заново.
-- * Снять охрану кнопкой хозяина (M.owner_unguard): в фазе watch рефлекс уходит из набора сразу;
--   иначе — после возврата (идущий разбор кончается reason "unguarded", новых эвакуаций до того нет,
--   разобранное не бросается в карманах), итог evacuate_restored несёт off:true.
-- * События (громкие): evacuate_started{area, threat:{name, pos, dist}},
--   evacuated{taken, lost, left?, kept?, reason?}, evacuate_missing{items},
--   evacuate_restored{placed, missing, failed?, left?, reset?, reset_why?, off?, reason?};
--   taken/lost/left/kept/placed/failed/reset — {имя постройки = число}, missing/items —
--   {ключ предмета = число}, reset_why — {имя постройки = [причина]} ("wire_to_gone", "wire",
--   "settings", "modules", "lossy"). left в evacuate_restored — что осталось в карманах; reason "dropped" —
--   снимок забыт (рефлекс убрали, сменили область в спокойной фазе, удалили помощника), а
--   разобранное осталось в карманах; "owner_forbids" — стройку запретил хозяин.
-- * Разрешения хозяина — при включении (scripts/core/reflexes.lua def.perms): разбор построек
--   снимка (deconstruct-owner — поставленных игроком, deconstruct-own — своих) и, при rebuild, build;
--   в начале каждой эвакуации и возврата «нельзя» проверяется снова. Сами задачи — свои вызовы мода,
--   мимо гейта.
local util = require("scripts.core.util")
local err = require("scripts.core.err")
local events = require("scripts.core.events")
local jobs = require("scripts.core.jobs")
local perms = require("scripts.core.perms")
local reflexes = require("scripts.core.reflexes")
local vis = require("scripts.core.vis")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")
local C = require("scripts.reflexes.common")
local flee = require("scripts.reflexes.flee")

local M = {}
M.name = "reflexes.evacuate"

M.REQ = "reflex:evacuate"      -- req задач разбора, постановки и отступления (виден в `jobs`)
M.RESUME_REQ = "resume:evacuate"
M.MAX_ENTITIES = 200           -- построек в снимке
M.MAX_RADIUS = 64
M.MAX_SIDE = 128
M.MAX_NAMES = 32
M.MAX_DIST = 150               -- центр области от тела, когда evacuate включает агент
M.GUARD_RADIUS = 50            -- кнопка хозяина: радиус по умолчанию и его границы
M.GUARD_MIN, M.GUARD_MAX = 8, 64
M.BATCH = 8                    -- своих задач в очереди тела одновременно
M.MAX_FAILS = 2                -- столько раз не разобралась — дальше не пробуем
M.MAX_FLEE_CUTS = 3            -- столько раз flee прервал разбор — дальше не лезем к врагу
M.RETREAT = 40                 -- на сколько клеток отступать от врага
M.GOAL_RADIUS = 2
M.RESUME_MAX = 4
M.SCAN = 200                   -- событий за один просмотр буфера
M.WATCH_EVERY = 60             -- тиков между проверками угрозы, пока всё спокойно
M.FORCES_EVERY = 3600          -- тиков между пересчётами враждебных сил
M.MAX_WIRES = 64               -- проводов одной постройки в снимке
M.MAX_FILTERS = 64             -- ячеек фильтра одной постройки в снимке
M.THREAT_TYPES = { "unit", "spider-unit", "segmented-unit", "segment" }

-- Ценность постройки по типу: меньше — разбирается раньше.
M.RANK = {
  ["mining-drill"] = 1, ["assembling-machine"] = 1, furnace = 1, lab = 1, beacon = 1, ["rocket-silo"] = 1,
  roboport = 1, reactor = 1, ["fusion-reactor"] = 1, ["fusion-generator"] = 1, ["agricultural-tower"] = 1,
  ["ammo-turret"] = 2, ["electric-turret"] = 2, ["fluid-turret"] = 2, ["artillery-turret"] = 2,
  boiler = 2, generator = 2, ["solar-panel"] = 2, accumulator = 2, radar = 2, ["offshore-pump"] = 2,
  pump = 2, ["storage-tank"] = 2,
  container = 3, ["logistic-container"] = 3,
  inserter = 4,
  pipe = 5, ["pipe-to-ground"] = 5,
  ["transport-belt"] = 6, ["underground-belt"] = 6, splitter = 6, loader = 6, ["loader-1x1"] = 6,
  ["electric-pole"] = 7, wall = 7, gate = 7, lamp = 7,
}
M.RANK_OTHER = 4

local CONTAINERS = { container = true, ["logistic-container"] = true }
-- постройки, чьи настройки мод не переносит (текст, звук): возвращаются без них, reset "lossy"
-- (и прочие, чьи настройки снимок не знает: имя и лимит станции, сигналы роботопорта и семафоров,
-- бесконечные сундуки и трубы, посадочная площадка и хаб платформы)
local LOSSY_TYPES = {
  ["programmable-speaker"] = true, ["display-panel"] = true, ["train-stop"] = true, roboport = true,
  ["rail-signal"] = true, ["rail-chain-signal"] = true, ["infinity-container"] = true, ["infinity-pipe"] = true,
  ["cargo-landing-pad"] = true, ["space-platform-hub"] = true,
}
-- вход/выход: create_entity{type=...} (place args.type)
local IO_TYPES = { ["underground-belt"] = "belt_to_ground_type", loader = "loader_type", ["loader-1x1"] = "loader_type" }

-- настройки постройки (свойства LuaEntity) по типу, в порядке записи
local ENTITY_PROPS = {
  inserter = { "use_filters", "inserter_filter_mode", "inserter_stack_size_override", "inserter_spoil_priority" },
  loader = { "use_filters", "loader_filter_mode" },
  ["loader-1x1"] = { "use_filters", "loader_filter_mode" },
  splitter = { "splitter_input_priority", "splitter_output_priority" },
  ["lane-splitter"] = { "splitter_input_priority", "splitter_output_priority" },
  ["logistic-container"] = { "request_from_buffers" },
  ["power-switch"] = { "power_switch_state" },
}
local FILTER_TYPES = { inserter = true, loader = true, ["loader-1x1"] = true }
local SPLITTERS = { splitter = true, ["lane-splitter"] = true }
-- комбинаторы: весь смысл — в parameters
local COMBINATORS = { ["arithmetic-combinator"] = true, ["decider-combinator"] = true, ["selector-combinator"] = true }
-- условия и режимы цепей обычных построек (LuaGenericOnOffControlBehavior и наследники); что у
-- постройки не бывает, движок не даёт прочесть — такое поле не попадает в снимок
local CB_PROPS = {
  "circuit_enable_disable", "circuit_condition", "connect_to_logistic_network", "logistic_condition",
  "circuit_set_filters", "circuit_read_hand_contents", "circuit_hand_read_mode", "circuit_set_stack_size",
  "circuit_stack_control_signal", "read_contents", "read_contents_mode", "circuit_read_resources",
  "resource_read_mode", "circuit_set_recipe", "circuit_read_contents", "include_in_crafting", "include_fuel",
  "circuit_read_ingredients", "circuit_read_recipe_finished", "circuit_recipe_finished_signal",
  "circuit_read_working", "circuit_working_signal", "use_colors", "color_mode", "output_signal",
}

-- ------------------------------------------------------------------ состояние

--- storage.evacuate[helper] = { key, surface, box, list = {запись снимка, ...}, phase, ... }
--- запись снимка: { name, item, count, pos, dir, io?, unit, quality, recipe?, modules?, settings?,
---                  wires?, lossy?, rank, state, fails, cuts, kept? }
--- modules — {ключ предмета = число} (inv.qkey: "имя" │ "имя@качество").
--- state: "present" (стоит) │ "taken" (разобрал это тело, в карманах) │ "lost" (уничтожена до разбора)
---        │ "other" (её взял другой помощник — вернёт он).
--- phase: "watch" │ "evac" │ "retreat" │ "away" │ "restore".
local function all()
  local s = storage.evacuate
  if type(s) ~= "table" then
    s = {}
    storage.evacuate = s
  end
  return s
end

function M.state(helper)
  local s = storage.evacuate
  return type(s) == "table" and s[helper] or nil
end

--- Область рефлекса как {left_top, right_bottom} (углы упорядочены).
function M.box_of(p)
  if p.area ~= nil then
    local a, b = p.area.left_top, p.area.right_bottom
    return {
      left_top = { x = math.min(a.x, b.x), y = math.min(a.y, b.y) },
      right_bottom = { x = math.max(a.x, b.x), y = math.max(a.y, b.y) },
    }
  end
  local c, r = p.center, p.radius
  return { left_top = { x = c.x - r, y = c.y - r }, right_bottom = { x = c.x + r, y = c.y + r } }
end

local function key_of(p)
  local b = M.box_of(p)
  return string.format("%.2f,%.2f,%.2f,%.2f|%s", b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y,
    table.concat(p.names or {}, ","))
end

--- Расстояние от точки до прямоугольника (0 — внутри).
local function box_dist(p, b)
  local dx = math.max(b.left_top.x - p.x, 0, p.x - b.right_bottom.x)
  local dy = math.max(b.left_top.y - p.y, 0, p.y - b.right_bottom.y)
  return math.sqrt(dx * dx + dy * dy)
end

local function prop(obj, key)
  if obj == nil then return nil end
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

local function add(map, name, n)
  map[name] = (map[name] or 0) + (n or 1)
end

local function or_nil(map)
  if map == nil or next(map) == nil then return nil end
  return map
end

local function count_state(st, state)
  local out = {}
  for _, en in ipairs(st.list) do
    if en.state == state then add(out, en.name) end
  end
  return out
end

-- ------------------------------------------------------------------ настройки построек

--- Имя прототипа: строка │ LuaPrototype │ {name=…} → строка │ nil.
local function nm(x)
  if type(x) == "string" then return x end
  local v = prop(x, "name")
  if type(v) == "string" then return v end
  return nil
end

--- Фильтр предмета (строка, ItemFilter, ItemIDAndQualityIDPair, LuaItemPrototype) → {name, quality?, comparator?}.
local function plain_filter(f)
  if f == nil then return nil end
  if type(f) == "string" then return { name = f } end
  local name = nm(prop(f, "name"))
  if name == nil then name = nm(f) end
  if name == nil then return nil end
  local out = { name = name }
  local q = nm(prop(f, "quality"))
  if q ~= nil then out.quality = q end
  local c = prop(f, "comparator")
  if type(c) == "string" then out.comparator = c end
  return out
end

local function read_props(obj, keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = util.plain(prop(obj, k))
    if v ~= nil then out[k] = v end
  end
  return or_nil(out)
end

--- Логистические секции (LuaLogisticSections или секции постоянного комбинатора) → список │ nil.
local function read_sections(holder)
  local n = prop(holder, "sections_count")
  if type(n) ~= "number" or n <= 0 then return nil end
  local out = {}
  for i = 1, n do
    local ok, s = pcall(function() return holder.get_section(i) end)
    if ok and s ~= nil and prop(s, "is_manual") ~= false then
      local g = prop(s, "group")
      out[#out + 1] = {
        group = type(g) == "string" and g or "", active = prop(s, "active"), multiplier = prop(s, "multiplier"),
        filters = util.plain(prop(s, "filters")) or {},
      }
    end
  end
  return or_nil(out)
end

--- Записать секции; → true │ false (что-то движок не принял).
local function write_sections(holder, list)
  local ok_all = true
  for i, rec in ipairs(list) do
    local ok = pcall(function()
      local group = rec.group ~= "" and rec.group or nil
      local s
      if i <= holder.sections_count then s = holder.get_section(i) else s = holder.add_section(group) end
      if s == nil then error("no section") end
      if group ~= nil and s.group ~= group then s.group = group end
      if group == nil and next(rec.filters or {}) ~= nil then s.filters = rec.filters end
      if rec.active ~= nil then s.active = rec.active end
      if rec.multiplier ~= nil then s.multiplier = rec.multiplier end
    end)
    if not ok then ok_all = false end
  end
  return ok_all
end

--- Настройки управления цепью (LuaControlBehavior) → таблица │ nil. wired — у постройки есть
--- красные или зелёные провода (без них условия цепи ничего не значат).
local function read_cb(e, wired)
  local ok, cb = pcall(function() return e.get_control_behavior() end)
  if not ok or cb == nil then return nil end
  if COMBINATORS[e.type] then
    local p = util.plain(prop(cb, "parameters"))
    return p ~= nil and { parameters = p } or nil
  end
  if e.type == "constant-combinator" then
    return { enabled = prop(cb, "enabled"), sections = read_sections(cb) }
  end
  if not wired and prop(cb, "connect_to_logistic_network") ~= true then return nil end
  local props = read_props(cb, CB_PROPS)
  return props ~= nil and { props = props } or nil
end

local function read_settings(e, wired)
  local out = {}
  local keys = ENTITY_PROPS[e.type]
  if keys ~= nil then out.props = read_props(e, keys) end
  if FILTER_TYPES[e.type] then
    local n = prop(e, "filter_slot_count")
    if type(n) == "number" and n > 0 then
      local list = {}
      for i = 1, math.min(n, M.MAX_FILTERS) do
        local ok, f = pcall(function() return e.get_filter(i) end)
        local pf = ok and plain_filter(f) or nil
        if pf ~= nil then list[#list + 1] = { i = i, f = pf } end
      end
      out.filters = or_nil(list)
    end
  end
  if SPLITTERS[e.type] then out.splitter_filter = plain_filter(prop(e, "splitter_filter")) end
  if e.type == "logistic-container" then
    local ok, s = pcall(function() return e.get_logistic_sections() end)
    if ok and s ~= nil then out.sections = read_sections(s) end
  end
  if CONTAINERS[e.type] then
    -- ограничение сундука (красный крестик в инвентаре)
    local ok, bar = pcall(function()
      local i = e.get_inventory(defines.inventory.chest)
      if i == nil or not i.supports_bar() then return nil end
      local b = i.get_bar()
      if b <= #i then return b end
      return nil
    end)
    if ok and type(bar) == "number" then out.bar = bar end
  end
  if e.type == "assembling-machine" then
    -- рецепт place ставит обычного качества; другое качество рецепта — здесь
    local ok, r, q = pcall(function() return e.get_recipe() end)
    local qn = ok and r ~= nil and q ~= nil and inv.quality_name(q) or inv.NORMAL
    local rn = ok and r ~= nil and (type(r) == "string" and r or prop(r, "name")) or nil
    if qn ~= inv.NORMAL and type(rn) == "string" then out.recipe_quality = { name = rn, quality = qn } end
  end
  out.cb = read_cb(e, wired)
  return or_nil(out)
end

--- Вернуть настройки снимка поставленной постройке; → true │ false (что-то движок не принял).
local function apply_settings(e, s)
  local ok_all = true
  local function try(fn)
    if not pcall(fn) then ok_all = false end
  end
  for _, k in ipairs(ENTITY_PROPS[e.type] or {}) do
    local v = s.props and s.props[k]
    if v ~= nil then try(function() e[k] = v end) end
  end
  for _, x in ipairs(s.filters or {}) do
    if not pcall(function() e.set_filter(x.i, x.f) end) then
      try(function() e.set_filter(x.i, x.f.name) end)
    end
  end
  if s.splitter_filter ~= nil then
    if not pcall(function() e.splitter_filter = s.splitter_filter end) then
      try(function() e.splitter_filter = s.splitter_filter.name end)
    end
  end
  if s.bar ~= nil then
    try(function()
      local i = e.get_inventory(defines.inventory.chest)
      if i == nil then error("no inventory") end
      i.set_bar(s.bar)
    end)
  end
  if s.recipe_quality ~= nil then
    try(function() e.set_recipe(s.recipe_quality.name, s.recipe_quality.quality) end)
  end
  if s.sections ~= nil then
    local ok, holder = pcall(function() return e.get_logistic_sections() end)
    if not ok or holder == nil or not write_sections(holder, s.sections) then ok_all = false end
  end
  if s.cb ~= nil then
    local ok, cb = pcall(function() return e.get_or_create_control_behavior() end)
    if not ok or cb == nil then
      ok_all = false
    else
      if s.cb.parameters ~= nil then try(function() cb.parameters = s.cb.parameters end) end
      if s.cb.enabled ~= nil then try(function() cb.enabled = s.cb.enabled end) end
      if s.cb.sections ~= nil and not write_sections(cb, s.cb.sections) then ok_all = false end
      for _, k in ipairs(CB_PROPS) do
        local v = s.cb.props and s.cb.props[k]
        if v ~= nil then try(function() cb[k] = v end) end
      end
    end
  end
  return ok_all
end

-- ------------------------------------------------------------------ провода

local function player_origin(w)
  local wo = defines.wire_origin
  local o = prop(w, "origin")
  return o == nil or wo == nil or wo.player == nil or o == wo.player
end

local function is_copper(c)
  local wt = defines.wire_type
  local t = prop(c, "wire_type")
  return wt ~= nil and t ~= nil and t == wt.copper
end

--- Провода игрока от постройки: {{c, tc, name, pos}, ...} │ nil, и есть ли среди них красные/зелёные.
local function read_wires(e)
  local ok, cons = pcall(function() return e.get_wire_connectors(false) end)
  if not ok or type(cons) ~= "table" then return nil, false end
  local out, circuit = {}, false
  for cid, c in pairs(cons) do
    local ok2, list = pcall(function() return c.connections end)
    if ok2 and type(list) == "table" and type(cid) == "number" then
      for _, w in ipairs(list) do
        if #out >= M.MAX_WIRES then break end
        local t = prop(w, "target")
        local owner, tid = prop(t, "owner"), prop(t, "wire_connector_id")
        -- провод к себе же (выход комбинатора на его вход) — к другому разъёму той же постройки
        if player_origin(w) and owner ~= nil and prop(owner, "valid") ~= false and type(tid) == "number"
            and (owner ~= e or tid ~= cid) then
          out[#out + 1] = { c = cid, tc = tid, name = owner.name, pos = util.xy(owner.position) }
          if not is_copper(c) then circuit = true end
        end
      end
    end
  end
  return or_nil(out), circuit
end

-- ------------------------------------------------------------------ снимок

--- Постройки области, которые рефлекс разбирает: своей силы, копаемые, с предметом для постановки.
local function scan(h, box, names)
  local filter = { area = { left_top = box.left_top, right_bottom = box.right_bottom }, force = h.force }
  if names ~= nil then filter.name = names end
  local out = {}
  for _, e in ipairs(h.surface.find_entities_filtered(filter)) do
    if e.valid and e ~= h and B.why_not_minable(e) == nil and not B.has_driver(e)
        and B.place_items(e.prototype)[1] ~= nil then
      out[#out + 1] = e
    end
  end
  if #out > M.MAX_ENTITIES then
    err.raise("limit", "more than " .. M.MAX_ENTITIES .. " buildings in the area; use a smaller area or names")
  end
  return out
end

local function record(e, order)
  local it = B.place_items(e.prototype)[1]
  local en = {
    name = e.name, item = it.name, count = it.count, pos = util.xy(e.position), dir = e.direction or 0,
    unit = e.unit_number, state = "present", fails = 0, cuts = 0,
    rank = order[e.name] or M.RANK[e.type] or M.RANK_OTHER,
  }
  en.quality = inv.quality_name(prop(e, "quality"))
  local io = IO_TYPES[e.type] and prop(e, IO_TYPES[e.type]) or nil
  if io == "input" or io == "output" then en.io = io end
  if e.type == "assembling-machine" then
    local ok, r = pcall(function() return e.get_recipe() end)
    if ok and r ~= nil then en.recipe = type(r) == "string" and r or prop(r, "name") end
  end
  local ok, mi = pcall(function() return e.get_module_inventory() end)
  if ok and mi ~= nil then en.modules = or_nil(inv.counts_q(mi)) end
  local wired
  en.wires, wired = read_wires(e)
  local ok2, s = pcall(read_settings, e, wired)
  if ok2 then en.settings = s else en.lossy = true end
  if LOSSY_TYPES[e.type] then en.lossy = true end
  return en
end

local function snapshot(h, p)
  local box = M.box_of(p)
  local order = {}
  for i, n in ipairs(p.names or {}) do
    if order[n] == nil then order[n] = i end
  end
  local list = {}
  for _, e in ipairs(scan(h, box, p.names)) do list[#list + 1] = record(e, order) end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.pos.y ~= b.pos.y then return a.pos.y < b.pos.y end
    return a.pos.x < b.pos.x
  end)
  return { key = key_of(p), surface = h.surface.index, box = box, list = list, phase = "watch" }
end

-- ------------------------------------------------------------------ угроза

--- Враждебные силе own силы: из storage, пересчёт раз в FORCES_EVERY (одинаково у всех игроков).
local function enemy_forces(own, tick)
  local cache = storage.evacuate_forces
  if type(cache) ~= "table" then
    cache = {}
    storage.evacuate_forces = cache
  end
  local c = cache[own.name]
  if c ~= nil and tick - c.tick < M.FORCES_EVERY and tick >= c.tick then return c.list end
  local out = {}
  for _, f in pairs(game.forces) do
    local ok, name, yes = pcall(function() return f.name, f.name ~= own.name and own.is_enemy(f) end)
    if ok and yes == true then out[#out + 1] = name end
  end
  cache[own.name] = { tick = tick, list = out }
  return out
end

--- Ближайший к области видимый враг, который может прийти: {name, pos, dist} │ nil.
local function find_threat(id, h, st, p, tick)
  local forces = enemy_forces(h.force, tick or game.tick)
  if forces[1] == nil then return nil end
  local b, r = st.box, p.threat_radius
  local filter = {
    area = { left_top = { x = b.left_top.x - r, y = b.left_top.y - r },
             right_bottom = { x = b.right_bottom.x + r, y = b.right_bottom.y + r } },
    type = M.THREAT_TYPES, force = forces,
  }
  if h.surface.count_entities_filtered(filter) == 0 then return nil end
  local best
  for _, e in ipairs(h.surface.find_entities_filtered(filter)) do
    if e.valid then
      local pos = util.xy(e.position)
      local d = box_dist(pos, b)
      if d <= r and (best == nil or d < best.dist) and vis.visible(id, h.surface, pos, h.force) then
        best = { name = e.name, pos = pos, dist = d }
      end
    end
  end
  return best
end

-- ------------------------------------------------------------------ задачи тела

local function entity_of(h, en)
  local list = h.surface.find_entities_filtered{ position = en.pos, radius = 0.5, name = en.name, force = h.force }
  for _, e in ipairs(list) do
    if e.valid and (en.unit == nil or e.unit_number == en.unit) then return e end
  end
  return nil
end

--- Та же постройка на месте записи, кем бы ни поставлена (номер мог смениться).
local function standing(h, en)
  local list = h.surface.find_entities_filtered{ position = en.pos, radius = 0.5, name = en.name, force = h.force }
  for _, e in ipairs(list) do
    if e.valid then return e end
  end
  return nil
end

local function fleeing(id)
  local s = C.state(id)
  return s ~= nil and s.flee ~= nil
end

local function job_pending(id, job)
  local active = jobs.active(id)
  if active ~= nil and active.job == job then return true end
  local q = jobs.queue_of(id, false)
  for _, t in ipairs(q and q.queue or {}) do
    if t.job == job then return true end
  end
  return false
end

local function idle(id)
  if jobs.active(id) ~= nil then return false end
  local q = jobs.queue_of(id, false)
  return q == nil or q.queue == nil or q.queue[1] == nil
end

local function act(id, h, tick, name, args, replace, hold_ok)
  return pcall(jobs.op_act, { ["do"] = name, args = args, replace = replace == true },
    { helper_id = id, request_id = M.REQ, entity = h, tick = tick, owner_hold_ok = hold_ok == true or nil })
end

--- Снять свои задачи из очереди тела (без событий об итоге в состояние: они уже не нужны).
local function cancel_pending(id, h, st)
  for _, p in ipairs(st.pending or {}) do
    if job_pending(id, p.job) then
      pcall(jobs.op_cancel, { job = p.job }, { helper_id = id, entity = h, tick = game.tick })
    end
  end
  st.pending = {}
end

local function has_present(st)
  for _, en in ipairs(st.list) do
    if en.state == "present" and en.fails < M.MAX_FAILS and en.kept == nil then return true end
  end
  return false
end

--- Хозяин запретил разбор этой постройки (perms «нельзя»)?
local function dig_denied(e)
  for _, k in ipairs(perms.dig_keys(e, {})) do
    if perms.get(k) == "deny" then return true end
  end
  return false
end

--- Сундук с содержимым: оно уйдёт в карманы и забьёт их.
local function has_contents(e)
  if not CONTAINERS[e.type] then return false end
  local ok, empty = pcall(function()
    local i = e.get_inventory(defines.inventory.chest)
    if i == nil then return true end
    return i.is_empty()
  end)
  return ok and empty == false
end

local function same_spot(a, b)
  return a.name == b.name and a.pos ~= nil and b.pos ~= nil and a.pos.x == b.pos.x and a.pos.y == b.pos.y
end

--- Постройку записи en взял (или сейчас разбирает) другой помощник своей охраной: у него в снимке
--- она taken либо его задача разбора по ней ещё идёт. Сопоставление — по номеру или имени и месту.
local function taken_by_other(id, st, en)
  for other, s in pairs(all()) do
    if other ~= id and type(s) == "table" and s.surface == st.surface and type(s.list) == "table" then
      local busy = {}
      for _, p in ipairs(s.pending or {}) do
        if p.kind == "take" and p.idx ~= nil then busy[p.idx] = true end
      end
      for i, x in ipairs(s.list) do
        if (x.state == "taken" or (x.state == "present" and busy[i]))
            and x.name == en.name and ((en.unit ~= nil and x.unit == en.unit) or same_spot(x, en)) then
          return true
        end
      end
    end
  end
  return false
end

--- Постройки нет на месте: взял другой помощник — "other" (молча), иначе — lost.
local function gone(id, st, en)
  if taken_by_other(id, st, en) then
    en.state = "other"
  else
    en.state = "lost"
    add(st.lost, en.name)
  end
end

-- ------------------------------------------------------------------ возврат настроек

--- Постройка поставлена без части настроек: в reset (одна на постройку) и причина в reset_why.
local function mark_reset(st, idx, why)
  local en = st.list[idx]
  st.reset = st.reset or {}
  st.reset_idx = st.reset_idx or {}
  st.reset_why = st.reset_why or {}
  if not st.reset_idx[idx] then
    st.reset_idx[idx] = true
    add(st.reset, en.name)
  end
  local list = st.reset_why[en.name] or {}
  st.reset_why[en.name] = list
  for _, w in ipairs(list) do
    if w == why then return end
  end
  list[#list + 1] = why
  table.sort(list)
end

local function find_at(h, name, pos)
  local list = h.surface.find_entities_filtered{ position = pos, radius = 0.5, name = name, force = h.force }
  for _, e in ipairs(list) do
    if e.valid then return e end
  end
  return nil
end

--- Провода поставленных построек — к тем, что стоят (вернул или не трогал). Провод к постройке,
--- которой больше нет, — reset "wire_to_gone"; движок не соединил — reset "wire".
local function rewire(h, st)
  for _, idx in ipairs(st.rewire or {}) do
    local en = st.list[idx]
    local e = en and en.state == "present" and en.wires ~= nil and (entity_of(h, en) or standing(h, en)) or nil
    if e ~= nil then
      for _, w in ipairs(en.wires) do
        local t = (w.name == en.name and w.pos.x == en.pos.x and w.pos.y == en.pos.y) and e or find_at(h, w.name, w.pos)
        if t == nil then
          mark_reset(st, idx, "wire_to_gone")
        else
          local ok, a, b = pcall(function()
            return e.get_wire_connector(w.c, true), t.get_wire_connector(w.tc, true)
          end)
          if not ok or a == nil or b == nil then
            mark_reset(st, idx, "wire")
          else
            local ok2, already = pcall(function() return a.is_connected_to(b) end)
            if not (ok2 and already == true) then
              local ok3, done = pcall(function() return a.connect_to(b, false) end)
              if not ok3 or done == false then mark_reset(st, idx, "wire") end
            end
          end
        end
      end
    end
  end
  st.rewire = nil
end

--- Постройка встала: настройки снимка — ей сразу, провода — в конце возврата.
local function restored(h, st, idx)
  local en = st.list[idx]
  if en.lossy then mark_reset(st, idx, "lossy") end
  if en.wires ~= nil then
    st.rewire = st.rewire or {}
    st.rewire[#st.rewire + 1] = idx
  end
  if en.settings == nil then return end
  local e = entity_of(h, en)
  if e == nil or not apply_settings(e, en.settings) then mark_reset(st, idx, "settings") end
end

-- ------------------------------------------------------------------ итоги задач

local CANCEL = { cancelled = true, no_helper = true, owner_hold = true }

--- Задача снята. Отступление flee — вернуть запись в очередь (но не больше MAX_FLEE_CUTS раз);
--- «стоп» хозяина — особый итог; иначе её снял агент.
local function on_cut(id, st, p, en)
  if fleeing(id) then
    en.cuts = (en.cuts or 0) + 1
    if en.cuts > M.MAX_FLEE_CUTS then
      st.aborted = "threatened" -- враг уже у построек: не ходить к нему снова и снова
      en.fails = M.MAX_FAILS
      if p.kind == "take" then add(st.left, en.name) else add(st.failed, en.name) end
      return
    end
    table.insert(st.todo, 1, p.idx) -- отступление flee: дело продолжится после него
  elseif jobs.held(id) ~= nil then
    if p.kind == "place" then table.insert(st.todo, 1, p.idx) end
    st.aborted = "owner_stop"
  else
    st.aborted = "cancelled"
  end
end

local function on_result(id, h, st, p, ev)
  local d = ev.data
  local done = ev.kind == "job_done"
  local en = p.idx and st.list[p.idx] or nil
  if p.kind == "take" and en ~= nil then
    if done then
      local removed = type(d.detail) == "table" and d.detail.removed or 0
      if type(removed) == "number" and removed >= 1 then
        en.state = "taken"
        add(st.taken, en.name)
      else
        gone(id, st, en) -- исчезла сама (или её разобрал кто-то другой), пока тело шло
      end
    elseif d.code == "not_found" then
      gone(id, st, en)
    elseif CANCEL[d.code] then
      on_cut(id, st, p, en)
    else
      en.fails = en.fails + 1
      add(st.left, en.name)
    end
  elseif p.kind == "place" and en ~= nil then
    if done then
      en.state = "present"
      en.fails, en.cuts = 0, 0
      if type(d.detail) == "table" and type(d.detail.unit_number) == "number" then en.unit = d.detail.unit_number end
      add(st.placed, en.name)
      restored(h, st, p.idx)
      if en.modules ~= nil then st.inserts[#st.inserts + 1] = p.idx end
    elseif d.code == "no_items" then
      add(st.missing, inv.qkey(en.item, en.quality), en.count)
    elseif CANCEL[d.code] then
      on_cut(id, st, p, en)
    else
      en.fails = en.fails + 1
      add(st.failed, en.name)
    end
  elseif p.kind == "insert" and en ~= nil then
    -- модули: снятую отступлением или «стоп» задачу — заново, иначе не встало — постройка в reset
    local left = done and type(d.detail) == "table" and d.detail.left or nil
    if not done and CANCEL[d.code] and (fleeing(id) or jobs.held(id) ~= nil) then
      st.inserts = st.inserts or {}
      st.inserts[#st.inserts + 1] = p.idx
    elseif not done or (type(left) == "table" and next(left) ~= nil) then
      mark_reset(st, p.idx, "modules")
    end
  end
end

--- Разобрать итоги своих задач из буфера событий; задача пропала без события (буфер переполнился) —
--- итог по миру.
local function collect(id, h, st)
  local pending = st.pending
  if pending[1] == nil then
    st.cursor = events.last_seq()
    return
  end
  local since = st.cursor or 0
  for _ = 1, 8 do
    local list, seq = events.query(since, id, M.SCAN)
    for _, ev in ipairs(list) do
      if (ev.kind == "job_done" or ev.kind == "job_failed") and type(ev.data) == "table" then
        for i, p in ipairs(pending) do
          if p.job == ev.data.job then
            table.remove(pending, i)
            on_result(id, h, st, p, ev)
            break
          end
        end
      end
    end
    since = seq
    if #list < M.SCAN then break end
  end
  st.cursor = since
  for i = #pending, 1, -1 do
    local p = pending[i]
    if not job_pending(id, p.job) then
      table.remove(pending, i)
      local en = p.idx and st.list[p.idx] or nil
      if en ~= nil and (p.kind == "take" or p.kind == "place") then
        local here = entity_of(h, en) ~= nil
        local ok = (p.kind == "take") ~= here
        on_result(id, h, st, p, { kind = ok and "job_done" or "job_failed",
          data = { job = p.job, code = ok and nil or "unknown", detail = { removed = ok and 1 or 0 } } })
      end
    end
  end
end

-- ------------------------------------------------------------------ возврат к делу

local function resumed(id, made, reason)
  events.emit(id, "reflex_resumed", { type = "evacuate", jobs = made, reason = reason }, { loud = true })
end

--- Снимок забыт, а разобранное этим телом ещё в карманах: сказать громко, что не вернётся.
local function drop(id, st, off)
  local left = count_state(st, "taken")
  if next(left) == nil then return end
  events.emit(id, "evacuate_restored", { placed = {}, missing = {}, left = left, reason = "dropped", off = off },
    { loud = true })
end

--- Охрану сняли кнопкой хозяина, а возврат кончился: evacuate уходит из набора тела.
local function remove_self(id)
  local set = type(storage.reflexes) == "table" and storage.reflexes[id] or nil
  if type(set) == "table" then
    local out = {}
    for _, r in ipairs(set) do
      if r.type ~= "evacuate" then out[#out + 1] = r end
    end
    storage.reflexes[id] = out
  end
  all()[id] = nil
end

local function finish_return(id, h, st, tick, told)
  local saved = st.saved
  local off = st.remove_after
  st.phase = "watch"
  st.saved, st.quiet, st.todo, st.pending, st.inserts = nil, nil, nil, {}, nil
  st.placed, st.missing, st.failed, st.reset, st.reset_why, st.reset_idx = nil, nil, nil, nil, nil, nil
  st.quality, st.going_on, st.rewire = nil, nil, nil
  st.owner_stopped = nil
  for _, en in ipairs(st.list) do
    -- следующая волна врагов — новая попытка для всего, что стоит
    if en.state == "present" then en.fails, en.cuts, en.kept = 0, 0, nil end
  end
  if off then
    if not told then drop(id, st, true) end
    remove_self(id)
  end
  if saved == nil or saved[1] == nil then return end
  if not idle(id) then return end -- агент уже решил сам
  if jobs.held(id) ~= nil then return resumed(id, {}, "owner_hold") end
  local made = {}
  for _, t in ipairs(saved) do
    local ok, res = pcall(jobs.op_act, { ["do"] = t["do"], args = t.args, replace = false },
      flee.resume_ctx(t, { helper_id = id, request_id = M.RESUME_REQ, entity = h, tick = tick }))
    if ok then made[#made + 1] = { job = res.job, ["do"] = t["do"] } end
  end
  resumed(id, made, made[1] == nil and "rejected" or nil)
end

local function save_jobs(id, st)
  st.saved = st.saved or {}
  for _, t in ipairs(flee.pending_jobs(id)) do
    if #st.saved >= M.RESUME_MAX then break end
    st.saved[#st.saved + 1] = t
  end
end

--- Дело, которое ждёт возврата после отступления flee: теперь его вернёт эвакуация (flee его
--- бросит, как только тело займётся разбором).
local function take_flee_resume(id, st)
  local fs = C.state(id)
  local r = fs and fs.resume
  if r == nil then return end
  fs.resume = nil
  local out = {}
  for _, t in ipairs(r.tasks or {}) do
    if #out < M.RESUME_MAX then out[#out + 1] = t end
  end
  for _, t in ipairs(st.saved or {}) do
    if #out < M.RESUME_MAX then out[#out + 1] = t end
  end
  st.saved = out
end

-- ------------------------------------------------------------------ эвакуация

local function start_retreat(id, h, st, p, threat, tick)
  local fp = { to = "away", distance = M.RETREAT, radius = p.threat_radius }
  for _, c in ipairs(flee.retreat_candidates(h, fp, threat)) do
    local spot = flee.usable_spot(id, h, c)
    if spot ~= nil then
      save_jobs(id, st) -- поставленное агентом за время разбора вернётся вместе с остальным
      local ok, res = act(id, h, tick, "walk", { to = spot, radius = M.GOAL_RADIUS }, true, true)
      if ok then
        st.pending = { { job = res.job, kind = "walk" } }
        st.cursor = events.last_seq()
        st.phase = "retreat"
        return
      end
    end
  end
  st.phase = "away"
end

local function finish_evac(id, h, st, p, tick, reason)
  cancel_pending(id, h, st)
  if reason == "threatened" then
    -- что не успели разобрать, в эту волну больше не трогаем
    for _, idx in ipairs(st.todo or {}) do
      local en = st.list[idx]
      if en.state == "present" then
        en.fails = M.MAX_FAILS
        add(st.left, en.name)
      end
    end
  end
  events.emit(id, "evacuated", {
    taken = st.taken, lost = st.lost, left = or_nil(st.left), kept = or_nil(st.kept), reason = reason,
  }, { loud = true })
  st.todo = nil
  st.quiet = nil
  if reason == "cancelled" then
    st.saved = nil -- задачи снял агент: что дальше, решает он
    st.phase = "away"
    return
  end
  if reason ~= nil then
    st.phase = "away" -- flee уже увёл тело, «стоп» хозяина держит его на месте
    st.owner_stopped = reason == "owner_stop" or nil
    return
  end
  local threat = find_threat(id, h, st, p, tick)
  if threat ~= nil then return start_retreat(id, h, st, p, threat, tick) end
  st.phase = "away"
end

local function pump_evac(id, h, st, p, tick)
  st.todo, st.pending = st.todo or {}, st.pending or {}
  st.taken, st.lost, st.left, st.kept = st.taken or {}, st.lost or {}, st.left or {}, st.kept or {}
  collect(id, h, st)
  -- хозяин снял охрану: дальше не разбирать, разобранное вернуть, когда станет тихо
  if st.remove_after and st.aborted == nil then st.aborted = "unguarded" end
  if st.aborted ~= nil then
    local reason = st.aborted
    st.aborted = nil
    return finish_evac(id, h, st, p, tick, reason)
  end
  if fleeing(id) then return end
  local todo = st.todo
  while #st.pending < M.BATCH and todo[1] ~= nil do
    local idx = table.remove(todo, 1)
    local en = st.list[idx]
    local e = entity_of(h, en)
    if e == nil then
      gone(id, st, en)
    else
      local ok, res = act(id, h, tick, "deconstruct",
        { target = { unit_number = e.unit_number, pos = util.pos(e.position) } }, st.first, true)
      if not ok then
        table.insert(todo, 1, idx) -- очередь полна: дольём на следующей проверке
        break
      end
      st.first = false
      st.pending[#st.pending + 1] = { job = res.job, idx = idx, kind = "take" }
    end
  end
  if todo[1] == nil and st.pending[1] == nil then finish_evac(id, h, st, p, tick, nil) end
end

local function start_evac(id, h, st, p, threat, tick)
  if st.saved == nil then st.saved = flee.pending_jobs(id) end -- до замены очереди разбором
  take_flee_resume(id, st)
  st.taken, st.lost, st.left, st.kept = {}, {}, {}, {}
  local todo = {}
  for i, en in ipairs(st.list) do
    en.kept = nil
    if en.state == "other" then
      -- её взял другой помощник; вернул — она снова наша забота
      local e = standing(h, en)
      if e ~= nil then
        en.state, en.unit, en.fails, en.cuts = "present", e.unit_number, 0, 0
      end
    end
    if en.state == "present" and en.fails < M.MAX_FAILS then
      local e = entity_of(h, en)
      -- разрешения хозяина могли смениться после включения; сундук с содержимым забьёт карманы
      if e ~= nil and dig_denied(e) then
        en.kept = "denied"
      elseif e ~= nil and has_contents(e) then
        en.kept = "contents"
      end
      if en.kept ~= nil then add(st.kept, en.name) else todo[#todo + 1] = i end
    end
  end
  st.phase = "evac"
  st.threat = { name = threat.name, pos = { x = threat.pos.x, y = threat.pos.y } }
  st.todo, st.pending, st.inserts = todo, {}, nil
  st.first = idle(id) == false -- очередь тела снимается первой же задачей разбора
  st.cursor = events.last_seq()
  st.quiet = nil
  events.emit(id, "evacuate_started", {
    area = util.plain(st.box),
    threat = { name = threat.name, pos = util.pos(threat.pos), dist = util.round1(threat.dist) },
  }, { loud = true })
  pump_evac(id, h, st, p, tick)
end

-- ------------------------------------------------------------------ возврат построек

local function sorted_why(map)
  if map == nil or next(map) == nil then return nil end
  return util.plain(map)
end

local function finish_restore(id, h, st, tick, reason)
  rewire(h, st) -- поставленные стоят при любом итоге: их провода — тоже
  events.emit(id, "evacuate_restored", {
    placed = st.placed, missing = st.missing, failed = or_nil(st.failed),
    left = or_nil(count_state(st, "taken")), reset = or_nil(st.reset), reset_why = sorted_why(st.reset_why),
    off = st.remove_after and true or nil, reason = reason,
  }, { loud = true })
  finish_return(id, h, st, tick, true)
end

local function same_map(a, b)
  for k, v in pairs(a or {}) do
    if (b or {})[k] ~= v then return false end
  end
  for k in pairs(b or {}) do
    if (a or {})[k] == nil then return false end
  end
  return true
end

local function start_restore(id, h, st, p, tick)
  if not p.rebuild then return finish_return(id, h, st, tick) end
  local going_on = st.going_on -- возврат после «стоп» хозяина: итог общий
  st.going_on = nil
  st.placed = going_on and st.placed or {}
  st.failed = going_on and st.failed or {}
  if not going_on then st.reset, st.reset_why, st.reset_idx, st.rewire = {}, {}, {}, nil end
  st.phase = "restore"
  st.pending, st.inserts = {}, {}
  st.cursor = events.last_seq()
  if perms.get("build") == "deny" then
    st.todo, st.missing = {}, {}
    return finish_restore(id, h, st, tick, "owner_forbids")
  end
  -- карманы по (имя, качество): ключ inv.qkey
  local have = inv.counts_q(h.get_main_inventory())
  local todo, missing = {}, {}
  local function take(key, n)
    local got = math.min(have[key] or 0, n)
    have[key] = (have[key] or 0) - got
    if got < n then add(missing, key, n - got) end
    return got == n
  end
  for i, en in ipairs(st.list) do
    if (en.state == "taken" or en.state == "other") and standing(h, en) ~= nil then
      en.state = "present" -- уже стоит: поставил хозяин или другой помощник
    end
    if en.state == "taken" and take(inv.qkey(en.item, en.quality), en.count or 1) then
      todo[#todo + 1] = i
      for m, n in pairs(en.modules or {}) do take(m, n) end
    end
  end
  st.todo = todo
  st.missing = missing
  if next(missing) ~= nil and not same_map(missing, st.missing_told) then
    events.emit(id, "evacuate_missing", { items = util.plain(missing) }, { loud = true })
  end
  st.missing_told = or_nil(util.plain(missing))
end

--- Модули в поставленную машину: по задаче insert на каждое качество, что есть в карманах
--- (нехватка уже в evacuate_missing).
local function queue_modules(id, h, st, tick, idx)
  local en = st.list[idx]
  if en.unit == nil then return end
  local main = h.get_main_inventory()
  local by_q = {}
  for key, n in pairs(en.modules or {}) do
    local name, q = inv.split_qkey(key)
    local k = math.min(n, inv.count(main, name, q))
    if k > 0 then
      by_q[q] = by_q[q] or {}
      by_q[q][name] = k
    end
  end
  for q, items in pairs(by_q) do
    local ok, res = act(id, h, tick, "insert", {
      target = { unit_number = en.unit, pos = util.pos(en.pos) }, items = items,
      quality = q ~= inv.NORMAL and q or nil,
    })
    if ok then
      st.pending[#st.pending + 1] = { job = res.job, idx = idx, kind = "insert" }
    else
      mark_reset(st, idx, "modules")
    end
  end
end

local function pump_restore(id, h, st, p, tick)
  st.todo, st.inserts = st.todo or {}, st.inserts or {}
  st.placed, st.failed, st.missing = st.placed or {}, st.failed or {}, st.missing or {}
  collect(id, h, st)
  if st.aborted == "owner_stop" then
    -- «стоп» хозяина: возврат ждёт его слова и потом продолжится с того, что осталось
    st.aborted = nil
    cancel_pending(id, h, st)
    st.phase, st.todo, st.inserts = "away", nil, nil
    st.quiet = tick - p.return_after_s * 60
    st.going_on = true
    return
  end
  if st.aborted ~= nil then
    local reason = st.aborted
    st.aborted = nil
    cancel_pending(id, h, st)
    return finish_restore(id, h, st, tick, reason)
  end
  local threat = find_threat(id, h, st, p, tick)
  if threat ~= nil then
    cancel_pending(id, h, st)
    rewire(h, st) -- уже поставленные, которые в этот набег не разберут, не остаются без проводов
    if st.remove_after then
      -- охрану сняли: заново не разбирать, вернуть остальное, когда снова станет тихо
      st.phase, st.todo, st.inserts, st.quiet, st.going_on = "away", nil, nil, nil, true
      return
    end
    return start_evac(id, h, st, p, threat, tick)
  end
  if fleeing(id) or jobs.held(id) ~= nil then return end -- возврат при hold ждёт
  while st.inserts[1] ~= nil and #st.pending < M.BATCH do
    queue_modules(id, h, st, tick, table.remove(st.inserts, 1))
  end
  local todo = st.todo
  while #st.pending < M.BATCH and todo[1] ~= nil do
    local idx = table.remove(todo, 1)
    local en = st.list[idx]
    local ok, res = act(id, h, tick, "place", {
      item = en.item, pos = { x = en.pos.x, y = en.pos.y }, direction = en.dir, recipe = en.recipe, type = en.io,
      quality = en.quality ~= inv.NORMAL and en.quality or nil,
    })
    if not ok then
      local code = err.normalize(res)
      if code == "owner_hold" or code == "limit" then
        table.insert(todo, 1, idx) -- подождать: hold снимет хозяин, очередь освободится
        break
      end
      en.fails = en.fails + 1
      add(st.failed, en.name)
    else
      st.pending[#st.pending + 1] = { job = res.job, idx = idx, kind = "place" }
    end
  end
  if todo[1] == nil and st.pending[1] == nil and st.inserts[1] == nil then finish_restore(id, h, st, tick) end
end

-- ------------------------------------------------------------------ раз в 10 тиков

function M.check(id, h, p, tick)
  local st = M.state(id)
  if st == nil or st.key ~= key_of(p) then
    st = snapshot(h, p)
    all()[id] = st
  end
  if h.surface.index ~= st.surface then return end
  st.pending = st.pending or {}
  local phase = st.phase
  if phase == "evac" then return pump_evac(id, h, st, p, tick) end
  if phase == "restore" then return pump_restore(id, h, st, p, tick) end
  if phase == "retreat" then
    collect(id, h, st)
    if st.pending[1] == nil then st.phase, st.quiet = "away", nil end
    return
  end
  if phase == "watch" then
    -- спокойно: смотреть реже (UPS на большой базе)
    if st.looked ~= nil and tick >= st.looked and tick - st.looked < M.WATCH_EVERY then return end
    st.looked = tick
  end
  local threat = find_threat(id, h, st, p, tick)
  if phase == "away" then
    if threat ~= nil then
      st.quiet = nil
      -- разбор снял «стоп» хозяина: пока hold стоит, заново не начинать; охрану сняли — тоже
      local stopped = (st.owner_stopped and jobs.held(id) ~= nil) or st.remove_after
      if has_present(st) and not fleeing(id) and not stopped then start_evac(id, h, st, p, threat, tick) end
      return
    end
    if st.quiet == nil then st.quiet = tick end
    if tick - st.quiet < p.return_after_s * 60 then return end
    if jobs.held(id) ~= nil or fleeing(id) then return end -- возврат при hold ждёт
    return start_restore(id, h, st, p, tick)
  end
  if threat ~= nil and has_present(st) and not fleeing(id) then start_evac(id, h, st, p, threat, tick) end
end

-- ------------------------------------------------------------------ интерфейс модуля

local function validate(v, path)
  if (v.area == nil) == (v.center == nil) then
    err.raise("bad_args", path .. ": exactly one of area, center is required")
  end
  if v.center ~= nil and v.radius == nil then err.raise("bad_args", path .. ".radius: required with center") end
  if v.area ~= nil and v.radius ~= nil then err.raise("bad_args", path .. ".radius: only with center") end
  for i, n in ipairs(v.names or {}) do
    -- неизвестное имя в find_entities_filtered — ошибка движка
    if prototypes.entity[n] == nil then err.raise("bad_args", path .. ".names[" .. i .. "]: unknown entity " .. n) end
  end
  return v
end

local function same(a, b)
  return a ~= nil and b ~= nil and key_of(a) == key_of(b) and a.rebuild == b.rebuild
end

--- Агент включает охрану только там, где тело: центр области не дальше MAX_DIST (запрос по RCON —
--- ctx.perm_gate; свои вызовы мода и кнопка хозяина — без предела).
local function near_enough(v, ctx)
  local h = ctx and ctx.entity
  if ctx == nil or ctx.perm_gate ~= true or h == nil or not h.valid then return end
  local b = M.box_of(v)
  local c = { x = (b.left_top.x + b.right_bottom.x) / 2, y = (b.left_top.y + b.right_bottom.y) / 2 }
  local d = util.dist(util.xy(h.position), c)
  if d > M.MAX_DIST then
    err.raise("too_far", string.format("evacuate: the area center is %d tiles from the helper (at most %d); walk there first",
      math.floor(d + 0.5), M.MAX_DIST), { distance = util.round1(d), max = M.MAX_DIST })
  end
end

--- Ключи разрешений для этих параметров (без учёта прежних).
local function perm_keys(v, ctx)
  local keys = {}
  if v.rebuild then keys[1] = "perm-build" end
  local h = ctx and ctx.entity
  if h == nil or not h.valid then
    perms.add(keys, "perm-deconstruct-owner")
    return keys
  end
  for _, e in ipairs(scan(h, M.box_of(v), v.names)) do perms.dig_keys(e, keys) end
  return keys
end

M.reflexes = {
  evacuate = {
    once = true, -- одно состояние на помощника (storage.evacuate[helper])
    schema = {
      area = { type = "area", max_side = M.MAX_SIDE },
      center = { type = "pos" },
      radius = { type = "number", min = 1, max = M.MAX_RADIUS },
      names = { type = "list", of = { type = "string", max = 100 }, max = M.MAX_NAMES },
      threat_radius = { type = "number", min = 10, max = 120, default = 40 },
      return_after_s = { type = "int", min = 30, max = 1800, default = 180 },
      rebuild = { type = "bool", default = true },
    },
    validate = validate,
    -- разбор построек снимка и (rebuild) стройка; те же параметры повторно — без вопроса
    perms = function(v, ctx, old)
      if same(v, old) then return {} end
      -- дальняя область: отказ до просмотра её построек (что там стоит, агенту не сообщается)
      if old == nil or key_of(v) ~= key_of(old) then near_enough(v, ctx) end
      return perm_keys(v, ctx)
    end,
    -- набор ещё не записан: отказ оставляет прежний
    guard = function(id, v, old, ctx)
      local changed = v == nil or old == nil or key_of(v) ~= key_of(old)
      local word = ctx ~= nil and ctx.owner_word == true -- кнопка хозяина: это его слово
      if not word and v ~= nil and (old == nil or not same(v, old)) and jobs.held(id) ~= nil then
        err.raise("owner_hold", "evacuate: the owner said stop; wait for his next word before switching it on or changing it")
      end
      local st = M.state(id)
      if changed and st ~= nil and st.phase ~= nil and st.phase ~= "watch" then
        local n = 0
        for _, en in ipairs(st.list or {}) do
          if en.state == "taken" then n = n + 1 end
        end
        err.raise("bad_args", "evacuate: an evacuation is under way (phase " .. st.phase .. ", " .. n
          .. " buildings in the pockets); keep the same area and names until evacuate_restored")
      end
      if v ~= nil and changed then near_enough(v, ctx) end
    end,
    on_set = function(id, v, old, ctx)
      local st = M.state(id)
      if st ~= nil and old ~= nil and st.key == key_of(v) then return end
      local h = ctx and ctx.entity
      if st ~= nil then
        drop(id, st)
        if h ~= nil and h.valid then cancel_pending(id, h, st) end
      end
      all()[id] = (h ~= nil and h.valid) and snapshot(h, v) or nil
    end,
    on_unset = function(id)
      local st = M.state(id)
      if st == nil then return end
      drop(id, st)
      local rec = storage.helpers and storage.helpers[id]
      local h = rec and rec.entity
      if h ~= nil and h.valid then cancel_pending(id, h, st) end
      all()[id] = nil
    end,
    check = function(id, entity, params, tick)
      M.check(id, entity, params, tick)
    end,
  },
}

-- ------------------------------------------------------------------ кнопки хозяина (core/panel.lua)

local function evac_of(id)
  for _, r in ipairs(reflexes.get(id) or {}) do
    if r.type == "evacuate" then return r end
  end
  return nil
end

--- Набор тела без evacuate (только поля схем) и прежний evacuate.
local function set_without(id)
  local out, old = {}, nil
  for _, r in ipairs(reflexes.public(reflexes.get(id) or {})) do
    if r.type == "evacuate" then old = r else out[#out + 1] = r end
  end
  return out, old
end

--- Есть ли у тела охрана (evacuate в наборе).
function M.guarding(id)
  return evac_of(id) ~= nil
end

--- «Охранять здесь»: evacuate вокруг center с radius телу id — слово хозяина: «спросить» не нужно,
--- hold не мешает, предела MAX_DIST нет; «нельзя» в настройках мода запрещает. Прочие рефлексы
--- тела и прежние threat_radius, return_after_s, rebuild остаются.
--- → true │ nil, code, text, data.
function M.owner_guard(id, h, center, radius)
  local r = math.floor(tonumber(radius) or M.GUARD_RADIUS)
  if r < M.GUARD_MIN then r = M.GUARD_MIN elseif r > M.GUARD_MAX then r = M.GUARD_MAX end
  local set, old = set_without(id)
  local v = {
    type = "evacuate", center = { x = util.round1(center.x), y = util.round1(center.y) }, radius = r,
    threat_radius = old and old.threat_radius or nil, return_after_s = old and old.return_after_s or nil,
    rebuild = old and old.rebuild,
  }
  if v.rebuild == nil then v.rebuild = true end
  local ok, keys = pcall(perm_keys, v, { entity = h })
  if not ok then
    local code, text, data = err.normalize(keys)
    return nil, code, text, data
  end
  for _, k in ipairs(keys) do
    if perms.get(k) == "deny" then
      return nil, "owner_forbids", "запрещено в настройках мода: " .. perms.label(k), { perm = (k:gsub("^perm%-", "")) }
    end
  end
  set[#set + 1] = v
  local ok2, e = pcall(reflexes.op_reflexes, { set = set }, { helper_id = id, entity = h, owner_word = true, tick = game.tick })
  if not ok2 then
    local code, text, data = err.normalize(e)
    return nil, code, text, data
  end
  local st = M.state(id)
  if st ~= nil then st.remove_after = nil end
  return true, nil, nil, { center = v.center, radius = r }
end

--- «Снять охрану»: в спокойной фазе evacuate уходит из набора сразу ("removed"); идёт эвакуация или
--- постройки ждут возврата — уйдёт после возврата ("later"); охраны нет — "none".
--- → результат │ nil, code, text.
function M.owner_unguard(id, h)
  if evac_of(id) == nil then return "none" end
  local st = M.state(id)
  if st ~= nil and st.phase ~= nil and st.phase ~= "watch" then
    st.remove_after = true
    return "later"
  end
  local set = set_without(id)
  local ok, e = pcall(reflexes.op_reflexes, { set = set }, { helper_id = id, entity = h, owner_word = true, tick = game.tick })
  if not ok then
    local code, text = err.normalize(e)
    return nil, code, text
  end
  return "removed"
end

return M
