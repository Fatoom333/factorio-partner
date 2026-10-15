-- Действие `approach`: «встань рядом» — с сущностью, точкой или хозяином.
-- Контракт: docs/ACTIONS.md (список v1, «Подход», «Общие типы аргументов»).
--   args: target (своей силы или neutral, иначе not_found; другая поверхность → not_reachable)
--         │ to = pos│"player"; distance = 0..64 (по умолчанию reach_distance персонажа)
--   done.detail: {pos}
-- К хозяину и к сущности подход идёт к их текущей позиции (цель может двигаться).
local owner = require("scripts.core.owner")
local util = require("scripts.core.util")
local target = require("scripts.core.target")

local M = {}
M.name = "approach"
M.schema = {
  target = { type = "target" },
  to = { type = { "pos", "string" }, values = { "player" } },
  distance = { type = "number", min = 0, max = 64 },
}

local function failed(code, text)
  return { status = "failed", code = code, text = text, detail = {} }
end

--- Найти цель `target` для помощника entity → LuaEntity | nil, result.
--- Поиск общий (scripts.core.target.resolve): своя сила или neutral (PROTOCOL §6.6),
--- иначе not_found; другая поверхность — not_reachable.
function M.resolve_target(t, entity)
  local ent, why = target.resolve(entity.surface, t, entity.force)
  if ent == nil then
    if why == "other_surface" then return nil, failed("not_reachable", "target is on another surface") end
    return nil, failed("not_found", "target not found")
  end
  return ent
end

--- Половина большей стороны bounding_box сущности (0, если коробки нет).
function M.half_extent(ent)
  local bb = ent.bounding_box
  if type(bb) ~= "table" then return 0 end
  local lt = bb.left_top or bb[1]
  local rb = bb.right_bottom or bb[2]
  if lt == nil or rb == nil then return 0 end
  local ltx, lty = lt.x or lt[1], lt.y or lt[2]
  local rbx, rby = rb.x or rb[1], rb.y or rb[2]
  return math.max(rbx - ltx, rby - lty) / 2
end

function M.start(task, ctx)
  local a = task.args
  if (a.target == nil) == (a.to == nil) then
    return failed("bad_args", "args: exactly one of target or to is required")
  end
  if a.target ~= nil then
    local ent, res = M.resolve_target(a.target, ctx.entity)
    if ent == nil then return res end
    task.target_entity = ent
    task.target_unit = ent.unit_number
  end
  task.distance = a.distance or ctx.entity.reach_distance or 10
  if task.target_entity ~= nil and a.distance ~= nil then
    -- к центру большой постройки ближе её половины не подойти: не ждать stuck
    task.distance = math.max(task.distance, M.half_extent(task.target_entity) + 0.6)
  end
  return M.tick(task, ctx)
end

local function goal_of(task, ctx)
  local a = task.args
  if task.target_entity ~= nil then
    local ent = task.target_entity
    if not ent.valid then return nil, failed("not_found", "target is gone") end
    if ent.surface.index ~= ctx.entity.surface.index then
      return nil, failed("not_reachable", "target is on another surface")
    end
    return util.xy(ent.position)
  end
  if a.to == "player" then
    local p = owner.present()
    if p == nil then return nil, failed("no_player", "owner is not online with a character") end
    if p.physical_surface.index ~= ctx.entity.surface.index then
      return nil, failed("not_reachable", "owner is on another surface")
    end
    return util.xy(p.physical_position)
  end
  return a.to
end

function M.tick(task, ctx)
  local goal, res = goal_of(task, ctx)
  if goal == nil then
    ctx.cancel_approach(task)
    return res
  end
  local r = ctx.approach(task, goal, task.distance)
  if r == nil then return nil end
  if r == true then
    local p = util.pos(ctx.entity.position)
    ctx.emit("arrived", { job = task.job, pos = p })
    return { status = "done", detail = { pos = p } }
  end
  return r
end

function M.stop(task, ctx)
  ctx.cancel_approach(task)
end

return M
