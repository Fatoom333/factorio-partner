-- Индекс построек хозяина: машины, лаборатории и горелки своей силы, которые ведутся по событиям
-- (построено, снесено, умерло, склонировано), а не сканом силы. Общий для `status` и рефлекса
-- `upkeep`. Устройство — по образцу registry.lua из factorio-codex (MIT, автор Matteo Mekhail):
-- события добавляют и убирают записи, сейв без индекса заполняется один раз «раскруткой» по
-- тикам; код написан заново, в проекте остались только идея и порядок работы.
--
-- Что хранится (storage.index; только простые таблицы и ссылки LuaEntity):
--   entries[unit] = { entity, unit, name, type, surface = индекс поверхности, x, y, force = имя,
--                     machine?, burner?, lab? }
--   machine / burner / lab — множества юнитов по виду; chunks[ключ] = множество юнитов чанка
--   (ключ — «поверхность:cx:cy»), по нему идёт выборка «в радиусе от точки».
--   ready — раскрутка закончена; boot — её состояние; count — записей всего.
--
-- Кто попадает: сущности силы хозяина (сила его тела-игрока или `player`) типов TYPES.
-- Раскрутка смотрит только открытые чанки (PROTOCOL §6.7: статичное — в открытых). Живое
-- (статус, топливо внутри) индекс не хранит: читающий берёт его у самой сущности и проверяет
-- видимость через scripts.core.vis.
--
-- Смерть: on_entity_died не слушается (у него уже стоит фильтр по персонажу у смерти помощника), запись
-- снимает on_object_destroyed — мёртвая сущность уничтожается в том же тике; до этого читающие
-- выбрасывают невалидные записи сами.
--
-- Сила и позиция: события смены силы у сущности в API нет, телепорт тоже не событие, поэтому
-- `near` сверяет их при выдаче: сменилась сила — запись снимается, сместилась позиция — запись
-- перекладывается в нужный чанк и отдаётся с новой позицией.
--
-- Бюджет: раскрутка — не больше BOOT_CHUNKS чанков и BOOT_ENTITIES найденных построек за тик;
-- список открытых чанков поверхности тоже собирается порциями (не больше LIST_CHUNKS чанков за
-- тик: итератор get_chunks в сейв не положить, поэтому он держится в кэше модуля и идёт дальше
-- без прохода с начала; после загрузки сейва его один раз проматывают по счётчику).
-- Пока раскрутка идёт, `ready` = false, читающие это видят и пишут в ответе.
local owner = require("scripts.core.owner")

local M = {}
M.name = "core.index"

M.VERSION = 1
M.BOOT_CHUNKS = 4
M.BOOT_ENTITIES = 400
M.LIST_CHUNKS = 2000

-- Типы сущностей, у которых есть статус и работа. Имён прототипов здесь нет.
local MACHINE_TYPES = {
  "assembling-machine", "furnace", "mining-drill", "rocket-silo", "lab", "boiler", "generator",
  "burner-generator", "reactor", "fusion-reactor", "fusion-generator", "agricultural-tower",
}
-- Попадают в индекс только с горелкой (электрических манипуляторов тысячи, они не нужны).
local BURNER_ONLY_TYPES = { "inserter" }

