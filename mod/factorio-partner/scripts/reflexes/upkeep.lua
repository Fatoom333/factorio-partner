-- Рефлекс `upkeep` — домашние дела: заправка машин на горелках и наука в лабораториях. Выключен по
-- умолчанию: агент включает его только по слову хозяина. Раз в EVERY тиков берёт машины своей силы
-- в radius клеток от тела (из индекса scripts.core.index) и кладёт в ближайшую, которой нужно,
-- топливо или науку из инвентаря помощника.
--   upkeep { radius?=96 (4..96), min?=2 (1..50), fill?=10 (1..200, не меньше min), packs?=10 (1..100),
--            fuel?:string, science?=true, chests?=true }
-- * Топливо: машина с горелкой, у которой в топливном слоте меньше min штук, получает топливо до
--   fill. Какое топливо — решает игра: предмет с топливной категорией, которую горелка принимает,
--   и `can_insert` топливного инвентаря (из подходящих — с наименьшей теплотой; fuel, если задан,
--   — только он). Реакторы не заправляются: их топливо хозяин выбирает сам.
-- * Наука: есть текущее исследование — лаборатория, у которой науки одного из его пакетов меньше
--   половины packs (и которая такой пакет принимает), получает недостающее до packs. Нет
--   исследования — лаборатории не кормятся.
-- * Только предметы качества normal и только машины своей силы; живое (топливо и наука внутри)
--   читается только у видимых машин (PROTOCOL §6.7), остальные пропускаются.
-- * В досягаемости (reach_distance) — кладёт сразу, как игрок рукой (inv.move), по одной машине за
--   проверку; шумное reflex_fired{type:"upkeep", detail:{kind:"fuel"|"science", pos, item, count}}.
--   Дальше — если у помощника нет задач, ставит `insert` (req "reflex:upkeep"): помощник подходит
--   сам. Для той же машины новая попытка — не раньше чем через COOLDOWN.
-- * Нужного нет в инвентаре и chests — при свободной очереди задача `collect` со складов в
--   COLLECT_RADIUS клетках (не чаще раза в COLLECT_BACKOFF); какое топливо брать — решает
--   перечень видимых складов (или fuel). Ничего громкого: «нечем заправить» видно в `status`.
-- * Пока хозяин держит помощника словом «стоп» (owner_hold) — не делает ничего.
-- * Пока идёт отступление (flee) — молчит.
-- Состояние — в reflexes.common body_state: upkeep_tick, upkeep_cd, upkeep_collect_until.
-- Заправка и подача науки — идея chores.lua из factorio-codex (MIT); код написан заново.
local util = require("scripts.core.util")
local events = require("scripts.core.events")
local jobs = require("scripts.core.jobs")
local vis = require("scripts.core.vis")
local index = require("scripts.core.index")
local inv = require("scripts.lib.inventory")
local stock = require("scripts.perception.stock")
local C = require("scripts.reflexes.common")

local M = {}
M.name = "reflexes.upkeep"

M.EVERY = 60
M.REQ = "reflex:upkeep"
M.COOLDOWN = 10 * 60
M.COLLECT_BACKOFF = 30 * 60
M.COLLECT_RADIUS = 64
M.MAX_RADIUS = 96

-- Эти типы не заправляются: топливо реактора хозяин выбирает сам.
local SKIP = { reactor = true, ["fusion-reactor"] = true }

local function prop(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

local function idle(id)
  if jobs.active(id) ~= nil then return false end
  local q = jobs.queue_of(id, false)
  return q == nil or q.queue == nil or q.queue[1] == nil
end

local function act(id, entity, tick, a)
  return pcall(jobs.op_act, a, { helper_id = id, request_id = M.REQ, entity = entity, tick = tick })
end

local function cooling(st, unit, tick)
  local cd = st.upkeep_cd
  return cd ~= nil and cd[unit] ~= nil and cd[unit] > tick
end

local function cool(st, unit, tick)
  st.upkeep_cd = st.upkeep_cd or {}
  st.upkeep_cd[unit] = tick + M.COOLDOWN
end

local function prune(st, tick)
  local cd = st.upkeep_cd
  if cd == nil then return end
  for unit, t in pairs(cd) do
    if t <= tick then cd[unit] = nil end
  end
  if next(cd) == nil then st.upkeep_cd = nil end
end

--- Топливо для горелки из counts ({name=count}): принимаемая горелкой категория, can_insert
--- топливного инвентаря, с наименьшей теплотой (при равной — по имени); only — единственный
--- допустимый предмет. → name, count или nil.
local function pick_fuel(counts, burner, binv, only)
  local cats = prop(burner, "fuel_categories")
  local best, best_value
  for name, n in pairs(counts) do
    if n > 0 and (only == nil or only == name) then
      local p = prototypes.item[name]
      local value = p ~= nil and prop(p, "fuel_value") or nil
      local cat = p ~= nil and prop(p, "fuel_category") or nil
      if type(value) == "number" and value > 0 and cat ~= nil and (cats == nil or cats[cat]) then
        local ok, can = pcall(function() return binv.can_insert{ name = name, count = 1, quality = inv.NORMAL } end)
        if ok and can and (best == nil or value < best_value or (value == best_value and name < best)) then
          best, best_value = name, value
        end
      end
    end
  end
  if best == nil then return nil end
  return best, counts[best]
end

--- Нужды: { {kind="fuel", m, target = LuaInventory, have, want, burner}, {kind="science", m, target,
--- pack, want}, ... } по возрастанию удаления.
local function needs_of(id, entity, params, st, tick)
  local surface = entity.surface
  local force = entity.force
  local pos = util.xy(entity.position)
  local eyes = vis.viewer(id, surface, force)
  local out = {}
  for _, m in ipairs(index.near("burner", surface.index, pos, params.radius, force.name)) do
    if not SKIP[m.type] and eyes(m.pos) and not cooling(st, m.unit, tick) then
      local burner = prop(m.entity, "burner")
      local binv = burner ~= nil and prop(burner, "inventory") or nil
      if binv ~= nil then
        local ok, have = pcall(function() return binv.get_item_count() end)
        if ok and have < params.min then
          out[#out + 1] = { kind = "fuel", m = m, burner = burner, target = binv, have = have,
            want = math.max(params.fill, params.min) - have }
        end
      end
    end
  end
  if params.science then
    local research = prop(force, "current_research")
    local ingredients = research ~= nil and prop(research, "research_unit_ingredients") or nil
    if type(ingredients) == "table" and ingredients[1] ~= nil then
      local floor_n = math.max(1, math.floor(params.packs / 2))
      for _, m in ipairs(index.near("lab", surface.index, pos, params.radius, force.name)) do
        if eyes(m.pos) and not cooling(st, m.unit, tick) then
          local ok, linv = pcall(function() return m.entity.get_inventory(defines.inventory.lab_input) end)
          if ok and linv ~= nil then
            for _, ing in ipairs(ingredients) do
              local pack = ing.name
              local ok2, have = pcall(function() return linv.get_item_count{ name = pack, quality = inv.NORMAL } end)
              local ok3, can = pcall(function()
                return linv.can_insert{ name = pack, count = 1, quality = inv.NORMAL }
              end)
              if ok2 and ok3 and can and have < floor_n then
                out[#out + 1] = { kind = "science", m = m, target = linv, pack = pack, have = have,
                  want = params.packs - have }
              end
            end
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a.m.dist ~= b.m.dist then return a.m.dist < b.m.dist end
    if a.m.unit ~= b.m.unit then return a.m.unit < b.m.unit end
    return (a.pack or "") < (b.pack or "")
  end)
  return out
