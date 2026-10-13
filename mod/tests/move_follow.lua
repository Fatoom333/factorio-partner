-- Действие follow (поток B): ACTIONS.md список v1, «пульс» progress_tick.
local S = require("stubs")
local B = require("stubs_b")

S.suite("move_follow", {
  { "рядом с хозяином: стоит, ставит progress_tick, ядро не снимает со stuck; по времени done", function()
      local _, h = B.setup()
      local job = B.act("follow", { duration_s = 70 }).job
      B.tick(65 * 60)
      S.eq(B.result(job), nil, "не снят за 65 с (stuck — 60 с без прогресса)")
      local t = require("scripts.core.jobs").active("h1")
      S.ok(t.progress_tick ~= nil and game.tick - t.progress_tick <= 1, "пульс")
      S.eq(h.walking_state.walking, false)
      local res = B.run(job, 6 * 60)
      S.eq(res.kind, "job_done")
      S.eq(#B.all_requests(), 0, "стоял — путь не искал")
  end },

  { "хозяин уходит — помощник идёт за ним и держится в distance", function()
      local p, h = B.setup()
      local job = B.act("follow", { distance = 3, duration_s = 60 }).job
      B.tick(5)
      -- хозяин идёт на восток 0.15 клетки за тик
      for _ = 1, 300 do
        S.move(p.character, { x = p.character.position.x + 0.15, y = 0 })
        B.tick(1)
      end
      B.tick(200)
      local d = S.dist(h.position, p.character.position)
      S.ok(d <= 4.05, "держится рядом: " .. d)
      S.eq(B.result(job), nil, "ещё следует")
      S.ok(#B.all_requests() >= 1)
  end },

  { "хозяин вышел из игры -> no_player; ходьба снята", function()
      local p, h = B.setup()
      local job = B.act("follow", {}).job
      B.tick(3)
      S.move(p.character, { x = 30, y = 0 })
      B.tick(20)
      p.connected = false
      local res = B.run(job, 5)
      S.eq(res.data.code, "no_player")
      S.eq(h.walking_state.walking, false)
      S.eq(B.count(storage.path_requests), 0)
  end },

  { "хозяин на другой поверхности -> not_reachable", function()
      local p = B.setup()
      local job = B.act("follow", {}).job
      B.tick(3)
      p.character.surface = S.surface{ name = "vulcanus" }
      S.eq(B.run(job, 5).data.code, "not_reachable")
  end },

  { "схема: distance 1..32, duration_s целое 1..3600", function()
      B.setup()
      S.err(S.req("act", { ["do"] = "follow", args = { distance = 0 } }, "h1"), "bad_args")
      S.err(S.req("act", { ["do"] = "follow", args = { duration_s = 1.5 } }, "h1"), "bad_args")
      S.err(S.req("act", { ["do"] = "follow", args = { duration_s = 3601 } }, "h1"), "limit")
  end },
})
