-- Поиск цели действия. Контракт: docs/ACTIONS.md «Общие типы» → target.
--   target = {unit_number, pos?} │ {name, pos} — сущность на поверхности surface, своей силы
--   или neutral (PROTOCOL §6.6).
-- В 2.0 `game.get_entity_by_unit_number` находит только сущности с флагом get-by-unit-number
-- (постройки — не всегда), поэтому при nil ищем `find_entities_filtered{position=pos, radius=2}`
-- и берём сущность с тем же unit_number. С opts.near (позиция помощника) номер ищется и шире:
-- pos неточный или мусорный, а номер верный — сущность своей силы или neutral с тем же
-- unit_number в радиусе WIDE_POS_RADIUS от pos, затем в радиусе WIDE_RADIUS от near.
local owner = require("scripts.core.owner")

local M = {}

M.SEARCH_RADIUS = 2   -- поиск по unit_number вокруг pos
M.NAME_RADIUS = 1     -- поиск по {name, pos}
M.WIDE_POS_RADIUS = 32  -- широкий поиск по unit_number вокруг pos (opts.near)
M.WIDE_RADIUS = 128     -- широкий поиск по unit_number вокруг помощника (opts.near)

local function force_name(f)
  if f == nil then return nil end
  if type(f) == "string" then return f end
  return f.name
end

local function xy(p)
  if p == nil then return nil end
  if p.x ~= nil then return { x = p.x, y = p.y } end
  return { x = p[1], y = p[2] }
end

local function own_force_name(force)
  if force ~= nil then return force_name(force) end
  local ok, p = pcall(owner.player)
  if ok and p ~= nil then
    local ok2, f = pcall(function() return p.force end)
    if ok2 and f ~= nil then return force_name(f) end
  end
  return "player"
end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

local function by_unit(surface, unit, center, radius, forces)
  if center == nil then return nil end
  local f = { position = center, radius = radius }
  if forces ~= nil then f.force = forces end
  local ok, list = pcall(function() return surface.find_entities_filtered(f) end)
  if not ok or type(list) ~= "table" then return nil end
  for _, x in ipairs(list) do
    if x.valid and x.unit_number == unit then return x end
  end
  return nil
end

--- resolve(surface, target[, force[, opts]]) -> LuaEntity | nil, reason
--- force — сила помощника (имя или LuaForce); по умолчанию сила хозяина.
--- opts.near — позиция помощника: включает широкий поиск по unit_number (см. шапку).
--- reason при nil: "not_found" (нет такой), "other_surface" (есть, но на другой поверхности),
--- "foreign" (чужая сила, не neutral) — вызывающий сам выбирает код (not_found / not_reachable).
function M.resolve(surface, target, force, opts)
  if type(target) ~= "table" or surface == nil then return nil, "not_found" end
  local mine = own_force_name(force)
  local ent

  if target.unit_number ~= nil then
    local ok, e = pcall(game.get_entity_by_unit_number, target.unit_number)
    if ok and e ~= nil and e.valid then
      ent = e
    elseif target.pos ~= nil then
      local list = surface.find_entities_filtered{ position = xy(target.pos), radius = M.SEARCH_RADIUS }
      for _, x in ipairs(list) do
        if x.valid and x.unit_number == target.unit_number then ent = x break end
      end
    end
    local near = opts and opts.near
    if ent == nil and near ~= nil then
      local forces = { mine, "neutral" }
      local p = target.pos ~= nil and xy(target.pos) or nil
      if p ~= nil and type(p.x) == "number" and type(p.y) == "number" then
        ent = by_unit(surface, target.unit_number, p, M.WIDE_POS_RADIUS, forces)
      end
      ent = ent or by_unit(surface, target.unit_number, xy(near), M.WIDE_RADIUS, forces)
    end
  elseif target.name ~= nil and target.pos ~= nil then
    if prototypes.entity[target.name] == nil then return nil, "not_found" end
    local p = xy(target.pos)
    local bd
    local list = surface.find_entities_filtered{ name = target.name, position = p, radius = M.NAME_RADIUS }
    for _, x in ipairs(list) do
      if x.valid then
        local d = dist(xy(x.position), p)
        if bd == nil or d < bd then ent, bd = x, d end
      end
    end
  end

  if ent == nil then return nil, "not_found" end
  if ent.surface == nil or ent.surface.index ~= surface.index then return nil, "other_surface" end
  local f = force_name(ent.force)
  if f ~= mine and f ~= "neutral" then return nil, "foreign" end
  return ent
end

return M
