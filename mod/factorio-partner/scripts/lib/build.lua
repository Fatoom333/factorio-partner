-- Стройка: общие функции (place, build_blueprint, build_ghosts, deconstruct).
-- Контракты: docs/ACTIONS.md («Подход», build_blueprint, build_ghosts, deconstruct),
-- PROTOCOL.md §6 (честность: без предметов из воздуха, досягаемость build_distance, только своя
-- сила/neutral, только quality normal, §6.5 — проверки постановки), §7 (резерв области).
--
-- Что здесь:
-- * цель и обзор: M.resolve (scripts.core.target через lib/inventory), M.visible (scripts.core.vis);
-- * геометрия: размер постройки, «тело стоит на месте постройки», точка «отойти в сторону»;
-- * подход к точке M.approach (через ctx.approach) и его сброс;
-- * разбор руками M.dig_new/M.dig_step (selected + mining_state до исчезновения) — общий для
--   deconstruct и для разбора помеченного к сносу перед стройкой;
-- * личные дроны M.robots, проверка «призрак заблокирован» M.blocked (ghost_revive);
-- * свойства плиток из игры (PROTOCOL §6.12, имён плиток в коде нет): M.masks_collide, M.cover_tile
--   (default_cover_tile), M.cover_available (предмет подложки открыт силе, есть у помощника или на
--   складах), M.liquid_under (под постройкой плитка, на которой она не стоит);
-- * пометки к сносу, которые поставила сама задача: M.marked_raw / M.unmark (cancel_deconstruction);
-- * помехи области M.survey/M.waits_for: помеченные к сносу сущности и призраки плиток под
--   постройками (призрак, который их ждёт, — не «заблокирован»);
-- * постройка призрака руками M.revive (сущность) и M.revive_tile (плитка): досягаемость →
--   предмет из инвентаря помощника → revive{raise_revive}; не вышло → откат;
-- * «движок» призраков M.ghosts_start/tick/stop — общий для build_ghosts и build_blueprint:
--   режимы auto/hand/robots, порядок «снос помеченного → плитки → постройки», blocked, missing,
--   прогресс {built, left}, свой отсчёт «застрял».
--
-- Призрак руками строится через LuaEntity.revive, а не create_entity: так сохраняются настройки
-- призрака (рецепт, фильтры, запросы модулей), как при постройке игроком поверх призрака.
-- Предмет при этом списывается ровно так же, как в §6.5 (remove_item, quality normal).
local util = require("scripts.core.util")
local reserve = require("scripts.core.reserve")
local err = require("scripts.core.err")
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
M.BODY_MARGIN = 0.1          -- запас к телу (размер тела — collision_box прототипа, у ванильного ±0.2)
M.MAX_MARKED = 500           -- столько помеченных к сносу сущностей области учитываем
M.DIG_MIN_TIMEOUT = 300      -- тиков без исчезновения цели разбора до пропуска
M.EPS = 0.05                 -- зазор при сравнении площадей
M.REACH_MARGIN = 0.5         -- запас к reach_distance при разборе руками
M.NEAR_MARGIN = inv.NEAR_MARGIN  -- запас к resource_reach_distance (камни, деревья)

local function chunk_of(pos)
  return { x = math.floor(pos.x / 32), y = math.floor(pos.y / 32) }
end

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

--- Живое в точке видно помощнику (PROTOCOL §6.7) — общая проверка ядра (scripts.core.vis).
function M.visible(ctx, pos)
  return inv.visible(ctx, pos) and true or false
end

--- Цель действия: сущность на поверхности помощника, своей силы или neutral, в открытом чанке
--- (scripts.core.target). Иначе err: not_found │ not_reachable (другая поверхность) │ not_charted.
function M.resolve(ctx, t)
  local e = inv.resolve_target(ctx, t)
  if e == nil or not e.valid then err.raise("not_found", "target not found") end
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
  local bx, by = 0.2, 0.2
  local cb = h.prototype and h.prototype.collision_box
  if cb ~= nil then
    local lt, rb = cb.left_top or cb[1], cb.right_bottom or cb[2]
    bx = ((rb.x or rb[1]) - (lt.x or lt[1])) / 2
    by = ((rb.y or rb[2]) - (lt.y or lt[2])) / 2
  end
  return math.abs(p.x - pos.x) < hx + bx + M.BODY_MARGIN and math.abs(p.y - pos.y) < hy + by + M.BODY_MARGIN
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

