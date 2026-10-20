-- Дальняя цель: follow за хозяином в сотне клеток и модуль пути (ACTIONS.md `follow`, «Модуль
-- пути»): новый маршрут не тянет тело назад к месту запроса; ушедший хозяин — не «неудача
-- маршрута»; частичный маршрут — не успех; обход лавы отрезками; громкое отставание один раз.
local S = require("stubs")
local B = require("stubs_b")

local function path_mod() return require("scripts.lib.path") end

--- «Движок пути», который отвечает через delay тиков после запроса.
local function slow(delay, inner)
  local seen = {}
  return function(params, id)
    seen[id] = seen[id] or game.tick
    if game.tick - seen[id] < delay then return nil end
    return (inner or B.straight_path)(params)
  end
end

local function said()
  local out = {}
  for _, m in ipairs(game.printed) do out[#out + 1] = m end
  return table.concat(out, "\n")
end

-- Лава: прямоугольник, по которому не ходят и через который движок пути не строит маршрут.
local LAVA = { x1 = 40, x2 = 60, y1 = -30, y2 = 30 }
local function in_lava(p) return p.x > LAVA.x1 and p.x < LAVA.x2 and p.y > LAVA.y1 and p.y < LAVA.y2 end
local function crosses_lava(a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local n = math.ceil(math.sqrt(dx * dx + dy * dy) * 2)
  for k = 0, n do
    if in_lava({ x = a.x + dx * k / n, y = a.y + dy * k / n }) then return true end
  end
  return false
end

S.suite("move_follow_far", {
  { "маршрут считается долго, цель уходит: новый маршрут не тянет тело назад к месту запроса", function()
      local _, h = B.setup()
      local P = path_mod()
      B.pathfinder = slow(60)
      local task = { job = 70, helper = "h1" }
      local function ctx() return { entity = h, tick = game.tick, emit = function() end } end
      local goal = { x = 150, y = 0 }
      local best_x, worst_back = h.position.x, 0
      for _ = 1, 900 do
        S.eq(P.step(task, ctx(), goal, 3), nil)
        goal = { x = goal.x + 0.1, y = 0 }
        B.tick(1)
        if h.position.x > best_x then best_x = h.position.x end
        worst_back = math.max(worst_back, best_x - h.position.x)
      end
      S.ok(worst_back < 1, "назад не ходил: откат " .. worst_back)
      S.ok(h.position.x > 90, "шёл вперёд: x = " .. h.position.x)
      P.cancel(task, ctx())
  end },

  { "follow за далёким уходящим хозяином: маршруты кончаются у его старого места — не path_failed", function()
      local p, h = B.setup()
      S.move(h, { x = -150, y = 0 })
      B.pathfinder = slow(40)
      local job = B.act("follow", { distance = 3, duration_s = 120 }).job
      for _ = 1, 3000 do
        if _ <= 1200 then S.move(p.character, { x = p.character.position.x + 0.1, y = 0 }) end
        B.tick(1)
      end
      S.eq(B.result(job), nil, "ещё следует: " .. S.dump(B.result(job)))
      S.ok(S.dist(h.position, p.character.position) <= 4.05, "догнал: " .. S.dist(h.position, p.character.position))
  end },

  { "частичный маршрут (кончается далеко от цели) — не успех: после 3 таких подряд — отрезками", function()
      local _, h = B.setup()
      -- движок отдаёт маршрут только на 20 клеток в сторону цели, к промежуточной точке — целиком
      B.pathfinder = function(params)
        local s, g = S.norm_pos(params.start), S.norm_pos(params.goal)
        local dx, dy = g.x - s.x, g.y - s.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len <= 50 then return B.straight_path(params) end
        local stop = { x = s.x + dx / len * 20, y = s.y + dy / len * 20 }
        return B.straight_path{ start = s, goal = stop, radius = 0.5 }
      end
      local job = B.act("walk", { to = { x = 300, y = 0 } }).job
      local res = B.run(job, 6000)
      S.eq(res.kind, "job_done", S.dump(res.data))
      S.ok(S.dist(h.position, { x = 300, y = 0 }) <= 1.5, "дошёл")
      local seg = 0
      for _, r in ipairs(B.all_requests()) do
        if r.params.radius == path_mod().SEG_RADIUS then seg = seg + 1 end
      end
      S.ok(seg >= 1, "шёл отрезками: " .. seg)
  end },

  { "дальняя цель за лавой: пути напрямую нет — отрезки в обход сбоку, дошёл", function()
      local _, h = B.setup()
      B.blocked = function(_, np) return in_lava(np) end
      h.surface.non_colliding = function(_, _, c) if in_lava(c) then return nil end return c end
      B.pathfinder = function(params)
        local s, g = S.norm_pos(params.start), S.norm_pos(params.goal)
        if S.dist(s, g) > 60 or crosses_lava(s, g) then return {} end
        return B.straight_path(params)
      end
      local job = B.act("walk", { to = { x = 150, y = 0 } }).job
      local res = B.run(job, 8000)
      S.eq(res.kind, "job_done", S.dump(res.data))
      S.ok(S.dist(h.position, { x = 150, y = 0 }) <= 1.5, "дошёл")
      for _, r in ipairs(B.all_requests()) do
        S.ok(not in_lava(S.norm_pos(r.params.goal)), "точка отрезка не на лаве")
      end
  end },

  { "дальняя цель, пути нет никуда — честный path_failed, без бесконечных отрезков", function()
      local _, h = B.setup()
      B.pathfinder = function() return {} end
      local job = B.act("walk", { to = { x = 200, y = 0 } }).job
      local res = B.run(job, 4000)
      S.eq(res.data.code, "path_failed")
      S.ok(#B.all_requests() <= path_mod().MAX_SEGMENTS + 10, "запросов: " .. #B.all_requests())
      S.eq(h.walking_state.walking, false)
  end },

  { "отстал больше 60 клеток дольше 30 с — громкое follow_lag и одно сообщение хозяину", function()
      local p, h = B.setup()
      local job = B.act("follow", { distance = 3, duration_s = 300 }).job
      -- хозяин уходит вдвое быстрее помощника
      for _ = 1, 3000 do
        S.move(p.character, { x = p.character.position.x + 0.3, y = 0 })
        B.tick(1)
      end
      local ev = B.events("follow_lag")
      S.eq(#ev, 1, "одно событие")
      S.eq(ev[1].loud, true)
      S.eq(ev[1].data.job, job)
      S.ok(ev[1].data.dist > 60, "отставание " .. ev[1].data.dist)
      local text = said()
      local _, n = text:gsub("Отстал на", "")
      S.eq(n, 1, text)
      -- хозяин стоит: догнал, отставание кончилось; снова уходит — снова одно сообщение
      B.until_(function() return S.dist(h.position, p.character.position) <= 4 end, 4000)
      S.eq(require("scripts.core.jobs").active("h1").lag, nil)
      for _ = 1, 3000 do
        S.move(p.character, { x = p.character.position.x + 0.3, y = 0 })
        B.tick(1)
      end
      S.eq(#B.events("follow_lag"), 2)
      S.eq(B.result(job), nil)
  end },
})
