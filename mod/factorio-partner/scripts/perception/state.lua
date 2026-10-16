-- Операция `state` и общие помощники восприятия (M.common).
-- Контракты: docs/STATE.md, PROTOCOL.md §1 (сериализация), §4, §6.7 (два уровня обзора), §6.11, §7.
-- Модули map/resources/stock/ghosts/recipes/vision берут общее отсюда:
--   local C = require("scripts.perception.state").common
local err = require("scripts.core.err")
local core_owner = require("scripts.core.owner")
local jobs = require("scripts.core.jobs")
local metrics = require("scripts.core.metrics")
local vis = require("scripts.core.vis")
-- Реестр помощников ядра: нужен только для поля `state.body`; без него — запасное значение.
local registry_ok, core_registry = pcall(require, "scripts.core.registry")
if not registry_ok then core_registry = nil end

local M = {}
local C = {}
M.common = C

local floor, sqrt, huge = math.floor, math.sqrt, math.huge

---------------------------------------------------------------------------
-- Числа и координаты
---------------------------------------------------------------------------

-- Округление до 0.1 (PROTOCOL §1). Не даёт "-0".
function C.round(v)
  local r = floor(v * 10 + 0.5) / 10
  if r == 0 then return 0 end
  return r
end

function C.rpos(p)
  local x = p.x or p[1]
  local y = p.y or p[2]
  return { x = C.round(x), y = C.round(y) }
end

function C.dist(a, b)
  local ax, ay = a.x or a[1], a.y or a[2]
  local bx, by = b.x or b[1], b.y or b[2]
  local dx, dy = ax - bx, ay - by
  return sqrt(dx * dx + dy * dy)
end

local function finite(v)
  return type(v) == "number" and v == v and v ~= huge and v ~= -huge
end
C.finite = finite

-- Предел координат: карта Factorio ±1 000 000 клеток.
local COORD_MAX = 1000000

---------------------------------------------------------------------------
-- Проверка аргументов операций (ошибка → bad_args с именем поля)
---------------------------------------------------------------------------

function C.bad(field, why)
  err.raise("bad_args", field .. ": " .. why)
end

function C.check_args(args)
  if args == nil then return {} end
  if type(args) ~= "table" then C.bad("args", "must be an object") end
  return args
end

-- Разрешённые ключи: неизвестное поле → bad_args (защита от опечаток агента).
function C.allow_only(args, allowed)
  for k in pairs(args) do
    if type(k) ~= "string" or not allowed[k] then
      C.bad(tostring(k), "unknown field")
    end
  end
end

function C.check_pos(v, field)
  if type(v) ~= "table" then C.bad(field, "must be {x,y}") end
  local x, y = v.x, v.y
  if not finite(x) or not finite(y) then C.bad(field, "x and y must be numbers") end
  if x > COORD_MAX or x < -COORD_MAX or y > COORD_MAX or y < -COORD_MAX then
    C.bad(field, "out of map")
  end
  return { x = x, y = y }
end

-- Число в [min, max]; больше max → limit (PROTOCOL §3: превышен лимит радиуса и т.п.).
function C.check_num(v, field, min, max, default)
  if v == nil then return default end
  if not finite(v) then C.bad(field, "must be a number") end
  if max and v > max then err.raise("limit", field .. ": must be <= " .. max) end
  if min and v < min then C.bad(field, "must be >= " .. min) end
  return v
end

function C.check_int(v, field, min, max, default)
  v = C.check_num(v, field, min, max, default)
  if v ~= nil and floor(v) ~= v then C.bad(field, "must be an integer") end
  return v
end

function C.check_bool(v, field, default)
  if v == nil then return default end
  if type(v) ~= "boolean" then C.bad(field, "must be true/false") end
  return v
end

function C.check_string(v, field, max, default)
  if v == nil then return default end
  if type(v) ~= "string" then C.bad(field, "must be a string") end
  if #v == 0 or #v > (max or 100) then C.bad(field, "length must be 1.." .. (max or 100)) end
  return v
end

-- Список имён: массив строк или {name=true|число}. → множество {name=true} или nil.
function C.check_names(v, field, max)
  if v == nil then return nil end
  if type(v) ~= "table" then C.bad(field, "must be a list of names") end
  max = max or 100
  local set, n = {}, 0
  for k, val in pairs(v) do
    local name
    if type(k) == "number" then name = val else name = k end
    if type(name) ~= "string" or #name == 0 or #name > 100 then
      C.bad(field, "names must be strings")
    end
    if not set[name] then
      set[name] = true
      n = n + 1
      if n > max then err.raise("limit", field .. ": at most " .. max .. " names") end
    end
  end
  if n == 0 then return nil end
  return set
