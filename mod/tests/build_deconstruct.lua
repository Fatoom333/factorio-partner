-- Действие deconstruct (поток F): ACTIONS.md «deconstruct», PROTOCOL §6.5 (selected + mining_state
-- до исчезновения сущности), §6.6 (только своя сила и neutral), резерв области.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

local function decon(args) return F.job("deconstruct", args) end

local AREA = { left_top = { x = 15, y = -5 }, right_bottom = { x = 30, y = 5 } }

S.suite("build_deconstruct", {
  { "target: подходит на reach, копает selected + mining_state, предмет возвращается", function()
      local W = F.setup()
      local ch = C.chest({ x = 20.5, y = 0.5 }, {})
      local job = decon{ target = { name = "iron-chest", pos = { x = 20.5, y = 0.5 } } }
      -- посреди работы: выбран сундук, добыча включена
      local seen = false
      for _ = 1, 400 do
        F.run(1)
        if W.h.selected == ch and W.h.mining_state.mining then seen = true break end
      end
      S.ok(seen, "selected = цель, mining_state.mining = true")
      S.eq(W.h.mining_state.position, { x = 20.5, y = 0.5 })
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { removed = 1, got = { ["iron-chest"] = 1 } })
      S.eq(ch.valid, false)
      S.eq(C.mined, 1, "разобрал движок, а не скрипт")
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      S.ok(#W.path.calls > 0)
      S.eq(W.h.mining_state.mining, false)
      S.eq(W.h.selected, nil)
      S.ok(F.target.calls > 0, "цель — через scripts.core.target")
  end },
  { "поставил и разобрал: предмет вернулся в инвентарь", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      local p = F.wait(F.job("place", { item = "iron-chest", pos = { x = 9.5, y = 2.5 } }))
      S.eq(C.counts(W.main), {})
      local d, kind = F.wait(decon{ target = { unit_number = p.detail.unit_number } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.got, { ["iron-chest"] = 1 })
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      S.eq(#F.built("iron-chest"), 0)
  end },
  { "area: свои постройки; чужая сила, деревья, призраки и руда не трогаются", function()
      local W = F.setup()
      local a = C.chest({ x = 20.5, y = 0.5 }, {})
      local b = C.chest({ x = 22.5, y = 0.5 }, {})
      local c = C.chest({ x = 24.5, y = 1.5 }, {}, { name = "wooden-chest" })
      local enemy = C.chest({ x = 21.5, y = 2.5 }, {}, { force = "enemy" })
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 23, y = -2 }, force = "neutral" }
      local ghost = F.ghost("iron-chest", { x = 25.5, y = -1.5 })
      local ore = C.resource("iron-ore", { x = 26.5, y = 0.5 }, 10)
      local outside = C.chest({ x = 40.5, y = 0.5 }, {})
      local job = decon{ area = AREA }
      F.run(2)
      S.eq(storage.reservations.areas.h1, AREA, "область занята на время задачи")
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { removed = 3, got = { ["iron-chest"] = 2, ["wooden-chest"] = 1 } })
      S.eq({ a.valid, b.valid, c.valid }, { false, false, false })
      S.ok(enemy.valid and tree.valid and ghost.valid and ore.valid and outside.valid)
      S.ok(W.player.character.valid and W.h.valid)
      S.eq(storage.reservations.areas.h1, nil)
      S.eq(C.mined, 3)
  end },
  { "area + filter: только названное, в том числе neutral (деревья)", function()
      local W = F.setup()
      local a = C.chest({ x = 20.5, y = 0.5 }, {})
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 23, y = -2 }, force = "neutral" }
      local d, kind = F.wait(decon{ area = AREA, filter = { "tree-01" } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { removed = 1, got = { wood = 4 } })
      S.ok(a.valid and not tree.valid)
      S.eq(C.counts(W.main), { wood = 4 })
      -- filter по своей постройке
      local d2 = F.wait(decon{ area = AREA, filter = { "iron-chest" } })
      S.eq(d2.detail.removed, 1)
      S.eq(a.valid, false)
  end },
  { "пустая область — done{removed = 0}", function()
      F.setup()
      local d, kind = F.wait(decon{ area = AREA })
      S.eq(kind, "job_done")
      S.eq(d.detail, { removed = 0, got = {} })
  end },
  { "цель: чужая сила, нет такой, призрак, некопаемое, не в фильтре", function()
      F.setup()
      local enemy = C.chest({ x = 6.5, y = 0.5 }, {}, { force = "enemy" })
      local ghost = F.ghost("iron-chest", { x = 7.5, y = 0.5 })
      local rock = S.nauvis.create_entity{ name = "bedrock", position = { x = 8.5, y = 0.5 }, force = "player" }
      local mine = C.chest({ x = 9.5, y = 0.5 }, {})
      local cases = {
        { args = { target = { unit_number = enemy.unit_number } }, code = "not_found" },
        { args = { target = { unit_number = 999999 } }, code = "not_found" },
        { args = { target = { unit_number = ghost.unit_number } }, code = "bad_args" },
        { args = { target = { unit_number = rock.unit_number } }, code = "bad_args" },
        { args = { target = { unit_number = mine.unit_number }, filter = { "wooden-chest" } }, code = "not_found" },
        { args = {}, code = "bad_args" },
        { args = { target = { unit_number = mine.unit_number }, area = AREA }, code = "bad_args" },
      }
      for i, c in ipairs(cases) do
        local d, kind = F.wait(decon(c.args))
        S.eq({ kind, d.code }, { "job_failed", c.code }, "случай " .. i .. " " .. S.dump(d))
      end
      S.ok(enemy.valid and ghost.valid and rock.valid and mine.valid)
      S.eq(C.mined, 0)
      S.err(C.act("deconstruct", { area = AREA, filter = "iron-chest" }), "bad_args")
      S.err(C.act("deconstruct", { area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 300, y = 1 } } }), "limit")
  end },
  { "цель в неоткрытом чанке — not_charted; область в неоткрытом — not_charted", function()
      F.setup()
      local far = C.chest({ x = 100.5, y = 0.5 }, {})
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      S.eq(F.wait(decon{ target = { unit_number = far.unit_number } }).code, "not_charted")
      S.eq(F.wait(decon{ area = { left_top = { x = 90, y = 0 }, right_bottom = { x = 110, y = 5 } } }).code, "not_charted")
      S.ok(far.valid)
  end },
  { "резерв: чужая область — reserved (и для цели, и для области)", function()
      F.setup()
      local a = C.chest({ x = 20.5, y = 0.5 }, {})
      storage.reservations.areas.h2 = { left_top = { x = 18, y = -3 }, right_bottom = { x = 23, y = 3 } }
      S.eq(F.wait(decon{ target = { unit_number = a.unit_number } }).code, "reserved")
      S.eq(F.wait(decon{ area = AREA }).code, "reserved")
      S.ok(a.valid)
  end },
  { "инвентарь полон — событие inventory_full и задача снята, постройка цела", function()
      local W = F.setup{ size = 1, items = { coal = 50 } }
      local a = C.chest({ x = 6.5, y = 0.5 }, {})
      local d, kind = F.wait(decon{ target = { unit_number = a.unit_number } })
      S.eq(kind, "job_failed", S.dump(d))
      S.ok(d.code == "stuck" or d.code == "no_space", d.code)
      S.eq(d.detail.removed, 0)
      S.eq(#C.events("inventory_full"), 1)
      S.ok(a.valid)
      S.eq(W.h.mining_state.mining, false)
  end },
  { "цель не поддаётся — пропуск по таймауту; ничего не разобрано — stuck с detail", function()
      local W = F.setup()
      local a = C.chest({ x = 6.5, y = 0.5 }, {})
      C.mining_disabled = true
      local d, kind = F.wait(decon{ area = { left_top = { x = 5, y = -2 }, right_bottom = { x = 8, y = 2 } } })
      S.eq({ kind, d.code }, { "job_failed", "stuck" })
      S.eq(d.detail, { removed = 0, got = {}, skipped = 1 })
      S.ok(a.valid)
      S.eq(W.h.mining_state.mining, false)
      S.eq(W.h.selected, nil)
  end },
  { "цель исчезла сама, пока шли — не засчитывается", function()
      F.setup()
      local a = C.chest({ x = 40.5, y = 0.5 }, {})
      local job = decon{ target = { unit_number = a.unit_number } }
      F.run(5)
      a.destroy()
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { removed = 0, got = {} })
  end },
  { "больше 500 построек в области — limit", function()
      F.setup()
      for i = 0, 500 do
        C.chest({ x = 20.5 + (i % 30), y = 0.5 + math.floor(i / 30) }, {})
      end
      local d = F.wait(decon{ area = { left_top = { x = 20, y = 0 }, right_bottom = { x = 51, y = 18 } } })
      S.eq(d.code, "limit")
      S.eq(C.mined, 0)
  end },
  { "отмена: добыча выключена, подход снят", function()
      local W = F.setup()
      local a = C.chest({ x = 6.5, y = 0.5 }, {})
      prototypes.entity["iron-chest"].mineable_properties.mining_time = 30
      local job = decon{ target = { unit_number = a.unit_number } }
      F.run(60)
      S.eq(W.h.mining_state.mining, true)
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(W.h.mining_state.mining, false)
      S.eq(W.h.selected, nil)
      S.ok(a.valid)
      S.ok(W.path.cancels > 0)
  end },
})
