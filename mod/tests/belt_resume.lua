-- Действие plan_belt, перекладка остатка: память плана storage.belt_last, from = "resume",
-- предупреждение unseen, уборка своих призраков при отказе по времени.
-- docs/ACTIONS.md («plan_belt»), docs/PROTOCOL.md §7.
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

local function has_prefix(list, prefix)
  for _, v in ipairs(list or {}) do
    if type(v) == "string" and v:sub(1, #prefix) == prefix then return v end
  end
  return nil
end

--- Настоящие ленты и подземные конвейеры мира: число и таблица по клеткам.
local function built()
  local n, at = 0, {}
  for _, e in ipairs(S.nauvis._entities) do
    if e.valid and (e.type == "transport-belt" or e.type == "underground-belt") then
      n = n + 1
      at[math.floor(e.position.x) .. "," .. math.floor(e.position.y)] = e
    end
  end
  return n, at
end

--- Призраки лент мира по порядку вдоль хода, начиная с клетки (x, y). → список.
local function chain(x, y)
  local all = X.live_ghosts()
  local out = {}
  local cur = X.at(all, x, y)
  local guard = 0
  while cur ~= nil and guard < 5000 do
    guard = guard + 1
    out[#out + 1] = cur
    local v = X.VEC[cur.direction]
    local nxt
    if cur.type == "input" then
      for len = 2, 7 do
        local g = X.at(all, cur.x + v[1] * len, cur.y + v[2] * len)
        if g ~= nil and g.type == "output" then nxt = g break end
      end
    else
      nxt = X.at(all, cur.x + v[1], cur.y + v[2])
    end
    cur = nxt
  end
  return out
end

local function resume(args)
  args = args or {}
  args.from = "resume"
  return X.plan(args)
end

S.suite("belt_resume", {
  { "память: удачный план запоминается (клетки по лентам), сухой прогон — нет", function()
      X.setup()
      S.eq(type(storage.belt_last), "table", "ключ создаёт migrate.ensure_shape")
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5), dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(storage.belt_last.h1, nil, "dry_run не запоминается")
      d, kind = X.plan{ from = P(2, 5), to = P(12, 5), underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local rec = storage.belt_last.h1
      S.eq(rec.surface_index, S.nauvis.index)
      S.eq(rec.to, P(12, 5))
      S.eq({ rec.belt, rec.underground, rec.lanes }, { "transport-belt", "never", 1 })
      S.eq(#rec.cells, 1)
      S.eq(#rec.cells[1], 11)
      S.eq({ rec.cells[1][1].x, rec.cells[1][1].y, rec.cells[1][1].d }, { 2, 5, X.D.east })
      S.eq(type(rec.tick), "number")
      S.ok(X.plain(storage.belt_last, "belt_last"))
  end },
  { "план длиннее лимита не запоминается: resume → bad_args", function()
      X.setup()
      local A = require("scripts.actions.plan_belt")
      local max = A.MAX_REMEMBERED
      X.plan{ from = P(2, 9), to = P(6, 9) }
      S.ok(storage.belt_last.h1 ~= nil)
      A.MAX_REMEMBERED = 5
      local d, kind = X.plan{ from = P(2, 5), to = P(12, 5) }
      A.MAX_REMEMBERED = max
      S.eq(kind, "job_done", S.dump(d))
      S.eq(storage.belt_last.h1, nil, "прежний план тоже забыт: он уже не последний")
      d, kind = resume()
      S.eq({ kind, d.code }, { "job_failed", "bad_args" })
      S.eq(#X.live_ghosts(), 11 + 5, "призраки на месте")
  end },
  { "перекладка: начало от построенной части, помеха обойдена, старых призраков нет", function()
      local W = X.setup()
      local d, kind = X.plan{ from = P(2, 5), to = P(22, 5), underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      for x = 2, 7 do X.build(x, 5) end
      X.thing(12, 5) -- помеха на недостроенной клетке (призрак под ней остался)
      d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      S.eq(t.resumed, { built = 6, removed = 15 })
      local n, at = built()
      S.eq(n, 6, "построенная часть цела")
      for x = 2, 7 do S.ok(at[x .. ",5"] ~= nil and at[x .. ",5"].direction == X.D.east) end
      local live = X.live_ghosts()
      S.eq(X.at(live, 12, 5), nil, "под помехой призрака нет")
      S.eq(t.ghosts, #live, "в мире только призраки нового пути")
      local c = chain(8, 5)
      S.eq(#c, #live, "новый путь непрерывен от построенной части: " .. #c .. " из " .. #live)
      S.eq({ c[#c].x, c[#c].y }, { 22, 5 }, "до той же цели")
      S.ok(#live > 14, "обход длиннее прямой")
      for _, g in ipairs(live) do
        S.eq(g.force, W.h.force.name)
        S.eq(g.name, "transport-belt")
      end
      S.eq(t.lanes, 1)
      S.eq(t.need, { ["transport-belt"] = #live })
      S.eq(t.warnings, {})
      -- память: построенная часть + новый путь
      local rec = storage.belt_last.h1
      S.eq(#rec.cells[1], 6 + #live)
      S.eq({ rec.cells[1][7].x, rec.cells[1][7].y }, { 8, 5 })
      S.ok(X.plain(storage.belt_last, "belt_last"))
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "перекладка дважды подряд: вторая берёт то, что построено из нового пути", function()
      X.setup()
      X.plan{ from = P(2, 5), to = P(22, 5), underground = "never" }
      for x = 2, 7 do X.build(x, 5) end
      X.thing(12, 5)
      local d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      local first = chain(8, 5)
      S.eq(#first, #X.live_ghosts())
      for i = 1, 3 do X.build(first[i].x, first[i].y) end
      X.thing(first[6].x, first[6].y) -- и снова помеха впереди
      d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, { built = 9, removed = #first - 3 })
      local live = X.live_ghosts()
      S.eq(X.at(live, first[6].x, first[6].y), nil)
      local c = chain(first[4].x, first[4].y)
      S.eq(#c, #live)
      S.eq({ c[#c].x, c[#c].y }, { 22, 5 })
      S.eq(built(), 9)
  end },
  { "убираются только свои призраки лент на клетках плана: чужое и постройки целы", function()
      X.setup()
      X.plan{ from = P(2, 5), to = P(22, 5), underground = "never" }
      X.build(2, 5)
      local function ghost(x, y, inner, force)
        return S.nauvis.create_entity{
          name = "entity-ghost", inner_name = inner, position = P(x, y), direction = X.D.east, force = force,
        }
      end
      local foreign = ghost(10, 8, "transport-belt", "enemy")   -- чужой призрак ленты
      local chest = ghost(10, 9, "iron-chest", "player")        -- свой призрак другой постройки
      local other = ghost(10, 12, "transport-belt", "player")   -- свой призрак ленты не из плана
      local thing = X.thing(14, 9)                              -- своя постройка
      local old_belt = X.belt(16, 12, X.D.north)                -- своя лента не из плана
      -- чужой призрак ленты на клетке плана: свой убран руками, на его месте чужой
      X.ghost_at(18, 5).destroy()
      local squatter = ghost(18, 5, "transport-belt", "enemy")
      local d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, { built = 1, removed = 19 }, "20 клеток без построенной и без занятой чужим")
      for name, e in pairs({ foreign = foreign, chest = chest, other = other, thing = thing, old_belt = old_belt, squatter = squatter }) do
        S.ok(e.valid, name .. " цел")
      end
      S.eq(X.at(X.live_ghosts(), 18, 5).force, "enemy")
  end },
  { "пометки к сносу, поставленные планом на убранном участке, снимаются", function()
      X.setup()
      local tree = X.tree(15, 5)
      local far_tree = X.tree(15, 20)
      far_tree.order_deconstruction(game.forces.player) -- пометил кто-то другой, не план
      X.marked = {}
      X.plan{ from = P(2, 5), to = P(22, 5), underground = "never" }
      S.eq(#X.marked, 1)
      S.ok(tree.to_be_deconstructed())
      X.build(2, 5)
      X.wall(14, 4, 14, 6) -- новый путь пойдёт в обход, мимо дерева
      local d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      S.eq(#X.unmarked, 1, S.dump(X.unmarked))
      S.eq({ X.unmarked[1].x, X.unmarked[1].y }, { 15, 5 })
      S.ok(far_tree.to_be_deconstructed(), "чужая пометка цела")
      S.ok(tree.valid and far_tree.valid)
  end },
  { "dry_run: ничего не убирает и не ставит, считает как после уборки, память прежняя", function()
      X.setup()
      X.plan{ from = P(2, 5), to = P(22, 5), underground = "never" }
      for x = 2, 7 do X.build(x, 5) end
      local before = #X.live_ghosts()
      local created = #S.nauvis.created
      local d, kind = resume{ dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.dry_run, true)
      S.eq(d.detail.resumed, { built = 6, removed = 15 })
      S.eq(d.detail.ghosts, 15, "прежние призраки помехой не считаются: путь прямой")
      S.eq(#X.live_ghosts(), before, "призраки на месте")
      S.eq(#S.nauvis.created, created, "ничего не поставлено")
      S.eq(#storage.belt_last.h1.cells[1], 21, "память не тронута")
      S.eq(#X.unmarked, 0)
  end },
  { "bad_args: нет плана, другая поверхность, не совпали to, belt, lanes", function()
      X.setup()
      local d, kind = resume()
      S.eq({ kind, d.code }, { "job_failed", "bad_args" })
      X.plan{ from = P(2, 5), to = P(12, 5) }
      for _, args in ipairs({
        { to = P(13, 5) }, { belt = "fast-transport-belt" }, { lanes = 2 },
      }) do
        d, kind = resume(args)
        S.eq({ kind, d.code }, { "job_failed", "bad_args" }, S.dump(args))
      end
      S.eq(#X.live_ghosts(), 11, "отказ ничего не убирает")
      storage.belt_last.h1.surface_index = S.nauvis.index + 7
      d, kind = resume()
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, "другая поверхность")
      storage.belt_last.h1.surface_index = S.nauvis.index
      storage.belt_last.h1.cells = "мусор"
      d, kind = resume()
      S.eq({ kind, d.code }, { "job_failed", "bad_args" }, "запись повреждена")
      S.err(C.act("plan_belt", { from = "restart", to = P(5, 0) }), "bad_args")
  end },
  { "совпавшие to, belt, lanes проходят; всё построено — перекладывать нечего (ghosts 0)", function()
      X.setup()
      X.plan{ from = P(2, 5), to = P(8, 5) }
      for x = 2, 8 do X.build(x, 5) end
      local d, kind = resume{ to = { x = 8.2, y = 5.9 }, belt = "transport-belt", lanes = 1 }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.ghosts, 0)
      S.eq(d.detail.resumed, { built = 7, removed = 0 })
      S.eq(#X.live_ghosts(), 0)
      S.eq(#storage.belt_last.h1.cells[1], 7)
  end },
  { "путь не найден: path_failed, старые призраки уже убраны, detail.removed; потом можно снова", function()
      X.setup()
      X.plan{ from = P(2, 5), to = P(22, 5), underground = "never" }
      for x = 2, 7 do X.build(x, 5) end
      X.tiles("lava", 15, -200, 15, 200)
      local d, kind = resume()
      S.eq({ kind, d.code }, { "job_failed", "path_failed" }, S.dump(d))
      S.eq(d.detail.removed, 15)
      S.eq(#X.live_ghosts(), 0, "недостроенное убрано: дроны не достроят ленту в тупик")
      S.eq(built(), 6)
      S.eq(#storage.belt_last.h1.cells[1], 6, "в памяти — построенная часть")
      X.tiles("grass-1", 15, -200, 15, 200)
      d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, { built = 6, removed = 0 })
      S.eq(#chain(8, 5), 15)
  end },
  { "подземная пара, построен только вход: призрак выхода остаётся, путь идёт от выхода", function()
      X.setup()
      X.wall(10, -30, 10, 30)
      local d, kind = X.plan{ from = P(2, 0), to = P(20, 0) }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 1)
      S.eq(X.at(X.live_ghosts(), 9, 0).type, "input")
      for x = 2, 9 do X.build(x, 0) end
      d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, { built = 8, removed = 9 })
      local live = X.live_ghosts()
      local out = X.at(live, 11, 0)
      S.ok(out ~= nil and out.type == "output", "выход пары на месте: " .. S.dump(out))
      S.eq(#chain(11, 0), #live, "путь непрерывен от выхода")
      S.eq(#live, 10)
      S.eq(has_prefix(d.detail.warnings, "dangling_underground"), nil)
      S.eq(#storage.belt_last.h1.cells[1], 18, "7 лент, пара, 9 лент нового пути")
  end },
  { "подземная пара без выхода: путь от клетки перед парой, вход в путь не входит (предупреждения)", function()
      X.setup()
      X.wall(10, -30, 10, 30)
      X.plan{ from = P(2, 0), to = P(20, 0) }
      for x = 2, 9 do X.build(x, 0) end
      X.ghost_at(11, 0).destroy()
      X.thing(11, 0) -- на месте выхода теперь помеха
      local d, kind = resume{ underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      S.eq(t.resumed.built, 8)
      S.ok(has(t.warnings, "dangling_underground:1"), S.dump(t.warnings))
      -- клетка за построенной лентой (8) занята входом: путь от неё поворачивает
      S.ok(has(t.warnings, "rotate_needed:1"), S.dump(t.warnings))
      S.eq(t.resumed.rotate[1].pos, P(8, 0))
      S.eq(t.undergrounds, 0)
      S.eq(#storage.belt_last.h1.cells[1], 7 + t.ghosts, "в памяти — клетки до пары и новый путь")
      S.eq(built(), 8, "построенное не тронуто")
  end },
  { "клетки плана, построенные не подряд, остаются и считаются помехой (built_apart)", function()
      X.setup()
      X.plan{ from = P(2, 5), to = P(22, 5), underground = "never" }
      for x = 2, 7 do X.build(x, 5) end
      X.build(15, 5)
      X.build(16, 5)
      local d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, { built = 6, removed = 13 })
      S.ok(has(d.detail.warnings, "built_apart:2"), S.dump(d.detail.warnings))
      S.eq(built(), 8)
      local live = X.live_ghosts()
      S.eq(X.at(live, 15, 5), nil)
      S.eq(#chain(8, 5), #live)
  end },
  { "две ленты: перекладка ведёт каждую от своей построенной части до своей цели", function()
      X.setup()
      local d, kind = X.plan{ from = P(2, 5), to = P(20, 5), lanes = 2, underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.lanes, 2)
      local rec = storage.belt_last.h1
      S.eq(#rec.cells, 2)
      local total = #rec.cells[1] + #rec.cells[2]
      local heads = {}
      for li = 1, 2 do
        for i = 1, 4 do X.build(rec.cells[li][i].x, rec.cells[li][i].y) end
        heads[li] = rec.cells[li][5]
      end
      d, kind = resume()
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.resumed, { built = 8, removed = total - 8 })
      S.eq(d.detail.lanes, 2)
      local live = X.live_ghosts()
      S.eq(#chain(heads[1].x, heads[1].y) + #chain(heads[2].x, heads[2].y), #live, "обе ленты непрерывны")
      S.eq(#storage.belt_last.h1.cells, 2)
  end },
  { "unseen: клетки пути в открытых чанках без текущего обзора", function()
      X.setup()
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      local d, kind = X.plan{ from = P(2, 5), to = P(60, 5) }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "unseen:29"), S.dump(d.detail.warnings))
      S.eq(d.detail.ghosts, 59, "планирование в таком чанке — как раньше")
      -- и у сухого прогона, и у перекладки
      d = X.plan{ from = P(2, 9), to = P(40, 9), dry_run = true }
      S.ok(has(d.detail.warnings, "unseen:9"), S.dump(d.detail.warnings))
      X.build(2, 5)
      d = resume()
      S.ok(has(d.detail.warnings, "unseen:29"), S.dump(d.detail.warnings))
  end },
  { "отказ по времени: призраки, поставленные задачей, убраны, detail.removed", function()
      X.setup()
      local A = require("scripts.actions.plan_belt")
      local max_ticks, per_tick = A.MAX_TICKS, A.PLACE_PER_TICK
      local tree = X.tree(3, 5)
      A.PLACE_PER_TICK = 2
      local job = S.okr(C.act("plan_belt", { from = P(2, 5), to = P(22, 5), underground = "never" })).job
      local placed = 0
      for _ = 1, 500 do
        C.run(1)
        placed = #X.live_ghosts()
        if placed >= 4 then break end
      end
      S.ok(placed >= 4 and placed < 21, "задача ставит призраки: " .. placed)
      S.ok(tree.to_be_deconstructed())
      A.MAX_TICKS = 0
      local d, kind = C.wait(job, 10)
      A.MAX_TICKS, A.PLACE_PER_TICK = max_ticks, per_tick
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "path_failed", "budget" }, S.dump(d))
      S.eq(d.detail.removed, placed)
      S.eq(#X.live_ghosts(), 0)
      S.ok(not tree.to_be_deconstructed(), "пометка задачи снята")
      S.eq(storage.belt_last.h1, nil, "недоставленный план не запомнен")
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "ядро: died_surface очищается при возрождении", function()
      local W = X.setup()
      local registry = require("scripts.core.registry")
      S.ok(registry.mark_dead("h1"))
      S.eq(storage.helpers.h1.died_surface, S.nauvis.name)
      local body = S.nauvis.create_entity{ name = "character", position = { x = 1, y = 1 }, force = W.h.force }
      registry.set_body("h1", body)
      S.eq(storage.helpers.h1.died_surface, nil)
      S.eq(storage.helpers.h1.state, "alive")
  end },
})
