-- Действие connect_entities, вид belt: концы-клетки и порты блока с направлением, via, max_length,
-- работа по тикам, dry_run, снабжение до призраков, стройка, уборка при отказе, память прокладки.
-- ACTIONS.md «connect_entities», PROTOCOL §6.5 (manual_ghost), §6.12 (плитки из игры).
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_n")
local J = require("stubs_j")

local function P(x, y) return { x = x + 0.5, y = y + 0.5 } end

local function has(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then return true end
  end
  return false
end

local function job_of(args)
  return S.okr(C.act("connect_entities", args)).job
end

local function run_until(pred, n)
  for _ = 1, n or 3000 do
    if pred() then return true end
    C.run(1)
  end
  return pred()
end

S.suite("connect_belt", {
  { "клетка → клетка: призраки ленты, итог по контракту, build:false — только призраки", function()
      local W = J.setup()
      local d, kind = J.connect{ kind = "belt", from = { pos = P(2, 5) }, to = { pos = P(12, 5) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      S.eq(t.kind, "belt")
      S.eq(t.length, 11)
      S.eq(t.ghosts, 11)
      S.eq(t.undergrounds, 0)
      S.eq(t.turns, 0)
      S.eq(t.need, { ["transport-belt"] = 11 })
      S.eq(t.chosen, { belt = "transport-belt", underground = "underground-belt" })
      S.eq(t.area, { left_top = { x = 2, y = 5 }, right_bottom = { x = 13, y = 6 } })
      S.eq(t.path, { P(2, 5), P(12, 5) })
      S.eq(t.from_pos, P(2, 5))
      S.eq(t.to_pos, P(12, 5))
      S.eq(t.built, nil, "без стройки")
      S.eq(t.missing, { ["transport-belt"] = 11 }, "карманы пусты — missing для сведения")
      local g = X.ghosts()
      S.eq(#g, 11)
      S.ok(X.continuous(g))
      for _, ghost in ipairs(g) do
        S.eq(ghost.force, W.h.force)
        S.eq(ghost.direction, X.D.east)
      end
      for _, c in ipairs(X.checks) do
        S.eq(c.kind, defines.build_check_type.manual_ghost)
      end
  end },
  { "порты блока с направлением: первая лента смотрит по порту выхода, последняя — по порту входа", function()
      J.setup()
      J.port("smelt", "out0", { pos = P(2, 2), kind = "belt", io = "out", dir = X.D.south })
      J.port("make", "in0", { pos = P(12, 8), kind = "belt", io = "in", dir = X.D.east })
      local d, kind = J.connect{ kind = "belt", from = { layout = "smelt", port = "out0" },
        to = { layout = "make", port = "in0" }, build = false, underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(X.continuous(g))
      S.eq({ g[1].x, g[1].y, g[1].direction }, { 2, 2, X.D.south })
      S.eq({ g[#g].x, g[#g].y, g[#g].direction }, { 12, 8, X.D.east })
      S.eq({ g[#g - 1].x, g[#g - 1].y }, { 11, 8 }, "вход в порт — с его стороны")
      S.eq(d.detail.from_pos, P(2, 2))
      S.eq(d.detail.to_pos, P(12, 8))
  end },
  { "конец {pos, dir} прокладывает то же, что порт с этим направлением; dir без pos — bad_args", function()
      J.setup()
      local d, kind = J.connect{ kind = "belt", from = { pos = P(2, 2), dir = X.D.south },
        to = { pos = P(12, 8), dir = X.D.east }, build = false, underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(X.continuous(g))
      S.eq({ g[1].x, g[1].y, g[1].direction }, { 2, 2, X.D.south })
      S.eq({ g[#g].x, g[#g].y, g[#g].direction }, { 12, 8, X.D.east })
      S.eq({ g[#g - 1].x, g[#g - 1].y }, { 11, 8 }, "вход в конец — с его стороны")
      J.setup()
      J.port("b", "p", { pos = P(2, 2), kind = "belt", io = "out" })
      d, kind = J.connect{ kind = "belt", from = { layout = "b", port = "p", dir = 4 }, to = { pos = P(9, 9) } }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, S.dump(d))
      local r = C.act("connect_entities", { kind = "belt", from = { pos = P(1, 1), dir = 2 }, to = { pos = P(9, 9) } })
      S.eq(r.error.code, "bad_args", "dir — только 0/4/8/12")
  end },
  { "концы: машина и постройка блока для ленты — bad_args; порт другого вида — bad_args; нет порта — not_found", function()
      J.setup()
      J.port("b", "p", { pos = P(2, 2), kind = "pipe", io = "out" })
      local chest = X.thing(4, 4)
      local d, kind = J.connect{ kind = "belt", from = { target = { unit_number = chest.unit_number } }, to = { pos = P(9, 9) } }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, S.dump(d))
      d, kind = J.connect{ kind = "belt", from = { layout = "b", i = 1 }, to = { pos = P(9, 9) } }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, S.dump(d))
      d, kind = J.connect{ kind = "belt", from = { layout = "b", port = "p" }, to = { pos = P(9, 9) } }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, S.dump(d))
      d, kind = J.connect{ kind = "belt", from = { layout = "b", port = "zz" }, to = { pos = P(9, 9) } }
      S.eq({ kind, d.code }, { "job_failed", "not_found" }, S.dump(d))
      d, kind = J.connect{ kind = "belt", from = { pos = P(1, 1), layout = "b", port = "p" }, to = { pos = P(9, 9) } }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, "ровно один вид конца")
      d, kind = J.connect{ kind = "belt", from = { pos = P(1, 1) }, to = { pos = P(9, 9) }, pole = "small-electric-pole" }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, "pole не для ленты")
      local r = C.act("connect_entities", { kind = "belt", from = { pos = P(1, 1) }, to = { pos = P(9, 9) },
        via = { P(1, 2), P(1, 3), P(1, 4), P(1, 5), P(1, 6), P(1, 7), P(1, 8), P(1, 9), P(1, 10) } })
      S.eq(r.ok, false)
      S.eq(r.error.code, "limit", "via больше 8")
      r = C.act("connect_entities", { kind = "belt", from = { pos = P(1, 1) }, to = { pos = P(9, 9) }, max_length = 201 })
      S.eq(r.error.code, "limit")
      S.eq(#X.ghosts(), 0)
  end },
  { "max_length: заведомо длинный путь — сразу too_long; обход длиннее предела — too_long после поиска", function()
      J.setup()
      local d, kind = J.connect{ kind = "belt", from = { pos = P(0, 0) }, to = { pos = P(40, 0) }, max_length = 10,
        underground = "never" }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "path_failed", "too_long" }, S.dump(d))
      X.wall(10, -8, 10, 8)
      d, kind = J.connect{ kind = "belt", from = { pos = P(0, 0) }, to = { pos = P(20, 0) }, max_length = 25,
        underground = "never" }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "path_failed", "too_long" }, S.dump(d))
      S.ok(d.detail.length > 25, S.dump(d.detail))
      S.eq(#X.ghosts(), 0, "призраки не ставятся, пока путь не найден целиком")
  end },
  { "via: путь идёт через точки по порядку, лента непрерывна и поворачивает в точке", function()
      J.setup()
      local d, kind = J.connect{ kind = "belt", from = { pos = P(0, 0) }, to = { pos = P(10, 0) },
        via = { P(5, 6) }, build = false, underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(X.continuous(g))
      S.ok(X.at(g, 5, 6) ~= nil, "через via")
      S.eq(d.detail.length, #g)
      local seen = {}
      for _, ghost in ipairs(g) do
        local k = X.key(ghost.x, ghost.y)
        S.ok(not seen[k], "клетка дважды: " .. k)
        seen[k] = true
      end
      S.eq(g[#g].x, 10)
  end },
  { "поиск идёт по тикам: не больше WORK_PER_TICK раскрытий за тик, пульс задачи", function()
      J.setup()
      X.wall(15, -30, 15, 30)
      local bp = require("scripts.lib.beltpath")
      local orig = bp.step
      local works, calls = {}, 0
      bp.step = function(search, env, job, work)
        calls = calls + 1
        works[work] = true
        return orig(search, env, job, work)
      end
      local d, kind = J.connect{ kind = "belt", from = { pos = P(0, 0) }, to = { pos = P(30, 0) }, build = false,
        underground = "never" }
      bp.step = orig
      S.eq(kind, "job_done", S.dump(d))
      S.ok(calls > 1, "поиск занял больше одного тика: " .. calls)
      S.eq(works, { [256] = true })
      S.ok(has(d.detail.warnings, "long_detour") or d.detail.length > 31)
  end },
  { "dry_run: считает, ничего не ставит и не помечает; деревья — в предупреждении", function()
      J.setup()
      X.tree(5, 5)
      local d, kind = J.connect{ kind = "belt", from = { pos = P(2, 5) }, to = { pos = P(12, 5) }, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.dry_run, true)
      S.eq(d.detail.ghosts, 11)
      S.eq(d.detail.need, { ["transport-belt"] = 11 })
      S.eq(#X.ghosts(), 0)
      S.eq(#X.marked, 0)
      S.ok(has(d.detail.warnings, "marked_for_deconstruction:1"), S.dump(d.detail.warnings))
      S.eq(storage.connect_last.h1, nil, "сухой прогон не запоминается")
  end },
  { "build без предметов: no_items до призраков (весь счёт сразу), ничего не поставлено", function()
      J.setup()
      X.tree(5, 5)
      local d, kind = J.connect{ kind = "belt", from = { pos = P(2, 5) }, to = { pos = P(12, 5) } }
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.eq(d.detail.missing, { ["transport-belt"] = 11 })
      S.eq(#X.ghosts(), 0)
      S.eq(#X.marked, 0)
  end },
  { "build с предметами: призраки ставятся и строятся руками, итог с полями build_ghosts", function()
      local W = J.setup{ items = { ["transport-belt"] = 20 } }
      local d, kind = J.connect{ kind = "belt", from = { pos = P(2, 1) }, to = { pos = P(8, 1) }, mode = "hand" }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 7)
      S.eq(d.detail.ghosts, 7)
      S.eq(#J.ghosts(), 0)
      S.eq(C.counts(W.main), { ["transport-belt"] = 13 })
      local phases = {}
      for _, e in ipairs(C.events("job_progress")) do
        if e.data.phase then phases[e.data.phase] = true end
      end
      S.ok(phases.build or phases.search or phases.place, S.dump(phases))
  end },
  { "auto_supply: недостающее добывается до призраков (весь счёт), потом стройка", function()
      local W = J.setup()
      C.chest({ x = 3.5, y = 3.5 }, { { name = "transport-belt", count = 20 } })
      local job = job_of{ kind = "belt", from = { pos = P(2, 1) }, to = { pos = P(8, 1) }, mode = "hand", auto_supply = true }
      local ghosts_before_items = false
      local ok = run_until(function()
        if #J.ghosts() > 0 and C.counts(W.main)["transport-belt"] == nil then ghosts_before_items = true end
        return C.result(job) ~= nil
      end)
      S.ok(ok)
      local d, kind = C.result(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(ghosts_before_items, false, "призраки — только после снабжения")
      S.eq(d.detail.built, 7)
  end },
  { "отмена во время стройки: свои непостроенные призраки убраны, пометки сняты (removed, unmarked)", function()
      J.setup{ items = { ["transport-belt"] = 40 } }
      X.tree(20, 1)
      -- дерево на пути, помеченное хозяином до задачи: его пометку уборка не трогает
      local owners = X.tree(24, 1)
      owners.order_deconstruction("player")
      X.marked = {}
      local job = job_of{ kind = "belt", from = { pos = P(2, 1) }, to = { pos = P(30, 1) }, mode = "hand",
        underground = "never" }
      S.ok(run_until(function() return #J.ghosts() > 0 end), "призраки поставлены")
      S.okr(S.req("cancel", { job = job }, "h1"))
      local d, kind = C.result(job)
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "cancelled")
      S.ok((d.detail.removed or 0) > 0, S.dump(d.detail))
      S.eq(#J.ghosts(), 0, "своих призраков не осталось")
      S.eq(#X.marked, 1)
      S.eq(#X.unmarked, 1, "пометка снята")
      S.eq({ X.unmarked[1].x, X.unmarked[1].y }, { 20, 1 }, "снята только своя")
      S.eq(owners.to_be_deconstructed(), true, "пометка хозяина осталась")
      S.eq(storage.connect_last.h1, nil)
  end },
  { "память: повтор с теми же аргументами при живых призраках не ищет путь (resumed)", function()
      J.setup()
      local args = { kind = "belt", from = { pos = P(2, 5) }, to = { pos = P(12, 5) }, build = false }
      local d, kind = J.connect(args)
      S.eq(kind, "job_done", S.dump(d))
      local rec = storage.connect_last.h1
      S.ok(rec ~= nil and #rec.cells == 11, S.dump(rec))
      S.ok(X.plain(storage.connect_last))
      local checks = #X.checks
      d, kind = J.connect(args)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, true)
      S.eq(d.detail.ghosts, 11)
      S.eq(#X.checks, checks, "движок не спрашивали — поиска не было")
      S.eq(#J.ghosts(), 11, "призраки не задвоились")
      -- другие аргументы — обычный поиск (призраки прошлой прокладки — помеха)
      d, kind = J.connect{ kind = "belt", from = { pos = P(2, 7) }, to = { pos = P(12, 7) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, nil)
  end },
  { "отступление flee: призраки остаются, повтор задачи достраивает без поиска", function()
      J.setup{ items = { ["transport-belt"] = 40 } }
      local args = { kind = "belt", from = { pos = P(2, 1) }, to = { pos = P(30, 1) }, mode = "hand", underground = "never" }
      local job = job_of(args)
      S.ok(run_until(function() return #J.ghosts() > 0 end))
      local jobs = require("scripts.core.jobs")
      jobs.fail_all("h1", "cancelled", "replaced by job from reflex:flee", J.W.h)
      local d = C.result(job)
      S.eq(d.code, "cancelled")
      S.ok(#J.ghosts() > 0, "призраки оставлены для возврата")
      local d2, kind2 = J.connect(args)
      S.eq(kind2, "job_done", S.dump(d2))
      S.eq(d2.detail.resumed, true)
      S.eq(#J.ghosts(), 0)
  end },
  { "отступление без возврата: через FLED_TTL свои призраки и пометки убраны; другая прокладка убирает сразу", function()
      J.setup{ items = { ["transport-belt"] = 40 } }
      X.tree(20, 1)
      local M = require("scripts.actions.connect_entities")
      local jobs = require("scripts.core.jobs")
      local args = { kind = "belt", from = { pos = P(2, 1) }, to = { pos = P(30, 1) }, mode = "hand", underground = "never" }
      local job = job_of(args)
      S.ok(run_until(function() return #J.ghosts() > 0 end))
      jobs.fail_all("h1", "cancelled", "replaced by job from reflex:flee", J.W.h)
      C.result(job)
      S.ok(#J.ghosts() > 0)
      local fr = storage.connect_fled.h1
      S.ok(fr ~= nil and #fr.flat > 0, "оставленное запомнено")
      M.expire_fled(fr.tick + M.FLED_TTL - 1)
      S.ok(#J.ghosts() > 0, "до срока не трогаем")
      M.expire_fled(fr.tick + M.FLED_TTL)
      S.eq(#J.ghosts(), 0, "после срока свои призраки убраны")
      S.eq(storage.connect_fled.h1, nil)
      S.eq(storage.connect_last.h1, nil, "память прокладки забыта")
      if #X.marked > 0 then S.eq(#X.unmarked, #X.marked, "свои пометки сняты") end
      -- другая прокладка после отступления убирает оставленное сразу
      job = job_of(args)
      S.ok(run_until(function() return #J.ghosts() > 0 end))
      jobs.fail_all("h1", "cancelled", "replaced by job from reflex:flee", J.W.h)
      C.result(job)
      S.ok(storage.connect_fled.h1 ~= nil)
      local d, kind = J.connect{ kind = "belt", from = { pos = P(2, 9) }, to = { pos = P(8, 9) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(storage.connect_fled.h1, nil)
      for _, g in ipairs(J.ghosts()) do S.eq(g.y, 9, "остались только призраки новой прокладки") end
  end },
  { "без ключа connect_last в storage: прокладка работает, память не пишется", function()
      J.setup{ no_memory = true }
      storage.connect_last = nil
      local d, kind = J.connect{ kind = "belt", from = { pos = P(2, 5) }, to = { pos = P(6, 5) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(storage.connect_last, nil)
  end },
  { "состояние задачи — простые таблицы (storage)", function()
      J.setup()
      X.wall(8, -10, 8, 10)
      local job = job_of{ kind = "belt", from = { pos = P(0, 0) }, to = { pos = P(16, 0) }, build = false }
      C.run(2)
      local task = storage.jobs.by_helper.h1.active
      S.ok(task ~= nil and task.job == job)
      S.ok(X.plain(task))
      C.wait(job)
  end },
})
