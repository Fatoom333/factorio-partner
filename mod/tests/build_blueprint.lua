-- Действие build_blueprint (поток F): ACTIONS.md «build_blueprint» — blob → create_inventory →
-- import_stack → проверки manual_ghost → build_blueprint{build_mode normal} → призраки → стройка.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")

local ANCHOR = { x = 20, y = 0.5 }

-- два сундука рядом: центр рамки чертежа — между ними
local function two_chests()
  return { entities = {
    { entity_number = 1, name = "iron-chest", position = { x = -0.5, y = 0.5 } },
    { entity_number = 2, name = "iron-chest", position = { x = 0.5, y = 0.5 } },
  } }
end

local function bp(args)
  args.blob = args.blob or "bp1"
  args.anchor = args.anchor or ANCHOR
  return F.job("build_blueprint", args)
end

local function put(spec, id)
  F.blueprints["BPSTR"] = spec
  F.blob(id or "bp1", "BPSTR")
end

S.suite("build_blueprint", {
  { "dry_run: только проверки — {ghosts, skipped, missing}, призраков нет, инвентарь уничтожен", function()
      local W = F.setup{ items = { ["iron-chest"] = 1 } }
      put(two_chests())
      local d, kind = F.wait(bp{ dry_run = true })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { ghosts = 2, skipped = {}, skipped_total = 0, missing = { ["iron-chest"] = 1 } })
      S.eq(#F.ghosts(), 0)
      S.eq(#F.bp_calls, 0, "build_blueprint не вызывался")
      S.eq({ F.bp_created, F.bp_destroyed }, { 1, 1 })
      S.eq(#W.path.calls, 0)
      local n = 0
      for _, c in ipairs(F.checks) do
        S.eq(c.kind, "manual_ghost")
        S.eq(c.force, W.h.force)
        n = n + 1
      end
      S.eq(n, 2)
      S.eq(F.checks[1].pos, { x = 19.5, y = 0.5 })
      S.eq(F.checks[2].pos, { x = 20.5, y = 0.5 })
      S.eq(storage.reservations.areas.h1, nil)
  end },
  { "ставит призраки (build_mode normal, центр = anchor) и строит их руками", function()
      local W = F.setup{ items = { ["iron-chest"] = 3 } }
      put(two_chests())
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, {
        ghosts = 2, skipped = {}, skipped_total = 0, built = 2, left = 0, blocked = {}, blocked_total = 0, missing = {},
      })
      S.eq(#F.bp_calls, 1)
      local p = F.bp_calls[1]
      S.eq(p.build_mode, defines.build_mode.normal)
      S.eq(p.skip_fog_of_war, false)
      S.eq(S.norm_pos(p.position), ANCHOR)
      S.eq(p.direction, 0)
      S.eq(p.force, W.h.force)
      S.eq(p.surface, W.h.surface)
      S.eq(p.raise_built, true)
      S.eq({ F.bp_created, F.bp_destroyed }, { 1, 1 })
      S.eq(#F.built("iron-chest", { x = 19.5, y = 0.5 }), 1)
      S.eq(#F.built("iron-chest", { x = 20.5, y = 0.5 }), 1)
      S.eq(#F.ghosts(), 0)
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      S.eq(F.imported, { "BPSTR" })
      S.eq(storage.reservations.areas.h1, nil)
  end },
  { "blob из нескольких частей склеивается", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      F.blueprints["0eNqABCDEFGHIJ"] = two_chests()
      F.blob("multi-1", "0eNqABCDEFGHIJ", 4)
      local d, kind = F.wait(bp{ blob = "multi-1", mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(F.imported, { "0eNqABCDEFGHIJ" })
      S.eq(d.detail.built, 2)
  end },
  { "занятое место: проверка manual_ghost → skipped; остальное строится", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      F.blocked[F.key({ x = 20.5, y = 0.5 })] = true
      local dry = F.wait(bp{ dry_run = true })
      S.eq(dry.detail.ghosts, 1)
      S.eq(dry.detail.skipped, { { name = "iron-chest", pos = { x = 20.5, y = 0.5 }, reason = "cannot_place" } })
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.built }, { 1, 1, 1 })
      S.eq(d.detail.skipped[1].reason, "cannot_place")
      S.eq(#F.ghosts(), 0)
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
  { "призрак встал, но ghost_revive = false — сразу убирается (дроны не зависнут), в skipped: blocked", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      F.blocked[F.key({ x = 20.5, y = 0.5 })] = { ghost_revive = true }
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.built, d.detail.blocked_total }, { 1, 1, 0 })
      S.eq(d.detail.skipped, { { name = "iron-chest", pos = { x = 20.5, y = 0.5 }, reason = "blocked" } })
      S.eq(#F.ghosts(), 0, "заблокированного призрака не осталось")
      S.eq(#F.built("iron-chest"), 1)
  end },
  { "не-normal качество в чертеже — призрак убирается, skipped: quality", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      local spec = two_chests()
      spec.entities[2].quality = "rare"
      put(spec)
      local dry = F.wait(bp{ dry_run = true })
      S.eq(dry.detail.skipped[1].reason, "quality")
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.built }, { 1, 1 })
      S.eq(d.detail.skipped[1].reason, "quality")
      S.eq(#F.ghosts(), 0)
  end },
  { "ничего не встало — cannot_place с detail", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      F.blocked[F.key({ x = 19.5, y = 0.5 })] = true
      F.blocked[F.key({ x = 20.5, y = 0.5 })] = true
      local d, kind = F.wait(bp{})
      S.eq({ kind, d.code }, { "job_failed", "cannot_place" })
      S.eq({ d.detail.ghosts, d.detail.skipped_total }, { 0, 2 })
      S.eq(F.bp_destroyed, 1)
  end },
  { "предметов нет — призраки стоят, задача no_items с missing", function()
      F.setup()
      put(two_chests())
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq({ d.detail.ghosts, d.detail.built, d.detail.left }, { 2, 0, 2 })
      S.eq(d.detail.missing, { ["iron-chest"] = 2 })
      S.eq(#F.ghosts(), 2)
  end },
  { "поворот чертежа: direction = 4 кладёт ряд вертикально и поворачивает сущности", function()
      F.setup()
      put({ entities = {
        { entity_number = 1, name = "transport-belt", position = { x = -0.5, y = 0.5 }, direction = 4 },
        { entity_number = 2, name = "transport-belt", position = { x = 0.5, y = 0.5 }, direction = 4 },
      } })
      local d = F.wait(bp{ dry_run = true, direction = 4, anchor = { x = 20.5, y = 5 } })
      S.eq(d.detail.ghosts, 2)
      S.eq({ F.checks[1].pos, F.checks[1].direction }, { { x = 20.5, y = 4.5 }, 8 })
      S.eq({ F.checks[2].pos, F.checks[2].direction }, { { x = 20.5, y = 5.5 }, 8 })
      -- и движок получает тот же поворот
      F.wait(bp{ direction = 4, anchor = { x = 20.5, y = 5 }, mode = "hand" })
      S.eq(F.bp_calls[1].direction, 4)
      local g = F.ghosts()
      S.eq(#g, 2)
      S.eq(g[1].direction, 8)
  end },
  { "большая постройка: чётный размер привязывается к границе клеток", function()
      F.setup()
      put({ entities = { { entity_number = 1, name = "stone-furnace", position = { x = 0, y = 0 } } } })
      local d = F.wait(bp{ dry_run = true, anchor = { x = 30.4, y = 7.6 } })
      S.eq(d.detail, { ghosts = 1, skipped = {}, skipped_total = 0, missing = { ["stone-furnace"] = 1 } })
      S.eq(F.checks[1].pos, { x = 30, y = 8 })
  end },
  { "движок поставил призраки со сдвигом на клетку — сверка всё равно сходится", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      F.bp_shift = { x = 0, y = 1 }
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.built, d.detail.left }, { 2, 0, 2, 0 })
      S.eq(#F.built("iron-chest", { x = 19.5, y = 1.5 }), 1)
  end },
  { "плитки чертежа не ставятся: tiles_skipped", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      local spec = two_chests()
      spec.tiles = { { name = "stone-path", position = { x = 0, y = 0 } }, { name = "stone-path", position = { x = 1, y = 0 } } }
      put(spec)
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.tiles_skipped, 2)
      S.eq(F.tile_ghosts, 0)
  end },
  { "плохой blob и не чертёж — bad_args, инвентарь уничтожается всегда", function()
      F.setup()
      -- blob не присылали
      S.eq(F.wait(bp{ blob = "nope" }).code, "bad_args")
      S.eq(F.bp_created, 0)
      -- пришла одна часть из двух
      S.okr(S.req("blob_put", { blob = "half", part = 1, total = 2, data = "BP" }))
      local d = F.wait(bp{ blob = "half" })
      S.eq(d.code, "bad_args")
      S.ok(d.text:find("1/2", 1, true), d.text)
      -- строка не импортируется
      F.blob("junk", "not-a-blueprint")
      S.eq(F.wait(bp{ blob = "junk" }).code, "bad_args")
      -- импорт с ошибками (-1) — тоже отказ
      F.blueprints["WARN"] = { entities = two_chests().entities, rc = -1 }
      F.blob("warn", "WARN")
      S.eq(F.wait(bp{ blob = "warn" }).code, "bad_args")
      -- книга чертежей / планировщик
      F.blueprints["BOOK"] = { kind = "blueprint-book", entities = two_chests().entities }
      F.blob("book", "BOOK")
      S.eq(F.wait(bp{ blob = "book" }).code, "bad_args")
      -- пустой чертёж
      F.blueprints["EMPTY"] = { entities = {} }
      F.blob("empty", "EMPTY")
      S.eq(F.wait(bp{ blob = "empty" }).code, "bad_args")
      S.eq(F.bp_created, 4)
      S.eq(F.bp_destroyed, 4, "временный инвентарь уничтожен и при ошибке")
      S.eq(#F.ghosts(), 0)
      S.eq(#F.bp_calls, 0)
  end },
  { "лимиты и схема: > 1000 сущностей, сторона > 128, direction, id blob", function()
      F.setup()
      local big = two_chests()
      big.count = 1001
      F.blueprints["BIG"] = big
      F.blob("big", "BIG")
      S.eq(F.wait(bp{ blob = "big" }).code, "limit")
      F.blueprints["WIDE"] = { entities = {
        { entity_number = 1, name = "iron-chest", position = { x = 0.5, y = 0.5 } },
        { entity_number = 2, name = "iron-chest", position = { x = 140.5, y = 0.5 } },
      } }
      F.blob("wide", "WIDE")
      S.eq(F.wait(bp{ blob = "wide" }).code, "limit")
      put(two_chests())
      S.eq(F.wait(bp{ direction = 2 }).code, "bad_args")
      S.err(C.act("build_blueprint", { blob = "bp1" }), "bad_args")
      S.err(C.act("build_blueprint", { anchor = ANCHOR }), "bad_args")
      S.err(C.act("build_blueprint", { blob = "BAD_ID", anchor = ANCHOR }), "bad_args")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, direction = 16 }), "limit")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, mode = "forced" }), "bad_args")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, build_mode = "forced" }), "bad_args")
      S.eq(#F.bp_calls, 0)
      S.eq(F.bp_created, F.bp_destroyed)
  end },
  { "неоткрытые чанки — not_charted; чужой резерв — reserved; призраков нет", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      S.eq(F.wait(bp{ anchor = { x = 100, y = 0.5 } }).code, "not_charted")
      storage.reservations.areas.h2 = { left_top = { x = 15, y = -5 }, right_bottom = { x = 25, y = 5 } }
      S.eq(F.wait(bp{}).code, "reserved")
      S.eq(F.wait(bp{ dry_run = true }).code, "reserved")
      S.eq(#F.ghosts(), 0)
      S.eq(#F.bp_calls, 0)
      S.eq(F.bp_created, F.bp_destroyed)
  end },
  { "неизвестная сущность в чертеже — skipped: unknown", function()
      F.setup()
      local spec = two_chests()
      spec.entities[2].name = "mod-removed-thing"
      put(spec)
      local d = F.wait(bp{ dry_run = true })
      S.eq(d.detail.ghosts, 1)
      S.eq(d.detail.skipped[1].reason, "unknown")
  end },
  { "robots: призраки чертежа строят личные дроны", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      F.give_robots(W.h, 2, 10)
      put(two_chests())
      local d, kind = F.wait(bp{ mode = "robots" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.built, F.robot_built, F.revive_calls }, { 2, 2, 2, 0 })
  end },
  { "область чертежа резервируется на время стройки; отмена снимает подход", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      local job = bp{ anchor = { x = 70, y = 0.5 }, mode = "hand" }
      F.run(3)
      local a = storage.reservations.areas.h1
      S.ok(a ~= nil and a.left_top.x < 69.5 and a.right_bottom.x > 70.5, S.dump(a))
      S.eq(#F.ghosts(), 2)
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(storage.reservations.areas.h1, nil)
      S.ok(W.path.cancels > 0)
      S.eq(W.h.walking_state.walking, false)
  end },
})
