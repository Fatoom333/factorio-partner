-- «Руки» помощника: общие функции переноса предметов, целей и подхода (поток C).
-- Контракты: docs/ACTIONS.md («Подход», «extract / перенос предметов с данными»),
-- PROTOCOL.md §6 (честность: без предметов из воздуха, досягаемость, только своя сила/neutral,
-- только quality normal), §7 (резервы storage.reservations — через scripts.core.reserve).
--
-- Перенос предметов:
-- * «простые» предметы (тип прототипа из PLAIN_TYPES и без порчи) — `LuaInventory.remove` из источника,
--   затем `insert` в приёмник; не влезший остаток возвращается источнику (а если и туда не влез —
--   высыпается на землю у помощника, ничего не пропадает и не появляется);
-- * предметы с данными (броня с сеткой, чертежи и книги, item-with-entity-data, с инвентарём,
--   с тегами, инструменты выделения, портящиеся) — только целым стаком
--   `LuaItemStack.transfer_stack` в пустую ячейку приёмника (или `swap_stack`), никогда
--   remove_item + insert (данные потерялись бы, а порча обнулилась бы — «предметы из воздуха»).
--   Стак не делится: в 2.0 transfer_stack принимает только стак (без count), поэтому стак
--   больше остатка заявки не берётся вовсе — переносится не больше запрошенного (резервы и
--   detail совпадают с заявкой), недобор виден в missing/left.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local target = require("scripts.core.target")
local vis = require("scripts.core.vis")

local M = {}

M.NORMAL = "normal"

--- Типы прототипов предметов без своих данных: переносятся количеством.
M.PLAIN_TYPES = {
  item = true, ammo = true, capsule = true, gun = true, module = true, ["rail-planner"] = true,
  tool = true, ["repair-tool"] = true, ["space-platform-starter-pack"] = true,
}

-- Главный инвентарь сущности по типу (источник для extract/collect, приёмник для данных).
-- infinity-container и linked-container нарочно не входят: бесконечный сундук — это предметы
-- из воздуха, связанный сундук — перенос на расстояние.
local MAIN_INV = {
  container = "chest", ["logistic-container"] = "chest",
  car = "car_trunk", ["spider-vehicle"] = "spider_trunk", ["cargo-wagon"] = "cargo_wagon",
  ["character-corpse"] = "character_corpse", character = "character_main",
}
local NO_INVENTORY = {
  ["infinity-container"] = true, ["linked-container"] = true, ["infinity-pipe"] = true,
}

-- ------------------------------------------------------------------ качество и прототипы

--- quality (строка | LuaQualityPrototype | nil) — normal?
function M.is_normal(q)
  if q == nil then return true end
  if type(q) == "string" then return q == M.NORMAL end
  local ok, name = pcall(function() return q.name end)
  return ok and name == M.NORMAL
end

function M.item_proto(name)
  if type(name) ~= "string" then return nil end
  return prototypes.item[name]
end

--- Предмет с данными (переносится только целым стаком)? Неизвестный прототип — да (осторожно).
function M.has_data(name)
  local p = M.item_proto(name)
  if p == nil then return true end
  if not M.PLAIN_TYPES[p.type] then return true end
  local ok, ticks = pcall(function() return p.get_spoil_ticks() end)
  if ok and type(ticks) == "number" and ticks > 0 then return true end
  return false
end

function M.is_armor(name)
  local p = M.item_proto(name)
  return p ~= nil and p.type == "armor"
end

-- ------------------------------------------------------------------ подсчёт

--- Содержимое инвентаря → {name=count}, только quality normal. names — множество имён или nil.
function M.counts(inv, names)
  local out = {}
  if inv == nil or not inv.valid then return out end
  for k, v in pairs(inv.get_contents()) do
    local name, count, quality
    if type(v) == "table" then
      name, count, quality = v.name, v.count, v.quality
    else
      name, count = k, v
    end
    if type(name) == "string" and type(count) == "number" and count > 0 and M.is_normal(quality)
        and (names == nil or names[name]) then
      out[name] = (out[name] or 0) + count
    end
  end
  return out
end

--- {name=count} только по именам из множества names, через get_item_count (без get_contents —
--- дёшево, годится для опроса каждый тик). Нулевые не попадают.
function M.counts_of(inv, names)
  local out = {}
  if inv == nil or not inv.valid then return out end
  for name in pairs(names) do
    local n = inv.get_item_count{ name = name, quality = M.NORMAL }
    if n > 0 then out[name] = n end
  end
  return out
end

function M.count(inv, name)
  if inv == nil or not inv.valid then return 0 end
  return inv.get_item_count{ name = name, quality = M.NORMAL }
end

