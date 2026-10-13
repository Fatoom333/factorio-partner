-- Тесты операции `map` (поток G). Контракт: docs/STATE.md «map».
local G = require("stubs_g")

local function cell(d, x, y)
  local r = y - d.bbox.y0 + 1
  local c = x - d.bbox.x0 + 1
  return d.rows[r]:sub(c, c)
end

-- 1. Слои, легенда, bbox, список сущностей
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 10.4, y = 10.6 } })
  local s, f = w.surface, w.force
  s.set_tile(5, 5, "water")
  s.set_tile(6, 5, "lava")
  -- руды: calcite → c, coal → o (c занята), copper-ore → p
  s.add(G.entity { name = "calcite", type = "resource", pos = { x = 3.5, y = 3.5 }, force = w.neutral, amount = 100 })
  s.add(G.entity { name = "coal", type = "resource", pos = { x = 4.5, y = 3.5 }, force = w.neutral, amount = 100 })
  s.add(G.entity { name = "copper-ore", type = "resource", pos = { x = 5.5, y = 3.5 }, force = w.neutral, amount = 100 })
  -- бур 3x3 поверх руды
  s.add(G.entity { name = "electric-mining-drill", type = "mining-drill", pos = { x = 15.5, y = 10.5 }, force = f, size = 3, direction = 4 })
  s.add(G.entity { name = "transport-belt", type = "transport-belt", pos = { x = 17.5, y = 10.5 }, force = f })
  s.add(G.entity { name = "small-electric-pole", type = "electric-pole", pos = { x = 17.5, y = 12.5 }, force = f })
  s.add(G.entity { name = "lab", type = "lab", pos = { x = 12.5, y = 14.5 }, force = f, size = 3 })
  s.add(G.entity { name = "entity-ghost", type = "entity-ghost", ghost_name = "stone-furnace", pos = { x = 8, y = 14 }, force = f, size = 2 })
  s.add(G.entity { name = "cliff", type = "cliff", pos = { x = 2.5, y = 15.5 }, force = w.neutral })
  s.add(G.entity { name = "big-rock", type = "simple-entity", pos = { x = 3.5, y = 15.5 }, force = w.neutral, rock = true })
  s.add(G.entity { name = "tree-01", type = "tree", pos = { x = 4.5, y = 15.5 }, force = w.neutral })
  s.add(G.entity { name = "small-biter", type = "unit", pos = { x = 16.5, y = 16.5 }, force = w.enemy })
  -- чужая постройка (другая сила) не рисуется
  local other = G.force("other")
  s.add(G.entity { name = "wooden-chest", type = "container", pos = { x = 1.5, y = 1.5 }, force = other })
  G.add_player(w, { name = "T", pos = { x = 12.2, y = 8.9 } })

  local M = require("scripts.perception.map")
  local d = M.ops.map({ radius = 8 }, ctx)
  G.plain(d)
  G.eq(d.bbox, { x0 = 2, y0 = 2, x1 = 18, y1 = 18 })
  G.eq(#d.rows, 17)
  for _, r in ipairs(d.rows) do G.eq(#r, 17, "row width") end
  G.eq(cell(d, 10, 10), "@")
  G.eq(cell(d, 12, 8), "P")
  G.eq(cell(d, 5, 5), "~")
  G.eq(cell(d, 6, 5), "~")
  G.eq(cell(d, 3, 3), "c")
  G.eq(cell(d, 4, 3), "o")
  G.eq(cell(d, 5, 3), "p")
  for x = 14, 16 do for y = 9, 11 do G.eq(cell(d, x, y), "D", "drill box " .. x .. "," .. y) end end
  G.eq(cell(d, 17, 10), "B")
  G.eq(cell(d, 17, 12), "E")
  G.eq(cell(d, 12, 14), "O", "other building")
  G.eq(cell(d, 7, 13), "g")
  G.eq(cell(d, 8, 14), "g")
  G.eq(cell(d, 2, 15), "#")
  G.eq(cell(d, 3, 15), "#")
  G.eq(cell(d, 4, 15), "T")
  G.eq(cell(d, 16, 16), "X")
  G.eq(cell(d, 2, 2), ".")
  G.eq(d.legend["c"], "руда: calcite")
  G.eq(d.legend["o"], "руда: coal")
  G.eq(d.legend["p"], "руда: copper-ore")
  G.eq(d.legend["D"], "бур")
  G.eq(d.legend["?"], nil, "nothing uncharted")
  -- каждый нарисованный символ есть в легенде
  for _, r in ipairs(d.rows) do
    for i = 1, #r do G.ok(d.legend[r:sub(i, i)], "legend for " .. r:sub(i, i)) end
  end
  -- список: без лент и столбов по умолчанию, призрак с ghost=true
  local names = {}
  for _, it in ipairs(d.entities) do names[it.name] = it end
  G.ok(names["electric-mining-drill"], "drill listed")
  G.eq(names["electric-mining-drill"].dir, 4)
  G.eq(names["electric-mining-drill"].c, "D")
  G.eq(names["electric-mining-drill"].pos, { x = 15.5, y = 10.5 })
  G.ok(names["electric-mining-drill"].unit, "unit_number given")
  G.eq(names["transport-belt"], nil, "belts hidden by default")
  G.eq(names["small-electric-pole"], nil, "poles hidden by default")
  G.eq(names["stone-furnace"].ghost, true)
  G.ok(names["small-biter"], "visible enemy listed")
  G.eq(names["tree-01"], nil, "neutral not listed by default")
  G.eq(d.truncated, false)
  G.ok(d.axis:sub(1, 3) == "x: ", "axis prefix")
  G.eq(#d.axis, 3 + 17)
end

-- 2. Неоткрытое → `?`, невидимые враги скрыты, map не открывает чанки
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 30, y = 10 } })
  local s, f = w.surface, w.force
  f.set_charted(1, 0, false)                    -- x 32..63 не открыт
  f.set_visible(0, 0, false)                    -- x 0..31 открыт, но не виден
  s.add(G.entity { name = "small-biter", type = "unit", pos = { x = 25.5, y = 10.5 }, force = w.enemy })
  s.add(G.entity { name = "iron-chest", type = "container", pos = { x = 35.5, y = 10.5 }, force = f })
  -- «глаза» помощника (PROTOCOL §6.7): враг ≤ 32 клеток от тела виден и в невидимом чанке
  local seen = require("scripts.perception.map").ops.map({ radius = 5 }, ctx)
  G.eq(cell(seen, 25, 10), "X", "enemy near the helper body is visible")
  -- без помощника в ctx (helper_id=nil) работает только is_chunk_visible
  local d = require("scripts.perception.map").ops.map({ radius = 5 }, { entity = e })
  G.plain(d)
  G.eq(cell(d, 25, 10), ".", "enemy in not-visible chunk not drawn")
  G.eq(cell(d, 31, 10), ".")
  G.eq(cell(d, 32, 10), "?")
  G.eq(cell(d, 35, 10), "?", "building in uncharted chunk hidden")
  G.eq(d.legend["?"], "не открыто")
  G.eq(#d.entities, 0, "chest uncharted, biter not visible")
  G.eq(#f.charts, 0, "map never charts")
end

-- 2b. Если и помощник, и враг в невидимом — `@` всё равно рисуется (своё тело)
-- (entities: в п.2 единственная запись — ни сундук, ни враг; проверим, что это не они)
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 30, y = 10 } })
  w.force.set_charted(1, 0, false)
  w.force.set_visible(0, 0, false)
  w.surface.add(G.entity { name = "small-biter", type = "unit", pos = { x = 25.5, y = 10.5 }, force = w.enemy })
  local d = require("scripts.perception.map").ops.map({ radius = 5 }, { entity = e })
  for _, it in ipairs(d.entities) do G.ok(it.name ~= "small-biter", "biter must not be listed") end
  G.eq(cell(d, 30, 10), "@")
