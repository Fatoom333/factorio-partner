-- Рефлекс `evacuate` — разобрать постройки области, пока к ней идут враги, и поставить их обратно,
-- когда станет тихо. Контракт: docs/EVENTS.md (evacuate_started, evacuated, evacuate_missing,
-- evacuate_restored, reflex_resumed), docs/ACTIONS.md (deconstruct, place, insert, walk),
-- PROTOCOL.md §6.5 (только честная игра), §6.7 (живое — только видимое).
--
--   evacuate { area:{left_top, right_bottom} (сторона ≤ 96) │ center:{x, y} + radius (1..48),
--              names?:[имя постройки] (≤ 32; только эти, в этом порядке), threat_radius?=40 (10..120),
--              return_after_s?=180 (30..1800), rebuild?=true }
--   Один на помощника. Включить или сменить при hold хозяина нельзя (owner_hold); убрать или сменить
--   область, пока идёт эвакуация или постройки в карманах ждут возврата (фаза не watch), — bad_args.
--
-- * Снимок. При включении (и при смене области или names) мод запоминает постройки своей силы в
--   области: имя, предмет, позиция, направление, вход/выход подземной ленты и погрузчика, рецепт
--   (сборочные машины), качество, модули внутри. Без предмета для постановки, некопаемое, техника с
--   водителем и персонажи в снимок не идут. Больше MAX_ENTITIES — отказ limit. Снимок — простые
--   таблицы в storage.evacuate[helper], сейв он переживает.
-- * Угроза — враг силы, враждебной силе тела (кусаки, пентаподы, разрушитель и его сегменты; черви
--   стоят на месте, гнёзда сами не ходят — не угроза), ближе threat_radius к краю области и видимый
--   помощнику. Любой такой враг считается, в том числе кусаки, что стоят у своего гнезда: у гнёзд
--   threat_radius берут меньше. Пока всё спокойно, проверка — раз в WATCH_EVERY тиков, во время
--   эвакуации и возврата — раз в 10; сначала дешёвый подсчёт (count_entities_filtered), список
--   враждебных сил — из storage, раз в FORCES_EVERY.
-- * Эвакуация. Задачи тела снимаются (как у flee: что было, запоминается для возврата; если
--   перед этим уже было отступление flee и его возврат к делу ещё ждёт, эвакуация забирает его себе),
--   тело обычными задачами `deconstruct` (req "reflex:evacuate") подходит и разбирает постройки
--   снимка — ценные первыми (порядок names, иначе машины и буры, потом турели и энергия, сундуки,
--   манипуляторы, трубы, ленты, столбы). Не трогаются (kept): постройки, разбор которых хозяин
--   теперь запретил (perms «нельзя»), и сундуки с содержимым (оно не влезет в карманы). Постройки,
--   которой уже нет, — lost. После — отступление обычной ходьбой прочь от врага (точки — как у flee).
--   Идёт и при hold хозяина: это защита, как flee. Пока идёт отступление flee, разбор ждёт; flee
--   прервал разбор больше MAX_FLEE_CUTS раз — враг уже у построек, эвакуация кончается (reason
--   "threatened"), остальное — left. Агент снял задачи разбора сам — эвакуация кончается (reason
--   "cancelled", его дело он решает сам; "owner_stop" — их снял «стоп» хозяина).
-- * Возврат. Врага нет return_after_s подряд, hold нет → (rebuild) задачи `place` по снимку из
--   карманов (рецепт — тем же place), модули — задачей `insert`. Ставится только то, что разобрало
--   это тело (taken); разрушенное (lost) не ставится и не просится. Постройки другого качества мод
--   не ставит (quality — они в карманах). Чего нет в карманах — evacuate_missing{items}. Стройку
--   хозяин запретил (build «нельзя») — ничего не ставится, всё в left. Настройки, которые place не
--   возвращает (фильтры, запросы, провода, комбинаторы), теряются: такие постройки — в reset.
--   «Стоп» хозяина посреди возврата — возврат ждёт его слова и потом продолжается с того, что
--   осталось. Потом снятые задачи ставятся снова: reflex_resumed{type:"evacuate"} (как после flee:
--   агент поставил своё — возврат молча отменяется; hold — reason "owner_hold"). Враг снова у
--   области во время возврата — задачи постановки снимаются, эвакуация заново.
-- * События (громкие): evacuate_started{area, threat:{name, pos, dist}},
--   evacuated{taken, lost, left?, kept?, reason?}, evacuate_missing{items},
--   evacuate_restored{placed, missing, failed?, left?, quality?, reset?, reason?};
--   taken/lost/left/kept/placed/failed/quality/reset — {имя постройки = число}, missing/items —
--   {имя предмета = число}. left в evacuate_restored — что осталось в карманах; reason "dropped" —
--   снимок забыт (рефлекс убрали, сменили область в спокойной фазе, удалили помощника), а
--   разобранное осталось в карманах; "owner_forbids" — стройку запретил хозяин.
-- * Разрешения хозяина — при включении (scripts/core/reflexes.lua def.perms): разбор построек
--   снимка (deconstruct-owner — поставленных игроком, deconstruct-own — своих) и, при rebuild, build;
--   в начале каждой эвакуации и возврата «нельзя» проверяется снова. Сами задачи — свои вызовы мода,
--   мимо гейта.
local util = require("scripts.core.util")
local err = require("scripts.core.err")
local events = require("scripts.core.events")
local jobs = require("scripts.core.jobs")
local perms = require("scripts.core.perms")
local vis = require("scripts.core.vis")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")
local C = require("scripts.reflexes.common")
local flee = require("scripts.reflexes.flee")

