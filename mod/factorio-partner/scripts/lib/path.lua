-- Путь и подход к цели (поток B). Контракт: docs/ACTIONS.md «Подход», «Модуль пути»,
-- PROTOCOL.md §6.1 (без телепорта), §6.7 (путь и цели — только в открытых чанках).
--
-- Ядро подставляет ctx.approach = path.step, ctx.cancel_approach = path.cancel.
--
--   path.step(task, ctx, goal_pos, distance) -> nil (иду/планирую) | true (на месте) | result (ошибка)
--     goal_pos = {x, y[, surface = имя│индекс]} — surface необязателен; другая поверхность → not_reachable.
--     distance — до какой дистанции подойти (≥ 0; меньше ARRIVE не бывает: 8 направлений
--     ходьбы не позволяют встать точно в точку).
--   path.cancel(task, ctx) — walking_state={walking=false}, забыть запросы пути задачи,
--     task.approach = nil. Зовут stop() всех действий, которые ходили.
--
-- Состояние — в task.approach (переживает сохранение, только простые таблицы):
--   { state = "planning"│"retry_wait"│"walking"│"final",
--     path_id,            -- ждущий запрос пути (или nil)
--     waypoints, i,       -- маршрут {x,y}[] и номер текущей точки
--     retries,            -- повторы после try_again_later / потерянного запроса (≤ MAX_RETRIES)
--     replans,            -- перепланирования из-за застревания (≤ MAX_REPLANS)
--     detours,            -- обходы игрока (≤ MAX_DETOURS)
--     extends,            -- маршрут кончился далеко от цели → новый запрос (≤ MAX_EXTENDS)
--     best_dist, last_move_tick, last_pos,
--     noted,              -- шумное stuck об этом перепланировании уже отправлено (сброс — когда пришёл маршрут)
--     goal,               -- цель, под которую строился маршрут (настоящая, без смещения обхода)
--     distance, plan_tick, retry_tick, goal_moved }
--
-- Запросы: storage.path_requests[id] = {helper, job, tick, finished?, try_again?, failed?, waypoints?}.
-- Ответ движка ловит M.events[on_script_path_request_finished] и только записывает итог в
-- запись запроса; забирает его path.step на следующем тике (так модуль не зависит от очереди
-- задач ядра). Потерянные записи чистит on_nth.
local util = require("scripts.core.util")

local M = {}

M.RETRY_TICKS = 60          -- try_again_later → повтор через 60 тиков
M.MAX_RETRIES = 10          -- … до 10 раз, потом path_failed
M.STUCK_TICKS = 60          -- не сдвинулся на STUCK_MOVE за 60 тиков → застрял
M.STUCK_MOVE = 0.1
M.MAX_REPLANS = 1           -- перепланирование при застревании — 1 раз, потом stuck
M.MAX_DETOURS = 3           -- обход игрока на пути (смещение цели)
M.DETOUR_OFFSET = 2         -- на сколько клеток смещать цель вбок при обходе
M.DETOUR_RADIUS = 1.5       -- «игрок на пути» — другой персонаж ближе этого
M.MAX_EXTENDS = 3           -- маршрут кончился далеко от цели → новый запрос
M.FINAL_SLACK = 3           -- конец маршрута ближе distance+3 — доходим по прямой
M.GOAL_TOL = 1.0            -- цель сдвинулась больше → перестроить маршрут (follow)
M.REPLAN_MIN_TICKS = 30     -- не чаще раза в 30 тиков из-за сдвига цели
M.PLAN_TIMEOUT = 1800       -- ответ на запрос не пришёл за 30 с → запрос считается потерянным
M.REQUEST_TTL = 36000       -- записи запросов старше 10 мин удаляются (on_nth)
M.ARRIVE = 0.3              -- минимальная дистанция «на месте» и порог точки маршрута
-- Коробка для поиска пути чуть шире тела (±0.2): ходьба по 8 направлениям срезает углы.
M.BOX = { left_top = { x = -0.35, y = -0.35 }, right_bottom = { x = 0.35, y = 0.35 } }
-- Тело стоит вплотную к постройке (так бывает у тела-игрока, которого подвёл человек): широкая
-- коробка в точке старта уже «в стене», и движок не находит пути никуда. Тогда один повтор с
-- настоящей коробкой тела (collision_box прототипа).

local floor, abs, max, sqrt = math.floor, math.abs, math.max, math.sqrt
local TAN_22_5 = 0.41421356237

