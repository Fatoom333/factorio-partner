-- Действие craft (поток C): только begin_crafting, опрос очереди, done по росту инвентаря.
local S = require("stubs")
local C = require("stubs_c")

local function craft(args) return S.okr(C.act("craft", args)).job end

S.suite("hands_craft", {
  { "крафт: begin_crafting, ингредиенты тратит «движок», done по приросту", function()
      local W = C.setup{ items = { ["iron-plate"] = 10 } }
      local job = craft{ recipe = "iron-gear-wheel", count = 3 }
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { crafted = { ["iron-gear-wheel"] = 3 } })
      S.eq(C.counts(W.main), { ["iron-plate"] = 4, ["iron-gear-wheel"] = 3 })
      S.eq(#W.path.calls, 0, "крафт без ходьбы")
      local began = 0
      for _, l in ipairs(C.log) do if l:find("^begin_crafting:iron%-gear%-wheel:3") then began = began + 1 end end
      S.eq(began, 1, "один begin_crafting на всю задачу")
      S.eq(W.h.crafting_queue_size, 0)
  end },
  { "не хватает ингредиентов — no_items с craftable, ничего не начато", function()
      local W = C.setup{ items = { ["iron-plate"] = 5 } }
      local d = C.wait(craft{ recipe = "iron-gear-wheel", count = 3 })
      S.eq({ d.code, d.detail }, { "no_items", { craftable = 2 } })
      S.eq(C.counts(W.main), { ["iron-plate"] = 5 })
      S.eq(W.h.crafting_queue_size, 0)
  end },
  { "рецепт: неизвестный, не ручной, не изучен — bad_args", function()
      C.setup{ items = { ["iron-plate"] = 50 } }
      for _, r in ipairs({ "nope", "sulfuric-acid", "electric-mining-drill", "hand-hidden" }) do
        S.eq(C.wait(craft{ recipe = r, count = 1 }).code, "bad_args", r)
      end
      S.err(C.act("craft", { recipe = "iron-gear-wheel", count = 0 }), "bad_args")
      S.err(C.act("craft", { count = 1 }), "bad_args")
  end },
  { "рецепт как в API 2.0: hidden_from_player_crafting и main_product — с прототипа", function()
      local W = C.setup{ items = { ["iron-plate"] = 10 } }
      local r = game.forces.player.recipes["iron-gear-wheel"]
      S.ok(not pcall(function() return r.hidden_from_player_crafting end), "у LuaRecipe этого ключа нет")
      S.ok(not pcall(function() return r.main_product end), "у LuaRecipe этого ключа нет")
      local d, kind = C.wait(craft{ recipe = "gear-and-stone", count = 2 })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { crafted = { ["iron-gear-wheel"] = 2 } }, "считается основной продукт, а не первый")
      S.eq(C.counts(W.main), { ["iron-plate"] = 6, ["iron-gear-wheel"] = 2, stone = 2 })
  end },
  { "отмена: свой крафт снят, ингредиенты вернул движок, без дублей", function()
      local W = C.setup{ items = { ["iron-plate"] = 20 } }
      local job = craft{ recipe = "iron-gear-wheel", count = 10 }
      C.run(65)
      local gears = W.main.get_item_count("iron-gear-wheel")
      S.ok(gears >= 1 and gears < 10, "часть сделана: " .. gears)
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(W.h.crafting_queue_size, 0, "очередь пуста")
      S.eq(C.result(job).code, "cancelled")
      local c = C.counts(W.main)
      S.eq(c["iron-plate"] + 2 * (c["iron-gear-wheel"] or 0), 20, "железо сохранилось: " .. S.dump(c))
  end },
  { "крафт стоит при полном инвентаре — inventory_full, stuck", function()
      local W = C.setup{ size = 2, items = { { name = "stone", count = 50 }, { name = "iron-plate", count = 50 } } }
      local job = craft{ recipe = "iron-gear-wheel", count = 1 }
      local d = C.wait(job, 3000)
      S.eq({ d.code, d.detail.reason }, { "stuck", "inventory_full" })
      S.eq(#C.events("inventory_full"), 1)
      S.eq(W.h.crafting_queue_size, 0, "stop снял крафт")
      S.eq(C.counts(W.main), { stone = 50, ["iron-plate"] = 50 }, "ингредиенты вернулись")
  end },
  { "очередь задач: craft после mine — из выкопанного", function()
      local W = C.setup()
      C.resource("stone", { x = 4.5, y = 0.5 }, 100)
      S.okr(C.act("mine", { resource = "stone", count = 5 }))
      local job = craft{ recipe = "stone-furnace", count = 1 }
      local d, kind = C.wait(job, 4000)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(C.counts(W.main), { ["stone-furnace"] = 1 })
  end },
})
