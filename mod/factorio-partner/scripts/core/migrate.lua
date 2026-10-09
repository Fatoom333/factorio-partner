-- Схема storage и миграции (поток A). PROTOCOL.md §7: ключи верхнего уровня
-- proto, helpers, jobs, events, recent, blobs, reservations, vision, reflexes, path_requests.
-- Ядро создаёт все ключи (пустыми таблицами), чтобы модули могли на них рассчитывать;
-- содержимое `vision` (G) и `path_requests` (B) заполняют их владельцы.
--
-- storage.proto — номер версии схемы storage (число). Новая версия схемы = новая функция
-- в STEPS[n] (переход n-1 -> n) + увеличить VERSION. Шаги должны быть идемпотентными.
local M = {}

M.VERSION = 1

local function ensure(t, k, default)
  if type(t[k]) ~= "table" then t[k] = default end
  return t[k]
end

--- Привести все ключи к ожидаемой форме (без потери данных).
function M.ensure_shape()
  local s = storage
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
  ensure(s, "path_requests", {})
end

-- Переходы между версиями схемы: STEPS[n] переводит версию n-1 в n.
local STEPS = {
  [1] = function() end, -- первая версия: только ensure_shape
}

--- Вызывается из on_init и on_configuration_changed.
function M.run()
  local from = type(storage.proto) == "number" and storage.proto or 0
  M.ensure_shape()
  for v = from + 1, M.VERSION do
    if STEPS[v] then STEPS[v]() end
  end
  storage.proto = M.VERSION
  M.ensure_shape()
end

return M
