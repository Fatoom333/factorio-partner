-- Действие mine (поток C): ACTIONS.md, PROTOCOL §6.5 (selected + mining_state), подход, прирост.
local S = require("stubs")
local C = require("stubs_c")

local function mine(args) return S.okr(C.act("mine", args)).job end

S.suite("hands_mine", {
  { "resource: подходит на resource_reach, копает selected+mining_state до count", function()
      local W = C.setup()
      local ore = C.resource("iron-ore", { x = 10.5, y = 0.5 }, 100)
      local job = mine{ resource = "iron-ore", count = 3 }
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { mined = { ["iron-ore"] = 3 } })
      S.eq(C.counts(W.main), { ["iron-ore"] = 3 })
      S.ok(#W.path.calls > 0, "подходил через ctx.approach")
      S.ok(W.path.calls[1].dist < W.h.resource_reach_distance, "дистанция подхода меньше resource_reach")
      S.ok(S.dist(W.h.position, ore.position) <= W.h.resource_reach_distance)
      S.eq(W.h.mining_state.mining, false, "добыча выключена в конце")
      S.eq(W.h.selected, nil)
      S.eq(ore.amount, 97)
  end },
  { "опрос каждый тик без get_contents: руда — ни разу, дерево — только на старте и итоге", function()
      local W = C.setup{ items = { coal = 5 } }
      C.resource("iron-ore", { x = 3.5, y = 0.5 }, 100)
      local calls = 0
      local orig = W.main.get_contents
      rawset(W.main, "get_contents", function(...) calls = calls + 1 return orig(...) end)
      local d, kind = C.wait(mine{ resource = "iron-ore", count = 3 })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(calls, 0, "resource-режим считает get_item_count")
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 4.5, y = 2.5 }, force = "neutral" }
      local d2, k2 = C.wait(mine{ target = { unit_number = tree.unit_number }, count = 1 })
      S.eq(k2, "job_done", S.dump(d2))
      S.eq(d2.detail, { mined = { wood = 4 } })
      S.ok(calls <= 2, "get_contents только на старте и итоге: " .. calls)
  end },
  { "resource: клетка кончилась — следующая рядом; near задаёт центр поиска", function()
      local W = C.setup()
      C.resource("iron-ore", { x = 6.5, y = 0.5 }, 2)
      C.resource("iron-ore", { x = 7.5, y = 0.5 }, 2)
      C.resource("iron-ore", { x = -40.5, y = 0.5 }, 50)
      local d, kind = C.wait(mine{ resource = "iron-ore", count = 4 })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.mined, { ["iron-ore"] = 4 })
      S.ok(W.h.position.x > 0, "далёкая руда не трогалась")
      -- near: идём к другому пятну
      local d2, k2 = C.wait(mine{ resource = "iron-ore", near = { x = -40, y = 0 }, count = 1 })
      S.eq(k2, "job_done", S.dump(d2))
      S.ok(W.h.position.x < -35)
  end },
  { "resource: руды не хватило — not_found с тем, что накопано; руды нет — not_found", function()
      C.setup()
      C.resource("iron-ore", { x = 5.5, y = 0.5 }, 2)
      local d, kind = C.wait(mine{ resource = "iron-ore", count = 5 })
      S.eq({ kind, d.code }, { "job_failed", "not_found" })
      S.eq(d.detail.mined, { ["iron-ore"] = 2 })
      local d2 = C.wait(mine{ resource = "copper-ore", count = 1 })
      S.eq(d2.code, "not_found")
  end },
  { "resource: руда в неоткрытом чанке и дальше 64 не берётся", function()
      C.setup()
      local f = game.forces.player
      C.resource("iron-ore", { x = 40.5, y = 0.5 }, 10)
      f.uncharted[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      C.resource("iron-ore", { x = 90.5, y = 0.5 }, 10)
      local d = C.wait(mine{ resource = "iron-ore", count = 1 })
      S.eq(d.code, "not_found")
  end },
  { "аргументы: ровно одно из target/resource, руда руками, жидкость, near без resource", function()
      local W = C.setup()
      local ore = C.resource("iron-ore", { x = 5.5, y = 0.5 })
      C.resource("tungsten-ore", { x = 6.5, y = 0.5 })
      local cases = {
        { args = { count = 1 }, code = "bad_args" },
        { args = { resource = "iron-ore", target = { unit_number = ore.unit_number }, count = 1 }, code = "bad_args" },
        { args = { resource = "nope", count = 1 }, code = "bad_args" },
        { args = { resource = "iron-chest", count = 1 }, code = "bad_args" },
        { args = { resource = "tungsten-ore", count = 1 }, code = "bad_args" },
        { args = { resource = "uranium-ore", count = 1 }, code = "bad_args" },
        { args = { target = { unit_number = ore.unit_number }, near = { x = 1, y = 1 }, count = 1 }, code = "bad_args" },
      }
      for i, c in ipairs(cases) do
        local d = C.wait(mine(c.args))
        S.eq(d.code, c.code, "случай " .. i .. " " .. S.dump(d))
      end
      S.err(C.act("mine", { resource = "iron-ore", count = 0 }), "bad_args")
      S.err(C.act("mine", { resource = "iron-ore" }), "bad_args")
      S.eq(W.h.mining_state.mining, false)
  end },
  { "target: дерево (neutral) копается до исчезновения, mined = прирост", function()
      local W = C.setup()
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 12, y = 3 }, force = "neutral" }
      local d, kind = C.wait(mine{ target = { name = "tree-01", pos = { x = 12, y = 3 } }, count = 1 })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.mined, { wood = 4 })
      S.eq(tree.valid, false)
      S.ok(S.dist(W.h.position, { x = 12, y = 3 }) <= W.h.reach_distance)
  end },
  { "target: своя постройка по unit_number; клетка руды — дальше как resource", function()
      local W = C.setup()
      local ch = C.chest({ x = 4.5, y = 0.5 }, {})
      local d = C.wait(mine{ target = { unit_number = ch.unit_number }, count = 1 })
      S.eq(d.detail.mined, { ["iron-chest"] = 1 })
      local a = C.resource("stone", { x = 8.5, y = 0.5 }, 1)
      C.resource("stone", { x = 8.5, y = 1.5 }, 5)
      local d2, k2 = C.wait(mine{ target = { name = "stone", pos = { x = 8.5, y = 0.5 } }, count = 3 })
      S.eq(k2, "job_done", S.dump(d2))
      S.eq(d2.detail.mined, { stone = 3 })
      S.eq(a.valid, false)
      S.eq(C.counts(W.main), { ["iron-chest"] = 1, stone = 3 })
  end },
  { "target: чужая сила — not_found, другая поверхность — not_reachable, неоткрыто — not_charted", function()
      C.setup()
      local enemy = C.chest({ x = 4.5, y = 0.5 }, {}, { force = "enemy" })
      S.eq(C.wait(mine{ target = { unit_number = enemy.unit_number }, count = 1 }).code, "not_found")
      local other = S.surface{ name = "vulcanus" }
      local far = C.chest({ x = 1.5, y = 0.5 }, {}, { surface = other })
      S.eq(C.wait(mine{ target = { unit_number = far.unit_number }, count = 1 }).code, "not_reachable")
      S.eq(C.wait(mine{ target = { name = "iron-chest", pos = { x = 50, y = 50 } }, count = 1 }).code, "not_found")
      local hid = C.chest({ x = 40.5, y = 0.5 }, {})
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      S.eq(C.wait(mine{ target = { unit_number = hid.unit_number }, count = 1 }).code, "not_charted")
      S.eq(enemy.valid and far.valid and hid.valid, true)
  end },
  { "полный инвентарь: событие inventory_full и failed{no_space, reason}", function()
      local W = C.setup{ size = 1, items = { stone = 50 } }
      C.resource("iron-ore", { x = 5.5, y = 0.5 }, 10)
      local job = mine{ resource = "iron-ore", count = 2 }
      local d = C.wait(job)
      S.eq({ d.code, d.detail.reason }, { "no_space", "inventory_full" })
      local ev = C.events("inventory_full")
      S.eq(#ev, 1)
      S.eq(ev[1].data, { job = job })
      S.eq(ev[1].loud, true)
      S.eq(W.h.mining_state.mining, false)
  end },
  { "нет прироста — клетка пропускается; 5 пропусков — stuck", function()
      local W = C.setup()
      for i = 1, 6 do C.resource("iron-ore", { x = 4.5 + i, y = 0.5 }, 10) end
      C.mining_disabled = true   -- «движок» не копает (как руда под постройкой)
      local job = mine{ resource = "iron-ore", count = 1 }
      C.run(400)
      S.eq(W.h.mining_state.mining, true, "после пропуска копает следующую клетку")
      local d = C.wait(job, 20000)
      S.eq({ d.code, d.text }, { "stuck", "mining gives nothing" })
      S.eq(W.h.mining_state.mining, false)
  end },
  { "отмена: stop снимает mining_state и зовёт cancel_approach", function()
      local W = C.setup()
      C.resource("iron-ore", { x = 4.5, y = 0.5 }, 100)
      local job = mine{ resource = "iron-ore", count = 50 }
      C.run(200)
      S.eq(W.h.mining_state.mining, true)
      local before = W.path.cancels
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(W.h.mining_state.mining, false)
      S.ok(W.path.cancels > before, "cancel_approach вызван")
      S.eq(C.result(job).code, "cancelled")
  end },
  { "ошибка пути передаётся как есть", function()
      local W = C.setup()
      C.resource("iron-ore", { x = 30.5, y = 0.5 }, 100)
      W.path.fail = { status = "failed", code = "path_failed", text = "no path" }
      local d = C.wait(mine{ resource = "iron-ore", count = 1 })
      S.eq(d.code, "path_failed")
  end },
  { "прогресс: task.progress растёт, job_progress шумный", function()
      local W = C.setup()
      C.resource("iron-ore", { x = 4.5, y = 0.5 }, 100)
      local job = mine{ resource = "iron-ore", count = 10 }
      C.wait(job)
      local pr = C.events("job_progress")
      S.ok(#pr >= 1, "был job_progress")
      S.eq(pr[1].data.total, 10)
      S.eq(pr[1].loud, false)
      S.eq(C.counts(W.main), { ["iron-ore"] = 10 })
  end },
})
