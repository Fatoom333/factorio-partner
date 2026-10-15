-- Большие данные частями: операция blob_put. PROTOCOL.md §4.
-- storage.blobs = { bytes = <всего байт>, items = { [blob] = {total, parts={[i]=str}, received, bytes, last_tick} } }
-- Живут 10 мин с последней части; всего ≤ 1 МБ (иначе `limit`). Повтор части безопасен.
-- Чтение для build_blueprint: blobs.get(id) -> строка целиком | nil, received, total.
local err = require("scripts.core.err")
local schema = require("scripts.core.schema")

local M = {}

M.MAX_PART = 3500
M.MAX_BYTES = 1024 * 1024
M.MAX_PARTS = math.ceil(M.MAX_BYTES / M.MAX_PART)
M.TTL = 10 * 60 * 60

local SCHEMA = {
  blob = { type = "string", required = true, max = 32, pattern = "^[a-z0-9%-]+$" },
  part = { type = "int", required = true, min = 1, max = M.MAX_PARTS },
  total = { type = "int", required = true, min = 1, max = M.MAX_PARTS },
  data = { type = "string", required = true, max = M.MAX_PART, max_code = "limit" },
}

local function B() return storage.blobs end

function M.drop(id)
  local b = B().items[id]
  if b == nil then return end
  B().bytes = B().bytes - b.bytes
  B().items[id] = nil
end

--- Удалить blob'ы старше 10 мин с последней части.
function M.expire(tick)
  tick = tick or game.tick
  for id, b in pairs(B().items) do
    if tick - b.last_tick >= M.TTL then M.drop(id) end
  end
end

function M.op_put(args)
  local a = schema.validate(SCHEMA, args)
  if a.part > a.total then err.raise("bad_args", "args.part: must be ≤ total") end
  M.expire()
  local root = B()
  local b = root.items[a.blob]
  if b ~= nil and b.total ~= a.total then
    err.raise("bad_args", "args.total: blob " .. a.blob .. " was started with total=" .. b.total)
  end
  local old = b and b.parts[a.part]
  local delta = #a.data - (old and #old or 0)
  if root.bytes + delta > M.MAX_BYTES then
    err.raise("limit", "blobs exceed " .. M.MAX_BYTES .. " bytes")
  end
  if b == nil then
    b = { total = a.total, parts = {}, received = 0, bytes = 0, last_tick = game.tick }
    root.items[a.blob] = b
  end
  if old == nil then b.received = b.received + 1 end
  b.parts[a.part] = a.data
  b.bytes = b.bytes + delta
  root.bytes = root.bytes + delta
  b.last_tick = game.tick
  return { blob = a.blob, received = b.received, total = b.total }
end

--- Склеенный blob, если получены все части; иначе nil, received, total.
function M.get(id)
  local b = B().items[id]
  if b == nil then return nil, 0, 0 end
  if b.received < b.total then return nil, b.received, b.total end
  local parts = {}
  for i = 1, b.total do parts[i] = b.parts[i] end
  return table.concat(parts), b.received, b.total
end

return M
