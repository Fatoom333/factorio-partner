-- Заглушки интерфейса для панели хозяина (scripts/core/panel.lua): player.gui.screen с деревом
-- элементов и player.set_shortcut_toggled. Дополняют mod/tests/stubs.lua (TESTING.md §1).
--
--   local P = require("stubs_panel")
--   P.attach(player)            -- player.gui.screen, player.toggled[prototype] = bool
--   P.find(root, name)          -- элемент по имени среди вложенных (или nil)
--   P.click(player, element)    -- on_gui_click; P.check(player, element, state); P.type_text(...)
--   P.confirm(player, element)  -- on_gui_confirmed
--   P.shortcut(player)          -- on_lua_shortcut «partner-panel»; P.hotkey(player) — custom-input
local S = require("stubs")

local P = {}

local Element = {}

local function new_element(parent, spec)
  local el = {
    valid = true, parent = parent, children = {}, style = {}, tags = spec.tags or {},
    name = spec.name, type = spec.type, caption = spec.caption, state = spec.state,
    text = spec.text, tooltip = spec.tooltip, direction = spec.direction, spec_style = spec.style,
  }
  -- методы вызываются как в игре: el.add{...}, el.destroy()
  el.add = function(child_spec)
    local ch = new_element(el, child_spec)
    el.children[#el.children + 1] = ch
    return ch
  end
  el.destroy = function()
    rawset(el, "valid", false)
    local list = el.parent and el.parent.children
    if list then
      for i, c in ipairs(list) do
        if c == el then table.remove(list, i) break end
      end
    end
  end
  return setmetatable(el, Element)
end

-- el[name] — дочерний элемент с таким именем (как LuaGuiElement)
Element.__index = function(t, k)
  for _, ch in ipairs(rawget(t, "children")) do
    if rawget(ch, "name") == k then return ch end
  end
  return nil
end

function P.attach(player)
  local screen = new_element(nil, { name = "screen", type = "screen" })
  player.gui = { screen = screen }
  player.toggled = {}
  player.set_shortcut_toggled = function(name, on) player.toggled[name] = on end
  player.is_shortcut_toggled = function(name) return player.toggled[name] end
  return player
end

function P.find(root, name)
  for _, ch in ipairs(root.children) do
    if ch.name == name then return ch end
    local r = P.find(ch, name)
    if r then return r end
  end
  return nil
end

function P.window(player) return player.gui.screen.partner_panel end

function P.click(player, el)
  return S.fire(defines.events.on_gui_click, { player_index = player.index, element = el })
end

function P.check(player, el, state)
  el.state = state
  return S.fire(defines.events.on_gui_checked_state_changed, { player_index = player.index, element = el })
end

function P.type_text(player, el, text)
  el.text = text
  return S.fire(defines.events.on_gui_text_changed, { player_index = player.index, element = el })
end

function P.confirm(player, el)
  return S.fire(defines.events.on_gui_confirmed, { player_index = player.index, element = el })
end

function P.shortcut(player)
  return S.fire(defines.events.on_lua_shortcut, { player_index = player.index, prototype_name = "partner-panel" })
end

--- Горячая клавиша: custom-input вызывается по строковому имени.
function P.hotkey(player)
  local h = S.handlers["partner-toggle-panel"]
  if not h then return false end
  h.fn({ player_index = player.index, input_name = "partner-toggle-panel", tick = game.tick })
  return true
end

return P
