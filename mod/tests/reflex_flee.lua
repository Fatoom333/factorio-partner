-- Рефлексы: flee (отступление обычной ходьбой) и watch (saw_enemy).
-- EVENTS.md reflex_fired/reflex_done/saw_enemy, PROTOCOL §6.1, §6.7.
local S = require("stubs")
local B = require("stubs_b")
local H = require("stubs_h")

local function flee_mod() return require("scripts.reflexes.flee") end

local function walk_jobs()
  local out = {}
  for _, e in ipairs(B.events()) do
    if (e.kind == "job_done" or e.kind == "job_failed") and e.data["do"] == "walk" then out[#out + 1] = e end
  end
  return out
end

S.suite("reflex_flee", {
  { "схема flee и watch: значения по умолчанию, границы, лишние поля", function()
      H.setup()
      S.eq(H.set{ { type = "flee" }, { type = "watch" } }, {
        { type = "flee", radius = 20, distance = 30, on_attack = true, to = "away", resume = true, resume_health = 0.8 },
        { type = "watch", radius = 32, every_s = 10 },
      })
      S.eq(H.set{ { type = "flee", radius = 8, distance = 64, health = 0.3, on_attack = false, to = "spawn" } }[1].to, "spawn")
      local function bad(r, code) S.err(S.req("reflexes", { set = { r } }, "h1"), code) end
      bad({ type = "flee", radius = 33 }, "limit")
      bad({ type = "flee", radius = 3 }, "bad_args")
      bad({ type = "flee", distance = 65 }, "limit")
      bad({ type = "flee", distance = 7 }, "bad_args")
      bad({ type = "flee", health = 1.5 }, "limit")
      bad({ type = "flee", health = -0.1 }, "bad_args")
      bad({ type = "flee", on_attack = "yes" }, "bad_args")
      bad({ type = "flee", to = "moon" }, "bad_args")
      bad({ type = "flee", speed = 9 }, "bad_args")
      bad({ type = "watch", radius = 64 }, "limit")
      bad({ type = "watch", every_s = 0 }, "bad_args")
      bad({ type = "watch", every_s = 1.5 }, "bad_args")
      bad({ type = "death" }, "bad_args")
      bad({ type = "respawn" }, "bad_args")
      S.eq(#storage.reflexes.h1, 1, "неудачные замены набор не трогают")
      for t in pairs(require("scripts.core.reflexes").types) do
        S.ok(t:find("^[a-z][a-z0-9_]*$") and #t <= 32, "имя типа " .. t)
      end
  end },

  { "враг в радиусе: задачи сняты, идёт прочь ходьбой, reflex_fired и reflex_done{ok}", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      local wait = B.act("wait", { seconds = 600 }).job
      local queued = B.act("wait", { seconds = 5 }).job
      B.tick(5)
      local biter = H.enemy({ x = -8, y = 0 })
      B.tick(5)
      local fired = B.events("reflex_fired")
      S.eq(#fired, 1, H.kinds())
      S.eq(fired[1].loud, false)
      S.eq(fired[1].data.type, "flee")
      S.eq(fired[1].data.detail.threat, "small-biter")
      S.eq(fired[1].data.detail.dist, 10)
      S.eq(fired[1].data.detail.to, { x = 32, y = 0 })
      S.eq(B.result(wait).data.code, "cancelled", "задача агента снята")
      S.eq(B.result(queued).data.code, "cancelled", "и очередь тоже")
      local jobs = S.okr(S.req("jobs", {}, "h1"))
      S.eq(jobs.queue[1]["do"], "walk")
      S.eq(jobs.queue[1].req, "reflex:flee")
      S.eq(jobs.queue[1].job, fired[1].data.detail.job)
      -- без переноса: только шаги не длиннее скорости
      local last = { x = h.position.x, y = h.position.y }
      local maxstep = 0
      B.until_(function()
        local d = S.dist(last, h.position)
        if d > maxstep then maxstep = d end
        last = { x = h.position.x, y = h.position.y }
        return B.events("reflex_done")[1] ~= nil
      end, 2000)
      S.ok(maxstep <= 0.15 + 1e-9, "шаг " .. maxstep)
      local done = B.events("reflex_done")[1]
      S.eq(done.loud, true)
      S.eq(done.data.type, "flee")
      S.eq(done.data.outcome, "ok")
      S.eq(done.data.detail.legs, 1)
      S.ok(S.dist(done.data.detail.pos, { x = 32, y = 0 }) <= 2.1, S.dump(done.data.detail))
      S.ok(S.dist(h.position, biter.position) >= 37, "ушёл от врага")
      S.eq(h.walking_state.walking, false)
      S.eq(B.result(fired[1].data.detail.job).kind, "job_done")
      S.eq(storage.reflex_state.h1.flee, nil)
      S.eq(B.count(storage.path_requests), 0)
  end },

  { "нет врагов / враг дальше radius / гнездо / своя сила — не отступает", function()
      local _, h = H.setup()
      H.set{ { type = "flee", radius = 10 } }
      H.enemy({ x = 13, y = 0 })                      -- 11 клеток
      H.enemy({ x = 5, y = 0 }, "biter-spawner")      -- гнездо само не нападает
      S.nauvis.create_entity{ name = "small-biter", position = { 4, 0 }, force = "player" }
      S.nauvis.create_entity{ name = "small-biter", position = { 4, 1 }, force = "neutral" }
      B.tick(60)
      S.eq(#B.events("reflex_fired"), 0)
      S.eq(h.walking_state.walking, false)
      S.eq(#B.all_requests(), 0)
  end },

  { "разрушитель, его сегмент, червь и пентапод — тоже угроза", function()
      for _, name in ipairs({ "small-demolisher", "small-demolisher-segment", "small-worm-turret", "small-strafer-pentapod" }) do
        H.setup()
        H.set{ { type = "flee" } }
        H.enemy({ x = 2, y = 15 }, name)
        B.tick(10)
        local fired = B.events("reflex_fired")
        S.eq(#fired, 1, name)
        S.eq(fired[1].data.detail.threat, name)
        S.eq(fired[1].data.detail.to, { x = 2, y = -30 })
      end
  end },

  { "health: при полном здоровье стоит, после ранения отступает сразу (в тике урона)", function()
      local _, h = H.setup()
      H.set{ { type = "flee", health = 0.5 } }
      H.enemy({ x = -8, y = 0 })
      B.tick(60)
      S.eq(#B.events("reflex_fired"), 0)
      B.tick(3)
      H.damage(h, 100, nil, "poison") -- 150/250 = 60 %
      S.eq(#B.events("reflex_fired"), 0)
      H.damage(h, 30, nil, "poison")  -- 120/250 = 48 %
      S.eq(#B.events("reflex_fired"), 1, "реакция на урон — не дожидаясь проверки раз в 10 тиков")
      S.eq(B.events("reflex_fired")[1].tick, 63)
  end },

  { "on_attack: враг ударил издалека — отступает от него; on_attack=false или свой — нет", function()
      local _, h = H.setup()
      H.set{ { type = "flee", radius = 10 } }
      local worm = H.enemy({ x = 2, y = 30 }, "small-worm-turret")
      local friend = S.nauvis.create_entity{ name = "small-biter", position = { 2, 5 }, force = "player" }
      B.tick(3)
      H.damage(h, 5, friend)
      B.tick(20)
      S.eq(#B.events("reflex_fired"), 0, "свой — не угроза")
      H.damage(h, 5, worm)
      local fired = B.events("reflex_fired")
      S.eq(#fired, 1)
      S.eq(fired[1].data.detail.threat, "small-worm-turret")
      S.eq(fired[1].data.detail.dist, 30)
      S.eq(fired[1].data.detail.to, { x = 2, y = -30 })

      local _, h2 = H.setup()
      H.set{ { type = "flee", radius = 10, on_attack = false } }
      local worm2 = H.enemy({ x = 2, y = 30 }, "small-worm-turret")
      H.damage(h2, 5, worm2)
      B.tick(30)
      S.eq(#B.events("reflex_fired"), 0)
      S.eq(#B.events("attacked"), 1, "но attacked приходит")
  end },

  { "удар издалека устаревает через 2 с", function()
      local _, h = H.setup()
      local worm = H.enemy({ x = 2, y = 30 }, "small-worm-turret")
      H.damage(h, 5, worm)
      B.tick(125)
      H.set{ { type = "flee", radius = 10 } }
      B.tick(30)
      S.eq(#B.events("reflex_fired"), 0)
  end },

  { "точка в неоткрытом чанке или с врагами рядом пропускается", function()
      local _, h = H.setup()
      h.force.uncharted[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true -- там (32, 0)
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 23.2, y = 21.2 }, "первая не годится — +45°")

      local _, h2 = H.setup()
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      H.enemy({ x = 30, y = 3 }) -- 28 клеток от помощника (вне radius), но у точки (32, 0)
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 23.2, y = 21.2 })
  end },

  { "врагов у невидимой точки не знаем (PROTOCOL §6.7) — она годится", function()
      local _, h = H.setup()
      H.set{ { type = "flee", distance = 60 } }
      H.enemy({ x = -8, y = 0 })
      H.enemy({ x = 60, y = 3 })
      h.force.invisible[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true -- (62, 0): дальше 32 и чанк не виден
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 62, y = 0 })

      local _, h2 = H.setup()
      H.set{ { type = "flee", distance = 60 } }
      H.enemy({ x = -8, y = 0 })
      H.enemy({ x = 60, y = 3 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 44.4, y = 42.4 }, "чанк виден (радар) — враг у точки известен")
  end },

  { "нет свободного места ни у одной точки — reflex_done{failed, no_safe_point} один раз", function()
      local _, h = H.setup()
      S.nauvis.non_colliding = false
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(10)
      local done = B.events("reflex_done")
      S.eq(#done, 1)
      S.eq(done[1].data.outcome, "failed")
      S.eq(done[1].data.detail.reason, "no_safe_point")
      S.eq(done[1].data.detail.legs, 0)
      S.eq(#B.events("reflex_fired"), 0)
      B.tick(1800)
      S.eq(#B.events("reflex_done"), 1, "та же причина — молчим")
      S.eq(#walk_jobs(), 0)
      S.nauvis.non_colliding = nil
      B.tick(600)
      S.eq(#B.events("reflex_fired"), 1, "место появилось — отступает")
  end },

  { "путь к первой точке не нашёлся — идёт к следующей; итог один", function()
      local _, h = H.setup()
      B.pathfinder = function(params)
        if S.dist(S.norm_pos(params.goal), { x = 32, y = 0 }) < 1 then return {} end
        return B.straight_path(params)
      end
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "ok", S.dump(done.data))
      S.eq(done.data.detail.legs, 1)
      S.eq(#B.events("reflex_fired"), 1, "reflex_fired — один на всё отступление")
      local wj = walk_jobs()
      S.eq(#wj, 2)
      S.eq({ wj[1].kind, wj[1].data.code, wj[2].kind }, { "job_failed", "path_failed", "job_done" })
      S.ok(S.dist(h.position, { x = 23.2, y = 21.2 }) <= 3, S.dump(h.position))
  end },

  { "пути нет никуда — reflex_done{failed, path_failed}, пауза 10 с, потом новая попытка", function()
      local _, h = H.setup()
      B.pathfinder = function() return {} end
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "failed")
      S.eq(done.data.detail.reason, "path_failed")
      S.eq(#walk_jobs(), 7, "перебраны все 7 направлений")
      S.eq(#B.events("reflex_fired"), 1)
      local t = game.tick
      B.tick(590)
      S.eq(#B.events("reflex_fired"), 1, "пауза")
      B.tick(20)
      S.eq(#B.events("reflex_fired"), 2)
      S.ok(game.tick - t <= 610)
  end },

  { "агент снял задачу отступления — reflex_done{failed, cancelled}, 10 с рефлекс не мешает", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(30)
      S.eq(#B.events("reflex_fired"), 1)
      local fj = B.events("reflex_fired")[1].data.detail.job
      S.eq(S.okr(S.req("cancel", { all = true }, "h1")).cancelled, { fj })
      local own = B.act("wait", { seconds = 5 }).job
      S.eq(h.walking_state.walking, false, "ходьба снята")
      B.tick(10)
      local done = B.events("reflex_done")
      S.eq(#done, 1)
      S.eq({ done[1].data.outcome, done[1].data.detail.reason }, { "failed", "cancelled" })
      B.tick(320)
      S.eq(B.result(own).kind, "job_done", "задача агента дошла до конца")
      S.eq(#B.events("reflex_fired"), 1)
      B.tick(300)
      S.eq(#B.events("reflex_fired"), 2, "враг всё ещё рядом — через 10 с рефлекс снова срабатывает")
  end },

  { "дошёл, а рядом другой враг — ещё переход, итог один (legs=2)", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      H.enemy({ x = -6, y = 0 })
      H.enemy({ x = 47, y = 0 }) -- 15 клеток от точки (32, 0): точка годится, но на месте он ближе radius
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "ok", S.dump(done.data))
      S.eq(done.data.detail.legs, 2)
      S.eq(#B.events("reflex_fired"), 1)
      local wj = walk_jobs()
      S.eq(#wj, 2)
      S.eq({ wj[1].kind, wj[2].kind }, { "job_done", "job_done" })
      S.ok(S.dist(h.position, { x = -6, y = 0 }) > 20 and S.dist(h.position, { x = 47, y = 0 }) > 20, S.dump(h.position))
  end },

  { "переходы кончились, враг рядом — reflex_done{failed, still_threatened}", function()
      local _, h = H.setup()
      flee_mod().MAX_LEGS = 1
      H.set{ { type = "flee" } }
      H.enemy({ x = -6, y = 0 })
      H.enemy({ x = 47, y = 0 })
      local done = H.wait("reflex_done")
      S.eq({ done.data.outcome, done.data.detail.reason, done.data.detail.legs }, { "failed", "still_threatened", 1 })
  end },

  { "to=spawn и to=player; цель рядом или у врага — обычное «прочь»", function()
      local _, h = H.setup()
      h.force.set_spawn_position({ x = 0, y = -40 }, S.nauvis)
      H.set{ { type = "flee", to = "spawn" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 0, y = -40 })

      local _, h2 = H.setup() -- точка возрождения (0,0) — в 2 клетках
      H.set{ { type = "flee", to = "spawn" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 32, y = 0 })

      local p3 = H.setup()
      S.move(p3.character, { x = 0, y = 40 })
      H.set{ { type = "flee", to = "player" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 0, y = 40 })

      local p4 = H.setup()
      S.move(p4.character, { x = -20, y = 0 }) -- хозяин сам рядом с врагом
      H.set{ { type = "flee", to = "player" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 32, y = 0 })

      local p5 = H.setup()
      S.move(p5.character, { x = 0, y = 40 })
      p5.connected = false
      H.set{ { type = "flee", to = "player" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 32, y = 0 })
  end },

  { "набор сняли посреди отступления — оно доводится до итога", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(30)
      H.set{}
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "ok")
      B.tick(100)
      H.enemy({ x = h.position.x + 5, y = 0 })
      B.tick(100)
      S.eq(#B.events("reflex_fired"), 1, "без набора новых отступлений нет")
  end },

  { "сохранение/загрузка посреди отступления — продолжает и доходит", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(60)
      S.reload()
      h = H.body()
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "ok")
      S.ok(S.dist(h.position, { x = 32, y = 0 }) <= 2.1)
  end },

  { "смерть посреди отступления — reflex_done{failed, no_helper}", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      local biter = H.enemy({ x = -8, y = 0 })
      B.tick(30)
      H.damage(h, 999, biter)
      B.tick(10)
      local done = B.events("reflex_done")
      S.eq(#done, 1)
      S.eq({ done[1].data.outcome, done[1].data.detail.reason }, { "failed", "no_helper" })
      S.eq(#B.events("died"), 1)
  end },

  { "helper_remove посреди отступления — без reflex_done (это решение агента)", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(30)
      local job = B.events("reflex_fired")[1].data.detail.job
      S.okr(S.req("helper_remove", {}, "h1"))
      B.tick(20)
      S.eq(B.result(job).data.code, "cancelled")
      S.eq(#B.events("reflex_done"), 0)
      S.eq(#B.events("died"), 0)
      S.eq(storage.reflex_state.h1, nil)
  end },

  { "после удачного отступления новый враг — новое отступление", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      H.wait("reflex_done")
      H.enemy({ x = h.position.x, y = 10 })
      B.tick(70)
      S.eq(#B.events("reflex_fired"), 2)
      S.eq(B.events("reflex_fired")[2].data.detail.to.y < -25, true)
  end },

  { "два помощника: отступает только тот, у кого враг и набор", function()
      local _, h = H.setup()
      B.tick(1)
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h2"))
      local h2 = H.body("h2")
      S.move(h2, { x = 100, y = 100 })
      H.set{ { type = "flee" } }
      H.set({ { type = "flee" } }, "h2")
      H.enemy({ x = 100, y = 90 })
      B.tick(10)
      local fired = B.events("reflex_fired")
      S.eq(#fired, 1)
      S.eq(fired[1].helper, "h2")
      S.eq(fired[1].data.detail.to, { x = 100, y = 130 })
      S.eq(h.walking_state.walking, false)
  end },

  { "watch: шумное saw_enemy о ближайшем (включая гнёзда), не чаще every_s", function()
      local _, h = H.setup()
      H.set{ { type = "watch", radius = 30, every_s = 5 } }
      B.tick(20)
      S.eq(#B.events("saw_enemy"), 0)
      H.enemy({ x = 2, y = 31 })
      H.enemy({ x = 2, y = 25 }, "biter-spawner")
      H.enemy({ x = 22, y = 0 })
      B.tick(10)
      local evs = B.events("saw_enemy")
      S.eq(#evs, 1)
      S.eq(evs[1].loud, false)
      S.eq(evs[1].helper, "h1")
      S.eq(evs[1].data, { name = "small-biter", pos = { x = 22, y = 0 }, dist = 20 })
      B.tick(290)
      S.eq(#B.events("saw_enemy"), 1)
      B.tick(10)
      S.eq(#B.events("saw_enemy"), 2)
      S.eq(h.walking_state.walking, false, "watch никуда не ходит")
  end },

  { "модуль не трогает чужое: в storage.reflexes только набор, состояние — в storage.reflex_state", function()
      local _, h = H.setup()
      H.set{ { type = "flee" }, { type = "watch" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(50)
      S.eq(storage.reflexes.h1, {
        { type = "flee", radius = 20, distance = 30, on_attack = true, to = "away", resume = true, resume_health = 0.8 },
        { type = "watch", radius = 32, every_s = 10 },
      })
      S.ok(storage.reflex_state.h1.flee.job, "идёт отступление")
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },

  { "после неудачи ходьбы кандидаты считаются заново: от нового места и нынешнего врага", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      local biter = H.enemy({ x = -8, y = 0 })
      B.tick(10)
      S.eq(B.events("reflex_fired")[1].data.detail.to, { x = 32, y = 0 })
      B.tick(60) -- прошёл часть пути на восток
      local x1 = h.position.x
      S.ok(x1 > 8, S.dump(h.position))
      -- упёрся: ходьба кончится stuck; тем временем прежний враг пропал, а новый пришёл с севера
      local until_tick = game.tick + 1300 -- дольше выбирания из зоны (ESCAPE_TICKS)
      B.blocked = function() return game.tick < until_tick end
      biter.destroy()
      H.enemy({ x = h.position.x, y = -10 })
      B.until_(function() return #walk_jobs() >= 1 end, 1500)
      S.eq(walk_jobs()[1].data.code, "stuck")
      B.tick(12)
      local f = storage.reflex_state.h1.flee
      S.ok(f, "отступление продолжается: " .. H.kinds())
      -- старый список (от места (2,0) и врага на западе) дал бы (23, 21); новый — прочь от врага на севере
      S.near(f.goal.x, h.position.x, 3)
      S.ok(f.goal.y > 25, S.dump(f.goal))
      S.eq(#f.tried, 1)
      S.eq(f.tried[1], { x = 32, y = 0 })
      S.eq(f.legs, 1, "это тот же переход, а не новый")
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "ok", S.dump(done.data))
      S.eq(#B.events("reflex_fired"), 1)
  end },

  { "испробованная точка не выбирается снова, попыток на переход — не больше MAX_TRIES", function()
      local _, h = H.setup()
      local F = flee_mod()
      F.MAX_TRIES = 3
      B.pathfinder = function() return {} end
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      local done = H.wait("reflex_done")
      S.eq({ done.data.outcome, done.data.detail.reason }, { "failed", "path_failed" })
      local goals, seen = {}, {}
      for _, e in ipairs(B.events()) do
        if e.kind == "job_failed" and e.data["do"] == "walk" then goals[#goals + 1] = e end
      end
      S.eq(#goals, 3, "три попытки и стоп")
      S.eq(storage.reflex_state.h1.flee, nil)
  end },

  { "видимость точки отступления — через core.vis: 32 клетки от тела или видимый чанк", function()
      local _, h = H.setup()
      local C = require("scripts.reflexes.common")
      local calls = {}
      local vis = require("scripts.core.vis")
      local orig = vis.visible
      vis.visible = function(id, surface, pos, force)
        calls[#calls + 1] = { id = id, surface = surface, force = force }
        return orig(id, surface, pos, force)
      end
      S.eq(C.visible("h1", h, { x = 20, y = 0 }), true, "рядом с телом")
      h.force.invisible[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      S.eq(C.visible("h1", h, { x = 100, y = 0 }), false, "далеко и чанк не виден")
      S.eq(C.visible("h1", h, { x = 200, y = 0 }), true, "далеко, но чанк виден силе")
      S.eq(#calls, 3)
      S.eq(calls[1].id, "h1")
      S.eq(calls[1].surface, S.nauvis)
      S.eq(calls[1].force, h.force)
      vis.visible = orig
  end },

  { "возврат к делу: отступление сняло walk — враг ушёл, здоровье есть — мод ставит его снова", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      local o = { x = h.position.x, y = h.position.y }
      B.act("walk", { to = { x = o.x + 40, y = o.y } })
      B.tick(5)
      local foe = H.enemy({ x = h.position.x + 10, y = h.position.y })
      H.wait("reflex_fired")
      foe.destroy()
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "ok", S.dump(done.data))
      local r = H.wait("reflex_resumed")
      S.eq(r.loud, true, "будит агента")
      S.eq(#r.data.jobs, 1, S.dump(r.data))
      S.eq(r.data.jobs[1]["do"], "walk")
      local res = B.run(r.data.jobs[1].job, 3000)
      S.eq(res.kind, "job_done", S.dump(res.data))
      S.ok(h.position.x - o.x >= 39, "дошёл до прежней цели: " .. S.dump(h.position))
  end },
  { "возврат к делу ждёт здоровья; агент за это время поставил своё — мод ничего не возвращает", function()
      local _, h = H.setup()
      h.max_health, h.health = 250, 100 -- 40 %: возврат ждёт resume_health 0.8
      H.set{ { type = "flee" } }
      local o = { x = h.position.x, y = h.position.y }
      B.act("walk", { to = { x = o.x + 40, y = o.y } })
      B.tick(5)
      local foe = H.enemy({ x = h.position.x + 10, y = h.position.y })
      H.wait("reflex_fired")
      foe.destroy()
      H.wait("reflex_done")
      B.tick(30)
      S.eq(#B.events("reflex_resumed"), 0, "здоровья мало — ждёт")
      B.act("walk", { to = { x = o.x, y = o.y + 5 } })
      h.health = 250
      B.tick(600)
      S.eq(#B.events("reflex_resumed"), 0)
  end },
  { "возврат к делу выключен (resume=false) — как раньше, решает агент", function()
      local _, h = H.setup()
      H.set{ { type = "flee", resume = false } }
      B.act("walk", { to = { x = h.position.x + 40, y = h.position.y } })
      B.tick(5)
      local foe = H.enemy({ x = h.position.x + 10, y = h.position.y })
      H.wait("reflex_fired")
      foe.destroy()
      H.wait("reflex_done")
      B.tick(600)
      S.eq(#B.events("reflex_resumed"), 0)
  end },
})
