-- Очередь задач (поток A). Контракт: docs/ACTIONS.md, PROTOCOL.md §4 (act/cancel/jobs).
--
-- storage.jobs = { next_job, by_helper = { [helper] = { active = task|nil, queue = {task, ...} } } }
-- task = { job, helper, ["do"], args (провалидированы, с default), req, created_tick, started_tick,
--          progress = {done, total, ...}?  -- модуль пишет сам; ядро шлёт job_progress раз в 5 с
--          progress_tick = tick?           -- «пульс»: модуль ставит, когда работает без видимых
--                                          --   изменений (ожидание, следование), чтобы не получить stuck
--          ...своё состояние модуля..., _mark (служебное ядра) }
--
-- Жизненный цикл: act ставит задачу в очередь; на следующем тике ядро берёт первую, зовёт
-- M.start (может сразу вернуть result), дальше каждый тик M.tick. result -> job_done/job_failed.
-- При сбое/отмене/застревании ядро зовёт M.stop (под pcall) — он ОБЯЗАН вызвать
-- ctx.cancel_approach(task) и снять своё. Все вызовы модулей — под pcall (иначе `internal`).
--
-- «Застрял»: 60 с без прогресса -> failed{code="stuck"}. Прогресс — любое из: сдвиг тела ≥ 0.1,
-- изменение числа предметов в основном инвентаре, очереди крафта, task.progress, task.progress_tick.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local schema = require("scripts.core.schema")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local reserve = require("scripts.core.reserve")
local path = require("scripts.lib.path")

local M = {}

M.MAX_QUEUE = 32               -- ждущих задач на помощника (PROTOCOL §4)
M.STUCK_TICKS = 60 * 60        -- 60 с без прогресса
M.CHECK_EVERY = 60             -- проверка прогресса раз в секунду
M.PROGRESS_EVERY = 5 * 60      -- job_progress не чаще раза в 5 с

M.actions = {}                 -- name -> модуль действия (не в storage)

--- Зарегистрировать модуль действия (из control.lua через init.register_action).
function M.register(mod)
  if type(mod) ~= "table" or type(mod.name) ~= "string" or mod.name == "" then
    error("jobs.register: action module without name", 2)
  end
  for _, f in ipairs({ "start", "tick", "stop" }) do
    if type(mod[f]) ~= "function" then error("jobs.register: action " .. mod.name .. " has no " .. f, 2) end
  end
  if M.actions[mod.name] then error("jobs.register: action " .. mod.name .. " registered twice", 2) end
  M.actions[mod.name] = mod
end

local function J() return storage.jobs end

function M.queue_of(helper, create)
  local q = J().by_helper[helper]
  if q == nil and create then
    q = { active = nil, queue = {} }
    J().by_helper[helper] = q
  end
  return q
end

--- Активная задача помощника (task) или nil. Для чтения (state, helper_list).
function M.active(helper)
  local q = J().by_helper[helper]
  return q and q.active or nil
end

function M.queue_len(helper)
  local q = J().by_helper[helper]
  return q and #q.queue or 0
end

-- ------------------------------------------------------------------ ctx

--- ctx для действий (ACTIONS.md «Интерфейс модуля действия»).
function M.make_ctx(helper, entity, tick)
  local ctx = { helper_id = helper, entity = entity, tick = tick or game.tick }
  ctx.emit = function(kind, data, opts) return events.emit(helper, kind, data, opts) end
  ctx.approach = function(task, goal_pos, distance) return path.step(task, ctx, goal_pos, distance) end
  ctx.cancel_approach = function(task) return path.cancel(task, ctx) end
  return ctx
end

-- ------------------------------------------------------------------ завершение

local function normalize_result(res)
  if type(res) ~= "table" then
    return { status = "failed", code = "internal", text = "action returned a non-table result", detail = {} }
  end
  local status = res.status
  if status ~= "done" and status ~= "failed" then
    return { status = "failed", code = "internal", text = "action returned bad status", detail = {} }
  end
  local out = { status = status, detail = util.plain(res.detail) or {} }
  if status == "failed" then
    out.code = err.CODES[res.code] and res.code or "internal"
    out.text = err.clean_text(res.text or out.code)
  end
  return out
end

