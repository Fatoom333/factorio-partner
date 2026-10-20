-- Рефлекс evacuate: снимок области, угроза, разбор ценного первым, отступление, возврат построек.
-- EVENTS.md evacuate_started/evacuated/evacuate_missing/evacuate_restored, PROTOCOL §6.5, §6.7.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

local AREA = { left_top = { x = 10, y = -6 }, right_bottom = { x = 22, y = 6 } }

local function world(opts)
  local W = F.setup(opts)
  S.add_prototype("entity", { name = "small-demolisher", type = "segmented-unit", max_health = 30000 })
  S.add_prototype("entity", { name = "biter-spawner", type = "unit-spawner", max_health = 350 })
  S.add_prototype("entity", { name = "small-worm-turret", type = "turret", max_health = 200 })
  S.add_prototype("item", { name = "speed-module", type = "module", stack_size = 50 })
  -- LuaForce.is_enemy: сила player враждует с enemy
  rawset(game.forces.player, "is_enemy", function(other)
    local n = type(other) == "string" and other or other.name
    return n == "enemy"
  end)
  return W
end

local function build(name, pos, dir, force)
  return S.nauvis.create_entity{ name = name, position = pos, force = force or "player", direction = dir }
end

--- Буры, машина с рецептом, сундук и две ленты в AREA.
local function base()
  local b = {
    belt1 = build("transport-belt", { x = 14.5, y = -4.5 }, 4),
    belt2 = build("transport-belt", { x = 15.5, y = -4.5 }, 4),
    chest = build("iron-chest", { x = 19.5, y = 3.5 }),
    drill = build("electric-mining-drill", { x = 12.5, y = 0.5 }, 8),
    asm = build("assembling-machine-1", { x = 16.5, y = 0.5 }),
  }
  rawset(b.asm, "get_recipe", function() return game.forces.player.recipes["iron-gear-wheel"] end)
  return b
end

local function set(list)
  return S.req("reflexes", { set = list }, "h1")
end

local function evac(extra)
  local r = { type = "evacuate", area = AREA, return_after_s = 30 }
  for k, v in pairs(extra or {}) do r[k] = v end
  return S.okr(set{ r }).set[1]
end