end

-- area = {left_top:pos, right_bottom:pos}, сторона ≤ max_side (ACTIONS.md «Общие типы»).
function C.check_area(v, field, max_side)
  if type(v) ~= "table" then C.bad(field, "must be {left_top, right_bottom}") end
  local lt = C.check_pos(v.left_top, field .. ".left_top")
  local rb = C.check_pos(v.right_bottom, field .. ".right_bottom")
  if rb.x < lt.x or rb.y < lt.y then C.bad(field, "right_bottom must be >= left_top") end
  if max_side and (rb.x - lt.x > max_side or rb.y - lt.y > max_side) then
    err.raise("limit", field .. ": side must be <= " .. max_side)
  end
  return { left_top = lt, right_bottom = rb }
end

---------------------------------------------------------------------------
-- Хозяин и игроки (PROTOCOL §4, §7)
---------------------------------------------------------------------------

-- Правило «кто хозяин» живёт в ядре (scripts.core.owner); здесь только обёртки.
function C.owner_player()
  local p = core_owner.player()
  if p and p.valid then return p end
  return nil
end

-- Игрок «есть»: connected и character ~= nil (для хозяина — то же, что owner.present()).
function C.player_present(p)
  return p ~= nil and p.valid and p.connected and p.character ~= nil
end

---------------------------------------------------------------------------
-- Помощник, центр, поверхность, сила
---------------------------------------------------------------------------

-- Тело помощника из ctx: nil, если не передано; невалидное → no_helper.
function C.helper_entity(ctx, required)
  local e = ctx and ctx.entity
  if e ~= nil and not e.valid then err.raise("no_helper", "helper body is not valid") end
  if e == nil and required then err.raise("no_helper", "helper is required") end
  return e
end

-- Где смотреть: args.center │ args.near="player" │ помощник │ хозяин (если помощника нет).
-- → {surface, force, center, entity, owner}
function C.resolve(args, ctx, opts)
  opts = opts or {}
  local e = C.helper_entity(ctx, opts.need_helper)
  if args.center ~= nil and args.near ~= nil then C.bad("near", "use either center or near") end
  if args.near ~= nil and args.near ~= "player" then C.bad("near", "only \"player\" is supported") end

  local owner = C.owner_player()
  local present = core_owner.present() ~= nil
  local where = { entity = e, owner = owner, helper_id = ctx and ctx.helper_id }

  if e then
    where.surface = e.surface
    where.force = e.force
  end

  if args.near == "player" then
    if not present then err.raise("no_player", "owner is not online with a body") end
    local psurf = owner.physical_surface
    if where.surface and psurf.index ~= where.surface.index then
      err.raise("no_player", "owner is on another surface")
    end
    where.surface = psurf
    where.force = where.force or owner.force
    where.center = owner.physical_position
  elseif args.center ~= nil then
    where.center = C.check_pos(args.center, "center")
  elseif e then
    where.center = e.position
  end

  if not where.surface then
    -- Без помощника — поверхность и сила хозяина; хозяина нет онлайн → no_player (PROTOCOL §4).
    if not present then
      err.raise("no_player", "no helper given and owner is not online")
    end
    where.surface = owner.physical_surface
    where.force = owner.force
    where.center = where.center or owner.physical_position
  end
  where.center = { x = where.center.x or where.center[1], y = where.center.y or where.center[2] }
  return where
end

---------------------------------------------------------------------------
-- Два уровня обзора (PROTOCOL §6.7): открытые / видимые чанки, кэш на один вызов
---------------------------------------------------------------------------

-- helper_id — чьими «глазами» смотрим живое (PROTOCOL §6.7): видимый чанк ИЛИ ≤ 32 клеток от
-- живого тела помощника (scripts.core.vis); nil — только is_chunk_visible.
function C.chunk_view(force, surface, helper_id)
  local charted = {}
  local eyes = vis.viewer(helper_id, surface, force)
  local v = {}
  local function key(cx, cy) return cx * 4194304 + cy end -- |cx|,|cy| < 2^21
  function v.charted_chunk(cx, cy)
    local k = key(cx, cy)
    local r = charted[k]
    if r == nil then
      r = force.is_chunk_charted(surface, { x = cx, y = cy }) and true or false
      charted[k] = r
    end
    return r
  end
  function v.charted(pos)
    return v.charted_chunk(floor((pos.x or pos[1]) / 32), floor((pos.y or pos[2]) / 32))
  end
  function v.visible(pos)
    return eyes(pos)
  end
  return v
end

---------------------------------------------------------------------------
-- Предметы (только quality normal, PROTOCOL §6.11)
---------------------------------------------------------------------------

