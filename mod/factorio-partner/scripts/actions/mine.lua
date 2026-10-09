-- Действие `mine` (поток C). Контракт: docs/ACTIONS.md, PROTOCOL.md §6.
--
-- args: target │ resource:string, near?:pos (только с resource), count:int.
-- * resource — ближайшая к помощнику руда этого имени в радиусе 64 от near (или от места
--   помощника на старте), только в открытых чанках; кончилась клетка — следующая. Готово, когда
--   основной продукт руды вырос на count. done.detail = {mined: items} — прирост продуктов.
-- * target — конкретная сущность своей силы или neutral: клетка руды (дальше как resource,
--   соседние клетки той же руды вокруг неё), дерево, камень или своя постройка — копаем, пока не
--   исчезнет; count для не-руды не используется. mined — весь прирост инвентаря.
-- Честно (PROTOCOL §6.5): только `selected` + `mining_state`, время и выход тратит движок;
-- `mine_entity` запрещён. Подход сам: руда — resource_reach_distance, остальное — reach_distance.
-- Контроль прироста: нет прироста дольше 3× времени добычи (≥ 5 с) — клетку пропускаем
-- (до 5 раз, потом stuck); полный инвентарь — событие inventory_full и failed{stuck}.
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")

local M = {}
M.name = "mine"
M.schema = {
  target = { type = "target" },
  resource = { type = "string", max = 100 },
  near = { type = "pos" },
  count = { type = "int", required = true, min = 1, max = 100000 },
}

M.SEARCH_RADIUS = 64   -- от near / места старта
M.LOCAL_RADIUS = 6     -- сначала ищем совсем рядом с помощником (дёшево)
M.MAX_SKIPS = 5
M.MIN_TIMEOUT = 300    -- тиков без прироста до пропуска клетки

local function key(p) return string.format("%.1f,%.1f", p.x, p.y) end

