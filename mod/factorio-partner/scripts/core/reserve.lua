-- Резервы предметов и областей между помощниками. PROTOCOL.md §7.
-- storage.reservations = {items={[helper]={[name]=count}}, areas={[helper]=area}}.
-- collect/extract не берут чужой резерв, build_* держат область на время задачи
-- (пересечение -> err `reserved`). Область помощника ядро снимает, когда его задача кончилась,
-- все резервы — при удалении/смерти/потере тела.
local err = require("scripts.core.err")

local M = {}

local function R() return storage.reservations end

local function overlap(a, b)
  return a.left_top.x < b.right_bottom.x and b.left_top.x < a.right_bottom.x
      and a.left_top.y < b.right_bottom.y and b.left_top.y < a.right_bottom.y
end
M.overlap = overlap

--- Кто из других помощников держит область, пересекающую area (id или nil).
function M.area_holder(helper, area)
  for other, a in pairs(R().areas) do
    if other ~= helper and overlap(a, area) then return other end
  end
  return nil
end

--- Занять область; пересечение с чужой -> err `reserved`.
function M.hold_area(helper, area)
  local other = M.area_holder(helper, area)
  if other then err.raise("reserved", "area is reserved by helper " .. other) end
  R().areas[helper] = {
    left_top = { x = area.left_top.x, y = area.left_top.y },
    right_bottom = { x = area.right_bottom.x, y = area.right_bottom.y },
  }
end

function M.release_area(helper)
  R().areas[helper] = nil
end

--- Зарезервировать предметы (добавить к своему резерву).
function M.add_items(helper, items)
  local mine = R().items[helper] or {}
  for name, n in pairs(items) do mine[name] = (mine[name] or 0) + n end
  R().items[helper] = mine
end

function M.release_items(helper, items)
  local mine = R().items[helper]
  if not mine then return end
  if items == nil then
    R().items[helper] = nil
    return
  end
  for name, n in pairs(items) do
    local left = (mine[name] or 0) - n
    mine[name] = left > 0 and left or nil
  end
  if next(mine) == nil then R().items[helper] = nil end
end

--- Сколько предмета name зарезервировали другие помощники.
function M.reserved_by_others(helper, name)
  local n = 0
  for other, items in pairs(R().items) do
    if other ~= helper then n = n + (items[name] or 0) end
  end
  return n
end

--- Занятые печи (и прочие машины-«рабочие места»): storage.reservations.machines = {[unit_number] = helper}.
--- Кто из других помощников занял машину (id или nil).
function M.machine_holder(helper, unit_number)
  local m = R().machines
  local other = m and m[unit_number]
  if other ~= nil and other ~= helper then return other end
  return nil
end

--- Занять машину; занята другим → false.
function M.hold_machine(helper, unit_number)
  if M.machine_holder(helper, unit_number) ~= nil then return false end
  local r = R()
  r.machines = r.machines or {}
  r.machines[unit_number] = helper
  return true
end

function M.release_machine(helper, unit_number)
  local m = R().machines
  if m and m[unit_number] == helper then m[unit_number] = nil end
end

function M.release_machines(helper)
  local m = R().machines
  if not m then return end
  for u, who in pairs(m) do
    if who == helper then m[u] = nil end
  end
end

function M.release_all(helper)
  M.release_area(helper)
  M.release_items(helper)
  M.release_machines(helper)
end

return M
