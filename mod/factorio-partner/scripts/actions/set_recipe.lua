-- Действие `set_recipe` (руки). Контракт: docs/ACTIONS.md («set_recipe»), PROTOCOL.md §6.
--
-- args: target, recipe? (нет — снять рецепт). Меняет рецепт сборочной машины своей силы, как игрок в
-- окне машины: только в досягаемости (reach_distance — помощник сначала подходит), только открытый
-- рецепт подходящей категории; печи (рецепт сам) и машины с жёстким рецептом — bad_args.
-- Что машина вернула при смене (ингредиенты, готовое) — в инвентарь помощника, не влезло — на землю
-- у ног, как у игрока.
-- done.detail = {name, pos, recipe, was, returned:{item=count}, spilled?:int}. Уже стоит — done с тем же was.
local inv = require("scripts.lib.inventory")
local util = require("scripts.core.util")
local B = require("scripts.lib.build")
local place = require("scripts.actions.place")

local M = {}
M.name = "set_recipe"
M.schema = {
  target = { type = "target", required = true },
  recipe = { type = "string", max = 100 },
}

local function fixed_recipe(t)
  local ok, v = pcall(function() return t.prototype.fixed_recipe end)
  return ok and v ~= nil and v ~= ""
end

function M.start(task, ctx)
  local t = inv.resolve_target(ctx, task.args.target)
  local f = t.force
  local fname = type(f) == "string" and f or (f and f.name)
  if fname ~= ctx.entity.force.name then
    return inv.failed("bad_args", "args.target: only machines of the owner's force")
  end
  if t.type ~= "assembling-machine" then
    return inv.failed("bad_args", "args.target: the recipe is set only on assembling machines (a furnace picks it itself)")
  end
  if fixed_recipe(t) then
    return inv.failed("bad_args", "args.target: this machine has a fixed recipe")
  end
  if task.args.recipe ~= nil then
    local why = place.why_bad_recipe(ctx.entity, t.prototype, task.args.recipe)
    if why then return inv.failed("bad_args", "args.recipe: " .. why) end
  end
  task.target = t
  return nil
end

--- Вернуть предметы из машины в инвентарь помощника; не влезло — на землю. → returned, spilled.
local function give_back(h, items)
  local returned, spilled = {}, 0
  local main = h.get_main_inventory()
  for _, it in ipairs(items or {}) do
    local q = it.quality or B.NORMAL
    local qname = type(q) == "string" and q or (q and q.name) or B.NORMAL
    local n = it.count or 0
    local ins = (n > 0 and main) and main.insert{ name = it.name, count = n, quality = qname } or 0
    if ins > 0 then returned[it.name] = (returned[it.name] or 0) + ins end
    if n - ins > 0 then
      h.surface.spill_item_stack{
        position = h.position, stack = { name = it.name, count = n - ins, quality = qname },
        enable_looted = true, allow_belts = false,
      }
      spilled = spilled + (n - ins)
    end
  end
  return returned, spilled
end

function M.tick(task, ctx)
  local t = task.target
  if t == nil or not t.valid then
    inv.stop_approach(task, ctx)
    return inv.failed("not_found", "target disappeared")
  end
  local r = inv.approach(task, ctx, t, "reach")
  if r == nil then return nil end
  if r ~= true then return r end

  local want = task.args.recipe
  local cur = t.get_recipe()
  local was = cur and cur.name or nil
  local detail = { name = t.name, pos = util.pos(t.position), recipe = want, was = was, returned = {} }
  if was == want then return inv.done(detail) end
  local ok, removed = pcall(function() return t.set_recipe(want, B.NORMAL) end)
  if not ok or not t.valid then
    return inv.failed("cannot_place", "the game did not let the recipe change", detail)
  end
  local returned, spilled = give_back(ctx.entity, removed)
  detail.returned = returned
  if spilled > 0 then detail.spilled = spilled end
  return inv.done(detail)
end

function M.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
