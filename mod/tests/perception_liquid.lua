-- `map` — проходимость и жидкости по правилам из игры, `resources.clipped`,
-- `ghosts` считает плитки, `state.body` / `state.module_errors`. Контракт: docs/STATE.md, PROTOCOL §6.12.
local G = require("stubs_g")

local function cell(d, x, y)
  local r = y - d.bbox.y0 + 1
  local c = x - d.bbox.x0 + 1
  return d.rows[r]:sub(c, c)
end

-- 1. map: `~` — не пройти, `,` — пройти можно, но нужна подложка; легенда и liquids называют плитки
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0.5, y = 0.5 } })
  local s = w.surface
  for x = 3, 5 do s.set_tile(x, 2, "lava") end
  s.set_tile(3, 3, "lava-hot")
  s.set_tile(-4, -4, "water-shallow")
  s.set_tile(-3, -4, "water-shallow")
  s.set_tile(40, 0, "lava") -- вне карты: не считается
  local M = require("scripts.perception.map")
  local d = M.ops.map({ radius = 6 }, ctx)
  G.plain(d)
  G.eq(cell(d, 3, 2), "~")
  G.eq(cell(d, 5, 2), "~")
  G.eq(cell(d, 3, 3), "~")
  G.eq(cell(d, -4, -4), ",")
  G.eq(cell(d, 0, 1), ".")
  G.eq(d.legend["~"], "не пройти: lava, lava-hot")
  G.eq(d.legend[","], "мелко: water-shallow")
  G.eq(d.liquids, {
    lava = { n = 3, cover = "foundation", cover_ok = false },
    ["lava-hot"] = { n = 1, cover = "foundation", cover_ok = false },
    ["water-shallow"] = { n = 2, cover = "landfill", cover_ok = false },
  })
  -- без жидкости в рамке: поле есть и пустое, в легенде `~` нет
  local dry = M.ops.map({ radius = 2, center = { x = -20, y = 20 } }, ctx)
  G.eq(dry.liquids, {})
  G.eq(dry.legend["~"], nil)
  G.eq(dry.legend[","], nil)
  local js = G.json(d)
  G.ok(js:find('"liquids":{', 1, true), "liquids is an object")
end

-- 2. map: подложка доступна — рецепт открыт силе, предмет у помощника или на складе рядом
do
  local w = G.reset()
  local main = G.inventory({ landfill = 3 })
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0.5, y = 0.5 }, main = main })
  local s = w.surface
  s.set_tile(2, 2, "water")
  s.set_tile(3, 2, "lava")
  local M = require("scripts.perception.map")
  local d = M.ops.map({ radius = 4 }, ctx)
  G.eq(d.liquids.water, { n = 1, cover = "landfill", cover_ok = true }, "landfill is in the inventory")
  G.eq(d.liquids.lava.cover_ok, false)
  -- рецепт открыт
  w.force.recipes["foundation"] = { name = "foundation", enabled = true }
  d = M.ops.map({ radius = 4 }, ctx)
  G.eq(d.liquids.lava.cover_ok, true, "recipe is researched")
  w.force.recipes["foundation"] = { name = "foundation", enabled = false }
  d = M.ops.map({ radius = 4 }, ctx)
  G.eq(d.liquids.lava.cover_ok, false, "disabled recipe does not count")
  -- предмет на складе рядом
  s.add(G.entity { name = "steel-chest", type = "container", pos = { x = 10.5, y = 0.5 }, force = w.force,
    inventory = G.inventory({ foundation = 1 }) })
  d = M.ops.map({ radius = 4 }, ctx)
  G.eq(d.liquids.lava.cover_ok, true, "foundation is in a chest nearby")
end

