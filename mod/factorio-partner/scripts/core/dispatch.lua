-- Команда /partner: конверт v1, маршрутизация операций, идемпотентность, лимиты.
-- Контракт: docs/PROTOCOL.md §1–§4.
--
-- Запрос:  {"v":1, "id":"r-1", "op":"act", "helper":"h1", "args":{...}}
-- Ответ:   {"v":1, "id":"r-1", "ok":true,  "tick":..., "seq":..., "data":{...}}
--          {"v":1, "id":"r-1", "ok":false, "tick":..., "seq":..., "error":{"code":"...", "text":"..."}}
-- Ровно одна строка в RCON через rcon.print. Из чата игрока — отказ в чат, в RCON ничего.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local events = require("scripts.core.events")
local recent = require("scripts.core.recent")
local registry = require("scripts.core.registry")
local perms = require("scripts.core.perms")

local M = {}

M.PROTO = 1
M.MAX_REQUEST = 8192
M.MAX_PARSE_OVERSIZE = 512 * 1024 -- запрос больше MAX_REQUEST, но до стольких байт — разбираем ради id
M.MAX_RESPONSE = 200000

-- Требование к `helper` (PROTOCOL §4): "h" — обязателен и жив; "h?" — необязателен, но если
-- указан — должен быть жив; "spawn"/"remove" — обязателен, проверку делает сама операция;
-- false — не нужен (если указан, игнорируется).
M.HELPER_REQ = {
  hello = false, helper_list = false, events = false, blob_put = false, helper_limit = false, settings = false,
  helper_spawn = "spawn", helper_remove = "remove",
  helper_attach = "spawn", -- операция тела-игрока (scripts/core/attach.lua): id обязателен, тело проверяет сама
  act = "h", cancel = "h", jobs = "h", reflexes = "h", say = "h", vision = "h", state = "h", recipes = "h",
  map = "h?", resources = "h?", stock = "h?", ghosts = "h?", rates = "h?", find = "h?", access = "h?", status = "h?",
}
M.DEFAULT_MODULE_REQ = "h?"

-- Только чтение: большой ответ таких операций не храним в recent (повтор безопасен).
M.READ_ONLY = {
  hello = true, helper_list = true, jobs = true, events = true, state = true, map = true, settings = true,
  resources = true, stock = true, ghosts = true, recipes = true, rates = true, find = true, access = true, status = true,
  supply = true, lookup = true,
}

M.ops = {} -- op -> function(args, ctx) -> data

function M.register_op(op, fn)
  if type(op) ~= "string" or type(fn) ~= "function" then error("dispatch.register_op: bad op", 2) end
  if M.ops[op] then error("dispatch.register_op: op " .. op .. " registered twice", 2) end
  M.ops[op] = fn
end

local ENVELOPE_KEYS = { v = true, id = true, op = true, helper = true, args = true, owner_ok = true }

local function encode(resp)
  local ok, line = pcall(helpers.table_to_json, resp)
  if not ok then
    log("[factorio-partner] response is not serializable: " .. err.clean_text(line))
    return nil
  end
  return line
end

local function error_line(id, code, text, data)
  local line = encode{
    v = M.PROTO, id = id, ok = false, tick = game.tick, seq = events.last_seq(),
    error = { code = code, text = err.clean_text(text or code), data = data },
  }
  return line
end

local function valid_id(id)
  return type(id) == "string" and #id >= 1 and #id <= 40 and id:find("^[A-Za-z0-9_.:%-]+$") ~= nil
end

local function valid_helper(h)
  return type(h) == "string" and #h >= 1 and #h <= 16 and h:find("^[a-z0-9_%-]+$") ~= nil
end

local function is_object(t)
  if type(t) ~= "table" then return false end
  for k in pairs(t) do if type(k) ~= "string" then return false end end
  return true
end

