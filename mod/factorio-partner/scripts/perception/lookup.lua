-- Операция `lookup`: справка «как в Факториопедии».
-- Контракт: docs/STATE.md «lookup», PROTOCOL §6.12 (свойства мира — из игры: имён предметов,
-- машин, технологий и планет здесь нет — всё читается из прототипов и сил).
--
-- Что это вообще такое в игре: рецепты (чем делается, где используется, в каких машинах, какая
-- технология открывает), технологии (что нужно изучить до неё, сколько стоит), постройки.
-- В отличие от `supply` («как это получить на моей базе») — сущности на карте не смотрит.
--
-- Только чтение: читает prototypes.* и force.recipes / force.technologies. Ничего не изучает и не
-- меняет, карту не открывает, в storage не пишет. Индексы (кто какой рецепт открывает, какие машины
-- умеют какую категорию) строятся один раз за вызов и только когда нужны.
--
-- Выборы, которых контракт не задаёт дословно:
--   * `used_in` — без скрытых рецептов, как `made_by`; открытые — первыми, потом по имени;
--   * `made_by` — рецепты, где это основной продукт (`main_product` или единственный продукт),
--     первыми, дальше по имени;
--   * `mined_from[].amount` — сколько этого выпадает за одну добычу (среднее min/max × вероятность);
--   * `machines` — не скрытые прототипы машин (типы assembling-machine, furnace, rocket-silo), по имени;
--   * `unlocked_by` — по имени технологии; у предмета — только у неоткрытых рецептов;
--   * `cost.time` — секунды на одну единицу исследования; `cost` нет у технологий с `trigger`;
--   * `energy_usage` постройки — ватты (в прототипе — джоули за тик);
--   * подсказки `suggest` — без скрытых прототипов, короткие имена первыми. Ошибка операции в
--     протоколе — только {code, text} (PROTOCOL §2): подсказки идут в текст «…; suggest: a, b»,
--     сервер переносит их в detail.suggest.
local err = require("scripts.core.err")
local C = require("scripts.perception.state").common
local find = require("scripts.perception.find")
local supply = require("scripts.perception.supply")
local hand_recipes = require("scripts.perception.recipes")

local F = find.lib
local S = supply.lib
local prop, call0, name_of = F.prop, F.call0, F.name_of

local M = {}

M.NAME_MAX = 200
M.DEFAULT_LIMIT = 20
M.MAX_LIMIT = 50
M.MAX_MACHINES = 10
M.MAX_UNLOCKED_BY = 5
M.MAX_MISSING = 30
M.MAX_SUGGEST = 5
M.KINDS = { "item", "fluid", "recipe", "technology", "entity" }
-- типы прототипов, при добыче которых что-то выпадает (ресурсы, деревья, камни, растения)
M.MINED_TYPES = { "resource", "tree", "simple-entity", "plant", "fish" }

local KIND_SET = {}
for _, k in ipairs(M.KINDS) do KIND_SET[k] = true end

