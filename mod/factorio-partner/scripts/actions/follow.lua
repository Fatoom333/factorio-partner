-- Действие `follow` (поток B): идти за хозяином duration_s секунд, держась в distance клеток.
-- Контракт: docs/ACTIONS.md (список v1; «пульс» task.progress_tick, пока законно стоит рядом).
--   args: distance = 1..32 (по умолчанию 3), duration_s = 1..3600 (по умолчанию 600)
--   done.detail: {} — когда время вышло. Хозяин ушёл из игры → no_player,
--   на другую поверхность → not_reachable (ходить между поверхностями нельзя).
local owner = require("scripts.core.owner")
local util = require("scripts.core.util")

local M = {}
M.name = "follow"
M.schema = {
  distance = { type = "number", min = 1, max = 32, default = 3 },
  duration_s = { type = "int", min = 1, max = 3600, default = 600 },
}
M.HYSTERESIS = 1 -- стоим рядом, пока хозяин не дальше distance + 1

local function failed(code, text)
  return { status = "failed", code = code, text = text, detail = {} }
end

function M.start(task, ctx)
  task.until_tick = ctx.tick + task.args.duration_s * 60
  return M.tick(task, ctx)
end

function M.tick(task, ctx)
  if ctx.tick >= task.until_tick then
    ctx.cancel_approach(task)
    return { status = "done", detail = {} }
  end
  local p = owner.present()
  if p == nil then
    ctx.cancel_approach(task)
    return failed("no_player", "owner is not online with a character")
  end
  if p.physical_surface.index ~= ctx.entity.surface.index then
    ctx.cancel_approach(task)
    return failed("not_reachable", "owner is on another surface")
  end
  local goal = util.xy(p.physical_position)
  local dist = task.args.distance
  if task.approach == nil and util.dist(util.xy(ctx.entity.position), goal) <= dist + M.HYSTERESIS then
    task.progress_tick = ctx.tick -- законно стоим рядом: ядро не снимет задачу со stuck
    return nil
  end
  local r = ctx.approach(task, goal, dist)
  if r == nil then return nil end
  if r == true then
    task.progress_tick = ctx.tick
    return nil
  end
  return r
end

function M.stop(task, ctx)
  ctx.cancel_approach(task)
end

return M
