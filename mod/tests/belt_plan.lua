-- Действие plan_belt (поток N): путь по земле — прямая, обход плиток без опоры, концы, ошибки.
-- ACTIONS.md «plan_belt», PROTOCOL §6.5 (manual_ghost), §6.11 (quality normal), §6.12 (плитки из игры).
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_n")

local function P(x, y) return { x = x + 0.5, y = y + 0.5 } end

local function has(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then return true end
  end
  return false
end

S.suite("belt_plan", {
  { "прямая: призраки силы хозяина, manual_ghost, quality normal, счёт и need", function()
      local W = X.setup()
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5) }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      local g = X.ghosts()
      S.eq(#g, 11)
      S.eq(t.ghosts, 11)
      S.eq(t.length, 11)
      S.eq(t.turns, 0)
      S.eq(t.undergrounds, 0)
      S.eq(t.lanes, 1)
      S.eq(t.need, { ["transport-belt"] = 11 })
      S.eq(t.chosen, { belt = "transport-belt", underground = "underground-belt" })
      S.eq(t.area, { left_top = { x = 2, y = 5 }, right_bottom = { x = 13, y = 6 } })
      S.eq(t.path, { P(2, 5), P(12, 5) })
      S.eq(t.warnings, {})
      S.eq(t.dry_run, nil)
      for i, ghost in ipairs(g) do
        S.eq(ghost.name, "transport-belt")
        S.eq(ghost.x, 1 + i)
        S.eq(ghost.y, 5)
        S.eq(ghost.direction, X.D.east)
        S.eq(ghost.force, W.h.force, "сила хозяина")
        S.eq(ghost.quality, "normal")
        S.eq(ghost.raise_built, true)
        S.eq(ghost.pos.x % 1, 0.5)
      end
      for _, c in ipairs(X.checks) do
        S.eq(c.kind, defines.build_check_type.manual_ghost, "проверка постановки — manual_ghost")
        S.eq(c.force, W.h.force)
      end
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "лава поперёк прямой: путь в обход, призраки непрерывны, ни одного на лаве", function()
      X.setup()
      X.tiles("lava", 10, -6, 12, 9)
      local d, kind = X.plan{ from = P(0, 0), to = P(25, 0), underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(#g > 26, "путь длиннее прямой: " .. #g)
      S.ok(X.continuous(g))
      for _, ghost in ipairs(g) do
        S.ok(not (ghost.x >= 10 and ghost.x <= 12 and ghost.y >= -6 and ghost.y <= 9), "призрак на лаве: " .. S.dump(ghost))
      end
      S.eq(g[1].x, 0)
      S.eq(g[1].y, 0)
      S.eq(g[#g].x, 25)
      S.eq(g[#g].y, 0)
      S.ok(d.detail.turns >= 2, "повороты: " .. d.detail.turns)
      S.eq(d.detail.length, #g)
      S.eq(#d.detail.path, d.detail.turns + 2, "углы пути: начало, повороты, конец")
      S.eq(d.detail.need, { ["transport-belt"] = #g })
  end },
  { "лава: в режиме auto подземный под лавой не идёт — тоже обход", function()
      X.setup()
      X.tiles("lava", 10, -6, 11, 9)
      local d, kind = X.plan{ from = P(0, 0), to = P(25, 0) }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 0)
      S.eq(#X.ghosts("underground-belt"), 0)
      S.ok(X.continuous(X.ghosts()))
  end },
  { "плитки берутся по маске, а не по имени: плитка из мода с тем же слоем обходится", function()
      X.setup()
      prototypes.tile["mod-acid-lake"] = { name = "mod-acid-lake", collision_mask = { layers = { water_tile = true } } }
      prototypes.tile["mod-moss"] = { name = "mod-moss", collision_mask = { layers = { ground_tile = true } } }
      X.tiles("mod-acid-lake", 5, -4, 5, 4)
      X.tiles("mod-moss", 6, -4, 8, 4)
      local d, kind = X.plan{ from = P(0, 0), to = P(10, 0), underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      for _, ghost in ipairs(g) do S.ok(ghost.x ~= 5 or math.abs(ghost.y) > 4, "призрак на плитке мода") end
      S.ok(X.at(g, 7, 0) ~= nil or #g > 11, "по мху идти можно")
  end },
  { "dry_run: считает, ничего не ставит и не помечает", function()
      X.setup()
      X.tree(5, 5)
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5), dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.ghosts, 11)
      S.eq(d.detail.dry_run, true)
      S.eq(d.detail.need, { ["transport-belt"] = 11 })
      S.eq(#X.ghosts(), 0)
      S.eq(#X.marked, 0)
      S.ok(has(d.detail.warnings, "marked_for_deconstruction:1"), S.dump(d.detail.warnings))
  end },
  { "деревья и камни на пути помечаются к сносу", function()
      local W = X.setup()
      X.tree(5, 5)
      X.tree(6, 5, "big-rock")
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5), underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(X.at(g, 5, 5), "лента идёт через дерево")
      S.ok(X.at(g, 6, 5), "лента идёт через камень")
      S.eq(#X.marked, 2)
      S.eq(X.marked[1].force, W.h.force)
      S.ok(has(d.detail.warnings, "marked_for_deconstruction:2"), S.dump(d.detail.warnings))
      S.ok(X.continuous(g))
  end },
  { "скала и своя постройка — преграды: обходятся, к сносу не помечаются", function()
      X.setup()
      X.thing(5, 5, "cliff", "neutral")
      X.thing(9, 5) -- свой сундук
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5), underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(X.at(X.ghosts(), 5, 5), nil)
      S.eq(X.at(X.ghosts(), 9, 5), nil)
      S.ok(X.continuous(X.ghosts()))
      S.eq(#X.marked, 0)
  end },
  { "конец занят постройкой (сундук, лента базы): лента подходит вплотную и смотрит в неё", function()
      X.setup()
      X.thing(12, 5)
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5) }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.eq(#g, 10)
      S.eq(X.at(g, 12, 5), nil)
      S.eq(g[#g].x, 11)
      S.eq(g[#g].direction, X.D.east)
  end },
  { "начало — конец существующей ленты: на неё призрак не ставится, ход продолжает её направление и тип", function()
      X.setup{ research = { "transport-belt", "underground-belt", "fast-transport-belt" } }
      X.belt(2, 5, X.D.south, "fast-transport-belt")
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5) }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.eq(X.at(g, 2, 5), nil)
      S.eq(g[1].x, 2)
      S.eq(g[1].y, 6, "первый шаг — куда смотрит существующая лента")
      S.eq(g[1].name, "fast-transport-belt", "тип — как у существующей ленты")
      S.eq(d.detail.chosen.belt, "fast-transport-belt")
      S.eq(g[#g].x, 12)
      S.eq(g[#g].y, 5)
  end },
  { "start_direction задаёт первый шаг", function()
      X.setup()
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5), start_direction = "north" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.eq(g[1].direction, X.D.north)
      S.eq(g[2].x, 2)
      S.eq(g[2].y, 4)
      S.ok(X.continuous(g))
  end },
  { "лента по умолчанию — лучшая из открытого; belt задаёт явно; чужой прототип — bad_args", function()
      X.setup{ research = { "transport-belt", "fast-transport-belt", "fast-underground-belt" } }
      local d = X.plan{ from = P(2, 5), to = P(6, 5), dry_run = true }
      S.eq(d.detail.chosen, { belt = "fast-transport-belt", underground = "fast-underground-belt" })
      d = X.plan{ from = P(2, 5), to = P(6, 5), dry_run = true, belt = "transport-belt" }
      S.eq(d.detail.chosen, { belt = "transport-belt" }, "подземный не открыт — не берётся")
      local d2, kind2 = X.plan{ from = P(2, 5), to = P(6, 5), belt = "iron-chest" }
      S.eq(kind2, "job_failed")
      S.eq(d2.code, "bad_args")
      X.forget("transport-belt", "fast-transport-belt")
      local d3, kind3 = X.plan{ from = P(2, 5), to = P(6, 5) }
      S.eq(kind3, "job_failed")
      S.eq(d3.code, "bad_args")
  end },
  { "цель за лавой без прохода: path_failed с reached, призраков нет", function()
      X.setup()
      -- остров: цель окружена лавой
      X.tiles("lava", 16, -4, 24, 4)
      X.tiles("grass-1", 19, -1, 21, 1)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0) }
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "path_failed")
      S.ok(d.detail.reason == "unreachable" or d.detail.reason == "budget", S.dump(d.detail))
      S.ok(d.detail.reached ~= nil, "reached")
      S.ok(d.detail.left >= 3 and d.detail.left <= 6, "дошёл до берега: " .. S.dump(d.detail))
      S.ok(d.detail.reached.x < 16.5 or math.abs(d.detail.reached.y) > 4, "reached не на острове")
      S.ok(d.detail.expanded > 0)
      S.eq(#X.ghosts(), 0)
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "начало заперто лавой: path_failed{reason=unreachable} сразу, reached — в пределах лужайки", function()
      X.setup()
      X.tiles("lava", -3, -3, 3, 3)
      X.tiles("grass-1", -1, -1, 1, 1)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0) }
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "path_failed")
      S.eq(d.detail.reason, "unreachable")
      S.eq(d.detail.reached, P(1, 0))
      S.eq(d.detail.left, 19)
      S.eq(#X.ghosts(), 0)
  end },
  { "бюджет поиска исчерпан: path_failed{reason=budget} с reached", function()
      X.setup()
      local A = require("scripts.actions.plan_belt")
      local base, per = A.BASE_EXPANSIONS, A.EXPANSIONS_PER_TILE
      A.BASE_EXPANSIONS, A.EXPANSIONS_PER_TILE = 30, 0
      X.tiles("lava", 10, -40, 10, 40)
      local d, kind = X.plan{ from = P(0, 0), to = P(25, 0) }
      A.BASE_EXPANSIONS, A.EXPANSIONS_PER_TILE = base, per
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "path_failed")
      S.eq(d.detail.reason, "budget")
      S.ok(d.detail.reached.x > 0.5, "продвинулся к цели: " .. S.dump(d.detail.reached))
      S.eq(#X.ghosts(), 0)
  end },
  { "поиск идёт в несколько тиков и держит «пульс»; состояние годится для сохранения", function()
      X.setup()
      X.tiles("lava", 30, -30, 30, 30)
      local job = S.okr(C.act("plan_belt", { from = P(0, 0), to = P(60, 0) })).job
      C.run(3)
      local task = storage.jobs.by_helper.h1.active
      S.ok(task ~= nil and task.belt ~= nil, "поиск ещё идёт")
      S.eq(task.belt.stage, "search")
      S.eq(#X.ghosts(), 0, "пока путь не найден, призраков нет")
      S.eq(task.progress_tick, game.tick)
      local ok, where = X.plain(task)
      S.ok(ok, "в состоянии задачи не данные: " .. tostring(where))
      local d, kind = C.wait(job, 3000)
      S.eq(kind, "job_done", S.dump(d))
      S.ok(X.continuous(X.ghosts()))
  end },
  { "отмена во время поиска: призраков нет, состояние убрано", function()
      X.setup()
      X.tiles("lava", 30, -30, 30, 30)
      local job = S.okr(C.act("plan_belt", { from = P(0, 0), to = P(60, 0) })).job
      C.run(3)
      S.okr(S.req("cancel", { job = job }, "h1"))
      C.run(2)
      local d, kind = C.result(job)
      S.eq(kind, "job_failed")
      S.eq(d.code, "cancelled")
      S.eq(#X.ghosts(), 0)
  end },
  { "ошибки аргументов: та же клетка, дальше 512, неоткрытый чанк, границы схемы", function()
      X.setup()
      local d, kind = X.plan{ from = P(2, 5), to = { x = 2.9, y = 5.1 } }
      S.eq(kind, "job_failed")
      S.eq(d.code, "bad_args")
      d = X.plan{ from = P(0, 0), to = P(513, 0) }
      S.eq(d.code, "limit")
      d = X.plan{ from = P(0, 0), to = P(400, 400) }
      S.eq(d.code, "limit", "расстояние по прямой")
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      d = X.plan{ from = P(0, 0), to = P(100, 0) }
      S.eq(d.code, "not_charted")
      S.err(C.act("plan_belt", { from = P(0, 0), to = P(5, 0), lanes = 5 }), "limit")
      S.err(C.act("plan_belt", { from = P(0, 0), to = P(5, 0), lanes = 0 }), "bad_args")
      S.err(C.act("plan_belt", { from = "base", to = P(5, 0) }), "bad_args")
      S.err(C.act("plan_belt", { from = P(0, 0), to = P(5, 0), underground = "always" }), "bad_args")
      S.err(C.act("plan_belt", { from = P(0, 0) }), "bad_args")
      S.eq(#X.ghosts(), 0)
  end },
  { "неоткрытые чанки на пути обходятся", function()
      X.setup()
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      local d, kind = X.plan{ from = P(20, 10), to = P(70, 10) }
      S.eq(kind, "job_done", S.dump(d))
      for _, ghost in ipairs(X.ghosts()) do
        S.ok(not (ghost.x >= 32 and ghost.x < 64 and ghost.y >= 0 and ghost.y < 32), "призрак в неоткрытом чанке")
      end
      S.ok(X.continuous(X.ghosts()))
  end },
  { "начало или конец на плитке без опоры: cannot_place", function()
      X.setup()
      X.tiles("lava", 12, 5, 12, 5)
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5) }
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "cannot_place")
      S.eq(d.detail.pos, P(12, 5))
      d = X.plan{ from = P(12, 5), to = P(2, 5) }
      S.eq(d.code, "cannot_place")
      S.eq(#X.ghosts(), 0)
  end },
  { "предупреждения: long_detour, narrow, near_enemy", function()
      X.setup()
      X.tiles("lava", 5, -30, 5, 30)
      local d = X.plan{ from = P(0, 0), to = P(10, 0), dry_run = true }
      S.ok(has(d.detail.warnings, "long_detour"), S.dump(d.detail.warnings))
      S.ok(not has(d.detail.warnings, "narrow"))
      S.ok(not has(d.detail.warnings, "near_enemy"))

      X.setup()
      -- коридор шириной 1 клетка
      X.tiles("lava", 4, -1, 8, -1)
      X.tiles("lava", 4, 1, 8, 1)
      d = X.plan{ from = P(0, 0), to = P(12, 0), dry_run = true }
      S.ok(has(d.detail.warnings, "narrow"), S.dump(d.detail.warnings))
      S.ok(not has(d.detail.warnings, "long_detour"))

      X.setup()
      S.force{ name = "enemy" }
      S.nauvis.create_entity{ name = "small-biter", position = { x = 8, y = 10 }, force = "enemy" }
      d = X.plan{ from = P(0, 0), to = P(12, 0), dry_run = true }
      S.ok(has(d.detail.warnings, "near_enemy"), S.dump(d.detail.warnings))
  end },
  { "длинная лента: area целиком и areas кусками не больше 128", function()
      X.setup()
      local d, kind = X.plan{ from = P(0, 0), to = P(300, 0), dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      S.eq(t.ghosts, 301)
      S.eq(t.area, { left_top = { x = 0, y = 0 }, right_bottom = { x = 301, y = 1 } })
      S.ok(#t.areas >= 3, "куски: " .. S.dump(t.areas))
      local cells = 0
      for _, a in ipairs(t.areas) do
        S.ok(a.right_bottom.x - a.left_top.x <= 128 and a.right_bottom.y - a.left_top.y <= 128, S.dump(a))
        cells = cells + (a.right_bottom.x - a.left_top.x)
      end
      S.eq(cells, 301, "куски покрывают всю ленту без наложений")
  end },
  { "место занято к моменту постановки: призрак пропущен, предупреждение skipped", function()
      X.setup()
      local job = S.okr(C.act("plan_belt", { from = P(0, 0), to = P(200, 0) })).job
      -- ждём начала постановки и занимаем клетку впереди
      for _ = 1, 3000 do
        C.run(1)
        local task = storage.jobs.by_helper.h1.active
        if task == nil then break end
        if task.belt.stage == "place" then
          X.blocked[X.key(150, 0)] = true
          break
        end
      end
      local d, kind = C.wait(job, 3000)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.skipped, 1)
      S.eq(d.detail.ghosts, 200)
      S.ok(has(d.detail.warnings, "skipped:1"))
      S.eq(X.at(X.ghosts(), 150, 0), nil)
  end },
})
