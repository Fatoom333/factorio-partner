-- Выходы линий хозяина и машин (scripts/lib/lines.lua): get_items и collect берут из них только с
-- from_lines, без флага — подсказка в ответе; из машины — только выходной слот. extract находит
-- цель по unit_number, даже когда pos неточный.
local S = require("stubs")
local C = require("stubs_c")

local function job_of(d, args) return S.okr(C.act(d, args)).job end
local function chest_inv(ch) return ch.get_inventory(defines.inventory.chest) end

local function prepare(opts)
  local W = C.setup(opts)
  prototypes.item["electric-engine-unit"] = { name = "electric-engine-unit", type = "item", stack_size = 50 }
  prototypes.item["processing-unit"] = { name = "processing-unit", type = "item", stack_size = 100 }
  prototypes.item["electronic-circuit"] = { name = "electronic-circuit", type = "item", stack_size = 200 }
  prototypes.entity["assembling-machine-2"] = { name = "assembling-machine-2", type = "assembling-machine" }
  -- как в 2.0: постройки движок по номеру не находит
  local find = game.get_entity_by_unit_number
  game.get_entity_by_unit_number = function(n)
    local e = find(n)
    if e ~= nil and e.type ~= "character" then return nil end
    return e
  end
  return W
end

--- Сборщик хозяина: вход и выход — отдельные инвентари, get_output_inventory — только выход.
local function assembler(pos, input, output)
  local e = S.nauvis.create_entity{ name = "assembling-machine-2", position = pos, force = "player" }
  local inp = C.inventory{ size = 4, items = input }
  local out = C.inventory{ size = 1, items = output }
  e.inventories = {
    [defines.inventory.assembling_machine_input] = inp,
    [defines.inventory.assembling_machine_output] = out,
  }
  rawset(e, "get_output_inventory", function() return out end)
  return e, inp, out
end

local function inserter(pos, from, to)
  return S.nauvis.create_entity{ name = "inserter", type = "inserter", position = pos, force = "player",
    fields = { type = "inserter", pickup_target = from, drop_target = to } }
end

