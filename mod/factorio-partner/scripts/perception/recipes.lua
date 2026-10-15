-- Операция `recipes`: что помощник может скрафтить руками сейчас.
-- Контракт: docs/STATE.md «recipes». Перебор force.recipes: enabled, не hidden,
-- категория ∈ crafting_categories персонажа; значение — get_craftable_count, нули не выводим.
local C = require("scripts.perception.state").common

local M = {}

local function categories(e)
  local ok, cats = pcall(function() return e.prototype.crafting_categories end)
  if ok and type(cats) == "table" and next(cats) ~= nil then return cats end
  local p = prototypes.entity["character"]
  return (p and p.crafting_categories) or {}
end

local function recipes_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { filter = true })
  -- Пустая строка — «без фильтра» (подстрока "" и так совпала бы со всем).
  local filter = args.filter
  if filter == "" then filter = nil end
  filter = C.check_string(filter, "filter", 100)
  local e = C.helper_entity(ctx, true)
  local cats = categories(e)
  local out = {}
  for name, r in pairs(e.force.recipes) do
    if r.enabled and not r.hidden and cats[r.category]
      and (filter == nil or string.find(name, filter, 1, true)) then
      local n = e.get_craftable_count(name)
      if type(n) == "number" and n > 0 then out[name] = n end
    end
  end
  return { craftable = out }
end

-- Категории ручного крафта тела — нужны и операции `supply`.
M.categories = categories

M.ops = {
  recipes = recipes_op,
}

return M
