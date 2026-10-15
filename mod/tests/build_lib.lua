-- scripts/lib/build.lua: геометрия, подход, дроны, цель и обзор через ядро, разбор руками,
-- помехи (помеченное к сносу, плитки под постройками), плитка руками, раскладка чертежа. Действия целиком — в build_place / build_ghosts / build_blueprint / build_deconstruct.
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
  { "обзор — через scripts.core.vis, запасных реализаций в модуле нет", function()
      local W = F.setup()
      local B = lib()
      local ctx = { helper_id = "h1", entity = W.h }
      S.eq({ B.fallback_vis, B.fallback_target }, { nil, nil })
      F.vis.result = false
      S.eq(B.visible(ctx, { x = 1, y = 0 }), false)
      F.vis.result = true
      S.eq(B.visible(ctx, { x = 1, y = 0 }), true)
      S.eq(F.vis.calls, 2)
      S.eq(F.vis.last.helper, "h1")
  end },
  { "dig_step: подход, selected + mining_state, removed; исчезла сама — gone; не поддаётся — skipped; нет места — full", function()
      local W = F.setup()
      local B = lib()
      local path = W.path
      local function ctx_of()
        return {
          helper_id = "h1", entity = W.h, tick = game.tick,
          approach = function() return true end, cancel_approach = function() end,
        }
      end
      S.move(W.h, { x = 18.5, y = 0.5 })
      -- разобрали сами
      local ch = C.chest({ x = 20.5, y = 0.5 }, {})
      local task = {}
      local st = B.dig_new(W.h, ch)
      S.eq({ st.name, st.pos, st.started }, { "iron-chest", { x = 20.5, y = 0.5 }, false })
      S.ok(st.timeout >= B.DIG_MIN_TIMEOUT)
      local r
      for _ = 1, 600 do
        r = B.dig_step(task, ctx_of(), st)
        if r ~= "working" then break end
        S.eq(W.h.selected, ch)
        S.eq(W.h.mining_state.mining, true)
        F.run(1)
      end
      S.eq(r, "removed")
      S.eq({ ch.valid, task.mining, W.h.mining_state.mining }, { false, false, false })
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      -- исчезла не от наших рук
      local other = C.chest({ x = 21.5, y = 0.5 }, {})
      local st2 = B.dig_new(W.h, other)
      S.eq(B.dig_step(task, ctx_of(), st2), "working")
      other.destroy()
      S.eq(B.dig_step(task, ctx_of(), st2), "gone")
      -- не поддаётся
      local hard = C.chest({ x = 19.5, y = 1.5 }, {}, { name = "wooden-chest" })
      C.mining_disabled = true
      local st3 = B.dig_new(W.h, hard)
      local r3
      for _ = 1, st3.timeout + 5 do
        r3 = B.dig_step(task, ctx_of(), st3)
        if r3 ~= "working" then break end
        F.run(1)
      end
      S.eq(r3, "skipped")
      S.eq(W.h.mining_state.mining, false)
      C.mining_disabled = false
      -- нет места под предмет
      for i = 1, 80 do W.main.insert{ name = "coal", count = 50 } end
      local st4 = B.dig_new(W.h, hard)
      S.eq(B.dig_step(task, ctx_of(), st4), "full")
      S.ok(hard.valid)
      -- ошибка пути уходит как есть
      S.move(W.h, { x = 80.5, y = 0.5 })
      local c5 = ctx_of()
      c5.approach = function() return { status = "failed", code = "path_failed" } end
      S.eq(B.dig_step(task, c5, B.dig_new(W.h, hard)).code, "path_failed")
      S.ok(path ~= nil)
  end },
  { "can_dig / dig_reach: камни и деревья — вплотную (resource_reach_distance), постройки — с reach_distance", function()
      local W = F.setup()
      local B = lib()
      F.reach_only_openable = true
      S.move(W.h, { x = 0.5, y = 0.5 })
      local rock = S.nauvis.create_entity{ name = "big-rock", position = { x = 5.5, y = 0.5 }, force = "neutral" }
      local near_rock = S.nauvis.create_entity{ name = "big-rock", position = { x = 2.5, y = 0.5 }, force = "neutral" }
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 0.5, y = 2.8 }, force = "neutral" }
      local ch = C.chest({ x = 9.5, y = 0.5 }, {})
      S.eq({ B.dig_reach(W.h, rock) }, { 2.7, B.NEAR_MARGIN })
      S.eq({ B.dig_reach(W.h, tree) }, { 2.7, B.NEAR_MARGIN })
      S.eq({ B.dig_reach(W.h, ch) }, { 10, B.REACH_MARGIN })
      S.eq(B.can_dig(W.h, rock), false, "с 5 клеток камень не достать")
      S.eq(B.can_dig(W.h, near_rock), true)
      S.eq(B.can_dig(W.h, tree), true)
      S.eq(B.can_dig(W.h, ch), true)
      -- подходит вплотную (путь — почти на предел досягаемости) и разбирает
      local calls = {}
      local ctx = {
        helper_id = "h1", entity = W.h,
        approach = function(task, pos, d)
          calls[#calls + 1] = d
          return W.path.step(task, { entity = W.h }, pos, d)
        end,
        cancel_approach = function() end,
      }
      local task = {}
      local st = B.dig_new(W.h, rock)
      local r
      for _ = 1, 900 do
        ctx.tick = game.tick
        r = B.dig_step(task, ctx, st)
        if r ~= "working" then break end
        if W.h.mining_state.mining then
          S.ok(S.dist(W.h.position, rock.position) <= 2.7, "копает только вплотную")
        end
        F.run(1)
      end
      S.eq(r, "removed")
      S.near(calls[1], 2.7 - B.NEAR_MARGIN - 0.4)
      S.eq(C.counts(W.main), { stone = 3 })
  end },
  { "why_not_minable / has_driver: персонажи, призраки, руда, некопаемое", function()
      local W = F.setup()
      local B = lib()
      S.eq(B.why_not_minable(C.chest({ x = 5.5, y = 0.5 }, {})), nil)
      S.ok(B.why_not_minable(W.h) ~= nil)
      S.ok(B.why_not_minable(F.ghost("iron-chest", { x = 6.5, y = 0.5 })) ~= nil)
      S.ok(B.why_not_minable(F.tile_ghost("stone-path", { x = 7, y = 0 })) ~= nil)
      S.ok(B.why_not_minable(C.resource("iron-ore", { x = 8.5, y = 0.5 }, 10)) ~= nil)
      S.ok(B.why_not_minable(S.nauvis.create_entity{ name = "bedrock", position = { x = 9, y = 0 }, force = "player" }) ~= nil)
      local car = S.nauvis.create_entity{ name = "car", position = { x = 12, y = 0 }, force = "player" }
      S.eq(B.has_driver(car), false)
      rawset(car, "get_driver", function() return W.h end)
      S.eq(B.has_driver(car), true)
  end },
  { "marked / survey / waits_for: помеченное своей силы и neutral, плитки под постройкой, пропущенное", function()
      local W = F.setup()
      local B = lib()
      local area = { left_top = { x = 15, y = -5 }, right_bottom = { x = 30, y = 5 } }
      local chest = prototypes.entity["iron-chest"]
      local furnace = prototypes.entity["stone-furnace"]
      local tree = F.mark(S.nauvis.create_entity{ name = "tree-01", position = { x = 20.5, y = 0.5 }, force = "neutral" })
      local mine = F.mark(C.chest({ x = 22.5, y = 0.5 }, {}))
      local plain = C.chest({ x = 24.5, y = 0.5 }, {})                                    -- не помечен
      local enemy = F.mark(C.chest({ x = 26.5, y = 0.5 }, {}, { force = "enemy" }))        -- чужой
      local rockbed = F.mark(S.nauvis.create_entity{ name = "bedrock", position = { x = 28.5, y = 0.5 }, force = "player" })
      local far = F.mark(C.chest({ x = 60.5, y = 0.5 }, {}))                               -- вне области
      S.eq(B.is_marked(tree), true)
      S.eq(B.is_marked(plain), false)
      local m = B.marked(W.h, area)
      local names = {}
      for _, x in ipairs(m) do names[#names + 1] = x.name .. "@" .. x.pos.x end
      table.sort(names)
      S.eq(names, { "iron-chest@22.5", "tree-01@20.5" })
      S.ok(enemy.valid and rockbed.valid and far.valid)
      F.tile_ghost("landfill", { x = 18, y = 2 })
      F.tile_ghost("landfill", { x = 16, y = 2 })
      local dead = { [B.ghost_key("landfill", { x = 16.5, y = 2.5 })] = true }
      local sv = B.survey(W.h, area, nil, dead)
      S.eq(#sv.marked, 2)
      S.eq({ sv.tiles["18,2"], sv.tiles["16,2"], sv.tiles["17,2"] }, { true, false, nil })
      local why, obstacles = B.waits_for(sv, chest, { x = 20.5, y = 0.5 }, 0)
      S.eq({ why, #obstacles, obstacles[1].name }, { "decon", 1, "tree-01" })
      S.eq(B.waits_for(sv, chest, { x = 21.5, y = 0.5 }, 0), nil, "соседняя клетка свободна")
      S.eq(B.waits_for(sv, chest, { x = 18.5, y = 2.5 }, 0), "tile")
      S.eq(B.waits_for(sv, chest, { x = 16.5, y = 2.5 }, 0), "tile_dead")
      S.eq(B.waits_for(sv, furnace, { x = 18, y = 2 }, 0), "tile", "2×2 накрывает клетку с плиткой")
      S.eq(B.waits_for(sv, chest, { x = 24.5, y = 0.5 }, 0), nil, "непомеченная постройка — не «ожидание»")
      -- помеху, которую разобрать не вышло, больше не ждём
      local skip = { [obstacles[1].key] = "stuck" }
      S.eq(B.waits_for(sv, chest, { x = 20.5, y = 0.5 }, 0, skip), "decon_dead")
      tree.destroy()
      S.eq(B.waits_for(sv, chest, { x = 20.5, y = 0.5 }, 0), nil, "помеха исчезла")
  end },
  { "revive_tile: предмет плитки из инвентаря, плитка на поверхности; отказы и возврат предмета", function()
      local W = F.setup{ items = { ["stone-brick"] = 2 } }
      local B = lib()
      local ctx = { helper_id = "h1", entity = W.h }
      S.move(W.h, { x = 0.5, y = 0.5 })
      local function entry(g, n) return { e = g, item = "stone-brick", count = n or 1 } end
      local g = F.tile_ghost("stone-path", { x = 4, y = 0 })
      S.eq(g.position, { x = 4.5, y = 0.5 })
      F.vis.result = false
      S.eq({ B.revive_tile(ctx, entry(g)) }, { nil, "not_visible" })
      F.vis.result = true
      S.eq({ B.revive_tile(ctx, entry(F.tile_ghost("stone-path", { x = 14, y = 0 }))) }, { nil, "far" })
      S.eq({ B.revive_tile(ctx, entry(g, 3)) }, { nil, "no_items" })
      S.eq({ B.revive_tile(ctx, entry(F.tile_ghost("stone-path", { x = 5, y = 0 }, { quality = "rare" }))) }, { nil, "quality" })
      -- призрак не оживился — предмет вернулся
      F.tile_revive_fails = true
      S.eq({ B.revive_tile(ctx, entry(g)) }, { nil, "blocked" })
      S.eq(C.counts(W.main), { ["stone-brick"] = 2 })
      S.ok(g.valid)
      F.tile_revive_fails = false
      -- предмет не списался — плитки нет
      F.remove_fails = true
      S.eq({ B.revive_tile(ctx, entry(g)) }, { nil, "no_items" })
      S.eq(F.tile_at(4, 0), "grass-1")
      F.remove_fails = false
      S.eq(B.revive_tile(ctx, entry(g)), true)
      S.eq({ g.valid, F.tile_at(4, 0) }, { false, "stone-path" })
      S.eq(C.counts(W.main), { ["stone-brick"] = 1 })
      S.eq({ B.revive_tile(ctx, entry(g)) }, { nil, "gone" })
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
  { "раскладка: постройки разного размера — как поставил движок 2.0.77 (сценарий build_2x2)", function()
      F.setup()
      local A = require("scripts.actions.build_blueprint")
      -- у настоящей печи коробка столкновений ±0.7 при размере 2×2: рамка считается по клеткам
      prototypes.entity["stone-furnace"].collision_box = { left_top = { x = -0.7, y = -0.7 }, right_bottom = { x = 0.7, y = 0.7 } }
      prototypes.entity["iron-chest"].collision_box = { left_top = { x = -0.35, y = -0.35 }, right_bottom = { x = 0.35, y = 0.35 } }
      local ents = {
        { name = "stone-furnace", position = { x = 0, y = 0 } },
        { name = "iron-chest", position = { x = 1.5, y = -0.5 } },
      }
      local anchor = { x = -49, y = 29 }
      local want = {
        [0] = { { x = -49, y = 29 }, { x = -47.5, y = 28.5 } },
        [4] = { { x = -49, y = 29 }, { x = -48.5, y = 30.5 } },
        [8] = { { x = -48, y = 29 }, { x = -49.5, y = 29.5 } },
        [12] = { { x = -49, y = 30 }, { x = -49.5, y = 28.5 } },
      }
      for dir, w in pairs(want) do
        local plan = A.layout(ents, anchor, dir)
        S.eq({ plan[1].pos, plan[2].pos }, w, "поворот " .. dir)
      end
  end },
  { "раскладка чертежа с плитками: рамка охватывает плитки, плитка — центр клетки, поворот", function()
      F.setup()
      local A = require("scripts.actions.build_blueprint")
      local ents = { { name = "iron-chest", position = { x = 0.5, y = 0.5 } } }
      local tiles = {
        { name = "stone-path", position = { x = -1, y = 0 } },
        { name = "stone-path", position = { x = 0, y = 0 } },
        { name = "stone-path", position = { x = 1, y = 0 } },
      }
      -- рамка: x −1..2, y 0..1 → центр (0.5, 0.5)
      local plan, tplan = A.layout(ents, { x = 10.5, y = 20.5 }, 0, tiles)
      S.eq(plan[1].pos, { x = 10.5, y = 20.5 })
      S.eq({ tplan[1].pos, tplan[2].pos, tplan[3].pos },
        { { x = 9.5, y = 20.5 }, { x = 10.5, y = 20.5 }, { x = 11.5, y = 20.5 } })
      S.eq(tplan[1].name, "stone-path")
      local _, r = A.layout(ents, { x = 10.5, y = 20.5 }, 4, tiles)
      S.eq({ r[1].pos, r[3].pos }, { { x = 10.5, y = 19.5 }, { x = 10.5, y = 21.5 } })
      -- только плитки: привязка по первой плитке
      local none, only = A.layout({}, { x = 3, y = 3 }, 0, { { name = "stone-path", position = { x = 0, y = 0 } },
        { name = "stone-path", position = { x = 1, y = 0 } } })
      S.eq(none, {})
      S.eq({ only[1].pos, only[2].pos }, { { x = 2.5, y = 3.5 }, { x = 3.5, y = 3.5 } })
  end },
  { "layout с зеркалом: места отражаются по x, направления восток ↔ запад, плитки — по клеткам", function()
      F.setup()
      local A = require("scripts.actions.build_blueprint")
      S.eq({ A.mirror_dir(0), A.mirror_dir(4), A.mirror_dir(8), A.mirror_dir(12), A.mirror_dir(2), A.mirror_dir(nil) },
        { 0, 12, 8, 4, 14, 0 })
      local ents = {
        { name = "iron-chest", position = { x = 0.5, y = 0.5 } },
        { name = "transport-belt", position = { x = 2.5, y = 0.5 }, direction = 4 },
      }
      local tiles = { { name = "stone-path", position = { x = 2, y = 1 } } }
      -- рамка x 0..3, y 0..2 → центр (1.5, 1); зеркало: x −3..0 → центр (−1.5, 1)
      local plan, tplan = A.layout(ents, { x = 10.5, y = 20 }, 0, tiles)
      S.eq({ plan[1].pos, plan[2].pos, plan[2].dir, tplan[1].pos },
        { { x = 9.5, y = 19.5 }, { x = 11.5, y = 19.5 }, 4, { x = 11.5, y = 20.5 } })
      local m, mt = A.layout(ents, { x = 10.5, y = 20 }, 0, tiles, true)
      S.eq({ m[1].pos, m[2].pos, m[2].dir, mt[1].pos },
        { { x = 11.5, y = 19.5 }, { x = 9.5, y = 19.5 }, 12, { x = 9.5, y = 20.5 } })
      -- зеркало и поворот: сначала отражение, потом поворот
      local r = A.layout(ents, { x = 10, y = 20.5 }, 4, nil, true)
      S.eq({ r[2].dir, r[1].dir }, { 0, 4 })
      S.eq(ents[2].position, { x = 2.5, y = 0.5 }, "исходный чертёж не тронут")
      -- кольца поиска: 8r клеток, ближние первыми, без повторов
      S.eq(A.ring(0), { { dx = 0, dy = 0 } })
      local ring = A.ring(3)
      S.eq(#ring, 24)
      S.eq(ring[1], { dx = 0, dy = -3 })
      local seen = {}
      for _, c in ipairs(ring) do
        S.eq(math.max(math.abs(c.dx), math.abs(c.dy)), 3)
        S.eq(seen[c.dx .. "," .. c.dy], nil)
        seen[c.dx .. "," .. c.dy] = true
      end
  end },
  { "свойства плиток из игры: маски, подложка (default_cover_tile), доступность подложки", function()
      local W = F.setup()
      local B = lib()
      local T = prototypes.tile
      S.eq(B.masks_collide({ layers = { a = true } }, { layers = { a = true, b = true } }), true)
      S.eq(B.masks_collide({ layers = { a = true } }, { layers = { b = true } }), false)
      S.eq(B.masks_collide({ a = true }, { layers = { a = true } }), true, "маска и её layers — одно и то же")
      S.eq(B.masks_collide({ layers = { a = false } }, { layers = { a = true } }), false)
      S.eq(B.masks_collide(nil, { layers = { a = true } }), false)
      F.set_tile(5, 5, "water")
      S.eq(B.tile_proto_at(S.nauvis, 5.7, 5.2), T["water"])
      S.eq(B.tile_proto_at(S.nauvis, -0.5, 0).name, "grass-1")
      S.eq(B.cover_tile(T["water"]), T["landfill"])
      S.eq(B.cover_tile(T["lava"]), nil, "у лавы подложки нет")
      S.eq(B.cover_tile(nil), nil)
      T["by-name"] = { name = "by-name", default_cover_tile = "landfill" }
      S.eq(B.cover_tile(T["by-name"]), T["landfill"])
      T["sealed"] = { name = "sealed", default_cover_tile = T["landfill"], allows_being_covered = false }
      S.eq(B.cover_tile(T["sealed"]), nil)
      T["ghost-cover"] = { name = "ghost-cover", default_cover_tile = "no-such-tile" }
      S.eq(B.cover_tile(T["ghost-cover"]), nil)
      -- доступность: рецепт открыт │ предмет у помощника │ предмет на складах силы
      local recipes = game.forces.player.recipes
      S.eq(B.cover_available(W.h, T["landfill"]), true)
      recipes["landfill"].enabled = false
      S.eq(B.cover_available(W.h, T["landfill"]), false)
      W.main.insert{ name = "landfill", count = 1 }
      S.eq(B.cover_available(W.h, T["landfill"]), true)
      W.main.remove{ name = "landfill", count = 1 }
      game.forces.player.logistic_networks = { nauvis = { { valid = true, get_item_count = function() return 3 end } },
        vulcanus = { { valid = true, get_item_count = function() error("другая поверхность не опрашивается") end } } }
      S.eq(B.cover_available(W.h, T["landfill"]), true)
      game.forces.player.logistic_networks = { nauvis = { { valid = false } } }
      S.eq(B.cover_available(W.h, T["landfill"]), false)
      game.forces.player.logistic_networks = nil
      -- рецепт с другим именем, который даёт предмет
      prototypes.get_recipe_filtered = function(f)
        S.eq(f[1].filter, "has-product-item")
        S.eq(f[1].elem_filters[1].name, "landfill")
        return { ["landfill-from-slag"] = {} }
      end
      recipes["landfill-from-slag"] = { name = "landfill-from-slag", enabled = false }
      S.eq(B.cover_available(W.h, T["landfill"]), false)
      recipes["landfill-from-slag"].enabled = true
      S.eq(B.cover_available(W.h, T["landfill"]), true)
      -- кэш одной оценки: второй раз не считается
      local cache = {}
      S.eq(B.cover_available(W.h, T["landfill"], cache), true)
      recipes["landfill-from-slag"].enabled = false
      S.eq(B.cover_available(W.h, T["landfill"], cache), true)
      S.eq(cache, { landfill = true })
      prototypes.get_recipe_filtered = nil
      -- плитка без предмета — недоступна
      S.eq(B.cover_available(W.h, T["grass-1"]), false)
      -- под постройкой
      local chest, furnace = prototypes.entity["iron-chest"], prototypes.entity["stone-furnace"]
      S.eq({ B.liquid_under(S.nauvis, chest, { x = 5.5, y = 5.5 }, 0) }, { true, "water" })
      S.eq({ B.liquid_under(S.nauvis, chest, { x = 6.5, y = 5.5 }, 0) }, { false })
      S.eq({ B.liquid_under(S.nauvis, furnace, { x = 5, y = 5 }, 0) }, { true, "water" }, "2×2 задевает клетку")
  end },
  { "marked_raw и unmark: свои и нейтральные пометки, снимаются только стоящие и ещё помеченные", function()
      local W = F.setup()
      local B = lib()
      local area = { left_top = { x = 10, y = -5 }, right_bottom = { x = 30, y = 5 } }
      local tree = F.mark(S.nauvis.create_entity{ name = "tree-01", position = { x = 20.5, y = 0.5 }, force = "neutral" })
      local rock = F.mark(S.nauvis.create_entity{ name = "bedrock", position = { x = 22.5, y = 0.5 }, force = "player" })
      local enemy = F.mark(C.chest({ x = 24.5, y = 0.5 }, {}, { force = "enemy" }))
      local plain = C.chest({ x = 26.5, y = 0.5 }, {})
      local far = F.mark(S.nauvis.create_entity{ name = "tree-01", position = { x = 60.5, y = 0.5 }, force = "neutral" })
      local raw = B.marked_raw(W.h, area)
      S.eq(#raw, 2, "некопаемое своё — тоже пометка; чужая сила и далёкое — нет")
      S.eq(B.mark_key(tree), B.ghost_key("tree-01", { x = 20.5, y = 0.5 }))
      S.eq(#B.marked(W.h, area), 1, "а разобрать руками можно только дерево")
      tree.destroy()
      local list = { tree, rock, plain, enemy }
      S.eq(B.unmark(list, "player"), 2, "дерева уже нет, сундук не помечен")
      S.eq({ rawget(rock, "_marked"), rawget(enemy, "_marked"), rawget(far, "_marked") }, { false, false, true })
      S.eq(B.unmark(list, "player"), 0, "повторно снимать нечего")
      S.eq(B.unmark(nil, "player"), 0)
      S.eq(B.unmark({ far }, "no-such-force"), 0)
      S.eq(rawget(far, "_marked"), true)
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
