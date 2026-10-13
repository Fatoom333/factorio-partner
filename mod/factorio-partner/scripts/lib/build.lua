-- Стройка: общие функции потока F (place, build_blueprint, build_ghosts, deconstruct).
-- Контракты: docs/ACTIONS.md («Подход», build_blueprint, build_ghosts, deconstruct),
-- PROTOCOL.md §6 (честность: без предметов из воздуха, досягаемость build_distance, только своя
-- сила/neutral, только quality normal, §6.5 — проверки постановки), §7 (резерв области).
--
-- Что здесь:
-- * цель и обзор: M.resolve (через scripts.core.target), M.visible (через scripts.core.vis);
-- * геометрия: размер постройки, «тело стоит на месте постройки», точка «отойти в сторону»;
-- * подход к точке M.approach (через ctx.approach) и его сброс;
-- * личные дроны M.robots, проверка «призрак заблокирован» M.blocked (ghost_revive);
-- * постройка призрака руками M.revive: досягаемость → ghost_revive → revive{raise_revive} →
--   списание предмета из инвентаря помощника; не списалось → откат (постройка убирается);
-- * «движок» призраков M.ghosts_start/tick/stop — общий для build_ghosts и build_blueprint:
--   режимы auto/hand/robots, blocked, missing, прогресс {built, left}, свой отсчёт «застрял».
--
-- Призрак руками строится через LuaEntity.revive, а не create_entity: так сохраняются настройки
-- призрака (рецепт, фильтры, запросы модулей), как при постройке игроком поверх призрака.
-- Предмет при этом списывается ровно так же, как в §6.5 (remove_item, quality normal).
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local reserve = require("scripts.core.reserve")
local inv = require("scripts.lib.inventory")

local M = {}

M.NORMAL = "normal"
M.SCAN_EVERY = 60            -- пересчёт призраков области, тиков
M.BUILD_EVERY = 5            -- пауза между постройками руками, тиков
M.MAX_BLOCK_CHECKS = 1000    -- проверок ghost_revive за один пересчёт
M.MAX_TRACK = 2000           -- столько призраков отслеживаем поштучно (кто построен дронами)
M.MAX_LIST = 20              -- длина списков blocked/skipped в detail (событие ≤ 4000 байт)
M.OWN_STUCK = 58 * 60        -- свой «застрял» чуть раньше ядра (60 с), чтобы отдать detail
M.ROBOT_PATIENCE = 120 * 60  -- сколько ждём летящих дронов без единой постройки
M.AUTO_FALLBACK = 30 * 60    -- auto: дроны стоят столько без постройки → дальше руками
M.MAX_ASIDE = 2              -- попыток отойти с места постройки
M.BODY_MARGIN = 0.3          -- тело ±0.2 + запас

-- ------------------------------------------------------------------ модули ревизии 3.1

-- scripts.core.vis и scripts.core.target появляются в ревизии 3.1 (поток X, PLAN.md). Пока их
-- нет в дереве, работает запасная реализация по тому же контракту; любая другая ошибка
-- загрузки (синтаксис и т.п.) не глотается.
local function optional(name)
  local ok, m = pcall(require, name)
  if ok then return type(m) == "table" and m or nil end
  local text = tostring(m)
  if text:find("not found", 1, true) or text:find("no such file", 1, true) or text:find("no file", 1, true) then
    return nil
  end
  error(m, 0)
end

local function chunk_of(pos)
  return { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) }
end

local fallback_vis = {}
--- PROTOCOL §6.7: чанк виден силе либо точка не дальше 32 клеток от живого тела помощника.
function fallback_vis.visible(helper_id, surface, pos)
  local p = util.xy(pos)
  local rec = helper_id and storage.helpers and storage.helpers[helper_id]
  local body = rec and rec.state == "alive" and rec.entity
  if not (body and body.valid) then return false end
  if body.surface.index == surface.index and util.dist(util.xy(body.position), p) <= 32 then return true end
  return body.force.is_chunk_visible(surface, chunk_of(p)) and true or false
end

