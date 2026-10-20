-- build_layout: поиск места (кольца × повороты, бюджет на тик, site_limit), on_resource, возврат
-- после отступления (resume_args), память блоков storage.layouts и её API (scripts/lib/layout.lua).
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")
local K = require("stubs_k")

local A = { x = 20, y = 0 }
local TWO = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } }

local function L() return require("scripts.actions.build_layout") end
local function lay() return require("scripts.lib.layout") end

local function lava(x0, x1, y0, y1)
  for x = x0, x1 do
    for y = y0, y1 do F.set_tile(x, y, "lava") end
  end
end

S.suite("build_layout_site", {
  { "поиск места: первый годный по кольцам, ближние первыми; search 0 — только якорь", function()
      local W = K.setup{ items = { ["iron-chest"] = 2 } }
      lava(16, 25, -1, 0)
      local f = F.wait(K.job{ anchor = A, entities = TWO })
      S.eq({ f.code, f.detail.reason, f.detail.site_checked }, { "cannot_place", "site_not_found", 1 }, S.dump(f))
      S.eq(f.detail.failed[1], { i = 1, name = "iron-chest", pos = { x = 20.5, y = 0.5 }, code = "cannot_place", why = "liquid" })
      local dry = F.wait(K.job{ anchor = A, entities = TWO, search = 2, dry_run = true })
      -- кольцо 1: (0,−1), (−1,0), (1,0) на лаве, (0,1) — суша
      S.eq(dry.detail.site, { anchor = { x = 20, y = 1 }, direction = 0, shift = { dx = 0, dy = 1 }, checked = 5 }, S.dump(dry))
      local d, kind = F.wait(K.job{ anchor = A, entities = TWO, search = 2, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(#K.built("iron-chest", { x = 20.5, y = 1.5 }), 1)
      S.eq(#K.built("iron-chest", { x = 21.5, y = 1.5 }), 1)
      S.eq(C.counts(W.main), {})
      -- места нет и в dry_run — done с той же оценкой
      lava(10, 30, -10, 10)
      local none, nk = F.wait(K.job{ anchor = A, entities = TWO, search = 2, dry_run = true })
      S.eq({ nk, none.detail.reason, none.detail.site_checked, none.detail.failed_total }, { "job_done", "site_not_found", 25, 2 })
  end },
  { "поиск идёт в несколько тиков с «пульсом» и обрывается бюджетом (site_limit)", function()
      K.setup{ items = { ["iron-chest"] = 2 } }
      lava(0, 40, -20, 20)
      local M = L()
      local ops, max = M.FIT_OPS_TICK, M.FIT_MAX_OPS
      M.FIT_OPS_TICK = 30
      local job = K.job{ anchor = A, entities = TWO, search = 4, dry_run = true }
      F.run(3)
      S.eq(C.result(job), nil, "за три тика поиск не кончился")
      local t = storage.jobs.by_helper.h1.active
      S.ok(t.site ~= nil and t.site.checked > 0 and t.progress_tick ~= nil, "идёт поиск, пульс стоит")
      S.eq(t.progress.phase, "site")
      for _, it in ipairs(t.plan or {}) do S.eq(it.proto, nil, "в задаче нет прототипов") end
      local d = F.wait(job)
      S.eq({ d.detail.reason, d.detail.site_checked, d.detail.site_limit }, { "site_not_found", 81, nil })
      M.FIT_MAX_OPS = 100
      local d2 = F.wait(K.job{ anchor = A, entities = TWO, search = 4, dry_run = true })
      S.eq(d2.detail.site_limit, true)
      S.ok(d2.detail.site_checked < 81)
      local f = F.wait(K.job{ anchor = A, entities = TWO, search = 4 })
      S.eq({ f.code, f.detail.site_limit }, { "cannot_place", true })
      M.FIT_OPS_TICK, M.FIT_MAX_OPS = ops, max
      -- отмена посреди поиска ничего не оставляет
      M.FIT_OPS_TICK = 30
      local job3 = K.job{ anchor = A, entities = TWO, search = 8 }
      F.run(2)
      S.okr(S.req("cancel", { job = job3 }, "h1"))
      S.eq({ C.result(job3).code, #F.ghosts(), #K.bp_calls }, { "cancelled", 0, 0 })
      M.FIT_OPS_TICK = ops
  end },
  { "rotate: перебираются повороты блока; поворот уходит в site.direction", function()
      K.setup{ items = { ["iron-chest"] = 3 } }
      lava(10, 30, -10, 10)
      for x = 19, 23 do F.set_tile(x, 0, "grass-1") end
      local col = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 0, dy = 1 }, { name = "iron-chest", dx = 0, dy = 2 } }
      local plain = F.wait(K.job{ anchor = A, entities = col, dry_run = true })
      S.eq(plain.detail.reason, "site_not_found")
      local d = F.wait(K.job{ anchor = A, entities = col, rotate = true, mode = "hand" })
      S.eq(d.detail.site, { anchor = { x = 20, y = 0 }, direction = 12, shift = { dx = 0, dy = 0 }, checked = 4 }, S.dump(d))
      for x = 20, 22 do S.eq(#K.built("iron-chest", { x = x + 0.5, y = 0.5 }), 1) end
  end },
  { "on_resource: бур годен, только если в его области есть эта руда", function()
      K.setup{ items = { ["electric-mining-drill"] = 1 } }
      C.resource("iron-ore", { x = 25.5, y = 1.5 }, 100)
      local drill = { { name = "electric-mining-drill", dx = 0, dy = 0 } }
      local free = F.wait(K.job{ anchor = A, entities = drill, search = 3, dry_run = true })
      S.eq(free.detail.site.shift, { dx = 0, dy = 0 })
      local d = F.wait(K.job{ anchor = A, entities = drill, search = 3, on_resource = "iron-ore", dry_run = true })
      S.eq(d.detail.site.shift, { dx = 2, dy = 0 }, S.dump(d.detail.site))
      local none = F.wait(K.job{ anchor = A, entities = drill, search = 3, on_resource = "copper-ore", dry_run = true })
      S.eq(none.detail.reason, "site_not_found")
  end },
  { "место в чужом резерве не годится; якорь в нём без поиска — reserved", function()
      K.setup{ items = { ["iron-chest"] = 2 } }
      storage.reservations.areas.h2 = { left_top = { x = 18, y = -2 }, right_bottom = { x = 23, y = 0.5 } }
      local f = F.wait(K.job{ anchor = A, entities = TWO })
      S.eq(f.code, "reserved", S.dump(f))
      S.eq(f.detail.failed[1].code, "reserved")
      local d = F.wait(K.job{ anchor = A, entities = TWO, search = 3, dry_run = true })
      S.ok(d.detail.site ~= nil and d.detail.site.shift.dy >= 2, S.dump(d.detail))
  end },
  { "resume_args: найденные anchor и direction, search 0; повтор даёт exists и не мешает", function()
      K.setup{ items = { ["iron-chest"] = 3 } }
      lava(16, 25, -1, 0)
      F.give_robots(F.W.h, 1, 30)
      F.robots_stalled = true
      local job = K.job{ anchor = A, entities = TWO, search = 2, rotate = true, mode = "robots", tag = "box" }
      for _ = 1, 20 do F.run(1) end
      local t = storage.jobs.by_helper.h1.active
      S.eq(t.job, job)
      local args = L().resume_args(t)
      S.eq({ args.anchor, args.direction, args.search, args.rotate, args.tag }, { { x = 20, y = 1 }, 0, 0, false, "box" })
      S.eq(args.entities, TWO)
      S.eq(args.blob, nil)
      -- ещё не начатая задача — свои аргументы
      local queued = { args = { anchor = A, entities = TWO, search = 2, direction = 4 } }
      S.eq(L().resume_args(queued).search, 2)
      S.okr(S.req("cancel", { job = job }, "h1"))
      -- одна постройка уже стоит: возврат с найденным местом достраивает блок
      S.nauvis.create_entity{ name = "iron-chest", position = { x = 20.5, y = 1.5 }, force = "player" }
      F.robots_stalled = false
      local d, kind = F.wait(K.job(args))
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.failed, { { i = 1, name = "iron-chest", pos = { x = 20.5, y = 1.5 }, code = "exists" } })
      S.eq(#K.built("iron-chest", { x = 21.5, y = 1.5 }), 1)
  end },
  { "память блока: tag пишет layouts (с exists), порты в мире; API port/entity; dry_run не пишет", function()
      K.setup{ items = { ["stone-furnace"] = 2 } }
      S.nauvis.create_entity{ name = "iron-chest", position = { x = 20.5, y = 0.5 }, force = "player" }
      local ents = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "stone-furnace", dx = 1, dy = 0 }, { name = "stone-furnace", dx = 3, dy = 0 } }
      local ports = { { id = "in", dx = -1, dy = 0, kind = "belt", io = "in", dir = 4, items = { "iron-ore", "coal" } },
        { id = "p_1", dx = 0, dy = 2, kind = "power", io = "in" } }
      F.wait(K.job{ anchor = A, entities = ents, ports = ports, tag = "smelt", dry_run = true })
      S.eq(storage.layouts.h1, nil, "dry_run не пишет")
      local d, kind = F.wait(K.job{ anchor = A, entities = ents, ports = ports, tag = "smelt", direction = 8, mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      local rec = storage.layouts.h1.smelt
      S.eq({ rec.surface, rec.anchor, rec.direction }, { "nauvis", { x = 20, y = 0 }, 8 })
      S.eq(#rec.placed, 3)
      S.eq(rec.placed[1], { i = 1, name = "iron-chest", pos = { x = 20.5, y = 0.5 } })
      -- поворот 8: клетка (−1, 0) блока → (1, 0) от якоря, направление 4 → 12
      S.eq(lay().port("h1", "smelt", "in"),
        { pos = { x = 21.5, y = 0.5 }, dir = 12, kind = "belt", io = "in", items = { "iron-ore", "coal" }, surface = "nauvis" })
      S.eq(lay().port("h1", "smelt", "p_1").pos, { x = 20.5, y = -1.5 })
      S.eq({ lay().port("h1", "smelt", "zz") }, { nil, "not_found", "layout smelt has no port zz" })
      S.eq({ lay().port("h1", "nope", "in") }, { nil, "not_found", "layout nope has no port in" })
      S.eq(lay().entity("h1", "smelt", 2), { name = "stone-furnace", pos = { x = 19, y = 0 }, surface = "nauvis" })
      S.eq(#K.built("stone-furnace", { x = 19, y = 0 }), 1)
      S.eq(select(2, lay().entity("h1", "smelt", 9)), "not_found")
      S.eq(d.detail.ports[1].pos, { x = 21.5, y = 0.5 })
      -- в storage — только простые данные
      S.ok(helpers.table_to_json(storage.layouts) ~= nil)
  end },
  { "память: не больше 16 тегов (старший вытесняется); helper_remove чистит записи", function()
      K.setup()
      local M = lay()
      for k = 1, 17 do
        M.write("h1", "t" .. k, { surface = "nauvis", anchor = { x = k, y = 0 }, direction = 0, tick = 100 + k,
          placed = {}, ports = {} })
      end
      local n = 0
      for _ in pairs(storage.layouts.h1) do n = n + 1 end
      S.eq(n, 16)
      S.eq(storage.layouts.h1.t1, nil, "самый старый вытеснен")
      S.ok(storage.layouts.h1.t17 ~= nil)
      -- перезапись того же тега не вытесняет
      M.write("h1", "t17", { surface = "nauvis", anchor = { x = 0, y = 0 }, direction = 4, tick = 500, placed = {}, ports = {} })
      S.ok(storage.layouts.h1.t2 ~= nil)
      S.eq(storage.layouts.h1.t17.direction, 4)
      storage.helpers.h1.state = "removed"   -- как после helper_remove
      M.clean()
      S.eq(storage.layouts.h1, nil)
      -- запись удалённого помощника снимается и сама — раз в CLEAN_EVERY тиков
      storage.layouts.h9 = { x = { surface = "nauvis", anchor = { x = 0, y = 0 }, direction = 0, tick = 1, placed = {}, ports = {} } }
      S.tick(M.CLEAN_EVERY + 1)
      S.eq(storage.layouts.h9, nil)
  end },
  { "схема storage: layouts и connect_last заводит ядро", function()
      K.setup()
      S.eq(type(storage.layouts), "table")
      S.eq(type(storage.connect_last), "table")
  end },
})
