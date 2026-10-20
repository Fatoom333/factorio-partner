-- pickup{corpse:true}: свой последний труп по записи рефлекса смерти; после трупа — броня из
-- карманов сама в пустой слот (лучшая, с модулями); рефлекс возрождения надевает броню из карманов.
local S = require("stubs")
local C = require("stubs_c")
local A = require("stubs_armor")
local H = require("stubs_h")
local B = require("stubs_b")

local PA = "power-armor-mk2"

local function pickup(args) return S.okr(C.act("pickup", args)).job end

local function corpse(pos, items, tick, force)
  local e = S.nauvis.create_entity{ name = "character-corpse", position = pos, force = force or "player" }
  e.inventories = { [defines.inventory.character_corpse] = C.inventory{ size = 20, items = items } }
  e.character_corpse_tick_of_death = tick
  rawset(e, "unit_number", nil) -- у трупа в игре номера нет
  return e
end

--- Запись «последний труп» — как её оставляет рефлекс смерти.
local function record(pos, tick)
  storage.reflex_state = storage.reflex_state or {}
  storage.reflex_state.h1 = storage.reflex_state.h1 or {}
  storage.reflex_state.h1.corpse = { pos = pos, surface = S.nauvis.index, tick = tick }
end

S.suite("hands_corpse", {
  { "смерть пишет последний труп: место трупа, поверхность и тик смерти", function()
      local _, h = H.setup()
      S.move(h, { x = 20.26, y = -7.04 })
      B.tick(15)
      H.damage(h, 300, H.enemy({ x = 21, y = -7 }))
      local rec = require("scripts.reflexes.death").last_corpse("h1")
      S.eq(rec, { pos = { x = 20.3, y = -7 }, surface = S.nauvis.index, tick = 15 })
      local c = S.nauvis.find_entities_filtered{ type = "character-corpse" }[1]
      S.eq(c.character_corpse_tick_of_death, rec.tick)
      B.tick(700) -- возрождение запись не стирает
      S.eq(storage.helpers.h1.state, "alive")
      S.eq(require("scripts.reflexes.death").last_corpse("h1").tick, 15)
  end },

  { "corpse:true: подходит к своему трупу и забирает всё; лучшая броня из него надета с модулями", function()
      local g_mk2, g_mod = A.grid(10, 10), A.grid(5, 5)
      local W = A.setup{}
      g_mk2.put{ name = "exoskeleton-equipment" }
      g_mk2.put{ name = "energy-shield-equipment" }
      local c = corpse({ x = 30.5, y = 4.5 }, {
        { name = "modular-armor", count = 1, data = g_mod },
        { name = PA, count = 1, data = g_mk2 },
        { name = "coal", count = 12 },
      }, 100)
      record({ x = 30, y = 4 }, 100)
      local d, kind = C.wait(pickup{ corpse = true })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.picked, { ["modular-armor"] = 1, [PA] = 1, coal = 12 })
      S.eq(d.detail.equipped, PA)
      S.eq(d.detail.armor, { name = PA, grid = { w = 10, h = 10, used = 12, free = 88,
        equipment = { ["exoskeleton-equipment"] = 1, ["energy-shield-equipment"] = 1 } } })
      S.eq(W.armor[1].name, PA)
      S.ok(W.armor[1].grid == g_mk2, "сетка с модулями переехала вместе с бронёй")
      S.eq(C.counts(W.main), { ["modular-armor"] = 1, coal = 12 })
      S.ok(c.get_inventory(defines.inventory.character_corpse).is_empty())
      S.ok(W.h.can_reach_entity(c), "подошёл к трупу")
      -- второй раз тот же труп не ищется
      local d2 = C.wait(pickup{ corpse = true })
      S.eq(d2.code, "not_found")
      S.eq(d2.detail.pos, { x = 30, y = 4 })
  end },

  { "corpse:true: слот брони занят — броня из трупа только в карманы", function()
      local W = A.setup{ armor = { { name = "modular-armor", grid = A.grid(5, 5) } } }
      corpse({ x = 10.5, y = 0.5 }, { { name = PA, count = 1, data = A.grid(10, 10) } }, 50)
      record({ x = 10.5, y = 0.5 }, 50)
      local d, kind = C.wait(pickup{ corpse = true })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { picked = { [PA] = 1 } })
      S.eq(W.armor[1].name, "modular-armor")
  end },

  { "corpse:true: чужие трупы рядом не берутся — только с тиком своей смерти", function()
      local W = A.setup{}
      local owner_corpse = corpse({ x = 20.5, y = 0.5 }, { { name = "coal", count = 5 } }, 70)   -- хозяин, раньше
      local other = corpse({ x = 21.5, y = 0.5 }, { { name = "stone", count = 5 } }, 90)         -- другой помощник
      local mine = corpse({ x = 22.5, y = 0.5 }, { { name = "iron-plate", count = 3 } }, 80)
      record({ x = 21, y = 0.5 }, 80)
      local d, kind = C.wait(pickup{ corpse = true })
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { picked = { ["iron-plate"] = 3 } })
      S.eq(C.counts(owner_corpse.get_inventory(defines.inventory.character_corpse)), { coal = 5 })
      S.eq(C.counts(other.get_inventory(defines.inventory.character_corpse)), { stone = 5 })
      S.ok(mine.get_inventory(defines.inventory.character_corpse).is_empty())
      S.eq(C.counts(W.main), { ["iron-plate"] = 3 })
  end },

  { "corpse:true: записи нет — not_found; трупа на месте нет — not_found с координатами", function()
      A.setup{}
      local d = C.wait(pickup{ corpse = true })
      S.eq(d.code, "not_found")
      record({ x = 40, y = 2 }, 33)
      corpse({ x = 40.5, y = 2.5 }, { { name = "coal", count = 1 } }, 34) -- чужой тик
      local d2 = C.wait(pickup{ corpse = true })
      S.eq(d2.code, "not_found")
      S.eq(d2.detail.pos, { x = 40, y = 2 })
      S.eq(d2.detail.surface, "nauvis")
  end },

  { "аргументы: corpse вместе с target/area или corpse:false — bad_args; не bool — bad_args", function()
      A.setup{}
      S.eq(C.wait(pickup{ corpse = true, area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 1, y = 1 } } }).code, "bad_args")
      S.eq(C.wait(pickup{ corpse = true, target = { name = "character-corpse", pos = { x = 1, y = 1 } } }).code, "bad_args")
      S.eq(C.wait(pickup{ corpse = false }).code, "bad_args")
      S.err(C.act("pickup", { corpse = "yes" }), "bad_args")
  end },

  { "после возрождения: броня в карманах, слот пуст — рефлекс надевает лучшую, armor_equipped", function()
      local g = A.grid(10, 10)
      local W = A.setup{ items = { { name = "light-armor" }, { name = PA, grid = g } } }
      storage.reflex_state = { h1 = { rearm = { dead_unit = -1 } } }
      C.run(61)
      S.eq(W.armor[1].name, PA)
      local ev = C.events("armor_equipped")
      S.eq(#ev, 1)
      S.eq(ev[1].data.item, PA)
      S.eq(ev[1].loud, false)
      S.eq(storage.reflex_state.h1.rearm, nil, "больше не смотрит")
  end },

  { "после возрождения: брони нет — ждёт до 10 мин; надели сами — перестаёт смотреть", function()
      local W = A.setup{}
      storage.reflex_state = { h1 = { rearm = { dead_unit = -1 } } }
      C.run(61)
      S.ok(storage.reflex_state.h1.rearm ~= nil, "ещё ждёт")
      W.main.insert{ name = "coal", count = 1 }
      W.armor[1].set("modular-armor", 1, "normal", A.grid(5, 5))
      C.run(60)
      S.eq(storage.reflex_state.h1.rearm, nil)
      S.eq(#C.events("armor_equipped"), 0)
  end },
})
