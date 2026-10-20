-- Разрешения хозяина: настройки мода `partner-perm-…` («сам» / «спросить» / «нельзя») и пределы.
-- Контракт: docs/PROTOCOL.md (операция settings, поле конверта owner_ok, коды owner_forbids и
-- needs_owner_ok), docs/ACTIONS.md (M.perms у действий).
--
-- Действие объявляет M.perms = function(args, ctx) return {"perm-…", …} end — ключи, которые
-- эти (уже проверенные схемой) аргументы задевают. Гейт — в jobs.op_act и в шагах plan, рефлексы —
-- в reflexes.op_reflexes. Он включён только для запросов по RCON (ctx.perm_gate, ставит dispatch):
-- свои вызовы мода (рефлексы, слова хозяина, возврат после отступления) идут мимо него.
--   * нельзя  → отказ owner_forbids, даже с owner_ok;
--   * спросить → отказ needs_owner_ok, если ключа нет в owner_ok конверта (список ключей, ставит только
--                сервер, когда хозяин ответил «да» на вопрос именно об этих разрешениях);
--   * сам → как раньше.
-- Задача очереди помнит perm_gate и owner_ok (task.perm_gate / task.owner_ok): проверки, которые
-- нельзя сделать по аргументам (плавка в get_items, деревья в mine{item}), идут по ним на ходу.
local err = require("scripts.core.err")
local owner = require("scripts.core.owner")
local util = require("scripts.core.util")
local target = require("scripts.core.target")

local M = {}

M.PREFIX = "partner-"

-- Разрешения: ключ без «perm-» → {по умолчанию, подпись}. Порядок — как в snapshot и в настройках.
M.PERMS = {
  { "take-chests", "auto", "Брать из сундуков" },
  { "take-lines", "ask", "Брать из выходов линий" },
  { "take-inputs", "deny", "Брать из входов машин и топлива" },
  { "build", "auto", "Строить" },
  { "superforced", "ask", "Сверхсильная стройка" },
  { "deconstruct-own", "auto", "Разбирать свои постройки" },
  { "deconstruct-owner", "ask", "Разбирать постройки хозяина" },
  { "set-recipe", "ask", "Менять рецепт в машинах хозяина" },
  { "chop", "auto", "Рубить деревья и камни" },
  { "smelt", "auto", "Плавить в печах хозяина" },
  { "spend", "ask", "Тратить много предметов" },
  { "shoot", "ask", "Включать стрельбу" },
  { "turrets", "auto", "Заправлять турели" },
  { "upkeep", "ask", "Включать обслуживание" },
  { "attack-nests", "deny", "Стрелять по гнёздам" },
  { "walk-far", "auto", "Уходить далеко от хозяина" },
  { "leave-planet", "deny", "Менять планету" },
  { "auto", "ask", "Самостоятельный режим AUTO" },
}

local INDEX = {}
for _, p in ipairs(M.PERMS) do INDEX[p[1]] = p end

M.LIMITS = { spend = 200, far = 300 }

local function raw(name)
  local s = settings and settings.global and settings.global[M.PREFIX .. name]
  if s == nil then return nil end
  return s.value
end

local function norm_key(key)
  key = tostring(key)
  return (key:gsub("^perm%-", ""))
end

--- "auto" │ "ask" │ "deny" для ключа ("perm-take-lines" или "take-lines"); неизвестное значение — по умолчанию.
function M.get(key)
  local p = INDEX[norm_key(key)]
  if p == nil then return "deny" end
  local v = raw("perm-" .. p[1])
  if v == "auto" or v == "ask" or v == "deny" then return v end
  return p[2]
end

--- Подпись разрешения (как в настройках мода).
function M.label(key)
  local p = INDEX[norm_key(key)]
  return p and p[3] or tostring(key)
end

