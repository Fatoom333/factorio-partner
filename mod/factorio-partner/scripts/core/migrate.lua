-- Схема storage и миграции (поток A). PROTOCOL.md §7: ключи верхнего уровня
-- proto, helpers, jobs, events, recent, blobs, reservations, vision, reflexes, reflex_state,
-- path_requests.
-- Ядро создаёт все ключи (пустыми таблицами), чтобы модули могли на них рассчитывать;
-- содержимое `vision` (G), `reflex_state` (H) и `path_requests` (B) заполняют их владельцы.
--
-- storage.proto = { version = <номер схемы storage>, max_helpers = <1..16> } (ревизия 3.2:
-- раньше это было просто число версии). Новая версия схемы = новая функция в STEPS[n]
-- (переход n-1 -> n) + увеличить VERSION. Шаги должны быть идемпотентными.
local M = {}

M.VERSION = 2
M.DEFAULT_MAX_HELPERS = 1   -- PROTOCOL §4: сколько помощников разрешил игрок (helper_limit)
M.MAX_HELPERS_CAP = 16

local function ensure(t, k, default)
  if type(t[k]) ~= "table" then t[k] = default end
  return t[k]
end

local function valid_max(v)
  return type(v) == "number" and v == math.floor(v) and v >= 1 and v <= M.MAX_HELPERS_CAP
end

--- Версия схемы, записанная в сейве (0 — мода в сейве ещё не было).
local function stored_version()
  local p = storage.proto
  if type(p) == "number" then return p end -- схема 1: просто число
  if type(p) == "table" and type(p.version) == "number" then return p.version end
  return 0
end

--- Привести все ключи к ожидаемой форме (без потери данных).
function M.ensure_shape()
  local s = storage
  -- proto: таблица; число из схемы 1 становится её версией
  local version = stored_version()
  local proto = s.proto
  if type(proto) ~= "table" then
    proto = { version = version }
    s.proto = proto
  end
  if type(proto.version) ~= "number" then proto.version = version end
  if not valid_max(proto.max_helpers) then proto.max_helpers = M.DEFAULT_MAX_HELPERS end

  ensure(s, "helpers", {})
  local jobs = ensure(s, "jobs", {})
  if type(jobs.next_job) ~= "number" then jobs.next_job = 1 end
  ensure(jobs, "by_helper", {})
  local ev = ensure(s, "events", {})
  if type(ev.next_seq) ~= "number" then ev.next_seq = 1 end
  ensure(ev, "list", {})
  local rc = ensure(s, "recent", {})
  ensure(rc, "map", {})
  ensure(rc, "order", {})
  if type(rc.head) ~= "number" then rc.head = 0 end
  if type(rc.bytes) ~= "number" then rc.bytes = 0 end
  local bl = ensure(s, "blobs", {})
  ensure(bl, "items", {})
  if type(bl.bytes) ~= "number" then bl.bytes = 0 end
  local rs = ensure(s, "reservations", {})
  ensure(rs, "items", {})
  ensure(rs, "areas", {})
  ensure(s, "vision", {})
  ensure(s, "reflexes", {})
  ensure(s, "reflex_state", {})
  ensure(s, "path_requests", {})
end

-- Переходы между версиями схемы: STEPS[n] переводит версию n-1 в n.
local STEPS = {
  [1] = function() end, -- первая версия: только ensure_shape
  -- 2 (ревизия 3.2): proto — таблица с max_helpers. Сейв, где помощников уже больше одного
  -- (прежняя константа разрешала 4), после обновления не должен оказаться «сверх лимита».
  [2] = function()
    local occupied = 0
    for _, rec in pairs(storage.helpers) do
      if type(rec) == "table" and (rec.state == "alive" or rec.state == "dead") then occupied = occupied + 1 end
    end
    if occupied > M.MAX_HELPERS_CAP then occupied = M.MAX_HELPERS_CAP end
    if occupied > storage.proto.max_helpers then storage.proto.max_helpers = occupied end
  end,
}

--- Вызывается из on_init и on_configuration_changed.
function M.run()
  local from = stored_version()
  M.ensure_shape()
  for v = from + 1, M.VERSION do
    if STEPS[v] then STEPS[v]() end
  end
  storage.proto.version = M.VERSION
  M.ensure_shape()
end

return M
