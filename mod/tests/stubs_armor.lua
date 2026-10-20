-- Заглушки брони и сетки брони (LuaEquipmentGrid). Дополняют stubs.lua и stubs_c.lua,
-- TESTING.md §1. Общие заглушки не меняют.
--
--   local S = require("stubs"); local A = require("stubs_armor")
--   local g = A.grid(4, 4)                                   -- сетка 4×4 категории "armor"
--   local W = A.setup{ items = { { name = "battery-equipment", count = 3 } },
--                      armor = { { name = "power-armor-mk2", count = 1, grid = g } } }
--   g.equipment / A.log                                      -- что стоит в сетке, вызовы put
--
-- Сетка — данные стака брони: переезжает вместе со стаком (swap_stack, transfer_stack), как в игре.
-- Стак брони отдаёт её полем `grid`. Модули ставятся только на свободные клетки, без позиции —
-- в первое свободное место сверху слева.
local S = require("stubs")
local C = require("stubs_c")

local A = {}
A.log = {}

-- модули брони: предмет → прототип модуля (форма w×h, категории)
A.EQUIPMENT = {
  ["battery-equipment"] = { w = 1, h = 2 },
  ["energy-shield-equipment"] = { w = 2, h = 2 },
  ["solar-panel-equipment"] = { w = 1, h = 1 },
  ["exoskeleton-equipment"] = { w = 2, h = 4 },
  ["spidertron-only-equipment"] = { w = 1, h = 1, cats = { "spidertron" } },
}

local function eq_proto(name)
  local spec = A.EQUIPMENT[name]
  return {
    name = name, type = "battery-equipment",
    shape = { width = spec.w, height = spec.h },
    equipment_categories = spec.cats or { "armor" },
    take_result = { name = name },
  }
end

--- Прототипы: предметы модулей брони (place_as_equipment_result) и броня без сетки.
function A.prototypes()
  for name in pairs(A.EQUIPMENT) do
    prototypes.item[name] = { name = name, type = "item", stack_size = 20,
      place_as_equipment_result = eq_proto(name) }
  end
  prototypes.item["light-armor"] = { name = "light-armor", type = "armor", stack_size = 1 }
end

local function occupied(g, x, y)
  for _, e in ipairs(g._list) do
    local p, sh = e.position, e.shape
    if x >= p.x and x < p.x + sh.width and y >= p.y and y < p.y + sh.height then return true end
  end
  return false
end

local function fits(g, sh, x, y)
  if x < 0 or y < 0 or x + sh.width > g.width or y + sh.height > g.height then return false end
  for yy = y, y + sh.height - 1 do
    for xx = x, x + sh.width - 1 do
      if occupied(g, xx, yy) then return false end
    end
  end
  return true
end

--- Сетка w×h. opts.cats — категории сетки (по умолчанию {"armor"}).
function A.grid(w, h, opts)
  opts = opts or {}
  local g = { _grid = true, _list = {}, width = w, height = h, valid = true, object_name = "LuaEquipmentGrid",
    prototype = { equipment_categories = opts.cats or { "armor" } } }
  return setmetatable(g, {
    __index = function(t, k)
      if k == "equipment" then
        local out = {}
        for i, e in ipairs(rawget(t, "_list")) do out[i] = e end
        return out
      end
      if k == "put" then
        return function(p)
          A.log[#A.log + 1] = "put:" .. p.name .. (p.position and (":" .. p.position.x .. "," .. p.position.y) or "")
          local item = prototypes.item[p.name]
          local proto = item and item.place_as_equipment_result
          if proto == nil then error("Unknown equipment " .. tostring(p.name), 2) end
          local sh = proto.shape
          local pos
          if p.position then
            if fits(t, sh, p.position.x, p.position.y) then pos = { x = p.position.x, y = p.position.y } end
          else
            -- как в игре без позиции: первое свободное место (здесь — только каждый второй
            -- ряд сверху, чтобы проверить перебор позиций модом)
            for y = 0, t.height - 1, 2 do
              for x = 0, t.width - 1 do
                if pos == nil and fits(t, sh, x, y) then pos = { x = x, y = y } end
              end
            end
          end
          if pos == nil then return nil end
          local e = { name = p.name, position = pos, shape = { width = sh.width, height = sh.height },
            prototype = proto, quality = { name = p.quality or "normal" }, energy = 0, valid = true }
          local list = rawget(t, "_list")
          list[#list + 1] = e
          return e
        end
      end
      if k == "take" then
        return function(p)
          local list = rawget(t, "_list")
          for i, e in ipairs(list) do
            if e == p.equipment then
              table.remove(list, i)
              e.valid = false
              A.log[#A.log + 1] = "take:" .. e.name
              return { name = e.prototype.take_result.name, count = 1, quality = e.quality.name }
            end
          end
          return nil
        end
      end
      return nil
    end,
  })
end

-- Стак отдаёт сетку из своих данных полем grid (как LuaItemStack.grid).
local function with_grid(inventory)
  for i = 1, #inventory do
    local st = inventory[i]
    local mt = getmetatable(st)
    local old = mt.__index
    mt.__index = function(t, k)
      if k == "grid" then
        local d = old(t, "_d")
        if d.name ~= nil and type(d.data) == "table" and rawget(d.data, "_grid") then return d.data end
        return nil
      end
      return old(t, k)
    end
  end
  return inventory
end

--- Мод + хозяин + помощник h1 (как C.setup) с прототипами модулей брони.
--- opts.items / opts.armor — списки стаков {name, count, grid?}; opts.size — главный инвентарь.
function A.setup(opts)
  opts = opts or {}
  A.log = {}
  local W = C.setup{}
  A.prototypes()
  local function conv(list)
    if list == nil then return nil end
    local out = {}
    for i, it in ipairs(list) do out[i] = { name = it.name, count = it.count or 1, data = it.grid } end
    return out
  end
  C.equip(W.h, { items = conv(opts.items), armor = conv(opts.armor), size = opts.size })
  W.main = with_grid(W.h.inventories[defines.inventory.character_main])
  W.armor = with_grid(W.h.inventories[defines.inventory.character_armor])
  return W
end

--- Что стоит в сетке: {item = count}.
function A.contents(g)
  local out = {}
  for _, e in ipairs(rawget(g, "_list")) do out[e.name] = (out[e.name] or 0) + 1 end
  return out
end

return A
