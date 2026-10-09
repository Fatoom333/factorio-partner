-- Действие `extract` (поток C). Контракт: docs/ACTIONS.md («extract / перенос предметов с
-- данными»), PROTOCOL.md §6, §7 (резервы).
--
-- args: target, items? (нет → всё), equip?:bool. Берёт предметы из главного инвентаря цели
-- (сундук, багажник, выход машины) в инвентарь помощника, только в досягаемости (reach_distance).
-- Чужой резерв (storage.reservations других помощников) не трогает. Предметы с данными — только
-- целым стаком (transfer_stack), стак больше заявки не делится и не берётся (попадает в missing);
-- equip=true — взятую броню сразу в слот брони (swap_stack): из нескольких видов — по имени
-- в алфавитном порядке (детерминированно); прежняя броня остаётся в инвентаре помощника и
-- называется в detail.unequipped.
-- done.detail = {extracted: items, missing?: items, equipped?: name, unequipped?: name}. Ничего
-- не взято → failed: reserved (всё нужное в чужом резерве), stuck{reason:"inventory_full"}
-- (инвентарь полон, плюс событие inventory_full), иначе no_items (если мешает только неделимый
-- стак — с detail.reason = "whole_stacks_only").
local reserve = require("scripts.core.reserve")
local inv = require("scripts.lib.inventory")

local M = {}
M.name = "extract"
M.schema = {
  target = { type = "target", required = true },
  items = { type = "items", min_kinds = 1 },
  equip = { type = "bool", default = false },
}

function M.start(task, ctx)
  local a = task.args
  if a.items then inv.check_items(a.items, "args.items") end
  local t = inv.resolve_target(ctx, a.target)
  if t.type == "character" then
    return inv.failed("bad_args", "args.target: cannot take items from a character")
  end
  if inv.main_inventory(t) == nil then
    return inv.failed("no_items", "target has no inventory to take from")
  end
  task.target = t
  return nil
end

--- Взять из src в инвентарь помощника. → extracted, missing, flags{reserved, full}
function M.take(task, ctx, src, wanted)
  local h = ctx.entity
  local main = h.get_main_inventory()
  local have = inv.counts(src)
  local extracted, missing, flags = {}, {}, {}
  local list = wanted or have
  for name, n in pairs(list) do
    local in_src = have[name] or 0
    local allowed = math.max(0, in_src - reserve.reserved_by_others(ctx.helper_id, name))
    local take = math.min(n, allowed)
    if take < n and in_src > allowed and wanted then flags.reserved = true end
    local moved = 0
    if take > 0 then
      local split
      moved, split = inv.move(src, { inv = main }, name, take, h)
      if split then flags.split = true end
      if moved < take and not split then flags.full = true end
    end
    inv.add(extracted, name, moved)
    if wanted then inv.add(missing, name, n - moved) end
  end
  return extracted, missing, flags
end

--- Надеть взятую броню. → equipped, unequipped (имя снятой брони, она в инвентаре помощника).
local function equip_armor(h, extracted)
  local names = {}
  for name in pairs(extracted) do
    if inv.is_armor(name) then names[#names + 1] = name end
  end
  if #names == 0 then return nil end
  table.sort(names)
  local name = names[1]
  local main = h.get_main_inventory()
  local armor_inv = h.get_inventory(defines.inventory.character_armor)
  if armor_inv == nil or #armor_inv < 1 then return nil end
  local slot = armor_inv[1]
  local old = slot.valid_for_read and slot.name or nil
  for i = 1, #main do
    local st = main[i]
    if st.valid_for_read and st.name == name and inv.is_normal(st.quality) then
      if slot.swap_stack(st) then return name, old end
      return nil
    end
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

  local src = inv.main_inventory(t)
  local extracted, missing, flags = M.take(task, ctx, src, task.args.items)
  local detail = { extracted = extracted }
  if next(missing) ~= nil then detail.missing = missing end
  if flags.full then inv.inventory_full(task, ctx) end
  if next(extracted) == nil then
    if flags.reserved then return inv.failed("reserved", "items are reserved by another helper", detail) end
    if flags.full then return inv.full_result(task, ctx, detail) end
    if flags.split then
      detail.reason = "whole_stacks_only"
      return inv.failed("no_items", "items with data or spoilage move only as whole stacks", detail)
    end
    return inv.failed("no_items", "target does not have the items", detail)
  end
  if task.args.equip then
    detail.equipped, detail.unequipped = equip_armor(h, extracted)
  end
  return inv.done(detail)
end

function M.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