function C.is_normal(q)
  if q == nil then return true end
  if type(q) == "string" then return q == "normal" end
  if type(q) == "table" or type(q) == "userdata" then
    local ok, name = pcall(function() return q.name end)
    return ok and name == "normal"
  end
  return false
end

-- Содержимое инвентаря → {name=count} (normal). filter — множество имён или nil.
-- Складывает в acc, если передан.
function C.inv_counts(inv, filter, acc)
  acc = acc or {}
  if not inv or not inv.valid then return acc end
  local contents = inv.get_contents()
  for k, v in pairs(contents) do
    local name, count, quality
    if type(v) == "table" then
      name, count, quality = v.name, v.count, v.quality
    else
      name, count = k, v -- форма {name=count}
    end
    if type(name) == "string" and type(count) == "number" and count > 0 and C.is_normal(quality)
      and (filter == nil or filter[name]) then
      acc[name] = (acc[name] or 0) + count
    end
  end
  return acc
end

function C.add_counts(acc, t)
  for k, v in pairs(t) do acc[k] = (acc[k] or 0) + v end
  return acc
end

---------------------------------------------------------------------------
-- Хранилище обзора (storage.vision — PROTOCOL §7)
---------------------------------------------------------------------------

-- storage.vision = {on = {[helper] = {on=bool, unit=unit_number}}, charted = {[key]=tick}}.
-- Запись on[h] относится к конкретному телу: после helper_remove → helper_spawn (или
-- возрождения) у помощника новое тело с другим unit_number, и запись считается устаревшей —
-- обзор снова включён (STATE.md «vision»: по умолчанию on=true после helper_spawn).
function C.vision_storage()
  local v = storage.vision
  if type(v) ~= "table" then
    v = {}
    storage.vision = v
  end
  if type(v.on) ~= "table" then v.on = {} end
  if type(v.charted) ~= "table" then v.charted = {} end
  return v
end

-- unit_number текущего тела помощника (по storage.helpers ядра) или nil.
function C.helper_unit(helper_id)
  local hs = storage.helpers
  local rec = type(hs) == "table" and hs[helper_id]
  if type(rec) ~= "table" then return nil end
  return rec.unit_number
end

-- Записать выбор обзора для текущего тела помощника.
function C.set_vision(helper_id, on)
  local v = C.vision_storage()
  v.on[helper_id] = { on = on, unit = C.helper_unit(helper_id) }
end

function C.vision_on(helper_id)
  local v = storage.vision
  if type(v) ~= "table" or type(v.on) ~= "table" then return true end
  local rec = v.on[helper_id]
  if type(rec) ~= "table" then return true end
  local unit = C.helper_unit(helper_id)
  if rec.unit == nil or unit == nil or rec.unit ~= unit then
    return true -- другое тело (или неизвестно чьё): запись устарела, по умолчанию включено
  end
  return rec.on ~= false
end

---------------------------------------------------------------------------
-- Задача помощника: данные ядра читаем осторожно
---------------------------------------------------------------------------

-- → job ({job, do, progress=[done,total]?}) или nil, длина очереди без активной.
-- Данные ядра (scripts.core.jobs, storage.jobs.by_helper); task.progress = {done, total, ...}.
function C.job_summary(helper_id)
  local sj = storage.jobs
  if type(sj) ~= "table" or type(sj.by_helper) ~= "table" then return nil, 0 end
  local job
  local a = jobs.active(helper_id)
  if type(a) == "table" and a.job ~= nil then
    job = { job = a.job, ["do"] = a["do"] }
    local pr = a.progress
    if type(pr) == "table" then
      local d, t = pr.done, pr.total
      if type(d) == "number" and type(t) == "number" then job.progress = { d, t } end
    end
  end
  return job, jobs.queue_len(helper_id)
end

function C.last_seq()
  local ev = storage.events
  if type(ev) == "table" and type(ev.next_seq) == "number" then return ev.next_seq - 1 end
  return 0
end

---------------------------------------------------------------------------
-- state
---------------------------------------------------------------------------

local ENEMY_TYPES = { "unit", "unit-spawner", "turret", "spider-unit", "segmented-unit" }
local CONTAINER_TYPES = { "container", "logistic-container" }
local NEAR_RADIUS = 32
local NEAR_ENEMIES_MAX = 20

local function read(obj, field)
  local ok, v = pcall(function() return obj[field] end)
  if ok then return v end
  return nil
end

