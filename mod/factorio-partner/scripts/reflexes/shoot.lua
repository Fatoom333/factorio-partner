-- Рефлекс `shoot` — стрельба в бою (ревизия 3.12, просьба хозяина 15.10). Выключен, пока агент не
-- включит его по слову хозяина (partner.md, «Бой вместе с хозяином»).
--   shoot { radius?=32 (4..32), skip?:[name] (≤ 10), fire_near_own?=false }
-- Раз в проверку рефлексов (10 тиков): ближайший опасный враг (типы как у flee) в radius и в пределах
-- досягаемости одного из своих стволов → как игрок: выбрать ствол (Tab — selected_gun_index) и
-- shooting_state = shooting_enemies по позиции врага. Ствол — пара «ячейка оружия + та же ячейка
-- патронов» (так устроен инвентарь персонажа); годится, если патроны есть, враг между min_range и
-- range оружия (attack_parameters из игры) и это вообще оружие. Из годных — самый короткобойный,
-- который достаёт: вблизи огнемёт, дальше пулемёт, без имён в коде.
-- * Не оружие — ствол, чьи патроны ничего не наносят: в действии патронов (get_ammo_type().action)
--   нет ни доставки снаряда/струи/луча, ни урона, огня, стикера (так выглядят, например, «патроны»
--   наноботов — они только запускают скрипт мода). Плюс skip — имена стволов, которые не брать.
-- * Огонь (в действии патронов есть create-fire) не бьёт, если у цели в FIRE_SAFE клетках стоят свои
--   постройки или персонажи (хозяин), — если только не fire_near_own.
-- * Цели нет — стрельба выключается (shooting_state = not_shooting). Шумное reflex_fired{type:"shoot",
--   detail:{target, gun, dist}} — когда меняется цель или ствол.
-- Честно: только то, что делает игрок кнопками (выбор ствола, стрельба по точке); патроны тратит движок.
local util = require("scripts.core.util")
local events = require("scripts.core.events")
local C = require("scripts.reflexes.common")

local M = {}
M.name = "reflexes.shoot"

M.FIRE_SAFE = 6
M.DELIVERY = { projectile = true, stream = true, beam = true, artillery = true, chain = true }
M.EFFECT = { damage = true, ["create-fire"] = true, ["create-sticker"] = true }

-- Свойства патронов по имени (кэш на загрузку: прототипы не меняются в игре).
local ammo_cache = {}

local function walk(t, out, depth)
  if type(t) ~= "table" or depth > 12 then return end
  local ty = t.type
  if type(ty) == "string" then out[ty] = true end
  for _, v in pairs(t) do
    if type(v) == "table" then walk(v, out, depth + 1) end
  end
end

--- {weapon = bool, fire = bool} для патронов name.
local function ammo_info(name)
  local c = ammo_cache[name]
  if c ~= nil then return c end
  local types = {}
  local p = prototypes.item[name]
  if p ~= nil then
    local ok, at = pcall(function() return p.get_ammo_type() end)
    if ok and type(at) == "table" then walk(at.action, types, 0) end
  end
  local weapon = false
  for t in pairs(types) do
    if M.DELIVERY[t] or M.EFFECT[t] then weapon = true break end
  end
  c = { weapon = weapon, fire = types["create-fire"] == true }
  ammo_cache[name] = c
  return c
end

local function attack(gun_name)
  local p = prototypes.item[gun_name]
  local ok, ap = pcall(function() return p and p.attack_parameters end)
  if not ok or type(ap) ~= "table" then return nil end
  return ap
end

local function own_near(entity, pos)
  for _, e in ipairs(entity.surface.find_entities_filtered{ position = pos, radius = M.FIRE_SAFE, force = entity.force }) do
    if e.valid and e ~= entity and e.unit_number ~= entity.unit_number then return true end
  end
  return false
end

--- Ствол для цели на расстоянии d: индекс, имя оружия или nil.
local function pick_gun(entity, params, target, d)
  local guns = entity.get_inventory(defines.inventory.character_guns)
  local ammo = entity.get_inventory(defines.inventory.character_ammo)
  if guns == nil or ammo == nil then return nil end
  local skip = {}
  for _, n in ipairs(params.skip or {}) do skip[n] = true end
  local best, best_name, best_range
  for i = 1, #guns do
    local g, a = guns[i], ammo[i]
    if g ~= nil and g.valid_for_read and not skip[g.name] and a ~= nil and a.valid_for_read and a.count > 0 then
      local ap = attack(g.name)
      local info = ammo_info(a.name)
      if ap ~= nil and info.weapon then
        local range, min_range = ap.range or 0, ap.min_range or 0
        local fire_ok = not info.fire or params.fire_near_own or not own_near(entity, target.pos)
        if d <= range and d >= min_range and fire_ok and (best_range == nil or range < best_range) then
          best, best_name, best_range = i, g.name, range
        end
      end
    end
  end
  return best, best_name
end

local function stop(entity, st)
  if st.shoot ~= nil then
    pcall(function() entity.shooting_state = { state = defines.shooting.not_shooting } end)
    st.shoot = nil
  end
end

function M.check(id, entity, params, tick)
  local st = C.body_state(id, entity)
  local list = C.enemies(entity, params.radius)
  for _, target in ipairs(list) do
    local i, gun = pick_gun(entity, params, target, target.dist)
    if i ~= nil then
      if entity.selected_gun_index ~= i then entity.selected_gun_index = i end
      entity.shooting_state = { state = defines.shooting.shooting_enemies, position = target.pos }
      local s = st.shoot
      if s == nil or s.gun ~= gun or s.target ~= target.name or util.dist(s.pos, target.pos) > 4 then
        events.emit(id, "reflex_fired", { type = "shoot", detail = {
          target = target.name, gun = gun, dist = util.round1(target.dist),
        } })
      end
      st.shoot = { gun = gun, target = target.name, pos = { x = target.pos.x, y = target.pos.y } }
      return
    end
  end
  stop(entity, st)
end

M.reflexes = {
  shoot = {
    schema = {
      radius = { type = "number", min = 4, max = C.EYES, default = C.EYES },
      skip = { type = "list", of = { type = "string", max = 100 }, max = 10 },
      fire_near_own = { type = "bool", default = false },
    },
    check = function(id, entity, params, tick) M.check(id, entity, params, tick) end,
  },
}

return M
