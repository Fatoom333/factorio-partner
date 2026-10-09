-- Действие `craft` (поток C). Контракт: docs/ACTIONS.md, PROTOCOL.md §6.4.
--
-- args: recipe:string, count:int. Только `begin_crafting` (время и ингредиенты тратит движок).
-- Событий крафта у персонажа без игрока нет (проверено 06.10) — опрашиваем очередь и инвентарь:
-- готово, когда основной продукт вырос на count × выход, или очередь опустела (итог — фактический
-- прирост). done.detail = {crafted: items}.
-- Ошибки старта: неизвестный/не ручной/закрытый рецепт — bad_args; не хватает ингредиентов на
-- count (get_craftable_count, с промежуточными) — no_items с detail {craftable}. Крафт стоит
-- 10 с при полном инвентаре — inventory_full и failed{stuck}. stop снимает поставленный крафт
-- (ингредиенты возвращает движок).
local inv = require("scripts.lib.inventory")

local M = {}
M.name = "craft"
M.schema = {
  recipe = { type = "string", required = true, max = 100 },
  count = { type = "int", required = true, min = 1, max = 10000 },
}

M.CHECK_EVERY = 10
M.STALL_TICKS = 600

--- Основной продукт (имя, выход). main_product есть только у LuaRecipePrototype (2.0), у
--- LuaRecipe такого ключа нет — чтение с LuaRecipe бросает «doesn't contain key».
local function main_product(recipe, rp)
  local mp = rp and rp.main_product
  if type(mp) == "table" and mp.type == "item" and mp.name then
    return mp.name, (mp.amount or mp.amount_max or 1)
  end
  for _, p in ipairs(recipe.products or {}) do
    if (p.type == nil or p.type == "item") and p.name then
      local amount = p.amount or p.amount_max or 1
      return p.name, amount
    end
  end
  return nil
end

local function queue_len(h)
  local ok, q = pcall(function() return h.crafting_queue end)
  if ok and type(q) == "table" then return #q end
  return 0
end

function M.start(task, ctx)
  local a = task.args
  local h = ctx.entity
  local recipe = h.force.recipes[a.recipe]
  if recipe == nil then return inv.failed("bad_args", "args.recipe: unknown recipe " .. a.recipe) end
  if not recipe.enabled then return inv.failed("bad_args", "args.recipe: recipe " .. a.recipe .. " is not researched") end
  -- hidden/enabled/category — у LuaRecipe (своя сила); hidden_from_player_crafting и
  -- main_product — только у прототипа (LuaRecipePrototype)
  local rp = recipe.prototype
  if recipe.hidden or (rp and rp.hidden_from_player_crafting) then
    return inv.failed("bad_args", "args.recipe: " .. a.recipe .. " cannot be crafted by hand")
  end
  local cats = h.prototype.crafting_categories
  if type(cats) == "table" and not cats[recipe.category] then
    return inv.failed("bad_args", "args.recipe: category " .. tostring(recipe.category) .. " is not hand-craftable")
  end
  local product, amount = main_product(recipe, rp)
  if product == nil then return inv.failed("bad_args", "args.recipe: recipe has no item product") end

  local craftable = h.get_craftable_count(a.recipe)
  if craftable < a.count then
    return inv.failed("no_items", "not enough ingredients: craftable " .. craftable, { craftable = craftable })
  end
  local main = h.get_main_inventory()
  task.product = product
  task.base = inv.count(main, product)
  task.queue_base = h.crafting_queue_size or 0
  task.queue_entries = queue_len(h)
  local started = h.begin_crafting{ recipe = a.recipe, count = a.count, silent = true }
  if not started or started <= 0 then
    return inv.failed("no_items", "crafting did not start", { craftable = craftable })
  end
  task.started = started
  task.expected = started * amount
  task.amount = amount
  task.last_qp = -1
  task.last_got = 0
  task.last_change = ctx.tick
  task.progress = { done = 0, total = started }
  return nil
end

local function crafted(task, h)
  local d = inv.count(h.get_main_inventory(), task.product) - task.base
  return d > 0 and d or 0
end

function M.tick(task, ctx)
  local h = ctx.entity
  if (ctx.tick - (task.started_tick or 0)) % M.CHECK_EVERY ~= 0 then return nil end
  local got = crafted(task, h)
  task.progress.done = math.min(task.started, math.floor(got / task.amount))
  local qsize = h.crafting_queue_size or 0
  if got >= task.expected or qsize <= task.queue_base then
    task.cancel_left = nil
    if got <= 0 then
      return inv.failed("stuck", "crafting ended without products", { crafted = {} })
    end
    return inv.done({ crafted = { [task.product] = got } })
  end
  local qp = (h.crafting_queue_progress or 0) + qsize * 10
  if qp ~= task.last_qp or got ~= task.last_got then
    task.last_qp = qp
    task.last_got = got
    task.last_change = ctx.tick
  elseif ctx.tick - task.last_change >= M.STALL_TICKS then
    local main = h.get_main_inventory()
    if main and main.count_empty_stacks() == 0 then
      return inv.full_result(task, ctx, { crafted = { [task.product] = got } })
    end
  end
  return nil
end

--- Снять свой крафт: записи очереди, добавленные этой задачей (после queue_entries).
function M.stop(task, ctx)
  local h = ctx.entity
  if h ~= nil and h.valid and task.started then
    -- снимаем с конца по одной записи и перечитываем очередь: отмена главного крафта может
    -- сама снять его промежуточные записи, индексы сдвигаются
    for _ = 1, 64 do
      local ok, q = pcall(function() return h.crafting_queue end)
      if not ok or type(q) ~= "table" or #q <= (task.queue_entries or 0) then break end
      local item = q[#q]
      local done = pcall(function() h.cancel_crafting{ index = item.index or #q, count = item.count } end)
      if not done then break end
    end
  end
  inv.stop_approach(task, ctx)
end

return M
