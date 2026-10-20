-- Отстояние от врага для рефлекса `ammo`: кто опасен и на сколько, безопасна ли точка, куда отойти.
-- Контракт: docs/EVENTS.md «ammo» (keep_away, turret_gap, ammo_unsafe).
--
-- Дальность врага — из прототипа: attack_parameters.range (кусаки, черви), иначе turret_range
-- (черви); нет ни того, ни другого — FALLBACK по типу (у разрушителя Space Age своей дальности в
-- прототипе нет). Точка годится, если враг до неё не достаёт или она не ближе к нему, чем линия
-- своих турелей (черви и разрушители бьют по турелям первыми), — M.judge.
-- Враги за пределами глаз (32 клетки) учитываются, только если их чанк виден силе (PROTOCOL §6.7).
-- Модуль без состояния: кэш дальностей — по имени прототипа, в памяти Lua (не в storage).
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")
local C = require("scripts.reflexes.common")

local M = {}

M.MARGIN = 4          -- запас к дальности атаки врага
M.MAX_ENEMIES = 48    -- ближних врагов, которых учитывает расчёт (бюджет на проход)
M.SCAN_LIMIT = 200    -- сколько сущностей вернуть из поиска движка
M.TYPES = { "unit", "turret", "spider-unit", "segmented-unit" }
M.FALLBACK = { unit = 2, turret = 30, ["spider-unit"] = 16, ["segmented-unit"] = 30 }
M.TURRET_TYPES = { "ammo-turret", "electric-turret", "fluid-turret" }

local range_cache = {}

local function proto_range(name, etype)
  local r = range_cache[name]
  if r ~= nil then return r end
  local p = prototypes.entity[name]
  if p ~= nil then
    local ok, ap = pcall(function() return p.attack_parameters end)
    if ok and type(ap) == "table" and type(ap.range) == "number" then r = ap.range end
    if r == nil then
      local ok2, tr = pcall(function() return p.turret_range end)
      if ok2 and type(tr) == "number" then r = tr end
    end
  end
  if r == nil then r = M.FALLBACK[etype] or 10 end
  range_cache[name] = r
  return r
end
M.range = proto_range

--- Враги вокруг center в radius, ближние первыми, не больше MAX_ENEMIES:
--- { {name, type, pos, dist, range}, ... }. Дальше глаз — только видимые.
function M.enemies(helper_id, entity, center, radius)
  local own = entity.force
  if own ~= nil and own.name == C.ENEMY_FORCE then return {} end
  local body = util.xy(entity.position)
  local list = entity.surface.find_entities_filtered{
    position = center, radius = radius, force = C.ENEMY_FORCE, type = M.TYPES, limit = M.SCAN_LIMIT,
  }
  local out = {}
  for _, e in ipairs(list) do
    if e.valid then
      local p = util.xy(e.position)
      if util.dist(p, body) <= C.EYES or C.visible(helper_id, entity, p) then
        out[#out + 1] = { name = e.name, type = e.type, pos = p, dist = util.dist(p, center),
          range = proto_range(e.name, e.type) }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.dist ~= b.dist then return a.dist < b.dist end
    if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
    return a.pos.y < b.pos.y
  end)
  for i = #out, M.MAX_ENEMIES + 1, -1 do out[i] = nil end
  return out
end

--- Оценка точки p относительно врагов. refs — центры своих турелей {x, y} рядом с точкой.
--- Враг дальше своей дальности + MARGIN не мешает. Ближе — точка годится, только если она не ближе к
--- нему, чем линия турелей (враги бьют по турелям первыми). Линия — вторая по близости к врагу
--- турель из refs (одна выдвинутая вперёд турель линию не сдвигает: ради неё к врагу не подходим);
--- одна турель — она сама. behind (если задан) — точка дальше линии ещё на behind; keep_away (если
--- задан) — не ближе keep_away к любому врагу, где бы он ни был.
--- → ok, враг, из-за которого нет, причина ("enemy_closer" │ "no_cover" │ "behind" │ "keep_away").
function M.judge(p, foes, keep_away, behind, refs)
  for _, f in ipairs(foes) do
    local d = util.dist(p, f.pos)
    if keep_away ~= nil and d < keep_away then return false, f, "keep_away" end
    if d < f.range + M.MARGIN then
      local r1, r2
      for _, t in ipairs(refs) do
        local x = util.dist(t, f.pos)
        if r1 == nil or x < r1 then r1, r2 = x, r1
        elseif r2 == nil or x < r2 then r2 = x end
      end
      local line = r2 or r1
      if line == nil then return false, f, "no_cover" end
      if d < line then return false, f, "enemy_closer" end
      if behind ~= nil and d < line + behind then return false, f, "behind" end
    end
  end
  return true
