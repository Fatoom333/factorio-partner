-- Действие `plan`: длинный план — до 200 обычных действий одной задачей очереди.
-- Контракт: docs/ACTIONS.md («plan»), docs/EVENTS.md («plan_done»).
--
-- args: steps:[{do, args?, on_fail?}] (1..200) │ blob (id из blob_put: JSON-массив тех же шагов),
--       on_fail?="stop"│"continue" (правило при отказе шага; у шага может быть своё),
--       from_step?=1 (начать с этого шага; так продолжает план возврат после отступления),
--       after?:job (преемник: встать в очередь сразу за задачей job; ядро, scripts/core/jobs.lua).
-- Шаг — обычное действие act: те же схема и проверки (вложенный plan нельзя). Шаги идут по
-- очереди без хода агента; следующий начинается на тике после конца предыдущего.
--
-- Состояние в task (переживает сохранение): i — номер текущего шага, cur — задача текущего шага
-- (та же форма, что у задачи очереди: job, helper, do, args, req, started_tick, …своё модуля),
-- marks — {[i] = "d"│"f"│"s"}, fails — отказы шагов, last — итог последнего удачного шага,
-- inv0 — содержимое основного инвентаря на старте (для inventory_delta).
--
-- Итог — одно событие plan_done (вместо job_done/job_failed): status "done" — план дошёл до
-- конца (с on_fail="continue" — даже если шаги отказали); "failed" — план оборван: отказ шага при
-- on_fail="stop", отмена (cancel, replace, слово хозяина «стоп», отступление flee), застревание,
-- пропажа тела. Оборванный шаг — "f" с кодом обрыва, не начатые — "s".
-- Прогресс: task.progress = {done = шагов позади, total = шагов, step, steps, do} → job_progress.
-- «Застрял» ядро считает по плану целиком: смена шага, прогресс и «пульс» шага переносятся в план.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local schema = require("scripts.core.schema")
local events = require("scripts.core.events")
local blobs = require("scripts.core.blobs")
local registry = require("scripts.core.registry")
local reserve = require("scripts.core.reserve")
local jobs = require("scripts.core.jobs")
local inventory = require("scripts.lib.inventory")

local M = {}
M.name = "plan"

M.MAX_STEPS = 200
M.MAX_FAILS = 10           -- отказов шагов в plan_done (счётчик — все)
M.MAX_DELTA = 20           -- видов предметов в inventory_delta
M.MAX_DETAIL = 400         -- байт JSON на detail шага в plan_done (больше — detail = {truncated=true})
M.MAX_EVENT = 3800         -- plan_done целиком (буфер ужимает события больше 4000 байт)

local ON_FAIL = { type = "enum", values = { "stop", "continue" } }
local STEP = {
  type = "object",
  fields = {
    ["do"] = { type = "string", required = true, max = 40 },
    args = { type = "any" },
    on_fail = ON_FAIL,
  },
}
local STEPS = { type = "list", max = M.MAX_STEPS, of = STEP }

M.schema = {
  steps = STEPS,
  blob = { type = "string", max = 32, pattern = "^[a-z0-9%-]+$" },
  on_fail = { type = "enum", values = { "stop", "continue" }, default = "stop" },
  from_step = { type = "int", min = 1, max = M.MAX_STEPS },
  after = { type = "int", min = 1 },
}

-- ------------------------------------------------------------------ проверка

local function steps_from_blob(id)
  local str, received, total = blobs.get(id)
  if str == nil then
    err.raise("bad_args", "args.args.blob: blob " .. id .. " is not complete (" .. tostring(received) .. "/" ..
      tostring(total) .. " parts); send it with blob_put")
  end
  local ok, t = pcall(helpers.json_to_table, str)
  if not ok or type(t) ~= "table" then err.raise("bad_args", "args.args.blob: not a JSON list of steps") end
  return schema.validate({ steps = STEPS }, { steps = t }, "args.args").steps
end

