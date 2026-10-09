-- Тесты операции `state` и общих помощников (поток G). Контракт: docs/STATE.md «state».
local G = require("stubs_g")

-- 1. Полный ответ
do
  local w = G.reset { tick = 4109766 }
  storage.events = { next_seq = 813, list = {} }
  -- форма ядра (scripts/core/jobs.lua): storage.jobs.by_helper[id] = {active, queue}
  storage.jobs = { next_job = 60, by_helper = {
    h1 = { active = { job = 57, helper = "h1", ["do"] = "walk", progress = { done = 12, total = 40, extra = 1 } },
           queue = { { job = 58, helper = "h1", ["do"] = "mine" }, { job = 59, helper = "h1", ["do"] = "craft" } } },
    h2 = { active = { job = 50, helper = "h2", ["do"] = "follow" }, queue = {} },
  } }
  local main = G.inventory({ ["iron-plate"] = 40, coal = 12 }, 80)
  -- предмет другого качества не виден
  main._contents[#main._contents + 1] = { name = "iron-plate", count = 5, quality = "rare" }
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 52.43, y = 93.37 }, main = main,
    armor = G.armor_inventory("power-armor-mk2"), robots = { 10, 9 } })
  G.add_player(w, { name = "Tartaluga", pos = { x = 48, y = 90 } })
  G.add_player(w, { name = "Guest", connected = false, character = false, pos = { x = 0, y = 0 } })
  w.surface.add(G.entity { name = "small-biter", type = "unit", pos = { x = 60, y = 93 }, force = w.enemy })
  w.surface.add(G.entity { name = "wooden-chest", type = "container", pos = { x = 50.5, y = 90.5 }, force = w.force })
  w.surface.add(G.entity { name = "wooden-chest", type = "container", pos = { x = 54.5, y = 90.5 }, force = w.force })
  -- чужой сундук не считается
  w.surface.add(G.entity { name = "wooden-chest", type = "container", pos = { x = 55.5, y = 90.5 }, force = w.enemy })

  local S = require("scripts.perception.state")
  local d = S.ops.state({}, ctx)
  G.plain(d)
  G.ok(G.json(d):find('"progress":[12,40]', 1, true), "job progress serializes as array")
  G.eq(d.helper, "h1")
  G.eq(d.surface, "nauvis")
  G.eq(d.pos, { x = 52.4, y = 93.4 }, "pos rounded")
  G.eq(d.health, 250)
  G.eq(d.max_health, 250)
  G.eq(d.reach, { build = 10, reach = 10, resource = 2.7, pickup = 1 })
  G.eq(d.inv, { ["iron-plate"] = 40, coal = 12 }, "only normal quality")
  G.eq(d.inv_free, 80 - 3)
  G.eq(d.armor, "power-armor-mk2")
  G.eq(d.robots, { construction = 10, available = 9 })
  G.eq(d.job, { job = 57, ["do"] = "walk", progress = { 12, 40 } })
  G.eq(d.queue, 2)
  G.eq(#d.players, 2)
  local tp, gp
  for _, p in ipairs(d.players) do if p.name == "Tartaluga" then tp = p else gp = p end end
  G.eq(tp.owner, true, "player index 1 is owner by default")
  G.eq(tp.online, true)
  G.eq(tp.surface, "nauvis")
  G.eq(tp.pos, { x = 48, y = 90 })
  G.eq(tp.dist, 5.6)
  G.eq(gp.owner, false)
  G.eq(gp.online, false)
  G.eq(gp.pos, nil, "offline player has no pos")
  G.eq(#d.near.enemies, 1)
  G.eq(d.near.enemies[1].name, "small-biter")
  G.eq(d.near.containers, 2)
  G.eq(d.vision, true)
  G.eq(d.tick, 4109766)
  G.eq(d.seq, 812)
end

-- 2. Враги в невидимом чанке не показываются; без задачи job=nil, queue=0; без брони и дронов
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 10, y = 10 } })
  w.surface.add(G.entity { name = "small-biter", type = "unit", pos = { x = 35, y = 10 }, force = w.enemy })
  w.force.set_visible(1, 0, false)
  require("scripts.perception.vision").ops.vision({ on = false }, ctx)
  local d = require("scripts.perception.state").ops.state({}, ctx)
  G.plain(d)
  G.eq(#d.near.enemies, 0, "enemy in not-visible chunk hidden")
  G.eq(d.job, nil)
  G.eq(d.queue, 0)
  G.eq(d.armor, nil)
  G.eq(d.robots, { construction = 0, available = 0 })
  G.eq(d.vision, false)
  G.eq(d.seq, 0)
end

-- 2b. Задача из ядра: storage.jobs.by_helper; служебные ключи storage.jobs — не помощники
do
  local w = G.reset()
  local S = require("scripts.perception.state")
  storage.jobs = { next_job = 9, by_helper = {
    h1 = { active = { job = 7, helper = "h1", ["do"] = "craft" }, queue = { { job = 8 } } },
  } }
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local d = S.ops.state({}, ctx)
  G.eq(d.job, { job = 7, ["do"] = "craft" }, "no progress yet")
  G.eq(d.queue, 1)
  -- id помощника совпадает с ключом storage.jobs — это не его очередь
  for _, id in ipairs({ "by_helper", "next_job" }) do
    local _, c = G.add_helper(w, id, { pos = { x = 1, y = 1 } })
    local r = S.ops.state({}, c)
    G.eq(r.job, nil, id .. ": job")
    G.eq(r.queue, 0, id .. ": queue")
  end
  -- помощник без записи в by_helper; storage.jobs ещё нет (до on_init ядра)
  local _, c3 = G.add_helper(w, "h3", { pos = { x = 2, y = 2 } })
  G.eq(S.ops.state({}, c3).queue, 0)
  storage.jobs = nil
  local r = S.ops.state({}, ctx)
  G.eq(r.job, nil)
  G.eq(r.queue, 0)
end

-- 3. Ошибки
do
  local w = G.reset()
  local S = require("scripts.perception.state")
  G.raises("no_helper", function() S.ops.state({}, {}) end, "no helper")
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  G.raises("bad_args", function() S.ops.state({ foo = 1 }, ctx) end, "unknown field")
  G.raises("bad_args", function() S.ops.state("x", ctx) end, "args not object")
  e.valid = false
  G.raises("no_helper", function() S.ops.state({}, ctx) end, "invalid body")
end

-- 4. Хозяин по настройке partner-owner
do
  local w = G.reset { owner = "Boss" }
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  G.add_player(w, { name = "First", pos = { x = 1, y = 1 } })
  G.add_player(w, { name = "Boss", pos = { x = 2, y = 2 } })
  local d = require("scripts.perception.state").ops.state({}, ctx)
  for _, p in ipairs(d.players) do G.eq(p.owner, p.name == "Boss", "owner flag " .. p.name) end
end

-- 5. Общие помощники
do
  G.reset()
  local C = require("scripts.perception.state").common
  G.eq(C.round(1.25), 1.3)
  G.eq(C.round(-0.04), 0)
  G.eq(C.round(-1.26), -1.3)
  G.ok(1 / C.round(-0.04) > 0, "no negative zero")
  G.raises("bad_args", function() C.check_pos({ x = 0 / 0, y = 1 }, "p") end, "nan")
  G.raises("bad_args", function() C.check_pos({ x = 1 }, "p") end, "missing y")
  G.raises("bad_args", function() C.check_pos({ x = 2e6, y = 1 }, "p") end, "out of map")
  G.raises("bad_args", function() C.check_pos({ x = 1 / 0, y = 1 }, "p") end, "inf")
  G.raises("limit", function() C.check_num(200, "radius", 1, 128) end, "over max")
  G.raises("bad_args", function() C.check_num(0, "radius", 1, 128) end, "under min")
  G.raises("bad_args", function() C.check_num("5", "radius", 1, 128) end, "string number")
  G.raises("bad_args", function() C.check_int(1.5, "limit", 1, 10) end, "not int")
  G.eq(C.check_names({ "a", "b", "a" }, "items"), { a = true, b = true })
  G.eq(C.check_names({ a = 5 }, "items"), { a = true })
  G.eq(C.check_names({}, "items"), nil)
  G.raises("bad_args", function() C.check_names({ 1, 2 }, "items") end, "non-string names")
  G.raises("bad_args", function() C.check_names("a", "items") end, "not a list")
  G.raises("limit", function() C.check_area({ left_top = { x = 0, y = 0 }, right_bottom = { x = 200, y = 1 } }, "area", 128) end)
  G.raises("bad_args", function() C.check_area({ left_top = { x = 5, y = 0 }, right_bottom = { x = 1, y = 1 } }, "area", 128) end)
  G.raises("bad_args", function() C.check_string("", "name") end, "empty string")
  G.raises("bad_args", function() C.check_string(string.rep("a", 101), "name", 100) end, "long string")
  G.eq(C.is_normal(nil), true)
  G.eq(C.is_normal("normal"), true)
  G.eq(C.is_normal("legendary"), false)
  G.eq(C.is_normal({ name = "normal" }), true)
end

-- 6. resolve: near=player, center, без помощника
do
  local w = G.reset()
  local C = require("scripts.perception.state").common
  G.raises("no_helper", function() C.resolve({}, {}) end, "nobody")
  local p = G.add_player(w, { name = "T", pos = { x = 7, y = 8 } })
  local r = C.resolve({}, {})
  G.eq(r.center, { x = 7, y = 8 }, "owner as center when no helper")
  G.eq(r.surface.name, "nauvis")
  G.eq(r.force.name, "player")
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 1, y = 2 } })
  G.eq(C.resolve({}, ctx).center, { x = 1, y = 2 })
  G.eq(C.resolve({ near = "player" }, ctx).center, { x = 7, y = 8 })
  G.eq(C.resolve({ center = { x = 3, y = 4 } }, ctx).center, { x = 3, y = 4 })
  G.raises("bad_args", function() C.resolve({ center = { x = 3, y = 4 }, near = "player" }, ctx) end)
  G.raises("bad_args", function() C.resolve({ near = "helper" }, ctx) end)
  p.connected = false
  G.raises("no_player", function() C.resolve({ near = "player" }, ctx) end, "owner offline")
  p.connected = true
  p.physical_surface = G.surface("vulcanus")
  G.raises("no_player", function() C.resolve({ near = "player" }, ctx) end, "owner on other surface")
end
