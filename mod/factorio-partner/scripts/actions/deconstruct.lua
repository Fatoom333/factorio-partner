-- Действие `deconstruct` (поток F): разобрать постройку или все постройки области руками.
-- Контракт: docs/ACTIONS.md («deconstruct», «Подход»), PROTOCOL.md §6.5, §6.6, §7.
--
-- args: target │ area, filter?: [name] (только эти имена).
-- done.detail: {removed, got: items, skipped?} — got — весь прирост инвентаря (постройка и её
-- содержимое), skipped — сколько не поддалось (не копается за разумное время).
-- Честно (§6.5): только `selected` + `mining_state` до исчезновения сущности (valid = false),
-- время тратит движок, предметы кладёт в инвентарь он же. Запрещённых приёмов (мгновенная
-- добыча, удаление с выдачей предметов) здесь нет.
-- * target — сущность своей силы или neutral (иначе not_found); подходит на reach_distance.
-- * area — постройки своей силы в области; с filter — ещё и neutral с этими именами (деревья,
--   камни). Не трогаются: персонажи, призраки, руда, техника с водителем, некопаемое.
--   Область на время задачи резервируется (пересечение с чужой → reserved). Больше 500 → limit.
-- failed: bad_args, not_found, not_reachable, not_charted, reserved, limit, stuck (ничего не
-- разобралось / инвентарь полон — событие inventory_full), ошибки пути.
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")

local M = {}
M.name = "deconstruct"
M.schema = {
  target = { type = "target" },
  area = { type = "area" },
  filter = { type = "list", of = { type = "string", max = 100 }, max = 50 },
}
M.MAX_ENTITIES = 500
M.MIN_TIMEOUT = 300   -- тиков без исчезновения цели до пропуска

local SKIP_TYPES = {
  character = true, ["entity-ghost"] = true, ["tile-ghost"] = true, resource = true,
  ["item-entity"] = true, ["item-request-proxy"] = true, ["character-corpse"] = true,
  ["construction-robot"] = true, ["logistic-robot"] = true, ["combat-robot"] = true,
}

local function mining_speed(h)
  local s = h.prototype and h.prototype.mining_speed
  local speed = (type(s) == "number" and s > 0) and s or 0.5
  local m = h.force.manual_mining_speed_modifier
  if type(m) == "number" then speed = speed * (1 + m) end
  return math.max(speed, 0.01)
end

--- Можно разобрать руками? → nil │ текст причины.
local function why_not(e)
  if SKIP_TYPES[e.type] then return e.type .. " is not deconstructed" end
  local mp = e.prototype and e.prototype.mineable_properties
  if mp == nil or not mp.minable or e.minable == false then return e.name .. " is not minable" end
  return nil
end

local function has_driver(e)
  local ok, d = pcall(function() return e.get_driver() end)
  return ok and d ~= nil
end

local function first_product(e)
  local mp = e.prototype and e.prototype.mineable_properties
  for _, p in ipairs(mp and mp.products or {}) do
    if (p.type == nil or p.type == "item") and type(p.name) == "string" then return p.name end
  end
  return nil
end

local function stop_mining(task, h)
  if task.mining and h ~= nil and h.valid then
    h.mining_state = { mining = false }
    pcall(function() h.clear_selected_entity() end)
  end
  task.mining = false
end

local function finish(task, ctx)
  stop_mining(task, ctx.entity)
  inv.stop_approach(task, ctx)
end

local function detail_of(task, h)
  local d = { removed = task.removed, got = {} }
  if h ~= nil and h.valid then d.got = inv.gain(task.base, inv.counts(h.get_main_inventory())) end
  if task.skipped > 0 then d.skipped = task.skipped end
  return d
end

