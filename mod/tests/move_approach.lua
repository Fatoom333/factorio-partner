-- Действие approach (поток B): ACTIONS.md «Подход», список v1.
local S = require("stubs")
local B = require("stubs_b")

S.suite("move_approach", {
  { "к сундуку по unit_number: встаёт в reach (10), detail.pos", function()
      local _, h = B.setup()
      local chest = S.nauvis.create_entity{ name = "iron-chest", position = { x = 40.5, y = 0.5 }, force = "player" }
      local job = B.act("approach", { target = { unit_number = chest.unit_number } }).job
      local res = B.run(job, 1000)
      S.eq(res.kind, "job_done", S.dump(res))
      local d = S.dist(h.position, chest.position)
      S.ok(d <= 10 and d >= 8, "в досягаемости, но не вплотную: " .. d)
      S.ok(res.data.detail.pos, "pos")
      S.eq(#B.events("arrived"), 1)
  end },

  { "к сущности по name+pos и с distance", function()
      local _, h = B.setup()
      local f = S.nauvis.create_entity{ name = "stone-furnace", position = { x = -20, y = 15 }, force = "player" }
      local job = B.act("approach", { target = { name = "stone-furnace", pos = { x = -20, y = 15 } }, distance = 2 }).job
      local res = B.run(job, 1000)
      S.eq(res.kind, "job_done")
      S.ok(S.dist(h.position, f.position) <= 2)
  end },

  { "к большой постройке с малой distance: не ближе половины её размера (не stuck)", function()
      local _, h = B.setup()
      local big = S.nauvis.create_entity{ name = "assembling-machine-1", position = { x = 25, y = 0 }, force = "player" }
      big.bounding_box = { left_top = { x = 22.5, y = -2.5 }, right_bottom = { x = 27.5, y = 2.5 } }
      local job = B.act("approach", { target = { unit_number = big.unit_number }, distance = 1 }).job
      local res = B.run(job, 1000)
      S.eq(res.kind, "job_done")
      local d = S.dist(h.position, big.position)
      S.ok(d <= 3.1 and d > 2.4, "у края: " .. d)
  end },

  { "к нейтральному (дерево) можно; к чужому -> not_found", function()
      B.setup()
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 15, y = 0 }, force = "neutral" }
      local j1 = B.act("approach", { target = { unit_number = tree.unit_number } }).job
      S.eq(B.run(j1, 1000).kind, "job_done")
      local bug = S.nauvis.create_entity{ name = "small-biter", position = { x = 30, y = 0 }, force = "enemy" }
      local j2 = B.act("approach", { target = { unit_number = bug.unit_number } }).job
      S.eq(B.run(j2, 5).data.code, "not_found")
      local j3 = B.act("approach", { target = { unit_number = 999999 } }).job
      S.eq(B.run(j3, 5).data.code, "not_found")
      local j4 = B.act("approach", { target = { name = "no-such-thing", pos = { x = 1, y = 1 } } }).job
      S.eq(B.run(j4, 5).data.code, "not_found")
  end },

  { "цель на другой поверхности -> not_reachable", function()
      B.setup()
      local v = S.surface{ name = "vulcanus" }
      local chest = v.create_entity{ name = "iron-chest", position = { x = 5, y = 5 }, force = "player" }
      local job = B.act("approach", { target = { unit_number = chest.unit_number } }).job
      S.eq(B.run(job, 5).data.code, "not_reachable")
  end },

  { "ровно одно из target / to, иначе bad_args", function()
      B.setup()
      local j1 = B.act("approach", {}).job
      S.eq(B.run(j1, 5).data.code, "bad_args")
      local j2 = B.act("approach", { to = { x = 1, y = 1 }, target = { unit_number = 1 } }).job
      S.eq(B.run(j2, 5).data.code, "bad_args")
      S.err(S.req("act", { ["do"] = "approach", args = { to = "base" } }, "h1"), "bad_args")
  end },

  { "to: pos и to: player (позиция хозяина отслеживается)", function()
      local p, h = B.setup()
      local j1 = B.act("approach", { to = { x = 0, y = 30 }, distance = 1 }).job
      S.eq(B.run(j1, 1000).kind, "job_done")
      S.ok(S.dist(h.position, { x = 0, y = 30 }) <= 1)
      S.move(p.character, { x = 30, y = 30 })
      local j2 = B.act("approach", { to = "player", distance = 2 }).job
      B.tick(40)
      S.move(p.character, { x = 30, y = 40 }) -- хозяин отошёл
      local res = B.run(j2, 2000)
      S.eq(res.kind, "job_done")
      S.ok(S.dist(h.position, { x = 30, y = 40 }) <= 2, "дошёл до новой позиции хозяина")
  end },

  { "цель исчезла по дороге -> not_found, ходьба снята", function()
      local _, h = B.setup()
      local chest = S.nauvis.create_entity{ name = "iron-chest", position = { x = 60, y = 0 }, force = "player" }
      local job = B.act("approach", { target = { unit_number = chest.unit_number } }).job
      B.tick(30)
      chest.destroy()
      local res = B.run(job, 10)
      S.eq(res.data.code, "not_found")
      S.eq(h.walking_state.walking, false)
  end },

  { "ctx.approach из чужого действия: подход до дистанции, потом true", function()
      local probe = { name = "mine", schema = {} }
      local got
      function probe.start(task, ctx) end
      function probe.tick(task, ctx)
        local r = ctx.approach(task, { x = 25, y = 0 }, 2.7)
        if r == true then got = true return { status = "done", detail = {} } end
        return r
      end
      function probe.stop(task, ctx) ctx.cancel_approach(task) end
      B.setup{ load = { replace = { ["scripts.actions.mine"] = probe } } }
      local h = storage.helpers.h1.entity
      local job = B.act("mine", {}).job
      S.eq(B.run(job, 1000).kind, "job_done")
      S.ok(got)
      S.ok(S.dist(h.position, { x = 25, y = 0 }) <= 2.7)
  end },
})
