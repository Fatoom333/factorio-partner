-- Тело-игрок (поток P). Контракт: docs/PROTOCOL.md §7 «Два вида тела».
--
-- Помощник может жить в персонаже подключённого ВТОРОГО клиента игры: админская операция
-- `helper_attach {player}` -> `{helper, pos, surface}` привязывает id помощника к `player.character`
-- (`storage.helpers[id].player_index`). Все действия идут тем же кодом, что и у тела без игрока.
-- Отличия собраны здесь, в одном месте:
--
-- 1. Удержание состояний. У персонажа игрока ввод клиента каждый тик сбрасывает `walking_state`,
--    `mining_state` и `selected` (у тела без игрока они держатся сами). Поэтому ядро:
--      * в конце тика задач (`after_tick`) запоминает, что действие оставило включённым —
--        `rec.hold = {job, walking, direction, mining, mining_pos, selected, selected_unit}`;
--      * в начале следующего (`before_tick`, ДО действий) выставляет это снова.
--    Действие видит тело таким, каким оставило его тик назад, и ничего про вид тела не знает.
--    Нет активной задачи — ничего не держим: игрок за вторым клиентом может шевелить телом сам.
--
-- 2. Тело появляется и пропадает не по воле мода:
--      * игрок вышел (on_player_left_game) — задачи
--        `job_failed{no_helper}`, событие `helper_lost{reason:"player_left"}`; запись остаётся
--        (`state="dead"`, `away="player_left"`) и держит место в лимите, как ждущий возрождения;
--      * игрок вернулся (on_player_joined_game) — тело подхватывается, `respawned{pos,
--        reason:"player_joined"}`;
--      * смерть — как у всех (ядро: `job_failed{no_helper}`, H: `died`); возрождает движок,
--        мод берёт новый `player.character` (on_player_respawned) — `respawned{pos}`;
--      * персонажа нет при игроке онлайн (редактор, режим бога, катсцена) или он подменён —
--        `helper_lost{reason:"no_character"|"body_changed"|"destroyed"}`, потом так же подхват.
--    События — только ускорение: каждый тик `before_tick` сверяет запись с игроком (`sync`),
--    поэтому пропущенное событие или иной порядок событий в движке ничего не ломают.
--
-- 3. `helper_remove` только отвязывает (registry.op_remove), обзор и возрождение для такого
--    тела мод не делает (perception/vision.lua, reflexes/death.lua смотрят `player_index`).
--
-- Честность (PROTOCOL §6): тело не создаётся и не переносится, предметы не появляются —
-- модуль только пишет в `walking_state` / `mining_state` / `selected` то, что уже выставило
-- действие. Всё состояние — в `storage` (второй клиент подключается в середине игры: локальные
-- переменные дали бы рассинхронизацию).
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local owner = require("scripts.core.owner")
local events = require("scripts.core.events")
local schema = require("scripts.core.schema")
local registry = require("scripts.core.registry")
local reserve = require("scripts.core.reserve")
local jobs = require("scripts.core.jobs")

local M = {}
M.name = "core.attach"

M.MAX_PLAYER_NAME = 60

local ATTACH_SCHEMA = { player = { type = "string", required = true, max = M.MAX_PLAYER_NAME } }

-- ------------------------------------------------------------------ тело игрока

--- Персонаж игрока, если игрок онлайн и тело есть (PROTOCOL §4: «игрок есть»).
local function body_of(p)
  if p == nil or not p.valid or not p.connected then return nil end
  local ch = p.character
  if ch == nil or not ch.valid or ch.type ~= "character" then return nil end
  return ch
end

local function same_entity(a, b)
  if a == nil or b == nil then return false end
  if a == b then return true end
  return a.valid and b.valid and a.unit_number ~= nil and a.unit_number == b.unit_number
end

--- Тело пропало не по смерти: задачи no_helper, запись ждёт тело (state="dead", away=reason).
local function lose(id, rec, reason)
  if rec.state ~= "alive" then return false end
  local e = rec.entity
  local valid = e ~= nil and e.valid
  -- stop действий зовётся при ещё живом теле (если оно есть): они сами выключат ходьбу и добычу
  jobs.fail_all(id, "no_helper", "helper body is gone (" .. reason .. ")", valid and e or nil)
  reserve.release_all(id)
  rec.state = "dead"
  rec.away = reason
  if valid then rec.died_pos = util.pos(e.position) end
  rec.corpse_pos = nil
  rec.entity = nil
  rec.reg = nil
  rec.hold = nil
  events.emit(id, "helper_lost", { reason = reason })
  return true