M.MACHINE = {}
M.TYPES = {}
for _, t in ipairs(MACHINE_TYPES) do
  M.MACHINE[t] = true
  M.TYPES[#M.TYPES + 1] = t
end
local BURNER_ONLY = {}
for _, t in ipairs(BURNER_ONLY_TYPES) do
  BURNER_ONLY[t] = true
  M.TYPES[#M.TYPES + 1] = t
end
local TYPE_SET = {}
for _, t in ipairs(M.TYPES) do TYPE_SET[t] = true end

local KINDS = { machine = true, burner = true, lab = true }

local floor, sqrt = math.floor, math.sqrt

-- ---------------------------------------------------------------- хранилище

local function fresh()
  return {
    v = M.VERSION, entries = {}, chunks = {}, machine = {}, burner = {}, lab = {},
    count = 0, ready = false, boot = nil,
  }
end

local function data()
  local d = storage.index
  if type(d) ~= "table" or d.v ~= M.VERSION then
    d = fresh()
    storage.index = d
  end
  return d
end

local function chunk_key(surface, cx, cy)
  return surface .. ":" .. cx .. ":" .. cy
end

--- Сила хозяина: сила его игрока, иначе `player`. nil — силы нет (тест без мира).
local function own_force()
  local ok, p = pcall(owner.player)
  if ok and p ~= nil and p.valid then
    local ok2, f = pcall(function() return p.force end)
    if ok2 and f ~= nil then return f end
  end
  local forces = game and game.forces
  if forces ~= nil then
    local ok3, f = pcall(function() return forces.player end)
    if ok3 then return f end
  end
  return nil
end

local function prop(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

-- ---------------------------------------------------------------- запись и снятие

--- Добавить сущность (повтор безопасен). → true, если запись новая.
function M.add(entity)
  if entity == nil or not entity.valid then return false end
  local kind = entity.type
  if not TYPE_SET[kind] then return false end
  local unit = entity.unit_number
  if unit == nil then return false end
  local d = data()
  if d.entries[unit] ~= nil then return false end
  local force = own_force()
  local ef = prop(entity, "force")
  if force == nil or ef == nil or ef.name ~= force.name then return false end
  local has_burner = prop(entity, "burner") ~= nil
  if BURNER_ONLY[kind] and not has_burner then return false end
  local pos = entity.position
  local sidx = prop(entity.surface, "index")
  if sidx == nil then return false end
  local entry = {
    entity = entity, unit = unit, name = entity.name, type = kind, surface = sidx,
    x = pos.x or pos[1], y = pos.y or pos[2], force = force.name,
  }
  if M.MACHINE[kind] then entry.machine = true end
  if has_burner then entry.burner = true end
  if kind == "lab" then entry.lab = true end
  entry.key = chunk_key(sidx, floor(entry.x / 32), floor(entry.y / 32))
  d.entries[unit] = entry
  d.count = d.count + 1
  for k in pairs(KINDS) do
    if entry[k] then d[k][unit] = true end
  end
  local bucket = d.chunks[entry.key]
  if bucket == nil then
    bucket = {}
    d.chunks[entry.key] = bucket
  end
  bucket[unit] = true
  if script ~= nil and script.register_on_object_destroyed ~= nil then
    pcall(script.register_on_object_destroyed, entity)
  end
  return true
end

--- Убрать запись по номеру юнита. → снятая запись или nil.
function M.remove(unit)
  if unit == nil then return nil end
  local d = data()
  local entry = d.entries[unit]
  if entry == nil then return nil end
  d.entries[unit] = nil
  d.count = math.max(0, d.count - 1)
  for k in pairs(KINDS) do d[k][unit] = nil end
  local bucket = d.chunks[entry.key]
  if bucket ~= nil then
    bucket[unit] = nil
    if next(bucket) == nil then d.chunks[entry.key] = nil end
  end
  return entry
end

--- Переложить запись на новую позицию (телепорт): сменить чанк, если он другой.
local function relocate(d, e, x, y)
  e.x, e.y = x, y
  local key = chunk_key(e.surface, floor(x / 32), floor(y / 32))
  if key == e.key then return end
  local bucket = d.chunks[e.key]
  if bucket ~= nil then
    bucket[e.unit] = nil
    if next(bucket) == nil then d.chunks[e.key] = nil end
  end
  e.key = key
  local nb = d.chunks[key]
  if nb == nil then
    nb = {}
    d.chunks[key] = nb
  end
  nb[e.unit] = true
end

-- ---------------------------------------------------------------- чтение

function M.ready()
  local d = storage.index
  return type(d) == "table" and d.v == M.VERSION and d.ready == true
end

--- Сводка: { ready, total, machine, burner, lab }.
function M.counts()
  local d = data()
  local out = { ready = d.ready == true, total = d.count }
  for k in pairs(KINDS) do
    local n = 0
    for _ in pairs(d[k]) do n = n + 1 end
    out[k] = n
  end
  return out
end

--- Записи вида kind ("machine" | "burner" | "lab") своей силы force_name на поверхности surface
--- (индекс) в радиусе radius от center, ближние первыми:
--- { {entity, unit, name, type, pos = {x, y}, dist}, ... }. Записи с невалидной сущностью по пути
--- снимаются. Видимость и живые данные проверяет вызывающий.
function M.near(kind, surface, center, radius, force_name)
  if not KINDS[kind] then error("index.near: unknown kind " .. tostring(kind), 2) end
  local d = data()
  local cx, cy = center.x or center[1], center.y or center[2]
  local x0, x1 = floor((cx - radius) / 32), floor((cx + radius) / 32)
  local y0, y1 = floor((cy - radius) / 32), floor((cy + radius) / 32)
  local r2 = radius * radius
  local out = {}
  local seen = {}
  local function take(unit, e)
    seen[unit] = true
    local ent = e.entity
    if ent == nil or not ent.valid then
      M.remove(unit)
      return
    end
    local ef = prop(ent, "force")
    if ef == nil or ef.name ~= e.force then
      M.remove(unit) -- сила сменилась: события нет, ловим при выдаче
      return
    end
    local pos = ent.position
    local px, py = pos.x or pos[1], pos.y or pos[2]
    if px ~= e.x or py ~= e.y then
      relocate(d, e, px, py) -- телепорт: события нет, ловим при выдаче
    end
    local dx, dy = e.x - cx, e.y - cy
    local q = dx * dx + dy * dy
    if q <= r2 then
      out[#out + 1] = {
        entity = ent, unit = unit, name = e.name, type = e.type,
        pos = { x = e.x, y = e.y }, dist = sqrt(q),
      }
    end
  end
  for gx = x0, x1 do
    for gy = y0, y1 do
      local bucket = d.chunks[chunk_key(surface, gx, gy)]
      if bucket ~= nil then
        local units = {}
        for unit in pairs(bucket) do units[#units + 1] = unit end
        for _, unit in ipairs(units) do
          local e = d.entries[unit]
          if e ~= nil and not seen[unit] and e[kind] and (force_name == nil or e.force == force_name) then
            take(unit, e)
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    return a.unit < b.unit
  end)
  return out
end

-- ---------------------------------------------------------------- раскрутка

local function surface_names()
  local list = {}
  for name, s in pairs(game.surfaces) do
    if type(name) == "string" and s ~= nil and s.valid then list[#list + 1] = { name = name, index = s.index } end
  end
  table.sort(list, function(a, b) return a.index < b.index end)
  local names = {}
  for i, s in ipairs(list) do names[i] = s.name end
  return names
end

-- Итератор get_chunks текущей раскрутки: кэш модуля, не storage. {name, index, skip, it, pos}:
-- pos — сколько чанков он уже отдал; совпало с b.skip — продолжаем, нет — собираем заново.
-- Только в одиночной игре: в сетевой у присоединившегося клиента кэша нет, и если между тиками
-- появились новые чанки, его заново созданный итератор отдал бы их в другом порядке, чем старый
-- итератор хоста, — разные b.list, рассинхрон. Поэтому в сетевой игре итератор каждую порцию
-- создаётся заново и проматывается на b.skip у всех участников одинаково.
local LIVE = nil

--- Счётчики для проверки сложности: сколько раз дёрнули итератор get_chunks и сколько раз его создали.
M.stats = { steps = 0, opened = 0 }

local function next_chunk(it)
  M.stats.steps = M.stats.steps + 1
  return it.it()
end

--- Итератор чанков поверхности, стоящий после skip чанков.
local function chunk_iter(surface, name, skip)
  local cache = not game.is_multiplayer()
  if not cache then LIVE = nil end
  if cache and skip > 0 and LIVE ~= nil and LIVE.name == name and LIVE.index == surface.index
      and LIVE.pos == skip then
    return LIVE
  end
  local it = { name = name, index = surface.index, it = surface.get_chunks(), pos = 0 }
  M.stats.opened = M.stats.opened + 1
  for _ = 1, skip do
    if next_chunk(it) == nil then break end
  end
  it.pos = skip
  if cache then LIVE = it end
  return it
end

local function boot_step(d)
  local b = d.boot
  if b == nil then
    d.boot = { surfaces = surface_names(), si = 1 }
    return
  end
  local force = own_force()
  if force == nil then return end
  local budget = M.BOOT_ENTITIES
  local chunks = 0
  while b.si <= #b.surfaces do
    local surface = game.surfaces[b.surfaces[b.si]]
    if surface == nil or not surface.valid then
      b.si, b.list, b.ci, b.skip = b.si + 1, nil, nil, nil
    elseif b.list == nil then
      b.list, b.ci, b.skip = {}, nil, 0
    elseif b.ci == nil then
      -- список открытых чанков поверхности — порцией за тик. Итератор живёт в кэше модуля (не в
      -- storage) и идёт дальше с того места, где остановился; после загрузки сейва кэша нет, и
      -- итератор один раз проматывается на b.skip чанков (счётчик в storage), дальше снова без прохода
      local it = chunk_iter(surface, b.surfaces[b.si], b.skip)
      local took, finished = 0, false
      while took < M.LIST_CHUNKS do
        local chunk = next_chunk(it)
        if chunk == nil then finished = true break end
        took = took + 1
        if force.is_chunk_charted(surface, { x = chunk.x, y = chunk.y }) then
          b.list[#b.list + 1] = chunk.x
          b.list[#b.list + 1] = chunk.y
        end
      end
      b.skip = b.skip + took
      it.pos = b.skip
      if finished then
        b.ci = 1
        LIVE = nil
      end
      return
    elseif b.ci > #b.list then
      b.si, b.list, b.ci, b.skip = b.si + 1, nil, nil, nil
    else
      if chunks >= M.BOOT_CHUNKS or budget <= 0 then return end
      local x, y = b.list[b.ci], b.list[b.ci + 1]
      b.ci = b.ci + 2
      chunks = chunks + 1
      local found = surface.find_entities_filtered{
        area = { { x * 32, y * 32 }, { x * 32 + 32, y * 32 + 32 } }, force = force, type = M.TYPES,
      }
      for _, e in ipairs(found) do
        budget = budget - 1
        M.add(e)
      end
    end
  end
  d.ready, d.boot = true, nil
end

--- Каждый тик: шаг раскрутки, пока она не закончена.
function M.step()
  local d = data()
  if d.ready then return end
  local ok, e = pcall(boot_step, d)
  if not ok then LIVE = nil end
  d.error = (not ok) and tostring(e) or nil
end

--- Начать раскрутку заново (смена набора модов): записи остаются, добавление идемпотентно.
function M.rescan()
  local d = data()
  d.ready, d.boot = false, nil
  LIVE = nil
end

-- ---------------------------------------------------------------- события

local function entity_of(e)
  return e.entity or e.created_entity or e.destination
end

function M.on_built(e)
  local ent = entity_of(e)
  if ent ~= nil then M.add(ent) end
end

function M.on_removed(e)
  local ent = e.entity
  if ent == nil then return end
  local ok, unit = pcall(function() return ent.unit_number end)
  if ok and unit ~= nil then M.remove(unit) end
end

function M.on_destroyed(e)
  local target = defines.target_type and defines.target_type.entity
  if target ~= nil and e.type ~= nil and e.type ~= target then return end
  M.remove(e.useful_id)
end

function M.on_surface_deleted(e)
  local d = data()
  local gone = {}
  for unit, entry in pairs(d.entries) do
    if entry.surface == e.surface_index then gone[#gone + 1] = unit end
  end
  for _, unit in ipairs(gone) do M.remove(unit) end
end

local FILTER = {}
for _, t in ipairs(M.TYPES) do FILTER[#FILTER + 1] = { filter = "type", type = t } end

local ev = defines.events
M.events = {}
for _, name in ipairs { "on_built_entity", "on_robot_built_entity", "on_space_platform_built_entity",
  "script_raised_built", "script_raised_revive", "on_entity_cloned" } do
  if ev[name] ~= nil then M.events[ev[name]] = { handler = M.on_built, filter = FILTER } end
end
for _, name in ipairs { "on_player_mined_entity", "on_robot_mined_entity", "on_space_platform_mined_entity",
  "script_raised_destroy" } do
  if ev[name] ~= nil then M.events[ev[name]] = { handler = M.on_removed, filter = FILTER } end
end
M.events[ev.on_object_destroyed] = M.on_destroyed
M.events[ev.on_surface_deleted] = M.on_surface_deleted
M.events[ev.on_tick] = M.step

function M.on_init() data() end

function M.on_configuration_changed() M.rescan() end

return M
