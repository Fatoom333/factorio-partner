-- Действие connect_entities, вид power: опоры по длине провода (оба конца), конец — покрытие
-- потребителя или провод до опоры, обход препятствий, max_length, via, 2×2 опоры, dry_run, отказы.
-- ACTIONS.md «connect_entities».
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_n")
local J = require("stubs_j")

local function P(x, y) return { x = x + 0.5, y = y + 0.5 } end

local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

--- Соседние опоры цепочки достают друг друга проводом r.
local function chained(poles, r)
  for i = 1, #poles - 1 do
    if d2(poles[i], poles[i + 1]) > r + 1e-9 then
      return false, "провод " .. i .. ": " .. d2(poles[i], poles[i + 1])
    end
  end
  return true
end

local function covers(p, s, box)
  return p.x - s < box.right_bottom.x and p.x + s > box.left_top.x and p.y - s < box.right_bottom.y and p.y + s > box.left_top.y
end

S.suite("connect_power", {
  { "клетка → клетка: опоры в клетках концов, шаг не длиннее провода, число опор наименьшее", function()
      J.setup()
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(20, 0) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      S.eq(t.kind, "power")
      S.eq(t.chosen, { pole = "medium-electric-pole" }, "лучшая открытая одноклеточная — по длине провода")
      local poles = J.pole_ghosts()
      S.eq(#poles, t.poles)
      S.eq(t.length, t.poles)
      S.eq(t.poles, 4, "20 клеток при проводе 9: 4 опоры")
      S.eq(poles[1], { x = 0.5, y = 0.5, name = "medium-electric-pole" })
      S.eq({ poles[#poles].x, poles[#poles].y }, { 20.5, 0.5 })
      S.ok(chained(poles, 9))
      S.eq(t.need, { ["medium-electric-pole"] = 4 })
      S.eq(t.undergrounds, nil)
  end },
  { "до потребителя: последняя опора покрывает его рамку областью снабжения", function()
      J.setup()
      local m = J.machine(20, -1, { name = "assembling-machine-1" })
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { target = { unit_number = m.unit_number } },
        pole = "small-electric-pole", build = false }
      S.eq(kind, "job_done", S.dump(d))
      local poles = J.pole_ghosts()
      S.ok(chained(poles, 7.5))
      S.ok(covers(poles[#poles], 2.5, m.bounding_box), S.dump(poles[#poles]))
      for i = 1, #poles - 1 do S.ok(not covers(poles[i], 2.5, m.bounding_box) or i == #poles, "лишняя опора") end
  end },
  { "от стоящей опоры: первая новая — в пределах провода обоих (min), опора на конце задаёт имя", function()
      J.setup()
      local old = J.pole(0, 0, "small-electric-pole")
      local d, kind = J.connect{ kind = "power", from = { target = { unit_number = old.unit_number } }, to = { pos = P(25, 0) },
        build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.chosen, { pole = "small-electric-pole" })
      local poles = J.pole_ghosts()
      S.ok(d2(poles[1], { x = 0.5, y = 0.5 }) <= 7.5)
      S.ok(chained(poles, 7.5))
      S.eq({ poles[#poles].x, poles[#poles].y }, { 25.5, 0.5 })
  end },
  { "провод — меньший из двух: medium от small-опоры тянется не дальше 7.5", function()
      J.setup()
      local old = J.pole(0, 0, "small-electric-pole")
      local d, kind = J.connect{ kind = "power", from = { target = { unit_number = old.unit_number } }, to = { pos = P(30, 0) },
        pole = "medium-electric-pole", build = false }
      S.eq(kind, "job_done", S.dump(d))
      local poles = J.pole_ghosts()
      S.ok(d2(poles[1], { x = 0.5, y = 0.5 }) <= 7.5, S.dump(poles[1]))
      S.ok(chained(poles, 9))
  end },
  { "препятствие: опоры обходят лаву и постройки, ни одной на них", function()
      J.setup()
      X.tiles("lava", 8, -30, 14, 30)
      X.wall(4, -2, 4, 2)
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(22, 0) },
        pole = "small-electric-pole", build = false }
      S.eq(kind, "job_done", S.dump(d))
      local poles = J.pole_ghosts()
      S.ok(chained(poles, 7.5))
      for _, p in ipairs(poles) do
        local x, y = math.floor(p.x), math.floor(p.y)
        S.ok(not (x >= 8 and x <= 14 and y >= -30 and y <= 30), "опора на лаве: " .. S.dump(p))
        S.ok(not (x == 4 and y >= -2 and y <= 2), "опора на постройке: " .. S.dump(p))
      end
  end },
  { "max_length: опор нужно больше предела → path_failed too_long", function()
      J.setup()
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(60, 0) }, max_length = 3 }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "path_failed", "too_long" }, S.dump(d))
      X.tiles("lava", 8, -6, 14, 6)
      d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(22, 0) }, max_length = 4,
        pole = "small-electric-pole" }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "path_failed", "too_long" }, S.dump(d))
      S.eq(#J.pole_ghosts(), 0)
  end },
  { "поиск опор идёт по тикам: не больше POWER_WORK_PER_TICK проверок за тик", function()
      J.setup()
      X.tiles("lava", 8, -30, 14, 30)
      local cl = require("scripts.lib.connect")
      local orig = cl.power_step
      local works, calls = {}, 0
      cl.power_step = function(st, env, p, work)
        calls = calls + 1
        works[work] = true
        return orig(st, env, p, work)
      end
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(22, 0) },
        pole = "small-electric-pole", build = false }
      cl.power_step = orig
      S.eq(kind, "job_done", S.dump(d))
      S.ok(calls > 1, "поиск занял больше одного тика: " .. calls)
      S.eq(works, { [4096] = true })
  end },
  { "уже соединено: опора на конце достаёт опору цели — ставить нечего", function()
      J.setup()
      local a, b = J.pole(0, 0), J.pole(5, 0)
      local d, kind = J.connect{ kind = "power", from = { target = { unit_number = a.unit_number } },
        to = { target = { unit_number = b.unit_number } } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.poles, 0)
      S.ok(#d.detail.warnings == 1 and d.detail.warnings[1] == "already_connected", S.dump(d.detail.warnings))
  end },
  { "цель уже под током той же сети: повтор поручения не строит вторую линию", function()
      J.setup()
      local a, b = J.pole(0, 0, "medium-electric-pole"), J.pole(18, 0, "medium-electric-pole")
      a.electric_network_id, b.electric_network_id = 7, 7
      local d, kind = J.connect{ kind = "power", from = { target = { unit_number = a.unit_number } },
        to = { pos = P(20, 1) } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.poles, 0)
      S.eq(#J.pole_ghosts(), 0)
      S.ok(d.detail.warnings[1] == "already_connected", S.dump(d.detail.warnings))
      -- опора рядом, но из другой сети: линию строить надо
      b.electric_network_id = 8
      local d2_, kind2 = J.connect{ kind = "power", from = { target = { unit_number = a.unit_number } },
        to = { pos = P(20, 1) }, build = false }
      S.eq(kind2, "job_done", S.dump(d2_))
      S.ok(d2_.detail.poles > 0, "другая сеть — опоры нужны")
  end },
  { "без pole: опора, которая у тела в карманах, а не лучшая открытая", function()
      J.setup({ items = { ["small-electric-pole"] = 10 } })
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(20, 0) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.chosen, { pole = "small-electric-pole" })
  end },
  { "via: опора встаёт в точке via", function()
      J.setup()
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(20, 0) }, via = { P(10, 10) },
        build = false }
      S.eq(kind, "job_done", S.dump(d))
      local poles = J.pole_ghosts()
      local found = false
      for _, p in ipairs(poles) do if p.x == 10.5 and p.y == 10.5 then found = true end end
      S.ok(found, S.dump(poles))
      S.ok(chained(poles, 9))
  end },
  { "опора 2×2 (big): центр на углу клеток, шаг до 30, неисследованная — ставится по имени", function()
      J.setup()
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(70, 0) }, pole = "big-electric-pole",
        build = false }
      S.eq(kind, "job_done", S.dump(d))
      local poles = J.pole_ghosts()
      S.eq(poles[1], { x = 1, y = 1, name = "big-electric-pole" })
      S.ok(chained(poles, 30))
      S.eq(#poles, 4)
  end },
  { "конец на постройке → cannot_place end_blocked; dry_run ничего не ставит", function()
      J.setup()
      X.thing(20, 0)
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(20, 0) } }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "cannot_place", "end_blocked" }, S.dump(d))
      d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(15, 0) }, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.dry_run, true)
      S.eq(#J.pole_ghosts(), 0)
      d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(15, 0) }, underground = "never" }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" })
  end },
  { "build с предметами: опоры строятся; без — no_items и ни одного призрака", function()
      J.setup()
      local d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(15, 0) } }
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.eq(#J.pole_ghosts(), 0)
      J.setup{ items = { ["medium-electric-pole"] = 10 } }
      d, kind = J.connect{ kind = "power", from = { pos = P(0, 0) }, to = { pos = P(15, 0) }, mode = "hand" }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, d.detail.poles)
      S.eq(#J.pole_ghosts(), 0)
  end },
})
