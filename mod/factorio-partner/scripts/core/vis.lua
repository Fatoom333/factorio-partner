-- Видимость живых данных (поток A, ревизия 3.1). Контракт: docs/PROTOCOL.md §6.7.
-- Живое (враги, содержимое контейнеров и машин, предметы на земле) — только в видимых чанках:
-- `force.is_chunk_visible` ИЛИ не дальше 32 клеток от живого тела помощника (его «глаза»:
-- без игроков онлайн `is_chunk_visible` от `force.chart` не включается).
-- Все модули зовут эту проверку, а не `is_chunk_visible` напрямую.
local owner = require("scripts.core.owner")

local M = {}

M.EYE_RADIUS = 32

local floor = math.floor

local function xy(p)
  if p == nil then return nil end
  if p.x ~= nil then return p.x, p.y end
  return p[1], p[2]
end

local function same_surface(a, b)
  if a == b then return true end
  if a == nil or b == nil then return false end
  return a.index ~= nil and a.index == b.index
end

--- Сила, чьи видимые чанки считаются: сила тела помощника, иначе сила хозяина, иначе player.
local function default_force(body)
  if body ~= nil then
    local ok, f = pcall(function() return body.force end)
    if ok and f ~= nil then return f end
  end
  local ok, p = pcall(owner.player)
  if ok and p ~= nil then
    local ok2, f = pcall(function() return p.force end)
    if ok2 and f ~= nil then return f end
  end
  return game.forces and game.forces.player or nil
end

--- Живое тело помощника (как registry.alive) или nil; без зависимости от registry и с защитой
--- от пустого storage (модули чтения зовут vis в тестах без ядра).
function M.body(helper_id)
  local hs = storage and storage.helpers
  local rec = hs and hs[helper_id]
  if rec and rec.state == "alive" and rec.entity and rec.entity.valid then return rec.entity end
  return nil
end

--- Функция-«глаза» для одной поверхности: viewer(pos) -> bool. Кэширует ответы
--- is_chunk_visible по чанкам (вызов дорогой, а позиций в одном запросе тысячи).
--- helper_id=nil — только is_chunk_visible; force необязательна (по умолчанию — как у visible).
function M.viewer(helper_id, surface, force)
  local body
  if helper_id ~= nil then
    local e = M.body(helper_id)
    if e ~= nil and same_surface(e.surface, surface) then body = e end
  end
  force = force or default_force(body)
  local bx, by
  if body ~= nil then bx, by = xy(body.position) end
  local r2 = M.EYE_RADIUS * M.EYE_RADIUS
  local cache = {}
  return function(pos)
    local x, y = xy(pos)
    if x == nil or y == nil then return false end
    if bx ~= nil then
      local dx, dy = x - bx, y - by
      if dx * dx + dy * dy <= r2 then return true end
    end
    if force == nil then return false end
    local cx, cy = floor(x / 32), floor(y / 32)
    local key = cx * 4194304 + cy -- |cx|, |cy| < 2^21
    local v = cache[key]
    if v == nil then
      v = force.is_chunk_visible(surface, { x = cx, y = cy }) and true or false
      cache[key] = v
    end
    return v
  end
end

--- visible(helper_id, surface, pos) -> bool (PROTOCOL §6.7).
function M.visible(helper_id, surface, pos, force)
  return M.viewer(helper_id, surface, force)(pos)
end

return M
