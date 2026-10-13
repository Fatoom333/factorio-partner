-- Помощники (поток A): storage.helpers, операции helper_spawn/remove/list, учёт смерти и
-- исчезновения тела. Контракт: PROTOCOL.md §4, §6.9, §7.
--
-- storage.helpers[id] = {
--   entity, unit_number, state = "alive"|"dead"|"away"|"removed", reg (номер register_on_object_destroyed),
--   spawned_tick, died_tick, died_pos, corpse_pos, removed_tick,
--   char_gone_tick?, -- тик, с которого идёт перезарядка helper_spawn после прежнего тела-персонажа
--                    -- этого id; переживает привязку и отвязку тела-игрока (PROTOCOL §4: пара
--                    -- remove→spawn не телепорт, в том числе через helper_attach между ними)
--   player_index?,   -- тело-игрок (PROTOCOL §7 «Два вида тела»): персонаж второго клиента
--   away?, away_pos?, away_surface?, hold? }
--                    -- только у тела-игрока, пишет scripts/core/attach.lua: state="away" — тела
--                    -- сейчас нет не по смерти (игрок вышел, остался без персонажа), away — почему,
--                    -- away_pos/away_surface — где тело было в последний раз; hold — состояния
--                    -- ходьбы и добычи активного действия, которые ядро выставляет каждый тик
--
-- Лимит (PROTOCOL §4, ревизия 3.3): занятых мест (живые + ждущие возрождения + away) ≤
-- storage.proto.max_helpers (по умолчанию 1, задаёт игрок при запуске: helper_limit {max:1..16}).
--
-- API для модулей (только чтение storage.helpers напрямую; запись — через функции ниже):
--   registry.get(id) -> rec|nil
--   registry.alive(id) -> rec, entity | nil       (state="alive" и entity.valid)
--   registry.mark_dead(id, corpse_pos?)           (ядро делает это само в on_entity_died)
--   registry.set_body(id, entity)                 (возрождение, поток H: новое тело после смерти)
--   registry.max_helpers() / registry.occupied(except_id?)   (лимит и занятые места)
--   registry.check_slot(id)                       (limit, если для нового тела id нет места)
--   registry.bind(id, entity, fields?) -> rec     (новая запись с живым телом; fields.player_index —
--                                                  тело-игрок, операция helper_attach потока P)
--   registry.is_player_body(id) -> bool
--   registry.body_kind(id) -> "character"|"player"
--   registry.info(id) -> {body, module_errors}    (для операции `state`, STATE.md: вид тела и счётчик
--                                                  падений модулей — тот же, что в `hello`)
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local owner = require("scripts.core.owner")
local events = require("scripts.core.events")
local schema = require("scripts.core.schema")

local M = {}

M.COOLDOWN = 600           -- 10 с после helper_remove / смерти, как возрождение в игре (PROTOCOL §4)
M.NEAR_AFTER = 5 * 60 * 60 -- раньше 5 мин после ухода любого тела новое появляется в точке возрождения
M.RESPAWN_RADIUS = 16      -- поиск свободного места вокруг точки возрождения
M.SPAWN_RADIUS = 10        -- тело появляется не дальше 10 клеток от хозяина
M.DEFAULT_MAX_HELPERS = 1  -- storage.proto.max_helpers, пока игрок не задал своё (helper_limit)
M.MAX_HELPERS_CAP = 16     -- верхняя граница helper_limit
M.MAX_RECORDS = 32         -- записей в storage.helpers (включая удалённые — для перезарядки)

