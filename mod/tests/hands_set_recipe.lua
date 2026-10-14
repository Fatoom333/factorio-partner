-- Действие set_recipe: смена рецепта стоящей сборочной машины (как в окне машины).
local S = require("stubs")
local C = require("stubs_c")

local function job_of(d, args) return S.okr(C.act(d, args)).job end

local function machine(pos, recipe, back)
  local e = S.nauvis.create_entity{ name = "assembling-machine-1", position = pos, force = "player" }
  rawset(e, "cur", recipe)
  rawset(e, "get_recipe", function()
    if e.cur == nil then return nil, nil end
    return { name = e.cur }, "normal"
  end)
  rawset(e, "set_recipe", function(r, q)
    e.cur, e.set_quality = r, q
    return back or {}
  end)
  return e
end

S.suite("hands_set_recipe", {
  { "подходит и меняет рецепт, вернувшиеся ингредиенты — в инвентарь", function()
      local W = C.setup()
      local e = machine({ x = 30.5, y = 0.5 }, "pipe", { { name = "iron-plate", count = 7, quality = "normal" } })
      local d, kind = C.wait(job_of("set_recipe", { target = { unit_number = e.unit_number }, recipe = "iron-gear-wheel" }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.recipe, d.detail.was, e.cur }, { "iron-gear-wheel", "pipe", "iron-gear-wheel" })
      S.eq(d.detail.returned["iron-plate"], 7)
      S.ok(W.h.can_reach_entity(e), "менял только в досягаемости")
  end },
  { "без recipe — рецепт снят", function()
      C.setup()
      local e = machine({ x = 3.5, y = 0.5 }, "pipe")
      local d, kind = C.wait(job_of("set_recipe", { target = { unit_number = e.unit_number } }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ e.cur, d.detail.was }, { nil, "pipe" })
  end },
  { "уже стоит — done без вызова set_recipe", function()
      C.setup()
      local e = machine({ x = 3.5, y = 0.5 }, "pipe")
      rawset(e, "set_recipe", function() error("не должен вызываться") end)
      local d, kind = C.wait(job_of("set_recipe", { target = { unit_number = e.unit_number }, recipe = "pipe" }))
      S.eq(kind, "job_done", S.dump(d))
  end },
  { "закрытый, неизвестный рецепт и не сборочная машина — bad_args", function()
      C.setup()
      local e = machine({ x = 3.5, y = 0.5 }, "pipe")
      for _, r in ipairs({ "electric-mining-drill", "no-such" }) do
        local d, kind = C.wait(job_of("set_recipe", { target = { unit_number = e.unit_number }, recipe = r }))
        S.eq({ kind, d.code, e.cur }, { "job_failed", "bad_args", "pipe" })
      end
      local ch = C.chest({ x = 3.5, y = 3.5 }, {})
      local d, kind = C.wait(job_of("set_recipe", { target = { unit_number = ch.unit_number }, recipe = "pipe" }))
      S.eq({ kind, d.code }, { "job_failed", "bad_args" })
  end },
})
