-- Тесты операции `stock` (поток G). Контракт: docs/STATE.md «stock».
local G = require("stubs_g")

local function chest(w, x, y, items, o)
  o = o or {}
  return w.surface.add(G.entity { name = o.name or "steel-chest", type = o.type or "container",
    pos = { x = x, y = y }, force = o.force or w.force, size = 1, inventory = G.inventory(items) })
end

-- 1. Содержимое, total, сортировка, только normal, свои сундуки
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local c1 = chest(w, 10.5, 4.5, { ["iron-plate"] = 800 })
  local c2 = chest(w, 3.5, 0.5, { ["iron-plate"] = 10, coal = 5 }, { name = "passive-provider-chest", type = "logistic-container" })
  local rare = G.inventory({ { name = "iron-gear-wheel", count = 9, quality = "rare" } })
  w.surface.add(G.entity { name = "iron-chest", type = "container", pos = { x = 6.5, y = 0.5 }, force = w.force, inventory = rare })
  chest(w, 1.5, 1.5, { coal = 99 }, { force = w.enemy })                 -- чужой
  chest(w, 2.5, 2.5, {})                                                   -- пустой
  w.surface.add(G.entity { name = "stone-furnace", type = "furnace", pos = { x = 4, y = 4 }, force = w.force,
    inventory = G.inventory({ coal = 5 }) })                               -- машина
  local S = require("scripts.perception.stock")
  local d = S.ops.stock({}, ctx)
  G.plain(d)
  G.eq(#d.containers, 2)
  G.eq(d.containers[1].unit, c2.unit_number)
  G.eq(d.containers[1].name, "passive-provider-chest")
  G.eq(d.containers[1].dist, 3.5)
  G.eq(d.containers[2].items, { ["iron-plate"] = 800 })
  G.eq(d.containers[2].pos, { x = 10.5, y = 4.5 })
  G.eq(d.total, { ["iron-plate"] = 810, coal = 5 })
  G.eq(d.hidden, 0)
  G.eq(d.truncated, false)
end

-- 2. Невидимые чанки → hidden; фильтр items; limit; radius
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  chest(w, 1.5, 1.5, { coal = 1, stone = 2 })
  chest(w, 2.5, 1.5, { coal = 3 })
  chest(w, 3.5, 1.5, { stone = 4 })
  chest(w, 40.5, 1.5, { coal = 100 })        -- чанк (1,0) не виден
  chest(w, 100.5, 1.5, { coal = 100 })       -- вне радиуса 64
  w.force.set_visible(1, 0, false)
  local S = require("scripts.perception.stock")
  local d = S.ops.stock({ items = { "coal" } }, ctx)
  G.eq(d.hidden, 1)
  G.eq(#d.containers, 2)
  G.eq(d.total, { coal = 4 })
  G.eq(d.containers[1].items, { coal = 1 }, "filtered items only")
  d = S.ops.stock({ limit = 1 }, ctx)
  G.eq(#d.containers, 1)
  G.eq(d.truncated, true)
  G.eq(d.total, { coal = 4, stone = 6 }, "total counts all, not only limit")
  d = S.ops.stock({ radius = 128 }, ctx)
  G.eq(d.total.coal, 104)
  -- items как {name=count}
  d = S.ops.stock({ items = { stone = 1 } }, ctx)
  G.eq(d.total, { stone = 6 })
end

-- 3. Центр у хозяина и ошибки
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  G.add_player(w, { name = "T", pos = { x = 300, y = 0 } })
  chest(w, 301.5, 0.5, { coal = 7 })
  local S = require("scripts.perception.stock")
  local d = S.ops.stock({ near = "player", radius = 5 }, ctx)
  G.eq(d.total, { coal = 7 })
  G.raises("limit", function() S.ops.stock({ radius = 500 }, ctx) end)
  G.raises("limit", function() S.ops.stock({ limit = 1000 }, ctx) end)
  G.raises("bad_args", function() S.ops.stock({ limit = 0 }, ctx) end)
  G.raises("bad_args", function() S.ops.stock({ items = "coal" }, ctx) end)
  G.raises("bad_args", function() S.ops.stock({ center = { x = 1 } }, ctx) end)
end
