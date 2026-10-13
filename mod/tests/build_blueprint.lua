-- Действие build_blueprint (поток F): ACTIONS.md «build_blueprint» — blob → create_inventory →
-- import_stack → проверки manual_ghost → build_blueprint{build_mode по args.force} → призраки построек
-- и плиток, пометки к сносу → снос помеченного → плитки → постройки.
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
      S.eq(d.detail, { ghosts = 2, skipped = {}, skipped_total = 0, missing = { ["iron-chest"] = 1 },
        tiles = 0, tiles_skipped = 0, on_liquid = 0, to_remove = {}, to_remove_total = 0 })
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
  { "ставит призраки (по умолчанию build_mode forced, центр = anchor) и строит их руками", function()
      local W = F.setup{ items = { ["iron-chest"] = 3 } }
      put(two_chests())
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, {
        ghosts = 2, skipped = {}, skipped_total = 0, built = 2, left = 0, blocked = {}, blocked_total = 0, missing = {},
        tiles = 0, tiles_skipped = 0, on_liquid = 0, to_remove = {}, to_remove_total = 0,
        tiles_built = 0, removed = 0, not_removed = 0,
      })
      S.eq(#F.bp_calls, 1)
      local p = F.bp_calls[1]
      S.eq(p.build_mode, defines.build_mode.forced)
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
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.missing }, { 1, 0, { ["stone-furnace"] = 1 } })
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
  { "плитки чертежа ставятся призраками и строятся раньше построек", function()
      local W = F.setup{ items = { ["iron-chest"] = 2, ["stone-brick"] = 5 } }
      local spec = two_chests()
      spec.tiles = { { name = "stone-path", position = { x = -1, y = 0 } }, { name = "stone-path", position = { x = 0, y = 0 } } }
      put(spec)
      local dry = F.wait(bp{ dry_run = true })
      S.eq({ dry.detail.ghosts, dry.detail.tiles, dry.detail.tiles_skipped, dry.detail.missing },
        { 2, 2, 0, {} })
      S.eq(#F.tile_ghosts_left(), 0, "dry_run плиток не ставит")
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.tiles, d.detail.tiles_skipped, d.detail.on_liquid }, { 2, 2, 0, 0 })
      S.eq({ d.detail.built, d.detail.left, d.detail.tiles_built, d.detail.tiles_first }, { 4, 0, 2, true })
      S.eq(F.tile_ghosts, 2)
      S.eq({ F.tile_at(19, 0), F.tile_at(20, 0) }, { "stone-path", "stone-path" })
      S.eq(#F.tile_ghosts_left(), 0)
      S.eq(#F.built("iron-chest"), 2)
      S.eq(C.counts(W.main), { ["stone-brick"] = 3 })
      -- порядок по журналу «движка»: обе плитки раньше первой постройки
      local last_tile, first_entity = 0, math.huge
      for _, t in ipairs(F.tile_log) do last_tile = math.max(last_tile, t.tick) end
      for _, e in ipairs(F.revive_log) do first_entity = math.min(first_entity, e.tick) end
      S.ok(last_tile < first_entity, "плитки построены раньше построек")
  end },
  { "плитка, которую сюда положить нельзя или которая уже лежит: tiles_skipped и «уже есть» (partial)", function()
      F.setup{ items = { ["iron-chest"] = 2, ["stone-brick"] = 5 } }
      local spec = two_chests()
      spec.tiles = {
        { name = "stone-path", position = { x = -1, y = 0 } },
        { name = "stone-path", position = { x = 0, y = 0 } },
        { name = "stone-path", position = { x = 1, y = 0 } },
      }
      put(spec)
      -- рамка x −1..2 → центр 0.5; anchor 20.5 → клетки 19, 20, 21
      F.set_tile(19, 0, "stone-path")   -- уже лежит
      F.set_tile(21, 0, "water")        -- дорожку на воду не кладут
      local a = { x = 20.5, y = 0.5 }
      -- дорожка на воде — клетка без опоры: без partial чертёж не ставится вовсе
      local refused, rk = F.wait(bp{ mode = "hand", anchor = a, search = 0 })
      S.eq({ rk, refused.code, refused.detail.on_liquid, refused.detail.liquids }, { "job_failed", "cannot_place", 1, { water = 1 } })
      S.eq({ #F.bp_calls, #F.tile_ghosts_left() }, { 0, 0 })
      local dry = F.wait(bp{ dry_run = true, anchor = a, partial = true })
      S.eq({ dry.detail.tiles, dry.detail.tiles_skipped, dry.detail.on_liquid }, { 1, 1, 1 })
      S.eq(dry.detail.skipped, { { name = "stone-path", pos = { x = 21.5, y = 0.5 }, reason = "liquid" } })
      local d, kind = F.wait(bp{ mode = "hand", anchor = a, partial = true })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.tiles, d.detail.tiles_skipped, d.detail.tiles_built }, { 1, 1, 1 })
      S.eq({ d.detail.on_liquid, d.detail.liquids }, { 1, { water = 1 } })
      S.eq({ F.tile_at(20, 0), F.tile_at(21, 0) }, { "stone-path", "water" })
  end },
  { "отсыпка в чертеже: на воду кладётся (и постройка встаёт на неё), на лаву — нет (tile_condition)", function()
      local W = F.setup{ items = { ["iron-chest"] = 2, landfill = 2 } }
      put({ entities = { { entity_number = 1, name = "iron-chest", position = { x = 0.5, y = 0.5 } } },
        tiles = { { name = "landfill", position = { x = 0, y = 0 } } } })
      -- лава: ни плитки, ни постройки
      F.set_tile(30, 0, "lava")
      local lava = { x = 30.5, y = 0.5 }
      local dry, dk = F.wait(bp{ dry_run = true, anchor = lava })
      S.eq(dk, "job_done", "dry_run отдаёт то же без ошибки")
      S.eq({ dry.detail.ghosts, dry.detail.tiles, dry.detail.tiles_skipped }, { 0, 0, 1 })
      -- клетка одна (плитка чертежа и сундук над ней — одна и та же); отсыпка ложится только на
      -- воду, воды рядом нет — сдвига, при котором чертёж встаёт целиком, не существует
      S.eq({ dry.detail.on_liquid, dry.detail.liquids, dry.detail.fit }, { 1, { lava = 1 }, nil })
      local d, kind = F.wait(bp{ mode = "hand", anchor = lava })
      S.eq({ kind, d.code }, { "job_failed", "cannot_place" })
      S.eq({ d.detail.ghosts, d.detail.tiles, d.detail.tiles_skipped }, { 0, 0, 1 })
      S.eq({ d.detail.on_liquid, d.detail.liquids, d.detail.fit }, { 1, { lava = 1 }, nil })
      S.eq({ #F.bp_calls, #F.ghosts(), #F.tile_ghosts_left() }, { 0, 0, 0 })
      S.eq(F.tile_at(30, 0), "lava")
      -- вода: плитка чертежа, потом постройка на ней
      F.set_tile(20, 0, "water")
      local water = { x = 20.5, y = 0.5 }
      local dry2 = F.wait(bp{ dry_run = true, anchor = water })
      S.eq({ dry2.detail.ghosts, dry2.detail.tiles, dry2.detail.tiles_skipped, dry2.detail.on_liquid }, { 1, 1, 0, 0 })
      local d2, kind2 = F.wait(bp{ mode = "hand", anchor = water })
      S.eq(kind2, "job_done", S.dump(d2))
      S.eq({ d2.detail.built, d2.detail.tiles_built, d2.detail.tiles_first }, { 2, 1, true })
      S.eq(F.tile_at(20, 0), "landfill")
      S.eq(C.counts(W.main), { ["iron-chest"] = 1, landfill = 1 })
  end },
  { "чертёж из одних плиток строится; пустой чертёж — bad_args", function()
      local W = F.setup{ items = { ["stone-brick"] = 3 } }
      put({ entities = {}, tiles = {
        { name = "stone-path", position = { x = 0, y = 0 } }, { name = "stone-path", position = { x = 1, y = 0 } },
      } })
      local d, kind = F.wait(bp{ mode = "hand", anchor = { x = 20, y = 0.5 } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.tiles, d.detail.built, d.detail.tiles_built }, { 0, 2, 2, 2 })
      S.eq({ F.tile_at(19, 0), F.tile_at(20, 0) }, { "stone-path", "stone-path" })
      S.eq(C.counts(W.main), { ["stone-brick"] = 1 })
  end },
  { "force normal: дерево и своя постройка на месте — skipped, ничего не помечено", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 19.5, y = 0.5 }, force = "neutral" }
      local mine = C.chest({ x = 20.5, y = 0.5 }, {}, { name = "wooden-chest" })
      local dry = F.wait(bp{ dry_run = true, force = "normal" })
      S.eq({ dry.detail.ghosts, dry.detail.skipped_total, dry.detail.to_remove_total }, { 0, 2, 0 })
      local d, kind = F.wait(bp{ mode = "hand", force = "normal" })
      S.eq({ kind, d.code }, { "job_failed", "cannot_place" })
      S.eq(F.bp_calls[1].build_mode, defines.build_mode.normal)
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.to_remove_total }, { 0, 2, 0 })
      S.eq({ rawget(tree, "_marked"), rawget(mine, "_marked") }, { nil, nil })
      S.ok(tree.valid and mine.valid)
  end },
  { "force forced (по умолчанию): дерево помечается и разбирается перед стройкой; свою постройку не трогает", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 19.5, y = 0.5 }, force = "neutral" }
      local mine = C.chest({ x = 20.5, y = 0.5 }, {}, { name = "wooden-chest" })
      local dry = F.wait(bp{ dry_run = true })
      S.eq({ dry.detail.ghosts, dry.detail.skipped_total }, { 1, 1 })
      S.eq(dry.detail.to_remove, { { name = "tree-01", pos = { x = 19.5, y = 0.5 } } })
      S.eq(dry.detail.to_remove_total, 1)
      S.eq(rawget(tree, "_marked"), nil, "dry_run ничего не помечает")
      F.reach_only_openable = true   -- как в игре: до дерева can_reach_entity = false
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.built, d.detail.removed }, { 1, 1, 1, 1 })
      S.eq(d.detail.to_remove, { { name = "tree-01", pos = { x = 19.5, y = 0.5 } } })
      S.eq(d.detail.skipped[1].pos, { x = 20.5, y = 0.5 })
      S.eq({ tree.valid, mine.valid }, { false, true })
      S.eq(#F.built("iron-chest", { x = 19.5, y = 0.5 }), 1)
      S.eq(C.mined, 1, "дерево срублено движком (selected + mining_state)")
      S.eq(C.counts(W.main), { ["iron-chest"] = 1, wood = 4 })
  end },
  { "force superforced: помечает и свою постройку; to_remove в dry_run и в итоге", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 19.5, y = 0.5 }, force = "neutral" }
      local mine = C.chest({ x = 20.5, y = 0.5 }, {}, { name = "wooden-chest" })
      local enemy = C.chest({ x = 30.5, y = 0.5 }, {}, { force = "enemy" })
      local dry = F.wait(bp{ dry_run = true, force = "superforced" })
      S.eq({ dry.detail.ghosts, dry.detail.skipped_total, dry.detail.to_remove_total }, { 2, 0, 2 })
      local names = { dry.detail.to_remove[1].name, dry.detail.to_remove[2].name }
      table.sort(names)
      S.eq(names, { "tree-01", "wooden-chest" })
      S.ok(tree.valid and mine.valid and rawget(mine, "_marked") == nil)
      local d, kind = F.wait(bp{ mode = "hand", force = "superforced" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(F.bp_calls[1].build_mode, defines.build_mode.superforced)
      S.eq({ d.detail.ghosts, d.detail.built, d.detail.removed, d.detail.to_remove_total }, { 2, 2, 2, 2 })
      S.eq({ tree.valid, mine.valid, enemy.valid }, { false, false, true })
      S.eq(#F.built("iron-chest"), 3, "два новых и чужой, которого не тронули")
      S.eq(C.counts(W.main), { wood = 4, ["wooden-chest"] = 1 })
  end },
  { "superforced поверх чужой постройки: не помечает, skipped", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      local enemy = C.chest({ x = 20.5, y = 0.5 }, {}, { force = "enemy" })
      local dry = F.wait(bp{ dry_run = true, force = "superforced" })
      S.eq({ dry.detail.ghosts, dry.detail.skipped_total, dry.detail.to_remove_total }, { 1, 1, 0 })
      local d = F.wait(bp{ mode = "hand", force = "superforced" })
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.built, d.detail.to_remove_total }, { 1, 1, 1, 0 })
      S.ok(enemy.valid and rawget(enemy, "_marked") == nil)
  end },
  { "forced на воде: под постройкой встаёт призрак отсыпки; плитка строится первой, потом постройка", function()
      local W = F.setup{ items = { ["iron-chest"] = 2, landfill = 1 } }
      put(two_chests())
      F.set_tile(20, 0, "water")
      local normal = F.wait(bp{ dry_run = true, force = "normal" })
      -- normal подложку не ставит: клетка — обычный пропуск с причиной liquid, чертёж не отменяется
      S.eq({ normal.detail.ghosts, normal.detail.skipped_total, normal.detail.tiles }, { 1, 1, 0 })
      S.eq({ normal.detail.skipped[1].reason, normal.detail.on_liquid, normal.detail.liquids, normal.detail.fit },
        { "liquid", 1, { water = 1 }, nil })
      local dry = F.wait(bp{ dry_run = true })
      S.eq({ dry.detail.ghosts, dry.detail.skipped_total, dry.detail.tiles, dry.detail.missing },
        { 2, 0, 1, {} })
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.tiles, d.detail.on_liquid }, { 2, 0, 1, 0 })
      S.eq({ d.detail.built, d.detail.tiles_built, d.detail.tiles_first, d.detail.blocked_total }, { 3, 1, true, 0 })
      S.eq(F.tile_at(20, 0), "landfill")
      S.eq(#F.built("iron-chest"), 2)
      S.eq(C.counts(W.main), {})
  end },
  { "подложка невозможна (рецепт закрыт, предмета нет): чертёж не ставится вовсе — cannot_place, on_liquid, liquids, fit", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      F.set_tile(20, 0, "water")
      game.forces.player.recipes["landfill"].enabled = false
      local dry, dk = F.wait(bp{ dry_run = true })
      S.eq(dk, "job_done", S.dump(dry))
      S.eq({ dry.detail.ghosts, dry.detail.skipped_total, dry.detail.tiles }, { 1, 1, 0 })
      S.eq(dry.detail.skipped, { { name = "iron-chest", pos = { x = 20.5, y = 0.5 }, reason = "liquid" } })
      S.eq({ dry.detail.on_liquid, dry.detail.liquids }, { 1, { water = 1 } })
      S.eq(dry.detail.fit, { anchor = { x = 20, y = -0.5 }, shift = { dx = 0, dy = -1 } })
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "cannot_place" })
      S.eq({ d.detail.on_liquid, d.detail.liquids, d.detail.fit },
        { 1, { water = 1 }, { anchor = { x = 20, y = -0.5 }, shift = { dx = 0, dy = -1 } } })
      S.eq({ #F.bp_calls, #F.ghosts(), #F.tile_ghosts_left() }, { 0, 0, 0 })
      S.eq(storage.reservations.areas.h1, nil)
      S.eq(C.counts(W.main), { ["iron-chest"] = 2 })
      S.eq(F.tile_at(20, 0), "water")
  end },
  { "подложка доступна по предмету у помощника или на складах (рецепт закрыт) — оценка считает её возможной", function()
      F.setup{ items = { ["iron-chest"] = 2, landfill = 1 } }
      put(two_chests())
      F.set_tile(20, 0, "water")
      game.forces.player.recipes["landfill"].enabled = false
      local dry = F.wait(bp{ dry_run = true })
      S.eq({ dry.detail.ghosts, dry.detail.tiles, dry.detail.on_liquid, dry.detail.missing }, { 2, 1, 0, {} })
      -- на складах силы (логистическая сеть), у помощника отсыпки нет
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      F.set_tile(20, 0, "water")
      game.forces.player.recipes["landfill"].enabled = false
      local asked = {}
      game.forces.player.logistic_networks = { nauvis = { { valid = true, get_item_count = function(it)
        asked[#asked + 1] = it
        return it.name == "landfill" and 5 or 0
      end } } }
      local dry2 = F.wait(bp{ dry_run = true })
      S.eq({ dry2.detail.ghosts, dry2.detail.tiles, dry2.detail.on_liquid, dry2.detail.missing }, { 2, 1, 0, { landfill = 1 } })
      S.eq(asked[1], { name = "landfill", quality = "normal" })
      game.forces.player.logistic_networks = nil
      S.eq(C.counts(W.main), { ["iron-chest"] = 2 })
  end },
  { "оценка обещала подложку, а движок её не поставил — откат: призраков и пометок нет, cannot_place с on_liquid", function()
      local W = F.setup{ items = { ["iron-chest"] = 2, landfill = 1 } }
      put(two_chests())
      F.set_tile(20, 0, "water")
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 19.5, y = 0.5 }, force = "neutral" }
      -- «движок» заглушки ставит подложку только при открытом рецепте; предмет у помощника есть
      game.forces.player.recipes["landfill"].enabled = false
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "cannot_place" })
      S.eq({ d.detail.ghosts, d.detail.on_liquid, d.detail.liquids }, { 0, 1, { water = 1 } })
      S.eq(d.detail.skipped, { { name = "iron-chest", pos = { x = 20.5, y = 0.5 }, reason = "liquid" } })
      S.eq(#F.bp_calls, 1)
      S.eq({ #F.ghosts(), #F.tile_ghosts_left() }, { 0, 0 })
      S.eq({ tree.valid, rawget(tree, "_marked"), #F.unmarked }, { true, false, 1 })
      S.eq(C.counts(W.main), { ["iron-chest"] = 2, landfill = 1 })
  end },
  { "forced на воде без отсыпки в инвентаре: призраки стоят (не blocked), no_items с missing", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      F.set_tile(20, 0, "water")
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq({ d.detail.ghosts, d.detail.built, d.detail.left, d.detail.blocked_total }, { 2, 1, 2, 0 })
      S.eq(d.detail.missing, { landfill = 1 })
      S.eq(#F.ghosts(), 1, "призрак над водой ждёт плитку, его не убрали")
      S.eq(#F.tile_ghosts_left(), 1)
  end },
  { "на лаве подложки нет: без partial — cannot_place с fit; по fit встаёт целиком; partial — обрезанный", function()
      local W = F.setup{ items = { ["iron-chest"] = 4 } }
      put(two_chests())
      F.set_tile(20, 0, "lava")
      local dry, dk = F.wait(bp{ dry_run = true })
      S.eq(dk, "job_done", S.dump(dry))
      S.eq({ dry.detail.ghosts, dry.detail.skipped_total, dry.detail.tiles }, { 1, 1, 0 })
      S.eq({ dry.detail.on_liquid, dry.detail.liquids }, { 1, { lava = 1 } })
      S.eq(dry.detail.fit, { anchor = { x = 20, y = -0.5 }, shift = { dx = 0, dy = -1 } })
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "cannot_place" })
      S.eq({ d.detail.on_liquid, d.detail.liquids, d.detail.fit.shift }, { 1, { lava = 1 }, { dx = 0, dy = -1 } })
      S.eq({ #F.bp_calls, #F.ghosts() }, { 0, 0 })
      -- поставить по fit: встаёт целиком
      local d2, k2 = F.wait(bp{ mode = "hand", anchor = d.detail.fit.anchor })
      S.eq(k2, "job_done", S.dump(d2))
      S.eq({ d2.detail.ghosts, d2.detail.skipped_total, d2.detail.built, d2.detail.on_liquid, d2.detail.liquids }, { 2, 0, 2, 0, nil })
      S.eq(#F.built("iron-chest", { x = 19.5, y = -0.5 }), 1)
      S.eq(#F.built("iron-chest", { x = 20.5, y = -0.5 }), 1)
      -- partial (с согласия хозяина): обрезанный чертёж, клетка — в skipped с reason liquid
      local d3, k3 = F.wait(bp{ mode = "hand", partial = true })
      S.eq(k3, "job_done", S.dump(d3))
      S.eq({ d3.detail.ghosts, d3.detail.skipped_total, d3.detail.built }, { 1, 1, 1 })
      S.eq(d3.detail.skipped, { { name = "iron-chest", pos = { x = 20.5, y = 0.5 }, reason = "liquid" } })
      S.eq({ d3.detail.on_liquid, d3.detail.liquids, d3.detail.fit }, { 1, { lava = 1 }, nil })
      S.eq(#F.built("iron-chest", { x = 19.5, y = 0.5 }), 1)
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
      S.eq(F.tile_at(20, 0), "lava")
  end },
  { "поиск сдвига: search = 0 — не искать; за пределами search — fit нет; границы аргумента", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      for x = 10, 30 do
        for y = -10, 10 do F.set_tile(x, y, "lava") end
      end
      local d0 = F.wait(bp{ dry_run = true, search = 0 })
      S.eq({ d0.detail.on_liquid, d0.detail.liquids, d0.detail.fit, d0.detail.fit_checked }, { 2, { lava = 2 }, nil, nil })
      -- суша начинается в 10 клетках по вертикали: search 4 не дотягивается, search 16 находит
      local d4 = F.wait(bp{ dry_run = true, search = 4 })
      S.eq({ d4.detail.fit, d4.detail.fit_checked }, { nil, 80 })
      local d16 = F.wait(bp{ dry_run = true })
      S.eq(d16.detail.fit, { anchor = { x = 20, y = -10.5 }, shift = { dx = 0, dy = -11 } })
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, search = 33 }), "limit")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, search = -1 }), "bad_args")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, search = 1.5 }), "bad_args")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, rotate = 1 }), "bad_args")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, partial = "yes" }), "bad_args")
  end },
  { "поиск сдвига идёт в несколько тиков, держит «пульс» и обрывается бюджетом (fit_limit)", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      for x = -20, 60 do
        for y = -40, 40 do F.set_tile(x, y, "lava") end
      end
      local A = require("scripts.actions.build_blueprint")
      local ops_tick, max_ops = A.FIT_OPS_TICK, A.FIT_MAX_OPS
      A.FIT_OPS_TICK = 120
      local job = bp{ dry_run = true, search = 8 }
      F.run(5)
      S.eq(C.result(job), nil, "за пять тиков поиск не кончился")
      local t = storage.jobs.by_helper.h1.active
      S.ok(t.fit ~= nil and t.fit.checked > 0 and t.progress_tick ~= nil, "идёт поиск, пульс стоит")
      -- сохранение и загрузка посреди поиска: в задаче только простые данные
      S.eq(S.dump(t.fit.src.entities[1]), S.dump({ name = "iron-chest", position = { x = -0.5, y = 0.5 }, direction = 0 }))
      local d = F.wait(job)
      S.eq({ d.detail.fit, d.detail.fit_checked, d.detail.fit_limit }, { nil, 288, nil })
      A.FIT_MAX_OPS = 500
      local d2 = F.wait(bp{ dry_run = true, search = 8 })
      S.eq({ d2.detail.fit, d2.detail.fit_limit }, { nil, true })
      S.ok(d2.detail.fit_checked < 288)
      A.FIT_OPS_TICK, A.FIT_MAX_OPS = ops_tick, max_ops
      -- отмена посреди поиска ничего не оставляет
      local job3 = bp{ search = 32 }
      F.run(2)
      S.okr(S.req("cancel", { job = job3 }, "h1"))
      S.eq({ C.result(job3).code, #F.ghosts(), #F.bp_calls }, { "cancelled", 0, 0 })
  end },
  { "rotate: без него сдвига нет, с ним — поворот; поставить по fit (direction) — встаёт целиком", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      -- суша — только столбик x = 20: ряд из двух сундуков не встаёт ни при каком сдвиге на клетку
      for x = 17, 22 do
        for y = -2, 2 do
          if x ~= 20 then F.set_tile(x, y, "lava") end
        end
      end
      local a = { x = 20, y = 0.5 }
      local d1 = F.wait(bp{ dry_run = true, anchor = a, search = 1 })
      S.eq({ d1.detail.on_liquid, d1.detail.fit }, { 1, nil })
      local d2 = F.wait(bp{ dry_run = true, anchor = a, search = 1, rotate = true })
      S.eq(d2.detail.fit, { anchor = { x = 20, y = 0.5 }, shift = { dx = 0, dy = 0 }, direction = 4, mirror = false })
      local d3, k3 = F.wait(bp{ mode = "hand", anchor = d2.detail.fit.anchor, direction = d2.detail.fit.direction })
      S.eq(k3, "job_done", S.dump(d3))
      S.eq({ d3.detail.ghosts, d3.detail.built, d3.detail.on_liquid }, { 2, 2, 0 })
      S.eq(#F.built("iron-chest", { x = 20.5, y = 0.5 }), 1)
      S.eq(#F.built("iron-chest", { x = 20.5, y = 1.5 }), 1)
      S.eq(C.counts(W.main), {})
  end },
  { "rotate перебирает и зеркало: чертёж буквой L встаёт только отражённым; mirror ставит его так", function()
      local W = F.setup{ items = { ["iron-chest"] = 3, ["transport-belt"] = 1 } }
      -- L из четырёх клеток: столбик из трёх сундуков и лента (на восток) справа от нижнего.
      -- Такую фигуру поворотами в её зеркальную не перевести.
      put({ entities = {
        { entity_number = 1, name = "iron-chest", position = { x = 0.5, y = 0.5 } },
        { entity_number = 2, name = "iron-chest", position = { x = 0.5, y = 1.5 } },
        { entity_number = 3, name = "iron-chest", position = { x = 0.5, y = 2.5 } },
        { entity_number = 4, name = "transport-belt", position = { x = 1.5, y = 2.5 }, direction = 4 },
      } })
      -- суша — зеркальная фигура: столбик (21,0..2) и клетка (20,2) слева от нижней; вокруг — лава
      for x = 14, 28 do
        for y = -6, 8 do F.set_tile(x, y, "lava") end
      end
      for _, c in ipairs({ { 21, 0 }, { 21, 1 }, { 21, 2 }, { 20, 2 } }) do F.set_tile(c[1], c[2], "grass-1") end
      local a = { x = 21, y = 1.5 }
      local plain = F.wait(bp{ dry_run = true, anchor = a, search = 2 })
      S.eq({ plain.detail.on_liquid, plain.detail.fit }, { 2, nil })
      local dry = F.wait(bp{ dry_run = true, anchor = a, search = 2, rotate = true })
      local fit = dry.detail.fit
      S.eq({ fit.shift, fit.direction, fit.mirror }, { { dx = 0, dy = 0 }, 0, true }, S.dump(fit))
      local d, kind = F.wait(bp{ mode = "hand", anchor = fit.anchor, direction = fit.direction, mirror = fit.mirror })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.built, d.detail.skipped_total }, { 4, 4, 0 })
      S.eq(F.bp_set_entities, 1, "чертёж отражён во временном стаке")
      for y = 0, 2 do S.eq(#F.built("iron-chest", { x = 21.5, y = y + 0.5 }), 1) end
      local belt = F.built("transport-belt", { x = 20.5, y = 2.5 })
      S.eq({ #belt, belt[1] and belt[1].direction }, { 1, 12 }, "лента смотрит на запад")
      S.eq(C.counts(W.main), {})
      -- рельсы зеркалом не ставим
      prototypes.entity["straight-rail"] = { name = "straight-rail", type = "straight-rail", tile_width = 2, tile_height = 2 }
      F.blueprints["RAIL"] = { entities = { { entity_number = 1, name = "straight-rail", position = { x = 1, y = 1 } } } }
      F.blob("rail", "RAIL")
      local r = F.wait(bp{ blob = "rail", mirror = true, dry_run = true })
      S.eq(r.code, "bad_args")
  end },
  { "плитка планеты из мода: имён в коде нет — подложка берётся из default_cover_tile", function()
      local W = F.setup{ items = { ["iron-chest"] = 2 } }
      local T, I = prototypes.tile, prototypes.item
      T["planks"] = { name = "planks", collision_mask = { layers = { ground_tile = true } },
        items_to_place_this = { { name = "planks", count = 1 } } }
      I["planks"] = { name = "planks", type = "item", stack_size = 100,
        place_as_tile_result = { result = T["planks"], condition_size = 1, condition = { layers = { ground_tile = true } } } }
      T["goo"] = { name = "goo", collision_mask = { layers = { water_tile = true, player = true } }, default_cover_tile = T["planks"] }
      T["tar"] = { name = "tar", collision_mask = { layers = { water_tile = true, player = true } },
        default_cover_tile = T["planks"], allows_being_covered = false }
      W.main.insert{ name = "planks", count = 1 }
      game.forces.player.recipes["planks"] = { name = "planks", enabled = true }
      put(two_chests())
      F.set_tile(20, 0, "goo")
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.ghosts, d.detail.tiles, d.detail.built, d.detail.tiles_built, d.detail.on_liquid }, { 2, 1, 3, 1, 0 })
      S.eq(F.tile_at(20, 0), "planks")
      -- плитка, которую игра накрывать не разрешает (allows_being_covered = false)
      F.set_tile(40, 0, "tar")
      local dry = F.wait(bp{ dry_run = true, anchor = { x = 40, y = 0.5 }, search = 0 })
      S.eq({ dry.detail.on_liquid, dry.detail.liquids }, { 1, { tar = 1 } })
  end },
  { "уже помеченное к сносу до чертежа в to_remove не попадает", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      local old = F.mark(S.nauvis.create_entity{ name = "tree-01", position = { x = 21.5, y = 1.5 }, force = "neutral" })
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.to_remove_total, d.detail.built, d.detail.removed }, { 0, 2, 0 })
      S.ok(old.valid, "помеченное, но не мешающее призракам, не трогается")
  end },
  { "свои пометки к сносу снимаются при отмене; чужие (поставленные до чертежа) остаются", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      -- рамка чертежа в anchor 70: сундуки в 69.5 и 70.5
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 69.5, y = 0.5 }, force = "neutral" }
      local rock = S.nauvis.create_entity{ name = "big-rock", position = { x = 70.5, y = 0.5 }, force = "neutral" }
      local old = F.mark(S.nauvis.create_entity{ name = "tree-01", position = { x = 71.5, y = 1.5 }, force = "neutral" })
      local job = bp{ anchor = { x = 70, y = 0.5 }, mode = "hand" }
      F.run(3)
      S.eq({ rawget(tree, "_marked"), rawget(rock, "_marked"), #F.ghosts() }, { true, true, 2 })
      S.okr(S.req("cancel", { job = job }, "h1"))
      S.eq(C.result(job).code, "cancelled")
      S.eq({ rawget(tree, "_marked"), rawget(rock, "_marked"), rawget(old, "_marked") }, { false, false, true })
      S.eq(#F.unmarked, 2)
      S.eq(F.unmarked[1].force, "player")
      S.ok(tree.valid and rock.valid and old.valid)
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "свои пометки снимаются при failed (no_items) и при stuck от ядра; при done их не остаётся", function()
      local W = F.setup()
      put(two_chests())
      local tree = S.nauvis.create_entity{ name = "tree-01", position = { x = 19.5, y = 0.5 }, force = "neutral" }
      C.mining_disabled = true   -- дерево не поддаётся: пометка доживает до конца задачи
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq({ d.detail.to_remove_total, d.detail.removed, d.detail.not_removed }, { 1, 0, 1 })
      S.eq({ tree.valid, rawget(tree, "_marked"), #F.unmarked }, { true, false, 1 })
      -- stuck от ядра (60 с без прогресса): тот же stop
      local jobs = require("scripts.core.jobs")
      for _, g in ipairs(F.ghosts()) do g.destroy() end
      W.main.insert{ name = "iron-chest", count = 2 }
      W.path.fail = nil
      local far2 = S.nauvis.create_entity{ name = "tree-01", position = { x = 90.5, y = 0.5 }, force = "neutral" }
      local job2 = bp{ anchor = { x = 91, y = 0.5 }, mode = "hand" }
      F.run(2)
      S.eq(rawget(far2, "_marked"), true)
      local q = storage.jobs.by_helper.h1
      S.eq(q.active.job, job2)
      jobs.fail_all("h1", "stuck", "no progress for 60 s", W.h)
      S.eq({ C.result(job2).code, rawget(far2, "_marked"), far2.valid }, { "stuck", false, true })
      -- тело погибло: stop зовётся без тела — пометки всё равно снимаются
      for _, g in ipairs(F.ghosts()) do g.destroy() end
      local far3 = S.nauvis.create_entity{ name = "tree-01", position = { x = 110.5, y = 0.5 }, force = "neutral" }
      local job3 = bp{ anchor = { x = 111, y = 0.5 }, mode = "hand" }
      F.run(2)
      S.eq(rawget(far3, "_marked"), true)
      jobs.fail_all("h1", "no_helper", "helper is absent or dead", nil)
      S.eq({ C.result(job3).code, rawget(far3, "_marked") }, { "no_helper", false })
  end },
  { "три длинных списка в detail урезаются, событие остаётся целым", function()
      F.setup()
      local ents = {}
      for i = 1, 40 do ents[i] = { entity_number = i, name = "iron-chest", position = { x = i - 0.5, y = 0.5 } } end
      put({ entities = ents })
      -- рамка x 0..40 → центр 20; anchor 40 → клетки 20.5 .. 59.5
      for i = 1, 15 do
        S.nauvis.create_entity{ name = "tree-01", position = { x = 19.5 + i, y = 0.5 }, force = "neutral" }
      end
      for i = 16, 30 do C.chest({ x = 19.5 + i, y = 0.5 }, {}, { name = "wooden-chest" }) end
      for i = 31, 40 do F.blocked[F.key({ x = 19.5 + i, y = 0.5 })] = { ghost_revive = true } end
      local d, kind = F.wait(bp{ mode = "hand", anchor = { x = 40, y = 0.5 } })
      S.eq({ kind, d.code }, { "job_failed", "no_items" })
      S.eq(d.truncated, nil, "событие не ужато ядром")
      S.eq({ d.detail.to_remove_total, d.detail.skipped_total }, { 15, 25 })
      S.eq({ #d.detail.to_remove, #d.detail.skipped }, { 10, 10 })
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
      -- импорт с предупреждениями (-1) — не провал: что импортировалось, то и раскладывается
      F.blueprints["WARN"] = { entities = two_chests().entities, rc = -1 }
      F.blob("warn", "WARN")
      local w, wk = F.wait(bp{ blob = "warn", dry_run = true })
      S.eq(wk, "job_done", S.dump(w))
      S.eq(w.detail.ghosts, 2)
      -- любой другой код — отказ
      F.blueprints["RC2"] = { entities = two_chests().entities, rc = 2 }
      F.blob("rc2", "RC2")
      S.eq(F.wait(bp{ blob = "rc2" }).code, "bad_args")
      -- книга чертежей / планировщик
      F.blueprints["BOOK"] = { kind = "blueprint-book", entities = two_chests().entities }
      F.blob("book", "BOOK")
      S.eq(F.wait(bp{ blob = "book" }).code, "bad_args")
      -- пустой чертёж
      F.blueprints["EMPTY"] = { entities = {} }
      F.blob("empty", "EMPTY")
      S.eq(F.wait(bp{ blob = "empty" }).code, "bad_args")
      S.eq(F.bp_created, 5)
      S.eq(F.bp_destroyed, 5, "временный инвентарь уничтожен и при ошибке")
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
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, force = "hyper" }), "bad_args")
      S.err(C.act("build_blueprint", { blob = "bp1", anchor = ANCHOR, force = true }), "bad_args")
      local many = two_chests()
      many.tiles = {}
      for i = 1, 4001 do many.tiles[i] = { name = "stone-path", position = { x = i % 100, y = math.floor(i / 100) } } end
      F.blueprints["TILES"] = many
      F.blob("tiles", "TILES")
      S.eq(F.wait(bp{ blob = "tiles" }).code, "limit")
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
  { "наложение на уже стоящий такой же призрак: чужой план не убирается, даже если он заблокирован", function()
      F.setup{ items = { ["iron-chest"] = 2 } }
      put(two_chests())
      local mine = F.ghost("iron-chest", { x = 20.5, y = 0.5 })   -- план хозяина, стоял до чертежа
      F.blocked[F.key({ x = 20.5, y = 0.5 })] = { ghost_revive = true }
      F.bp_return_existing = true
      local d, kind = F.wait(bp{ mode = "hand" })
      S.eq(kind, "job_done", S.dump(d))
      S.ok(mine.valid, "призрак хозяина на месте")
      S.eq({ d.detail.ghosts, d.detail.skipped_total, d.detail.built, d.detail.blocked_total }, { 1, 1, 1, 1 })
      S.eq(d.detail.skipped[1], { name = "iron-chest", pos = { x = 20.5, y = 0.5 }, reason = "blocked" })
      S.eq(#F.ghosts(), 1)
  end },
})
