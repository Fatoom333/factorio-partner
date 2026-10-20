-- Действие `pickup`. Контракт: docs/ACTIONS.md, PROTOCOL.md §6.
--
-- args: corpse:true (свой последний труп) │ target (труп: `{name:"character-corpse", pos}`) │
-- area (предметы на земле). Ровно одно.
-- * corpse:true — последний труп этого помощника по записи рефлекса смерти
--   (scripts/reflexes/death.lua last_corpse): у места трупа, тик смерти совпадает с
--   character_corpse_tick_of_death. Чужие трупы (хозяина, других помощников) так не берутся —
--   только явной целью. Нет записи или трупа на месте — not_found с detail.pos;
-- * труп — цель в форме {name, pos} (у трупа в игре нет unit_number; pos — `corpse` из события
--   `died` или `helper_list`): ближайший труп в 3 клетках от pos. Подходит на reach_distance и
--   забирает всё (normal) из инвентаря трупа; предметы с
--   данными — целым стаком (transfer_stack). После трупа слот брони пуст, а в карманах броня —
--   мод надевает лучшую (scripts/lib/armor.lua auto_wear): detail.equipped и detail.armor;
-- * area — предметы на земле (`item-entity`, своя сила или neutral, только normal) в области
--   (сторона ≤ 128); живое (PROTOCOL §6.7): берутся только видимые предметы (видимый чанк или
--   уже в досягаемости помощника), если в области есть только невидимые — not_visible. Обходит
--   ближайший-первым, к каждому подходит на item_pickup_distance; не больше 500 за задачу.
-- done.detail = {picked: items, equipped?, armor?}; инвентарь полон — событие inventory_full и failed{no_space}
-- (detail: picked и, у трупа, left).
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")
local armor = require("scripts.lib.armor")
local death = require("scripts.reflexes.death")

local M = {}
M.name = "pickup"
M.schema = {
  corpse = { type = "bool" },
  target = { type = "target" },
  area = { type = "area" },
}

M.MAX_ITEMS = 500
M.CORPSE_RADIUS = 3   -- труп ищем вокруг pos: место смерти в событии округлено, тело могло упасть рядом

local CORPSE = "character-corpse"   -- тип прототипа (у трупов из модов имя другое, тип тот же)

--- Труп по форме цели {name, pos} (ACTIONS.md «pickup»): ближайший к pos труп в радиусе
--- CORPSE_RADIUS, своей силы или neutral, в открытом чанке; непустой — раньше пустого (на одном
--- месте может лежать несколько трупов). Ищем по типу прототипа: имя по умолчанию
--- ("character-corpse") значит «любой труп персонажа» — у тела из мода имя трупа другое; имя
--- сравнивается, только когда задано своё. → LuaEntity │ nil.
local function corpse_near(ctx, t)
  local h = ctx.entity
  local p = util.xy(t.pos)
  local found = h.surface.find_entities_filtered{ type = CORPSE, position = p, radius = M.CORPSE_RADIUS }
  local best, bd, bfull
  for _, e in ipairs(found) do
    if e.valid and (t.name == CORPSE or e.name == t.name) and inv.allowed_force(h, e)
        and inv.charted(h, e.position) then
      local src = inv.main_inventory(e)
      local full = src ~= nil and src.valid and not src.is_empty()
      local d = util.dist(util.xy(e.position), p)
      if best == nil or (full and not bfull) or (full == bfull and d < bd) then
        best, bd, bfull = e, d, full
      end
    end
  end
  return best
end

local function tick_of_death(e)
  local ok, t = pcall(function() return e.character_corpse_tick_of_death end)
  if ok then return t end
  return nil
end

--- Свой последний труп (pickup{corpse:true}) → LuaEntity │ nil, result-ошибка.
local function own_corpse(ctx)
  local h = ctx.entity
  local rec = death.last_corpse(ctx.helper_id)
  if rec == nil or rec.pos == nil then
    return nil, inv.failed("not_found", "this helper has no corpse on record")
  end
  local where = { pos = rec.pos, surface = rec.surface }
  if rec.taken then
    return nil, inv.failed("not_found", "the corpse of this helper was already picked up", where)
  end
  if rec.surface ~= nil and rec.surface ~= h.surface.index then
    local s = game.get_surface(rec.surface)
    where.surface = s and s.name or rec.surface
    return nil, inv.failed("not_reachable", "the corpse is on another surface", where)
  end
  where.surface = h.surface.name
  local p = util.xy(rec.pos)
  if not inv.charted(h, p) then return nil, inv.failed("not_charted", "the corpse is in uncharted chunks", where) end
  local found = h.surface.find_entities_filtered{ type = CORPSE, position = p, radius = M.CORPSE_RADIUS }
  local best, bd
  for _, e in ipairs(found) do
    if e.valid and inv.allowed_force(h, e) then
      local t = tick_of_death(e)
      -- тик смерти известен — только этот труп; не знает его игра — ближайший к месту записи
      if t == nil or t == rec.tick then
        local d = util.dist(util.xy(e.position), p)
        if best == nil or d < bd then best, bd = e, d end
      end
    end
  end
  if best == nil then
    return nil, inv.failed("not_found", "no corpse of this helper at the place of death", where)
  end
  return best
end