local function events(kind)
  local out, since = {}, 0
  for _ = 1, 20 do
    local r = S.okr(S.req("events", { since = since, limit = 200 }))
    for _, e in ipairs(r.events) do
      if kind == nil or e.kind == kind then out[#out + 1] = e end
    end
    if #r.events < 200 then break end
    since = r.seq
  end
  return out
end

local function wait_for(kind, n, max)
  n = n or 1
  for _ = 1, max or 6000 do
    F.run(1)
    local list = events(kind)
    if list[n] ~= nil then return list[n] end
  end
  error("нет события " .. kind, 2)
end

local function enemy(pos, name)
  return S.nauvis.create_entity{ name = name or "small-biter", position = pos, force = "enemy" }
end

local function at(name, pos)
  return S.nauvis.find_entity(name, pos)
end

S.suite("reflex_evacuate", {
  { "схема: значения по умолчанию, область или центр с радиусом, границы", function()
      world()
      S.eq(evac(), { type = "evacuate", area = AREA, threat_radius = 40, return_after_s = 30, rebuild = true })
      local c = S.okr(set{ { type = "evacuate", center = { x = 16, y = 0 }, radius = 48, names = { "iron-chest" } } }).set[1]
      S.eq(c.return_after_s, 180)
      S.eq(c.names, { "iron-chest" })
      local function bad(r, code) S.err(set{ r }, code, S.dump(r)) end
      bad({ type = "evacuate" }, "bad_args")
      bad({ type = "evacuate", area = AREA, center = { x = 0, y = 0 }, radius = 5 }, "bad_args")
      bad({ type = "evacuate", center = { x = 0, y = 0 } }, "bad_args")
      bad({ type = "evacuate", area = AREA, radius = 5 }, "bad_args")
      bad({ type = "evacuate", center = { x = 0, y = 0 }, radius = 49 }, "limit")
      bad({ type = "evacuate", area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 97, y = 1 } } }, "limit")
      bad({ type = "evacuate", area = AREA, threat_radius = 9 }, "bad_args")
      bad({ type = "evacuate", area = AREA, threat_radius = 121 }, "limit")
      bad({ type = "evacuate", area = AREA, return_after_s = 29 }, "bad_args")
      bad({ type = "evacuate", area = AREA, return_after_s = 1801 }, "limit")
      bad({ type = "evacuate", area = AREA, names = { "no-such-thing" } }, "bad_args")
      bad({ type = "evacuate", area = AREA, rebuild = "yes" }, "bad_args")
  end },

  { "снимок при включении: имя, позиция, направление, рецепт, модули; только своё и в области", function()
      world()
      local b = base()
      rawset(b.drill, "get_module_inventory", function() return C.inventory{ size = 3, items = { ["speed-module"] = 2 } } end)
      build("iron-chest", { x = 30.5, y = 0.5 })               -- вне области
      build("iron-chest", { x = 11.5, y = 4.5 }, nil, "enemy")  -- чужая сила
      F.ghost("iron-chest", { x = 13.5, y = 4.5 })              -- призрак
      C.resource("iron-ore", { x = 20.5, y = -2.5 }, 10)        -- руда
      evac()
      local st = storage.evacuate.h1
      S.eq(st.phase, "watch")
      S.eq(st.box, AREA)
      local names = {}
      for _, en in ipairs(st.list) do names[#names + 1] = en.name end
      S.eq(names, { "electric-mining-drill", "assembling-machine-1", "iron-chest", "transport-belt", "transport-belt" },
        "ценные первыми")
      local drill, asm = st.list[1], st.list[2]
      S.eq(drill.pos, { x = 12.5, y = 0.5 })
      S.eq(drill.dir, 8)
      S.eq(drill.item, "electric-mining-drill")
      S.eq(drill.modules, { ["speed-module"] = 2 })
      S.eq(drill.quality, "normal")
      S.eq(drill.state, "present")
      S.eq(asm.recipe, "iron-gear-wheel")
      S.eq(st.list[4].dir, 4)
      -- names: только эти и в их порядке
      evac{ names = { "transport-belt", "iron-chest" } }
      names = {}
      for _, en in ipairs(storage.evacuate.h1.list) do names[#names + 1] = en.name end
      S.eq(names, { "transport-belt", "transport-belt", "iron-chest" })
      -- тот же набор ещё раз — снимок не переснимается
      local before = storage.evacuate.h1
      evac{ names = { "transport-belt", "iron-chest" } }
      S.ok(storage.evacuate.h1 == before)
      -- выключили — состояние забыто
      S.okr(set{})
      S.eq(storage.evacuate.h1, nil)
  end },

  { "угроза: кусака и разрушитель у края области; червь, гнездо, далёкий, невидимый и свой — нет", function()
      local function started(setup)
        world()
        base()
        evac()
        setup()
        F.run(20)
        return events("evacuate_started")[1]
      end
      S.eq(started(function() enemy({ x = 60, y = 0 }) end).data.threat,
        { name = "small-biter", pos = { x = 60, y = 0 }, dist = 38 })
      S.eq(started(function() enemy({ x = 16, y = 40 }, "small-demolisher") end).data.threat.name, "small-demolisher")
      S.eq(started(function() enemy({ x = 16, y = 10 }, "small-worm-turret") end), nil, "червь стоит на месте")
      S.eq(started(function() enemy({ x = 16, y = 10 }, "biter-spawner") end), nil, "гнездо само не ходит")
      S.eq(started(function() enemy({ x = 63, y = 0 }) end), nil, "дальше threat_radius")
      S.eq(started(function() build("small-biter", { x = 30, y = 0 }, nil, "neutral") end), nil, "не враг")
      S.eq(started(function()
        F.vis.result = false
        enemy({ x = 60, y = 0 })
      end), nil, "невидимого врага помощник не знает")
      local ev = started(function() enemy({ x = 60, y = 0 }) end)
      S.eq(ev.loud, true)
      S.eq(ev.data.area, AREA)
  end },

  { "эвакуация: задачи сняты, разбор ценного первым, отступление, тишина — возврат с рецептом и делом", function()
      local W = world()
      local b = base()
      evac()
      local wait = S.okr(C.act("wait", { seconds = 600 })).job
      F.run(5)
      local biter = enemy({ x = 60, y = 0 })
      F.run(10)
      S.eq(C.result(wait).code, "cancelled", "задача агента снята")
      local jobs = S.okr(S.req("jobs", {}, "h1"))
      local first = jobs.active or jobs.queue[1]
      S.eq(first["do"], "deconstruct")
      S.eq(first.req, "reflex:evacuate")
      local ev = wait_for("evacuated", 1, 4000)
      S.eq(ev.loud, true)
      S.eq(ev.data.taken, { ["electric-mining-drill"] = 1, ["assembling-machine-1"] = 1, ["iron-chest"] = 1, ["transport-belt"] = 2 })
      S.eq(ev.data.lost, {})
      -- порядок разбора — по итогам задач
      local order = {}
      for _, e in ipairs(events("job_done")) do
        if e.data["do"] == "deconstruct" then order[#order + 1] = next(e.data.detail.got) end
      end
      S.eq(order, { "electric-mining-drill", "assembling-machine-1", "iron-chest", "transport-belt", "transport-belt" })
      for _, e in pairs(b) do S.eq(e.valid, false) end
      S.eq(C.counts(W.main)["transport-belt"], 2)
      -- отступление обычной ходьбой прочь от врага
      S.eq(storage.evacuate.h1.phase, "retreat")
      local walk = S.okr(S.req("jobs", {}, "h1"))
      walk = walk.active or walk.queue[1]
      S.eq(walk["do"], "walk")
      S.eq(walk.req, "reflex:evacuate")
      for _ = 1, 200 do
        F.run(1)
        if storage.evacuate.h1.phase == "away" then break end
      end
      S.eq(storage.evacuate.h1.phase, "away")
      S.ok(S.dist(W.h.position, biter.position) >= 40, S.dump(W.h.position))
      -- враг ушёл: через return_after_s — постройки обратно, рецепт, прерванное дело
      biter.destroy()
      F.run(30 * 60 - 60)
      S.eq(events("evacuate_restored")[1], nil, "ещё рано")
      local r = wait_for("evacuate_restored", 1, 4000)
      S.eq(r.loud, true)
      S.eq(r.data.placed, { ["electric-mining-drill"] = 1, ["assembling-machine-1"] = 1, ["iron-chest"] = 1, ["transport-belt"] = 2 })
      S.eq(r.data.missing, {})
      local drill = at("electric-mining-drill", { x = 12.5, y = 0.5 })
      S.ok(drill ~= nil and drill.direction == 8)
      S.eq(at("transport-belt", { x = 15.5, y = -4.5 }).direction, 4)
      S.eq(at("assembling-machine-1", { x = 16.5, y = 0.5 }).recipe_set, { recipe = "iron-gear-wheel", quality = "normal" })
      S.eq(#events("evacuate_missing"), 0)
      local res = wait_for("reflex_resumed", 1, 20)
      S.eq(res.data.type, "evacuate")
      S.eq(#res.data.jobs, 1)
      S.eq(res.data.jobs[1]["do"], "wait")
      S.eq(storage.evacuate.h1.phase, "watch")
      S.eq(storage.evacuate.h1.list[1].state, "present")
  end },

  { "уничтоженная до разбора — lost и не просится; чего нет в карманах — evacuate_missing", function()
      local W = world()
      local b = base()
      evac()
      b.chest.destroy()
      local biter = enemy({ x = 60, y = 0 })
      local ev = wait_for("evacuated", 1, 4000)
      S.eq(ev.data.lost, { ["iron-chest"] = 1 })
      S.eq(ev.data.taken["iron-chest"], nil)
      biter.destroy()
      W.main.remove{ name = "electric-mining-drill", count = 1 }
      local m = wait_for("evacuate_missing", 1, 6000)
      S.eq(m.loud, true)
      S.eq(m.data.items, { ["electric-mining-drill"] = 1 }, "разрушенное врагом не просится")
      local r = wait_for("evacuate_restored", 1, 4000)
      S.eq(r.data.placed, { ["assembling-machine-1"] = 1, ["transport-belt"] = 2 })
      S.eq(r.data.missing, { ["electric-mining-drill"] = 1 })
      S.eq(r.data.left, { ["electric-mining-drill"] = 1 }, "в карманах не нашлось — осталось несделанным")
      S.eq(at("electric-mining-drill", { x = 12.5, y = 0.5 }), nil)
      S.eq(at("iron-chest", { x = 19.5, y = 3.5 }), nil, "lost не ставится")
  end },

  { "постройку разобрал кто-то другой (общая область двух тел) — lost, без просьб о предметах", function()
      local W = world()
      base()
      evac()
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuate_started")
      -- второе тело успело раньше: сундука уже нет, но и в наших карманах его не будет
      at("iron-chest", { x = 19.5, y = 3.5 }).destroy()
      local ev = wait_for("evacuated", 1, 4000)
      S.eq(ev.data.lost, { ["iron-chest"] = 1 })
      biter.destroy()
      local r = wait_for("evacuate_restored", 1, 6000)
      S.eq(r.data.missing, {})
      S.eq(r.data.failed, nil)
      S.eq(#events("evacuate_missing"), 0)
      S.eq(C.counts(W.main)["iron-chest"], nil)
  end },

  { "модули: снимок помнит, после постановки — задача insert из карманов", function()
      local W = world()
      local b = base()
      rawset(b.drill, "get_module_inventory", function() return C.inventory{ size = 3, items = { ["speed-module"] = 2 } } end)
      evac()
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuated", 1, 4000)
      W.main.insert{ name = "speed-module", count = 2 } -- в игре модули выпадают в карманы при разборе
      biter.destroy()
      local seen
      for _ = 1, 6000 do
        F.run(1)
        local q = S.okr(S.req("jobs", {}, "h1"))
        for _, t in ipairs(q.queue) do if t["do"] == "insert" then seen = t end end
        if q.active and q.active["do"] == "insert" then seen = q.active end
        if seen or events("evacuate_restored")[1] then break end
      end
      S.ok(seen ~= nil, "задача insert поставлена")
      S.eq(seen.req, "reflex:evacuate")
  end },

  { "hold хозяина: эвакуация идёт, возврат ждёт его слова", function()
      world()
      base()
      evac()
      storage.owner_hold = { h1 = { kind = "stop", tick = game.tick, seq = 1 } }
      local biter = enemy({ x = 60, y = 0 })
      local ev = wait_for("evacuated", 1, 4000)
      S.eq(ev.data.taken["electric-mining-drill"], 1)
      for _ = 1, 300 do
        F.run(1)
        if storage.evacuate.h1.phase == "away" then break end
      end
      biter.destroy()
      F.run(30 * 60 + 300)
      S.eq(storage.evacuate.h1.phase, "away")
      S.eq(events("evacuate_restored")[1], nil, "при hold не возвращает")
      storage.owner_hold = {}
      local r = wait_for("evacuate_restored", 1, 4000)
      S.eq(r.data.placed["electric-mining-drill"], 1)
  end },

  { "переживает сейв: снимок и ход эвакуации — простые таблицы в storage", function()
      world()
      base()
      evac()
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuate_started")
      F.run(15)
      S.reload()
      S.eq(storage.evacuate.h1.phase, "evac")
      local ev = wait_for("evacuated", 1, 4000)
      S.eq(ev.data.taken["transport-belt"], 2)
      biter.destroy()
      S.reload()
      local r = wait_for("evacuate_restored", 1, 6000)
      S.eq(r.data.placed["assembling-machine-1"], 1)
  end },

  { "агент снял задачи разбора — эвакуация кончается, его дело не возвращается", function()
      world()
      base()
      evac()
      local wait = S.okr(C.act("wait", { seconds = 600 })).job
      F.run(2)
      enemy({ x = 60, y = 0 })
      F.run(20)
      S.eq(C.result(wait).code, "cancelled")
      S.okr(S.req("cancel", { all = true }, "h1"))
      local ev = wait_for("evacuated", 1, 50)
      S.eq(ev.data.reason, "cancelled")
      S.eq(storage.evacuate.h1.phase, "away")
      S.eq(storage.evacuate.h1.saved, nil)
  end },

  { "разрешения: разбор построек хозяина и стройка — по owner_ok или «сам»; «нельзя» — отказ", function()
      world()
      local b = base()
      rawset(b.drill, "last_user", { name = "Tartaluga" })
      S.owner_ok = nil
      local e = S.err(set{ { type = "evacuate", area = AREA } }, "needs_owner_ok")
      S.eq(e.data.perm, "deconstruct-owner")
      S.eq(storage.reflexes.h1, nil, "набор не изменился")
      S.owner_ok = { "deconstruct-owner" }
      S.okr(set{ { type = "evacuate", area = AREA } })
      S.ok(storage.evacuate.h1 ~= nil)
      S.owner_ok = nil
      S.okr(set{ { type = "evacuate", area = AREA } }, "те же параметры — без нового вопроса")
      settings.global["partner-perm-build"] = { value = "ask" }
      S.okr(set{ { type = "evacuate", area = AREA, threat_radius = 50 } }, "та же область — без вопроса")
      e = S.err(set{ { type = "evacuate", center = { x = 16, y = 0 }, radius = 6, names = { "iron-chest" } } }, "needs_owner_ok")
      S.eq(e.data.perm, "build", "другая область — спрашивает снова")
      S.okr(set{ { type = "evacuate", center = { x = 16, y = 0 }, radius = 6, names = { "iron-chest" }, rebuild = false } }, "без возврата стройка не нужна")
      S.okr(set{})
      S.owner_ok = { "build" }
      S.err(set{ { type = "evacuate", area = AREA } }, "needs_owner_ok", "build дан, разбор хозяйского — нет")
      settings.global["partner-perm-deconstruct-owner"] = { value = "deny" }
      S.owner_ok = S.all_leave()
      S.err(set{ { type = "evacuate", area = AREA } }, "owner_forbids")
      -- только свои постройки помощников — deconstruct-own («сам» по умолчанию)
      S.owner_ok = nil
      settings.global["partner-perm-build"] = { value = "auto" }
      S.okr(set{ { type = "evacuate", area = AREA, names = { "transport-belt" } } })
  end },

  { "пока постройки в карманах — убрать рефлекс или сменить область нельзя; после возврата — можно", function()
      world()
      base()
      evac()
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuated", 1, 4000)
      for _ = 1, 300 do
        F.run(1)
        if storage.evacuate.h1.phase == "away" then break end
      end
      S.eq(storage.evacuate.h1.phase, "away")
      local e = S.err(set{}, "bad_args")
      S.ok(e.text:find("pockets"), e.text)
      S.err(set{ { type = "evacuate", center = { x = 16, y = 0 }, radius = 5 } }, "bad_args", "другая область")
      S.eq(#storage.reflexes.h1, 1, "набор прежний")
      S.eq(storage.evacuate.h1.phase, "away", "снимок не забыт")
      evac{ threat_radius = 50 } -- та же область: можно
      biter.destroy()
      wait_for("evacuate_restored", 1, 6000)
      S.okr(set{})
      S.eq(storage.evacuate, {})
      S.eq(#events("evacuate_restored"), 1, "нечего терять — молча")
  end },

  { "снимок забыт, а разобранное осталось в карманах — громкое evacuate_restored{dropped}", function()
      local W = world()
      base()
      evac()
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuated", 1, 4000)
      biter.destroy()
      W.main.remove{ name = "electric-mining-drill", count = 1 }
      wait_for("evacuate_restored", 1, 6000)
      S.eq(storage.evacuate.h1.phase, "watch")
      S.okr(set{})
      local d = wait_for("evacuate_restored", 2, 5)
      S.eq(d.loud, true)
      S.eq(d.data.reason, "dropped")
      S.eq(d.data.left, { ["electric-mining-drill"] = 1 })
  end },

  { "второй evacuate в одном наборе — отказ", function()
      world()
      local e = S.err(set{ { type = "evacuate", area = AREA }, { type = "evacuate", center = { x = 40, y = 0 }, radius = 5 } },
        "bad_args")
      S.ok(e.text:find("only one evacuate"), e.text)
      S.eq(storage.reflexes.h1, nil)
  end },

  { "names: не больше 32", function()
      world()
      local names = {}
      for i = 1, 33 do names[i] = "iron-chest" end
      S.err(set{ { type = "evacuate", area = AREA, names = names } }, "limit")
      names[33] = nil
      S.okr(set{ { type = "evacuate", area = AREA, names = names } })
  end },

  { "подземная лента возвращается тем же концом: вход и выход", function()
      local W = world()
      local E, I = prototypes.entity, prototypes.item
      E["underground-belt"] = { name = "underground-belt", type = "underground-belt",
        items_to_place_this = { { name = "underground-belt", count = 1 } },
        collision_box = { left_top = { x = -0.4, y = -0.4 }, right_bottom = { x = 0.4, y = 0.4 } },
        tile_width = 1, tile_height = 1,
        collision_mask = { layers = { object = true, water_tile = true, is_object = true } },
        mineable_properties = { minable = true, mining_time = 0.2,
          products = { { type = "item", name = "underground-belt", amount = 1 } } } }
      I["underground-belt"] = { name = "underground-belt", type = "item", stack_size = 50, place_result = E["underground-belt"] }
      S.nauvis.create_entity{ name = "underground-belt", position = { x = 13.5, y = 4.5 }, force = "player", direction = 4, type = "input" }
      S.nauvis.create_entity{ name = "underground-belt", position = { x = 17.5, y = 4.5 }, force = "player", direction = 4, type = "output" }
      evac()
      S.eq(storage.evacuate.h1.list[1].io, "input")
      S.eq(storage.evacuate.h1.list[2].io, "output")
      local biter = enemy({ x = 60, y = 0 })
      local ev = wait_for("evacuated", 1, 4000)
      S.eq(ev.data.taken, { ["underground-belt"] = 2 })
      S.eq(C.counts(W.main)["underground-belt"], 2)
      biter.destroy()
      local r = wait_for("evacuate_restored", 1, 6000)
      S.eq(r.data.placed, { ["underground-belt"] = 2 })
      S.eq(at("underground-belt", { x = 13.5, y = 4.5 }).belt_to_ground_type, "input")
      S.eq(at("underground-belt", { x = 17.5, y = 4.5 }).belt_to_ground_type, "output")
      W.main.insert{ name = "iron-chest", count = 1 }
      local bad = S.okr(C.act("place", { item = "iron-chest", pos = { x = 30.5, y = 0.5 }, type = "input" })).job
      F.run(5)
      S.eq(C.result(bad).code, "bad_args", "type — только подземным лентам и погрузчикам")
  end },

  { "настройки, которых place не вернёт (провода, фильтры), — reset в итоге возврата", function()
      world()
      local b = base()
      rawset(b.drill, "get_wire_connectors", function() return { { connection_count = 1 } } end)
      evac()
      S.eq(storage.evacuate.h1.list[1].lossy, true)
      S.eq(storage.evacuate.h1.list[2].lossy, nil)
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuated", 1, 4000)
      biter.destroy()
      local r = wait_for("evacuate_restored", 1, 6000)
      S.eq(r.data.reset, { ["electric-mining-drill"] = 1 })
  end },

  { "другое качество: мод его не ставит — quality, без просьб о предметах", function()
      local W = world()
      local b = base()
      rawset(b.drill, "quality", { name = "rare", level = 2 })
      evac()
      S.eq(storage.evacuate.h1.list[1].quality, "rare")
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuated", 1, 4000)
      -- в игре разобранный редкий бур ложится в карманы редким предметом
      W.main.remove{ name = "electric-mining-drill", count = 1 }
      W.main.insert{ name = "electric-mining-drill", count = 1, quality = "rare" }
      biter.destroy()
      local r = wait_for("evacuate_restored", 1, 6000)
      S.eq(r.data.quality, { ["electric-mining-drill"] = 1 })
      S.eq(r.data.missing, {})
      S.eq(r.data.left, { ["electric-mining-drill"] = 1 })
      S.eq(#events("evacuate_missing"), 0)
      S.eq(at("electric-mining-drill", { x = 12.5, y = 0.5 }), nil)
  end },

  { "сундук с содержимым и запрещённое хозяином не разбираются — kept", function()
      world()
      local b = base()
      rawset(b.chest, "get_inventory", function() return C.inventory{ size = 16, items = { ["iron-plate"] = 400 } } end)
      rawset(b.drill, "last_user", { name = "Tartaluga" })
      evac()
      settings.global["partner-perm-deconstruct-owner"] = { value = "deny" } -- хозяин передумал после включения
      local biter = enemy({ x = 60, y = 0 })
      local ev = wait_for("evacuated", 1, 4000)
      S.eq(ev.data.kept, { ["iron-chest"] = 1, ["electric-mining-drill"] = 1 })
      S.eq(ev.data.taken, { ["assembling-machine-1"] = 1, ["transport-belt"] = 2 })
      S.ok(b.drill.valid and b.chest.valid)
      for _ = 1, 300 do F.run(1) end
      S.eq(#events("evacuate_started"), 1, "оставленное не начинает эвакуацию заново")
      biter.destroy()
  end },

  { "hold хозяина: включить или сменить evacuate нельзя, тот же набор — можно", function()
      world()
      base()
      evac()
      storage.owner_hold = { h1 = { kind = "stop", tick = game.tick, seq = 1 } }
      evac() -- те же параметры
      S.err(set{ { type = "evacuate", center = { x = 16, y = 0 }, radius = 5 } }, "owner_hold")
      S.err(set{ { type = "evacuate", area = AREA, rebuild = false } }, "owner_hold")
      storage.owner_hold = {}
      S.okr(set{})
      storage.owner_hold = { h1 = { kind = "come", tick = game.tick, seq = 2 } }
      S.err(set{ { type = "evacuate", area = AREA } }, "owner_hold")
      S.eq(storage.reflexes.h1, {})
  end },

  { "стройку хозяин запретил после включения — возврат ничего не ставит, всё в left", function()
      world()
      base()
      evac()
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuated", 1, 4000)
      settings.global["partner-perm-build"] = { value = "deny" }
      biter.destroy()
      local r = wait_for("evacuate_restored", 1, 6000)
      S.eq(r.data.reason, "owner_forbids")
      S.eq(r.data.placed, {})
      S.eq(r.data.left["electric-mining-drill"], 1)
      S.eq(at("electric-mining-drill", { x = 12.5, y = 0.5 }), nil)
  end },

  { "«стоп» хозяина посреди возврата: возврат ждёт и продолжается с того, что осталось", function()
      world()
      base()
      evac()
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuated", 1, 4000)
      biter.destroy()
      for _ = 1, 6000 do
        F.run(1)
        local st = storage.evacuate.h1
        if st.phase == "restore" and st.placed ~= nil and next(st.placed) ~= nil then break end
      end
      S.eq(storage.evacuate.h1.phase, "restore")
      storage.owner_hold = { h1 = { kind = "stop", tick = game.tick, seq = 1 } }
      S.okr(S.req("cancel", { all = true }, "h1")) -- так «стоп» снимает задачи тела
      F.run(30)
      S.eq(storage.evacuate.h1.phase, "away")
      S.eq(events("evacuate_restored")[1], nil, "не кончился")
      F.run(600)
      S.eq(events("evacuate_restored")[1], nil, "ждёт слова хозяина")
      storage.owner_hold = {}
      local r = wait_for("evacuate_restored", 1, 6000)
      S.eq(r.data.placed, { ["electric-mining-drill"] = 1, ["assembling-machine-1"] = 1, ["iron-chest"] = 1, ["transport-belt"] = 2 })
      S.eq(r.data.left, nil)
      S.ok(at("transport-belt", { x = 15.5, y = -4.5 }) ~= nil)
  end },

  { "flee раньше эвакуации: прерванное дело не теряется, его возвращает эвакуация", function()
      local W = world()
      base()
      set{ { type = "flee", health = 1, on_attack = false }, { type = "evacuate", area = AREA, return_after_s = 30 } }
      W.h.health = 100 -- раненый: flee ждёт здоровья для возврата к делу
      local wait = S.okr(C.act("wait", { seconds = 600 })).job
      F.run(5)
      local p = W.h.position
      local biter = enemy({ x = p.x - 10, y = p.y })
      wait_for("reflex_done", 1, 2000)
      S.eq(C.result(wait).code, "cancelled")
      wait_for("evacuate_started", 1, 2000)
      S.eq(storage.reflex_state.h1.resume, nil, "возврат к делу забрала эвакуация")
      S.eq(storage.evacuate.h1.saved[1]["do"], "wait")
      wait_for("evacuated", 1, 6000)
      biter.destroy()
      W.h.health = 250
      local res = wait_for("reflex_resumed", 1, 8000)
      S.eq(res.data.type, "evacuate")
      S.eq(res.data.jobs[1]["do"], "wait")
  end },

  { "flee раз за разом прерывает разбор у врага — эвакуация кончается threatened, без пинг-понга", function()
      local W = world()
      base()
      set{ { type = "flee", radius = 20, health = 1, on_attack = false, resume = false },
           { type = "evacuate", area = AREA, return_after_s = 30 } }
      local biter = enemy({ x = 60, y = 0 })
      wait_for("evacuate_started", 1, 200)
      S.move(biter, { x = 12.5, y = 6 }) -- враг уже у бура
      local ev = wait_for("evacuated", 1, 20000)
      S.eq(ev.data.reason, "threatened", S.dump(ev.data))
      S.ok(ev.data.left ~= nil, S.dump(ev.data))
      local flees = #events("reflex_done")
      for _ = 1, 2000 do F.run(1) end
      S.eq(#events("evacuate_started"), 1)
      S.ok(#events("reflex_done") <= flees + 1, "тело не ходит к врагу снова")
      S.ok(W.h.valid)
  end },
})