end

-- 2c. Другие помощники — `H`, текущий — `@`; мёртвые/удалённые не рисуются; JSON через мост A
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0.5, y = 0.5 } })
  G.add_helper(w, "h2", { pos = { x = 3.5, y = 0.5 } })
  G.add_helper(w, "h3", { pos = { x = -3.5, y = 0.5 }, state = "dead" })
  local far = G.surface("vulcanus")
  local e4 = G.character { pos = { x = 2.5, y = 2.5 }, force = w.force }
  far.add(e4)
  storage.helpers.h4 = { entity = e4, unit_number = e4.unit_number, state = "alive" }
  w.surface.add(G.entity { name = "iron-ore", type = "resource", pos = { x = 1.5, y = 1.5 }, force = w.neutral, amount = 5 })
  local d = require("scripts.perception.map").ops.map({ radius = 4 }, ctx)
  G.eq(cell(d, 0, 0), "@")
  G.eq(cell(d, 3, 0), "H")
  G.eq(cell(d, -4, 0), ".", "dead helper not drawn")
  G.eq(cell(d, 2, 2), ".", "helper on other surface not drawn")
  G.eq(d.legend["H"], "другой помощник")
  -- настоящий helpers.table_to_json: ключи легенды `.`, `~`, буквы руд, пустые списки
  local js = G.json(d)
  G.ok(js:find('"legend":{', 1, true), "legend is an object")
  G.ok(js:find('"@":"', 1, true) and js:find('".":"', 1, true), "legend keys")
  G.ok(js:find('"rows":["', 1, true), "rows is an array")
  -- карта с цифрой-буквой руды тоже сериализуется (ключ легенды — строка "0")
  G.eq(type(G.json({ legend = { ["0"] = "руда: x", ["~"] = "вода/лава" } })), "string")
