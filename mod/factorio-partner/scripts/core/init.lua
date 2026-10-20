-- Ядро мода: регистрация модулей и действий, команда /partner, склейка событий
-- всех модулей, жизненный цикл (on_init / on_configuration_changed). Контракты:
-- docs/PROTOCOL.md, ACTIONS.md, EVENTS.md, ARCHITECTURE.md «Модульный интерфейс».
--
-- control.lua: core.register_action(mod) для каждого действия, core.register_module(mod)
-- для остальных модулей, затем core.init(). Модули сами script.on_event / on_nth_tick /
-- commands.add_command не вызывают — ядро склеивает их M.events / M.on_nth.
local err = require("scripts.core.err")
local migrate = require("scripts.core.migrate")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local reserve = require("scripts.core.reserve")
local jobs = require("scripts.core.jobs")
local blobs = require("scripts.core.blobs")
local reflexes = require("scripts.core.reflexes")
local dispatch = require("scripts.core.dispatch")
local ops = require("scripts.core.ops")
local wait = require("scripts.core.wait")
local perms = require("scripts.core.perms")

local M = {}

local modules = {}
local initialized = false

function M.register_action(mod)
  jobs.register(mod)
  if mod.ops or mod.events or mod.on_nth or mod.reflexes or mod.on_init or mod.on_configuration_changed then
    M.register_module(mod)
  end
end

