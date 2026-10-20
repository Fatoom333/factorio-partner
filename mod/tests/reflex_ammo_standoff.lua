-- Рефлекс ammo: все турели в досягаемости за проход, один подход к лучшей точке, отстояние от врага.
local S = require("stubs")
local C = require("stubs_c")
local A = require("stubs_ammo")

local function set(list) return S.okr(S.req("reflexes", { set = list }, "h1")).set end

local function body(W) return S.norm_pos(W.h.position) end

local RING = { { 5, 0 }, { -5, 0 }, { 0, 5 }, { 0, -5 }, { 4, 4 }, { -4, -4 } }

S.suite("reflex_ammo_standoff", {
  { "6 турелей в досягаемости — все за один проход, одно reflex_fired", function()
      local W = A.setup(200)
      local p = body(W)
      local invs = {}
      for _, d in ipairs(RING) do
        local _, ti = A.turret({ x = p.x + d[1], y = p.y + d[2] }, 0)
        invs[#invs + 1] = ti
      end
      set{ { type = "ammo", min = 10, fill = 30 } }
      C.run(10)
      for i, ti in ipairs(invs) do S.eq(ti.get_item_count(), 30, "турель " .. i) end
      local f = C.events("reflex_fired")
      S.eq(#f, 1, S.dump(f))
      S.eq(#f[1].data.detail.turrets, 6)
      S.eq(f[1].data.detail.count, 180)
      S.eq(W.main.get_item_count(A.AMMO), 20)
      S.eq(#W.path.calls, 0, "без ходьбы")
  end },
  { "патронов мало — поровну всем в досягаемости", function()
      local W = A.setup(60)
      local p = body(W)
      local invs = {}
      for _, d in ipairs(RING) do
        local _, ti = A.turret({ x = p.x + d[1], y = p.y + d[2] }, 0)
        invs[#invs + 1] = ti
      end
      set{ { type = "ammo", min = 10, fill = 30 } }
      C.run(10)
      for i, ti in ipairs(invs) do S.eq(ti.get_item_count(), 10, "турель " .. i) end
  end },
  { "2 группы дальних: один подход к лучшей точке, там вся группа, потом вторая", function()
      local W = A.setup(400)
      local p = body(W)
      local ga, ents = {}, {}
      for _, dy in ipairs({ -3, 0, 3 }) do
        local t, ti = A.turret({ x = p.x + 22, y = p.y + dy }, 0)
        ga[#ga + 1] = ti
        ents[#ents + 1] = t
      end
      local tb, tib = A.turret({ x = p.x - 12, y = p.y }, 0)
      ents[#ents + 1] = tb
      set{ { type = "ammo", radius = 32, min = 10, fill = 30 } }
      local a_tick, b_tick, walks_at_a
      for i = 1, 3000 do
        C.run(1)
        local full, some = 0, 0
        for _, ti in ipairs(ga) do
          if ti.get_item_count() >= 30 then full = full + 1 end
          if ti.get_item_count() > 0 then some = some + 1 end
        end
        if a_tick == nil then
          S.ok(some == 0 or full == #ga, "группа A заправлена разом, а не по одной")
          if full == #ga then
            a_tick = i
            walks_at_a = #A.walks()
            S.eq(tib.get_item_count(), 0, "вторая группа ещё ждёт")
          end
        end
        if tib.get_item_count() >= 30 then b_tick = i break end
      end
      S.ok(a_tick ~= nil and b_tick ~= nil and a_tick < b_tick, "A, потом B: " .. tostring(a_tick) .. " " .. tostring(b_tick))
      S.eq(walks_at_a, 1, "к группе A — один подход")
      local w = A.walks()
      S.eq(#w, 2, "всего два подхода: " .. S.dump(w))
      for _, t in ipairs(ents) do
        local d = S.dist(w[1], S.norm_pos(t.position))
        S.ok(d >= 1 + 3 - 1e-6, "не ближе turret_gap к турели: " .. S.dump(w[1]))
      end
  end },
  { "червь с дальностью 30: точка за турелью, как можно дальше от него, турель в досягаемости", function()
      local W = A.setup(100)
      local p = body(W)
      local worm = A.worm({ x = p.x, y = p.y - 40 }, 30)
      local wp = S.norm_pos(worm.position)
      local t, ti = A.turret({ x = p.x, y = p.y - 25 }, 0)
      local tp = S.norm_pos(t.position)
      set{ { type = "ammo", radius = 32, min = 10, fill = 30 } }
      local closest = math.huge
      for _ = 1, 3000 do
        C.run(1)
        closest = math.min(closest, S.dist(body(W), wp))
        if ti.get_item_count() >= 30 then break end
      end
      S.eq(ti.get_item_count(), 30, "заправил")
      local w = A.walks()
      S.eq(#w, 1)
      S.ok(w[1].y > tp.y, "с дальней от червя стороны: " .. S.dump(w[1]))
      local behind = S.dist(w[1], wp) - S.dist(tp, wp)
      S.ok(behind >= 8 and behind <= 9 + 1e-6, "за турелью на reach − 1.5 (± радиус шага): " .. behind)
      S.ok(closest >= S.dist(tp, wp) + 8 - 1e-6, "ближе к червю не подходил: " .. closest)
      S.eq(#C.events("ammo_unsafe"), 0)
  end },
  { "линия турелей и выдвинутая вперёд турель: линия заправлена, вперёд не выходит", function()
      local W = A.setup(200)
      local p = body(W)
      local worm = A.worm({ x = p.x, y = p.y - 45 }, 30)
      local wp = S.norm_pos(worm.position)
      local _, line_a = A.turret({ x = p.x + 4, y = p.y - 20 }, 0)
      A.turret({ x = p.x - 4, y = p.y - 20 }, 50)
      local _, forward = A.turret({ x = p.x, y = p.y - 31 }, 0)
      set{ { type = "ammo", radius = 32, min = 10, fill = 30 } }
      local closest = math.huge
      for _ = 1, 600 do
        C.run(1)
        closest = math.min(closest, S.dist(body(W), wp))
      end
      S.eq(line_a.get_item_count(), 30, "линия заправлена")
      S.eq(forward.get_item_count(), 0, "выдвинутая ждёт")
      S.ok(closest >= 25, "перед линией не выходил: " .. closest)
      local ev = C.events("ammo_unsafe")
      S.eq(#ev, 1, S.dump(ev))
      S.eq(ev[1].data.reason, "enemy_closer")
      S.eq(ev[1].data.turret.y, p.y - 31)
  end },
  { "behind задан: точка ещё дальше за линией, иначе отказ", function()
      local W = A.setup(100)
      local p = body(W)
      A.worm({ x = p.x, y = p.y - 40 }, 30)
      local _, ti = A.turret({ x = p.x, y = p.y - 25 }, 0)
      set{ { type = "ammo", radius = 32, min = 10, fill = 30, behind = 9 } }
      C.run(600)
      S.eq(ti.get_item_count(), 0, "за 9 клеток от турели рукой не достать")
      S.eq(#W.path.calls, 0)
      local ev = C.events("ammo_unsafe")
      S.eq(#ev, 1)
      S.eq(ev[1].data.reason, "behind")
  end },
  { "keep_away задан: жёсткий предел от врага", function()
      local W = A.setup(100)
      local p = body(W)
      A.worm({ x = p.x, y = p.y - 40 }, 30)
      local _, ti = A.turret({ x = p.x, y = p.y - 25 }, 0)
      set{ { type = "ammo", radius = 32, min = 10, fill = 30, keep_away = 30 } }
      C.run(600)
      S.eq(ti.get_item_count(), 0)
      S.eq(#W.path.calls, 0)
      local ev = C.events("ammo_unsafe")
      S.eq(#ev, 1)
      S.eq(ev[1].data.reason, "keep_away")
  end },
  { "враги со всех сторон турели: ammo_unsafe раз в минуту, тело не идёт", function()
      local W = A.setup(100)
      local p = body(W)
      local tp = { x = p.x, y = p.y - 30 }
      local _, ti = A.turret(tp, 0)
      for i = 0, 7 do
        local a = math.pi / 4 * i
        A.worm({ x = tp.x + math.cos(a) * 6, y = tp.y + math.sin(a) * 6 }, 8)
      end
      set{ { type = "ammo", radius = 32, min = 10, fill = 30 } }
      C.run(600)
      S.eq(ti.get_item_count(), 0)
      S.eq(#W.path.calls, 0, "не ходил")
      local ev = C.events("ammo_unsafe")
      S.eq(#ev, 1, S.dump(ev))
      S.eq(ev[1].loud, true)
      S.eq(ev[1].data.turret.x, tp.x)
      S.eq(ev[1].data.turret.y, tp.y)
      S.eq(ev[1].data.reason, "enemy_closer")
      S.ok(ev[1].data.enemy ~= nil and ev[1].data.name == "worm-8", S.dump(ev[1].data))
      C.run(3700)
      S.eq(#C.events("ammo_unsafe"), 2, "повтор через минуту")
      S.eq(#W.path.calls, 0)
  end },
  { "тело только что били: к турелям не идёт, ammo_unsafe{reason:attacked}", function()
      local W = A.setup(100)
      local p = body(W)
      A.worm({ x = p.x, y = p.y - 40 }, 30)
      local _, ti = A.turret({ x = p.x, y = p.y - 25 }, 0)
      storage.reflex_state = { h1 = { unit = W.h.unit_number,
        attack = { first_tick = game.tick, last_tick = game.tick + 60, noisy_tick = game.tick, pending = 0 } } }
      set{ { type = "ammo", radius = 32, min = 10, fill = 30 } }
      C.run(60)
      S.eq(ti.get_item_count(), 0)
      S.eq(#W.path.calls, 0)
      local ev = C.events("ammo_unsafe")
      S.eq(#ev, 1)
      S.eq(ev[1].data.reason, "attacked")
  end },
  { "тело в дальности червя без прикрытия турелей — само отходит", function()
      local W = A.setup(0)
      local p = body(W)
      local worm = A.worm({ x = p.x + 20, y = p.y }, 30)
      local wp = S.norm_pos(worm.position)
      set{ { type = "ammo", radius = 20 } }
      for _ = 1, 2000 do
        C.run(1)
        if #A.walks() > 0 then break end
      end
      S.ok(S.dist(body(W), wp) >= 34, "отошёл: " .. S.dump(body(W)))
      local f = C.events("reflex_fired")
      S.ok(#f >= 1 and f[1].data.detail.retreat ~= nil, S.dump(f))
      local n = #W.path.calls
      C.run(300)
      S.eq(#A.walks(), 1, "на безопасном месте больше не ходит")
      S.eq(#W.path.calls, n)
  end },
  { "тело за линией турелей в дальности червя — стоит", function()
      local W = A.setup(0)
      local p = body(W)
      A.worm({ x = p.x + 20, y = p.y }, 30)
      A.turret({ x = p.x + 12, y = p.y }, 50)
      A.turret({ x = p.x + 12, y = p.y + 4 }, 50)
      set{ { type = "ammo", radius = 20 } }
      C.run(300)
      S.eq(#W.path.calls, 0)
      S.eq(#C.events("ammo_unsafe"), 0)
  end },
  { "задача агента идёт — к дальним не идёт и не отходит, кладёт только в досягаемости", function()
      local W = A.setup(100)
      local p = body(W)
      A.worm({ x = p.x + 20, y = p.y + 20 }, 30)
      local _, far = A.turret({ x = p.x - 18, y = p.y }, 0)
      local _, near = A.turret({ x = p.x, y = p.y + 4 }, 0)
      W.path.speed = 0.01
      S.okr(C.act("walk", { to = { x = p.x + 30, y = p.y - 30 }, radius = 0.5 }))
      set{ { type = "ammo", radius = 20, min = 10, fill = 30 } }
      C.run(200)
      S.eq(near.get_item_count(), 30, "в досягаемости — сразу")
      S.eq(far.get_item_count(), 0)
      S.eq(#A.reflex_jobs(), 0, "своих задач не ставил")
  end },
})
