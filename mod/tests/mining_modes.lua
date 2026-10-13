-- plan_mining (поток M): все семь раскладок MPP на одном пятне, во все стороны; код MPP на месте
-- (лицензия, шапки файлов), метатаблицы сетки зарегистрированы для сохранения.
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_m")

local ALL = { "electric-mining-drill", "transport-belt", "underground-belt", "small-electric-pole", "pipe",
  "passive-provider-chest" }
local LAYOUTS = { "simple", "compact", "super_compact", "sparse", "logistics", "compact_logistics", "sparse_logistics" }
local DIRS = { "north", "east", "south", "west" }
local BELTS = { simple = true, compact = true, super_compact = true, sparse = true }
local UNDERGROUND = { compact = true, super_compact = true }

local function plan(layout, dir, extra)
  X.setup{ research = ALL }
  local ore = X.patch("iron-ore", 0, 0, 14, 11)
  local args = { near = { x = 5, y = 4 }, layout = layout, direction = dir }
  for k, v in pairs(extra or {}) do args[k] = v end
  local d, kind = X.plan(args)
  S.eq(kind, "job_done", layout .. "/" .. dir .. ": " .. S.dump(d))
  return d.detail, ore
end

--- Постройки одного плана не налезают друг на друга (по клеткам).
local function no_overlap(label)
  local taken = {}
  for _, g in ipairs(X.ghosts()) do
    if g.kind == "entity-ghost" then
      local p = prototypes.entity[g.name]
      local w, h = p.tile_width, p.tile_height
      for dx = 0, w - 1 do
        for dy = 0, h - 1 do
          local k = math.floor(g.pos.x - w / 2 + dx + 0.01) .. "," .. math.floor(g.pos.y - h / 2 + dy + 0.01)
          S.ok(taken[k] == nil, label .. ": клетка " .. k .. " занята дважды: " .. tostring(taken[k]) .. " и " .. g.name)
          taken[k] = g.name
        end
      end
    end
  end
end

local cases = {}