function M.start(task, ctx)
  local a, h = task.args, ctx.entity
  if (a.target == nil) == (a.area == nil) then
    return B.failed("bad_args", "args: exactly one of target, area is required")
  end
  local names
  if a.filter ~= nil then
    names = {}
    for _, n in ipairs(a.filter) do
      -- неизвестное имя в find_entities_filtered — ошибка движка (ушла бы как internal)
      if prototypes.entity[n] == nil then
        return B.failed("bad_args", "args.filter: unknown entity " .. n)
      end
      names[n] = true
    end
  end
  local queue = {}
  if a.target ~= nil then
    local e = B.resolve(ctx, a.target)
    if names ~= nil and not names[e.name] then
      return B.failed("not_found", "target " .. e.name .. " is not in the filter")
    end
    local why = why_not(e)
    if why then return B.failed("bad_args", why) end
    B.check_free(ctx, B.footprint(e.prototype, util.xy(e.position), e.direction))
    queue[1] = { e = e, name = e.name, pos = util.xy(e.position) }
  else
    if not B.area_charted(h, a.area) then
      return B.failed("not_charted", "area is in uncharted chunks")
    end
    B.hold_area(ctx, a.area)
    local filter = { area = { a.area.left_top, a.area.right_bottom } }
    if a.filter ~= nil then
      filter.force = { h.force.name, "neutral" }
      filter.name = a.filter
    else
      filter.force = h.force
    end
    for _, e in ipairs(h.surface.find_entities_filtered(filter)) do
      if e.valid and e ~= h and why_not(e) == nil and inv.allowed_force(h, e) and not has_driver(e) then
        if #queue >= M.MAX_ENTITIES then
          return B.failed("limit", "more than " .. M.MAX_ENTITIES .. " entities in the area; use a smaller area or a filter")
        end
        queue[#queue + 1] = { e = e, name = e.name, pos = util.xy(e.position) }
      end
    end
  end
  task.queue = queue
  task.removed = 0
  task.skipped = 0
  task.base = inv.counts(h.get_main_inventory())
  task.progress = { done = 0, total = #queue }
  if #queue == 0 then return B.done({ removed = 0, got = {} }) end
  return nil
end

--- Вынуть из очереди ближайшую живую цель.
local function next_target(task, h)
  local hp = util.xy(h.position)
  local q = task.queue
  local best, bd
  local i = 1
  while i <= #q do
    local en = q[i]
    if not en.e.valid then
      -- исчезла сама (разобрал кто-то другой) — не наша заслуга
      q[i] = q[#q]
      q[#q] = nil
    else
      local d = util.dist(en.pos, hp)
      if bd == nil or d < bd then best, bd = i, d end
      i = i + 1
    end
  end
  if best == nil then return nil end
  local en = q[best]
  q[best] = q[#q]
  q[#q] = nil
  return en
end

function M.tick(task, ctx)
  local h, tick = ctx.entity, ctx.tick
  local cur = task.cur
  if cur ~= nil and not cur.e.valid then
    -- цель исчезла. Нашей считаем её, только если мы её копали И в инвентарь что-то пришло:
    -- иначе её параллельно разобрал игрок или дрон, и removed был бы завышен. Постройка без
    -- предметов при разборе (cur.product == nil) засчитывается по самому факту добычи.
    if task.started_mining then
      local n = h.get_main_inventory().get_item_count()
      if cur.product == nil or n > (task.mine_inv or n) then
        task.removed = task.removed + 1
        task.progress.done = task.removed
      end
    end
    stop_mining(task, h)
    task.cur, cur = nil, nil
  end
  if cur == nil then
    cur = next_target(task, h)
    if cur == nil then
      finish(task, ctx)
      local d = detail_of(task, h)
      if task.removed == 0 and task.skipped > 0 then
        return B.failed("stuck", "nothing could be deconstructed", d)
      end
      return B.done(d)
    end
    task.cur = cur
    task.started_mining = false
    task.mine_since = nil
    local mt = cur.e.prototype.mineable_properties.mining_time or 1
    task.timeout = math.max(M.MIN_TIMEOUT, math.ceil(mt / mining_speed(h) * 60 * 3) + 60)
  end

  local r = inv.approach(task, ctx, cur.e, "reach")
  if r == nil then
    stop_mining(task, h)
    task.mine_since = nil
    return nil
  end
  if r ~= true then
    finish(task, ctx)
    r.detail = r.detail or detail_of(task, h)
    return r
  end

  local product = first_product(cur.e)
  if product ~= nil and not inv.has_room(h, product) then
    finish(task, ctx)
    return inv.full_result(task, ctx, detail_of(task, h))
  end

  if not task.mining or h.selected ~= cur.e then
    h.selected = cur.e
    h.mining_state = { mining = true, position = util.xy(cur.e.position) }
    task.mining = true
    if not task.started_mining then
      task.mine_inv = h.get_main_inventory().get_item_count()
      cur.product = product
    end
    task.started_mining = true
    task.mine_since = task.mine_since or tick
  elseif not (h.mining_state and h.mining_state.mining) then
    h.mining_state = { mining = true, position = util.xy(cur.e.position) }
  end

  if tick - (task.mine_since or tick) > task.timeout then
    -- не поддаётся (например, содержимое не влезает в инвентарь) — пропускаем
    stop_mining(task, h)
    task.skipped = task.skipped + 1
    task.cur = nil
  end
  return nil
end

function M.stop(task, ctx)
  finish(task, ctx)
end

return M
