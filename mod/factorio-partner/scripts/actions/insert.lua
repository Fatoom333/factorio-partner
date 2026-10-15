-- Действие `insert`. Контракт: docs/ACTIONS.md, PROTOCOL.md §6.
--
-- args: target, items. Кладёт предметы из инвентаря помощника в цель (сундук, печь, машину…):
-- сам подходит на reach_distance, переносит только в досягаемости. Предметы с данными — только
-- целым стаком (transfer_stack) и только в настоящий главный инвентарь цели (сундук, багажник,
-- вагон; у машин без него — bad_args), стак больше заявки не делится (остаётся в left);
-- простые — remove_item у помощника →
-- insert цели, не влезшее возвращается помощнику. Если у помощника не хватает чего-то из items —
-- сразу failed{no_items, detail:{missing}} (ничего не переносится).
-- done.detail = {inserted: items, left?: items, reason?} — left: не влезло в цель (осталось у
-- помощника); reason="whole_stacks_only" — часть left это неделимый стак больше заявки.
local inv = require("scripts.lib.inventory")

local M = {}
M.name = "insert"
M.schema = {
  target = { type = "target", required = true },
  items = { type = "items", required = true, min_kinds = 1 },
}

local function missing_of(h, items)
  local main = h.get_main_inventory()
  local missing = {}
  for name, n in pairs(items) do
    local have = inv.count(main, name)
    if have < n then missing[name] = n - have end
  end
  return missing
end

function M.start(task, ctx)
  local a = task.args
  inv.check_items(a.items, "args.items")
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
  local missing = missing_of(ctx.entity, a.items)
  if next(missing) ~= nil then
    return inv.failed("no_items", "helper does not have the items", { missing = missing })
  end
  return nil
end

function M.tick(task, ctx)
  local h = ctx.entity
  local t = task.target
  if t == nil or not t.valid then
    inv.stop_approach(task, ctx)
    return inv.failed("not_found", "target disappeared")
  end
  local r = inv.approach(task, ctx, t, "reach")
  if r == nil then return nil end
  if r ~= true then return r end

  -- в досягаемости: перепроверить наличие (могло измениться, пока шли)
  local missing = missing_of(h, task.args.items)
  if next(missing) ~= nil then
    return inv.failed("no_items", "helper does not have the items", { missing = missing })
  end
  local main = h.get_main_inventory()
  local inserted, left, split = {}, {}, false
  for name, n in pairs(task.args.items) do
    local moved, whole = inv.move(main, { entity = t }, name, n, h)
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
  inv.stop_approach(task, ctx)
end

return M
