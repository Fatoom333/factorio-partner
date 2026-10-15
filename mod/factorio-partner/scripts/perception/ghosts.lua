-- Операция `ghosts`: призраки своей силы в области. Контракт: docs/STATE.md «ghosts».
-- Призраки — статичное (открытые чанки). `blocked` — призраки, у которых проверка
-- `ghost_revive` = false (PROTOCOL §6.5): дроны над ними висят вечно, строить их нельзя.
-- `have.stock` — склады в радиусе 64 от центра (только видимые).
local C = require("scripts.perception.state").common
local stock = require("scripts.perception.stock")

local M = {}

M.MAX_RADIUS = 128
M.DEFAULT_RADIUS = 64
M.MAX_AREA_SIDE = 128
M.STOCK_RADIUS = 64
M.MAX_BLOCKED = 50
-- Потолок проверок can_place_entity за вызов: на поле из тысяч призраков лент каждая проверка
-- стоит времени тика. Остальные призраки не проверяются, ответ помечается blocked_partial=true.
M.MAX_BLOCK_CHECKS = 1000

-- Предмет для постройки призрака: первый из items_to_place_this.
local function place_item(ghost)
  local ok, list = pcall(function() return ghost.ghost_prototype.items_to_place_this end)
  if not ok or type(list) ~= "table" then return nil end
  local first = list[1]
  if type(first) == "table" and type(first.name) == "string" then
    return first.name, first.count or 1
  end
  if type(first) == "string" then return first, 1 end
  return nil
end
M.place_item = place_item

-- Запрошенные в призрак предметы (модули и т.п.): item_requests (2.0: [{name,count,quality}]).
local function requests(ghost, acc)
  local ok, list = pcall(function() return ghost.item_requests end)
  if not ok or type(list) ~= "table" then return end
  for k, v in pairs(list) do
    local name, count, quality
    if type(v) == "table" then name, count, quality = v.name, v.count, v.quality
    else name, count = k, v end
    if type(name) == "string" and type(count) == "number" and count > 0 and C.is_normal(quality) then
      acc[name] = (acc[name] or 0) + count
    end
  end
end

-- Проверка ghost_revive (PROTOCOL §6.5): true — призрак заблокирован.
function M.is_blocked(surface, ghost)
  return not surface.can_place_entity {
    name = ghost.ghost_name,
    position = ghost.position,
    direction = ghost.direction,
    force = ghost.force,
    build_check_type = defines.build_check_type.ghost_revive,
  }
end

local function ghosts_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { area = true, radius = true, center = true, near = true })
  if args.area ~= nil and args.radius ~= nil then C.bad("radius", "use either area or radius") end
  local area
  if args.area ~= nil then area = C.check_area(args.area, "area", M.MAX_AREA_SIDE) end
  local radius = C.check_num(args.radius, "radius", 1, M.MAX_RADIUS, M.DEFAULT_RADIUS)

  local resolve_args = { center = args.center, near = args.near }
  if area and args.center == nil and args.near == nil then
    resolve_args.center = {
      x = (area.left_top.x + area.right_bottom.x) / 2,
      y = (area.left_top.y + area.right_bottom.y) / 2,
    }
  end
  local where = C.resolve(resolve_args, ctx)
  local surface, force, center = where.surface, where.force, where.center
  local view = C.chunk_view(force, surface)

  -- Призраки построек и призраки плиток (подложка, бетон): плитки идут в `need` и в `tiles`,
  -- но не в `count`/`by_name` (STATE.md «ghosts»).
  local filter = { force = force, type = { "entity-ghost", "tile-ghost" } }
  if area then
    filter.area = { area.left_top, area.right_bottom }
  else
    filter.position = center
    filter.radius = radius
    area = {
      left_top = { x = center.x - radius, y = center.y - radius },
      right_bottom = { x = center.x + radius, y = center.y + radius },
    }
  end
  local found = surface.find_entities_filtered(filter)

  local count, by_name, need, blocked, blocked_total, checks = 0, {}, {}, {}, 0, 0
  local tiles = 0
  for _, g in ipairs(found) do
    if g.valid and g.type == "tile-ghost" then
      if view.charted(g.position) then
        tiles = tiles + 1
        local item, n = place_item(g)
        if item then need[item] = (need[item] or 0) + n end
      end
    elseif g.valid and view.charted(g.position) then
      count = count + 1
      local gname = g.ghost_name
      by_name[gname] = (by_name[gname] or 0) + 1
      local item, n = place_item(g)
      if item then need[item] = (need[item] or 0) + n end
      requests(g, need)
      checks = checks + 1
      if checks <= M.MAX_BLOCK_CHECKS and M.is_blocked(surface, g) then
        blocked_total = blocked_total + 1
        if #blocked < M.MAX_BLOCKED then
          blocked[#blocked + 1] = { name = gname, pos = C.rpos(g.position) }
        end
      end
    end
  end

  -- Что есть: инвентарь помощника и склады рядом (видимые).
  local have_helper, have_stock = {}, {}
  if next(need) ~= nil then
    local e = where.entity
    if e then
      have_helper = C.inv_counts(e.get_inventory(defines.inventory.character_main), need)
    end
    have_stock = stock.scan(surface, force, center, M.STOCK_RADIUS, need, where.helper_id).total
  end
  local missing = {}
  for name, n in pairs(need) do
    local left = n - (have_helper[name] or 0) - (have_stock[name] or 0)
    if left > 0 then missing[name] = left end
  end

  return {
    count = count,
    tiles = tiles,
    by_name = by_name,
    need = need,
    have = { helper = have_helper, stock = have_stock },
    missing = missing,
    blocked = blocked,
    blocked_total = blocked_total,
    blocked_partial = checks > M.MAX_BLOCK_CHECKS,
    area = { left_top = C.rpos(area.left_top), right_bottom = C.rpos(area.right_bottom) },
  }
end

M.ops = {
  ghosts = ghosts_op,
}

return M
