-- Проверка аргументов по схеме (поток A). Контракт типов — docs/ACTIONS.md «Интерфейс модуля».
--
-- Схема — таблица {поле = спецификация}. Спецификация:
--   type     = "pos"|"area"|"items"|"target"|"string"|"number"|"int"|"bool"|"enum"|"list"|"object"|"any"
--              или список типов {"pos", "string"} — подходит любой (первый подошедший);
--   required = true          — поле обязательно;
--   default  = значение      — подставляется, если поля нет (копия);
--   max_code = "limit" — для string: превышение max даёт `limit`, а не `bad_args`
--   min/max  — для number/int (значение), string (длина в байтах, по умолчанию max=200), list (число элементов);
--   values   = {..}          — для enum и для string (если задано — допустимые строки);
--   of       = спецификация  — элемент list ("pos" или {type=...});
--   fields   = схема         — для object (вложенная схема).
-- Верхняя граница числа / длины списка / стороны области / числа видов предметов -> код `limit`
-- (PROTOCOL §3), остальное (тип, нижняя граница, лишнее поле, длина строки) -> `bad_args`.
-- Лишние поля — ошибка (текст называет поле). Возвращается новая таблица, вход не меняется.
local err = require("scripts.core.err")

local M = {}

local MAX_COORD = 1e6        -- за пределами карты Factorio (±1 000 000) координат нет
local MAX_AREA_SIDE = 128    -- ACTIONS.md: сторона области ≤ 128
local MAX_ITEMS_KINDS = 200
local MAX_ITEM_COUNT = 100000
local MAX_NAME = 200