-- ------------------------------------------------------------------ плитки: свойства из игры
-- PROTOCOL §6.12: имён плиток, планет и жидкостей в коде нет. «Плитка без опоры» для постройки —
-- та, чья маска столкновений пересекается с маской постройки (вода, лава, мазут, плитки планет из
-- модов); чем её накрыть — default_cover_tile; доступна ли подложка — её предмет открыт силе
-- (рецепт) либо уже есть у помощника или на складах силы.

local function pread(obj, field)
  local ok, v = pcall(function() return obj[field] end)
  if ok then return v end
  return nil
end

local function layers_of(mask)
  if type(mask) ~= "table" then return nil end
  return mask.layers or mask
end

--- Пересекаются ли две маски столкновений (CollisionMask или её layers).
function M.masks_collide(a, b)
  a, b = layers_of(a), layers_of(b)
  if a == nil or b == nil then return false end
  for layer, on in pairs(a) do
    if on and b[layer] then return true end
  end
  return false
end

--- Прототип плитки в клетке (x, y — любая точка клетки) или nil.
function M.tile_proto_at(surface, x, y)
  local ok, t = pcall(function() return surface.get_tile(math.floor(x), math.floor(y)) end)
  if not ok or t == nil then return nil end
  return prototypes.tile[t.name]
end

--- Плитка-подложка, которой игра накрывает эту плитку (default_cover_tile), или nil.
function M.cover_tile(tp)
  if tp == nil or pread(tp, "allows_being_covered") == false then return nil end
  local c = pread(tp, "default_cover_tile")
  if c == nil then return nil end
  local name = type(c) == "string" and c or pread(c, "name")
  if type(name) ~= "string" then return nil end
  return prototypes.tile[name]
end

--- Предмет открыт силе: включён рецепт с таким именем или любой рецепт, который его даёт.
local function item_known(force, item)
  local r = force.recipes[item]
  if r ~= nil and r.enabled == true then return true end
  local ok, list = pcall(function()
    return prototypes.get_recipe_filtered{
      { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } },
    }
  end)
  if ok and list ~= nil then
    for name in pairs(list) do
      local fr = force.recipes[name]
      if fr ~= nil and fr.enabled == true then return true end
    end
  end
  return false
end

--- Сколько предмета лежит на складах силы на этой поверхности (логистические сети).
local function stored(h, item)
  local n = 0
  pcall(function()
    local nets = h.force.logistic_networks[h.surface.name]
    for _, net in pairs(nets or {}) do
      if net.valid then n = n + net.get_item_count{ name = item, quality = M.NORMAL } end
    end
  end)
  return n
end

--- Подложка cover (прототип плитки) доступна: её предмет открыт силе, есть у помощника или на
--- складах. cache — таблица на время одной оценки ({имя плитки: bool}).
function M.cover_available(h, cover, cache)
  local name = cover.name
  if cache ~= nil and cache[name] ~= nil then return cache[name] end
  local ok = false
  local main = h.get_main_inventory()
  for _, it in ipairs(M.place_items(cover)) do
    if item_known(h.force, it.name) or inv.count(main, it.name) >= it.count or stored(h, it.name) >= it.count then
      ok = true
      break
    end
  end
  if cache ~= nil then cache[name] = ok end
  return ok
end

--- Под постройкой есть клетка, плитка которой ей мешает (без опоры)? → bool, имя плитки.
function M.liquid_under(surface, proto, pos, dir)
  local hx, hy = M.half_size(proto, dir)
  local mask = pread(proto, "collision_mask")
  for cx = math.floor(pos.x - hx + M.EPS), math.floor(pos.x + hx - M.EPS) do
    for cy = math.floor(pos.y - hy + M.EPS), math.floor(pos.y + hy - M.EPS) do
      local tp = M.tile_proto_at(surface, cx, cy)
      if tp ~= nil and M.masks_collide(mask, tp.collision_mask) then return true, tp.name end
    end
  end
  return false
end

-- ------------------------------------------------------------------ подход к точке

--- Подойти к точке pos ближе within (ACTIONS.md «Подход»).
--- → true (на месте) │ nil (иду) │ result (ошибка пути). Состояние: task._goal, task._tries.
--- goal_d — на какое расстояние просить путь (по умолчанию считается из within).
function M.approach(task, ctx, pos, within, goal_d)
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
  local d
  if goal_d ~= nil then
    d = goal_d - tries * 0.4
  else
    d = within > 2 and (within - 1.5 - tries) or (within * 0.75)
  end
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
  task._near_tries = nil
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

-- ------------------------------------------------------------------ разбор руками

