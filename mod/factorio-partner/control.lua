-- factorio-partner: точка входа. Файл принадлежит ядру (PROTOCOL §7): другой модуль
-- добавляется одной строкой в список ниже — в ACTIONS (действие из scripts/actions) или в
-- MODULES (всё остальное). Необязательных модулей нет: каждый файл из списков лежит в
-- репозитории, а отсутствующий — это ошибка сборки мода, и она должна быть видна сразу (игра
-- назовёт файл), а не угадываться по тексту сообщения `require`.
local core = require("scripts.core.init")

local ACTIONS = {
  "walk", "approach", "follow",
  "mine", "craft", "insert", "extract", "collect", "pickup", "equip", "armor_grid",
  "place", "rotate", "set_recipe", "build_blueprint", "build_layout", "build_ghosts", "deconstruct",
  "plan_mining",
  "plan_belt",
  "connect_entities",
  "get_items",
  "plan",
}
for _, name in ipairs(ACTIONS) do
  core.register_action(require("scripts.actions." .. name))
end

local MODULES = {
  "lib.path", "lib.layout",
  "perception.state", "perception.map", "perception.resources", "perception.stock", "perception.ghosts",
  "perception.recipes", "perception.vision", "perception.rates", "perception.find",
  "perception.access",
  "perception.supply", "perception.lookup",
  "core.index", "perception.status",
  "reflexes.flee", "reflexes.death", "reflexes.ammo", "reflexes.shoot", "reflexes.upkeep",
  "core.nameplate", "core.bgcraft", "core.tidy", "core.owner_words", "core.metrics", "core.panel",
}
for _, name in ipairs(MODULES) do
  core.register_module(require("scripts." .. name))
end
-- тело-игрок (PROTOCOL §7): часть ядра, подключается последним
core.register_module(require("scripts.core.attach"))

core.init()
