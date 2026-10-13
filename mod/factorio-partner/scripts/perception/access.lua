-- Операция `access` (поток V3, ревизия 3.3): суша, преграды и выходы с участка.
-- Контракт: docs/STATE.md «access», PROTOCOL.md §6.7 (только открытые чанки), §6.12 (свойства
-- мира — из игры: проходимость плитки и преграды считаются по маскам столкновений прототипов).
--
-- Расчёт — `M.compute(p)`: его же зовёт действие `plan_mining` для своих предупреждений.
--   p = {surface, force, area = {left_top, right_bottom}, from = pos|nil, body = LuaEntity|nil}
--   → {area, land, liquid, liquids, enclosed, exits, best?, reachable?, warnings, not_charted}
-- Рамка — area + 8 клеток (не больше 144×144 клеток): считается за один вызов, без размазывания
-- по тикам. Три заливки по 4 соседям: по проходимым клеткам и по маске, «усаженной» на 1 и на 2
-- клетки (клетка остаётся, если проходимы все клетки вокруг неё в квадрате 3×3 / 5×5) — так
-- находится самое узкое место по дороге от участка до выхода: коридор шириной 1–2 клетки не
-- переживает усадку на 1, шириной 3–4 — усадку на 2.
-- Только чтение: в игре и в storage ничего не меняет.
local err = require("scripts.core.err")
local C = require("scripts.perception.state").common
local T = require("scripts.perception.tiles")

local M = {}

M.MARGIN = 8            -- рамка = area + 8 клеток
M.MAX_SIDE = 128        -- сторона area
M.DEFAULT_RADIUS = 32
M.MAX_RADIUS = 64
M.MAX_EXITS = 8
M.MAX_LIQUIDS = 12      -- имён плиток в `liquids` (самые частые)

local floor, ceil = math.floor, math.ceil

-- Не преграды, хотя маска может пересекаться с телом: деревья (их сносят, STATE.md) и всё, что
-- движется или исчезает само. Это типы сущностей движка, не имена плиток или планет.
local NOT_OBSTACLE = {
  ["tree"] = true, ["character"] = true, ["unit"] = true, ["spider-unit"] = true,
  ["segmented-unit"] = true, ["segment"] = true, ["car"] = true, ["spider-vehicle"] = true,
  ["locomotive"] = true, ["cargo-wagon"] = true, ["fluid-wagon"] = true, ["artillery-wagon"] = true,
  ["infinity-cargo-wagon"] = true, ["construction-robot"] = true, ["logistic-robot"] = true,
  ["combat-robot"] = true, ["capture-robot"] = true, ["fish"] = true, ["entity-ghost"] = true,
  ["tile-ghost"] = true, ["resource"] = true, ["corpse"] = true, ["character-corpse"] = true,
  ["item-entity"] = true, ["gate"] = true, ["cargo-pod"] = true, ["asteroid"] = true,
}

local NECK_RANK = { wide = 3, medium = 2, narrow = 1 }
local SIDE_RANK = { north = 1, east = 2, south = 3, west = 4 }

-- Заливка по 4 соседям в сетке W×H: mask[i] — можно ли в клетку, seeds — список индексов.
local function flood(mask, W, H, seeds)
  local reached = {}
  local stack, n = {}, 0
  for _, i in ipairs(seeds) do
    if mask[i] and not reached[i] then
      reached[i] = true
      n = n + 1
      stack[n] = i
    end
  end
  local total = W * H
  while n > 0 do
    local i = stack[n]
    stack[n] = nil
    n = n - 1
    local col = (i - 1) % W
    local j
    if col > 0 then
      j = i - 1
      if mask[j] and not reached[j] then reached[j] = true; n = n + 1; stack[n] = j end
    end
    if col < W - 1 then
      j = i + 1
      if mask[j] and not reached[j] then reached[j] = true; n = n + 1; stack[n] = j end
    end
    j = i - W
    if j >= 1 and mask[j] and not reached[j] then reached[j] = true; n = n + 1; stack[n] = j end
    j = i + W
    if j <= total and mask[j] and not reached[j] then reached[j] = true; n = n + 1; stack[n] = j end
  end
  return reached
