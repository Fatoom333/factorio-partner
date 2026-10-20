-- Действие build_layout: ACTIONS.md «build_layout» — постройки по смещениям от клетки-якоря →
-- план в мире (поворот блока) → оценка → снабжение всего счёта → призраки временным чертежом
-- (forced) → стройка → рецепт и insert → память блока.
local S = require("stubs")
local C = require("stubs_c")
local F = require("stubs_f")
local K = require("stubs_k")

-- у подмены vis из stubs_f нет «глаз» viewer, которые нужны складам снабжения: всё видно
local pre_vis = package.preload["scripts.core.vis"]
package.preload["scripts.core.vis"] = function()
  local m = pre_vis()
  m.viewer = function() return function() return true end end
  return m
end

local A = { x = 20, y = 0 }

local function L() return require("scripts.actions.build_layout") end

--- Клетки блока до поворота → клетки в мире при повороте dir вокруг центра клетки якоря.
local function rotated_cells(cell, x0, y0, w, h, dir)
  local out = {}
  for x = x0, x0 + w - 1 do
    for y = y0, y0 + h - 1 do
      local rx, ry = x, y
      if dir == 4 then rx, ry = -y, x elseif dir == 8 then rx, ry = -x, -y elseif dir == 12 then rx, ry = y, -x end
      out[(cell.x + rx) .. "," .. (cell.y + ry)] = true
    end
  end
  return out
end

local SIZES = {
  { "iron-chest", 1, 1 }, { "stone-furnace", 2, 2 }, { "assembling-machine-1", 3, 3 }, { "test-2x3", 2, 3 },
}

