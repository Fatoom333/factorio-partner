-- Действие `collect`. Контракт: docs/ACTIONS.md, PROTOCOL.md §6, §7 (резервы),
-- STATE.md «stock» (какие склады видны).
--
-- args: items, center?:pos │ near?:"player", radius?=64 (≤ 128, больше → limit), from_lines?=false.
-- Собирает items со складов своей силы в радиусе (те же склады, что видит `stock`: контейнеры и
-- логистические сундуки, содержимое — только в видимых чанках). Сундук, в который кладёт манипулятор
-- или загрузчик хозяина (выход линии), и выходные слоты сборщиков и печей — только с from_lines
-- (scripts/lib/lines.lua); без флага то, что там лежит, называется в detail.lines.
-- Чужой резерв не берёт; на время задачи резервирует нужное за собой (storage.reservations,
-- снимается в конце). Обходит склады жадно — ближайший к помощнику, где ещё есть нужное; к каждому
-- подходит на reach_distance.
-- done.detail = {collected: items, missing: items, from: [unit_number], lines?: {item: {count, at,
-- hint}}}; ничего не собрано → failed{no_items} с той же detail; полный инвентарь — событие
-- inventory_full и failed{no_space}
-- (detail — что успел собрать). Остался только неделимый стак (предмет с данными/портящийся
-- больше остатка заявки) — failed{no_items, detail.reason="whole_stacks_only"}.
local reserve = require("scripts.core.reserve")
local util = require("scripts.core.util")
local target = require("scripts.core.target")
local inv = require("scripts.lib.inventory")
local extract = require("scripts.actions.extract")
local C = require("scripts.perception.state").common
local lines = require("scripts.lib.lines")

local M = {}
M.name = "collect"
M.schema = {
  items = { type = "items", required = true, min_kinds = 1 },
  center = { type = "pos" },
  near = { type = "string", values = { "player" } },
  radius = { type = "number", min = 1, max = 128, default = 64 },
  from_lines = { type = "bool", default = false },
}

M.MAX_RADIUS = 128
M.MAX_CONTAINERS = 64

local function remaining(task)
  local out = {}
  for name, n in pairs(task.want) do
    local left = n - (task.collected[name] or 0)
    if left > 0 then out[name] = left end
  end
  return out
end

local function result(task)
  local missing = {}
  for name, n in pairs(task.args.items) do
    local left = n - (task.collected[name] or 0)
    if left > 0 then missing[name] = left end
  end
  local detail = { collected = task.collected, missing = missing, from = task.from }
  if task.lines ~= nil then
    local hints = {}
    for name in pairs(missing) do hints[name] = lines.hint(task.lines, name) end
    if next(hints) ~= nil then detail.lines = hints end
  end
  return detail
end

local function release(task, ctx)
  if task.reserved then
    reserve.release_items(ctx.helper_id, task.reserved)
    task.reserved = nil
  end
end

local function finish(task, ctx)
  release(task, ctx)
  inv.stop_approach(task, ctx)
  local detail = result(task)
  if task.full then return inv.full_result(task, ctx, detail) end
  if next(task.collected) == nil then
    if task.split then
      detail.reason = "whole_stacks_only"
      return inv.failed("no_items", "items with data or spoilage move only as whole stacks", detail)
    end
    if detail.lines ~= nil then
      return inv.failed("no_items", "the items are only in owner's line outputs (needs from_lines)", detail)
    end
    return inv.failed("no_items", "nothing to collect in range", detail)
  end
  return inv.done(detail)
end

function M.start(task, ctx)
  local a = task.args
  inv.check_items(a.items, "args.items")
  if a.radius > M.MAX_RADIUS then
    return inv.failed("limit", "args.radius: must be ≤ " .. M.MAX_RADIUS)
  end
  local where = C.resolve({ center = a.center, near = a.near }, ctx)
  local h = ctx.entity
  local filter = {}
  for name in pairs(a.items) do filter[name] = true end
  local scan = lines.scan(h.surface, h.force, where.center, a.radius, filter, ctx.helper_id,
    { from_lines = a.from_lines, hint = not a.from_lines })
  task.lines = scan.lines

  -- сколько можно взять: видимое на складах минус чужой резерв
  task.want = {}
  for name, n in pairs(a.items) do
    local allowed = math.max(0, (scan.total[name] or 0) - reserve.reserved_by_others(ctx.helper_id, name))
    local w = math.min(n, allowed)
    if w > 0 then task.want[name] = w end
  end
  task.collected = {}
  task.from = {}
  task.plan = {}
  for i, c in ipairs(scan.containers) do
    if i > M.MAX_CONTAINERS then break end
    task.plan[#task.plan + 1] = { unit = c.unit, pos = c.pos, items = c.items, kind = c.kind }
  end
  if next(task.want) == nil then return finish(task, ctx) end
  reserve.add_items(ctx.helper_id, task.want)
  task.reserved = util.copy(task.want)
  task.progress = { done = 0, total = inv.sum(task.want) }
  return nil
end

local function useful(entry, need)
  for name in pairs(need) do
    if (entry.items[name] or 0) > 0 then return true end
  end
  return false
end

local function next_container(task, h, need)
  local hp = util.xy(h.position)
  local best, bi, bd
  for i, entry in ipairs(task.plan) do
    if useful(entry, need) then
      local d = util.dist(hp, entry.pos)
      if bd == nil or d < bd then best, bi, bd = entry, i, d end
    end
  end
  if best == nil then return nil end
  table.remove(task.plan, bi)
  local e = target.resolve(h.surface, { unit_number = best.unit, pos = best.pos }, h.force)
  if e == nil then return next_container(task, h, need) end
  task.cur_kind = best.kind
  return e
end

function M.tick(task, ctx)
  local h = ctx.entity
  local need = remaining(task)
  if next(need) == nil or task.full then return finish(task, ctx) end
  if task.cur == nil or not task.cur.valid then
    if task.cur ~= nil then inv.stop_approach(task, ctx) end
    task.cur = next_container(task, h, need)
    if task.cur == nil then return finish(task, ctx) end
  end
  local r = inv.approach(task, ctx, task.cur, "reach")
  if r == nil then return nil end
  if r ~= true then
    release(task, ctx)
    r.detail = result(task)
    return r
  end
  -- у машины — только выходной слот (lines.lua): входы и топливо не трогаются
  local src
  if task.cur_kind == "machine" then src = lines.output_inventory(task.cur) else src = inv.main_inventory(task.cur) end
  if src ~= nil then
    -- свой резерв на эти предметы на время переноса снят не будет: reserved_by_others его не видит
    local got, _, flags = extract.take(task, ctx, src, need)
    if flags.split then task.split = true end
    if next(got) ~= nil then
      task.from[#task.from + 1] = task.cur.unit_number
      for name, n in pairs(got) do inv.add(task.collected, name, n) end
    end
    if flags.full then
      task.full = true
      inv.inventory_full(task, ctx)
    end
  end
  task.cur = nil
  task.progress.done = inv.sum(task.collected)
  return nil
end

function M.stop(task, ctx)
  release(task, ctx)
  inv.stop_approach(task, ctx)
end

return M
