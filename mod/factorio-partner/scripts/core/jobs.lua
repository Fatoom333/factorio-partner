-- Очередь задач. Контракт: docs/ACTIONS.md, PROTOCOL.md §4 (act/cancel/jobs).
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
--
-- Необязательные функции модуля (ядро зовёт их, если они есть):
--   M.check_args(args, ctx) -> args   — проверка, которую не выразить схемой (после schema.validate);
--   M.emit_result(task, res)          — своё событие итога вместо job_done/job_failed (plan -> plan_done);
--   M.resume_args(task) -> args|nil   — аргументы, с которыми задачу продолжают с места (возврат flee);
--   M.at_boundary(task) -> bool       — cancel{at_boundary}: true — модуль сам закончит задачу на границе шага.
-- stop получает третьим аргументом итог задачи (res), если он известен.
-- Преемник: task.after = номер задачи, сразу за которой эта стоит в очереди (args.after у plan).
-- Предшественник закончился отказом — его преемники снимаются (cancelled).
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local schema = require("scripts.core.schema")
local perms = require("scripts.core.perms")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local reserve = require("scripts.core.reserve")
local path = require("scripts.lib.path")

local M = {}

M.MAX_QUEUE = 32               -- ждущих задач на помощника (PROTOCOL §4)
M.STUCK_TICKS = 60 * 60        -- 60 с без прогресса
M.CHECK_EVERY = 60             -- проверка прогресса раз в секунду
M.PROGRESS_EVERY = 5 * 60      -- job_progress не чаще раза в 5 с
M.RECENT = 8                   -- итогов последних задач помнится на помощника (для after)

M.actions = {}                 -- name -> модуль действия (не в storage)

-- Тело-игрок (PROTOCOL §7 «Два вида тела»): scripts/core/attach.lua ставит сюда свои
-- функции. before_tick(tick) — до действий (сверка с игроком, удержание ходьбы и добычи),
-- after_tick(tick) — после них (запомнить состояния). Ошибки внутри они ловят сами.
M.body_hooks = { before_tick = nil, after_tick = nil }

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

--- hold хозяина у помощника (запись storage.owner_hold[id] = {kind, tick, seq}) или nil.
--- Рефлексы, которые сами что-то делают руками помощника (ammo, upkeep), при hold молчат.
function M.held(helper)
  local all = storage.owner_hold
  return all and all[helper] or nil
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

function M.normalize_result(res)
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
local normalize_result = M.normalize_result

--- stop может вернуть таблицу простых полей — они дописываются в detail итога (то, что известно
--- только после уборки: например, сколько своих пометок к сносу снято). Поля итога не затираются.
local function safe_stop(task, ctx, res)
  local mod = M.actions[task["do"]]
  if not mod then return end
  local ok, e = pcall(mod.stop, task, ctx, res)
  if not ok then err.count_module_error("stop " .. tostring(task["do"]), e) end
  if ok and res ~= nil and type(e) == "table" then
    local extra = util.plain(e, 2)
    if type(res.detail) ~= "table" then res.detail = {} end
    for k, v in pairs(extra or {}) do
      if type(k) == "string" and res.detail[k] == nil then res.detail[k] = v end
    end
  end
  if not ok then log("[factorio-partner] stop " .. tostring(task["do"]) .. " failed: " .. err.clean_text(err.is(e) and e.text or e)) end
end
--- Для контейнеров задач (plan): остановить вложенную задачу так же, как ядро — свою.
M.stop_task = safe_stop

-- Задачи домашних дел (рефлекс upkeep) завершаются тихо: агента будит только отказ.
local QUIET_DONE = { ["reflex:upkeep"] = true, ["reflex:evacuate"] = true }

