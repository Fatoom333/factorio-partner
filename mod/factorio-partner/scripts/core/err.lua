-- Ошибки с кодом из PROTOCOL.md §3.
-- Модули бросают err.raise(code, text); ядро превращает это в ответ {ok=false, error={code,text}}
-- или в job_failed{code,text}. Любая другая ошибка Lua становится `internal`.
local M = {}

M.CODES = {
  bad_request = true, version_mismatch = true, unknown_op = true, bad_args = true,
  no_helper = true, helper_exists = true, cooldown = true, no_player = true, limit = true,
  not_found = true, not_reachable = true, no_items = true, cannot_place = true,
  not_charted = true, not_visible = true, reserved = true, path_failed = true, stuck = true, no_space = true,
  cancelled = true, owner_hold = true, too_large = true, internal = true,
  owner_forbids = true, needs_owner_ok = true, too_far = true,
}

local MAX_TEXT = 300

--- Обрезает строку до n байт, не разрезая UTF-8 символ (в Lua 5.2 нет utf8).
function M.utf8_trunc(s, n)
  if #s <= n then return s end
  local i = n
  -- байт продолжения 10xxxxxx: 0x80..0xBF; откатываемся к началу символа
  while i > 0 do
    local b = s:byte(i + 1)
    if b == nil or b < 0x80 or b >= 0xC0 then break end
    i = i - 1
  end
  return s:sub(1, i)
end

--- Текст ошибки для ответа: без путей к файлам и номеров строк, ≤ 300 байт.
function M.clean_text(text)
  local s = tostring(text or "")
  s = s:gsub("__[A-Za-z0-9_%-]+__/[^ \t:]*:%d+: ", "")
  s = s:gsub("[A-Za-z0-9_%-./\\]+%.lua:%d+: ", "")
  s = s:gsub("[\r\n\t]+", " ")
  s = s:gsub("stack traceback:.*$", "")
  return M.utf8_trunc(s, MAX_TEXT)
end

function M.raise(code, text, data)
  if not M.CODES[code] then code = "internal" end
  error({ partner_error = true, code = code, text = text or code, data = data }, 0)
end

function M.is(e) return type(e) == "table" and e.partner_error == true end

-- Счётчик `hello.module_errors` (PROTOCOL §4, EVENTS «Рефлексы v1»): сколько раз модуль или
-- рефлекс упал под pcall с загрузки. Не в storage: это диагностика процесса, на состояние
-- игры не влияет (читает её только `hello` по RCON), после загрузки сейва снова 0.
local module_errors = 0

-- Последние падения (`hello.module_errors_last`, `state.module_errors_last`): чтобы помощник мог
-- назвать хозяину, что именно падает, а не число. Тоже в памяти, не в storage.
local LAST_MAX = 3
local WHERE_MAX = 80
local TEXT_MAX = 160
local last = {}

--- Учесть падение модуля под pcall (ядро зовёт рядом с записью в журнал игры).
--- where — короткое имя места («reflex ammo», «event on_tick»), text — что бросил Lua (ошибка или
--- строка); оба необязательны и обрезаются, пути и номера строк вырезаются.
function M.count_module_error(where, text)
  module_errors = module_errors + 1
  if where ~= nil or text ~= nil then
    local w = M.utf8_trunc(M.clean_text(where ~= nil and where or "?"), WHERE_MAX)
    local t = text
    if M.is(t) then t = t.text end
    t = M.utf8_trunc(M.clean_text(t ~= nil and t or ""), TEXT_MAX)
    last[#last + 1] = { where = w, text = t, tick = game and game.tick or 0 }
    if #last > LAST_MAX then table.remove(last, 1) end
  end
  return module_errors
end

function M.module_errors() return module_errors end

--- Копия последних падений, старые первыми (≤ 3 записей).
function M.module_errors_last()
  local out = {}
  for i, r in ipairs(last) do out[i] = { where = r.where, text = r.text, tick = r.tick } end
  return out
end

--- Ошибка (что угодно из pcall) -> code, text, data (data — необязательные поля ответа, например {perm}).
function M.normalize(e)
  if M.is(e) then
    local code = M.CODES[e.code] and e.code or "internal"
    return code, M.clean_text(e.text or code), type(e.data) == "table" and e.data or nil
  end
  return "internal", M.clean_text(e)
end

return M
