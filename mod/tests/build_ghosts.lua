-- Действие build_ghosts (поток F): ACTIONS.md «build_ghosts», PROTOCOL §6.5 (blocked = ghost_revive
-- false), §7 (резерв области). Режимы hand/robots/auto, no_items, stuck с detail, прогресс.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

local function row(name, n, x0, y)
  local out = {}
  for i = 1, n do out[i] = F.ghost(name, { x = x0 + i - 1, y = y }) end
  return out
end

local function build(args) return F.job("build_ghosts", args) end

S.suite("build_ghosts", {
  { "hand: подходит и строит призраки руками (revive{raise_revive} + списание предмета)", function()
      local W = F.setup{ items = { ["iron-chest"] = 5 } }
      row("iron-chest", 3, 20.5, 0.5)
      local d, kind = F.wait(build{ radius = 30, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { built = 3, left = 0, blocked = {}, blocked_total = 0, missing = {} })
      S.eq(#F.built("iron-chest"), 3)
      S.eq(#F.ghosts(), 0)
      S.eq(C.counts(W.main), { ["iron-chest"] = 2 }, "по одному предмету на призрак")
      S.eq({ F.revive_calls, F.raised_revive }, { 3, 3 })
      S.ok(#W.path.calls > 0)
      S.ok(S.dist(W.h.position, { x = 21.5, y = 0.5 }) <= W.h.build_distance + 1)
      S.ok(F.vis.calls >= 3, "обзор — через scripts.core.vis")
      -- проверка «заблокирован» — ghost_revive, с силой призрака
      local n = 0
      for _, c in ipairs(F.checks) do
        if c.kind == "ghost_revive" then
          n = n + 1
          S.eq(c.name, "iron-chest")
          S.eq(c.force, W.h.force)
        end
      end
      S.ok(n >= 3)
      S.eq(#F.script_built(), 0, "призраки оживляются, а не создаются заново")
      S.eq(storage.reservations.areas.h1, nil, "резерв снят после задачи")
  end },
  { "прогресс: шумное job_progress{done,total,built,left}", function()
      F.setup{ items = { ["iron-chest"] = 40 } }
      for y = 0, 3 do row("iron-chest", 10, 30.5, y + 0.5) end
      local job = build{ radius = 50, mode = "hand" }
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 40)
      local ev = C.events("job_progress")
      S.ok(#ev >= 1, "есть job_progress")
      local last = ev[#ev].data
      S.eq(last.job, job)
      S.eq(last.done, last.built)
      S.eq(last.total, last.built + last.left)
      S.eq(last.total, 40)
  end },
  { "предметов не хватило — строит сколько есть, потом no_items с detail", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      row("iron-chest", 3, 8.5, 0.5)
      local d, kind = F.wait(build{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(d.detail.built, 1)
      S.eq(d.detail.left, 2)
      S.eq(d.detail.missing, { ["iron-chest"] = 2 })
      S.eq(#F.built("iron-chest"), 1)
      S.eq(#F.ghosts(), 2)
      S.eq(C.counts(W.main), {})
  end },
  { "заблокированный призрак не строится и уходит в blocked; остальные — done", function()
      local W = F.setup{ items = { ["iron-chest"] = 3 } }
      local g = row("iron-chest", 3, 8.5, 0.5)
      F.blocked[F.key(g[2].position)] = { ghost_revive = true }
      local d, kind = F.wait(build{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.built, d.detail.left, d.detail.blocked_total }, { 2, 0, 1 })
      S.eq(d.detail.blocked, { { name = "iron-chest", pos = { x = 9.5, y = 0.5 }, reason = "blocked" } })
      S.ok(g[2].valid, "чужой заблокированный призрак не трогаем")
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
  { "revive вернул nil — призрак помечается blocked, задача не зацикливается", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      row("iron-chest", 1, 8.5, 0.5)
      F.revive_nil = true
      local d, kind = F.wait(build{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.built, d.detail.blocked_total }, { 0, 1 })
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 }, "предмет не списан")
  end },
  { "не трогает: не-normal качество, постройку без предмета, чужую силу, вне области", function()
      local W = F.setup{ items = { ["iron-chest"] = 9 } }
      F.ghost("iron-chest", { x = 8.5, y = 0.5 }, { quality = "rare" })
      F.ghost("infinity-chest", { x = 9.5, y = 0.5 })
      local foreign = F.ghost("iron-chest", { x = 10.5, y = 0.5 }, { force = "enemy" })
      local far = F.ghost("iron-chest", { x = 80.5, y = 0.5 })
      F.ghost("iron-chest", { x = 11.5, y = 0.5 })
      local d, kind = F.wait(build{ radius = 20, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.built, d.detail.left, d.detail.blocked_total }, { 1, 0, 2 })
      local reasons = {}
      for _, b in ipairs(d.detail.blocked) do reasons[b.name] = b.reason end
      S.eq(reasons, { ["iron-chest"] = "quality", ["infinity-chest"] = "no_item" })
      S.ok(foreign.valid and far.valid)
      S.eq(C.counts(W.main), { ["iron-chest"] = 8 })
  end },
  { "призрак в неоткрытом чанке не считается и не строится", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      local g = F.ghost("iron-chest", { x = 40.5, y = 0.5 })
      F.ghost("iron-chest", { x = 8.5, y = 0.5 })
      local d, kind = F.wait(build{ radius = 60, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 1)
      S.ok(g.valid)
  end },
  { "откат: предмет не списался — постройка убрана, предмет на месте", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      row("iron-chest", 1, 8.5, 0.5)
      F.remove_fails = true
      local d = F.wait(build{ mode = "hand" })
      S.eq(d.detail.built, 0)
      S.eq(#F.built("iron-chest"), 0, "постройки из воздуха нет")
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      -- призрак — план хозяина: после отката он снова стоит на том же месте
      S.ok(F.ghost_restored >= 1)
      local gs = F.ghosts()
      S.eq(#gs, 1)
      S.eq({ gs[1].ghost_name, S.norm_pos(gs[1].position), gs[1].force }, { "iron-chest", { x = 8.5, y = 0.5 }, W.h.force })
  end },
  { "предметы из-под постройки возвращаются помощнику", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      row("iron-chest", 1, 8.5, 0.5)
      F.collided = { { name = "coal", count = 3, quality = "normal" } }
      local d, kind = F.wait(build{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(C.counts(W.main), { coal = 3 })
  end },
  { "призрак под ногами: отходит в сторону и строит", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      local here = { x = math.floor(W.h.position.x) + 0.5, y = math.floor(W.h.position.y) + 0.5 }
      S.move(W.h, here)
      F.ghost("iron-chest", here)
      local d, kind = F.wait(build{ radius = 5, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 1)
      S.eq(#F.built("iron-chest", here), 1)
      S.ok(S.dist(W.h.position, here) > 1)
  end },
  { "до призрака нет пути — он помечается причиной, остальные строятся", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      F.ghost("iron-chest", { x = 3.5, y = 0.5 })
      F.ghost("iron-chest", { x = 40.5, y = 0.5 })
      local orig = W.path.step
      W.path.step = function(task, ctx, goal, dist)
        if goal.x > 30 then return { status = "failed", code = "path_failed", text = "no path" } end
        return orig(task, ctx, goal, dist)
      end
      local d, kind = F.wait(build{ radius = 60, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.built, d.detail.left }, { 1, 0 })
      S.eq(d.detail.blocked[1].reason, "path_failed")
  end },
  { "robots: встаёт в зону робопорта и ждёт дронов; руками не строит", function()
      local W = F.setup{ items = { ["iron-chest"] = 3 } }
      F.give_robots(W.h, 2, 10)
      row("iron-chest", 3, 40.5, 0.5)
      local d, kind = F.wait(build{ radius = 60, mode = "robots" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.built, d.detail.left }, { 3, 0 })
      S.eq(F.robot_built, 3)
      S.eq(F.revive_calls, 0, "руками не строил")
      S.ok(math.abs(W.h.position.x - 41.5) <= 10, "встал в зоне робопорта")
      S.ok(S.dist(W.h.position, { x = 41.5, y = 0.5 }) > 3, "но не вплотную")
      S.eq(C.counts(W.main), {})
      S.eq(W.h.walking_state.walking, false)
  end },
  { "robots: долгий полёт дронов — «пульс» progress_tick, ядро не снимает задачу как stuck", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      F.give_robots(W.h, 1, 10)
      F.flight_ticks = 4500    -- 75 с в полёте
      row("iron-chest", 1, 6.5, 0.5)
      local job = build{ radius = 20, mode = "robots" }
      F.run(4000)
      S.eq(C.result(job), nil, "через 66 с задача ещё жива")
      S.ok(storage.jobs.by_helper.h1.active.progress_tick ~= nil, "пульс ставится")
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 1)
  end },
  { "robots: дронов нет — no_items; дроны стоят — stuck с detail", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      row("iron-chest", 2, 6.5, 0.5)
      local d, kind = F.wait(build{ radius = 20, mode = "robots" })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(d.detail.left, 2)
      F.give_robots(W.h, 2, 10)
      F.robots_stalled = true
      local job = build{ radius = 20, mode = "robots" }
      local d2, k2 = F.wait(job)
      S.eq({ k2, d2.code }, { "job_failed", "stuck" })
      S.eq({ d2.detail.built, d2.detail.left }, { 0, 2 })
      S.eq(d2.detail.missing, {})
      S.eq(#C.events("job_failed"), 2)
  end },
  { "auto: без дронов — руками; дроны стоят 30 с — дальше руками", function()
      local W = F.setup{ items = { ["iron-chest"] = 4 } }
      row("iron-chest", 2, 6.5, 0.5)
      local d, kind = F.wait(build{ radius = 20 })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.built, F.revive_calls }, { 2, 2 })
      F.give_robots(W.h, 2, 10)
      F.robots_stalled = true
      row("iron-chest", 2, 6.5, 3.5)
      local d2, k2 = F.wait(build{ radius = 20 })
      S.eq(k2, "job_done", S.dump(d2))
      S.eq({ d2.detail.built, F.revive_calls, F.robot_built }, { 2, 4, 0 })
  end },
  { "auto: с дронами строят дроны", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      F.give_robots(W.h, 2, 10)
      row("iron-chest", 2, 6.5, 0.5)
      local d, kind = F.wait(build{ radius = 20 })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.built, F.revive_calls, F.robot_built }, { 2, 0, 2 })
  end },
  { "hand: личные дроны на время задачи не вылетают, потом переключатель возвращается", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      F.give_robots(W.h, 2, 10)
      row("iron-chest", 2, 6.5, 0.5)
      local job = build{ radius = 20, mode = "hand" }
      F.run(2)
      S.eq(W.h.allow_dispatching_robots, false)
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ F.revive_calls, F.robot_built }, { 2, 0 })
      S.eq(W.h.allow_dispatching_robots, true)
      -- и при отмене тоже
      row("iron-chest", 1, 50.5, 0.5)
      W.main.insert{ name = "iron-chest", count = 1 }
      local job2 = build{ radius = 60, mode = "hand" }
      F.run(3)
      S.eq(W.h.allow_dispatching_robots, false)
      S.okr(S.req("cancel", { job = job2 }, "h1"))
      S.eq(W.h.allow_dispatching_robots, true)
      S.ok(W.path.cancels > 0)
  end },
  { "резерв области: держится на время задачи, чужой резерв — reserved", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      row("iron-chest", 1, 50.5, 0.5)
      local job = build{ area = { left_top = { x = 40, y = -10 }, right_bottom = { x = 60, y = 10 } }, mode = "hand" }
      F.run(3)
      S.eq(storage.reservations.areas.h1, { left_top = { x = 40, y = -10 }, right_bottom = { x = 60, y = 10 } })
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(storage.reservations.areas.h1, nil)
      storage.reservations.areas.h2 = { left_top = { x = 55, y = 0 }, right_bottom = { x = 70, y = 5 } }
      local d = F.wait(build{ area = { left_top = { x = 40, y = -10 }, right_bottom = { x = 60, y = 10 } } })
      S.eq(d.code, "reserved")
      S.eq(#W.path.calls > 0 and W.path.calls[#W.path.calls].x < 60, true)
  end },
  { "аргументы: area и radius вместе, границы, режим", function()
      F.setup()
      local area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 10, y = 10 } }
      local d = F.wait(build{ area = area, radius = 10 })
      S.eq(d.code, "bad_args")
      S.err(C.act("build_ghosts", { radius = 65 }), "limit")
      S.err(C.act("build_ghosts", { radius = 0 }), "bad_args")
      S.err(C.act("build_ghosts", { mode = "magic" }), "bad_args")
      S.err(C.act("build_ghosts", { area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 200, y = 1 } } }), "limit")
      -- пустая область — сразу done
      local d2, k2 = F.wait(build{ area = area })
      S.eq(k2, "job_done")
      S.eq(d2.detail, { built = 0, left = 0, blocked = {}, blocked_total = 0, missing = {} })
  end },
  { "сохранение и загрузка посреди стройки: задача продолжается", function()
      F.setup{ items = { ["iron-chest"] = 6 } }
      row("iron-chest", 6, 30.5, 0.5)
      local job = build{ radius = 50, mode = "hand" }
      F.run(25)
      S.reload()
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 6)
  end },
  { "detail влезает в событие целиком даже при сотне заблокированных", function()
      F.setup{ items = { ["iron-chest"] = 1 } }
      for i = 1, 100 do
        local g = F.ghost("iron-chest", { x = 5.5 + (i % 10), y = 0.5 + math.floor(i / 10) })
        F.blocked[F.key(g.position)] = { ghost_revive = true }
      end
      local d, kind = F.wait(build{ radius = 30, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.blocked_total, 100)
      S.eq(#d.detail.blocked, 20)
      S.eq(d.detail.truncated, nil)
      S.eq(d.truncated, nil)
  end },
  { "robots/auto: переключатель дронов после задачи возвращается к прежнему значению", function()
      for _, mode in ipairs({ "robots", "auto" }) do
        local W = F.setup{ items = { ["iron-chest"] = 2 } }
        F.give_robots(W.h, 2, 10)
        W.h.allow_dispatching_robots = false   -- хозяин (или прошлая задача) выключил вылет
        row("iron-chest", 2, 6.5, 0.5)
        local job = build{ radius = 20, mode = mode }
        F.run(2)
        S.eq(W.h.allow_dispatching_robots, true, mode .. ": на время задачи дроны вылетают")
        local d, kind = F.wait(job)
        S.eq(kind, "job_done", S.dump(d))
        S.eq(F.robot_built, 2)
        S.eq(W.h.allow_dispatching_robots, false, mode .. ": вернулось прежнее")
      end
  end },
  { "постройка стоит несколько предметов (items_to_place_this count > 1): списывается ровно столько", function()
      local W = F.setup{ items = { ["iron-chest"] = 5 } }
      prototypes.entity["iron-chest"].items_to_place_this = { { name = "iron-chest", count = 2 } }
      row("iron-chest", 3, 8.5, 0.5)
      local d, kind = F.wait(build{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.eq({ d.detail.built, d.detail.left }, { 2, 1 })
      S.eq(d.detail.missing, { ["iron-chest"] = 2 })
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 }, "по два предмета на постройку")
  end },
  { "проверок ghost_revive за пересчёт не больше MAX_BLOCK_CHECKS; сверх лимита блок ловится при постройке", function()
      local W = F.setup{ items = { ["iron-chest"] = 6 } }
      local B = require("scripts.lib.build")   -- после F.setup: мод загружен заново
      local old = B.MAX_BLOCK_CHECKS
      B.MAX_BLOCK_CHECKS = 2
      local ok, e = pcall(function()
        local g = row("iron-chest", 6, 30.5, 0.5)
        -- самый дальний (вне лимита проверок первого пересчёта) заблокирован
        F.blocked[F.key(g[6].position)] = { ghost_revive = true }
        local job = build{ radius = 50, mode = "hand" }
        local n = 0
        for _ = 1, 10 do
          F.run(1)
          for _, c in ipairs(F.checks) do if c.kind == "ghost_revive" then n = n + 1 end end
          if n > 0 then break end
        end
        S.eq(n, 2, "первый пересчёт: проверено не больше лимита (до призраков ещё не дошли)")
        local d, kind = F.wait(job)
        S.eq(kind, "job_done", S.dump(d))
        S.eq({ d.detail.built, d.detail.left, d.detail.blocked_total }, { 5, 0, 1 })
        S.eq(d.detail.blocked[1].pos, { x = 35.5, y = 0.5 })
        S.ok(g[6].valid)
        S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      end)
      B.MAX_BLOCK_CHECKS = old
      if not ok then error(e, 0) end
  end },
  { "призрак с запросом модулей (item_request_proxy): строится, запрос не трогаем, предметы не берутся", function()
      local W = F.setup{ items = { coal = 2 } }   -- coal — «модули» из запроса: их брать нельзя
      W.main.insert{ name = "assembling-machine-1", count = 1 }
      F.ghost("assembling-machine-1", { x = 9.5, y = 0.5 })
      local proxy = { valid = true, type = "item-request-proxy", destroyed = false }
      proxy.destroy = function() proxy.destroyed = true proxy.valid = false end
      F.proxy = proxy
      local d, kind = F.wait(build{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 1)
      S.eq(#F.built("assembling-machine-1"), 1)
      S.ok(proxy.valid and not proxy.destroyed, "запрос модулей остаётся дронам/игроку")
      S.eq(C.counts(W.main), { coal = 2 }, "списана только постройка, остальное не тронуто")
  end },
})
