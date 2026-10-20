-- Рефлексы «смерть и возрождение». Всегда включены, в набор `reflexes` не входят.
-- Контракт: docs/PROTOCOL.md §6.9 (появление тела), §7 (смерть, registry.set_body),
-- docs/EVENTS.md (died, respawned).
--
-- Смерть: обработчик модуля идёт раньше ядра и видит state="alive"; для helper_remove ядро
-- заранее ставит state="removed" — такие смерти не считаются. Громкое died{pos, corpse} уходит из
-- on_post_entity_died (там уже известен труп); если оно не пришло — на следующей проверке, без corpse.
--
-- Возрождение: через 600 тиков после смерти, на той же поверхности, у
-- force.get_spawn_position(surface), новое тело `character` с пустым инвентарём (вещи остались
-- в трупе), сила та же. Тело отдаётся ядру через registry.set_body, громкое respawned{pos}.
-- Места нет — повтор каждые 5 с (до 12 раз), потом reflex_done{type:"respawn", outcome:"failed"}
-- и помощник остаётся мёртвым (helper_spawn — после перезарядки). Помощника удалили или
-- заспавнили заново, пока он был мёртв, — возрождение отменяется.
--
-- Последний труп: при смерти в состояние рефлексов пишется `corpse = {pos, surface, tick, taken?}`
-- (место трупа из on_post_entity_died, иначе — место смерти; tick — тик смерти, он же
-- character_corpse_tick_of_death у трупа). Его находит pickup{corpse:true}; запись переживает
-- возрождение и заменяется следующей смертью.
--
-- Броня после возрождения: пока новое тело живёт меньше REARM_TICKS, раз в секунду проверяется
-- слот брони — пуст, а в карманах броня (тело-игрок, вещи из сундука) — надевается лучшая
-- (scripts/lib/armor.lua auto_wear), шумное armor_equipped{item, armor}.
local util = require("scripts.core.util")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local armor = require("scripts.lib.armor")
local C = require("scripts.reflexes.common")

local M = {}
M.name = "reflexes.death"

M.RESPAWN_TICKS = 600   -- PROTOCOL §6.9
M.RETRY_TICKS = 300     -- нет места у точки возрождения — повтор
M.MAX_RETRIES = 12
M.SPAWN_RADIUS = 16     -- поиск свободного места вокруг точки возрождения
M.REARM_TICKS = 36000   -- 10 мин после возрождения мод сам надевает броню из карманов

local CHAR = { { filter = "type", type = "character" } }

local function announce(id, d, corpse)
  d.announced = true
  events.emit(id, "died", { pos = d.pos, corpse = corpse })
end

function M.on_died(e)
  local ent = e.entity
  if not (ent and ent.valid and ent.type == "character") then return end
  local id, rec = registry.find_by_unit(ent.unit_number)
  if id == nil or rec.state ~= "alive" then return end -- "removed": helper_remove, не смерть
  local st = C.state(id, true)
  st.attack = nil
  st.low = nil
  st.death = {
    tick = game.tick, unit = ent.unit_number, pos = util.pos(ent.position),
    surface = ent.surface.index, force = ent.force.name, announced = false, retries = 0,
  }
  st.corpse = { pos = util.pos(ent.position), surface = ent.surface.index, tick = game.tick }
  st.rearm = { dead_unit = ent.unit_number }
end

function M.on_post_died(e)
  local unit = e.unit_number
  if unit == nil then return end
  for id, st in pairs(C.all()) do
    local d = st.death
    if d ~= nil and d.unit == unit and not d.announced then
      local c = e.corpses and e.corpses[1]
      local cpos = c and c.valid and util.pos(c.position) or nil
      if cpos ~= nil and st.corpse ~= nil and st.corpse.tick == d.tick then st.corpse.pos = cpos end
      announce(id, d, cpos)
      return
    end
  end
end

--- Последний труп помощника: {pos, surface (индекс), tick, taken?} или nil.
function M.last_corpse(helper)
  local st = C.state(helper, false)
  return st and st.corpse or nil
end

--- Свой труп забран целиком (pickup{corpse:true}): второй раз его не ищем.
function M.corpse_taken(helper)
  local c = M.last_corpse(helper)
  if c ~= nil then c.taken = true end
end

--- Броня после возрождения (см. шапку): новое тело, слот пуст, в карманах броня → надеть.
function M.rearm_sweep(tick)
  for id, st in pairs(C.all()) do
    local r = st.rearm
    if r ~= nil then
      local rec = registry.get(id)
      local e = rec and rec.entity
      if rec == nil or rec.state == "removed" then
        st.rearm = nil
      elseif rec.state == "alive" and e ~= nil and e.valid and e.unit_number ~= r.dead_unit then
        r.since = r.since or tick
        local ok, got = pcall(armor.auto_wear, e)
        if ok and got ~= nil then
          st.rearm = nil
          events.emit(id, "armor_equipped", { item = got.equipped, armor = got.armor })
        elseif tick - r.since >= M.REARM_TICKS then
          st.rearm = nil
        else
          -- броню уже надели (equip, extract{equip}) — дальше не смотрим
          local ok2, worn = pcall(function()
            local s = armor.slot(e)
            return s ~= nil and s.valid_for_read
          end)
          if ok2 and worn then st.rearm = nil end
        end
      end
    end
  end
end

local function give_up(id, st, reason)
  st.death = nil
  events.emit(id, "reflex_done", { type = "respawn", outcome = "failed", detail = { reason = reason } })
end

local function respawn(id, st, d, tick)
  local surface = game.get_surface(d.surface)
  if surface == nil or not surface.valid then return give_up(id, st, "surface_gone") end
  local force = game.forces[d.force]
  if force == nil or not force.valid then return give_up(id, st, "force_gone") end
  local spawn = util.xy(force.get_spawn_position(surface))
  local pos = surface.find_non_colliding_position("character", spawn, M.SPAWN_RADIUS, 0.5)
  local body
  if pos ~= nil then
    body = surface.create_entity{ name = "character", position = pos, force = force, quality = "normal" }
  end
  if body == nil or not body.valid then
    d.retries = (d.retries or 0) + 1
    if d.retries > M.MAX_RETRIES then return give_up(id, st, "no_place") end
    d.retry_tick = tick + M.RETRY_TICKS
    return
  end
  registry.set_body(id, body)
  st.death = nil
  C.body_state(id, body)
  events.emit(id, "respawned", { pos = util.pos(body.position) })
end

function M.sweep(tick)
  for id, st in pairs(C.all()) do
    local d = st.death
    if d ~= nil then
      local rec = registry.get(id)
      if rec == nil or rec.state ~= "dead" or rec.unit_number ~= d.unit then
        -- удалён, заспавнен заново или ядро смерть не отметило — возрождать нечего
        st.death = nil
      else
        if not d.announced and tick > d.tick then announce(id, d, rec.corpse_pos) end
        -- тело-игрок (PROTOCOL §7): возрождает движок, новое тело подхватывает helper_attach
        if rec.player_index == nil and tick >= d.tick + M.RESPAWN_TICKS and tick >= (d.retry_tick or 0) then
          respawn(id, st, d, tick)
        end
      end
    end
  end
end

M.reflexes = {}

M.events = {
  [defines.events.on_entity_died] = { handler = M.on_died, filter = CHAR },
  [defines.events.on_post_entity_died] = { handler = M.on_post_died, filter = CHAR },
}

M.on_nth = {
  [10] = function(e) M.sweep(e.tick) end,
  [60] = function(e) M.rearm_sweep(e.tick) end,
}

return M
