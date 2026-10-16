-- Рефлекс upkeep — заправка машин на горелках и наука в лабораториях. Выключен по умолчанию;
-- только предметы normal и только своя сила; живое — только у видимых машин.
local S = require("stubs")
local C = require("stubs_c")

local FUEL = { coal = 4000000, wood = 2000000, ["solid-fuel"] = 12000000 }

local function setup(items)
  local W = C.setup()
  for name, value in pairs(FUEL) do
    prototypes.item[name] = { name = name, type = "item", stack_size = 50, fuel_value = value, fuel_category = "chemical" }
  end
  prototypes.item["nuclear-fuel"] = { name = "nuclear-fuel", type = "item", stack_size = 1, fuel_value = 1e9, fuel_category = "nuclear" }
  prototypes.item["automation-science-pack"] = { name = "automation-science-pack", type = "tool", stack_size = 200 }
  prototypes.item["logistic-science-pack"] = { name = "logistic-science-pack", type = "tool", stack_size = 200 }
  prototypes.entity["stone-furnace"] = { name = "stone-furnace", type = "furnace" }
  prototypes.entity["nuclear-reactor"] = { name = "nuclear-reactor", type = "reactor" }
  prototypes.entity["lab"] = { name = "lab", type = "lab" }
  defines.inventory.lab_input = defines.inventory.lab_input or 20
  for name, n in pairs(items or {}) do W.main.insert{ name = name, count = n } end
  return W
end

-- Топливный инвентарь берёт только предметы с топливной категорией chemical.
local function fuel_inventory(n)
  local binv = C.inventory{ size = 1, items = n and n > 0 and { coal = n } or {} }
  rawset(binv, "can_insert", function(st)
    local p = prototypes.item[st.name]
    return p ~= nil and p.fuel_category == "chemical" and binv.get_item_count() < 50
  end)
  return binv
end

local function furnace(x, y, n, o)
  o = o or {}
  local binv = fuel_inventory(n)
  local e = S.nauvis.create_entity{
    name = o.name or "stone-furnace", position = { x = x, y = y }, force = o.force or "player", raise_built = true,
    fields = { burner = { inventory = binv, fuel_categories = o.cats or { chemical = true } } },
  }
  return e, binv
end

local function lab(x, y, n, can)
  local linv = C.inventory{ size = 4, items = n and n > 0 and { ["automation-science-pack"] = n } or {} }
  rawset(linv, "can_insert", function(st) return can ~= false and st.name:find("science") ~= nil end)
  local e = S.nauvis.create_entity{ name = "lab", position = { x = x, y = y }, force = "player", raise_built = true }
  e.inventories = { [defines.inventory.lab_input] = linv }
  return e, linv
end

