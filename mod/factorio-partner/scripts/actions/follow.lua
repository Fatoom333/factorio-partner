-- Действие `follow`: идти за хозяином duration_s секунд, держась в distance клеток.
-- Контракт: docs/ACTIONS.md (список v1; «пульс» task.progress_tick, пока законно стоит рядом).
--   args: distance = 1..32 (по умолчанию 3), duration_s = 1..3600 (по умолчанию 600)
--   done.detail: {} — когда время вышло. Хозяин ушёл из игры → no_player,
--   на другую поверхность → not_reachable (ходить между поверхностями нельзя).
local owner = require("scripts.core.owner")
local util = require("scripts.core.util")
local path = require("scripts.lib.path")

local M = {}
M.name = "follow"
M.schema = {
  distance = { type = "number", min = 1, max = 32, default = 3 },
  duration_s = { type = "int", min = 1, max = 3600, default = 600 },
}
M.HYSTERESIS = 1 -- стоим рядом, пока хозяин не дальше distance + 1
-- Хозяин близко — идём к нему напрямую, без запроса пути: иначе, догнав его, помощник стоял, пока
-- движок считал новый маршрут (живой прогон 14.10). Прямо не идётся (не сдвинулся DIRECT_STALL тиков)
-- — DIRECT_COOLDOWN тиков обычный поиск пути.
M.DIRECT = 8
M.DIRECT_STALL = 20
M.DIRECT_COOLDOWN = 300

local function stop_walk(e)
  local ws = e.walking_state
  if ws ~= nil and ws.walking then e.walking_state = { walking = false, direction = ws.direction } end
end

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
  local e = ctx.entity
  local pos = util.xy(e.position)
  local d = util.dist(pos, goal)
  if task.approach == nil and (d <= dist or (task.direct == nil and d <= dist + M.HYSTERESIS)) then
    task.direct = nil
    stop_walk(e)
    task.progress_tick = ctx.tick -- законно стоим рядом: ядро не снимет задачу со stuck
    return nil
  end
  if d <= M.DIRECT and ctx.tick >= (task.direct_off_until or 0) then
    if task.approach ~= nil then ctx.cancel_approach(task) end
    local dr = task.direct
    if dr == nil then
      dr = { x = pos.x, y = pos.y, tick = ctx.tick }
      task.direct = dr
    elseif util.dist(pos, dr) >= 0.1 then
      dr.x, dr.y, dr.tick = pos.x, pos.y, ctx.tick
    elseif ctx.tick - dr.tick >= M.DIRECT_STALL then
      -- прямо не идётся (стена, машина): дальше — обычный поиск пути
      task.direct = nil
      task.direct_off_until = ctx.tick + M.DIRECT_COOLDOWN
      stop_walk(e)
    end
    if task.direct ~= nil then
      e.walking_state = { walking = true, direction = path.direction(goal.x - pos.x, goal.y - pos.y) }
      task.progress_tick = ctx.tick
      return nil
    end
  else
    if task.direct ~= nil then
      task.direct = nil
      stop_walk(e)
    end
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
