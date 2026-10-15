-- Тесты операции `access`: суша, преграды и выходы с участка.
-- Контракт: docs/STATE.md «access», PROTOCOL §6.12 (правила — из масок прототипов, без имён плиток).
local G = require("stubs_g")

local AREA = { left_top = { x = 0, y = 0 }, right_bottom = { x = 10, y = 10 } } -- клетки 0..9, рамка -8..17

local function fill(s, x0, y0, x1, y1, name)
  for x = x0, x1 do for y = y0, y1 do s.set_tile(x, y, name) end end
end

-- Вся рамка — лава, кроме участка.
local function island(s, name)
  fill(s, -8, -8, 17, 17, name or "lava")
  fill(s, 0, 0, 9, 9, "grass-1")
end

local function by_side(d)
  local out = {}
  for _, e in ipairs(d.exits) do out[e.side] = out[e.side] or e end
  return out
end

local function has(list, v)
  for _, x in ipairs(list) do if x == v then return true end end
  return false
end

local function access()
  return require("scripts.perception.access")
end

-- 1. Открытое место: четыре широких выхода, ничего не мешает
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  local d = access().ops.access({ area = AREA }, ctx)
  G.plain(d)
  G.eq(d.area, AREA)
  G.eq(d.land, 100)
  G.eq(d.liquid, 0)
  G.eq(d.liquids, {})
  G.eq(d.enclosed, false)
  G.eq(#d.exits, 4)
  local e = by_side(d)
  G.eq(e.north, { side = "north", pos = { x = 4, y = -8 }, width = 26, neck = "wide" })
  G.eq(e.south.pos, { x = 4, y = 17 })
  G.eq(e.west, { side = "west", pos = { x = -8, y = 4 }, width = 24, neck = "wide" })
  G.eq(e.east.width, 24)
  G.eq(d.best, "north", "широкие первыми, при равенстве — север")
  G.eq(d.reachable, true)
  G.eq(d.warnings, {})
  G.eq(d.surface, "nauvis")
  G.eq(d.wide_sides, nil, "служебные поля расчёта в ответ не идут")
  G.eq(d.not_charted, nil)
  local js = G.json(d)
  G.ok(js:find('"exits":[', 1, true), "exits is an array")
  -- только чтение
  G.eq(#w.force.charts, 0)
  G.eq(next(storage, "helpers"), nil, "в storage ничего не пишет")
end

-- 2. Остров: выходов нет
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  island(w.surface)
  fill(w.surface, 2, 2, 3, 3, "lava-hot") -- лужа внутри участка
  local d = access().ops.access({ area = AREA }, ctx)
  G.plain(d)
  G.eq(d.enclosed, true)
  G.eq(d.exits, {})
  G.eq(d.best, nil)
  G.eq(d.land, 96)
  G.eq(d.liquid, 4)
  G.eq(d.liquids, { ["lava-hot"] = 4 }, "плитки внутри участка, по именам из игры")
  G.eq(d.reachable, true, "помощник стоит на острове")
  G.eq(d.warnings, { "enclosed" })
end

-- 3. Перешеек: ширина 1–2 — narrow, 3–4 — medium, 5 и больше — wide
do
  local want = { [1] = "narrow", [2] = "narrow", [3] = "medium", [4] = "medium", [5] = "wide", [8] = "wide" }
  for width, neck in pairs(want) do
    local w = G.reset()
    local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
    island(w.surface)
    fill(w.surface, 1, -8, width, -1, "grass-1") -- коридор на север
    local d = access().ops.access({ area = AREA }, ctx)
    G.eq(#d.exits, 1, "width " .. width)
    G.eq(d.exits[1].side, "north")
    G.eq(d.exits[1].width, width)
    G.eq(d.exits[1].neck, neck, "width " .. width)
    G.eq(d.exits[1].pos, { x = 1 + math.floor((width - 1) / 2), y = -8 })
    G.eq(d.best, "north")
    G.eq(d.enclosed, false)
    if neck == "narrow" then G.eq(d.warnings, { "narrow_access" }) else G.eq(d.warnings, {}) end
  end
end

-- 4. Узкое место посреди широкого коридора; широкий выход важнее узкого, даже если тот длиннее по рамке
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  local s = w.surface
  island(s)
  fill(s, 0, -8, 9, -1, "grass-1")   -- на север — коридор шириной 10...
  fill(s, 0, -4, 7, -4, "lava")      -- ...с горлом в 2 клетки (x = 8..9)
  fill(s, 10, 2, 17, 7, "grass-1")   -- на восток — ровный коридор шириной 6
  local d = access().ops.access({ area = AREA }, ctx)
  local e = by_side(d)
  G.eq(e.north.width, 10)
  G.eq(e.north.neck, "narrow", "самое узкое место по дороге, а не ширина на рамке")
  G.eq(e.east.width, 6)
  G.eq(e.east.neck, "wide")
  G.eq(d.exits[1].side, "east")
  G.eq(d.best, "east")
  G.eq(d.warnings, { "narrow_access:north" })
end

-- 5. Преграды — постройки, утёсы и камни; деревья, ленты, руда и призраки — нет
do
  local function world(make)
    local w = G.reset()
    local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
    local s = w.surface
    island(s)
    fill(s, 0, -8, 9, -1, "grass-1") -- коридор на север шириной 10
    for x = 0, 9 do
      if x ~= 4 then make(w, x + 0.5, -3.5) end -- стена поперёк с проходом в одну клетку
    end
    return access().ops.access({ area = AREA }, ctx)
  end
  local d = world(function(w, x, y)
    w.surface.add(G.entity { name = "stone-wall", type = "wall", pos = { x = x, y = y }, force = w.force })
  end)
  G.eq(d.exits[1].neck, "narrow", "стена своей силы — преграда")
  G.eq(d.land, 100, "преграды на число клеток суши не влияют")
  d = world(function(w, x, y)
    w.surface.add(G.entity { name = "cliff", type = "cliff", pos = { x = x, y = y }, force = w.neutral })
  end)
  G.eq(d.exits[1].neck, "narrow", "утёс — преграда")
  d = world(function(w, x, y)
    w.surface.add(G.entity { name = "big-rock", type = "simple-entity", pos = { x = x, y = y }, force = w.neutral, rock = true })
  end)
  G.eq(d.exits[1].neck, "narrow", "камень — преграда")
  d = world(function(w, x, y)
    w.surface.add(G.entity { name = "small-worm-turret", type = "turret", pos = { x = x, y = y }, force = w.enemy })
  end)
  G.eq(d.exits[1].neck, "narrow", "чужая постройка тоже стоит на пути")
  for _, o in ipairs({
    { name = "tree-01", type = "tree" },
    { name = "transport-belt", type = "transport-belt" },
    { name = "iron-ore", type = "resource" },
    { name = "entity-ghost", type = "entity-ghost", ghost_name = "stone-wall" },
    { name = "small-biter", type = "unit" },
    { name = "character", type = "character" },
  }) do
    d = world(function(w, x, y)
      w.surface.add(G.entity { name = o.name, type = o.type, ghost_name = o.ghost_name, pos = { x = x, y = y },
        force = o.type == "tree" and w.neutral or w.force })
    end)
    G.eq(d.exits[1].neck, "wide", o.type .. " — не преграда")
  end
  -- большая постройка закрашивает всю свою площадь: 3×3 закрывает проход в 3 клетки
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  island(w.surface)
  fill(w.surface, 3, -8, 5, -1, "grass-1")
  w.surface.add(G.entity { name = "assembling-machine-1", type = "assembling-machine", pos = { x = 4.5, y = -4.5 }, force = w.force, size = 3 })
  d = access().ops.access({ area = AREA }, ctx)
  G.eq(d.enclosed, true)
  -- постройка, которая сталкивается только с плитками, тело не держит
  w = G.reset()
  _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  island(w.surface)
  fill(w.surface, 3, -8, 5, -1, "grass-1")
  local e = w.surface.add(G.entity { name = "mod-floor", type = "simple-entity-with-owner", pos = { x = 4.5, y = -4.5 }, force = w.force, size = 3 })
  e.prototype.collision_mask.colliding_with_tiles_only = true
  d = access().ops.access({ area = AREA }, ctx)
  G.eq(d.enclosed, false)
end

-- 6. Имён плиток в коде нет: планета из мода со своими масками
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  G.TILES["mod-goo"] = { layers = { mod_goo_layer = true, player = true } }
  G.TILES["mod-mist"] = { layers = { water_tile = true, item = true } } -- строить нельзя, пройти можно
  island(w.surface, "mod-goo")
  fill(w.surface, 2, -8, 8, -1, "mod-mist")
  fill(w.surface, 0, 0, 1, 1, "mod-goo")
  local d = access().ops.access({ area = AREA }, ctx)
  G.eq(d.liquids, { ["mod-goo"] = 4 })
  G.eq(d.liquid, 4)
  G.eq(d.exits[1], { side = "north", pos = { x = 5, y = -8 }, width = 7, neck = "wide" })
  -- другое тело: маска без слоя, с которым сталкивается плитка, — идёт где угодно
  ctx.entity.prototype.collision_mask = { layers = { train = true } }
  d = access().ops.access({ area = AREA }, ctx)
  G.eq(d.liquid, 0)
  G.eq(#d.exits, 4)
end

-- 7. Неоткрытое — преграда и предупреждение; участок целиком не открыт → not_charted
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  w.force.set_charted(-1, 0, false)  -- x < 0, y 0..31
  w.force.set_charted(-1, -1, false) -- x < 0, y < 0
  local d = access().ops.access({ area = AREA }, ctx)
  local e = by_side(d)
  G.eq(e.west, nil, "на неоткрытой стороне выхода нет")
  G.eq(e.north.width, 18, "x = 0..17")
  G.eq(e.north.pos, { x = 8, y = -8 })
  G.ok(has(d.warnings, "not_charted:" .. (8 * 26)), G.show(d.warnings))
  G.eq(d.land, 100)
  w.force.set_charted(0, 0, false)
  G.raises("not_charted", function() access().ops.access({ area = AREA }, ctx) end)
  -- участок открыт наполовину: суша — только открытые клетки
  w = G.reset()
  _, ctx = G.add_helper(w, "h1", { pos = { x = 35.5, y = 5.5 } })
  w.force.set_charted(0, 0, false)
  d = access().ops.access({ area = { left_top = { x = 27, y = 0 }, right_bottom = { x = 37, y = 10 } } }, ctx)
  G.eq(d.land, 50)
end

-- 8. reachable: помощник за жидкостью — false; вне рамки — поля нет; без помощника — от хозяина
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 15.5, y = 15.5 } })
  island(w.surface)
  fill(w.surface, 14, 14, 17, 17, "grass-1") -- отдельный клочок суши в углу рамки
  local d = access().ops.access({ area = AREA }, ctx)
  G.eq(d.reachable, false)
  G.eq(d.enclosed, true, "выход чужого клочка суши выходом участка не считается")
  e.position = { x = 40.5, y = 5.5 }
  d = access().ops.access({ area = AREA }, ctx)
  G.eq(d.reachable, nil, "помощник вне рамки: ответ даёт walk/approach")
  -- тело вплотную к постройке (клетка закрашена ею): смотрим соседние клетки
  w = G.reset()
  e, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  w.surface.add(G.entity { name = "iron-chest", type = "container", pos = { x = 5.5, y = 5.5 }, force = w.force })
  G.eq(access().ops.access({ area = AREA }, ctx).reachable, true)
  -- без помощника: поверхность и точка — хозяина
  w = G.reset()
  G.add_player(w, { name = "T", pos = { x = 3.5, y = 3.5 } })
  d = access().ops.access({ area = AREA }, {})
  G.eq(d.reachable, true)
  G.eq(d.land, 100)
  w.players[1].connected = false
  G.raises("no_player", function() access().ops.access({ area = AREA }, {}) end)
end

-- 9. Аргументы: center/near + radius, границы
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 10.4, y = -3.7 } })
  local A = access()
  local d = A.ops.access({}, ctx)
  G.eq(d.area, { left_top = { x = 10 - 32, y = -4 - 32 }, right_bottom = { x = 10 + 32, y = -4 + 32 } }, "радиус по умолчанию 32")
  G.eq(d.land, 64 * 64)
  d = A.ops.access({ center = { x = 100.5, y = 100.5 }, radius = 4 }, ctx)
  G.eq(d.area, { left_top = { x = 96, y = 96 }, right_bottom = { x = 104, y = 104 } })
  G.eq(d.reachable, nil)
  G.add_player(w, { name = "T", pos = { x = 200.2, y = 0.9 } })
  d = A.ops.access({ near = "player", radius = 2 }, ctx)
  G.eq(d.area, { left_top = { x = 198, y = -2 }, right_bottom = { x = 202, y = 2 } })
  -- дробная область округляется наружу до клеток
  d = A.ops.access({ area = { left_top = { x = 0.5, y = 0.5 }, right_bottom = { x = 2.5, y = 2.5 } } }, ctx)
  G.eq(d.area, { left_top = { x = 0, y = 0 }, right_bottom = { x = 3, y = 3 } })
  G.eq(d.land, 9)
  G.raises("limit", function() A.ops.access({ radius = 65 }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ radius = 0 }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ radius = 2.5 }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ area = AREA, radius = 5 }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ area = AREA, center = { x = 0, y = 0 } }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ area = AREA, near = "player" }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ center = { x = 0, y = 0 }, near = "player" }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ area = { left_top = { x = 0, y = 0 } } }, ctx) end)
  G.raises("bad_args", function() A.ops.access({ zoom = 1 }, ctx) end)
  G.raises("limit", function()
    A.ops.access({ area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 129, y = 5 } } }, ctx)
  end)
  -- 128×128 — предел: считается за один вызов
  d = A.ops.access({ area = { left_top = { x = -64, y = -64 }, right_bottom = { x = 64, y = 64 } } }, ctx)
  G.eq(d.land, 128 * 128)
  G.eq(#d.exits, 4)
  d = A.ops.access({ radius = 64 }, ctx)
  G.eq(d.land, 128 * 128)
end

-- 10. Не больше 8 выходов; в liquids — самые частые плитки
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 5.5, y = 5.5 } })
  local A = access()
  local s = w.surface
  -- рамка: каждая третья клетка северной и южной стороны — лава (много коротких выходов)
  for x = -8, 17 do
    if x % 3 == 0 then s.set_tile(x, -8, "lava"); s.set_tile(x, 17, "lava") end
  end
  local d = A.ops.access({ area = AREA }, ctx)
  G.eq(#d.exits, A.MAX_EXITS)
  G.eq(d.exits[1].neck, "wide", "восток и запад — целые стороны")
  for i = 2, #d.exits do
    local a, b = d.exits[i - 1], d.exits[i]
    local rank = { wide = 3, medium = 2, narrow = 1 }
    G.ok(rank[a.neck] > rank[b.neck] or (a.neck == b.neck and a.width >= b.width), "широкие первыми")
  end
  for i = 1, 15 do
    G.TILES["pool-" .. i] = { layers = { player = true } }
    for k = 1, i do s.set_tile(k % 10, i % 10, "pool-" .. i) end
  end
  d = A.ops.access({ area = AREA }, ctx)
  local n = 0
  for _ in pairs(d.liquids) do n = n + 1 end
  G.ok(n <= A.MAX_LIQUIDS, "liquids capped: " .. n)
end

-- 11. Заливка и усадка маски (внутренние функции)
do
  G.reset()
  local I = access()._internal
  -- сетка 5×3, средняя строка — стена с дырой в столбце 3
  local W, H = 5, 3
  local mask = {}
  for i = 1, W * H do mask[i] = true end
  for x = 0, 4 do if x ~= 2 then mask[1 * W + x + 1] = false end end
  local r = I.flood(mask, W, H, { 1 })
  G.eq(r[2 * W + 5], true, "через дыру заливка проходит")
  mask[1 * W + 3] = false
  r = I.flood(mask, W, H, { 1 })
  G.eq(r[2 * W + 1], nil, "стена без дыры — не проходит (по диагонали не ходим)")
  G.eq(r[5], true)
  -- заливка не перескакивает с правого края строки на левый край следующей
  mask = { true, true, false, false, false, false, true, true, true }
  r = I.flood(mask, 3, 3, { 1 })
  G.eq(r[2], true)
  G.eq(r[7], nil)
  -- усадка: за краем сетки — «проходимо», внутри дырка съедает соседей
  local full = {}
  for i = 1, 25 do full[i] = true end
  local e = I.erode(full, 5, 5)
  for i = 1, 25 do G.eq(e[i], true, "без преград усадка ничего не съедает") end
  full[13] = false -- центр
  e = I.erode(full, 5, 5)
  G.eq(e[1], true)
  G.eq(e[7], nil, "сосед преграды по диагонали")
  G.eq(e[12], nil)
  G.eq(e[13], nil)
  G.eq(e[5], true)
end
