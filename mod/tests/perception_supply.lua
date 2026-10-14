-- Тесты операции `supply` (поток U, ревизия 3.7). Контракт: docs/STATE.md «supply»,
-- PROTOCOL §6.7 (содержимое — только видимое), §6.11 (качество normal), §6.12 (имён в коде нет).
local U = require("stubs_u")
local G = U.G

-- 1. Цепочка в три уровня с нехваткой: need/have/short, crafts, yield, карманы делятся по дереву
do
  local w = U.world()
  local _, ctx = U.helper(w, { gear = 4, plate = 3 })
  local d = U.supply({ item = "widget", count = 2 }, ctx)
  G.eq(d.item, "widget")
  G.eq(d.count, 2)
  G.eq(d.surface, "nauvis")
  local t = d.tree
  G.eq({ t.name, t.kind, t.need, t.have, t.short }, { "widget", "item", 2, 0, 2 })
  G.eq({ t.recipe.name, t.recipe.hand, t.recipe.category, t.recipe.yield, t.recipe.crafts, t.recipe.time },
       { "widget", true, "crafting", 1, 2, 4 })
  local board, gear = t.recipe.ingredients[1], t.recipe.ingredients[2]
  G.eq({ gear.name, gear.need, gear.have, gear.short }, { "gear", 10, 4, 6 }, "5 × 2 крафта, 4 в карманах")
  G.eq({ board.name, board.need, board.have, board.short }, { "board", 6, 0, 6 })
  G.eq(gear.recipe.crafts, 6)
  -- board раскрыт раньше gear (порядок ингредиентов рецепта): его plate берёт карманы первым
  local bplate, wire = board.recipe.ingredients[1], board.recipe.ingredients[2]
  G.eq({ bplate.name, bplate.need, bplate.have, bplate.short }, { "plate", 6, 3, 3 })
  local gplate = gear.recipe.ingredients[1]
  G.eq({ gplate.need, gplate.have, gplate.short }, { 12, 0, 12 }, "карманы уже заняты первым узлом plate")
  G.eq({ wire.need, wire.short, wire.recipe.yield, wire.recipe.crafts }, { 18, 18, 2, 9 }, "crafts = ceil(short / yield)")
  local bar = wire.recipe.ingredients[1]
  G.eq({ bar.name, bar.need, bar.note }, { "bar", 9, "depth" }, "глубина 3 исчерпана")
  G.eq(bar.recipe, nil)
  G.eq(bplate.recipe.hand, false, "переплавка — не руками")
  local ore = bplate.recipe.ingredients[1]
  G.eq({ ore.name, ore.need, ore.note }, { "ore", 3, "no_recipe" })
  G.eq(d.nodes, 9)
  G.eq(#U.nodes(d), d.nodes)
  G.eq(d.truncated, nil)
  G.eq(d.hidden, nil)
  G.eq(U.flat(d.summary.short), { widget = 2, gear = 6, board = 6, plate = 15, wire = 18, bar = 9, ore = 15 })
  G.eq(U.flat(d.summary.raw), { ore = 15 }, "сырьё — то, что копают или что без рецепта")
  G.eq(d.summary.short[1].name, "widget", "порядок — как в дереве")
  G.ok(U.has(d.warnings, "no_source:ore"), "ни запаса, ни машины, ни рецепта, ни пятна")
  G.ok(U.has(d.warnings, "other_surface"), "на поверхности нет ничего нужного")
  for _, n in ipairs(U.nodes(d)) do
    G.eq(n.short, math.max(0, n.need - n.have), n.name .. ": short = max(0, need − have)")
    if n.recipe then
      G.eq(n.recipe.crafts, math.ceil(n.short / n.recipe.yield), n.name .. ": crafts")
    end
  end
end

-- 2. have покрывает need: note enough, узел не раскрыт
do
  local w = U.world()
  local _, ctx = U.helper(w, { { name = "widget", count = 5 }, { name = "gear", count = 99, quality = "rare" } })
  local d = U.supply({ item = "widget", count = 3 }, ctx)
  G.eq({ d.tree.need, d.tree.have, d.tree.short, d.tree.note }, { 3, 5, 0, "enough" })
  G.eq(d.tree.recipe, nil)
  G.eq(d.nodes, 1)
  G.eq(#d.summary.short, 0)
  G.eq(#d.warnings, 0)
  -- часть есть: раскрыт только недостающий ингредиент; не-normal в карманах не считается
  w = U.world()
  _, ctx = U.helper(w, { { name = "board", count = 3 }, { name = "gear", count = 99, quality = "rare" } })
  d = U.supply({ item = "widget" }, ctx)
  local board, gear = d.tree.recipe.ingredients[1], d.tree.recipe.ingredients[2]
  G.eq({ board.have, board.short, board.note }, { 3, 0, "enough" })
  G.eq(board.recipe, nil)
  G.eq({ gear.have, gear.short }, { 0, 5 }, "качество не normal — не в счёт (§6.11)")
  G.ok(gear.recipe ~= nil)
end

-- 3. Рецепт только в машине, машина на базе есть: producers с out, makers; чужая сила не видна
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  local smelt = { smelting = true }
  local a = U.machine(w, "smelter", "furnace", 10, 0, { recipe = "plate", cats = smelt, out = { plate = 7, ore = 99 } })
  U.machine(w, "smelter", "furnace", 14, 0, { recipe = "plate", cats = smelt, out = { plate = 5 } })
  U.machine(w, "big-smelter", "furnace", 300, 0, { recipe = "plate", cats = smelt, out = { plate = 1000 } })
  U.machine(w, "smelter", "furnace", 18, 0, { recipe = "bar", cats = smelt })            -- другой рецепт
  U.machine(w, "smelter", "furnace", 16, 0, { previous = "plate", cats = smelt })        -- печь: последний рецепт
  U.machine(w, "smelter", "furnace", 12, 0, { recipe = "plate", cats = smelt, quality = "rare" }) -- не normal
  U.machine(w, "smelter", "furnace", 6, 0, { recipe = "plate", cats = smelt, out = { plate = 500 }, force = w.enemy })
  U.machine(w, "bench", "assembling-machine", 20, 0, { recipe = "gear", out = { gear = 2 } })
  local d = U.supply({ item = "gear", count = 10 }, ctx)
  local gear = d.tree
  G.eq(gear.recipe.hand, true)
  G.eq(gear.producers, { count = 1, pos = { x = 20, y = 0 }, dist = 20, names = { bench = 1 }, recipe = "gear", out = 2 })
  G.eq(gear.recipe.makers.names, { bench = 1 })
  local plate = gear.recipe.ingredients[1]
  G.eq({ plate.need, plate.short }, { 20, 20 })
  G.eq(plate.recipe.hand, false, "категория машины — руками нельзя")
  G.eq(plate.recipe.category, "smelting")
  local p = plate.producers
  G.eq(p.count, 3, "ближайшая группа: две печи с рецептом и печь с последним рецептом; чужая и rare — нет")
  G.eq(p.names, { smelter = 3 })
  G.eq(p.recipe, "plate")
  G.eq(p.out, 12, "готовое в выходах машин группы; чужой предмет в выходе не считается")
  G.eq(p.dist, 13.3)
  local m = plate.recipe.makers
  G.eq(m.count, 5, "все печи рядом могут делать рецепт по категории, даже с другим рецептом")
  G.eq(m.names, { smelter = 5 })
  G.eq(m.recipe, nil)
  G.eq(gear.recipe.makers.count, 1)
  G.eq(d.hidden, nil, "дальняя печь рядом не видна? — в заглушке все чанки видимы")
  G.ok(not U.has(d.warnings, "other_surface"))
  G.ok(not U.has(d.warnings, "no_source:plate"))
  G.ok(a.out_reads >= 1)

  -- руками нельзя из-за жидкости, хотя категория ручная; у жидкости — цистерна и скважина
  U.tank(w, 30.5, 30.5, { goo = 2500.4 })
  U.ore(w, "goo-well", 60, 0, 1, 1, 100000)
  d = U.supply({ item = "resin", count = 2 }, ctx)
  G.eq(d.tree.recipe.hand, false, "жидкость в ингредиентах")
  local goo = U.node(d, "goo")
  G.eq({ goo.kind, goo.need, goo.have, goo.short }, { "fluid", 40, 0, 40 })
  G.eq(goo.stored.total, 2500)
  G.eq(goo.stored.n, 2500)
  G.eq(goo.resource.name, "goo-well")
  G.eq(goo.note, "no_recipe")
  G.eq(U.flat(d.summary.raw), { goo = 40, rock = 2 })
  -- сам запрос жидкости
  d = U.supply({ item = "goo", count = 100 }, ctx)
  G.eq({ d.tree.kind, d.tree.short }, { "fluid", 100 })
end

-- 4. Запас в сундуке: total по всем видимым, pos/dist/n — ближайшая группа
do
  local w = U.world()
  local _, ctx = U.helper(w, { plate = 1 })
  U.chest(w, 5.5, 0.5, { plate = 100, ore = 7 })
  U.chest(w, 6.5, 0.5, { plate = 50 }, { name = "smart-box", type = "logistic-container" })
  U.chest(w, 200.5, 0.5, { plate = 1000 })
  U.chest(w, 3.5, 0.5, { plate = 9999 }, { force = w.enemy })                     -- чужой
  U.chest(w, 4.5, 0.5, { { name = "plate", count = 77, quality = "rare" } })     -- не normal
  local d = U.supply({ item = "gear", count = 3 }, ctx)
  local plate = d.tree.recipe.ingredients[1]
  G.eq({ plate.need, plate.have, plate.short }, { 6, 1, 5 })
  G.eq(plate.stored, { total = 1150, pos = { x = 6, y = 0.5 }, dist = 6, n = 150 })
  G.eq(d.tree.stored, nil, "шестерён на базе нет")
  local ore = plate.recipe.ingredients[1]
  G.eq(ore.stored.total, 7, "источники указаны и у нераскрытого узла")
  G.eq(ore.note, "no_recipe")
  G.ok(not U.has(d.warnings, "no_source:ore"))
end

-- 5. Сырьё с пятном: resource, drills; ближайшее пятно; неоткрытый чанк не считается
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  U.ore(w, "ore", 40, 0, 4, 3, 500)          -- ближнее: 12 клеток × 500
  U.ore(w, "ore", 100, 0, 2, 2, 9000)        -- дальнее
  U.ore(w, "ore", -20, 0, 2, 2, 7000)        -- ближе всех, но чанк не открыт
  w.force.set_charted(-1, 0, false)
  U.ore(w, "rock-field", 10, 10, 2, 2, 50)
  U.drill(w, 41.5, 1.5, "ore")
  U.drill(w, 44.5, 1.5, "ore")
  U.drill(w, 101.5, 1.5, "ore")              -- на другом пятне
  U.drill(w, 41.5, 4.5, "rock-field")        -- рядом, но копает другое
  U.drill(w, 42.5, 1.5, "ore", { force = w.enemy })
  local d = U.supply({ item = "plate", count = 8 }, ctx)
  local ore = d.tree.recipe.ingredients[1]
  G.eq(ore.resource, { name = "ore", pos = { x = 42, y = 1.5 }, dist = 42, amount = 6000, drills = 2 })
  G.eq(ore.note, "no_recipe")
  G.eq(U.flat(d.summary.raw), { ore = 8 })
  G.ok(not U.has(d.warnings, "no_source:ore"))
  G.ok(not U.has(d.warnings, "other_surface"))
  G.eq(d.tree.resource, nil, "plate из земли не добывается")
  -- запрос ресурсов один, по именам, вокруг помощника
  local n = 0
  for _, c in ipairs(w.surface.calls) do
    if c[1] == "find_entities_filtered" and c[2].name ~= nil and c[2].position ~= nil then
      n = n + 1
      G.eq(c[2].name, { "ore" })
    end
  end
  G.eq(n, 2, "счёт и сам поиск — по одному разу")
end

-- 6. Неоткрытый рецепт: note not_researched и предупреждение
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  local d = U.supply({ item = "secret" }, ctx)
  G.eq(d.tree.note, "not_researched")
  G.eq(d.tree.recipe, nil)
  G.eq(d.nodes, 1)
  G.ok(U.has(d.warnings, "not_researched:secret"))
  G.ok(not U.has(d.warnings, "no_source:secret"), "no_source — только без рецепта; здесь он есть")
  G.eq(U.flat(d.summary.raw), {}, "рецепт есть — это не сырьё")
  -- скрытый рецепт не выбирается вовсе
  U.recipe(w, "dust", { rock = 1 }, { hidden = true })
  d = U.supply({ item = "dust" }, ctx)
  G.eq(d.tree.note, "no_recipe")
end

-- 7. Цикл рецептов не зацикливает
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  local d = U.supply({ item = "loop-a", depth = 5 }, ctx)
  local b = d.tree.recipe.ingredients[1]
  local a2 = b.recipe.ingredients[1]
  G.eq({ b.name, a2.name, a2.note }, { "loop-b", "loop-a", "cycle" })
  G.eq(a2.recipe, nil)
  G.eq(d.nodes, 3)
end

-- 8. Обрезка по глубине и по числу узлов
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  local S = require("scripts.perception.supply")
  G.eq({ S.MAX_NODES, S.MAX_DEPTH, S.DEFAULT_DEPTH, S.MAX_COUNT }, { 60, 5, 3, 10000 })
  local d = U.supply({ item = "widget", depth = 1 }, ctx)
  G.eq(d.nodes, 3)
  for _, c in ipairs(d.tree.recipe.ingredients) do
    G.eq(c.note, "depth")
    G.eq(c.recipe, nil)
  end
  G.eq(d.truncated, nil, "глубина — не обрезка")
  d = U.supply({ item = "widget", depth = 5 }, ctx)
  G.eq(d.nodes, 10, "до сырья: widget, board, gear, plate×2, wire, ore×2, bar, rock")
  G.eq(U.node(d, "rock").note, "no_recipe")

  S.MAX_NODES = 4
  d = U.supply({ item = "widget", depth = 5 }, ctx)
  G.eq(d.truncated, true)
  G.ok(d.nodes <= 4)
  G.eq(#U.nodes(d), d.nodes)
  local board, gear = d.tree.recipe.ingredients[1], d.tree.recipe.ingredients[2]
  G.eq(board.recipe, nil, "два ингредиента не влезли")
  G.eq(board.note, "depth", "note — закрытый список контракта; обрезку показывает truncated")
  G.ok(gear.recipe ~= nil, "один — влез")
  G.eq(U.flat(d.summary.short).plate, 10)
  S.MAX_NODES = 60
end

-- 9. Ошибки аргументов; неизвестный предмет → not_found; помощник обязателен
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  local S = require("scripts.perception.supply")
  local function bad(args, code) return G.raises(code or "bad_args", function() S.ops.supply(args, ctx) end) end
  bad({})
  bad({ item = 5 })
  bad({ item = "no-such-thing" }, "not_found")
  bad({ item = "ore", count = 0 })
  bad({ item = "ore", count = 1.5 })
  bad({ item = "ore", count = 10001 }, "limit")
  bad({ item = "ore", depth = 0 })
  bad({ item = "ore", depth = 6 }, "limit")
  bad({ item = "ore", surface = "nauvis" })
  bad({ item = string.rep("a", 201) })
  G.raises("no_helper", function() S.ops.supply({ item = "ore" }, {}) end)
  G.eq(U.supply({ item = "ore", count = 10000, depth = 5 }, ctx).tree.need, 10000)
end

-- 10. Содержимое вне обзора → hidden; машина вне обзора: стоит на карте, но out не читается
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  U.chest(w, 5.5, 0.5, { plate = 10 })
  U.chest(w, 200.5, 0.5, { plate = 1000 })                       -- чанк (6,0) не виден
  U.chest(w, 400.5, 0.5, { plate = 5000 })                       -- чанк (12,0) не открыт вовсе
  local far = U.machine(w, "smelter", "furnace", 210, 0, { recipe = "plate", cats = { smelting = true }, out = { plate = 64 } })
  w.force.set_visible(6, 0, false)
  w.force.set_charted(12, 0, false)
  local d = U.supply({ item = "plate", count = 4 }, ctx)
  G.eq(d.tree.stored.total, 10, "невидимый сундук в запас не входит")
  G.eq(d.hidden, 2, "сундук и выход машины вне обзора; неоткрытый чанк не считается совсем")
  G.eq(d.tree.producers.count, 1, "сама машина на карте есть (§6.7: статичное — открытые чанки)")
  G.eq(d.tree.producers.out, 0)
  G.eq(far.out_reads, 0, "выход невидимой машины не читался")
  G.eq(d.tree.recipe.makers.count, 1)
end

-- 11. Вероятностные и многопродуктовые рецепты: основной продукт и ожидаемый выход
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  local S = require("scripts.perception.supply")
  local ex = S._internal.expected
  G.eq(ex({ amount = 3 }), 3)
  G.eq(ex({ amount_min = 1, amount_max = 4 }), 2.5)
  G.eq(ex({ amount = 5, probability = 0.5 }), 2.5)
  G.eq(ex({ amount = 1, extra_count_fraction = 0.5 }), 1.5)
  -- основной продукт задан прототипом; 5 × 0.5 = 2.5 → yield 2
  U.recipe(w, "sift", { rock = 3 }, { main = { type = "item", name = "dust" }, products = {
    { type = "item", name = "dust", amount = 5, probability = 0.5 },
    { type = "item", name = "ore", amount = 1 } } })
  local d = U.supply({ item = "dust", count = 5 }, ctx)
  G.eq({ d.tree.recipe.name, d.tree.recipe.yield, d.tree.recipe.crafts }, { "sift", 2, 3 })
  G.eq(d.tree.recipe.ingredients[1].need, 9)
  -- побочный продукт рецептом предмета не считается
  G.eq(U.supply({ item = "ore" }, ctx).tree.note, "no_recipe")
  -- продукт, который не предмет и не жидкость (прогресс исследования), рецептом предмета не становится
  prototypes.item["lore"] = { name = "lore" }
  U.recipe(w, "study", { rock = 1 }, { products = { { type = "research-progress", research_item = "lore", name = "lore", amount = 1 } } })
  U.machine(w, "desk", "assembling-machine", 9, 9, { recipe = "study" })
  d = U.supply({ item = "lore" }, ctx)
  G.eq({ d.tree.note, d.tree.producers }, { "no_recipe" })
  w.force.recipes["study"] = nil
  -- редкий продукт: ожидание меньше 1 → yield 1
  U.recipe(w, "pan", { rock = 1 }, { products = { { type = "item", name = "mystery", amount = 1, probability = 0.1 } } })
  d = U.supply({ item = "mystery", count = 2 }, ctx)
  G.eq({ d.tree.recipe.yield, d.tree.recipe.crafts }, { 1, 2 })
  -- несколько продуктов без основного — рецепт не выбирается
  U.recipe(w, "split", { rock = 1 }, { products = {
    { type = "item", name = "resin", amount = 1 }, { type = "fluid", name = "steam2", amount = 10 } } })
  d = U.supply({ item = "steam2" }, ctx)
  G.eq(d.tree.note, "no_recipe")
  -- катализатор: продукт среди ингредиентов; выход ≤ расхода — рецепт не годится
  U.recipe(w, "grow", { { type = "item", name = "mystery", amount = 2 }, { type = "item", name = "rock", amount = 1 } },
    { products = { { type = "item", name = "mystery", amount = 5 } } })
  U.recipe(w, "wash", { { type = "item", name = "bar", amount = 1 } },
    { products = { { type = "item", name = "bar", amount = 1 } } })
  w.force.recipes["pan"].enabled = false
  d = U.supply({ item = "mystery", count = 6 }, ctx)
  G.eq({ d.tree.recipe.name, d.tree.recipe.yield, d.tree.recipe.crafts }, { "grow", 3, 2 }, "чистый выход 5 − 2")
  G.eq(d.tree.recipe.ingredients[1].note, "cycle")
  G.eq(U.flat(d.summary.short).mystery, 6, "катализатор в нехватку второй раз не идёт")
  d = U.supply({ item = "bar" }, ctx)
  G.eq(d.tree.recipe.name, "bar", "рецепт без прибавки не выбран")
end

-- 12. Выбор рецепта: стоящий в машинах базы → руками → меньше ингредиентов
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  local function alt(name, ingredients, o)
    o = o or {}
    o.products = { { type = "item", name = "plate", amount = 1 } }
    return U.recipe(w, name, ingredients, o)
  end
  alt("plate-cast", { goo = 20 }, { category = "casting" })
  alt("plate-press", { rock = 1, ore = 1, bar = 1 }, { category = "crafting" })
  local d = U.supply({ item = "plate" }, ctx)
  G.eq(d.tree.recipe.name, "plate-press", "руками — раньше, чем меньше ингредиентов")
  w.force.recipes["plate-press"].enabled = false
  d = U.supply({ item = "plate" }, ctx)
  G.eq(d.tree.recipe.name, "plate", "при равном числе ингредиентов — рецепт с именем предмета")
  U.machine(w, "caster", "assembling-machine", 8, 8, { recipe = "plate-cast", cats = { casting = true } })
  w.force.recipes["plate-press"].enabled = true
  d = U.supply({ item = "plate" }, ctx)
  G.eq(d.tree.recipe.name, "plate-cast", "уже стоит в машинах базы — первым")
  G.eq(d.tree.recipe.makers.names, { caster = 1 })
end

-- 13. Один проход по базе, лимит работы, только чтение
do
  local w = U.world()
  local _, ctx = U.helper(w, {})
  for i = 1, 6 do U.chest(w, i + 0.5, 3.5, { plate = 1 }) end
  U.machine(w, "bench", "assembling-machine", 20, 0, { recipe = "gear" })
  local function keys()
    local out = {}
    for k in pairs(storage) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return table.concat(out, ",")
  end
  local before, n = keys(), #w.surface.entities
  w.surface.calls = {}
  U.supply({ item = "widget", depth = 5 }, ctx)
  local force_calls = 0
  for _, c in ipairs(w.surface.calls) do
    if c[1] == "find_entities_filtered" and c[2].force ~= nil then force_calls = force_calls + 1 end
  end
  G.eq(force_calls, 2, "по сущностям силы — один счёт и один поиск на весь ответ, а не на узел")
  G.eq(keys(), before, "в storage ничего не появилось")
  G.eq(#w.surface.entities, n)
  G.eq(#w.force.charts, 0, "supply не открывает карту")

  local F = require("scripts.perception.find")
  G.eq(F.MAX_ENTITIES, 20000)
  F.MAX_ENTITIES = 5
  G.raises("limit", function() require("scripts.perception.supply").ops.supply({ item = "widget" }, ctx) end)
  F.MAX_ENTITIES = 20000
end

-- 14. Имён из игры в модуле нет (§6.12): в исходнике нет ни одного имени прототипа заглушек
-- и типовых имён игры в кавычках, кроме типов сущностей движка.
do
  local path = package.searchpath("scripts.perception.supply", package.path)
  G.ok(path ~= nil, "файл модуля найден")
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  for _, name in ipairs { "iron", "copper", "plate", "foundry", "nauvis", "vulcanus", "stone", "coal", "lava", "chest" } do
    G.ok(not text:find('"[^"\n]*' .. name .. '[^"\n]*"'), "в коде нет имени " .. name)
  end
end
