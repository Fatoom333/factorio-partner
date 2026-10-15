-- Свойства плиток — из игры, не из кода (PROTOCOL §6.12). Общий помощник для `map`,
-- `access` и `plan_mining`. Имён плиток, планет и жидкостей здесь нет: всё берётся из прототипов.
--   * пройти нельзя — маска столкновений плитки пересекается с маской прототипа персонажа;
--   * построить нельзя — маска плитки пересекается с маской постройки;
--   * чем накрыть — `default_cover_tile` плитки, предмет — `items_to_place_this` плитки-подложки;
--   * доступна ли подложка — рецепт предмета открыт силе либо предмет уже есть (помощник, склады).
-- Только чтение: в игре и в storage ничего не меняет.
local T = {}

T.CHARACTER = "character" -- имя прототипа тела (PROTOCOL §7), не плитки

local function prop(obj, key)
  if obj == nil then return nil end
  local ok, v = pcall(function() return obj[key] end)
  if ok then return v end
  return nil
end
T.prop = prop

--- Слои маски столкновений прототипа → множество {layer = true} (пустое, если маски нет).
function T.layers_of(proto)
  local out = {}
  local mask = prop(proto, "collision_mask")
  local layers = type(mask) == "table" and mask.layers or prop(mask, "layers")
  if type(layers) ~= "table" then return out end
  for k, v in pairs(layers) do
    if type(k) == "string" and v then out[k] = true
    elseif type(v) == "string" then out[v] = true end
  end
  return out
end

--- Сталкивается ли постройка только с плитками (тогда с телом она не сталкивается).
function T.tiles_only(proto)
  local mask = prop(proto, "collision_mask")
  return type(mask) == "table" and mask.colliding_with_tiles_only == true
end

function T.intersects(a, b)
  for k in pairs(a) do
    if b[k] then return true end
  end
  return false
end

function T.layer_list(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

--- Маска тела: прототип самого тела (если передано), иначе прототип `character`.
function T.body_layers(entity)
  local proto = entity ~= nil and prop(entity, "prototype") or nil
  local set = T.layers_of(proto)
  if next(set) == nil then
    set = T.layers_of(prototypes.entity and prototypes.entity[T.CHARACTER] or nil)
  end
  return set
end

--- Маска постройки по имени прототипа.
function T.entity_layers(name)
  return T.layers_of(prototypes.entity and prototypes.entity[name] or nil)
end

local function first_item(proto)
  local list = prop(proto, "items_to_place_this")
  local first = type(list) == "table" and list[1] or nil
  if type(first) == "string" then return first end
  if type(first) == "table" and type(first.name) == "string" then return first.name end
  return nil
end
T.first_item = first_item

--- Открыт ли силе рецепт, дающий предмет.
function T.item_unlocked(force, item)
  if force == nil or item == nil then return false end
  local recipes = prop(force, "recipes")
  if recipes == nil then return false end
  local r = recipes[item]
  if r and r.enabled then return true end
  if prototypes.get_recipe_filtered == nil then return false end
  local ok, found = pcall(prototypes.get_recipe_filtered, {
    { filter = "has-product-item", elem_filters = { { filter = "name", name = item } } },
  })
  if ok and found then
    for recipe_name in pairs(found) do
      local rr = recipes[recipe_name]
      if rr and rr.enabled then return true end
    end
  end
  return false
end

--- Классификатор плиток с кэшем по имени: classify(tile) → info
---   info = {blocked = bool (не пройти/не построить по маске `layers`), cover = имя плитки-подложки|nil,
---           cover_item = предмет подложки|nil}
function T.classifier(layers)
  local cache = {}
  return function(tile)
    local name = tile.name
    local info = cache[name]
    if info ~= nil then return info end
    local proto = prop(tile, "prototype") or (prototypes.tile and prototypes.tile[name]) or nil
    info = { blocked = T.intersects(T.layers_of(proto), layers) }
    local cover = prop(proto, "default_cover_tile")
    if cover ~= nil then
      local cname = type(cover) == "string" and cover or prop(cover, "name")
      if type(cname) == "string" then
        info.cover = cname
        local cproto = type(cover) ~= "string" and cover or (prototypes.tile and prototypes.tile[cname]) or nil
        info.cover_item = first_item(cproto)
      end
    end
    cache[name] = info
    return info
  end
end

--- Плитки области, на которых маска `layers` сталкивается с плиткой (жидкость и т.п.).
--- Пустая маска → пусто (а не «все плитки»).
function T.find_blocked(surface, area, layers)
  local list = T.layer_list(layers)
  if #list == 0 then return {} end
  return surface.find_tiles_filtered{ area = area, collision_mask = list }
end

return T
