-- Заглушки операции `supply`. Дополняют stubs_g.lua (мир восприятия), общий stubs.lua
-- не трогают.
--
--   local U = require("stubs_u")
--   local w = U.world()                         -- мир G + предметы, жидкости, рецепты, ресурсы
--   local _, ctx = U.helper(w, { gear = 4 })    -- помощник h1 в (0,0) с карманами
--   U.machine(w, "smelter", "furnace", 10, 0, { recipe = "plate", cats = { smelting = true }, out = { plate = 7 } })
--   U.chest(w, 5.5, 5.5, { plate = 100 })
--   U.ore(w, "ore", 40, 40, 4, 3, 500)          -- пятно 4×3 по 500
--   U.drill(w, 41, 41, "ore")
--   local d = U.supply({ item = "widget" }, ctx)
--
-- Имена в заглушке выдуманные нарочно: мод не должен знать ни одного имени из игры (§6.12).
local G = require("stubs_g")

local U = {}

U.G = G

-- Рецепт: o = {category?, energy?, enabled?, hidden?, main?, products?}; ingredients — {имя=кол-во}
-- или список записей; продукт по умолчанию — один предмет с именем рецепта.
function U.recipe(w, name, ingredients, o)
  o = o or {}
  local list = {}
  if ingredients[1] ~= nil then
    list = ingredients
  else
    local names = {}
    for k in pairs(ingredients) do names[#names + 1] = k end
    table.sort(names)
    for _, k in ipairs(names) do
      list[#list + 1] = { type = prototypes.fluid[k] and "fluid" or "item", name = k, amount = ingredients[k] }
    end
  end
  local r = {
    name = name, enabled = o.enabled ~= false, hidden = o.hidden or false,
    category = o.category or "crafting", energy = o.energy or 1,
    ingredients = list,
    products = o.products or { { type = "item", name = name, amount = o.yield or 1 } },
    prototype = { main_product = o.main },
  }
  w.force.recipes[name] = r
  return r
end

function U.world(opts)
  local w = G.reset(opts)
  package.loaded["scripts.perception.supply"] = nil
  prototypes.item = {}
  for _, n in ipairs { "widget", "gear", "board", "wire", "plate", "bar", "ore", "rock", "goo-can",
                       "secret", "loop-a", "loop-b", "dust", "mystery", "resin" } do
    prototypes.item[n] = { name = n }
  end
  prototypes.fluid = { goo = { name = "goo" }, steam2 = { name = "steam2" } }
  prototypes.entity["ore"] = { name = "ore", type = "resource",
    mineable_properties = { products = { { type = "item", name = "ore", amount = 1 } } } }
  prototypes.entity["rock-field"] = { name = "rock-field", type = "resource",
    mineable_properties = { products = { { type = "item", name = "rock", amount = 1 } } } }
  prototypes.entity["goo-well"] = { name = "goo-well", type = "resource",
    mineable_properties = { products = { { type = "fluid", name = "goo", amount = 10 } } } }
  game.forces = { player = w.force, enemy = w.enemy, neutral = w.neutral }

  -- widget ← 5 gear + 3 board;  gear ← 2 plate;  board ← 1 plate + 3 wire;  wire ×2 ← 1 bar
  U.recipe(w, "widget", { gear = 5, board = 3 }, { energy = 2 })
  U.recipe(w, "gear", { plate = 2 })
  U.recipe(w, "board", { plate = 1, wire = 3 })
  U.recipe(w, "wire", { bar = 1 }, { yield = 2 })
  -- только в машине
  U.recipe(w, "plate", { ore = 1 }, { category = "smelting", energy = 3.2 })
  U.recipe(w, "bar", { rock = 1 }, { category = "smelting" })
  -- жидкость среди ингредиентов: категория ручная, но руками нельзя
  U.recipe(w, "resin", { goo = 20, rock = 1 })
  -- не открыт
  U.recipe(w, "secret", { plate = 1 }, { enabled = false })
  -- цикл
  U.recipe(w, "loop-a", { ["loop-b"] = 1 })
  U.recipe(w, "loop-b", { ["loop-a"] = 1 })
  return w
end

-- Помощник h1: pockets — {имя=кол-во} или список {name,count,quality}.
function U.helper(w, pockets, o)
  o = o or {}
  o.pos = o.pos or { x = 0, y = 0 }
  o.main = G.inventory(pockets or {}, 80)
  return G.add_helper(w, o.id or "h1", o)
end

-- Машина: o = {recipe?, cats, out? ({имя=кол-во}), fluids?, force?, quality?, previous?}
function U.machine(w, name, etype, x, y, o)
  o = o or {}
  local force = o.force or w.force
  local e = w.surface.add(G.entity { name = name, type = etype, pos = { x = x, y = y }, force = force, size = 2 })
  e.prototype.crafting_categories = o.cats or { crafting = true }
  local r = o.recipe and w.force.recipes[o.recipe] or nil
  e.get_recipe = function() return r, o.quality end
  if o.previous then e.previous_recipe = { name = o.previous, quality = "normal" } end
  local out = G.inventory(o.out or {})
  e.out_reads = 0
  e.get_output_inventory = function()
    e.out_reads = e.out_reads + 1
    return out
  end
  e.get_fluid_contents = function() return o.fluids or {} end
  return e
end

function U.chest(w, x, y, items, o)
  o = o or {}
  return w.surface.add(G.entity { name = o.name or "box", type = o.type or "container",
    pos = { x = x, y = y }, force = o.force or w.force, size = 1, inventory = G.inventory(items) })
end

function U.tank(w, x, y, fluids, o)
  o = o or {}
  local e = w.surface.add(G.entity { name = "tank", type = "storage-tank", pos = { x = x, y = y },
    force = o.force or w.force, size = 3 })
  e.get_fluid_contents = function() return fluids end
  return e
end

-- Пятно ресурса: прямоугольник wd×ht клеток с левым верхним углом (x, y).
function U.ore(w, name, x, y, wd, ht, amount)
  for dx = 0, wd - 1 do
    for dy = 0, ht - 1 do
      w.surface.add(G.entity { name = name, type = "resource", pos = { x = x + dx + 0.5, y = y + dy + 0.5 },
        force = w.neutral, amount = amount, unit = false })
    end
  end
end

function U.drill(w, x, y, resource, o)
  o = o or {}
  local e = w.surface.add(G.entity { name = "digger", type = "mining-drill", pos = { x = x, y = y },
    force = o.force or w.force, size = 3 })
  if resource then e.mining_target = { valid = true, name = resource } end
  return e
end

-- Ответ операции, проверенный на сериализуемость (как уйдёт по RCON).
function U.supply(args, ctx)
  local d = require("scripts.perception.supply").ops.supply(args, ctx)
  G.plain(d)
  G.json(d)
  return d
end

-- Все узлы дерева списком (в глубину).
function U.nodes(d)
  local out = {}
  local function walk(n)
    out[#out + 1] = n
    for _, c in ipairs(n.recipe and n.recipe.ingredients or {}) do walk(c) end
  end
  walk(d.tree)
  return out
end

-- Первый узел с таким именем.
function U.node(d, name)
  for _, n in ipairs(U.nodes(d)) do
    if n.name == name then return n end
  end
  return nil
end

function U.has(list, text)
  for _, v in ipairs(list or {}) do
    if v == text then return true end
  end
  return false
end

-- summary.short / summary.raw → {имя=n}
function U.flat(list)
  local out = {}
  for _, r in ipairs(list or {}) do out[r.name] = r.n end
  return out
end

return U