local NOT_DECONSTRUCTED = {
  character = true, ["entity-ghost"] = true, ["tile-ghost"] = true, resource = true,
  ["item-entity"] = true, ["item-request-proxy"] = true, ["character-corpse"] = true,
  ["construction-robot"] = true, ["logistic-robot"] = true, ["combat-robot"] = true,
}

local function read(obj, field)
  local ok, v = pcall(function() return obj[field] end)
  if ok then return v end
  return nil
end

--- Можно разобрать руками? → nil │ текст причины.
function M.why_not_minable(e)
  if NOT_DECONSTRUCTED[e.type] then return e.type .. " is not deconstructed" end
  local mp = e.prototype and e.prototype.mineable_properties
  if mp == nil or not mp.minable or e.minable == false then return e.name .. " is not minable" end
  return nil
end

function M.has_driver(e)
  local ok, d = pcall(function() return e.get_driver() end)
  return ok and d ~= nil
end

local function mining_speed(h)
  local s = h.prototype and h.prototype.mining_speed
  local speed = (type(s) == "number" and s > 0) and s or 0.5
  local m = h.force.manual_mining_speed_modifier
  if type(m) == "number" then speed = speed * (1 + m) end
  return math.max(speed, 0.01)
end

local function first_product(e)
  local mp = e.prototype and e.prototype.mineable_properties
  for _, p in ipairs(mp and mp.products or {}) do
    if (p.type == nil or p.type == "item") and type(p.name) == "string" then return p.name end
  end
  return nil
end

--- Перестать копать (можно звать много раз). Флаг — task.mining.
function M.stop_mining(task, h)
  if task.mining and h ~= nil and h.valid then
    h.mining_state = { mining = false }
    pcall(function() h.clear_selected_entity() end)
  end
  task.mining = false
end

--- Состояние разбора одной сущности (лежит в task, переживает сохранение).
function M.dig_new(h, e)
  local mt = e.prototype.mineable_properties.mining_time or 1
  return {
    e = e, name = e.name, pos = util.xy(e.position), started = false,
    timeout = math.max(M.DIG_MIN_TIMEOUT, math.ceil(mt / mining_speed(h) * 60 * 3) + 60),
  }
end

-- Камни, деревья и рыба копаются рукой только вблизи — как руда, с resource_reach_distance (2.7),
-- а не с reach_distance (10). Живой замер 2026-10-13 (2.0.77): с 5–9 клеток `can_reach_entity`
-- для камня и дерева = false, а `selected` + `mining_state` ничего не добывают.
-- Список типов — один на «руки» и стройку: scripts/lib/inventory.lua (NEAR_ONLY).

--- Досягаемость для разбора этой сущности и запас к ней.
function M.dig_reach(h, e)
  if inv.NEAR_ONLY[e.type] then return h.resource_reach_distance, M.NEAR_MARGIN end
  return h.reach_distance, M.REACH_MARGIN
end

--- Достаём ли рукой до сущности, чтобы её разобрать: проверка движка `can_reach_entity` либо
--- расстояние от тела до центра сущности не больше её досягаемости с запасом. Копает всё равно
--- движок: вне его собственной досягаемости добыча просто не пойдёт.
function M.can_dig(h, e)
  local ok, r = pcall(function() return h.can_reach_entity(e) end)
  if ok and r == true then return true end
  local reach, margin = M.dig_reach(h, e)
  return util.dist(util.xy(h.position), util.xy(e.position)) <= reach - margin
end

