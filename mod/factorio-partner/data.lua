-- Панель хозяина: ярлык в панели быстрых кнопок и горячая клавиша (scripts/core/panel.lua).
-- Формат ярлыка — как у ярлыков игры (base/prototypes/shortcuts.lua): icon и small_icon — имена
-- файлов, размеры — в icon_size и small_icon_size.
data:extend({
  {
    type = "custom-input",
    name = "partner-toggle-panel",
    key_sequence = "", -- без назначения: хозяин назначит сам в настройках управления
    action = "lua",
  },
  {
    type = "shortcut",
    name = "partner-panel",
    order = "z[partner]",
    action = "lua",
    toggleable = true,
    associated_control_input = "partner-toggle-panel",
    icon = "__factorio-partner__/graphics/panel-x64.png",
    icon_size = 64,
    small_icon = "__factorio-partner__/graphics/panel-x24.png",
    small_icon_size = 24,
  },
})
