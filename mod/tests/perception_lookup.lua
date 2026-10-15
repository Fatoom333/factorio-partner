-- Тесты операции `lookup`. Контракт: docs/STATE.md «lookup»,
-- PROTOCOL §6.12 (имён в коде нет: всё из прототипов и сил).
local K = require("stubs_lookup")
local G = K.G

-- Снимок storage: простые значения по путям; Lua-объекты (тело помощника) — только по ссылке.
local function snapshot()
  local out, seen = {}, {}
  local function walk(t, path)
    if seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do
      local p = path .. "." .. tostring(k)
      if type(v) == "table" and v.object_name == nil then
        walk(v, p)
      else
        out[#out + 1] = p .. "=" .. tostring(v)
      end
    end
  end
  walk(storage, "storage")
  table.sort(out)
  return table.concat(out, ";")
end

-- 1. Предмет с двумя рецептами: основной первым, скрытый не показан; машины; used_in с обрезкой
do
  local w = K.world()
  local _, ctx = K.helper(w)
  local before = snapshot()
  local d = K.lookup({ name = "plate" }, ctx)
  G.eq({ d.kind, d.name, d.type, d.stack_size }, { "item", "plate", "item", 100 })
  G.eq(d.made_by_total, 2, "скрытый рецепт не считается")
  G.eq(K.names(d.made_by, "name"), { "plate", "plate-from-rock" }, "основной продукт — первым")
  local r = d.made_by[1]
  G.eq({ r.enabled, r.category, r.hand, r.time }, { true, "smelting", false, 3.2 })
  G.eq(r.ingredients, { { name = "ore", type = "item", amount = 1 } })
  G.eq(r.products, { { name = "plate", type = "item", amount = 1 } })
  G.eq(r.machines, { "big-maker", "smelter" }, "по категории, без скрытых, по имени")
  G.eq(r.machines_total, 2)
  G.eq(r.unlocked_by, nil, "открытому рецепту предмета unlocked_by не нужен")
  G.eq(r.hidden, nil)
  G.eq(d.made_by[2].products[2], { name = "plate", type = "item", amount = 1, probability = 0.5 })
  G.eq(d.used_in_total, 3)
  G.eq(d.used_in[1], { recipe = "board", enabled = true, category = "crafting" })
  G.eq(K.names(d.used_in, "recipe"), { "board", "gear", "secret" }, "открытые первыми")
  G.eq(d.used_in[3].enabled, false)
  G.eq(#d.mined_from, 0)
  G.eq(d.researched_any, true)
  G.eq(d.fuel_value, nil)

  local cut = K.lookup({ name = "plate", limit = 1 }, ctx)
  G.eq(#cut.made_by, 1)
  G.eq(cut.made_by_total, 2)
  G.eq(K.names(cut.used_in, "recipe"), { "board" })
  G.eq(cut.used_in_total, 3)
  G.eq(snapshot(), before, "lookup ничего не пишет в storage")
end

-- 2. Руда и камень: mined_from по прототипам ресурсов, деревьев и камней (по типам, без имён)
do
  local w = K.world()
  local _, ctx = K.helper(w)
  local ore = K.lookup({ name = "ore" }, ctx)
  G.eq(ore.mined_from, { { resource = "ore", amount = 1 } })
  G.eq(ore.made_by_total, 0)
  G.eq(ore.researched_any, true, "добывается — значит доступно")
  G.eq(ore.fuel_value, nil, "нулевое топливо не показывается")
  local rock = K.lookup({ name = "rock" }, ctx)
  G.eq(rock.mined_from, { { resource = "rock-field", amount = 1 }, { resource = "boulder", amount = 25 } },
       "ресурсы раньше камней; amount — среднее min/max")
  G.eq(rock.fuel_value, 2000000)
  local resin = K.lookup({ name = "resin" }, ctx)
  G.eq(resin.mined_from, { { resource = "bush", amount = 2 } }, "деревья тоже")
  G.eq(resin.made_by[1].hand, false, "жидкость среди ингредиентов — не руками (как у supply)")
  local goo = K.lookup({ name = "goo" }, ctx)
  G.eq({ goo.kind, goo.type }, { "fluid", "fluid" })
  G.eq(goo.mined_from, { { resource = "goo-well", amount = 10 } })
  G.eq(goo.stack_size, nil)
  local gear = K.lookup({ name = "gear" }, ctx)
  G.eq(gear.made_by[1].hand, true)
  G.eq(gear.made_by[1].machines, { "big-maker", "maker" })
end

-- 3. Неоткрытый рецепт: unlocked_by; рецепт целиком — unlocked_by всегда
do
  local w = K.world()
  local _, ctx = K.helper(w)
  K.tech(w, "t-z")
  K.tech(w, "t-secrets", { unlocks = { "secret" } })
  K.tech(w, "t-also", { unlocks = { "secret", "gear" }, researched = true })
  local item = K.lookup({ name = "secret" }, ctx)
  G.eq(item.researched_any, false)
  G.eq(item.made_by[1].enabled, false)
  G.eq(item.made_by[1].unlocked_by, { "t-also", "t-secrets" })
  local r = K.lookup({ name = "secret", kind = "recipe" }, ctx)
  G.eq({ r.kind, r.name, r.enabled }, { "recipe", "secret", false })
  G.eq(r.unlocked_by, { "t-also", "t-secrets" })
  local open = K.lookup({ name = "widget", kind = "recipe" }, ctx)
  G.eq(open.unlocked_by, {}, "открыт с начала — пусто")
  local hidden = K.lookup({ name = "plate-recycle" }, ctx)
  G.eq({ hidden.kind, hidden.hidden }, { "recipe", true }, "скрытый рецепт по имени — с hidden")
end

-- 4. Технологии: цепочка из трёх неизученных предпосылок, изученная предпосылка, trigger, cost
do
  local w = K.world()
  local _, ctx = K.helper(w)
  K.tech(w, "t-a", { researched = true })
  K.tech(w, "t-b", { pre = { "t-a" }, count = 30, ingredients = { pack = 1, pack2 = 2 }, energy = 900 })
  K.tech(w, "t-c", { pre = { "t-b" } })
  K.tech(w, "t-d", { pre = { "t-c", "t-a" } })
  K.tech(w, "t-x", { pre = { "t-b" } })
  K.tech(w, "t-e", { pre = { "t-d", "t-x" }, unlocks = { "secret" },
                     other = { { type = "some-bonus", modifier = 0.5 }, { type = "give-thing", item = { name = "gear" } } } })
  local d = K.lookup({ name = "t-e" }, ctx)
  G.eq({ d.kind, d.name, d.researched, d.enabled, d.available }, { "technology", "t-e", false, true, false })
  G.eq(d.prerequisites, { { name = "t-d", researched = false }, { name = "t-x", researched = false } })
  G.eq(d.missing, { "t-b", "t-c", "t-d", "t-x" }, "в порядке изучения, без повторов, без изученных")
  G.eq(d.unlocks, { "secret" })
  G.eq(d.other_effects, { { type = "some-bonus", modifier = 0.5 }, { type = "give-thing", item = "gear" } })
  G.eq(d.cost, { count = 10, ingredients = {}, time = 10 })
  G.eq(d.trigger, nil)

  local b = K.lookup({ name = "t-b", kind = "technology" }, ctx)
  G.eq(b.prerequisites, { { name = "t-a", researched = true } })
  G.eq(b.available, true)
  G.eq(#b.missing, 0)
  G.eq(b.cost, { count = 30, ingredients = { { name = "pack", amount = 1 }, { name = "pack2", amount = 2 } }, time = 15 })

  K.tech(w, "t-trig", { pre = { "t-a" }, trigger = { type = "craft-item", item = "plate", count = 10 } })
  local t = K.lookup({ name = "t-trig" }, ctx)
  G.eq(t.trigger, { type = "craft-item", item = "plate", count = 10 })
  G.eq(t.cost, nil, "изучается действием, а не колбами")
  G.eq(t.available, true)
  G.eq(#t.unlocks, 0)

  -- missing не больше 30: длинная цепочка
  local prev = "t-a"
  for i = 1, 40 do
    local n = string.format("t-chain-%02d", i)
    K.tech(w, n, { pre = { prev } })
    prev = n
  end
  local long = K.lookup({ name = prev }, ctx)
  G.eq(#long.missing, 30)
  G.eq(long.missing[1], "t-chain-01", "первым — то, что изучать первым")
end

-- 5. Постройка: только существующие поля
do
  local w = K.world()
  local _, ctx = K.helper(w)
  local s = K.lookup({ name = "smelter", kind = "entity" }, ctx)
  G.eq(s, { kind = "entity", name = "smelter", type = "furnace", size = { w = 2, h = 2 },
            items_to_place = { "smelter" }, crafting_categories = { "smelting" }, crafting_speed = 2,
            energy_usage = 90000, mineable_results = { { name = "smelter", type = "item", amount = 1 } } })
  local dg = K.lookup({ name = "digger" }, ctx)
  G.eq(dg, { kind = "entity", name = "digger", type = "mining-drill", size = { w = 3, h = 3 },
             items_to_place = {}, mining_categories = { "basic" } })
end

-- 6. kind явный и без kind (порядок поиска item → fluid → recipe → technology → entity)
do
  local w = K.world()
  local _, ctx = K.helper(w)
  G.eq(K.lookup({ name = "smelter" }, ctx).kind, "item", "без kind — сначала предмет")
  local it = K.lookup({ name = "smelter" }, ctx)
  G.eq(it.place_result, "smelter")
  G.eq(K.lookup({ name = "plate", kind = "recipe" }, ctx).kind, "recipe")
  G.eq(K.lookup({ name = "ore", kind = "entity" }, ctx).kind, "entity")
  G.eq(K.lookup({ name = "plate-from-rock" }, ctx).kind, "recipe", "нет предмета — рецепт")
  K.tech(w, "t-only")
  G.eq(K.lookup({ name = "t-only" }, ctx).kind, "technology")
  G.eq(K.lookup({ name = "bush" }, ctx).kind, "entity")
  G.raises("not_found", function() K.lookup({ name = "plate", kind = "fluid" }, ctx) end)
end

-- 7. not_found с подсказками; аргументы; без помощника — сила хозяина
do
  local w = K.world()
  local _, ctx = K.helper(w)
  local text = G.raises("not_found", function() K.lookup({ name = "PLAT" }, ctx) end)
  G.ok(string.find(text, "suggest: plate, plate-from-rock", 1, true), "подсказки без учёта регистра: " .. text)
  G.ok(not string.find(text, "plate-recycle", 1, true), "скрытое не подсказывается")
  local none = G.raises("not_found", function() K.lookup({ name = "zzz" }, ctx) end)
  G.ok(not string.find(none, "suggest", 1, true))
  local many = G.raises("not_found", function() K.lookup({ name = "e" }, ctx) end)
  local _, commas = string.gsub(string.match(many, "suggest: (.*)$"), ", ", "")
  G.eq(commas, 4, "не больше 5 подсказок: " .. many)
  G.ok(#many <= 300)

  G.raises("bad_args", function() K.lookup({}, ctx) end)
  G.raises("bad_args", function() K.lookup({ name = "plate", kind = "thing" }, ctx) end)
  G.raises("bad_args", function() K.lookup({ name = "plate", limit = 0 }, ctx) end)
  G.raises("limit", function() K.lookup({ name = "plate", limit = 51 }, ctx) end)
  G.raises("bad_args", function() K.lookup({ name = "plate", radius = 5 }, ctx) end)
  G.raises("bad_args", function() K.lookup({ name = string.rep("a", 201) }, ctx) end)
  G.eq(K.lookup({ name = "plate", limit = 50 }, ctx).made_by_total, 2)

  G.raises("no_player", function() K.lookup({ name = "plate" }, nil) end)
end

do
  local w = K.world({ owner = "boss" })
  G.add_player(w, { name = "boss", connected = false, character = false })
  K.tech(w, "t-secrets", { unlocks = { "secret" } })
  local d = K.lookup({ name = "secret", kind = "recipe" }, nil)
  G.eq(d.unlocked_by, { "t-secrets" }, "без помощника — сила хозяина, хозяин может быть не в игре")
  G.eq(d.hand, true, "без тела — категории персонажа из прототипа")
end

print("perception_lookup: ok")
