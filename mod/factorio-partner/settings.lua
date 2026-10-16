-- Настройки мода. PROTOCOL.md §7: хозяин помощников.
data:extend({
  {
    type = "string-setting",
    name = "partner-owner",
    setting_type = "runtime-global",
    default_value = "",
    allow_blank = true,
    order = "a",
  },
  {
    type = "string-setting",
    name = "partner-helper-name",
    setting_type = "runtime-global",
    default_value = "Claude",
    allow_blank = true,
    order = "b",
  },
  {
    type = "bool-setting",
    name = "partner-owner-words",
    setting_type = "runtime-global",
    default_value = true,
    order = "c",
  },
  {
    type = "string-setting",
    name = "partner-stop-words",
    setting_type = "runtime-global",
    default_value = "стоп,стой,остановись,отмена,stop",
    allow_blank = true,
    order = "d",
  },
  {
    type = "string-setting",
    name = "partner-come-phrases",
    setting_type = "runtime-global",
    default_value = "иди сюда,ко мне,иди ко мне,come,come here",
    allow_blank = true,
    order = "e",
  },
})