--- Вектор (dx, dy) → defines.direction из 8 направлений ходьбы (север 0, восток 4, юг 8,
--- запад 12; y растёт на юг). Нулевой вектор → nil.
function M.direction(dx, dy)
  local d = defines.direction
  local ax, ay = abs(dx), abs(dy)
  if ax < 1e-9 and ay < 1e-9 then return nil end
  if ax <= ay * TAN_22_5 then return dy < 0 and d.north or d.south end
  if ay <= ax * TAN_22_5 then return dx > 0 and d.east or d.west end
  if dx > 0 then return dy < 0 and d.northeast or d.southeast end
  return dy < 0 and d.northwest or d.southwest
end

local function reqs()
  local r = storage.path_requests
  if r == nil then
    r = {}
    storage.path_requests = r
  end
  return r
end

local function chunk_of(p)
  return { x = floor(p.x / 32), y = floor(p.y / 32) }
end

local function charted(entity, p)
  return entity.force.is_chunk_charted(entity.surface, chunk_of(p)) and true or false
end

local function same_surface(surface, want)
  if type(want) == "number" then return surface.index == want end
  if type(want) == "string" then return surface.name == want end
  if type(want) == "table" then return want.index == surface.index end
  return false
end

local function stop_walking(entity)
  if entity == nil or not entity.valid then return end
  local ws = entity.walking_state
  local dir = ws and ws.direction or defines.direction.north
  if ws and ws.walking == false then return end
  entity.walking_state = { walking = false, direction = dir }
end

local function walk_towards(entity, from, to)
  local dir = M.direction(to.x - from.x, to.y - from.y)
  if dir == nil then
    stop_walking(entity)
  else
    entity.walking_state = { walking = true, direction = dir }
  end
end

local function arrive_threshold(entity)
  local speed = entity.character_running_speed or 0.15
  return max(M.ARRIVE, speed * 1.5)
end

local function forget_request(st)
  if st and st.path_id ~= nil then
    reqs()[st.path_id] = nil
    st.path_id = nil
  end
end

--- Запросить путь. req_goal — куда строить (с обходным смещением), goal — настоящая цель.
--- keep_walking=true — идти по старому маршруту, пока считается новый (сдвиг цели).
local function request(task, ctx, st, goal, req_goal, keep_walking)
  local e = ctx.entity
  forget_request(st)
  local proto = e.prototype
  local id = e.surface.request_path{
    bounding_box = st.tight and proto.collision_box or M.BOX,
    collision_mask = proto.collision_mask,
    start = util.xy(e.position),
    goal = { x = req_goal.x, y = req_goal.y },
    force = e.force,
    radius = max(1, st.distance - 0.3),
    entity_to_ignore = e,
    can_open_gates = false,
    pathfind_flags = { cache = false, prefer_straight_paths = true, low_priority = false },
  }
  reqs()[id] = { helper = task.helper, job = task.job, tick = ctx.tick }
  st.path_id = id
  st.plan_tick = ctx.tick
  st.goal = { x = goal.x, y = goal.y }
  st.goal_moved = false
  if not keep_walking or st.waypoints == nil then
    st.state = "planning"
    st.waypoints = nil
    st.i = nil
    stop_walking(e)
  end
end

local function fail(code, text, pos)
  return { status = "failed", code = code, text = text, detail = { pos = pos and util.pos(pos) or nil } }
end

--- Снять ходьбу и забыть запросы задачи (ACTIONS.md: stop() обязан это вызвать).
function M.cancel(task, ctx)
  local e = ctx and ctx.entity
  stop_walking(e)
  if task == nil then return end
  local r = storage.path_requests
  if r ~= nil then
    for id, rec in pairs(r) do
      if rec.helper == task.helper and rec.job == task.job then r[id] = nil end
    end
  end
  task.approach = nil
end

-- Шумное событие `stuck` (EVENTS.md): перепланирование/обход/потеря запроса. Не последнее слово:
-- если не помогло, задача кончится громким job_failed{code:"stuck"}.
-- Одно событие на одно перепланирование: пока новый маршрут не пришёл (st.noted), повторные
-- причины (запрос потерялся, а тело при этом ещё и стоит) молчат — иначе на одно и то же
-- перепланирование агент видел два stuck подряд.
local function noisy_stuck(task, ctx, st, pos, reason)
  if st.noted then return end
  st.noted = true
  ctx.emit("stuck", { job = task.job, pos = util.pos(pos), reason = reason })
end

-- Неудача шага: остановиться, забыть запросы, вернуть result.
local function give_up(task, ctx, code, text, pos)
  M.cancel(task, ctx)
  return fail(code, text, pos)
end

