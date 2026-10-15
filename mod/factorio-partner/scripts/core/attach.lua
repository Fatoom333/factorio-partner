-- Тело-игрок. Контракт: docs/PROTOCOL.md §7 «Два вида тела».
--
-- Помощник может жить в персонаже подключённого ВТОРОГО клиента игры: админская операция
-- `helper_attach {player}` -> `{helper, pos, surface}` привязывает id помощника к `player.character`
-- (`storage.helpers[id].player_index`). Все действия идут тем же кодом, что и у тела без игрока.
-- Отличия собраны здесь, в одном месте:
--
-- 1. Удержание состояний. У персонажа игрока ввод клиента каждый тик сбрасывает `walking_state`,
--    `mining_state` и `selected` (у тела без игрока они держатся сами). Мод держит ТОЛЬКО то, что
--    выставило активное действие, и отличает его от ввода человека за вторым клиентом так:
--      * до действий (`before_tick`) по каждому каналу (ходьба, добыча): если действие держит канал
--        (`rec.hold`), ядро выставляет его снова; если нет, а канал включён — это ввод человека:
--        ядро запоминает его и на время действия выключает канал;
--      * действие работает и видит тело таким, каким оставило его тик назад: канал включён,
--        только если включило его оно само;
--      * после действий (`after_tick`): канал включён при живой задаче — значит, его выставило
--        (или оставило) действие, он попадает в `rec.hold = {job, walking, direction, mining,
--        mining_pos, selected, selected_unit}`; иначе удержание канала снимается, а ввод человека
--        возвращается на место нетронутым.
--    Итог: `wait`, `mine`, `craft` ходьбой не управляют — нажатие клавиши человеком в `hold` не
--    попадает, тело делает шаг, пока клавиша нажата, и останавливается само. Нет задачи — мод
--    телом не управляет вовсе (состояния не читает и не пишет).
--
-- 2. Тело появляется и пропадает не по воле мода:
--      * игрок вышел (on_player_left_game) — задачи `job_failed{no_helper}`, событие
--        `helper_lost{reason:"player_left"}`; запись получает `state="away"`, `away=<причина>`,
--        `away_pos`/`away_surface` (где тело было в последний раз) и держит место в лимите;
--        операции «h» отвечают `no_helper`;
--      * игрок вернулся (on_player_joined_game) — тело подхватывается, `respawned{pos,
--        reason:"player_joined"}`;
--      * смерть — как у всех (ядро: `state="dead"`, `job_failed{no_helper}`, H: `died`); возрождает
--        движок, мод берёт новый `player.character` (on_player_respawned) — `respawned{pos}`;
--        вышел, не дождавшись возрождения, — `dead` становится `away` (`helper_lost{player_left}`);
--      * персонажа нет при игроке онлайн (редактор, режим бога, катсцена) или он подменён —
--        `helper_lost{reason:"no_character"|"body_changed"|"destroyed"}`, `state="away"`, потом
--        подхват с `respawned{reason:"body_restored"}`;
--      * игрока удалили из сейва — `helper_lost{reason:"player_removed"}`, запись `removed`.
--    События — только ускорение: каждый тик `before_tick` сверяет запись с игроком (`sync`),
--    поэтому пропущенное событие или иной порядок событий в движке ничего не ломают.
--
-- 3. `helper_remove` только отвязывает (registry.op_remove), обзор и возрождение для такого
--    тела мод не делает (perception/vision.lua, reflexes/death.lua смотрят `player_index`).
--    Набор рефлексов (`storage.reflexes`) возврат тела переживает: его сбрасывает только
--    `helper_remove`.
--
-- Честность (PROTOCOL §6): тело не создаётся и не переносится, предметы не появляются —
-- модуль только пишет в `walking_state` / `mining_state` / `selected` то, что уже выставило
-- действие, либо возвращает ввод человека, который сам же на тик убрал. Всё состояние между
-- тиками — в `storage` (второй клиент подключается в середине игры: локальные переменные дали
-- бы рассинхронизацию); таблица `snap` живёт только внутри одного обработчика on_tick.
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

--- Где тело было в последний раз: по самому телу, иначе по игроку (у вышедшего игрока
--- `physical_position` — место, где он стоял). → pos, имя поверхности | nil.
local function last_place(rec, e)
  if e ~= nil and e.valid then
    local ok, pos, surface = pcall(function() return util.pos(e.position), e.surface.name end)
    if ok then return pos, surface end
  end
  local p = rec.player_index ~= nil and game.get_player(rec.player_index) or nil
  if p ~= nil and p.valid then
    local ok, pos, surface = pcall(function() return util.pos(p.physical_position), p.physical_surface.name end)
    if ok then return pos, surface end
  end
  return nil, nil
