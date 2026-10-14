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
-- Коробка для поиска пути — тело (collision_box прототипа персонажа, у ванильного ±0.2) плюс
-- BOX_MARGIN с каждой стороны: ходьба по 8 направлениям срезает углы. Размер тела — из игры: моды
-- меняют и персонажа, и постройки (Squeak Through 2 уменьшает рамки построек — щели находит сам
-- движок поиска пути, а узкие для широкой коробки проходы берёт «тонкий» маршрут ниже).
M.BOX_MARGIN = 0.15
M.BOX = { left_top = { x = -0.35, y = -0.35 }, right_bottom = { x = 0.35, y = 0.35 } } -- если тела нет
-- Тело стоит вплотную к постройке (так бывает у тела-игрока, которого подвёл человек): широкая
-- коробка в точке старта уже «в стене», и движок не находит пути никуда. Тогда один повтор с
-- настоящей коробкой тела (collision_box прототипа) — но только чтобы отойти: такой маршрут жмётся
-- к стенам и жидкости, поэтому через UNSTICK_DIST клеток от старта путь считается заново широкой
-- коробкой. Широкий не нашёлся и там — к цели ведёт только узкий проход (плотная база: щель между
-- углами машин): тогда идём «тонким» маршрутом до конца (st.thin), застряли на нём — обычное
-- перепланирование тем же тонким. Не нашёлся и тонкий — отказ.
M.UNSTICK_DIST = 1.5
-- Выбирание из застревания (решение автора 14.10). Тело не сдвинулось за STUCK_TICKS — маршрут не
-- пересчитывается сразу (он чаще всего снова ведёт в тот же угол): тело ищет выход из «зоны» —
-- круга ESCAPE_RADIUS вокруг места застревания. Идёт в одну сторону, пока не упрётся (не сдвинулось
-- за ESCAPE_STEP_TICKS) или не выйдет из круга; упёрлось — следующая сторона с того места, где стоит
-- (не возвращаясь к началу: так выходит и из П-образного тупика). Порядок сторон — от ближних к
-- нужному направлению: ±45°, ±90°, ±135°, назад, вперёд. Упёршиеся стороны помнятся, пока тело не
-- сдвинулось на ESCAPE_SPOT. Вышло из круга — путь считается заново от нового места. Не вышло за
-- ESCAPE_TICKS, или застряло в той же зоне ESCAPE_REPEATS раз — честный stuck. Только ходьба.
M.ESCAPE_RADIUS = 2.5
M.ESCAPE_STEP_TICKS = 15
M.ESCAPE_TICKS = 900
M.ESCAPE_SPOT = 0.5
M.ESCAPE_REPEATS = 3
M.ESCAPE_ORDER = { 2, -2, 4, -4, 6, -6, 8, 0 } -- сдвиг от нужного направления, в шагах defines.direction

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

--- Широкая коробка поиска пути: тело из прототипа плюс запас.
function M.wide_box(proto)
  local b = proto and proto.collision_box
  if b == nil then return M.BOX end
  local lt, rb = b.left_top or b[1], b.right_bottom or b[2]
  local x1, y1 = lt.x or lt[1], lt.y or lt[2]
  local x2, y2 = rb.x or rb[1], rb.y or rb[2]
  local m = M.BOX_MARGIN
  return { left_top = { x = x1 - m, y = y1 - m }, right_bottom = { x = x2 + m, y = y2 + m } }
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
    bounding_box = st.tight and proto.collision_box or M.wide_box(proto),
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

--- Начать выбирание: нужное направление — куда тело шло (или к цели).
local function escape_start(task, ctx, st, e, pos, goal, tick)
  forget_request(st)
  local ws = e.walking_state
  local want = (ws and ws.walking and ws.direction) or M.direction(goal.x - pos.x, goal.y - pos.y) or 0
  local order = {}
  for i, off in ipairs(M.ESCAPE_ORDER) do order[i] = (want + off) % 16 end
  st.escape = {
    center = { x = pos.x, y = pos.y }, start = tick, order = order, k = 1,
    spot = { x = pos.x, y = pos.y }, dead = {}, moved_pos = { x = pos.x, y = pos.y }, moved_tick = tick,
  }
  noisy_stuck(task, ctx, st, pos, "no_progress")
