-- Помощники и хозяин: helper_spawn/remove/list, перезарядка, смерть, потеря тела (PROTOCOL §4, §6.9, §7).
local S = require("stubs")

local COOLDOWN = 5 * 60 * 60

S.suite("helpers", {
  { "spawn: рядом с хозяином, его поверхность и сила, пустой инвентарь", function()
      S.load_mod()
      local vulc = S.surface{ name = "vulcanus" }
      local p = S.add_player{ name = "Tartaluga", surface = vulc, position = { 100, 50 } }
      local d = S.okr(S.req("helper_spawn", {}, "h1"))
      S.eq(d.helper, "h1")
      S.eq(d.surface, "vulcanus")
      S.ok(S.dist(d.pos, { x = 100, y = 50 }) <= 10)
      local rec = storage.helpers.h1
      S.eq(rec.state, "alive")
      S.eq(rec.unit_number, d.unit_number)
      S.eq(rec.entity.force, p.force)
      S.eq(rec.entity.get_main_inventory().is_empty(), true)
      S.eq(rec.entity.surface, vulc)
  end },
  { "spawn: хозяин из настройки partner-owner, физическая позиция", function()
      S.load_mod()
      S.add_player{ name = "First", position = { 0, 0 } }
      local own = S.add_player{ name = "Owner", position = { 500, 500 } }
      settings.global["partner-owner"] = { value = "Owner" }
      own.position = { x = -999, y = -999 } -- камера удалённого вида; тело стоит на 500,500
      local d = S.okr(S.req("helper_spawn", {}, "h1"))
      S.ok(S.dist(d.pos, { x = 500, y = 500 }) <= 10, S.dump(d.pos))
      S.eq(S.okr(S.req("hello")).owner, "Owner")
  end },
  { "spawn: хозяина нет в сейве / онлайн без тела -> no_player", function()
      S.load_mod()
      S.err(S.req("helper_spawn", {}, "h1"), "no_player")
      local p = S.add_player{ name = "Tartaluga" }
      p.character = nil
      S.err(S.req("helper_spawn", {}, "h1"), "no_player", "онлайн, но без тела")
      settings.global["partner-owner"] = { value = "Nobody" }
      S.err(S.req("helper_spawn", {}, "h1"), "no_player", "такого игрока в сейве нет")
      S.eq(storage.helpers.h1, nil)
  end },
  { "spawn: хозяин офлайн (ревизия 3) — у его последней позиции на его поверхности", function()
      S.load_mod()
      local vulc = S.surface{ name = "vulcanus" }
      local p = S.add_player{ name = "Tartaluga", surface = vulc, position = { 300, -40 }, connected = false }
      p.position = { x = 5, y = 5 } -- камера не в счёт: берётся physical_position
      local d = S.okr(S.req("helper_spawn", {}, "h1"))
      S.eq(d.surface, "vulcanus")
      S.ok(S.dist(d.pos, { x = 300, y = -40 }) <= 10, S.dump(d.pos))
      S.eq(storage.helpers.h1.entity.force, p.force)
      S.eq(storage.helpers.h1.entity.get_main_inventory().is_empty(), true)
      -- тот же поиск места ≤ 10 клеток: нет места -> cannot_place
      S.nauvis.non_colliding = false
      vulc.non_colliding = false
      S.err(S.req("helper_spawn", {}, "h2"), "cannot_place")
      -- и пара remove -> spawn остаётся за перезарядкой
      S.okr(S.req("helper_remove", {}, "h1"))
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
  end },
  { "spawn: нет места рядом -> cannot_place; слишком далеко -> cannot_place", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.nauvis.non_colliding = false
      S.err(S.req("helper_spawn", {}, "h1"), "cannot_place")
      S.nauvis.non_colliding = function() return { x = 30, y = 0 } end
      S.err(S.req("helper_spawn", {}, "h1"), "cannot_place")
      S.eq(storage.helpers.h1, nil)
  end },
  { "spawn: живой с этим id -> helper_exists; лимит живых", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.err(S.req("helper_spawn", {}, "h1"), "helper_exists")
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.okr(S.req("helper_spawn", {}, "h3"))
      S.okr(S.req("helper_spawn", {}, "h4"))
      S.err(S.req("helper_spawn", {}, "h5"), "limit")
  end },
  { "spawn: лишние аргументы -> bad_args", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.err(S.req("helper_spawn", { pos = { x = 1, y = 1 } }, "h1"), "bad_args")
  end },
  { "remove: state=removed ДО die(), труп с вещами, перезарядка 5 мин", function()
      local seen_state
      S.load_mod{ replace = { ["scripts.reflexes.death"] = {
        events = { [defines.events.on_entity_died] = {
          handler = function(e) seen_state = storage.helpers.h1 and storage.helpers.h1.state end,
          filter = { { filter = "type", type = "character" } } } },
      } } }
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      local body = storage.helpers.h1.entity
      body.insert{ name = "iron-plate", count = 7 }
      local d = S.okr(S.req("helper_remove", {}, "h1"))
      S.eq(seen_state, "removed")
      S.ok(d.corpse ~= nil, "есть труп")
      S.eq(body.valid, false)
      local corpse = S.nauvis.find_entities_filtered{ type = "character-corpse" }[1]
      S.eq(corpse.get_inventory(defines.inventory.character_corpse).get_item_count("iron-plate"), 7)
      S.eq(storage.helpers.h1.state, "removed")
      S.err(S.req("helper_remove", {}, "h1"), "no_helper")
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(COOLDOWN - 1)
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(1)
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.tick()
      -- старое on_object_destroyed не трогает новое тело
      S.eq(storage.helpers.h1.state, "alive")
  end },
  { "remove: снимает задачи с cancelled и резервы", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.req("act", { ["do"] = "wait", args = { seconds = 100 } }, "h1")
      S.req("act", { ["do"] = "wait", args = { seconds = 100 } }, "h1")
      S.tick(2)
      require("scripts.core.reserve").add_items("h1", { coal = 5 })
      S.okr(S.req("helper_remove", {}, "h1"))
      local ev = S.okr(S.req("events", { since = 0 })).events
      S.eq(#ev, 2)
      S.eq({ ev[1].kind, ev[1].data.code, ev[2].kind, ev[2].data.code }, { "job_failed", "cancelled", "job_failed", "cancelled" })
      S.eq(storage.reservations.items.h1, nil)
  end },
  { "смерть: state=dead, задачи no_helper, перезарядка от смерти, труп", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.req("act", { ["do"] = "wait", args = { seconds = 100 } }, "h1")
      S.tick(5)
      local body = storage.helpers.h1.entity
      body.die()
      local rec = storage.helpers.h1
      S.eq(rec.state, "dead")
      S.eq(rec.died_tick, 5)
      S.ok(rec.corpse_pos ~= nil, "позиция трупа")
      S.tick()
      local ev = S.okr(S.req("events", { since = 0 })).events
      S.eq(#ev, 1, "helper_lost после смерти не шлётся")
      S.eq({ ev[1].kind, ev[1].data.code }, { "job_failed", "no_helper" })
      S.err(S.req("jobs", {}, "h1"), "no_helper")
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      local list = S.okr(S.req("helper_list")).helpers
      S.eq(list[1].state, "dead")
      S.ok(list[1].cooldown_s > 0)
  end },
  { "remove мёртвого: перезарядка от смерти, а не заново; возвращает труп", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.tick(5)
      storage.helpers.h1.entity.die()
      local corpse = storage.helpers.h1.corpse_pos
      S.ok(corpse ~= nil)
      S.tick(4 * 60 * 60)
      local d = S.okr(S.req("helper_remove", {}, "h1"))
      S.eq(d.corpse, corpse)
      S.eq(storage.helpers.h1.state, "removed")
      S.err(S.req("helper_remove", {}, "h1"), "no_helper")
      local list = S.okr(S.req("helper_list")).helpers
      S.eq(list[1].cooldown_s, 60, "осталась минута, а не 5")
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(COOLDOWN - 4 * 60 * 60 - 1)
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(1)
      S.okr(S.req("helper_spawn", {}, "h1"))
  end },
  { "on_object_destroyed с чужим registration_number ничего не трогает", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      local reg = storage.helpers.h1.reg
      S.fire(defines.events.on_object_destroyed, { registration_number = reg + 1000, useful_id = 1, type = 1 })
      S.eq(storage.helpers.h1.state, "alive")
      S.eq(storage.helpers.h1.reg, reg)
      S.eq(S.okr(S.req("events", { since = 0 })).events, {})
  end },
  { "set_body (возрождение, поток H): мёртвый -> живой", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      storage.helpers.h1.entity.die()
      local reg = require("scripts.core.registry")
      local body = S.nauvis.create_entity{ name = "character", position = { 0, 0 }, force = "player" }
      reg.set_body("h1", body)
      S.eq(storage.helpers.h1.state, "alive")
      S.okr(S.req("jobs", {}, "h1"))
      S.raises(function() reg.set_body("h1", body) end, "not dead")
  end },
  { "тело исчезло не по смерти -> helper_lost, задачи no_helper", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.req("act", { ["do"] = "wait", args = { seconds = 100 } }, "h1")
      S.tick(2)
      storage.helpers.h1.entity.destroy()
      S.tick()
      local ev = S.okr(S.req("events", { since = 0 })).events
      local kinds = {}
      for _, e in ipairs(ev) do kinds[#kinds + 1] = e.kind .. ":" .. tostring(e.data.code or e.data.reason) end
      S.eq(kinds, { "job_failed:no_helper", "helper_lost:destroyed" })
      S.eq(ev[2].loud, true)
      S.eq(ev[2].helper, "h1")
      S.eq(storage.helpers.h1.state, "removed")
  end },
  { "helper_list: id, state, surface, pos, job", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.req("act", { ["do"] = "wait", args = { seconds = 100 } }, "h1")
      S.tick()
      local list = S.okr(S.req("helper_list")).helpers
      S.eq(#list, 2)
      S.eq({ list[1].id, list[1].state, list[1].surface, list[1].job }, { "h1", "alive", "nauvis", 1 })
      S.eq(list[2].job, nil)
      S.eq(S.okr(S.req("hello")).helpers, { "h1", "h2" })
  end },
  { "команды мода не используют телепорт", function()
      -- заглушки бросают ошибку на teleport/mine_entity; полный путь spawn->act->remove не падает
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1")
      S.tick(100)
      S.okr(S.req("helper_remove", {}, "h1"))
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },
})