end

--- Тело снова есть (игрок вернулся, возродился, получил персонажа).
local function take(id, rec, ch)
  local away = rec.away
  registry.set_body(id, ch) -- state "dead" -> "alive"
  rec.away = nil
  rec.hold = nil
  local data = { pos = util.pos(ch.position) }
  if away == "player_left" then
    data.reason = "player_joined"
  elseif away ~= nil then
    data.reason = "body_restored"
  end
  events.emit(id, "respawned", data)
end

--- Сверить запись тела-игрока с игроком. Идемпотентна; зовётся каждый тик и из событий.
local function sync(id, rec)
  if rec.player_index == nil or rec.state == "removed" then return end
  local p = game.get_player(rec.player_index)
  -- игрока нет в сейве: этим занимается on_player_removed (drop), здесь гадать не о чем
  if p == nil or not p.valid then return end
  local ch = body_of(p)
  if rec.state == "alive" then
    if ch == nil then
      lose(id, rec, p.connected and "no_character" or "player_left")
    elseif not same_entity(rec.entity, ch) then
      lose(id, rec, "body_changed")
      take(id, rec, ch)
    end
  elseif rec.state == "dead" and ch ~= nil then
    take(id, rec, ch)
  end
end

--- Игрока удалили из сейва (on_player_removed): тело не вернётся, место в лимите освобождается.
local function drop(id, rec)
  if rec.state == "removed" then return end
  lose(id, rec, "player_removed")
  rec.state = "removed"
  rec.removed_tick = nil
  rec.entity = nil
  rec.reg = nil
  rec.away = nil
  rec.hold = nil
end

local function is_player_body(rec)
  return type(rec) == "table" and rec.player_index ~= nil and rec.state ~= "removed"
end

-- ------------------------------------------------------------------ удержание состояний

--- Выставить заново то, что действие оставило включённым тик назад.
local function apply_hold(rec)
  local h = rec.hold
  if h == nil then return end
  local e = rec.entity
  if h.walking then
    e.walking_state = { walking = true, direction = h.direction }
  end
  if h.mining then
    local sel = h.selected
    if h.selected_unit ~= false and (sel == nil or not sel.valid) then
      -- цель исчезла (добыта, разобрана): держать нечего, действие разберётся само
      h.mining = false
      h.selected = nil
      h.selected_unit = nil
      h.mining_pos = nil
    else
      if sel ~= nil and e.selected ~= sel then e.selected = sel end
      e.mining_state = { mining = true, position = h.mining_pos }
    end
  end
  if not h.walking and not h.mining then rec.hold = nil end
end

--- Запомнить, что действие оставило включённым в этом тике.
local function latch(id, rec)
  local e = rec.entity
  local task = jobs.active(id)
  if rec.state ~= "alive" or e == nil or not e.valid or task == nil then
    rec.hold = nil
    return
  end
  local ws, ms = e.walking_state, e.mining_state
  local walking = ws ~= nil and ws.walking == true
  local mining = ms ~= nil and ms.mining == true
  if not walking and not mining then
    rec.hold = nil
    return
  end
  local h = rec.hold
  if h == nil then
    h = {}
    rec.hold = h
  end
  h.job = task.job
  h.walking = walking
  h.direction = walking and ws.direction or nil
  h.mining = mining
  if mining then
    local sel = e.selected
    if sel ~= nil and not sel.valid then sel = nil end
    h.selected = sel
    -- false — добыча без выбранной сущности (плитки); иначе рядом с LuaEntity её номер (PROTOCOL §7)
    if sel == nil then h.selected_unit = false else h.selected_unit = sel.unit_number end
    h.mining_pos = util.xy(ms.position or (sel and sel.position) or e.position)
  else
    h.selected = nil
    h.selected_unit = nil
    h.mining_pos = nil
  end
end

local last_log = nil
local function report(where, e)
  err.count_module_error()
  local tick = game.tick
  if last_log ~= nil and tick - last_log < 3600 then return end
  last_log = tick
  log("[factorio-partner] attach " .. where .. " failed: " .. err.clean_text(err.is(e) and e.text or e))
end

local function hold_one(id, rec)
  local h = rec.hold
  local e = rec.entity
  local task = jobs.active(id)
  -- держим только для той задачи, что оставила состояния: её отменили или заменили между
  -- тиками (cancel, act{replace}) — stop уже всё выключил, возвращать нельзя
  if rec.state ~= "alive" or e == nil or not e.valid or task == nil or task.job ~= h.job then
    rec.hold = nil
    return
  end
  apply_hold(rec)
end