end

--- Ещё раз застрять в этой же зоне? Учёт зон — st.zones = {{x, y, n}}.
local function zone_hit(st, pos)
  st.zones = st.zones or {}
  for _, z in ipairs(st.zones) do
    if util.dist(z, pos) <= M.ESCAPE_RADIUS then
      z.n = z.n + 1
      return z.n
    end
  end
  st.zones[#st.zones + 1] = { x = pos.x, y = pos.y, n = 1 }
  return 1
end

--- Шаг выбирания. → nil (ещё выбирается), true (вышло из зоны), false (не вышло за отведённое время).
local function escape_step(st, e, pos, tick)
  local esc = st.escape
  if util.dist(pos, esc.center) >= M.ESCAPE_RADIUS then return true end
  if tick - esc.start >= M.ESCAPE_TICKS then return false end
  if util.dist(pos, esc.spot) >= M.ESCAPE_SPOT then
    esc.spot = { x = pos.x, y = pos.y } -- тело сдвинулось: с нового места все стороны снова пробуются
    esc.dead = {}
  end
  if util.dist(pos, esc.moved_pos) >= M.STUCK_MOVE then
    esc.moved_pos = { x = pos.x, y = pos.y }
    esc.moved_tick = tick
  elseif tick - esc.moved_tick >= M.ESCAPE_STEP_TICKS then
    -- эта сторона упёрлась: следующая, ещё не упёршаяся с этого места
    esc.dead[esc.order[esc.k]] = true
    local found = false
    for _ = 1, #esc.order do
      esc.k = esc.k % #esc.order + 1
      if not esc.dead[esc.order[esc.k]] then found = true break end
    end
    if not found then
      esc.dead = {} -- все стороны упёрлись с этого места: пробовать по кругу заново, пока есть время
      esc.k = 1
    end
    esc.moved_tick = tick
  end
  e.walking_state = { walking = true, direction = esc.order[esc.k] }
  return nil
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
    if not st.tight and st.unstick == nil and not st.thin then
      -- широкий не нашёлся: тонким — сначала только отойти от препятствия
      st.tight = true
      request(task, ctx, st, st.goal, st.req_goal or st.goal, false)
      st.last_move_tick = tick
      return nil
    end
    if st.unstick ~= nil and not st.tight then
      -- отошли, а широкий так и не нашёлся: к цели ведёт только узкий проход — тонким до конца
      st.unstick = nil
      st.thin = true
      st.tight = true
      request(task, ctx, st, st.goal, st.req_goal or st.goal, false)
      st.last_move_tick = tick
      return nil
    end
    return give_up(task, ctx, "path_failed", "no path to the goal", pos)
  end
  if st.thin then
    st.unstick = nil -- тонкий маршрут до конца: перепланирования этой задачи — тоже тонкие
  elseif st.tight then
    st.tight = nil
    st.unstick = { x = pos.x, y = pos.y } -- отойти от старта и пересчитать широкой коробкой
  else
    st.unstick = nil
  end
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

  -- выбирание из застревания
  if st.escape ~= nil then
    local r = escape_step(st, e, pos, tick)
    if r == nil then return nil end
    st.escape = nil
    if r == false then return give_up(task, ctx, "stuck", "cannot get out of a tight spot", pos) end
    -- вышло из зоны: путь заново от нового места
    stop_walking(e)
    st.req_goal = nil
    st.last_pos = pos
    st.last_move_tick = tick
    request(task, ctx, st, goal, goal, false)
    return nil
  end

  -- walking / final
  if st.unstick ~= nil and st.path_id == nil and util.dist(pos, st.unstick) >= M.UNSTICK_DIST then
    -- отошли от препятствия по «тонкому» маршруту — дальше только с запасом (стоим, пока считается)
    st.req_goal = nil
    request(task, ctx, st, goal, goal, false)
    return nil
  end
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
    if zone_hit(st, pos) >= M.ESCAPE_REPEATS then
      return give_up(task, ctx, "stuck", "stuck in the same place again and again", pos)
    end
    escape_start(task, ctx, st, e, pos, goal, tick)
    st.last_move_tick = tick
    return nil
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
