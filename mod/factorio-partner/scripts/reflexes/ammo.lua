-- Рефлекс `ammo` — заправщик турелей (хозяин ставит турели, помощник сразу кладёт в них патроны). Без раздумий агента: раз в EVERY тиков смотрит
-- свои турели с патронами (`ammo-turret`) в radius клеток от тела, где патронов меньше min, и
-- доводит их до fill патронами из своего инвентаря.
--   ammo { radius?=20 (4..32), min?=10 (1..200), fill?=50 (1..400, не меньше min), item?:string,
--          chests?=true, turret_gap?=3 (0..16), behind? (0..12), keep_away? (0..96) }
-- * Все такие турели в досягаемости (reach_distance) — за один проход, как игрок рукой (inv.move —
--   тот же перенос, что у `insert`), самые пустые первыми; патронов мало — поровну. Одно шумное
--   reflex_fired{type:"ammo", detail:{turrets:[{pos, item, count}], count}}.
-- * Дальние — если у помощника нет задач: одна задача `walk` (req "reflex:ammo") в точку, из
--   которой в досягаемости (reach_distance тела − REACH_SPARE) больше всего недозаправленных
--   турелей; там следующий проход заправит их все. Точка — за линией турелей (reflexes.standoff:
--   враг бьёт по турелям первыми, к нему не ближе, чем турели), не ближе turret_gap к любой турели,
--   при равном охвате — как можно дальше от врага, затем ближе к телу. Турель, ради которой
--   пришлось бы выйти перед линией, ждёт следующего прохода. Жёсткие пределы, если заданы: behind —
--   ещё на столько клеток за линией, keep_away — не ближе к любому врагу. Точки нет или тело уже
--   бьют — не идёт: громкое ammo_unsafe{turret, enemy, name, reason} не чаще раза в UNSAFE_REPEAT.
--   Врагов нет, а точку не дали турели вплотную — задача `insert` к ближней турели.
-- * Между заправками: тело перед линией турелей в дальности врага и задач нет — задача `walk`
--   (req "reflex:ammo") за линию (не чаще раза в RETREAT_EVERY), шумное reflex_fired{detail:{retreat}}.
-- * Задачи агента важнее: есть задачи — дальние ждут (кладёт только в досягаемости).
-- * Какие патроны: item, если задан, иначе любые предметы типа ammo из инвентаря, которые турель
--   принимает (`can_insert` движка — категория патронов из игры, без имён в коде).
-- * Патронов нет: громкое ammo_low{item?, turret} не чаще раза в LOW_REPEAT; задан item и chests —
--   при свободной очереди задача `collect{items:{item: fill × 2}}` со складов в 64 клетках (не чаще
--   раза в COLLECT_BACKOFF).
-- * Пока хозяин держит помощника словом «стоп» (owner_hold) — не делает ничего.
-- * Пока идёт отступление (flee) — молчит: жизнь важнее.
-- Состояние — в reflexes.common body_state: ammo_tick, ammo_low_tick, ammo_collect_until,
-- ammo_unsafe_tick, ammo_retreat_tick, ammo_nospot_until, ammo_spot = {x, y}, ammo_bad = { {x, y, till}, ... }.
local util = require("scripts.core.util")
local events = require("scripts.core.events")
local jobs = require("scripts.core.jobs")
local inv = require("scripts.lib.inventory")
local C = require("scripts.reflexes.common")
local SO = require("scripts.reflexes.standoff")

local M = {}
M.name = "reflexes.ammo"

M.EVERY = 30
M.REQ = "reflex:ammo"
M.LOW_REPEAT = 60 * 60
M.UNSAFE_REPEAT = 60 * 60
M.RETREAT_EVERY = 2 * 60
M.COLLECT_BACKOFF = 30 * 60
M.COLLECT_RADIUS = 64
M.MAX_PER_PASS = 32     -- турелей за проход (в досягаемости)
M.MAX_SEEDS = 8         -- дальних турелей, вокруг которых ищется точка
M.DIRS = 12
M.ENEMY_SCAN = 40       -- клеток сверх radius + reach: где искать врагов
M.BAD_SPOT = 60 * 60    -- точка, из которой не достали, не выбирается столько тиков
M.BAD_MAX = 4
M.NOSPOT_BACKOFF = 5 * 60 -- точки нет — следующий поиск не раньше (новые турели — тогда же)
M.BUCKET = 1            -- клеток: равное удаление от врага при сравнении точек
M.REACH_SPARE = 1.5     -- запас к reach_distance тела: турели в досягаемости точки с этим запасом
M.HIT_RECENT = 2 * 60   -- тело били не дальше этого — к дальним турелям не идём