S.suite("build_layout", {
  { "геометрия: dx/dy и cx/cy во всех поворотах — 1×1, 2×2, 3×3, 2×3 встают в расчётные клетки", function()
      K.setup()
      local M = L()
      local cell = { x = 20, y = 0 }
      for _, sz in ipairs(SIZES) do
        local name, w, h = sz[1], sz[2], sz[3]
        for _, own in ipairs({ 0, 4 }) do
          local ow, oh = w, h
          if own == 4 then ow, oh = h, w end
          for _, dir in ipairs({ 0, 4, 8, 12 }) do
            local by_cell = M.plan_at({ { name = name, dx = 2, dy = -3, direction = own } }, cell, dir)[1]
            local by_centre = M.plan_at({ { name = name, cx = 2 + ow / 2, cy = -3 + oh / 2, direction = own } }, cell, dir)[1]
            local tag = name .. " own " .. own .. " dir " .. dir
            S.eq(by_centre.pos, by_cell.pos, tag)
            S.eq(by_cell.dir, (own + dir) % 16, tag)
            S.eq(K.cells(name, by_cell.pos, by_cell.dir), rotated_cells(cell, 2, -3, ow, oh, dir), tag)
          end
        end
      end
      -- центр не на сетке привязывается к сетке по размеру постройки
      local p = M.plan_at({ { name = "assembling-machine-1", cx = 1.2, cy = 1.9 } }, cell, 0)[1]
      S.eq(p.pos, { x = 21.5, y = 1.5 })
  end },
  { "призраки временного чертежа встают ровно в расчётные клетки во всех поворотах", function()
      for _, dir in ipairs({ 0, 4, 8, 12 }) do
        local W = K.setup{ items = { ["iron-chest"] = 1, ["stone-furnace"] = 1, ["assembling-machine-1"] = 1, ["test-2x3"] = 1 } }
        local ents = {
          { name = "assembling-machine-1", dx = 0, dy = 0 },
          { name = "stone-furnace", dx = 3, dy = 0 },
          { name = "iron-chest", dx = 3, dy = 2, direction = 4 },
          { name = "test-2x3", dx = 5, dy = 0, direction = 4 },
        }
        local d, kind = F.wait(K.job{ anchor = { x = 20.7, y = 0.2 }, entities = ents, direction = dir, mode = "hand" })
        S.eq(kind, "job_done", "dir " .. dir .. " " .. S.dump(d))
        local plan = L().plan_at(ents, { x = 20, y = 0 }, dir)
        for i, it in ipairs(plan) do
          S.eq(#K.built(it.name, it.pos), 1, "dir " .. dir .. " " .. it.name .. " " .. S.dump(it.pos))
          S.eq(K.built(it.name, it.pos)[1].direction, it.dir, "dir " .. dir .. " " .. it.name)
          local x0, y0, w, h = L().cells_of(ents[i])
          S.eq(K.cells(it.name, it.pos, it.dir), rotated_cells({ x = 20, y = 0 }, x0, y0, w, h, dir), "клетки " .. it.name)
        end
        S.eq(K.bp_calls[1].direction, 0, "поворот — уже в самих сущностях чертежа")
        S.eq(K.bp_calls[1].build_mode, defines.build_mode.forced)
        S.eq({ K.inv_created, K.inv_destroyed }, { 1, 1 })
        S.eq(K.set_stack[1].name, "blueprint")
        S.eq({ d.detail.placed_total, d.detail.failed_total }, { 4, 0 })
        S.eq(d.detail.site, { anchor = { x = 20, y = 0 }, direction = dir, shift = { dx = 0, dy = 0 }, checked = 1 })
        S.eq(C.counts(W.main), {})
      end
  end },
  { "проверка аргументов: пересечение, пары dx/dy и cx/cy, имена, recipe, type, insert, рамка, порты", function()
      K.setup()
      local function act(args)
        args.anchor = args.anchor or A
        return C.act("build_layout", args)
      end
      local r = act{ entities = { { name = "stone-furnace", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 1 } } }
      S.err(r, "bad_args")
      S.ok(r.error.text:find("entities[2] overlaps entities[1]", 1, true), r.error.text)
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0, cx = 0.5, cy = 0.5 } } }, "bad_args")
      S.err(act{ entities = { { name = "iron-chest", dx = 0 } } }, "bad_args")
      S.err(act{ entities = { { name = "iron-chest" } } }, "bad_args")
      S.err(act{ entities = { { name = "no-such-thing", dx = 0, dy = 0 } } }, "bad_args")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0, recipe = "iron-gear-wheel" } } }, "bad_args")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0, type = "input" } } }, "bad_args")
      S.err(act{ entities = { { name = "iron-chest", dx = 65, dy = 0 } } }, "limit")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 64, dy = 0 } } }, "limit")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0,
        insert = { coal = 1, wood = 1, ["iron-plate"] = 1, ["copper-plate"] = 1, stone = 1 } } } }, "limit")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 } }, direction = 2 }, "bad_args")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 } }, search = 33 }, "limit")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 } }, on_resource = "iron-chest" }, "bad_args")
      S.err(act{ entities = {} }, "bad_args")
      S.err(act{}, "bad_args")
      local many = {}
      for i = 1, 101 do many[i] = { name = "iron-chest", dx = i % 10, dy = math.floor(i / 10) } end
      S.err(act{ entities = many }, "limit")
      local port = { id = "in", dx = 0, dy = 0, kind = "belt", io = "in" }
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 } }, ports = { port, port } }, "bad_args")
      local ports = {}
      for i = 1, 17 do ports[i] = { id = "p" .. i, dx = 0, dy = 0, kind = "belt", io = "in" } end
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 } }, ports = ports }, "limit")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 } }, tag = "Bad Tag" }, "bad_args")
      S.err(act{ entities = { { name = "iron-chest", dx = 0, dy = 0 } }, blob = "x1" }, "bad_args")
      -- закрытый рецепт — отказ на старте задачи
      game.forces.player.recipes["iron-gear-wheel"] = { name = "iron-gear-wheel", enabled = false, category = "crafting" }
      local d = F.wait(K.job{ anchor = A, entities = { { name = "assembling-machine-1", dx = 0, dy = 0, recipe = "iron-gear-wheel" } } })
      S.eq(d.code, "bad_args", S.dump(d))
      S.eq(#K.bp_calls, 0)
  end },
  { "dry_run: место, need, missing, порты в мире — без призраков и пометок", function()
      local W = K.setup{ items = { ["iron-chest"] = 1 } }
      local tree = S.nauvis.create_entity{ name = "tree-01", type = "tree", position = { x = 21.5, y = 0.5 }, force = "neutral" }
      local d, kind = F.wait(K.job{ anchor = A, direction = 4, dry_run = true,
        entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 0, dy = 1, insert = { coal = 5 } } },
        ports = { { id = "out", dx = 2, dy = 0, kind = "belt", io = "out", dir = 4, items = { "coal" } } } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.dry_run, true)
      S.eq(d.detail.site, { anchor = { x = 20, y = 0 }, direction = 4, shift = { dx = 0, dy = 0 }, checked = 1 })
      S.eq({ d.detail.placed, d.detail.failed }, { {}, {} })
      S.eq(d.detail.need, { ["iron-chest"] = 2, coal = 5 })
      S.eq(d.detail.missing, { ["iron-chest"] = 1, coal = 5 })
      -- клетка (2, 0) блока при повороте 4 — это (0, 2) от якоря; направление 4 + 4 = 8
      S.eq(d.detail.ports, { { id = "out", kind = "belt", io = "out", pos = { x = 20.5, y = 2.5 }, dir = 8, items = { "coal" } } })
      S.eq(d.detail.to_remove_total, 0, "дерево — не на месте построек при повороте")
      S.eq({ #K.bp_calls, #F.ghosts(), K.inv_created }, { 0, 0, 0 })
      S.eq(storage.reservations.areas.h1, nil)
      S.eq(rawget(tree, "_marked"), nil)
      local d0 = F.wait(K.job{ anchor = A, dry_run = true, entities = { { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq(d0.detail.to_remove, { { name = "tree-01", pos = { x = 21.5, y = 0.5 } } })
      S.eq(C.counts(W.main), { ["iron-chest"] = 1 })
  end },
  { "blob формы forge: порт с rate и пустой полосой проходит проверку", function()
      K.setup{ items = { ["iron-chest"] = 1 } }
      local text = helpers.table_to_json{
        entities = { { name = "iron-chest", cx = 0.5, cy = 0.5, direction = 0 } },
        ports = {
          { id = "in0", kind = "belt", io = "in", dx = 1, dy = 0, dir = 4, items = { "iron-plate", "" }, rate = 7.5 },
          { id = "out0", kind = "pipe", io = "out", dx = 0, dy = 1, dir = 8, fluid = "water", rate = 1200 },
        },
      }
      S.okr(S.req("blob_put", { blob = "forge-1", part = 1, total = 1, data = text }))
      local d, kind = F.wait(K.job{ anchor = A, dry_run = true, blob = "forge-1" })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.ports[1].items, { "iron-plate", "" })
      S.eq(d.detail.ports[2].fluid, "water")
  end },
  { "стройка: рецепт (запасной путь set_recipe), insert из карманов, камень помечен и разобран", function()
      local W = K.setup{ items = { ["assembling-machine-1"] = 1, ["stone-furnace"] = 1, coal = 10 } }
      S.nauvis.create_entity{ name = "big-rock", position = { x = 21.5, y = 1.5 }, force = "neutral" }
      local d, kind = F.wait(K.job{ anchor = A, mode = "hand", entities = {
        { name = "assembling-machine-1", dx = 0, dy = 0, recipe = "iron-gear-wheel" },
        { name = "stone-furnace", dx = 3, dy = 0, insert = { coal = 4 } },
      } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(K.bp_entities[1].recipe, "iron-gear-wheel", "рецепт уходит в чертёж")
      local am = K.built("assembling-machine-1", { x = 21.5, y = 1.5 })[1]
      S.eq(am.recipe_set, { recipe = "iron-gear-wheel", quality = "normal" })
      S.eq(K.set_recipe_calls, 1)
      S.eq(d.detail.placed[1], { i = 1, name = "assembling-machine-1", pos = { x = 21.5, y = 1.5 }, unit_number = am.unit_number })
      S.eq(d.detail.placed[2].inserted, { coal = 4 }, S.dump(d.detail))
      S.eq(d.detail.placed[2].left, nil)
      S.eq(d.detail.removed, 1, "камень разобран")
      S.eq(C.counts(W.main).coal, 6)
      -- призрак донёс рецепт — set_recipe не нужен
      K.setup{ items = { ["assembling-machine-1"] = 1 } }
      K.ghost_keeps_recipe = true
      local d2 = F.wait(K.job{ anchor = A, mode = "hand", entities = { { name = "assembling-machine-1", dx = 0, dy = 0, recipe = "iron-gear-wheel" } } })
      S.eq(d2.detail.placed_total, 1, S.dump(d2))
      S.eq(K.set_recipe_calls, 0)
      -- рецепт не встал — recipe_set:false, постройка остаётся
      K.setup{ items = { ["assembling-machine-1"] = 1 } }
      K.set_recipe_fails = true
      local d3 = F.wait(K.job{ anchor = A, mode = "hand", entities = { { name = "assembling-machine-1", dx = 0, dy = 0, recipe = "iron-gear-wheel" } } })
      S.eq(d3.detail.placed[1].recipe_set, false, S.dump(d3))
  end },
  { "underground-belt: type уходит в чертёж", function()
      K.setup{ items = { ["underground-belt"] = 2 } }
      local d, kind = F.wait(K.job{ anchor = A, mode = "hand", entities = {
        { name = "underground-belt", dx = 0, dy = 0, direction = 4, type = "input" },
        { name = "underground-belt", dx = 3, dy = 0, direction = 4, type = "output" },
      } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ K.bp_entities[1].type, K.bp_entities[2].type }, { "input", "output" })
  end },
  { "нет предметов без auto_supply — no_items до призраков: весь счёт сразу, ничего не поставлено", function()
      K.setup{ items = { ["iron-chest"] = 1 } }
      local d, kind = F.wait(K.job{ anchor = A, mode = "hand",
        entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq({ kind, d.code }, { "job_failed", "no_items" }, S.dump(d))
      S.eq(d.detail.missing, { ["iron-chest"] = 1 })
      S.eq({ #K.bp_calls, #F.ghosts(), d.detail.ghosts_removed }, { 0, 0, nil })
  end },
  { "auto_supply: весь счёт добывается до постановки призраков", function()
      local W = K.setup{ items = { ["iron-plate"] = 16 } }
      prototypes.item["iron-plate"].fuel_value = 0
      local job = K.job{ anchor = A, mode = "hand", auto_supply = true,
        entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } }
      local saw_supply = false
      for _ = 1, 4000 do
        F.run(1)
        local t = storage.jobs.by_helper.h1 and storage.jobs.by_helper.h1.active
        if t and t.supply ~= nil then
          saw_supply = true
          S.eq(#K.bp_calls, 0, "призраков нет, пока идёт снабжение")
          S.eq(t.progress.phase, "supply")
        end
        if C.result(job) then break end
      end
      local d, kind = C.result(job)
      S.eq(kind, "job_done", S.dump(d))
      S.ok(saw_supply, "снабжение было")
      S.eq(#K.bp_calls, 1)
      S.eq(#K.built("iron-chest"), 2)
      S.eq(C.counts(W.main), {})
      -- добыть нечем: no_items с detail.supply, ничего не поставлено
      K.setup()
      local d2 = F.wait(K.job{ anchor = A, auto_supply = true, entities = { { name = "iron-chest", dx = 0, dy = 0 } } })
      S.eq(d2.code, "no_items", S.dump(d2))
      S.ok(d2.detail.supply ~= nil, S.dump(d2))
      S.eq(#K.bp_calls, 0)
  end },
  { "отмена: свои пометки сняты, свои непостроенные призраки убраны; keep_ghosts — призраки остаются", function()
      for _, keep in ipairs({ false, true }) do
        K.setup{ items = { ["iron-chest"] = 3 } }
        F.ghost("iron-chest", { x = 23.5, y = 0.5 })   -- план хозяина рядом: его не трогаем
        local rock = S.nauvis.create_entity{ name = "big-rock", position = { x = 21.5, y = 0.5 }, force = "neutral" }
        F.robots_stalled = true
        F.give_robots(F.W.h, 2, 30)
        local job = K.job{ anchor = A, mode = "robots", keep_ghosts = keep,
          entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } }
        for _ = 1, 30 do F.run(1) end
        S.eq(#F.ghosts(), 3, "призраки блока стоят")
        S.eq(rawget(rock, "_marked"), true, "камень помечен")
        S.okr(S.req("cancel", { job = job }, "h1"))
        local d = C.result(job)
        S.eq(d.code, "cancelled")
        S.eq(rawget(rock, "_marked"), false, "пометка снята")
        S.eq(d.detail.unmarked, 1)
        if keep then
          S.eq(#F.ghosts(), 3)
          S.eq(d.detail.ghosts_removed, nil)
        else
          S.eq(#F.ghosts(), 1, "остался только призрак хозяина")
          S.eq(S.norm_pos(F.ghosts()[1].position), { x = 23.5, y = 0.5 })
          S.eq(d.detail.ghosts_removed, 2)
        end
      end
  end },
  { "коды failed[]: exists, cannot_place (occupied / foreign), no_item; места нет — оценка в исходном месте", function()
      K.setup{ items = { ["iron-chest"] = 2 } }
      S.nauvis.create_entity{ name = "iron-chest", position = { x = 20.5, y = 0.5 }, force = "player" }
      -- уже стоит такая же постройка — exists, блок ставится
      local d, kind = F.wait(K.job{ anchor = A, mode = "hand",
        entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.failed, { { i = 1, name = "iron-chest", pos = { x = 20.5, y = 0.5 }, code = "exists" } })
      S.eq(d.detail.placed_total, 1)
      -- повтор: всё уже стоит — done, ничего не ставится
      local again = F.wait(K.job{ anchor = A, mode = "hand",
        entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq({ again.detail.failed_total, again.detail.placed_total, #K.bp_calls }, { 2, 0, 1 }, S.dump(again))
      -- своя другая постройка и чужая сила — места нет: оценка в исходном месте
      K.setup{ items = { ["iron-chest"] = 2 } }
      S.nauvis.create_entity{ name = "wooden-chest", position = { x = 20.5, y = 0.5 }, force = "player" }
      S.nauvis.create_entity{ name = "iron-chest", position = { x = 21.5, y = 0.5 }, force = "enemy" }
      local f, fk = F.wait(K.job{ anchor = A, entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq({ fk, f.code }, { "job_failed", "cannot_place" }, S.dump(f))
      S.eq(f.detail.reason, "site_not_found")
      S.eq(f.detail.site_checked, 1)
      S.eq(f.detail.failed, {
        { i = 1, name = "iron-chest", pos = { x = 20.5, y = 0.5 }, code = "cannot_place", why = "occupied" },
        { i = 2, name = "iron-chest", pos = { x = 21.5, y = 0.5 }, code = "cannot_place", why = "foreign" },
      })
      S.eq(#K.bp_calls, 0)
      -- постройка без предмета — no_item, остальное ставится
      K.setup{ items = { ["iron-chest"] = 1 } }
      prototypes.entity["infinity-chest"].tile_width, prototypes.entity["infinity-chest"].tile_height = 1, 1
      local n, nk = F.wait(K.job{ anchor = A, mode = "hand",
        entities = { { name = "infinity-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq(nk, "job_done", S.dump(n))
      S.eq(n.detail.failed, { { i = 1, name = "infinity-chest", pos = { x = 20.5, y = 0.5 }, code = "no_item" } })
      S.eq(#K.bp_entities, 1, "в чертёж ушло только то, что встанет")
  end },
  { "призрак встал, но ghost_revive = false — убран, код blocked; движок ничего не поставил — cannot_place", function()
      K.setup{ items = { ["iron-chest"] = 2 } }
      F.blocked[F.key({ x = 21.5, y = 0.5 })] = { ghost_revive = true }
      local d, kind = F.wait(K.job{ anchor = A, mode = "hand",
        entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.failed, { { i = 2, name = "iron-chest", pos = { x = 21.5, y = 0.5 }, code = "blocked" } })
      S.eq(#F.ghosts(), 0)
      K.setup{ items = { ["iron-chest"] = 2 } }
      F.blocked[F.key({ x = 20.5, y = 0.5 })] = { blueprint_ghost = true }
      F.blocked[F.key({ x = 21.5, y = 0.5 })] = { blueprint_ghost = true }
      local f = F.wait(K.job{ anchor = A, entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 1, dy = 0 } } })
      S.eq(f.code, "cannot_place", S.dump(f))
      S.eq(f.detail.failed[1].why, "engine")
  end },
  { "движок поставил все призраки со сдвигом — они убираются и ставятся ещё раз с поправкой", function()
      local W = K.setup{ items = { ["iron-chest"] = 2 } }
      K.bp_shift = { x = 1, y = 0 }   -- движок систематически ставит на клетку правее
      local d, kind = F.wait(K.job{ anchor = A, mode = "hand",
        entities = { { name = "iron-chest", dx = 0, dy = 0 }, { name = "iron-chest", dx = 0, dy = 1 } } })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(#K.bp_calls, 2)
      S.near(S.norm_pos(K.bp_calls[2].position).x, S.norm_pos(K.bp_calls[1].position).x - 1, 1e-9)
      S.eq(#K.built("iron-chest", { x = 20.5, y = 0.5 }), 1)
      S.eq(#K.built("iron-chest", { x = 20.5, y = 1.5 }), 1)
      S.eq(#F.ghosts(), 0)
      S.eq(C.counts(W.main), {})
  end },
})
