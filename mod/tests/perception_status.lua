-- Операция `status`: «что стоит и почему». Контракт: docs/STATE.md «status»,
-- PROTOCOL §6.7 (статус машины — живое, только видимое), §6.11.
local S = require("stubs")

local STATUSES = {
  working = 1, normal = 2, no_power = 3, low_power = 4, no_fuel = 5, no_ingredients = 6, no_recipe = 7,
  full_output = 8, waiting_for_space_in_destination = 9, no_minable_resources = 10, disabled = 11,
  marked_for_deconstruction = 12, missing_science_packs = 13, brand_new_status = 14,
  no_research_in_progress = 15, waiting_to_launch_rocket = 16, launching_rocket = 17,
}

local function setup()
  S.load_mod()
  for k, v in pairs(STATUSES) do defines.entity_status[k] = v end
  for name, t in pairs {
    ["assembling-machine-1"] = "assembling-machine", ["stone-furnace"] = "furnace", ["lab"] = "lab",
    ["electric-mining-drill"] = "mining-drill", ["steel-chest"] = "container",
  } do
    prototypes.entity[name] = { name = name, type = t }
  end
  S.add_player{ name = "Tartaluga", position = { x = 0, y = 0 } }
  S.okr(S.req("helper_spawn", {}, "h1"))
  return storage.helpers.h1.entity
end

local function machine(name, x, y, status, recipe, o)
  o = o or {}
  local fields = { status = status and defines.entity_status[status] or nil }
  if recipe then fields.get_recipe = function() return { name = recipe } end end
  return S.nauvis.create_entity{
    name = name, position = { x = x, y = y }, force = o.force or "player", raise_built = true, fields = fields,
  }
end

local function status(args) return S.okr(S.req("status", args or {}, "h1")) end

