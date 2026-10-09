-- Операция `map` (поток G): плиточная карта вокруг центра. Контракт: docs/STATE.md «map».
-- Статичное — только в открытых чанках (иначе `?`), враги — только в видимых (PROTOCOL §6.7).
-- `map` никогда не отдаёт not_charted и никогда не вызывает chart.
local C = require("scripts.perception.state").common

local M = {}

M.MAX_RADIUS = 32
M.DEFAULT_RADIUS = 16
M.MAX_ENTITIES = 100

local floor, ceil = math.floor, math.ceil

-- Постоянная легенда. Строчные буквы, кроме `g`, свободны для руд.
local FIXED = {
  ["."] = "земля", ["~"] = "вода/лава", ["#"] = "утёс/скала", ["?"] = "не открыто",
  ["@"] = "помощник", ["H"] = "другой помощник", ["P"] = "игрок",
  ["D"] = "бур", ["F"] = "печь", ["A"] = "сборщик", ["B"] = "лента", ["I"] = "манипулятор",
  ["C"] = "сундук", ["E"] = "столб", ["g"] = "призрак",
  ["L"] = "труба", ["T"] = "дерево", ["X"] = "враг", ["O"] = "другая постройка",
}
M.FIXED = FIXED

local TYPE_CHAR = {
  ["mining-drill"] = "D",
  ["furnace"] = "F",
  ["assembling-machine"] = "A", ["rocket-silo"] = "A",
  ["transport-belt"] = "B", ["underground-belt"] = "B", ["splitter"] = "B",
  ["loader"] = "B", ["loader-1x1"] = "B", ["linked-belt"] = "B", ["lane-splitter"] = "B",
  ["inserter"] = "I",
  ["container"] = "C", ["logistic-container"] = "C", ["linked-container"] = "C",
  ["infinity-container"] = "C",
  ["electric-pole"] = "E",
  ["pipe"] = "L", ["pipe-to-ground"] = "L", ["infinity-pipe"] = "L",
}
M.TYPE_CHAR = TYPE_CHAR

-- Не попадают в список entities по умолчанию (их много).
local NOISY_TYPES = {
  ["transport-belt"] = true, ["underground-belt"] = true, ["splitter"] = true,
  ["loader"] = true, ["loader-1x1"] = true, ["linked-belt"] = true, ["lane-splitter"] = true,
  ["pipe"] = true, ["pipe-to-ground"] = true, ["infinity-pipe"] = true,
  ["electric-pole"] = true,
}

-- Своей силы, но не постройки: не рисуем.
local SKIP_TYPES = {
  ["resource"] = true, ["character"] = true, ["character-corpse"] = true, ["corpse"] = true,
  ["item-entity"] = true, ["item-request-proxy"] = true, ["particle-source"] = true,
  ["smoke-with-trigger"] = true, ["fire"] = true, ["stream"] = true, ["projectile"] = true,
  ["explosion"] = true, ["highlight-box"] = true, ["speech-bubble"] = true, ["sticker"] = true,
  ["flying-text"] = true, ["deconstructible-tile-proxy"] = true, ["tile-ghost"] = true,
  ["construction-robot"] = true, ["logistic-robot"] = true, ["combat-robot"] = true,
  ["fish"] = true, ["beam"] = true, ["arrow"] = true, ["artillery-projectile"] = true,
}

local ENEMY_TYPES = {
  ["unit"] = true, ["unit-spawner"] = true, ["turret"] = true, ["spider-unit"] = true,
  ["segmented-unit"] = true,
}

-- Буква руды: первая свободная строчная буква имени, иначе любая свободная, иначе цифра.
local function ore_char(name, used)
  for i = 1, #name do
    local ch = name:sub(i, i)
    if ch:match("^%l$") and not used[ch] then return ch end
  end
  local pool = "abcdefghijklmnopqrstuvwxyz0123456789"
  for i = 1, #pool do
    local ch = pool:sub(i, i)
    if not used[ch] then return ch end
  end
  return nil
end
M.ore_char = ore_char

local function is_rock(e)
  if e.type == "cliff" then return true end
  if e.type == "simple-entity" then
    local ok, r = pcall(function() return e.prototype.count_as_rock_for_filtered_deconstruction end)
    return ok and r == true
  end
  return false
end

