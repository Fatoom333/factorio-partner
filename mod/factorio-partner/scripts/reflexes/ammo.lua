-- Рефлекс `ammo` — заправщик турелей (хозяин ставит турели, помощник сразу кладёт в них патроны). Без раздумий агента: раз в EVERY тиков смотрит
-- свои турели с патронами (`ammo-turret`) в radius клеток от тела и кладёт в самую пустую из них
-- патроны из своего инвентаря — до fill, если в ней меньше min.
--   ammo { radius?=20 (4..32), min?=10 (1..200), fill?=50 (1..400, не меньше min), item?:string,
--          chests?=true }
-- * Турель в досягаемости (reach_distance) — кладёт сразу, как игрок рукой (inv.move — тот же
--   перенос, что у `insert`), по одной турели за раз. Шумное reflex_fired{type:"ammo", detail}.
-- * Дальше — если у помощника нет задач, ставит задачу `insert` (req "reflex:ammo"): помощник
--   подходит сам, с дальней от врага стороны (inventory.approach). Есть задачи — ждёт: задачи
--   агента важнее; в бою агенту очередь держать пустой (правило агента).
-- * Какие патроны: item, если задан, иначе любые предметы типа ammo из инвентаря, которые турель
--   принимает (`can_insert` движка — категория патронов из игры, без имён в коде).
-- * Патронов нет: громкое ammo_low{item?, turret} не чаще раза в LOW_REPEAT; задан item и chests —
--   при свободной очереди задача `collect{items:{item: fill × 2}}` со складов в 64 клетках (не чаще
--   раза в COLLECT_BACKOFF).
-- * Пока идёт отступление (flee) — молчит: жизнь важнее.
-- Состояние — в reflexes.common body_state: ammo_tick, ammo_low_tick, ammo_collect_until.
local util = require("scripts.core.util")
local events = require("scripts.core.events")
local jobs = require("scripts.core.jobs")
local inv = require("scripts.lib.inventory")
local C = require("scripts.reflexes.common")

local M = {}
M.name = "reflexes.ammo"

M.EVERY = 30
M.REQ = "reflex:ammo"
M.LOW_REPEAT = 60 * 60
M.COLLECT_BACKOFF = 30 * 60
M.COLLECT_RADIUS = 64

local function idle(id)
  if jobs.active(id) ~= nil then return false end
  local q = jobs.queue_of(id, false)
  return q == nil or q.queue == nil or q.queue[1] == nil
end

local function turret_count(t)
  local ok, ti = pcall(function() return t.get_inventory(defines.inventory.turret_ammo) end)
  if not ok or ti == nil then return 0 end
  return ti.get_item_count()
end

--- Имена патронов в инвентаре (по алфавиту): item или все предметы типа ammo.
local function ammo_names(main, item)
  local out = {}
  if main == nil then return out end
  if item ~= nil then
    if inv.count(main, item) > 0 then out[1] = item end
    return out
  end
  for name, n in pairs(inv.counts(main)) do
    local p = prototypes.item[name]
    if n > 0 and p ~= nil and p.type == "ammo" then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function act(id, entity, tick, a)
  return pcall(jobs.op_act, a, { helper_id = id, request_id = M.REQ, entity = entity, tick = tick })
end

local function out_of_ammo(id, entity, params, st, tick, turret)
  local pos = util.xy(entity.position)
  if params.item ~= nil and params.chests and idle(id) and (st.ammo_collect_until or 0) <= tick then
    st.ammo_collect_until = tick + M.COLLECT_BACKOFF
    act(id, entity, tick, { ["do"] = "collect", args = {
      items = { [params.item] = params.fill * 2 }, center = { x = pos.x, y = pos.y }, radius = M.COLLECT_RADIUS,
    } })
  end
  if st.ammo_low_tick == nil or tick - st.ammo_low_tick >= M.LOW_REPEAT then
    st.ammo_low_tick = tick
    events.emit(id, "ammo_low", { item = params.item, turret = util.pos(turret.position) }, { loud = true })
  end
end

function M.check(id, entity, params, tick)
  local st = C.body_state(id, entity)
  if st.ammo_tick ~= nil and tick - st.ammo_tick < M.EVERY then return end
  st.ammo_tick = tick
  if st.flee ~= nil then return end
  local fill = math.max(params.fill, params.min)
  local turrets = entity.surface.find_entities_filtered{
    type = "ammo-turret", force = entity.force, position = util.xy(entity.position), radius = params.radius,
  }
  local best, bc
  for _, t in ipairs(turrets) do
    if t.valid then
      local n = turret_count(t)
      if n < params.min and (bc == nil or n < bc) then best, bc = t, n end
    end
  end
  if best == nil then return end
  local main = entity.get_main_inventory()
  local name
  for _, a in ipairs(ammo_names(main, params.item)) do
    local ok, can = pcall(function() return best.can_insert{ name = a, count = 1 } end)
    if ok and can then name = a break end
  end
  if name == nil then return out_of_ammo(id, entity, params, st, tick, best) end
  local n = math.min(fill - bc, inv.count(main, name))
  if n <= 0 then return end
  if inv.in_reach(entity, best, "reach") then
    local moved = inv.move(main, { entity = best }, name, n, entity)
    if moved > 0 then
      events.emit(id, "reflex_fired", { type = "ammo", detail = {
        turret = util.pos(best.position), item = name, count = moved,
      } })
    end
  elseif idle(id) then
    act(id, entity, tick, { ["do"] = "insert", args = {
      target = { name = best.name, pos = util.pos(best.position) }, items = { [name] = n },
    } })
  end
end

M.reflexes = {
  ammo = {
    schema = {
      radius = { type = "number", min = 4, max = C.EYES, default = 20 },
      min = { type = "int", min = 1, max = 200, default = 10 },
      fill = { type = "int", min = 1, max = 400, default = 50 },
      item = { type = "string", max = 100 },
      chests = { type = "bool", default = true },
    },
    check = function(id, entity, params, tick) M.check(id, entity, params, tick) end,
  },
}

return M