S.suite("hands_lines", {
  { "extract: номер верный, pos мимо на 20 клеток — сундук находится, помощник подходит и берёт", function()
      local W = prepare()
      local ch = C.chest({ x = 14.5, y = 6.5 }, { ["electric-engine-unit"] = 90 }, { size = 48 })
      local d, kind = C.wait(job_of("extract", {
        target = { unit_number = ch.unit_number, pos = { x = 34.5, y = 6.5 } },
        items = { ["electric-engine-unit"] = 40 },
      }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.extracted, { ["electric-engine-unit"] = 40 })
      S.eq(C.counts(chest_inv(ch)), { ["electric-engine-unit"] = 50 })
      S.ok(W.h.can_reach_entity(ch), "брал в досягаемости")
      local foe = C.chest({ x = 8.5, y = 2.5 }, { coal = 1 }, { force = "enemy" })
      local d2 = C.wait(job_of("extract", { target = { unit_number = foe.unit_number, pos = { x = 30, y = 30 } } }))
      S.eq(d2.code, "not_found", "чужая сила по номеру не находится")
  end },
  { "get_items: выходной сундук линии без from_lines — no_source с подсказкой, ничего не тронуто", function()
      local W = prepare()
      local asm = assembler({ x = 10.5, y = 4.5 }, {}, {})
      local out1 = C.chest({ x = 10.5, y = 8.5 }, { ["electric-engine-unit"] = 150 }, { size = 48 })
      local out2 = C.chest({ x = 12.5, y = 8.5 }, { ["electric-engine-unit"] = 107 }, { size = 48 })
      inserter({ x = 10.5, y = 6.5 }, asm, out1)
      inserter({ x = 12.5, y = 6.5 }, asm, out2)
      local d, kind = C.wait(job_of("get_items", { items = { ["electric-engine-unit"] = 120 } }))
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "no_items")
      local sf = d.detail.shortfall[1]
      S.eq({ sf.item, sf.missing, sf.reason, sf.in_lines }, { "electric-engine-unit", 120, "no_source", 257 })
      S.eq(#sf.lines_at, 2)
      S.eq(sf.lines_at[1], { pos = { x = 10.5, y = 8.5 }, count = 150, kind = "line" })
      S.ok(sf.hint:find("from_lines", 1, true) ~= nil, sf.hint)
      S.eq(C.counts(chest_inv(out1)), { ["electric-engine-unit"] = 150 })
      S.eq(C.counts(chest_inv(out2)), { ["electric-engine-unit"] = 107 })
      S.eq(C.counts(W.main), {})
  end },
  { "get_items с from_lines: берёт из выходных сундуков линии", function()
      local W = prepare()
      local asm = assembler({ x = 10.5, y = 4.5 }, {}, {})
      local out1 = C.chest({ x = 10.5, y = 8.5 }, { ["electric-engine-unit"] = 150 }, { size = 48 })
      local out2 = C.chest({ x = 12.5, y = 8.5 }, { ["electric-engine-unit"] = 107 }, { size = 48 })
      inserter({ x = 10.5, y = 6.5 }, asm, out1)
      inserter({ x = 12.5, y = 6.5 }, asm, out2)
      local d, kind = C.wait(job_of("get_items", { items = { ["electric-engine-unit"] = 120 }, from_lines = true }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["electric-engine-unit"] = 120 })
      S.eq(d.detail.from, { storage = { ["electric-engine-unit"] = 120 } })
      S.eq(d.detail.shortfall, nil)
      local left = (C.counts(chest_inv(out1))["electric-engine-unit"] or 0) + (C.counts(chest_inv(out2))["electric-engine-unit"] or 0)
      S.eq(left, 137, "из сундуков ушло ровно 120")
  end },
  { "свой склад (без манипулятора) берётся без флага, выход линии рядом не трогается", function()
      local W = prepare()
      local asm = assembler({ x = 10.5, y = 4.5 }, {}, {})
      local line = C.chest({ x = 5.5, y = 0.5 }, { ["electric-engine-unit"] = 50 })
      inserter({ x = 7.5, y = 2.5 }, asm, line)
      local own = C.chest({ x = 14.5, y = 0.5 }, { ["electric-engine-unit"] = 30 })
      local d, kind = C.wait(job_of("get_items", { items = { ["electric-engine-unit"] = 40 } }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["electric-engine-unit"] = 30 })
      S.eq(C.counts(chest_inv(line)), { ["electric-engine-unit"] = 50 }, "выход линии не тронут")
      S.eq(C.counts(chest_inv(own)), {})
      local sf = d.detail.shortfall[1]
      S.eq({ sf.missing, sf.in_lines }, { 10, 50 })
  end },
  { "get_items с from_lines: готовое из выходного слота сборщика, входы не тронуты", function()
      local W = prepare()
      local asm, inp, out = assembler({ x = 9.5, y = 3.5 }, { ["electronic-circuit"] = 40 }, { ["processing-unit"] = 30 })
      local d0, k0 = C.wait(job_of("get_items", { items = { ["processing-unit"] = 20 } }))
      S.eq(k0, "job_failed", S.dump(d0))
      local sf = d0.detail.shortfall[1]
      S.eq({ sf.reason, sf.in_lines, sf.lines_at[1].kind }, { "no_source", 30, "machine" })
      S.eq(C.counts(out), { ["processing-unit"] = 30 }, "без флага выход машины не тронут")
      local d, kind = C.wait(job_of("get_items", { items = { ["processing-unit"] = 20 }, from_lines = true }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.have, { ["processing-unit"] = 20 })
      S.eq(C.counts(out), { ["processing-unit"] = 10 })
      S.eq(C.counts(inp), { ["electronic-circuit"] = 40 }, "вход сборщика не тронут")
      S.eq(C.counts(W.main), { ["processing-unit"] = 20 })
      S.ok(W.h.can_reach_entity(asm), "брал в досягаемости")
  end },
  { "collect: без флага — no_items с detail.lines, с флагом — собирает из выхода линии и машины", function()
      local W = prepare()
      local asm, inp, out = assembler({ x = 9.5, y = 3.5 }, { ["electronic-circuit"] = 5 }, { ["processing-unit"] = 4 })
      local line = C.chest({ x = 6.5, y = 0.5 }, { ["processing-unit"] = 6 })
      inserter({ x = 8.5, y = 1.5 }, asm, line)
      local d, kind = C.wait(job_of("collect", { items = { ["processing-unit"] = 8 } }))
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.code, "no_items")
      S.eq(d.detail.lines["processing-unit"].count, 10)
      S.eq(#d.detail.lines["processing-unit"].at, 2)
      local d2, k2 = C.wait(job_of("collect", { items = { ["processing-unit"] = 8 }, from_lines = true }))
      S.eq(k2, "job_done", S.dump(d2))
      S.eq(d2.detail.collected, { ["processing-unit"] = 8 })
      S.eq(C.counts(inp), { ["electronic-circuit"] = 5 }, "вход сборщика не тронут")
      S.eq((C.counts(out)["processing-unit"] or 0) + (C.counts(chest_inv(line))["processing-unit"] or 0), 2)
  end },
  { "get_items: склад есть, но дойти нельзя — причина — код сбора, а не no_source", function()
      local W = prepare()
      C.chest({ x = 20.5, y = 0.5 }, { ["electric-engine-unit"] = 10 })
      W.path.fail = { status = "failed", code = "path_failed", text = "no path" }
      local d, kind = C.wait(job_of("get_items", { items = { ["electric-engine-unit"] = 5 } }))
      S.eq(kind, "job_failed", S.dump(d))
      S.eq(d.detail.shortfall[1].reason, "path_failed")
  end },
})
