-- Действие `insert`. Контракт: docs/ACTIONS.md, PROTOCOL.md §6.
--
-- args: target, items, auto_supply? = false (не хватает предметов у помощника — сначала добыть их
-- как `get_items`, а не failed{no_items}). Кладёт предметы из инвентаря помощника в цель (сундук, печь, машину…):
-- сам подходит на reach_distance, переносит только в досягаемости. Предметы с данными — только
-- целым стаком (transfer_stack) и только в настоящий главный инвентарь цели (сундук, багажник,
-- вагон; у машин без него — bad_args), стак больше заявки не делится (остаётся в left);
-- простые — remove_item у помощника →
-- insert цели, не влезшее возвращается помощнику. Если у помощника не хватает чего-то из items —
-- сразу failed{no_items, detail:{missing}} (ничего не переносится).
-- done.detail = {inserted: items, left?: items, reason?} — left: не влезло в цель (осталось у
-- помощника); reason="whole_stacks_only" — часть left это неделимый стак больше заявки.
-- target = "armor" — модули брони в сетку надетой брони (как armor_grid{put}, scripts/lib/armor.lua):
-- без подхода, нехватка предметов не мешает остальным (не влезшее — left и not_placed с причиной);
-- не поставлено ничего — failed с кодом по первой причине.
-- quality? — только свои вызовы мода (модули в постройку, которую вернул рефлекс evacuate; запрос по
-- RCON с ним — bad_args): все items этого качества, только из карманов тела, без auto_supply.
local err = require("scripts.core.err")
local inv = require("scripts.lib.inventory")
local G = require("scripts.lib.getitems")
local armor = require("scripts.lib.armor")

local M = {}
M.name = "insert"
M.schema = {
  target = { type = { "target", "string" }, values = { "armor" }, required = true },
  items = { type = "items", required = true, min_kinds = 1 },
  auto_supply = { type = "bool", default = false },
  quality = { type = "string", max = 50 },
}

--- quality — только свой вызов мода: в запросе по RCON (ctx.perm_gate) его нет (PROTOCOL §6.11).
function M.check_args(a, ctx)
  if a.quality ~= nil and ctx ~= nil and ctx.perm_gate == true then
    err.raise("bad_args", "args.quality: unknown field")
  end
  return a
end

local function missing_of(h, items, quality)
  local main = h.get_main_inventory()
  local missing = {}
  for name, n in pairs(items) do
    local have = inv.count(main, name, quality)
    if have < n then missing[name] = n - have end
  end
  return missing
end

-- Вставка в сетку надетой брони: {inserted, left?, not_placed?, armor} │ failed.
local function into_armor(task, ctx)
  local h = ctx.entity
  local placed, not_placed = armor.put(h, task.args.items)
  local detail = { inserted = placed, armor = armor.summary(h) }
  if #not_placed > 0 then
    local left = {}
    for _, x in ipairs(not_placed) do inv.add(left, x.item, x.count) end
    detail.left = left
    detail.not_placed = not_placed
  end
  if next(placed) == nil then return armor.failed_of(not_placed, detail) end
  return inv.done(G.with_supply(task, detail))
end

function M.start(task, ctx)
  local a = task.args
  inv.check_items(a.items, "args.items")
  local q = a.quality or inv.NORMAL
  if q ~= inv.NORMAL then
    if task.perm_gate or not inv.known_quality(q) then return inv.failed("bad_args", "args.quality: unknown quality") end
    if a.auto_supply or a.target == "armor" then
      return inv.failed("bad_args", "args.quality: only from the inventory into a building, without auto_supply")
    end
    for name in pairs(a.items) do
      if inv.has_data(name) then return inv.failed("bad_args", "args.items." .. name .. ": items with data are normal only") end
    end
  end
  task.quality = q
  if a.target == "armor" then
    task.armor = true
    if a.auto_supply and next(missing_of(ctx.entity, a.items)) ~= nil then
      G.begin(task, ctx, a.items, {})
      return nil
    end
    return into_armor(task, ctx)
  end
  task.target = inv.resolve_target(ctx, a.target)
  if task.target.unit_number == ctx.entity.unit_number then
    return inv.failed("bad_args", "args.target: cannot insert into itself")
  end
  for name in pairs(a.items) do
    if inv.has_data(name) and inv.data_inventory(task.target) == nil then
      return inv.failed("bad_args", "args.items." .. name
        .. ": items with data go only into a chest, vehicle or wagon inventory")
    end
  end
  local missing = missing_of(ctx.entity, a.items, q)
  if next(missing) ~= nil then
    if not a.auto_supply then
      return inv.failed("no_items", "helper does not have the items", { missing = missing })
    end
    G.begin(task, ctx, a.items, {})
  end
  return nil
end

function M.tick(task, ctx)
  local h = ctx.entity
  local t = task.target
  local pre = G.pre_tick(task, ctx)
  if pre == nil then return nil end
  if pre ~= false then
    inv.stop_approach(task, ctx)
    return G.failed_with(pre, { missing = missing_of(h, task.args.items) })
  end
  if task.armor then return into_armor(task, ctx) end
  if t == nil or not t.valid then
    inv.stop_approach(task, ctx)
    return inv.failed("not_found", "target disappeared")
  end
  local r = inv.approach(task, ctx, t, "reach")
  if r == nil then return nil end
  if r ~= true then return r end

  -- в досягаемости: перепроверить наличие (могло измениться, пока шли)
  local missing = missing_of(h, task.args.items, task.quality)
  if next(missing) ~= nil then
    return inv.failed("no_items", "helper does not have the items", G.with_supply(task, { missing = missing }))
  end
  local main = h.get_main_inventory()
  local inserted, left, split = {}, {}, false
  for name, n in pairs(task.args.items) do
    local moved, whole = inv.move(main, { entity = t }, name, n, h, task.quality)
    if whole then split = true end
    inv.add(inserted, name, moved)
    inv.add(left, name, n - moved)
  end
  local detail = { inserted = inserted }
  if next(left) ~= nil then
    detail.left = left
    -- предмет с данными/портящийся не делится: стак больше заявки не переносится (ACTIONS.md)
    if split then detail.reason = "whole_stacks_only" end
  end
  return inv.done(detail)
end

function M.stop(task, ctx)
  G.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
