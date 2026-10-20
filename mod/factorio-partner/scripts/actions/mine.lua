-- Действие `mine`. Контракт: docs/ACTIONS.md, PROTOCOL.md §6.
--
-- args: target │ resource:string │ item:string, near?:pos (с resource или item), count:int.
-- * resource — ближайшая к помощнику руда этого имени в радиусе 64 от near (или от места
--   помощника на старте), только в открытых чанках; кончилась клетка — следующая. Готово, когда
--   основной продукт руды вырос на count. done.detail = {mined: items} — прирост продуктов.
-- * target — конкретная сущность своей силы или neutral: клетка руды (дальше как resource,
--   соседние клетки той же руды вокруг неё), дерево, камень или своя постройка — копаем, пока не
--   исчезнет; count для не-руды не используется. mined — весь прирост инвентаря.
-- * item — «набери count этого предмета» (например, вольфрам из камней). Источники — всё, что рукой даёт этот предмет:
--   камни, деревья, рыба (`simple-entity`, `tree`, `fish`, сила neutral) и руда, которую можно копать
--   руками; что копается и что даёт — из прототипов игры. Мод сам идёт от источника к источнику без
--   остановок и выбирает выгодный, а не ближний: ожидаемый выход предмета / (путь + добыча).
--   Готово, когда предмет вырос на count; источники в радиусе 64 кончились — not_found с
--   накопанным. mined — весь прирост инвентаря (камень даёт и попутное).
-- Честно (PROTOCOL §6.5): только `selected` + `mining_state`, время и выход тратит движок;
-- `mine_entity` запрещён. Подход сам: руда, а также деревья и камни — resource_reach_distance
-- (с reach_distance движок их не добывает), своя постройка — reach_distance.
-- Контроль прироста: нет прироста дольше 3× времени добычи (≥ 5 с) — клетку пропускаем
-- (до 5 раз, потом stuck); полный инвентарь — событие inventory_full и failed{stuck}.
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")

local perms = require("scripts.core.perms")

local M = {}
M.name = "mine"

--- Разрешения хозяина (scripts/core/perms.lua): какие ключи задевают эти аргументы.
--- Руда — всегда можно; цель-постройка — как её разбор (perms.dig_keys). Режим item сам выбирает
--- источник: деревья и камни в нём отсекает start. Цель проверяется ещё раз в start — по той
--- сущности, что найдена, когда задача началась.
function M.perms(a, ctx)
  local non_ore = false
  if a.target ~= nil then
    return perms.dig_keys(perms.find(ctx, a.target))
  elseif a.resource ~= nil then
    local proto = prototypes.entity[a.resource]
    non_ore = proto ~= nil and proto.type ~= "resource"
  end
  if non_ore then return { "perm-chop" } end
  return {}
end
M.schema = {
  target = { type = "target" },
  resource = { type = "string", max = 100 },
  item = { type = "string", max = 100 },
  near = { type = "pos" },
  count = { type = "int", required = true, min = 1, max = 100000 },
}

M.SEARCH_RADIUS = 64   -- от near / места старта
M.LOCAL_RADIUS = 6     -- сначала ищем совсем рядом с помощником (дёшево)
M.MAX_SKIPS = 5
M.MIN_TIMEOUT = 300    -- тиков без прироста до пропуска клетки
M.WALK_SPEED = 0.15    -- клеток за тик, если скорость бега тела не прочесть
M.ITEM_SOURCES = { tree = true, ["simple-entity"] = true, fish = true } -- не-руда для item

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

--- Ожидаемое число предмета item за одну добычу (amount или среднее min/max, с вероятностью).
local function expected(proto, item)
  local mp = proto.mineable_properties
  local n = 0
  for _, p in ipairs(mp and mp.products or {}) do
    if (p.type == nil or p.type == "item") and p.name == item then
      local a = p.amount
      if type(a) ~= "number" then a = ((p.amount_min or 0) + (p.amount_max or p.amount_min or 0)) / 2 end
      n = n + a * (type(p.probability) == "number" and p.probability or 1)
    end
  end
  return n
end

