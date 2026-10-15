-- Действие walk: ACTIONS.md список v1, PROTOCOL §6.1.
local S = require("stubs")
local B = require("stubs_b")

S.suite("move_walk", {
  { "walk на 30 клеток: job_done{pos, walked}, позиция у цели, arrived", function()
      local _, h = B.setup()
      local job = B.act("walk", { to = { x = 32, y = 0 } }).job
      local res = B.run(job, 1000)
      S.eq(res.kind, "job_done", S.dump(res))
      S.eq(res.data["do"], "walk")
      local d = res.data.detail
      S.ok(S.dist(d.pos, { x = 32, y = 0 }) <= 1.05, "у цели: " .. S.dump(d.pos))
      S.ok(d.walked >= 28 and d.walked <= 31, "walked=" .. tostring(d.walked))
      S.ok(S.dist(h.position, { x = 32, y = 0 }) <= 1.05)
      S.eq(h.walking_state.walking, false, "остановился")
      S.eq(#B.events("arrived"), 1)
      S.eq(B.count(storage.path_requests), 0)
  end },

  { "walk по диагонали и с radius", function()
      local _, h = B.setup()
      local job = B.act("walk", { to = { x = -20, y = 25 }, radius = 3 }).job
      local res = B.run(job, 1000)
      S.eq(res.kind, "job_done")
      local dd = S.dist(h.position, { x = -20, y = 25 })
      S.ok(dd <= 3.05, "в радиусе 3: " .. dd)
  end },

  { "walk к цели рядом — сразу done без запроса пути", function()
      local _, h = B.setup()
      local job = B.act("walk", { to = { x = 2.5, y = 0 } }).job
      local res = B.run(job, 5)
      S.eq(res.kind, "job_done")
      S.eq(res.data.detail.walked, 0)
      S.eq(#B.all_requests(), 0)
  end },

  { "walk to player: к хозяину на момент старта", function()
      local p, h = B.setup()
      S.move(p.character, { x = -15, y = 10 })
      local job = B.act("walk", { to = "player" }).job
      local res = B.run(job, 1000)
      S.eq(res.kind, "job_done")
      S.ok(S.dist(h.position, { x = -15, y = 10 }) <= 1.05)
  end },

  { "walk to player: хозяин офлайн -> no_player, на другой поверхности -> not_reachable", function()
      local p = B.setup()
      p.connected = false
      local j1 = B.act("walk", { to = "player" }).job
      S.eq(B.run(j1, 5).data.code, "no_player")
      p.connected = true
      local other = S.surface{ name = "vulcanus" }
      p.character.surface = other
      local j2 = B.act("walk", { to = "player" }).job
      S.eq(B.run(j2, 5).data.code, "not_reachable")
  end },

  { "схема: to обязателен, строка только player, radius ≤ 64", function()
      B.setup()
      S.err(S.req("act", { ["do"] = "walk", args = {} }, "h1"), "bad_args")
      S.err(S.req("act", { ["do"] = "walk", args = { to = "home" } }, "h1"), "bad_args")
      S.err(S.req("act", { ["do"] = "walk", args = { to = { x = 1, y = 1 }, radius = 65 } }, "h1"), "limit")
      S.err(S.req("act", { ["do"] = "walk", args = { to = { x = 1, y = 1 }, speed = 3 } }, "h1"), "bad_args")
  end },

  { "replace: новая задача снимает ходьбу старой", function()
      local _, h = B.setup()
      local j1 = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(20)
      local j2 = B.act("walk", { to = { x = 2, y = 20 } }, { replace = true }).job
      S.eq(B.result(j1).data.code, "cancelled")
      local res = B.run(j2, 1000)
      S.eq(res.kind, "job_done")
      S.ok(S.dist(h.position, { x = 2, y = 20 }) <= 1.05)
  end },

  { "без телепорта: позиция меняется только шагами не длиннее скорости", function()
      local _, h = B.setup()
      local job = B.act("walk", { to = { x = 25, y = -10 } }).job
      local last = { x = h.position.x, y = h.position.y }
      local maxstep = 0
      B.until_(function()
        local d = S.dist(last, h.position)
        if d > maxstep then maxstep = d end
        last = { x = h.position.x, y = h.position.y }
        return B.result(job) ~= nil
      end, 1000)
      S.ok(maxstep <= 0.15 + 1e-9, "шаг " .. maxstep)
      S.eq(B.result(job).kind, "job_done")
  end },

  { "смерть посреди пути: задача снята, запросы забыты", function()
      local _, h = B.setup()
      B.pathfinder = nil
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(3)
      S.eq(B.count(storage.path_requests), 2, "первый запрос — парой")
      S.fire(defines.events.on_entity_died, { entity = h })
      local res = B.result(job)
      S.eq(res.data.code, "no_helper")
      S.eq(B.count(storage.path_requests), 0)
  end },
})
