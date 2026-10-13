-- plan_mining, ревизия 3.3 (поток V3): жидкость под рудой (`on_liquid`), выходы с участка
-- (`narrow_access`, `enclosed`, `access_side`), сторона ленты по лучшему выходу, лимит итоговой
-- области, запись `storage.mining_last`. ACTIONS.md «plan_mining», STATE.md «access», PROTOCOL §6.12, §7.
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_m")

local VEC = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }
local NEAR = { x = 5, y = 4 }

local function has(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

local function starts(list, prefix)
  for _, v in ipairs(list) do if v:sub(1, #prefix) == prefix then return v end end
  return nil
end

--- Пятно 12×9 (клетки 0..11 × 0..8) на «острове» с полями в 4 клетки, вокруг — плитка `name`.
--- Рамка расчёта выходов — пятно + 8 клеток: -8..19 × -8..16.
local function island(name)
  local ore = X.patch("iron-ore", 0, 0, 12, 9)
  X.pool(-8, -8, 19, -5, name)
  X.pool(-8, 13, 19, 16, name)
  X.pool(-8, -4, -5, 12, name)
  X.pool(16, -4, 19, 12, name)
  return ore
end

--- Убрать плитки из прямоугольника (коридор через жидкость).
local function dig(x0, y0, x1, y1)
  local keep = {}
  for _, t in ipairs(X.water_tiles) do
    if not (t.x >= x0 and t.x <= x1 and t.y >= y0 and t.y <= y1) then keep[#keep + 1] = t end
  end
  X.water_tiles = keep
end

local function belt_dirs()
  local dirs = {}
  for _, b in ipairs(X.ghosts("transport-belt")) do dirs[b.direction] = true end
  return dirs
end

S.suite("mining_access", {
  { "открытое место: предупреждений о выходах нет, лента — на север", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local d, kind = X.plan{ near = NEAR }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.warnings, {})
      S.eq(belt_dirs(), { [X.D.north] = true })
  end },
  { "storage.mining_last: концы выходных лент после настоящей разметки (все четыре стороны)", function()
      for dir, vec in pairs(VEC) do
        X.setup()
        X.patch("iron-ore", 0, 0, 12, 9)
        S.tick(7)
        local d, kind = X.plan{ near = NEAR, direction = dir }
        S.eq(kind, "job_done", dir .. ": " .. S.dump(d))
        local last = storage.mining_last and storage.mining_last.h1
        S.ok(last, dir .. ": запись есть")
        S.eq(last.surface, "nauvis")
        S.eq(last.surface_index, S.nauvis.index)
        S.ok(last.tick > 0 and last.tick <= game.tick)
        S.ok(#last.outputs >= 1, dir .. ": есть выходы")
        local belts = {}
        for _, b in ipairs(X.ghosts("transport-belt")) do belts[X.key(b.pos)] = b end
        for _, o in ipairs(last.outputs) do
          S.eq(o.direction, X.D[dir], dir .. ": направление — defines.direction")
          S.eq(o.side, dir)
          local b = belts[X.key(o.pos)]
          S.ok(b, dir .. ": выход — клетка призрака ленты " .. S.dump(o.pos))
          S.eq(b.direction, X.D[dir])
          S.eq(belts[X.key({ x = o.pos.x + vec[1], y = o.pos.y + vec[2] })], nil, dir .. ": дальше ленты нет")
        end
        -- каждый конец выходной ленты в списке: лент, смотрящих наружу без продолжения, столько же
        local ends = 0
        for _, b in pairs(belts) do
          if b.direction == X.D[dir] and belts[X.key({ x = b.pos.x + vec[1], y = b.pos.y + vec[2] })] == nil then
            ends = ends + 1
          end
        end
        S.eq(#last.outputs, ends, dir)
        -- только простые данные: запись переживает сохранение
        S.ok(#helpers.table_to_json(last) > 0)
      end
  end },
  { "storage.mining_last: сухой прогон и неудача запись не трогают; у каждого помощника своя", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.plan{ near = NEAR, dry_run = true }
      S.eq((storage.mining_last or {}).h1, nil, "dry_run ничего не пишет")
      X.plan{ near = NEAR, direction = "east" }
      local first = S.copy(storage.mining_last.h1)
      S.eq(first.outputs[1].side, "east")
      -- повтор на том же месте: cannot_place, запись прежняя
      local d2, kind2 = X.plan{ near = NEAR, direction = "east" }
      S.eq(kind2, "job_failed", S.dump(d2))
      S.eq(storage.mining_last.h1, first)
      -- сухой прогон после настоящего запись тоже не меняет
      X.patch("iron-ore", 40, 40, 12, 9)
      X.plan{ near = { x = 45, y = 44 }, dry_run = true }
      S.eq(storage.mining_last.h1, first)
  end },
  { "сундуки вместо лент (logistics): запись есть, выходов нет", function()
      X.setup{ research = { "electric-mining-drill", "transport-belt", "small-electric-pole", "passive-provider-chest" } }
      X.patch("iron-ore", 0, 0, 12, 9)
      local d, kind = X.plan{ near = NEAR, layout = "logistics" }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(storage.mining_last.h1.outputs, {})
  end },
  { "остров с одним широким выходом: access_side, лента сама выходит в ту сторону", function()
      X.setup()
      island("lava")
      dig(16, 1, 19, 6) -- коридор на восток шириной 6
      local d, kind = X.plan{ near = NEAR }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "access_side:east"), S.dump(d.detail.warnings))
      S.ok(not has(d.detail.warnings, "narrow_access"), S.dump(d.detail.warnings))
      S.ok(not has(d.detail.warnings, "enclosed"))
      S.eq(belt_dirs(), { [X.D.east] = true }, "лента смотрит на восток")
      S.eq(storage.mining_last.h1.outputs[1].side, "east")
  end },
  { "направление, заданное хозяином, сильнее лучшего выхода (предупреждение остаётся)", function()
      X.setup()
      island("lava")
      dig(16, 1, 19, 6)
      local d, kind = X.plan{ near = NEAR, direction = "north", dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "access_side:east"), S.dump(d.detail.warnings))
      local dirs = {}
      for _, c in ipairs(X.checks) do
        if c.name == "transport-belt" then dirs[c.direction] = true end
      end
      S.eq(dirs, { [X.D.north] = true })
  end },
  { "узкий выход: narrow_access + access_side, разметка всё равно ставится", function()
      X.setup()
      island("lava")
      dig(1, 13, 2, 16) -- коридор на юг шириной 2
      local d, kind = X.plan{ near = NEAR }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "narrow_access"), S.dump(d.detail.warnings))
      S.ok(has(d.detail.warnings, "access_side:south"), S.dump(d.detail.warnings))
      S.ok(d.detail.ghosts > 0)
      S.eq(#X.ghosts(), d.detail.ghosts)
      S.eq(belt_dirs(), { [X.D.south] = true })
  end },
  { "выходов нет: enclosed, разметка ставится, лента — на север", function()
      X.setup()
      island("lava")
      local d, kind = X.plan{ near = NEAR }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "enclosed"), S.dump(d.detail.warnings))
      S.eq(starts(d.detail.warnings, "access_side"), nil)
      S.eq(starts(d.detail.warnings, "narrow_access"), nil)
      S.ok(d.detail.ghosts > 0)
      S.eq(belt_dirs(), { [X.D.north] = true })
  end },
  { "плитка планеты из мода: имён в коде нет — пройти можно, значит не остров", function()
      X.setup()
      island("mod-moss") -- маска не сталкивается ни с телом, ни с буром
      local d, kind = X.plan{ near = NEAR, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.warnings, {})
  end },
  { "руда под жидкостью: on_liquid:N, буры на такие клетки не ставятся (лава и плитка из мода)", function()
      for _, tile in ipairs({ "lava", "water", "mod-mist" }) do
        X.setup()
        X.patch("iron-ore", 0, 0, 12, 9)
        local base = X.plan{ near = NEAR, dry_run = true }
        X.pool(0, 0, 2, 2, tile)   -- 9 клеток руды под плиткой
        X.pool(-3, 0, -1, 2, tile) -- рядом, но не под рудой: в счёт не идёт
        local d, kind = X.plan{ near = NEAR }
        S.eq(kind, "job_done", tile .. ": " .. S.dump(d))
        S.eq(d.detail.warnings[1], "on_liquid:9", tile .. ": " .. S.dump(d.detail.warnings))
        S.eq(d.detail.tiles, 0, tile .. ": подложку без просьбы не ставим")
        S.ok(d.detail.drills <= base.detail.drills, tile)
        local drills = X.ghosts("electric-mining-drill")
        S.ok(#drills > 0)
        for _, g in ipairs(drills) do
          for _, t in ipairs(X.water_tiles) do
            local inside = t.x + 0.5 > g.pos.x - 1.5 and t.x + 0.5 < g.pos.x + 1.5
              and t.y + 0.5 > g.pos.y - 1.5 and t.y + 0.5 < g.pos.y + 1.5
            S.ok(not inside, tile .. ": бур " .. S.dump(g.pos) .. " стоит на плитке " .. S.dump(t))
          end
        end
      end
  end },
  { "предупреждения о жидкости и выходах идут первыми и не теряются при обрезке до 20", function()
      X.setup()
      island("lava")
      X.pool(0, 0, 1, 0, "lava")
      local d, kind = X.plan{ near = NEAR, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.warnings[1], "on_liquid:2")
      S.eq(d.detail.warnings[2], "enclosed")
      S.ok(#d.detail.warnings <= 20)
  end },
  { "итоговая область с полями больше 128 → limit до первого призрака", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 128, 9) -- само пятно в лимит влезает, разметка с полями — нет
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "limit", S.dump(d))
      S.ok(d.text:find("args.area", 1, true), d.text)
      S.eq(#X.ghosts(), 0, "ни одного призрака не поставлено")
      S.eq(#X.marked, 0)
      S.eq((storage.mining_last or {}).h1, nil)
      local a = d.detail.area
      S.ok(a.right_bottom.x - a.left_top.x > 128, "область в detail: " .. S.dump(a))
      -- сухой прогон отвечает тем же
      local d2, kind2 = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(kind2, "job_failed")
      S.eq(d2.code, "limit")
      -- по частям — проходит
      local d3, kind3 = X.plan{ area = { left_top = { x = 0, y = -2 }, right_bottom = { x = 60, y = 11 } } }
      S.eq(kind3, "job_done", S.dump(d3))
      S.ok(d3.detail.area.right_bottom.x - d3.detail.area.left_top.x <= 128)
  end },
  { "сухой прогон не встал — настоящий не начинается (cannot_place без призраков и пометок)", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.tree({ x = 4.5, y = 1.5 })
      X.block_all = true
      local d, kind = X.plan{ near = NEAR }
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "cannot_place")
      S.eq(#X.ghosts(), 0)
      S.eq(#X.marked, 0, "деревья не помечены")
      S.eq(d.detail.dry_run, nil, "агент просил настоящий прогон")
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "сохранение и загрузка между сухим и настоящим прогоном", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 20, 15)
      local job = S.okr(C.act("plan_mining", { near = NEAR })).job
      local t
      for _ = 1, 400 do
        C.run(1)
        t = storage.jobs.by_helper.h1.active
        if t == nil or (t.mpp_plan and t.mpp_plan.phase == "real") then break end
      end
      S.ok(t and t.mpp_plan.phase == "real", "дошли до настоящего прогона")
      S.eq(#X.ghosts(), 0, "сухой прогон ничего не поставил")
      S.reload()
      local d, kind = C.wait(job, 2000)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(#X.ghosts(), d.detail.ghosts)
      S.ok(storage.mining_last.h1)
  end },
})
