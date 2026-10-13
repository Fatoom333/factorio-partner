-- Рефлексы потока H: attacked (первое в эпизоде громкое), health_low. EVENTS.md.
local S = require("stubs")
local B = require("stubs_b")
local H = require("stubs_h")

S.suite("reflex_attack", {
  { "обработчик урона зарегистрирован с фильтром type=character", function()
      H.setup()
      local h = S.handlers[defines.events.on_entity_damaged]
      S.ok(h, "нет обработчика on_entity_damaged")
      S.eq(h.filters, { { filter = "type", type = "character" } })
      S.eq(S.unknown_events, {}, "все defines.events известны")
  end },

  { "первый урон — громкое attacked{by, damage, health}; набор рефлексов не нужен", function()
      local _, h = H.setup()
      local biter = H.enemy({ x = 3, y = 0 })
      S.tick(7)
      H.damage(h, 12.34, biter)
      local evs = H.events("attacked")
      S.eq(#evs, 1)
      S.eq(evs[1].helper, "h1")
      S.eq(evs[1].loud, true)
      S.eq(evs[1].data, { by = "small-biter", damage = 12.3, health = 237.7 })
      S.eq(evs[1].tick, 7)
  end },

  { "повторные в эпизоде — шумные, не чаще раза в секунду, урон суммируется", function()
      local _, h = H.setup()
      local biter = H.enemy({ x = 3, y = 0 })
      H.damage(h, 5, biter)
      for _ = 1, 59 do
        S.tick(1)
        H.damage(h, 1, biter)
      end
      S.eq(#H.events("attacked"), 1, "59 тиков — только первое")
      S.tick(1)
      H.damage(h, 1, biter)
      local evs = H.events("attacked")
      S.eq(#evs, 2)
      S.eq(evs[2].loud, false)
      S.eq(evs[2].data.damage, 60)
      S.eq(evs[2].data.health, 250 - 65)
      S.tick(60)
      H.damage(h, 2, biter)
      evs = H.events("attacked")
      S.eq(#evs, 3)
      S.eq({ evs[3].loud, evs[3].data.damage }, { false, 2 })
  end },

  { "эпизод кончается через 30 с без урона — следующее attacked снова громкое", function()
      local _, h = H.setup()
      local biter = H.enemy({ x = 3, y = 0 })
      H.damage(h, 5, biter)
      S.tick(1799)
      H.damage(h, 5, biter)
      S.eq(H.last("attacked").loud, false, "29,98 с — тот же эпизод")
      S.tick(1801)
      S.eq(storage.reflex_state.h1.attack, nil, "эпизод закрыт проверкой раз в 10 тиков")
      H.damage(h, 5, biter)
      local evs = H.events("attacked")
      S.eq(#evs, 3)
      S.eq(evs[3].loud, true)
  end },

  { "урон без виновника: by — тип урона; без типа — unknown", function()
      local _, h = H.setup()
      H.damage(h, 3, nil, "fire")
      S.eq(H.last("attacked").data.by, "fire")
      S.tick(1800)
      S.fire(defines.events.on_entity_damaged, { entity = h, final_damage_amount = 1, final_health = 246 })
      S.eq(H.last("attacked").data.by, "unknown")
  end },

  { "чужие персонажи, удалённый помощник, нулевой урон — событий нет", function()
      local p, h = H.setup()
      local biter = H.enemy({ x = 3, y = 0 })
      H.damage(p.character, 10, biter)
      S.fire(defines.events.on_entity_damaged, { entity = h, final_damage_amount = 0, original_damage_amount = 0, final_health = 250 })
      S.fire(defines.events.on_entity_damaged, { entity = biter, final_damage_amount = 5, final_health = 10 })
      S.eq(#H.events("attacked"), 0)
      storage.helpers.h1.state = "removed"
      H.damage(h, 10, biter)
      S.eq(#H.events("attacked"), 0)
  end },

  { "health_low: здоровье < 40 % — один раз, громко; снова — после восстановления до 50 %", function()
      local _, h = H.setup()
      local biter = H.enemy({ x = 3, y = 0 })
      H.damage(h, 150, biter) -- 100/250 = 40 % — ещё не ниже
      S.eq(#H.events("health_low"), 0)
      H.damage(h, 1, biter)
      local evs = H.events("health_low")
      S.eq(#evs, 1)
      S.eq(evs[1].loud, true)
      S.eq(evs[1].data, { health = 99, max = 250 })
      H.damage(h, 20, biter)
      S.tick(30)
      S.eq(#H.events("health_low"), 1, "повторно не шлём")
      h.health = 110 -- 44 %: выше порога, но ниже 50 % — не перевзводим
      S.tick(10)
      H.damage(h, 30, biter)
      S.eq(#H.events("health_low"), 1)
      h.health = 130 -- 52 %
      S.tick(10)
      H.damage(h, 40, biter)
      S.eq(#H.events("health_low"), 2)
      S.eq(H.last("health_low").data.health, 90)
  end },

  { "смертельный удар: attacked есть, health_low нет", function()
      local _, h = H.setup()
      local biter = H.enemy({ x = 3, y = 0 })
      H.damage(h, 999, biter)
      S.eq(#H.events("attacked"), 1)
      S.eq(H.last("attacked").data.health, 0)
      S.eq(#H.events("health_low"), 0)
      S.eq(#H.events("died"), 1)
  end },

  { "состояние переживает сохранение/загрузку: эпизод тот же, в storage нет функций и LuaEntity", function()
      local _, h = H.setup()
      local biter = H.enemy({ x = 3, y = 0 })
      H.damage(h, 5, biter)
      S.tick(100)
      S.reload()
      local function scan(v, path)
        if type(v) == "table" then
          S.ok(not S.is_lua_object(v), "LuaObject в " .. path)
          for k, x in pairs(v) do scan(x, path .. "." .. tostring(k)) end
        end
      end
      scan(storage.reflex_state, "storage.reflex_state")
      H.damage(h, 5, biter)
      local evs = H.events("attacked")
      S.eq(#evs, 2)
      S.eq(evs[2].loud, false)
  end },

  { "состояние удалённого помощника убирается", function()
      local _, h = H.setup()
      H.damage(h, 5, H.enemy({ x = 3, y = 0 }))
      S.ok(storage.reflex_state.h1)
      S.okr(S.req("helper_remove", {}, "h1"))
      S.tick(10)
      S.eq(storage.reflex_state.h1, nil)
      S.eq(#H.events("died"), 0, "helper_remove — не смерть")
  end },
})