local M = {}
M.name = "reflexes.evacuate"

M.REQ = "reflex:evacuate"      -- req задач разбора, постановки и отступления (виден в `jobs`)
M.RESUME_REQ = "resume:evacuate"
M.MAX_ENTITIES = 200           -- построек в снимке
M.MAX_RADIUS = 48
M.MAX_SIDE = 96
M.MAX_NAMES = 32
M.BATCH = 8                    -- своих задач в очереди тела одновременно
M.MAX_FAILS = 2                -- столько раз не разобралась — дальше не пробуем
M.MAX_FLEE_CUTS = 3            -- столько раз flee прервал разбор — дальше не лезем к врагу
M.RETREAT = 40                 -- на сколько клеток отступать от врага
M.GOAL_RADIUS = 2
M.RESUME_MAX = 4
M.SCAN = 200                   -- событий за один просмотр буфера
M.WATCH_EVERY = 60             -- тиков между проверками угрозы, пока всё спокойно
M.FORCES_EVERY = 3600          -- тиков между пересчётами враждебных сил
M.THREAT_TYPES = { "unit", "spider-unit", "segmented-unit", "segment" }

-- Ценность постройки по типу: меньше — разбирается раньше.
M.RANK = {
  ["mining-drill"] = 1, ["assembling-machine"] = 1, furnace = 1, lab = 1, beacon = 1, ["rocket-silo"] = 1,
  roboport = 1, reactor = 1, ["fusion-reactor"] = 1, ["fusion-generator"] = 1, ["agricultural-tower"] = 1,
  ["ammo-turret"] = 2, ["electric-turret"] = 2, ["fluid-turret"] = 2, ["artillery-turret"] = 2,
  boiler = 2, generator = 2, ["solar-panel"] = 2, accumulator = 2, radar = 2, ["offshore-pump"] = 2,
  pump = 2, ["storage-tank"] = 2,
  container = 3, ["logistic-container"] = 3,
  inserter = 4,
  pipe = 5, ["pipe-to-ground"] = 5,
  ["transport-belt"] = 6, ["underground-belt"] = 6, splitter = 6, loader = 6, ["loader-1x1"] = 6,
  ["electric-pole"] = 7, wall = 7, gate = 7, lamp = 7,
}
M.RANK_OTHER = 4

local CONTAINERS = { container = true, ["logistic-container"] = true }
-- постройки, у которых всё дело — в настройках (place их не вернёт)
local SETTINGS_TYPES = {
  ["constant-combinator"] = true, ["decider-combinator"] = true, ["arithmetic-combinator"] = true,
  ["selector-combinator"] = true, ["programmable-speaker"] = true, ["power-switch"] = true,
  ["display-panel"] = true,
}
-- вход/выход: create_entity{type=...} (place args.type)
local IO_TYPES = { ["underground-belt"] = "belt_to_ground_type", loader = "loader_type", ["loader-1x1"] = "loader_type" }

-- ------------------------------------------------------------------ состояние

--- storage.evacuate[helper] = { key, surface, box, list = {запись снимка, ...}, phase, ... }
--- запись снимка: { name, item, count, pos, dir, io?, unit, quality, recipe?, modules?, lossy?, rank,
---                  state, fails, cuts, kept? }
--- state: "present" (стоит) │ "taken" (разобрал это тело, в карманах) │ "lost" (уничтожена до разбора).
--- phase: "watch" │ "evac" │ "retreat" │ "away" │ "restore".
local function all()
  local s = storage.evacuate
  if type(s) ~= "table" then
    s = {}
    storage.evacuate = s
  end
  return s
end

function M.state(helper)
  local s = storage.evacuate
  return type(s) == "table" and s[helper] or nil
end

--- Область рефлекса как {left_top, right_bottom} (углы упорядочены).
function M.box_of(p)
  if p.area ~= nil then
    local a, b = p.area.left_top, p.area.right_bottom
    return {
      left_top = { x = math.min(a.x, b.x), y = math.min(a.y, b.y) },
      right_bottom = { x = math.max(a.x, b.x), y = math.max(a.y, b.y) },
    }
  end
  local c, r = p.center, p.radius
  return { left_top = { x = c.x - r, y = c.y - r }, right_bottom = { x = c.x + r, y = c.y + r } }
end

local function key_of(p)
  local b = M.box_of(p)
  return string.format("%.2f,%.2f,%.2f,%.2f|%s", b.left_top.x, b.left_top.y, b.right_bottom.x, b.right_bottom.y,
    table.concat(p.names or {}, ","))
