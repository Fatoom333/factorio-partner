-- Действие `armor_grid`. Контракт: docs/ACTIONS.md («armor_grid»), PROTOCOL.md §6.
--
-- args: put?: items, take?: items (хотя бы одно). Сначала вынимает модули `take` из сетки
-- надетой брони в инвентарь помощника, потом ставит модули `put` из инвентаря в сетку
-- (свободное место ищется само). Только quality normal, только из карманов (scripts/lib/armor.lua).
-- done.detail = {placed?, not_placed?: [{item, count, reason}], taken?, not_taken?, armor}.
-- reason: no_armor, no_grid, not_equipment, wrong_category, no_item, no_space (в сетке),
-- not_in_grid, inventory_full. Не сделано ничего — failed с кодом по первой причине
-- (armor.CODE_OF); не влезло в инвентарь при take — no_space + inventory_full (ACTIONS «Нет места»).
local inv = require("scripts.lib.inventory")
local armor = require("scripts.lib.armor")

local M = {}
M.name = "armor_grid"
M.schema = {
  put = { type = "items", min_kinds = 1 },
  take = { type = "items", min_kinds = 1 },
}

local function run(task, ctx)
  local h = ctx.entity
  local a = task.args
  local detail = {}
  local reasons = {}
  local did = false
  local full = false
  if a.take ~= nil then
    local taken, not_taken
    taken, not_taken, full = armor.take(h, a.take)
    if next(taken) ~= nil then detail.taken = taken; did = true end
    if #not_taken > 0 then
      detail.not_taken = not_taken
      for _, x in ipairs(not_taken) do reasons[#reasons + 1] = x end
    end
  end
  if a.put ~= nil then
    local placed, not_placed = armor.put(h, a.put)
    if next(placed) ~= nil then detail.placed = placed; did = true end
    if #not_placed > 0 then
      detail.not_placed = not_placed
      for _, x in ipairs(not_placed) do reasons[#reasons + 1] = x end
    end
  end
  detail.armor = armor.summary(h)
  if full then return inv.full_result(task, ctx, detail) end
  if not did then return armor.failed_of(reasons, detail) end
  return inv.done(detail)
end

function M.start(task, ctx)
  local a = task.args
  if a.put == nil and a.take == nil then
    return inv.failed("bad_args", "args: put or take is required")
  end
  for _, field in ipairs({ "put", "take" }) do
    if a[field] ~= nil then inv.check_items(a[field], "args." .. field) end
  end
  return run(task, ctx)
end

function M.tick(task, ctx)
  return run(task, ctx)
end

function M.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