--- Положительная разница after - before → {name=count} (пустая таблица, если прироста нет).
function M.gain(before, after)
  local out = {}
  for name, n in pairs(after) do
    local d = n - (before[name] or 0)
    if d > 0 then out[name] = d end
  end
  return out
end

function M.add(acc, name, n)
  if n and n > 0 then acc[name] = (acc[name] or 0) + n end
  return acc
end

function M.sum(t)
  local n = 0
  for _, c in pairs(t) do n = n + c end
  return n
end

-- ------------------------------------------------------------------ инвентари сущностей

--- Настоящий главный инвентарь (сундук, багажник, вагон, труп) или nil — без выхода машин.
--- Приёмник предметов с данными: броне/чертежу/портящемуся в выходном слоте сборщика не место.
function M.data_inventory(e)
  if e == nil or not e.valid or NO_INVENTORY[e.type] then return nil end
  local key = MAIN_INV[e.type]
  if key and defines.inventory[key] then return e.get_inventory(defines.inventory[key]) end
  return nil
end

--- Главный инвентарь сущности (сундук, багажник, труп, …) или nil.
function M.main_inventory(e)
  if e == nil or not e.valid or NO_INVENTORY[e.type] then return nil end
  local key = MAIN_INV[e.type]
  if key and defines.inventory[key] then
    return e.get_inventory(defines.inventory[key])
  end
  local ok, inv = pcall(function() return e.get_output_inventory() end)
  if ok and inv and inv.valid then return inv end
  return nil
end

function M.helper_main(h)
  return h.get_main_inventory()
end

--- Есть ли место в инвентаре помощника хотя бы под 1 предмет name.
function M.has_room(h, name)
  local inv = h.get_main_inventory()
  if inv == nil then return false end
  return inv.can_insert{ name = name, count = 1, quality = M.NORMAL }
end

-- ------------------------------------------------------------------ перенос

local function spill(h, name, count)
  if count <= 0 or h == nil or not h.valid then return end
  h.surface.spill_item_stack{
    position = h.position, stack = { name = name, count = count, quality = M.NORMAL },
    enable_looted = true, allow_belts = false,
  }
end

--- Переложить один стак st (LuaItemStack, normal) целиком в пустую ячейку dst_inv.
--- → сколько переложено (0 — нет пустой ячейки). Части стака не бывает (см. шапку).
function M.transfer_stack(st, dst_inv)
  if dst_inv == nil or not dst_inv.valid or not st.valid_for_read then return 0 end
  if not M.is_normal(st.quality) then return 0 end
  local before = st.count
  local slot = dst_inv.find_empty_stack(st.name)
  if slot == nil then return 0 end
  slot.transfer_stack(st)
  local after = st.valid_for_read and st.count or 0
  return before - after
end

--- Предметы с данными: целыми стаками из src (LuaInventory) в dst_inv, не больше count.
--- → переложено, split (был стак больше остатка заявки — не взят).
function M.move_stacks(src, dst_inv, name, count)
  local moved, split = 0, false
  if src == nil or dst_inv == nil then return 0, false end
  for i = 1, #src do
    if moved >= count then break end
    local st = src[i]
    if st.valid_for_read and st.name == name and M.is_normal(st.quality) then
      if st.count > count - moved then
        split = true
      else
        local n = M.transfer_stack(st, dst_inv)
        -- в приёмнике нет пустой ячейки — дальше смысла нет
        if n == 0 and dst_inv.find_empty_stack(name) == nil then break end
        moved = moved + n
      end
    end
  end
  return moved, split
end

--- Перенести count предметов name (normal) из src (LuaInventory) в приёмник.
--- dst = {inv = LuaInventory} | {entity = LuaEntity} (insert сущности сам выберет слот:
--- топливо, патроны, сундук). h — тело помощника (куда высыпать невозвращённый остаток).
--- Предметы с данными — только в настоящий главный инвентарь (data_inventory), целыми стаками.
--- → сколько реально оказалось в приёмнике, split (см. move_stacks).
function M.move(src, dst, name, count, h)
  if count == nil or count <= 0 or src == nil or not src.valid then return 0, false end
  if M.has_data(name) then
    local dst_inv = dst.inv or M.data_inventory(dst.entity)
    return M.move_stacks(src, dst_inv, name, count)
  end
  local removed = src.remove{ name = name, count = count, quality = M.NORMAL }
  if removed <= 0 then return 0, false end
  local target = dst.inv or dst.entity
  local ins = target.insert{ name = name, count = removed, quality = M.NORMAL }
  local left = removed - ins
  if left > 0 then
    local back = src.insert{ name = name, count = left, quality = M.NORMAL }
    if back < left then spill(h, name, left - back) end
  end
  return ins, false
