-- Действия insert / extract (поток C): подход на reach, без потерь и дублей, предметы с данными
-- только transfer_stack/swap_stack, чужой резерв, equip, inventory_full.
local S = require("stubs")
local C = require("stubs_c")

local function job_of(d, args) return S.okr(C.act(d, args)).job end

local function total(...)
  local acc = {}
  for _, inv in ipairs({ ... }) do
    for k, v in pairs(C.counts(inv)) do acc[k] = (acc[k] or 0) + v end
  end
  return acc
end

local function count_log(prefix)
  local n = 0
  for _, l in ipairs(C.log) do if l:sub(1, #prefix) == prefix then n = n + 1 end end
  return n
end

local function chest_inv(ch) return ch.get_inventory(defines.inventory.chest) end

S.suite("hands_transfer", {
  { "insert: подходит на reach, переносит, без потерь", function()
      local W = C.setup{ items = { ["iron-plate"] = 30 } }
      local ch = C.chest({ x = 30.5, y = 0.5 }, {})
      local d, kind = C.wait(job_of("insert", { target = { unit_number = ch.unit_number }, items = { ["iron-plate"] = 20 } }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { inserted = { ["iron-plate"] = 20 } })
      S.eq(C.counts(W.main), { ["iron-plate"] = 10 })
      S.eq(C.counts(chest_inv(ch)), { ["iron-plate"] = 20 })
      S.ok(#W.path.calls > 0)
      S.ok(W.h.can_reach_entity(ch), "переносил только в досягаемости")
      S.ok(W.path.calls[#W.path.calls].dist <= W.h.reach_distance)
  end },
  { "insert: target {name,pos}; нет у помощника — no_items с missing, ничего не тронуто", function()
      local W = C.setup{ items = { ["iron-plate"] = 5 } }
      local ch = C.chest({ x = 3.5, y = 0.5 }, {})
      local d = C.wait(job_of("insert", { target = { name = "iron-chest", pos = { x = 3.5, y = 0.5 } }, items = { ["iron-plate"] = 20, coal = 1 } }))
      S.eq({ d.code, d.detail }, { "no_items", { missing = { ["iron-plate"] = 15, coal = 1 } } })
      S.eq(C.counts(W.main), { ["iron-plate"] = 5 })
      S.err(C.act("insert", { target = { unit_number = ch.unit_number }, items = {} }), "bad_args")
      S.err(C.act("insert", { items = { coal = 1 } }), "bad_args")
      S.eq(C.wait(job_of("insert", { target = { unit_number = ch.unit_number }, items = { unobtainium = 1 } })).code, "bad_args")
  end },
  { "insert: цель полна — остаток у помощника (left), сумма сохраняется", function()
      local W = C.setup{ items = { ["iron-plate"] = 30 } }
      local ch = C.chest({ x = 3.5, y = 0.5 }, { { name = "stone", count = 40 }, { name = "iron-plate", count = 40 } }, { size = 2 })
      local d = C.wait(job_of("insert", { target = { unit_number = ch.unit_number }, items = { ["iron-plate"] = 30 } }))
      S.eq(d.detail, { inserted = { ["iron-plate"] = 10 }, left = { ["iron-plate"] = 20 } })
      S.eq(total(W.main, chest_inv(ch)), { ["iron-plate"] = 70, stone = 40 })
  end },
  { "insert: броня с данными — только transfer_stack, данные целы", function()
      local W = C.setup{ items = { { name = "power-armor-mk2", count = 1, data = "grid-1" }, { name = "coal", count = 5 } } }
      local ch = C.chest({ x = 3.5, y = 0.5 }, {})
      local d = C.wait(job_of("insert", { target = { unit_number = ch.unit_number }, items = { ["power-armor-mk2"] = 1, coal = 5 } }))
      S.eq(d.detail, { inserted = { ["power-armor-mk2"] = 1, coal = 5 } })
      local inv = chest_inv(ch)
      local found
      for i = 1, #inv do if inv[i].valid_for_read and inv[i].name == "power-armor-mk2" then found = inv[i].data end end
      S.eq(found, "grid-1", "сетка брони перенесена")
      S.eq(C.data_destroyed, 0, "remove_item не трогал предмет с данными")
      S.eq(count_log("transfer_stack:power-armor-mk2"), 1)
      S.eq(count_log("remove_item:power-armor-mk2"), 0)
  end },
  { "extract: берёт нужное в досягаемости, без потерь и дублей", function()
      local W = C.setup()
      local ch = C.chest({ x = -25.5, y = 4.5 }, { ["iron-plate"] = 100, coal = 5 }, { size = 4 })
      local d, kind = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, items = { ["iron-plate"] = 30 } }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { extracted = { ["iron-plate"] = 30 } })
      S.eq(C.counts(W.main), { ["iron-plate"] = 30 })
      S.eq(C.counts(chest_inv(ch)), { ["iron-plate"] = 70, coal = 5 })
      S.ok(W.h.can_reach_entity(ch))
  end },
  { "extract: без items — всё; больше, чем есть — missing", function()
      local W = C.setup()
      local ch = C.chest({ x = 3.5, y = 0.5 }, { ["iron-plate"] = 10, coal = 5 })
      local d = C.wait(job_of("extract", { target = { unit_number = ch.unit_number } }))
      S.eq(d.detail, { extracted = { ["iron-plate"] = 10, coal = 5 } })
      S.ok(chest_inv(ch).is_empty())
      local ch2 = C.chest({ x = 4.5, y = 2.5 }, { stone = 3 })
      local d2 = C.wait(job_of("extract", { target = { unit_number = ch2.unit_number }, items = { stone = 10, wood = 1 } }))
      S.eq(d2.detail, { extracted = { stone = 3 }, missing = { stone = 7, wood = 1 } })
      local d3 = C.wait(job_of("extract", { target = { unit_number = ch2.unit_number }, items = { stone = 1 } }))
      S.eq(d3.code, "no_items")
      S.eq(C.counts(W.main), { ["iron-plate"] = 10, coal = 5, stone = 3 })
  end },
  { "extract: чужой резерв не берётся; всё в резерве — reserved", function()
      local W = C.setup()
      local ch = C.chest({ x = 3.5, y = 0.5 }, { ["iron-plate"] = 100 })
      storage.reservations.items.h2 = { ["iron-plate"] = 90 }
      local d = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, items = { ["iron-plate"] = 30 } }))
      S.eq(d.detail, { extracted = { ["iron-plate"] = 10 }, missing = { ["iron-plate"] = 20 } })
      local d2 = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, items = { ["iron-plate"] = 5 } }))
      S.eq(d2.code, "reserved")
      S.eq(C.counts(chest_inv(ch)), { ["iron-plate"] = 90 })
      storage.reservations.items.h1 = { ["iron-plate"] = 90 }
      storage.reservations.items.h2 = nil
      local d3 = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, items = { ["iron-plate"] = 5 } }))
      S.eq(d3.detail.extracted, { ["iron-plate"] = 5 }, "свой резерв не мешает")
      S.eq(C.counts(W.main), { ["iron-plate"] = 15 })
  end },
  { "extract equip: броня целым стаком в слот, прежняя — в инвентарь", function()
      local W = C.setup{ armor = { { name = "modular-armor", count = 1, data = "old" } } }
      local ch = C.chest({ x = 3.5, y = 0.5 }, { { name = "power-armor-mk2", count = 1, data = "grid-A" }, { name = "coal", count = 2 } })
      local d = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, items = { ["power-armor-mk2"] = 1 }, equip = true }))
      S.eq(d.detail, { extracted = { ["power-armor-mk2"] = 1 }, equipped = "power-armor-mk2", unequipped = "modular-armor" })
      S.eq({ W.armor[1].name, W.armor[1].data }, { "power-armor-mk2", "grid-A" })
      local old
      for i = 1, #W.main do if W.main[i].valid_for_read then old = { W.main[i].name, W.main[i].data } end end
      S.eq(old, { "modular-armor", "old" })
      S.eq(C.data_destroyed, 0)
      S.eq(C.counts(chest_inv(ch)), { coal = 2 })
  end },
  { "extract: портящееся — стаком, item-with-entity-data — стаком", function()
      local W = C.setup()
      local ch = C.chest({ x = 3.5, y = 0.5 }, { { name = "yumako", count = 20, data = "spoil-0.3" }, { name = "car", count = 1, data = "car-fuel" } })
      local d = C.wait(job_of("extract", { target = { unit_number = ch.unit_number } }))
      S.eq(d.detail.extracted, { yumako = 20, car = 1 })
      S.eq(count_log("remove_item:"), 0, "ни одного remove_item")
      S.eq(C.data_destroyed, 0)
      local datas = {}
      for i = 1, #W.main do if W.main[i].valid_for_read then datas[W.main[i].name] = W.main[i].data end end
      S.eq(datas, { yumako = "spoil-0.3", car = "car-fuel" })
  end },
  { "портящееся: стак не делится — не больше заявки, недобор в missing/left", function()
      local W = C.setup()
      local ch = C.chest({ x = 3.5, y = 0.5 }, { { name = "yumako", count = 50, data = "spoil-A" }, { name = "yumako", count = 8, data = "spoil-B" } })
      local d, kind = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, items = { yumako = 10 } }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { extracted = { yumako = 8 }, missing = { yumako = 2 } }, "взят только целый стак ≤ заявки")
      S.eq(C.counts(W.main), { yumako = 8 })
      local d2 = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, items = { yumako = 10 } }))
      S.eq({ d2.code, d2.detail.reason }, { "no_items", "whole_stacks_only" })
      S.eq(C.counts(chest_inv(ch)), { yumako = 50 })
      local ch2 = C.chest({ x = 4.5, y = 2.5 }, {})
      local d3 = C.wait(job_of("insert", { target = { unit_number = ch2.unit_number }, items = { yumako = 5 } }))
      S.eq(d3.detail, { inserted = {}, left = { yumako = 5 } })
      S.eq(C.counts(W.main), { yumako = 8 })
      S.eq(count_log("remove_item:"), 0)
  end },
  { "equip: из двух видов брони — детерминированно по имени", function()
      local W = C.setup()
      local ch = C.chest({ x = 3.5, y = 0.5 }, { { name = "power-armor-mk2", count = 1, data = "P" }, { name = "modular-armor", count = 1, data = "M" } })
      local d = C.wait(job_of("extract", { target = { unit_number = ch.unit_number }, equip = true }))
      S.eq(d.detail.equipped, "modular-armor")
      S.eq(d.detail.unequipped, nil)
      S.eq({ W.armor[1].name, W.armor[1].data }, { "modular-armor", "M" })
  end },
  { "insert: предмет с данными в машину без главного инвентаря — bad_args", function()
      local W = C.setup{ items = { { name = "power-armor-mk2", count = 1, data = "grid-1" } } }
      local asm = S.nauvis.create_entity{ name = "assembling-machine-1", position = { x = 3.5, y = 0.5 }, force = "player" }
      asm.inventories = { [defines.inventory.assembling_machine_output or 3] = C.inventory{ size = 1 } }
      rawset(asm, "get_output_inventory", function() return asm.inventories[defines.inventory.assembling_machine_output or 3] end)
      local d = C.wait(job_of("insert", { target = { unit_number = asm.unit_number }, items = { ["power-armor-mk2"] = 1 } }))
      S.eq(d.code, "bad_args")
      S.eq(C.counts(W.main), { ["power-armor-mk2"] = 1 })
  end },
  { "extract: чужая сила — not_found, персонаж — bad_args, бесконечный сундук — no_items", function()
      local W = C.setup()
      local enemy = C.chest({ x = 3.5, y = 0.5 }, { coal = 5 }, { force = "enemy" })
      S.eq(C.wait(job_of("extract", { target = { unit_number = enemy.unit_number } })).code, "not_found")
      S.eq(C.wait(job_of("extract", { target = { unit_number = W.player.character.unit_number } })).code, "bad_args")
      local inf = C.chest({ x = 4.5, y = 0.5 }, { coal = 5 }, { name = "infinity-chest" })
      S.eq(C.wait(job_of("extract", { target = { unit_number = inf.unit_number } })).code, "no_items")
      S.eq(C.counts(W.main), {})
  end },
  { "extract: полный инвентарь — inventory_full; частично — done и событие", function()
      local W = C.setup{ size = 2, items = { { name = "stone", count = 50 }, { name = "coal", count = 45 } } }
      local ch = C.chest({ x = 3.5, y = 0.5 }, { ["iron-plate"] = 10, coal = 20 })
      local job = job_of("extract", { target = { unit_number = ch.unit_number }, items = { ["iron-plate"] = 10 } })
      local d = C.wait(job)
      S.eq({ d.code, d.detail.reason }, { "stuck", "inventory_full" })
      local job2 = job_of("extract", { target = { unit_number = ch.unit_number }, items = { coal = 20 } })
      local d2, k2 = C.wait(job2)
      S.eq(k2, "job_done")
      S.eq(d2.detail, { extracted = { coal = 5 }, missing = { coal = 15 } })
      S.eq(#C.events("inventory_full"), 2)
      S.eq(total(W.main, chest_inv(ch)), { stone = 50, coal = 65, ["iron-plate"] = 10 })
  end },
  { "цель исчезла по пути — not_found", function()
      local W = C.setup()
      local ch = C.chest({ x = 40.5, y = 0.5 }, { coal = 1 })
      local job = job_of("extract", { target = { unit_number = ch.unit_number } })
      C.run(5)
      ch.destroy()
      local d = C.wait(job)
      S.eq(d.code, "not_found")
      S.ok(W.path.cancels > 0)
  end },
})
