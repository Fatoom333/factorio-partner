-- Рефлексы «атака, здоровье, отступление».
-- Контракт: docs/EVENTS.md (attacked, health_low, reflex_fired, reflex_done, saw_enemy),
-- docs/ARCHITECTURE.md «Модульный интерфейс», docs/PROTOCOL.md §6.1 (ходьба, не перенос), §6.7.
--
-- Всегда включено (набор рефлексов не нужен):
--   attacked{by, damage, health}  — первое за эпизод громкое, дальше шумные не чаще раза в секунду
--                                   (урон за секунду суммируется); эпизод кончается через 30 с без урона;
--   health_low{health, max}       — здоровье < 40 %, один раз; снова — после восстановления до 50 %.
--
-- Типы рефлексов для `reflexes{set:[...]}`:
--   flee  { radius?=20 (4..32), distance?=30 (8..64), health?=1 (0..1), on_attack?=true,
--           to?="away"│"spawn"│"player" }
--     Враг (сила enemy: кусаки, черви, пентаподы, разрушитель) ближе radius, либо (on_attack) только
--     что ударил издалека, и здоровье ≤ health (доля; 1 — отступать при любом здоровье) →
--     помощник бросает задачи (им приходит job_failed{cancelled}) и идёт обычной задачей `walk`
--     к безопасной точке: на distance клеток прочь от врага (или к точке возрождения силы / к
--     хозяину, если до них далеко от врага). Точка — в открытом чанке, свободная, без врагов рядом.
--     Путь не нашёлся — точки считаются заново (от места, где помощник стоит теперь, и от
--     врага, который ближе теперь), уже испробованные пропускаются; попыток на переход — до 8.
--     Дошёл, а враг снова рядом — ещё переход (до 5). Шумное reflex_fired{type, detail:{job, to, threat, dist}} в начале, громкое
--     reflex_done{type, outcome, detail:{pos, legs, reason?}} в конце.
--     reason: no_safe_point │ cancelled (задачу сняли — агент решил иначе) │ still_threatened │
--     no_helper │ код ошибки ходьбы (path_failed, stuck, …).
--     Ревизия 3.11 — возврат к делу: resume?=true, resume_health?=0.8 (0..1). Перед отступлением
--     мод запоминает задачи, которые оно снимет (активную и очередь, без задач рефлексов, не больше
--     RESUME_MAX; у mine — остаток count). Отступление удалось (outcome ok), врага ближе radius нет,
--     здоровье ≥ resume_health, а агент за это время ничего не поставил — мод ставит их снова и шлёт
--     громкое reflex_resumed{type:"flee", jobs:[{job, do}]}. Не дождался за RESUME_WAIT или вернулся
--     уже RESUME_LIMIT раз за RESUME_WINDOW — reflex_resumed{jobs:[], reason:"timeout"│"too_often"}.
--     Агент сам что-то поставил — возврат молча отменяется (решил агент).
--   watch { radius?=32 (4..32), every_s?=10 (1..600) }
--     Шумное saw_enemy{name, pos, dist} о ближайшем враге (включая гнёзда), не чаще раза в every_s.
local util = require("scripts.core.util")
local err = require("scripts.core.err")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local owner = require("scripts.core.owner")
local jobs = require("scripts.core.jobs")
local C = require("scripts.reflexes.common")

local M = {}
M.name = "reflexes.flee"

M.EPISODE = 30 * 60        -- тиков без урона — эпизод атаки кончился
M.NOISY_EVERY = 60         -- повторные attacked не чаще
M.LOW = 0.4                -- health_low: здоровье ниже этой доли
M.LOW_REARM = 0.5          -- … и снова после восстановления до этой
M.RECENT_HIT = 120         -- удар врага издалека считается угрозой столько тиков
M.MAX_LEGS = 5             -- переходов подряд за одно отступление
M.GOAL_RADIUS = 2          -- walk.radius: на сколько близко подойти к точке
M.MAX_TRIES = 8            -- точек на один переход (после path_failed / stuck — другая)
M.TRIED_RADIUS = 3         -- точка ближе этого к уже испробованной — та же самая
M.MIN_GOAL = 8             -- ближе этого точка спасения бессмысленна
M.SAFE_RADIUS = 8          -- врагов ближе этого к точке быть не должно
M.FREE_RADIUS = 4          -- поиск свободного места у точки
M.BLOCK_OK = 60            -- пауза после удачного отступления
M.BLOCK_FAILED = 600       -- пауза после неудачи (не спорить с агентом и не шуметь)
M.FAIL_REPEAT = 3600       -- одинаковую неудачу «даже не начал» повторять не чаще
M.REQ = "reflex:flee"      -- req задачи ходьбы (виден в `jobs`)
M.ANGLES = { 0, 45, -45, 90, -90, 135, -135 } -- отклонения от направления «прочь от врага»
M.RESUME_MAX = 4           -- задач, которые отступление вернёт
M.RESUME_WAIT = 120 * 60   -- столько ждём здоровья и тишины для возврата
M.RESUME_LIMIT = 3         -- возвратов за RESUME_WINDOW — дальше решает агент
M.RESUME_WINDOW = 5 * 60 * 60
M.RESUME_REQ = "resume:flee"

