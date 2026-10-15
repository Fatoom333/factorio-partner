-- Операция `resources`: пятна руды вокруг центра. Контракт: docs/STATE.md «resources».
-- Кластеризация по имени и соседству (8-связность), только открытые чанки,
-- не больше 20 пятен (ближайшие по центру пятна).
local C = require("scripts.perception.state").common

local M = {}

M.MAX_RADIUS = 128
M.DEFAULT_RADIUS = 64
M.MAX_PATCHES = 20
M.CLIP_RING = 2         -- на сколько клеток шире круга ищем, чтобы заметить обрезанное пятно

local floor = math.floor
local OFF = 1048576     -- 2^20: сдвиг координат в ключе
local MUL = 4194304     -- 2^22

local function key(x, y) return (x + OFF) * MUL + (y + OFF) end

-- Кластеры из списка клеток {x, y, amount, out?} одного имени → массив пятен.
-- Клетка с `out = true` лежит за кругом поиска: в `tiles`, `amount`, центр и область она не входит,
-- но связывает пятно и помечает его `clipped = true` (пятно обрезано кругом, числа — нижняя оценка).
-- Пятно целиком за кругом в ответ не попадает.
function M.cluster(cells)
  local by_key = {}
  for i, c in ipairs(cells) do by_key[key(c.x, c.y)] = i end
  local seen = {}
  local patches = {}
  for i in ipairs(cells) do
    if not seen[i] then
      seen[i] = true
      local stack = { i }
      local n, amount, sx, sy = 0, 0, 0, 0
      local minx, miny, maxx, maxy
      local clipped = false
      while #stack > 0 do
        local j = stack[#stack]
        stack[#stack] = nil
        local c = cells[j]
        if c.out then
          clipped = true
        else
          n = n + 1
          amount = amount + (c.amount or 0)
          sx, sy = sx + c.x, sy + c.y
          if minx == nil then minx, miny, maxx, maxy = c.x, c.y, c.x, c.y end
          if c.x < minx then minx = c.x end
          if c.y < miny then miny = c.y end
          if c.x > maxx then maxx = c.x end
          if c.y > maxy then maxy = c.y end
        end
        for dx = -1, 1 do
          for dy = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
              local k = by_key[key(c.x + dx, c.y + dy)]
              if k and not seen[k] then
                seen[k] = true
                stack[#stack + 1] = k
              end
            end
          end
        end
      end
      if n > 0 then
        patches[#patches + 1] = {
          tiles = n, amount = amount,
          center = { x = sx / n + 0.5, y = sy / n + 0.5 },
          area = { left_top = { x = minx, y = miny }, right_bottom = { x = maxx + 1, y = maxy + 1 } },
          clipped = clipped or nil,
        }
      end
    end
  end
  return patches
end

local function resources_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { center = true, near = true, radius = true, name = true })
  local radius = C.check_num(args.radius, "radius", 1, M.MAX_RADIUS, M.DEFAULT_RADIUS)
  local name = C.check_string(args.name, "name", 100)
  if name then
    -- Неизвестное имя в фильтре API — ошибка Lua; проверяем заранее.
    local proto = prototypes.entity[name]
    if not proto or proto.type ~= "resource" then C.bad("name", "unknown resource " .. name) end
  end
  local where = C.resolve(args, ctx)
  local surface, force, center = where.surface, where.force, where.center
  local view = C.chunk_view(force, surface)

  -- Ищем чуть шире круга: клетки в кольце CLIP_RING за ним в числа не входят, но показывают, что
  -- пятно продолжается за кругом (`clipped`).
  local filter = { position = center, radius = radius + M.CLIP_RING, type = "resource" }
  if name then filter.name = name end
  local found = surface.find_entities_filtered(filter)

  local r2 = radius * radius
  local by_name, order = {}, {}
  for _, e in ipairs(found) do
    if e.valid then
      local p = e.position
      if view.charted(p) then
        local n = e.name
        local list = by_name[n]
        if not list then list = {}; by_name[n] = list; order[#order + 1] = n end
        local dx, dy = p.x - center.x, p.y - center.y
        list[#list + 1] = {
          x = floor(p.x), y = floor(p.y), amount = e.amount or 0,
          out = (dx * dx + dy * dy > r2) or nil,
        }
      end
    end
  end

  local all = {}
  for _, n in ipairs(order) do
    for _, p in ipairs(M.cluster(by_name[n])) do
      p.name = n
      p.dist = C.dist(p.center, center)
      all[#all + 1] = p
    end
  end
  table.sort(all, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    return a.name < b.name
  end)

  local out = {}
  for i = 1, math.min(#all, M.MAX_PATCHES) do
    local p = all[i]
    out[i] = {
      name = p.name,
      center = C.rpos(p.center),
      area = p.area,
      tiles = p.tiles,
      amount = p.amount,
      dist = C.round(p.dist),
      clipped = p.clipped,
    }
  end
  return { patches = out, truncated = #all > #out }
end

M.ops = {
  resources = resources_op,
}

return M
