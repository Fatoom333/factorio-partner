-- Флаг auto_supply у build_ghosts (общая заглушка стройки stubs_f подменяет ядерный vis, поэтому
-- отдельным файлом от hands_get_items): предметы кончились — крафт по пути, стройка дальше.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

-- у подмены vis из stubs_f нет «глаз» viewer, которые нужны складам (stock.scan): всё видно
local pre = package.preload["scripts.core.vis"]
package.preload["scripts.core.vis"] = function()
  local m = pre()
  m.viewer = function() return function() return true end end
  return m
end

local function prepare(opts)
  local W = F.setup(opts)
  prototypes.item["iron-plate"].fuel_value = 0
  return W
end

S.suite("hands_get_items_build", {
  { "auto_supply у place: нет предмета — крафтит и ставит; без флага — no_items", function()
      local W = prepare{ items = { ["iron-plate"] = 10 } }
      local job = S.okr(C.act("place", { item = "iron-chest", pos = { x = 3.5, y = 0.5 } })).job
      S.eq(F.wait(job).code, "no_items")
      local job2 = S.okr(C.act("place", { item = "iron-chest", pos = { x = 3.5, y = 0.5 }, auto_supply = true })).job
      local d, kind = F.wait(job2)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.name, "iron-chest")
      S.eq(C.counts(W.main), { ["iron-plate"] = 2 })
  end },
  { "auto_supply у place: добыть нечем — no_items с detail.supply", function()
      prepare()
      local job = S.okr(C.act("place", { item = "iron-chest", pos = { x = 3.5, y = 0.5 }, auto_supply = true })).job
      local d, kind = F.wait(job)
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.ok(d.detail.supply and d.detail.supply.shortfall, S.dump(d))
  end },
  { "auto_supply у build_ghosts: предметы кончились — крафт и стройка дальше", function()
      local W = prepare{ items = { ["iron-chest"] = 1, ["iron-plate"] = 16 } }
      for i = 1, 3 do F.ghost("iron-chest", { x = 8.5 + i, y = 0.5 }) end
      local job = F.job("build_ghosts", { radius = 30, mode = "hand", auto_supply = true })
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.built, 3)
      S.eq(#F.built("iron-chest"), 3)
      S.eq(C.counts(W.main), {})
  end },
  { "auto_supply у build_ghosts mode=hand с дронами: после снабжения вылет дронов снова запрещён, в конце возвращён", function()
      local W = prepare{ items = { ["iron-chest"] = 1, ["iron-plate"] = 16 } }
      F.give_robots(W.h, 2, 10)
      for i = 1, 3 do F.ghost("iron-chest", { x = 8.5 + i, y = 0.5 }) end
      local job = F.job("build_ghosts", { radius = 30, mode = "hand", auto_supply = true })
      local seen_supply, bad = false, nil
      for _ = 1, 4000 do
        F.run(1)
        if W.h.allow_dispatching_robots == true then
          -- включённым дроны бывают только до начала стройки и после её конца
          if #F.built("iron-chest") >= 2 and #F.built("iron-chest") < 3 then bad = "включено посреди стройки" end
        else
          seen_supply = true
        end
        if #F.built("iron-chest") >= 3 then break end
      end
      S.eq(bad, nil)
      S.ok(seen_supply, "переключатель был выключен")
      local d, kind = F.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(#F.built("iron-chest"), 3)
      S.eq(W.h.allow_dispatching_robots, true, "прежнее значение возвращено")
  end },
  { "build_ghosts без флага: прежний no_items с missing", function()
      prepare{ items = { ["iron-chest"] = 1, ["iron-plate"] = 16 } }
      for i = 1, 3 do F.ghost("iron-chest", { x = 8.5 + i, y = 0.5 }) end
      local d2 = F.wait(F.job("build_ghosts", { radius = 30, mode = "hand" }))
      S.eq({ d2.code, d2.detail.missing }, { "no_items", { ["iron-chest"] = 2 } })
  end },
  { "auto_supply у build_ghosts mode=robots без дронов: снабжение не запускается, прежний no_items", function()
      local W = prepare{ items = { ["iron-plate"] = 16 } }
      for i = 1, 3 do F.ghost("iron-chest", { x = 8.5 + i, y = 0.5 }) end
      local d = F.wait(F.job("build_ghosts", { radius = 30, mode = "robots", auto_supply = true }))
      S.eq(d.code, "no_items", S.dump(d))
      S.eq(d.detail.supply, nil, "снабжение не пробовали")
      S.eq(C.counts(W.main), { ["iron-plate"] = 16 }, "ничего не скрафтили")
  end },
  { "auto_supply у build_ghosts: добыть нечем — прежний no_items с detail.supply", function()
      prepare{ items = { ["iron-chest"] = 1 } }
      for i = 1, 3 do F.ghost("iron-chest", { x = 8.5 + i, y = 0.5 }) end
      local d = F.wait(F.job("build_ghosts", { radius = 30, mode = "hand", auto_supply = true }))
      S.eq(d.code, "no_items", S.dump(d))
      S.eq(d.detail.built, 1)
      S.eq(d.detail.missing, { ["iron-chest"] = 2 })
      S.ok(d.detail.supply and d.detail.supply.shortfall, S.dump(d))
  end },
})