local cos, sin, rad, sqrt = math.cos, math.sin, math.rad, math.sqrt

-- ------------------------------------------------------------------ атака и здоровье

local function attacker(e)
  local c = e.cause
  if c and c.valid then
    local threat
    local f = c.force
    if f and f.name == C.ENEMY_FORCE then threat = { name = c.name, pos = util.xy(c.position) } end
    return c.name, threat
  end
  local dt = e.damage_type
  if dt and type(dt.name) == "string" then return dt.name end
  return "unknown"
end

local function check_health(id, entity, st, health)
  local ratio, h, max = C.health(entity, health)
  if h <= 0 then return end
  if ratio < M.LOW then
    if not st.low then
      st.low = true
      events.emit(id, "health_low", { health = util.round1(h), max = util.round1(max) })
    end
  elseif ratio >= M.LOW_REARM then
    st.low = nil
  end
end

local function flee_params(id)
  local set = storage.reflexes and storage.reflexes[id]
  if type(set) ~= "table" then return nil end
  for _, r in ipairs(set) do
    if type(r) == "table" and r.type == "flee" then return r end
  end
  return nil
end

function M.on_damaged(e)
  local ent = e.entity
  if not (ent and ent.valid and ent.type == "character") then return end
  local id, rec = registry.find_by_unit(ent.unit_number)
  if id == nil or rec.state ~= "alive" then return end
  local dmg = e.final_damage_amount or 0
  if dmg <= 0 and (e.original_damage_amount or 0) <= 0 then return end
  local tick = e.tick or game.tick
  local st = C.body_state(id, ent)
  local by, threat = attacker(e)
  local health = type(e.final_health) == "number" and e.final_health or ent.health or 0
  local a = st.attack
  if a == nil or tick - a.last_tick >= M.EPISODE then
    a = { first_tick = tick, last_tick = tick, noisy_tick = tick, pending = 0 }
    st.attack = a
    events.emit(id, "attacked", { by = by, damage = util.round1(dmg), health = util.round1(health) }, { loud = true })
  else
    a.last_tick = tick
    a.pending = a.pending + dmg
    if tick - a.noisy_tick >= M.NOISY_EVERY then
      events.emit(id, "attacked", { by = by, damage = util.round1(a.pending), health = util.round1(health) }, { loud = false })
      a.pending = 0
      a.noisy_tick = tick
    end
  end
  a.by = by
  if threat ~= nil then a.threat = threat end
  if health <= 0 then return end -- сейчас умрёт: дальше — модуль death
  check_health(id, ent, st, health)
  local params = flee_params(id)
  if params ~= nil and params.on_attack then M.consider(id, ent, params, tick, st, health) end
end

-- ------------------------------------------------------------------ отступление

local function charted(entity, p)
  return entity.force.is_chunk_charted(entity.surface, C.chunk_of(p)) and true or false
end

