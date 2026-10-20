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
local perms = require("scripts.core.perms")

local M = {}

M.MAX_SET = 16
M.CHECK_EVERY = 10

M.types = {} -- type -> {schema, check}

-- Разрешение на включение рефлекса (scripts/core/perms.lua): только новый в наборе.
M.PERM = { shoot = "perm-shoot", ammo = "perm-turrets", upkeep = "perm-upkeep" }

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

--- Копия набора для ответа и для повторной отправки: type и поля схем рефлексов (служебные поля
--- старых сейвов не уходят и не ломают проверку схемы).
function M.public(set)
  local out = {}
  for i, r in ipairs(set or {}) do
    local def = M.types[r.type]
    local fields = def and def.schema or nil
    local c = {}
    for k, v in pairs(r) do
      if k == "type" or (fields ~= nil and fields[k] ~= nil) or (fields == nil and k ~= "nests_ok") then
        c[k] = v
      end
    end
    out[i] = c
  end
  return out
end

local function leave_of(helper)
  local t = type(storage.reflex_leave) == "table" and storage.reflex_leave[helper] or nil
  return type(t) == "table" and t or nil
end

--- Хозяин разрешил этому помощнику стрелять по гнёздам (perm-attack-nests на «спросить»): разрешение
--- дано при включении shoot и живёт, пока shoot в наборе. Хранится отдельно от параметров рефлекса.
function M.nests_leave(helper)
  local t = leave_of(helper)
  return t ~= nil and t.shoot_nests == true
end

function M.op_reflexes(args, ctx)
  local a = schema.validate(SET_SCHEMA, args)
  if a.set == nil then return { set = M.public(M.get(ctx.helper_id)) } end
  local before = {}
  for _, r in ipairs(M.get(ctx.helper_id) or {}) do before[r.type] = r end
  local out = {}
  local nests = nil
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
    local old = before[r.type]
    if old == nil and M.PERM[r.type] then perms.demand({ M.PERM[r.type] }, ctx) end
    -- shoot: стрельба по гнёздам при «спросить» — только если хозяин разрешил именно её
    -- (owner_ok с attack-nests); разрешение держится, пока shoot остаётся в наборе
    if r.type == "shoot" then
      nests = perms.allowed(ctx, "perm-attack-nests") or (old ~= nil and M.nests_leave(ctx.helper_id))
    end
    out[i] = v
  end
  storage.reflexes[ctx.helper_id] = out
  if type(storage.reflex_leave) ~= "table" then storage.reflex_leave = {} end
  storage.reflex_leave[ctx.helper_id] = nests and { shoot_nests = true } or nil
  return { set = M.public(out) }
end

--- Забыть набор рефлексов помощника (только helper_remove).
function M.forget(helper)
  if type(storage.reflexes) == "table" then storage.reflexes[helper] = nil end
  if type(storage.reflex_leave) == "table" then storage.reflex_leave[helper] = nil end
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