-- Другой персонаж (игрок, помощник) вплотную — «шагаю на месте» из-за него.
local function blocker_near(e, pos)
  local list = e.surface.find_entities_filtered{ type = "character", position = pos, radius = M.DETOUR_RADIUS }
  for _, c in ipairs(list) do
    if c.valid and c ~= e and c.unit_number ~= e.unit_number then return c end
  end
  return nil
end

local function detour_goal(goal, pos, n)
  local dx, dy = goal.x - pos.x, goal.y - pos.y
  local len = sqrt(dx * dx + dy * dy)
  if len < 1e-6 then dx, dy, len = 1, 0, 1 end
  local side = (n % 2 == 1) and 1 or -1
  return { x = goal.x - dy / len * M.DETOUR_OFFSET * side, y = goal.y + dx / len * M.DETOUR_OFFSET * side }
end

-- Забрать итог запроса, если он пришёл. Возвращает result при провале, иначе nil.
local function poll_request(task, ctx, st, pos)
  local r = reqs()[st.path_id]
  local tick = ctx.tick
  if r == nil or (not r.finished and tick - st.plan_tick >= M.PLAN_TIMEOUT) then
    -- запрос потерян (сохранение/загрузка) или завис — повторить
    st.retries = st.retries + 1
    if st.retries > M.MAX_RETRIES then
      return give_up(task, ctx, "path_failed", "pathfinder did not answer", pos)
    end
    noisy_stuck(task, ctx, st, pos, "path_lost")
    request(task, ctx, st, st.goal, st.req_goal or st.goal, true)
    -- новый запрос — новое окно «не двигаюсь»: иначе в этом же тике сработало бы ещё и
    -- перепланирование no_progress, которое выбросило бы только что отправленный запрос
    st.last_move_tick = tick
    return nil
  end
  if not r.finished then return nil end
  forget_request(st)
  if r.try_again then
    st.retries = st.retries + 1
    if st.retries > M.MAX_RETRIES then
      return give_up(task, ctx, "path_failed", "pathfinder is busy (try_again_later " .. M.MAX_RETRIES .. " times)", pos)
    end
    if st.state == "planning" then
      st.state = "retry_wait"
      st.retry_tick = tick + M.RETRY_TICKS
    else
      st.goal_moved = true -- идём по старому маршруту, повторим позже
    end
    return nil
  end
  if r.failed or type(r.waypoints) ~= "table" or r.waypoints[1] == nil then
    if not st.tight then
      st.tight = true
      request(task, ctx, st, st.goal, st.req_goal or st.goal, false)
      st.last_move_tick = tick
      return nil
    end
    return give_up(task, ctx, "path_failed", "no path to the goal", pos)
  end
  st.tight = nil -- следующий запрос этой задачи снова с широкой коробкой
  -- путь — только по открытым чанкам (PROTOCOL §6.7)
  local seen = {}
  for _, wp in ipairs(r.waypoints) do
    local c = chunk_of(wp)
    local key = c.x .. ":" .. c.y
    if not seen[key] then
      seen[key] = true
      if not ctx.entity.force.is_chunk_charted(ctx.entity.surface, c) then
        return give_up(task, ctx, "not_charted", "path crosses uncharted chunks", pos)
      end
    end
  end
  st.waypoints = r.waypoints
  st.i = 1
  st.state = "walking"
  st.retries = 0
  st.noted = nil -- маршрут пришёл: перепланирование закончено
  st.last_move_tick = tick
  st.last_pos = pos
  return nil
end