-- 3. map: имён плиток в коде нет — плитка планеты из мода работает по своим маскам
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0.5, y = 0.5 } })
  G.TILES["mod-acid-sea"] = { layers = { some_mod_layer = true, player = true } }          -- не пройти, подложки нет
  G.TILES["mod-swamp"] = { layers = { item = true }, cover = "mod-planks" }                -- пройти, подложка своя
  G.TILES["mod-planks"] = { layers = { ground_tile = true }, item = "mod-plank" }
  G.TILES["mod-glass"] = { layers = { water_tile = true } }                                 -- «водяной» слой, но тело проходит
  local s = w.surface
  s.set_tile(1, 1, "mod-acid-sea")
  s.set_tile(2, 1, "mod-swamp")
  s.set_tile(3, 1, "mod-glass")
  local d = require("scripts.perception.map").ops.map({ radius = 4 }, ctx)
  G.eq(cell(d, 1, 1), "~")
  G.eq(cell(d, 2, 1), ",")
  G.eq(cell(d, 3, 1), ".", "tile the body can cross and that needs no cover is plain land")
  G.eq(d.legend["~"], "не пройти: mod-acid-sea")
  G.eq(d.liquids, {
    ["mod-acid-sea"] = { n = 1, cover_ok = false },
    ["mod-swamp"] = { n = 1, cover = "mod-plank", cover_ok = false },
  })
  -- маска тела другая (мод поменял персонажа): по воде оно ходит
  prototypes.entity.character.collision_mask = { layers = { train = true } }
  ctx.entity.prototype.collision_mask = { layers = { train = true } }
  s.set_tile(-2, -2, "water")
  d = require("scripts.perception.map").ops.map({ radius = 4 }, ctx)
  G.eq(cell(d, -2, -2), ",", "walkable for this body, still needs a cover to build")
  G.eq(cell(d, 1, 1), ".", "no cover and walkable for this body")
end

-- 4. map: длинный список плиток в подписи обрезается, liquids — не больше MAX_LIQUIDS
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0.5, y = 0.5 } })
  local M = require("scripts.perception.map")
  for i = 1, 20 do
    G.TILES["sea-" .. string.format("%02d", i)] = { layers = { player = true } }
    w.surface.set_tile(-10 + i, 3, "sea-" .. string.format("%02d", i))
  end
  local d = M.ops.map({ radius = 12 }, ctx)
  G.ok(d.legend["~"]:find(", %+14$"), d.legend["~"])
  local n = 0
  for _ in pairs(d.liquids) do n = n + 1 end
  G.eq(n, M.MAX_LIQUIDS)
end

