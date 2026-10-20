-- Действие connect_entities, вид pipe: трубы и подземные трубы из прототипов, концы у машин по
-- жидкости, запрет смешения жидкостей (клетки, к которым смотрит чужая коробка), fluid_mix,
-- no_free_port, dry_run. ACTIONS.md «connect_entities».
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_n")
local J = require("stubs_j")

local function P(x, y) return { x = x + 0.5, y = y + 0.5 } end

local function near(g, x, y)
  return math.abs(g.x - x) + math.abs(g.y - y) <= 1
end

--- Цепочка труб связна: каждая следующая клетка — соседняя, либо пара подземных труб на линии.
local function linked(g)
  for i = 1, #g - 1 do
    local a, b = g[i], g[i + 1]
    local d = math.abs(a.x - b.x) + math.abs(a.y - b.y)
    if d ~= 1 then
      if not (a.name == "pipe-to-ground" and b.name == "pipe-to-ground" and (a.x == b.x or a.y == b.y) and d <= 10) then
        return false, "разрыв у #" .. i .. ": " .. S.dump(a) .. " → " .. S.dump(b)
      end
    end
  end
  return true
end

S.suite("connect_pipe", {
  { "клетка → клетка: трубы из прототипов, направление не важно, итог по контракту", function()
      J.setup()
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 0) }, to = { pos = P(8, 0) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      local t = d.detail
      S.eq(t.kind, "pipe")
      S.eq(t.length, 9)
      S.eq(t.chosen, { pipe = "pipe", underground = "pipe-to-ground" })
      S.eq(t.need, { pipe = 9 })
      local g = X.ghosts()
      S.eq(#g, 9)
      for _, ghost in ipairs(g) do
        S.eq(ghost.name, "pipe")
        S.eq(ghost.direction, 0)
        S.eq(ghost.type, nil, "у призрака трубы нет type input/output")
      end
  end },
  { "конец-машина: берётся свободное соединение коробки с нужной жидкостью, ближнее к другому концу", function()
      J.setup()
      -- химзавод 3×3 в (10, 0): коробка 1 — нефть (соединение к клетке (9, 1)), коробка 2 — вода (к (13, 1) и (11, 3))
      local plant = J.machine(10, 0, { boxes = {
        { targets = { { 9, 1 } }, filter = "crude-oil" },
        { targets = { { 13, 1 }, { 11, 3 } }, filter = "water" },
      } })
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(11, 10) },
        to = { target = { unit_number = plant.unit_number } }, fluid = "water", build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.to_pos, P(11, 3), "ближнее соединение водяной коробки")
      local g = X.ghosts()
      S.ok(linked(g))
      S.eq({ g[#g].x, g[#g].y }, { 11, 3 })
      for _, ghost in ipairs(g) do S.ok(not (ghost.x == 9 and ghost.y == 1), "не к нефтяной коробке") end
  end },
  { "конец {layout, i}: постройка блока ищется по имени и месту", function()
      J.setup()
      local plant = J.machine(10, 0, { boxes = { { targets = { { 9, 1 } }, filter = "water" } } })
      J.block("chem", 2, { name = "chemical-plant", pos = { x = plant.position.x, y = plant.position.y } })
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(2, 1) }, to = { layout = "chem", i = 2 }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.to_pos, P(9, 1))
      d, kind = J.connect{ kind = "pipe", from = { pos = P(2, 5) }, to = { layout = "chem", i = 3 }, build = false }
      S.eq({ kind, d.code }, { "job_failed", "not_found" })
  end },
  { "жидкость не та: у машины нет коробки под fluid → cannot_place fluid_mix", function()
      J.setup()
      local plant = J.machine(10, 0, { boxes = { { targets = { { 9, 1 } }, filter = "water" } } })
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(2, 1) },
        to = { target = { unit_number = plant.unit_number } }, fluid = "crude-oil" }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "cannot_place", "fluid_mix" }, S.dump(d))
      S.eq(#X.ghosts(), 0)
  end },
  { "концы с разной жидкостью → fluid_mix; стоящая труба на конце с другой жидкостью → fluid_mix", function()
      J.setup()
      local a = J.machine(0, 0, { boxes = { { targets = { { 3, 1 } }, filter = "water" } } })
      local b = J.machine(12, 0, { boxes = { { targets = { { 11, 1 } }, filter = "steam" } } })
      local d, kind = J.connect{ kind = "pipe", from = { target = { unit_number = a.unit_number } },
        to = { target = { unit_number = b.unit_number } } }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "cannot_place", "fluid_mix" }, S.dump(d))
      J.pipe(5, 8, "steam")
      d, kind = J.connect{ kind = "pipe", from = { pos = P(5, 8) }, to = { pos = P(5, 14) }, fluid = "water" }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "cannot_place", "fluid_mix" }, S.dump(d))
  end },
  { "чужая труба рядом с прямой: путь обходит клетки, к которым она смотрит (без смешения)", function()
      J.setup()
      J.pipe(6, 1, "steam")
      J.pipe(6, -1, "steam")
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 0) }, to = { pos = P(12, 0) }, build = false,
        underground = "never" }
      S.eq(kind, "job_done", S.dump(d))
      local g = X.ghosts()
      S.ok(linked(g))
      for _, ghost in ipairs(g) do
        S.ok(not near(ghost, 6, 1) and not near(ghost, 6, -1), "труба рядом с чужой: " .. S.dump(ghost))
      end
  end },
  { "конец рядом с чужой коробкой → cannot_place fluid_mix", function()
      J.setup()
      J.pipe(6, 1, "steam")
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 0) }, to = { pos = P(6, 0) } }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "cannot_place", "fluid_mix" }, S.dump(d))
  end },
  { "подземная труба под стеной: пара на линии, вход смотрит назад, выход — вперёд, дальность из прототипа", function()
      J.setup()
      X.wall(6, -20, 7, 20)
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 0) }, to = { pos = P(14, 0) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.undergrounds, 1)
      local u = X.ghosts("pipe-to-ground")
      S.eq(#u, 2)
      S.eq({ u[1].x, u[1].y, u[1].direction }, { 5, 0, X.D.west })
      S.eq({ u[2].x, u[2].y, u[2].direction }, { 8, 0, X.D.east })
      S.eq(u[1].type, nil)
      S.ok(linked(X.ghosts()))
  end },
  { "подземная труба не ложится на линию чужой подземной трубы той же оси", function()
      J.setup()
      X.wall(6, -3, 7, 3)
      local e = S.nauvis.create_entity{ name = "pipe-to-ground", position = P(12, 0), direction = X.D.west, force = "player" }
      S.ok(e ~= nil)
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 0) }, to = { pos = P(10, 0) }, build = false }
      S.eq(kind, "job_done", S.dump(d))
      for _, ghost in ipairs(X.ghosts("pipe-to-ground")) do
        S.ok(ghost.y ~= 0, "подземная на линии чужой: " .. S.dump(ghost))
      end
  end },
  { "все соединения машины заняты → cannot_place no_free_port", function()
      J.setup()
      local plant = J.machine(10, 0, { boxes = { { targets = { { 9, 1 } }, filter = "water" } } })
      X.thing(9, 1)
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(2, 1) },
        to = { target = { unit_number = plant.unit_number } } }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "cannot_place", "no_free_port" }, S.dump(d))
  end },
  { "порт трубы блока: клетка порта, жидкость порта сверяется с fluid", function()
      J.setup()
      J.port("blk", "w", { pos = P(4, 4), kind = "pipe", io = "in", fluid = "water" })
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 4) }, to = { layout = "blk", port = "w" },
        fluid = "steam" }
      S.eq({ kind, d.code, d.detail.reason }, { "job_failed", "cannot_place", "fluid_mix" }, S.dump(d))
      d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 4) }, to = { layout = "blk", port = "w" },
        fluid = "water", build = false }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.to_pos, P(4, 4))
  end },
  { "dry_run: ничего не ставит; fluid у ленты — bad_args", function()
      J.setup()
      local d, kind = J.connect{ kind = "pipe", from = { pos = P(0, 0) }, to = { pos = P(5, 0) }, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.dry_run, true)
      S.eq(#X.ghosts(), 0)
      d, kind = J.connect{ kind = "belt", from = { pos = P(0, 0) }, to = { pos = P(5, 0) }, fluid = "water" }
      S.eq({ kind, d.code }, { "job_failed", "bad_args" })
  end },
})
