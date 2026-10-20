-- Действие `walk`: дойти до точки или до хозяина. Контракт: docs/ACTIONS.md
-- (список v1, «Подход»), PROTOCOL.md §6.1 (только walking_state, без телепорта).
--   args: to = pos│"player", radius = 0..64 (по умолчанию 1)
--   done.detail: {pos, walked} — где встал и сколько клеток прошёл.
-- "player" — позиция хозяина в момент старта (за хозяином ходит `follow`).
local owner = require("scripts.core.owner")
local util = require("scripts.core.util")

local perms = require("scripts.core.perms")

local M = {}
M.name = "walk"

--- Разрешения хозяина (scripts/core/perms.lua): какие ключи задевают эти аргументы.
function M.perms(a, ctx)
  if type(a.to) == "table" and perms.too_far(ctx, a.to) then return { "perm-walk-far" } end
  return {}
end
M.schema = {
  to = { type = { "pos", "string" }, values = { "player" }, required = true },
  radius = { type = "number", min = 0, max = 64, default = 1 },
}

local function failed(code, text)
  return { status = "failed", code = code, text = text, detail = {} }
end

--- Позиция хозяина на поверхности помощника → pos | nil, result.
function M.owner_goal(entity)
  local p = owner.present()
  if p == nil then return nil, failed("no_player", "owner is not online with a character") end
  if p.physical_surface.index ~= entity.surface.index then
    return nil, failed("not_reachable", "owner is on another surface")
  end
  return util.xy(p.physical_position)
end

function M.start(task, ctx)
  local goal = task.args.to
  if goal == "player" then
    local g, res = M.owner_goal(ctx.entity)
    if g == nil then return res end
    goal = g
  end
  task.goal = { x = goal.x, y = goal.y }
  task.walked = 0
  task.last_pos = util.xy(ctx.entity.position)
  return M.tick(task, ctx)
end

function M.tick(task, ctx)
  local pos = util.xy(ctx.entity.position)
  task.walked = task.walked + util.dist(pos, task.last_pos)
  task.last_pos = pos
  local r = ctx.approach(task, task.goal, task.args.radius)
  if r == nil then return nil end
  if r == true then
    local p = util.pos(pos)
    ctx.emit("arrived", { job = task.job, pos = p })
    return { status = "done", detail = { pos = p, walked = util.round1(task.walked) } }
  end
  return r
end

function M.stop(task, ctx)
  ctx.cancel_approach(task)
end

return M
