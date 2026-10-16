-- Буфер событий. Контракт: docs/EVENTS.md.
-- storage.events = {next_seq, list}: кольцо последних 500 событий, слот = (seq-1) % 500 + 1.
-- Событие: {seq, tick, helper|nil, kind, data, loud}. seq растёт монотонно и переживает загрузку.
-- Модули шлют события только через events.emit(helper, kind, data[, opts]); в действиях — ctx.emit.
local util = require("scripts.core.util")
local owner = require("scripts.core.owner")
local schema = require("scripts.core.schema")
local err = require("scripts.core.err")

local M = {}

M.CAPACITY = 500
M.MAX_DATA_BYTES = 4000   -- больше -> data ужимается (shrink): detail = {truncated=true}
M.MAX_FIELD_CHARS = 200   -- при ужатии: строки длиннее обрезаются
M.MAX_SMALL_TABLE = 256   -- при ужатии: вложенные таблицы до стольких байт JSON остаются (pos и т.п.)
M.MAX_EVENTS_BYTES = 150000 -- op events: суммарный размер событий в одном ответе (лимит ответа 200 000)
-- Поля, которые остаются при любом ужатии (EVENTS.md: job_done/job_failed = {job, do, code, text, detail}).
local KEY_FIELDS = { "job", "do", "code", "text", "type", "reason", "outcome" }
M.MAX_CHAT = 500          -- player_said.text, символов

-- Будят агента (EVENTS.md). `attacked` громкий только первый в эпизоде — модуль H передаёт
-- opts.loud=false для повторных. `player_said` громкий только от хозяина.
M.LOUD = {
  job_done = true, job_failed = true, attacked = true, health_low = true,
  died = true, respawned = true, reflex_done = true, inventory_full = true, helper_lost = true,
  craft_done = true, reflex_resumed = true, ammo_low = true,
  owner_stop = true, owner_resume = true,
}

local function storage_events() return storage.events end

local function json_len(t)
  local ok, json = pcall(helpers.table_to_json, t)
  if not ok then return nil end
  return #json
end

--- Ужать данные события, которые не влезли в MAX_DATA_BYTES. Скалярные поля остаются всегда
--- (строки обрезаются до MAX_FIELD_CHARS), `detail` заменяется на {truncated=true}, прочие
--- вложенные таблицы остаются, только если они маленькие. На верхнем уровне всегда truncated=true.
local function shrink(clean)
  local out = {}
  local keys = {}
  for k in pairs(clean) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    local v = clean[k]
    local t = type(v)
    if t == "number" or t == "boolean" then
      out[k] = v
    elseif t == "string" then
      local s = util.utf8_head(v, M.MAX_FIELD_CHARS)
      out[k] = s
    elseif k == "detail" then
      out[k] = { truncated = true }
    elseif t == "table" then
      local n = json_len(v)
      if n ~= nil and n <= M.MAX_SMALL_TABLE then out[k] = v end
    end
  end
  out.truncated = true -- EVENTS.md: ужатое событие помечено на верхнем уровне
  local n = json_len(out)
  if n ~= nil and n <= M.MAX_DATA_BYTES then return out end
  -- полей слишком много: только ключевые
  local min = { truncated = true }
  for _, k in ipairs(KEY_FIELDS) do
    local v = out[k]
    if type(v) == "number" or type(v) == "boolean" or type(v) == "string" then min[k] = v end
  end
  if out.detail ~= nil then min.detail = { truncated = true } end
  return min
end
M._shrink = shrink

--- Добавить событие. helper — id помощника или nil (событие мира).
--- opts.loud (bool) — переопределить «будит ли агента». Возвращает seq.
function M.emit(helper, kind, data, opts)
  if type(kind) ~= "string" or kind == "" then error("events.emit: kind must be a string", 2) end
  local ev = storage_events()
  local clean = util.plain(data or {})
  if type(clean) ~= "table" then clean = {} end -- emit не роняют даже на мусоре вместо data
  local n = json_len(clean)
  if n == nil or n > M.MAX_DATA_BYTES then
    clean = shrink(clean)
  end
  local loud
  if opts and opts.loud ~= nil then
    loud = opts.loud and true or false
  elseif kind == "player_said" then
    loud = clean.owner == true
  else
    loud = M.LOUD[kind] == true
  end
  local seq = ev.next_seq
  ev.next_seq = seq + 1
  ev.list[(seq - 1) % M.CAPACITY + 1] = {
    seq = seq, tick = game.tick, helper = helper, kind = kind, data = clean, loud = loud,
  }
  return seq
end