end

-- ------------------------------------------------------------------ цели

--- Цель действия (ACTIONS.md «Общие типы»): {unit_number, pos?} │ {name, pos} на поверхности
--- помощника, своей силы или neutral — поиск общий, scripts.core.target.resolve.
--- Нет / чужая сила — not_found; другая поверхность — not_reachable; неоткрытый чанк — not_charted.
function M.resolve_target(ctx, t)
  local h = ctx.entity
  local e, why = target.resolve(h.surface, t, h.force)
  if e == nil then
    if why == "other_surface" then err.raise("not_reachable", "target is on another surface") end
    if why == "foreign" then err.raise("not_found", "target is not of own or neutral force") end
    if t.unit_number ~= nil then err.raise("not_found", "target " .. t.unit_number .. " not found") end
    if prototypes.entity[t.name] == nil then err.raise("not_found", "unknown entity " .. t.name) end
    err.raise("not_found", "no " .. t.name .. " near the given pos")
  end
  if not M.charted(h, e.position) then err.raise("not_charted", "target is in an uncharted chunk") end
  return e
end

--- Сила цели — своя или neutral (PROTOCOL §6.6).
function M.allowed_force(h, e)
  local f = e.force
  if f == nil then return false end
  local fname = type(f) == "string" and f or f.name
  return fname == h.force.name or fname == "neutral"
end

local function chunk_of(pos)
  local p = util.xy(pos)
  return { x = math.floor(p.x / 32), y = math.floor(p.y / 32) }
end

function M.charted(h, pos)
  return h.force.is_chunk_charted(h.surface, chunk_of(pos))
end

--- Видна ли позиция (PROTOCOL §6.7): видимый чанк или ≤ 32 клеток от тела помощника.
--- ctx — контекст действия (нужен helper_id); viewer(pos) — для массовых проверок.
function M.visible(ctx, pos)
  return vis.visible(ctx.helper_id, ctx.entity.surface, pos, ctx.entity.force)
end

function M.viewer(ctx)
  return vis.viewer(ctx.helper_id, ctx.entity.surface, ctx.entity.force)
end

-- ------------------------------------------------------------------ досягаемость и подход

-- Деревья, камни и рыба копаются рукой только вблизи — как руда, с resource_reach_distance (2.7),
-- а не с reach_distance (10): ACTIONS.md «Подход». Живой замер 2026-10-13 (2.0.77): с 5–9 клеток
-- `can_reach_entity` для камня и дерева = false, а `selected` + `mining_state` ничего не добывают.
-- Это типы прототипов, а не имена: камни и деревья планет из модов подпадают сами.
M.NEAR_ONLY = { tree = true, ["simple-entity"] = true, fish = true }
M.NEAR_MARGIN = 0.3   -- запас к resource_reach_distance

--- Вид досягаемости для добычи/разбора сущности рукой: "near" (вплотную) │ "reach".
function M.dig_kind(e)
  if M.NEAR_ONLY[e.type] then return "near" end
  return "reach"
end

--- Досягаемость персонажа с бонусами силы (PROTOCOL §6.3).
function M.reach(h, kind)
  if kind == "resource" or kind == "near" then return h.resource_reach_distance end
  if kind == "pickup" then return h.item_pickup_distance end
  if kind == "build" then return h.build_distance end
  return h.reach_distance
end

--- Рамка сущности {x0, y0, x1, y1}: bounding_box движка, иначе collision_box прототипа вокруг
--- позиции, иначе точка.
local function box_of(e)
  local p = util.xy(e.position)
  local ok, bb = pcall(function() return e.bounding_box end)
  if not ok or type(bb) ~= "table" then
    local ok2, cb = pcall(function() return e.prototype.collision_box end)
    if ok2 and type(cb) == "table" then
      local lt, rb = cb.left_top or cb[1], cb.right_bottom or cb[2]
      if lt and rb then
        return { p.x + (lt.x or lt[1]), p.y + (lt.y or lt[2]), p.x + (rb.x or rb[1]), p.y + (rb.y or rb[2]) }
      end
    end
    return { p.x, p.y, p.x, p.y }
  end
  local lt, rb = bb.left_top or bb[1], bb.right_bottom or bb[2]
  return { lt.x or lt[1], lt.y or lt[2], rb.x or rb[1], rb.y or rb[2] }
end

--- Расстояние от точки до рамки сущности (0 — внутри) и меньшая полуширина рамки.
function M.edge_dist(pos, e)
  local b = box_of(e)
  local dx = math.max(b[1] - pos.x, 0, pos.x - b[3])
  local dy = math.max(b[2] - pos.y, 0, pos.y - b[4])
  return math.sqrt(dx * dx + dy * dy), math.min(b[3] - b[1], b[4] - b[2]) / 2