local fallback_target = {}
--- ACTIONS.md «target»: {unit_number, pos?} │ {name, pos} на поверхности surface → LuaEntity | nil.
function fallback_target.resolve(surface, t)
  if type(t) ~= "table" then return nil end
  local e
  if t.unit_number ~= nil then
    e = game.get_entity_by_unit_number(t.unit_number)
    if (e == nil or not e.valid) and t.pos ~= nil then
      e = nil
      for _, x in ipairs(surface.find_entities_filtered{ position = t.pos, radius = 2 }) do
        if x.valid and x.unit_number == t.unit_number then e = x break end
      end
    end
  elseif t.name ~= nil and t.pos ~= nil then
    if prototypes.entity[t.name] == nil then return nil end
    local bd
    for _, x in ipairs(surface.find_entities_filtered{ name = t.name, position = t.pos, radius = 2 }) do
      if x.valid then
        local d = util.dist(util.xy(x.position), t.pos)
        if bd == nil or d < bd then e, bd = x, d end
      end
    end
  end
  if e == nil or not e.valid then return nil end
  return e
end

local vis = optional("scripts.core.vis") or fallback_vis
local target = optional("scripts.core.target") or fallback_target
M.fallback_vis = fallback_vis
M.fallback_target = fallback_target

-- ------------------------------------------------------------------ результаты

M.failed = inv.failed
M.done = inv.done

-- ------------------------------------------------------------------ обзор и цель

function M.charted(h, pos)
  return h.force.is_chunk_charted(h.surface, chunk_of(pos)) and true or false
end

--- Все чанки, которые задевает область, открыты?
function M.area_charted(h, area)
  local a, b = chunk_of(area.left_top), chunk_of(area.right_bottom)
  for cx = a.x, b.x do
    for cy = a.y, b.y do
      if not h.force.is_chunk_charted(h.surface, { x = cx, y = cy }) then return false end
    end
  end
  return true
end

--- Живое в точке видно помощнику (PROTOCOL §6.7) — общая проверка ядра.
function M.visible(ctx, pos)
  return vis.visible(ctx.helper_id, ctx.entity.surface, pos) and true or false
end

--- Цель действия: сущность на поверхности помощника, своей силы или neutral, в открытом чанке.
--- Иначе err: not_found │ not_reachable (другая поверхность) │ not_charted.
function M.resolve(ctx, t)
  local h = ctx.entity
  local e = target.resolve(h.surface, t)
  if e == nil or not e.valid then err.raise("not_found", "target not found") end
  if e.surface.index ~= h.surface.index then err.raise("not_reachable", "target is on another surface") end
  if not inv.allowed_force(h, e) then err.raise("not_found", "target is not of own or neutral force") end
  if not M.charted(h, util.xy(e.position)) then err.raise("not_charted", "target is in an uncharted chunk") end
  return e
end

-- ------------------------------------------------------------------ прототипы и геометрия