-- Подпись столбцов: у каждого x, кратного 5 (и у первого столбца), число, если оно
-- помещается до следующей метки; иначе `|` (для кратных 5); остальные столбцы — `.`.
function M.axis(x0, x1)
  local w = x1 - x0 + 1
  local chars = {}
  for i = 1, w do chars[i] = "." end
  local marks = {}
  for x = x0, x1 do
    if x % 5 == 0 or x == x0 then marks[#marks + 1] = x end
  end
  for i, x in ipairs(marks) do
    local col = x - x0 + 1
    local nxt = marks[i + 1] and (marks[i + 1] - x0 + 1) or (w + 1)
    local label = tostring(floor(x))
    local last = col + #label - 1
    if last < nxt and last <= w then
      for j = 1, #label do chars[col + j - 1] = label:sub(j, j) end
    elseif x % 5 == 0 then
      chars[col] = "|"
    end
  end
  return "x: " .. table.concat(chars)
end

local function map_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { center = true, near = true, radius = true, types = true, names = true })
  local radius = C.check_int(args.radius, "radius", 1, M.MAX_RADIUS, M.DEFAULT_RADIUS)
  local types = C.check_names(args.types, "types", 50)
  local names = C.check_names(args.names, "names", 100)
  local where = C.resolve(args, ctx)
  local surface, force, center = where.surface, where.force, where.center

  local ccx, ccy = floor(center.x), floor(center.y)
  local x0, y0, x1, y1 = ccx - radius, ccy - radius, ccx + radius, ccy + radius
  local W = x1 - x0 + 1
  local view = C.chunk_view(force, surface)
  local charted_chunk = view.charted_chunk

  -- Сетка grid[row][col], по умолчанию земля; неоткрытое отмечено в unknown.
  local grid, unknown = {}, {}
  for r = 1, W do
    local row, urow = {}, {}
    local cy = floor((y0 + r - 1) / 32)
    for c = 1, W do
      row[c] = "."
      urow[c] = not charted_chunk(floor((x0 + c - 1) / 32), cy)
    end
    grid[r], unknown[r] = row, urow
  end

  local function put(x, y, ch)
    local c, r = x - x0 + 1, y - y0 + 1
    if r >= 1 and r <= W and c >= 1 and c <= W and not unknown[r][c] then
      grid[r][c] = ch
    end
  end

  -- Закрасить bounding_box сущности целиком (в пределах карты).
  local function paint_box(e, ch)
    local bb = e.bounding_box
    local lt, rb = bb.left_top or bb[1], bb.right_bottom or bb[2]
    local ax0 = floor((lt.x or lt[1]) + 0.01)
    local ay0 = floor((lt.y or lt[2]) + 0.01)
    local ax1 = ceil((rb.x or rb[1]) - 0.01) - 1
    local ay1 = ceil((rb.y or rb[2]) - 0.01) - 1
    if ax1 < ax0 then ax1 = ax0 end
    if ay1 < ay0 then ay1 = ay0 end
    if ax0 < x0 then ax0 = x0 end
    if ay0 < y0 then ay0 = y0 end
    if ax1 > x1 then ax1 = x1 end
    if ay1 > y1 then ay1 = y1 end
    for y = ay0, ay1 do
      for x = ax0, ax1 do put(x, y, ch) end
    end
  end

  local area = { { x0, y0 }, { x1 + 1, y1 + 1 } }

  -- 1. Тайлы: вода/лава.
  local tile_cache = {}
  for _, t in ipairs(surface.find_tiles_filtered { area = area }) do
    local liquid = tile_cache[t.name]
    if liquid == nil then
      liquid = false
      local ok, layers = pcall(function() return t.prototype.collision_mask.layers end)
      if ok and type(layers) == "table" then
        liquid = (layers["water_tile"] or layers["lava_tile"]) and true or false
      end
      tile_cache[t.name] = liquid
    end
    if liquid then
      local p = t.position
      put(floor(p.x), floor(p.y), "~")
    end
  end

  -- 2. Сущности одним запросом, рисуем слоями.
  local own_name = force.name
  local found = surface.find_entities_filtered { area = area, force = { own_name, "neutral", "enemy" } }
  local ores, rocks, trees, ghosts, builds, enemies = {}, {}, {}, {}, {}, {}
  for _, e in ipairs(found) do
    if e.valid then
      local ty = e.type
      local fname = e.force.name
      if ty == "resource" then
        ores[#ores + 1] = e
      elseif fname == own_name then
        if ty == "entity-ghost" then ghosts[#ghosts + 1] = e
        elseif not SKIP_TYPES[ty] then builds[#builds + 1] = e end
      elseif fname == "neutral" then
        if is_rock(e) then rocks[#rocks + 1] = e
        elseif ty == "tree" then trees[#trees + 1] = e end
      elseif fname == "enemy" then
        if ENEMY_TYPES[ty] and view.visible(e.position) then enemies[#enemies + 1] = e end
      end
    end
  end

  -- Руды: имена по алфавиту, чтобы буквы не прыгали между вызовами.
  local used = {}
  for ch in pairs(FIXED) do used[ch] = true end
  local ore_names, ore_letter = {}, {}
  for _, e in ipairs(ores) do
    if ore_letter[e.name] == nil then ore_letter[e.name] = false; ore_names[#ore_names + 1] = e.name end
  end
  table.sort(ore_names)
  for _, n in ipairs(ore_names) do
    local ch = ore_char(n, used)
    if ch then used[ch] = true; ore_letter[n] = ch end
  end
  for _, e in ipairs(ores) do
    local ch = ore_letter[e.name]
    if ch then
      local p = e.position
      put(floor(p.x), floor(p.y), ch)
    end
  end
  for _, e in ipairs(trees) do paint_box(e, "T") end
  for _, e in ipairs(rocks) do paint_box(e, "#") end
  for _, e in ipairs(ghosts) do paint_box(e, "g") end
  for _, e in ipairs(builds) do paint_box(e, TYPE_CHAR[e.type] or "O") end
  for _, e in ipairs(enemies) do paint_box(e, "X") end

  -- Игроки и помощник поверх всего.
  for _, p in pairs(game.players) do
    if C.player_present(p) and p.physical_surface.index == surface.index then
      local pp = p.physical_position
      put(floor(pp.x), floor(pp.y), "P")
    end
  end
  -- Другие живые помощники (storage.helpers ядра) — `H`, текущий — `@`.
  local he = where.entity
  local he_unit = he and he.unit_number
  local hs = storage.helpers
  if type(hs) == "table" then
    for _, rec in pairs(hs) do
      local oe = type(rec) == "table" and rec.entity or nil
      if oe and rec.state == "alive" and oe.valid and oe.unit_number ~= he_unit and oe.surface.index == surface.index then
        local op = oe.position
        put(floor(op.x), floor(op.y), "H")
      end
    end
  end
  if he and he.surface.index == surface.index then
    local hp = he.position
    put(floor(hp.x), floor(hp.y), "@")
  end

  -- Неоткрытое.
  for r = 1, W do
    for c = 1, W do
      if unknown[r][c] then grid[r][c] = "?" end
    end
  end

  local rows = {}
  for r = 1, W do rows[r] = table.concat(grid[r]) end

  -- Легенда — ровно то, что нарисовано.
  local ore_by_char = {}
  for n, ch in pairs(ore_letter) do if ch then ore_by_char[ch] = n end end
  local legend = {}
  for r = 1, W do
    for c = 1, W do
      local ch = grid[r][c]
      if not legend[ch] then
        legend[ch] = ore_by_char[ch] and ("руда: " .. ore_by_char[ch]) or FIXED[ch] or ch
      end
    end
  end

  -- 3. Список сущностей (до 100).
  local list, total = {}, 0
  local function want(e)
    if types or names then
      return (types ~= nil and types[e.type] == true)
        or (names ~= nil and (names[e.name] == true
          or (e.type == "entity-ghost" and names[e.ghost_name] == true)))
    end
    return not NOISY_TYPES[e.type]
  end
  local function add(e, ch)
    if not view.charted(e.position) or not want(e) then return end
    total = total + 1
    if #list >= M.MAX_ENTITIES then return end
    local item = { c = ch, name = e.name, pos = C.rpos(e.position) }
    if e.type == "entity-ghost" then item.name = e.ghost_name; item.ghost = true end
    local okd, dir = pcall(function() return e.direction end)
    if okd and type(dir) == "number" then item.dir = dir end
    local oku, un = pcall(function() return e.unit_number end)
    if oku and type(un) == "number" then item.unit = un end
    list[#list + 1] = item
  end
  for _, e in ipairs(builds) do add(e, TYPE_CHAR[e.type] or "O") end
  for _, e in ipairs(ghosts) do add(e, "g") end
  for _, e in ipairs(enemies) do add(e, "X") end
  if types or names then
    -- нейтральное — только по явному фильтру
    for _, e in ipairs(trees) do add(e, "T") end
    for _, e in ipairs(rocks) do add(e, "#") end
    for _, e in ipairs(ores) do
      if ore_letter[e.name] then add(e, ore_letter[e.name]) end
    end
  end

  return {
    surface = surface.name,
    bbox = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 },
    axis = M.axis(x0, x1),
    rows = rows,
    legend = legend,
    entities = list,
    truncated = total > #list,
  }
end

M.ops = {
  map = map_op,
}

return M