end

--- Что и сколько из инвентаря помощника: name, count или nil.
local function from_hands(main, counts, need, params)
  if need.kind == "science" then
    local n = inv.count(main, need.pack)
    if n > 0 then return need.pack, math.min(n, need.want) end
    return nil
  end
  local name, n = pick_fuel(counts, need.burner, need.target, params.fuel)
  if name == nil then return nil end
  return name, math.min(n, need.want)
end

local function deliver(id, entity, tick, st, params, need, name, count)
  local target = need.m.entity
  if inv.in_reach(entity, target, "reach") then
    local main = entity.get_main_inventory()
    local moved = inv.move(main, { inv = need.target }, name, count, entity)
    if moved > 0 then
      events.emit(id, "reflex_fired", { type = "upkeep", detail = {
        kind = need.kind, pos = util.pos(target.position), item = name, count = moved,
      } })
    else
      cool(st, need.m.unit, tick)
    end
  elseif idle(id) then
    cool(st, need.m.unit, tick)
    act(id, entity, tick, { ["do"] = "insert", args = {
      target = { name = target.name, pos = util.pos(target.position) }, items = { [name] = count },
    } })
  end
end

--- Нужное есть только на складах: задача collect (не чаще раза в COLLECT_BACKOFF, при пустой очереди).
local function fetch(id, entity, tick, st, params, needs)
  if not params.chests or not idle(id) or (st.upkeep_collect_until or 0) > tick then return end
  st.upkeep_collect_until = tick + M.COLLECT_BACKOFF
  local pos = util.xy(entity.position)
  local totals
  for _, need in ipairs(needs) do
    local item, n
    if need.kind == "science" then
      item, n = need.pack, params.packs * 2
    else
      if totals == nil then
        totals = stock.scan(entity.surface, entity.force, pos, M.COLLECT_RADIUS, nil, id).total
      end
      item = pick_fuel(totals, need.burner, need.target, params.fuel)
      n = math.max(params.fill, params.min) * 2
    end
    if item ~= nil then
      act(id, entity, tick, { ["do"] = "collect", args = {
        items = { [item] = n }, center = { x = pos.x, y = pos.y }, radius = M.COLLECT_RADIUS,
      } })
      return
    end
  end
end

function M.check(id, entity, params, tick)
  local st = C.body_state(id, entity)
  if st.upkeep_tick ~= nil and tick - st.upkeep_tick < M.EVERY then return end
  st.upkeep_tick = tick
  if st.flee ~= nil or jobs.held(id) ~= nil then return end
  prune(st, tick)
  local needs = needs_of(id, entity, params, st, tick)
  if needs[1] == nil then return end
  local main = entity.get_main_inventory()
  local counts = inv.counts(main)
  for _, need in ipairs(needs) do
    local name, count = from_hands(main, counts, need, params)
    if name ~= nil and count > 0 then
      return deliver(id, entity, tick, st, params, need, name, count)
    end
  end
  fetch(id, entity, tick, st, params, needs)
end

M.reflexes = {
  upkeep = {
    schema = {
      radius = { type = "number", min = 4, max = M.MAX_RADIUS, default = 96 },
      min = { type = "int", min = 1, max = 50, default = 2 },
      fill = { type = "int", min = 1, max = 200, default = 10 },
      packs = { type = "int", min = 1, max = 100, default = 10 },
      fuel = { type = "string", max = 100 },
      science = { type = "bool", default = true },
      chests = { type = "bool", default = true },
    },
    check = function(id, entity, params, tick) M.check(id, entity, params, tick) end,
  },
}

return M
