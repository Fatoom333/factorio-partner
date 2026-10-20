-- Действия equip, armor_grid и insert{target:"armor"}: броня из карманов в слот (прежняя — в
-- инвентарь с модулями), модули из карманов в сетку надетой брони и обратно, без предметов из
-- воздуха; что не встало — not_placed с причиной; state показывает сетку.
local S = require("stubs")
local C = require("stubs_c")
local A = require("stubs_armor")

local function job_of(d, args) return S.okr(C.act(d, args)).job end

local PA = "power-armor-mk2"

S.suite("hands_armor", {
  { "equip: броня из инвентаря в слот, прежняя — в инвентарь со своей сеткой", function()
      local g_new, g_old = A.grid(4, 4), A.grid(2, 2)
      local W = A.setup{ items = { { name = PA, grid = g_new } }, armor = { { name = "modular-armor", grid = g_old } } }
      g_old.put{ name = "solar-panel-equipment" }
      local d, kind = C.wait(job_of("equip", { item = PA }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { equipped = PA, unequipped = "modular-armor",
        armor = { name = PA, grid = { w = 4, h = 4, used = 0, free = 16, equipment = {} } } })
      S.eq(W.armor[1].name, PA)
      S.ok(W.armor[1].grid == g_new, "сетка переехала вместе с бронёй")
      local old
      for i = 1, #W.main do if W.main[i].valid_for_read then old = W.main[i] end end
      S.eq(old.name, "modular-armor")
      S.ok(old.grid == g_old, "снятая броня — с прежней сеткой")
      S.eq(A.contents(g_old), { ["solar-panel-equipment"] = 1 })
  end },
  { "equip: не броня — bad_args, брони нет в карманах — no_items", function()
      local W = A.setup{ items = { { name = "coal", count = 5 } } }
      S.eq(C.wait(job_of("equip", { item = "coal" })).code, "bad_args")
      local d = C.wait(job_of("equip", { item = "light-armor" }))
      S.eq({ d.code, d.detail.missing }, { "no_items", { ["light-armor"] = 1 } })
      S.eq(W.armor[1].valid_for_read, false)
  end },
  { "insert{target:armor}: модули встают, не влезшее — left и not_placed с причиной", function()
      local g = A.grid(4, 4)
      local W = A.setup{
        items = { { name = "battery-equipment", count = 3 }, { name = "energy-shield-equipment", count = 2 },
                  { name = "exoskeleton-equipment", count = 1 }, { name = "coal", count = 1 } },
        armor = { { name = PA, grid = g } } }
      local d, kind = C.wait(job_of("insert", { target = "armor", items = {
        ["battery-equipment"] = 5, ["energy-shield-equipment"] = 2, ["exoskeleton-equipment"] = 1, coal = 1 } }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.inserted, { ["battery-equipment"] = 3, ["energy-shield-equipment"] = 2 })
      S.eq(d.detail.left, { ["battery-equipment"] = 2, coal = 1, ["exoskeleton-equipment"] = 1 })
      S.eq(d.detail.not_placed, {
        { item = "battery-equipment", count = 2, reason = "no_item" },
        { item = "coal", count = 1, reason = "not_equipment" },
        { item = "exoskeleton-equipment", count = 1, reason = "no_space" },
      })
      S.eq(d.detail.armor.grid, { w = 4, h = 4, used = 14, free = 2,
        equipment = { ["battery-equipment"] = 3, ["energy-shield-equipment"] = 2 } })
      S.eq(C.counts(W.main), { coal = 1, ["exoskeleton-equipment"] = 1 }, "ушло ровно поставленное")
      S.eq(A.contents(g), { ["battery-equipment"] = 3, ["energy-shield-equipment"] = 2 })
      for _, e in ipairs(g.equipment) do S.eq(e.energy, 0, "модуль приходит без заряда") end
  end },
  { "armor_grid put: без позиции не встало — перебор позиций", function()
      local g = A.grid(2, 2)
      local W = A.setup{ items = { { name = "solar-panel-equipment", count = 5 } }, armor = { { name = PA, grid = g } } }
      local d = C.wait(job_of("armor_grid", { put = { ["solar-panel-equipment"] = 5 } }))
      S.eq(d.detail.placed, { ["solar-panel-equipment"] = 4 })
      S.eq(d.detail.not_placed, { { item = "solar-panel-equipment", count = 1, reason = "no_space" } })
      S.eq(C.counts(W.main), { ["solar-panel-equipment"] = 1 })
      local by_pos = 0
      for _, l in ipairs(A.log) do if l:find("^put:solar%-panel%-equipment:") then by_pos = by_pos + 1 end end
      S.ok(by_pos > 0, "были попытки с позицией")
      S.eq(A.contents(g), { ["solar-panel-equipment"] = 4 })
  end },
  { "armor_grid take: модули обратно в карманы; чего нет в сетке — not_in_grid", function()
      local g = A.grid(4, 4)
      local W = A.setup{ items = { { name = "battery-equipment", count = 3 } }, armor = { { name = PA, grid = g } } }
      S.eq(C.wait(job_of("armor_grid", { put = { ["battery-equipment"] = 3 } })).detail.placed, { ["battery-equipment"] = 3 })
      local d, kind = C.wait(job_of("armor_grid", { take = { ["battery-equipment"] = 2, ["solar-panel-equipment"] = 1 } }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.taken, { ["battery-equipment"] = 2 })
      S.eq(d.detail.not_taken, { { item = "solar-panel-equipment", count = 1, reason = "not_in_grid" } })
      S.eq(C.counts(W.main), { ["battery-equipment"] = 2 })
      S.eq(A.contents(g), { ["battery-equipment"] = 1 })
      S.eq(d.detail.armor.grid.used, 2)
  end },
  { "take: инвентарь полон — no_space, модуль остаётся в сетке", function()
      local g = A.grid(4, 4)
      local W = A.setup{ size = 1, items = { { name = "battery-equipment", count = 1 } }, armor = { { name = PA, grid = g } } }
      C.wait(job_of("armor_grid", { put = { ["battery-equipment"] = 1 } }))
      W.main.insert{ name = "coal", count = 50 }
      local d = C.wait(job_of("armor_grid", { take = { ["battery-equipment"] = 1 } }))
      S.eq({ d.code, d.detail.reason }, { "no_space", "inventory_full" })
      S.eq(A.contents(g), { ["battery-equipment"] = 1 })
      S.eq(#C.events("inventory_full"), 1)
  end },
  { "нет брони — no_items{no_armor}; броня без сетки — bad_args{no_grid}; не модуль — bad_args", function()
      local W = A.setup{ items = { { name = "battery-equipment", count = 1 }, { name = "coal", count = 1 },
        { name = "light-armor" } } }
      local d = C.wait(job_of("armor_grid", { put = { ["battery-equipment"] = 1 } }))
      S.eq({ d.code, d.detail.reason }, { "no_items", "no_armor" })
      local d2 = C.wait(job_of("insert", { target = "armor", items = { ["battery-equipment"] = 1 } }))
      S.eq({ d2.code, d2.detail.reason, d2.detail.left }, { "no_items", "no_armor", { ["battery-equipment"] = 1 } })
      S.eq(C.wait(job_of("equip", { item = "light-armor" })).detail.equipped, "light-armor")
      local d3 = C.wait(job_of("armor_grid", { put = { ["battery-equipment"] = 1 } }))
      S.eq({ d3.code, d3.detail.reason }, { "bad_args", "no_grid" })
      S.eq(C.counts(W.main), { ["battery-equipment"] = 1, coal = 1 }, "ничего не потрачено")
  end },
  { "не модуль и чужая категория — отказ, предметы на месте", function()
      local g = A.grid(4, 4)
      local W = A.setup{ items = { { name = "coal", count = 2 }, { name = "spidertron-only-equipment", count = 1 } },
        armor = { { name = PA, grid = g } } }
      local d = C.wait(job_of("armor_grid", { put = { coal = 2 } }))
      S.eq({ d.code, d.detail.reason }, { "bad_args", "not_equipment" })
      local d2 = C.wait(job_of("armor_grid", { put = { ["spidertron-only-equipment"] = 1 } }))
      S.eq({ d2.code, d2.detail.reason }, { "bad_args", "wrong_category" })
      S.eq(C.counts(W.main), { coal = 2, ["spidertron-only-equipment"] = 1 })
      S.eq(A.contents(g), {})
  end },
  { "аргументы: armor_grid без put и take, insert с неверной строкой цели — bad_args", function()
      A.setup{ armor = { { name = PA, grid = A.grid(2, 2) } } }
      S.eq(C.wait(job_of("armor_grid", {})).code, "bad_args")
      local r = C.act("insert", { target = "chest", items = { coal = 1 } })
      S.eq(r.ok, false)
      S.eq(r.error.code, "bad_args")
  end },
  { "state: броня и сетка кратко", function()
      local g = A.grid(4, 4)
      A.setup{ items = { { name = "battery-equipment", count = 2 } }, armor = { { name = PA, grid = g } } }
      C.wait(job_of("armor_grid", { put = { ["battery-equipment"] = 2 } }))
      local st = S.okr(S.req("state", {}, "h1"))
      S.eq(st.armor, PA)
      S.eq(st.armor_grid, { w = 4, h = 4, used = 4, free = 12, equipment = { ["battery-equipment"] = 2 } })
  end },
})
