-- Операция `supply` (поток U, ревизия 3.7): «что из чего делается и где это взять».
-- Контракт: docs/STATE.md «supply», docs/PROTOCOL.md §6.7 (два уровня обзора), §6.11 (только
-- качество normal), §6.12 (свойства мира — из игры: имён предметов, машин и планет здесь нет).
--
-- Ход работы:
--   1. рецепты силы раскладываются по основному продукту (один перебор force.recipes);
--   2. база просматривается ОДНИМ запросом по сущностям силы помощника (машины, буры, сундуки,
--      цистерны) — из него строятся все указатели сразу, а не поиск на каждый узел дерева;
--   3. дерево строится в ширину (верхние уровни целее при обрезке по числу узлов);
--   4. пятна сырья ищутся одним запросом вокруг помощника — способом операции `resources`.
-- Группы и расстояния — функции операции `find` (find.lib), пятна — resources.cluster.
--
-- Выборы, которых контракт не задаёт дословно (см. также сводку потока):
--   * основной продукт рецепта — `main_product` прототипа, иначе единственный продукт; рецепт с
--     несколькими продуктами без основного не выбирается ни для одного из них;
--   * скрытые рецепты (`hidden`) не рассматриваются — как в операции `recipes`;
--   * `yield` — ожидаемое количество основного продукта за один крафт: amount или среднее
--     amount_min/amount_max, умноженное на probability, плюс extra_count_fraction, минус то же
--     имя среди ингредиентов (катализатор); округляется вниз, но не меньше 1. Рецепт, который
--     предмета не прибавляет (выход ≤ расход), не выбирается;
--   * `time` — секунды на все `crafts` при скорости крафта 1 (energy × crafts);
--   * карманы делятся по дереву: `have` узла — сколько предмета в карманах ещё не занято узлами,
--     стоящими раньше (в порядке обхода в ширину). У первого узла с таким именем это ровно
--     содержимое карманов; так `short` по дереву не занижается, когда один предмет нужен дважды;
--   * `stored.n` — сколько предмета в ближайшей группе сундуков; `producers` — ближайшая группа
--     машин с рецептом, где предмет есть среди продуктов (в том числе побочных);
--   * `resource` ищется не дальше resources.MAX_RADIUS клеток от помощника.
-- Только чтение: ничего не меняет в игре, в storage не пишет.
local err = require("scripts.core.err")
local C = require("scripts.perception.state").common
local find = require("scripts.perception.find")
local resources = require("scripts.perception.resources")
local hand_recipes = require("scripts.perception.recipes")

local F = find.lib
local prop, call0, name_of = F.prop, F.call0, F.name_of

local M = {}

M.MAX_COUNT = 10000
M.DEFAULT_DEPTH = 3
M.MAX_DEPTH = 5
M.MAX_NODES = 60
M.MAX_NAMES = 3          -- имён построек в группе (ответ и так большой)
M.MAX_WARNINGS = 20
M.NAME_MAX = 200
M.DRILL_MARGIN = 3       -- бур «на пятне», если стоит не дальше 3 клеток от его рамки
M.RESOURCE_RADII = { resources.MAX_RADIUS, 64, 32 }

local floor, ceil, max = math.floor, math.ceil, math.max

local function key_of(kind, name) return kind .. "|" .. name end

local function set_of(list)
  local s = {}
  for _, v in ipairs(list) do s[v] = true end
  return s
end

-- ---------------------------------------------------------------- аргументы

local function parse_args(args)
  args = C.check_args(args)
  C.allow_only(args, { item = true, count = true, depth = true })
  if args.item == nil then C.bad("item", "required") end
  local a = {}
  a.item = C.check_string(args.item, "item", M.NAME_MAX)
  a.count = C.check_int(args.count, "count", 1, M.MAX_COUNT, 1)
  a.depth = C.check_int(args.depth, "depth", 1, M.MAX_DEPTH, M.DEFAULT_DEPTH)
  return a
end

local function kind_of(name)
  if prototypes.item ~= nil and prototypes.item[name] ~= nil then return "item" end
  if prototypes.fluid ~= nil and prototypes.fluid[name] ~= nil then return "fluid" end
  return nil
end

-- ---------------------------------------------------------------- рецепты

-- Запись продукта или ингредиента → "item" | "fluid"; прочее (например, прогресс исследования
-- как продукт рецепта) — nil: это не предмет и не жидкость.
local function entry_kind(p)
  local t = p.type
  if t == "fluid" then return "fluid" end
  if t == nil or t == "item" then return "item" end
  return nil
end

