-- Действие `deconstruct`: разобрать постройку или все постройки области руками.
-- Контракт: docs/ACTIONS.md («deconstruct», «Подход»), PROTOCOL.md §6.5, §6.6, §7.
--
-- args: target │ area, filter?: [name] (только эти имена).
-- done.detail: {removed, got: items, skipped?} — got — весь прирост инвентаря (постройка и её
-- содержимое), skipped — сколько не поддалось (не копается за разумное время).
-- Честно (§6.5): только `selected` + `mining_state` до исчезновения сущности (valid = false),
-- время тратит движок, предметы кладёт в инвентарь он же. Запрещённых приёмов (мгновенная
-- добыча, удаление с выдачей предметов) здесь нет.
-- * target — сущность своей силы или neutral (иначе not_found); к постройке подходит на
--   reach_distance, к камню и дереву — вплотную (resource_reach_distance: с reach_distance движок
--   их не добывает). Сам разбор — общий B.dig_step (scripts/lib/build.lua).
-- * area — постройки своей силы в области; с filter — ещё и neutral с этими именами (деревья,
--   камни). Не трогаются: персонажи, призраки, руда, техника с водителем, некопаемое.
--   Область на время задачи резервируется (пересечение с чужой → reserved). Больше 500 → limit.
-- failed: bad_args, not_found, not_reachable, not_charted, reserved, limit, stuck (ничего не
-- разобралось / инвентарь полон — событие inventory_full), ошибки пути.
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")

local perms = require("scripts.core.perms")

local M = {}
M.name = "deconstruct"

--- Разрешения хозяина на разбор сущности e (scripts/core/perms.lua dig_keys).
M.entity_keys = perms.dig_keys

--- Ключи, которые задевают эти аргументы, — для раннего отказа при постановке. Окончательная
--- проверка — в start по тем сущностям, что будут разбираться на самом деле (за время в очереди
--- в области могло появиться новое).
function M.perms(a, ctx)
  local keys = {}
  if a.target ~= nil then
    local e = perms.find(ctx, a.target)
    if e ~= nil then M.entity_keys(e, keys) end
  elseif a.area ~= nil then
    local h = ctx and ctx.entity
    if h ~= nil and h.valid then
      local ok, list = pcall(function()
        return h.surface.find_entities_filtered{
          area = { a.area.left_top, a.area.right_bottom }, force = { h.force.name, "neutral" }, name = a.filter,
        }
      end)
      if ok and type(list) == "table" then
        for i, e in ipairs(list) do
          if i > M.MAX_ENTITIES then break end
          if e.valid and e ~= h then M.entity_keys(e, keys) end
        end
      end
    end
  end
  return keys
end
M.schema = {
  target = { type = "target" },
  area = { type = "area" },
  filter = { type = "list", of = { type = "string", max = 100 }, max = 50 },
}
M.MAX_ENTITIES = 500

local why_not = B.why_not_minable
local has_driver = B.has_driver

local function finish(task, ctx)
  B.stop_mining(task, ctx.entity)
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
  -- разрешения хозяина на то, что разбирается на самом деле (по задаче: perm_gate и owner_ok)
  local keys = {}
  for _, it in ipairs(queue) do M.entity_keys(it.e, keys) end
  local pcode, ptext, pdata = perms.refusal(keys, task)
  if pcode ~= nil then
    return B.failed(pcode, ptext, pdata)
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
  local h = ctx.entity
  if task.dig == nil then
    local cur = next_target(task, h)
    if cur == nil then
      finish(task, ctx)
      local d = detail_of(task, h)
      if task.removed == 0 and task.skipped > 0 then
        return B.failed("stuck", "nothing could be deconstructed", d)
      end
      return B.done(d)
    end
    task.dig = B.dig_new(h, cur.e)
  end

  local r = B.dig_step(task, ctx, task.dig)
  if r == "working" then return nil end
  task.dig = nil
  if r == "removed" then
    task.removed = task.removed + 1
    task.progress.done = task.removed
  elseif r == "gone" then
    -- исчезла сама (разобрал кто-то другой) — не наша заслуга
    return nil
  elseif r == "skipped" then
    task.skipped = task.skipped + 1
  elseif r == "full" then
    finish(task, ctx)
    return inv.full_result(task, ctx, detail_of(task, h))
  else
    finish(task, ctx)
    r.detail = r.detail or detail_of(task, h)
    return r
  end
  return nil
end

function M.stop(task, ctx)
  finish(task, ctx)
end

return M
