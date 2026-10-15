-- Идемпотентность (PROTOCOL.md §2): кольцо последних 128 ответов по `id`.
-- Повторный запрос с тем же id получает сохранённую строку ответа, операция не исполняется.
-- storage.recent = { map = {[id] = line}, order = {[slot] = id}, head, bytes }
--
-- Чтобы сейв не распухал: ответ операции только для чтения длиннее MAX_READ_ENTRY не
-- сохраняется (её повтор безопасен — просто исполнится заново). Ответы операций с
-- последствиями (act, cancel, helper_*, say, blob_put, reflexes, vision) сохраняются всегда.
local M = {}

M.SIZE = 128
M.MAX_READ_ENTRY = 16 * 1024

local function R() return storage.recent end

function M.get(id)
  return R().map[id]
end

function M.put(id, line, read_only)
  local r = R()
  if r.map[id] ~= nil then return end
  if read_only and #line > M.MAX_READ_ENTRY then return end
  r.head = r.head % M.SIZE + 1
  local old = r.order[r.head]
  if old ~= nil and r.map[old] ~= nil then
    r.bytes = r.bytes - #r.map[old]
    r.map[old] = nil
  end
  r.order[r.head] = id
  r.map[id] = line
  r.bytes = r.bytes + #line
end

return M
