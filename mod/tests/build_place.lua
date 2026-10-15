-- Действие place: ACTIONS.md, PROTOCOL §6.5 (can_place_entity → create_entity{raise_built,
-- quality normal} → remove_item, откат), подход на build_distance.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

local POS = { x = 20.5, y = 0.5 }

S.suite("build_place", {
  { "ставит сундук из инвентаря: подход, проверка тела, create_entity{raise_built, normal}, списание", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      local d, kind = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq(kind, "job_done", S.dump(d))
      local built = F.built("iron-chest", POS)
      S.eq(#built, 1)
      S.eq(d.detail, { unit_number = built[1].unit_number, name = "iron-chest", pos = POS })
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 }, "списан ровно один предмет")
      S.ok(#W.path.calls > 0, "подходил через ctx.approach")
      S.ok(S.dist(W.h.position, POS) <= W.h.build_distance, "встал в пределах build_distance")
      local p = F.script_built("iron-chest")[1]
      S.eq({ p.raise_built, p.quality, p.direction }, { true, "normal", 0 })
      S.eq(p.force, W.h.force)
      -- проверка постановки — LuaControl.can_place_entity тела, уже рядом с местом
      local manual = {}
      for _, c in ipairs(F.checks) do if c.kind == "manual" then manual[#manual + 1] = c end end
      S.eq(#manual, 1)
      S.eq(manual[1].far, nil)
      S.ok(F.vis.calls > 0, "обзор — через scripts.core.vis")
      S.eq(F.vis.last.helper, "h1")
      S.eq(W.h.walking_state.walking, false)
  end },
  { "direction передаётся постройке", function()
      F.setup{ items = { ["transport-belt"] = 1 } }
      local d, kind = F.wait(F.job("place", { item = "transport-belt", pos = { x = 6.5, y = 3.5 }, direction = 4 }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(F.built("transport-belt")[1].direction, 4)
  end },
  { "аргументы: неизвестный предмет, не постройка, предмет с данными, схема", function()
      F.setup{ items = { ["iron-plate"] = 5, ["iron-chest"] = 1, car = 1 } }
      local cases = {
        { item = "nope", pos = POS },
        { item = "iron-plate", pos = POS },
        { item = "car", pos = POS },
      }
      for i, a in ipairs(cases) do
        local d, kind = F.wait(F.job("place", a))
        S.eq({ kind, d.code }, { "job_failed", "bad_args" }, "случай " .. i .. " " .. S.dump(d))
      end
      S.err(C.act("place", { item = "iron-chest" }), "bad_args")
      S.err(C.act("place", { pos = POS }), "bad_args")
      S.err(C.act("place", { item = "iron-chest", pos = POS, direction = -1 }), "bad_args")
      S.err(C.act("place", { item = "iron-chest", pos = POS, direction = 16 }), "limit")
      S.err(C.act("place", { item = "iron-chest", pos = POS, direction = 1.5 }), "bad_args")
      S.err(C.act("place", { item = "iron-chest", pos = POS, extra = 1 }), "bad_args")
      S.eq(#F.script_built(), 0)
  end },
  { "нет предмета — no_items сразу, без ходьбы", function()
      local W = F.setup{ items = { ["iron-plate"] = 5 } }
      local d, kind = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(#W.path.calls, 0)
      S.eq(#F.built("iron-chest"), 0)
  end },
  { "место занято — cannot_place, предмет остался", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      F.blocked[F.key(POS)] = true
      local d, kind = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq({ kind, d.code }, { "job_failed", "cannot_place" })
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      S.eq(#F.built("iron-chest"), 0)
      S.eq(#F.script_built(), 0, "create_entity не вызывался")
  end },
  { "create_entity вернул nil — cannot_place, предмет остался", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      F.create_nil = true
      local d = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq(d.code, "cannot_place")
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
  { "откат: предмет не списался — постройка убрана, no_items", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      F.remove_fails = true
      local destroyed = 0
      script.on_event(defines.events.script_raised_destroy, function() destroyed = destroyed + 1 end)
      local d, kind = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(#F.built("iron-chest"), 0, "постройки из воздуха нет")
      S.eq(#F.script_built("iron-chest"), 1)
      S.eq(destroyed, 1, "убрана с raise_destroy")
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
  { "мешает само тело — отходит в сторону и ставит", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      local here = { x = math.floor(W.h.position.x) + 0.5, y = math.floor(W.h.position.y) + 0.5 }
      S.move(W.h, here)
      local d, kind = F.wait(F.job("place", { item = "iron-chest", pos = here }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(#F.built("iron-chest", here), 1)
      S.ok(S.dist(W.h.position, here) > 1, "тело ушло с места постройки")
      S.ok(S.dist(W.h.position, here) <= W.h.build_distance)
  end },
  { "неоткрытый чанк — not_charted; вне обзора — not_visible", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      local d = F.wait(F.job("place", { item = "iron-chest", pos = { x = 100.5, y = 0.5 } }))
      S.eq(d.code, "not_charted")
      S.eq(#W.path.calls, 0)
      F.vis.result = false
      local d2 = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq(d2.code, "not_visible")
      S.eq(#F.built("iron-chest"), 0)
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
  { "recipe: сборщику ставится рецепт; плохой рецепт и не-сборщик — bad_args", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      W.main.insert{ name = "assembling-machine-1", count = 2 }
      local d, kind = F.wait(F.job("place", { item = "assembling-machine-1", pos = { x = 12.5, y = 5.5 }, recipe = "iron-gear-wheel" }))
      S.eq(kind, "job_done", S.dump(d))
      local e = F.built("assembling-machine-1")[1]
      S.eq(e.recipe_set, { recipe = "iron-gear-wheel", quality = "normal" })
      S.eq(d.detail.recipe_set, nil)
      local bad = {
        { item = "assembling-machine-1", pos = POS, recipe = "nope" },
        { item = "assembling-machine-1", pos = POS, recipe = "electric-mining-drill" },  -- не изучен
        { item = "assembling-machine-1", pos = POS, recipe = "sulfuric-acid" },           -- не та категория
        { item = "iron-chest", pos = POS, recipe = "iron-gear-wheel" },
      }
      for i, a in ipairs(bad) do
        local r = F.wait(F.job("place", a))
        S.eq(r.code, "bad_args", "случай " .. i .. " " .. S.dump(r))
      end
      S.eq(C.counts(W.main), { ["assembling-machine-1"] = 1, ["iron-chest"] = 1 })
  end },
  { "область держит другой помощник — reserved", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      storage.reservations.areas.h2 = { left_top = { x = 15, y = -5 }, right_bottom = { x = 25, y = 5 } }
      local d = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq(d.code, "reserved")
      S.eq(#W.path.calls, 0)
  end },
  { "отмена в пути: подход снят, ничего не построено", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      local job = F.job("place", { item = "iron-chest", pos = { x = 60.5, y = 0.5 } })
      F.run(5)
      S.okr(S.req("cancel", { job = job }, "h1"))
      local d = C.result(job)
      S.eq(d.code, "cancelled")
      S.ok(W.path.cancels > 0)
      F.run(100)
      S.eq(#F.built("iron-chest"), 0)
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
  { "путь не найден — ошибка пути уходит как есть", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      W.path.fail = { status = "failed", code = "path_failed", text = "no path" }
      local d = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq(d.code, "path_failed")
      S.eq(#F.built("iron-chest"), 0)
  end },
  { "постройка стоит несколько предметов (count > 1): мало — no_items, хватает — списывается ровно столько", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      prototypes.entity["iron-chest"].items_to_place_this = { { name = "iron-chest", count = 2 } }
      local d, kind = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(#W.path.calls, 0, "без ходьбы")
      S.eq(#F.built("iron-chest"), 0)
      W.main.insert{ name = "iron-chest", count = 2 }
      local d2, k2 = F.wait(F.job("place", { item = "iron-chest", pos = POS }))
      S.eq(k2, "job_done", S.dump(d2))
      S.eq(#F.built("iron-chest"), 1)
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
})