local function emit_result(task, res)
  local mod = M.actions[task["do"]]
  if mod ~= nil and mod.emit_result ~= nil then
    local ok, e = pcall(mod.emit_result, task, res)
    if ok then return end
    err.count_module_error("emit_result " .. tostring(task["do"]), e)
    log("[factorio-partner] emit_result " .. tostring(task["do"]) .. " failed: " .. err.clean_text(err.is(e) and e.text or e))
  end
  if res.status == "done" then
    events.emit(task.helper, "job_done", { job = task.job, ["do"] = task["do"], detail = res.detail },
      QUIET_DONE[task.req] and { loud = false } or nil)
  else
    events.emit(task.helper, "job_failed", {
      job = task.job, ["do"] = task["do"], code = res.code, text = res.text, detail = res.detail,
    })
  end
end

--- Завершить активную задачу q.active результатом res (уже нормализован или сырой).
--- stop вызывается для любого failed (отмена, сбой, застревание, failed от модуля).
local function fail_result(code, text)
  return { status = "failed", code = code, text = text, detail = {} }
end

local function remember(q, job, ok)
  local r = q.recent
  if r == nil then
    r = {}
    q.recent = r
  end
  r[#r + 1] = { job = job, ok = ok }
  while #r > M.RECENT do table.remove(r, 1) end
end

--- Снять из очереди преемников задачи job (и их преемников): предшественник не доделан.
local function drop_successors(q, job)
  local gone = { [job] = true }
  local i = 1
  while i <= #q.queue do
    local t = q.queue[i]
    if t.after ~= nil and gone[t.after] then
      table.remove(q.queue, i)
      gone[t.job] = true
      remember(q, t.job, false)
      emit_result(t, normalize_result(fail_result("cancelled", "predecessor job " .. tostring(t.after) .. " failed")))
    else
      i = i + 1
    end
  end
end

local function finish_active(q, res, ctx)
  local task = q.active
  if task == nil then return end
  res = normalize_result(res)
  q.active = nil
  if res.status == "failed" then safe_stop(task, ctx, res) end
  reserve.release_area(task.helper)
  remember(q, task.job, res.status == "done")
  emit_result(task, res)
  if res.status == "failed" then drop_successors(q, task.job) end
end

--- Снять все задачи помощника: активную (с stop) и очередь; каждой job_failed{code}.
--- Возвращает список номеров снятых задач.
function M.fail_all(helper, code, text, entity)
  local q = J().by_helper[helper]
  local done = {}
  if q == nil then return done end
  -- очередь снимается до активной: её преемники получают тот же код, а не «predecessor failed»
  local queue = q.queue
  q.queue = {}
  if q.active then
    local ctx = M.make_ctx(helper, entity, game.tick)
    done[#done + 1] = q.active.job
    finish_active(q, fail_result(code, text), ctx)
  end
  for _, task in ipairs(queue) do
    done[#done + 1] = task.job
    remember(q, task.job, false)
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
  local key = tostring(p.done) .. "/" .. tostring(p.total) .. "/" .. tostring(p.step or "")
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
      if code == "internal" then err.count_module_error("start " .. tostring(task["do"]), res) end
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
    if code == "internal" then err.count_module_error("tick " .. tostring(task["do"]), res) end
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
  local hooks = M.body_hooks
  if hooks.before_tick then hooks.before_tick(tick) end
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
  if hooks.after_tick then hooks.after_tick(tick) end
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
  if mod.check_args ~= nil then targs = mod.check_args(targs, ctx) end
  -- разрешения хозяина (scripts/core/perms.lua): нельзя — отказ всегда, спросить — нужен owner_ok
  perms.enforce(mod, targs, ctx)
  if a.replace and name == "wait" then
    err.raise("bad_args", "args.replace: wait never replaces the queue")
  end
  -- преемник: args.after (у plan) — номер задачи, за которой встать; в args он не остаётся
  local after = targs.after
  targs.after = nil
  if after ~= nil and a.replace then
    err.raise("bad_args", "args.replace: a successor (args.after) never replaces the queue")
  end
  local helper = ctx.helper_id
  -- hold хозяина (scripts/core/owner_words.lua): новые задачи не берутся, пока он не скажет продолжать.
  -- Пропускается только то, что вызывающий код пометил ctx.owner_hold_ok (отступление flee): это поле
  -- ставит только код мода, из запроса по RCON оно не приходит.
  local hold = M.held(helper)
  if hold ~= nil and ctx.owner_hold_ok ~= true then
    err.raise("owner_hold", "the owner said " .. tostring(hold.kind) .. "; wait for his next word")
  end
  local q = M.queue_of(helper, true)
  if a.replace then
    M.fail_all(helper, "cancelled", "replaced by job from " .. tostring(ctx.request_id), ctx.entity)
  elseif #q.queue >= M.MAX_QUEUE then
    err.raise("limit", "queue is full (" .. M.MAX_QUEUE .. ")")
  end
  local pos = #q.queue + 1
  if after ~= nil then pos = M.successor_pos(q, after) end
  local queued_before = (q.active and 1 or 0) + pos - 1
  local jobs = J()
  local task = {
    job = jobs.next_job, helper = helper, ["do"] = name, args = targs, req = ctx.request_id,
    created_tick = game.tick, after = after,
    perm_gate = ctx.perm_gate == true or nil,
    owner_ok = (ctx.perm_gate == true and type(ctx.owner_ok) == "table" and util.plain(ctx.owner_ok)) or nil,
  }
  jobs.next_job = jobs.next_job + 1
  table.insert(q.queue, pos, task)
  return { job = task.job, queued_before = queued_before }
end

--- Место преемника задачи job в очереди q: сразу за ней (и за её прежними преемниками).
--- job активна или недавно закончилась удачно → начало очереди; закончилась отказом → not_found
--- (предшественник не доделан, преемнику не с чего начинать); неизвестна → not_found.
function M.successor_pos(q, job)
  local pos
  if q.active ~= nil and q.active.job == job then
    pos = 1
  else
    for i, t in ipairs(q.queue) do
      if t.job == job then pos = i + 1 break end
    end
  end
  if pos == nil then
    local recent = q.recent or {}
    for i = #recent, 1, -1 do
      if recent[i].job == job then
        if not recent[i].ok then
          err.raise("not_found", "args.args.after: job " .. job .. " failed; its successor is not queued")
        end
        pos = 1
        break
      end
    end
  end
  if pos == nil then
    err.raise("not_found", "args.args.after: job " .. job .. " is not active, queued or recently finished")
  end
  while q.queue[pos] ~= nil and q.queue[pos].after == job do pos = pos + 1 end
  return pos
end

local CANCEL_SCHEMA = {
  job = { type = "int", min = 1 },
  all = { type = "bool" },
  at_boundary = { type = "bool", default = false },
}

function M.op_cancel(args, ctx)
  local a = schema.validate(CANCEL_SCHEMA, args)
  local helper = ctx.helper_id
  if a.all then
    return { cancelled = M.fail_all(helper, "cancelled", "cancelled", ctx.entity) }
  end
  if a.job == nil then err.raise("bad_args", "args: job or all=true required") end
  local q = M.queue_of(helper, false)
  if a.at_boundary and q and q.active and q.active.job == a.job then
    -- контейнер шагов (plan) доделывает текущий шаг и заканчивается сам; прочие задачи — как обычно
    local mod = M.actions[q.active["do"]]
    if mod ~= nil and mod.at_boundary ~= nil and mod.at_boundary(q.active) then
      return { cancelled = { a.job }, at_boundary = true }
    end
  end
  if q and q.active and q.active.job == a.job then
    finish_active(q, fail_result("cancelled", "cancelled"), M.make_ctx(helper, ctx.entity, game.tick))
    return { cancelled = { a.job } }
  end
  if q then
    for i, task in ipairs(q.queue) do
      if task.job == a.job then
        table.remove(q.queue, i)
        remember(q, task.job, false)
        emit_result(task, normalize_result(fail_result("cancelled", "cancelled")))
        drop_successors(q, task.job)
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
    out.queue[#out.queue + 1] = { job = t.job, ["do"] = t["do"], req = t.req, after = t.after }
  end
  return out
end

return M
