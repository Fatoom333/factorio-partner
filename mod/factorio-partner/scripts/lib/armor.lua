-- Броня и сетка брони помощника: надеть броню из карманов, вставить и вынуть модули брони.
-- Контракты: docs/ACTIONS.md («equip», «armor_grid», «insert» в броню), STATE.md («state»),
-- PROTOCOL.md §6 (честность: только из инвентаря помощника, без предметов из воздуха, только
-- quality normal).
--
-- * Броня меняется `swap_stack` слота брони (defines.inventory.character_armor) со стаком из
--   главного инвентаря: прежняя броня встаёт на место новой целым стаком, вместе со своей
--   сеткой и модулями (как в игре).
-- * Модуль ставится `LuaEquipmentGrid.put{name, quality}` — сначала без позиции (игра сама
--   ищет место), потом перебором позиций; только после удачной постановки предмет уходит из
--   инвентаря (`remove` по одному). Новый модуль приходит пустым: заряд батарей и щитов копится
--   как в игре, мод его не задаёт.
-- * Модуль вынимается `LuaEquipmentGrid.take{equipment}` только если в инвентаре помощника есть
--   место под предмет; вынутое — `insert` в главный инвентарь (заряд теряется, как в игре).
-- * Автонадевание (`auto_wear`): слот брони пуст, а в карманах есть броня — надевается лучшая
--   (больше сетка, затем больше занятых модулями клеток) тем же `swap_stack`. Зовут pickup трупа
--   и рефлекс возрождения (scripts/reflexes/death.lua).
local inv = require("scripts.lib.inventory")
local perms = require("scripts.core.perms")

local M = {}

M.NORMAL = "normal"

-- reason из not_placed/not_taken → код ошибки итога, когда не сделано ничего (PROTOCOL §3)
M.CODE_OF = {
  no_armor = "no_items", no_grid = "bad_args", not_equipment = "bad_args",
  wrong_category = "bad_args", no_item = "no_items", no_space = "no_space",
  not_in_grid = "no_items", inventory_full = "no_space",
}