local function finite(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function is_int(v) return finite(v) and math.floor(v) == v end

local function fail(path, text) err.raise("bad_args", path .. ": " .. text) end
-- PROTOCOL §3: верхняя граница числового аргумента / числа имён / стороны области -> `limit`
-- (нижняя граница, тип, лишнее поле -> bad_args).
local function over(path, text) err.raise("limit", path .. ": " .. text) end

local function is_array(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    n = n + 1
  end
  for i = 1, n do if t[i] == nil then return false end end
  return true
end
M.is_array = is_array

local function is_object(t)
  if type(t) ~= "table" then return false end
  for k in pairs(t) do if type(k) ~= "string" then return false end end
  return true
end

local function check_name(v)
  return type(v) == "string" and #v >= 1 and #v <= MAX_NAME and not v:find("[\0-\31\127]")
end

local checkers = {}

function checkers.any(v) return v end

function checkers.bool(v, spec, path)
  if type(v) ~= "boolean" then fail(path, "expected bool") end
  return v
end

local function check_range(v, spec, path)
  if spec.min ~= nil and v < spec.min then fail(path, "must be ≥ " .. spec.min) end
  if spec.max ~= nil and v > spec.max then over(path, "must be ≤ " .. spec.max) end
end

function checkers.number(v, spec, path)
  if not finite(v) then fail(path, "expected number") end
  check_range(v, spec, path)
  return v
end

function checkers.int(v, spec, path)
  if not is_int(v) then fail(path, "expected integer") end
  check_range(v, spec, path)
  return v
end

function checkers.string(v, spec, path)
  if type(v) ~= "string" then fail(path, "expected string") end
  local max = spec.max or MAX_NAME
  if #v > max then
    -- spec.max_code = "limit": «слишком большой», а не «неверный» (часть blob_put, PROTOCOL §4)
    (spec.max_code == "limit" and over or fail)(path, "longer than " .. max .. " bytes")
  end
  if spec.min and #v < spec.min then fail(path, "shorter than " .. spec.min .. " bytes") end
  if spec.values then
    local okv = false
    for _, x in ipairs(spec.values) do if x == v then okv = true break end end
    if not okv then fail(path, "must be one of " .. table.concat(spec.values, ", ")) end
  end
  if spec.pattern and not v:find(spec.pattern) then fail(path, "bad format") end
  return v
end

function checkers.enum(v, spec, path)
  for _, x in ipairs(spec.values or {}) do
    if x == v then return v end
  end
  local names = {}
  for _, x in ipairs(spec.values or {}) do names[#names + 1] = tostring(x) end
  fail(path, "must be one of " .. table.concat(names, ", "))
end

function checkers.pos(v, spec, path)
  if type(v) ~= "table" then fail(path, "expected pos {x, y}") end
  for k in pairs(v) do
    if k ~= "x" and k ~= "y" then fail(path, "expected pos {x, y}") end
  end
  if not finite(v.x) or not finite(v.y) then fail(path, "expected pos {x, y}") end
  if math.abs(v.x) > MAX_COORD or math.abs(v.y) > MAX_COORD then fail(path, "out of map") end
  return { x = v.x, y = v.y }
end

function checkers.area(v, spec, path)
  if type(v) ~= "table" or v.left_top == nil or v.right_bottom == nil then
    fail(path, "expected area {left_top, right_bottom}")
  end
  for k in pairs(v) do
    if k ~= "left_top" and k ~= "right_bottom" then fail(path, "unexpected field " .. tostring(k)) end
  end
  local lt = checkers.pos(v.left_top, spec, path .. ".left_top")
  local rb = checkers.pos(v.right_bottom, spec, path .. ".right_bottom")
  if rb.x < lt.x or rb.y < lt.y then fail(path, "right_bottom must be ≥ left_top") end
  local side = spec.max_side or MAX_AREA_SIDE
  if rb.x - lt.x > side or rb.y - lt.y > side then over(path, "side must be ≤ " .. side) end
  return { left_top = lt, right_bottom = rb }
end

function checkers.items(v, spec, path)
  if not is_object(v) then fail(path, "expected {item: count}") end
  local out, n = {}, 0
  for name, count in pairs(v) do
    n = n + 1
    if n > MAX_ITEMS_KINDS then over(path, "too many kinds (≤ " .. MAX_ITEMS_KINDS .. ")") end
    if not check_name(name) then fail(path, "bad item name") end
    if not is_int(count) or count < 1 or count > MAX_ITEM_COUNT then
      fail(path .. "." .. name, "count must be integer 1.." .. MAX_ITEM_COUNT)
    end
    out[name] = count
  end
  if spec.min_kinds and n < spec.min_kinds then fail(path, "empty") end
  return out
end

function checkers.target(v, spec, path)
  if type(v) ~= "table" then fail(path, "expected target {unit_number} or {name, pos}") end
  if v.unit_number ~= nil then
    -- {unit_number, pos?}: pos нужен, когда get_entity_by_unit_number не находит постройку (ACTIONS.md)
    for k in pairs(v) do
      if k ~= "unit_number" and k ~= "pos" then fail(path, "unexpected field " .. tostring(k)) end
    end
    -- unit_number — целое ≥ 1 (ACTIONS.md «Общие типы»): нуля у сущностей не бывает
    if not is_int(v.unit_number) or v.unit_number < 1 then fail(path .. ".unit_number", "expected integer ≥ 1") end
    if v.pos ~= nil then
      return { unit_number = v.unit_number, pos = checkers.pos(v.pos, spec, path .. ".pos") }
    end
    return { unit_number = v.unit_number }
  end
  for k in pairs(v) do
    if k ~= "name" and k ~= "pos" then fail(path, "unexpected field " .. tostring(k)) end
  end
  if not check_name(v.name) then fail(path .. ".name", "expected string") end
  return { name = v.name, pos = checkers.pos(v.pos, spec, path .. ".pos") }
end

function checkers.list(v, spec, path)
  if type(v) ~= "table" or not is_array(v) then fail(path, "expected list") end
  local max = spec.max or 100
  if #v > max then over(path, "more than " .. max .. " elements") end
  if spec.min and #v < spec.min then fail(path, "fewer than " .. spec.min .. " elements") end
  local of = spec.of or { type = "any" }
  if type(of) == "string" then of = { type = of } end
  local out = {}
  for i, x in ipairs(v) do out[i] = M.check_value(x, of, path .. "[" .. i .. "]") end
  return out
end

function checkers.object(v, spec, path)
  if not is_object(v) then fail(path, "expected object") end
  return M.validate(spec.fields or {}, v, path)
end

--- Проверить одно значение по спецификации (без required/default).
function M.check_value(v, spec, path)
  local t = spec.type
  if type(t) == "table" then
    local last
    for _, alt in ipairs(t) do
      local s2 = {}
      for k, x in pairs(spec) do s2[k] = x end
      s2.type = alt
      local ok, res = pcall(M.check_value, v, s2, path)
      if ok then return res end
      -- bad_args от альтернативы — пробуем следующую; всё прочее (internal, ошибка Lua) — наружу
      if not (err.is(res) and res.code == "bad_args") then error(res, 0) end
      last = res
    end
    local names = {}
    for _, alt in ipairs(t) do names[#names + 1] = tostring(alt) end
    fail(path, "expected " .. table.concat(names, " or "))
  end
  local c = checkers[t]
  if not c then err.raise("internal", "schema: unknown type " .. tostring(t) .. " at " .. path) end
  return c(v, spec, path)
end

local function copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = copy(x) end
  return out
end

--- Проверить объект args по схеме. path — префикс для текста ошибки ("args").
function M.validate(schema, args, path)
  path = path or "args"
  schema = schema or {}
  if args == nil then args = {} end
  if not is_object(args) then
    -- пустой JSON-массив [] приходит как пустая таблица — это тоже «пустой объект»
    fail(path, "expected object")
  end
  for k in pairs(args) do
    if schema[k] == nil then fail(path .. "." .. tostring(k), "unknown field") end
  end
  local out = {}
  for name, spec in pairs(schema) do
    local v = args[name]
    local p = path .. "." .. name
    if v == nil then
      if spec.required then fail(p, "required") end
      if spec.default ~= nil then out[name] = copy(spec.default) end
    else
      out[name] = M.check_value(v, spec, p)
    end
  end
  return out
end

return M
