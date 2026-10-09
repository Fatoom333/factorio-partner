-- Помощники (поток A): storage.helpers, операции helper_spawn/remove/list, учёт смерти и
-- исчезновения тела. Контракт: PROTOCOL.md §4, §6.9, §7.
--
-- storage.helpers[id] = {
--   entity, unit_number, state = "alive"|"dead"|"removed", reg (номер register_on_object_destroyed),
--   spawned_tick, died_tick, died_pos, corpse_pos, removed_tick }
--
-- API для модулей (только чтение storage.helpers напрямую; запись — через функции ниже):
--   registry.get(id) -> rec|nil
--   registry.alive(id) -> rec, entity | nil       (state="alive" и entity.valid)
--   registry.mark_dead(id, corpse_pos?)           (ядро делает это само в on_entity_died)
--   registry.set_body(id, entity)                 (возрождение, поток H: новое тело после смерти)
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local owner = require("scripts.core.owner")
local events = require("scripts.core.events")
local schema = require("scripts.core.schema")

local M = {}

M.COOLDOWN = 5 * 60 * 60   -- 5 мин после helper_remove / смерти (PROTOCOL §4)
M.SPAWN_RADIUS = 10        -- тело появляется не дальше 10 клеток от хозяина
M.MAX_ALIVE = 4            -- одновременно живых помощников
M.MAX_RECORDS = 32         -- записей в storage.helpers (включая удалённые — для перезарядки)

-- Крючки, которые ставит ядро (init.lua): что сделать с задачами и резервами помощника.
M.hooks = {
  before_remove = function(id) end, -- helper_remove: до die()
  on_dead = function(id) end,       -- смерть (тело ещё valid)
  on_lost = function(id) end,       -- тело исчезло не по смерти
}

function M.get(id)
  return storage.helpers[id]
end

function M.alive(id)
  local rec = storage.helpers[id]
  if rec and rec.state == "alive" and rec.entity and rec.entity.valid then
    return rec, rec.entity
  end
  return nil
end

--- Для операций «h»: живой помощник или ошибка no_helper.
function M.require_alive(id)
  local rec, e = M.alive(id)
  if not rec then err.raise("no_helper", "helper " .. tostring(id) .. " is absent or dead") end
  return rec, e
end

function M.find_by_unit(unit_number)
  if unit_number == nil then return nil end
  for id, rec in pairs(storage.helpers) do
    if rec.unit_number == unit_number then return id, rec end
  end
  return nil
end

