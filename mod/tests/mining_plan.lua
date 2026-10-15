-- Действие plan_mining: раскладка simple — счёт, призраки, покрытие, сторона ленты.
-- ACTIONS.md «plan_mining», PROTOCOL §6.5 (manual_ghost), §6.11 (quality normal).
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_m")

local DIRS = { "north", "east", "south", "west" }

S.suite("mining_plan", {
  { "dry_run: считает призраки и предметы, ничего не ставит", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local d, kind = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      S.ok(t.ghosts > 0, "ghosts > 0")
      S.eq(t.layout, "simple")
      S.eq(t.dry_run, true)
      S.ok((t.need["electric-mining-drill"] or 0) > 0, "нужны буры: " .. S.dump(t.need))
      S.ok((t.need["transport-belt"] or 0) > 0, "нужна лента")
      S.ok((t.need["small-electric-pole"] or 0) > 0, "нужны столбы")
      S.eq(t.drills, t.need["electric-mining-drill"])
      S.eq(#X.ghosts(), 0, "dry_run не ставит призраки")
      S.ok(#X.checks >= t.ghosts, "каждый призрак проверен")
      S.eq(t.chosen, { miner = "electric-mining-drill", belt = "transport-belt", pole = "small-electric-pole" })
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "без dry_run: призраки силы хозяина, manual_ghost, quality normal, need = счёт призраков", function()
      local W = X.setup()
      local ore = X.patch("iron-ore", 0, 0, 12, 9)
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      local ghosts = X.ghosts()
      S.eq(#ghosts, t.ghosts, "detail.ghosts = число созданных призраков")
      S.eq(t.dry_run, nil)
      for _, g in ipairs(ghosts) do
        S.eq(g.kind, "entity-ghost")
        S.eq(g.force, W.h.force, "сила хозяина")
        S.eq(g.quality, "normal")
        S.eq(g.raise_built, true)
      end
      local n = 0
      for _, c in ipairs(X.checks) do
        S.eq(c.kind, "manual_ghost", "проверка постановки — manual_ghost")
        S.eq(c.force, W.h.force)
        n = n + 1
      end
      -- расчёт идёт дважды: сухой прогон (область и «встанет ли») и настоящий
      S.eq(n, 2 * #ghosts, "две проверки на призрак: сухой прогон и настоящий")
      S.eq(t.need, X.ghost_counts(), "need — по одному предмету на призрак")
      S.eq(t.skipped, 0)
      local ok, missed = X.covered(ore, "electric-mining-drill")
      S.ok(ok, "буры покрывают всю руду, мимо: " .. missed)
      -- область охватывает все призраки
      for _, g in ipairs(ghosts) do
        S.ok(g.pos.x >= t.area.left_top.x and g.pos.x <= t.area.right_bottom.x
          and g.pos.y >= t.area.left_top.y and g.pos.y <= t.area.right_bottom.y, "призрак вне area: " .. S.dump(g))
      end
      S.ok(t.area.right_bottom.x - t.area.left_top.x <= 128)
  end },
  { "лента выходит в заданную сторону (все четыре)", function()
      for _, dir in ipairs(DIRS) do
        X.setup()
        local ore = X.patch("iron-ore", 0, 0, 12, 9)
        local d, kind = X.plan{ near = { x = 5, y = 4 }, direction = dir }
        S.eq(kind, "job_done", dir .. ": " .. S.dump(d))
        local belts = X.ghosts("transport-belt")
        S.ok(#belts > 0, dir .. ": есть лента")
        local far = belts[1]
        for _, b in ipairs(belts) do
          S.eq(b.direction, X.D[dir], dir .. ": лента смотрит в сторону выхода")
          if dir == "north" and b.pos.y < far.pos.y then far = b end
          if dir == "south" and b.pos.y > far.pos.y then far = b end
          if dir == "west" and b.pos.x < far.pos.x then far = b end
          if dir == "east" and b.pos.x > far.pos.x then far = b end
        end
        -- конец ленты — не ближе крайнего бура с нужной стороны (лента выходит из раскладки туда)
        for _, m in ipairs(X.ghosts("electric-mining-drill")) do
          if dir == "north" then S.ok(far.pos.y <= m.pos.y, "north: " .. S.dump(far.pos)) end
          if dir == "south" then S.ok(far.pos.y >= m.pos.y, "south: " .. S.dump(far.pos)) end
          if dir == "west" then S.ok(far.pos.x <= m.pos.x, "west: " .. S.dump(far.pos)) end
          if dir == "east" then S.ok(far.pos.x >= m.pos.x, "east: " .. S.dump(far.pos)) end
        end
        -- призраки стоят по сетке: постройка 1×1 — в центре клетки
        S.eq(far.pos.x % 1, 0.5)
        S.eq(far.pos.y % 1, 0.5)
        S.ok(X.covered(ore, "electric-mining-drill"), dir .. ": руда покрыта")
      end
  end },
  { "занятое место: призрак пропущен, предупреждение skipped; всё занято — cannot_place", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local d0 = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      local total = d0.detail.ghosts
      -- первый бур из проверок сухого прогона
      local first
      for _, c in ipairs(X.checks) do
        if c.name == "electric-mining-drill" then first = c break end
      end
      X.blocked[X.key(first.pos)] = true
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.ghosts, total - 1)
      S.eq(d.detail.skipped, 1)
      local found = false
      for _, w in ipairs(d.detail.warnings) do
        if w == "skipped:electric-mining-drill:1" then found = true end
      end
      S.ok(found, "предупреждение о пропуске: " .. S.dump(d.detail.warnings))
      S.eq(#X.ghosts(), total - 1)

      X.block_all = true
      local d2, kind2 = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(kind2, "job_failed", S.dump(d2))
      S.eq(d2.code, "cannot_place")
      S.eq(d2.detail.ghosts, 0)
      S.ok(d2.detail.skipped > 0)
  end },
  { "повторная разметка того же пятна не ставит призраки поверх своих", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local d1 = X.plan{ near = { x = 5, y = 4 } }
      local n = #X.ghosts()
      S.eq(d1.detail.ghosts, n)
      local d2, kind2 = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind2, "job_failed", S.dump(d2))
      S.eq(d2.code, "cannot_place")
      S.eq(#X.ghosts(), n, "новых призраков нет")
  end },
  { "деревья и камни на пути помечаются к сносу силой хозяина (как Shift); dry_run не помечает", function()
      local W = X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      local drill
      for _, c in ipairs(X.checks) do
        if c.name == "electric-mining-drill" then drill = c break end
      end
      S.eq(drill.forced, true, "с пометкой деревьев проверка идёт с forced")
      X.tree({ x = drill.pos.x + 0.3, y = drill.pos.y - 0.4 })
      X.tree({ x = drill.pos.x - 0.6, y = drill.pos.y + 0.2 }, "big-rock")
      X.tree({ x = -40.5, y = -40.5 }) -- далеко: не трогаем
      local d = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(#X.marked, 0, "dry_run ничего не помечает")
      local seen = false
      for _, w in ipairs(d.detail.warnings) do if w == "marked_for_deconstruction:2" then seen = true end end
      S.ok(seen, S.dump(d.detail.warnings))

      local d2, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d2))
      S.eq(#X.marked, 2)
      for _, m in ipairs(X.marked) do S.eq(m.force, W.h.force) end
  end },
  { "options.deconstruct=false: деревья не помечаются, проверка без forced", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.tree({ x = 4.5, y = 1.5 })
      local d, kind = X.plan{ near = { x = 5, y = 4 }, options = { deconstruct = false } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(#X.marked, 0)
      for _, c in ipairs(X.checks) do S.eq(c.forced, false) end
  end },
  { "состояние раскладки переживает сохранение и загрузку посреди расчёта (в storage нет функций)", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 20, 15)
      local job = S.okr(C.act("plan_mining", { near = { x = 5, y = 4 } })).job
      C.run(4)
      local t = storage.jobs.by_helper.h1.active
      S.ok(t and t.mpp, "расчёт идёт: состояние в task.mpp")
      S.ok(t.mpp.grid ~= nil, "сетка уже создана")
      S.reload()
      local d, kind = C.wait(job, 2000)
      S.eq(kind, "job_done", S.dump(d))
      S.ok(d.detail.ghosts > 0)
      S.eq(#X.ghosts(), d.detail.ghosts)
  end },
  { "отмена посреди расчёта: состояние сброшено, задача cancelled", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 20, 15)
      local job = S.okr(C.act("plan_mining", { near = { x = 5, y = 4 } })).job
      C.run(3)
      local t = storage.jobs.by_helper.h1.active
      S.ok(t and t.mpp)
      S.okr(S.req("cancel", { job = job }, "h1"))
      C.run(2)
      local d, kind = C.result(job)
      S.eq(kind, "job_failed")
      S.eq(d.code, "cancelled")
      S.eq(t.mpp, nil, "тяжёлое состояние освобождено")
  end },
  { "помощник никуда не идёт и ничего не тратит", function()
      local W = X.setup{ items = { ["iron-plate"] = 10 } }
      X.patch("iron-ore", 30, 30, 12, 9)
      local before = S.copy(W.h.position)
      local d, kind = X.plan{ near = { x = 35, y = 34 } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(W.h.position, before)
      S.eq(#W.path.calls, 0, "путь не запрашивался")
      S.eq(C.counts(W.main), { ["iron-plate"] = 10 })
  end },
  { "итог влезает в событие (≤ 4000 байт)", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 40, 30)
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(#helpers.table_to_json(d) < 4000)
      S.ok(#d.detail.warnings <= 20)
  end },
})
