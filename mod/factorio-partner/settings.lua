-- Настройки мода (поток A). PROTOCOL.md §7: хозяин помощников.
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
})