--- Номер последнего события (0 — событий не было).
function M.last_seq()
  local ev = storage and storage.events
  if not ev then return 0 end
  return ev.next_seq - 1
end

--- События с seq > since (для helper — его и мировые), не больше limit и (если задан
--- max_bytes) не больше max_bytes байт JSON суммарно; хотя бы одно событие выдаётся всегда.
--- Возвращает events, seq, lost. seq — номер, до которого просмотрен буфер: последний в
--- буфере, а если список обрезан по limit/max_bytes — номер последнего выданного события
--- (следующий запрос since=seq продолжит без пропусков).
function M.query(since, helper, limit, max_bytes)
  local ev = storage_events()
  local last = ev.next_seq - 1
  local oldest = math.max(1, last - M.CAPACITY + 1)
  local out = {}
  if since >= last then return out, last, false end
  local lost = since + 1 < oldest
  local seq_ret = last
  local bytes, prev = 0, since
  for s = math.max(since + 1, oldest), last do
    local e = ev.list[(s - 1) % M.CAPACITY + 1]
    if e and e.seq == s and (helper == nil or e.helper == nil or e.helper == helper) then
      if max_bytes then
        bytes = bytes + (json_len(e) or M.MAX_DATA_BYTES) + 1
        if #out > 0 and bytes > max_bytes then
          seq_ret = prev
          break
        end
      end
      out[#out + 1] = e
      prev = s
      if #out >= limit then
        seq_ret = s
        break
      end
    end
  end
  return out, seq_ret, lost
end

-- ------------------------------------------------------------------ операция events

local EVENTS_SCHEMA = {
  since = { type = "int", required = true, min = 0 },
  helper = { type = "string", max = 16, pattern = "^[a-z0-9_%-]+$" },
  limit = { type = "int", min = 1, max = 200, default = 100 },
}

function M.op_events(args)
  local a = schema.validate(EVENTS_SCHEMA, args)
  local list, seq, lost = M.query(a.since, a.helper, a.limit, M.MAX_EVENTS_BYTES)
  return { seq = seq, events = list, lost = lost }
end

-- ------------------------------------------------------------------ player_said

M.MAX_GPS = 4

--- Метки карты из текста чата: `[gps=x,y]` или `[gps=x,y,поверхность]` (пинг и Shift+клик по
--- карте). → список {pos, surface?} (≤ MAX_GPS) или nil.
function M.gps_tags(text)
  local out
  for x, y, rest in string.gmatch(text or "", "%[gps=(%-?[%d%.]+),(%-?[%d%.]+)([^%]]*)%]") do
    local nx, ny = tonumber(x), tonumber(y)
    if nx ~= nil and ny ~= nil and nx == nx and ny == ny and math.abs(nx) <= 2e6 and math.abs(ny) <= 2e6 then
      out = out or {}
      local surface = string.match(rest, "^,([%w%-_ ]+)$")
      out[#out + 1] = { pos = util.pos({ x = nx, y = ny }), surface = surface }
      if #out >= M.MAX_GPS then break end
    end
  end
  return out
end

-- Разбор слов хозяина: модули кладут сюда функцию по имени (scripts/core/owner_words.lua).
-- hook(data) -> extra|nil, after|nil: extra — поля, дописываемые в player_said; after(seq) зовётся
-- после emit с номером player_said. Хуки зовутся только для сообщений хозяина, под pcall.
M.chat_hooks = {}

function M.on_console_chat(e)
  if e.player_index == nil then return end -- сервер/RCON
  local p = game.get_player(e.player_index)
  if p == nil then return end
  local is_owner = owner.is_owner(p)
  local text = util.utf8_head(util.one_line(e.message or ""), M.MAX_CHAT)
  local ok, pos = pcall(function() return util.pos(p.physical_position) end)
  local data = { player = p.name, owner = is_owner, text = text, pos = ok and pos or nil }
  data.gps = M.gps_tags(text)
  if is_owner then
    local sel = p.selected
    if sel and sel.valid then
      data.selected = { name = sel.name, pos = util.pos(sel.position), unit_number = sel.unit_number }
    end
  end
  local afters = {}
  if is_owner then
    local names = {}
    for name in pairs(M.chat_hooks) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local ok, extra, after = pcall(M.chat_hooks[name], data)
      if ok then
        for k, v in pairs(extra or {}) do data[k] = v end
        if after ~= nil then afters[#afters + 1] = after end
      else
        err.count_module_error()
      end
    end
  end
  local seq = M.emit(nil, "player_said", data)
  for _, after in ipairs(afters) do
    if not pcall(after, seq) then err.count_module_error() end
  end
end

return M