--- Отсортированный список id.
function M.ids(filter_state)
  local out = {}
  for id, rec in pairs(storage.helpers) do
    if filter_state == nil or rec.state == filter_state then out[#out + 1] = id end
  end
  table.sort(out)
  return out
end

local function count_alive(except)
  local n = 0
  for id in pairs(storage.helpers) do
    if id ~= except and M.alive(id) then n = n + 1 end
  end
  return n
end

--- Сколько тиков ещё ждать до helper_spawn (0 — можно).
function M.cooldown_left(rec)
  if rec == nil then return 0 end
  local since
  if rec.state == "removed" then since = rec.removed_tick or rec.died_tick
  elseif rec.state == "dead" then since = rec.died_tick end
  if since == nil then return 0 end
  return math.max(0, since + M.COOLDOWN - game.tick)
end

local function purge_old_records()
  for id, rec in pairs(storage.helpers) do
    if rec.state == "removed" and M.cooldown_left(rec) == 0 then storage.helpers[id] = nil end
  end
end

local function attach(rec, entity)
  rec.entity = entity
  rec.unit_number = entity.unit_number
  rec.state = "alive"
  rec.reg = script.register_on_object_destroyed(entity)
end

--- Отметить смерть (state alive -> dead). Вызывается ядром из on_entity_died.
function M.mark_dead(id, corpse_pos)
  local rec = storage.helpers[id]
  if rec == nil or rec.state ~= "alive" then return false end
  local e = rec.entity
  rec.state = "dead"
  rec.died_tick = game.tick
  if e and e.valid then rec.died_pos = util.pos(e.position) end
  if corpse_pos then rec.corpse_pos = util.pos(corpse_pos) end
  return true
end

--- Новое тело помощника (возрождение после смерти, поток H, PROTOCOL §6.9).
--- Сущность создаёт вызывающий (у force.get_spawn_position той же поверхности, пустой инвентарь).
function M.set_body(id, entity)
  local rec = storage.helpers[id]
  if rec == nil or rec.state ~= "dead" then error("registry.set_body: helper " .. tostring(id) .. " is not dead", 2) end
  if not (entity and entity.valid and entity.type == "character") then error("registry.set_body: not a character", 2) end
  attach(rec, entity)
  rec.spawned_tick = game.tick
  rec.corpse_pos = nil
  return rec
end

-- ------------------------------------------------------------------ операции

function M.op_spawn(args, ctx)
  schema.validate({}, args)
  local id = ctx.helper_id
  local rec = storage.helpers[id]
  if rec and rec.state == "alive" and rec.entity and rec.entity.valid then
    err.raise("helper_exists", "helper " .. id .. " is alive")
  end
  local left = M.cooldown_left(rec)
  if left > 0 then
    err.raise("cooldown", "helper_spawn possible in " .. math.ceil(left / 60) .. " s")
  end
  if count_alive(id) >= M.MAX_ALIVE then
    err.raise("limit", "at most " .. M.MAX_ALIVE .. " helpers")
  end
  if rec == nil and util.count(storage.helpers) >= M.MAX_RECORDS then
    purge_old_records()
    if util.count(storage.helpers) >= M.MAX_RECORDS then err.raise("limit", "too many helper ids") end
  end
  local p, surface, anchor = owner.spawn_anchor()
  if not p then err.raise("no_player", "owner is not in the save, or is online without a character") end
  local center = util.xy(anchor)
  local pos = surface.find_non_colliding_position("character", { x = center.x + 2, y = center.y }, M.SPAWN_RADIUS - 2, 0.5)
  if pos == nil then err.raise("cannot_place", "no free place near the owner") end
  pos = util.xy(pos)
  if util.dist(pos, center) > M.SPAWN_RADIUS then err.raise("cannot_place", "no free place near the owner") end
  local e = surface.create_entity{ name = "character", position = pos, force = p.force, quality = "normal" }
  if e == nil then err.raise("cannot_place", "character was not created") end
  local new = {
    spawned_tick = game.tick,
    removed_tick = rec and rec.removed_tick or nil,
    died_tick = rec and rec.died_tick or nil,
  }
  attach(new, e)
  storage.helpers[id] = new
  return { helper = id, unit_number = e.unit_number, surface = surface.name, pos = util.pos(e.position) }
end

local function find_corpse(surface, pos, tick)
  local list = surface.find_entities_filtered{ type = "character-corpse", position = pos, radius = 3 }
  local best, bestd
  for _, c in ipairs(list) do
    if c.valid and (c.character_corpse_tick_of_death == nil or c.character_corpse_tick_of_death == tick) then
      local d = util.dist(util.xy(c.position), pos)
      if best == nil or d < bestd then best, bestd = c, d end
    end
  end
  return best
end

function M.op_remove(args, ctx)
  schema.validate({}, args)
  local id = ctx.helper_id
  local rec = storage.helpers[id]
  if rec == nil or rec.state == "removed" then err.raise("no_helper", "helper " .. id .. " does not exist") end
  if rec.state == "dead" then
    -- тела нет; перезарядка идёт от died_tick (removed_tick не ставим — иначе отсчёт начнётся заново)
    M.hooks.before_remove(id)
    rec.state = "removed"
    rec.removed_tick = nil
    rec.entity = nil
    return { corpse = rec.corpse_pos }
  end
  M.hooks.before_remove(id)
  local data = {}
  local e = rec.entity
  -- state="removed" ставится ДО die(): рефлекс смерти (H) такие события игнорирует (PROTOCOL §7)
  rec.state = "removed"
  rec.removed_tick = game.tick
  if e and e.valid then
    local surface = e.surface
    local pos = util.xy(e.position)
    rec.corpse_pos = nil
    e.die()
    if rec.corpse_pos == nil then
      local c = find_corpse(surface, pos, game.tick)
      if c then rec.corpse_pos = util.pos(c.position) end
    end
    data.corpse = rec.corpse_pos
  end
  rec.entity = nil
  return data
end

function M.op_list(args, ctx, jobs_active)
  schema.validate({}, args)
  local out = {}
  for _, id in ipairs(M.ids()) do
    local rec = storage.helpers[id]
    local item = { id = id, state = rec.state }
    local e = rec.entity
    if rec.state == "alive" and e and e.valid then
      item.surface = e.surface.name
      item.pos = util.pos(e.position)
    elseif rec.state == "dead" then
      item.pos = rec.died_pos
      item.corpse = rec.corpse_pos
    end
    local left = M.cooldown_left(rec)
    if left > 0 then item.cooldown_s = math.ceil(left / 60) end
    if jobs_active then item.job = jobs_active(id) end
    out[#out + 1] = item
  end
  return { helpers = out }
end

-- ------------------------------------------------------------------ события игры

function M.on_entity_died(e)
  local ent = e.entity
  if not (ent and ent.valid and ent.type == "character") then return end
  local id = M.find_by_unit(ent.unit_number)
  if id == nil then return end
  local rec = storage.helpers[id]
  if rec.state ~= "alive" then return end
  M.hooks.on_dead(id)
  M.mark_dead(id)
end

function M.on_post_entity_died(e)
  local id, rec = M.find_by_unit(e.unit_number)
  if id == nil then return end
  if rec.state ~= "dead" and rec.state ~= "removed" then return end
  local c = e.corpses and e.corpses[1]
  if c and c.valid then rec.corpse_pos = util.pos(c.position) end
end

function M.on_object_destroyed(e)
  for id, rec in pairs(storage.helpers) do
    if rec.reg ~= nil and rec.reg == e.registration_number then
      rec.reg = nil
      if rec.state == "alive" then
        M.hooks.on_lost(id)
        rec.state = "removed"
        rec.removed_tick = game.tick
        rec.entity = nil
        events.emit(id, "helper_lost", { reason = "destroyed" })
      end
      return
    end
  end
end

return M
