-- op `rates`, scope="area" — номинальная оценка по машинам (STATE.md «rates»).
local L = require("stubs_l")
local rates = require("scripts.perception.rates")
local op = rates.ops.rates

local AREA = { left_top = { x = 0, y = 0 }, right_bottom = { x = 64, y = 64 } }

local gear = L.recipe("iron-gear-wheel", 0.5,
  { { type = "item", name = "iron-plate", amount = 2 } },
  { { type = "item", name = "iron-gear-wheel", amount = 1 } })
local smelt = L.recipe("iron-plate", 3.2,
  { { type = "item", name = "iron-ore", amount = 1 } },
  { { type = "item", name = "iron-plate", amount = 1 } })

local function setup(entities, opts)
  opts = opts or {}
  local surf = L.surface { name = "nauvis", entities = {} }
  local force = L.force { visible = opts.visible, recipes = { ["iron-plate"] = smelt, ["iron-gear-wheel"] = gear } }
  for _, mk in ipairs(entities) do
    local e = mk(force)
    surf.entities[#surf.entities + 1] = e
  end
  L.install {
    surfaces = { surf }, forces = { player = force },
    items = { "iron-plate", "iron-gear-wheel", "iron-ore", "copper-ore", "uranium-ore", "stone" },
    fluids = { "crude-oil", "sulfuric-acid", "water" },
  }
  return surf, force, L.character(force, surf, { x = 5, y = 5 })
end

local function call(args, helper)
  local a = { scope = "area", period = "1m", area = AREA }
  for k, v in pairs(args or {}) do a[k] = v end
  return op(a, { helper_id = "h1", entity = helper })
end

local function group(d, name, recipe)
  for _, m in ipairs(d.machines) do
    if m.name == name and m.recipe == recipe then return m end
  end
  return nil
end

L.case("сборщики: crafting_speed / energy * 60, группировка по (машина, рецепт)", function()
  local _, _, h = setup {
    function(f) return L.crafter { force = f, recipe = gear, crafting_speed = 0.75, pos = { x = 1, y = 1 } } end,
    function(f) return L.crafter { force = f, recipe = gear, crafting_speed = 0.75, pos = { x = 4, y = 1 } } end,
  }
  local d = call({}, h)
  L.plain(d)
  L.eq(d.scope, "area"); L.eq(d.nominal, true); L.eq(d.surface, "nauvis")
  L.eq(#d.machines, 1)
  local g = group(d, "assembling-machine-2", "iron-gear-wheel")
  L.eq(g.count, 2)
  -- 0.75 / 0.5 * 60 = 90 циклов/мин на машину, ×2
  L.near(g.out["iron-gear-wheel"], 180, "out")
  L.near(g["in"]["iron-plate"], 360, "in")
  L.near(d.net["iron-gear-wheel"], 180)
  L.near(d.net["iron-plate"], -360)
  L.eq(d.hidden, 0); L.eq(d.truncated, false)
end)

L.case("продуктивность умножает только продукты", function()
  local _, _, h = setup {
    function(f) return L.crafter { force = f, recipe = gear, crafting_speed = 1, productivity_bonus = 0.4 } end,
  }
  local d = call({}, h)
  local g = d.machines[1]
  L.near(g.out["iron-gear-wheel"], 120 * 1.4, "out с бонусом")
  L.near(g["in"]["iron-plate"], 240, "ингредиенты без бонуса")
end)

L.case("ignored_by_productivity, probability, amount_min/max", function()
  local r = L.recipe("weird", 1, {},
    { { type = "item", name = "stone", amount = 2, ignored_by_productivity = 1 },
      { type = "item", name = "iron-ore", amount_min = 1, amount_max = 3, probability = 0.5 } })
  local _, _, h = setup {
    function(f) return L.crafter { force = f, recipe = r, crafting_speed = 1, productivity_bonus = 0.5 } end,
  }
  local d = call({}, h)
  local g = d.machines[1]
  -- stone: 60 * (2 + (2-1)*0.5) = 150; iron-ore: expected = 2*0.5 = 1 -> 60 * 1 * 1.5 = 90
  L.near(g.out.stone, 150)
  L.near(g.out["iron-ore"], 90)
end)

L.case("печь: текущий рецепт и previous_recipe, без рецепта — idle", function()
  local _, _, h = setup {
    function(f) return L.crafter { force = f, name = "stone-furnace", type = "furnace", recipe = smelt, crafting_speed = 2 } end,
    function(f) return L.crafter { force = f, name = "stone-furnace", type = "furnace", crafting_speed = 2,
      previous_recipe = { name = "iron-plate", quality = "normal" } } end,
    function(f) return L.crafter { force = f, name = "stone-furnace", type = "furnace", crafting_speed = 2 } end,
    function(f) return L.crafter { force = f } end,
  }
  local d = call({}, h)
  L.plain(d)
  local g = group(d, "stone-furnace", "iron-plate")
  L.eq(g.count, 2)
  -- 2 / 3.2 * 60 = 37.5 на печь
  L.near(g.out["iron-plate"], 75)
  L.near(g["in"]["iron-ore"], 75)
  L.eq(d.idle, 2, "печь без рецепта и сборщик без рецепта")
end)

L.case("рецепт не normal качества не считается (§6.11)", function()
  local _, _, h = setup {
    function(f) return L.crafter { force = f, recipe = gear, recipe_quality = "rare" } end,
  }
  local d = call({}, h)
  L.eq(#d.machines, 0); L.eq(d.idle, 1)
end)

L.case("буры: mining_speed * (1 + speed_bonus) / mining_time, продуктивность", function()
  local ore = L.resource { name = "iron-ore", mining_time = 1 }
  local _, _, h = setup {
    function(f) return L.drill { force = f, target = ore, mining_speed = 0.5, speed_bonus = 0.2, productivity_bonus = 0.1 } end,
    function(f) return L.drill { force = f, target = ore, mining_speed = 0.5, speed_bonus = 0.2, productivity_bonus = 0.1 } end,
  }
  local d = call({}, h)
  local g = group(d, "electric-mining-drill", "iron-ore")
  L.eq(g.count, 2)
  -- 0.5*1.2*60 = 36 циклов/мин, ×1.1, ×2 = 79.2
  L.near(g.out["iron-ore"], 79.2)
  L.eq(L.count(g["in"]), 0)
end)

L.case("бур на урановой руде тратит кислоту (fluid_amount на 10 циклов)", function()
  local ore = L.resource { name = "uranium-ore", mining_time = 2, required_fluid = "sulfuric-acid", fluid_amount = 10 }
  local _, _, h = setup {
    function(f) return L.drill { force = f, target = ore, mining_speed = 0.5 } end,
  }
  local d = call({}, h)
  local g = d.machines[1]
  -- 0.5/2*60 = 15 циклов/мин -> 15 руды, 15 кислоты
  L.near(g.out["uranium-ore"], 15)
  L.near(g["in"]["sulfuric-acid"], 15)
  L.near(d.net["sulfuric-acid"], -15)
end)

L.case("насос на нефти: выход × amount / normal_resource_amount", function()
  local oil = L.resource { name = "crude-oil", infinite = true, amount = 300000, normal_amount = 300000 / 1.5 * 1,
    mining_time = 1, products = { { type = "fluid", name = "crude-oil", amount = 10 } } }
  local _, _, h = setup {
    function(f) return L.drill { force = f, name = "pumpjack", target = oil, mining_speed = 1 } end,
  }
  local d = call({}, h)
  -- 60 циклов * 10 * 1.5 = 900
  L.near(d.machines[1].out["crude-oil"], 900)
end)

L.case("бур без цели — idle", function()
  local _, _, h = setup { function(f) return L.drill { force = f } end }
  local d = call({}, h)
  L.eq(#d.machines, 0); L.eq(d.idle, 1)
end)

L.case("машины в невидимых чанках — только счётчик hidden (§6.7)", function()
  local _, force, h = setup({
    function(f) return L.crafter { force = f, recipe = gear, pos = { x = 1, y = 1 } } end,
    function(f) return L.crafter { force = f, recipe = gear, pos = { x = 40, y = 1 } } end,
  }, { visible = function(cx, cy) return cx == 0 and cy == 0 end })
  local d = call({}, h)
  L.eq(d.hidden, 1)
  L.eq(d.machines[1].count, 1)
end)

L.case("в поиск идут area, своя сила, типы машин", function()
  local surf, force, h = setup {}
  call({}, h)
  local f = surf.last_filter
  L.eq(f.force, force)
  L.eq(f.area.left_top.x, 0); L.eq(f.area.right_bottom.y, 64)
  local types = {}
  for _, t in ipairs(f.type) do types[t] = true end
  L.eq(types["assembling-machine"] and types["furnace"] and types["mining-drill"], true)
end)

L.case("чужие машины не считаются", function()
  local other = L.force { name = "enemy" }
  local _, _, h = setup {
    function(f) return L.crafter { force = other, recipe = gear } end,
    function(f) return L.crafter { force = f, recipe = gear } end,
  }
  local d = call({}, h)
  L.eq(d.machines[1].count, 1)
end)

L.case("items фильтрует группы и net", function()
  local ore = L.resource { name = "copper-ore" }
  local _, _, h = setup {
    function(f) return L.crafter { force = f, recipe = gear } end,
    function(f) return L.drill { force = f, target = ore } end,
  }
  local d = call({ items = { "copper-ore" } }, h)
  L.eq(#d.machines, 1)
  L.eq(d.machines[1].recipe, "copper-ore")
  L.eq(L.count(d.net), 1)
  L.near(d.net["copper-ore"], 30)
end)

L.case("area обязательна и проверяется", function()
  local _, _, h = setup {}
  L.raises("bad_args", function() op({ scope = "area", period = "1m" }, { entity = h }) end)
  L.raises("bad_args", function()
    op({ scope = "area", period = "1m", area = { left_top = { x = 10, y = 0 }, right_bottom = { x = 0, y = 5 } } }, { entity = h })
  end)
  L.raises("bad_args", function()
    op({ scope = "area", period = "1m", area = { left_top = { x = 0 / 0, y = 0 }, right_bottom = { x = 1, y = 1 } } }, { entity = h })
  end)
  L.raises("limit", function()
    op({ scope = "area", period = "1m", area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 129, y = 1 } } }, { entity = h })
  end)
  L.raises("bad_args", function()
    op({ scope = "surface", period = "1m", area = AREA }, { entity = h })
  end)
end)

L.case("area в ответе округлена до 0.1", function()
  local _, _, h = setup {}
  local d = call({ area = { left_top = { x = 0.123, y = -5.06 }, right_bottom = { x = 10.98, y = 3 } } }, h)
  L.eq(d.area.left_top.x, 0.1); L.eq(d.area.left_top.y, -5.1); L.eq(d.area.right_bottom.x, 11)
end)

L.case("больше 100 групп — truncated", function()
  local list = {}
  for i = 1, 105 do
    local r = L.recipe("r" .. i, 1, {}, { { type = "item", name = "stone", amount = 1 } })
    list[#list + 1] = function(f) return L.crafter { force = f, recipe = r, pos = { x = i % 60, y = 1 } } end
  end
  local _, _, h = setup(list)
  local d = call({}, h)
  L.eq(#d.machines, 100); L.eq(d.truncated, true)
  L.near(d.net.stone, 105 * 60 * 0.75)
end)

L.case("продуктивность ограничена maximum_productivity рецепта", function()
  local capped = L.recipe("capped", 1, { { type = "item", name = "stone", amount = 1 } },
    { { type = "item", name = "iron-plate", amount = 1 } }, 0.5)
  local _, _, h = setup {
    function(f) return L.crafter { force = f, recipe = capped, crafting_speed = 1, productivity_bonus = 2.0 } end,
  }
  local d = call({}, h)
  local g = d.machines[1]
  L.near(g.out["iron-plate"], 60 * 1.5, "бонус 2.0 урезан до 0.5")
  L.near(g["in"].stone, 60)
end)

L.case("без maximum_productivity в рецепте предел по умолчанию +300%", function()
  local _, _, h = setup {
    function(f) return L.crafter { force = f, recipe = gear, crafting_speed = 1, productivity_bonus = 5 } end,
  }
  local d = call({}, h)
  L.near(d.machines[1].out["iron-gear-wheel"], 120 * 4)
end)

L.case("rocket-silo среди машин area", function()
  local part = L.recipe("rocket-part", 3, { { type = "item", name = "stone", amount = 10 } },
    { { type = "item", name = "rocket-part", amount = 1 } })
  local surf, _, h = setup {
    function(f) return L.crafter { force = f, name = "rocket-silo", type = "rocket-silo", recipe = part, crafting_speed = 1 } end,
  }
  local d = call({}, h)
  L.eq(#d.machines, 1)
  L.eq(d.machines[1].name, "rocket-silo")
  L.near(d.machines[1].out["rocket-part"], 20)
  local types = {}
  for _, t in ipairs(surf.last_filter.type) do types[t] = true end
  L.eq(types["rocket-silo"], true)
end)

L.case("area без помощника: хозяин через core.owner, ответ полной формы", function()
  local _, force = setup {}
  local surf = L.surface { name = "nauvis" }
  local me = L.player { name = "Tartaluga", force = force, surface = surf, character = {} }
  L.install { surfaces = { surf }, forces = { player = force }, players = { [1] = me } }
  local d = op({ scope = "area", period = "1m", area = AREA }, {})
  L.plain(d)
  L.eq(d.scope, "area"); L.eq(d.surface, "nauvis"); L.eq(d.per, "1m")
  L.eq(type(d.area.left_top.x), "number"); L.eq(d.hidden, 0); L.eq(d.idle, 0); L.eq(d.truncated, false)
  L.eq(#d.machines, 0)
end)

L.finish("rates_area")
