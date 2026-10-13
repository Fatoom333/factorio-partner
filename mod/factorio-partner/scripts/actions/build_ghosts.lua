-- Действие `build_ghosts` (поток F): построить призраки своей силы в области.
-- Контракт: docs/ACTIONS.md («build_ghosts»), PROTOCOL.md §6.5 (blocked = ghost_revive false),
-- §7 (резерв области на время задачи).
--
-- args: area │ radius = 64 (квадрат вокруг помощника на старте), mode = "auto"│"hand"│"robots".
-- done.detail: {built, left, blocked:[{name,pos,reason}], blocked_total, missing}.
-- * hand   — только руками (личные дроны на время задачи не вылетают);
-- * robots — только личные дроны: помощник встаёт так, чтобы призраки были в зоне робопорта,
--            и ждёт (предметы дроны берут из его инвентаря); дронов нет → `no_items`;
-- * auto   — дроны, если они есть; стоят 30 с без единой постройки → дальше руками.
-- Готово — в области не осталось строимых призраков (заблокированные — в detail.blocked).
-- failed: no_items (предметы кончились; сбор — решение агента), stuck (60 с без прогресса),
-- reserved (область держит другой помощник). Прогресс — job_progress{done, total, built, left}.
-- Вся логика — scripts/lib/build.lua (общая с build_blueprint).
local B = require("scripts.lib.build")
local util = require("scripts.core.util")

local M = {}
M.name = "build_ghosts"
M.schema = {
  area = { type = "area" },
  radius = { type = "number", min = 1, max = 64 },
  mode = { type = "enum", values = { "auto", "hand", "robots" }, default = "auto" },
}
M.DEFAULT_RADIUS = 64

function M.start(task, ctx)
  local a = task.args
  if a.area ~= nil and a.radius ~= nil then
    return B.failed("bad_args", "args: use either area or radius")
  end
  local area = a.area
  if area == nil then
    local p = util.xy(ctx.entity.position)
    local r = a.radius or M.DEFAULT_RADIUS
    area = {
      left_top = { x = p.x - r, y = p.y - r },
      right_bottom = { x = p.x + r, y = p.y + r },
    }
  end
  B.hold_area(ctx, area)
  return B.ghosts_start(task, ctx, area, a.mode)
end

function M.tick(task, ctx)
  return B.ghosts_tick(task, ctx)
end

function M.stop(task, ctx)
  B.ghosts_stop(task, ctx)
end

return M
