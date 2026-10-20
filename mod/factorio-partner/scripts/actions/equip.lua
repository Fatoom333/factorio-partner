-- Действие `equip`. Контракт: docs/ACTIONS.md («equip»), PROTOCOL.md §6.
--
-- args: item (имя брони). Надевает броню из главного инвентаря помощника в слот брони
-- (swap_stack): прежняя броня целым стаком — со своей сеткой и модулями — встаёт на место
-- новой в инвентаре, как у игрока. Только quality normal, только из карманов.
-- done.detail = {equipped, unequipped?, armor: {name, grid?: {w, h, used, free, equipment}}}.
-- Уже надета эта броня — done без unequipped. Брони нет в инвентаре — failed{no_items, missing};
-- предмет не броня — bad_args; игра не дала поменять — cannot_place.
local inv = require("scripts.lib.inventory")
local armor = require("scripts.lib.armor")

local M = {}
M.name = "equip"
M.schema = {
  item = { type = "string", required = true },
}

local function wear(task, ctx)
  local h = ctx.entity
  local name = task.args.item
  local p = inv.item_proto(name)
  if p == nil then return inv.failed("bad_args", "args.item: unknown item " .. name) end
  if p.type ~= "armor" then return inv.failed("bad_args", "args.item: " .. name .. " is not armor") end
  local slot = armor.slot(h)
  if slot == nil then return inv.failed("bad_args", "the body has no armor slot") end
  local old = slot.valid_for_read and slot.name or nil
  if old == name and inv.is_normal(slot.quality) then
    return inv.done({ equipped = name, armor = armor.summary(h) })
  end
  local main = h.get_main_inventory()
  for i = 1, #main do
    local st = main[i]
    if st.valid_for_read and st.name == name and inv.is_normal(st.quality) then
      if not slot.swap_stack(st) then
        return inv.failed("cannot_place", "the game did not allow to swap the armor")
      end
      return inv.done({ equipped = name, unequipped = old, armor = armor.summary(h) })
    end
  end
  return inv.failed("no_items", "helper does not have the armor", { missing = { [name] = 1 } })
end

function M.start(task, ctx)
  return wear(task, ctx)
end

function M.tick(task, ctx)
  return wear(task, ctx)
end

function M.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