--- Один тик подхода. См. шапку файла.
function M.step(task, ctx, goal_pos, distance)
  local e = ctx.entity
  local tick = ctx.tick
  if type(goal_pos) ~= "table" then return give_up(task, ctx, "internal", "approach: goal is not a position") end
  local goal = util.xy(goal_pos)
  if type(goal.x) ~= "number" or type(goal.y) ~= "number" then
    return give_up(task, ctx, "internal", "approach: goal is not a position")
  end
  local pos = util.xy(e.position)
  if goal_pos.surface ~= nil and not same_surface(e.surface, goal_pos.surface) then
    return give_up(task, ctx, "not_reachable", "goal is on another surface", pos)
  end
  distance = tonumber(distance) or 1
  if distance < 0 then distance = 0 end
  local eff = max(distance, M.ARRIVE)
  local d = util.dist(pos, goal)
  local st = task.approach

  if d <= eff then
    if st ~= nil then M.cancel(task, ctx) end
    return true
  end

  if st ~= nil and st.distance ~= distance then
    M.cancel(task, ctx)
    st = nil
  end

  if st == nil then
    if not charted(e, goal) then return give_up(task, ctx, "not_charted", "goal is in uncharted chunks", pos) end
    st = {
      state = "planning", retries = 0, replans = 0, detours = 0, extends = 0,
      best_dist = d, last_move_tick = tick, last_pos = pos, distance = distance,
    }
    task.approach = st
    request(task, ctx, st, goal, goal, false)
    return nil
  end

  -- цель сдвинулась (follow, approach к игроку)
  if util.dist(goal, st.goal) > 1e-6 then
    if not charted(e, goal) then return give_up(task, ctx, "not_charted", "goal is in uncharted chunks", pos) end
    if util.dist(goal, st.goal) > M.GOAL_TOL then st.goal_moved = true end
  end

  if util.dist(pos, st.last_pos) >= M.STUCK_MOVE then
    st.last_pos = pos
    st.last_move_tick = tick
  end
  if d < st.best_dist then st.best_dist = d end

  if st.path_id ~= nil then
    local res = poll_request(task, ctx, st, pos)
    if res ~= nil then return res end
  end

  if st.state == "planning" then
    st.last_move_tick = tick -- стоим, пока считается путь: это не застревание
    return nil
  end
  if st.state == "retry_wait" then
    st.last_move_tick = tick
    if tick >= st.retry_tick then
      st.req_goal = nil
      request(task, ctx, st, goal, goal, false)
    end
    return nil
  end

  -- walking / final
  if st.goal_moved and st.path_id == nil and tick - (st.plan_tick or 0) >= M.REPLAN_MIN_TICKS then
    st.req_goal = nil
    request(task, ctx, st, goal, goal, true)
  end

  if tick - st.last_move_tick >= M.STUCK_TICKS then
    if blocker_near(e, pos) and st.detours < M.MAX_DETOURS then
      st.detours = st.detours + 1
      noisy_stuck(task, ctx, st, pos, "blocked")
      st.req_goal = detour_goal(goal, pos, st.detours)
      request(task, ctx, st, goal, st.req_goal, false)
      st.last_move_tick = tick
      return nil
    end
    if st.replans < M.MAX_REPLANS then
      st.replans = st.replans + 1
      noisy_stuck(task, ctx, st, pos, "no_progress")
      st.req_goal = nil
      request(task, ctx, st, goal, goal, false)
      st.last_move_tick = tick
      return nil
    end
    return give_up(task, ctx, "stuck", "cannot move towards the goal", pos)
  end

  local target
  if st.state == "walking" then
    local wps = st.waypoints
    local thr = arrive_threshold(e)
    local i = st.i
    while i <= #wps do
      local di = util.dist(pos, wps[i])
      if di < thr then
        i = i + 1
      elseif di < 1 and wps[i + 1] ~= nil
          and util.dist(pos, wps[i + 1]) + 0.05 < util.dist(wps[i], wps[i + 1]) then
        i = i + 1 -- точку проскочили (8 направлений не дают идти точно по линии) — не возвращаться
      else
        break
      end
    end
    st.i = i
    if i > #wps then
      if d <= eff + M.FINAL_SLACK then
        st.state = "final"
      elseif st.path_id == nil then
        st.extends = st.extends + 1
        if st.extends > M.MAX_EXTENDS then
          return give_up(task, ctx, "path_failed", "path ends too far from the goal", pos)
        end
        st.req_goal = nil
        request(task, ctx, st, goal, goal, false)
        return nil
      else
        stop_walking(e) -- новый маршрут уже считается
        st.last_move_tick = tick
        return nil
      end
    else
      target = wps[i]
    end
  end
  if st.state == "final" then target = goal end
  walk_towards(e, pos, target)
  return nil
end

--- Ответ движка на request_path: записать итог в запрос (забирает path.step).
function M.on_path_finished(e)
  local r = storage.path_requests and storage.path_requests[e.id]
  if r == nil then return end -- чужой или уже забытый запрос
  r.finished = true
  if e.try_again_later then
    r.try_again = true
  elseif e.path ~= nil then
    local wps = {}
    for i, w in ipairs(e.path) do
      local p = util.xy(w.position or w)
      wps[i] = { x = p.x, y = p.y }
    end
    r.waypoints = wps
  else
    r.failed = true
  end
end

--- Удалить записи запросов, которые никто не забрал.
function M.gc(tick)
  local r = storage.path_requests
  if r == nil then return end
  for id, rec in pairs(r) do
    if type(rec) ~= "table" or (rec.tick or 0) + M.REQUEST_TTL < tick then r[id] = nil end
  end
end

M.events = {
  [defines.events.on_script_path_request_finished] = { handler = M.on_path_finished },
}

M.on_nth = {
  [3600] = function(e) M.gc(e.tick) end,
}

return M