local function idle(id)
  if jobs.active(id) ~= nil then return false end
  local q = jobs.queue_of(id, false)
  return q == nil or q.queue == nil or q.queue[1] == nil
end

local function turret_count(t)
  local ok, ti = pcall(function() return t.get_inventory(defines.inventory.turret_ammo) end)
  if not ok or ti == nil then return 0 end
  return ti.get_item_count()
end

--- Имена патронов в инвентаре (по алфавиту): item или все предметы типа ammo.
local function ammo_names(main, item)
  local out = {}
  if main == nil then return out end
  if item ~= nil then
    if inv.count(main, item) > 0 then out[1] = item end
    return out
  end
  for name, n in pairs(inv.counts(main)) do
    local p = prototypes.item[name]
    if n > 0 and p ~= nil and p.type == "ammo" then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

--- Первые патроны из names, которые турель примет и которые ещё есть в инвентаре, или nil.
local function pick_ammo(t, names, main)
  for _, a in ipairs(names) do
    if inv.count(main, a) > 0 then
      local ok, can = pcall(function() return t.can_insert{ name = a, count = 1 } end)
      if ok and can then return a end
    end
  end
  return nil
end

local function act(id, entity, tick, a)
  local ok, r = pcall(jobs.op_act, a, { helper_id = id, request_id = M.REQ, entity = entity, tick = tick })
  return ok and r ~= nil
end

local function walk_to(id, entity, tick, p)
  return act(id, entity, tick, { ["do"] = "walk", args = { to = { x = p.x, y = p.y }, radius = 0.5 } })
end

local function out_of_ammo(id, entity, params, st, tick, turret)
  local pos = util.xy(entity.position)
  if params.item ~= nil and params.chests and idle(id) and (st.ammo_collect_until or 0) <= tick then
    st.ammo_collect_until = tick + M.COLLECT_BACKOFF
    act(id, entity, tick, { ["do"] = "collect", args = {
      items = { [params.item] = params.fill * 2 }, center = { x = pos.x, y = pos.y }, radius = M.COLLECT_RADIUS,
    } })
  end
  if st.ammo_low_tick == nil or tick - st.ammo_low_tick >= M.LOW_REPEAT then
    st.ammo_low_tick = tick
    events.emit(id, "ammo_low", { item = params.item, turret = util.pos(turret.position) }, { loud = true })
  end
end