end

--- Тела нет не по смерти: задачи no_helper, запись ждёт тело (state="away", away=reason).
--- Мёртвое тело (ждёт возрождения движком) уходит в "away", только если игрока больше нет.
local function lose(id, rec, reason)
  local state = rec.state
  local gone = reason == "player_left" or reason == "player_removed"
  if state == "alive" then
    local e = rec.entity
    local valid = e ~= nil and e.valid
    -- stop действий зовётся при ещё живом теле (если оно есть): они сами выключат ходьбу и добычу
    jobs.fail_all(id, "no_helper", "helper body is gone (" .. reason .. ")", valid and e or nil)
    reserve.release_all(id)
    rec.away_pos, rec.away_surface = last_place(rec, e)
  elseif state == "dead" and gone then
    -- поверхность смерти (died_surface); у записи из сейва старой версии её нет — тогда по игроку
    local _, by_player = last_place(rec, nil)
    rec.away_pos, rec.away_surface = rec.died_pos, rec.died_surface or by_player
  elseif state == "away" and reason == "player_removed" then
    -- уже ждал тело: игрок удалён — оно не вернётся, агент должен это узнать
  else
    return false
  end
  rec.state = "away"
  rec.away = reason
  rec.corpse_pos = nil
  rec.entity = nil
  rec.reg = nil
  rec.hold = nil
  events.emit(id, "helper_lost", { reason = reason })
  return true
end

--- Тело снова есть (игрок вернулся, возродился, получил персонажа).
local function take(id, rec, ch)
  local away = rec.state == "away" and rec.away or nil
  registry.set_body(id, ch) -- state "dead" | "away" -> "alive", поля away сняты
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
  local state = rec.state
  if state == "alive" then
    if ch == nil then
      lose(id, rec, p.connected and "no_character" or "player_left")
    elseif not same_entity(rec.entity, ch) then
      lose(id, rec, "body_changed")
      take(id, rec, ch)
    end
  elseif ch ~= nil then
    if state == "dead" or state == "away" then take(id, rec, ch) end
  elseif not p.connected then
    if state == "dead" then
      lose(id, rec, "player_left")
    elseif state == "away" and rec.away ~= "player_left" then
      rec.away = "player_left" -- тела не было и до выхода: событие уже ушло, меняется только причина
    end
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
  rec.away_pos = nil
  rec.away_surface = nil
  rec.hold = nil
end

local function is_player_body(rec)
  return type(rec) == "table" and rec.player_index ~= nil and rec.state ~= "removed"
end

-- ------------------------------------------------------------------ удержание состояний

-- Снимки ввода человека на время одного тика задач: snap[id] = {walk = walking_state человека?,
-- mine = {position}?}. Заполняется в before_tick и разбирается в after_tick того же on_tick,
-- между тиками всегда пуст (в storage ему не место, на состояние игры между тиками не влияет).
local snap = {}

--- Задача, которая будет тикать у помощника в этом тике: активная, и есть ли работа вообще
--- (первая в очереди стартует в этом же тике).
local function work_of(id)
  local q = jobs.queue_of(id, false)
  if q == nil then return nil, false end
  return q.active, q.active ~= nil or q.queue[1] ~= nil
end

--- Выставить заново добычу, которую действие оставило включённой. → держится ли она ещё.
local function apply_mining(e, h)
  local sel = h.selected
  if h.selected_unit ~= false and (sel == nil or not sel.valid) then
    -- цель исчезла (добыта, разобрана): держать нечего, действие разберётся само
    h.mining = false
    h.selected = nil
    h.selected_unit = nil
    h.mining_pos = nil
    return false
  end
  if sel ~= nil and e.selected ~= sel then e.selected = sel end
  e.mining_state = { mining = true, position = h.mining_pos }
  return true
end

