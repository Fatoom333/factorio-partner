-- Рефлексы: операция `reflexes` и вызов проверок модулей.
-- Модуль объявляет M.reflexes = { <type> = { schema = {...}, check = function(helper_id, entity, params, tick) end } }.
-- `reflexes{set:[{type, ...параметры}]}` — полная замена набора помощника, параметры проверяются
-- по schema типа; `reflexes{}` без `set` ничего не меняет и возвращает текущий набор. storage.reflexes[helper] = { {type=..., ...}, ... }.
-- Ядро вызывает check каждые CHECK_EVERY тиков для каждого живого помощника и каждого
-- рефлекса из его набора (под pcall). Что делать (события, задачи) — решает check.
--
-- Срок жизни набора (EVENTS.md «Рефлексы v1»): он лежит в storage и привязан к id помощника, а
-- не к телу, поэтому переживает смерть и возрождение, перезагрузку сейва и возврат
-- тела-игрока (пока тела нет, проверки просто не идут). Сбрасывает его только `helper_remove`
-- (M.forget, зовёт ядро) — и, конечно, новый вызов `reflexes{set}`.
local err = require("scripts.core.err")
local schema = require("scripts.core.schema")
local registry = require("scripts.core.registry")

local M = {}

M.MAX_SET = 16
M.CHECK_EVERY = 10

M.types = {} -- type -> {schema, check}

function M.register(mod)
  for t, def in pairs(mod.reflexes or {}) do
    if type(t) ~= "string" or type(def) ~= "table" or type(def.check) ~= "function" then
      error("reflexes.register: bad reflex " .. tostring(t), 2)
    end
    if M.types[t] then error("reflexes.register: reflex " .. t .. " registered twice", 2) end
    M.types[t] = def
  end
end

local SET_SCHEMA = {
  set = { type = "list", max = M.MAX_SET, of = { type = "any" } },
}

function M.op_reflexes(args, ctx)
  local a = schema.validate(SET_SCHEMA, args)
  if a.set == nil then return { set = M.get(ctx.helper_id) or {} } end
  local out = {}
  for i, r in ipairs(a.set) do
    local path = "args.set[" .. i .. "]"
    if type(r) ~= "table" or type(r.type) ~= "string" then err.raise("bad_args", path .. ".type: required") end
    local def = M.types[r.type]
    if def == nil then err.raise("bad_args", path .. ".type: unknown reflex " .. r.type) end
    local params = {}
    for k, v in pairs(r) do
      if k ~= "type" then params[k] = v end
    end
    local v = schema.validate(def.schema or {}, params, path)
    v.type = r.type
    out[i] = v
  end
  storage.reflexes[ctx.helper_id] = out
  return { set = out }
end

--- Забыть набор рефлексов помощника (только helper_remove).
function M.forget(helper)
  if type(storage.reflexes) == "table" then storage.reflexes[helper] = nil end
end

--- Набор рефлексов помощника (копия не делается — только для чтения) или nil.
function M.get(helper)
  local set = type(storage.reflexes) == "table" and storage.reflexes[helper] or nil
  if type(set) ~= "table" then return nil end
  return set
end

local last_log = {}

function M.run(tick)
  for helper, set in pairs(storage.reflexes) do
    if type(set) == "table" and set[1] ~= nil then
      local rec, entity = registry.alive(helper)
      if rec then
        for _, params in ipairs(set) do
          local def = M.types[params.type]
          if def then
            local ok, e = pcall(def.check, helper, entity, params, tick)
            if not ok then
              err.count_module_error() -- hello.module_errors (EVENTS.md «Рефлексы v1»)
              local key = params.type
              if last_log[key] == nil or tick - last_log[key] >= 3600 then
                last_log[key] = tick
                log("[factorio-partner] reflex " .. key .. " failed: " .. err.clean_text(err.is(e) and e.text or e))
              end
            end
            if not entity.valid then break end
          end
        end
      end
    end
  end
end

return M
