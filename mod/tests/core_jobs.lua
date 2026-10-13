-- Очередь задач: act/cancel/jobs, ctx, stuck, job_progress, wait (ACTIONS.md, PROTOCOL §4).
local S = require("stubs")

-- Тестовое действие с журналом вызовов. opts.start/tick/stop — своё поведение.
local function probe(name, opts)
  opts = opts or {}
  local M = { name = name, log = {} }
  M.schema = opts.schema or { n = { type = "int", min = 1, max = 5, default = 1 } }
  function M.start(task, ctx)
    M.log[#M.log + 1] = "start:" .. task.job
    if opts.start then return opts.start(task, ctx) end
  end
  function M.tick(task, ctx)
    M.log[#M.log + 1] = "tick:" .. task.job
    if opts.tick then return opts.tick(task, ctx) end
  end
  function M.stop(task, ctx)
    M.log[#M.log + 1] = "stop:" .. task.job
    if opts.stop then return opts.stop(task, ctx) end
  end
  return M
end

local function setup(walk_opts, extra)
  local walk = probe("walk", walk_opts)
  local replace = { ["scripts.actions.walk"] = walk }
  for k, v in pairs(extra or {}) do replace[k] = v end
  S.load_mod{ replace = replace }
  S.add_player{ name = "Tartaluga" }
  S.okr(S.req("helper_spawn", {}, "h1"))
  return walk
end

local function act(d, args, extra)
  local a = { ["do"] = d, args = args }
  for k, v in pairs(extra or {}) do a[k] = v end
  return S.req("act", a, "h1")
end

local function events_since(since)
  return S.okr(S.req("events", { since = since or 0, limit = 200 })).events
end

local function kinds(evs)
  local out = {}
  for _, e in ipairs(evs) do
    out[#out + 1] = e.kind .. ":" .. tostring(e.data.job) .. (e.data.code and (":" .. e.data.code) or "")
  end
  return out
end

S.suite("jobs", {
  { "act: очередь по порядку, start на следующем тике, done -> job_done", function()
      local n = 0
      local walk = setup{ tick = function(task) n = n + 1; if n % 2 == 0 then return { status = "done", detail = { pos = { x = 1, y = 2 } } } end end }
      local r1 = S.okr(act("walk", { n = 2 }))
      local r2 = S.okr(act("walk", {}))
      S.eq({ r1.job, r1.queued_before, r2.job, r2.queued_before }, { 1, 0, 2, 1 })
      S.eq(walk.log, {}, "ничего не исполняется в команде")
      S.tick(6)
      S.eq(walk.log, { "start:1", "tick:1", "tick:1", "start:2", "tick:2", "tick:2" })
      local ev = events_since()
      S.eq(kinds(ev), { "job_done:1", "job_done:2" })
      S.eq(ev[1].data["do"], "walk")
      S.eq(ev[1].data.detail, { pos = { x = 1, y = 2 } })
      S.eq(ev[1].loud, true)
  end },
  { "act: схема — default, bad_args с именем поля, лишние поля", function()
      local seen
      setup{ start = function(task) seen = task.args; return { status = "done" } end }
      S.okr(act("walk", {}))
      S.tick()
      S.eq(seen, { n = 1 })
      local e = S.err(act("walk", { n = 9 }), "limit") -- верхняя граница -> limit
      S.ok(e.text:find("args.args.n", 1, true), e.text)
      S.ok(S.err(act("walk", { zzz = 1 }), "bad_args").text:find("zzz", 1, true))
      S.err(act("walk", { n = 1.5 }), "bad_args")
      S.err(act("fly", {}), "bad_args")
      S.err(S.req("act", { ["do"] = "walk", args = "x" }, "h1"), "bad_args")
      S.err(S.req("act", { args = {} }, "h1"), "bad_args")
      S.err(S.req("act", { ["do"] = "walk", replace = "yes" }, "h1"), "bad_args")
  end },
  { "act: req = id запроса, jobs показывает active/queue", function()
      local walk = setup{ start = function(task) task.progress = { done = 1, total = 4 } end }
      S.call{ v = 1, id = "req-A", op = "act", helper = "h1", args = { ["do"] = "walk", args = {} } }
      S.call{ v = 1, id = "req-B", op = "act", helper = "h1", args = { ["do"] = "wait", args = { seconds = 2 } } }
      S.tick(3)
      local j = S.okr(S.req("jobs", {}, "h1"))
      S.eq(j.active, { job = 1, ["do"] = "walk", since = 1, progress = { done = 1, total = 4 }, req = "req-A" })
      S.eq(j.queue, { { job = 2, ["do"] = "wait", req = "req-B" } })
  end },
  { "replace=true: текущая и очередь -> cancelled (stop у активной), новая встаёт", function()
      local walk = setup()
      act("walk", {})
      act("walk", {})
      S.tick(2)
      local r = S.okr(act("walk", {}, { replace = true }))
      S.eq(r.queued_before, 0)
      S.eq(walk.log, { "start:1", "tick:1", "stop:1" })
      S.eq(kinds(events_since()), { "job_failed:1:cancelled", "job_failed:2:cancelled" })
      S.tick()
      S.eq(walk.log[#walk.log], "start:3")
  end },
  { "очередь ≤ 32 ждущих -> limit", function()
      setup()
      for i = 1, 32 do S.okr(act("walk", {})) end
      S.err(act("walk", {}), "limit")
      S.tick() -- первая стала активной, место освободилось
      S.okr(act("walk", {}))
  end },
  { "cancel: активная (stop), из очереди, all, not_found, bad_args", function()
      local walk = setup()
      for i = 1, 4 do act("walk", {}) end
      S.tick()
      S.eq(S.okr(S.req("cancel", { job = 1 }, "h1")).cancelled, { 1 })
      S.eq(walk.log, { "start:1", "stop:1" })
      S.eq(S.okr(S.req("cancel", { job = 3 }, "h1")).cancelled, { 3 })
      S.err(S.req("cancel", { job = 3 }, "h1"), "not_found")
      S.err(S.req("cancel", {}, "h1"), "bad_args")
      S.tick()
      S.eq(S.okr(S.req("cancel", { all = true }, "h1")).cancelled, { 2, 4 })
      S.eq(kinds(events_since()), { "job_failed:1:cancelled", "job_failed:3:cancelled", "job_failed:2:cancelled", "job_failed:4:cancelled" })
      S.eq(S.okr(S.req("jobs", {}, "h1")), { queue = {} })
  end },
  { "ошибка Lua в tick -> internal, stop вызван, очередь идёт дальше", function()
      local walk = setup{ tick = function(task) if task.job == 1 then error("boom") end return { status = "done" } end }
      act("walk", {})
      act("walk", {})
      S.tick(4)
      S.eq(walk.log, { "start:1", "tick:1", "stop:1", "start:2", "tick:2" })
      local ev = events_since()
      S.eq(kinds(ev), { "job_failed:1:internal", "job_done:2" })
      S.ok(not ev[1].data.text:find(".lua", 1, true), ev[1].data.text)
  end },
  { "err.raise в start -> этот код; failed от модуля -> stop; плохой код -> internal", function()
      local err = require("scripts.core.err")
      local walk = setup{ start = function(task)
        if task.args.n == 1 then err.raise("path_failed", "no route") end
        if task.args.n == 2 then return { status = "failed", code = "not_found", text = "no tree" } end
        if task.args.n == 3 then return { status = "failed", code = "nope" } end
        return { status = "maybe" }
      end }
      for n = 1, 4 do act("walk", { n = n }) end
      S.tick(4)
      local ev = events_since()
      S.eq(kinds(ev), { "job_failed:1:path_failed", "job_failed:2:not_found", "job_failed:3:internal", "job_failed:4:internal" })
      S.eq(ev[1].data.text, "no route")
      S.eq(walk.log, { "start:1", "stop:1", "start:2", "stop:2", "start:3", "stop:3", "start:4", "stop:4" })
  end },
  { "stuck: 60 с без прогресса -> failed stuck и stop", function()
      local walk = setup()
      act("walk", {})
      S.tick(3600)
      S.eq(kinds(events_since()), {})
      S.tick(60)
      S.eq(kinds(events_since()), { "job_failed:1:stuck" })
      S.eq(walk.log[#walk.log], "stop:1")
  end },
  { "не stuck: тело движется / пульс progress_tick / меняется инвентарь", function()
      local mode
      local walk = setup{ tick = function(task, ctx)
        if mode == "move" then S.move(ctx.entity, { x = ctx.entity.position.x + 0.2, y = 0 })
        elseif mode == "pulse" then task.progress_tick = ctx.tick
        elseif mode == "inv" and ctx.tick % 600 == 0 then ctx.entity.insert{ name = "coal", count = 1 } end
      end }
      for _, m in ipairs({ "move", "pulse", "inv" }) do
        mode = m
        act("walk", {})
        S.tick(5000)
        S.eq(kinds(events_since()), {}, m)
        S.req("cancel", { all = true }, "h1")
        S.tick()
        storage.events.list = {}
        storage.events.next_seq = 1
      end
  end },
  { "job_progress: шумное, не чаще раза в 5 с", function()
      setup{ tick = function(task, ctx) task.progress = { done = ctx.tick, total = 10000 } end }
      act("walk", {})
      S.tick(700)
      local ev = events_since()
      S.eq(#ev, 3)
      S.eq({ ev[1].kind, ev[1].loud, ev[1].data.job, ev[1].data.total }, { "job_progress", false, 1, 10000 })
      S.eq({ ev[2].tick - ev[1].tick, ev[3].tick - ev[2].tick }, { 300, 300 })
  end },
  { "ctx: helper_id, entity, tick, emit, approach -> path.step, cancel_approach -> path.cancel", function()
      local calls = {}
      local fake_path = {
        step = function(task, ctx, goal, dist) calls[#calls + 1] = { "step", ctx.helper_id, goal, dist } return true end,
        cancel = function(task, ctx) calls[#calls + 1] = { "cancel", ctx.helper_id } end,
        events = {},
      }
      local seen
      setup({
        start = function(task, ctx)
          seen = { ctx.helper_id, ctx.entity.valid, ctx.tick }
          ctx.emit("arrived", { job = task.job, pos = { x = 1, y = 1 } })
          local r = ctx.approach(task, { x = 5, y = 5 }, 2.7)
          S.eq(r, true)
        end,
        stop = function(task, ctx) ctx.cancel_approach(task) end,
      }, { ["scripts.lib.path"] = fake_path })
      act("walk", {})
      S.tick()
      S.eq(seen, { "h1", true, 1 })
      S.req("cancel", { job = 1 }, "h1")
      S.eq(calls, { { "step", "h1", { x = 5, y = 5 }, 2.7 }, { "cancel", "h1" } })
      local ev = events_since()
      S.eq({ ev[1].kind, ev[1].helper, ev[1].loud }, { "arrived", "h1", false })
  end },
  { "ошибка внутри path.step: действие получает failed internal", function()
      local broken_path = {
        step = function() error("boom") end,
        cancel = function() end,
        events = {},
      }
      setup({ start = function(task, ctx) return ctx.approach(task, { x = 1, y = 1 }, 1) end },
        { ["scripts.lib.path"] = broken_path })
      act("walk", {})
      S.tick()
      S.eq(kinds(events_since()), { "job_failed:1:internal" })
  end },
  { "wait: seconds 1..600, никогда не replace, done через N секунд", function()
      setup()
      S.err(act("wait", { seconds = 0 }), "bad_args")
      S.err(act("wait", { seconds = 601 }), "limit")
      S.err(act("wait", {}), "bad_args")
      S.err(act("wait", { seconds = 2 }, { replace = true }), "bad_args")
      S.okr(act("wait", { seconds = 2 }))
      S.tick(120)
      S.eq(kinds(events_since()), {})
      S.tick(1)
      S.eq(kinds(events_since()), { "job_done:1" })
  end },
  { "wait 600 с не считается застреванием", function()
      setup()
      act("wait", { seconds = 600 })
      S.tick(600 * 60 + 1)
      S.eq(kinds(events_since()), { "job_done:1" })
  end },
  { "очередь переживает сохранение/загрузку", function()
      local walk = setup{ tick = function(task) task.count = (task.count or 0) + 1; if task.count >= 3 then return { status = "done", detail = { c = task.count } } end end }
      act("walk", {})
      act("wait", { seconds = 1 })
      S.tick(2)
      S.reload()
      S.tick(70)
      local ev = events_since()
      S.eq(kinds(ev), { "job_done:1", "job_done:2" })
      S.eq(ev[1].data.detail, { c = 3 })
      S.eq(S.okr(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1")).job, 3, "номера задач продолжаются")
  end },
  { "задача освобождает свою область резерва при завершении", function()
      local reserve = require("scripts.core.reserve")
      setup{ start = function(task, ctx)
        reserve.hold_area(ctx.helper_id, { left_top = { x = 0, y = 0 }, right_bottom = { x = 10, y = 10 } })
        return { status = "done" }
      end }
      act("walk", {})
      S.tick()
      S.eq(storage.reservations.areas.h1, nil)
  end },
  { "смерть посреди задачи: stop вызван при живом теле, job_failed no_helper", function()
      local valid_in_stop
      local walk = setup{ stop = function(task, ctx) valid_in_stop = ctx.entity and ctx.entity.valid end }
      act("walk", {})
      act("walk", {})
      S.tick(2)
      storage.helpers.h1.entity.die()
      S.eq(valid_in_stop, true)
      -- died шлёт рефлекс смерти (поток H, EVENTS.md) — после job_failed ядра
      S.eq(kinds(events_since()), { "job_failed:1:no_helper", "job_failed:2:no_helper", "died:nil" })
  end },
})
