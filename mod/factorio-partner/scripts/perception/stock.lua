-- Операция `stock` (поток G): склады своей силы вокруг центра. Контракт: docs/STATE.md «stock».
-- Склады = контейнеры и логистические сундуки своей силы. Содержимое — только в видимых
-- чанках (PROTOCOL §6.7); невидимые считаются в `hidden`. Машины не считаются.
-- Предметы — только quality normal.
local C = require("scripts.perception.state").common

local M = {}

M.MAX_RADIUS = 128
M.DEFAULT_RADIUS = 64
M.DEFAULT_LIMIT = 50
M.MAX_LIMIT = 200
M.CONTAINER_TYPES = { "container", "logistic-container" }

-- Общий сбор складов (его же использует `ghosts`); helper_id — «глаза» помощника (core.vis).
-- → {containers = [{unit,name,pos,dist,items}] (по возрастанию dist, только с предметами),
--    total = {name=count}, hidden = int}
function M.scan(surface, force, center, radius, filter, helper_id)
  local view = C.chunk_view(force, surface, helper_id)
  local found = surface.find_entities_filtered {
    position = center, radius = radius, force = force, type = M.CONTAINER_TYPES,
  }
  local containers, total, hidden = {}, {}, 0
  for _, e in ipairs(found) do
    if e.valid then
      if not view.visible(e.position) then
        hidden = hidden + 1
      else
        local inv = e.get_inventory(defines.inventory.chest)
        local items = C.inv_counts(inv, filter)
        if next(items) ~= nil then
          C.add_counts(total, items)
          containers[#containers + 1] = {
            unit = e.unit_number,
            name = e.name,
            pos = C.rpos(e.position),
            dist = C.dist(e.position, center),
            items = items,
          }
        end
      end
    end
  end
  table.sort(containers, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    return (a.unit or 0) < (b.unit or 0)
  end)
  return { containers = containers, total = total, hidden = hidden }
end

local function stock_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { center = true, near = true, radius = true, items = true, limit = true })
  local radius = C.check_num(args.radius, "radius", 1, M.MAX_RADIUS, M.DEFAULT_RADIUS)
  local limit = C.check_int(args.limit, "limit", 1, M.MAX_LIMIT, M.DEFAULT_LIMIT)
  local filter = C.check_names(args.items, "items", 100)
  local where = C.resolve(args, ctx)

  local r = M.scan(where.surface, where.force, where.center, radius, filter, where.helper_id)
  local out = {}
  for i = 1, math.min(#r.containers, limit) do
    local c = r.containers[i]
    c.dist = C.round(c.dist)
    out[i] = c
  end
  return {
    containers = out,
    total = r.total,
    hidden = r.hidden,
    truncated = #r.containers > #out,
  }
end

M.ops = {
  stock = stock_op,
}

return M