local function sorted_keys(t)
  local out = {}
  if type(t) == "table" then
    for k, v in pairs(t) do
      if type(k) == "string" and v then out[#out + 1] = k end
    end
  end
  table.sort(out)
  return out
end

local function head(list, n)
  local out = {}
  for i = 1, math.min(n, #list) do out[i] = list[i] end
  return out
end

local function num(v)
  if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then return v end
  return nil
end

-- ---------------------------------------------------------------- аргументы

local function parse_args(args)
  args = C.check_args(args)
  C.allow_only(args, { name = true, kind = true, limit = true })
  if args.name == nil then C.bad("name", "required") end
  local a = {}
  a.name = C.check_string(args.name, "name", M.NAME_MAX)
  if args.kind ~= nil then
    if type(args.kind) ~= "string" or not KIND_SET[args.kind] then
      C.bad("kind", "must be one of " .. table.concat(M.KINDS, ", "))
    end
    a.kind = args.kind
  end
  a.limit = C.check_int(args.limit, "limit", 1, M.MAX_LIMIT, M.DEFAULT_LIMIT)
  return a
end

-- Сила и тело для категорий ручного крафта: помощник, без него — хозяин (STATE «lookup»).
local function whose(ctx)
  local e = C.helper_entity(ctx, false)
  if e ~= nil then return e.force, e end
  local owner = C.owner_player()
  if owner == nil then err.raise("no_player", "no helper given and no owner") end
  local body = prop(owner, "character")
  if body ~= nil and not body.valid then body = nil end
  return owner.force, body
end

-- ---------------------------------------------------------------- записи рецептов

local function amount_of(p)
  local a = num(p.amount)
  if a == nil then a = ((num(p.amount_min) or 0) + (num(p.amount_max) or 0)) / 2 end
  return C.round(a)
end

local function ingredients_of(r)
  local out, fluids = {}, false
  for _, ing in ipairs(prop(r, "ingredients") or {}) do
    if type(ing) == "table" and type(ing.name) == "string" then
      local t = ing.type or "item"
      if t == "fluid" then fluids = true end
      out[#out + 1] = { name = ing.name, type = t, amount = amount_of(ing) }
    end
  end
  return out, fluids
end

local function products_of(r)
  local out, fluids = {}, false
  for _, p in ipairs(prop(r, "products") or {}) do
    if type(p) == "table" and type(p.name) == "string" then
      local t = p.type or "item"
      if t == "fluid" then fluids = true end
      local rec = { name = p.name, type = t, amount = amount_of(p) }
      local pr = num(p.probability)
      if pr ~= nil and pr < 1 then rec.probability = C.round(pr * 1000) / 1000 end
      out[#out + 1] = rec
    end
  end
  return out, fluids
end

-- Есть ли (kind, name) среди продуктов рецепта; второе — это основной продукт.
local function produces(r, kind, name)
  local products = prop(r, "products")
  if type(products) ~= "table" then return false, false end
  local found = false
  for _, p in ipairs(products) do
    if type(p) == "table" and p.name == name and S.entry_kind(p) == kind then found = true; break end
  end
  if not found then return false, false end
  local mk, mn = S.main_product(r, products)
  return true, mk == kind and mn == name
end

local function uses(r, kind, name)
  for _, ing in ipairs(prop(r, "ingredients") or {}) do
    if type(ing) == "table" and ing.name == name and S.entry_kind(ing) == kind then return true end
  end
  return false
end

-- ---------------------------------------------------------------- контекст вызова (ленивые индексы)

local function new_ctx(force, body, limit)
  local cx = { force = force, hand_cats = hand_recipes.categories(body), limit = limit }

  -- рецепт → {имя технологии…}: по effects технологий (unlock-recipe), один раз за вызов
  function cx.unlocks_index()
    if cx._unlocks == nil then
      local idx = {}
      for tname, t in pairs(force.technologies or {}) do
        if type(tname) == "string" then
          local effects = prop(prop(t, "prototype") or {}, "effects") or prop(t, "effects")
          for _, ef in ipairs(type(effects) == "table" and effects or {}) do
            if type(ef) == "table" and ef.type == "unlock-recipe" and type(ef.recipe) == "string" then
              local list = idx[ef.recipe]
              if list == nil then list = {}; idx[ef.recipe] = list end
              list[#list + 1] = tname
            end
          end
        end
      end
      for _, list in pairs(idx) do table.sort(list) end
      cx._unlocks = idx
    end
    return cx._unlocks
  end

  -- категория → {имя машины…}: не скрытые прототипы машин, чьи crafting_categories её содержат
  function cx.machines(category)
    if cx._machines == nil then
      local by_cat = {}
      local types = sorted_keys(F.CRAFTER)
      local ok, list = pcall(function()
        return prototypes.get_entity_filtered({ { filter = "type", type = types } })
      end)
      if not ok or list == nil then list = prototypes.entity or {} end
      for ename, proto in pairs(list) do
        if type(ename) == "string" and F.CRAFTER[prop(proto, "type") or ""] and not prop(proto, "hidden") then
          for _, cat in ipairs(sorted_keys(prop(proto, "crafting_categories"))) do
            local l = by_cat[cat]
            if l == nil then l = {}; by_cat[cat] = l end
            l[#l + 1] = ename
          end
        end
      end
      for _, l in pairs(by_cat) do table.sort(l) end
      cx._machines = by_cat
    end
    return cx._machines[category] or {}
  end

  -- запись `recipe` контракта; always_unlocks — unlocked_by и у открытого рецепта
  function cx.recipe(r, always_unlocks)
    local rname = prop(r, "name")
    local category = prop(r, "category")
    local ingredients, f1 = ingredients_of(r)
    local products, f2 = products_of(r)
    local enabled = prop(r, "enabled") == true
    local machines = cx.machines(category)
    local rec = {
      name = rname, enabled = enabled, category = category,
      hand = S.hand_of(category, f1 or f2, cx.hand_cats),
      time = C.round(num(prop(r, "energy")) or 0),
      ingredients = ingredients, products = products,
      machines = head(machines, M.MAX_MACHINES), machines_total = #machines,
    }
    if prop(r, "hidden") == true then rec.hidden = true end
    if always_unlocks or not enabled then
      rec.unlocked_by = head(cx.unlocks_index()[rname] or {}, M.MAX_UNLOCKED_BY)
    end
    return rec
  end

  return cx
end

-- ---------------------------------------------------------------- добыча: что откуда выпадает

local function mined_prototypes()
  local ok, list = pcall(function()
    return prototypes.get_entity_filtered({ { filter = "type", type = M.MINED_TYPES } })
  end)
  if ok and list ~= nil then return list end
  return prototypes.entity or {}
end

local function mined_from(kind, name)
  local order = {}
  for i, t in ipairs(M.MINED_TYPES) do order[t] = i end
  local out = {}
  for ename, proto in pairs(mined_prototypes()) do
    local t = prop(proto, "type")
    if type(ename) == "string" and order[t or ""] then
      local mp = prop(proto, "mineable_properties")
      if type(mp) == "table" and mp.minable ~= false and type(mp.products) == "table" then
        for _, p in ipairs(mp.products) do
          if type(p) == "table" and p.name == name and S.entry_kind(p) == kind then
            local rec = { resource = ename, amount = C.round(S.expected(p)), _o = order[t] }
            if type(mp.required_fluid) == "string" then rec.required_fluid = mp.required_fluid end
            out[#out + 1] = rec
            break
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if a._o ~= b._o then return a._o < b._o end
    return a.resource < b.resource
  end)
  for _, rec in ipairs(out) do rec._o = nil end
  return out
end

-- ---------------------------------------------------------------- предмет и жидкость

local function describe_material(kind, name, proto, cx)
  local made, used = {}, {}
  local any_open = false
  for rname, r in pairs(cx.force.recipes or {}) do
    if type(rname) == "string" and not prop(r, "hidden") then
      local yes, main = produces(r, kind, name)
      if yes then
        local enabled = prop(r, "enabled") == true
        if enabled then any_open = true end
        made[#made + 1] = { r = r, name = rname, main = main }
      end
      if uses(r, kind, name) then
        used[#used + 1] = { recipe = rname, enabled = prop(r, "enabled") == true, category = prop(r, "category") }
      end
    end
  end
  table.sort(made, function(a, b)
    if a.main ~= b.main then return a.main end
    return a.name < b.name
  end)
  table.sort(used, function(a, b)
    if a.enabled ~= b.enabled then return a.enabled end
    return a.recipe < b.recipe
  end)

  local made_by = {}
  for i = 1, math.min(cx.limit, #made) do made_by[i] = cx.recipe(made[i].r, false) end
  local mined = mined_from(kind, name)

  local d = {
    kind = kind, name = name, type = prop(proto, "type") or kind,
    made_by = made_by, made_by_total = #made,
    used_in = head(used, cx.limit), used_in_total = #used,
    mined_from = head(mined, cx.limit),
    researched_any = any_open or #mined > 0,
  }
  if kind == "item" then
    d.stack_size = num(prop(proto, "stack_size"))
    d.place_result = name_of(prop(proto, "place_result"))
  end
  local fuel = num(prop(proto, "fuel_value"))
  if fuel ~= nil and fuel > 0 then d.fuel_value = fuel end
  return d
end

-- ---------------------------------------------------------------- технология

-- Простые поля таблицы эффекта или триггера: числа, строки, bool; объект или {name=…} — его имя.
local function flat(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for k, v in pairs(t) do
    if type(k) == "string" then
      local tv = type(v)
      if tv == "string" or tv == "boolean" or (tv == "number" and num(v) ~= nil) then
        out[k] = v
      elseif tv == "table" or tv == "userdata" then
        local n = name_of(v)
        if type(n) == "string" then out[k] = n end
      end
    end
  end
  return out
end

local function is_researched(force, tname)
  local t = (force.technologies or {})[tname]
  return t ~= nil and prop(t, "researched") == true
end

-- Неизученные предпосылки транзитивно, в порядке изучения (предпосылка раньше зависящей), без
-- повторов. Обход в глубину с выходом после детей; предпосылки — по имени (порядок устойчив).
local function missing_of(force, t)
  local out, seen = {}, {}
  local techs = force.technologies or {}
  local function visit(tech)
    for _, pname in ipairs(sorted_keys(prop(tech, "prerequisites"))) do
      if not seen[pname] and not is_researched(force, pname) then
        seen[pname] = true
        local p = techs[pname]
        if p ~= nil then visit(p) end
        out[#out + 1] = pname
      end
    end
  end
  seen[prop(t, "name") or ""] = true
  visit(t)
  return head(out, M.MAX_MISSING)
end

local function describe_technology(name, t, cx)
  local force = cx.force
  local proto = prop(t, "prototype") or (prototypes.technology or {})[name] or {}
  local prereq, available = {}, true
  for _, pname in ipairs(sorted_keys(prop(t, "prerequisites"))) do
    local done = is_researched(force, pname)
    if not done then available = false end
    prereq[#prereq + 1] = { name = pname, researched = done }
  end

  local unlocks, other = {}, {}
  local effects = prop(proto, "effects") or prop(t, "effects")
  for _, ef in ipairs(type(effects) == "table" and effects or {}) do
    if type(ef) == "table" then
      if ef.type == "unlock-recipe" and type(ef.recipe) == "string" then
        unlocks[#unlocks + 1] = ef.recipe
      elseif type(ef.type) == "string" then
        other[#other + 1] = flat(ef)
      end
    end
  end

  local d = {
    kind = "technology", name = name,
    researched = prop(t, "researched") == true,
    enabled = prop(t, "enabled") ~= false,
    available = available,
    prerequisites = prereq,
    missing = missing_of(force, t),
    unlocks = head(unlocks, cx.limit),
    other_effects = head(other, cx.limit),
  }

  local trigger = prop(proto, "research_trigger")
  if type(trigger) == "table" and type(trigger.type) == "string" then
    d.trigger = flat(trigger)
  else
    local count = num(prop(t, "research_unit_count")) or num(prop(proto, "research_unit_count"))
    local ings = prop(t, "research_unit_ingredients") or prop(proto, "research_unit_ingredients")
    local energy = num(prop(t, "research_unit_energy")) or num(prop(proto, "research_unit_energy"))
    if count ~= nil and count > 0 then
      local list = {}
      for _, ing in ipairs(type(ings) == "table" and ings or {}) do
        if type(ing) == "table" and type(ing.name) == "string" then
          list[#list + 1] = { name = ing.name, amount = num(ing.amount) or 1 }
        end
      end
      d.cost = { count = count, ingredients = list, time = C.round((energy or 0) / 60) }
    end
  end
  return d
end

-- ---------------------------------------------------------------- постройка

local function describe_entity(name, proto)
  local d = { kind = "entity", name = name, type = prop(proto, "type") }
  local w, h = num(prop(proto, "tile_width")), num(prop(proto, "tile_height"))
  if w == nil or h == nil then
    local box = prop(proto, "collision_box")
    if type(box) == "table" and type(box.left_top) == "table" and type(box.right_bottom) == "table" then
      w = math.ceil((box.right_bottom.x or 0) - (box.left_top.x or 0))
      h = math.ceil((box.right_bottom.y or 0) - (box.left_top.y or 0))
    end
  end
  d.size = { w = w or 1, h = h or 1 }

  local items = {}
  for _, it in ipairs(prop(proto, "items_to_place_this") or {}) do
    local n = name_of(it)
    if type(n) == "string" then items[#items + 1] = n end
  end
  d.items_to_place = items

  local cats = sorted_keys(prop(proto, "crafting_categories"))
  if #cats > 0 then
    d.crafting_categories = cats
    local speed = num(prop(proto, "crafting_speed"))
    if speed == nil then speed = num(call0(proto, "get_crafting_speed")) end
    if speed ~= nil then d.crafting_speed = C.round(speed * 100) / 100 end
  end
  local mining = sorted_keys(prop(proto, "resource_categories"))
  if #mining > 0 then d.mining_categories = mining end
  local energy = num(prop(proto, "energy_usage"))
  if energy ~= nil and energy > 0 then d.energy_usage = C.round(energy * 60) end
  local mp = prop(proto, "mineable_properties")
  if type(mp) == "table" and mp.minable ~= false and type(mp.products) == "table" and #mp.products > 0 then
    local res = {}
    for _, p in ipairs(mp.products) do
      if type(p) == "table" and type(p.name) == "string" then
        res[#res + 1] = { name = p.name, type = p.type or "item", amount = amount_of(p) }
      end
    end
    if #res > 0 then d.mineable_results = res end
  end
  return d
end

-- ---------------------------------------------------------------- поиск по имени

-- Таблица прототипов вида; recipe и technology — из силы (у неё есть enabled/researched).
local function source(kind, force)
  if kind == "item" then return prototypes.item end
  if kind == "fluid" then return prototypes.fluid end
  if kind == "recipe" then return force.recipes end
  if kind == "technology" then return force.technologies end
  return prototypes.entity
end

local function suggest(text)
  local q = string.lower(text)
  local seen, list = {}, {}
  local tables = { prototypes.item, prototypes.fluid, prototypes.recipe, prototypes.technology, prototypes.entity }
  for i = 1, #tables do
    for pname, proto in pairs(tables[i] or {}) do
      if type(pname) == "string" and not seen[pname] and not prop(proto, "hidden")
        and string.find(string.lower(pname), q, 1, true) then
        seen[pname] = true
        list[#list + 1] = pname
      end
    end
  end
  table.sort(list, function(a, b)
    if #a ~= #b then return #a < #b end
    return a < b
  end)
  return head(list, M.MAX_SUGGEST)
end

local function not_found(a)
  local what = a.kind or "item, fluid, recipe, technology or entity"
  local text = "no " .. what .. " named " .. err.utf8_trunc(a.name, 60)
  local names = suggest(a.name)
  if #names > 0 then
    local tail = "; suggest: "
    for i, n in ipairs(names) do
      local piece = (i > 1 and ", " or "") .. n
      if #text + #tail + #piece > 290 then break end
      tail = tail .. piece
    end
    if tail ~= "; suggest: " then text = text .. tail end
  end
  err.raise("not_found", text)
end

-- ---------------------------------------------------------------- операция

local function lookup_op(args, ctx)
  local a = parse_args(args)
  local force, body = whose(ctx)
  local kinds = a.kind and { a.kind } or M.KINDS
  for _, kind in ipairs(kinds) do
    local obj = (source(kind, force) or {})[a.name]
    if obj ~= nil then
      local cx = new_ctx(force, body, a.limit)
      if kind == "item" or kind == "fluid" then return describe_material(kind, a.name, obj, cx) end
      if kind == "recipe" then
        local d = cx.recipe(obj, true)
        d.kind = "recipe"
        return d
      end
      if kind == "technology" then return describe_technology(a.name, obj, cx) end
      return describe_entity(a.name, obj)
    end
  end
  not_found(a)
end

M.ops = {
  lookup = lookup_op,
}

-- Для тестов.
M._internal = { parse_args = parse_args, suggest = suggest, missing_of = missing_of }

return M