S.suite("perception_status", {
  { "работающие считаются, остановившиеся — группами «имя + причина», по разряду причины", function()
      setup()
      machine("assembling-machine-1", 10, 0, "working", "iron-gear-wheel")
      machine("assembling-machine-1", 12, 0, "normal", "iron-gear-wheel")
      machine("assembling-machine-1", 14, 0, "no_power", "iron-gear-wheel")
      machine("assembling-machine-1", 16, 0, "no_power", "iron-gear-wheel")
      machine("assembling-machine-1", 30, 0, "no_power", "copper-cable")
      machine("stone-furnace", 8, 0, "no_fuel", "iron-plate")
      machine("assembling-machine-1", 20, 0, "full_output", "iron-gear-wheel")
      machine("assembling-machine-1", 22, 0, "no_ingredients", "iron-gear-wheel")
      machine("assembling-machine-1", 24, 0, "no_recipe")
      machine("electric-mining-drill", 26, 0, "no_minable_resources")
      machine("lab", 28, 0, "marked_for_deconstruction")
      local d = status()
      S.eq(d.surface, "nauvis")
      S.eq(d.machines, { seen = 11, running = 2, stopped = 8, hidden = 0, ignored = 1 })
      S.eq(d.causes, { power = 3, fuel = 1, output = 1, input = 1, recipe = 1, resource = 1 })
      S.eq(d.index_ready, false, "раскрутка не закончена — это видно в ответе")
      S.eq(d.truncated, nil)
      -- порядок: power (по числу машин, ближние первыми), fuel, resource, input, output, recipe
      local order = {}
      for _, r in ipairs(d.stopped) do order[#order + 1] = r.cause .. ":" .. r.reason .. ":" .. (r.recipe or "-") end
      S.eq(order, {
        "power:no_power:iron-gear-wheel", "power:no_power:copper-cable", "fuel:no_fuel:iron-plate",
        "resource:no_minable_resources:-", "input:no_ingredients:iron-gear-wheel",
        "output:full_output:iron-gear-wheel", "recipe:no_recipe:-",
      })
      S.eq(d.stopped[1], { name = "assembling-machine-1", reason = "no_power", cause = "power",
        recipe = "iron-gear-wheel", count = 2, pos = { x = 14, y = 0 }, dist = 12 })
  end },

  { "low_power, нет исследования и пуск ракеты — не остановка: свои счётчики slow и waiting", function()
      setup()
      machine("assembling-machine-1", 10, 0, "low_power", "iron-gear-wheel")
      machine("lab", 12, 0, "no_research_in_progress")
      machine("assembling-machine-1", 14, 0, "waiting_to_launch_rocket")
      machine("assembling-machine-1", 16, 0, "launching_rocket")
      machine("assembling-machine-1", 18, 0, "no_power", "iron-gear-wheel")
      local d = status()
      S.eq(d.machines, { seen = 5, running = 0, stopped = 1, hidden = 0, slow = 1, waiting = 3 })
      S.eq(d.causes, { power = 1, slow = 1, research = 1, rocket = 2 })
      S.eq(d.stopped[1].cause, "power", "настоящая остановка идёт первой")
      S.eq(d.stopped[2].cause, "slow")
      S.eq(d.stopped[2].reason, "low_power")
  end },

  { "чужая сила не попадает; незнакомый статус — other, имя остаётся; статуса нет — unknown", function()
      setup()
      machine("assembling-machine-1", 10, 0, "no_power", nil, { force = "enemy" })
      machine("assembling-machine-1", 12, 0, "brand_new_status")
      machine("assembling-machine-1", 14, 0, nil)
      local d = status()
      S.eq(d.machines, { seen = 2, running = 0, stopped = 1, hidden = 0, unknown = 1 })
      S.eq(d.stopped[1].cause, "other")
      S.eq(d.stopped[1].reason, "brand_new_status")
  end },

  { "живое — только видимое: машины в невидимом чанке дальше 32 клеток — hidden", function()
      local h = setup()
      S.move(h, { x = 2, y = 0 })
      machine("assembling-machine-1", 10, 0, "no_power")
      machine("assembling-machine-1", 100, 0, "no_power")
      machine("assembling-machine-1", 105, 0, "working")
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      local d = status{ radius = 128 }
      S.eq(d.machines, { seen = 1, running = 0, stopped = 1, hidden = 2 })
      S.eq(#d.stopped, 1)
      S.eq(d.stopped[1].pos.x, 10)
  end },

  { "радиус и центр: считаются только машины в круге; near=player", function()
      local h = setup()
      S.move(h, { x = 2, y = 0 })
      machine("assembling-machine-1", 10, 0, "no_power")
      machine("assembling-machine-1", 50, 0, "no_power")
      S.eq(status{ radius = 20 }.machines.stopped, 1)
      S.eq(status{ radius = 64 }.machines.stopped, 2)
      S.eq(status{ radius = 8, center = { x = 50, y = 0 } }.machines.stopped, 1)
      S.eq(status{ radius = 8, near = "player" }.machines.stopped, 0)
  end },

  { "limit режет строки, truncated; счётчики остаются полными", function()
      setup()
      for i = 1, 5 do machine("assembling-machine-1", 5 + i, 0, "no_power", "recipe-" .. i) end
      local d = status{ limit = 2 }
      S.eq(#d.stopped, 2)
      S.eq(d.truncated, true)
      S.eq(d.machines.stopped, 5)
      S.eq(d.causes.power, 5)
  end },

  { "ответ про помощника; сериализуем; границы аргументов", function()
      setup()
      machine("stone-furnace", 8, 0, "no_fuel")
      local d = status()
      S.eq(d.helper.queue, 0)
      S.eq(d.radius, 64)
      local resp = S.req("status", { radius = 500 }, "h1")
      S.err(resp, "limit")
      S.err(S.req("status", { radius = 0 }, "h1"), "bad_args")
      S.err(S.req("status", { limit = 0 }, "h1"), "bad_args")
      S.err(S.req("status", { kinds = {} }, "h1"), "bad_args")
      S.err(S.req("status", { center = { x = 1, y = 1 }, near = "player" }, "h1"), "bad_args")
  end },

  { "без помощника — вокруг хозяина", function()
      setup()
      machine("stone-furnace", 8, 0, "no_fuel")
      local d = S.okr(S.req("status", {}, nil))
      S.eq(d.machines.stopped, 1)
      S.eq(d.helper, nil)
  end },

  { "индекс закончил раскрутку — index_ready", function()
      setup()
      rawset(S.nauvis, "get_chunks", function() return function() return nil end end)
      S.tick(5)
      S.eq(status().index_ready, true)
  end },
})