--- Положить патроны во все турели списка, до которых тело достаёт. → список заправленных.
local function fill_in_reach(entity, main, names, list, fill)
  local reach_list = {}
  for _, it in ipairs(list) do
    if #reach_list >= M.MAX_PER_PASS then break end
    if inv.in_reach(entity, it.t, "reach") then reach_list[#reach_list + 1] = it end
  end
  local done = {}
  for i, it in ipairs(reach_list) do
    local name = pick_ammo(it.t, names, main)
    if name ~= nil then
      local have = inv.count(main, name)
      local need = fill - it.n
      -- патронов на всех не хватит — поровну оставшимся (самые пустые первыми)
      local share = math.max(1, math.floor(have / (#reach_list - i + 1)))
      local n = math.min(need, have, share)
      if n > 0 then
        local moved = inv.move(main, { entity = it.t }, name, n, entity)
        if moved > 0 then
          it.n = it.n + moved
          it.filled = true
          done[#done + 1] = { pos = util.pos(it.t.position), item = name, count = moved }
        end
      end
    end
  end
  return done
end

local function near_bad(st, p, tick)
  for _, b in ipairs(st.ammo_bad or {}) do
    if b.till > tick and util.dist(b, p) <= 1.5 then return true end
  end
  return false
end

local function mark_bad(st, p, tick)
  local out = {}
  for _, b in ipairs(st.ammo_bad or {}) do
    if b.till > tick then out[#out + 1] = b end
  end
  table.insert(out, 1, { x = p.x, y = p.y, till = tick + M.BAD_SPOT })
  for i = #out, M.BAD_MAX + 1, -1 do out[i] = nil end
  st.ammo_bad = out
end

--- Сколько турелей из far в досягаемости точки p (по центру, с запасом).
local function coverage(p, far, cover)
  local n = 0
  for _, it in ipairs(far) do
    if util.dist(p, it.pos) <= cover then n = n + 1 end
  end
  return n
end

--- Лучше ли a, чем b: охват, затем дальше от врага (ведрами BUCKET), затем короче путь от тела.
local function better(a, b)
  if b == nil then return true end
  if a.cov ~= b.cov then return a.cov > b.cov end
  local ea, eb = math.floor(a.enemy / M.BUCKET), math.floor(b.enemy / M.BUCKET)
  if ea ~= eb then return ea > eb end
  return a.walk < b.walk - 1e-6
end

--- Точка, из которой в досягаемости больше всего турелей из far (с запасом REACH_SPARE), не ближе
--- к врагу, чем линия турелей (SO.judge), не ближе gap к турелям; при равном охвате — как можно
--- дальше от врага. → pos │ nil, отказ {foe, reason} (почему не годилась лучшая по охвату).
local function pick_spot(entity, st, tick, far, foes, o)
  local body = util.xy(entity.position)
  local cover = o.reach - M.REACH_SPARE
  local radii = { cover - 0.05, cover * 0.55 }
  local cands, refusal = {}, nil
  for i = 1, math.min(#far, M.MAX_SEEDS) do
    local seed = far[i]
    local sx, sy, k = 0, 0, 0
    for _, it in ipairs(far) do
      if util.dist(it.pos, seed.pos) <= 2 * o.reach then sx, sy, k = sx + it.pos.x, sy + it.pos.y, k + 1 end
    end
    local centers = { seed.pos }
    if k > 1 then centers[2] = { x = sx / k, y = sy / k } end
    for _, c in ipairs(centers) do
      for _, r in ipairs(radii) do
        for d = 0, M.DIRS - 1 do
          local a = 2 * math.pi * d / M.DIRS
          local p = { x = c.x + math.cos(a) * r, y = c.y + math.sin(a) * r }
          local cov = coverage(p, far, cover)
          if cov > 0 and SO.clear_of(p, o.boxes, o.gap) and not near_bad(st, p, tick) then
            local ok, foe, why = SO.judge_here(p, foes, o.keep_away, o.behind, o.boxes, o.near)
            if ok then
              cands[#cands + 1] = { p = p, cov = cov, enemy = SO.nearest(p, foes), walk = util.dist(p, body) }
            elseif refusal == nil or cov > refusal.cov then
              refusal = { foe = foe, reason = why, cov = cov }
            end
          end
        end
      end
    end
  end
  for _ = 1, 3 do
    local best, bi
    for i, c in ipairs(cands) do
      if c ~= false and better(c, best) then best, bi = c, i end
    end
    if best == nil then break end
    cands[bi] = false
    local spot = SO.free_spot(entity.surface, best.p)
    if spot ~= nil and coverage(spot, far, cover) > 0
      and SO.judge_here(spot, foes, o.keep_away, o.behind, o.boxes, o.near) then
      local last = st.ammo_spot
      if last ~= nil and util.dist(last, spot) <= 1.5 and util.dist(body, spot) <= 1.5 then
        -- уже стоим здесь, а достать не вышло — эта точка не годится
        mark_bad(st, spot, tick)
      else
        return spot
      end
    end
  end
  return nil, refusal
end

local function nearest_foe(foes, pos)
  local foe, fd
  for _, f in ipairs(foes) do
    local d = util.dist(f.pos, pos)
    if fd == nil or d < fd then foe, fd = f, d end
  end
  return foe
end

local function unsafe(id, st, tick, turret_pos, foe, reason)
  if foe == nil then return end
  if st.ammo_unsafe_tick ~= nil and tick - st.ammo_unsafe_tick < M.UNSAFE_REPEAT then return end
  st.ammo_unsafe_tick = tick
  events.emit(id, "ammo_unsafe", {
    turret = util.pos(turret_pos), enemy = util.pos(foe.pos), name = foe.name, reason = reason,
  }, { loud = true })
end

local function boxes_around(entity, body, radius)
  return SO.boxes(entity.surface.find_entities_filtered{
    type = SO.TURRET_TYPES, force = entity.force, position = body, radius = radius,
  }, body)
end

function M.check(id, entity, params, tick)
  local st = C.body_state(id, entity)
  if st.ammo_tick ~= nil and tick - st.ammo_tick < M.EVERY then return end
  st.ammo_tick = tick
  if st.flee ~= nil or jobs.held(id) ~= nil then return end
  local fill = math.max(params.fill, params.min)
  local body = util.xy(entity.position)
  local reach = inv.reach(entity, "reach") or 10
  local o = {
    reach = reach, gap = params.turret_gap or 3, keep_away = params.keep_away, behind = params.behind,
  }
  o.near = reach + o.gap
  local scan = params.radius + reach + math.max(M.ENEMY_SCAN, o.keep_away or 0)
  local turrets = entity.surface.find_entities_filtered{
    type = "ammo-turret", force = entity.force, position = body, radius = params.radius,
  }
  local list = {}
  for _, t in ipairs(turrets) do
    if t.valid then
      local n = turret_count(t)
      if n < params.min then
        local p = util.xy(t.position)
        list[#list + 1] = { t = t, n = n, pos = p, dist = util.dist(p, body) }
      end
    end
  end
  table.sort(list, function(a, b)
    if a.n ~= b.n then return a.n < b.n end
    if a.dist ~= b.dist then return a.dist < b.dist end
    if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
    return a.pos.y < b.pos.y
  end)
  local main = entity.get_main_inventory()
  local names = ammo_names(main, params.item)

  if list[1] ~= nil then
    local done = fill_in_reach(entity, main, names, list, fill)
    if done[1] ~= nil then
      local total = 0
      for _, d in ipairs(done) do total = total + d.count end
      events.emit(id, "reflex_fired", { type = "ammo", detail = { turrets = done, count = total } })
    end
    -- дальние: не заправленные в этот проход и с подходящими патронами
    local far, starved = {}, nil
    for _, it in ipairs(list) do
      if not it.filled and it.n < params.min then
        if pick_ammo(it.t, names, main) ~= nil then
          if not inv.in_reach(entity, it.t, "reach") then far[#far + 1] = it end
        elseif starved == nil then
          starved = it
        end
      end
    end
    if starved ~= nil then out_of_ammo(id, entity, params, st, tick, starved.t) end
    if far[1] ~= nil and idle(id) and (st.ammo_nospot_until or 0) <= tick then
      table.sort(far, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
        return a.pos.y < b.pos.y
      end)
      local foes = SO.enemies(id, entity, body, scan)
      local hit = st.attack
      if hit ~= nil and tick - hit.last_tick <= M.HIT_RECENT and foes[1] ~= nil then
        -- тело уже бьют: к турелям не идём (решают агент и flee)
        unsafe(id, st, tick, far[1].pos, nearest_foe(foes, body), "attacked")
      else
        o.boxes = boxes_around(entity, body, params.radius + reach + o.gap)
        local spot, refusal = pick_spot(entity, st, tick, far, foes, o)
        if spot ~= nil then
          if walk_to(id, entity, tick, spot) then st.ammo_spot = { x = spot.x, y = spot.y } end
          return
        end
        st.ammo_nospot_until = tick + M.NOSPOT_BACKOFF
        if foes[1] ~= nil then
          local foe = refusal and refusal.foe or nearest_foe(foes, far[1].pos)
          unsafe(id, st, tick, far[1].pos, foe, refusal and refusal.reason or "enemy_closer")
        else
          -- врагов нет, а точку не дали турели вплотную: подойти к ближней турели
          local t = far[1]
          local name = pick_ammo(t.t, names, main)
          act(id, entity, tick, { ["do"] = "insert", args = {
            target = { name = t.t.name, pos = util.pos(t.t.position) },
            items = { [name] = math.min(fill - t.n, inv.count(main, name)) },
          } })
          return
        end
      end
    end
  end

  -- между заправками: не стоять перед линией турелей под ударом
  if idle(id) and (st.ammo_retreat_tick == nil or tick - st.ammo_retreat_tick >= M.RETREAT_EVERY) then
    local foes = SO.enemies(id, entity, body, scan)
    if foes[1] ~= nil then
      o.boxes = o.boxes or boxes_around(entity, body, params.radius + reach + o.gap)
      if not SO.judge_here(body, foes, o.keep_away, o.behind, o.boxes, o.near) then
        st.ammo_retreat_tick = tick
        local p = SO.retreat_point(entity, foes, o.keep_away, o.behind, o.boxes, o.gap, o.near)
        if p ~= nil and walk_to(id, entity, tick, p) then
          events.emit(id, "reflex_fired", { type = "ammo", detail = {
            retreat = util.pos(p), from = util.pos(nearest_foe(foes, body).pos),
          } })
        end
      end
    end
  end
end

M.reflexes = {
  ammo = {
    schema = {
      radius = { type = "number", min = 4, max = C.EYES, default = 20 },
      min = { type = "int", min = 1, max = 200, default = 10 },
      fill = { type = "int", min = 1, max = 400, default = 50 },
      item = { type = "string", max = 100 },
      chests = { type = "bool", default = true },
      turret_gap = { type = "number", min = 0, max = 16, default = 3 },
      behind = { type = "number", min = 0, max = 12 },
      keep_away = { type = "number", min = 0, max = 96 },
    },
    check = function(id, entity, params, tick) M.check(id, entity, params, tick) end,
  },
}

return M
