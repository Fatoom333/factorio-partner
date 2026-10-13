-- Действие `pickup` (поток C). Контракт: docs/ACTIONS.md, PROTOCOL.md §6.
--
-- args: target (труп: `{name:"character-corpse", pos}`) │ area (предметы на земле). Ровно одно.
-- * труп — цель в форме {name, pos} (у трупа в игре нет unit_number; pos — `corpse` из события
--   `died` или `helper_list`): ближайший труп в 3 клетках от pos. Подходит на reach_distance и
--   забирает всё (normal) из инвентаря трупа; предметы с
--   данными — целым стаком (transfer_stack);
-- * area — предметы на земле (`item-entity`, своя сила или neutral, только normal) в области
--   (сторона ≤ 128); живое (PROTOCOL §6.7): берутся только видимые предметы (видимый чанк или
--   уже в досягаемости помощника), если в области есть только невидимые — not_visible. Обходит
--   ближайший-первым, к каждому подходит на item_pickup_distance; не больше 500 за задачу.
-- done.detail = {picked: items}; инвентарь полон — событие inventory_full и failed{no_space}
-- (detail: picked и, у трупа, left).
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")

local M = {}
M.name = "pickup"
M.schema = {
  target = { type = "target" },
  area = { type = "area" },
}

M.MAX_ITEMS = 500
M.CORPSE_RADIUS = 3   -- труп ищем вокруг pos: место смерти в событии округлено, тело могло упасть рядом

local CORPSE = "character-corpse"   -- тип прототипа (у трупов из модов имя другое, тип тот же)

--- Труп по форме цели {name, pos} (ACTIONS.md «pickup»): ближайший к pos труп с этим именем прототипа
--- в радиусе CORPSE_RADIUS, своей силы или neutral, в открытом чанке; непустой — раньше пустого
--- (на одном месте может лежать несколько трупов). → LuaEntity │ nil.
local function corpse_near(ctx, t)
  local h = ctx.entity
  local p = util.xy(t.pos)
  local found = h.surface.find_entities_filtered{ type = CORPSE, position = p, radius = M.CORPSE_RADIUS }
  local best, bd, bfull
  for _, e in ipairs(found) do
    if e.valid and e.name == t.name and inv.allowed_force(h, e) and inv.charted(h, e.position) then
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

function M.start(task, ctx)
  local a = task.args
  local h = ctx.entity
  if (a.target == nil) == (a.area == nil) then
    return inv.failed("bad_args", "args: exactly one of target, area is required")
  end
  task.picked = {}
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
  if next(left) ~= nil then
    detail.left = left
    return inv.full_result(task, ctx, detail)
  end
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
