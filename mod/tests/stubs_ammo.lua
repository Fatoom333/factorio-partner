-- Заглушки для рефлекса ammo: турели с патронами и враги с дальностью. Дополняют stubs_c.lua.
--   local A = require("stubs_ammo"); local W = A.setup(200); A.turret(pos, n); A.worm(pos, 30)
local S = require("stubs")
local C = require("stubs_c")

local A = {}

A.AMMO = "firearm-magazine"
A.BOX = { left_top = { x = -1, y = -1 }, right_bottom = { x = 1, y = 1 } }

--- Мир stubs_c с патронами n в инвентаре помощника и прототипом турели 2×2.
function A.setup(n)
  local W = C.setup()
  prototypes.item[A.AMMO] = { name = A.AMMO, type = "ammo", stack_size = 200 }
  prototypes.entity["gun-turret"] = { name = "gun-turret", type = "ammo-turret", collision_box = A.BOX }
  if n and n > 0 then W.main.insert{ name = A.AMMO, count = n } end
  A.W = W
  return W
end

--- Своя турель с n патронами → entity, инвентарь патронов.
function A.turret(pos, n)
  local t = S.nauvis.create_entity{ name = "gun-turret", position = pos, force = "player" }
  local ti = C.inventory{ size = 10, items = (n and n > 0) and { [A.AMMO] = n } or {} }
  rawset(t, "get_inventory", function() return ti end)
  rawset(t, "can_insert", function(st) return st.name == A.AMMO end)
  rawset(t, "insert", function(st) return ti.insert(st) end)
  return t, ti
end

--- Червь силы enemy с дальностью атаки range (attack_parameters прототипа).
function A.worm(pos, range)
  local name = "worm-" .. tostring(range)
  prototypes.entity[name] = { name = name, type = "turret", attack_parameters = { range = range } }
  return S.nauvis.create_entity{ name = name, position = pos, force = "enemy" }
end

--- Позиции, где закончились задачи walk (по событиям job_done): { pos, ... }.
function A.walks()
  local out = {}
  for _, e in ipairs(C.events("job_done")) do
    if e.data["do"] == "walk" then out[#out + 1] = e.data.detail.pos end
  end
  return out
end

--- Задачи помощника h1 с req рефлекса ammo (активная и очередь).
function A.reflex_jobs()
  local out = {}
  local r = S.okr(S.req("jobs", {}, "h1"))
  if r.active ~= nil and r.active.req == "reflex:ammo" then out[#out + 1] = r.active end
  for _, j in ipairs(r.queue or {}) do
    if j.req == "reflex:ammo" then out[#out + 1] = j end
  end
  return out, r
end

return A
