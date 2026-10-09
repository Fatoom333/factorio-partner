-- Хозяин помощников (поток A). PROTOCOL.md §7: игрок из настройки `partner-owner`
-- (runtime-global, строка; пусто -> игрок с индексом 1). Приказы — только от хозяина.
local M = {}

M.SETTING = "partner-owner"

function M.setting_value()
  local s = settings and settings.global and settings.global[M.SETTING]
  local v = s and s.value
  if type(v) ~= "string" then return "" end
  return v
end

--- LuaPlayer хозяина или nil (игрока с таким именем нет).
function M.player()
  local name = M.setting_value()
  if name ~= "" then
    return game.get_player(name)
  end
  return game.get_player(1)
end

--- Имя хозяина (строка) или nil.
function M.name()
  local p = M.player()
  return p and p.name or nil
end

function M.is_owner(player)
  local o = M.player()
  return o ~= nil and player ~= nil and o.index == player.index
end

--- Хозяин «есть» (PROTOCOL §4): connected и character ~= nil. Возвращает player, character.
function M.present()
  local p = M.player()
  if p == nil or not p.connected then return nil end
  local ch = p.character
  if ch == nil or not ch.valid then return nil end
  return p, ch
end

--- Где стоит хозяин для helper_spawn (PROTOCOL §4, ревизия 3): `player, surface, position`.
--- Хозяин онлайн -> нужно тело (`present`), иначе nil. Хозяин в сейве, но офлайн (сервер без
--- окна в тестах) -> его последняя `physical_position` на `physical_surface`. Хозяина нет в
--- сейве -> nil (вызывающий отвечает `no_player`).
function M.spawn_anchor()
  local p = M.player()
  if p == nil then return nil end
  if p.connected then
    if not M.present() then return nil end
  end
  local ok, surface, pos = pcall(function() return p.physical_surface, p.physical_position end)
  if not ok or surface == nil or pos == nil or not surface.valid then return nil end
  return p, surface, pos
end

return M