local function int_setting(name, default, lo, hi)
  local v = raw(name)
  if type(v) ~= "number" then return default end
  v = math.floor(v)
  if v < lo then v = lo elseif v > hi then v = hi end
  return v
end

local function bool_setting(name, default)
  local v = raw(name)
  if type(v) ~= "boolean" then return default end
  return v
end

local function num_setting(name, default, lo, hi)
  local v = raw(name)
  if type(v) ~= "number" then return default end
  if v < lo then v = lo elseif v > hi then v = hi end
  return v
end

local function enum_setting(name, default, values)
  local v = raw(name)
  for _, x in ipairs(values) do
    if v == x then return v end
  end
  return default
end

function M.limit(name)
  if name == "spend" then return int_setting("spend-limit", M.LIMITS.spend, 1, 100000) end
  if name == "far" then return int_setting("far-distance", M.LIMITS.far, 10, 100000) end
  return nil
end

--- Бой: {flee_health (%), auto_armor, turret_standoff, turret_gap}.
function M.combat()
  return {
    flee_health = int_setting("flee-health", 40, 1, 100),
    auto_armor = bool_setting("auto-armor", true),
    turret_standoff = bool_setting("turret-standoff", true),
    turret_gap = int_setting("turret-gap", 3, 1, 10),
  }
end

function M.chat()
  return {
    answer_every = bool_setting("answer-every", true),
    reply_lines = int_setting("reply-lines", 2, 1, 6),
  }
end

function M.agents()
  return {
    helpers = int_setting("helpers", 1, 1, 5),
    pilot_model = enum_setting("pilot-model", "sonnet", { "sonnet", "haiku" }),
    strategist_model = enum_setting("strategist-model", "sonnet", { "sonnet", "opus" }),
    thoughts = bool_setting("thoughts", false),
    voice_pause = num_setting("voice-pause", 2.5, 0, 6),
    budget = {
      strategist = int_setting("budget-strategist", 70, 0, 100),
      voice_only = int_setting("budget-voice-only", 85, 0, 100),
      weekly = int_setting("budget-weekly", 90, 0, 100),
    },
  }
end

--- Всё сразу — ответ операции `settings`.
function M.snapshot()
  local perms = {}
  for _, p in ipairs(M.PERMS) do perms[p[1]:gsub("%-", "_")] = M.get(p[1]) end
  return {
    perms = perms,
    limits = { spend = M.limit("spend"), far = M.limit("far") },
    agents = M.agents(),
    combat = M.combat(),
    chat = M.chat(),
  }
end

--- owner_ok конверта (список ключей "take_lines" / "take-lines" / "perm-take-lines") → множество
--- {["take-lines"]=true} │ nil; неизвестный ключ или не список — nil и текст ошибки.
function M.leave_set(v)
  if v == nil then return nil end
  if type(v) ~= "table" then return nil, "owner_ok must be a list of permission keys" end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n > #M.PERMS or n ~= #v then return nil, "owner_ok must be a list of permission keys" end
  local set = {}
  for _, k in ipairs(v) do
    if type(k) ~= "string" or #k > 40 then return nil, "owner_ok must be a list of permission keys" end
    local key = norm_key(k:gsub("_", "-"))
    if INDEX[key] == nil then return nil, "owner_ok: unknown permission " .. k end
    set[key] = true
  end
  return set
end

--- Хозяин разрешил ключ key этому запросу или задаче (gate.owner_ok — множество из leave_set).
function M.allowed(gate, key)
  local ok = gate and gate.perm_gate == true and gate.owner_ok
  return type(ok) == "table" and ok[norm_key(key)] == true
end

function M.op_settings(args)
  if type(args) == "table" and next(args) ~= nil then
    err.raise("bad_args", "args: settings takes no arguments")
  end
  return M.snapshot()
end

-- ------------------------------------------------------------------ проверка