end

--- Цель в досягаемости? Для reach — проверка движка can_reach_entity (учитывает размер);
--- near — до края рамки (огромный камень Вулкануса — ~2 клетки от центра до края: живая игра 14.10,
--- по центру помощник упирался в камень и «не доставал»); иначе расстояние до центра.
function M.in_reach(h, e, kind)
  if kind == "reach" or kind == nil then
    local ok, r = pcall(function() return h.can_reach_entity(e) end)
    if ok and type(r) == "boolean" then return r end
  end
  if kind == "near" then
    -- движок сам знает размер камня; если он говорит «нет» — по расстоянию до центра с запасом
    local ok, r = pcall(function() return h.can_reach_entity(e) end)
    if ok and r == true then return true end
    return M.edge_dist(util.xy(h.position), e) <= M.reach(h, kind) - M.NEAR_MARGIN
  end
  return util.dist(util.xy(h.position), util.xy(e.position)) <= M.reach(h, kind)
end

local MAX_NEAR_TRIES = 3

--- Подойти к сущности e на дистанцию kind (ACTIONS.md «Подход»).
--- → true (в досягаемости) │ nil (иду) │ result (ошибка пути).
--- Своё состояние: task._goal (ключ текущей цели), task._near_tries.
function M.approach(task, ctx, e, kind)
  local h = ctx.entity
  if M.in_reach(h, e, kind) then
    if task._goal ~= nil then
      ctx.cancel_approach(task)
      task._goal = nil
    end
    task._near_tries = nil
    return true
  end
  if e.surface.index ~= h.surface.index then
    return { status = "failed", code = "not_reachable", text = "target is on another surface" }
  end
  local pos = util.xy(e.position)
  local tries = task._near_tries or 0
  -- подходим чуть ближе предела; после ложного «на месте» — ещё ближе
  local reach = M.reach(h, kind)
  local dist
  if kind == "resource" then
    dist = reach - 0.5 - tries * 0.5
  elseif kind == "near" then
    -- почти на предел от края: ближе мешает сама сущность. Цель пути — круг вокруг центра, поэтому
    -- к радиусу добавляем меньшую полуширину рамки (в круге радиуса d + half до края ≤ d)
    local _, half = M.edge_dist(pos, e)
    dist = reach - M.NEAR_MARGIN - 0.4 - tries * 0.4 + half
  elseif kind == "pickup" then
    dist = reach * 0.6 - tries * 0.2
  else
    dist = math.max(1, reach - 1.5 - tries)
  end
  if dist < 0.3 then dist = 0.3 end
  local key = string.format("%.2f:%.2f:%.2f", pos.x, pos.y, dist)
  if task._goal ~= key then
    if task._goal ~= nil then ctx.cancel_approach(task) end
    task.approach = nil
    task._goal = key
  end
  local r = ctx.approach(task, pos, dist)
  if r == true then
    task._goal = nil
    if M.in_reach(h, e, kind) then
      task._near_tries = nil
      return true
    end
    -- путь «дошёл», а до цели не достаём: ещё попытка ближе
    task._near_tries = tries + 1
    if task._near_tries > MAX_NEAR_TRIES then
      return { status = "failed", code = "stuck", text = "cannot get within reach of the target" }
    end
    task.approach = nil
    return nil
  end
  return r
end

--- Сбросить подход (смена цели, конец задачи).
function M.stop_approach(task, ctx)
  ctx.cancel_approach(task)
  task._goal = nil
  task._near_tries = nil
end

-- ------------------------------------------------------------------ события

--- inventory_full{job} — один раз за задачу (EVENTS.md, громкое).
function M.inventory_full(task, ctx)
  if task._inv_full_sent then return end
  task._inv_full_sent = true
  ctx.emit("inventory_full", { job = task.job })
end

--- Результат «инвентарь полон»: громкое inventory_full и failed{no_space} (PROTOCOL §3).
function M.full_result(task, ctx, detail)
  M.inventory_full(task, ctx)
  detail = detail or {}
  detail.reason = "inventory_full"
  return { status = "failed", code = "no_space", text = "inventory is full", detail = detail }
end

function M.failed(code, text, detail)
  return { status = "failed", code = code, text = text, detail = detail or {} }
end

function M.done(detail)
  return { status = "done", detail = detail or {} }
end

--- Проверка имён предметов из args (неизвестный предмет → bad_args).
function M.check_items(items, field)
  for name in pairs(items) do
    if M.item_proto(name) == nil then err.raise("bad_args", field .. "." .. name .. ": unknown item") end
  end
end

return M