function M.register_module(mod)
  if type(mod) ~= "table" then error("core.register_module: module must be a table", 2) end
  for _, m in ipairs(modules) do if m == mod then return end end
  modules[#modules + 1] = mod
  for op, fn in pairs(mod.ops or {}) do dispatch.register_op(op, fn) end
  reflexes.register(mod)
end

-- ------------------------------------------------------------------ склейка событий

local last_log = {}
local function log_error(where, e)
  err.count_module_error(where, e) -- hello.module_errors: каждое падение, а в журнал — не чаще раза в минуту
  local key = where
  local tick = game and game.tick or 0
  if last_log[key] ~= nil and tick - last_log[key] < 3600 then return end
  last_log[key] = tick
  log("[factorio-partner] " .. where .. " failed: " .. err.clean_text(err.is(e) and e.text or e))
end

-- entries: { {fn=, filter=, name=}, ... } в порядке вызова
local function add_handler(map, id, fn, filter, name)
  if id == nil then error("core: event id is nil (" .. tostring(name) .. ")", 3) end
  map[id] = map[id] or {}
  local list = map[id]
  list[#list + 1] = { fn = fn, filter = filter, name = name }
end

local function merged_filter(list)
  local out = {}
  for _, h in ipairs(list) do
    if h.filter == nil then return nil end
    for _, f in ipairs(h.filter) do out[#out + 1] = f end
  end
  if #out == 0 then return nil end
  return out
end

local function make_dispatcher(list)
  if #list == 1 then
    local h = list[1]
    return function(e)
      local ok, x = pcall(h.fn, e)
      if not ok then log_error(h.name, x) end
    end
  end
  return function(e)
    for _, h in ipairs(list) do
      local ok, x = pcall(h.fn, e)
      if not ok then log_error(h.name, x) end
    end
  end
end

local function call_all(hook, ...)
  for i, mod in ipairs(modules) do
    local fn = mod[hook]
    if type(fn) == "function" then
      local ok, e = pcall(fn, ...)
      if not ok then log_error(hook .. " of module " .. tostring(mod.name or i), e) end
    end
  end
end

function M.init()
  if initialized then error("core.init called twice", 2) end
  initialized = true

  jobs.register(wait)

  -- операции ядра
  dispatch.register_op("hello", ops.hello)
  dispatch.register_op("say", ops.say)
  dispatch.register_op("helper_spawn", registry.op_spawn)
  dispatch.register_op("helper_remove", registry.op_remove)
  dispatch.register_op("helper_limit", registry.op_limit)
  dispatch.register_op("helper_list", function(args, ctx)
    return registry.op_list(args, ctx, function(id)
      local t = jobs.active(id)
      return t and t.job or nil
    end)
  end)
  dispatch.register_op("act", jobs.op_act)
  dispatch.register_op("cancel", jobs.op_cancel)
  dispatch.register_op("jobs", jobs.op_jobs)
  dispatch.register_op("events", events.op_events)
  dispatch.register_op("reflexes", reflexes.op_reflexes)
  dispatch.register_op("blob_put", blobs.op_put)
  dispatch.register_op("settings", function(args, ctx) return perms.op_settings(args, ctx) end)

  -- что делать с задачами и резервами, когда тело пропадает
  registry.hooks.before_remove = function(id)
    local _, e = registry.alive(id)
    jobs.fail_all(id, "cancelled", "helper removed", e)
    reserve.release_all(id)
    -- набор рефлексов сбрасывает только helper_remove (EVENTS.md «Рефлексы v1»): смерть,
    -- возрождение, перезагрузку сейва и возврат тела-игрока он переживает
    reflexes.forget(id)
  end
  registry.hooks.on_dead = function(id)
    local rec = registry.get(id)
    jobs.fail_all(id, "no_helper", "helper died", rec and rec.entity)
    reserve.release_all(id)
  end
  registry.hooks.on_lost = function(id)
    jobs.fail_all(id, "no_helper", "helper body lost", nil)
    reserve.release_all(id)
  end

  commands.add_command("partner", { "partner-command.help" }, dispatch.handle)

  -- события: ядро + все модули
  local ev = defines.events
  local CHAR = { { filter = "type", type = "character" } }
  local map = {}
  add_handler(map, ev.on_tick, jobs.on_tick, nil, "jobs.on_tick")
  add_handler(map, ev.on_console_chat, events.on_console_chat, nil, "player_said")
  for i, mod in ipairs(modules) do
    for id, h in pairs(mod.events or {}) do
      local fn, filter = h, nil
      if type(h) == "table" then fn, filter = h.handler, h.filter end
      if type(fn) ~= "function" then error("core: module " .. tostring(mod.name or i) .. " has bad handler for event " .. tostring(id), 2) end
      -- фильтры модулей склеиваются конкатенацией (через «or»); mode="and" прицепился бы к
      -- последнему условию чужого модуля и молча сузил бы его фильтр — запрещаем
      if filter ~= nil then
        if type(filter) ~= "table" then error("core: module " .. tostring(mod.name or i) .. " has bad filter for event " .. tostring(id), 2) end
        for _, f in ipairs(filter) do
          if type(f) == "table" and f.mode == "and" then
            error("core: module " .. tostring(mod.name or i) .. ": filter mode=\"and\" is not supported for event " .. tostring(id) .. " (filters of modules are merged with or)", 2)
          end
        end
      end
      add_handler(map, id, fn, filter, "event " .. tostring(id) .. " of module " .. tostring(mod.name or i))
    end
  end
  -- смерть: ядро ПОСЛЕ модулей, чтобы рефлекс смерти видел state="alive" (или "removed")
  add_handler(map, ev.on_entity_died, registry.on_entity_died, CHAR, "registry.on_entity_died")
  add_handler(map, ev.on_post_entity_died, registry.on_post_entity_died, CHAR, "registry.on_post_entity_died")
  add_handler(map, ev.on_object_destroyed, registry.on_object_destroyed, nil, "registry.on_object_destroyed")

  for id, list in pairs(map) do
    local filter = merged_filter(list)
    if filter then
      script.on_event(id, make_dispatcher(list), filter)
    else
      script.on_event(id, make_dispatcher(list))
    end
  end

  -- on_nth_tick: ядро + модули
  local nth = {}
  local function add_nth(n, fn, name)
    if type(n) ~= "number" or n < 1 or n % 1 ~= 0 then error("core: bad on_nth period " .. tostring(n), 3) end
    nth[n] = nth[n] or {}
    nth[n][#nth[n] + 1] = { fn = fn, name = name }
  end
  add_nth(600, function() blobs.expire() end, "blobs.expire")
  add_nth(reflexes.CHECK_EVERY, function(e) reflexes.run(e.tick) end, "reflexes.run")
  for i, mod in ipairs(modules) do
    for n, fn in pairs(mod.on_nth or {}) do
      add_nth(n, fn, "on_nth " .. n .. " of module " .. tostring(mod.name or i))
    end
  end
  for n, list in pairs(nth) do script.on_nth_tick(n, make_dispatcher(list)) end

  script.on_init(function()
    migrate.run()
    call_all("on_init")
  end)
  script.on_configuration_changed(function(data)
    migrate.run()
    call_all("on_configuration_changed", data)
  end)
end

-- Для тестов и модулей: доступ к подсистемам ядра.
M.jobs = jobs
M.events = events
M.registry = registry
M.blobs = blobs
M.reserve = reserve
M.dispatch = dispatch

return M
