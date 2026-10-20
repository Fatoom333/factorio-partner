-- Стадия данных (data.lua): прототипы ярлыка панели и горячей клавиши в формате Factorio 2.0 —
-- у ярлыка icon и small_icon имена файлов (строки), размеры в icon_size и small_icon_size, сами
-- файлы лежат в моде.
local S = require("stubs")

local function load_data()
  local list = {}
  _G.data = { extend = function(_, protos) for _, p in ipairs(protos) do list[#list + 1] = p end end }
  package.loaded["data"] = nil
  require("data")
  _G.data = nil
  local by = {}
  for _, p in ipairs(list) do by[p.type .. "/" .. p.name] = p end
  return by
end

local function mod_file(path)
  local prefix = "__" .. __fp_test_env.mod_name .. "__/"
  S.ok(path:sub(1, #prefix) == prefix, "путь внутри мода: " .. path)
  local f = io.open(__fp_test_env.mod_dir .. "/" .. path:sub(#prefix + 1), "rb")
  S.ok(f ~= nil, "файл есть: " .. path)
  local src = f:read("*a")
  f:close()
  return src
end

--- Размер PNG из заголовка IHDR (ширина, высота).
local function png_size(src)
  S.ok(src ~= nil and src:sub(2, 4) == "PNG", "это PNG")
  local function u32(i)
    local a, b, c, d = src:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

S.suite("data", {
  { "ярлык partner-panel: формат 2.0 (строки и размеры), файлы иконок есть и нужного размера", function()
      local by = load_data()
      local sc = by["shortcut/partner-panel"]
      S.ok(sc ~= nil, "ярлык объявлен")
      S.eq({ type(sc.icon), type(sc.small_icon) }, { "string", "string" })
      S.eq({ sc.icon_size, sc.small_icon_size }, { 64, 24 })
      S.eq({ sc.action, sc.toggleable, sc.associated_control_input }, { "lua", true, "partner-toggle-panel" })
      S.eq({ png_size(mod_file(sc.icon)) }, { 64, 64 })
      S.eq({ png_size(mod_file(sc.small_icon)) }, { 24, 24 })
      local ci = by["custom-input/partner-toggle-panel"]
      S.ok(ci ~= nil and ci.key_sequence == "" and ci.action == "lua", "горячая клавиша без назначения")
  end },
})
