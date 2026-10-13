-- scripts/lib/build.lua (поток F): геометрия, подход, дроны, запасные vis/target (пока нет ревизии 3.1),
-- раскладка чертежа. Действия целиком — в build_place / build_ghosts / build_blueprint / build_deconstruct.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

local function lib() return require("scripts.lib.build") end

S.suite("build_lib", {
  { "half_size / footprint / tile_size: коробка, поворот, запасной размер", function()
      F.setup()
      local B = lib()
      local furnace = prototypes.entity["stone-furnace"]
      local hx, hy = B.half_size(furnace, 0)
      S.near(hx, 0.9); S.near(hy, 0.9)
      local wide = { name = "wide", collision_box = { left_top = { x = -1.4, y = -0.4 }, right_bottom = { x = 1.4, y = 0.4 } } }
      S.eq({ B.half_size(wide, 0) }, { 1.4, 0.4 })
      S.eq({ B.half_size(wide, 4) }, { 0.4, 1.4 })
      S.eq({ B.half_size(wide, 8) }, { 1.4, 0.4 })
      S.eq({ B.half_size(wide, 12) }, { 0.4, 1.4 })
      S.eq({ B.half_size(nil, 0) }, { 0.5, 0.5 })
      S.eq({ B.half_size({ tile_width = 3, tile_height = 2 }, 0) }, { 1.5, 1 })
      S.eq({ B.tile_size(wide, 0) }, { 3, 1 })
      S.eq({ B.tile_size(wide, 4) }, { 1, 3 })
      S.eq({ B.tile_size(furnace, 0) }, { 2, 2 })
      S.eq(B.footprint(wide, { x = 10, y = 5 }, 4),
        { left_top = { x = 9.6, y = 3.6 }, right_bottom = { x = 10.4, y = 6.4 } })
  end },
  { "body_inside и aside_point", function()
      local W = F.setup()
      local B = lib()
      local chest = prototypes.entity["iron-chest"]
      S.move(W.h, { x = 5.5, y = 5.5 })
      S.eq(B.body_inside(W.h, chest, { x = 5.5, y = 5.5 }, 0), true)
      S.eq(B.body_inside(W.h, chest, { x = 6.1, y = 5.5 }, 0), true)
      S.eq(B.body_inside(W.h, chest, { x = 6.5, y = 5.5 }, 0), false)
      local p = B.aside_point(W.h, chest, { x = 5.5, y = 5.5 }, 0)
      S.ok(S.dist(p, { x = 5.5, y = 5.5 }) > 1.5)
      S.move(W.h, { x = 5.5, y = 6.0 })
      local p2 = B.aside_point(W.h, chest, { x = 5.5, y = 5.5 }, 0)
      S.near(p2.x, 5.5)
      S.ok(p2.y > 7, "отходит в ту сторону, где уже стоит")
  end },
  { "place_items: строки, таблицы, пусто", function()
      F.setup()
      local B = lib()
      S.eq(B.place_items({ items_to_place_this = { { name = "rail", count = 3 }, "other" } }),
        { { name = "rail", count = 3 }, { name = "other", count = 1 } })
      S.eq(B.place_items({}), {})
      S.eq(B.place_items(nil), {})
  end },
  { "approach: на месте — true без ходьбы; иначе ctx.approach с запасом; смена цели сбрасывает путь", function()
      local W = F.setup()
      local B = lib()
      local calls, cancels = {}, 0
      local ctx = {
        entity = W.h,
        approach = function(task, pos, d) calls[#calls + 1] = { x = pos.x, y = pos.y, d = d } return nil end,
        cancel_approach = function() cancels = cancels + 1 end,
      }
      local task = {}
      S.move(W.h, { x = 0, y = 0 })
      S.eq(B.approach(task, ctx, { x = 5, y = 0 }, 9.5), true)
      S.eq(#calls, 0)
      S.eq(B.approach(task, ctx, { x = 30, y = 0 }, 9.5), nil)
      S.eq(calls[1], { x = 30, y = 0, d = 8 })
      S.eq(B.approach(task, ctx, { x = 30, y = 0 }, 9.5), nil)
      S.eq(cancels, 0)
      S.eq(B.approach(task, ctx, { x = 0, y = 40 }, 9.5), nil)
      S.eq(cancels, 1, "старый путь снят при смене цели")
      -- ошибка пути уходит как есть и сбрасывает цель
      ctx.approach = function() return { status = "failed", code = "path_failed" } end
      S.eq(B.approach(task, ctx, { x = 0, y = 40 }, 9.5).code, "path_failed")
      S.eq(task._goal, nil)
      -- «дошёл», но не достаём — ещё попытки ближе, потом stuck
      ctx.approach = function() return true end
      local r
      for _ = 1, 6 do
        r = B.approach(task, ctx, { x = 0, y = 40 }, 9.5)
        if r ~= nil then break end
      end
      S.eq(r.code, "stuck")
      B.stop_approach(task, ctx)
      S.eq({ task._goal, task._tries }, { nil, nil })
  end },
  { "robots: нет робопорта — nil; есть — {total, available, radius}", function()
      local W = F.setup()
      local B = lib()
      S.eq(B.robots(W.h), nil)
      local net = F.give_robots(W.h, 5, 15)
      net.available_construction_robots = 3
      S.eq(B.robots(W.h), { total = 5, available = 3, radius = 15 })
  end },
  { "resolve: через scripts.core.target, только своя сила и neutral, открытый чанк, своя поверхность", function()
      local W = F.setup()
      local B = lib()
      local ctx = { helper_id = "h1", entity = W.h }
      local mine = C.chest({ x = 5.5, y = 0.5 }, {})
      local enemy = C.chest({ x = 6.5, y = 0.5 }, {}, { force = "enemy" })
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 7, y = 0 }, force = "neutral" }
      S.eq(B.resolve(ctx, { unit_number = mine.unit_number }), mine)
      S.eq(B.resolve(ctx, { name = "tree-01", pos = { x = 7, y = 0 } }), tree)
      S.eq(F.target.calls, 2)
      S.raises(function() B.resolve(ctx, { unit_number = enemy.unit_number }) end, "not_found")
      S.raises(function() B.resolve(ctx, { unit_number = 424242 }) end, "not_found")
      local far = C.chest({ x = 100.5, y = 0.5 }, {})
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      S.raises(function() B.resolve(ctx, { unit_number = far.unit_number }) end, "not_charted")
      local other = S.surface{ name = "vulcanus" }
      local there = C.chest({ x = 1.5, y = 0.5 }, {}, { surface = other })
      -- фейковый target ищет только на своей поверхности — чужая поверхность даёт not_found
      S.raises(function() B.resolve(ctx, { unit_number = there.unit_number }) end, "not_found")
  end },
  { "запасной vis: видимый чанк силы или ≤ 32 клеток от живого тела помощника", function()
      local W = F.setup()
      local B = lib()
      local V = B.fallback_vis
      local f = game.forces.player
      S.move(W.h, { x = 0, y = 0 })
      S.eq(V.visible("h1", S.nauvis, { x = 100, y = 0 }), true, "чанк виден силе")
      f.invisible[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      f.invisible[S.chunk_key(S.nauvis, { x = 0, y = 0 })] = true
      S.eq(V.visible("h1", S.nauvis, { x = 100, y = 0 }), false)
      S.eq(V.visible("h1", S.nauvis, { x = 20, y = 0 }), true, "собственные глаза: 32 клетки")
      S.eq(V.visible("nobody", S.nauvis, { x = 1, y = 0 }), false)
      storage.helpers.h1.state = "dead"
      S.eq(V.visible("h1", S.nauvis, { x = 1, y = 0 }), false, "мёртвый помощник не видит")
  end },
  { "запасной target: unit_number (и поиск рядом с pos), name+pos — ближайшая, чужое не фильтрует", function()
      F.setup()
      local B = lib()
      local T = B.fallback_target
      local a = C.chest({ x = 5.5, y = 0.5 }, {})
      local b = C.chest({ x = 6.5, y = 0.5 }, {})
      S.eq(T.resolve(S.nauvis, { unit_number = a.unit_number }), a)
      S.eq(T.resolve(S.nauvis, { name = "iron-chest", pos = { x = 6.4, y = 0.5 } }), b)
      S.eq(T.resolve(S.nauvis, { name = "iron-chest", pos = { x = 50, y = 0 } }), nil)
      S.eq(T.resolve(S.nauvis, { name = "no-such-entity", pos = { x = 5.5, y = 0.5 } }), nil)
      S.eq(T.resolve(S.nauvis, { unit_number = 31337 }), nil)
      -- 2.0: get_entity_by_unit_number находит не всё — тогда поиск рядом с pos
      local orig = game.get_entity_by_unit_number
      game.get_entity_by_unit_number = function() return nil end
      S.eq(T.resolve(S.nauvis, { unit_number = a.unit_number }), nil)
      S.eq(T.resolve(S.nauvis, { unit_number = a.unit_number, pos = { x = 5.5, y = 0.5 } }), a)
      S.eq(T.resolve(S.nauvis, { unit_number = a.unit_number, pos = { x = 30, y = 0 } }), nil)
      game.get_entity_by_unit_number = orig
      S.eq(T.resolve(S.nauvis, "iron-chest"), nil)
  end },
  { "revive: причины отказа по порядку — качество, обзор, далеко, нет предмета, тело, заблокирован", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      local B = lib()
      local ctx = { helper_id = "h1", entity = W.h }
      S.move(W.h, { x = 0.5, y = 0.5 })
      local function entry(g) return { e = g, item = "iron-chest", count = 1 } end
      local rare = F.ghost("iron-chest", { x = 3.5, y = 0.5 }, { quality = "rare" })
      S.eq({ B.revive(ctx, entry(rare)) }, { nil, "quality" })
      local g = F.ghost("iron-chest", { x = 4.5, y = 0.5 })
      F.vis.result = false
      S.eq({ B.revive(ctx, entry(g)) }, { nil, "not_visible" })
      F.vis.result = true
      local far = F.ghost("iron-chest", { x = 14.5, y = 0.5 })
      S.eq({ B.revive(ctx, entry(far)) }, { nil, "far" })
      S.eq({ B.revive(ctx, { e = g, item = "iron-chest", count = 2 }) }, { nil, "no_items" })
      local under = F.ghost("iron-chest", { x = 0.5, y = 0.5 })
      S.eq({ B.revive(ctx, entry(under)) }, { nil, "body" })
      F.blocked[F.key(g.position)] = { ghost_revive = true }
      S.eq({ B.revive(ctx, entry(g)) }, { nil, "blocked" })
      S.eq(F.revive_calls, 0)
      F.blocked = {}
      local e = B.revive(ctx, entry(g))
      S.eq({ e.name, e.valid, g.valid }, { "iron-chest", true, false })
      S.eq(C.counts(W.main), {})
      S.eq({ B.revive(ctx, entry(g)) }, { nil, "gone" })
  end },
  { "раскладка чертежа: центр рамки в anchor, повороты, привязка к сетке", function()
      F.setup()
      local A = require("scripts.actions.build_blueprint")
      local ents = {
        { name = "assembling-machine-1", position = { x = 100.5, y = 50.5 } },
        { name = "iron-chest", position = { x = 102.5, y = 50.5 }, direction = 4 },
      }
      -- рамка: x 99..103, y 49..52 → центр (101, 50.5)
      local plan = A.layout(ents, { x = 10, y = 20.5 }, 0)
      S.eq({ plan[1].pos, plan[1].dir }, { { x = 9.5, y = 20.5 }, 0 })
      S.eq({ plan[2].pos, plan[2].dir }, { { x = 11.5, y = 20.5 }, 4 })
      local r = A.layout(ents, { x = 10.5, y = 20 }, 4)
      S.eq({ r[1].pos, r[1].dir }, { { x = 10.5, y = 19.5 }, 4 })
      S.eq({ r[2].pos, r[2].dir }, { { x = 10.5, y = 21.5 }, 8 })
      local r2 = A.layout(ents, { x = 10, y = 20.5 }, 8)
      S.eq(r2[1].pos, { x = 10.5, y = 20.5 })
      S.eq(r2[2].pos, { x = 8.5, y = 20.5 })
      local r3 = A.layout(ents, { x = 10.5, y = 20 }, 12)
      S.eq(r3[1].pos, { x = 10.5, y = 20.5 })
      S.eq(r3[2].pos, { x = 10.5, y = 18.5 })
      S.eq(A.layout({}, { x = 0, y = 0 }, 0), {})
  end },
  { "модуль держит контракт интерфейса действий и не трогает запрещённое", function()
      F.setup()
      for _, name in ipairs({ "place", "build_blueprint", "build_ghosts", "deconstruct" }) do
        local m = require("scripts.actions." .. name)
        S.eq(m.name, name)
        S.eq({ type(m.schema), type(m.start), type(m.tick), type(m.stop) }, { "table", "function", "function", "function" })
        S.eq(m.events, nil)
        S.eq(m.ops, nil)
      end
      S.eq(require("scripts.lib.build").NORMAL, "normal")
  end },
})