-- Ожидаемое количество продукта за один крафт.
local function expected(p)
  local amount = p.amount
  if type(amount) ~= "number" then
    amount = ((tonumber(p.amount_min) or 0) + (tonumber(p.amount_max) or 0)) / 2
  end
  local probability = type(p.probability) == "number" and p.probability or 1
  local extra = type(p.extra_count_fraction) == "number" and p.extra_count_fraction or 0
  return amount * probability + extra
end

local function main_product(recipe, products)
  local main = prop(prop(recipe, "prototype") or {}, "main_product")
  if type(main) == "table" and type(main.name) == "string" then
    return entry_kind(main), main.name
  end
  if #products == 1 and type(products[1]) == "table" and type(products[1].name) == "string" then
    return entry_kind(products[1]), products[1].name
  end
  return nil
end

-- → {[kind/name] = {info, ...}}: info = {name, enabled, category, energy, ingredients, yield, hand}
local function recipe_index(force, hand_cats)
  local index = {}
  for rname, r in pairs(force.recipes) do
    if type(rname) == "string" and not prop(r, "hidden") then
      local products = prop(r, "products")
      local ingredients = prop(r, "ingredients")
      if type(products) == "table" and type(ingredients) == "table" then
        local kind, name = main_product(r, products)
        if kind ~= nil then
          local net, fluids = 0, false
          for _, p in ipairs(products) do
            if type(p) == "table" then
              if entry_kind(p) == "fluid" then fluids = true end
              if p.name == name and entry_kind(p) == kind then net = net + expected(p) end
            end
          end
          local list = {}
          for _, ing in ipairs(ingredients) do
            if type(ing) == "table" and type(ing.name) == "string" and type(ing.amount) == "number" then
              local ikind = entry_kind(ing)
              if ikind == "fluid" then fluids = true end
              if ing.name == name and ikind == kind then net = net - ing.amount end
              if ikind ~= nil then
                list[#list + 1] = { kind = ikind, name = ing.name, amount = ing.amount }
              end
            end
          end
          if net > 0 then
            local category = prop(r, "category")
            local k = key_of(kind, name)
            local bucket = index[k]
            if bucket == nil then bucket = {}; index[k] = bucket end
            bucket[#bucket + 1] = {
              name = rname, item = name, enabled = prop(r, "enabled") == true, category = category,
              energy = tonumber(prop(r, "energy")) or 0, ingredients = list,
              yield = max(1, floor(net)),
              hand = (not fluids) and category ~= nil and hand_cats[category] == true,
            }
          end
        end
      end
    end
  end
  return index
end

-- ---------------------------------------------------------------- база: один проход

-- → base = {by_recipe, producers, by_name, cats, stored, drills, hidden, view}
local function scan(surface, force, helper_id)
  local view = C.chunk_view(force, surface, helper_id)
  local chest_types, tank_types = set_of(F.STORAGE_ITEM), set_of(F.STORAGE_FLUID)
  local types = { "mining-drill" }
  for t in pairs(F.CRAFTER) do types[#types + 1] = t end
  for t in pairs(chest_types) do types[#types + 1] = t end
  for t in pairs(tank_types) do types[#types + 1] = t end
  table.sort(types)

  local base = { by_recipe = {}, producers = {}, by_name = {}, cats = {}, stored = {}, drills = {},
                 hidden = 0, view = view }
  local budget = { n = 0, hint = "the base is too large for supply" }
  local function put(map, k, v)
    local list = map[k]
    if list == nil then list = {}; map[k] = list end
    list[#list + 1] = v
  end

  for _, e in ipairs(F.search(surface, { force = force, type = types }, budget)) do
    if e.valid and view.charted(e.position) then
      local p = e.position
      local x, y, t, ename = p.x or p[1], p.y or p[2], e.type, e.name
      if F.CRAFTER[t] then
        local m = { x = x, y = y, name = ename, entity = e }
        put(base.by_name, ename, m)
        if base.cats[ename] == nil then
          local cats = prop(prop(e, "prototype") or {}, "crafting_categories")
          base.cats[ename] = type(cats) == "table" and cats or {}
        end
        local recipe, quality = F.machine_recipe(e)
        if recipe ~= nil and F.is_normal(quality) then
          local rname = name_of(recipe)
          if rname ~= nil then
            m.recipe = rname
            base.by_recipe[rname] = (base.by_recipe[rname] or 0) + 1
            local seen = {}
            for _, product in ipairs(prop(recipe, "products") or {}) do
              local pkind = type(product) == "table" and type(product.name) == "string"
                and entry_kind(product) or nil
              if pkind ~= nil then
                local k = key_of(pkind, product.name)
                if not seen[k] then
                  seen[k] = true
                  put(base.producers, k, m)
                end
              end
            end
          end
        end
      elseif t == "mining-drill" then
        local target = prop(e, "mining_target")
        if target ~= nil and target.valid ~= false and type(target.name) == "string" then
          put(base.drills, target.name, { x = x, y = y })
        end
      elseif not view.visible(p) then
        base.hidden = base.hidden + 1
      elseif tank_types[t] then
        local contents = call0(e, "get_fluid_contents")
        if type(contents) == "table" then
          for fname, n in pairs(contents) do
            if type(fname) == "string" and type(n) == "number" and n > 0 then
              put(base.stored, key_of("fluid", fname), { x = x, y = y, name = ename, amount = n })
            end
          end
        end
      else
        for iname, n in pairs(C.inv_counts(e.get_inventory(defines.inventory.chest))) do
          put(base.stored, key_of("item", iname), { x = x, y = y, name = ename, amount = n })
        end
      end
    end
  end
  return base
end

-- Ближайшая к центру группа из списка записей {x, y, name, recipe?, amount?}.
local function nearest(list, center)
  local best, bx, by, bd
  for _, g in ipairs(F.cluster(list)) do
    local x, y = g.sx / g.count, g.sy / g.count
    local d = C.dist({ x = x, y = y }, center)
    if best == nil or d < bd or (d == bd and g.count > best.count) then
      best, bx, by, bd = g, x, y, d
    end
  end
  if best == nil then return nil end
  local names = F.top_counts(best.names, M.MAX_NAMES)
  local _, _, recipe = F.top_counts(best.recipes, 1)
  return {
    count = best.count, pos = C.rpos({ x = bx, y = by }), dist = C.round(bd),
    names = names, recipe = recipe, amount = best.amount,
  }
end

-- Сколько готового лежит в выходе машины (только там, где помощник это видит).
local function machine_out(base, m, kind, name)
  if m.visible == nil then
    m.visible = base.view.visible(m) and true or false
    if not m.visible then base.hidden = base.hidden + 1 end
  end
  if not m.visible then return 0 end
  if kind == "fluid" then
    local contents = call0(m.entity, "get_fluid_contents")
    local n = type(contents) == "table" and contents[name] or nil
    return type(n) == "number" and n or 0
  end
  return C.inv_counts(call0(m.entity, "get_output_inventory"), { [name] = true })[name] or 0
end

-- ---------------------------------------------------------------- пятна сырья

local function resource_prototypes()
  local ok, list = pcall(function()
    return prototypes.get_entity_filtered({ { filter = "type", type = "resource" } })
  end)
  if ok and list ~= nil then return list end
  return prototypes.entity or {}
end

-- → {[kind/name] = {имя ресурса, ...}} для всего, что добывается из земли.
local function mined_index()
  local index = {}
  for rname, proto in pairs(resource_prototypes()) do
    if type(rname) == "string" and prop(proto, "type") == "resource" then
      local mp = prop(proto, "mineable_properties")
      local products = type(mp) == "table" and mp.products or nil
      if type(products) == "table" then
        for _, product in ipairs(products) do
          local pkind = type(product) == "table" and type(product.name) == "string"
            and entry_kind(product) or nil
          if pkind ~= nil then
            local k = key_of(pkind, product.name)
            local list = index[k]
            if list == nil then list = {}; index[k] = list end
            list[#list + 1] = rname
          end
        end
      end
    end
  end
  for _, list in pairs(index) do table.sort(list) end
  return index
end

-- Пятна нужных ресурсов вокруг центра: → {[имя ресурса] = ближайшее пятно}, limited (bool).
local function patches_near(surface, base, center, names)
  if #names == 0 then return {}, false end
  local found
  for _, radius in ipairs(M.RESOURCE_RADII) do
    local filter = { position = center, radius = radius, name = names }
    if surface.count_entities_filtered(filter) <= find.MAX_ENTITIES then
      found = surface.find_entities_filtered(filter)
      break
    end
  end
  if found == nil then return {}, true end

  local cells = {}
  for _, e in ipairs(found) do
    if e.valid and base.view.charted(e.position) then
      local p = e.position
      local list = cells[e.name]
      if list == nil then list = {}; cells[e.name] = list end
      list[#list + 1] = { x = floor(p.x or p[1]), y = floor(p.y or p[2]), amount = prop(e, "amount") or 0 }
    end
  end
  local out = {}
  for rname, list in pairs(cells) do
    local best
    for _, patch in ipairs(resources.cluster(list)) do
      patch.dist = C.dist(patch.center, center)
      if best == nil or patch.dist < best.dist then best = patch end
    end
    if best ~= nil then
      local drills = 0
      local lt, rb = best.area.left_top, best.area.right_bottom
      for _, d in ipairs(base.drills[rname] or {}) do
        if d.x >= lt.x - M.DRILL_MARGIN and d.x <= rb.x + M.DRILL_MARGIN
          and d.y >= lt.y - M.DRILL_MARGIN and d.y <= rb.y + M.DRILL_MARGIN then
          drills = drills + 1
        end
      end
      out[rname] = { name = rname, pos = C.rpos(best.center), dist = C.round(best.dist),
                     amount = best.amount, drills = drills, _d = best.dist }
    end
  end
  return out, false
end

-- ---------------------------------------------------------------- операция

local function supply_op(args, ctx)
  local a = parse_args(args)
  local e = C.helper_entity(ctx, true)
  local root_kind = kind_of(a.item)
  if root_kind == nil then err.raise("not_found", "item: no item or fluid named " .. a.item) end

  local surface, force = e.surface, e.force
  local p = e.position
  local center = { x = p.x or p[1], y = p.y or p[2] }
  local index = recipe_index(force, hand_recipes.categories(e))
  local base = scan(surface, force, ctx and ctx.helper_id or nil)

  -- Выбор рецепта узла: → info | nil, причина ("no_recipe" | "not_researched").
  local chosen = {}
  local function choose(k, name)
    local c = chosen[k]
    if c ~= nil then return c.info, c.why end
    local list, open = index[k], {}
    for _, info in ipairs(list or {}) do
      if info.enabled then open[#open + 1] = info end
    end
    table.sort(open, function(x, y)
      local bx, by = base.by_recipe[x.name] ~= nil, base.by_recipe[y.name] ~= nil
      if bx ~= by then return bx end                      -- уже стоит в машинах базы
      if x.hand ~= y.hand then return x.hand end          -- можно руками
      if #x.ingredients ~= #y.ingredients then return #x.ingredients < #y.ingredients end
      local nx, ny = x.name == name, y.name == name
      if nx ~= ny then return nx end                      -- рецепт с именем самого предмета
      return x.name < y.name
    end)
    c = { info = open[1] }
    if open[1] == nil then c.why = (list ~= nil and #list > 0) and "not_researched" or "no_recipe" end
    chosen[k] = c
    return c.info, c.why
  end

  -- Источники по ключу узла считаются один раз, сколько бы узлов с этим именем ни было.
  local stored_cache, producers_cache, makers_cache = {}, {}, {}
  local function stored_of(k)
    local c = stored_cache[k]
    if c == nil then
      c = false
      local list = base.stored[k]
      if list ~= nil then
        local total = 0
        for _, r in ipairs(list) do total = total + r.amount end
        local g = nearest(list, center)
        c = { total = floor(total), pos = g.pos, dist = g.dist, n = floor(g.amount) }
      end
      stored_cache[k] = c
    end
    return c or nil
  end
  local function producers_of(k, kind, name)
    local c = producers_cache[k]
    if c == nil then
      c = false
      local machines = base.producers[k]
      if machines ~= nil then
        local list = {}
        for i, m in ipairs(machines) do
          list[i] = { x = m.x, y = m.y, name = m.name, recipe = m.recipe, amount = machine_out(base, m, kind, name) }
        end
        local g = nearest(list, center)
        c = { count = g.count, pos = g.pos, dist = g.dist, names = g.names, recipe = g.recipe, out = floor(g.amount) }
      end
      producers_cache[k] = c
    end
    return c or nil
  end
  local function makers_of(category)
    if category == nil then return nil end
    local c = makers_cache[category]
    if c == nil then
      c = false
      local list = {}
      for ename, cats in pairs(base.cats) do
        if cats[category] then
          for _, m in ipairs(base.by_name[ename]) do list[#list + 1] = { x = m.x, y = m.y, name = m.name } end
        end
      end
      local g = nearest(list, center)
      if g ~= nil then c = { count = g.count, pos = g.pos, dist = g.dist, names = g.names } end
      makers_cache[category] = c
    end
    return c or nil
  end

  -- Дерево: обход в ширину. meta — служебное по узлу (в ответ не идёт).
  local pool = C.inv_counts(e.get_inventory(defines.inventory.character_main))
  local nodes, meta, queue = {}, {}, {}
  local truncated = false
  local function make(kind, name, need, parent, level)
    local have = kind == "item" and (pool[name] or 0) or 0
    local node = { name = name, kind = kind, need = need, have = have, short = max(0, need - have) }
    if kind == "item" then pool[name] = max(0, have - need) end
    nodes[#nodes + 1] = node
    meta[node] = { key = key_of(kind, name), parent = parent, level = level }
    queue[#queue + 1] = node
    return node
  end
  local function on_path(mt, k)
    local up = mt.parent
    while up ~= nil do
      if meta[up].key == k then return true end
      up = meta[up].parent
    end
    return false
  end

  local tree = make(root_kind, a.item, a.count, nil, 0)
  local head = 1
  while head <= #queue do
    local node = queue[head]
    head = head + 1
    local mt = meta[node]
    local info, why = choose(mt.key, node.name)
    mt.why = why
    if node.short == 0 then
      node.note = "enough"
    elseif info == nil then
      node.note = why
    elseif on_path(mt, mt.key) then
      node.note = "cycle"
    elseif mt.level >= a.depth then
      node.note = "depth"
    elseif #nodes + #info.ingredients > M.MAX_NODES then
      node.note = "truncated"
      truncated = true
    else
      local crafts = ceil(node.short / info.yield)
      local recipe = {
        name = info.name, hand = info.hand, category = info.category, yield = info.yield,
        crafts = crafts, time = C.round(info.energy * crafts),
        makers = makers_of(info.category), ingredients = {},
      }
      for i, ing in ipairs(info.ingredients) do
        recipe.ingredients[i] = make(ing.kind, ing.name, ceil(ing.amount * crafts), node, mt.level + 1)
      end
      node.recipe = recipe
    end
    node.stored = stored_of(mt.key)
    node.producers = producers_of(mt.key, node.kind, node.name)
  end

  -- Пятна сырья: один запрос по именам ресурсов, нужных дереву.
  local mined = mined_index()
  local wanted, names = {}, {}
  for _, node in ipairs(nodes) do
    for _, rname in ipairs(mined[meta[node].key] or {}) do
      if not wanted[rname] then
        wanted[rname] = true
        names[#names + 1] = rname
      end
    end
  end
  table.sort(names)
  local patches, limited = patches_near(surface, base, center, names)

  local warnings, warned = {}, {}
  local function warn(text)
    if not warned[text] and #warnings < M.MAX_WARNINGS then
      warned[text] = true
      warnings[#warnings + 1] = text
    end
  end
  if limited then warn("limit:resources") end

  local any_source = false
  local short, short_at, raw, raw_seen = {}, {}, {}, {}
  for _, node in ipairs(nodes) do
    local mt = meta[node]
    local best
    for _, rname in ipairs(mined[mt.key] or {}) do
      local patch = patches[rname]
      if patch ~= nil and (best == nil or patch._d < best._d) then best = patch end
    end
    if best ~= nil then
      node.resource = { name = best.name, pos = best.pos, dist = best.dist, amount = best.amount, drills = best.drills }
    end
    local makers = node.recipe ~= nil and node.recipe.makers or nil
    if node.stored ~= nil or node.producers ~= nil or node.resource ~= nil or makers ~= nil then
      any_source = true
    end
    if node.short > 0 then
      if mt.why == "not_researched" then warn("not_researched:" .. node.name) end
      if node.stored == nil and node.producers == nil and node.resource == nil and mt.why ~= nil then
        warn("no_source:" .. node.name)
      end
      local at = short_at[mt.key]
      if at == nil then
        at = #short + 1
        short_at[mt.key] = at
        short[at] = { name = node.name, n = 0 }
      end
      short[at].n = short[at].n + node.short
      if (mined[mt.key] ~= nil or mt.why == "no_recipe") and not raw_seen[mt.key] then
        raw_seen[mt.key] = true
        raw[#raw + 1] = short[at] -- та же запись: число досчитается вместе с short
      end
    end
  end
  if tree.short > 0 and not any_source then warn("other_surface") end

  -- raw делит записи с short только на время счёта; в ответ — свои таблицы
  local raw_out = {}
  for i, r in ipairs(raw) do raw_out[i] = { name = r.name, n = r.n } end

  local data = {
    item = a.item, count = a.count, surface = surface.name, tree = tree,
    summary = { short = short, raw = raw_out }, nodes = #nodes, warnings = warnings,
  }
  if truncated then data.truncated = true end
  if base.hidden > 0 then data.hidden = base.hidden end
  return data
end

M.ops = {
  supply = supply_op,
}

-- Для тестов.
M._internal = { expected = expected, parse_args = parse_args }

return M
