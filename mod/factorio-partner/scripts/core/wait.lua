-- Действие `wait` (docs/ACTIONS.md): пауза в очереди на seconds секунд.
-- Никогда не заменяет очередь (act{do="wait", replace=true} -> bad_args, проверяет jobs.lua).
local M = {}
M.name = "wait"
M.schema = { seconds = { type = "number", required = true, min = 1, max = 600 } }

function M.start(task, ctx)
  task.until_tick = ctx.tick + math.floor(task.args.seconds * 60 + 0.5)
  task.progress_tick = ctx.tick
end

function M.tick(task, ctx)
  task.progress_tick = ctx.tick -- ожидание — не «застрял» (ядро следит за прогрессом 60 с)
  if ctx.tick >= task.until_tick then
    return { status = "done", detail = {} }
  end
end

function M.stop(task, ctx) end

return M
