-- Общее для рефлексов (поток H): хранилище состояния и поиск врагов.
-- Контракт: docs/PROTOCOL.md §6.7 (живое — только видимое), §7; docs/EVENTS.md.
--
-- Состояние рефлексов — storage.reflex_state[helper] (создаётся здесь по требованию; набор
-- рефлексов помощника storage.reflexes[helper] принадлежит ядру, сюда его только читают):
--   { unit    = unit_number тела, к которому относятся attack/low/flee/watch_tick,
--     attack  = { first_tick, last_tick, noisy_tick, pending, by, threat = {name, pos}? },
--     low     = true — health_low уже отправлен (сброс при здоровье ≥ 50 %),
--     flee    = { job, goal, legs, cand, tried, since_seq, started, threat, p = {radius, distance, to} },
--     flee_block = тик, раньше которого отступление не начинается снова,
--     flee_fail = { reason, tick } — последняя неудача «даже не начал» (чтобы не повторять громко),
--     watch_tick = тик последнего saw_enemy,
--     death   = { tick, unit, pos, surface, force, announced, retries, retry_tick } }
-- Только простые таблицы: без LuaEntity и функций.
local util = require("scripts.core.util")
local vis = require("scripts.core.vis")

local C = {}

C.EYES = 32 -- клеток: собственные глаза помощника (PROTOCOL §6.7)

-- Кто опасен. Гнёзда (unit-spawner) сами не нападают — их показывает только watch.
C.THREAT = { unit = true, turret = true, ["spider-unit"] = true, ["segmented-unit"] = true, segment = true }
C.SEEN = {
  unit = true, turret = true, ["spider-unit"] = true, ["segmented-unit"] = true, segment = true,
  ["unit-spawner"] = true,
}
C.ENEMY_FORCE = "enemy" -- как в STATE.md «near.enemies»

function C.all()
  local s = storage.reflex_state
  if type(s) ~= "table" then
    s = {}
    storage.reflex_state = s
  end
  return s
end

function C.state(helper, create)
  local all = C.all()
  local st = all[helper]
  if st == nil and create then
    st = {}
    all[helper] = st
  end
  return st
end

--- Состояние для живого тела: всё, что относилось к прошлому телу, забывается.
function C.body_state(helper, entity)
  local st = C.state(helper, true)
  local unit = entity.unit_number
  if st.unit ~= unit then
    st.unit = unit
    st.attack = nil
    st.low = nil
    st.flee = nil
    st.flee_block = nil
    st.flee_fail = nil
    st.watch_tick = nil
  end
  return st
end

--- Убрать состояние помощников, которых больше нет (удалены или запись стёрта).
function C.gc()
  local helpers = storage.helpers or {}
  for id in pairs(C.all()) do
    local rec = helpers[id]
    if rec == nil or rec.state == "removed" then storage.reflex_state[id] = nil end
  end
end

function C.chunk_of(p)
  return { x = math.floor(p.x / 32), y = math.floor(p.y / 32) }
end

--- Видит ли помощник точку: ≤ 32 клеток от тела или чанк виден силе (PROTOCOL §6.7).
--- Проверка одна на весь мод — scripts.core.vis; напрямую is_chunk_visible здесь не зовётся.
function C.visible(helper_id, entity, p)
  return vis.visible(helper_id, entity.surface, p, entity.force)
end

--- Враги вокруг точки center (по умолчанию — тела) в радиусе radius, ближние первыми:
--- { {name, type, pos = {x, y}, dist}, ... }. kinds — C.THREAT (по умолчанию) или C.SEEN.
--- Вызывающий отвечает за видимость точки (радиус ≤ 32 от тела виден всегда).
function C.enemies(entity, radius, kinds, center)
  kinds = kinds or C.THREAT
  local own = entity.force
  if own ~= nil and own.name == C.ENEMY_FORCE then return {} end
  local c = center or util.xy(entity.position)
  local list = entity.surface.find_entities_filtered{ position = c, radius = radius, force = C.ENEMY_FORCE }
  local out = {}
  for _, e in ipairs(list) do
    if e.valid and kinds[e.type] then
      local p = util.xy(e.position)
      out[#out + 1] = { name = e.name, type = e.type, pos = p, dist = util.dist(p, c) }
    end
  end
  table.sort(out, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
    return a.pos.y < b.pos.y
  end)
  return out
end

--- Доля здоровья тела 0..1 и сами числа: ratio, health, max.
function C.health(entity, health)
  local max = entity.max_health or 0
  local h = health or entity.health or 0
  if max <= 0 then return 1, h, max end
  return h / max, h, max
end

return C
