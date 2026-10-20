-- Действие get_items и флаг auto_supply: карманы → склады → крафт с промежуточными → плавка →
-- добыча руками; shortfall; только видимое и своё; прогресс; отмена.
local S = require("stubs")
local C = require("stubs_c")

local function get(args) return S.okr(C.act("get_items", args)).job end
local function chest_inv(ch) return ch.get_inventory(defines.inventory.chest) end

-- ---- печи: заглушка «движка» плавки. Слоты как в игре: fuel=1, source=2, result=3.
local furnaces = {}
local orig_run = C.run

local function furnace_step(f)
  local src, res, fuel = f.src, f.res, f.fuel
  if src.is_empty() then return end
  if f.burner and f.fuel_left <= 0 then
    if fuel.get_item_count("coal") > 0 then
      fuel.remove{ name = "coal", count = 1 }
      f.fuel_left = 14
    else
      return
    end
  end
  for _, r in ipairs(f.recipes) do
    if src.get_item_count(r.from) > 0 then
      f.progress = f.progress + 1 / (r.time * 60)
      if f.progress >= 1 then
        f.progress = 0
        src.remove{ name = r.from, count = 1 }
        res.insert{ name = r.to, count = 1 }
        f.smelted = f.smelted + 1
        if f.burner then f.fuel_left = f.fuel_left - 1 end
      end
      return
    end
  end
end

C.run = function(n)
  for _ = 1, n or 1 do
    for _, f in ipairs(furnaces) do
      if f.e.valid then furnace_step(f) end
    end
    orig_run(1)
  end
end