--- Отказ по списку ключей → code, text, data │ nil. gate — ctx запроса или задача:
--- читаются perm_gate и owner_ok (множество разрешённых ключей). Без perm_gate (свой вызов мода) всё
--- разрешено.
function M.refusal(keys, gate)
  if type(keys) ~= "table" or gate == nil or gate.perm_gate ~= true then return nil end
  local ask
  for _, key in ipairs(keys) do
    local mode = M.get(key)
    if mode == "deny" then
      return "owner_forbids", "запрещено в настройках мода: " .. M.label(key), { perm = norm_key(key) }
    elseif mode == "ask" and ask == nil and not M.allowed(gate, key) then
      ask = key
    end
  end
  if ask ~= nil then
    return "needs_owner_ok", "нужно разрешение хозяина: " .. M.label(ask), { perm = norm_key(ask) }
  end
  return nil
end

--- Как refusal, но бросает ошибку.
function M.demand(keys, gate)
  local code, text, data = M.refusal(keys, gate)
  if code ~= nil then err.raise(code, text, data) end
end

--- Действие (имя или модуль) и его проверенные аргументы → код, текст, данные │ nil.
function M.check(action, args, ctx)
  local mod = action
  if type(mod) ~= "table" or type(mod.perms) ~= "function" then return nil end
  local keys = mod.perms(args or {}, ctx)
  return M.refusal(keys, ctx)
end

function M.enforce(action, args, ctx)
  local code, text, data = M.check(action, args, ctx)
  if code ~= nil then err.raise(code, text, data) end
end

--- Трата n предметов одной задачей стройки: больше partner-spend-limit — ключ perm-spend в keys.
function M.add_spend(keys, n)
  if type(n) == "number" and n > M.limit("spend") then M.add(keys, "perm-spend") end
  return keys
end

--- Список ключей без повторов.
function M.add(keys, key)
  for _, k in ipairs(keys) do
    if k == key then return keys end
  end
  keys[#keys + 1] = key
  return keys
end

-- ------------------------------------------------------------------ помощники для действий

--- Постройку поставил игрок (у LuaEntity.last_user есть игрок), а не помощник.
function M.owner_built(e)
  if e == nil then return false end
  local ok, v = pcall(function() return e.valid and e.last_user ~= nil end)
  return ok and v == true
end

--- Ключи разбора (deconstruct, mine{target}) сущности e, добавляются в keys: постройка игрока
--- (last_user) — хозяйская, остальные своей силы — помощников; деревья и камни (сила neutral) — как
--- добыча деревьев; руда — всегда можно.
function M.dig_keys(e, keys)
  keys = keys or {}
  if e == nil or e.valid == false or e.type == "resource" then return keys end
  local force = e.force
  local fname = type(force) == "string" and force or (force and force.name)
  if fname == "neutral" then
    M.add(keys, "perm-chop")
  elseif M.owner_built(e) then
    M.add(keys, "perm-deconstruct-owner")
  else
    M.add(keys, "perm-deconstruct-own")
  end
  return keys
end

--- Сущность по цели без ошибок (nil — не нашли): для гейта по аргументам, настоящие ошибки
--- действие скажет само, когда начнёт.
function M.find(ctx, t)
  local h = ctx and ctx.entity
  if h == nil or not h.valid or type(t) ~= "table" then return nil end
  local ok, e = pcall(function()
    return target.resolve(h.surface, t, h.force, { near = h.position })
  end)
  if ok and e ~= nil and e.valid then return e end
  return nil
end

--- Точка pos дальше предела от хозяина (хозяин в игре, на той же поверхности)?
function M.too_far(ctx, pos)
  local h = ctx and ctx.entity
  if h == nil or not h.valid or type(pos) ~= "table" then return false end
  local _, ch = owner.present()
  if ch == nil then return false end
  local ok, far = pcall(function()
    if ch.surface ~= h.surface then return false end
    return util.dist(util.xy(ch.position), util.xy(pos)) > M.limit("far")
  end)
  return ok and far == true
end

return M