end

--- Расстояние от точки до прямоугольника (0 — внутри).
local function box_dist(p, b)
  local dx = math.max(b.left_top.x - p.x, 0, p.x - b.right_bottom.x)
  local dy = math.max(b.left_top.y - p.y, 0, p.y - b.right_bottom.y)
  return math.sqrt(dx * dx + dy * dy)
end

local function prop(obj, key)
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end

local function add(map, name, n)
  map[name] = (map[name] or 0) + (n or 1)
end

local function or_nil(map)
  if map == nil or next(map) == nil then return nil end
  return map
end

local function count_state(st, state)
  local out = {}
  for _, en in ipairs(st.list) do
    if en.state == state then add(out, en.name) end
  end
  return out
end

-- ------------------------------------------------------------------ снимок

--- Постройки области, которые рефлекс разбирает: своей силы, копаемые, с предметом для постановки.
local function scan(h, box, names)
  local filter = { area = { left_top = box.left_top, right_bottom = box.right_bottom }, force = h.force }
  if names ~= nil then filter.name = names end
  local out = {}
  for _, e in ipairs(h.surface.find_entities_filtered(filter)) do
    if e.valid and e ~= h and B.why_not_minable(e) == nil and not B.has_driver(e)
        and B.place_items(e.prototype)[1] ~= nil then
      out[#out + 1] = e
    end
  end
  if #out > M.MAX_ENTITIES then
    err.raise("limit", "more than " .. M.MAX_ENTITIES .. " buildings in the area; use a smaller area or names")
  end
  return out
end

--- Есть ли у постройки настройки, которые place не вернёт: провода, фильтры, приоритеты, запросы.
local function settings_lost(e)
  if SETTINGS_TYPES[e.type] then return true end
  local ok, cons = pcall(function() return e.get_wire_connectors(false) end)
  if ok and type(cons) == "table" then
    for _, c in pairs(cons) do
      local n = prop(c, "connection_count")
      if type(n) == "number" and n > 0 then return true end
    end
  end
  if (e.type == "inserter" or e.type == "loader" or e.type == "loader-1x1") and prop(e, "use_filters") == true then
    return true
  end
  if e.type == "splitter" then
    if prop(e, "splitter_filter") ~= nil then return true end
    for _, k in ipairs({ "splitter_input_priority", "splitter_output_priority" }) do
      local v = prop(e, k)
      if v ~= nil and v ~= "none" then return true end
    end
  end
  if e.type == "logistic-container" then
    local ok2, n = pcall(function()
      local s = e.get_logistic_sections()
      local total = 0
      for i = 1, s.sections_count do total = total + s.get_section(i).filters_count end
      return total
    end)
    if ok2 and type(n) == "number" and n > 0 then return true end
  end
  return false
end

local function record(e, order)
  local it = B.place_items(e.prototype)[1]
  local en = {
    name = e.name, item = it.name, count = it.count, pos = util.xy(e.position), dir = e.direction or 0,
    unit = e.unit_number, state = "present", fails = 0, cuts = 0,
    rank = order[e.name] or M.RANK[e.type] or M.RANK_OTHER,
  }
  local q = prop(e, "quality")
  en.quality = type(q) == "table" and q.name or (type(q) == "string" and q) or "normal"
  local io = IO_TYPES[e.type] and prop(e, IO_TYPES[e.type]) or nil
  if io == "input" or io == "output" then en.io = io end
  if e.type == "assembling-machine" then
    local ok, r = pcall(function() return e.get_recipe() end)
    if ok and r ~= nil then en.recipe = type(r) == "string" and r or prop(r, "name") end
  end
  local ok, mi = pcall(function() return e.get_module_inventory() end)
  if ok and mi ~= nil then en.modules = or_nil(inv.counts(mi)) end
  if settings_lost(e) then en.lossy = true end
  return en
end

local function snapshot(h, p)
  local box = M.box_of(p)
  local order = {}
  for i, n in ipairs(p.names or {}) do
    if order[n] == nil then order[n] = i end
  end
  local list = {}
  for _, e in ipairs(scan(h, box, p.names)) do list[#list + 1] = record(e, order) end
  table.sort(list, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    if a.pos.y ~= b.pos.y then return a.pos.y < b.pos.y end
    return a.pos.x < b.pos.x
  end)
  return { key = key_of(p), surface = h.surface.index, box = box, list = list, phase = "watch" }
end

-- ------------------------------------------------------------------ угроза

--- Враждебные силе own силы: из storage, пересчёт раз в FORCES_EVERY (одинаково у всех игроков).
local function enemy_forces(own, tick)
  local cache = storage.evacuate_forces
  if type(cache) ~= "table" then
    cache = {}
    storage.evacuate_forces = cache
  end
  local c = cache[own.name]
  if c ~= nil and tick - c.tick < M.FORCES_EVERY and tick >= c.tick then return c.list end
  local out = {}
  for _, f in pairs(game.forces) do
    local ok, name, yes = pcall(function() return f.name, f.name ~= own.name and own.is_enemy(f) end)
    if ok and yes == true then out[#out + 1] = name end
  end
  cache[own.name] = { tick = tick, list = out }
  return out
end

--- Ближайший к области видимый враг, который может прийти: {name, pos, dist} │ nil.
local function find_threat(id, h, st, p, tick)
  local forces = enemy_forces(h.force, tick or game.tick)
  if forces[1] == nil then return nil end
  local b, r = st.box, p.threat_radius
  local filter = {
    area = { left_top = { x = b.left_top.x - r, y = b.left_top.y - r },
             right_bottom = { x = b.right_bottom.x + r, y = b.right_bottom.y + r } },
    type = M.THREAT_TYPES, force = forces,
  }
  if h.surface.count_entities_filtered(filter) == 0 then return nil end
  local best
  for _, e in ipairs(h.surface.find_entities_filtered(filter)) do
    if e.valid then
      local pos = util.xy(e.position)
      local d = box_dist(pos, b)
      if d <= r and (best == nil or d < best.dist) and vis.visible(id, h.surface, pos, h.force) then
        best = { name = e.name, pos = pos, dist = d }
      end
    end
  end
  return best
end

-- ------------------------------------------------------------------ задачи тела

local function entity_of(h, en)
  local list = h.surface.find_entities_filtered{ position = en.pos, radius = 0.5, name = en.name, force = h.force }
  for _, e in ipairs(list) do
    if e.valid and (en.unit == nil or e.unit_number == en.unit) then return e end
  end
  return nil
end

--- Та же постройка на месте записи, кем бы ни поставлена (номер мог смениться).
local function standing(h, en)
  local list = h.surface.find_entities_filtered{ position = en.pos, radius = 0.5, name = en.name, force = h.force }
  for _, e in ipairs(list) do
    if e.valid then return e end
  end
  return nil
end

local function fleeing(id)
  local s = C.state(id)
  return s ~= nil and s.flee ~= nil
end

local function job_pending(id, job)
  local active = jobs.active(id)
  if active ~= nil and active.job == job then return true end
  local q = jobs.queue_of(id, false)
  for _, t in ipairs(q and q.queue or {}) do
    if t.job == job then return true end
  end
  return false
end

local function idle(id)
  if jobs.active(id) ~= nil then return false end
  local q = jobs.queue_of(id, false)
  return q == nil or q.queue == nil or q.queue[1] == nil
end

local function act(id, h, tick, name, args, replace, hold_ok)
  return pcall(jobs.op_act, { ["do"] = name, args = args, replace = replace == true },
    { helper_id = id, request_id = M.REQ, entity = h, tick = tick, owner_hold_ok = hold_ok == true or nil })
end

--- Снять свои задачи из очереди тела (без событий об итоге в состояние: они уже не нужны).
local function cancel_pending(id, h, st)
  for _, p in ipairs(st.pending or {}) do
    if job_pending(id, p.job) then
      pcall(jobs.op_cancel, { job = p.job }, { helper_id = id, entity = h, tick = game.tick })
    end
  end
  st.pending = {}
end

local function has_present(st)
  for _, en in ipairs(st.list) do
    if en.state == "present" and en.fails < M.MAX_FAILS and en.kept == nil then return true end
  end
  return false
end

--- Хозяин запретил разбор этой постройки (perms «нельзя»)?
local function dig_denied(e)
  for _, k in ipairs(perms.dig_keys(e, {})) do
    if perms.get(k) == "deny" then return true end
  end
  return false
end

--- Сундук с содержимым: оно уйдёт в карманы и забьёт их.
local function has_contents(e)
  if not CONTAINERS[e.type] then return false end
  local ok, empty = pcall(function()
    local i = e.get_inventory(defines.inventory.chest)
    if i == nil then return true end
    return i.is_empty()
  end)
  return ok and empty == false
end

-- ------------------------------------------------------------------ итоги задач

local CANCEL = { cancelled = true, no_helper = true, owner_hold = true }

--- Задача снята. Отступление flee — вернуть запись в очередь (но не больше MAX_FLEE_CUTS раз);
--- «стоп» хозяина — особый итог; иначе её снял агент.
local function on_cut(id, st, p, en)
  if fleeing(id) then
    en.cuts = (en.cuts or 0) + 1
    if en.cuts > M.MAX_FLEE_CUTS then
      st.aborted = "threatened" -- враг уже у построек: не ходить к нему снова и снова
      en.fails = M.MAX_FAILS
      if p.kind == "take" then add(st.left, en.name) else add(st.failed, en.name) end
      return
    end
    table.insert(st.todo, 1, p.idx) -- отступление flee: дело продолжится после него
  elseif jobs.held(id) ~= nil then
    if p.kind == "place" then table.insert(st.todo, 1, p.idx) end
    st.aborted = "owner_stop"
  else
    st.aborted = "cancelled"
  end
end

local function on_result(id, h, st, p, ev)
  local d = ev.data
  local done = ev.kind == "job_done"
  local en = p.idx and st.list[p.idx] or nil
  if p.kind == "take" and en ~= nil then
    if done then
      local removed = type(d.detail) == "table" and d.detail.removed or 0
      if type(removed) == "number" and removed >= 1 then
        en.state = "taken"
        add(st.taken, en.name)
      else
        en.state = "lost" -- исчезла сама (или её разобрал кто-то другой), пока тело шло
        add(st.lost, en.name)
      end
    elseif d.code == "not_found" then
      en.state = "lost"
      add(st.lost, en.name)
    elseif CANCEL[d.code] then
      on_cut(id, st, p, en)
    else
      en.fails = en.fails + 1
      add(st.left, en.name)
    end
  elseif p.kind == "place" and en ~= nil then
    if done then
      en.state = "present"
      en.fails, en.cuts = 0, 0
      if type(d.detail) == "table" and type(d.detail.unit_number) == "number" then en.unit = d.detail.unit_number end
      add(st.placed, en.name)
      if en.lossy then add(st.reset, en.name) end
      if en.modules ~= nil then st.inserts[#st.inserts + 1] = p.idx end
    elseif d.code == "no_items" then
      add(st.missing, en.item, en.count)
    elseif CANCEL[d.code] then
      on_cut(id, st, p, en)
    else
      en.fails = en.fails + 1
      add(st.failed, en.name)
    end
  end
end

--- Разобрать итоги своих задач из буфера событий; задача пропала без события (буфер переполнился) —
--- итог по миру.
local function collect(id, h, st)
  local pending = st.pending
  if pending[1] == nil then
    st.cursor = events.last_seq()
    return
  end
  local since = st.cursor or 0
  for _ = 1, 8 do
    local list, seq = events.query(since, id, M.SCAN)
    for _, ev in ipairs(list) do
      if (ev.kind == "job_done" or ev.kind == "job_failed") and type(ev.data) == "table" then
        for i, p in ipairs(pending) do
          if p.job == ev.data.job then
            table.remove(pending, i)
            on_result(id, h, st, p, ev)
            break
          end
        end
      end
    end
    since = seq
    if #list < M.SCAN then break end
  end
  st.cursor = since
  for i = #pending, 1, -1 do
    local p = pending[i]
    if not job_pending(id, p.job) then
      table.remove(pending, i)
      local en = p.idx and st.list[p.idx] or nil
      if en ~= nil and (p.kind == "take" or p.kind == "place") then
        local here = entity_of(h, en) ~= nil
        local ok = (p.kind == "take") ~= here
        on_result(id, h, st, p, { kind = ok and "job_done" or "job_failed",
          data = { job = p.job, code = ok and nil or "unknown", detail = { removed = ok and 1 or 0 } } })
      end
    end
  end
end

-- ------------------------------------------------------------------ возврат к делу

local function resumed(id, made, reason)
  events.emit(id, "reflex_resumed", { type = "evacuate", jobs = made, reason = reason }, { loud = true })
end

local function finish_return(id, h, st, tick)
  local saved = st.saved
  st.phase = "watch"
  st.saved, st.quiet, st.todo, st.pending, st.inserts = nil, nil, nil, {}, nil
  st.placed, st.missing, st.failed, st.reset, st.quality, st.going_on = nil, nil, nil, nil, nil, nil
  st.owner_stopped = nil
  for _, en in ipairs(st.list) do
    -- следующая волна врагов — новая попытка для всего, что стоит
    if en.state == "present" then en.fails, en.cuts, en.kept = 0, 0, nil end
  end
  if saved == nil or saved[1] == nil then return end
  if not idle(id) then return end -- агент уже решил сам
  if jobs.held(id) ~= nil then return resumed(id, {}, "owner_hold") end
  local made = {}
  for _, t in ipairs(saved) do
    local ok, res = pcall(jobs.op_act, { ["do"] = t["do"], args = t.args, replace = false },
      { helper_id = id, request_id = M.RESUME_REQ, entity = h, tick = tick })
    if ok then made[#made + 1] = { job = res.job, ["do"] = t["do"] } end
  end
  resumed(id, made, made[1] == nil and "rejected" or nil)
end

local function save_jobs(id, st)
  st.saved = st.saved or {}
  for _, t in ipairs(flee.pending_jobs(id)) do
    if #st.saved >= M.RESUME_MAX then break end
    st.saved[#st.saved + 1] = t
  end
end

--- Дело, которое ждёт возврата после отступления flee: теперь его вернёт эвакуация (flee его
--- бросит, как только тело займётся разбором).
local function take_flee_resume(id, st)
  local fs = C.state(id)
  local r = fs and fs.resume
  if r == nil then return end
  fs.resume = nil
  local out = {}
  for _, t in ipairs(r.tasks or {}) do
    if #out < M.RESUME_MAX then out[#out + 1] = t end
  end
  for _, t in ipairs(st.saved or {}) do
    if #out < M.RESUME_MAX then out[#out + 1] = t end
  end
  st.saved = out
end

-- ------------------------------------------------------------------ эвакуация

local function start_retreat(id, h, st, p, threat, tick)
  local fp = { to = "away", distance = M.RETREAT, radius = p.threat_radius }
  for _, c in ipairs(flee.retreat_candidates(h, fp, threat)) do
    local spot = flee.usable_spot(id, h, c)
    if spot ~= nil then
      save_jobs(id, st) -- поставленное агентом за время разбора вернётся вместе с остальным
      local ok, res = act(id, h, tick, "walk", { to = spot, radius = M.GOAL_RADIUS }, true, true)
      if ok then
        st.pending = { { job = res.job, kind = "walk" } }
        st.cursor = events.last_seq()
        st.phase = "retreat"
        return
      end
    end
  end
  st.phase = "away"
end

local function finish_evac(id, h, st, p, tick, reason)
  cancel_pending(id, h, st)
  if reason == "threatened" then
    -- что не успели разобрать, в эту волну больше не трогаем
    for _, idx in ipairs(st.todo or {}) do
      local en = st.list[idx]
      if en.state == "present" then
        en.fails = M.MAX_FAILS
        add(st.left, en.name)
      end
    end
  end
  events.emit(id, "evacuated", {
    taken = st.taken, lost = st.lost, left = or_nil(st.left), kept = or_nil(st.kept), reason = reason,
  }, { loud = true })
  st.todo = nil
  st.quiet = nil
  if reason == "cancelled" then
    st.saved = nil -- задачи снял агент: что дальше, решает он
    st.phase = "away"
    return
  end
  if reason ~= nil then
    st.phase = "away" -- flee уже увёл тело, «стоп» хозяина держит его на месте
    st.owner_stopped = reason == "owner_stop" or nil
    return
  end
  local threat = find_threat(id, h, st, p, tick)
  if threat ~= nil then return start_retreat(id, h, st, p, threat, tick) end
  st.phase = "away"
end

local function pump_evac(id, h, st, p, tick)
  collect(id, h, st)
  if st.aborted ~= nil then
    local reason = st.aborted
    st.aborted = nil
    return finish_evac(id, h, st, p, tick, reason)
  end
  if fleeing(id) then return end
  local todo = st.todo
  while #st.pending < M.BATCH and todo[1] ~= nil do
    local idx = table.remove(todo, 1)
    local en = st.list[idx]
    local e = entity_of(h, en)
    if e == nil then
      en.state = "lost"
      add(st.lost, en.name)
    else
      local ok, res = act(id, h, tick, "deconstruct",
        { target = { unit_number = e.unit_number, pos = util.pos(e.position) } }, st.first, true)
      if not ok then
        table.insert(todo, 1, idx) -- очередь полна: дольём на следующей проверке
        break
      end
      st.first = false
      st.pending[#st.pending + 1] = { job = res.job, idx = idx, kind = "take" }
    end
  end
  if todo[1] == nil and st.pending[1] == nil then finish_evac(id, h, st, p, tick, nil) end
end

local function start_evac(id, h, st, p, threat, tick)
  if st.saved == nil then st.saved = flee.pending_jobs(id) end -- до замены очереди разбором
  take_flee_resume(id, st)
  st.taken, st.lost, st.left, st.kept = {}, {}, {}, {}
  local todo = {}
  for i, en in ipairs(st.list) do
    en.kept = nil
    if en.state == "present" and en.fails < M.MAX_FAILS then
      local e = entity_of(h, en)
      -- разрешения хозяина могли смениться после включения; сундук с содержимым забьёт карманы
      if e ~= nil and dig_denied(e) then
        en.kept = "denied"
      elseif e ~= nil and has_contents(e) then
        en.kept = "contents"
      end
      if en.kept ~= nil then add(st.kept, en.name) else todo[#todo + 1] = i end
    end
  end
  st.phase = "evac"
  st.threat = { name = threat.name, pos = { x = threat.pos.x, y = threat.pos.y } }
  st.todo, st.pending, st.inserts = todo, {}, nil
  st.first = idle(id) == false -- очередь тела снимается первой же задачей разбора
  st.cursor = events.last_seq()
  st.quiet = nil
  events.emit(id, "evacuate_started", {
    area = util.plain(st.box),
    threat = { name = threat.name, pos = util.pos(threat.pos), dist = util.round1(threat.dist) },
  }, { loud = true })
  pump_evac(id, h, st, p, tick)
end

-- ------------------------------------------------------------------ возврат построек

local function finish_restore(id, h, st, tick, reason)
  events.emit(id, "evacuate_restored", {
    placed = st.placed, missing = st.missing, failed = or_nil(st.failed),
    left = or_nil(count_state(st, "taken")), quality = or_nil(st.quality), reset = or_nil(st.reset),
    reason = reason,
  }, { loud = true })
  finish_return(id, h, st, tick)
end

local function same_map(a, b)
  for k, v in pairs(a or {}) do
    if (b or {})[k] ~= v then return false end
  end
  for k in pairs(b or {}) do
    if (a or {})[k] == nil then return false end
  end
  return true
end

local function start_restore(id, h, st, p, tick)
  if not p.rebuild then return finish_return(id, h, st, tick) end
  local going_on = st.going_on -- возврат после «стоп» хозяина: итог общий
  st.going_on = nil
  st.placed = going_on and st.placed or {}
  st.failed = going_on and st.failed or {}
  st.reset = going_on and st.reset or {}
  st.quality = {}
  st.phase = "restore"
  st.pending, st.inserts = {}, {}
  st.cursor = events.last_seq()
  if perms.get("build") == "deny" then
    st.todo, st.missing = {}, {}
    return finish_restore(id, h, st, tick, "owner_forbids")
  end
  local have = inv.counts(h.get_main_inventory())
  local todo, missing = {}, {}
  local function take(name, n)
    local got = math.min(have[name] or 0, n)
    have[name] = (have[name] or 0) - got
    if got < n then add(missing, name, n - got) end
    return got == n
  end
  for i, en in ipairs(st.list) do
    if en.state == "taken" and standing(h, en) ~= nil then
      en.state = "present" -- уже стоит: поставил хозяин или другой помощник
    end
    if en.state == "taken" then
      if en.quality ~= nil and en.quality ~= "normal" then
        add(st.quality, en.name) -- мод ставит только обычное качество: эта постройка ждёт в карманах
      elseif take(en.item, en.count or 1) then
        todo[#todo + 1] = i
        for m, n in pairs(en.modules or {}) do take(m, n) end
      end
    end
  end
  st.todo = todo
  st.missing = missing
  if next(missing) ~= nil and not same_map(missing, st.missing_told) then
    events.emit(id, "evacuate_missing", { items = util.plain(missing) }, { loud = true })
  end
  st.missing_told = or_nil(util.plain(missing))
end

local function pump_restore(id, h, st, p, tick)
  collect(id, h, st)
  if st.aborted == "owner_stop" then
    -- «стоп» хозяина: возврат ждёт его слова и потом продолжится с того, что осталось
    st.aborted = nil
    cancel_pending(id, h, st)
    st.phase, st.todo, st.inserts = "away", nil, nil
    st.quiet = tick - p.return_after_s * 60
    st.going_on = true
    return
  end
  if st.aborted ~= nil then
    local reason = st.aborted
    st.aborted = nil
    cancel_pending(id, h, st)
    return finish_restore(id, h, st, tick, reason)
  end
  local threat = find_threat(id, h, st, p, tick)
  if threat ~= nil then
    cancel_pending(id, h, st)
    return start_evac(id, h, st, p, threat, tick)
  end
  if fleeing(id) or jobs.held(id) ~= nil then return end -- возврат при hold ждёт
  -- модули в поставленные машины: что есть в карманах (нехватка уже в evacuate_missing)
  while st.inserts[1] ~= nil and #st.pending < M.BATCH do
    local idx = table.remove(st.inserts, 1)
    local en = st.list[idx]
    local main = h.get_main_inventory()
    local items = {}
    for m, n in pairs(en.modules or {}) do
      local k = math.min(n, inv.count(main, m))
      if k > 0 then items[m] = k end
    end
    if next(items) ~= nil and en.unit ~= nil then
      local ok, res = act(id, h, tick, "insert", { target = { unit_number = en.unit, pos = util.pos(en.pos) }, items = items })
      if ok then st.pending[#st.pending + 1] = { job = res.job, idx = idx, kind = "insert" } end
    end
  end
  local todo = st.todo
  while #st.pending < M.BATCH and todo[1] ~= nil do
    local idx = table.remove(todo, 1)
    local en = st.list[idx]
    local ok, res = act(id, h, tick, "place", {
      item = en.item, pos = { x = en.pos.x, y = en.pos.y }, direction = en.dir, recipe = en.recipe, type = en.io,
    })
    if not ok then
      local code = err.normalize(res)
      if code == "owner_hold" or code == "limit" then
        table.insert(todo, 1, idx) -- подождать: hold снимет хозяин, очередь освободится
        break
      end
      en.fails = en.fails + 1
      add(st.failed, en.name)
    else
      st.pending[#st.pending + 1] = { job = res.job, idx = idx, kind = "place" }
    end
  end
  if todo[1] == nil and st.pending[1] == nil and st.inserts[1] == nil then finish_restore(id, h, st, tick) end
end

-- ------------------------------------------------------------------ раз в 10 тиков

function M.check(id, h, p, tick)
  local st = M.state(id)
  if st == nil or st.key ~= key_of(p) then
    st = snapshot(h, p)
    all()[id] = st
  end
  if h.surface.index ~= st.surface then return end
  st.pending = st.pending or {}
  local phase = st.phase
  if phase == "evac" then return pump_evac(id, h, st, p, tick) end
  if phase == "restore" then return pump_restore(id, h, st, p, tick) end
  if phase == "retreat" then
    collect(id, h, st)
    if st.pending[1] == nil then st.phase, st.quiet = "away", nil end
    return
  end
  if phase == "watch" then
    -- спокойно: смотреть реже (UPS на большой базе)
    if st.looked ~= nil and tick >= st.looked and tick - st.looked < M.WATCH_EVERY then return end
    st.looked = tick
  end
  local threat = find_threat(id, h, st, p, tick)
  if phase == "away" then
    if threat ~= nil then
      st.quiet = nil
      -- разбор снял «стоп» хозяина: пока hold стоит, заново не начинать
      local stopped = st.owner_stopped and jobs.held(id) ~= nil
      if has_present(st) and not fleeing(id) and not stopped then start_evac(id, h, st, p, threat, tick) end
      return
    end
    if st.quiet == nil then st.quiet = tick end
    if tick - st.quiet < p.return_after_s * 60 then return end
    if jobs.held(id) ~= nil or fleeing(id) then return end -- возврат при hold ждёт
    return start_restore(id, h, st, p, tick)
  end
  if threat ~= nil and has_present(st) and not fleeing(id) then start_evac(id, h, st, p, threat, tick) end
end

-- ------------------------------------------------------------------ интерфейс модуля

local function validate(v, path)
  if (v.area == nil) == (v.center == nil) then
    err.raise("bad_args", path .. ": exactly one of area, center is required")
  end
  if v.center ~= nil and v.radius == nil then err.raise("bad_args", path .. ".radius: required with center") end
  if v.area ~= nil and v.radius ~= nil then err.raise("bad_args", path .. ".radius: only with center") end
  for i, n in ipairs(v.names or {}) do
    -- неизвестное имя в find_entities_filtered — ошибка движка
    if prototypes.entity[n] == nil then err.raise("bad_args", path .. ".names[" .. i .. "]: unknown entity " .. n) end
  end
  return v
end

local function same(a, b)
  return a ~= nil and b ~= nil and key_of(a) == key_of(b) and a.rebuild == b.rebuild
end

--- Снимок забыт, а разобранное этим телом ещё в карманах: сказать громко, что не вернётся.
local function drop(id, st)
  local left = count_state(st, "taken")
  if next(left) == nil then return end
  events.emit(id, "evacuate_restored", { placed = {}, missing = {}, left = left, reason = "dropped" }, { loud = true })
end

M.reflexes = {
  evacuate = {
    once = true, -- одно состояние на помощника (storage.evacuate[helper])
    schema = {
      area = { type = "area", max_side = M.MAX_SIDE },
      center = { type = "pos" },
      radius = { type = "number", min = 1, max = M.MAX_RADIUS },
      names = { type = "list", of = { type = "string", max = 100 }, max = M.MAX_NAMES },
      threat_radius = { type = "number", min = 10, max = 120, default = 40 },
      return_after_s = { type = "int", min = 30, max = 1800, default = 180 },
      rebuild = { type = "bool", default = true },
    },
    validate = validate,
    -- разбор построек снимка и (rebuild) стройка; те же параметры повторно — без вопроса
    perms = function(v, ctx, old)
      if same(v, old) then return {} end
      local keys = {}
      if v.rebuild then keys[1] = "perm-build" end
      local h = ctx and ctx.entity
      if h == nil or not h.valid then
        perms.add(keys, "perm-deconstruct-owner")
        return keys
      end
      for _, e in ipairs(scan(h, M.box_of(v), v.names)) do perms.dig_keys(e, keys) end
      return keys
    end,
    -- набор ещё не записан: отказ оставляет прежний
    guard = function(id, v, old, ctx)
      local changed = v == nil or old == nil or key_of(v) ~= key_of(old)
      if v ~= nil and (old == nil or not same(v, old)) and jobs.held(id) ~= nil then
        err.raise("owner_hold", "evacuate: the owner said stop; wait for his next word before switching it on or changing it")
      end
      local st = M.state(id)
      if changed and st ~= nil and st.phase ~= nil and st.phase ~= "watch" then
        local n = 0
        for _, en in ipairs(st.list or {}) do
          if en.state == "taken" then n = n + 1 end
        end
        err.raise("bad_args", "evacuate: an evacuation is under way (phase " .. st.phase .. ", " .. n
          .. " buildings in the pockets); keep the same area and names until evacuate_restored")
      end
    end,
    on_set = function(id, v, old, ctx)
      local st = M.state(id)
      if st ~= nil and old ~= nil and st.key == key_of(v) then return end
      local h = ctx and ctx.entity
      if st ~= nil then
        drop(id, st)
        if h ~= nil and h.valid then cancel_pending(id, h, st) end
      end
      all()[id] = (h ~= nil and h.valid) and snapshot(h, v) or nil
    end,
    on_unset = function(id)
      local st = M.state(id)
      if st == nil then return end
      drop(id, st)
      local rec = storage.helpers and storage.helpers[id]
      local h = rec and rec.entity
      if h ~= nil and h.valid then cancel_pending(id, h, st) end
      all()[id] = nil
    end,
    check = function(id, entity, params, tick)
      M.check(id, entity, params, tick)
    end,
  },
}

return M
