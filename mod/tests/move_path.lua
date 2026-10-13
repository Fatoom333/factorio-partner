-- Модуль пути scripts/lib/path.lua (поток B): ACTIONS.md «Модуль пути», PROTOCOL §6.1, §6.7.
local S = require("stubs")
local B = require("stubs_b")

local function path_mod() return require("scripts.lib.path") end

local function walking(h) return h.walking_state and h.walking_state.walking end

S.suite("move_path", {
  { "direction: 8 направлений из вектора (север 0, восток 4, юг 8, запад 12)", function()
      B.setup()
      local P = path_mod()
      local d = defines.direction
      S.eq(P.direction(0, -1), d.north)
      S.eq(P.direction(1, -1), d.northeast)
      S.eq(P.direction(1, 0), d.east)
      S.eq(P.direction(1, 1), d.southeast)
      S.eq(P.direction(0, 1), d.south)
      S.eq(P.direction(-1, 1), d.southwest)
      S.eq(P.direction(-1, 0), d.west)
      S.eq(P.direction(-1, -1), d.northwest)
      S.eq(P.direction(10, 3), d.east, "3/10 < tg 22.5° — прямо")
      S.eq(P.direction(10, 5), d.southeast, "5/10 > tg 22.5° — диагональ")
      S.eq(P.direction(-0.2, -5), d.north)
      S.eq(P.direction(0, 0), nil)
  end },

  { "обработчик on_script_path_request_finished зарегистрирован ядром", function()
      B.setup()
      S.ok(S.handlers[defines.events.on_script_path_request_finished], "нет обработчика")
      S.eq(S.unknown_events.on_script_path_request_finished, nil)
  end },

  { "request_path: entity_to_ignore = тело, сила, маска, учёт в storage.path_requests", function()
      local _, h = B.setup()
      B.pathfinder = nil -- не отвечать
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(2)
      local r = B.last_request()
      S.ok(r, "запроса пути нет")
      S.ok(r.params.entity_to_ignore == h, "entity_to_ignore — не тело помощника")
      S.ok(r.params.force == h.force, "сила")
      S.eq(r.params.goal, { x = 30, y = 0 })
      S.ok(r.params.collision_mask ~= nil, "маска столкновений")
      S.ok(r.params.bounding_box ~= nil, "коробка")
      S.eq(storage.path_requests[r.id].helper, "h1")
      S.eq(storage.path_requests[r.id].job, job)
      S.eq(walking(h), false, "пока путь считается — стоим")
  end },

  { "try_again_later: повтор через 60 тиков, после 10 повторов path_failed", function()
      local _, h = B.setup()
      B.pathfinder = function() return { try_again_later = true } end
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      local res = B.run(job, 2000)
      S.eq(res.kind, "job_failed")
      S.eq(res.data.code, "path_failed")
      local all = B.all_requests()
      S.eq(#all, 11, "1 запрос + 10 повторов")
      S.eq(B.count(storage.path_requests), 0, "запросы забыты")
      S.eq(walking(h), false)
  end },

  { "try_again_later, потом путь — идём", function()
      local _, h = B.setup()
      local n = 0
      B.pathfinder = function(params)
        n = n + 1
        if n <= 3 then return { try_again_later = true } end
        return B.straight_path(params)
      end
      local job = B.act("walk", { to = { x = 20, y = 0 } }).job
      local res = B.run(job, 3000)
      S.eq(res.kind, "job_done")
      S.ok(S.dist(h.position, { x = 20, y = 0 }) <= 1, "дошёл")
      S.ok(game.tick >= 3 * 60, "повторы не раньше чем через 60 тиков")
  end },

  { "пути нет (вода/лава) -> path_failed", function()
      local _, h = B.setup()
      B.pathfinder = function() return {} end
      local job = B.act("walk", { to = { x = 30, y = 5 } }).job
      local res = B.run(job, 200)
      S.eq(res.data.code, "path_failed")
      S.eq(walking(h), false)
  end },

  { "цель в неоткрытом чанке -> not_charted, путь не запрашивается", function()
      local _, h = B.setup()
      h.force.uncharted[B.chunk_key(S.nauvis, 200, 0)] = true
      local job = B.act("walk", { to = { x = 200, y = 0 } }).job
      local res = B.run(job, 10)
      S.eq(res.data.code, "not_charted")
      S.eq(#B.all_requests(), 0)
  end },

  { "путь через неоткрытый чанк -> not_charted", function()
      local _, h = B.setup()
      h.force.uncharted[B.chunk_key(S.nauvis, 40, 0)] = true -- чанк (1,0) между помощником и целью
      local job = B.act("walk", { to = { x = 80, y = 0 } }).job
      local res = B.run(job, 50)
      S.eq(res.data.code, "not_charted")
      S.eq(walking(h), false)
  end },

  { "застрял: 60 тиков без сдвига -> перепланирование 1 раз -> stuck + событие stuck", function()
      local _, h = B.setup()
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(10)
      B.blocked = function() return true end
      local res = B.run(job, 1000)
      S.eq(res.data.code, "stuck")
      S.eq(#B.all_requests(), 2, "первый путь + одно перепланирование")
      -- шумное stuck — при перепланировании; финал — громкое job_failed{stuck} (EVENTS.md)
      local st = B.events("stuck")
      S.eq(#st, 1)
      S.eq(st[1].data.job, job)
      S.eq(st[1].data.reason, "no_progress")
      S.eq(st[1].loud, false)
      S.ok(st[1].data.pos, "pos в событии")
      S.eq(walking(h), false)
      S.eq(B.count(storage.path_requests), 0)
  end },

  { "игрок на пути: обход — новый путь со смещённой целью", function()
      local p, h = B.setup()
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(5)
      -- игрок встал вплотную и «держит» помощника
      S.move(p.character, { x = h.position.x + 0.5, y = h.position.y })
      local blocked_until = game.tick + 200
      B.blocked = function(e) return e == h and game.tick < blocked_until end
      B.tick(70)
      local r = B.last_request()
      S.ok(r.params.goal.y ~= 0, "цель смещена вбок")
      S.near(math.abs(r.params.goal.y), 2, 0.01)
      local st = B.events("stuck")
      S.eq(#st, 1, "обход — шумное stuck")
      S.eq(st[1].data.reason, "blocked")
      S.eq(st[1].loud, false)
      local res = B.run(job, 2000)
      S.eq(res.kind, "job_done", "после обхода дошёл")
      S.ok(S.dist(h.position, { x = 30, y = 0 }) <= 1)
  end },

  { "cancel: снимает walking_state и забывает запросы задачи", function()
      local _, h = B.setup()
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(20)
      S.eq(walking(h), true)
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(walking(h), false)
      S.eq(B.count(storage.path_requests), 0)
      local x = h.position.x
      B.tick(10)
      S.eq(h.position.x, x, "больше не идёт")
  end },

  { "cancel во время расчёта пути: поздний ответ игнорируется", function()
      local _, h = B.setup()
      B.pathfinder = nil
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(3)
      local r = B.last_request()
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(B.count(storage.path_requests), 0)
      B.answer(r.id, B.straight_path(r.params))
      B.tick(5)
      S.eq(walking(h), false)
      S.eq(B.count(storage.path_requests), 0)
  end },

  { "path.step: другая поверхность -> not_reachable; distance 0 не ниже ARRIVE", function()
      local _, h = B.setup()
      local P = path_mod()
      local task = { job = 99, helper = "h1" }
      local ctx = { entity = h, tick = game.tick, emit = function() end }
      local r = P.step(task, ctx, { x = 5, y = 0, surface = "vulcanus" }, 1)
      S.eq(r.code, "not_reachable")
      local r2 = P.step(task, ctx, { x = h.position.x + 0.2, y = h.position.y }, 0)
      S.eq(r2, true)
  end },

  { "сохранение посреди пути: в storage нет функций, ходьба продолжается", function()
      local _, h = B.setup()
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(30)
      S.reload()
      local res = B.run(job, 2000)
      S.eq(res.kind, "job_done")
  end },

  { "маршрут с поворотами и неосевыми отрезками: доходит, не разворачивается назад", function()
      local _, h = B.setup()
      B.pathfinder = function(params)
        local s = params.start
        local pts = { { s.x, s.y }, { s.x + 3, s.y + 1 }, { s.x + 6, s.y + 1.4 }, { s.x + 6.3, s.y + 5 },
          { s.x + 10, s.y + 8.7 }, { params.goal.x, params.goal.y } }
        local path = {}
        for i, p in ipairs(pts) do path[i] = { position = { x = p[1], y = p[2] } } end
        return { path = path }
      end
      local job = B.act("walk", { to = { x = 2 + 14, y = 12 } }).job
      local steps_back, last = 0, nil
      B.until_(function()
        local d = S.dist(h.position, { x = 16, y = 12 })
        if last and d > last + 0.2 then steps_back = steps_back + 1 end
        last = d
        return B.result(job) ~= nil
      end, 1000)
      S.eq(B.result(job).kind, "job_done")
      S.ok(steps_back <= 2, "разворотов: " .. steps_back)
  end },

  { "gc: старые записи запросов удаляются", function()
      B.setup()
      local P = path_mod()
      storage.path_requests[777] = { helper = "x", job = 1, tick = 0 }
      P.gc(P.REQUEST_TTL + 1)
      S.eq(storage.path_requests[777], nil)
  end },

  { "цель сдвигается (follow): маршрут перестраивается не чаще раза в 30 тиков", function()
      local _, h = B.setup()
      local P = path_mod()
      local task = { job = 50, helper = "h1" }
      local function ctx() return { entity = h, tick = game.tick, emit = function() end } end
      local goal = { x = 20, y = 0 }
      -- ручной цикл: шаг пути каждый тик, цель уезжает на 0.2 клетки за тик
      for _ = 1, 120 do
        local r = P.step(task, ctx(), goal, 2)
        S.eq(r, nil)
        goal = { x = goal.x, y = goal.y + 0.2 }
        B.tick(1)
      end
      local n = #B.all_requests()
      S.ok(n >= 2 and n <= 5, "перепланирований: " .. n)
      P.cancel(task, ctx())
      S.eq(task.approach, nil)
  end },

  { "path_lost и «не двигаюсь» в одном тике: одно шумное stuck и один новый запрос (ревизия 3.2)", function()
      local _, h = B.setup()
      local P = path_mod()
      local task = { job = 60, helper = "h1" }
      local emitted = {}
      local function ctx()
        return { entity = h, tick = game.tick, emit = function(kind, data) emitted[#emitted + 1] = { kind = kind, data = data } end }
      end
      local goal = { x = 30, y = 0 }
      for _ = 1, 10 do
        S.eq(P.step(task, ctx(), goal, 1), nil)
        B.tick(1)
      end
      local st = task.approach
      S.eq(st.state, "walking")
      S.eq(#emitted, 0)
      -- тело упёрлось и стоит уже 60 тиков, а ждущий запрос пути потерян (как после загрузки сейва)
      B.blocked = function() return true end
      B.pathfinder = nil -- «движок» больше не отвечает: перепланирование остаётся незавершённым
      st.path_id = 987654
      st.last_move_tick = game.tick - P.STUCK_TICKS
      local before = #B.all_requests()
      S.eq(P.step(task, ctx(), goal, 1), nil)
      S.eq(#emitted, 1, "одно событие на одно перепланирование")
      S.eq({ emitted[1].kind, emitted[1].data.reason, emitted[1].data.job }, { "stuck", "path_lost", 60 })
      S.eq(#B.all_requests(), before + 1, "и один новый запрос пути, а не два")
      S.eq(B.count(storage.path_requests), 1, "только что отправленный запрос не выброшен")
      -- пока маршрут не пришёл, новые причины молчат; счётчик перепланирований при этом идёт
      for _ = 1, P.STUCK_TICKS + 5 do
        B.tick(1)
        local r = P.step(task, ctx(), goal, 1)
        if r ~= nil then break end
      end
      S.eq(#emitted, 1, "повторного шумного stuck на то же перепланирование нет")
      S.eq(task.approach.replans, 1)
      -- маршрут пришёл — перепланирование закончено, следующее застревание снова видно агенту
      B.blocked = nil
      B.pathfinder = B.straight_path
      for _ = 1, 20 do
        B.tick(1)
        S.eq(P.step(task, ctx(), goal, 1), nil)
      end
      S.eq(task.approach.noted, nil)
      S.eq(task.approach.state, "walking")
      B.blocked = function() return true end
      local p = S.add_player{ name = "Blocker", position = { h.position.x + 0.5, h.position.y } }
      for _ = 1, P.STUCK_TICKS + 2 do
        B.tick(1)
        P.step(task, ctx(), goal, 1)
      end
      S.eq(#emitted, 2)
      S.eq(emitted[2].data.reason, "blocked")
      P.cancel(task, ctx())
  end },

  { "потерянный запрос при планировании: шумное path_lost одно, пока маршрут не пришёл", function()
      local _, h = B.setup()
      local P = path_mod()
      B.pathfinder = nil
      local job = B.act("walk", { to = { x = 30, y = 0 } }).job
      B.tick(3)
      storage.path_requests = {} -- запросы потеряны
      B.tick(2)
      S.eq(#B.events("stuck"), 1)
      S.eq(B.events("stuck")[1].data.reason, "path_lost")
      storage.path_requests = {}
      B.tick(2)
      S.eq(#B.events("stuck"), 1, "маршрут так и не пришёл — то же перепланирование, второго события нет")
      B.pathfinder = B.straight_path
      S.eq(B.run(job, 2000).kind, "job_done")
  end },
})