--- Режим item: имена прототипов, которые рукой дают предмет, и их выход {per, ticks, resource}.
local function item_sources(h, item, ore_only)
  local names, info = {}, {}
  local speed = mining_speed(h)
  for name, proto in pairs(prototypes.entity) do
    local t = proto.type
    if (t == "resource" or (M.ITEM_SOURCES[t] and not ore_only)) and why_not_minable(h, proto) == nil then
      local per = expected(proto, item)
      if per > 0 then
        names[#names + 1] = name
        info[name] = { per = per, resource = t == "resource",
          ticks = (proto.mineable_properties.mining_time or 1) / speed * 60 }
      end
    end
  end
  table.sort(names)
  return names, info
end

local function walk_speed(h)
  local ok, v = pcall(function() return h.character_running_speed end)
  return (ok and type(v) == "number" and v > 0) and v or M.WALK_SPEED
end

--- Режим item: самый выгодный источник — больше предмета за тик пути и добычи.
local function find_best(task, h, got)
  local hp = util.xy(h.position)
  local need = math.max(1, task.args.count - got)
  local walk = walk_speed(h)
  local charted = {}
  local best, bs
  local list = h.surface.find_entities_filtered{ name = task.src_names, position = task.center, radius = M.SEARCH_RADIUS }
  for _, e in ipairs(list) do
    local inf = e.valid and task.src[e.name]
    -- amount есть только у руды: у камня чтение поля — ошибка движка
    if inf and inv.allowed_force(h, e) and (not inf.resource or (e.amount or 0) > 0) then
      local p = util.xy(e.position)
      local ck = math.floor(p.x / 32) .. ":" .. math.floor(p.y / 32)
      if charted[ck] == nil then charted[ck] = inv.charted(h, p) and true or false end
      if charted[ck] and not task.skip[key(p)] then
        local cycles = 1
        if inf.resource then cycles = math.max(1, math.min(e.amount or 1, math.ceil(need / inf.per))) end
        local score = inf.per * cycles / (cycles * inf.ticks + util.dist(p, hp) / walk)
        if bs == nil or score > bs then best, bs = e, score end
      end
    end
  end
  return best
end

function M.start(task, ctx)
  local a = task.args
  local h = ctx.entity
  local n = (a.target and 1 or 0) + (a.resource and 1 or 0) + (a.item and 1 or 0)
  if n ~= 1 then
    return inv.failed("bad_args", "args: exactly one of target, resource, item is required")
  end
  if a.near ~= nil and a.target ~= nil then
    return inv.failed("bad_args", "args.near: only together with resource or item")
  end
  if a.item then
    if prototypes.item[a.item] == nil then
      return inv.failed("bad_args", "args.item: unknown item " .. a.item)
    end
    -- деревья и камни при запрете или «спросить» без разрешения (perm-chop) не берутся
    local chop_code, chop_text = perms.refusal({ "perm-chop" }, task)
    local names, info = item_sources(h, a.item, chop_code ~= nil)
    if #names == 0 and chop_code ~= nil and #item_sources(h, a.item, false) > 0 then
      return inv.failed(chop_code, chop_text)
    end
    if #names == 0 then
      return inv.failed("bad_args", "nothing gives " .. a.item .. " when mined by hand")
    end
    task.mode = "item"
    task.src_names, task.src = names, info
    task.center = a.near and { x = a.near.x, y = a.near.y } or util.xy(h.position)
    task.primary = a.item
    task.pset = { [a.item] = true }
    local main = h.get_main_inventory()
    task.base = inv.counts_of(main, task.pset)
    task.base_all = inv.counts(main)
    task.last_got = 0
    task.last_gain_tick = ctx.tick
    task.skip = {}
    task.skips = 0
    local slow = 0
    for _, i in pairs(info) do slow = math.max(slow, i.ticks) end
    task.timeout = math.max(M.MIN_TIMEOUT, math.ceil(slow * 3) + 60)
    task.progress = { done = 0, total = a.count }
    return nil
  end
  local e, proto
  if a.target then
    e = inv.resolve_target(ctx, a.target)
    local pcode, ptext, pdata = perms.refusal(perms.dig_keys(e), task)
    if pcode ~= nil then return inv.failed(pcode, ptext, pdata) end
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
  local counted = task.mode ~= "entity"
  local got = counted and (gained[task.primary] or 0) or inv.sum(gained)
  if got > task.last_got then
    task.last_got = got
    task.last_gain_tick = ctx.tick
  end

  if counted then
    task.progress.done = math.min(got, task.args.count)
    if got >= task.args.count then
      finish(task, ctx)
      return inv.done({ mined = mined(task, h, gained) })
    end
    if task.cur == nil or not task.cur.valid then
      stop_mining(task, h)
      if task.mode == "item" then
        task.cur = find_best(task, h, got)
      else
        task.cur = find_next(task, h)
      end
      task.last_gain_tick = ctx.tick
      if task.cur == nil then
        finish(task, ctx)
        local what = task.mode == "item" and ("sources of " .. task.primary) or task.res_name
        local text = got > 0 and ("no more " .. what .. " nearby") or ("no " .. what .. " nearby")
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

  -- руда — resource_reach_distance; деревья и камни — тоже вплотную ("near"); постройка — reach
  local r = inv.approach(task, ctx, task.cur, task.cur.type == "resource" and "resource" or inv.dig_kind(task.cur))
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
    if counted then
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
