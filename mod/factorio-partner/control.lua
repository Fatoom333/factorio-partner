-- factorio-partner: точка входа. Список модулей фиксирован этапом 0 (docs/PLAN.md),
-- потоки меняют только содержимое своих файлов.
local core = require("scripts.core.init")

-- Модули волны 3, которые пишут другие потоки (M — plan_mining, P — тело-игрок): пока файла
-- нет, мод работает без него. «Нет файла» отличаем от ошибки ВНУТРИ файла: вторая — наружу.
local function optional(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  local text = tostring(mod)
  local as_path = name:gsub("%.", "/")
  local about_it = text:find(name, 1, true) ~= nil or text:find(as_path, 1, true) ~= nil
  local missing = text:find("not found", 1, true) ~= nil or text:find("no such file", 1, true) ~= nil
    or text:find("no file", 1, true) ~= nil
  if about_it and missing then return nil end
  error(mod, 0)
end

local ACTIONS = {
  "walk", "approach", "follow",
  "mine", "craft", "insert", "extract", "collect", "pickup",
  "place", "build_blueprint", "build_ghosts", "deconstruct",
  "plan_mining",
}
for _, name in ipairs(ACTIONS) do
  core.register_action(require("scripts.actions." .. name))
end

local MODULES = {
  "lib.path",
  "perception.state", "perception.map", "perception.resources", "perception.stock", "perception.ghosts",
  "perception.recipes", "perception.vision", "perception.rates", "perception.find",
  "perception.access",
  "reflexes.flee", "reflexes.death",
}
for _, name in ipairs(MODULES) do
  core.register_module(require("scripts." .. name))
end
local attach = optional("scripts.core.attach")
if attach then core.register_module(attach) end

core.init()
