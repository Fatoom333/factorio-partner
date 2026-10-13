-- Рефлексы потока H: смерть (died) и возрождение (respawned). PROTOCOL §6.9, §7; EVENTS.md.
local S = require("stubs")
local B = require("stubs_b")
local H = require("stubs_h")

local function death_mod() return require("scripts.reflexes.death") end

local function state(helper)
  for _, h in ipairs(S.okr(S.req("helper_list")).helpers) do
    if h.id == (helper or "h1") then return h end
  end
  return nil
end

S.suite("reflex_death", {
  { "обработчики смерти зарегистрированы с фильтром type=character, ядро — после модуля", function()
      H.setup()
      for _, name in ipairs({ "on_entity_died", "on_post_entity_died" }) do
        local h = S.handlers[defines.events[name]]
        S.ok(h, name)
        for _, f in ipairs(h.filters) do S.eq(f, { filter = "type", type = "character" }) end
      end
      S.eq(death_mod().reflexes, {}, "смерть и возрождение — не типы набора")
  end },

  { "смерть от урона: died{pos, corpse}, задачи сняты no_helper, вещи в трупе", function()
      local _, h = H.setup()
      S.move(h, { x = 20.26, y = -7.04 })
      h.insert{ name = "iron-plate", count = 7 }
      local job = B.act("wait", { seconds = 60 }).job
      B.tick(15)
      local biter = H.enemy({ x = 21, y = -7 })
      H.damage(h, 300, biter)
      local died = B.events("died")
      S.eq(#died, 1)
      S.eq(died[1].loud, true)
      S.eq(died[1].helper, "h1")
      S.eq(died[1].tick, 15)
      S.eq(died[1].data, { pos = { x = 20.3, y = -7 }, corpse = { x = 20.3, y = -7 } })
      S.eq(B.result(job).data.code, "no_helper")
      S.eq(storage.helpers.h1.state, "dead")
      S.eq(state().state, "dead")
      local corpse = S.nauvis.find_entities_filtered{ type = "character-corpse" }[1]
      S.eq(corpse.get_inventory(defines.inventory.character_corpse).get_item_count("iron-plate"), 7)
      S.err(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1"), "no_helper")
  end },

  { "возрождение через 600 тиков у точки возрождения силы: пустой инвентарь, respawned{pos}", function()
      local _, h = H.setup()
      h.force.set_spawn_position({ x = -50.5, y = 12.5 }, S.nauvis)
      S.move(h, { x = 20, y = 0 })
      h.insert{ name = "iron-plate", count = 7 }
      H.set{ { type = "flee" } }
      B.tick(15)
      local old_unit = h.unit_number
      H.damage(h, 300, H.enemy({ x = 21, y = 0 }))
      local created = #S.nauvis.created
      B.tick(595) -- тик 610: 15 + 600 = 615 ещё не наступил
      S.eq(storage.helpers.h1.state, "dead")
      S.eq(#B.events("respawned"), 0)
      S.eq(#S.nauvis.created, created, "раньше срока тело не создаётся")
      B.tick(10) -- тик 620: первая проверка после 615
      local ev = B.events("respawned")
      S.eq(#ev, 1)
      S.eq(ev[1].loud, true)
      S.eq(ev[1].helper, "h1")
      S.eq(ev[1].tick, 620)
      S.eq(ev[1].data, { pos = { x = -50.5, y = 12.5 } })
      local rec = storage.helpers.h1
      S.eq(rec.state, "alive")
      local body = rec.entity
      S.ok(body.valid and body ~= h and body.unit_number ~= old_unit, "новое тело")
      S.eq(body.name, "character")
      S.eq(body.position, { x = -50.5, y = 12.5 })
      S.ok(body.force == h.force, "та же сила")
      S.ok(body.surface == S.nauvis, "та же поверхность")
      S.eq(body.get_main_inventory().is_empty(), true, "пустой инвентарь")
      local params = S.nauvis.created[#S.nauvis.created]
      S.eq(params.name, "character")
      S.eq(params.quality, "normal")
      S.eq(params.raise_built, nil)
      S.eq(#S.nauvis.created, created + 1, "создано ровно одно тело")
      local corpse = S.nauvis.find_entities_filtered{ type = "character-corpse" }[1]
      S.eq(corpse.get_inventory(defines.inventory.character_corpse).get_item_count("iron-plate"), 7, "вещи остались в трупе")
      S.eq(state().state, "alive")
      S.eq(state().pos, { x = -50.5, y = 12.5 })
      S.eq(storage.reflex_state.h1.death, nil)
      -- набор рефлексов пережил смерть, новое тело слушается
      S.eq(#storage.reflexes.h1, 1)
      local job = B.act("walk", { to = { x = -45, y = 12.5 } }).job
      S.eq(B.run(job, 500).kind, "job_done")
      H.damage(body, 10, H.enemy({ x = -80, y = 12.5 }))
      S.eq(H.last("attacked").loud, true, "у нового тела — новый эпизод")
      S.eq(#B.events("reflex_fired"), 1, "и рефлекс flee работает")
      B.tick(700)
      S.eq(#B.events("respawned"), 1)
      S.eq(#B.events("died"), 1)
  end },

  { "смерть на другой поверхности — возрождение на ней же, у её точки", function()
      local p, h = H.setup()
      local vulcanus = S.surface{ name = "vulcanus" }
      h.force.set_spawn_position({ x = 7, y = 7 }, vulcanus)
      h.force.set_spawn_position({ x = -99, y = -99 }, S.nauvis)
      S.nauvis._remove(h)
      h.surface = vulcanus
      vulcanus._entities[#vulcanus._entities + 1] = h
      B.tick(5)
      H.damage(h, 300)
      B.tick(610)
      local body = H.body()
      S.ok(body.surface == vulcanus, "поверхность смерти")
      S.eq(body.position, { x = 7, y = 7 })
      S.eq(state().surface, "vulcanus")
  end },

  { "helper_remove: не смерть — ни died, ни возрождения", function()
      local _, h = H.setup()
      B.tick(5)
      S.okr(S.req("helper_remove", {}, "h1"))
      B.tick(700)
      S.eq(#B.events("died"), 0)
      S.eq(#B.events("respawned"), 0)
      S.eq(storage.helpers.h1.state, "removed")
      S.eq(storage.reflex_state.h1, nil)
  end },

  { "helper_remove мёртвого до срока — возрождение отменено", function()
      local _, h = H.setup()
      B.tick(5)
      H.damage(h, 300)
      B.tick(100)
      S.okr(S.req("helper_remove", {}, "h1"))
      local created = #S.nauvis.created
      B.tick(700)
      S.eq(#B.events("died"), 1)
      S.eq(#B.events("respawned"), 0)
      S.eq(#S.nauvis.created, created)
      S.eq(storage.helpers.h1.state, "removed")
  end },

  { "нет места у точки возрождения — повтор каждые 5 с; потом получается", function()
      local _, h = H.setup()
      B.tick(5)
      H.damage(h, 300)
      S.nauvis.non_colliding = false
      B.tick(1200)
      S.eq(storage.helpers.h1.state, "dead")
      S.eq(#B.events("respawned"), 0)
      S.eq(storage.reflex_state.h1.death.retries, 2, "тики 610 и 910")
      local seen
      S.nauvis.non_colliding = function(surface, name, center, radius, precision)
        seen = { name = name, center = center, radius = radius }
        return { x = center.x + 3, y = center.y }
      end
      B.tick(10)
      S.eq(#B.events("respawned"), 1)
      S.eq(seen, { name = "character", center = { x = 0, y = 0 }, radius = 16 })
      S.eq(H.body().position, { x = 3, y = 0 })
      S.eq(H.last("respawned").data.pos, { x = 3, y = 0 })
  end },

  { "места нет совсем — reflex_done{respawn, failed, no_place}, помощник остаётся мёртвым", function()
      local _, h = H.setup()
      B.tick(5)
      H.damage(h, 300)
      S.nauvis.non_colliding = false
      B.tick(600 + 300 * 12) -- тик 4205: попытки 610, 910, … 3910 — двенадцать
      S.eq(#B.events("reflex_done"), 0)
      S.eq(storage.reflex_state.h1.death.retries, 12)
      B.tick(10)             -- тик 4210: тринадцатая — отказ
      local done = B.events("reflex_done")
      S.eq(#done, 1)
      S.eq(done[1].data, { type = "respawn", outcome = "failed", detail = { reason = "no_place" } })
      S.nauvis.non_colliding = nil
      B.tick(1000)
      S.eq(#B.events("respawned"), 0)
      S.eq(storage.helpers.h1.state, "dead")
  end },

  { "поверхность удалена — reflex_done{respawn, failed, surface_gone}", function()
      local _, h = H.setup()
      B.tick(5)
      H.damage(h, 300)
      S.nauvis.valid = false
      B.tick(620)
      local done = B.events("reflex_done")
      S.eq(#done, 1)
      S.eq(done[1].data.detail.reason, "surface_gone")
      S.eq(#B.events("respawned"), 0)
  end },

  { "сохранение/загрузка между смертью и возрождением", function()
      local _, h = H.setup()
      B.tick(5)
      H.damage(h, 300)
      B.tick(300)
      S.reload()
      B.tick(320)
      S.eq(#B.events("respawned"), 1)
      S.eq(storage.helpers.h1.state, "alive")
  end },

  { "on_post_entity_died не пришёл — died уходит на следующей проверке, без corpse", function()
      local _, h = H.setup()
      B.tick(5)
      S.fire(defines.events.on_entity_died, { entity = h })
      S.eq(storage.helpers.h1.state, "dead")
      S.eq(#B.events("died"), 0)
      B.tick(5)
      local died = B.events("died")
      S.eq(#died, 1)
      S.eq(died[1].data, { pos = { x = 2, y = 0 } })
      B.tick(10)
      S.eq(#B.events("died"), 1)
  end },

  { "смерть игрока и чужого персонажа — мимо", function()
      local p, h = H.setup()
      local other = S.nauvis.create_entity{ name = "character", position = { 9, 9 }, force = "player" }
      other.die()
      p.character.die()
      B.tick(700)
      S.eq(#B.events("died"), 0)
      S.eq(#B.events("respawned"), 0)
      S.eq(next(storage.reflex_state or {}), nil, "состояние не заводилось")
  end },

  { "умер и возродился дважды; перезарядка helper_spawn возрождению не мешает", function()
      local _, h = H.setup()
      B.tick(5)
      H.damage(h, 300)
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      B.tick(610)
      local b1 = H.body()
      S.eq(storage.helpers.h1.state, "alive")
      S.err(S.req("helper_spawn", {}, "h1"), "helper_exists")
      H.damage(b1, 300)
      B.tick(610)
      S.eq(#B.events("died"), 2)
      S.eq(#B.events("respawned"), 2)
      S.ok(H.body() ~= b1 and H.body().valid)
  end },

  { "без переноса и предметов из воздуха: модуль не зовёт insert и не двигает тела", function()
      local _, h = H.setup()
      B.tick(5)
      H.damage(h, 300)
      B.tick(610)
      local body = H.body()
      for idx, inv in pairs(body.inventories) do
        S.eq(inv.is_empty(), true, "инвентарь " .. tostring(idx))
      end
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },
})
