-- Действие `place`: поставить постройку из инвентаря помощника.
-- Контракт: docs/ACTIONS.md (список v1, «Подход»), PROTOCOL.md §6.5.
--
-- args: item (предмет из инвентаря), pos, direction? = 0 (defines.direction, 0..15),
--       recipe? (только для сборочных машин: рецепт своей силы, открытый, подходящей категории),
--       auto_supply? = false (нет предмета в инвентаре — сначала добыть его как `get_items`).
-- done.detail: {unit_number, name, pos}.
-- Ход (честность §6.5): сам подходит на build_distance → LuaControl.can_place_entity
-- (досягаемость + коллизии) → surface.create_entity{force, raise_built=true, quality="normal"}
-- → remove_item (quality normal); не списалось → постройка убирается, `no_items`.
-- Если мешает само тело помощника — отходит в сторону и пробует снова (до 2 раз).
-- Ошибки: bad_args (не предмет-постройка, предмет с данными, плохой рецепт), no_items,
-- not_charted, reserved (область держит другой помощник), not_visible, cannot_place,
-- ошибки пути (path_failed, stuck, not_charted).
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")
local G = require("scripts.lib.getitems")

local perms = require("scripts.core.perms")

local M = {}
M.name = "place"

--- Разрешения хозяина (scripts/core/perms.lua): какие ключи задевают эти аргументы.
function M.perms(a, ctx)
  return { "perm-build" }
end
M.schema = {
  item = { type = "string", required = true, max = 100 },
  pos = { type = "pos", required = true },
  direction = { type = "int", min = 0, max = 15, default = 0 },
  recipe = { type = "string", max = 100 },
  auto_supply = { type = "bool", default = false },
}

local function stop(task, ctx)
  B.stop_approach(task, ctx)
  task.aside = nil
end

local function fail(task, ctx, code, text)
  stop(task, ctx)
  return B.failed(code, text)
end

--- Рецепт можно задать этой постройке? → nil │ текст причины.
local function why_bad_recipe(h, proto, name)
  if proto.type ~= "assembling-machine" then return "recipe is only for assembling machines" end
  local r = h.force.recipes[name]
  if r == nil then return "unknown recipe " .. name end
  if not r.enabled then return "recipe " .. name .. " is not researched" end
  local cats = proto.crafting_categories
  if type(cats) == "table" and not cats[r.category] then
    return proto.name .. " cannot craft " .. name
  end
  return nil
end
M.why_bad_recipe = why_bad_recipe

function M.start(task, ctx)
  local a, h = task.args, ctx.entity
  local ip = inv.item_proto(a.item)
  if ip == nil then return B.failed("bad_args", "args.item: unknown item " .. a.item) end
  local ep = ip.place_result
  if ep == nil then return B.failed("bad_args", "args.item: " .. a.item .. " does not place an entity") end
  if inv.has_data(a.item) then
    return B.failed("bad_args", "args.item: items with data are not placed in v1")
  end
  if a.recipe ~= nil then
    local why = why_bad_recipe(h, ep, a.recipe)
    if why then return B.failed("bad_args", "args.recipe: " .. why) end
  end
  -- сколько предметов стоит постройка (обычно 1)
  local need = 1
  for _, it in ipairs(B.place_items(ep)) do
    if it.name == a.item then need = it.count break end
  end
  if not B.charted(h, a.pos) then return B.failed("not_charted", "pos is in an uncharted chunk") end
  B.check_free(ctx, B.footprint(ep, a.pos, a.direction))
  if inv.count(h.get_main_inventory(), a.item) < need then
    if not a.auto_supply then return B.failed("no_items", "no " .. a.item .. " in the inventory") end
    G.begin(task, ctx, { [a.item] = need }, {})
  end
  task.entity_name = ep.name
  task.need = need
  task.asides = 0
  return nil
end

function M.tick(task, ctx)
  local a, h = task.args, ctx.entity
  local pre = G.pre_tick(task, ctx)
  if pre == nil then return nil end
  if pre ~= false then
    stop(task, ctx)
    return B.failed(pre.code, pre.text, { supply = pre.detail })
  end
  if task.aside ~= nil then
    local r = B.approach(task, ctx, task.aside, 0.6)
    if r == nil then return nil end
    task.aside = nil
    if r ~= true then return fail(task, ctx, "cannot_place", "helper stands on the spot and cannot step aside") end
  end
  local r = B.approach(task, ctx, a.pos, h.build_distance - 0.5)
  if r == nil then return nil end
  if r ~= true then
    stop(task, ctx)
    return r
  end
  if not B.visible(ctx, a.pos) then return fail(task, ctx, "not_visible", "pos is not visible") end
  if inv.count(h.get_main_inventory(), a.item) < task.need then
    stop(task, ctx)
    return B.failed("no_items", "no " .. a.item .. " in the inventory", G.with_supply(task))
  end
  local proto = prototypes.entity[task.entity_name]
  if not h.can_place_entity{ name = task.entity_name, position = a.pos, direction = a.direction } then
    if B.body_inside(h, proto, a.pos, a.direction) and task.asides < B.MAX_ASIDE then
      task.asides = task.asides + 1
      task.aside = B.aside_point(h, proto, a.pos, a.direction)
      return nil
    end
    return fail(task, ctx, "cannot_place", task.entity_name .. " cannot be placed here")
  end
  local e = h.surface.create_entity{
    name = task.entity_name, position = a.pos, direction = a.direction, force = h.force,
    raise_built = true, quality = B.NORMAL,
  }
  if e == nil or not e.valid then
    return fail(task, ctx, "cannot_place", task.entity_name .. " cannot be placed here")
  end
  local removed = h.remove_item{ name = a.item, count = task.need, quality = B.NORMAL }
  if removed < task.need then
    -- откат: постройка без списанного предмета — это предмет из воздуха
    if removed > 0 then h.insert{ name = a.item, count = removed, quality = B.NORMAL } end
    e.destroy{ raise_destroy = true }
    return fail(task, ctx, "no_items", "no " .. a.item .. " in the inventory")
  end
  local detail = { unit_number = e.unit_number, name = e.name, pos = util.pos(e.position) }
  if a.recipe ~= nil then
    local ok = pcall(function() e.set_recipe(a.recipe, B.NORMAL) end)
    if not ok then detail.recipe_set = false end
  end
  stop(task, ctx)
  return B.done(detail)
end

function M.stop(task, ctx)
  G.stop(task, ctx)
  stop(task, ctx)
end

return M