local function get(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

--- Слот брони тела (LuaItemStack) или nil.
function M.slot(h)
  local ai = h.get_inventory(defines.inventory.character_armor)
  if ai == nil or #ai < 1 then return nil end
  return ai[1]
end

--- Надетая броня → stack, grid (grid nil — броня без сетки) │ nil, reason ("no_armor").
function M.worn(h)
  local st = M.slot(h)
  if st == nil or not st.valid_for_read then return nil, nil, "no_armor" end
  local grid = get(st, "grid")
  if grid == nil then return st, nil, "no_grid" end
  return st, grid
end

--- Прототип модуля брони для предмета или nil (не модуль брони).
function M.equipment_proto(name)
  local p = inv.item_proto(name)
  if p == nil then return nil end
  return get(p, "place_as_equipment_result")
end

--- Имя предмета, который даёт модуль при снятии.
function M.item_of(eq)
  local p = get(eq, "prototype")
  local tr = p and get(p, "take_result")
  if type(tr) == "string" then return tr end
  if tr ~= nil then
    local n = get(tr, "name")
    if type(n) == "string" then return n end
  end
  return eq.name
end

local function cells(eq)
  local sh = get(eq, "shape")
  if type(sh) ~= "table" then return 1 end
  if type(sh.points) == "table" and #sh.points > 0 then return #sh.points end
  return (sh.width or 1) * (sh.height or 1)
end

--- Сводка сетки: {w, h, used, free, equipment: {item: count}} или nil.
function M.grid_summary(grid)
  if grid == nil then return nil end
  local w, hh = grid.width or 0, grid.height or 0
  local used, eqs = 0, {}
  for _, eq in ipairs(grid.equipment or {}) do
    used = used + cells(eq)
    inv.add(eqs, M.item_of(eq), 1)
  end
  local free = w * hh - used
  if free < 0 then free = 0 end
  return { w = w, h = hh, used = used, free = free, equipment = eqs }
end

--- Сводка надетой брони для state и ответов действий: {name, grid?} или nil (брони нет).
function M.summary(h)
  local ok, st, grid = pcall(M.worn, h)
  if not ok or st == nil then return nil end
  return { name = st.name, grid = M.grid_summary(grid) }
end

-- Подходит ли модуль сетке по категориям (нет данных о категориях — не мешаем, решит put).
local function category_ok(grid, eqp)
  local gp = get(grid, "prototype")
  local gcats = gp and get(gp, "equipment_categories")
  local ecats = get(eqp, "equipment_categories")
  if type(gcats) ~= "table" or type(ecats) ~= "table" then return true end
  local set = {}
  for _, c in ipairs(gcats) do set[c] = true end
  for _, c in ipairs(ecats) do if set[c] then return true end end
  return false
end

local function try_put(grid, eq_name, position)
  local ok, e = pcall(function()
    return grid.put{ name = eq_name, quality = M.NORMAL, position = position }
  end)
  if ok then return e end
  return nil
end

-- Поставить один модуль: без позиции, потом перебором позиций слева-сверху.
local function put_one(grid, eq_name)
  local e = try_put(grid, eq_name, nil)
  if e ~= nil then return e end
  for y = 0, (grid.height or 0) - 1 do
    for x = 0, (grid.width or 0) - 1 do
      e = try_put(grid, eq_name, { x = x, y = y })
      if e ~= nil then return e end
    end
  end
  return nil
end

--- Вставить модули из инвентаря помощника в сетку надетой брони.
--- → placed: items, not_placed: [{item, count, reason}].
function M.put(h, items)
  local placed, not_placed = {}, {}
  local _, grid, why = M.worn(h)
  if grid == nil then
    for _, name in ipairs(sorted_keys(items)) do
      not_placed[#not_placed + 1] = { item = name, count = items[name], reason = why }
    end
    return placed, not_placed
  end
  local main = h.get_main_inventory()
  for _, name in ipairs(sorted_keys(items)) do
    local n = items[name]
    local eqp = M.equipment_proto(name)
    if eqp == nil then
      not_placed[#not_placed + 1] = { item = name, count = n, reason = "not_equipment" }
    elseif not category_ok(grid, eqp) then
      not_placed[#not_placed + 1] = { item = name, count = n, reason = "wrong_category" }
    else
      local have = inv.count(main, name)
      local want = math.min(n, have)
      local done = 0
      while done < want do
        local e = put_one(grid, eqp.name)
        if e == nil then break end
        if main.remove{ name = name, count = 1, quality = M.NORMAL } < 1 then
          -- предмета не оказалось: модуль из воздуха не оставляем
          pcall(function() grid.take{ equipment = e } end)
          break
        end
        done = done + 1
      end
      inv.add(placed, name, done)
      if done < want then
        not_placed[#not_placed + 1] = { item = name, count = want - done, reason = "no_space" }
      end
      if have < n then
        not_placed[#not_placed + 1] = { item = name, count = n - have, reason = "no_item" }
      end
    end
  end
  return placed, not_placed
end

--- Вынуть модули из сетки надетой брони в инвентарь помощника.
--- → taken: items, not_taken: [{item, count, reason}], full: bool (не хватило места в инвентаре).
function M.take(h, items)
  local taken, not_taken, full = {}, {}, false
  local _, grid, why = M.worn(h)
  if grid == nil then
    for _, name in ipairs(sorted_keys(items)) do
      not_taken[#not_taken + 1] = { item = name, count = items[name], reason = why }
    end
    return taken, not_taken, false
  end
  local main = h.get_main_inventory()
  for _, name in ipairs(sorted_keys(items)) do
    local n = items[name]
    local list = {}
    for _, eq in ipairs(grid.equipment or {}) do
      if #list >= n then break end
      if M.item_of(eq) == name and inv.is_normal(get(eq, "quality")) then list[#list + 1] = eq end
    end
    local done = 0
    for _, eq in ipairs(list) do
      if not main.can_insert{ name = name, count = 1, quality = M.NORMAL } then
        full = true
        break
      end
      local pos, eq_name = eq.position, eq.name
      local r = grid.take{ equipment = eq }
      if r == nil then break end
      local cnt = (type(r) == "table" and r.count) or 1
      local got = main.insert{ name = name, count = cnt, quality = M.NORMAL }
      if got < cnt then
        -- не влезло (место кончилось между проверкой и вставкой): модуль обратно в сетку
        if got > 0 then main.remove{ name = name, count = got, quality = M.NORMAL } end
        try_put(grid, eq_name, pos)
        full = true
        break
      end
      done = done + 1
    end
    inv.add(taken, name, done)
    if done < #list then
      not_taken[#not_taken + 1] = { item = name, count = #list - done,
        reason = full and "inventory_full" or "not_in_grid" }
    end
    if #list < n then
      not_taken[#not_taken + 1] = { item = name, count = n - #list, reason = "not_in_grid" }
    end
  end
  return taken, not_taken, full
end

-- Чем броня лучше для автонадевания: больше сетка, затем больше занятых модулями клеток, затем
-- имя (чтобы выбор был один и тот же). Броня без сетки — сетка 0.
local function armor_rank(st)
  local s = M.grid_summary(get(st, "grid"))
  if s == nil then return 0, 0 end
  return s.w * s.h, s.used
end

--- Лучшая броня (quality normal) в главном инвентаре тела: стак или nil.
function M.best_in_pockets(h)
  local main = h.get_main_inventory()
  if main == nil then return nil end
  local best, ba, bu, bn
  for i = 1, #main do
    local st = main[i]
    if st.valid_for_read and inv.is_armor(st.name) and inv.is_normal(st.quality) then
      local a, u = armor_rank(st)
      local n = st.name
      if best == nil or a > ba or (a == ba and (u > bu or (u == bu and n < bn))) then
        best, ba, bu, bn = st, a, u, n
      end
    end
  end
  return best
end

--- Слот брони пуст, а в карманах есть броня — надеть лучшую (целым стаком, с сеткой и модулями,
--- как `equip`). → {equipped = имя, armor = сводка} │ nil (слот занят, брони нет, игра не дала).
function M.auto_wear(h)
  if h == nil or not h.valid then return nil end
  if not perms.combat().auto_armor then return nil end -- настройка мода partner-auto-armor
  local slot = M.slot(h)
  if slot == nil or slot.valid_for_read then return nil end
  local st = M.best_in_pockets(h)
  if st == nil then return nil end
  local name = st.name
  local ok, swapped = pcall(function() return slot.swap_stack(st) end)
  if not ok or not swapped or not slot.valid_for_read then return nil end
  return { equipped = name, armor = M.summary(h) }
end

--- Ничего не сделано → итог failed с кодом по первой причине (detail.reason — она же).
function M.failed_of(list, detail)
  local first = list[1] and list[1].reason or "no_item"
  detail.reason = first
  local code = M.CODE_OF[first] or "no_items"
  local text = ({
    no_armor = "no armor is equipped", no_grid = "the armor has no equipment grid",
    not_equipment = "items are not armor equipment", wrong_category = "the grid does not accept this equipment",
    no_item = "helper does not have the items", no_space = "no room in the armor grid",
    not_in_grid = "the armor grid has no such equipment", inventory_full = "inventory is full",
  })[first] or "nothing was done"
  return { status = "failed", code = code, text = text, detail = detail }
end

return M