--- Шаг честного разбора (PROTOCOL §6.5): подойти на досягаемость (M.dig_reach), `selected` +
--- `mining_state` до исчезновения сущности; время тратит движок, предметы в инвентарь кладёт он же.
--- → "working" │ "removed" (разобрали мы) │ "gone" (исчезла не от наших рук) │
---   "skipped" (не поддаётся за разумное время) │ "full" (нет места под предмет) │ result (ошибка пути).
function M.dig_step(task, ctx, st)
  local h, tick = ctx.entity, ctx.tick
  if not st.e.valid then
    -- Нашей считаем цель, только если мы её копали И в инвентарь что-то пришло: иначе её
    -- параллельно разобрал игрок или дрон. Постройка без предметов при разборе
    -- (product == nil) засчитывается по самому факту добычи.
    local ours = false
    if st.started then
      local n = h.get_main_inventory().get_item_count()
      ours = st.product == nil or n > (st.inv0 or n)
    end
    M.stop_mining(task, h)
    return ours and "removed" or "gone"
  end
  local r
  if M.can_dig(h, st.e) then
    if task._goal ~= nil then M.stop_approach(task, ctx) end
    r = true
  elseif st.e.surface.index ~= h.surface.index then
    r = { status = "failed", code = "not_reachable", text = "target is on another surface" }
  else
    local reach, margin = M.dig_reach(h, st.e)
    if reach > 5 then
      r = M.approach(task, ctx, util.xy(st.e.position), reach - margin - 0.5)
    else
      -- вплотную: путь просим почти на предел досягаемости (ближе мешает сама сущность)
      r = M.approach(task, ctx, util.xy(st.e.position), reach - margin, reach - margin - 0.4)
    end
    if r == true and not M.can_dig(h, st.e) then r = nil end
  end
  if r == nil then
    M.stop_mining(task, h)
    st.since = nil
    return "working"
  end
  if r ~= true then
    M.stop_mining(task, h)
    return r
  end
  local product = first_product(st.e)
  if product ~= nil and not inv.has_room(h, product) then
    M.stop_mining(task, h)
    return "full"
  end
  if not task.mining or h.selected ~= st.e then
    h.selected = st.e
    h.mining_state = { mining = true, position = util.xy(st.e.position) }
    task.mining = true
    if not st.started then
      st.inv0 = h.get_main_inventory().get_item_count()
      st.product = product
    end
    st.started = true
    st.since = st.since or tick
  elseif not (h.mining_state and h.mining_state.mining) then
    h.mining_state = { mining = true, position = util.xy(st.e.position) }
  end
  if tick - (st.since or tick) > st.timeout then
    -- не поддаётся (например, содержимое не влезает в инвентарь) — пропускаем
    M.stop_mining(task, h)
    return "skipped"
  end
  return "working"
end

-- ------------------------------------------------------------------ помехи: снос и плитки

function M.cell_key(x, y)
  return math.floor(x) .. "," .. math.floor(y)
end

function M.is_tile_ghost(e)
  return e.type == "tile-ghost"
end

--- Сущность помечена к сносу?
function M.is_marked(e)
  local ok, v = pcall(function() return e.to_be_deconstructed() end)
  return ok and v == true
end

local function box_of(e)
  local bb = read(e, "bounding_box")
  if type(bb) == "table" then
    local lt, rb = bb.left_top or bb[1], bb.right_bottom or bb[2]
    if lt and rb then
      return (lt.x or lt[1]), (lt.y or lt[2]), (rb.x or rb[1]), (rb.y or rb[2])
    end
  end
  local f = M.footprint(e.prototype, util.xy(e.position), e.direction)
  return f.left_top.x, f.left_top.y, f.right_bottom.x, f.right_bottom.y
end