--- Точки, куда можно отступать, по порядку предпочтения.
local function candidates(entity, p, threat)
  local pos = util.xy(entity.position)
  local out = {}
  local named
  if p.to == "spawn" then
    named = util.xy(entity.force.get_spawn_position(entity.surface))
  elseif p.to == "player" then
    local pl = owner.present()
    if pl ~= nil and pl.physical_surface.index == entity.surface.index then named = util.xy(pl.physical_position) end
  end
  if named ~= nil and util.dist(pos, named) >= M.MIN_GOAL and util.dist(named, threat.pos) > p.radius then
    out[#out + 1] = named
  end
  local dx, dy = pos.x - threat.pos.x, pos.y - threat.pos.y
  local len = sqrt(dx * dx + dy * dy)
  if len < 1e-6 then dx, dy, len = 1, 0, 1 end
  dx, dy = dx / len, dy / len
  for _, deg in ipairs(M.ANGLES) do
    local a = rad(deg)
    local ca, sa = cos(a), sin(a)
    out[#out + 1] = {
      x = pos.x + (dx * ca - dy * sa) * p.distance,
      y = pos.y + (dx * sa + dy * ca) * p.distance,
    }
  end
  return out
end

--- Годится ли точка: открытый чанк, есть свободное место, рядом (если видно) нет врагов.
local function usable(id, entity, pt)
  if not charted(entity, pt) then return nil end
  local spot = entity.surface.find_non_colliding_position("character", pt, M.FREE_RADIUS, 0.5)
  if spot == nil then return nil end
  spot = util.xy(spot)
  if not charted(entity, spot) then return nil end
  if C.visible(id, entity, spot) and C.enemies(entity, M.SAFE_RADIUS, C.THREAT, spot)[1] ~= nil then return nil end
  return { x = util.round1(spot.x), y = util.round1(spot.y) }
end

local function was_tried(tried, spot)
  for _, t in ipairs(tried) do
    if util.dist(t, spot) <= M.TRIED_RADIUS then return true end
  end
  return false
end

--- Поставить задачу ходьбы к первой годной точке. Кандидаты всегда считаются от нынешнего
--- места тела и от threat; tried — точки этого перехода, к которым дойти уже не вышло
--- (пропускаются). → true | false, причина.
--- Задачи помощника, которые снимет отступление: {{do, args}, ...} (без задач рефлексов).
local function snapshot(id)
  local out = {}
  local list = {}
  local active = jobs.active(id)
  if active ~= nil then list[1] = active end
  local q = jobs.queue_of(id, false)
  for _, t in ipairs(q and q.queue or {}) do list[#list + 1] = t end
  for _, t in ipairs(list) do
    if #out >= M.RESUME_MAX then break end
    local req = t.req
    if not (type(req) == "string" and req:sub(1, 7) == "reflex:") and type(t.args) == "table" then
      local args = util.copy(t.args)
      local done = t.progress and t.progress.done
      if t["do"] == "mine" and type(args.count) == "number" and (args.resource or args.item)
          and type(done) == "number" and done > 0 then
        args.count = math.max(1, args.count - done) -- вернуться — докопать остаток
      end
      out[#out + 1] = { ["do"] = t["do"], args = args }
    end
  end
  return out
end

local function start_leg(id, entity, st, p, threat, tick, legs, tried, resume)
  tried = tried or {}
  local cands = candidates(entity, p, threat)
  for i = 1, #cands do
    local spot = usable(id, entity, cands[i])
    if spot ~= nil and was_tried(tried, spot) then spot = nil end
    if spot ~= nil then
      local since = events.last_seq()
      local ok, res = pcall(jobs.op_act,
        { ["do"] = "walk", args = { to = spot, radius = M.GOAL_RADIUS }, replace = true },
        { helper_id = id, request_id = M.REQ, entity = entity, tick = tick })
      if not ok then
        local code = err.normalize(res)
        return false, code
      end
      st.flee = {
        job = res.job, goal = spot, legs = legs, cand = i, tried = tried, since_seq = since, started = tick,
        threat = { name = threat.name, pos = { x = threat.pos.x, y = threat.pos.y } },
        p = { radius = p.radius, distance = p.distance, to = p.to },
        resume = resume,
      }
      return true
    end
  end
  return false, "no_safe_point"
end

local function finish(id, entity, st, tick, outcome, detail)
  st.flee = nil
  st.flee_block = tick + (outcome == "ok" and M.BLOCK_OK or M.BLOCK_FAILED)
  if entity ~= nil and entity.valid then detail.pos = util.pos(entity.position) end
  events.emit(id, "reflex_done", { type = "flee", outcome = outcome, detail = detail })
end

local function find_threat(entity, params, st, tick)
  local near = C.enemies(entity, params.radius)[1]
  if near ~= nil then return near end
  local a = st.attack
  if params.on_attack and a ~= nil and a.threat ~= nil and tick - a.last_tick <= M.RECENT_HIT then
    return { name = a.threat.name, pos = a.threat.pos, dist = util.dist(util.xy(entity.position), a.threat.pos) }
  end
  return nil
end

--- Нужно ли отступать прямо сейчас; если да — начать. → true, если отступление началось.
function M.consider(id, entity, params, tick, st, health)
  st = st or C.body_state(id, entity)
  if st.flee ~= nil then return false end
  if st.flee_block ~= nil and tick < st.flee_block then return false end
  if C.health(entity, health) > params.health then return false end
  local threat = find_threat(entity, params, st, tick)
  if threat == nil then return false end
  local saved = snapshot(id) -- до замены очереди задачей отступления
  local ok, reason = start_leg(id, entity, st, params, threat, tick, 1, nil, saved)
  if ok then
    local f = st.flee
    events.emit(id, "reflex_fired", { type = "flee", detail = {
      job = f.job, to = util.pos(f.goal), threat = threat.name, dist = util.round1(threat.dist),
    } })
    return true
  end
  -- даже не начал: громко — один раз, потом молчим, пока причина та же
  st.flee_block = tick + M.BLOCK_FAILED
  local last = st.flee_fail
  if last == nil or last.reason ~= reason or tick - last.tick >= M.FAIL_REPEAT then
    st.flee_fail = { reason = reason, tick = tick }
    events.emit(id, "reflex_done", { type = "flee", outcome = "failed", detail = {
      reason = reason, pos = util.pos(entity.position), legs = 0, threat = threat.name,
    } })
  end
  return false
end

--- Итог задачи ходьбы job из буфера событий: событие job_done/job_failed или nil.
local function job_result(id, f)
  local since = f.since_seq
  for _ = 1, 4 do
    local list, seq = events.query(since, id, 200)
    for _, ev in ipairs(list) do
      if (ev.kind == "job_done" or ev.kind == "job_failed") and type(ev.data) == "table" and ev.data.job == f.job then
        return ev
      end
    end
    if #list < 200 then break end
    since = seq
  end
  return nil
end

local function job_idle(id)
  if jobs.active(id) ~= nil then return false end
  local q = jobs.queue_of(id, false)
  return q == nil or q.queue == nil or q.queue[1] == nil
end

local function job_pending(id, job)
  local active = jobs.active(id)
  if active ~= nil and active.job == job then return true end
  local q = jobs.queue_of(id, false)
  if q ~= nil then
    for _, t in ipairs(q.queue) do
      if t.job == job then return true end
    end
  end
  return false
end

--- Следить за идущим отступлением: задача кончилась — следующий переход, другая точка или итог.
local function progress(id, entity, st, tick)
  local f = st.flee
  if f == nil or job_pending(id, f.job) then return end
  local ev = job_result(id, f)
  local kind, code
  if ev ~= nil then
    kind, code = ev.kind, ev.data.code
  elseif util.dist(util.xy(entity.position), f.goal) <= M.GOAL_RADIUS + 1.5 then
    kind = "job_done"
  else
    kind, code = "job_failed", "unknown"
  end
  st.flee = nil
  if kind == "job_done" then
    local near = C.enemies(entity, f.p.radius)[1]
    if near == nil then
      st.flee_fail = nil
      finish(id, entity, st, tick, "ok", { legs = f.legs })
      if f.resume ~= nil and f.resume[1] ~= nil then
        st.resume = { tasks = f.resume, until_tick = tick + M.RESUME_WAIT }
      end
      return
    end
    if f.legs >= M.MAX_LEGS then
      return finish(id, entity, st, tick, "failed", { reason = "still_threatened", legs = f.legs })
    end
    local ok, reason = start_leg(id, entity, st, f.p, near, tick, f.legs + 1, nil, f.resume)
    if not ok then finish(id, entity, st, tick, "failed", { reason = reason, legs = f.legs }) end
    return
  end
  if code == "cancelled" then
    return finish(id, entity, st, tick, "failed", { reason = "cancelled", legs = f.legs })
  end
  -- путь не нашёлся / застрял: другая точка. Кандидаты пересчитываются: помощник мог уйти с
  -- места, где считался прежний список, а враг — подойти с другой стороны (номер в старом
  -- списке к новому не подходит). Точки, к которым уже не дошли, пропускаются.
  local tried = {}
  for _, t in ipairs(f.tried or {}) do tried[#tried + 1] = t end
  tried[#tried + 1] = { x = f.goal.x, y = f.goal.y }
  local ok = false
  if #tried < M.MAX_TRIES then
    local near = C.enemies(entity, f.p.radius)[1]
    local threat = near ~= nil and { name = near.name, pos = near.pos } or f.threat
    ok = start_leg(id, entity, st, f.p, threat, tick, f.legs, tried, f.resume)
  end
  if not ok then finish(id, entity, st, tick, "failed", { reason = code or "unknown", legs = f.legs }) end
end

-- ------------------------------------------------------------------ возврат к делу

local function resumed(id, made, reason)
  events.emit(id, "reflex_resumed", { type = "flee", jobs = made, reason = reason }, { loud = true })
end

--- После удачного отступления: здоровье и тишина — поставить снятые задачи снова.
local function resume_check(id, entity, st, tick)
  local r = st.resume
  if r == nil or st.flee ~= nil then return end
  if not job_idle(id) then st.resume = nil return end -- агент уже решил сам
  local p = flee_params(id)
  if p == nil or p.resume == false then st.resume = nil return end
  if tick > r.until_tick then
    st.resume = nil
    return resumed(id, {}, "timeout")
  end
  if C.health(entity) < (p.resume_health or 0.8) then return end
  if C.enemies(entity, p.radius)[1] ~= nil then return end
  local recent = {}
  for _, t in ipairs(st.resumes or {}) do
    if tick - t < M.RESUME_WINDOW then recent[#recent + 1] = t end
  end
  st.resumes = recent
  st.resume = nil
  if #recent >= M.RESUME_LIMIT then return resumed(id, {}, "too_often") end
  recent[#recent + 1] = tick
  local made = {}
  for _, t in ipairs(r.tasks) do
    local ok, res = pcall(jobs.op_act, { ["do"] = t["do"], args = t.args, replace = false },
      { helper_id = id, request_id = M.RESUME_REQ, entity = entity, tick = tick })
    if ok then made[#made + 1] = { job = res.job, ["do"] = t["do"] } end
  end
  resumed(id, made, made[1] == nil and "rejected" or nil)
end

-- ------------------------------------------------------------------ раз в 10 тиков

function M.sweep(tick)
  for id, st in pairs(C.all()) do
    local rec, entity = registry.alive(id)
    if rec ~= nil and st.unit == entity.unit_number then
      local a = st.attack
      if a ~= nil and tick - a.last_tick >= M.EPISODE then st.attack = nil end
      check_health(id, entity, st)
      progress(id, entity, st, tick)
      resume_check(id, entity, st, tick)
    elseif st.flee ~= nil then
      -- тело пропало посреди отступления: смерть — итог no_helper; удаление (решение агента) — молча
      local r = registry.get(id)
      if r ~= nil and r.state ~= "removed" then
        finish(id, nil, st, tick, "failed", { reason = "no_helper", legs = st.flee.legs })
      else
        st.flee = nil
      end
    end
  end
  C.gc()
end

-- ------------------------------------------------------------------ интерфейс модуля

M.reflexes = {
  flee = {
    schema = {
      radius = { type = "number", min = 4, max = C.EYES, default = 20 },
      distance = { type = "number", min = 8, max = 64, default = 30 },
      health = { type = "number", min = 0, max = 1, default = 1 },
      on_attack = { type = "bool", default = true },
      to = { type = "enum", values = { "away", "spawn", "player" }, default = "away" },
      resume = { type = "bool", default = true },
      resume_health = { type = "number", min = 0, max = 1, default = 0.8 },
    },
    check = function(id, entity, params, tick)
      M.consider(id, entity, params, tick)
    end,
  },
  watch = {
    schema = {
      radius = { type = "number", min = 4, max = C.EYES, default = C.EYES },
      every_s = { type = "int", min = 1, max = 600, default = 10 },
    },
    check = function(id, entity, params, tick)
      local st = C.body_state(id, entity)
      if st.watch_tick ~= nil and tick - st.watch_tick < params.every_s * 60 then return end
      local near = C.enemies(entity, params.radius, C.SEEN)[1]
      if near == nil then return end
      st.watch_tick = tick
      events.emit(id, "saw_enemy", { name = near.name, pos = util.pos(near.pos), dist = util.round1(near.dist) })
    end,
  },
}

M.events = {
  [defines.events.on_entity_damaged] = {
    handler = M.on_damaged,
    filter = { { filter = "type", type = "character" } },
  },
}

M.on_nth = {
  [10] = function(e) M.sweep(e.tick) end,
}

return M
