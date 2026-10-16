-- Учёт занятости тела помощника. Раз в SAMPLE тиков смотрит, есть ли у живого помощника активная
-- задача (jobs.active; саму очередь не меняет), и копит:
--   idle_ticks  — сколько тиков подряд задачи нет (0, пока она есть);
--   busy_share  — доля времени с задачей за последние WINDOW_MIN минут (0..1).
-- Бюджет: один проход по помощникам раз в SAMPLE тиков; в storage.metrics[helper] — кольцо из
-- WINDOW_MIN минутных корзин, размер не растёт. Читает perception/state (поля `idle_ticks`, `busy`).
local jobs = require("scripts.core.jobs")

local M = {}

-- Активная задача; без данных ядра (storage.jobs ещё нет) — считаем, что задачи нет.
local function has_task(helper)
  if type(storage.jobs) ~= "table" or type(storage.jobs.by_helper) ~= "table" then return false end
  return jobs.active(helper) ~= nil
end
M.name = "metrics"
M.SAMPLE = 30          -- шаг учёта, тиков
M.BUCKET = 3600        -- корзина — минута игрового времени
M.WINDOW_MIN = 10      -- окно доли занятости, минут

local function store()
  if type(storage.metrics) ~= "table" then storage.metrics = {} end
  return storage.metrics
end

local function rec_of(helper, tick)
  local s = store()
  local r = s[helper]
  if r == nil then
    r = { idle_since = nil, last = tick, buckets = {} }
    s[helper] = r
  end
  return r
end

--- Учесть интервал [r.last, tick) с состоянием busy; отрезок через границу минуты делится между
--- соседними корзинами.
local function account(r, tick, busy)
  if tick - r.last <= 0 then return end
  local from = r.last
  r.last = tick
  while from < tick do
    local idx = math.floor(from / M.BUCKET)
    local upto = math.min(tick, (idx + 1) * M.BUCKET)
    local dt = upto - from
    local b = r.buckets[idx % M.WINDOW_MIN]
    if b == nil or b.idx ~= idx then
      b = { idx = idx, busy = 0, total = 0 }
      r.buckets[idx % M.WINDOW_MIN] = b
    end
    b.total = b.total + dt
    if busy then b.busy = b.busy + dt end
    from = upto
  end
end

--- Один проход учёта (вызывается раз в SAMPLE тиков). Смерть помощника учёт не сбрасывает: пока он
--- мёртв, время не считается, после возрождения (тот же id) учёт идёт дальше. Запись снимается,
--- когда записи помощника в storage.helpers больше нет (helper_remove).
function M.sample(tick)
  tick = tick or game.tick
  local s = store()
  local helpers = storage.helpers or {}
  for id in pairs(s) do
    if helpers[id] == nil then s[id] = nil end
  end
  for id, rec in pairs(helpers) do
    if rec.state == "alive" then
      local r = rec_of(id, tick)
      local busy = has_task(id)
      account(r, tick, busy)
      if busy then r.idle_since = nil
      elseif r.idle_since == nil then r.idle_since = tick end
    elseif s[id] ~= nil then
      s[id].last = tick     -- мёртвое время не считается ни занятым, ни простоем
      s[id].idle_since = nil
    end
  end
end

--- → idle_ticks (число), busy_share (0..1 или nil, пока нет данных), window (тиков в оценке).
function M.snapshot(helper, tick)
  tick = tick or game.tick
  if has_task(helper) then
    local r = storage.metrics and storage.metrics[helper]
    local share, win = M.share(r, tick)
    return 0, share, win
  end
  local r = storage.metrics and storage.metrics[helper]
  local idle = 0
  if r ~= nil and r.idle_since ~= nil then idle = math.max(0, tick - r.idle_since) end
  local share, win = M.share(r, tick)
  return idle, share, win
end

function M.share(r, tick)
  if r == nil then return nil, 0 end
  local cur = math.floor(tick / M.BUCKET)
  local busy, total = 0, 0
  for _, b in pairs(r.buckets) do
    if b.idx > cur - M.WINDOW_MIN then
      busy = busy + b.busy
      total = total + b.total
    end
  end
  if total <= 0 then return nil, 0 end
  return busy / total, total
end

M.on_nth = {
  [M.SAMPLE] = function() M.sample(game.tick) end,
}

return M