end

-- «Усадка» маски на одну клетку: клетка остаётся, если проходимы она и все 8 соседей.
-- За краем рамки — неизвестно, считаем проходимым (иначе любой выход на рамке «сужался» бы сам).
local function erode(mask, W, H)
  local out = {}
  for y = 0, H - 1 do
    for x = 0, W - 1 do
      local i = y * W + x + 1
      if mask[i] then
        local ok = true
        for dy = -1, 1 do
          local yy = y + dy
          if yy >= 0 and yy < H then
            for dx = -1, 1 do
              local xx = x + dx
              if xx >= 0 and xx < W and not mask[yy * W + xx + 1] then ok = false break end
            end
          end
          if not ok then break end
        end
        if ok then out[i] = true end
      end
    end
  end
  return out
end

M._internal = { flood = flood, erode = erode }

--- Расчёт суши и выходов. См. шапку файла.
function M.compute(p)
  local surface, force = p.surface, p.force
  local lt, rb = p.area.left_top, p.area.right_bottom
  local ax0, ay0 = floor(lt.x), floor(lt.y)
  local ax1, ay1 = ceil(rb.x) - 1, ceil(rb.y) - 1
  if ax1 < ax0 then ax1 = ax0 end
  if ay1 < ay0 then ay1 = ay0 end
  local fx0, fy0, fx1, fy1 = ax0 - M.MARGIN, ay0 - M.MARGIN, ax1 + M.MARGIN, ay1 + M.MARGIN
  local W, H = fx1 - fx0 + 1, fy1 - fy0 + 1

  local function idx(x, y) return (y - fy0) * W + (x - fx0) + 1 end
  local function inside(x, y) return x >= fx0 and x <= fx1 and y >= fy0 and y <= fy1 end
  local function in_area(x, y) return x >= ax0 and x <= ax1 and y >= ay0 and y <= ay1 end

  -- 1. Открытые чанки: неоткрытое — преграда.
  local pass, known = {}, {}
  local not_charted, area_known = 0, 0
  local chunk_cache = {}
  for y = fy0, fy1 do
    local cy = floor(y / 32)
    for x = fx0, fx1 do
      local cx = floor(x / 32)
      local key = cx * 4194304 + cy
      local ch = chunk_cache[key]
      if ch == nil then
        ch = force.is_chunk_charted(surface, { x = cx, y = cy }) and true or false
        chunk_cache[key] = ch
      end
      local i = idx(x, y)
      if ch then
        pass[i], known[i] = true, true
        if in_area(x, y) then area_known = area_known + 1 end
      else
        not_charted = not_charted + 1
      end
    end
  end

  -- 2. Плитки, по которым тело не проходит (маска плитки против маски тела).
  local body_layers = T.body_layers(p.body)
  local frame_area = { left_top = { x = fx0, y = fy0 }, right_bottom = { x = fx1 + 1, y = fy1 + 1 } }
  local liquid, liquids = 0, {}
  for _, t in ipairs(T.find_blocked(surface, frame_area, body_layers)) do
    local tp = t.position
    local x, y = floor(tp.x), floor(tp.y)
    if inside(x, y) then
      local i = idx(x, y)
      if known[i] and pass[i] then
        pass[i] = false
        if in_area(x, y) then
          liquid = liquid + 1
          local name = t.name
          liquids[name] = (liquids[name] or 0) + 1
        end
      end
    end
  end
  local land = area_known - liquid

  -- 3. Преграды: утёсы, камни, постройки — всё, чья маска сталкивается с телом (кроме деревьев и
  -- подвижного). Ленты, руда, призраки по маске не сталкиваются и преградой не считаются.
  local layer_list = T.layer_list(body_layers)
  if #layer_list > 0 then
    local obstacle = {} -- имя прототипа → преграда ли
    local found = surface.find_entities_filtered{ area = frame_area, collision_mask = layer_list }
    for _, e in ipairs(found) do
      if e.valid and not NOT_OBSTACLE[e.type] then
        local name = e.name
        local is = obstacle[name]
        if is == nil then
          local proto = T.prop(e, "prototype")
          is = T.intersects(T.layers_of(proto), body_layers) and not T.tiles_only(proto)
          obstacle[name] = is
        end
        if is then
          local bb = T.prop(e, "bounding_box")
          local x0, y0, x1, y1
          if type(bb) == "table" then
            local a, b = bb.left_top or bb[1], bb.right_bottom or bb[2]
            x0, y0 = floor((a.x or a[1]) + 0.01), floor((a.y or a[2]) + 0.01)
            x1, y1 = ceil((b.x or b[1]) - 0.01) - 1, ceil((b.y or b[2]) - 0.01) - 1
          else
            local ep = e.position
            x0, y0 = floor(ep.x), floor(ep.y)
            x1, y1 = x0, y0
          end
          if x1 < x0 then x1 = x0 end
          if y1 < y0 then y1 = y0 end
          if x0 < fx0 then x0 = fx0 end
          if y0 < fy0 then y0 = fy0 end
          if x1 > fx1 then x1 = fx1 end
          if y1 > fy1 then y1 = fy1 end
          for y = y0, y1 do
            for x = x0, x1 do pass[idx(x, y)] = false end
          end
        end
      end
    end
  end

  -- 4. Заливки от суши участка: обычная и по усаженным маскам.
  local seeds = {}
  for y = ay0, ay1 do
    for x = ax0, ax1 do
      local i = idx(x, y)
      if pass[i] then seeds[#seeds + 1] = i end
    end
  end
  local reached = flood(pass, W, H, seeds)
  local mask1 = erode(pass, W, H)
  local mask2 = erode(mask1, W, H)
  local reached1 = flood(mask1, W, H, seeds)
  local reached2 = flood(mask2, W, H, seeds)

  -- 5. Выходы: участки рамки, до которых дошла заливка.
  local exits = {}
  local function scan(side, count, cell)
    local run_start, run_wide, run_medium
    local function close(last)
      if run_start == nil then return end
      local width = last - run_start + 1
      local x, y = cell(run_start + floor((width - 1) / 2))
      exits[#exits + 1] = {
        side = side, pos = { x = x, y = y }, width = width,
        neck = run_wide and "wide" or (run_medium and "medium" or "narrow"),
      }
      run_start, run_wide, run_medium = nil, nil, nil
    end
    for k = 0, count - 1 do
      local x, y = cell(k)
      local i = idx(x, y)
      if reached[i] then
        if run_start == nil then run_start = k end
        if reached2[i] then run_wide = true end
        if reached1[i] then run_medium = true end
      else
        close(k - 1)
      end
    end
    close(count - 1)
  end
  scan("north", W, function(k) return fx0 + k, fy0 end)
  scan("south", W, function(k) return fx0 + k, fy1 end)
  if H > 2 then
    scan("west", H - 2, function(k) return fx0, fy0 + 1 + k end)
    scan("east", H - 2, function(k) return fx1, fy0 + 1 + k end)
  end
  table.sort(exits, function(a, b)
    if a.neck ~= b.neck then return NECK_RANK[a.neck] > NECK_RANK[b.neck] end
    if a.width ~= b.width then return a.width > b.width end
    if a.side ~= b.side then return SIDE_RANK[a.side] < SIDE_RANK[b.side] end
    if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
    return a.pos.y < b.pos.y
  end)
  local exits_total = #exits
  while #exits > M.MAX_EXITS do exits[#exits] = nil end

  local out = {
    area = { left_top = { x = ax0, y = ay0 }, right_bottom = { x = ax1 + 1, y = ay1 + 1 } },
    land = land, liquid = liquid,
    exits = exits, enclosed = exits_total == 0,
    not_charted = not_charted,
  }

  -- Плитки жидкости: самые частые имена (в ответ — как есть, PROTOCOL §6.12).
  local names = {}
  for name in pairs(liquids) do names[#names + 1] = name end
  table.sort(names, function(a, b)
    if liquids[a] ~= liquids[b] then return liquids[a] > liquids[b] end
    return a < b
  end)
  out.liquids = {}
  for i = 1, math.min(#names, M.MAX_LIQUIDS) do out.liquids[names[i]] = liquids[names[i]] end

  -- 6. Дойдёт ли помощник (или хозяин): его клетка внутри рамки и в той же заливке.
  if p.from ~= nil then
    local hx, hy = floor(p.from.x or p.from[1]), floor(p.from.y or p.from[2])
    if inside(hx, hy) then
      local ok = reached[idx(hx, hy)] == true
      if not ok and not pass[idx(hx, hy)] then
        -- тело стоит вплотную к преграде (клетка закрашена постройкой): смотрим соседей
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          local nx, ny = hx + d[1], hy + d[2]
          if inside(nx, ny) and reached[idx(nx, ny)] then ok = true end
        end
      end
      out.reachable = ok
    end
  end

  -- 7. Предупреждения.
  local warnings = {}
  if out.enclosed then
    warnings[#warnings + 1] = "enclosed"
  else
    local best = exits[1]
    out.best = best.side
    if best.neck == "narrow" then
      warnings[#warnings + 1] = "narrow_access" -- лучший выход узкий, значит узкие все
    else
      local seen = {}
      for _, e in ipairs(exits) do
        if e.neck == "narrow" and not seen[e.side] then
          seen[e.side] = true
          warnings[#warnings + 1] = "narrow_access:" .. e.side
        end
      end
    end
  end
  if not_charted > 0 then warnings[#warnings + 1] = "not_charted:" .. not_charted end
  out.warnings = warnings
  -- сколько сторон открыто широко (для plan_mining: открытое место без предупреждений)
  local wide_sides, n_wide = {}, 0
  for _, e in ipairs(exits) do
    if e.neck == "wide" and not wide_sides[e.side] then
      wide_sides[e.side] = true
      n_wide = n_wide + 1
    end
  end
  out.wide_sides = n_wide
  out.area_known = area_known
  return out
end

local function access_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { area = true, center = true, near = true, radius = true })
  local area
  local resolve_args = { center = args.center, near = args.near }
  if args.area ~= nil then
    if args.center ~= nil or args.near ~= nil or args.radius ~= nil then
      C.bad("area", "use either area or center/near with radius")
    end
    area = C.check_area(args.area, "area", M.MAX_SIDE)
    resolve_args.center = {
      x = (area.left_top.x + area.right_bottom.x) / 2,
      y = (area.left_top.y + area.right_bottom.y) / 2,
    }
  end
  local radius = C.check_int(args.radius, "radius", 1, M.MAX_RADIUS, M.DEFAULT_RADIUS)
  local where = C.resolve(resolve_args, ctx)
  local surface, force = where.surface, where.force
  if area == nil then
    local cx, cy = floor(where.center.x), floor(where.center.y)
    area = {
      left_top = { x = cx - radius, y = cy - radius },
      right_bottom = { x = cx + radius, y = cy + radius },
    }
  end

  -- Откуда идти: помощник, иначе хозяин на этой же поверхности.
  local from
  local e = where.entity
  if e ~= nil then
    if e.surface.index == surface.index then from = e.position end
  else
    local owner = where.owner
    if C.player_present(owner) and owner.physical_surface.index == surface.index then
      from = owner.physical_position
    end
  end

  local r = M.compute{ surface = surface, force = force, area = area, from = from, body = e }
  if r.area_known == 0 then err.raise("not_charted", "area is not charted") end
  r.surface = surface.name
  r.wide_sides, r.area_known, r.not_charted = nil, nil, nil
  return r
end

M.ops = {
  access = access_op,
}

return M
