-- Действие plan_belt (поток N): подземные участки — режимы auto/never/prefer, маска подземного
-- конвейера, длина по прототипу, существующие подземные конвейеры. ACTIONS.md «plan_belt», PROTOCOL §6.12.
local S = require("stubs")
local X = require("stubs_n")
local beltpath = require("scripts.lib.beltpath")

local function P(x, y) return { x = x + 0.5, y = y + 0.5 } end

--- Мир и окружение слоя игры без задачи (для прямых проверок правил).
local function env_of(belt, under)
  local W = X.setup()
  local world = beltpath.new_world(belt or "transport-belt", under or "underground-belt")
  return beltpath.env(world, S.nauvis, W.h.force), world
end

local function edge(fx, fy, tx, ty, dir)
  return {
    kind = "underground", from_x = fx, from_y = fy, to_x = tx, to_y = ty, direction = dir,
    length = math.abs(tx - fx) + math.abs(ty - fy),
  }
end

local JOB = { start = { x = -100, y = -100 }, goal = { x = 100, y = 100 }, underground = "auto" }

S.suite("belt_under", {
  { "auto: через стену построек — подземный (вход, выход, направление), по земле в остальном", function()
      X.setup()
      X.wall(10, -30, 11, 30)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0) }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(X.continuous(g))
      S.eq(d.detail.undergrounds, 1)
      local u = X.ghosts("underground-belt")
      S.eq(#u, 2)
      S.eq(u[1].type, "input")
      S.eq(u[2].type, "output")
      S.eq(u[1].direction, X.D.east)
      S.eq(u[2].direction, X.D.east)
      S.eq(u[1].y, 0)
      S.eq(u[1].x, 9)
      S.eq(u[2].x, 12)
      S.eq(d.detail.need["underground-belt"], 2)
      S.eq(d.detail.need["transport-belt"], #g - 2)
      S.eq(d.detail.length, 21, "длина считает и клетки под землёй")
      S.eq(d.detail.turns, 0)
      S.eq(X.at(g, 10, 0), nil)
      S.eq(X.at(g, 11, 0), nil)
  end },
  { "auto: без помехи подземных нет", function()
      X.setup()
      local d = X.plan{ from = P(0, 0), to = P(30, 0) }
      S.eq(d.detail.undergrounds, 0)
      S.eq(#X.ghosts("underground-belt"), 0)
  end },
  { "auto: через существующую ленту и трубу — подземный", function()
      X.setup()
      for y = -30, 30 do X.belt(10, y, X.D.south) end
      for y = -30, 30 do X.thing(14, y, "pipe") end
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0) }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 2)
      S.ok(X.continuous(X.ghosts()))
      S.eq(X.at(X.ghosts(), 10, 0), nil, "чужая лента не тронута")
      S.eq(#X.marked, 0, "ничего не помечено к сносу")
  end },
  { "never: стену обходит по земле", function()
      X.setup()
      X.wall(10, -8, 11, 8)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 0)
      S.eq(#X.ghosts("underground-belt"), 0)
      S.ok(d.detail.length > 21)
      S.ok(X.continuous(X.ghosts()))
  end },
  { "стена толще, чем достаёт подземный конвейер (max_underground_distance): обход", function()
      X.setup()
      X.wall(10, -8, 14, 8) -- 5 клеток: вход и выход разнесены на 6 > 5
      local d, kind = X.plan{ from = P(0, 0), to = P(25, 0) }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 0)
      S.ok(X.continuous(X.ghosts()))
      -- быстрый подземный достаёт на 7
      X.setup{ research = { "fast-transport-belt", "fast-underground-belt" } }
      X.wall(10, -30, 14, 30)
      d, kind = X.plan{ from = P(0, 0), to = P(25, 0) }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 1)
      S.ok(X.continuous(X.ghosts(), 7))
  end },
  { "подземный конвейер не открыт исследованием: auto его не берёт, prefer берёт с предупреждением", function()
      X.setup{ research = { "transport-belt" } }
      X.wall(10, -8, 11, 8)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 0)
      S.eq(d.detail.chosen, { belt = "transport-belt" })
      d = X.plan{ from = P(0, 0), to = P(20, 0), dry_run = true, underground = "prefer" }
      S.ok(d.detail.undergrounds >= 1)
      S.eq(d.detail.warnings[1], "not_researched:underground-belt")
  end },
  { "prefer: подземные и по свободной земле, цепочка непрерывна, начало и конец — на земле", function()
      X.setup()
      local d, kind = X.plan{ from = P(0, 0), to = P(30, 0), underground = "prefer" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(d.detail.undergrounds >= 3, "подземных пар: " .. d.detail.undergrounds)
      S.ok(X.continuous(g))
      S.eq(g[1].name, "transport-belt")
      S.eq(g[#g].name, "transport-belt")
      S.eq(d.detail.length, 31)
  end },
  { "под лавой подземный не идёт: полоса лавы шириной 2 обходится, а не пересекается", function()
      X.setup()
      X.tiles("lava", 10, -8, 11, 8)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), underground = "prefer" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(X.continuous(g))
      for i = 1, #g - 1 do
        if g[i].type == "input" then
          local a, b = g[i], g[i + 1]
          S.ok(not (a.y >= -8 and a.y <= 8 and a.x < 10 and b.x > 11), "подземный под лавой: " .. S.dump(a))
        end
      end
  end },
  { "правило подземного участка: маска из стадии данных точнее — под водой можно, под лавой нельзя", function()
      -- без данных о масках: под плиткой, где конвейер не стоит, подземный не идёт (осторожно)
      local env = env_of()
      X.tiles("water", 5, 0)
      X.tiles("lava", 5, 10)
      local prefer = { start = JOB.start, goal = JOB.goal, underground = "prefer" }
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 0, 6, 0, 4)), false, "вода без данных — нельзя")
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 10, 6, 10, 4)), false, "лава — нельзя")
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 20, 6, 20, 4)), true, "земля — можно")
      -- стадия данных отдала underground_collision_mask прототипа
      env = env_of()
      X.underground_masks({ ["underground-belt"] = { layers = { lava_tile = true, empty_space = true } } })
      env = beltpath.env(env.W, env.surface, env.force)
      X.tiles("water", 5, 0)
      X.tiles("lava", 5, 10)
      X.tiles("void", 5, 30)
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 0, 6, 0, 4)), true, "под водой можно")
      S.eq(beltpath.underground_ok(env, JOB, edge(4, 0, 6, 0, 4)), true, "вода — помеха, auto разрешает")
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 10, 6, 10, 4)), false, "под лавой нельзя")
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 30, 6, 30, 4)), false, "под пустотой нельзя")
  end },
  { "правило подземного участка: длина, концы, помеха в auto, неоткрытый чанк", function()
      local env = env_of()
      X.thing(5, 0)
      S.eq(beltpath.underground_ok(env, JOB, edge(4, 0, 6, 0, 4)), true)
      local prefer = { start = JOB.start, goal = JOB.goal, underground = "prefer" }
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 0, 9, 0, 4)), true, "ровно max")
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 0, 10, 0, 4)), false, "длиннее max")
      S.eq(beltpath.underground_ok(env, JOB, edge(4, 0, 9, 0, 4)), false, "auto: выход не вплотную за помехой")
      S.eq(beltpath.underground_ok(env, JOB, edge(3, 0, 6, 0, 4)), false, "auto: вход не вплотную к помехе")
      S.eq(beltpath.underground_ok(env, JOB, edge(4, 0, 5, 0, 4)), false, "выход в помехе")
      S.eq(beltpath.underground_ok(env, JOB, edge(4, 5, 6, 5, 4)), false, "auto: помехи нет")
      S.eq(beltpath.underground_ok(env, { start = JOB.start, goal = { x = 6, y = 0 }, underground = "auto" },
        edge(4, 0, 6, 0, 4)), false, "выход в клетке цели")
      S.eq(beltpath.underground_ok(env, { start = { x = 4, y = 0 }, goal = JOB.goal, underground = "auto" },
        edge(4, 0, 6, 0, 4)), false, "вход в клетке начала")
      X.blocked[X.key(40, 0)] = true
      S.eq(beltpath.cell(env, 40, 0), beltpath.TILE, "движок не даёт строить, сущностей нет")
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 2, y = 2 })] = true
      X.thing(63, 70)
      S.eq(beltpath.underground_ok(env, JOB, edge(62, 70, 66, 70, 4)), false, "под неоткрытым чанком")
      S.eq(beltpath.cell(env, 65, 70), beltpath.UNCHARTED)
  end },
  { "существующий подземный конвейер того же типа на линии: участок через него не кладётся", function()
      local env = env_of()
      -- чужая пара на той же линии: вход (5,0) → выход (8,0)
      local a = X.underground(5, 0, X.D.east, "input")
      X.underground(8, 0, X.D.east, "output", a)
      local prefer = { start = JOB.start, goal = JOB.goal, underground = "prefer" }
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 0, 9, 0, 4)), false, "поверх чужой пары")
      S.eq(beltpath.underground_ok(env, prefer, edge(6, 0, 7, 0, 4)), false, "слишком короткий")
      S.eq(beltpath.underground_ok(env, prefer, edge(4, 1, 9, 1, 4)), true, "соседняя линия свободна")
      S.eq(beltpath.underground_ok(env, prefer, edge(6, -2, 6, 2, 8)), true, "поперёк чужой пары — можно")
      -- одиночный конец другого типа не мешает; одиночный вход того же типа — мешает (наш выход
      -- подхватил бы его)
      env = env_of()
      X.underground(20, 0, X.D.east, "input", nil, "fast-underground-belt")
      X.underground(20, 10, X.D.east, "input")
      S.eq(beltpath.underground_ok(env, prefer, edge(21, 0, 24, 0, 4)), true)
      S.eq(beltpath.underground_ok(env, prefer, edge(21, 10, 24, 10, 4)), false)
      S.eq(beltpath.underground_ok(env, prefer, edge(21, 11, 24, 11, 4)), true)
  end },
  { "свои подземные участки не ложатся друг на друга: вторая лента идёт рядом, а не в ту же линию", function()
      X.setup()
      X.wall(10, -30, 11, 30)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), lanes = 2 }
      S.eq(kind, "job_done", S.dump(d))
      local u = X.ghosts("underground-belt")
      S.eq(#u, 4)
      S.eq(d.detail.undergrounds, 2)
      S.eq(d.detail.lanes, 2)
      local rows = {}
      for _, ghost in ipairs(u) do rows[ghost.y] = (rows[ghost.y] or 0) + 1 end
      for _, n in pairs(rows) do S.eq(n, 2, "по одной паре на линию: " .. S.dump(rows)) end
  end },
})
