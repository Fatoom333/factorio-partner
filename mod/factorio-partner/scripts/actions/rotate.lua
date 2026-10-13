-- Действие `rotate` (руки). Контракт: docs/ACTIONS.md («rotate»), PROTOCOL.md §6.
--
-- args: target, direction (0│4│8│12). Поворачивает постройку своей силы, как игрок клавишей R:
-- только в досягаемости (reach_distance — помощник сначала подходит), только то, что игра даёт
-- поворачивать (supports_direction и rotatable). Чужую силу и нейтральные сущности не трогает.
-- Нужно перекладке ленты (plan_belt{from:"resume"} → resumed.rotate): последняя построенная
-- лента смотрит в помеху, а новый путь уходит от неё вбок.
-- done.detail = {name, pos, direction, was}. Уже смотрит туда — done с тем же was.
local inv = require("scripts.lib.inventory")
local util = require("scripts.core.util")

local M = {}
M.name = "rotate"
M.schema = {
  target = { type = "target", required = true },
  direction = { type = "enum", values = { 0, 4, 8, 12 }, required = true },
}

function M.start(task, ctx)
  local t = inv.resolve_target(ctx, task.args.target)
  local f = t.force
  local fname = type(f) == "string" and f or (f and f.name)
  if fname ~= ctx.entity.force.name then
    return inv.failed("bad_args", "args.target: only buildings of the owner's force can be rotated")
  end
  if not t.supports_direction or not t.rotatable then
    return inv.failed("bad_args", "args.target: this entity cannot be rotated")
  end
  task.target = t
  return nil
end

function M.tick(task, ctx)
  local t = task.target
  if t == nil or not t.valid then
    inv.stop_approach(task, ctx)
    return inv.failed("not_found", "target disappeared")
  end
  local r = inv.approach(task, ctx, t, "reach")
  if r == nil then return nil end
  if r ~= true then return r end

  local want = task.args.direction
  local was = t.direction
  local detail = { name = t.name, pos = util.pos(t.position), direction = want, was = was }
  if was == want then return inv.done(detail) end
  local ok = pcall(function() t.direction = want end)
  if not ok or not t.valid or t.direction ~= want then
    detail.direction = t.valid and t.direction or nil
    return inv.failed("cannot_place", "the game did not let the entity turn this way", detail)
  end
  return inv.done(detail)
end

function M.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
