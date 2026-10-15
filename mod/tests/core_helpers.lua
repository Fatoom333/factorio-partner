-- Помощники и хозяин: helper_spawn/remove/list, перезарядка, смерть, потеря тела (PROTOCOL §4, §6.9, §7).
local S = require("stubs")

local COOLDOWN = 600

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
  { "spawn: хозяин офлайн — у его последней позиции на его поверхности", function()
      S.load_mod()
      S.okr(S.req("helper_limit", { max = 2 }))
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
  { "spawn: живой с этим id -> helper_exists; по умолчанию помощник один (max_helpers = 1)", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.eq(storage.proto.max_helpers, 1)
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.err(S.req("helper_spawn", {}, "h1"), "helper_exists")
      S.err(S.req("helper_spawn", {}, "h2"), "limit")
      S.eq(storage.helpers.h2, nil)
  end },
  { "helper_limit: игрок задаёт число помощников, {max, alive}; третий spawn при max=2 -> limit", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.eq(S.okr(S.req("helper_limit", { max = 2 })), { max = 2, alive = 0 })
      S.eq(storage.proto.max_helpers, 2)
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.err(S.req("helper_spawn", {}, "h3"), "limit")
      S.eq(S.okr(S.req("helper_limit", { max = 16 })), { max = 16, alive = 2 })
      S.okr(S.req("helper_spawn", {}, "h3"))
      -- значение переживает сохранение/загрузку
      S.reload()
      S.eq(storage.proto.max_helpers, 16)
      S.eq(S.okr(S.req("helper_limit", { max = 3 })).alive, 3)
      S.err(S.req("helper_spawn", {}, "h4"), "limit")
  end },
  { "helper_limit: границы 1..16, ниже числа занятых мест нельзя, помощник не нужен", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.err(S.req("helper_limit", {}), "bad_args")
      S.err(S.req("helper_limit", { max = 0 }), "bad_args")
      S.err(S.req("helper_limit", { max = 1.5 }), "bad_args")
      S.err(S.req("helper_limit", { max = "2" }), "bad_args")
      S.err(S.req("helper_limit", { max = 17 }), "limit")
      S.err(S.req("helper_limit", { max = 2, extra = 1 }), "bad_args")
      S.eq(storage.proto.max_helpers, 1, "неудачные вызовы значение не меняют")
      S.okr(S.req("helper_limit", { max = 3 }))
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.err(S.req("helper_limit", { max = 1 }), "limit")
      S.eq(storage.proto.max_helpers, 3)
      S.okr(S.req("helper_limit", { max = 2 }))
      -- id помощника в конверте не обязателен и не проверяется (операция не «h»)
      S.eq(S.okr(S.req("helper_limit", { max = 2 }, "nobody")).max, 2)
  end },
  { "лимит считает живых и мёртвых, ждущих возрождения: возрождение его не превышает", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      require("scripts.reflexes.death").RESPAWN_TICKS = math.huge -- остаётся мёртвым
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.tick(5)
      storage.helpers.h1.entity.die()
      S.eq(storage.helpers.h1.state, "dead")
      S.err(S.req("helper_spawn", {}, "h3"), "limit", "мёртвый держит место")
      S.err(S.req("helper_limit", { max = 1 }), "limit", "занято два места: живой и ждущий возрождения")
      S.eq(S.okr(S.req("helper_limit", { max = 2 })), { max = 2, alive = 1 })
      -- удалили мёртвого — место свободно
      S.okr(S.req("helper_remove", {}, "h1"))
      -- перезарядка общая для всех id: новое тело под другим id сразу не появляется
      S.err(S.req("helper_spawn", {}, "h3"), "cooldown", "10 секунд общие для всех id")
      S.tick(COOLDOWN)
      S.eq(S.okr(S.req("helper_spawn", {}, "h3")).at, "respawn_point", "remove h1 → spawn h3 не телепорт")
      S.okr(S.req("helper_remove", {}, "h3"))
      S.tick(5 * 60 * 60)
      S.eq(S.okr(S.req("helper_spawn", {}, "h3")).at, "owner", "через 5 минут — снова у хозяина")
      S.okr(S.req("helper_limit", { max = 2 }))
  end },
  { "registry.bind / тело-игрок: helper_remove только отвязывает, персонаж игрока жив", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      local friend = S.add_player{ name = "Second", position = { 20, 0 } }
      local reg = require("scripts.core.registry")
      reg.check_slot("p1")
      local rec = reg.bind("p1", friend.character, { player_index = friend.index, junk = function() end })
      S.eq(rec.state, "alive")
      S.eq(rec.player_index, friend.index)
      S.eq(rec.junk, nil, "в запись идут только простые значения")
      S.eq(reg.is_player_body("p1"), true)
      S.eq(select(1, reg.occupied()), 1)
      S.raises(function() reg.check_slot("h1") end, "limit")
      S.okr(S.req("jobs", {}, "p1"))
      S.eq(S.okr(S.req("helper_remove", {}, "p1")), {})
      S.eq(friend.character.valid, true, "персонажа игрока не убиваем")
      S.eq(storage.helpers.p1.state, "removed")
      S.eq(reg.cooldown_left(storage.helpers.p1), 0, "отвязка — без перезарядки")
      S.eq(select(1, reg.occupied()), 0)
      S.raises(function() reg.bind("p1", nil) end, "not a character")
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
      -- после job_failed идёт died от рефлекса смерти (EVENTS.md); helper_lost не шлётся
      S.eq(#ev, 2, "helper_lost после смерти не шлётся")
      S.eq({ ev[1].kind, ev[1].data.code, ev[2].kind }, { "job_failed", "no_helper", "died" })
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
      -- помощник должен остаться мёртвым: возрождение (PROTOCOL §6.9) здесь отключено;
      -- load_mod грузит модули заново, поэтому правка не выходит за этот тест
      require("scripts.reflexes.death").RESPAWN_TICKS = math.huge
      S.tick(5)
      storage.helpers.h1.entity.die()
      local corpse = storage.helpers.h1.corpse_pos
      S.ok(corpse ~= nil)
      S.tick(300)
      local d = S.okr(S.req("helper_remove", {}, "h1"))
      S.eq(d.corpse, corpse)
      S.eq(storage.helpers.h1.state, "removed")
      S.err(S.req("helper_remove", {}, "h1"), "no_helper")
      local list = S.okr(S.req("helper_list")).helpers
      S.eq(list[1].cooldown_s, 5, "осталось 5 секунд, а не 10")
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(COOLDOWN - 300 - 1)
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(1)
      -- окно 5 минут ещё идёт: тело появляется в точке возрождения, а не у хозяина
      S.eq(S.okr(S.req("helper_spawn", {}, "h1")).at, "respawn_point")
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
  { "set_body (возрождение): мёртвый -> живой", function()
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
      S.okr(S.req("helper_limit", { max = 2 }))
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
