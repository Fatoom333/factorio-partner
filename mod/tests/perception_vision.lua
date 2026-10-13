-- Тесты обзора помощника (поток G). Контракт: PROTOCOL §6.8, STATE.md «vision».
local G = require("stubs_g")

-- 1. Итерация: ≤ 8 чанков, ближние первыми, границы чанков, повтор не раньше 10 с
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 40, y = 40 } })     -- чанк (1,1)
  local V = require("scripts.perception.vision")
  V.on_init()
  G.eq(type(storage.vision.charted), "table")
  local f = w.force

  -- ядро вызывает M.on_nth[60]
  G.ok(V.on_nth[60], "on_nth[60] exported")
  V.on_nth[60]({ tick = 1000 })
  G.eq(#f.charts, 8)
  G.eq(f.charts[1].area, { { 32, 32 }, { 63, 63 } }, "own chunk first")
  for _, c in ipairs(f.charts) do G.eq(c.surface, "nauvis") end

  -- следующая итерация добирает остальные 25 - 8 и не повторяет уже открытые
  for t = 1060, 1180, 60 do V.on_nth[60]({ tick = t }) end
  G.eq(#f.charts, 25, "5x5 chunks, each once")
  local seen = {}
  for _, c in ipairs(f.charts) do
    local k = c.area[1][1] .. ":" .. c.area[1][2]
    G.ok(not seen[k], "no duplicate " .. k)
    seen[k] = true
    G.eq(c.area[2][1] - c.area[1][1], 31)
    G.ok(c.area[1][1] % 32 == 0 and c.area[1][2] % 32 == 0, "chunk aligned")
  end
  G.ok(seen["-32:-32"] and seen["96:96"], "radius 2 chunks")

  -- до 10 с ничего нового
  V.on_nth[60]({ tick = 1500 })
  G.eq(#f.charts, 25)
  -- через 10 с после первого — снова, не больше 8
  V.on_nth[60]({ tick = 1600 })
  G.eq(#f.charts, 33)
  -- устаревшие записи вычищаются
  local n = 0
  for _ in pairs(storage.vision.charted) do n = n + 1 end
  G.ok(n <= 25, "charted table bounded")
end

-- 2. Несгенерированные чанки не трогаем; выключенный, мёртвый, удалённый — без обзора
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local V = require("scripts.perception.vision")
  for cx = -2, 2 do for cy = -2, 2 do
    if not (cx == 0 and cy == 0) then w.surface.ungenerated[cx .. ":" .. cy] = true end
  end end
  V.run(100)
  G.eq(#w.force.charts, 1, "only generated chunk")

  local w2 = G.reset()
  local e2, ctx2 = G.add_helper(w2, "h1", { pos = { x = 0, y = 0 } })
  V = require("scripts.perception.vision")
  G.eq(V.ops.vision({ on = false }, ctx2), { on = false })
  V.run(100)
  G.eq(#w2.force.charts, 0, "vision off")
  G.eq(require("scripts.perception.state").ops.state({}, ctx2).vision, false)
  G.eq(V.ops.vision({ on = true }, ctx2), { on = true })
  storage.helpers.h1.state = "dead"
  V.run(200)
  G.eq(#w2.force.charts, 0, "dead helper")
  storage.helpers.h1.state = "removed"
  V.run(300)
  G.eq(#w2.force.charts, 0, "removed helper")
  storage.helpers.h1.state = "alive"
  e2.valid = false
  V.run(400)
  G.eq(#w2.force.charts, 0, "invalid body")
  e2.valid = true
  V.run(500)
  G.eq(#w2.force.charts, 8, "alive again")
end

-- 3. Два помощника — по 8 каждому; по умолчанию включено; storage без vision
do
  local w = G.reset()
  G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  G.add_helper(w, "h2", { pos = { x = 1000, y = 1000 } })
  local V = require("scripts.perception.vision")
  V.run(100)
  G.eq(#w.force.charts, 16)
  -- нет storage.helpers — ничего не падает
  storage.helpers = nil
  V.run(200)
end

-- 4. Операция vision: аргументы
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local V = require("scripts.perception.vision")
  G.raises("bad_args", function() V.ops.vision({}, ctx) end)
  G.raises("bad_args", function() V.ops.vision({ on = "yes" }, ctx) end)
  G.raises("bad_args", function() V.ops.vision({ on = true, radius = 3 }, ctx) end)
  G.raises("no_helper", function() V.ops.vision({ on = true }, {}) end)
end

-- 5. Выбор обзора принадлежит телу: off → helper_remove → helper_spawn (тот же id) → снова on
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local V = require("scripts.perception.vision")
  local S = require("scripts.perception.state")
  V.ops.vision({ on = false }, ctx)
  V.run(100)
  G.eq(#w.force.charts, 0, "off")
  G.eq(S.ops.state({}, ctx).vision, false)
  -- запись off переживает итерации, пока тело то же
  V.run(700)
  G.eq(#w.force.charts, 0, "still off")
  G.ok(storage.vision.on.h1 ~= nil, "off record kept")
  -- helper_remove: тело уничтожено, запись ядра removed
  e.valid = false
  storage.helpers.h1.state = "removed"
  V.run(800)
  G.eq(#w.force.charts, 0, "removed")
  -- helper_spawn с тем же id: новое тело, новый unit_number (как registry.op_spawn)
  local e2, ctx2 = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  G.ok(e2.unit_number ~= e.unit_number)
  G.eq(S.ops.state({}, ctx2).vision, true, "default on after spawn")
  V.run(900)
  G.eq(#w.force.charts, 8, "new body charts")
  G.eq(storage.vision.on.h1, nil, "stale record dropped")
  -- и снова можно выключить уже новое тело
  V.ops.vision({ on = false }, ctx2)
  G.eq(S.ops.state({}, ctx2).vision, false)
  -- возрождение после смерти (registry.set_body: тот же rec, новый unit_number) — тоже включено
  storage.helpers.h1.unit_number = e2.unit_number + 100
  G.eq(require("scripts.perception.state").common.vision_on("h1"), true, "respawned body")
  -- on=true не хранится
  V.ops.vision({ on = true }, ctx2)
  V.run(2000)
  G.eq(storage.vision.on.h1, nil, "on is default, no record")
end

-- 6. Помощник без таблицы в storage.helpers не роняет итерацию
do
  local w = G.reset()
  G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  storage.helpers.bad = true
  local V = require("scripts.perception.vision")
  V.run(100)
  G.eq(#w.force.charts, 8)
end

-- 7. Тело-игрок (PROTOCOL §7): карту ему открывает движок, мод обзор не ведёт
do
  local w = G.reset()
  G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  storage.helpers.h1.player_index = 2
  local V = require("scripts.perception.vision")
  V.run(100)
  G.eq(#w.force.charts, 0)
  storage.helpers.h1.player_index = nil
  V.run(200)
  G.eq(#w.force.charts, 8)
end
