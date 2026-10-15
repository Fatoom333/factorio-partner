-- Поиск цели действия. Контракт: docs/ACTIONS.md «Общие типы» → target.
--   target = {unit_number, pos?} │ {name, pos} — сущность на поверхности surface, своей силы
--   или neutral (PROTOCOL §6.6).
-- В 2.0 `game.get_entity_by_unit_number` находит только сущности с флагом get-by-unit-number
-- (постройки — не всегда), поэтому при nil ищем `find_entities_filtered{position=pos, radius=2}`
-- и берём сущность с тем же unit_number.
local owner = require("scripts.core.owner")

local M = {}

M.SEARCH_RADIUS = 2   -- поиск по unit_number вокруг pos
M.NAME_RADIUS = 1     -- поиск по {name, pos}

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

--- resolve(surface, target[, force]) -> LuaEntity | nil, reason
--- force — сила помощника (имя или LuaForce); по умолчанию сила хозяина.
--- reason при nil: "not_found" (нет такой), "other_surface" (есть, но на другой поверхности),
--- "foreign" (чужая сила, не neutral) — вызывающий сам выбирает код (not_found / not_reachable).
function M.resolve(surface, target, force)
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
