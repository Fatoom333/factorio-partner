-- Тесты операции `find` (поток G, ревизия 3.2). Контракт: docs/STATE.md «find»,
-- PROTOCOL §6.7 (статичное — открытые чанки, содержимое складов — только видимое), §6.11.
local G = require("stubs_g")

local function world(opts)
  local w = G.reset(opts)
  prototypes.item = {
    ["iron-plate"] = { name = "iron-plate" },
    ["iron-ore"] = { name = "iron-ore" },
    ["iron-gear-wheel"] = { name = "iron-gear-wheel" },
    ["automation-science-pack"] = { name = "automation-science-pack" },
    ["steel-chest"] = { name = "steel-chest", place_result = { name = "steel-chest" } },
    ["rail"] = { name = "rail", place_result = { name = "straight-rail" } },
  }
  prototypes.fluid = { water = { name = "water" }, ["sulfuric-acid"] = { name = "sulfuric-acid" } }
  prototypes.entity["steel-chest"] = { name = "steel-chest" }
  prototypes.entity["straight-rail"] = { name = "straight-rail" }
  game.forces = { player = w.force, enemy = w.enemy, neutral = w.neutral }
  w.force.recipes = {
    ["iron-plate"] = { name = "iron-plate", ingredients = { { type = "item", name = "iron-ore", amount = 1 } },
      products = { { type = "item", name = "iron-plate", amount = 1 } } },
    ["iron-gear-wheel"] = { name = "iron-gear-wheel", ingredients = { { type = "item", name = "iron-plate", amount = 2 } },
      products = { { type = "item", name = "iron-gear-wheel", amount = 1 } } },
  }
  return w
end

local function machine(w, name, etype, x, y, recipe, o)
  o = o or {}
  local e = w.surface.add(G.entity { name = name, type = etype, pos = { x = x, y = y }, force = o.force or w.force, size = 2 })
  local r = recipe and w.force.recipes[recipe] or nil
  e.get_recipe = function() return r, o.quality end
  if o.previous then e.previous_recipe = { name = o.previous, quality = "normal" } end
  return e
end

local function drill(w, x, y, ore, fluid)
  local e = w.surface.add(G.entity { name = "electric-mining-drill", type = "mining-drill", pos = { x = x, y = y }, force = w.force, size = 3 })
  if ore then
    e.mining_target = { valid = true, name = ore, prototype = { mineable_properties = {
      products = { { type = "item", name = ore, amount = 1 } }, required_fluid = fluid } } }
  end
  return e
end

local function chest(w, x, y, items, o)
  o = o or {}
  return w.surface.add(G.entity { name = o.name or "steel-chest", type = o.type or "container",
    pos = { x = x, y = y }, force = o.force or w.force, size = 1, inventory = G.inventory(items) })
end

local function find_mod() return require("scripts.perception.find") end

