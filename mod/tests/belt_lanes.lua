-- Действие plan_belt: несколько лент пачкой (`lanes`) и ленты от разметки (`from: "patch"`).
-- ACTIONS.md «plan_belt», PROTOCOL §7 (storage.mining_last).
local S = require("stubs")
local X = require("stubs_n")
local beltpath = require("scripts.lib.beltpath")

local function P(x, y) return { x = x + 0.5, y = y + 0.5 } end

local function has(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then return true end
  end
  return false
end

--- Разложить призраки (в порядке постановки) на цепочки: новая цепочка там, где следующий призрак не
--- стоит по ходу предыдущего.
local function chains(ghosts)
  local out = { {} }
  for i, g in ipairs(ghosts) do
    local cur = out[#out]
    local prev = ghosts[i - 1]
    if prev ~= nil and #cur > 0 then
      local ok = X.continuous({ prev, g })
      if not ok then
        cur = {}
        out[#out + 1] = cur
      end
    end
    cur[#cur + 1] = g
  end
  return out
end

local function no_overlap(ghosts)
  local seen = {}
  for _, g in ipairs(ghosts) do
    local k = X.key(g.x, g.y)
    if seen[k] then return false, k end
    seen[k] = true
  end
  return true
end

--- Клетка, в которую смотрит призрак.
local function ahead(g)
  local v = X.VEC[g.direction]
  return g.x + v[1], g.y + v[2]
end

local function straight_route(x1, y, x2)
  local route = { nodes = { { x = x1, y = y } }, edges = {} }
  for x = x1, x2 - 1 do
    route.edges[#route.edges + 1] = { kind = "ground", direction = 4, length = 1, from_x = x, from_y = y, to_x = x + 1, to_y = y }
    route.nodes[#route.nodes + 1] = { x = x + 1, y = y, direction = 4 }
  end
  return route
end

--- Маршрут из отрезков {dir, len} от точки.
local function route_of(x, y, segs)
  local route = { nodes = { { x = x, y = y } }, edges = {} }
  for _, s in ipairs(segs) do
    local v = X.VEC[s[1]]
    for _ = 1, s[2] do
      route.edges[#route.edges + 1] = {
        kind = "ground", direction = s[1], length = 1, from_x = x, from_y = y, to_x = x + v[1], to_y = y + v[2],
      }
      x, y = x + v[1], y + v[2]
      route.nodes[#route.nodes + 1] = { x = x, y = y, direction = s[1] }
    end
  end
  return route
end

local function lane_cells(lane)
  local out = {}
  for _, n in ipairs(lane.nodes) do out[#out + 1] = X.key(n.x, n.y) end
  return out
end

S.suite("belt_lanes", {
  { "пачка: прямая в две и в четыре ленты", function()
      X.setup()
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), lanes = 2 }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.eq(#g, 42)
      S.eq(d.detail.lanes, 2)
      S.eq(d.detail.ghosts, 42)
      S.eq(d.detail.length, 21, "длина — одной ленты")
      S.eq(d.detail.need, { ["transport-belt"] = 42 })
      S.eq(d.detail.area, { left_top = { x = 0, y = 0 }, right_bottom = { x = 21, y = 2 } })
      S.eq(d.detail.warnings, {})
      local c = chains(g)
      S.eq(#c, 2)
      S.eq(#c[1], 21)
      S.eq(#c[2], 21)
      S.ok(no_overlap(g))

      X.setup()
      d, kind = X.plan{ from = P(0, 0), to = P(0, 20), lanes = 4 }
      S.eq(kind, "job_done", S.dump(d))
      g = X.ghosts()
      S.eq(#chains(g), 4)
      S.eq(#g, 84)
      S.ok(no_overlap(g))
      for _, ghost in ipairs(g) do S.eq(ghost.direction, X.D.south) end
  end },
  { "пачка с поворотами: ленты параллельны, не пересекаются, каждая непрерывна и той же формы", function()
      X.setup()
      X.tiles("lava", 15, -10, 15, 30)
      X.tiles("lava", -20, 31, 15, 31)
      local d, kind = X.plan{ from = P(0, 0), to = P(30, 20), lanes = 3, underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      local c = chains(g)
      S.eq(#c, 3, "три цепочки")
      S.eq(d.detail.lanes, 3)
      S.ok(no_overlap(g))
      S.ok(not has(d.detail.warnings, "not_bundled"), S.dump(d.detail.warnings))
      for _, chain in ipairs(c) do
        S.ok(X.continuous(chain))
        local turns = 0
        for i = 2, #chain do
          if chain[i].direction ~= chain[i - 1].direction then turns = turns + 1 end
        end
        S.eq(turns, d.detail.turns, "у лент пачки одинаковое число поворотов")
        for _, ghost in ipairs(chain) do S.ok(ghost.x ~= 15 or ghost.y < -10, "призрак на лаве") end
      end
      -- концы пачки стоят рядом
      local ends = {}
      for _, chain in ipairs(c) do ends[#ends + 1] = chain[#chain] end
      S.ok(math.abs(ends[1].x - ends[3].x) + math.abs(ends[1].y - ends[3].y) == 2, "концы рядом: " .. S.dump(ends))
  end },
  { "derive_lanes: смещения лент на прямой и в повороте; тесный разворот не складывается", function()
      local lanes = beltpath.derive_lanes(straight_route(0, 5, 4), 2)
      S.eq(lane_cells(lanes[1]), { "0,5", "1,5", "2,5", "3,5", "4,5" })
      S.eq(lane_cells(lanes[2]), { "0,6", "1,6", "2,6", "3,6", "4,6" })
      -- на восток, потом на юг (правый поворот): левая лента — внешняя
      lanes = beltpath.derive_lanes(route_of(0, 0, { { 4, 3 }, { 8, 3 } }), 2)
      S.eq(lane_cells(lanes[1]), { "0,0", "1,0", "2,0", "3,0", "4,0", "4,1", "4,2", "4,3" })
      S.eq(lane_cells(lanes[2]), { "0,1", "1,1", "2,1", "3,1", "3,2", "3,3" })
      -- на восток, потом на север (левый поворот): левая лента — внутренняя
      lanes = beltpath.derive_lanes(route_of(0, 0, { { 4, 3 }, { 0, 3 } }), 2)
      S.eq(lane_cells(lanes[1]), { "0,0", "1,0", "2,0", "3,0", "3,-1", "3,-2", "3,-3" })
      S.eq(lane_cells(lanes[2]), { "0,1", "1,1", "2,1", "3,1", "4,1", "4,0", "4,-1", "4,-2", "4,-3" })
      -- разворот через 1 клетку: внутренней ленте негде повернуть
      S.eq(beltpath.derive_lanes(route_of(0, 0, { { 4, 5 }, { 8, 1 }, { 12, 5 } }), 2), nil)
      -- разворот через 3 клетки — складывается, ленты не пересекаются
      lanes = beltpath.derive_lanes(route_of(0, 0, { { 4, 5 }, { 8, 3 }, { 12, 5 } }), 2)
      S.ok(lanes ~= nil)
      local seen = {}
      for _, lane in ipairs(lanes) do
        for _, k in ipairs(lane_cells(lane)) do
          S.eq(seen[k], nil, "клетка занята дважды: " .. k)
          seen[k] = true
        end
      end
      -- подземный участок в опорном пути — пачка не складывается
      local r = straight_route(0, 0, 4)
      r.edges[2].kind = "underground"
      S.eq(beltpath.derive_lanes(r, 2), nil)
  end },
  { "рядом с путём нет места: пачка идёт широким проходом, если он не намного длиннее", function()
      X.setup()
      -- стена с двумя проходами: узкий (1 клетка) прямо по ходу и широкий (3 клетки) чуть в стороне
      X.tiles("lava", 10, -30, 10, 30)
      X.tiles("grass-1", 10, 0, 10, 0)
      X.tiles("grass-1", 10, 6, 10, 8)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), lanes = 2, underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.eq(#chains(g), 2)
      S.ok(not has(d.detail.warnings, "not_bundled"), S.dump(d.detail.warnings))
      S.eq(X.at(g, 10, 0), nil, "узкий проход не использован")
      S.ok(X.at(g, 10, 6) or X.at(g, 10, 7), "пачка идёт широким проходом")
      S.ok(no_overlap(g))
  end },
  { "широкого прохода нет: ленты ищутся по одной (not_bundled), каждая непрерывна", function()
      X.setup()
      -- два узких прохода далеко друг от друга
      X.tiles("lava", 10, -30, 10, 30)
      X.tiles("grass-1", 10, 0, 10, 0)
      X.tiles("grass-1", 10, 12, 10, 12)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), lanes = 2, underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      local c = chains(g)
      S.eq(#c, 2)
      S.ok(has(d.detail.warnings, "not_bundled"), S.dump(d.detail.warnings))
      S.ok(X.at(g, 10, 0) and X.at(g, 10, 12), "ленты прошли разными проходами")
      S.ok(no_overlap(g))
      for _, chain in ipairs(c) do S.ok(X.continuous(chain)) end
      S.eq(c[1][1].x, 0)
      S.eq(c[1][1].y, 0)
      S.eq(c[2][1].y, 1, "вторая лента начинается справа от первой")
      S.eq(c[2][#c[2]].x, 20)
      S.eq(c[2][#c[2]].y, 1, "и приходит к цели справа от первой")
  end },
  { "второй ленте пути нет: path_failed с номером ленты, призраков нет", function()
      X.setup()
      X.tiles("lava", 10, -60, 10, 60)
      X.tiles("grass-1", 10, 0, 10, 0)
      local d, kind = X.plan{ from = P(0, 0), to = P(20, 0), lanes = 2, underground = "never" }
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "path_failed")
      S.eq(d.detail.lane, 2)
      S.eq(#X.ghosts(), 0)
  end },

  -- ------------------------------------------------------------------ from = "patch"

  { "patch: один выход — лента от него до цели; призрак ленты разметки не дублируется", function()
      X.setup()
      -- выход разметки: призрак ленты, смотрит на север
      S.nauvis.create_entity{
        name = "entity-ghost", position = P(5, 10), direction = X.D.north, force = "player",
        fields = { ghost_type = "transport-belt", ghost_name = "transport-belt" },
      }
      S.nauvis.created = {}
      storage.mining_last = { h1 = { surface = S.nauvis.index, tick = 1, outputs = { { pos = P(5, 10), direction = X.D.north } } } }
      local d, kind = X.plan{ from = "patch", to = P(30, -10) }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.eq(X.at(g, 5, 10), nil, "на клетку выхода призрак не ставится")
      S.eq(g[1].x, 5)
      S.eq(g[1].y, 9, "лента продолжает выход")
      S.eq(g[#g].x, 30)
      S.eq(g[#g].y, -10)
      S.ok(X.continuous(g))
      S.eq(d.detail.lanes, 1)
  end },
  { "patch: три выхода в одну ленту — два вливаются сбоку у пятна", function()
      X.setup()
      storage.mining_last = { h1 = { surface = "nauvis", tick = 1, outputs = {
        { pos = P(0, 10), direction = "north" }, { pos = P(7, 10), direction = "north" }, { pos = P(14, 10), direction = "north" },
      } } }
      local d, kind = X.plan{ from = "patch", to = P(50, -20) }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      local c = chains(g)
      S.eq(#c, 3, "лента до цели и два притока: " .. #c)
      S.eq(d.detail.lanes, 1)
      S.eq(d.detail.merged, 2)
      S.ok(no_overlap(g))
      S.ok(not has(d.detail.warnings, "unmerged_outputs:1"))
      local trunk = c[1]
      S.eq(trunk[#trunk].x, 50)
      S.eq(trunk[#trunk].y, -20)
      S.eq(trunk[1].x, 14, "до цели идёт ближний к ней выход")
      for i = 2, 3 do
        local feeder = c[i]
        S.ok(X.continuous(feeder))
        S.eq(feeder[1].direction, X.D.north, "приток выходит, куда смотрит выход разметки")
        local last = feeder[#feeder]
        local ax, ay = ahead(last)
        -- вливается в ленту до цели или в приток, влитый раньше
        local target = X.at(trunk, ax, ay) or (i == 3 and X.at(c[2], ax, ay)) or nil
        S.ok(target ~= nil, "приток упирается в ленту своей группы: " .. S.dump(last))
        S.ok((target.direction + 8) % 16 ~= last.direction, "не навстречу")
        local tx, ty = ahead(target)
        S.ok(not (tx == last.x and ty == last.y), "ленты не смотрят друг в друга")
      end
      S.eq(c[2][1].x, 7, "ближний к ленте выход вливается первым")
      -- все выходы начинаются в своих клетках
      for _, x in ipairs({ 0, 7, 14 }) do S.ok(X.at(g, x, 10), "выход " .. x) end
  end },
  { "patch: lanes = 2 — две ленты до цели рядом, третий выход вливается в свою группу", function()
      X.setup()
      storage.mining_last = { h1 = { surface = 1, tick = 1, outputs = {
        { pos = P(0, 10), direction = 0 }, { pos = P(7, 10), direction = 0 }, { pos = P(14, 10), direction = 0 },
      } } }
      storage.mining_last.h1.surface = S.nauvis.index
      local d, kind = X.plan{ from = "patch", to = P(50, -20), lanes = 2 }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      local c = chains(g)
      S.eq(#c, 3)
      S.eq(d.detail.lanes, 2)
      S.eq(d.detail.merged, 1)
      S.ok(no_overlap(g))
      local e1, e2 = c[1][#c[1]], c[2][#c[2]]
      S.eq(e1.x, 50)
      S.eq(e1.y, -20)
      S.eq(math.abs(e1.x - e2.x) + math.abs(e1.y - e2.y), 1, "вторая лента приходит рядом с первой")
      S.eq(e1.direction, e2.direction)
  end },
  { "patch: выходу некуда влиться — предупреждение unmerged_outputs, остальное построено", function()
      X.setup()
      storage.mining_last = { h1 = { surface = "nauvis", tick = 1, outputs = {
        { pos = P(0, 10), direction = "north" }, { pos = P(-30, 10), direction = "north" },
      } } }
      -- второй выход заперт лавой
      X.tiles("lava", -33, 7, -27, 13)
      X.tiles("grass-1", -30, 9, -30, 10)
      local d, kind = X.plan{ from = "patch", to = P(40, 10) }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "unmerged_outputs:1"), S.dump(d.detail.warnings))
      S.eq(d.detail.merged, nil)
      S.ok(X.continuous(X.ghosts()))
  end },
  { "patch: нет разметки, другая поверхность, слишком много выходов", function()
      X.setup()
      local d, kind = X.plan{ from = "patch", to = P(30, 0) }
      S.eq(kind, "job_failed")
      S.eq(d.code, "not_found")
      storage.mining_last = { h1 = { surface = "vulcanus", tick = 1, outputs = { { pos = P(0, 10), direction = 0 } } } }
      d = X.plan{ from = "patch", to = P(30, 0) }
      S.eq(d.code, "not_found")
      storage.mining_last = { other = { surface = "nauvis", tick = 1, outputs = { { pos = P(0, 10), direction = 0 } } } }
      d = X.plan{ from = "patch", to = P(30, 0) }
      S.eq(d.code, "not_found", "разметка другого помощника не берётся")
      local outputs = {}
      for i = 1, 17 do outputs[i] = { pos = P(i * 3, 10), direction = 0 } end
      storage.mining_last = { h1 = { surface = "nauvis", tick = 1, outputs = outputs } }
      d = X.plan{ from = "patch", to = P(30, 0) }
      S.eq(d.code, "limit")
      S.eq(#X.ghosts(), 0)
  end },
})
