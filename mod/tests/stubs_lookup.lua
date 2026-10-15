-- Заглушки операции `lookup`. Дополняют stubs_u.lua (мир `supply`): прототипы рецептов
-- и технологий, машины-прототипы, деревья и камни. Общий stubs.lua не трогают.
--
--   local K = require("stubs_lookup")
--   local w = K.world()                      -- мир U + технологии и прототипы машин
--   local _, ctx = K.helper(w)
--   local d = K.lookup({ name = "plate" }, ctx)
--
-- Имена выдуманные нарочно: мод не должен знать ни одного имени из игры (§6.12).
local U = require("stubs_u")
local G = U.G

local K = {}
K.G, K.U = G, U

-- Технология: o = {pre = {имена}, unlocks = {рецепты}, other = {эффекты}, researched?, enabled?,
-- count?, ingredients? ({имя=кол-во}), energy? (тики на единицу), trigger?}
function K.tech(w, name, o)
  o = o or {}
  local effects = {}
  for _, r in ipairs(o.unlocks or {}) do effects[#effects + 1] = { type = "unlock-recipe", recipe = r } end
  for _, ef in ipairs(o.other or {}) do effects[#effects + 1] = ef end
  local ings = {}
  local names = {}
  for k in pairs(o.ingredients or {}) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do ings[#ings + 1] = { type = "item", name = k, amount = o.ingredients[k] } end
  local proto = { name = name, effects = effects, research_trigger = o.trigger,
                  research_unit_count = o.count or (o.trigger and 0 or 10), research_unit_ingredients = ings,
                  research_unit_energy = o.energy or 600 }
  local t = { name = name, researched = o.researched == true, enabled = o.enabled ~= false,
              prerequisites = {}, prototype = proto,
              research_unit_count = proto.research_unit_count, research_unit_ingredients = ings,
              research_unit_energy = proto.research_unit_energy }
  w.force.technologies[name] = t
  prototypes.technology[name] = proto
  for _, p in ipairs(o.pre or {}) do t.prerequisites[p] = w.force.technologies[p] or { name = p } end
  return t
end

function K.world(opts)
  local w = U.world(opts)
  package.loaded["scripts.perception.lookup"] = nil
  package.loaded["scripts.perception.supply"] = nil
  w.force.technologies = {}
  prototypes.technology = {}
  -- прототипы рецептов — те же записи, что у силы (для подсказок по имени)
  prototypes.recipe = w.force.recipes

  -- второй рецепт plate: побочный продукт; и скрытый рецепт plate (не показывается)
  U.recipe(w, "plate-from-rock", { rock = 2 }, { category = "smelting",
    products = { { type = "item", name = "dust", amount = 1 },
                 { type = "item", name = "plate", amount = 1, probability = 0.5 } },
    main = { type = "item", name = "dust" } })
  U.recipe(w, "plate-recycle", { widget = 1 }, { hidden = true,
    products = { { type = "item", name = "plate", amount = 3 } } })

  -- машины-прототипы (для `machines`) и постройка с полями
  prototypes.entity["smelter"] = { name = "smelter", type = "furnace", tile_width = 2, tile_height = 2,
    crafting_categories = { smelting = true }, crafting_speed = 2, energy_usage = 1500,
    items_to_place_this = { { name = "smelter", count = 1 } },
    mineable_properties = { minable = true, products = { { type = "item", name = "smelter", amount = 1 } } } }
  prototypes.entity["maker"] = { name = "maker", type = "assembling-machine", tile_width = 3, tile_height = 3,
    crafting_categories = { crafting = true, smelting = false } }
  prototypes.entity["big-maker"] = { name = "big-maker", type = "assembling-machine",
    crafting_categories = { crafting = true, smelting = true } }
  prototypes.entity["old-maker"] = { name = "old-maker", type = "assembling-machine", hidden = true,
    crafting_categories = { crafting = true } }
  prototypes.entity["digger"] = { name = "digger", type = "mining-drill", tile_width = 3, tile_height = 3,
    resource_categories = { basic = true } }
  -- дерево и камень: при добыче тоже что-то выпадает
  prototypes.entity["bush"] = { name = "bush", type = "tree",
    mineable_properties = { minable = true, products = { { type = "item", name = "resin", amount = 2 } } } }
  prototypes.entity["boulder"] = { name = "boulder", type = "simple-entity",
    mineable_properties = { minable = true, products = { { type = "item", name = "rock", amount_min = 20, amount_max = 30 } } } }
  prototypes.item["smelter"] = { name = "smelter", type = "item", stack_size = 50,
    place_result = prototypes.entity["smelter"] }
  prototypes.item["plate"] = { name = "plate", type = "item", stack_size = 100 }
  prototypes.item["ore"] = { name = "ore", type = "item", stack_size = 50, fuel_value = 0 }
  prototypes.item["rock"] = { name = "rock", type = "item", stack_size = 50, fuel_value = 2000000 }
  return w
end

function K.helper(w, pockets, o)
  return U.helper(w, pockets, o)
end

-- Ответ операции, проверенный на сериализуемость (как уйдёт по RCON).
function K.lookup(args, ctx)
  local d = require("scripts.perception.lookup").ops.lookup(args, ctx)
  G.plain(d)
  G.json(d)
  return d
end

function K.names(list, field)
  local out = {}
  for i, v in ipairs(list or {}) do out[i] = field and v[field] or v end
  return out
end

return K