local function by_kind(d, kind)
  local out = {}
  for _, g in ipairs(d.groups) do if g.kind == kind then out[#out + 1] = g end end
  return out
end

-- 1. Кто делает, кто тратит, где лежит; группы по 32 клетки, ближайшие первыми, total
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  -- печи: две рядом (одна группа) и одна далеко
  machine(w, "stone-furnace", "furnace", 10, 0, "iron-plate")
  machine(w, "stone-furnace", "furnace", 14, 0, "iron-plate")
  machine(w, "steel-furnace", "furnace", 200, 0, nil, { previous = "iron-plate" }) -- без текущего рецепта — последний
  machine(w, "stone-furnace", "furnace", 18, 0, nil)                                  -- пустая: не считается
  machine(w, "stone-furnace", "furnace", 20, 0, "iron-plate", { force = w.enemy })    -- чужая
  machine(w, "stone-furnace", "furnace", 22, 0, "iron-plate", { quality = "rare" })   -- не normal
  -- сборщики шестерён тратят пластины
  machine(w, "assembling-machine-2", "assembling-machine", 60, 60, "iron-gear-wheel")
  -- склады
  chest(w, 5.5, 5.5, { ["iron-plate"] = 800 })
  chest(w, 6.5, 5.5, { ["iron-plate"] = 200, coal = 5 }, { name = "passive-provider-chest", type = "logistic-container" })
  chest(w, 7.5, 5.5, { coal = 50 })                                                   -- без предмета
  chest(w, 8.5, 5.5, { { name = "iron-plate", count = 9, quality = "rare" } })       -- не normal
  local d = find_mod().ops.find({ item = "iron-plate" }, ctx)
  G.plain(d)
  G.json(d)
  G.eq(d.item, "iron-plate")
  G.eq(d.surface, "nauvis")
  G.eq(d.total, { producers = 3, consumers = 1, storage = 2 })
  G.eq(d.hidden, 0)
  G.eq(d.truncated, nil)
  G.eq(#d.groups, 4)
  -- ближайшие первыми
  for i = 2, #d.groups do G.ok(d.groups[i - 1].dist <= d.groups[i].dist, "по возрастанию dist") end
  G.eq(d.groups[1].kind, "storage")
  G.eq(d.groups[1], { kind = "storage", pos = { x = 6, y = 5.5 }, dist = 8.1, count = 2, amount = 1000,
    names = { ["steel-chest"] = 1, ["passive-provider-chest"] = 1 } })
  local prod = by_kind(d, "producers")
  G.eq(#prod, 2)
  G.eq(prod[1], { kind = "producers", pos = { x = 12, y = 0 }, dist = 12, count = 2,
    names = { ["stone-furnace"] = 2 }, recipe = "iron-plate" })
  G.eq(prod[2].names, { ["steel-furnace"] = 1 })
  G.eq(prod[2].dist, 200)
  local cons = by_kind(d, "consumers")
  G.eq(cons[1].recipe, "iron-gear-wheel")
  G.eq(cons[1].pos, { x = 60, y = 60 })
end

-- 2. Буры по руде, жидкость для бура, лаборатории, береговой насос, цистерна
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  drill(w, 10, 10, "iron-ore")
  drill(w, 13, 10, "iron-ore")
  drill(w, 16, 10, nil)                       -- без цели
  drill(w, 100, 10, "uranium-ore", "sulfuric-acid")
  machine(w, "stone-furnace", "furnace", 30, 30, "iron-plate")
  local F = find_mod()
  local d = F.ops.find({ item = "iron-ore" }, ctx)
  G.eq(d.total, { producers = 2, consumers = 1, storage = 0 })
  G.eq(by_kind(d, "producers")[1].names, { ["electric-mining-drill"] = 2 })
  G.eq(by_kind(d, "producers")[1].recipe, nil)
  G.eq(by_kind(d, "consumers")[1].recipe, "iron-plate")

  d = F.ops.find({ item = "sulfuric-acid", kinds = { "consumers" } }, ctx)
  G.eq(d.total, { consumers = 1 })
  G.eq(d.groups[1].pos, { x = 100, y = 10 })
  G.eq(d.hidden, nil, "storage не просили — hidden нет")

  local lab = w.surface.add(G.entity { name = "lab", type = "lab", pos = { x = 40, y = 0 }, force = w.force, size = 3 })
  lab.prototype.lab_inputs = { "automation-science-pack", "logistic-science-pack" }
  d = F.ops.find({ item = "automation-science-pack", kinds = { "consumers" } }, ctx)
  G.eq(d.total, { consumers = 1 })
  G.eq(d.groups[1].names, { lab = 1 })

  local pump = w.surface.add(G.entity { name = "offshore-pump", type = "offshore-pump", pos = { x = -20, y = 0 }, force = w.force })
  pump.get_fluid_contents = function() return { water = 5 } end -- что качает насос — по содержимому
  pump.get_fluid_source_fluid = function() error("get_fluid_source_fluid must not be called") end
  local pump2 = w.surface.add(G.entity { name = "offshore-pump", type = "offshore-pump", pos = { x = -300, y = 0 }, force = w.force })
  pump2.get_fluid_contents = function() return { water = 100 } end
  local dry = w.surface.add(G.entity { name = "offshore-pump", type = "offshore-pump", pos = { x = -310, y = 0 }, force = w.force })
  dry.get_fluid_contents = function() return {} end -- пустой насос производителем не считается
  local tank = w.surface.add(G.entity { name = "storage-tank", type = "storage-tank", pos = { x = -25, y = 3 }, force = w.force, size = 3 })
  tank.get_fluid_count = function(name) return name == "water" and 12000.4 or 0 end
  local empty = w.surface.add(G.entity { name = "storage-tank", type = "storage-tank", pos = { x = -28, y = 3 }, force = w.force, size = 3 })
  empty.get_fluid_count = function() return 0 end
  d = F.ops.find({ item = "water" }, ctx)
  G.eq(d.total, { producers = 2, consumers = 0, storage = 1 })
  G.eq(by_kind(d, "storage")[1].amount, 12000.4)
  G.eq(by_kind(d, "storage")[1].names, { ["storage-tank"] = 1 })
end

-- 3. Честность: неоткрытые чанки не видны вовсе; склады вне обзора — только счёт hidden
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  machine(w, "stone-furnace", "furnace", 10, 0, "iron-plate")
  machine(w, "stone-furnace", "furnace", 330, 0, "iron-plate")     -- чанк (10,0) не открыт
  chest(w, 330.5, 5.5, { ["iron-plate"] = 999 })                    -- не открыт: ни в storage, ни в hidden
  chest(w, 100.5, 0.5, { ["iron-plate"] = 500 })                    -- открыт, но не виден: hidden
  chest(w, 20.5, 0.5, { ["iron-plate"] = 40 })                      -- в 32 клетках от тела — «глаза» помощника
  w.force.set_charted(10, 0, false)
  w.force.set_visible(3, 0, false)
  w.force.set_visible(0, 0, false)
  local d = find_mod().ops.find({ item = "iron-plate" }, ctx)
  G.eq(d.total, { producers = 1, consumers = 0, storage = 1 })
  G.eq(d.hidden, 1)
  G.eq(by_kind(d, "storage")[1].amount, 40)
  -- без помощника «глаз» нет: видимость только по чанкам силы
  G.add_player(w, { name = "T", pos = { x = 0, y = 0 } })
  d = find_mod().ops.find({ item = "iron-plate", kinds = { "storage" } }, {})
  G.eq(d.total, { storage = 0 })
  G.eq(d.hidden, 2)
  -- чужая сила не ищется никогда
  for _, c in ipairs(w.surface.calls) do
    if c[1] == "find_entities_filtered" then G.eq(c[2].force, w.force, "поиск только по своей силе") end
  end
end

-- 4. kinds=entities: постройки по имени и по предмету, который их ставит; limit и truncated
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  for i = 0, 5 do chest(w, i * 100 + 0.5, 0.5, {}) end
  local rare = chest(w, 3.5, 3.5, {})
  rare.quality = { name = "rare" }
  w.surface.add(G.entity { name = "straight-rail", type = "straight-rail", pos = { x = 50, y = 50 }, force = w.force, size = 2 })
  local F = find_mod()
  local d = F.ops.find({ item = "steel-chest", kinds = { "entities" } }, ctx)
  G.eq(d.total, { entities = 6 })
  G.eq(#d.groups, 6)
  G.eq(d.groups[1].dist, 0.7)
  d = F.ops.find({ item = "steel-chest", kinds = { "entities" }, limit = 2 }, ctx)
  G.eq(#d.groups, 2)
  G.eq(d.truncated, true)
  G.eq(d.total, { entities = 6 }, "total — по всем, не только по limit")
  d = F.ops.find({ item = "rail", kinds = { "entities" } }, ctx)
  G.eq(d.groups[1].names, { ["straight-rail"] = 1 })
  d = F.ops.find({ item = "straight-rail", kinds = { "entities" } }, ctx) -- имя постройки, не предмета
  G.eq(d.total, { entities = 1 })
  G.raises("bad_args", function() F.ops.find({ item = "straight-rail" }, ctx) end, "не предмет — только с kinds=entities")
  -- предмет без постройки: entities пусто, не ошибка
  d = F.ops.find({ item = "iron-plate", kinds = { "entities" } }, ctx)
  G.eq(d.total, { entities = 0 })
  G.eq(d.groups, {})
end

-- 5. Аргументы
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local F = find_mod()
  local function bad(args, code) return G.raises(code or "bad_args", function() F.ops.find(args, ctx) end) end
  bad({})
  bad({ item = 5 })
  bad({ item = "" })
  bad({ item = "no-such-thing" })
  bad({ item = "iron-plate", kinds = "storage" })
  bad({ item = "iron-plate", kinds = {} })
  bad({ item = "iron-plate", kinds = { "storage", "everything" } })
  bad({ item = "iron-plate", kinds = { storage = true } })
  bad({ item = "iron-plate", kinds = { "storage", "storage", "storage", "storage", "storage" } }, "limit")
  bad({ item = "iron-plate", limit = 0 })
  bad({ item = "iron-plate", limit = 2.5 })
  bad({ item = "iron-plate", limit = 51 }, "limit")
  bad({ item = "iron-plate", radius = 10 })
  bad({ item = "iron-plate", surface = 7 })
  bad({ item = "iron-plate", surface = "gleba" }, "not_found")
  G.eq(#F.ops.find({ item = "iron-plate", limit = 50, kinds = { "producers", "producers" } }, ctx).groups, 0)
end

-- 6. Поверхность: по умолчанию помощника; явная — другая; без помощника — хозяина; no_player
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local vulc = G.surface("vulcanus")
  game.surfaces.vulcanus = vulc
  local far = vulc.add(G.entity { name = "foundry", type = "assembling-machine", pos = { x = 500, y = 500 }, force = w.force, size = 4 })
  far.get_recipe = function() return w.force.recipes["iron-plate"] end
  local F = find_mod()
  G.eq(F.ops.find({ item = "iron-plate" }, ctx).total.producers, 0)
  local d = F.ops.find({ item = "iron-plate", surface = "vulcanus" }, ctx)
  G.eq(d.surface, "vulcanus")
  G.eq(d.total.producers, 1)
  G.eq(d.groups[1].dist, nil, "помощник на другой поверхности — расстояния нет")
  G.eq(d.groups[1].pos, { x = 500, y = 500 })
  -- без помощника и хозяина офлайн
  G.raises("no_player", function() F.ops.find({ item = "iron-plate" }, {}) end)
  -- с явной поверхностью хозяин онлайн не нужен (сила player)
  G.eq(F.ops.find({ item = "iron-plate", surface = "vulcanus" }, {}).total.producers, 1)
  -- хозяин онлайн на vulcanus: его поверхность и расстояние от него
  G.add_player(w, { name = "T", pos = { x = 500, y = 490 }, surface = vulc })
  d = F.ops.find({ item = "iron-plate" }, {})
  G.eq(d.surface, "vulcanus")
  G.eq(d.groups[1].dist, 10)
  -- невалидное тело помощника
  ctx.entity.valid = false
  G.raises("no_helper", function() F.ops.find({ item = "iron-plate" }, ctx) end)
end

-- 7. Лимиты: размер карты лимитом не является (ревизия 3.3), лимит — число найденных сущностей
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local F = find_mod()
  G.eq(F.MAX_CHUNKS, nil, "лимита по чанкам больше нет")
  G.eq(F.MAX_ENTITIES, 20000)
  w.surface.chunk_count = 1000000
  w.surface.get_chunks = function() error("find must not walk the chunks of the surface") end
  F.ops.find({ item = "iron-plate" }, ctx)
  -- сущности считаются до поиска: большую таблицу мод не строит
  for i = 1, 6 do chest(w, i + 0.5, 0.5, { ["iron-plate"] = 1 }) end
  F.MAX_ENTITIES = 5
  local finds_before = 0
  for _, c in ipairs(w.surface.calls) do if c[1] == "find_entities_filtered" then finds_before = finds_before + 1 end end
  local orig_count = w.surface.count_entities_filtered
  local counted = 0
  w.surface.count_entities_filtered = function(f)
    counted = counted + 1
    local n = 0
    for _, e in ipairs(w.surface.entities) do
      if e.valid and e.force == f.force then
        for _, t in ipairs(f.type or {}) do if e.type == t then n = n + 1 end end
      end
    end
    return n
  end
  text = G.raises("limit", function() F.ops.find({ item = "iron-plate", kinds = { "storage" } }, ctx) end)
  G.ok(text:find("narrow kinds"), text)
  G.eq(counted, 1)
  local finds_after = 0
  for _, c in ipairs(w.surface.calls) do if c[1] == "find_entities_filtered" then finds_after = finds_after + 1 end end
  G.eq(finds_after, finds_before, "при превышении find_entities_filtered не вызывается")
  w.surface.count_entities_filtered = orig_count
end

-- 8. Группировка: цепочка через 30 клеток — одна группа, разрыв 40 — две; имена обрезаются
do
  world()
  local F = find_mod()
  local list = {}
  for i = 0, 10 do list[#list + 1] = { kind = "producers", x = i * 30, y = 0, name = "a" } end
  list[#list + 1] = { kind = "producers", x = 10 * 30 + 80, y = 0, name = "b" }
  list[#list + 1] = { kind = "producers", x = -1000, y = -1000, name = "c" }
  list[#list + 1] = { kind = "producers", x = -1005, y = -1001, name = "c" }
  local groups = F._internal.cluster(list)
  G.eq(#groups, 3)
  table.sort(groups, function(a, b) return a.count > b.count end)
  G.eq({ groups[1].count, groups[2].count, groups[3].count }, { 11, 2, 1 })
  G.eq(F._internal.cluster({}), {})
  -- отрицательные координаты и границы клеток сетки не рвут группу
  local near = F._internal.cluster({ { x = -0.5, y = -0.5, name = "a" }, { x = 0.5, y = 0.5, name = "a" } })
  G.eq(#near, 1)

  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  for i = 1, 12 do
    prototypes.entity["chest-" .. i] = { name = "chest-" .. i }
    for _ = 1, i do chest(w, i + 0.5, 2.5, { ["iron-plate"] = 1 }, { name = "chest-" .. i }) end
  end
  local d = find_mod().ops.find({ item = "iron-plate", kinds = { "storage" } }, ctx)
  local g = d.groups[1]
  G.eq(g.count, 78)
  local n = 0
  for _ in pairs(g.names) do n = n + 1 end
  G.eq(n, 8, "в группе — восемь самых частых имён")
  G.eq(g.names["chest-12"], 12)
  G.eq(g.names["chest-4"], nil)
  G.eq(g.names_more, 4)
end

-- 9. Только чтение: storage не меняется, ничего не создаётся
do
  local w = world()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  chest(w, 5.5, 5.5, { ["iron-plate"] = 800 })
  local function keys()
    local out = {}
    for k in pairs(storage) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return table.concat(out, ",")
  end
  local before = keys()
  local n = #w.surface.entities
  find_mod().ops.find({ item = "iron-plate", kinds = { "producers", "consumers", "storage", "entities" } }, ctx)
  G.eq(keys(), before, "в storage ничего не появилось")
  G.eq(#w.surface.entities, n)
  G.eq(#w.force.charts, 0, "find не открывает карту")
end
