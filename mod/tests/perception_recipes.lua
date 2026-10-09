-- Тесты операции `recipes` (поток G). Контракт: docs/STATE.md «recipes».
local G = require("stubs_g")

do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 },
    craftable = { ["iron-gear-wheel"] = 20, pipe = 40, ["electronic-circuit"] = 0, ["steel-plate"] = 5,
                  ["hidden-thing"] = 3, ["locked"] = 2 } })
  w.force.recipes = {
    ["iron-gear-wheel"] = { enabled = true, hidden = false, category = "crafting" },
    pipe = { enabled = true, hidden = false, category = "crafting" },
    ["electronic-circuit"] = { enabled = true, hidden = false, category = "crafting" },
    ["steel-plate"] = { enabled = true, hidden = false, category = "smelting" },   -- не руками
    ["hidden-thing"] = { enabled = true, hidden = true, category = "crafting" },
    ["locked"] = { enabled = false, hidden = false, category = "crafting" },
  }
  local R = require("scripts.perception.recipes")
  local d = R.ops.recipes({}, ctx)
  G.plain(d)
  G.eq(d.craftable, { ["iron-gear-wheel"] = 20, pipe = 40 })
  d = R.ops.recipes({ filter = "gear" }, ctx)
  G.eq(d.craftable, { ["iron-gear-wheel"] = 20 })
  -- filter — подстрока, не шаблон Lua
  d = R.ops.recipes({ filter = "iron-" }, ctx)
  G.eq(d.craftable, { ["iron-gear-wheel"] = 20 })
  d = R.ops.recipes({ filter = "%a" }, ctx)
  G.eq(d.craftable, {})
  G.raises("bad_args", function() R.ops.recipes({ filter = 1 }, ctx) end)
  -- пустой фильтр = без фильтра
  G.eq(R.ops.recipes({ filter = "" }, ctx).craftable, { ["iron-gear-wheel"] = 20, pipe = 40 })
  G.raises("bad_args", function() R.ops.recipes({ filter = string.rep("a", 101) }, ctx) end)
  G.raises("no_helper", function() R.ops.recipes({}, {}) end)
end
