-- Рефлекс ammo — заправщик турелей и подход с дальней от врага стороны.
local S = require("stubs")
local C = require("stubs_c")

local AMMO = "firearm-magazine"

local function setup(n)
  local W = C.setup()
  prototypes.item[AMMO] = { name = AMMO, type = "ammo", stack_size = 200 }
  prototypes.entity["gun-turret"] = { name = "gun-turret", type = "ammo-turret" }
  prototypes.entity["small-biter"] = { name = "small-biter", type = "unit" }
  if n and n > 0 then W.main.insert{ name = AMMO, count = n } end
  return W
end

local function turret(pos, n)
  local t = S.nauvis.create_entity{ name = "gun-turret", position = pos, force = "player" }
  local ti = C.inventory{ size = 10, items = (n and n > 0) and { [AMMO] = n } or {} }
  rawset(t, "get_inventory", function() return ti end)
  rawset(t, "can_insert", function(st) return st.name == AMMO end)
  rawset(t, "insert", function(st) return ti.insert(st) end)
  return t, ti
end

local function set(list) return S.okr(S.req("reflexes", { set = list }, "h1")).set end

S.suite("reflex_ammo", {
  { "турель рядом: патроны из инвентаря до fill, по одной турели, шумное reflex_fired", function()
      local W = setup(100)
      local p = S.norm_pos(W.h.position)
      local _, ti = turret({ x = p.x + 4, y = p.y }, 0)
      local _, ti2 = turret({ x = p.x - 4, y = p.y }, 20)
      set{ { type = "ammo", min = 10, fill = 30 } }
      C.run(120)
      S.eq(ti.get_item_count(), 30)
      S.eq(ti2.get_item_count(), 20, "в этой больше min — не трогал")
      S.eq(W.main.get_item_count(AMMO), 70)
      local f = C.events("reflex_fired")
      S.ok(#f >= 1 and f[1].data.type == "ammo", S.dump(f))
      S.eq(f[1].loud, false)
      S.eq(#W.path.calls, 0, "без ходьбы")
  end },
  { "турель далеко и очередь пуста: сам ставит insert и подходит", function()
      local W = setup(100)
      local p = S.norm_pos(W.h.position)
      local _, ti = turret({ x = p.x + 18, y = p.y }, 0)
      set{ { type = "ammo", radius = 20, min = 10, fill = 30 } }
      for _ = 1, 2000 do
        C.run(1)
        if ti.get_item_count() >= 30 then break end
      end
      S.eq(ti.get_item_count(), 30)
      S.ok(#W.path.calls > 0, "подходил")
  end },
  { "патронов нет: громкое ammo_low один раз (не чаще раза в минуту)", function()
      setup(0)
      local W = C.W
      local p = S.norm_pos(W.h.position)
      turret({ x = p.x + 4, y = p.y }, 0)
      set{ { type = "ammo", item = AMMO, chests = false } }
      C.run(300)
      local ev = C.events("ammo_low")
      S.eq(#ev, 1)
      S.eq(ev[1].loud, true)
      S.eq(ev[1].data.item, AMMO)
  end },
  { "подход к постройке, когда рядом враг: с дальней от него стороны", function()
      local W = setup(10)
      local p = S.norm_pos(W.h.position)
      local ch = C.chest({ x = p.x + 12, y = p.y }, {})
      S.nauvis.create_entity{ name = "small-biter", position = { x = p.x + 12, y = p.y - 20 }, force = "enemy" }
      local job = S.okr(C.act("insert", { target = { unit_number = ch.unit_number }, items = { [AMMO] = 5 } })).job
      local d, kind = C.wait(job)
      S.eq(kind, "job_done", S.dump(d))
      local b = { x = W.h.position.x - (p.x + 12), y = W.h.position.y - p.y }
      local len = math.sqrt(b.x * b.x + b.y * b.y)
      S.ok(b.y >= 1 and b.y >= 0.7 * len, "встал за сундуком (враг на севере), в секторе ±45°: " .. S.dump(W.h.position))
  end },
})
