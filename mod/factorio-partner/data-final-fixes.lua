-- Стадия данных: `underground_collision_mask` подземных конвейеров во время игры не читается
-- (2.0.77), поэтому кладём маски в прототип `mod-data` — их читает scripts/lib/beltpath.lua.
-- Записываем только явно заданные маски: без записи beltpath работает по осторожному правилу
-- (под плиткой, на которой сам конвейер стоять не может, подземный не идёт). PROTOCOL §6.12.
local masks = {}
for name, proto in pairs(data.raw["underground-belt"] or {}) do
  local mask = proto.underground_collision_mask
  if type(mask) == "table" and type(mask.layers) == "table" then
    local layers = {}
    for layer, on in pairs(mask.layers) do
      if on then layers[layer] = true end
    end
    masks[name] = { layers = layers }
  end
end

data:extend({
  { type = "mod-data", name = "factorio-partner-underground-masks", data = masks },
})
