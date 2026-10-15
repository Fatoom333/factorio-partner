-- Мелкие общие функции ядра. Можно использовать из любых модулей.
local err = require("scripts.core.err")

local M = {}

--- Округление до 0.1 (PROTOCOL §1).
function M.round1(v)
  return math.floor(v * 10 + 0.5) / 10
end

--- Позиция (MapPosition в любом виде) -> {x, y}, округлено до 0.1.
function M.pos(p)
  if p == nil then return nil end
  local x, y = p.x, p.y
  if x == nil then x, y = p[1], p[2] end
  return { x = M.round1(x), y = M.round1(y) }
end

--- Позиция без округления, {x, y}.
function M.xy(p)
  if p == nil then return nil end
  if p.x ~= nil then return { x = p.x, y = p.y } end
  return { x = p[1], y = p[2] }
end

function M.dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

M.utf8_trunc = err.utf8_trunc

--- Длина строки в символах UTF-8.
function M.utf8_len(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then n = n + 1 end
  end
  return n
end

--- Первые n символов UTF-8.
function M.utf8_head(s, n)
  local count, i = 0, 1
  while i <= #s do
    local b = s:byte(i)
    if b < 0x80 or b >= 0xC0 then
      count = count + 1
      if count > n then return s:sub(1, i - 1) end
    end
    i = i + 1
  end
  return s
end

--- Заменяет байты, не образующие корректный UTF-8, на «?» (текст из чата уходит в JSON).
function M.utf8_clean(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len
    if b < 0x80 then len = 1
    elseif b >= 0xC2 and b <= 0xDF then len = 2
    elseif b >= 0xE0 and b <= 0xEF then len = 3
    elseif b >= 0xF0 and b <= 0xF4 then len = 4
    else len = 0 end
    local ok = len > 0 and i + len - 1 <= n
    if ok then
      for j = i + 1, i + len - 1 do
        local c = s:byte(j)
        if c < 0x80 or c > 0xBF then ok = false break end
      end
    end
    if ok then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      out[#out + 1] = "?"
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Текст в одну строку: без переводов строк и управляющих символов, корректный UTF-8.
function M.one_line(s)
  s = M.utf8_clean(tostring(s or ""))
  s = s:gsub("[\r\n]+", " ")
  s = s:gsub("[\0-\31\127]", "")
  return s
end

--- Текст для чата игре (PROTOCOL §4 «say»): одна строка, без rich-text тегов,
--- не больше max символов.
function M.chat_text(s, max)
  s = M.one_line(s)
  s = s:gsub("%[[^%]]*%]", "")
  s = s:gsub("[%[%]]", "")
  s = s:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
  return M.utf8_head(s, max or 200)
end

--- Таблица только из чисел/строк/bool (без LuaObject и функций) — копия глубины ≤ depth.
function M.plain(v, depth)
  depth = depth or 8
  local t = type(v)
  if t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
  end
  if t == "string" or t == "boolean" then return v end
  if t ~= "table" or depth <= 0 then return nil end
  if v.object_name ~= nil and type(v.object_name) == "string" and v.valid ~= nil then return nil end
  local out = {}
  for k, x in pairs(v) do
    if type(k) == "string" or type(k) == "number" then
      out[k] = M.plain(x, depth - 1)
    end
  end
  return out
end

function M.copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = M.copy(x) end
  return out
end

function M.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

return M
