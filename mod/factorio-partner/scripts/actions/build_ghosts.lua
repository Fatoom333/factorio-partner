-- Действие `build_ghosts`: построить призраки своей силы в области.
-- Контракт: docs/ACTIONS.md («build_ghosts»), PROTOCOL.md §6.5 (blocked = ghost_revive false),
-- §7 (резерв области на время задачи).
--
-- args: area │ radius = 64 (квадрат вокруг помощника на старте), mode = "auto"│"hand"│"robots".
-- done.detail: {built, tiles_built, left, removed, not_removed, blocked:[{name,pos,reason}],
--               blocked_total, missing} (ACTIONS.md). Причины в blocked: obstacle (мешает помеченное,
--               которое разобрать не вышло), tile (плитку под призраком положить не удалось), liquid
--               (под призраком плитка без опоры и без призрака подложки — свойства плиток берутся
--               из игры, PROTOCOL §6.12), blocked (прочее: ghost_revive = false).
-- * hand   — только руками (личные дроны на время задачи не вылетают);
-- * robots — только личные дроны: помощник встаёт так, чтобы призраки были в зоне робопорта,
--            и ждёт (предметы дроны берут из его инвентаря); дронов нет → `no_items`;
-- * auto   — дроны, если они есть; стоят 30 с без единой постройки → дальше руками.
-- Порядок работы руками: снос помеченного → плитки → постройки.
-- * Призраки плиток (tile-ghost) строятся так же, как призраки построек (предмет плитки из
--   инвентаря, revive), и всегда первыми. Постройка, под которой ещё лежит призрак плитки, ждёт
--   её и заблокированной не считается.
-- * Сущности своей силы и neutral, помеченные к сносу и стоящие на месте призрака области (игрок
--   поставил чертёж с Shift / Ctrl+Shift), помощник сначала разбирает сам — честно, как
--   deconstruct (selected + mining_state). Остальное помеченное не трогает. В режимах с дронами
--   снос и плитки делают личные дроны.
-- removed — сколько помеченного помощник разобрал сам, not_removed — сколько не смог, tiles_built —
-- сколько из built плитки. Сверх контракта, когда есть что сказать: not_removed_list
-- ([{name,pos,reason}]) и tiles_first (ни одна постройка не поставлена раньше плиток).
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
