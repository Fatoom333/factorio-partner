-- Действие `build_blueprint` (поток F). Контракт: docs/ACTIONS.md. Заглушка этапа 0.
local err = require("scripts.core.err")
local M = {}
M.name = "build_blueprint"
M.schema = {}
function M.start(task, ctx)
  return { status = "failed", code = "internal", detail = { text = "not implemented" } }
end
function M.tick(task, ctx) return nil end
function M.stop(task, ctx) end
return M
