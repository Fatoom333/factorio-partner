-- Тесты операции `ghosts`. Контракт: docs/STATE.md «ghosts», PROTOCOL §6.5.
local G = require("stubs_g")

local function ghost(w, name, x, y, o)
  o = o or {}
  return w.surface.add(G.entity { name = "entity-ghost", type = "entity-ghost", ghost_name = name,
    pos = { x = x, y = y }, force = o.force or w.force, size = o.size or 1, direction = o.direction,
    place_item = o.item, item_requests = o.requests })
end

-- 1. Подсчёт, need/have/missing, blocked по ghost_revive
do
  local w = G.reset()
  local main = G.inventory({ ["transport-belt"] = 40, ["electric-mining-drill"] = 1 })
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 }, main = main })
  for i = 1, 4 do ghost(w, "electric-mining-drill", i * 3 + 0.5, 5.5, { size = 3 }) end
  for i = 1, 60 do ghost(w, "transport-belt", (i % 20) + 0.5, 10.5 + math.floor(i / 20)) end
  ghost(w, "assembling-machine-2", -5.5, -5.5, { size = 3, requests = { { name = "speed-module", count = 2, quality = "normal" } } })
  ghost(w, "stone-furnace", 1, 1, { force = w.enemy })   -- чужой
  w.surface.blocked["3.5:7.5"] = true
  ghost(w, "transport-belt", 3.5, 7.5)                   -- заблокирован
  w.surface.add(G.entity { name = "steel-chest", type = "container", pos = { x = 20.5, y = 20.5 }, force = w.force,
    inventory = G.inventory({ ["electric-mining-drill"] = 2, ["transport-belt"] = 500, coal = 50 }) })

  local M = require("scripts.perception.ghosts")
  local d = M.ops.ghosts({}, ctx)
  G.plain(d)
  G.eq(d.count, 66)
  G.eq(d.by_name, { ["electric-mining-drill"] = 4, ["transport-belt"] = 61, ["assembling-machine-2"] = 1 })
  G.eq(d.need, { ["electric-mining-drill"] = 4, ["transport-belt"] = 61, ["assembling-machine-2"] = 1, ["speed-module"] = 2 })
  G.eq(d.have.helper, { ["transport-belt"] = 40, ["electric-mining-drill"] = 1 })
  G.eq(d.have.stock, { ["electric-mining-drill"] = 2, ["transport-belt"] = 500 }, "stock only for needed items")
  G.eq(d.missing, { ["electric-mining-drill"] = 1, ["assembling-machine-2"] = 1, ["speed-module"] = 2 })
  G.eq(#d.blocked, 1)
  G.eq(d.blocked[1], { name = "transport-belt", pos = { x = 3.5, y = 7.5 } })
  G.eq(d.blocked_total, 1)
  G.eq(d.area, { left_top = { x = -64, y = -64 }, right_bottom = { x = 64, y = 64 } })
  -- проверка ghost_revive по имени внутренней сущности
  local seen = false
  for _, c in ipairs(w.surface.calls) do
    if c[1] == "can_place_entity" then
      seen = true
      G.eq(c[2].build_check_type, defines.build_check_type.ghost_revive)
      G.ok(c[2].name ~= "entity-ghost", "checks inner entity name")
      G.eq(c[2].force.name, "player")
    end
  end
  G.ok(seen, "can_place_entity called")
end

-- 2. area, неоткрытые чанки, лимит blocked
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  for i = 1, 60 do
    local x = i + 0.5
    w.surface.blocked[x .. ":0.5"] = true
    ghost(w, "transport-belt", x, 0.5)
  end
  ghost(w, "transport-belt", 70.5, 0.5)       -- вне area
  ghost(w, "transport-belt", 5.5, -40.5)      -- чанк (0,-2) не открыт
  w.force.set_charted(0, -2, false)
  local M = require("scripts.perception.ghosts")
  local d = M.ops.ghosts({ area = { left_top = { x = 0, y = -50 }, right_bottom = { x = 64, y = 10 } } }, ctx)
  G.eq(d.count, 60)
  G.eq(#d.blocked, M.MAX_BLOCKED)
  G.eq(d.blocked_total, 60)
  G.eq(d.blocked_partial, false)
  -- потолок проверок can_place_entity: дальше не проверяем, ответ помечен
  local cap = M.MAX_BLOCK_CHECKS
  M.MAX_BLOCK_CHECKS = 10
  local before = 0
  for _, c in ipairs(w.surface.calls) do if c[1] == "can_place_entity" then before = before + 1 end end
  local d2 = M.ops.ghosts({ area = { left_top = { x = 0, y = -50 }, right_bottom = { x = 64, y = 10 } } }, ctx)
  local after = 0
  for _, c in ipairs(w.surface.calls) do if c[1] == "can_place_entity" then after = after + 1 end end
  M.MAX_BLOCK_CHECKS = cap
  G.eq(after - before, 10, "can_place_entity capped")
  G.eq(d2.count, 60)
  G.eq(d2.blocked_total, 10)
  G.eq(d2.blocked_partial, true)
  G.eq(d.area, { left_top = { x = 0, y = -50 }, right_bottom = { x = 64, y = 10 } })
  G.eq(d.missing, { ["transport-belt"] = 60 })
end

-- 3. Пусто; ошибки
do
  local w = G.reset()
  local e, ctx = G.add_helper(w, "h1", { pos = { x = 0, y = 0 } })
  local M = require("scripts.perception.ghosts")
  local d = M.ops.ghosts({ radius = 10 }, ctx)
  G.plain(d)
  G.eq(d.count, 0)
  G.eq(d.need, {})
  G.eq(d.missing, {})
  G.eq(d.blocked, {})
  G.raises("bad_args", function() M.ops.ghosts({ radius = 10, area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 1, y = 1 } } }, ctx) end)
  G.raises("limit", function() M.ops.ghosts({ area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 300, y = 1 } } }, ctx) end)
  G.raises("limit", function() M.ops.ghosts({ radius = 129 }, ctx) end)
  G.raises("bad_args", function() M.ops.ghosts({ area = { left_top = { x = 0, y = 0 } } }, ctx) end)
end

-- 4. Без помощника: центр по area, have.helper пусто
do
  local w = G.reset()
  G.add_player(w, { name = "T", pos = { x = 0, y = 0 } })
  ghost(w, "stone-furnace", 50.5, 50.5, { size = 2 })
  local d = require("scripts.perception.ghosts").ops.ghosts(
    { area = { left_top = { x = 40, y = 40 }, right_bottom = { x = 60, y = 60 } } }, {})
  G.eq(d.count, 1)
  G.eq(d.have.helper, {})
  G.eq(d.missing, { ["stone-furnace"] = 1 })
end