end

-- 3. Фильтры types/names, лимит 100 и truncated
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  for i = 1, 120 do
    w.surface.add(G.entity { name = "transport-belt", type = "transport-belt", pos = { x = (i % 30) - 15 + 0.5, y = math.floor(i / 30) - 2 + 0.5 }, force = w.force })
  end
  w.surface.add(G.entity { name = "iron-chest", type = "container", pos = { x = 5.5, y = 5.5 }, force = w.force })
  w.surface.add(G.entity { name = "tree-01", type = "tree", pos = { x = -5.5, y = 5.5 }, force = w.neutral })
  local M = require("scripts.perception.map")
  local d = M.ops.map({ radius = 16, types = { "transport-belt" } }, ctx)
  G.eq(#d.entities, 100)
  G.eq(d.truncated, true)
  for _, it in ipairs(d.entities) do G.eq(it.name, "transport-belt") end
  d = M.ops.map({ radius = 16, names = { "tree-01", "iron-chest" } }, ctx)
  G.eq(#d.entities, 2)
  G.eq(d.truncated, false)
  d = M.ops.map({ radius = 16 }, ctx)
  G.eq(#d.entities, 1, "default list without belts and neutral")
  G.eq(d.entities[1].name, "iron-chest")
end

-- 4. Аргументы
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local M = require("scripts.perception.map")
  G.raises("limit", function() M.ops.map({ radius = 33 }, ctx) end)
  G.raises("bad_args", function() M.ops.map({ radius = 0 }, ctx) end)
  G.raises("bad_args", function() M.ops.map({ radius = 2.5 }, ctx) end)
  G.raises("bad_args", function() M.ops.map({ center = { x = "a", y = 1 } }, ctx) end)
  G.raises("bad_args", function() M.ops.map({ zoom = 1 }, ctx) end)
  local d = M.ops.map({}, ctx)
  G.eq(#d.rows, 2 * M.DEFAULT_RADIUS + 1, "default radius")
  -- center без помощника: поверхность хозяина
  G.add_player(w, { name = "T", pos = { x = 100, y = 100 } })
  d = M.ops.map({ center = { x = 50.7, y = -3.2 }, radius = 2 }, {})
  G.eq(d.bbox, { x0 = 48, y0 = -6, x1 = 52, y1 = -2 })
  G.raises("no_helper", function()
    w.players[1].connected = false
    M.ops.map({ center = { x = 0, y = 0 } }, {})
  end)
end

-- 5. Подпись столбцов и буквы руд
do
  G.reset()
  local M = require("scripts.perception.map")
  local a = M.axis(41, 60)
  G.eq(#a, 3 + 20)
  G.eq(a:sub(4, 5), "41", "first column labelled when it fits")
  G.eq(a:sub(4 + 4, 4 + 5), "45")
  G.eq(a:sub(4 + 9, 4 + 10), "50")
  G.eq(a:sub(4 + 19, 4 + 19), "|", "label that does not fit becomes |")
  G.eq(a:sub(6, 7), "..")
  local b = M.axis(-12, 2)
  G.eq(#b, 3 + 15)
  G.eq(b:sub(4 + 2, 4 + 4), "-10")
  G.eq(b:sub(4 + 12, 4 + 12), "0")
  local c = M.axis(44, 46)
  G.eq(c, "x: .45", "44 does not fit before 45, 45 fits")
  local used = {}
  for ch in pairs(M.FIXED) do used[ch] = true end
  G.eq(M.ore_char("calcite", used), "c")
  used.c = true
  G.eq(M.ore_char("coal", used), "o")
  used.o = true; used.a = true; used.l = true
  G.eq(M.ore_char("coal", used), "b", "fallback to first free letter")
end