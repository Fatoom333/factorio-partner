-- Длинный план (scripts/actions/plan.lua): шаги по очереди, plan_done, отказ шага, «стоп» хозяина,
-- cancel (сразу и на границе шага), преемник after, отступление flee, сохранение посреди плана.
-- Контракт: docs/ACTIONS.md «plan», docs/EVENTS.md «plan_done».
local S = require("stubs")
local B = require("stubs_b")
local H = require("stubs_h")

--- Тестовое действие вместо rotate: n — номер (для журнала), ticks — сколько тиков работает,
--- fail — код отказа в конце, pulse — держать «пульс», big — длинный текст и большой detail.
local function probe()
  local M = { name = "rotate", log = {} }
  M.schema = {
    n = { type = "int", min = 0, max = 10000, default = 0 },
    ticks = { type = "int", min = 0, max = 100000, default = 0 },
    fail = { type = "string", max = 40 },
    pulse = { type = "bool", default = true },
    big = { type = "bool", default = false },
  }
  local function result(task)
    local a = task.args
    if a.fail then
      return { status = "failed", code = a.fail, text = a.big and string.rep("x", 250) or "boom",
        detail = a.big and { junk = string.rep("y", 1000) } or { n = a.n } }
    end
    return { status = "done", detail = { n = a.n } }
  end
  function M.start(task, ctx)
    M.log[#M.log + 1] = "start:" .. task.args.n
    task.left = task.args.ticks
    if task.left <= 0 then return result(task) end
  end
  function M.tick(task, ctx)
    if task.args.pulse then task.progress_tick = ctx.tick end
    task.left = task.left - 1
    if task.left <= 0 then return result(task) end
  end
  function M.stop(task, ctx)
    M.log[#M.log + 1] = "stop:" .. task.args.n
  end
  return M
end

local function setup()
  local p = probe()
  B.setup{ load = { replace = { ["scripts.actions.rotate"] = p } } }
  return p
end

local function steps(n, extra)
  local out = {}
  for i = 1, n do
    local a = { n = i, ticks = 3 }
    for k, v in pairs((extra or {})[i] or {}) do a[k] = v end
    out[i] = { ["do"] = "rotate", args = a }
  end
  return out
end

local function plan(args, extra) return B.act("plan", args, extra) end

local function act_err(args, code)
  return S.err(S.req("act", { ["do"] = "plan", args = args }, "h1"), code)
end

local function done_of(job)
  for _, e in ipairs(B.events("plan_done")) do if e.data.job == job then return e end end
  return nil
end

local function run_plan(job, max)
  local res
  B.until_(function() res = done_of(job) return res ~= nil end, max or 5000)
  return res
end

local function starts(p)
  local out = {}
  for _, l in ipairs(p.log) do if l:sub(1, 6) == "start:" then out[#out + 1] = tonumber(l:sub(7)) end end
  return out
end

local function job_events(job)
  local out = {}
  for _, e in ipairs(B.events()) do
    if (e.kind == "job_done" or e.kind == "job_failed") and e.data.job == job then out[#out + 1] = e end
  end
  return out
end

S.suite("plan", {
  { "план из 20 шагов: по очереди без хода агента, одно plan_done, прогресс {step, steps}", function()
      local p = setup()
      local r = plan{ steps = steps(20, { [7] = { ticks = 400 } }) }
      S.eq(r.queued_before, 0)
      B.until_(function() local t = storage.jobs.by_helper.h1.active return t and t.i == 7 end, 500)
      local j = S.okr(S.req("jobs", {}, "h1"))
      S.eq(j.active["do"], "plan")
      S.eq(j.active.progress.step, 7)
      S.eq(j.active.progress.steps, 20)
      S.eq(j.active.progress.done, 6)
      S.eq(j.active.progress["do"], "rotate")
      local ev = run_plan(r.job)
      S.eq(starts(p), { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 })
      S.eq(ev.loud, true, "plan_done будит агента")
      local d = ev.data
      S.eq({ d.status, d.steps, d.done, d.failed, d.skipped }, { "done", 20, 20, 0, 0 })
      S.eq(d.marks, string.rep("d", 20))
      S.eq(d["do"], "plan")
      S.eq(d.last, { step = 20, ["do"] = "rotate", detail = { n = 20 } })
      S.eq(d.code, nil)
      S.eq(#B.events("plan_done"), 1)
      S.eq(#job_events(r.job), 0, "job_done у плана нет — только plan_done")
      local prog = B.events("job_progress")
      S.ok(#prog >= 1, "есть job_progress")
      S.eq(prog[1].data.job, r.job)
      S.eq(prog[1].data.steps, 20)
      S.ok(type(prog[1].data.step) == "number")
      S.eq(storage.jobs.by_helper.h1.active, nil)
  end },
  { "проверка шагов при постановке: неизвестное действие, вложенный план, аргументы шага, границы", function()
      setup()
      S.ok(act_err({ steps = { { ["do"] = "fly" } } }, "bad_args").text:find("steps[1].do", 1, true))
      S.ok(act_err({ steps = { { ["do"] = "plan", args = { steps = steps(1) } } } }, "bad_args").text:find("plan", 1, true))
      local e = act_err({ steps = { { ["do"] = "rotate" }, { ["do"] = "rotate", args = { zzz = 1 } } } }, "bad_args")
      S.ok(e.text:find("args.args.steps[2].args.zzz", 1, true), e.text)
      act_err({ steps = { { ["do"] = "rotate", args = { n = 99999 } } } }, "limit")
      act_err({ steps = { { ["do"] = "rotate", args = "x" } } }, "bad_args")
      act_err({ steps = {} }, "bad_args")
      act_err({}, "bad_args")
      act_err({ steps = steps(1), blob = "abc" }, "bad_args")
      act_err({ steps = steps(2), from_step = 3 }, "bad_args")
      act_err({ steps = steps(2), on_fail = "maybe" }, "bad_args")
      act_err({ steps = { { ["do"] = "rotate", on_fail = "maybe" } } }, "bad_args")
      act_err({ steps = { { ["do"] = "rotate", extra = 1 } } }, "bad_args")
      local many = {}
      for i = 1, 201 do many[i] = { ["do"] = "wait", args = { seconds = 1 } } end
      act_err({ steps = many }, "limit")
      -- шаг wait проверяется своей схемой
      act_err({ steps = { { ["do"] = "wait", args = { seconds = 0 } } } }, "bad_args")
      local q = storage.jobs.by_helper.h1
      S.ok(q == nil or (q.active == nil and q.queue[1] == nil), "ничего не встало")
  end },
  { "отказ шага: по умолчанию план стоит, остаток пропущен; stop шага позван", function()
      local p = setup()
      local r = plan{ steps = steps(5, { [3] = { fail = "no_items" } }) }
      local ev = run_plan(r.job)
      S.eq(starts(p), { 1, 2, 3 })
      S.eq(p.log[#p.log], "stop:3", "у отказавшего шага позван stop")
      local d = ev.data
      S.eq({ d.status, d.code, d.at, d.done, d.failed, d.skipped, d.marks }, { "failed", "no_items", 3, 2, 1, 2, "ddfss" })
      S.ok(d.text:find("step 3 (rotate): boom", 1, true), d.text)
      S.eq(d.failures, { { step = 3, ["do"] = "rotate", code = "no_items", text = "boom", detail = { n = 3 } } })
      B.tick(30)
      S.eq(starts(p), { 1, 2, 3 }, "дальше ничего не исполняется")
  end },
  { "on_fail=continue (и у шага своё правило): план идёт дальше и кончается done", function()
      local p = setup()
      local r = plan{ steps = steps(5, { [2] = { fail = "cannot_place" }, [4] = { fail = "no_space" } }), on_fail = "continue" }
      local d = run_plan(r.job).data
      S.eq(starts(p), { 1, 2, 3, 4, 5 })
      S.eq({ d.status, d.done, d.failed, d.skipped, d.marks }, { "done", 3, 2, 0, "dfdfd" })
      S.eq(#d.failures, 2)
      S.eq(d.failures[2].code, "no_space")
      -- правило шага сильнее правила плана
      local s = steps(4, { [2] = { fail = "no_items" } })
      s[2].on_fail = "continue"
      s[3].args.fail = "stuck"
      local r2 = plan{ steps = s }
      local d2 = run_plan(r2.job).data
      S.eq({ d2.status, d2.code, d2.marks }, { "failed", "stuck", "dffs" })
  end },
  { "ошибка Lua в шаге — отказ шага internal, а не падение плана", function()
      local p = setup()
      local old = p.tick
      p.tick = function(task, ctx)
        if task.args.n == 2 then error("kaboom") end
        return old(task, ctx)
      end
      local r = plan{ steps = steps(3), on_fail = "continue" }
      local d = run_plan(r.job).data
      S.eq(d.marks, "dfd")
      S.eq(d.failures[1].code, "internal")
  end },
  { "«стоп» хозяина посреди плана: обрыв сразу, текущий шаг остановлен, остаток не исполняется", function()
      local p = setup()
      local r = plan{ steps = steps(6, { [3] = { ticks = 1000 } }) }
      B.until_(function() local t = storage.jobs.by_helper.h1.active return t and t.i == 3 end, 500)
      B.tick(5)
      S.chat(1, "стоп")
      local ev = done_of(r.job)
      S.ok(ev ~= nil, "plan_done в том же тике")
      local d = ev.data
      S.eq({ d.status, d.code, d.at, d.marks }, { "failed", "cancelled", 3, "ddfsss" })
      S.eq(d.failures[1], { step = 3, ["do"] = "rotate", code = "cancelled", text = "stopped by owner" })
      S.eq(p.log[#p.log], "stop:3")
      S.eq(storage.jobs.by_helper.h1.active, nil)
      B.tick(30)
      S.eq(starts(p), { 1, 2, 3 })
      S.eq(act_err({ steps = steps(1) }, "owner_hold").code, "owner_hold")
  end },
  { "cancel{job}: обрыв сразу; cancel{job, at_boundary}: шаг доделывается, потом конец", function()
      local p = setup()
      local r = plan{ steps = steps(4, { [2] = { ticks = 200 } }) }
      B.until_(function() local t = storage.jobs.by_helper.h1.active return t and t.i == 2 end, 500)
      S.eq(S.okr(S.req("cancel", { job = r.job }, "h1")).cancelled, { r.job })
      local d = done_of(r.job).data
      S.eq({ d.status, d.code, d.marks }, { "failed", "cancelled", "dfss" })
      S.eq(p.log[#p.log], "stop:2")
      local r2 = plan{ steps = steps(4, { [2] = { ticks = 100 } }) }
      B.until_(function() local t = storage.jobs.by_helper.h1.active return t and t.job == r2.job and t.i == 2 end, 500)
      local c = S.okr(S.req("cancel", { job = r2.job, at_boundary = true }, "h1"))
      S.eq(c, { cancelled = { r2.job }, at_boundary = true })
      S.eq(done_of(r2.job), nil, "шаг ещё идёт")
      local d2 = run_plan(r2.job).data
      S.eq({ d2.status, d2.code, d2.marks }, { "failed", "cancelled", "ddss" })
      S.ok(d2.text:find("boundary", 1, true), d2.text)
      local n = 0
      for _, l in ipairs(p.log) do if l == "stop:2" then n = n + 1 end end
      S.eq(n, 1, "доделанный шаг не останавливали")
      -- ждущую задачу at_boundary снимает сразу, как обычный cancel
      local w = B.act("wait", { seconds = 60 }).job
      local q = plan{ steps = steps(1) }.job
      S.eq(S.okr(S.req("cancel", { job = q, at_boundary = true }, "h1")).cancelled, { q })
      S.eq(done_of(q).data.marks, "s")
      S.okr(S.req("cancel", { job = w }, "h1"))
  end },
  { "replace=true снимает план (plan_done cancelled) и ставит новое", function()
      local p = setup()
      local r = plan{ steps = steps(3, { [1] = { ticks = 100 } }) }
      B.tick(5)
      local w = plan({ steps = steps(1, { [1] = { n = 9 } }) }, { replace = true })
      S.eq(done_of(r.job).data.code, "cancelled")
      S.eq(p.log[#p.log], "stop:1")
      S.eq(run_plan(w.job).data.status, "done")
      S.eq(starts(p), { 1, 9 })
  end },
  { "преемник after: встаёт сразу за планом; отказ предшественника снимает его", function()
      local p = setup()
      local a = plan{ steps = steps(3, { [1] = { ticks = 50 } }) }
      B.tick(2)
      local w = B.act("wait", { seconds = 1 })
      local b = plan({ steps = steps(2, { [1] = { n = 100 }, [2] = { n = 101 } }), after = a.job })
      S.eq(b.queued_before, 1, "сразу за активным планом, перед wait")
      local c = plan({ steps = steps(1, { [1] = { n = 200 } }), after = a.job })
      S.eq(c.queued_before, 2, "второй преемник — за первым")
      local j = S.okr(S.req("jobs", {}, "h1"))
      S.eq({ j.queue[1].job, j.queue[2].job, j.queue[3].job }, { b.job, c.job, w.job })
      S.eq(j.queue[1].after, a.job)
      run_plan(a.job)
      local db = run_plan(b.job).data
      S.eq(db.status, "done")
      S.eq(storage.jobs.by_helper.h1.queue[1] == nil or storage.jobs.by_helper.h1.queue[1].job ~= b.job, true)
      -- после удачно законченного — в начало очереди
      B.run(w.job)
      local d = plan{ steps = steps(1, { [1] = { ticks = 40 } }) }
      B.act("wait", { seconds = 30 })
      run_plan(d.job)
      local e = plan({ steps = steps(1, { [1] = { n = 300 } }), after = d.job })
      S.eq(e.queued_before, 0, "в начало очереди, перед wait")
      S.eq(storage.jobs.by_helper.h1.queue[1].job, e.job)
      -- cancel{all}: в ответе и план, и его преемник; у преемника тот же текст отмены
      B.until_(function() local t = storage.jobs.by_helper.h1.active return t and t.job == e.job end, 3000)
      local e2 = plan({ steps = steps(1), after = e.job })
      local all = S.okr(S.req("cancel", { all = true }, "h1")).cancelled
      table.sort(all)
      S.ok(#all >= 2 and all[#all] == e2.job, S.dump(all))
      S.eq(done_of(e2.job).data.text, "cancelled")
      -- отказ предшественника: преемник и его преемник сняты, прочее идёт
      local f = plan{ steps = steps(2, { [1] = { ticks = 20, fail = "no_items" } }) }
      local g = plan({ steps = steps(1, { [1] = { n = 400 } }), after = f.job })
      local h = plan({ steps = steps(1, { [1] = { n = 500 } }), after = g.job })
      local w2 = B.act("wait", { seconds = 1 })
      run_plan(f.job)
      local dg = done_of(g.job)
      S.ok(dg ~= nil, "преемник снят")
      S.eq({ dg.data.status, dg.data.code, dg.data.marks }, { "failed", "cancelled", "s" })
      S.ok(dg.data.text:find("predecessor", 1, true), dg.data.text)
      S.eq(done_of(h.job).data.code, "cancelled")
      S.eq(B.run(w2.job).kind, "job_done")
      for _, n in ipairs(starts(p)) do S.ok(n ~= 400 and n ~= 500, "преемники не начинались") end
      -- за отказавшим или неизвестным — not_found; с replace — bad_args
      S.err(S.req("act", { ["do"] = "plan", args = { steps = steps(1), after = f.job } }, "h1"), "not_found")
      S.err(S.req("act", { ["do"] = "plan", args = { steps = steps(1), after = 9999 } }, "h1"), "not_found")
      S.err(S.req("act", { ["do"] = "plan", args = { steps = steps(1), after = w2.job }, replace = true }, "h1"), "bad_args")
  end },
  { "сохранение и загрузка посреди плана: продолжает с того же шага", function()
      local p = setup()
      local r = plan{ steps = steps(6, { [3] = { ticks = 60 } }) }
      B.until_(function() local t = storage.jobs.by_helper.h1.active return t and t.i == 3 end, 500)
      B.tick(10)
      S.reload()
      local d = run_plan(r.job).data
      S.eq({ d.status, d.marks }, { "done", "dddddd" })
      S.eq(starts(p), { 1, 2, 3, 4, 5, 6 }, "шаг 3 не начинался заново")
  end },
  { "шаг без прогресса 60 с — план снят stuck, stop шага позван", function()
      local p = setup()
      local r = plan{ steps = steps(3, { [2] = { ticks = 100000, pulse = false } }) }
      local d = run_plan(r.job, 5000).data
      S.eq({ d.status, d.code, d.marks }, { "failed", "stuck", "dfs" })
      S.eq(p.log[#p.log], "stop:2")
  end },
  { "шаги с «пульсом» не застревают, даже если идут дольше 60 с", function()
      setup()
      local r = plan{ steps = steps(2, { [1] = { ticks = 4000 } }) }
      local d = run_plan(r.job, 6000).data
      S.eq(d.status, "done")
  end },
  { "200 шагов с отказами: plan_done в пределах буфера, без ужатия", function()
      local p = setup()
      local s = {}
      for i = 1, 200 do s[i] = { ["do"] = "rotate", args = { n = i, fail = "no_items", big = true } } end
      -- 200 шагов не влезают в запрос 8 КБ — через blob_put, как большой чертёж
      local json = helpers.table_to_json(s)
      local parts = {}
      for k = 1, #json, 3500 do parts[#parts + 1] = json:sub(k, k + 3499) end
      for k, part in ipairs(parts) do
        S.okr(S.req("blob_put", { blob = "plan-200", part = k, total = #parts, data = part }))
      end
      local r = plan{ blob = "plan-200", on_fail = "continue" }
      local ev = run_plan(r.job, 1000)
      local d = ev.data
      S.eq(#starts(p), 200)
      S.eq(d.truncated, nil, "не ужато буфером")
      S.eq(#d.marks, 200)
      S.eq({ d.status, d.failed, d.done }, { "done", 200, 0 })
      S.ok(#d.failures <= 10)
      S.ok(#helpers.table_to_json(d) <= 4000)
  end },
  { "шаги из blob (JSON-массив через blob_put)", function()
      local p = setup()
      local json = helpers.table_to_json(steps(3))
      S.okr(S.req("blob_put", { blob = "plan-a", part = 1, total = 1, data = json }))
      local r = plan{ blob = "plan-a" }
      S.eq(run_plan(r.job).data.marks, "ddd")
      S.eq(starts(p), { 1, 2, 3 })
      act_err({ blob = "nope" }, "bad_args")
      S.okr(S.req("blob_put", { blob = "plan-b", part = 1, total = 1, data = "{\"x\":1}" }))
      act_err({ blob = "plan-b" }, "bad_args")
  end },
  { "from_step: начинает с шага, до него — «-» в marks", function()
      local p = setup()
      local r = plan{ steps = steps(4), from_step = 3 }
      local d = run_plan(r.job).data
      S.eq(starts(p), { 3, 4 })
      S.eq({ d.marks, d.from_step, d.done, d.skipped }, { "--dd", 3, 2, 0 })
  end },
  { "ждущий план снят cancel{all}: plan_done со всеми шагами «s»", function()
      setup()
      B.act("wait", { seconds = 60 })
      local r = plan{ steps = steps(3) }
      S.okr(S.req("cancel", { all = true }, "h1"))
      local d = done_of(r.job).data
      S.eq({ d.status, d.code, d.marks, d.skipped, d.at }, { "failed", "cancelled", "sss", 3, nil })
  end },
  { "inventory_delta: что прибавилось и убыло за план", function()
      local p = setup()
      local inv = storage.helpers.h1.entity.get_main_inventory()
      inv.insert{ name = "iron-plate", count = 10 }
      local old = p.start
      p.start = function(task, ctx)
        if task.args.n == 1 then ctx.entity.get_main_inventory().insert{ name = "copper-plate", count = 5 } end
        if task.args.n == 2 then ctx.entity.get_main_inventory().remove_item{ name = "iron-plate", count = 4 } end
        return old(task, ctx)
      end
      local r = plan{ steps = steps(2) }
      local d = run_plan(r.job).data
      S.eq(d.inventory_delta, { ["copper-plate"] = 5, ["iron-plate"] = -4 })
  end },
})

S.suite("plan_flee", {
  { "отступление посреди плана: план снят, после — продолжает с текущего шага, а не с начала", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      local o = { x = h.position.x, y = h.position.y }
      local r = B.act("plan", { steps = {
        { ["do"] = "walk", args = { to = { x = o.x + 2, y = o.y } } },
        { ["do"] = "walk", args = { to = { x = o.x + 40, y = o.y } } },
        { ["do"] = "walk", args = { to = { x = o.x + 42, y = o.y } } },
      } })
      B.until_(function() local t = storage.jobs.by_helper.h1.active return t and t.job == r.job and t.i == 2 end, 2000)
      B.tick(5)
      local foe = H.enemy({ x = h.position.x + 10, y = h.position.y })
      H.wait("reflex_fired")
      local first = done_of(r.job)
      S.ok(first ~= nil, "план снят отступлением")
      S.eq({ first.data.status, first.data.code, first.data.marks }, { "failed", "cancelled", "dfs" })
      foe.destroy()
      local res = H.wait("reflex_resumed")
      S.eq(#res.data.jobs, 1, S.dump(res.data))
      S.eq(res.data.jobs[1]["do"], "plan")
      local job2 = res.data.jobs[1].job
      local t = storage.jobs.by_helper.h1.active or storage.jobs.by_helper.h1.queue[1]
      S.eq(t.args.from_step, 2)
      local d = run_plan(job2, 4000).data
      S.eq({ d.status, d.marks, d.from_step }, { "done", "-dd", 2 })
      S.ok(math.abs(h.position.x - (o.x + 42)) <= 1.5, "дошёл до конца плана: " .. S.dump(h.position))
  end },
  { "возврат плана с шагом mine по ресурсу — с остатком count", function()
      B.setup()
      local P = require("scripts.actions.plan")
      local task = {
        args = { steps = {
          { ["do"] = "walk", args = { to = { x = 1, y = 1 } } },
          { ["do"] = "mine", args = { resource = "iron-ore", count = 50 } },
        }, on_fail = "stop" },
        i = 2, marks = { "d" }, cur = { ["do"] = "mine", progress = { done = 20, total = 50 } },
      }
      local a = P.resume_args(task)
      S.eq(a.from_step, 2)
      S.eq(a.steps[2].args.count, 30)
      S.eq(task.args.steps[2].args.count, 50, "исходный план не тронут")
      -- шаг только что закончился: продолжать со следующего; всё сделано — нечего продолжать
      S.eq(P.resume_args({ args = task.args, i = 1, marks = { "d" } }).from_step, 2)
      S.eq(P.resume_args({ args = task.args, i = 2, marks = { "d", "d" } }), nil)
      S.eq(P.resume_args({ args = { steps = task.args.steps, from_step = 2 } }).from_step, 2)
  end },
})