local function item_products(proto)
  local mp = proto.mineable_properties
  local out = {}
  for _, p in ipairs(mp and mp.products or {}) do
    if (p.type == nil or p.type == "item") and type(p.name) == "string" then out[#out + 1] = p.name end
  end
  return out
end

local function mining_speed(h)
  local ok, s = pcall(function() return h.prototype.mining_speed end)
  local speed = (ok and type(s) == "number" and s > 0) and s or 0.5
  local ok2, m = pcall(function() return h.force.manual_mining_speed_modifier end)
  if ok2 and type(m) == "number" then speed = speed * (1 + m) end
  return math.max(speed, 0.01)
end

--- Можно ли копать руками; иначе текст причины.
local function why_not_minable(h, proto)
  local mp = proto.mineable_properties
  if mp == nil or not mp.minable then return proto.name .. " is not minable" end
  if mp.required_fluid then return proto.name .. " needs a fluid to mine" end
  if proto.type == "resource" then
    -- 2.0: LuaEntityPrototype.resource_categories — «категории ресурсов персонажа или бура»
    local ok, cats = pcall(function() return h.prototype.resource_categories end)
    if not ok or type(cats) ~= "table" then
      ok, cats = pcall(function() return h.prototype.mining_categories end)
    end
    local cat = proto.resource_category
    if ok and type(cats) == "table" and cat ~= nil and not cats[cat] then
      return proto.name .. " cannot be mined by hand (" .. tostring(cat) .. ")"
    end
  end
  if #item_products(proto) == 0 then return proto.name .. " gives no items" end
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

local function find_next(task, h)
  local surf = h.surface
  local hp = util.xy(h.position)
  local charted = {}
  local function is_charted(p)
    local k = math.floor(p.x / 32) .. ":" .. math.floor(p.y / 32)
    if charted[k] == nil then charted[k] = inv.charted(h, p) and true or false end
    return charted[k]
  end
  local function pick(list)
    local best, bd
    for _, r in ipairs(list) do
      if r.valid then
        local p = util.xy(r.position)
        if not task.skip[key(p)] and util.dist(p, task.center) <= M.SEARCH_RADIUS
            and (r.amount == nil or r.amount > 0) and is_charted(p) then
          local d = util.dist(p, hp)
          if bd == nil or d < bd then best, bd = r, d end
        end
      end
    end
    return best
  end
  local r = pick(surf.find_entities_filtered{ type = "resource", name = task.res_name, position = hp, radius = M.LOCAL_RADIUS })
  if r then return r end
  return pick(surf.find_entities_filtered{ type = "resource", name = task.res_name, position = task.center, radius = M.SEARCH_RADIUS })
end

function M.start(task, ctx)
  local a = task.args
  local h = ctx.entity
  if (a.target == nil) == (a.resource == nil) then
    return inv.failed("bad_args", "args: exactly one of target, resource is required")
  end
  if a.near ~= nil and a.target ~= nil then
    return inv.failed("bad_args", "args.near: only together with resource")
  end
  local e, proto
  if a.target then
    e = inv.resolve_target(ctx, a.target)
    proto = e.prototype
  else
    proto = prototypes.entity[a.resource]
    if proto == nil or proto.type ~= "resource" then
      return inv.failed("bad_args", "args.resource: unknown resource " .. a.resource)
    end
  end
  local why = why_not_minable(h, proto)
  if why then return inv.failed("bad_args", why) end

  local products = item_products(proto)
  task.mode = proto.type == "resource" and "resource" or "entity"
  task.res_name = proto.name
  task.cur = e
  task.center = a.near and { x = a.near.x, y = a.near.y } or (e and util.xy(e.position)) or util.xy(h.position)
  task.primary = products[1]
  task.pset = {}
  for _, n in ipairs(products) do task.pset[n] = true end
  -- база: продукты (опрос каждый тик — только они, get_item_count); для не-руды ещё и весь
  -- инвентарь — полный прирост (постройка отдаёт и своё содержимое) считается только на итоге
  local main = h.get_main_inventory()
  task.base = inv.counts_of(main, task.pset)
  if task.mode ~= "resource" then task.base_all = inv.counts(main) end
  task.last_got = 0
  task.last_gain_tick = ctx.tick
  task.skip = {}
  task.skips = 0
  local per_item = (proto.mineable_properties.mining_time or 1) / mining_speed(h) * 60
  task.timeout = math.max(M.MIN_TIMEOUT, math.ceil(per_item * 3) + 60)
  task.progress = { done = 0, total = task.mode == "resource" and a.count or 1 }
  return nil
end

--- detail.mined: для руды — прирост продуктов (уже посчитан), для остального — весь прирост
--- инвентаря (один get_contents на итоге задачи).
local function mined(task, h, gained)
  if task.mode == "resource" or task.base_all == nil or h == nil or not h.valid then return gained end
  return inv.gain(task.base_all, inv.counts(h.get_main_inventory()))
end

function M.tick(task, ctx)
  local h = ctx.entity
  local gained = inv.gain(task.base, inv.counts_of(h.get_main_inventory(), task.pset))
  local got = task.mode == "resource" and (gained[task.primary] or 0) or inv.sum(gained)
  if got > task.last_got then
    task.last_got = got
    task.last_gain_tick = ctx.tick
  end

  if task.mode == "resource" then
    task.progress.done = math.min(got, task.args.count)
    if got >= task.args.count then
      finish(task, ctx)
      return inv.done({ mined = mined(task, h, gained) })
    end
    if task.cur == nil or not task.cur.valid then
      stop_mining(task, h)
      task.cur = find_next(task, h)
      task.last_gain_tick = ctx.tick
      if task.cur == nil then
        finish(task, ctx)
        local text = got > 0 and ("no more " .. task.res_name .. " nearby") or ("no " .. task.res_name .. " nearby")
        return inv.failed("not_found", text, { mined = mined(task, h, gained) })
      end
    end
  elseif task.cur == nil or not task.cur.valid then
    finish(task, ctx)
    if task.started_mining then
      task.progress.done = 1
      return inv.done({ mined = mined(task, h, gained) })
    end
    return inv.failed("not_found", "target disappeared", { mined = mined(task, h, gained) })
  end

  local r = inv.approach(task, ctx, task.cur, task.mode == "resource" and "resource" or "reach")
  if r == nil then
    stop_mining(task, h)
    task.last_gain_tick = ctx.tick
    return nil
  end
  if r ~= true then
    stop_mining(task, h)
    r.detail = r.detail or { mined = mined(task, h, gained) }
    return r
  end

  if task.primary and not inv.has_room(h, task.primary) then
    finish(task, ctx)
    return inv.full_result(task, ctx, { mined = mined(task, h, gained) })
  end

  if not task.mining or h.selected ~= task.cur then
    h.selected = task.cur
    h.mining_state = { mining = true, position = util.xy(task.cur.position) }
    task.mining = true
    task.started_mining = true
    task.last_gain_tick = ctx.tick
  elseif not (h.mining_state and h.mining_state.mining) then
    h.mining_state = { mining = true, position = util.xy(task.cur.position) }
  end

  if ctx.tick - task.last_gain_tick > task.timeout then
    if task.mode == "resource" then
      task.skip[key(util.xy(task.cur.position))] = true
      task.skips = task.skips + 1
      stop_mining(task, h)
      task.cur = nil
      task.last_gain_tick = ctx.tick
      if task.skips >= M.MAX_SKIPS then
        finish(task, ctx)
        return inv.failed("stuck", "mining gives nothing", { mined = mined(task, h, gained) })
      end
      return nil
    end
    finish(task, ctx)
    return inv.failed("stuck", "target is not being mined", { mined = mined(task, h, gained) })
  end
  return nil
end

function M.stop(task, ctx)
  stop_mining(task, ctx.entity)
  inv.stop_approach(task, ctx)
end

return M
