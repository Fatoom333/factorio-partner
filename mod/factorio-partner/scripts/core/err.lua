-- Ошибки с кодом из PROTOCOL.md §3 (поток A).
-- Модули бросают err.raise(code, text); ядро превращает это в ответ {ok=false, error={code,text}}
-- или в job_failed{code,text}. Любая другая ошибка Lua становится `internal`.
local M = {}

M.CODES = {
  bad_request = true, version_mismatch = true, unknown_op = true, bad_args = true,
  no_helper = true, helper_exists = true, cooldown = true, no_player = true, limit = true,
  not_found = true, not_reachable = true, no_items = true, cannot_place = true,
  not_charted = true, not_visible = true, reserved = true, path_failed = true, stuck = true,
  cancelled = true, too_large = true, internal = true,
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

function M.raise(code, text)
  if not M.CODES[code] then code = "internal" end
  error({ partner_error = true, code = code, text = text or code }, 0)
end

function M.is(e) return type(e) == "table" and e.partner_error == true end

--- Ошибка (что угодно из pcall) -> code, text.
function M.normalize(e)
  if M.is(e) then
    local code = M.CODES[e.code] and e.code or "internal"
    return code, M.clean_text(e.text or code)
  end
  return "internal", M.clean_text(e)
end

return M