end

--- Расстояние от точки до ближайшего врага (math.huge — врагов нет).
function M.nearest(p, foes)
  local d = math.huge
  for _, f in ipairs(foes) do
    local x = util.dist(p, f.pos)
    if x < d then d = x end
  end
  return d
end

M.MAX_BOXES = 96

--- Рамки турелей {x0, y0, x1, y1} (один раз на проход; ближние к center первыми, не больше MAX_BOXES).
function M.boxes(turrets, center)
  local out = {}
  for _, t in ipairs(turrets) do
    if t.valid then
      local p = util.xy(t.position)
      local ok, bb = pcall(function() return t.bounding_box end)
      local b
      if ok and type(bb) == "table" then
        local lt, rb = bb.left_top or bb[1], bb.right_bottom or bb[2]
        b = { lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2] }
      else
        local _, half = inv.edge_dist(p, t) -- рамка прототипа вокруг центра (или точка)
        b = { p.x - half, p.y - half, p.x + half, p.y + half }
      end
      b.x, b.y = p.x, p.y
      b.d = util.dist(p, center)
      out[#out + 1] = b
    end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  for i = #out, M.MAX_BOXES + 1, -1 do out[i] = nil end
  return out
end

--- Точка не ближе gap к каждой рамке из M.boxes?
function M.clear_of(p, boxes, gap)
  if gap <= 0 then return true end
  for _, b in ipairs(boxes) do
    local dx = math.max(b[1] - p.x, 0, p.x - b[3])
    local dy = math.max(b[2] - p.y, 0, p.y - b[4])
    if dx * dx + dy * dy < gap * gap then return false end
  end
  return true
end

--- Свободная клетка для персонажа возле p (движок) или nil.
function M.free_spot(surface, p)
  local ok, spot = pcall(function() return surface.find_non_colliding_position("character", p, 2, 0.5) end)
  if not ok or spot == nil then return nil end
  return util.xy(spot)
end

M.RETREAT_DIRS = 16
M.RETREAT_STEP = 3
M.RETREAT_MAX = 48

--- Свои турели (рамки M.boxes) не дальше near от точки.
function M.refs_near(p, boxes, near)
  local out = {}
  for _, b in ipairs(boxes) do
    if util.dist(b, p) <= near then out[#out + 1] = b end
  end
  return out
end

--- Оценка точки по турелям в near от неё: см. M.judge.
function M.judge_here(p, foes, keep_away, behind, boxes, near)
  return M.judge(p, foes, keep_away, behind, M.refs_near(p, boxes, near))
end

--- Куда отойти из-под удара: из ближнего к телу кольца, где есть годные (M.judge) точки не ближе gap к
--- турелям, — самая дальняя от врага. → pos │ nil.
function M.retreat_point(entity, foes, keep_away, behind, boxes, gap, near)
  local body = util.xy(entity.position)
  local best, be
  local r = M.RETREAT_STEP
  while r <= M.RETREAT_MAX do
    for i = 0, M.RETREAT_DIRS - 1 do
      local a = 2 * math.pi * i / M.RETREAT_DIRS
      local p = { x = body.x + math.cos(a) * r, y = body.y + math.sin(a) * r }
      if M.clear_of(p, boxes, gap) and M.judge_here(p, foes, keep_away, behind, boxes, near) then
        local e = M.nearest(p, foes)
        if best == nil or e > be then best, be = p, e end
      end
    end
    if best ~= nil then break end
    r = r + M.RETREAT_STEP
  end
  if best == nil then return nil end
  local spot = M.free_spot(entity.surface, best)
  if spot == nil or not M.judge_here(spot, foes, keep_away, behind, boxes, near) then return nil end
  return spot
end

return M