-- Крючки, которые ставит ядро (init.lua): что сделать с задачами и резервами помощника.
M.hooks = {
  before_remove = function(id) end, -- helper_remove: до die()
  on_dead = function(id) end,       -- смерть (тело ещё valid)
  on_lost = function(id) end,       -- тело исчезло не по смерти
  -- тело-игрок исчезло не по смерти: true — запись забрал поток P (ждёт новое тело игрока)
  on_player_body_gone = function(id) return false end,
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

--- Сколько помощников разрешил игрок (storage.proto.max_helpers; по умолчанию 1).
function M.max_helpers()
  local p = storage.proto
  local v = type(p) == "table" and p.max_helpers or nil
  if type(v) ~= "number" or v < 1 then return M.DEFAULT_MAX_HELPERS end
  if v > M.MAX_HELPERS_CAP then return M.MAX_HELPERS_CAP end
  return math.floor(v)
end

--- Занятые места лимита: живые, мёртвые, ждущие возрождения (PROTOCOL §6.9: мёртвый место
--- держит, поэтому возрождение лимит не превышает), и тела-игроки в состоянии `away` (§7: игрок
--- вышел — место держится). except — id, который не считать. Второе значение — сколько живых.
function M.occupied(except)
  local n, alive = 0, 0
  for id, rec in pairs(storage.helpers) do
    if id ~= except then
      if M.alive(id) then
        n = n + 1
        alive = alive + 1
      elseif rec.state == "dead" or rec.state == "away" then
        n = n + 1
      end
    end
  end
  return n, alive
end

--- Тик, с которого идёт перезарядка helper_spawn для записи (nil — перезарядки нет).
--- Своё тело-игрок перезарядки не даёт (PROTOCOL §7: отвязка без перезарядки), но перезарядка
--- прежнего тела-персонажа того же id (char_gone_tick) остаётся: иначе цепочка
--- remove → attach → remove → spawn переносила бы тело к хозяину без ожидания (§4).
local function cooldown_since(rec)
  local since
  if rec.player_index == nil then
    if rec.state == "removed" then since = rec.removed_tick or rec.died_tick
    elseif rec.state == "dead" then since = rec.died_tick end
  end
  local prev = rec.char_gone_tick
  if type(prev) == "number" and (since == nil or prev > since) then since = prev end
  return since
end

--- Сколько тиков ещё ждать до helper_spawn (0 — можно).
function M.cooldown_left(rec)
  if rec == nil then return 0 end
  -- тело-игрок, пока привязано (живое, мёртвое, away): helper_spawn и так ответит helper_exists
  if rec.player_index ~= nil and rec.state ~= "removed" then return 0 end
  local since = cooldown_since(rec)
  if since == nil then return 0 end
  return math.max(0, since + M.COOLDOWN - game.tick)
end

local function purge_old_records()
  for id, rec in pairs(storage.helpers) do
    -- запись живёт всё окно NEAR_AFTER: по ней helper_spawn решает, где появиться телу
    local since = cooldown_since(rec)
    if rec.state == "removed" and (since == nil or since + M.NEAR_AFTER <= game.tick) then
      storage.helpers[id] = nil
    end
  end
end

local function attach(rec, entity)
  rec.entity = entity
  rec.unit_number = entity.unit_number
  rec.state = "alive"
  rec.reg = script.register_on_object_destroyed(entity)
end

--- Есть ли место для нового тела помощника id: лимит max_helpers (сам id не считается — его
--- запись заменяется) и число записей. Нет — ошибка `limit`.
function M.check_slot(id)
  local max = M.max_helpers()
  if M.occupied(id) >= max then
    err.raise("limit", "at most " .. max .. " helpers (helper_limit sets the number)")
  end
  if storage.helpers[id] == nil and util.count(storage.helpers) >= M.MAX_RECORDS then
    purge_old_records()
    if util.count(storage.helpers) >= M.MAX_RECORDS then err.raise("limit", "too many helper ids") end
  end
end

--- Новая запись помощника с живым телом (заменяет прежнюю запись id; отметки перезарядки
--- переносятся: у тела-игрока — одним полем char_gone_tick, которое helper_remove не стирает). fields — простые поля записи (player_index у тела-игрока).
--- Проверки (лимит, перезарядка, чьё тело) делает вызывающий: helper_spawn здесь, helper_attach — поток P.
function M.bind(id, entity, fields)
  if not (entity and entity.valid and entity.type == "character") then error("registry.bind: not a character", 2) end
  local old = storage.helpers[id]
  local new = {
    spawned_tick = game.tick,
    removed_tick = old and old.removed_tick or nil,
    died_tick = old and old.died_tick or nil,
  }
  for k, v in pairs(fields or {}) do
    if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then new[k] = v end
  end
  -- после fields: вызывающий это поле задать не может
  new.char_gone_tick = old and cooldown_since(old) or nil
  if new.player_index ~= nil then
    -- отметки тела-персонажа в записи тела-игрока не живут (died_tick здесь — смерть игрока)
    new.removed_tick = nil
    new.died_tick = nil
  end
  attach(new, entity)
  storage.helpers[id] = new
  return new
end

--- Тело-игрок (персонаж подключённого второго клиента, PROTOCOL §7)?
function M.is_player_body(id)
  local rec = storage.helpers[id]
  return rec ~= nil and rec.player_index ~= nil
end

--- Вид тела помощника: "player" — персонаж второго клиента, иначе "character" (PROTOCOL §7).
function M.body_kind(id)
  return M.is_player_body(id) and "player" or "character"
end

--- Сведения ядра для операции `state` (STATE.md: поля `body` и `module_errors`). Только чтение.
--- Вызывает perception/state.lua: `local info = require("scripts.core.registry").info(helper_id)`.
function M.info(id)
  return { body = M.body_kind(id), module_errors = err.module_errors() }
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
--- У тела-игрока (scripts/core/attach.lua) — ещё и возврат из "away": тело то же или новое, его
--- даёт движок, мод ничего не создаёт.
function M.set_body(id, entity)
  local rec = storage.helpers[id]
  if rec == nil or not (rec.state == "dead" or (rec.state == "away" and rec.player_index ~= nil)) then
    error("registry.set_body: helper " .. tostring(id) .. " is not dead or away", 2)
  end
  if not (entity and entity.valid and entity.type == "character") then error("registry.set_body: not a character", 2) end
  attach(rec, entity)
  rec.spawned_tick = game.tick
  rec.corpse_pos = nil
  rec.away = nil
  rec.away_pos = nil
  rec.away_surface = nil
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
  if rec and rec.player_index ~= nil and rec.state ~= "removed" then
    -- тело-игрок ждёт игрока или возрождения движком: запись держит место, новое тело поверх
    -- неё не создаём (сначала helper_remove)
    err.raise("helper_exists", "helper " .. id .. " is bound to a player body (helper_remove detaches it)")
  end
  local left = M.cooldown_left(rec)
  if left > 0 then
    err.raise("cooldown", "helper_spawn possible in " .. math.ceil(left / 60) .. " s")
  end
  M.check_slot(id)
  -- перезарядка и окно общие для всех id (PROTOCOL §4): иначе helper_remove h1 → helper_spawn h2
  -- переносил бы тело к хозяину. Пока окно NEAR_AFTER не прошло, новое тело появляется в точке
  -- возрождения силы (как игрок после смерти) и идёт пешком.
  local recent = false
  for _, other in pairs(storage.helpers) do
    local since = cooldown_since(other)
    if since ~= nil then
      left = math.max(left, since + M.COOLDOWN - game.tick)
      if since + M.NEAR_AFTER > game.tick then recent = true end
    end
  end
  if left > 0 then
    err.raise("cooldown", "helper_spawn possible in " .. math.ceil(left / 60) .. " s")
  end
  local p, surface, anchor = owner.spawn_anchor()
  if not p then err.raise("no_player", "owner is not in the save, or is online without a character") end
  local pos
  if recent then
    local spawn = util.xy(p.force.get_spawn_position(surface))
    pos = surface.find_non_colliding_position("character", spawn, M.RESPAWN_RADIUS, 0.5)
    if pos == nil then err.raise("cannot_place", "no free place near the respawn point") end
    pos = util.xy(pos)
  else
    local center = util.xy(anchor)
    pos = surface.find_non_colliding_position("character", { x = center.x + 2, y = center.y }, M.SPAWN_RADIUS - 2, 0.5)
    if pos == nil then err.raise("cannot_place", "no free place near the owner") end
    pos = util.xy(pos)
    if util.dist(pos, center) > M.SPAWN_RADIUS then err.raise("cannot_place", "no free place near the owner") end
  end
  local e = surface.create_entity{ name = "character", position = pos, force = p.force, quality = "normal" }
  if e == nil then err.raise("cannot_place", "character was not created") end
  M.bind(id, e)
  return { helper = id, unit_number = e.unit_number, surface = surface.name, pos = util.pos(e.position),
           at = recent and "respawn_point" or "owner" }
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
  if rec.player_index ~= nil then
    -- тело-игрок в любом состоянии (живое, мёртвое, away): только отвязать, персонажа игрока не
    -- убивать (PROTOCOL §7); трупа в ответе и перезарядки нет — тело не создаётся и не
    -- переносится, телепортом пара detach/attach служить не может. char_gone_tick (перезарядка
    -- прежнего тела-персонажа этого id) не трогаем: helper_spawn её дождётся
    M.hooks.before_remove(id)
    rec.state = "removed"
    rec.removed_tick = nil
    rec.died_tick = nil
    rec.corpse_pos = nil
    rec.entity = nil
    rec.reg = nil
    rec.away = nil
    rec.away_pos = nil
    rec.away_surface = nil
    rec.hold = nil
    return {}
  end
  if rec.state == "dead" then
    -- тела нет; перезарядка идёт от died_tick (removed_tick не ставим — иначе отсчёт начнётся заново)
    M.hooks.before_remove(id)
    rec.state = "removed"
    rec.removed_tick = nil
    rec.entity = nil
    rec.away = nil
    rec.hold = nil
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

local LIMIT_SCHEMA = { max = { type = "int", required = true, min = 1, max = M.MAX_HELPERS_CAP } }

--- helper_limit {max:1..16} -> {max, alive} (PROTOCOL §4). Админская операция: её шлёт скрипт
--- запуска напарника («сколько помощников?»), агентам сервер её не даёт. Нижняя граница —
--- занятые места (живые + ждущие возрождения + away): ниже опустить нельзя — `limit`.
--- `alive` в ответе — только живые.
function M.op_limit(args, ctx)
  local a = schema.validate(LIMIT_SCHEMA, args)
  local occupied, alive = M.occupied()
  if a.max < occupied then
    err.raise("limit", "max " .. a.max .. " is below the number of occupied slots (" .. occupied
      .. ": helpers alive, awaiting respawn or away)")
  end
  if type(storage.proto) ~= "table" then
    -- сейв со схемой 1 (proto — число), миграция ещё не шла: версию сохранить
    storage.proto = { version = type(storage.proto) == "number" and storage.proto or 0 }
  end
  storage.proto.max_helpers = a.max
  return { max = a.max, alive = alive }
end

function M.op_list(args, ctx, jobs_active)
  schema.validate({}, args)
  local out = {}
  for _, id in ipairs(M.ids()) do
    local rec = storage.helpers[id]
    local item = { id = id, state = rec.state, body = M.body_kind(id) }
    local e = rec.entity
    if rec.state == "alive" and e and e.valid then
      item.surface = e.surface.name
      item.pos = util.pos(e.position)
    elseif rec.state == "dead" then
      item.pos = rec.died_pos
      item.corpse = rec.corpse_pos
    elseif rec.state == "away" then
      -- тело-игрок, игрока или персонажа сейчас нет: место, где тело было в последний раз
      item.pos = rec.away_pos
      item.surface = rec.away_surface
      item.away = rec.away
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
      if rec.state == "alive" and rec.player_index ~= nil and M.hooks.on_player_body_gone(id) then
        return
      end
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
