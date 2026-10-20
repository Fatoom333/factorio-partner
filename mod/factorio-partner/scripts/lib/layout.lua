-- Память поставленных блоков (storage.layouts, PROTOCOL.md §7): build_layout пишет, connect_entities
-- читает концы {layout, port} и {layout, i}. Контракт: docs/ACTIONS.md («build_layout»).
--
-- storage.layouts[helper] = { [tag] = {surface, anchor = {x, y}, direction, tick,
--   placed = {{i, name, pos}, ...} (≤ 100), ports = {[id] = {pos, dir, kind, io, items?, fluid?}}} }
-- Только простые данные: сущность ищется заново по имени и месту. ≤ 16 тегов на помощника (старший
-- по tick вытесняется). Записи удалённого помощника убираются при следующей записи и раз в
-- CLEAN_EVERY тиков (модуль подключён в control.lua).
local registry = require("scripts.core.registry")

local M = {}
M.name = "layout"
M.MAX_TAGS = 16
M.MAX_PLACED = 100
M.CLEAN_EVERY = 600

local function all()
  if type(storage.layouts) ~= "table" then storage.layouts = {} end
  return storage.layouts
end

local function gone(id)
  local rec = registry.get(id)
  return rec == nil or rec.state == "removed"
end

--- Убрать записи помощников, которых больше нет (helper_remove).
function M.clean()
  local t = all()
  for id in pairs(t) do
    if gone(id) then t[id] = nil end
  end
end

M.on_nth = { [M.CLEAN_EVERY] = function() M.clean() end }

local function copy_pos(p)
  return { x = p.x, y = p.y }
end

--- Запомнить блок под тегом. rec = {surface, anchor, direction, tick, placed, ports}.
function M.write(helper_id, tag, rec)
  M.clean()
  local t = all()
  local mine = t[helper_id]
  if type(mine) ~= "table" then
    mine = {}
    t[helper_id] = mine
  end
  local placed = {}
  for k, p in ipairs(rec.placed or {}) do
    if k > M.MAX_PLACED then break end
    placed[k] = { i = p.i, name = p.name, pos = copy_pos(p.pos) }
  end
  local ports = {}
  for id, p in pairs(rec.ports or {}) do
    local q = { pos = copy_pos(p.pos), dir = p.dir, kind = p.kind, io = p.io }
    if p.items ~= nil then
      q.items = {}
      for k, v in ipairs(p.items) do q.items[k] = v end
    end
    q.fluid = p.fluid
    ports[id] = q
  end
  mine[tag] = {
    surface = rec.surface, anchor = copy_pos(rec.anchor), direction = rec.direction,
    tick = rec.tick, placed = placed, ports = ports,
  }
  -- не больше MAX_TAGS: вытесняется самый старый
  local n, oldest, otick = 0, nil, nil
  for k, r in pairs(mine) do
    n = n + 1
    if k ~= tag and (otick == nil or (r.tick or 0) < otick) then oldest, otick = k, r.tick or 0 end
  end
  if n > M.MAX_TAGS and oldest ~= nil then mine[oldest] = nil end
end

--- Запись блока или nil, "not_found", текст.
function M.get(helper_id, tag)
  local mine = all()[helper_id]
  local rec = type(mine) == "table" and mine[tag] or nil
  if rec == nil then return nil, "not_found", "no layout " .. tostring(tag) end
  return rec
end

--- Порт блока: {pos, dir, kind, io, items?, fluid?, surface} │ nil, "not_found", текст.
function M.port(helper_id, tag, id)
  local rec = M.get(helper_id, tag)
  local p = rec and rec.ports and rec.ports[id]
  if p == nil then return nil, "not_found", "layout " .. tostring(tag) .. " has no port " .. tostring(id) end
  local out = { pos = copy_pos(p.pos), dir = p.dir, kind = p.kind, io = p.io, fluid = p.fluid, surface = rec.surface }
  if p.items ~= nil then
    out.items = {}
    for k, v in ipairs(p.items) do out.items[k] = v end
  end
  return out
end

--- Постройка блока по её номеру i в списке entities: {name, pos, surface} │ nil, "not_found", текст.
--- Живую сущность вызывающий ищет сам по name и pos.
function M.entity(helper_id, tag, i)
  local rec = M.get(helper_id, tag)
  if rec ~= nil then
    for _, p in ipairs(rec.placed or {}) do
      if p.i == i then return { name = p.name, pos = copy_pos(p.pos), surface = rec.surface } end
    end
  end
  return nil, "not_found", "layout " .. tostring(tag) .. " has no building " .. tostring(i)
end

return M
