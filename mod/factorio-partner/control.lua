-- factorio-partner: точка входа. Список модулей фиксирован этапом 0 (docs/PLAN.md),
-- потоки меняют только содержимое своих файлов.
local core = require("scripts.core.init")

local ACTIONS = {
  "walk", "approach", "follow",
  "mine", "craft", "insert", "extract", "collect", "pickup",
  "place", "build_blueprint", "build_ghosts", "deconstruct",
}
for _, name in ipairs(ACTIONS) do
  core.register_action(require("scripts.actions." .. name))
end

local MODULES = {
  "lib.path",
  "perception.state", "perception.map", "perception.resources", "perception.stock", "perception.ghosts",
  "perception.recipes", "perception.vision", "perception.rates",
  "reflexes.flee", "reflexes.death",
}
for _, name in ipairs(MODULES) do
  core.register_module(require("scripts." .. name))
end

core.init()