function M.start(task, ctx)
  local a = task.args
  local h = ctx.entity
  local n = (a.corpse ~= nil and 1 or 0) + (a.target ~= nil and 1 or 0) + (a.area ~= nil and 1 or 0)
  if n ~= 1 or a.corpse == false then
    return inv.failed("bad_args", "args: exactly one of corpse:true, target, area is required")
  end
  task.picked = {}
  if a.corpse then
    local c, res = own_corpse(ctx)
    if c == nil then return res end
    task.corpse = c
    task.own = true
    return nil
  end
  if a.target then
    local t = a.target
    if t.name ~= nil then
      -- форма {name:"character-corpse", pos}: у трупа в игре нет unit_number, его находят по месту
      local proto = prototypes.entity[t.name]
      if proto ~= nil and proto.type ~= CORPSE then
        return inv.failed("bad_args", "args.target: only a character corpse can be picked up " ..
          "({name: \"character-corpse\", pos})")
      end
      local c = corpse_near(ctx, t)
      if c == nil then c = inv.resolve_target(ctx, t) end   -- нет рядом — общий отказ not_found
      task.corpse = c
      return nil
    end
    local e = inv.resolve_target(ctx, t)
    if e.type ~= CORPSE then
      return inv.failed("bad_args", "args.target: only a character corpse can be picked up " ..
        "({name: \"character-corpse\", pos})")
    end
    task.corpse = e
    return nil
  end
  local see = inv.viewer(ctx)
  local found = h.surface.find_entities_filtered{ area = a.area, type = "item-entity" }
  local list, hidden = {}, 0
  for _, e in ipairs(found) do
    if e.valid and inv.allowed_force(h, e) and e.stack.valid_for_read and inv.is_normal(e.stack.quality) then
      if see(e.position) or inv.in_reach(h, e, "reach") then
        if #list < M.MAX_ITEMS then list[#list + 1] = e end
      else
        hidden = hidden + 1
      end
    end
  end
  if #list == 0 then
    if hidden > 0 then return inv.failed("not_visible", "items in the area are not visible") end
    return inv.failed("not_found", "no items on the ground in the area")
  end
  task.items = list
  task.progress = { done = 0, total = #list }
  return nil
end

local function from_ground(e, main)
  local st = e.stack
  if not st.valid_for_read or not inv.is_normal(st.quality) then return nil, 0 end
  local name = st.name
  local n
  if inv.has_data(name) then
    n = inv.transfer_stack(st, main)
  else
    local count = st.count
    n = main.insert{ name = name, count = count, quality = inv.NORMAL }
    if n >= count then
      st.clear()
    elseif n > 0 then
      st.count = count - n
    end
  end
  -- опустевший item-entity движок убирает сам; destroy не зовём (PROTOCOL §6.5)
  return name, n
end

local function tick_corpse(task, ctx)
  local h = ctx.entity
  local t = task.corpse
  if t == nil or not t.valid then
    inv.stop_approach(task, ctx)
    return inv.failed("not_found", "corpse disappeared")
  end
  local r = inv.approach(task, ctx, t, "reach")
  if r == nil then return nil end
  if r ~= true then return r end
  local src = inv.main_inventory(t)
  local main = h.get_main_inventory()
  local left = {}
  for name, n in pairs(inv.counts(src)) do
    local moved = inv.move(src, { inv = main }, name, n, h)
    inv.add(task.picked, name, moved)
    inv.add(left, name, n - moved)
  end
  local detail = { picked = task.picked }
  -- слот брони пуст (после смерти), а броня теперь в карманах — надеть лучшую с её модулями
  local worn = armor.auto_wear(h)
  if worn ~= nil then
    detail.equipped = worn.equipped
    detail.armor = worn.armor
  end
  if next(left) ~= nil then
    detail.left = left
    return inv.full_result(task, ctx, detail)
  end
  if task.own then death.corpse_taken(task.helper or ctx.helper_id) end
  return inv.done(detail)
end

local function nearest(task, h)
  local hp = util.xy(h.position)
  local best, bi, bd
  local i = 1
  while i <= #task.items do
    local e = task.items[i]
    if not e.valid or not e.stack.valid_for_read then
      table.remove(task.items, i)
    else
      local d = util.dist(hp, util.xy(e.position))
      if bd == nil or d < bd then best, bi, bd = e, i, d end
      i = i + 1
    end
  end
  return best, bi
end

local function tick_area(task, ctx)
  local h = ctx.entity
  local e = task.cur
  if e == nil or not e.valid then
    if e ~= nil then inv.stop_approach(task, ctx) end
    e = nearest(task, h)
    task.cur = e
    if e == nil then
      inv.stop_approach(task, ctx)
      if next(task.picked) == nil then return inv.failed("not_found", "items on the ground are gone") end
      return inv.done({ picked = task.picked })
    end
  end
  local r = inv.approach(task, ctx, e, "pickup")
  if r == nil then return nil end
  if r ~= true then
    r.detail = { picked = task.picked }
    return r
  end
  local name, n = from_ground(e, h.get_main_inventory())
  if name then inv.add(task.picked, name, n) end
  if e.valid and e.stack.valid_for_read then
    -- не влезло: инвентарь полон
    inv.stop_approach(task, ctx)
    local detail = { picked = task.picked }
    return inv.full_result(task, ctx, detail)
  end
  -- подобранный предмет из списка убрать, даже если сущность ещё жива до конца тика
  for i = #task.items, 1, -1 do
    if task.items[i] == e then table.remove(task.items, i) end
  end
  task.cur = nil
  task.progress.done = task.progress.done + 1
  return nil
end

function M.tick(task, ctx)
  if task.corpse ~= nil then return tick_corpse(task, ctx) end
  return tick_area(task, ctx)
end

function M.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
