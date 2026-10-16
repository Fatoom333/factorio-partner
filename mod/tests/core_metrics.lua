-- Учёт занятости тела (core.metrics): idle_ticks и доля занятости в state.
local S = require("stubs")
local C = require("stubs_c")

-- Настоящая долгая задача (ходьба с очень медленным фейковым path) и её отмена.
local function set_active(W, on)
  if on then
    W.path.speed = 0.001
    S.okr(C.act("walk", { to = { x = 500, y = 0 } }))
    C.run(1)
  else
    S.okr(S.req("cancel", { all = true }, "h1"))
  end
end

S.suite("core_metrics", {
  { "без задачи idle_ticks растёт, с задачей — 0", function()
      local W = C.setup()
      local M = require("scripts.core.metrics")
      set_active(W, false)
      C.run(300)
      local idle = M.snapshot("h1", game.tick)
      S.ok(idle >= 270 and idle <= 300, "idle_ticks: " .. idle)
      set_active(W, true)
      S.eq((M.snapshot("h1", game.tick)), 0, "с задачей сразу 0")
      C.run(60)
      S.eq((M.snapshot("h1", game.tick)), 0)
      set_active(W, false)
      C.run(90)
      local idle2 = M.snapshot("h1", game.tick)
      S.ok(idle2 > 0 and idle2 <= 90, "счёт idle заново: " .. idle2)
  end },
  { "доля занятости: половина времени с задачей — около 0.5", function()
      local W = C.setup()
      local M = require("scripts.core.metrics")
      set_active(W, true); C.run(600)
      set_active(W, false); C.run(600)
      local _, share, win = M.snapshot("h1", game.tick)
      S.ok(share ~= nil and share > 0.4 and share < 0.6, "share: " .. tostring(share))
      S.ok(win >= 1000, "окно: " .. win)
  end },
  { "старые минуты выходят из окна", function()
      local W = C.setup()
      local M = require("scripts.core.metrics")
      set_active(W, true); C.run(1200)
      set_active(W, false)
      C.run(M.BUCKET * (M.WINDOW_MIN + 1))
      local _, share = M.snapshot("h1", game.tick)
      S.ok(share ~= nil and share < 0.01, "share: " .. tostring(share))
  end },
  { "отрезок через границу минуты делится между корзинами", function()
      C.setup()
      local M = require("scripts.core.metrics")
      storage.metrics = {}
      storage.helpers = { x = { state = "alive" } }
      local r = { last = M.BUCKET - 10, buckets = {} }
      storage.metrics.x = r
      -- учёт напрямую: 30 тиков, из них 10 в предыдущей минуте
      local sampled = M.sample
      storage.jobs = nil
      sampled(M.BUCKET + 20)
      local prev, cur = r.buckets[0], r.buckets[1]
      S.eq(prev.total, 10)
      S.eq(cur.total, 20)
  end },
  { "смерть не сбрасывает учёт, helper_remove (записи нет) — снимает", function()
      C.setup()
      local M = require("scripts.core.metrics")
      storage.metrics = {}
      storage.helpers = { x = { state = "alive" } }
      M.sample(100)
      M.sample(130)
      local r = storage.metrics.x
      S.ok(r ~= nil and r.buckets[0].total == 30, "учёт идёт")
      storage.helpers.x.state = "dead"
      M.sample(1000)
      S.eq(storage.metrics.x, r, "запись цела")
      storage.helpers.x.state = "alive"
      M.sample(1030)
      S.eq(storage.metrics.x, r, "та же запись после возрождения")
      S.eq(r.buckets[0].total, 60, "мёртвое время не посчитано")
      storage.helpers.x = nil
      M.sample(1060)
      S.eq(storage.metrics.x, nil, "записи помощника нет — учёт снят")
  end },
  { "state отдаёт поля idle_ticks, busy_share, busy_window", function()
      local W = C.setup()
      set_active(W, false)
      C.run(120)
      local ctx = { helper_id = "h1", entity = storage.helpers.h1.entity }
      local d = require("scripts.perception.state").ops.state({}, ctx)
      S.ok(type(d.idle_ticks) == "number" and d.idle_ticks > 0, "idle_ticks")
      S.eq(d.busy_share, 0)
      S.ok(d.busy_window > 0, "busy_window")
  end },
  { "мёртвый помощник не копится, но запись не теряется", function()
      local W = C.setup()
      C.run(120)
      storage.helpers.h1.state = "dead"
      local total = storage.metrics.h1.buckets[0].total
      C.run(60)
      S.ok(storage.metrics.h1 ~= nil, "запись цела")
      S.eq(storage.metrics.h1.buckets[0].total, total, "мёртвое время не копится")
  end },
})
