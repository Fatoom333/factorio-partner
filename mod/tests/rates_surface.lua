-- op `rates`, scope="surface" (STATE.md «rates»).
local L = require("stubs_l")
local rates = require("scripts.perception.rates")
local op = rates.ops.rates
local FPI = defines.flow_precision_index

-- Мир: nauvis и vulcanus; на vulcanus статистика по всем периодам.
local function world(opts)
  opts = opts or {}
  local nauvis = L.surface { name = "nauvis" }
  local vulcanus = L.surface { name = "vulcanus", index = 2 }
  local istats = L.stats {
    input_counts = { ["iron-plate"] = 5000, ["copper-plate"] = 10, ["stone"] = 3, ["gear"] = 1 },
    output_counts = { ["iron-plate"] = 4000, ["coal"] = 700 },
    flows = {
      [FPI.one_minute] = {
        input = { ["iron-plate"] = 1200, ["copper-plate"] = 60, ["stone"] = 0, ["gear"] = 0.333 },
        output = { ["iron-plate"] = 950, ["coal"] = 300 },
      },
      [FPI.ten_minutes] = { input = { ["iron-plate"] = 12000 }, output = { ["iron-plate"] = 9000 } },
      [FPI.one_hour] = { input = { ["iron-plate"] = 70000 }, output = {} },
    },
    throw_on = opts.throw_on,
  }
  local fstats = L.stats {
    input_counts = { water = 1 }, output_counts = { water = 1, steam = 1 },
    flows = { [FPI.one_minute] = { input = { water = 36000 }, output = { water = 35000, steam = 0 } } },
  }
  local force = L.force {
    item_stats = { vulcanus = istats }, fluid_stats = { vulcanus = fstats },
  }
  local helper = L.character(force, vulcanus, { x = 10, y = 10 })
  L.install {
    surfaces = { nauvis, vulcanus }, forces = { player = force },
    items = { "iron-plate", "copper-plate", "stone", "gear", "coal" }, fluids = { "water", "steam" },
    players = opts.players or {},
    owner = opts.owner,
  }
  return { force = force, helper = helper, istats = istats, fstats = fstats, nauvis = nauvis, vulcanus = vulcanus }
end

L.case("поверхность помощника, 1m: произведено = input, потреблено = output", function()
  local w = world()
  local d = op({ scope = "surface", period = "1m" }, { helper_id = "h1", entity = w.helper })
  L.plain(d)
  L.eq(d.scope, "surface"); L.eq(d.surface, "vulcanus"); L.eq(d.period, "1m")
  L.eq(d.items["iron-plate"].made, 1200, "iron made")
  L.eq(d.items["iron-plate"].used, 950, "iron used")
  L.eq(d.items["coal"].made, 0); L.eq(d.items["coal"].used, 300)
  L.eq(d.items["copper-plate"].made, 60)
  L.eq(d.items["gear"].made, 0.33, "округление до 0.01")
  L.eq(d.items["stone"], nil, "нули не выводятся")
  L.eq(d.fluids.water.made, 36000); L.eq(d.fluids.water.used, 35000)
  L.eq(d.fluids.steam, nil)
  L.eq(d.truncated, false)
end)

L.case("get_flow_count вызывается с count=true, верной точностью и категориями", function()
  local w = world()
  op({ scope = "surface", period = "10m" }, { helper_id = "h1", entity = w.helper })
  local cats = {}
  for _, c in ipairs(w.istats.calls) do
    L.eq(c.count, true, "count")
    L.eq(c.precision_index, FPI.ten_minutes, "precision")
    L.eq(type(c.name), "string", "имя-строка = качество normal")
    cats[c.category] = true
  end
  L.eq(cats.input, true); L.eq(cats.output, true)
  L.eq(L.count(cats), 2)
end)

L.case("периоды 10m и 1h", function()
  local w = world()
  local d = op({ scope = "surface", period = "10m" }, { helper_id = "h1", entity = w.helper })
  L.eq(d.items["iron-plate"].made, 12000); L.eq(d.items["iron-plate"].used, 9000)
  d = op({ scope = "surface", period = "1h" }, { helper_id = "h1", entity = w.helper })
  L.eq(d.items["iron-plate"].made, 70000); L.eq(d.items["iron-plate"].used, 0)
  L.eq(d.period, "1h")
end)

L.case("top режет по обороту и ставит truncated", function()
  local w = world()
  local d = op({ scope = "surface", period = "1m", top = 2 }, { helper_id = "h1", entity = w.helper })
  L.eq(L.count(d.items), 2)
  L.eq(d.items["iron-plate"] ~= nil, true, "самый большой оборот")
  L.eq(d.items["coal"] ~= nil, true, "второй по обороту (300)")
  L.eq(d.items["copper-plate"], nil)
  L.eq(d.truncated, true)
end)

