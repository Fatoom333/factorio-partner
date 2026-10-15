-- scripts/lib/inventory.lua: перенос без потерь/дублей, предметы с данными, качество.
local S = require("stubs")
local C = require("stubs_c")

S.suite("hands_inventory", {
  { "has_data: простые количеством, броня/чертёж/порча/неизвестное — стаком", function()
      C.setup()
      local inv = require("scripts.lib.inventory")
      S.eq(inv.has_data("iron-plate"), false)
      S.eq(inv.has_data("power-armor-mk2"), true)
      S.eq(inv.has_data("blueprint"), true)
      S.eq(inv.has_data("car"), true)
      S.eq(inv.has_data("yumako"), true)
      S.eq(inv.has_data("no-such-item"), true)
  end },
  { "move: не влезло — остаток вернулся источнику", function()
      C.setup()
      local inv = require("scripts.lib.inventory")
      local src = C.inventory{ size = 4, items = { coal = 100 } }
      local dst = C.inventory{ size = 1, items = { coal = 20 } }
      local n = inv.move(src, { inv = dst }, "coal", 60, nil)
      S.eq(n, 30)
      S.eq({ C.counts(src), C.counts(dst) }, { { coal = 70 }, { coal = 50 } })
  end },
  { "move: источник не принял остаток — высыпается у помощника, ничего не пропадает", function()
      local W = C.setup()
      local inv = require("scripts.lib.inventory")
      local spilled = {}
      local real = getmetatable(S.nauvis).__index
      rawset(S.nauvis, "spill_item_stack", function(p) spilled[#spilled + 1] = p.stack return {} end)
      local src = C.inventory{ size = 1, items = { coal = 50 } }
      local dst = C.inventory{ size = 1, items = { coal = 40 } }
      -- источник «закрывается» после remove: insert обратно не принимает
      local orig_remove = src.remove
      rawset(src, "remove", function(st)
        local r = orig_remove(st)
        src.insert{ name = "stone", count = 50 }
        return r
      end)
      local n = inv.move(src, { inv = dst }, "coal", 50, W.h)
      S.eq(n, 10)
      S.eq(spilled, { { name = "coal", count = 40, quality = "normal" } })
      S.ok(real ~= nil)
  end },
  { "counts/move: не normal не видно и не трогается", function()
      C.setup()
      local inv = require("scripts.lib.inventory")
      local src = C.inventory{ size = 4, items = { { name = "coal", count = 5, quality = "rare" }, { name = "coal", count = 3 } } }
      S.eq(inv.counts(src), { coal = 3 })
      local dst = C.inventory{ size = 4 }
      S.eq((inv.move(src, { inv = dst }, "coal", 10, nil)), 3)
      S.eq(C.counts(src), { ["coal@rare"] = 5 })
  end },
})