--- Проверка шагов: каждый — как отдельный act (схема действия и его check_args).
function M.check_args(a, ctx)
  if (a.steps ~= nil) == (a.blob ~= nil) then err.raise("bad_args", "args.args: one of steps / blob is required") end
  local steps = a.steps
  if a.blob ~= nil then
    steps = steps_from_blob(a.blob)
    a.blob = nil
  end
  if #steps == 0 then err.raise("bad_args", "args.args.steps: at least one step") end
  for i, s in ipairs(steps) do
    local path = "args.args.steps[" .. i .. "]"
    local name = s["do"]
    if name == M.name then err.raise("bad_args", path .. ".do: a plan cannot hold a plan") end
    local mod = jobs.actions[name]
    if mod == nil then err.raise("bad_args", path .. ".do: unknown action " .. name) end
    if s.args ~= nil and type(s.args) ~= "table" then err.raise("bad_args", path .. ".args: expected object") end
    local sargs = schema.validate(mod.schema or {}, s.args or {}, path .. ".args")
    if mod.check_args ~= nil then sargs = mod.check_args(sargs, ctx) end
    s.args = sargs
  end
  if a.from_step ~= nil and a.from_step > #steps then
    err.raise("bad_args", "args.args.from_step: the plan has " .. #steps .. " steps")
  end
  a.steps = steps
  return a
end

-- ------------------------------------------------------------------ ход плана

local function first_step(task) return task.args.from_step or 1 end

local function main_counts(entity)
  if entity == nil or not entity.valid then return nil end
  local ok, inv = pcall(entity.get_main_inventory)
  if not ok or inv == nil then return nil end
  return inventory.counts(inv)
end

local function set_progress(task, tick)
  local n = #task.args.steps
  local step = task.args.steps[task.i]
  task.progress = { done = task.i - 1, total = n, step = task.i, steps = n, ["do"] = step and step["do"] or nil }
  task.progress_tick = tick
end

local function step_rule(task, i)
  local s = task.args.steps[i]
  return (s and s.on_fail) or task.args.on_fail or "stop"
end

--- Короткий detail шага для plan_done: большой — {truncated=true}.
local function small_detail(d)
  d = util.plain(d, 4)
  if type(d) ~= "table" then return nil end
  local ok, json = pcall(helpers.table_to_json, d)
  if not ok then return nil end
  if #json > M.MAX_DETAIL then return { truncated = true } end
  return d
end

--- Записать итог текущего шага (res нормализован). → итог плана, если план на этом кончается.
local function record(task, res)
  local i = task.i
  task.cur = nil
  if res.status == "done" then
    task.marks[i] = "d"
    task.last = { step = i, ["do"] = task.args.steps[i]["do"], detail = small_detail(res.detail) }
    return nil
  end
  task.marks[i] = "f"
  task.nfail = (task.nfail or 0) + 1
  if #task.fails < M.MAX_FAILS then
    task.fails[#task.fails + 1] = {
      step = i, ["do"] = task.args.steps[i]["do"], code = res.code, text = res.text, detail = small_detail(res.detail),
    }
  end
  if step_rule(task, i) == "stop" then
    return {
      status = "failed", code = res.code,
      text = "step " .. i .. " (" .. tostring(task.args.steps[i]["do"]) .. "): " .. tostring(res.text),
      detail = {},
    }
  end
  return nil
end

--- Итог шага от модуля: нормализовать, у отказа — stop шага, снять резерв места.
local function step_done(task, ctx, raw)
  local res = jobs.normalize_result(raw)
  if res.status == "failed" then jobs.stop_task(task.cur, ctx, res) end
  reserve.release_area(task.helper)
  return record(task, res)
end

local function step_error(task, ctx, e)
  local code, text = err.normalize(e)
  if code == "internal" then err.count_module_error() end
  return step_done(task, ctx, { status = "failed", code = code, text = text, detail = {} })
end

--- Начать следующий шаг. → итог плана или nil.
local function begin_next(task, ctx)
  if task.boundary_stop then
    return { status = "failed", code = "cancelled", text = "cancelled at a step boundary", detail = {} }
  end
  local hold = jobs.held(task.helper)
  if hold ~= nil then
    return { status = "failed", code = "owner_hold", text = "the owner said " .. tostring(hold.kind), detail = {} }
  end
  task.i = task.i + 1
  local steps = task.args.steps
  if task.i > #steps then return { status = "done", detail = {} } end
  local step = steps[task.i]
  local mod = jobs.actions[step["do"]]
  set_progress(task, ctx.tick)
  local sub = {
    job = task.job, helper = task.helper, ["do"] = step["do"], args = util.copy(step.args or {}),
    req = task.req, created_tick = task.created_tick, started_tick = ctx.tick, plan_step = task.i,
  }
  task.cur = sub
  if mod == nil then
    return step_done(task, ctx, { status = "failed", code = "internal",
      text = "action " .. tostring(step["do"]) .. " is not registered", detail = {} })
  end
  local ok, res = pcall(mod.start, sub, ctx)
  if not ok then return step_error(task, ctx, res) end
  if res ~= nil then return step_done(task, ctx, res) end
  return nil
end

function M.start(task, ctx)
  task.i = first_step(task) - 1
  task.marks = {}
  task.fails = {}
  task.inv0 = main_counts(ctx.entity)
  return begin_next(task, ctx)
end

--- Перенести в план прогресс и «пульс» шага: ядро следит за «застрял» по задаче плана.
local function carry_progress(task, sub, tick)
  if sub.progress_tick ~= nil and sub.progress_tick ~= task._sub_pulse then
    task._sub_pulse = sub.progress_tick
    task.progress_tick = tick
  end
  local p = sub.progress
  if type(p) == "table" then
    local key = tostring(p.done) .. "/" .. tostring(p.total)
    if key ~= task._sub_key then
      task._sub_key = key
      task.progress_tick = tick
    end
  end
end

function M.tick(task, ctx)
  local sub = task.cur
  if sub == nil then return begin_next(task, ctx) end
  local mod = jobs.actions[sub["do"]]
  if mod == nil then
    return step_done(task, ctx, { status = "failed", code = "internal",
      text = "action " .. tostring(sub["do"]) .. " is not registered", detail = {} })
  end
  local ok, res = pcall(mod.tick, sub, ctx)
  if not ok then return step_error(task, ctx, res) end
  if res ~= nil then return step_done(task, ctx, res) end
  carry_progress(task, sub, ctx.tick)
  return nil
end

--- План оборван снаружи (отмена, «стоп», отступление, застревание, тело пропало) или своим
--- отказом шага (тогда текущего шага уже нет). Текущий шаг останавливается как задача очереди.
function M.stop(task, ctx, res)
  local sub = task.cur
  if sub == nil then return end
  local why = res or { status = "failed", code = "cancelled", text = "cancelled", detail = {} }
  jobs.stop_task(sub, ctx, why)
  task.cur = nil
  if task.marks ~= nil then
    task.marks[task.i] = "f"
    task.nfail = (task.nfail or 0) + 1
    if #task.fails < M.MAX_FAILS then
      task.fails[#task.fails + 1] = { step = task.i, ["do"] = sub["do"], code = why.code, text = why.text }
    end
  end
end

--- cancel{job, at_boundary:true}: доделать текущий шаг и закончить план.
function M.at_boundary(task)
  task.boundary_stop = true
  return true
end

--- Аргументы, чтобы продолжить план с текущего шага (возврат после отступления flee).
--- Текущий шаг mine по resource/item — с остатком count, как у отдельной задачи.
function M.resume_args(task)
  local a = task.args
  if type(a) ~= "table" or type(a.steps) ~= "table" then return nil end
  local i
  if task.i == nil then
    i = a.from_step or 1 -- план ещё не начат (ждал в очереди)
  else
    i = math.max(task.i, a.from_step or 1)
    -- шаг уже закончился, следующий начнётся на следующем тике
    if task.cur == nil and task.marks ~= nil and task.marks[i] ~= nil then i = i + 1 end
  end
  if i > #a.steps then return nil end
  local out = { steps = util.copy(a.steps), on_fail = a.on_fail, from_step = i }
  local sub = task.cur
  local s = out.steps[i]
  if sub ~= nil and s["do"] == "mine" and type(s.args) == "table" and type(s.args.count) == "number"
      and (s.args.resource or s.args.item) then
    local done = type(sub.progress) == "table" and sub.progress.done
    if type(done) == "number" and done > 0 then s.args.count = math.max(1, s.args.count - done) end
  end
  return out
end

-- ------------------------------------------------------------------ итог

local function delta(before, after)
  if before == nil or after == nil then return nil end
  local list = {}
  for name, n in pairs(after) do
    local d = n - (before[name] or 0)
    if d ~= 0 then list[#list + 1] = { name, d } end
  end
  for name, n in pairs(before) do
    if after[name] == nil then list[#list + 1] = { name, -n } end
  end
  table.sort(list, function(x, y)
    if math.abs(x[2]) ~= math.abs(y[2]) then return math.abs(x[2]) > math.abs(y[2]) end
    return x[1] < y[1]
  end)
  local out = {}
  for k = 1, math.min(#list, M.MAX_DELTA) do out[list[k][1]] = list[k][2] end
  return out, #list > M.MAX_DELTA
end

local function json_len(t)
  local ok, json = pcall(helpers.table_to_json, t)
  return ok and #json or math.huge
end

--- plan_done{job, do, status, code?, text?, steps, from_step?, done, failed, skipped, marks,
---           failures?, last?, inventory_delta?, delta_truncated?}
function M.data(task, res)
  local steps = type(task.args) == "table" and task.args.steps or {}
  local n = #steps
  local first = first_step(task)
  local marks = task.marks or {}
  local chars, done, failed, skipped = {}, 0, 0, 0
  for i = 1, n do
    local m = marks[i]
    if i < first then
      m = "-"
    elseif m == nil then
      m = "s"
      skipped = skipped + 1
    elseif m == "d" then
      done = done + 1
    else
      failed = failed + 1
    end
    chars[i] = m
  end
  local data = {
    job = task.job, ["do"] = M.name, status = res.status, steps = n,
    done = done, failed = failed, skipped = skipped, marks = table.concat(chars),
  }
  if first > 1 then data.from_step = first end
  if res.status == "failed" then
    data.code = res.code
    data.text = res.text
    data.at = task.i
  end
  if task.fails ~= nil and task.fails[1] ~= nil then data.failures = util.plain(task.fails) end
  if task.last ~= nil then data.last = util.plain(task.last) end
  if task.inv0 ~= nil then
    local _, entity = registry.alive(task.helper)
    local d, cut = delta(task.inv0, main_counts(entity))
    if d ~= nil and next(d) ~= nil then data.inventory_delta = d end
    if cut then data.delta_truncated = true end
  end
  -- в буфер событий не больше 4000 байт: сначала убираются detail шагов, потом лишние отказы
  if json_len(data) > M.MAX_EVENT then
    for _, f in ipairs(data.failures or {}) do f.detail = nil end
    if data.last then data.last.detail = nil end
  end
  while json_len(data) > M.MAX_EVENT and data.failures ~= nil and #data.failures > 1 do
    table.remove(data.failures)
  end
  return data
end

function M.emit_result(task, res)
  events.emit(task.helper, "plan_done", M.data(task, res))
end

return M