L.case("items: только заданные, включая нулевые, и жидкости", function()
  local w = world()
  local d = op({ scope = "surface", period = "1m", items = { "stone", "water", "iron-plate" }, top = 1 },
    { helper_id = "h1", entity = w.helper })
  L.plain(d)
  L.eq(L.count(d.items), 2)
  L.eq(d.items.stone.made, 0); L.eq(d.items.stone.used, 0)
  L.eq(d.items["iron-plate"].made, 1200)
  L.eq(d.fluids.water.made, 36000)
  L.eq(d.truncated, false)
end)

L.case("items: неизвестное имя -> bad_args", function()
  local w = world()
  L.raises("bad_args", function()
    op({ scope = "surface", period = "1m", items = { "unobtainium" } }, { helper_id = "h1", entity = w.helper })
  end)
end)

L.case("surface в аргументах перекрывает поверхность помощника", function()
  local w = world()
  local d = op({ scope = "surface", period = "1m", surface = "nauvis" }, { helper_id = "h1", entity = w.helper })
  L.eq(d.surface, "nauvis")
  L.eq(L.count(d.items), 0)
  L.eq(w.force.stats_calls[1].surface, "nauvis")
end)

L.case("неизвестная поверхность -> not_found", function()
  local w = world()
  L.raises("not_found", function()
    op({ scope = "surface", period = "1m", surface = "fulgora" }, { helper_id = "h1", entity = w.helper })
  end)
end)

L.case("без помощника: поверхность хозяина (индекс 1)", function()
  local tmp = world()
  local owner = L.player { name = "Tartaluga", force = tmp.force, surface = tmp.vulcanus, character = {} }
  local w = world { players = { [1] = owner, Tartaluga = owner } }
  owner.force = w.force; owner.physical_surface = w.vulcanus
  local d = op({ period = "1m" }, {})
  L.eq(d.scope, "surface", "scope по умолчанию")
  L.eq(d.surface, "vulcanus")
  L.eq(d.items["iron-plate"].made, 1200)
end)

L.case("хозяин из настройки partner-owner", function()
  local w0 = world()
  local other = L.player { name = "Bob", force = w0.force, surface = w0.nauvis, character = {} }
  local boss = L.player { name = "Boss", force = w0.force, surface = w0.vulcanus, character = {} }
  local w = world { players = { [1] = other, Bob = other, Boss = boss }, owner = "Boss" }
  boss.force = w.force; boss.physical_surface = w.vulcanus
  other.force = w.force; other.physical_surface = w.nauvis
  local d = op({ scope = "surface", period = "1m" }, nil)
  L.eq(d.surface, "vulcanus")
end)

L.case("без помощника и хозяина офлайн: no_player; с surface — сила player", function()
  local w0 = world()
  local off = L.player { name = "Tartaluga", connected = false, force = w0.force, surface = w0.vulcanus, character = {} }
  world { players = { [1] = off } }
  L.raises("no_player", function() op({ scope = "surface", period = "1m" }, {}) end)
  local d = op({ scope = "surface", period = "1m", surface = "vulcanus" }, {})
  L.eq(d.items["iron-plate"].made, 1200)
end)

L.case("невалидный помощник не используется", function()
  local w = world()
  w.helper.valid = false
  L.raises("no_player", function() op({ scope = "surface", period = "1m" }, { helper_id = "h1", entity = w.helper }) end)
end)

L.case("ошибка get_flow_count не прячется за пустым ответом: internal", function()
  local w = world { throw_on = { ["copper-plate"] = true } }
  local text = L.raises("internal", function()
    op({ scope = "surface", period = "1m" }, { helper_id = "h1", entity = w.helper })
  end)
  L.eq(text:find("copper-plate", 1, true) ~= nil, true, "в тексте имя")
end)

L.case("не-числовой ответ get_flow_count — internal", function()
  local w = world()
  w.istats.get_flow_count = function() return nil end
  L.raises("internal", function()
    op({ scope = "surface", period = "1m" }, { helper_id = "h1", entity = w.helper })
  end)
end)

L.case("сортировка стабильна при равном обороте (по имени)", function()
  local s = L.surface { name = "s" }
  local st = L.stats {
    input_counts = { b = 1, a = 1, c = 1 },
    flows = { [FPI.one_minute] = { input = { a = 5, b = 5, c = 5 }, output = {} } },
  }
  local f = L.force { item_stats = { s = st } }
  L.install { surfaces = { s }, forces = { player = f }, items = { "a", "b", "c" } }
  local d = op({ scope = "surface", period = "1m", top = 2 }, { entity = L.character(f, s) })
  L.eq(d.items.a ~= nil and d.items.b ~= nil and d.items.c == nil, true)
end)

L.finish("rates_surface")
