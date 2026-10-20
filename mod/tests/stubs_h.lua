-- Заглушки рефлексов. Дополняют stubs.lua и stubs_b.lua (ходьба и «движок пути»).
--
--   local S = require("stubs"); local B = require("stubs_b"); local H = require("stubs_h")
--   local p, h = H.setup()            -- мод, хозяин Tartaluga в (0,0), помощник h1 в (2,0)
--   local biter = H.enemy({ x = -8, y = 0 })            -- сущность силы enemy
--   H.damage(h, 30, biter)            -- урон: health -= 30, on_entity_damaged; здоровье 0 -> die()
--   H.set{ { type = "flee" } }        -- reflexes{set} помощнику h1
--   H.wait("reflex_done")             -- тикать (B.tick), пока не появится событие; вернуть его
local S = require("stubs")
local B = require("stubs_b")

local H = {}

function H.setup(opts)
  local p, h = B.setup(opts)
  S.add_prototype("entity", { name = "small-demolisher", type = "segmented-unit", max_health = 30000 })
  S.add_prototype("entity", { name = "small-demolisher-segment", type = "segment", max_health = 30000 })
  S.add_prototype("entity", { name = "biter-spawner", type = "unit-spawner", max_health = 350 })
  S.add_prototype("entity", { name = "small-worm-turret", type = "turret", max_health = 200 })
  S.add_prototype("entity", { name = "small-strafer-pentapod", type = "spider-unit", max_health = 1200 })
  -- порог отступления из настроек мода тут не предмет проверки: отступать при любом здоровье, как в схеме до настроек
  settings.global["partner-flee-health"] = { value = 100 }
  return p, h
end

--- Сущность силы enemy (по умолчанию small-biter).
function H.enemy(pos, name, surface)
  return (surface or S.nauvis).create_entity{ name = name or "small-biter", position = pos, force = "enemy" }
end

--- Урон как в игре: здоровье уже уменьшено, затем on_entity_damaged; при нуле — смерть.
--- cause — LuaEntity или nil (огонь, яд); dtype — имя типа урона.
function H.damage(entity, amount, cause, dtype)
  local health = math.max(0, (entity.health or 0) - amount)
  entity.health = health
  S.fire(defines.events.on_entity_damaged, {
    entity = entity, final_damage_amount = amount, original_damage_amount = amount, final_health = health,
    cause = cause, force = cause and cause.force or nil, damage_type = { name = dtype or "physical" },
  })
  if health <= 0 and entity.valid then entity.die(cause and cause.force or nil, cause) end
end

function H.set(list, helper)
  return S.okr(S.req("reflexes", { set = list }, helper or "h1")).set
end

function H.body(helper)
  return storage.helpers[helper or "h1"].entity
end

H.tick = B.tick
H.events = B.events

--- Последнее событие вида kind (или nil).
function H.last(kind)
  local list = B.events(kind)
  return list[#list]
end

--- Тикать, пока событий вида kind не станет n (по умолчанию 1); вернуть n-е.
function H.wait(kind, n, max)
  n = n or 1
  local got
  B.until_(function()
    got = B.events(kind)[n]
    return got ~= nil
  end, max or 3000)
  return got
end

--- Виды событий по порядку (для сообщений об ошибках).
function H.kinds()
  local out = {}
  for _, e in ipairs(B.events()) do out[#out + 1] = e.kind end
  return table.concat(out, ",")
end

return H