--- Начало тика задач (до действий): сверка с игроком и удержание состояний.
function M.before_tick(tick)
  for id, rec in pairs(storage.helpers) do
    if is_player_body(rec) then
      local ok, e = pcall(sync, id, rec)
      if not ok then report("sync of " .. tostring(id), e) end
      if rec.hold ~= nil then
        ok, e = pcall(hold_one, id, rec)
        if not ok then
          rec.hold = nil -- не повторять сбой каждый тик
          report("hold of " .. tostring(id), e)
        end
      end
    end
  end
end

--- Конец тика задач (после действий): запомнить состояния.
function M.after_tick(tick)
  for id, rec in pairs(storage.helpers) do
    if is_player_body(rec) then
      local ok, e = pcall(latch, id, rec)
      if not ok then
        rec.hold = nil
        report("latch of " .. tostring(id), e)
      end
    end
  end
end

-- ------------------------------------------------------------------ операция helper_attach

--- Помощник (не удалённый), чьё тело — этот игрок; except — id, который не считать.
local function helper_of_player(player_index, except)
  for id, rec in pairs(storage.helpers) do
    if id ~= except and is_player_body(rec) and rec.player_index == player_index then return id end
  end
  return nil
end
M.helper_of_player = helper_of_player

--- helper_attach {player:string} -> {helper, pos, surface}. Админская операция: её шлёт скрипт
--- запуска напарника при `--body player`, агентам сервер её не даёт.
function M.op_attach(args, ctx)
  local a = schema.validate(ATTACH_SCHEMA, args)
  local id = ctx.helper_id
  local name = a.player
  if name == "" or name:find("[\0-\31\127]") then err.raise("bad_args", "args.player: not a player name") end
  if registry.alive(id) then err.raise("helper_exists", "helper " .. id .. " is alive") end
  local p = game.get_player(name)
  if p == nil or not p.valid or p.name ~= name then err.raise("no_player", "no such player in the save") end
  if owner.is_owner(p) then err.raise("no_player", "the owner cannot be a helper body") end
  local ch = body_of(p)
  if ch == nil then err.raise("no_player", "the player must be online and have a character") end
  local o = owner.player()
  if o ~= nil and o.valid and o.force ~= nil and p.force ~= nil and o.force.name ~= p.force.name then
    err.raise("no_player", "the player is not in the owner's force")
  end
  local other = helper_of_player(p.index, id)
  if other ~= nil then err.raise("helper_exists", "this player is already the body of helper " .. other) end
  registry.check_slot(id)
  -- запись id заменяется целиком (bind): прежнее тело этого id мертво или удалено, задач у него нет
  local rec = registry.bind(id, ch, { player_index = p.index })
  rec.away = nil
  rec.hold = nil
  return { helper = id, pos = util.pos(ch.position), surface = ch.surface.name }
end

-- ------------------------------------------------------------------ события игры

local function for_player(player_index, fn)
  if player_index == nil then return end
  for id, rec in pairs(storage.helpers) do
    if is_player_body(rec) and rec.player_index == player_index then fn(id, rec) end
  end
end

--- Игрок вышел (on_player_left_game). Персонажа у отключённого игрока уже нет
--- (`player.character` = nil), поэтому stop действий зовётся без тела — как при helper_lost.
function M.on_player_leaving(e)
  for_player(e.player_index, function(id, rec) lose(id, rec, "player_left") end)
end

--- Игрок вошёл, возродился, получил или потерял персонажа: сверить запись.
function M.on_player_changed(e)
  for_player(e.player_index, sync)
end

--- Игрока удалили из сейва.
function M.on_player_removed(e)
  for_player(e.player_index, drop)
end

M.ops = { helper_attach = M.op_attach }

local ev = defines.events
M.events = {
  [ev.on_player_left_game] = M.on_player_leaving,
  [ev.on_player_joined_game] = M.on_player_changed,
  [ev.on_player_respawned] = M.on_player_changed,
  [ev.on_player_removed] = M.on_player_removed,
}

-- Крючки ядра (ставятся при загрузке модуля; control.lua подключает его, только если файл есть).
jobs.body_hooks.before_tick = M.before_tick
jobs.body_hooks.after_tick = M.after_tick
-- тело-игрок исчезло не по смерти (register_on_object_destroyed): запись не удаляется, а ждёт тело
registry.hooks.on_player_body_gone = function(id)
  local rec = registry.get(id)
  if rec == nil or rec.player_index == nil then return false end
  lose(id, rec, "destroyed")
  return true
end

-- Для тестов.
M.sync = sync
M.body_of = body_of

return M