local function furnace(pos, opts)
  opts = opts or {}
  local e = S.nauvis.create_entity{ name = "stone-furnace", position = pos, force = opts.force or "player" }
  local f = {
    e = e, burner = opts.burner ~= false, progress = 0, fuel_left = 0, smelted = 0,
    recipes = { { from = "iron-ore", to = "iron-plate", time = 3.2 }, { from = "copper-ore", to = "copper-plate", time = 3.2 } },
    fuel = C.inventory{ size = 1, items = opts.fuel }, src = C.inventory{ size = 1 }, res = C.inventory{ size = 1 },
  }
  e.inventories = { [1] = f.fuel, [2] = f.src, [3] = f.res }
  rawset(e, "insert", function(st)
    if st.name == "coal" or st.name == "wood" then return f.fuel.insert(st) end
    for _, r in ipairs(f.recipes) do
      if r.from == st.name then return f.src.insert(st) end
    end
    return 0
  end)
  furnaces[#furnaces + 1] = f
  return f
end

local function prepare(opts)
  furnaces = {}
  local W = C.setup(opts)
  local E = prototypes.entity
  E["stone-furnace"].crafting_categories = { smelting = true }
  E["stone-furnace"].get_crafting_speed = function() return 1 end
  E["stone-furnace"].burner_prototype = {}
  prototypes.item.coal.fuel_value = 4000000
  prototypes.item.wood.fuel_value = 2000000
  prototypes.item["iron-plate"].fuel_value = 0
  prototypes.item["gear-box"] = { name = "gear-box", type = "item", stack_size = 50 }
  local R = game.forces.player.recipes
  local function recipe(name, cat, ingr, product, time)
    local ing, prod = {}, { { type = "item", name = product, amount = 1 } }
    for _, i in ipairs(ingr) do ing[#ing + 1] = { type = "item", name = i[1], amount = i[2] } end
    R[name] = { name = name, enabled = true, hidden = false, category = cat, energy = time, ingredients = ing,
      products = prod, valid = true }
  end
  recipe("iron-plate", "smelting", { { "iron-ore", 1 } }, "iron-plate", 3.2)
  recipe("copper-plate", "smelting", { { "copper-ore", 1 } }, "copper-plate", 3.2)
  recipe("gear-box", "crafting", { { "iron-gear-wheel", 2 }, { "pipe", 1 } }, "gear-box", 0.5)
  return W
end

S.suite("hands_get_items", {
  { "уже есть в карманах: ничего не делает, from.inventory", function()
      local W = prepare{ items = { ["iron-plate"] = 30 } }
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 20 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { have = { ["iron-plate"] = 30 }, from = { inventory = { ["iron-plate"] = 20 } } })
      S.eq(C.counts(W.main), { ["iron-plate"] = 30 })
      S.eq(#W.path.calls, 0)
  end },
  { "склад: недостающее берёт со склада (как collect), карманы засчитываются", function()
      local W = prepare{ items = { ["iron-plate"] = 5 } }
      local ch = C.chest({ x = 10.5, y = 0.5 }, { ["iron-plate"] = 50, coal = 3 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 25 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["iron-plate"] = 25 })
      S.eq(d.detail.from, { inventory = { ["iron-plate"] = 5 }, storage = { ["iron-plate"] = 20 } })
      S.eq(C.counts(chest_inv(ch)), { ["iron-plate"] = 30, coal = 3 })
      S.eq(storage.reservations.items.h1, nil, "резерв склада снят")
  end },
  { "склад с большими запасами: сталь и шестерни из нескольких сундуков (как на живом стенде)", function()
      local W = prepare()
      prototypes.item["steel-plate"] = { name = "steel-plate", type = "item", stack_size = 100 }
      for i = 1, 3 do C.chest({ x = 4.5 + i, y = 0.5 }, { ["steel-plate"] = 1000, ["iron-plate"] = 1000 }, { size = 48 }) end
      local d, kind = C.wait(get{ items = { ["steel-plate"] = 20 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["steel-plate"] = 20 })
      S.eq(d.detail.from, { storage = { ["steel-plate"] = 20 } })
      S.eq(C.counts(W.main), { ["steel-plate"] = 20 })
      d, kind = C.wait(get{ items = { ["iron-gear-wheel"] = 5 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.from, { storage = { ["iron-plate"] = 10 }, crafted = { ["iron-gear-wheel"] = 5 } })
  end },
  { "крафт с промежуточными: шестерни и трубы, потом сборка", function()
      local W = prepare{ items = { ["iron-plate"] = 12 } }
      local d, kind = C.wait(get{ items = { ["gear-box"] = 2 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["gear-box"] = 2 })
      S.eq(d.detail.from.crafted, { ["iron-gear-wheel"] = 4, pipe = 2, ["gear-box"] = 2 })
      S.eq(C.counts(W.main), { ["iron-plate"] = 2, ["gear-box"] = 2 })
      S.eq(d.detail.shortfall, nil)
  end },
  { "склад + крафт: плиты берёт со склада и крафтит из них", function()
      local W = prepare()
      C.chest({ x = 6.5, y = 0.5 }, { ["iron-plate"] = 40 })
      local d, kind = C.wait(get{ items = { ["iron-gear-wheel"] = 5 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.from, { storage = { ["iron-plate"] = 10 }, crafted = { ["iron-gear-wheel"] = 5 } })
      S.eq(C.counts(W.main), { ["iron-gear-wheel"] = 5 })
  end },
  { "плавка: руда из карманов в свободной печи рядом, плиты забирает", function()
      local W = prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      local f = furnace({ x = 8.5, y = 0.5 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 6 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["iron-plate"] = 6 })
      S.eq(d.detail.from, { smelted = { ["iron-plate"] = 6 } })
      local c = C.counts(W.main)
      S.eq(c["iron-plate"], 6)
      S.eq(c["iron-ore"], 4)
      S.ok((c.coal or 0) < 2, "топливо в печь положено")
      S.eq(f.smelted, 6)
      S.ok(f.res.is_empty() and f.src.is_empty(), "печь освобождена")
  end },
  { "плавка по настройке perm-smelt: нельзя — печь хозяина не трогает; спросить — только с owner_ok", function()
      local W = prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      local f = furnace({ x = 8.5, y = 0.5 })
      rawset(f.e, "last_user", { name = "Tartaluga" }) -- печь поставил хозяин
      settings.global["partner-perm-smelt"] = { value = "deny" }
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 6 } })
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.eq(f.smelted, 0)
      S.eq(C.counts(W.main)["iron-ore"], 10)
      settings.global["partner-perm-smelt"] = { value = "ask" }
      S.owner_ok = nil
      local d2, kind2 = C.wait(get{ items = { ["iron-plate"] = 6 } })
      S.eq({ kind2, f.smelted }, { "job_failed", 0 }, S.dump(d2))
      S.owner_ok = { "chop" }
      local d4, kind4 = C.wait(get{ items = { ["iron-plate"] = 6 } })
      S.eq({ kind4, f.smelted }, { "job_failed", 0 }, "разрешение на другое плавить не даёт: " .. S.dump(d4))
      S.owner_ok = { "smelt" }
      local d3, kind3 = C.wait(get{ items = { ["iron-plate"] = 6 } })
      S.eq(kind3, "job_done", S.dump(d3))
      S.eq(f.smelted, 6)
  end },
  { "плавка: своя печь помощника — без разрешения хозяина, даже при «нельзя»", function()
      local W = prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      local f = furnace({ x = 8.5, y = 0.5 })
      settings.global["partner-perm-smelt"] = { value = "deny" }
      S.owner_ok = nil
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 6 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(f.smelted, 6)
      S.ok(C.counts(W.main)["iron-plate"] >= 6)
  end },
  { "плавка при «нельзя»: печь хозяина рядом не берётся, своя дальше — берётся", function()
      prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      local theirs = furnace({ x = 4.5, y = 0.5 })
      rawset(theirs.e, "last_user", { name = "Tartaluga" })
      local own = furnace({ x = 10.5, y = 0.5 })
      settings.global["partner-perm-smelt"] = { value = "deny" }
      S.owner_ok = nil
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 6 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ theirs.smelted, own.smelted }, { 0, 6 })
  end },
  { "плавка: печь с топливом хозяина (в слоте или горит) и занятая не берутся; пустая берётся", function()
      local W = prepare{ items = { ["iron-ore"] = 4, coal = 5 } }
      local busy = furnace({ x = 5.5, y = 0.5 })
      busy.src.insert{ name = "iron-ore", count = 7 }
      local fueled = furnace({ x = 8.5, y = 0.5 }, { fuel = { coal = 3 } })
      local burning = furnace({ x = 10.5, y = 0.5 })
      burning.e.burner = { remaining_burning_fuel = 1000 }
      local free = furnace({ x = 12.5, y = 0.5 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 4 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(busy.src.get_item_count("iron-ore"), 7, "занятая печь не тронута")
      S.eq(fueled.fuel.get_item_count("coal"), 3, "топливо хозяина на месте")
      S.eq({ fueled.smelted, burning.smelted }, { 0, 0 })
      S.eq(free.smelted, 4)
  end },
  { "плавка: печь с манипулятором или загрузчиком хозяина не берётся, посторонний манипулятор не мешает", function()
      local W = prepare{ items = { ["iron-ore"] = 4, coal = 2 } }
      local a = furnace({ x = 5.5, y = 0.5 })
      local b = furnace({ x = 5.5, y = 4.5 })
      local c = furnace({ x = 5.5, y = 8.5 })
      local d3 = furnace({ x = 5.5, y = 12.5 })
      local other = C.chest({ x = 20.5, y = 20.5 }, {})
      local function dev(name, pos, fields)
        return S.nauvis.create_entity{ name = name, type = fields.type, position = pos, force = "player", fields = fields }
      end
      dev("some-inserter", { x = 5.5, y = 2.5 }, { type = "inserter", pickup_target = a.e, drop_target = other })
      dev("some-inserter", { x = 5.5, y = 6.5 }, { type = "inserter", pickup_target = other, drop_target = b.e })
      dev("some-loader", { x = 5.5, y = 10.5 }, { type = "loader-1x1", loader_container = c.e })
      dev("some-inserter", { x = 7.5, y = 12.5 }, { type = "inserter", pickup_target = other, drop_target = other })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 4 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ a.smelted, b.smelted, c.smelted, d3.smelted }, { 0, 0, 0, 4 })
  end },
  { "плавка: длинный и модовый манипулятор хозяина (дальше 3 клеток от центра) тоже находятся", function()
      local W = prepare{ items = { ["iron-ore"] = 4, coal = 2 } }
      prototypes.get_entity_filtered = function()
        return {
          ["inserter"] = { inserter_pickup_position = { 0, -1 }, inserter_drop_position = { 0, 1.2 } },
          ["mod-reach-inserter"] = { inserter_pickup_position = { x = 0, y = -4 }, inserter_drop_position = { x = 0, y = 4.2 } },
        }
      end
      local a = furnace({ x = 5.5, y = 0.5 })
      local free = furnace({ x = 15.5, y = 0.5 })
      local other = C.chest({ x = 30.5, y = 30.5 }, {})
      S.nauvis.create_entity{ name = "mod-reach-inserter", type = "inserter", position = { x = 5.5, y = 5.5 },
        force = "player", fields = { type = "inserter", pickup_target = other, drop_target = a.e } }
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 4 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ a.smelted, free.smelted }, { 0, 4 })
  end },
  { "плавка: срок вышел — недоплавленное возвращается без руды хозяина, подложенной в ту же печь", function()
      local W = prepare{ items = { ["iron-ore"] = 4, coal = 2 } }
      local f = furnace({ x = 5.5, y = 0.5 })
      local job = get{ items = { ["iron-plate"] = 4 } }
      local guard = 0
      while f.smelted < 1 and guard < 600 do C.run(1); guard = guard + 1 end
      S.eq(f.smelted, 1, "одна плита выплавлена")
      f.src.insert{ name = "iron-ore", count = 10 }          -- руда хозяина
      f.fuel.remove{ name = "coal", count = 99 }             -- топливо кончилось: печь встала
      f.fuel_left = 0
      local d = C.wait(job)
      S.eq(f.src.get_item_count("iron-ore"), 10, "руда хозяина осталась: " .. S.dump(d))
      S.eq(C.counts(W.main)["iron-ore"], 3, "вернули ровно недоплавленное")
      S.eq(C.counts(W.main)["iron-plate"], 1)
  end },
  { "плавка: печь занята другим помощником не берётся; своя бронь держится на время и снимается", function()
      local W = prepare{ items = { ["iron-ore"] = 4, coal = 2 } }
      local theirs = furnace({ x = 5.5, y = 0.5 })
      local mine = furnace({ x = 9.5, y = 0.5 })
      storage.reservations.machines = { [theirs.e.unit_number] = "h2" }
      local job = get{ items = { ["iron-plate"] = 4 } }
      C.run(40)
      S.eq(storage.reservations.machines[mine.e.unit_number], "h1", "печь занята помощником")
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ theirs.smelted, mine.smelted }, { 0, 4 })
      S.eq(storage.reservations.machines[mine.e.unit_number], nil, "бронь снята")
      S.eq(storage.reservations.machines[theirs.e.unit_number], "h2", "чужая бронь цела")
  end },
  { "плавка: бронь печи снимается и при отмене", function()
      prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      local f = furnace({ x = 3.5, y = 0.5 })
      local job = get{ items = { ["iron-plate"] = 10 } }
      C.run(60)
      S.eq(storage.reservations.machines[f.e.unit_number], "h1")
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(storage.reservations.machines[f.e.unit_number], nil)
  end },
  { "плавка: из выхода забирает только свою долю, чужое остаётся", function()
      local W = prepare{ items = { ["iron-ore"] = 6, coal = 2 } }
      local f = furnace({ x = 8.5, y = 0.5 })
      local job = get{ items = { ["iron-plate"] = 6 } }
      C.run(60)
      f.res.insert{ name = "iron-plate", count = 5 }
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(C.counts(W.main)["iron-plate"], 6)
      S.eq(f.res.get_item_count("iron-plate"), 5, "чужие плиты на месте")
  end },
  { "сохранение посреди плавки: в storage нет функций, задача доделывается", function()
      local W = prepare{ items = { ["iron-ore"] = 6, coal = 2 } }
      furnace({ x = 8.5, y = 0.5 })
      local job = get{ items = { ["iron-plate"] = 6 } }
      C.run(200)
      S.reload()
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(C.counts(W.main)["iron-plate"], 6)
  end },
  { "сохранение посреди крафта: в storage нет функций, задача доделывается", function()
      local W = prepare{ items = { ["iron-plate"] = 12 } }
      local job = get{ items = { ["gear-box"] = 2 } }
      C.run(3)
      S.reload()
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["gear-box"] = 2 })
  end },
  { "много альтернативных рецептов и глубокое дерево: план строится быстро", function()
      prepare()
      local R = game.forces.player.recipes
      for k = 1, 10 do
        for j = 1, 6 do
          local name = "chain" .. k .. "-v" .. j
          R[name] = { name = name, enabled = true, hidden = false, category = "crafting", energy = 0.5, valid = true,
            ingredients = { { type = "item", name = "chain" .. (k - 1), amount = 2 } },
            products = { { type = "item", name = "chain" .. k, amount = 1 } } }
        end
      end
      for k = 0, 10 do prototypes.item["chain" .. k] = { name = "chain" .. k, type = "item", stack_size = 50 } end
      local t0 = os.clock()
      local d, kind = C.wait(get{ items = { chain10 = 1 } })
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.ok(d.detail.shortfall[1].reason ~= nil, S.dump(d))
      S.ok(os.clock() - t0 < 5, "план строился слишком долго: " .. (os.clock() - t0))
  end },
  { "лимит вызовов плана: причина too_complex в shortfall", function()
      prepare()
      local G = require("scripts.lib.getitems")
      local R = game.forces.player.recipes
      for k = 1, 5 do
        local name = "wide" .. k
        R[name] = { name = name, enabled = true, hidden = false, category = "crafting", energy = 0.5, valid = true,
          ingredients = { { type = "item", name = "wide" .. (k - 1), amount = 1 } },
          products = { { type = "item", name = "wide" .. k, amount = 1 } } }
      end
      for k = 0, 5 do prototypes.item["wide" .. k] = { name = "wide" .. k, type = "item", stack_size = 50 } end
      local old = G.MAX_CALLS
      G.MAX_CALLS = 0
      local d = C.wait(get{ items = { wide5 = 1 } })
      G.MAX_CALLS = old
      S.eq(d.detail.shortfall[1].reason, "too_complex", S.dump(d))
  end },
  { "перебор рецептов не копирует склад: записей журнала не зависит от размера склада", function()
      local function run_plan(junk)
        local W = prepare()
        local R = game.forces.player.recipes
        for k = 1, 6 do
          for j = 1, 4 do
            local name = "chain" .. k .. "-v" .. j
            R[name] = { name = name, enabled = true, hidden = false, category = "crafting", energy = 0.5, valid = true,
              ingredients = { { type = "item", name = "chain" .. (k - 1), amount = 2 } },
              products = { { type = "item", name = "chain" .. k, amount = 1 } } }
          end
        end
        for k = 0, 6 do prototypes.item["chain" .. k] = { name = "chain" .. k, type = "item", stack_size = 50 } end
        local items = {}
        for k = 1, junk do
          prototypes.item["junk" .. k] = { name = "junk" .. k, type = "item", stack_size = 50 }
          items["junk" .. k] = 1
        end
        C.chest({ x = 6.5, y = 0.5 }, items, { size = junk + 1 })
        local G = require("scripts.lib.getitems")
        G.stats.journal = 0
        local d, kind = C.wait(get{ items = { chain6 = 1 } })
        S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
        return G.stats.journal
      end
      local small = run_plan(5)
      local big = run_plan(400)
      S.ok(small > 0, "журнал работал")
      -- склад в 80 раз больше, а работы перебора столько же: полной копии нет
      S.eq(big, small, "журнал " .. small .. " против " .. big)
  end },
  { "плавка несколькими печами сразу", function()
      local W = prepare{ items = { ["iron-ore"] = 20, coal = 4 } }
      local a, b = furnace({ x = 6.5, y = 0.5 }), furnace({ x = 6.5, y = 4.5 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 20 } })
      S.eq(kind, "job_done", S.dump(d))
      S.ok(a.smelted > 0 and b.smelted > 0, "обе печи работали: " .. a.smelted .. "/" .. b.smelted)
      S.eq(a.smelted + b.smelted, 20)
  end },
  { "печи нет — shortfall no_furnace; нет ничего — failed no_items", function()
      local W = prepare{ items = { ["iron-ore"] = 10 } }
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 5 } })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(d.detail.shortfall, { { item = "iron-plate", missing = 5, reason = "no_furnace" } })
      S.eq(C.counts(W.main), { ["iron-ore"] = 10 })
  end },
  { "печь чужой силы, невидимая и далёкая не годятся", function()
      local W = prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      furnace({ x = 5.5, y = 0.5 }, { force = "enemy" })
      furnace({ x = 100.5, y = 0.5 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 5 } })
      S.eq(d.detail.shortfall[1].reason, "no_furnace", S.dump(d))
      S.eq(C.wait(get{ items = { ["iron-plate"] = 2 }, radius = 128 }).detail.have, { ["iron-plate"] = 2 })
  end },
  { "печь без топлива и топлива нет в карманах — no_fuel", function()
      local W = prepare{ items = { ["iron-ore"] = 10 } }
      furnace({ x = 5.5, y = 0.5 })
      local d = C.wait(get{ items = { ["iron-plate"] = 5 } })
      S.eq(d.detail.shortfall[1].reason, "no_fuel", S.dump(d))
  end },
  { "руками: руду копает, плавит и забирает плиты", function()
      local W = prepare{ items = { coal = 1 } }
      C.resource("iron-ore", { x = 4.5, y = 0.5 }, 100)
      furnace({ x = 8.5, y = 3.5 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 3 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["iron-plate"] = 3 })
      S.eq(d.detail.from, { mined = { ["iron-ore"] = 3 }, smelted = { ["iron-plate"] = 3 } })
      S.eq(C.counts(W.main)["iron-plate"], 3)
  end },
  { "своя печь рядом, малый радиус, топливо копать далеко: после добычи печь та же, плиты выплавлены", function()
      local W = prepare{ items = { ["iron-ore"] = 5 } }
      prototypes.item.coal.type = "item"
      C.resource("coal", { x = 40.5, y = 0.5 }, 100)
      local f = furnace({ x = 3.5, y = 0.5 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 5 }, radius = 4 })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["iron-plate"] = 5 })
      S.ok(d.detail.from.mined and (d.detail.from.mined.coal or 0) > 0, "топливо добыто: " .. S.dump(d))
      S.eq(d.detail.from.smelted, { ["iron-plate"] = 5 })
      S.eq(f.smelted, 5)
  end },
  { "руками: камень", function()
      local W = prepare()
      C.resource("stone", { x = 4.5, y = 0.5 }, 100)
      local d, kind = C.wait(get{ items = { stone = 4 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.from, { mined = { stone = 4 } })
  end },
  { "нечего копать — shortfall not_found; предмета, который рукой не добыть — no_source", function()
      prepare()
      local d, kind = C.wait(get{ items = { ["iron-ore"] = 5 } })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(d.detail.shortfall, { { item = "iron-ore", missing = 5, reason = "not_found" } })
      local d2 = C.wait(get{ items = { ["electric-mining-drill"] = 1 } })
      S.eq(d2.detail.shortfall[1].reason, "no_source", S.dump(d2))
  end },
  { "часть есть — done с shortfall; взятое сохраняется", function()
      local W = prepare()
      C.chest({ x = 5.5, y = 0.5 }, { ["iron-plate"] = 3 })
      local d, kind = C.wait(get{ items = { ["iron-plate"] = 10 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["iron-plate"] = 3 })
      S.eq(d.detail.shortfall, { { item = "iron-plate", missing = 7, reason = "no_furnace" } })
      S.eq(d.detail.from, { storage = { ["iron-plate"] = 3 } })
  end },
  { "склады: чужая сила, невидимый чанк и чужой резерв не берутся", function()
      local W = prepare()
      C.chest({ x = 5.5, y = 0.5 }, { coal = 10 }, { force = "enemy" })
      C.chest({ x = 40.5, y = 0.5 }, { coal = 10 })
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      C.chest({ x = 10.5, y = 5.5 }, { coal = 10 })
      storage.reservations.items.h2 = { coal = 8 }
      local d = C.wait(get{ items = { coal = 5 } })
      S.eq(d.detail.have, { coal = 2 }, S.dump(d))
      S.eq(d.detail.shortfall[1].missing, 3)
  end },
  { "аргументы: пустой items, неизвестный предмет, radius вне 1..128", function()
      prepare()
      S.err(C.act("get_items", {}), "bad_args")
      S.err(C.act("get_items", { items = {} }), "bad_args")
      S.err(C.act("get_items", { items = { coal = 1 }, radius = 200 }), "limit")
      S.eq(C.wait(get{ items = { nope = 1 } }).code, "bad_args")
  end },
  { "отмена во время плавки: задача снята, тело свободно", function()
      local W = prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      furnace({ x = 3.5, y = 0.5 })
      local job = get{ items = { ["iron-plate"] = 10 } }
      C.run(120)
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(C.result(job).code, "cancelled")
  end },
  { "прогресс: job_progress с done/total по запрошенному", function()
      prepare{ items = { ["iron-ore"] = 10, coal = 2 } }
      furnace({ x = 3.5, y = 0.5 })
      local job = get{ items = { ["iron-plate"] = 10 } }
      local d = C.wait(job)
      S.eq(d.detail.have, { ["iron-plate"] = 10 })
      S.ok(#C.events("job_progress") >= 1, "есть job_progress")
  end },
  { "auto_supply у insert: недостающее берёт со склада, потом кладёт", function()
      local W = prepare{ items = { ["iron-plate"] = 4 } }
      C.chest({ x = 6.5, y = 0.5 }, { ["iron-plate"] = 30 })
      local target = C.chest({ x = -6.5, y = 0.5 }, {})
      local job = S.okr(C.act("insert", { target = { unit_number = target.unit_number },
        items = { ["iron-plate"] = 20 }, auto_supply = true })).job
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.inserted, { ["iron-plate"] = 20 })
      S.eq(C.counts(chest_inv(target)), { ["iron-plate"] = 20 })
      S.eq(C.counts(W.main), {}, "карманы потрачены")
  end },
  { "auto_supply у insert: добыто не всё — итоговый no_items несёт detail.supply", function()
      local W = prepare{ items = { ["iron-plate"] = 4 } }
      C.chest({ x = 6.5, y = 0.5 }, { ["iron-plate"] = 6 })
      local target = C.chest({ x = -6.5, y = 0.5 }, {})
      local job = S.okr(C.act("insert", { target = { unit_number = target.unit_number },
        items = { ["iron-plate"] = 20 }, auto_supply = true })).job
      local d, kind = C.wait(job)
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.eq(d.detail.missing, { ["iron-plate"] = 10 })
      S.ok(d.detail.supply and d.detail.supply.shortfall, S.dump(d))
  end },
})