--- Предметы, которыми ставится постройка: {{name, count}, ...} (items_to_place_this).
function M.place_items(proto)
  local out = {}
  local list = proto and proto.items_to_place_this
  if type(list) ~= "table" then return out end
  for _, it in ipairs(list) do
    if type(it) == "string" then
      out[#out + 1] = { name = it, count = 1 }
    elseif type(it) == "table" and type(it.name) == "string" then
      local n = tonumber(it.count) or 1
      if n >= 1 then out[#out + 1] = { name = it.name, count = n } end
    end
  end
  return out
end

--- Полуразмеры постройки по осям с учётом поворота (4/12 — оси меняются местами).
function M.half_size(proto, dir)
  local hx, hy = 0.5, 0.5
  local cb = proto and proto.collision_box
  if type(cb) == "table" then
    local lt, rb = cb.left_top or cb[1], cb.right_bottom or cb[2]
    if lt and rb then
      hx = math.max(math.abs(lt.x or lt[1]), math.abs(rb.x or rb[1]))
      hy = math.max(math.abs(lt.y or lt[2]), math.abs(rb.y or rb[2]))
    end
  elseif proto and proto.tile_width and proto.tile_height then
    hx, hy = proto.tile_width / 2, proto.tile_height / 2
  end
  if dir == 4 or dir == 12 then hx, hy = hy, hx end
  return hx, hy
end

--- Размер в клетках (для привязки к сетке) с учётом поворота.
function M.tile_size(proto, dir)
  local hx, hy = M.half_size(proto, 0)
  local w = (proto and proto.tile_width) or math.max(1, math.ceil(hx * 2 - 0.01))
  local h = (proto and proto.tile_height) or math.max(1, math.ceil(hy * 2 - 0.01))
  if dir == 4 or dir == 12 then w, h = h, w end
  return w, h
end

function M.footprint(proto, pos, dir)
  local hx, hy = M.half_size(proto, dir)
  return {
    left_top = { x = pos.x - hx, y = pos.y - hy },
    right_bottom = { x = pos.x + hx, y = pos.y + hy },
  }
end

--- Тело помощника стоит на месте будущей постройки?
function M.body_inside(h, proto, pos, dir)
  local hx, hy = M.half_size(proto, dir)
  local p = util.xy(h.position)
  return math.abs(p.x - pos.x) < hx + M.BODY_MARGIN and math.abs(p.y - pos.y) < hy + M.BODY_MARGIN
end

--- Куда отойти, чтобы не мешать постройке: от её центра в сторону тела.
function M.aside_point(h, proto, pos, dir)
  local hx, hy = M.half_size(proto, dir)
  local p = util.xy(h.position)
  local dx, dy = p.x - pos.x, p.y - pos.y
  local d = math.sqrt(dx * dx + dy * dy)
  if d < 0.05 then dx, dy, d = 1, 0, 1 end
  local r = math.sqrt(hx * hx + hy * hy) + 1.5
  return { x = pos.x + dx / d * r, y = pos.y + dy / d * r }
end

-- ------------------------------------------------------------------ подход к точке

--- Подойти к точке pos ближе within (ACTIONS.md «Подход»).
--- → true (на месте) │ nil (иду) │ result (ошибка пути). Состояние: task._goal, task._tries.
function M.approach(task, ctx, pos, within)
  local h = ctx.entity
  if util.dist(util.xy(h.position), pos) <= within then
    if task._goal ~= nil then
      ctx.cancel_approach(task)
      task._goal = nil
    end
    task._tries = nil
    return true
  end
  local tries = task._tries or 0
  local d = within > 2 and (within - 1.5 - tries) or (within * 0.75)
  if d < 0.3 then d = 0.3 end
  local key = string.format("%.2f:%.2f:%.2f", pos.x, pos.y, d)
  if task._goal ~= key then
    if task._goal ~= nil then ctx.cancel_approach(task) end
    task.approach = nil
    task._goal = key
  end
  local r = ctx.approach(task, pos, d)
  if r == true then
    task._goal = nil
    if util.dist(util.xy(h.position), pos) <= within then
      task._tries = nil
      return true
    end
    task._tries = tries + 1
    if task._tries > 3 then
      task._tries = nil
      return { status = "failed", code = "stuck", text = "cannot get within build distance" }
    end
    task.approach = nil
    return nil
  end
  if r ~= nil then
    task._goal = nil
    task._tries = nil
  end
  return r
end

function M.stop_approach(task, ctx)
  ctx.cancel_approach(task)
  task._goal = nil
  task._tries = nil
end

-- ------------------------------------------------------------------ резерв области

--- Занять область на время задачи (ядро снимает резерв, когда задача кончилась).
--- Пересечение с областью другого помощника → err `reserved`.
function M.hold_area(ctx, area)
  reserve.hold_area(ctx.helper_id, area)
end

--- Область занята другим помощником? → err `reserved`.
function M.check_free(ctx, area)
  local other = reserve.area_holder(ctx.helper_id, area)
  if other then err.raise("reserved", "area is reserved by helper " .. other) end
end

-- ------------------------------------------------------------------ дроны и призраки

local function read(obj, field)
  local ok, v = pcall(function() return obj[field] end)
  if ok then return v end
  return nil
end

--- Личные строительные дроны помощника: {total, available, radius} или nil (робопорта нет).
function M.robots(h)
  local cell = read(h, "logistic_cell")
  if cell == nil or cell.valid == false then return nil end
  local net = read(cell, "logistic_network")
  if net == nil or net.valid == false then return nil end
  return {
    total = read(net, "all_construction_robots") or 0,
    available = read(net, "available_construction_robots") or 0,
    radius = read(cell, "construction_radius") or 0,
  }
end

local function set_dispatch(h, on)
  pcall(function() h.allow_dispatching_robots = on end)
end

--- Призрак «заблокирован» (PROTOCOL §6.5): проверка ghost_revive = false.
function M.blocked(surface, ghost)
  return not surface.can_place_entity{
    name = ghost.ghost_name,
    position = ghost.position,
    direction = ghost.direction,
    force = ghost.force,
    build_check_type = defines.build_check_type.ghost_revive,
  }
end

function M.ghost_key(name, pos)
  return string.format("%s|%.2f|%.2f", name, pos.x, pos.y)
end

--- Вернуть помощнику предметы, которые лежали под постройкой (revive отдаёт их списком).
local function give_collided(h, collided)
  if type(collided) ~= "table" then return end
  for k, v in pairs(collided) do
    local name, count, quality
    if type(v) == "table" then name, count, quality = v.name, v.count, v.quality else name, count = k, v end
    if type(name) == "string" and type(count) == "number" and count > 0 then
      local q = type(quality) == "table" and quality.name or quality or M.NORMAL
      local put = 0
      if q == M.NORMAL then put = h.insert{ name = name, count = count, quality = M.NORMAL } end
      if put < count then
        h.surface.spill_item_stack{
          position = h.position, stack = { name = name, count = count - put, quality = q },
          enable_looted = true, allow_belts = false,
        }
      end
    end
  end
end

--- Построить призрак руками. entry = {e = призрак, item, count}.
--- → LuaEntity │ nil, причина: "gone" │ "quality" │ "not_visible" │ "far" │ "no_items" │
---   "body" (мешает само тело) │ "blocked".
function M.revive(ctx, entry)
  local h, g = ctx.entity, entry.e
  if g == nil or not g.valid then return nil, "gone" end
  if not inv.is_normal(g.quality) then return nil, "quality" end
  local pos = util.xy(g.position)
  if not M.visible(ctx, pos) then return nil, "not_visible" end
  if util.dist(util.xy(h.position), pos) > h.build_distance then return nil, "far" end
  local main = h.get_main_inventory()
  if inv.count(main, entry.item) < entry.count then return nil, "no_items" end
  if M.blocked(g.surface, g) then
    if M.body_inside(h, g.ghost_prototype, pos, g.direction) then return nil, "body" end
    return nil, "blocked"
  end
  local collided, e = g.revive{ raise_revive = true }
  if e == nil or not e.valid then return nil, "blocked" end
  local removed = h.remove_item{ name = entry.item, count = entry.count, quality = M.NORMAL }
  if removed < entry.count then
    -- предмет не списался: постройки из воздуха не бывает — убираем её, частично списанное возвращаем
    if removed > 0 then h.insert{ name = entry.item, count = removed, quality = M.NORMAL } end
    e.destroy{ raise_destroy = true }
    return nil, "no_items"
  end
  give_collided(h, collided)
  return e
end

-- ------------------------------------------------------------------ движок призраков

local function detail_of(g)
  return {
    built = g.built, left = g.left, blocked = g.blocked, blocked_total = g.blocked_total,
    missing = g.missing,
  }
end
M.ghost_detail = function(task) return detail_of(task.g) end

local function set_progress(task)
  local g = task.g
  task.progress = { done = g.built, total = g.built + g.left, built = g.built, left = g.left }
end

--- Пересчёт призраков области: что строимо (и чем), что заблокировано, чего не хватает.
local function scan(task, ctx)
  local g, h, tick = task.g, ctx.entity, ctx.tick
  local surface = h.surface
  local found = surface.find_entities_filtered{
    area = { g.area.left_top, g.area.right_bottom }, type = "entity-ghost", force = h.force,
  }
  local hp = util.xy(h.position)
  local chunks = {}
  local function charted(p)
    local k = math.floor(p.x / 32) .. ":" .. math.floor(p.y / 32)
    if chunks[k] == nil then chunks[k] = M.charted(h, p) end
    return chunks[k]
  end
  local entries = {}
  for _, e in ipairs(found) do
    if e.valid then
      local p = util.xy(e.position)
      if charted(p) then entries[#entries + 1] = { e = e, pos = p, d = util.dist(p, hp) } end
    end
  end
  -- ближние первыми: им достаются предметы, если хватает не на все
  table.sort(entries, function(a, b) return a.d < b.d end)

  local main = h.get_main_inventory()
  local budget = {}
  local function take(name, n)
    if budget[name] == nil then budget[name] = inv.count(main, name) end
    if budget[name] >= n then
      budget[name] = budget[name] - n
      return true
    end
    return false
  end

  local cur, n_cur = {}, 0
  local list, blocked, blocked_total, missing, left, checks = {}, {}, 0, {}, 0, 0
  for _, en in ipairs(entries) do
    local e = en.e
    local name = e.ghost_name
    local key = M.ghost_key(name, en.pos)
    n_cur = n_cur + 1
    cur[key] = { n = name, x = en.pos.x, y = en.pos.y }
    local proto = e.ghost_prototype
    local items = M.place_items(proto)
    local reason = g.skip[key]
    local body = false
    if reason == nil then
      if not inv.is_normal(e.quality) then
        reason = "quality"
      elseif #items == 0 then
        reason = "no_item"
      else
        checks = checks + 1
        if checks <= M.MAX_BLOCK_CHECKS and M.blocked(surface, e) then
          -- мешает само тело помощника — это не «заблокирован»: отойдём
          if M.body_inside(h, proto, en.pos, e.direction) then body = true else reason = "blocked" end
        end
      end
    end
    if reason then
      blocked_total = blocked_total + 1
      if #blocked < M.MAX_LIST then
        blocked[#blocked + 1] = { name = name, pos = util.pos(en.pos), reason = reason }
      end
    else
      left = left + 1
      local chosen
      for _, it in ipairs(items) do
        if not inv.has_data(it.name) and take(it.name, it.count) then chosen = it break end
      end
      if chosen then
        list[#list + 1] = {
          e = e, key = key, name = name, pos = en.pos, item = chosen.name, count = chosen.count, body = body,
        }
      else
        missing[items[1].name] = (missing[items[1].name] or 0) + items[1].count
      end
    end
  end

  -- кто исчез с прошлого пересчёта и стал постройкой — построен (дронами или кем-то ещё)
  local before = g.built
  if g.seen ~= nil then
    for key, s in pairs(g.seen) do
      if cur[key] == nil and surface.find_entity(s.n, { x = s.x, y = s.y }) ~= nil then
        g.built = g.built + 1
      end
    end
  elseif g.scanned and left < g.left then
    g.built = g.built + (g.left - left)
  end
  if g.built ~= before then g.last_built = tick end
  if g.built ~= before or left ~= g.left then g.last_progress = tick end

  g.seen = n_cur <= M.MAX_TRACK and cur or nil
  g.list, g.blocked, g.blocked_total, g.missing, g.left = list, blocked, blocked_total, missing, left
  g.scanned = true
  g.scan_tick = tick
  g.next_scan = tick + M.SCAN_EVERY
  g.r_tick = nil
  -- текущая цель рук осталась в списке — вынимаем её оттуда, иначе её забудут
  if g.cur ~= nil then
    local keep = false
    for i, en in ipairs(list) do
      if en.key == g.cur.key then
        g.cur.item, g.cur.count, g.cur.e = en.item, en.count, en.e
        list[i] = list[#list]
        list[#list] = nil
        keep = true
        break
      end
    end
    if not keep then g.cur = nil end
  end
  set_progress(task)
end

--- Вынуть из списка ближайший к помощнику живой призрак.
local function next_entry(g, h)
  local hp = util.xy(h.position)
  local list = g.list
  local best, bd
  local i = 1
  while i <= #list do
    local en = list[i]
    if not en.e.valid then
      list[i] = list[#list]
      list[#list] = nil
    else
      local d = util.dist(en.pos, hp)
      if bd == nil or d < bd then best, bd = i, d end
      i = i + 1
    end
  end
  if best == nil then return nil end
  local en = list[best]
  list[best] = list[#list]
  list[#list] = nil
  return en
end

local function soon(g, tick, dt)
  if g.next_scan > tick + dt then g.next_scan = tick + dt end
end

local function drop_cur(task, ctx, reason)
  local g = task.g
  if g.cur ~= nil and reason ~= nil then g.skip[g.cur.key] = reason end
  g.cur = nil
  g.aside = nil
  M.stop_approach(task, ctx)
  soon(g, ctx.tick, 30)
end

local function hand_step(task, ctx)
  local g, h, tick = task.g, ctx.entity, ctx.tick
  if g.next_build ~= nil and tick < g.next_build then return nil end
  local cur = g.cur
  if cur ~= nil and not cur.e.valid then
    -- призрак пропал, пока шли (построил дрон или игрок, либо убрали) — разберётся пересчёт
    drop_cur(task, ctx, nil)
    cur = nil
  end
  if cur == nil then
    cur = next_entry(g, h)
    if cur == nil then
      soon(g, tick, 0)
      return nil
    end
    g.cur = cur
    g.asides = 0
    g.aside = nil
  end
  if g.aside ~= nil then
    local r = M.approach(task, ctx, g.aside, 0.6)
    if r == nil then return nil end
    g.aside = nil
    if r ~= true then
      drop_cur(task, ctx, "blocked")
      return nil
    end
  end
  local r = M.approach(task, ctx, cur.pos, h.build_distance - 0.5)
  if r == nil then return nil end
  if r ~= true then
    -- до этого призрака не дойти: помечаем причиной и строим остальные
    drop_cur(task, ctx, r.code or "path_failed")
    return nil
  end
  local e, why = M.revive(ctx, cur)
  if e ~= nil then
    g.built = g.built + 1
    g.left = math.max(0, g.left - 1)
    if g.seen ~= nil then g.seen[cur.key] = nil end
    g.last_built = tick
    g.last_progress = tick
    g.cur = nil
    g.next_build = tick + M.BUILD_EVERY
    set_progress(task)
    return nil
  end
  if why == "body" and (g.asides or 0) < M.MAX_ASIDE then
    g.asides = (g.asides or 0) + 1
    g.aside = M.aside_point(h, cur.e.ghost_prototype, cur.pos, cur.e.direction)
    return nil
  end
  if why == "gone" or why == "no_items" or why == "far" then
    drop_cur(task, ctx, nil)
  else
    drop_cur(task, ctx, why == "body" and "blocked" or why)
  end
  return nil
end

local function robots_step(task, ctx, rb, busy)
  local g, h, tick = task.g, ctx.entity, ctx.tick
  if g.r_tick == nil or tick - g.r_tick >= 10 then
    local hp = util.xy(h.position)
    local r = math.max(1, rb.radius - 1)
    local in_range, near, nd, body = 0, nil, nil, nil
    for _, en in ipairs(g.list) do
      if en.e.valid then
        local dx, dy = math.abs(en.pos.x - hp.x), math.abs(en.pos.y - hp.y)
        if dx <= r and dy <= r then
          in_range = in_range + 1
          if en.body and body == nil then body = en end
        else
          local d = util.dist(en.pos, hp)
          if nd == nil or d < nd then near, nd = en, d end
        end
      end
    end
    g.r_tick, g.in_range = tick, in_range
    g.near = near and { x = near.pos.x, y = near.pos.y } or nil
    g.near_key = near and near.key or nil
    g.r_aside = nil
    if body ~= nil and (g.body_tries or 0) < M.MAX_ASIDE then
      g.body_tries = (g.body_tries or 0) + 1
      g.r_aside = M.aside_point(h, body.e.ghost_prototype, body.pos, body.e.direction)
    end
  end
  if g.r_aside ~= nil then
    -- стоим на месте призрака: дроны его не построят, пока не отойдём
    local r = M.approach(task, ctx, g.r_aside, 0.6)
    if r == nil then return nil end
    g.r_aside = nil
    soon(g, tick, 0)
    return nil
  end
  if g.in_range > 0 then
    if g.walking then
      M.stop_approach(task, ctx)
      g.walking = false
    end
    if g.wait_since == nil or g.wait_built ~= g.built then
      g.wait_since, g.wait_built = tick, g.built
    end
    -- дроны в полёте — законно стоим на месте: «пульс», чтобы ядро не сняло задачу как stuck
    if busy and tick - g.last_built < M.ROBOT_PATIENCE then
      task.progress_tick = tick
      g.last_progress = tick
    end
    if g.mode == "auto" and tick - g.wait_since >= M.AUTO_FALLBACK then
      g.fallback = true
      g.last_progress = tick
    end
    return nil
  end
  g.wait_since = nil
  if g.near == nil then
    soon(g, tick, 0)
    return nil
  end
  g.walking = true
  local r = M.approach(task, ctx, g.near, math.max(2, rb.radius - 3))
  if r == nil then return nil end
  g.walking = false
  g.r_tick = nil
  if r ~= true then
    if g.near_key ~= nil then g.skip[g.near_key] = r.code or "path_failed" end
    M.stop_approach(task, ctx)
    soon(g, tick, 0)
  end
  return nil
end

--- Начать стройку призраков области area в режиме mode ("auto"│"hand"│"robots").
function M.ghosts_start(task, ctx, area, mode)
  local h = ctx.entity
  task.g = {
    area = area, mode = mode, built = 0, left = 0, blocked = {}, blocked_total = 0, missing = {},
    list = {}, skip = {}, next_scan = 0, scanned = false,
    last_progress = ctx.tick, last_built = ctx.tick,
  }
  if M.robots(h) ~= nil then
    if mode == "hand" then
      -- «только руками»: личные дроны на время задачи не вылетают
      local prev = read(h, "allow_dispatching_robots")
      task.g.prev_dispatch = prev == nil and true or prev
      set_dispatch(h, false)
    else
      set_dispatch(h, true)
    end
  end
  set_progress(task)
  return nil
end

--- Снять своё: подход и переключатель дронов. Можно звать много раз.
function M.ghosts_stop(task, ctx)
  M.stop_approach(task, ctx)
  local g = task.g
  local h = ctx.entity
  if g ~= nil and g.prev_dispatch ~= nil and h ~= nil and h.valid then
    set_dispatch(h, g.prev_dispatch)
    g.prev_dispatch = nil
  end
end

local function finish(task, ctx, res)
  M.ghosts_stop(task, ctx)
  res.detail = res.detail or detail_of(task.g)
  return res
end

--- Тик стройки призраков: nil — работаю, result — готово.
function M.ghosts_tick(task, ctx)
  local g, h, tick = task.g, ctx.entity, ctx.tick
  -- свой учёт прогресса: сдвиг тела и число предметов (как у ядра), плюс постройки и «пульс»
  if g.pos == nil or (tick - task.started_tick) % 30 == 0 then
    local p = util.xy(h.position)
    local n = h.get_main_inventory().get_item_count()
    if g.pos == nil or util.dist(p, g.pos) >= 0.1 or n ~= g.inv_n then
      g.pos, g.inv_n, g.last_progress = p, n, tick
    end
  end
  if tick >= g.next_scan then scan(task, ctx) end
  if g.left == 0 then
    return finish(task, ctx, M.done(detail_of(g)))
  end

  local rb = M.robots(h)
  local has_robots = rb ~= nil and rb.total > 0
  if g.mode == "robots" and not has_robots then
    return finish(task, ctx, M.failed("no_items",
      "no personal construction robots (roboport in armor and robots in inventory)", detail_of(g)))
  end
  local use_robots = g.mode == "robots" or (g.mode == "auto" and has_robots and not g.fallback)
  local busy = has_robots and rb.available < rb.total

  if #g.list == 0 and g.cur == nil then
    if busy and tick - g.last_built < M.ROBOT_PATIENCE then
      -- дроны уже унесли предметы и летят строить — ждём их (в любом режиме: они могли
      -- вылететь ещё до начала задачи)
      task.progress_tick = tick
      g.last_progress = tick
      return nil
    end
    if g.scan_tick ~= tick then
      soon(g, tick, 0)
      return nil
    end
    return finish(task, ctx, M.failed("no_items", "not enough items for the remaining ghosts", detail_of(g)))
  end

  local r
  if use_robots then r = robots_step(task, ctx, rb, busy) else r = hand_step(task, ctx) end
  if r ~= nil then return finish(task, ctx, r) end
  if tick - g.last_progress >= M.OWN_STUCK then
    return finish(task, ctx, M.failed("stuck", "no progress for 60 s", detail_of(g)))
  end
  return nil
end

return M