local function safe_stop(task, ctx)
  local mod = M.actions[task["do"]]
  if not mod then return end
  local ok, e = pcall(mod.stop, task, ctx)
  if not ok then log("[factorio-partner] stop " .. tostring(task["do"]) .. " failed: " .. err.clean_text(err.is(e) and e.text or e)) end
end

local function emit_result(task, res)
  if res.status == "done" then
    events.emit(task.helper, "job_done", { job = task.job, ["do"] = task["do"], detail = res.detail })
  else
    events.emit(task.helper, "job_failed", {
      job = task.job, ["do"] = task["do"], code = res.code, text = res.text, detail = res.detail,
    })
  end
end

--- Завершить активную задачу q.active результатом res (уже нормализован или сырой).
--- stop вызывается для любого failed (отмена, сбой, застревание, failed от модуля).
local function finish_active(q, res, ctx)
  local task = q.active
  if task == nil then return end
  res = normalize_result(res)
  q.active = nil
  if res.status == "failed" then safe_stop(task, ctx) end
  reserve.release_area(task.helper)
  emit_result(task, res)
end

local function fail_result(code, text)
  return { status = "failed", code = code, text = text, detail = {} }
end

--- Снять все задачи помощника: активную (с stop) и очередь; каждой job_failed{code}.
--- Возвращает список номеров снятых задач.
function M.fail_all(helper, code, text, entity)
  local q = J().by_helper[helper]
  local done = {}
  if q == nil then return done end
  if q.active then
    local ctx = M.make_ctx(helper, entity, game.tick)
    done[#done + 1] = q.active.job
    finish_active(q, fail_result(code, text), ctx)
  end
  local queue = q.queue
  q.queue = {}
  for _, task in ipairs(queue) do
    done[#done + 1] = task.job
    emit_result(task, normalize_result(fail_result(code, text)))
  end
  return done
end

-- ------------------------------------------------------------------ прогресс и «застрял»

local function signature(task, entity)
  local inv = entity.get_main_inventory and entity.get_main_inventory()
  local inv_n = inv and inv.get_item_count() or 0
  local p = task.progress
  local pd, pt = "", ""
  if type(p) == "table" then pd, pt = tostring(p.done), tostring(p.total) end
  return table.concat({
    tostring(inv_n), tostring(entity.crafting_queue_size or 0), tostring(entity.crafting_queue_progress or 0),
    pd, pt, tostring(task.progress_tick or ""),
  }, "|")
end

local function mark(task, entity, tick)
  task._mark = { tick = tick, pos = util.xy(entity.position), sig = signature(task, entity) }
end

--- true — задача застряла.
local function check_stuck(task, entity, tick)
  local m = task._mark
  if m == nil then mark(task, entity, tick) return false end
  local pos = util.xy(entity.position)
  local sig = signature(task, entity)
  if util.dist(pos, m.pos) >= 0.1 or sig ~= m.sig then
    task._mark = { tick = tick, pos = pos, sig = sig }
    return false
  end
  return tick - m.tick >= M.STUCK_TICKS
end

local function maybe_progress(task, tick)
  local p = task.progress
  if type(p) ~= "table" then return end
  local key = tostring(p.done) .. "/" .. tostring(p.total)
  if key == task._progress_key then return end
  local last = task._progress_tick
  if last ~= nil and tick - last < M.PROGRESS_EVERY then return end
  task._progress_key = key
  task._progress_tick = tick
  local data = util.plain(p) or {}
  data.job = task.job
  events.emit(task.helper, "job_progress", data)
end

-- ------------------------------------------------------------------ тик

local function step(helper, q, entity, tick)
  -- простой помощник: ctx (3 замыкания) не создаём
  if q.active == nil and q.queue[1] == nil then return end
  local ctx = M.make_ctx(helper, entity, tick)
  local task = q.active
  if task == nil then
    task = table.remove(q.queue, 1)
    if task == nil then return end
    q.active = task
    task.started_tick = tick
    mark(task, entity, tick)
    local mod = M.actions[task["do"]]
    if mod == nil then
      finish_active(q, fail_result("internal", "action " .. tostring(task["do"]) .. " is not registered"), ctx)
      return
    end
    local ok, res = pcall(mod.start, task, ctx)
    if not ok then
      local code, text = err.normalize(res)
      finish_active(q, fail_result(code, text), ctx)
    elseif res ~= nil then
      finish_active(q, res, ctx)
    end
    return
  end
  local mod = M.actions[task["do"]]
  if mod == nil then
    finish_active(q, fail_result("internal", "action " .. tostring(task["do"]) .. " is not registered"), ctx)
    return
  end
  local ok, res = pcall(mod.tick, task, ctx)
  if not ok then
    local code, text = err.normalize(res)
    finish_active(q, fail_result(code, text), ctx)
    return
  end
  if res ~= nil then
    finish_active(q, res, ctx)
    return
  end
  maybe_progress(task, tick)
  if (tick - task.started_tick) % M.CHECK_EVERY == 0 and check_stuck(task, entity, tick) then
    finish_active(q, fail_result("stuck", "no progress for 60 s"), ctx)
  end
end

function M.on_tick(e)
  local tick = e.tick
  for helper, q in pairs(J().by_helper) do
    if q.active ~= nil or q.queue[1] ~= nil then
      local rec, entity = registry.alive(helper)
      if rec == nil then
        M.fail_all(helper, "no_helper", "helper is absent or dead", nil)
      else
        step(helper, q, entity, tick)
      end
    end
  end
end

-- ------------------------------------------------------------------ операции

local ACT_SCHEMA = {
  ["do"] = { type = "string", required = true, max = 40 },
  args = { type = "any" },
  replace = { type = "bool", default = false },
}

function M.op_act(args, ctx)
  local a = schema.validate(ACT_SCHEMA, args)
  local name = a["do"]
  local mod = M.actions[name]
  if mod == nil then err.raise("bad_args", "args.do: unknown action " .. name) end
  local targs = a.args
  if targs ~= nil and type(targs) ~= "table" then err.raise("bad_args", "args.args: expected object") end
  targs = schema.validate(mod.schema or {}, targs or {}, "args.args")
  if a.replace and name == "wait" then
    err.raise("bad_args", "args.replace: wait never replaces the queue")
  end
  local helper = ctx.helper_id
  local q = M.queue_of(helper, true)
  if a.replace then
    M.fail_all(helper, "cancelled", "replaced by job from " .. tostring(ctx.request_id), ctx.entity)
  elseif #q.queue >= M.MAX_QUEUE then
    err.raise("limit", "queue is full (" .. M.MAX_QUEUE .. ")")
  end
  local queued_before = (q.active and 1 or 0) + #q.queue
  local jobs = J()
  local task = {
    job = jobs.next_job, helper = helper, ["do"] = name, args = targs, req = ctx.request_id,
    created_tick = game.tick,
  }
  jobs.next_job = jobs.next_job + 1
  q.queue[#q.queue + 1] = task
  return { job = task.job, queued_before = queued_before }
end

local CANCEL_SCHEMA = {
  job = { type = "int", min = 1 },
  all = { type = "bool" },
}

function M.op_cancel(args, ctx)
  local a = schema.validate(CANCEL_SCHEMA, args)
  local helper = ctx.helper_id
  if a.all then
    return { cancelled = M.fail_all(helper, "cancelled", "cancelled", ctx.entity) }
  end
  if a.job == nil then err.raise("bad_args", "args: job or all=true required") end
  local q = M.queue_of(helper, false)
  if q and q.active and q.active.job == a.job then
    finish_active(q, fail_result("cancelled", "cancelled"), M.make_ctx(helper, ctx.entity, game.tick))
    return { cancelled = { a.job } }
  end
  if q then
    for i, task in ipairs(q.queue) do
      if task.job == a.job then
        table.remove(q.queue, i)
        emit_result(task, normalize_result(fail_result("cancelled", "cancelled")))
        return { cancelled = { a.job } }
      end
    end
  end
  err.raise("not_found", "job " .. a.job .. " is not active or queued")
end

local function progress_of(task)
  local p = task.progress
  if type(p) ~= "table" then return nil end
  return util.plain(p)
end

function M.op_jobs(args, ctx)
  schema.validate({}, args)
  local q = M.queue_of(ctx.helper_id, false)
  local out = { queue = {} }
  if q == nil then return out end
  if q.active then
    local t = q.active
    out.active = { job = t.job, ["do"] = t["do"], since = t.started_tick, progress = progress_of(t), req = t.req }
  end
  for _, t in ipairs(q.queue) do
    out.queue[#out.queue + 1] = { job = t.job, ["do"] = t["do"], req = t.req }
  end
  return out
end

return M