for _, layout in ipairs(LAYOUTS) do
  cases[#cases + 1] = { layout .. ": призраки во все четыре стороны, руда покрыта, постройки не пересекаются", function()
      for _, dir in ipairs(DIRS) do
        local t, ore = plan(layout, dir)
        local label = layout .. "/" .. dir
        S.eq(t.layout, layout)
        S.ok(t.ghosts > 0 and t.drills > 0, label)
        S.eq(#X.ghosts(), t.ghosts, label .. ": detail.ghosts")
        S.eq(t.need, X.ghost_counts(), label .. ": need")
        S.eq(t.skipped, 0, label .. ": " .. S.dump(t.warnings))
        S.eq(#X.ghosts("electric-mining-drill"), t.drills, label)
        local ok, missed = X.covered(ore, "electric-mining-drill")
        S.ok(ok, label .. ": не покрыто клеток " .. missed)
        no_overlap(label)
        if BELTS[layout] then
          S.ok((t.need["transport-belt"] or 0) > 0, label .. ": лента")
          S.eq(t.need["passive-provider-chest"], nil, label)
          S.eq(t.chosen.belt, "transport-belt")
          -- обычная лента идёт к выходу или поперёк (сборная), но не от выхода
          local opposite = (X.D[dir] + 8) % 16
          local toward = 0
          for _, b in ipairs(X.ghosts("transport-belt")) do
            S.ok(b.direction ~= opposite, label .. ": лента течёт от выхода " .. S.dump(b))
            if b.direction == X.D[dir] then toward = toward + 1 end
          end
          S.ok(toward > 0, label .. ": есть лента к выходу")
        else
          S.eq(t.need["transport-belt"], nil, label)
          S.ok((t.need["passive-provider-chest"] or 0) > 0, label .. ": сундуки")
          S.eq(t.chosen.chest, "passive-provider-chest")
          S.eq(t.chosen.belt, nil)
        end
        if UNDERGROUND[layout] then
          local under = X.ghosts("underground-belt")
          S.ok(#under > 0, label .. ": подземная лента")
          local ins, outs = 0, 0
          for _, u in ipairs(under) do
            if u.type == "input" then ins = ins + 1 elseif u.type == "output" then outs = outs + 1
            else error(label .. ": подземная лента без type: " .. S.dump(u)) end
          end
          S.eq(ins, outs, label .. ": входы и выходы подземной ленты парные")
        end
      end
  end }
end

cases[#cases + 1] = { "sparse ставит меньше буров, чем simple; super_compact — не меньше simple", function()
    local simple = plan("simple", "north").drills
    local sparse = plan("sparse", "north").drills
    local super = plan("super_compact", "north").drills
    S.ok(sparse < simple, sparse .. " < " .. simple)
    S.ok(super >= simple, super .. " >= " .. simple)
end }

cases[#cases + 1] = { "большой бур 5×5: simple и sparse работают, super_compact — нет", function()
    local big = { "big-mining-drill", "transport-belt", "underground-belt", "medium-electric-pole", "small-electric-pole" }
    for _, layout in ipairs({ "simple", "sparse", "compact" }) do
      X.setup{ research = big }
      local ore = X.patch("iron-ore", 0, 0, 30, 24)
      local d, kind = X.plan{ near = { x = 5, y = 4 }, layout = layout }
      S.eq(kind, "job_done", layout .. ": " .. S.dump(d))
      S.eq(d.detail.chosen.miner, "big-mining-drill")
      S.ok(X.covered(ore, "big-mining-drill"), layout)
      no_overlap(layout .. "/big")
    end
    X.setup{ research = big }
    X.patch("iron-ore", 0, 0, 30, 24)
    local d, kind = X.plan{ near = { x = 5, y = 4 }, layout = "super_compact" }
    S.eq(kind, "job_failed", S.dump(d))
    S.eq(d.code, "bad_args")
end }

cases[#cases + 1] = { "бур 2×2 (твердотопливный): simple раскладывается без столбов", function()
    X.setup{ research = { "burner-mining-drill", "transport-belt" } }
    local ore = X.patch("iron-ore", 0, 0, 10, 8)
    local d, kind = X.plan{ near = { x = 5, y = 4 } }
    S.eq(kind, "job_done", S.dump(d))
    S.ok(d.detail.drills > 0)
    no_overlap("burner")
    -- постройка 2×2 стоит на границе клеток
    for _, g in ipairs(X.ghosts("burner-mining-drill")) do
      S.eq(g.pos.x % 1, 0, S.dump(g.pos))
      S.eq(g.pos.y % 1, 0, S.dump(g.pos))
    end
end }

cases[#cases + 1] = { "неровное пятно с дырой: раскладка строится, руда покрыта", function()
    X.setup{ research = ALL }
    local ore = {}
    for y = 0, 17 do
      for x = 0, 21 do
        local dx, dy = x - 10.5, y - 8.5
        local r = dx * dx / 110 + dy * dy / 72
        if r < 1 and not (math.abs(dx) < 2 and math.abs(dy) < 2) then
          ore[#ore + 1] = C.resource("iron-ore", { x = x + 0.5, y = y + 0.5 }, 500 + x * 7 + y)
        end
      end
    end
    for _, layout in ipairs({ "simple", "compact", "sparse" }) do
      S.nauvis.created = {}
      for _, e in ipairs(S.nauvis._entities) do
        if e.valid and e.name == "entity-ghost" then e.valid = false end
      end
      local d, kind = X.plan{ near = { x = 5, y = 8 }, layout = layout }
      S.eq(kind, "job_done", layout .. ": " .. S.dump(d))
      local ok, missed = X.covered(ore, "electric-mining-drill")
      S.ok(ok, layout .. ": не покрыто клеток " .. missed .. " " .. S.dump(d.detail.warnings))
      no_overlap(layout .. "/blob")
    end
end }

cases[#cases + 1] = { "код MPP: лицензия MIT рядом, у каждого файла шапка с автором и версией", function()
    local env = __fp_test_env
    local base = env.mod_dir .. "/scripts/vendor/mpp/"
    local license = env.read(base .. "LICENSE")
    S.ok(license and license:find("MIT License", 1, true), "LICENSE")
    S.ok(license:find("Rimbas", 1, true), "автор в LICENSE")
    local readme = env.read(base .. "README.md")
    S.ok(readme and readme:find("1.7.19", 1, true), "README с версией")
    for _, f in ipairs({ "layouts/base.lua", "layouts/common.lua", "layouts/simple.lua", "layouts/compact.lua",
      "layouts/super_compact.lua", "layouts/sparse.lua", "layouts/logistics.lua", "layouts/compact_logistics.lua",
      "layouts/sparse_logistics.lua", "mpp/mpp_util.lua", "mpp/grid_mt.lua", "mpp/pole_grid_mt.lua", "mpp/list.lua",
      "mpp/cliffs.lua", "mpp/global_extends.lua" }) do
      local src = env.read(base .. f)
      S.ok(src, "нет файла " .. f)
      local head = src:sub(1, 400)
      S.ok(head:find("Mining Patch Planner 1.7.19", 1, true) and head:find("Rimbas", 1, true)
        and head:find("MIT", 1, true), "шапка " .. f)
      -- интерфейс игрока в код раскладок не попал (закомментированная отладка автора не в счёт)
      local code = src:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", "")
      for _, word in ipairs({ "state%.player", "storage%.", "settings%.", "game%.print", "rendering%.", "helpers%." }) do
        S.ok(not code:find(word), f .. ": осталось " .. word)
      end
    end
    for _, f in ipairs({ "mpp/builder.lua", "partner/adapter.lua", "partner/noop.lua" }) do
      S.ok(env.read(base .. f), "нет файла " .. f)
    end
    for _, f in ipairs({ "mpp/render_util.lua", "mpp/belt_planner.lua", "mpp/drawing.lua", "gui/gui.lua",
      "layouts/blueprints.lua" }) do
      S.eq(env.read(base .. f), nil, "лишний файл " .. f)
    end
end }

cases[#cases + 1] = { "метатаблицы сетки MPP регистрируются при загрузке (состояние переживает сейв)", function()
    S.reset()
    local reg = {}
    script.register_metatable = function(name, mt)
      S.ok(type(mt) == "table" and reg[name] == nil, "метатаблица " .. tostring(name))
      reg[name] = mt
    end
    S.load_mod{ reset = false }
    for _, name in ipairs({ "fp_mpp_List", "fp_mpp_grid", "fp_mpp_pole_grid" }) do
      S.ok(reg[name], "не зарегистрирована " .. name)
    end
    S.ok(reg.fp_mpp_grid.get_tile and reg.fp_mpp_pole_grid.add_pole)
    S.ok(require("scripts.core.jobs").actions.plan_mining, "действие зарегистрировано в control.lua")
end }

S.suite("mining_modes", cases)