local function research(...)
  local list = {}
  for _, name in ipairs { ... } do list[#list + 1] = { name = name, amount = 1 } end
  game.forces.player.current_research = { research_unit_ingredients = list }
end

local function set(list) return S.okr(S.req("reflexes", { set = list }, "h1")).set end

local function fired()
  local out = {}
  for _, e in ipairs(C.events("reflex_fired")) do
    if e.data.type == "upkeep" then out[#out + 1] = e end
  end
  return out
end

S.suite("reflex_upkeep", {
  { "стоп хозяина: ни прямой подачи, ни insert, ни collect; после снятия работает", function()
      local W = setup({ coal = 50 })
      local _, near = furnace(6, 0, 0)
      local _, far = furnace(7, 30, 0)
      storage.owner_hold = { h1 = { kind = "stop", tick = 0, seq = 1 } }
      set{ { type = "upkeep", min = 2, fill = 10 } }
      C.run(300)
      S.eq(near.get_item_count(), 0)
      S.eq(far.get_item_count(), 0)
      S.eq(W.main.get_item_count("coal"), 50)
      S.eq(#fired(), 0)
      S.eq(#W.path.calls, 0, "задач не ставил")
      storage.owner_hold = nil
      C.run(200)
      S.ok(near.get_item_count() > 0, "после снятия кладёт")
  end },

  { "выключен по умолчанию: без слова хозяина машина с пустым топливом не трогается", function()
      local W = setup({ coal = 50 })
      local _, binv = furnace(6, 0, 0)
      lab(4, 3, 0)
      research("automation-science-pack")
      C.run(300)
      S.eq(binv.get_item_count(), 0)
      S.eq(W.main.get_item_count("coal"), 50)
      S.eq(#fired(), 0)
  end },

  { "заправка в досягаемости: топливо из рук до fill, шумное reflex_fired, по одной машине за проверку", function()
      local W = setup({ coal = 50 })
      local _, a = furnace(6, 0, 0)
      local _, b = furnace(7, 2, 0)
      set{ { type = "upkeep", min = 2, fill = 10 } }
      C.run(40)
      S.eq(a.get_item_count() + b.get_item_count(), 10, "за первую проверку — одна машина")
      C.run(200)
      S.eq(a.get_item_count(), 10)
      S.eq(b.get_item_count(), 10)
      S.eq(W.main.get_item_count("coal"), 30)
      local f = fired()
      S.eq(#f, 2)
      S.eq(f[1].loud, false)
      S.eq(f[1].data.detail.kind, "fuel")
      S.eq(f[1].data.detail.item, "coal")
      S.eq(f[1].data.detail.count, 10)
      S.eq(#W.path.calls, 0, "без ходьбы")
  end },

  { "у кого топлива хватает (≥ min) — не трогается; добирает до fill", function()
      local W = setup({ coal = 50 })
      local _, full = furnace(6, 0, 2)
      local _, low = furnace(7, 2, 1)
      set{ { type = "upkeep", min = 2, fill = 5 } }
      C.run(200)
      S.eq(full.get_item_count(), 2)
      S.eq(low.get_item_count(), 5)
      S.eq(W.main.get_item_count("coal"), 46)
  end },

  { "какое топливо: наименьшая теплота из принимаемых; чужая категория не берётся; fuel — только он", function()
      local W = setup({ coal = 20, wood = 20, ["solid-fuel"] = 20, ["nuclear-fuel"] = 1 })
      local _, a = furnace(6, 0, 0)
      set{ { type = "upkeep", fill = 4 } }
      C.run(100)
      S.eq(a.get_item_count("wood"), 4, "wood дешевле coal и solid-fuel")
      S.eq(W.main.get_item_count("nuclear-fuel"), 1)
      local W2 = setup({ coal = 20, wood = 20 })
      local _, b = furnace(6, 0, 0)
      set{ { type = "upkeep", fill = 4, fuel = "coal" } }
      C.run(100)
      S.eq(b.get_item_count("coal"), 4)
      S.eq(W2.main.get_item_count("wood"), 20)
  end },

  { "реактор не заправляется", function()
      local W = setup({ coal = 20 })
      local _, r = furnace(6, 0, 0, { name = "nuclear-reactor" })
      set{ { type = "upkeep" } }
      C.run(100)
      S.eq(r.get_item_count(), 0)
      S.eq(W.main.get_item_count("coal"), 20)
  end },

  { "только normal: топливо другого качества в инвентаре не используется", function()
      local W = setup()
      W.main.insert{ name = "coal", count = 20, quality = "rare" }
      local _, a = furnace(6, 0, 0)
      set{ { type = "upkeep", chests = false } }
      C.run(200)
      S.eq(a.get_item_count(), 0)
      S.eq(W.main.get_item_count{ name = "coal", quality = "rare" }, 20)
  end },

  { "чужая сила не заправляется", function()
      local W = setup({ coal = 20 })
      local _, a = furnace(6, 0, 0, { force = "enemy" })
      set{ { type = "upkeep" } }
      C.run(200)
      S.eq(a.get_item_count(), 0)
      S.eq(W.main.get_item_count("coal"), 20)
  end },

  { "далеко и очередь пуста: сам ставит insert, подходит и заправляет", function()
      local W = setup({ coal = 30 })
      local _, a = furnace(24, 0, 0)
      set{ { type = "upkeep", fill = 6 } }
      for _ = 1, 3000 do
        C.run(1)
        if a.get_item_count() >= 6 then break end
      end
      S.eq(a.get_item_count(), 6)
      S.ok(#W.path.calls > 0, "подходил")
      S.eq(W.main.get_item_count("coal"), 24)
  end },

  { "очередь занята — дальнюю машину не обслуживает, ближнюю в досягаемости — да", function()
      local W = setup({ coal = 30 })
      local _, far = furnace(24, 0, 0)
      local _, near = furnace(6, 0, 0)
      C.act("wait", { seconds = 600 })
      set{ { type = "upkeep", fill = 6 } }
      C.run(300)
      S.eq(near.get_item_count(), 6)
      S.eq(far.get_item_count(), 0)
      S.eq(#W.path.calls, 0)
  end },

  { "в невидимом чанке дальше 32 клеток машина пропускается", function()
      local W = setup({ coal = 30 })
      local _, a = furnace(60, 0, 0)
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      set{ { type = "upkeep", radius = 96 } }
      C.run(200)
      S.eq(a.get_item_count(), 0)
      S.eq(#W.path.calls, 0)
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = nil
      C.run(2500)
      S.eq(a.get_item_count(), 10, "стала видна — заправлена")
  end },

  { "нет топлива в руках: берёт со складов (collect), потом заправляет; chests=false — не берёт", function()
      local W = setup()
      local ch = C.chest({ x = 5, y = 4 }, { coal = 40 })
      local _, a = furnace(6, 0, 0)
      set{ { type = "upkeep", fill = 5, chests = false } }
      C.run(200)
      S.eq(a.get_item_count(), 0)
      S.eq(W.main.get_item_count("coal"), 0)
      set{ { type = "upkeep", fill = 5 } }
      for _ = 1, 3000 do
        C.run(1)
        if a.get_item_count() >= 5 then break end
      end
      S.eq(a.get_item_count(), 5)
      S.ok(C.counts(ch.inventories[defines.inventory.chest]).coal < 40, "взято со склада")
  end },

  { "наука: недостающее до packs из рук; у кого хватает — не трогается; без исследования — не кормит", function()
      local W = setup({ ["automation-science-pack"] = 30, ["logistic-science-pack"] = 30 })
      local _, empty = lab(4, 3, 0)
      local _, enough = lab(4, -3, 6)
      set{ { type = "upkeep", packs = 10 } }
      C.run(300)
      S.eq(empty.get_item_count("automation-science-pack"), 0, "исследования нет — лаборатории не кормятся")
      research("automation-science-pack")
      C.run(300)
      S.eq(empty.get_item_count("automation-science-pack"), 10)
      S.eq(enough.get_item_count("automation-science-pack"), 6, "6 ≥ половины packs")
      S.eq(W.main.get_item_count("logistic-science-pack"), 30, "пакеты не из исследования не носит")
      S.eq(W.main.get_item_count("automation-science-pack"), 20)
      local f = fired()
      S.eq(f[1].data.detail.kind, "science")
      S.eq(f[1].data.detail.item, "automation-science-pack")
  end },

  { "наука: лаборатория, не принимающая пакет, пропускается; science=false выключает", function()
      setup({ ["automation-science-pack"] = 30 })
      local _, no = lab(4, 3, 0, false)
      research("automation-science-pack")
      set{ { type = "upkeep" } }
      C.run(300)
      S.eq(no.get_item_count("automation-science-pack"), 0)
      local _, yes = lab(4, -3, 0)
      set{ { type = "upkeep", science = false } }
      C.run(300)
      S.eq(yes.get_item_count("automation-science-pack"), 0)
      set{ { type = "upkeep" } }
      C.run(300)
      S.eq(yes.get_item_count("automation-science-pack"), 10)
  end },

  { "во время отступления молчит", function()
      local W = setup({ coal = 20 })
      local _, a = furnace(6, 0, 0)
      set{ { type = "upkeep" } }
      storage.reflex_state = { h1 = { unit = W.h.unit_number, flee = { job = 1 } } }
      C.run(200)
      S.eq(a.get_item_count(), 0)
      storage.reflex_state.h1.flee = nil
      C.run(200)
      S.eq(a.get_item_count(), 10)
  end },

  { "схема набора: границы и умолчания", function()
      setup()
      S.eq(set{ { type = "upkeep" } }, { { type = "upkeep", radius = 96, min = 2, fill = 10, packs = 10, science = true, chests = true } })
      S.err(S.req("reflexes", { set = { { type = "upkeep", radius = 97 } } }, "h1"), "limit")
      S.err(S.req("reflexes", { set = { { type = "upkeep", min = 0 } } }, "h1"), "bad_args")
      S.err(S.req("reflexes", { set = { { type = "upkeep", nope = 1 } } }, "h1"), "bad_args")
  end },
})