--- Помеченные к сносу сущности области, которые помощник вправе разобрать руками: своя сила и
--- neutral (PROTOCOL §6.6), копаемые, не персонажи и не техника с водителем.
--- → {{e, key, name, pos, x0, y0, x1, y1}, ...} (не больше MAX_MARKED).
function M.marked(h, area)
  local out = {}
  local found = h.surface.find_entities_filtered{
    area = { { area.left_top.x - 2, area.left_top.y - 2 }, { area.right_bottom.x + 2, area.right_bottom.y + 2 } },
    to_be_deconstructed = true, force = { h.force.name, "neutral" }, limit = M.MAX_MARKED,
  }
  for _, e in ipairs(found) do
    if e.valid and e ~= h and M.is_marked(e) and inv.allowed_force(h, e)
        and M.why_not_minable(e) == nil and not M.has_driver(e) then
      local p = util.xy(e.position)
      local x0, y0, x1, y1 = box_of(e)
      out[#out + 1] = { e = e, key = M.ghost_key(e.name, p), name = e.name, pos = p, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
    end
  end
  return out
end

--- Всё помеченное к сносу в области (своя сила и neutral) — без отбора «можно ли разобрать руками»:
--- по этому списку задача узнаёт, какие пометки поставила она сама. → {LuaEntity, ...}
function M.marked_raw(h, area)
  local out = {}
  local found = h.surface.find_entities_filtered{
    area = { { area.left_top.x - 2, area.left_top.y - 2 }, { area.right_bottom.x + 2, area.right_bottom.y + 2 } },
    to_be_deconstructed = true, force = { h.force.name, "neutral" },
  }
  for _, e in ipairs(found) do
    if e.valid and e ~= h and M.is_marked(e) then out[#out + 1] = e end
  end
  return out
end

function M.mark_key(e)
  return M.ghost_key(e.name, util.xy(e.position))
end

--- Снять пометки к сносу со списка сущностей (те, что ещё стоят и ещё помечены). force_name — сила,
--- от имени которой пометка ставилась. Тело помощника не нужно: зовётся и после его смерти.
--- → сколько снято.
function M.unmark(list, force_name)
  local n = 0
  local force = force_name and game.forces[force_name] or nil
  if type(list) ~= "table" or force == nil then return 0 end
  for _, e in ipairs(list) do
    if e ~= nil and e.valid and M.is_marked(e) then
      local ok = pcall(function() e.cancel_deconstruction(force) end)
      if ok then n = n + 1 end
    end
  end
  return n
end

--- Снимок помех области: sv.marked — помеченное к сносу, sv.tiles["x,y"] = true (призрак плитки
--- ждёт постройки) │ false (призрак плитки есть, но построить его нельзя — пропущен).
--- tile_ghosts — уже найденные призраки плиток (иначе ищутся здесь), dead — ключи пропущенных.
function M.survey(h, area, tile_ghosts, dead)
  local sv = { marked = M.marked(h, area), tiles = {}, any_tiles = false }
  tile_ghosts = tile_ghosts or h.surface.find_entities_filtered{
    area = { area.left_top, area.right_bottom }, type = "tile-ghost", force = h.force,
  }
  for _, t in ipairs(tile_ghosts) do
    if t.valid then
      local p = util.xy(t.position)
      local alive = not (dead and dead[M.ghost_key(t.ghost_name, p)])
      local k = M.cell_key(p.x, p.y)
      if alive or sv.tiles[k] == nil then sv.tiles[k] = alive end
      sv.any_tiles = true
    end
  end
  return sv
end

--- Чего ждёт постройка на этом месте: "decon", {помехи} — сначала разобрать помеченное;
--- "decon_dead" — на месте помеченное, которое разобрать не вышло; "tile" — под ней ещё не положена
--- плитка; "tile_dead" — плитку под ней положить нельзя; nil — ничего.
--- dead — ключи помех, которые разобрать не вышло (они больше не «ожидание», а блок).
function M.waits_for(sv, proto, pos, dir, dead)
  local hx, hy = M.half_size(proto, dir)
  local x0, y0, x1, y1 = pos.x - hx, pos.y - hy, pos.x + hx, pos.y + hy
  local obstacles, dead_obstacle
  for _, m in ipairs(sv.marked) do
    if m.e.valid and m.x0 < x1 - M.EPS and m.x1 > x0 + M.EPS and m.y0 < y1 - M.EPS and m.y1 > y0 + M.EPS then
      if dead and dead[m.key] then
        dead_obstacle = true
      else
        obstacles = obstacles or {}
        obstacles[#obstacles + 1] = m
      end
    end
  end
  if dead_obstacle then return "decon_dead" end
  if obstacles then return "decon", obstacles end
  if sv.any_tiles then
    local dead_tile = false
    for cx = math.floor(x0 + M.EPS), math.floor(x1 - M.EPS) do
      for cy = math.floor(y0 + M.EPS), math.floor(y1 - M.EPS) do
        local t = sv.tiles[cx .. "," .. cy]
        if t == true then return "tile" end
        if t == false then dead_tile = true end
      end
    end
    if dead_tile then return "tile_dead" end
  end
  return nil
end

-- ------------------------------------------------------------------ дроны и призраки

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
  -- что нужно, чтобы вернуть призрак при откате (после revive сам призрак уже невалиден)
  local back = {
    surface = g.surface, name = g.ghost_name, position = pos, direction = g.direction, force = g.force,
  }
  local collided, e = g.revive{ raise_revive = true }
  if e == nil or not e.valid then return nil, "blocked" end
  local removed = h.remove_item{ name = entry.item, count = entry.count, quality = M.NORMAL }
  if removed < entry.count then
    -- предмет не списался: постройки из воздуха не бывает — убираем её, частично списанное возвращаем.
    -- Призрак — план хозяина: ставим его обратно на то же место. Возвращаются имя, место, поворот
    -- и сила; настройки призрака (рецепт, фильтры, запросы модулей) при таком откате теряются.
    if removed > 0 then h.insert{ name = entry.item, count = removed, quality = M.NORMAL } end
    e.destroy{ raise_destroy = true }
    give_collided(h, collided)
    pcall(function()
      back.surface.create_entity{
        name = "entity-ghost", inner_name = back.name, position = back.position,
        direction = back.direction, force = back.force, raise_built = true,
      }
    end)
    return nil, "no_items"
  end
  give_collided(h, collided)
  return e
end

--- Положить плитку по её призраку руками. entry = {e = призрак плитки, item, count}.
--- Предмет списывается ДО revive (плитку, в отличие от постройки, обратно не убрать); призрак
--- не оживился — предмет возвращается в инвентарь, откуда взят.
--- → true │ nil, причина: "gone" │ "quality" │ "not_visible" │ "far" │ "no_items" │ "blocked".
function M.revive_tile(ctx, entry)
  local h, g = ctx.entity, entry.e
  if g == nil or not g.valid then return nil, "gone" end
  if not inv.is_normal(g.quality) then return nil, "quality" end
  local pos = util.xy(g.position)
  if not M.visible(ctx, pos) then return nil, "not_visible" end
  if util.dist(util.xy(h.position), pos) > h.build_distance then return nil, "far" end
  local main = h.get_main_inventory()
  if inv.count(main, entry.item) < entry.count then return nil, "no_items" end
  local removed = h.remove_item{ name = entry.item, count = entry.count, quality = M.NORMAL }
  if removed < entry.count then
    if removed > 0 then h.insert{ name = entry.item, count = removed, quality = M.NORMAL } end
    return nil, "no_items"
  end
  local collided = g.revive{ raise_revive = true }
  if g.valid then
    -- призрак остался — плитка не легла: предмет возвращаем
    h.insert{ name = entry.item, count = entry.count, quality = M.NORMAL }
    return nil, "blocked"
  end
  give_collided(h, collided)
  return true
end

-- ------------------------------------------------------------------ движок призраков

-- Поля по ACTIONS.md «build_ghosts»: built, tiles_built (сколько из built — плитки), left, removed
-- (сколько помеченного к сносу помощник разобрал сам), not_removed (сколько не смог), blocked,
-- blocked_total, missing. Сверх контракта, только когда есть что сказать: not_removed_list:
-- [{name,pos,reason}] (≤ 20) и tiles_first — ни одна постройка не поставлена руками раньше
-- последней плитки.
local function detail_of(g)
  local d = {
    built = g.built, tiles_built = g.tiles_built or 0, left = g.left,
    removed = g.removed or 0, not_removed = g.not_removed_total or 0,
    blocked = g.blocked, blocked_total = g.blocked_total, missing = g.missing,
  }
  if (g.not_removed_total or 0) > 0 then d.not_removed_list = g.not_removed end
  if (g.tiles_built or 0) > 0 then
    d.tiles_first = g.first_entity_tick == nil or g.last_tile_tick == nil or g.last_tile_tick <= g.first_entity_tick
  end
  return d
end
M.ghost_detail = function(task) return detail_of(task.g) end

local function set_progress(task)
  local g = task.g
  task.progress = { done = g.built, total = g.built + g.left, built = g.built, left = g.left }
end

local function tile_now(surface, x, y)
  local ok, t = pcall(function() return surface.get_tile(math.floor(x), math.floor(y)) end)
  if ok and t ~= nil then return t.name end
  return nil
end

--- Пересчёт призраков области: что строимо (и чем), что заблокировано, чего не хватает, что
--- ждёт плитку или сноса помеченного; заодно — очередь сноса g.decon.
local function scan(task, ctx)
  local g, h, tick = task.g, ctx.entity, ctx.tick
  local surface = h.surface
  local found = surface.find_entities_filtered{
    area = { g.area.left_top, g.area.right_bottom }, type = { "entity-ghost", "tile-ghost" }, force = h.force,
  }
  local hp = util.xy(h.position)
  local chunks = {}
  local function charted(p)
    local k = math.floor(p.x / 32) .. ":" .. math.floor(p.y / 32)
    if chunks[k] == nil then chunks[k] = M.charted(h, p) end
    return chunks[k]
  end
  local entries, tile_ghosts = {}, {}
  for _, e in ipairs(found) do
    if e.valid then
      local p = util.xy(e.position)
      if charted(p) then
        local tile = M.is_tile_ghost(e)
        entries[#entries + 1] = { e = e, pos = p, d = util.dist(p, hp), tile = tile }
        if tile then tile_ghosts[#tile_ghosts + 1] = e end
      end
    end
  end
  -- ближние первыми: им достаются предметы, если хватает не на все
  table.sort(entries, function(a, b) return a.d < b.d end)
  local sv = M.survey(h, g.area, tile_ghosts, g.skip)

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
  local decon, decon_seen = {}, {}
  for _, en in ipairs(entries) do
    local e = en.e
    local name = e.ghost_name
    local key = M.ghost_key(name, en.pos)
    n_cur = n_cur + 1
    cur[key] = { n = name, x = en.pos.x, y = en.pos.y, t = en.tile or nil }
    local proto = e.ghost_prototype
    local items = M.place_items(proto)
    -- g.skip держится до конца задачи: призрак с причиной path_failed/stuck/blocked повторно не
    -- пробуется, даже если путь потом освободился (v1: проще и не зацикливается; повтор — новой
    -- задачей build_ghosts по той же области).
    local reason = g.skip[key]
    local body, wait = false, nil
    if reason == nil then
      if not inv.is_normal(e.quality) then
        reason = "quality"
      elseif #items == 0 then
        reason = "no_item"
      elseif not en.tile then
        local why, obstacles = M.waits_for(sv, proto, en.pos, e.direction, g.decon_skip)
        if why == "decon" then
          -- помеченное к сносу мешает призраку: сначала разбор (ACTIONS «build_ghosts»)
          wait = "decon"
          for _, m in ipairs(obstacles) do
            if not decon_seen[m.key] then
              decon_seen[m.key] = true
              decon[#decon + 1] = { e = m.e, key = m.key, name = m.name, pos = m.pos }
            end
          end
        elseif why == "decon_dead" then
          reason = "obstacle"    -- помеченное на его месте разобрать не удалось (detail.not_removed)
        elseif why == "tile" then
          wait = "tile"          -- ждёт плитку под собой — это не «заблокирован»
        elseif why == "tile_dead" then
          reason = "tile"        -- плитку под ним положить не удалось
        else
          checks = checks + 1
          if checks <= M.MAX_BLOCK_CHECKS and M.blocked(surface, e) then
            -- мешает само тело помощника — это не «заблокирован»: отойдём
            if M.body_inside(h, proto, en.pos, e.direction) then
              body = true
            elseif M.liquid_under(surface, proto, en.pos, e.direction) then
              reason = "liquid"    -- под призраком плитка без опоры, а призрака подложки нет
            else
              reason = "blocked"
            end
          end
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
          tile = en.tile or nil, wait = wait,
        }
      else
        missing[items[1].name] = (missing[items[1].name] or 0) + items[1].count
      end
    end
  end

  -- кто исчез с прошлого пересчёта и стал постройкой (плиткой) — построен (дронами или кем-то ещё)
  local before = g.built
  if g.seen ~= nil then
    for key, s in pairs(g.seen) do
      if cur[key] == nil then
        local there
        if s.t then
          there = tile_now(surface, s.x, s.y) == s.n
        else
          there = surface.find_entity(s.n, { x = s.x, y = s.y }) ~= nil
        end
        if there then
          g.built = g.built + 1
          if s.t then g.tiles_built = (g.tiles_built or 0) + 1 end
        end
      end
    end
  elseif g.scanned and left < g.left then
    g.built = g.built + (g.left - left)
  end
  if g.built ~= before then g.last_built = tick end
  if g.built ~= before or left ~= g.left then g.last_progress = tick end

  g.seen = n_cur <= M.MAX_TRACK and cur or nil
  g.list, g.blocked, g.blocked_total, g.missing, g.left = list, blocked, blocked_total, missing, left
  -- цель разбора, которую уже копаем, в очередь второй раз не кладём
  if g.dig ~= nil then
    for i = #decon, 1, -1 do
      if decon[i].key == g.dig.key then table.remove(decon, i) end
    end
  end
  g.decon = decon
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

--- Вынуть из списка ближайший к помощнику живой призрак, который можно строить сейчас:
--- плитки всегда раньше построек; постройки, ждущие плитку или сноса, не берутся.
local function next_entry(g, h)
  local hp = util.xy(h.position)
  local list = g.list
  local best, bd, best_tile, btd
  local i = 1
  while i <= #list do
    local en = list[i]
    if not en.e.valid then
      list[i] = list[#list]
      list[#list] = nil
    else
      if not en.wait then
        local d = util.dist(en.pos, hp)
        if en.tile then
          if btd == nil or d < btd then best_tile, btd = i, d end
        elseif bd == nil or d < bd then
          best, bd = i, d
        end
      end
      i = i + 1
    end
  end
  best = best_tile or best
  if best == nil then return nil end
  local en = list[best]
  list[best] = list[#list]
  list[#list] = nil
  return en
end

--- Есть ли в списке то, что руки могут строить прямо сейчас.
local function has_ready(g)
  for _, en in ipairs(g.list) do
    if not en.wait and en.e.valid then return true end
  end
  return false
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

--- Разбор помеченного к сносу, которое мешает призракам. → true (занят разбором) │ false (нечего)
--- │ result (инвентарь полон).
local function decon_step(task, ctx)
  local g, h, tick = task.g, ctx.entity, ctx.tick
  if g.dig == nil then
    local hp = util.xy(h.position)
    local best, bd
    for i = #g.decon, 1, -1 do
      local m = g.decon[i]
      if not m.e.valid or g.decon_skip[m.key] then
        table.remove(g.decon, i)
      end
    end
    for i, m in ipairs(g.decon) do
      local d = util.dist(m.pos, hp)
      if bd == nil or d < bd then best, bd = i, d end
    end
    if best == nil then return false end
    local m = table.remove(g.decon, best)
    M.stop_approach(task, ctx)
    g.dig = M.dig_new(h, m.e)
    g.dig.key = m.key
  end
  local r = M.dig_step(task, ctx, g.dig)
  if r == "working" then return true end
  local key, dug = g.dig.key, g.dig
  g.dig = nil
  M.stop_approach(task, ctx)
  if r == "removed" then
    g.removed = (g.removed or 0) + 1
    g.last_progress = tick
  elseif r == "gone" then
    g.last_progress = tick
  elseif r == "full" then
    return inv.full_result(task, ctx, detail_of(g))
  else
    -- не поддаётся или до неё не дойти: больше не пробуем, призрак за ней станет blocked
    local why = type(r) == "table" and (r.code or "path_failed") or "not_minable_in_time"
    g.decon_skip[key] = why
    g.not_removed_total = (g.not_removed_total or 0) + 1
    g.not_removed = g.not_removed or {}
    if #g.not_removed < M.MAX_LIST then
      g.not_removed[#g.not_removed + 1] = { name = dug.name, pos = util.pos(dug.pos), reason = why }
    end
  end
  soon(g, tick, #g.decon == 0 and 0 or 30)
  return true
end

local function hand_step(task, ctx)
  local g, h, tick = task.g, ctx.entity, ctx.tick
  if g.cur == nil and (g.dig ~= nil or #g.decon > 0) then
    local r = decon_step(task, ctx)
    if r ~= false then
      if r == true then return nil end
      return r
    end
  end
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
  local e, why
  if cur.tile then e, why = M.revive_tile(ctx, cur) else e, why = M.revive(ctx, cur) end
  if e ~= nil then
    if cur.tile then
      g.tiles_built = (g.tiles_built or 0) + 1
      g.last_tile_tick = tick
    elseif g.first_entity_tick == nil then
      g.first_entity_tick = tick
    end
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

--- Взять переключатель вылета личных дронов на время задачи: «только руками» — не вылетают, иначе
--- вылетают. Прежнее значение запоминается один раз и возвращается в ghosts_stop; после ghosts_stop
--- (например, на время снабжения) звать снова — переключатель встанет заново.
function M.dispatch_arm(task, ctx)
  local g, h = task.g, ctx.entity
  if g == nil or h == nil or not h.valid or M.robots(h) == nil then return end
  if g.prev_dispatch == nil then
    local prev = read(h, "allow_dispatching_robots")
    g.prev_dispatch = prev == nil and true or prev
  end
  set_dispatch(h, g.mode ~= "hand")
end

--- Начать стройку призраков области area в режиме mode ("auto"│"hand"│"robots").
function M.ghosts_start(task, ctx, area, mode)
  local h = ctx.entity
  task.g = {
    area = area, mode = mode, built = 0, left = 0, blocked = {}, blocked_total = 0, missing = {},
    list = {}, skip = {}, decon = {}, decon_skip = {}, removed = 0, tiles_built = 0,
    next_scan = 0, scanned = false,
    last_progress = ctx.tick, last_built = ctx.tick,
  }
  M.dispatch_arm(task, ctx)
  set_progress(task)
  return nil
end

--- Снять своё: подход и переключатель дронов. Можно звать много раз.
function M.ghosts_stop(task, ctx)
  M.stop_approach(task, ctx)
  local g = task.g
  local h = ctx.entity
  M.stop_mining(task, h)
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

  local idle
  if use_robots then
    idle = #g.list == 0
  else
    idle = g.cur == nil and g.dig == nil and #g.decon == 0 and not has_ready(g)
  end
  if idle then
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
    local res = M.failed("no_items", "not enough items for the remaining ghosts", detail_of(g))
    res.shortage = true -- нехватка предметов (а не дронов): по этому признаку работает auto_supply
    return finish(task, ctx, res)
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