--- До действий: по каждому каналу — либо удержание действия, либо ввод человека, убранный на
--- время действия (вернётся в settle).
local function prepare(id, rec)
  local e = rec.entity
  local active, busy = work_of(id)
  local h = rec.hold
  -- держим только для той задачи, что оставила состояния: её отменили или заменили между
  -- тиками (cancel, act{replace}) — stop уже всё выключил, возвращать нельзя
  if h ~= nil and (active == nil or active.job ~= h.job) then
    rec.hold = nil
    h = nil
  end
  if rec.state ~= "alive" or e == nil or not e.valid or not busy then
    -- задача кончилась между тиками (cancel, replace, отказ вне тика действия), а ходьбу включал
    -- мод: выключить её один раз, иначе тело идёт дальше само (замечено живьём 14.10)
    if rec.walk_owned and rec.state == "alive" and e ~= nil and e.valid then
      local ws = e.walking_state
      if ws ~= nil and ws.walking == true then
        e.walking_state = { walking = false, direction = ws.direction }
      end
    end
    rec.walk_owned = nil
    rec.hold = nil
    return -- без задачи мод телом не управляет вовсе
  end
  local s = {}
  snap[id] = s
  if h ~= nil and h.walking then
    e.walking_state = { walking = true, direction = h.direction }
  else
    -- пока есть задача, ходьбой управляет только мод: включённую не им ходьбу он выключает и
    -- НЕ возвращает после действия. Отличить клавишу человека от собственного старого движения
    -- нельзя, а возврат «чужой» ходьбы делал её вечной (дрейф и дребезг, живой прогон 14.10).
    local ws = e.walking_state
    if ws ~= nil and ws.walking == true then
      e.walking_state = { walking = false, direction = ws.direction }
    end
  end
  if not (h ~= nil and h.mining and apply_mining(e, h)) then
    local ms = e.mining_state
    if ms ~= nil and ms.mining == true then
      s.mine = { position = ms.position ~= nil and util.xy(ms.position) or nil }
      e.mining_state = { mining = false }
    end
  end
  if h ~= nil and not h.walking and not h.mining then rec.hold = nil end
end

--- После действий: что включено при живой задаче — выставило действие, это и держим; остальное
--- отпускаем и возвращаем ввод человека.
local function settle(id, rec, s)
  local e = rec.entity
  if rec.state ~= "alive" or e == nil or not e.valid then
    rec.hold = nil
    return
  end
  local task = jobs.active(id)
  local ws, ms = e.walking_state, e.mining_state
  local walking = ws ~= nil and ws.walking == true
  local mining = ms ~= nil and ms.mining == true
  local keep_walk = task ~= nil and walking
  local keep_mine = task ~= nil and mining
  if keep_walk or keep_mine then
    local h = rec.hold
    if h == nil then
      h = {}
      rec.hold = h
    end
    h.job = task.job
    if keep_walk then rec.walk_owned = true end
    h.walking = keep_walk
    h.direction = keep_walk and ws.direction or nil
    h.mining = keep_mine
    if keep_mine then
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
  else
    rec.hold = nil
  end
  if not keep_walk then
    -- задача кончилась, а ходьба осталась включённой: без задачи тело не ведём
    if walking then e.walking_state = { walking = false, direction = ws.direction } end
    if s.walk ~= nil then e.walking_state = s.walk end
  end
  if not keep_mine then
    if mining then e.mining_state = { mining = false } end
    if s.mine ~= nil then
      local sel = e.selected
      local pos = s.mine.position or (sel ~= nil and sel.valid and util.xy(sel.position)) or util.xy(e.position)
      e.mining_state = { mining = true, position = pos }
    end
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

--- Начало тика задач (до действий): сверка с игроком и подготовка состояний.
function M.before_tick(tick)
  snap = {}
  for id, rec in pairs(storage.helpers) do
    if is_player_body(rec) then
      local ok, e = pcall(sync, id, rec)
      if not ok then report("sync of " .. tostring(id), e) end
      ok, e = pcall(prepare, id, rec)
      if not ok then
        rec.hold = nil -- не повторять сбой каждый тик
        report("hold of " .. tostring(id), e)
      end
    end
  end
end

--- Конец тика задач (после действий): запомнить состояния действия, вернуть ввод человека.
function M.after_tick(tick)
  local taken = snap
  snap = {}
  for id, s in pairs(taken) do
    local rec = storage.helpers[id]
    if is_player_body(rec) then
      local ok, e = pcall(settle, id, rec, s)
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
--- Правила (PROTOCOL §7): имя игрока — точное; игрок офлайн, без персонажа, хозяин или другой
--- силы -> `no_player`; id занят живым телом, либо привязан к телу-игроку (в том числе ждущему:
--- `dead`, `away`), либо игрок уже чьё-то тело -> `helper_exists`; запись с мёртвым
--- телом-персонажем заменяется (его возрождение отменяется). Перезарядки нет.
function M.op_attach(args, ctx)
  local a = schema.validate(ATTACH_SCHEMA, args)
  local id = ctx.helper_id
  local name = a.player
  if name == "" or name:find("[\0-\31\127]") then err.raise("bad_args", "args.player: not a player name") end
  if registry.alive(id) then err.raise("helper_exists", "helper " .. id .. " is alive") end
  if is_player_body(registry.get(id)) then
    err.raise("helper_exists", "helper " .. id .. " is bound to a player body (helper_remove detaches it)")
  end
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

-- Крючки ядра (ставятся при загрузке модуля).
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
