-- Действие collect: склады своей силы в радиусе (видимые), резервы, missing, from.
local S = require("stubs")
local C = require("stubs_c")

local function collect(args) return S.okr(C.act("collect", args)).job end
local function chest_inv(ch) return ch.get_inventory(defines.inventory.chest) end

S.suite("hands_collect", {
  { "собирает с нескольких складов, ближний первым; резерв на время задачи снят в конце", function()
      local W = C.setup()
      local a = C.chest({ x = 10.5, y = 0.5 }, { ["iron-plate"] = 30, coal = 4 })
      local b = C.chest({ x = -30.5, y = 0.5 }, { ["iron-plate"] = 50 })
      local job = collect{ items = { ["iron-plate"] = 60 } }
      C.run(3)
      S.eq(storage.reservations.items.h1, { ["iron-plate"] = 60 }, "резерв за собой на время задачи")
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { collected = { ["iron-plate"] = 60 }, missing = {}, from = { a.unit_number, b.unit_number } })
      S.eq(C.counts(W.main), { ["iron-plate"] = 60 })
      S.eq(C.counts(chest_inv(a)), { coal = 4 })
      S.eq(C.counts(chest_inv(b)), { ["iron-plate"] = 20 })
      S.eq(storage.reservations.items.h1, nil, "резерв снят")
  end },
  { "не хватает — missing; ничего нет — no_items", function()
      C.setup()
      C.chest({ x = 5.5, y = 0.5 }, { ["iron-plate"] = 30 })
      local d = C.wait(collect{ items = { ["iron-plate"] = 100, coal = 3 } })
      S.eq(d.detail, { collected = { ["iron-plate"] = 30 }, missing = { ["iron-plate"] = 70, coal = 3 }, from = { d.detail.from[1] } })
      local d2 = C.wait(collect{ items = { coal = 3 } })
      S.eq({ d2.code, d2.detail.missing }, { "no_items", { coal = 3 } })
  end },
  { "только видимые склады своей силы в радиусе; center/near", function()
      local W = C.setup()
      C.chest({ x = 5.5, y = 0.5 }, { coal = 10 }, { force = "enemy" })
      local hidden = C.chest({ x = 40.5, y = 0.5 }, { coal = 10 })
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      C.chest({ x = 100.5, y = 0.5 }, { coal = 10 })
      local d = C.wait(collect{ items = { coal = 5 } })
      S.eq(d.code, "no_items", S.dump(d))
      local d2 = C.wait(collect{ items = { coal = 5 }, center = { x = 100, y = 0 }, radius = 5 })
      S.eq(d2.detail.collected, { coal = 5 })
      S.eq(C.counts(chest_inv(hidden)), { coal = 10 })
      -- near = player: хозяин в (0,0)
      local near = C.chest({ x = -3.5, y = 0.5 }, { stone = 2 })
      S.move(W.h, { x = 60, y = 0 })
      local d3 = C.wait(collect{ items = { stone = 2 }, near = "player", radius = 10 })
      S.eq(d3.detail.from, { near.unit_number })
  end },
  { "чужой резерв учитывается", function()
      C.setup()
      C.chest({ x = 5.5, y = 0.5 }, { ["iron-plate"] = 50 })
      storage.reservations.items.h2 = { ["iron-plate"] = 45 }
      local d = C.wait(collect{ items = { ["iron-plate"] = 20 } })
      S.eq({ d.detail.collected, d.detail.missing }, { { ["iron-plate"] = 5 }, { ["iron-plate"] = 15 } })
  end },
  { "аргументы: radius > 128 — limit, лишнее — bad_args, near только player", function()
      C.setup()
      S.err(C.act("collect", { items = { coal = 1 }, radius = 200 }), "limit")
      S.err(C.act("collect", { items = { coal = 1 }, near = "base" }), "bad_args")
      S.err(C.act("collect", { items = { coal = 1 }, radius = 0 }), "bad_args")
      S.err(C.act("collect", {}), "bad_args")
      S.eq(C.wait(collect{ items = { coal = 1 }, center = { x = 1, y = 1 }, near = "player" }).code, "bad_args")
  end },
  { "отмена по пути: резерв снят, ничего не взято", function()
      local W = C.setup()
      local a = C.chest({ x = 60.5, y = 0.5 }, { coal = 10 })
      local job = collect{ items = { coal = 10 } }
      C.run(10)
      S.ok(storage.reservations.items.h1 ~= nil)
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(storage.reservations.items.h1, nil)
      S.eq(C.counts(chest_inv(a)), { coal = 10 })
      S.eq(C.counts(W.main), {})
  end },
  { "склад в невидимом чанке, но ≤ 32 клеток от тела помощника — виден (без игроков онлайн)", function()
      local W = C.setup()
      local ch = C.chest({ x = 20.5, y = 0.5 }, { coal = 12 })
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 0, y = 0 })] = true
      local d, kind = C.wait(collect{ items = { coal = 5 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.collected, { coal = 5 })
      S.eq(C.counts(chest_inv(ch)), { coal = 7 })
  end },
  { "остался только неделимый стак — no_items, reason=whole_stacks_only", function()
      local W = C.setup()
      C.chest({ x = 5.5, y = 0.5 }, { { name = "yumako", count = 50, data = "spoil-A" } })
      local d = C.wait(collect{ items = { yumako = 10 } })
      S.eq({ d.code, d.detail.reason }, { "no_items", "whole_stacks_only" }, S.dump(d))
      S.eq(C.counts(W.main), {})
  end },
  { "полный инвентарь: inventory_full и no_space, в detail — что успел", function()
      local W = C.setup{ size = 1, items = { coal = 40 } }
      C.chest({ x = 5.5, y = 0.5 }, { coal = 30 })
      local d, kind = C.wait(collect{ items = { coal = 30 } })
      S.eq(kind, "job_failed")
      S.eq({ d.code, d.detail.reason }, { "no_space", "inventory_full" })
      S.eq(d.detail.collected, { coal = 10 })
      S.eq(d.detail.missing, { coal = 20 })
      S.eq(#C.events("inventory_full"), 1)
      S.eq(C.counts(W.main), { coal = 50 })
  end },
})