--- Исполнить разобранный конверт с корректным id. Возвращает строку ответа.
local function execute(id, req)
  for k in pairs(req) do
    if not ENVELOPE_KEYS[k] then return error_line(id, "bad_request", "unknown envelope field " .. tostring(k)) end
  end
  if req.v == nil then return error_line(id, "bad_request", "v is required") end
  if type(req.v) ~= "number" then return error_line(id, "bad_request", "v must be a number") end
  if req.v ~= M.PROTO then return error_line(id, "version_mismatch", "mod speaks protocol v" .. M.PROTO) end
  local op = req.op
  if type(op) ~= "string" or op == "" or #op > 40 then return error_line(id, "bad_request", "op must be a string") end
  local helper = req.helper
  if helper ~= nil and not valid_helper(helper) then
    return error_line(id, "bad_request", "helper must match ^[a-z0-9_-]{1,16}$")
  end
  local args = req.args
  if args == nil then args = {} end
  if not is_object(args) then return error_line(id, "bad_request", "args must be an object") end
  -- owner_ok — разрешение хозяина на «спросить» (scripts/core/perms.lua): список ключей, о которых
  -- был вопрос; ставит только сервер
  local leave, leave_err = perms.leave_set(req.owner_ok)
  if leave_err ~= nil then return error_line(id, "bad_request", leave_err) end

  local fn = M.ops[op]
  if fn == nil then return error_line(id, "unknown_op", "unknown op " .. op) end

  local need = M.HELPER_REQ[op]
  if need == nil then need = M.DEFAULT_MODULE_REQ end
  local ctx = { tick = game.tick, request_id = id, perm_gate = true, owner_ok = leave }
  local ok, res = pcall(function()
    if need == "h" or need == "spawn" or need == "remove" then
      if helper == nil then err.raise("bad_request", "helper is required for " .. op) end
      ctx.helper_id = helper
      if need == "h" then
        local _, e = registry.require_alive(helper)
        ctx.entity = e
      end
    elseif need == "h?" and helper ~= nil then
      local _, e = registry.require_alive(helper)
      ctx.helper_id = helper
      ctx.entity = e
    end
    return fn(args, ctx)
  end)
  if not ok then
    local code, text, data = err.normalize(res)
    if code == "internal" then
      err.count_module_error("op " .. tostring(op), res)
      log("[factorio-partner] op " .. op .. " failed: " .. text)
    end
    return error_line(id, code, text, data)
  end
  local data = res
  if data == nil then data = {} end
  if type(data) ~= "table" then return error_line(id, "internal", "op returned non-table data") end
  local line = encode{ v = M.PROTO, id = id, ok = true, tick = game.tick, seq = events.last_seq(), data = data }
  if line == nil then return error_line(id, "internal", "response is not serializable") end
  if #line > M.MAX_RESPONSE then
    return error_line(id, "too_large", "response is " .. #line .. " bytes (limit " .. M.MAX_RESPONSE .. "), narrow the request")
  end
  return line
end

--- Строка параметра команды -> строка ответа (одна строка JSON).
function M.process(param)
  if type(param) ~= "string" or param == "" then
    return error_line(nil, "bad_request", "empty command: /partner <JSON>")
  end
  if #param > M.MAX_REQUEST then
    -- id берём из разобранного запроса, чтобы сервер сопоставил ответ (PROTOCOL §5);
    -- в recent такой ответ не кладём — операция не исполнялась.
    local id
    if #param <= M.MAX_PARSE_OVERSIZE then
      local okp, big = pcall(helpers.json_to_table, param)
      if okp and type(big) == "table" and valid_id(big.id) then id = big.id end
    end
    return error_line(id, "limit", "request is larger than " .. M.MAX_REQUEST .. " bytes; use blob_put")
  end
  local req = helpers.json_to_table(param)
  if type(req) ~= "table" then return error_line(nil, "bad_request", "not a JSON object") end
  local id = req.id
  if not valid_id(id) then
    return error_line(nil, "bad_request", "id must match ^[A-Za-z0-9_.:-]{1,40}$")
  end
  local saved = recent.get(id)
  if saved ~= nil then return saved end
  local line = execute(id, req)
  recent.put(id, line, M.READ_ONLY[req.op] == true)
  return line
end

--- Обработчик commands.add_command("partner", ...).
function M.handle(cmd)
  if cmd.player_index ~= nil then
    local p = game.get_player(cmd.player_index)
    if p then p.print("[partner] только для RCON") end
    return
  end
  local ok, line = pcall(M.process, cmd.parameter)
  if not ok then
    log("[factorio-partner] /partner failed: " .. err.clean_text(line))
    line = error_line(nil, "internal", "internal error")
  end
  if line == nil then
    line = '{"v":1,"ok":false,"error":{"code":"internal","text":"internal error"}}'
  end
  rcon.print(line)
end

return M
