-- Действие `get_items`. Контракт: docs/ACTIONS.md («get_items»), PROTOCOL.md §6.
--
-- args: items {имя: число} — сколько каждого предмета должно оказаться в карманах помощника,
--       radius?=64 (1..128) — где искать склады и печи вокруг помощника;
--       from_lines?=false — разрешение хозяина брать и из выходов его линий (сундук, в который кладёт
--       манипулятор или загрузчик) и из выходных слотов сборщиков и печей (входы и топливо — никогда).
-- Что уже лежит в карманах — засчитывается. Недостающее: склады своей силы (как `collect`) →
-- ручной крафт с промежуточными (рецепты своей силы, открытые) → плавка в свободных печах своей
-- силы рядом → добыча руками (`mine{item}`). Только легальные действия: без предметов из воздуха
-- и без телепорта, склады и печи — только видимые. Механизм — scripts/lib/getitems.lua.
-- done.detail = {have: items (что стало в карманах из запрошенного), from: {inventory, storage,
-- crafted, smelted, mined: items} (откуда что взято; пустые источники опущены), shortfall?:
-- [{item, missing, reason, via?, in_lines?, lines_at?, lines_item?, hint?}]} (in_lines — сколько
-- недостающего лежит в выходах линий и машин, когда from_lines не дан). Всё есть → done без
-- shortfall. Часть есть, часть нет → done с shortfall. Не прибавилось ничего → failed{no_items} с
-- той же detail. Полный инвентарь — failed{no_space}.
local inv = require("scripts.lib.inventory")
local G = require("scripts.lib.getitems")

local M = {}
M.name = "get_items"
M.schema = {
  items = { type = "items", required = true, min_kinds = 1 },
  radius = { type = "number", min = 1, max = 128, default = G.DEFAULT_RADIUS },
  from_lines = { type = "bool", default = false },
}

function M.start(task, ctx)
  local a = task.args
  local r = G.begin(task, ctx, a.items, { radius = a.radius, from_lines = a.from_lines })
  if r ~= nil then return r end
  return G.step(task, ctx)
end

function M.tick(task, ctx)
  return G.step(task, ctx)
end

function M.stop(task, ctx)
  G.stop(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