-- 5. resources: пятно, обрезанное кругом поиска, помечено clipped, числа — только часть в круге
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local function ore(name, x, y, amount)
    w.surface.add(G.entity { name = name, type = "resource", pos = { x = x + 0.5, y = y + 0.5 },
      force = w.neutral, amount = amount or 100 })
  end
  for x = 5, 30 do ore("iron-ore", x, 0) end       -- уходит за круг радиуса 20
  for x = -8, -4 do ore("coal", x, 0) end          -- целиком в круге
  for x = 21, 25 do ore("stone", x, 10) end        -- целиком за кругом (в кольце и дальше)
  local R = require("scripts.perception.resources")
  local d = R.ops.resources({ radius = 20 }, ctx)
  G.plain(d)
  G.eq(#d.patches, 2, "patch that is entirely outside the circle is not listed")
  local iron, coal
  for _, p in ipairs(d.patches) do
    if p.name == "iron-ore" then iron = p else coal = p end
  end
  G.eq(iron.clipped, true)
  G.eq(iron.tiles, 15, "cells 5..19: centre of cell 19 is 19.5 from the helper")
  G.eq(iron.amount, 1500)
  G.eq(iron.area, { left_top = { x = 5, y = 0 }, right_bottom = { x = 20, y = 1 } })
  G.eq(coal.clipped, nil, "whole patch: no flag")
  G.eq(coal.tiles, 5)
  -- круг шире — пятно целое
  prototypes.entity["iron-ore"] = { name = "iron-ore", type = "resource" }
  d = R.ops.resources({ radius = 40, name = "iron-ore" }, ctx)
  G.eq(d.patches[1].clipped, nil)
  G.eq(d.patches[1].tiles, 26)
  -- кластеризация: клетки `out` связывают, но не считаются; пятно только из `out` не выдаётся
  local p = R.cluster({ { x = 0, y = 0, amount = 1 }, { x = 1, y = 0, amount = 1, out = true }, { x = 9, y = 9, out = true } })
  G.eq(#p, 1)
  G.eq(p[1].tiles, 1)
  G.eq(p[1].clipped, true)
end

-- 6. ghosts: призраки плиток — в need и в tiles, но не в count/by_name; blocked их не проверяет
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 }, main = G.inventory({ landfill = 2 }) })
  local s = w.surface
  local function tile_ghost(x, y, name, item)
    local g = G.entity { name = "tile-ghost", type = "tile-ghost", pos = { x = x, y = y }, force = w.force, unit = false }
    g.ghost_name = name
    g.ghost_prototype = { name = name, items_to_place_this = { { name = item, count = 1 } } }
    return s.add(g)
  end
  for i = 1, 5 do tile_ghost(i + 0.5, 3.5, "landfill", "landfill") end
  tile_ghost(40.5, 3.5, "landfill", "landfill")
  w.force.set_charted(1, 0, false) -- плитка в неоткрытом чанке не считается
  s.blocked["2.5:3.5"] = true      -- под призраком плитки: проверка ghost_revive к плиткам не относится
  s.add(G.entity { name = "entity-ghost", type = "entity-ghost", ghost_name = "transport-belt",
    pos = { x = 0.5, y = 5.5 }, force = w.force })
  local d = require("scripts.perception.ghosts").ops.ghosts({}, ctx)
  G.plain(d)
  G.eq(d.count, 1)
  G.eq(d.tiles, 5)
  G.eq(d.by_name, { ["transport-belt"] = 1 })
  G.eq(d.need, { ["transport-belt"] = 1, landfill = 5 })
  G.eq(d.have.helper, { landfill = 2 })
  G.eq(d.missing, { ["transport-belt"] = 1, landfill = 3 })
  G.eq(d.blocked_total, 0)
  for _, c in ipairs(s.calls) do
    if c[1] == "find_entities_filtered" and type(c[2].type) == "table" and c[2].type[1] == "entity-ghost" then
      G.eq(c[2].type, { "entity-ghost", "tile-ghost" })
    end
  end
  -- без плиток поле есть и равно 0
  local w2 = G.reset()
  local _, ctx2 = G.add_helper(w2, "h1", { pos = { x = 0, y = 0 } })
  G.eq(require("scripts.perception.ghosts").ops.ghosts({}, ctx2).tiles, 0)
end

-- 7. state: body и module_errors (данные ядра; без них — запасные значения)
do
  local w = G.reset()
  local _, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local St = require("scripts.perception.state")
  local d = St.ops.state({}, ctx)
  G.plain(d)
  G.eq(d.body, "character")
  G.eq(type(d.module_errors), "number")
  local base = d.module_errors
  -- тело-игрок: запись помощника с player_index
  storage.helpers.h1.player_index = 2
  G.eq(St.ops.state({}, ctx).body, "player")
  storage.helpers.h1.player_index = nil
  -- счётчик ошибок — тот же, что в hello
  require("scripts.core.err").count_module_error()
  G.eq(St.ops.state({}, ctx).module_errors, base + 1)
  require("scripts.core.err").count_module_error("reflex flee", "boom")
  local st = St.ops.state({}, ctx)
  G.eq(#st.module_errors_last, 1)
  G.eq(st.module_errors_last[1].where, "reflex flee")
  G.eq(st.module_errors_last[1].text, "boom")
  -- функция ядра сильнее, а её сбой не роняет state
  local registry = require("scripts.core.registry")
  local saved = registry.body_kind
  registry.body_kind = function(id) return id == "h1" and "player" or "character" end
  G.eq(St.ops.state({}, ctx).body, "player")
  registry.body_kind = function() error("boom") end
  G.eq(St.ops.state({}, ctx).body, "character")
  registry.body_kind = saved
end
