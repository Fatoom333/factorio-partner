-- Тесты операции `resources`. Контракт: docs/STATE.md «resources».
local G = require("stubs_g")

local function ore(w, name, x, y, amount)
  return w.surface.add(G.entity { name = name, type = "resource", pos = { x = x + 0.5, y = y + 0.5 },
    force = w.neutral, amount = amount or 100 })
end

-- 1. Кластеризация 8-связностью, по имени; сортировка по расстоянию
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  -- пятно A: iron 3x2 у (10..12, 0..1)
  for x = 10, 12 do for y = 0, 1 do ore(w, "iron-ore", x, y, 1000) end end
  -- диагональный сосед — то же пятно
  ore(w, "iron-ore", 13, 2, 500)
  -- пятно B: iron отдельно (разрыв в 2 клетки)
  ore(w, "iron-ore", 20, 0, 50)
  -- пятно C: coal вплотную к A — другое имя → другое пятно
  ore(w, "coal", 9, 0, 70)
  local R = require("scripts.perception.resources")
  local d = R.ops.resources({ radius = 32 }, ctx)
  G.plain(d)
  G.eq(#d.patches, 3)
  G.eq(d.truncated, false)
  local A, B, Cc
  for _, p in ipairs(d.patches) do
    if p.name == "coal" then Cc = p elseif p.tiles == 1 then B = p else A = p end
  end
  G.eq(A.tiles, 7)
  G.eq(A.amount, 6500)
  G.eq(A.area, { left_top = { x = 10, y = 0 }, right_bottom = { x = 14, y = 3 } })
  G.eq(B.amount, 50)
  G.eq(B.center, { x = 20.5, y = 0.5 })
  G.eq(Cc.tiles, 1)
  -- ближайшие первыми
  for i = 2, #d.patches do G.ok(d.patches[i - 1].dist <= d.patches[i].dist, "sorted by dist") end
  G.eq(d.patches[1].name, "coal")
end

-- 2. Фильтр по имени, радиус, неоткрытые чанки
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  ore(w, "iron-ore", 5, 5)
  ore(w, "coal", 6, 10)
  ore(w, "stone", 40, 0)           -- чанк (1,0) не открыт
  ore(w, "copper-ore", 100, 100)   -- вне радиуса
  w.force.set_charted(1, 0, false)
  prototypes.entity["coal"] = { name = "coal", type = "resource" }
  prototypes.entity["iron-chest"] = { name = "iron-chest", type = "container" }
  local R = require("scripts.perception.resources")
  G.raises("bad_args", function() R.ops.resources({ name = "no-such-ore" }, ctx) end, "unknown name")
  G.raises("bad_args", function() R.ops.resources({ name = "iron-chest" }, ctx) end, "not a resource")
  local d = R.ops.resources({ radius = 64 }, ctx)
  local names = {}
  for _, p in ipairs(d.patches) do names[p.name] = true end
  G.eq(names, { ["iron-ore"] = true, coal = true }, "uncharted and far are skipped")
  d = R.ops.resources({ radius = 64, name = "coal" }, ctx)
  G.eq(#d.patches, 1)
  G.eq(d.patches[1].name, "coal")
  -- центр явно
  d = R.ops.resources({ center = { x = 100.5, y = 100.5 }, radius = 5 }, ctx)
  G.eq(#d.patches, 1)
  G.eq(d.patches[1].name, "copper-ore")
  G.eq(d.patches[1].dist, 0)
end

-- 3. Не больше 20 пятен, truncated
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  for i = 1, 25 do ore(w, "stone", i * 3, 0) end
  local d = require("scripts.perception.resources").ops.resources({ radius = 128 }, ctx)
  G.eq(#d.patches, 20)
  G.eq(d.truncated, true)
  G.eq(d.patches[1].center, { x = 3.5, y = 0.5 })
end

-- 4. near=player и ошибки аргументов
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  G.add_player(w, { name = "T", pos = { x = 200, y = 0 } })
  ore(w, "coal", 201, 0)
  local R = require("scripts.perception.resources")
  local d = R.ops.resources({ near = "player", radius = 10 }, ctx)
  G.eq(#d.patches, 1)
  G.raises("limit", function() R.ops.resources({ radius = 129 }, ctx) end)
  G.raises("bad_args", function() R.ops.resources({ name = 5 }, ctx) end)
  G.raises("bad_args", function() R.ops.resources({ near = "player", center = { x = 0, y = 0 } }, ctx) end)
  -- без помощника и без хозяина онлайн
  w.players[1].connected = false
  G.raises("no_player", function() R.ops.resources({}, {}) end)
end

-- 5. Кластеризация большого пятна (без глубокой рекурсии)
do
  G.reset()
  local R = require("scripts.perception.resources")
  local cells = {}
  for x = 0, 99 do for y = 0, 99 do cells[#cells + 1] = { x = x, y = y, amount = 1 } end end
  local p = R.cluster(cells)
  G.eq(#p, 1)
  G.eq(p[1].tiles, 10000)
  G.eq(p[1].center, { x = 50, y = 50 })
  -- отрицательные координаты
  p = R.cluster({ { x = -1, y = -1 }, { x = 0, y = 0 }, { x = -3, y = -1 } })
  G.eq(#p, 2)
end