local function players_list(e)
  local out = {}
  local owner = C.owner_player()
  for _, p in pairs(game.players) do
    if p.valid then
      local item = { name = p.name, owner = (owner ~= nil and p.index == owner.index),
                     online = p.connected and true or false }
      if p.connected and p.character then
        local surf = p.physical_surface
        local pos = p.physical_position
        item.surface = surf.name
        item.pos = C.rpos(pos)
        if surf.index == e.surface.index then item.dist = C.round(C.dist(pos, e.position)) end
      end
      out[#out + 1] = item
    end
  end
  return out
end

local function robots(e)
  local r = { construction = 0, available = 0 }
  local cell = read(e, "logistic_cell")
  if cell and cell.valid then
    local net = cell.logistic_network
    if net and net.valid then
      r.construction = net.all_construction_robots or 0
      r.available = net.available_construction_robots or 0
    end
  end
  return r
end

local function near(e, helper_id)
  local surface, force, pos = e.surface, e.force, e.position
  local view = C.chunk_view(force, surface, helper_id)
  local enemies = {}
  local found = surface.find_entities_filtered { position = pos, radius = NEAR_RADIUS, force = "enemy", type = ENEMY_TYPES }
  for _, en in ipairs(found) do
    if en.valid and view.visible(en.position) then
      enemies[#enemies + 1] = { name = en.name, pos = C.rpos(en.position), dist = C.round(C.dist(en.position, pos)) }
    end
  end
  table.sort(enemies, function(a, b) return a.dist < b.dist end)
  while #enemies > NEAR_ENEMIES_MAX do table.remove(enemies) end
  -- Сундуки — статичное: только в открытых чанках (PROTOCOL §6.7).
  local containers = 0
  local chests = surface.find_entities_filtered { position = pos, radius = NEAR_RADIUS, force = force, type = CONTAINER_TYPES }
  for _, c in ipairs(chests) do
    if c.valid and view.charted(c.position) then containers = containers + 1 end
  end
  return { enemies = enemies, containers = containers }
end

-- Вид тела и счётчик ошибок модулей — данные ядра. Зовём под pcall с запасным
-- значением: тесты восприятия идут и без ядра, а сбой чужого модуля не должен ронять `state`.
-- (`core_registry` подключён при загрузке файла: `require` в рантайме Factorio запрещён.)
local function core_call(mod, fn, ...)
  if type(mod) ~= "table" or type(mod[fn]) ~= "function" then return nil end
  local ok, v = pcall(mod[fn], ...)
  if ok then return v end
  return nil
end

-- "character" │ "player" (PROTOCOL §7 «Два вида тела»).
local function body_kind(helper_id)
  local kind = core_call(core_registry, "body_kind", helper_id)
  if kind == "player" or kind == "character" then return kind end
  if core_call(core_registry, "is_player_body", helper_id) == true then return "player" end
  local hs = storage.helpers
  local rec = type(hs) == "table" and hs[helper_id] or nil
  if type(rec) == "table" and rec.player_index ~= nil then return "player" end
  return "character"
end

local function module_errors()
  local n = core_call(err, "module_errors")
  if type(n) == "number" then return n end
  return 0
end

local function state_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, {})
  local e = C.helper_entity(ctx, true)
  local helper_id = ctx.helper_id

  local main = e.get_inventory(defines.inventory.character_main)
  local armor_inv = e.get_inventory(defines.inventory.character_armor)
  local armor
  if armor_inv and armor_inv.valid and #armor_inv > 0 then
    local st = armor_inv[1]
    if st and st.valid_for_read then armor = st.name end
  end

  local job, queue = C.job_summary(helper_id)
  local idle_ticks, busy_share, busy_window = metrics.snapshot(helper_id, game.tick)

  return {
    helper = helper_id,
    surface = e.surface.name,
    pos = C.rpos(e.position),
    health = C.round(e.health or 0),
    max_health = C.round(read(e, "max_health") or e.prototype.get_max_health()),
    reach = {
      build = C.round(e.build_distance),
      reach = C.round(e.reach_distance),
      resource = C.round(e.resource_reach_distance),
      pickup = C.round(e.item_pickup_distance),
    },
    inv = C.inv_counts(main),
    inv_free = (main and main.valid) and main.count_empty_stacks() or 0,
    armor = armor,
    robots = robots(e),
    job = job,
    queue = queue,
    idle_ticks = idle_ticks,
    busy_share = busy_share and floor(busy_share * 100 + 0.5) / 100 or nil,
    busy_window = busy_window,
    players = players_list(e),
    near = near(e, helper_id),
    vision = C.vision_on(helper_id),
    body = body_kind(helper_id),
    module_errors = module_errors(),
    tick = game.tick,
    seq = C.last_seq(),
  }
end

M.ops = {
  state = state_op,
}

return M
