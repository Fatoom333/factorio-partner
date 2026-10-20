-- Действие `extract`. Контракт: docs/ACTIONS.md («extract / перенос предметов с
-- данными»), PROTOCOL.md §6, §7 (резервы).
--
-- args: target, items? (нет → всё), equip?:bool. Берёт предметы из главного инвентаря цели
-- (сундук, багажник, выход машины) в инвентарь помощника, только в досягаемости (reach_distance).
-- Цель по unit_number ищется и без точного pos: движок (get_entity_by_unit_number) находит не все
-- постройки, поэтому номер ищется вокруг pos и в радиусе 128 вокруг помощника (core/target.lua,
-- opts.near); сила своя или neutral, та же поверхность, открытый чанк — дальше помощник подходит сам.
-- Чужой резерв (storage.reservations других помощников) не трогает. Предметы с данными — только
-- целым стаком (transfer_stack), стак больше заявки не делится и не берётся (попадает в missing);
-- equip=true — взятую броню сразу в слот брони (swap_stack): из нескольких видов — по имени
-- в алфавитном порядке (детерминированно); прежняя броня остаётся в инвентаре помощника и
-- называется в detail.unequipped.
-- done.detail = {extracted: items, missing?: items, equipped?: name, unequipped?: name}. Ничего
-- не взято → failed: reserved (всё нужное в чужом резерве), иначе no_items (если мешает только
-- неделимый стак — с detail.reason = "whole_stacks_only"). Не влезло в инвентарь помощника
-- (взято всё или часть) — событие inventory_full и failed{no_space} (detail — что взято).
local err = require("scripts.core.err")
local reserve = require("scripts.core.reserve")
local target = require("scripts.core.target")
local inv = require("scripts.lib.inventory")

local perms = require("scripts.core.perms")
local lines = require("scripts.lib.lines")

local M = {}
M.name = "extract"

--- Разрешения хозяина (scripts/core/perms.lua) на то, чтобы взять из сущности e.
--- Только постройки хозяина (perms.owner_built): свои машины и сундуки помощников — без разрешений.
--- Труп — не склад хозяина; машина (берётся её выход) и сундук, в который кладёт манипулятор или
--- загрузчик, — выход линии; остальное — свободный сундук.
function M.entity_keys(e)
  if e == nil or e.valid == false or e.type == "character" or e.type == "character-corpse" then return {} end
  if inv.main_inventory(e) == nil or not perms.owner_built(e) then return {} end
  if inv.data_inventory(e) == nil then return { "perm-take-lines" } end
  local ok, fed = pcall(function()
    return e.unit_number ~= nil and lines.fed(e.surface, e.force, e.position, 1)[e.unit_number]
  end)
  if ok and fed then return { "perm-take-lines" } end
  return { "perm-take-chests" }
end

--- Ключи по аргументам — ранний отказ при постановке; окончательно — в start и перед тем, как
--- взять (цель решается заново, сундук мог стать выходом линии, пока задача ждала).
function M.perms(a, ctx)
  return M.entity_keys(perms.find(ctx, a.target))
end

--- Отказ разрешений хозяина по задаче (perm_gate и owner_ok) → результат failed │ nil.
local function perm_failed(task, e)
  local code, text, data = perms.refusal(M.entity_keys(e), task)
  if code ~= nil then return inv.failed(code, text, data) end
  return nil
end
M.schema = {
  target = { type = "target", required = true },
  items = { type = "items", min_kinds = 1 },
  equip = { type = "bool", default = false },
}

--- Цель extract: по unit_number — с широким поиском (pos может быть неточным), иначе как у всех.
function M.resolve(ctx, t)
  local h = ctx.entity
  if t.unit_number ~= nil then
    local e = target.resolve(h.surface, t, h.force, { near = h.position })
    if e ~= nil then
      if not inv.charted(h, e.position) then err.raise("not_charted", "target is in an uncharted chunk") end
      return e
    end
  end
  return inv.resolve_target(ctx, t)
end

function M.start(task, ctx)
  local a = task.args
  if a.items then inv.check_items(a.items, "args.items") end
  local t = M.resolve(ctx, a.target)
  if t.type == "character" then
    return inv.failed("bad_args", "args.target: cannot take items from a character")
  end
  if inv.main_inventory(t) == nil then
    return inv.failed("no_items", "target has no inventory to take from")
  end
  local refused = perm_failed(task, t)
  if refused ~= nil then return refused end
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

  local refused = perm_failed(task, t)
  if refused ~= nil then return refused end
  local src = inv.main_inventory(t)
  local extracted, missing, flags = M.take(task, ctx, src, task.args.items)
  local detail = { extracted = extracted }
  if next(missing) ~= nil then detail.missing = missing end
  if flags.full then
    if task.args.equip then detail.equipped, detail.unequipped = equip_armor(h, extracted) end
    return inv.full_result(task, ctx, detail)
  end
  if next(extracted) == nil then
    if flags.reserved then return inv.failed("reserved", "items are reserved by another helper", detail) end
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
