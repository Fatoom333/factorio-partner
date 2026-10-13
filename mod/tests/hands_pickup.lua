-- Действие pickup (поток C): труп и предметы на земле; только normal, своя сила/neutral, видимые.
local S = require("stubs")
local C = require("stubs_c")

local function pickup(args) return S.okr(C.act("pickup", args)).job end

local function corpse(pos, items)
  local e = S.nauvis.create_entity{ name = "character-corpse", position = pos, force = "player" }
  e.inventories = { [defines.inventory.character_corpse] = C.inventory{ size = 20, items = items } }
  return e
end

S.suite("hands_pickup", {
  { "area: подбирает предметы на земле, подходя на item_pickup_distance", function()
      local W = C.setup()
      local g1 = C.ground({ x = 8.5, y = 0.5 }, "iron-plate", 7)
      local g2 = C.ground({ x = 9.5, y = 2.5 }, "coal", 3)
      local g3 = C.ground({ x = 9.5, y = 2.5 }, "blueprint", 1, { data = "bp-string" })
      local d, kind = C.wait(pickup{ area = { left_top = { x = 5, y = -5 }, right_bottom = { x = 15, y = 5 } } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { picked = { ["iron-plate"] = 7, coal = 3, blueprint = 1 } })
      S.eq({ g1.valid, g2.valid, g3.valid }, { false, false, false })
      local bp
      for i = 1, #W.main do if W.main[i].valid_for_read and W.main[i].name == "blueprint" then bp = W.main[i].data end end
      S.eq(bp, "bp-string", "чертёж перенесён стаком")
      for _, c in ipairs(W.path.calls) do S.ok(c.dist <= W.h.item_pickup_distance, "подход на item_pickup_distance") end
  end },
  { "area: не normal и чужая сила не трогаются; невидимое — not_visible; пусто — not_found", function()
      local W = C.setup()
      local q = C.ground({ x = 8.5, y = 0.5 }, "iron-plate", 7, { quality = "rare" })
      local en = C.ground({ x = 9.5, y = 0.5 }, "coal", 7, { force = "enemy" })
      local d = C.wait(pickup{ area = { left_top = { x = 5, y = -5 }, right_bottom = { x = 15, y = 5 } } })
      S.eq(d.code, "not_found")
      S.eq({ q.valid, en.valid }, { true, true })
      local far = C.ground({ x = 40.5, y = 0.5 }, "coal", 1)
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      local d2 = C.wait(pickup{ area = { left_top = { x = 35, y = -5 }, right_bottom = { x = 45, y = 5 } } })
      S.eq(d2.code, "not_visible")
      S.eq(far.valid, true)
      S.eq(C.counts(W.main), {})
      S.err(C.act("pickup", { area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 300, y = 1 } } }), "limit")
  end },
  { "area: чанк не виден, но предмет ≤ 32 клеток от тела помощника — виден (глаза помощника)", function()
      local W = C.setup()
      local near = C.ground({ x = 20.5, y = 0.5 }, "coal", 4)
      game.forces.player.invisible[S.chunk_key(S.nauvis, { x = 0, y = 0 })] = true
      local d, kind = C.wait(pickup{ area = { left_top = { x = 15, y = -5 }, right_bottom = { x = 25, y = 5 } } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { picked = { coal = 4 } })
      S.eq(near.valid, false)
  end },
  { "труп: забирает всё, броня с данными — стаком", function()
      local W = C.setup()
      local c = corpse({ x = 20.5, y = 0.5 }, { { name = "power-armor-mk2", count = 1, data = "grid-X" }, { name = "coal", count = 30 } })
      local d, kind = C.wait(pickup{ target = { unit_number = c.unit_number } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { picked = { ["power-armor-mk2"] = 1, coal = 30 } })
      S.ok(c.get_inventory(defines.inventory.character_corpse).is_empty())
      S.eq(C.data_destroyed, 0)
      S.ok(W.h.can_reach_entity(c))
  end },
  { "аргументы: ровно одно; цель не труп — bad_args", function()
      C.setup()
      local ch = C.chest({ x = 3.5, y = 0.5 }, { coal = 1 })
      S.eq(C.wait(pickup{}).code, "bad_args")
      S.eq(C.wait(pickup{ target = { unit_number = ch.unit_number } }).code, "bad_args")
      S.eq(C.wait(pickup{ target = { unit_number = ch.unit_number }, area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 1, y = 1 } } }).code, "bad_args")
  end },
  { "полный инвентарь: труп — часть взята, no_space, left и inventory_full", function()
      local W = C.setup{ size = 1, items = { coal = 40 } }
      local c = corpse({ x = 3.5, y = 0.5 }, { coal = 30, stone = 5 })
      local d, kind = C.wait(pickup{ target = { unit_number = c.unit_number } })
      S.eq(kind, "job_failed")
      S.eq(d.code, "no_space")
      S.eq(d.detail, { picked = { coal = 10 }, left = { coal = 20, stone = 5 }, reason = "inventory_full" })
      S.eq(#C.events("inventory_full"), 1)
      S.eq(C.counts(c.get_inventory(defines.inventory.character_corpse)), { coal = 20, stone = 5 })
      S.eq(C.counts(W.main), { coal = 50 })
  end },
  { "полный инвентарь: на земле — no_space, предмет остался", function()
      local W = C.setup{ size = 1, items = { stone = 50 } }
      local g = C.ground({ x = 3.5, y = 0.5 }, "coal", 5)
      local d = C.wait(pickup{ area = { left_top = { x = 0, y = -2 }, right_bottom = { x = 6, y = 2 } } })
      S.eq({ d.code, d.detail.reason }, { "no_space", "inventory_full" })
      S.eq(g.valid, true)
      S.eq(g.stack.count, 5)
      S.eq(C.counts(W.main), { stone = 50 })
  end },
})
