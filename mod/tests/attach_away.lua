-- Тело-игрок (поток V1, волна 4): состояние `away`, поля `body`/`away` в helper_list, лимит,
-- helper_remove без трупа и перезарядки, правила helper_attach. PROTOCOL §4, §7 (ревизия 3.3).
local S = require("stubs")
local P = require("stubs_p")

local function limit(n) return S.req("helper_limit", { max = n }) end

local function item(id)
  for _, h in ipairs(S.okr(S.req("helper_list")).helpers) do
    if h.id == id then return h end
  end
  return nil
end

local function last(kind)
  local list = P.events(kind)
  return list[#list]
end

S.suite("attach_away", {
  { "helper_list: body у обоих видов тела, away только у ушедшего", function()
      local _, friend = P.setup()
      S.okr(limit(2))
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.eq(item("h1").body, "character")
      S.eq(item("h1").away, nil)
      S.eq(item("p1").body, "player")
      S.eq(item("p1").away, nil)
      S.eq(item("p1").state, "alive")
      P.tick(3)
      friend.character.walking_state = { walking = false, direction = 0 }
      S.move(friend.character, { x = 33.26, y = -4.04 })
      P.leave(friend)
      local it = item("p1")
      S.eq(it.state, "away")
      S.eq(it.away, "player_left")
      S.eq(it.body, "player")
      S.eq(it.pos, { x = 33.3, y = -4 }, "последнее место тела, округлено до 0.1")
      S.eq(it.surface, "nauvis")
      S.eq(it.job, nil)
      S.eq(it.corpse, nil)
      S.eq(it.cooldown_s, nil)
      S.eq(item("h1").state, "alive", "сосед ни при чём")
      -- вернулся: поля away исчезают
      P.join(friend)
      it = item("p1")
      S.eq(it.state, "alive")
      S.eq(it.away, nil)
      S.eq(P.rec().away_pos, nil)
      S.eq(P.rec().away_surface, nil)
  end },

  { "игрок вышел, тела уже нет (движок его убрал): последнее место — по игроку", function()
      local _, friend = P.setup()
      P.tick(2)
      friend.position = { x = 20, y = 0 }
      P.leave(friend, { destroy = true, silent = true })
      P.tick(1)
      local it = item("p1")
      S.eq(it.state, "away")
      S.eq(it.pos, { x = 20, y = 0 })
  end },

  { "away держит место в лимите: helper_limit ниже занятых — limit, alive — только живые", function()
      local _, friend = P.setup()
      S.eq(S.okr(limit(2)), { max = 2, alive = 1 })
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.eq(S.okr(limit(2)), { max = 2, alive = 2 })
      P.leave(friend)
      S.err(limit(1), "limit", "занято два места: живой h1 и ушедший p1")
      S.eq(S.okr(limit(2)), { max = 2, alive = 1 }, "alive — только живые")
      S.err(S.req("helper_spawn", {}, "h2"), "limit", "место ушедшего не освобождается")
      S.eq(S.okr(limit(3)), { max = 3, alive = 1 })
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.eq(S.okr(limit(3)).alive, 2)
      -- отвязали ушедшего — место свободно, границу можно опустить
      S.okr(S.req("helper_remove", {}, "p1"))
      S.eq(S.okr(limit(2)), { max = 2, alive = 2 })
  end },

  { "ждущий возрождения и away считаются вместе с живыми", function()
      local _, friend = P.setup()
      S.okr(limit(3))
      S.okr(S.req("helper_spawn", {}, "h1"))
      local third = S.add_player{ name = "Third", position = { x = -20, y = 0 } }
      S.okr(P.attach("p2", "Third"))
      P.tick(2)
      storage.helpers.h1.entity.die() -- ждёт возрождения
      P.leave(third)                  -- away
      S.eq(storage.helpers.h1.state, "dead")
      S.eq(P.rec("p2").state, "away")
      S.err(limit(2), "limit", "занято три: живой, мёртвый, ушедший")
      S.eq(S.okr(limit(3)), { max = 3, alive = 1 })
      S.eq(friend.character.valid, true)
  end },

  { "операции «h» у away — no_helper; h? с таким помощником — тоже", function()
      local _, friend = P.setup()
      P.tick(2)
      P.leave(friend)
      for _, op in ipairs({ "act", "cancel", "jobs", "reflexes", "say", "vision", "state", "recipes" }) do
        S.err(S.req(op, {}, "p1"), "no_helper", op)
      end
      S.err(S.req("map", {}, "p1"), "no_helper", "map с указанным помощником")
      S.eq(S.okr(S.req("hello")).helpers, { "p1" }, "в hello он есть: запись не удалена")
  end },

  { "helper_remove тела-игрока: без трупа и перезарядки в любом состоянии", function()
      -- живое
      local _, friend = P.setup()
      S.eq(S.okr(S.req("helper_remove", {}, "p1")), {})
      S.eq(item("p1").cooldown_s, nil)
      S.eq(friend.character.valid, true)
      S.eq(P.created("character-corpse"), 0)
      -- away
      S.okr(P.attach("p1", "Second"))
      P.tick(2)
      P.leave(friend)
      S.eq(S.okr(S.req("helper_remove", {}, "p1")), {})
      S.eq(item("p1").state, "removed")
      S.eq(item("p1").cooldown_s, nil)
      S.eq(item("p1").away, nil)
      P.join(friend)
      S.okr(P.attach("p1", "Second"), "сразу снова, без перезарядки")
      -- мёртвое (ждёт возрождения движком): труп — игрока, в ответе его нет, перезарядки нет
      P.tick(2)
      P.kill(friend)
      S.eq(P.rec().state, "dead")
      S.ok(P.rec().corpse_pos)
      S.eq(item("p1").cooldown_s, nil, "у тела-игрока перезарядки нет и после смерти")
      S.eq(S.okr(S.req("helper_remove", {}, "p1")), {}, "без corpse")
      S.eq(P.rec().state, "removed")
      S.eq(P.rec().corpse_pos, nil)
      S.eq(item("p1").cooldown_s, nil)
      P.respawn(friend)
      P.tick(5)
      S.eq(P.rec().state, "removed", "отвязанного возрождение не оживляет")
      S.okr(P.attach("p1", "Second"))
      S.eq(P.rec().state, "alive")
      S.eq(#P.events("respawned"), 0)
  end },

  { "id, привязанный к ушедшему игроку, занят: helper_spawn и helper_attach -> helper_exists", function()
      local _, friend = P.setup()
      S.okr(limit(3))
      local third = S.add_player{ name = "Third", position = { x = -20, y = 0 } }
      P.tick(2)
      P.leave(friend)
      S.err(S.req("helper_spawn", {}, "p1"), "helper_exists", "поверх ждущей записи тело не создаётся")
      S.err(P.attach("p1", "Third"), "helper_exists", "и другого игрока к этому id не привязать")
      S.eq(P.rec().player_index, friend.index)
      S.eq(P.rec().state, "away")
      -- игрок вернулся — запись на месте, тело подхвачено
      P.join(friend)
      S.eq(P.rec().state, "alive")
      S.eq(last("respawned").data.reason, "player_joined")
      -- после helper_remove id свободен для любого вида тела
      S.okr(S.req("helper_remove", {}, "p1"))
      S.okr(P.attach("p1", "Third"))
      S.eq(P.rec().player_index, third.index)
  end },

  { "helper_attach: правила §7 разом", function()
      local _, friend = P.setup{ attach = false }
      S.okr(limit(3))
      S.err(P.attach("p1", "second"), "no_player", "имя точное")
      S.err(P.attach("p1", "Second "), "no_player")
      friend.force = S.force{ name = "rivals" }
      S.err(P.attach("p1", "Second"), "no_player", "другая сила")
      friend.force = game.forces.player
      S.okr(P.attach("p1", "Second"))
      S.err(P.attach("p2", "Second"), "helper_exists", "игрок уже привязан к другому помощнику")
      S.okr(S.req("helper_spawn", {}, "h1"))
      local third = S.add_player{ name = "Third", position = { x = -20, y = 0 } }
      S.err(P.attach("h1", "Third"), "helper_exists", "id занят живым телом")
      -- запись с мёртвым телом-персонажем заменяется
      P.tick(2)
      storage.helpers.h1.entity.die()
      S.okr(P.attach("h1", "Third"))
      S.eq(storage.helpers.h1.player_index, third.index)
      S.eq(item("h1").body, "player")
      S.eq(item("h1").cooldown_s, nil)
  end },

  { "перезарядку тела-персонажа привязка и отвязка тела-игрока не снимают (§4: не телепорт)", function()
      local COOLDOWN = 5 * 60 * 60
      local reg = require("scripts.core.registry")
      local _, friend = P.setup{ attach = false }
      S.okr(S.req("helper_spawn", {}, "h1"))
      P.tick(10)
      S.move(storage.helpers.h1.entity, { x = 500, y = 500 }) -- ушёл далеко от хозяина
      S.okr(S.req("helper_remove", {}, "h1"))
      local gone = game.tick
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      P.tick(100)
      -- привязка разрешена сразу (перезарядки у helper_attach нет), у привязанного её не видно
      S.okr(P.attach("h1", "Second"))
      S.eq(P.rec("h1").char_gone_tick, gone)
      S.eq(P.rec("h1").removed_tick, nil)
      S.eq(item("h1").cooldown_s, nil)
      S.eq(S.okr(S.req("helper_remove", {}, "h1")), {})
      S.eq(friend.character.valid, true)
      -- отвязали: перезарядка прежнего тела идёт дальше с того же тика, а не заново и не с нуля
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown", "цепочка remove → attach → remove → spawn")
      S.eq(reg.cooldown_left(P.rec("h1")), COOLDOWN - 100)
      S.eq(item("h1").cooldown_s, math.ceil((COOLDOWN - 100) / 60))
      -- повторная привязка и отвязка отметку тоже не стирают; attach — по-прежнему сразу
      S.okr(P.attach("h1", "Second"))
      S.okr(S.req("helper_remove", {}, "h1"))
      S.eq(P.rec("h1").char_gone_tick, gone)
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      -- то же после смерти тела-игрока и после выхода игрока (dead, away -> removed)
      S.okr(P.attach("h1", "Second"))
      P.tick(2)
      P.kill(friend)
      S.okr(S.req("helper_remove", {}, "h1"))
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      P.respawn(friend)
      S.okr(P.attach("h1", "Second"))
      P.tick(2)
      P.leave(friend)
      S.okr(S.req("helper_remove", {}, "h1"))
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(gone + COOLDOWN - 1 - game.tick)
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(1)
      local d = S.okr(S.req("helper_spawn", {}, "h1"))
      S.eq(item("h1").body, "character")
      S.ok(math.abs(d.pos.x) <= 10 and math.abs(d.pos.y) <= 10, "новое тело — рядом с хозяином")
  end },

  { "перезарядка после смерти тела-персонажа: замена записи телом-игроком её не снимает", function()
      local COOLDOWN = 5 * 60 * 60
      P.setup{ attach = false }
      S.okr(S.req("helper_spawn", {}, "h1"))
      P.tick(5)
      storage.helpers.h1.entity.die()
      local died = game.tick
      S.eq(storage.helpers.h1.state, "dead")
      P.tick(20)
      S.okr(P.attach("h1", "Second")) -- запись с мёртвым телом-персонажем заменяется (§7)
      S.eq(P.rec("h1").char_gone_tick, died)
      S.eq(P.rec("h1").died_tick, nil)
      S.okr(S.req("helper_remove", {}, "h1"))
      S.err(S.req("helper_spawn", {}, "h1"), "cooldown")
      S.tick(died + COOLDOWN - game.tick)
      S.okr(S.req("helper_spawn", {}, "h1"))
      -- у тела-игрока без прежнего тела-персонажа перезарядки по-прежнему нет
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(P.attach("p1", "Second"))
      S.okr(S.req("helper_remove", {}, "p1"))
      S.okr(S.req("helper_spawn", {}, "p1"), "отвязка без прежнего персонажа — spawn сразу")
  end },

  { "причины helper_lost и respawned по EVENTS.md", function()
      local _, friend = P.setup()
      P.tick(2)
      -- no_character -> body_restored
      local ch = friend.character
      friend.character = nil
      P.tick(1)
      S.eq(last("helper_lost").data, { reason = "no_character" })
      S.eq(item("p1").away, "no_character")
      -- без персонажа, а потом ещё и вышел: событие второй раз не шлём, причина — выход
      P.leave(friend)
      S.eq(#P.events("helper_lost"), 1)
      P.tick(1)
      S.eq(item("p1").away, "player_left")
      friend.connected = true
      friend.character = ch
      local list = ch.surface._entities
      list[#list + 1] = ch
      P.tick(1)
      S.eq(last("respawned").data.reason, "player_joined")
      -- destroyed -> body_restored
      friend.character.destroy()
      friend.character = nil
      S.flush_destroyed()
      S.eq(last("helper_lost").data, { reason = "destroyed" })
      S.eq(item("p1").away, "destroyed")
      P.respawn(friend, { x = 1, y = 1 }, { silent = true })
      P.tick(1)
      S.eq(last("respawned").data, { pos = { x = 1, y = 1 }, reason = "body_restored" })
      -- player_removed: и для ждущей записи тоже
      P.leave(friend)
      S.eq(last("helper_lost").data, { reason = "player_left" })
      S.fire(defines.events.on_player_removed, { player_index = friend.index })
      S.eq(last("helper_lost").data, { reason = "player_removed" })
      S.eq(P.rec().state, "removed")
      S.eq(item("p1").away, nil)
      for _, e in ipairs(P.events("helper_lost")) do S.eq(e.loud, true) end
  end },

  { "registry.info(helper) -> {body, module_errors}: функция ядра для операции state", function()
      P.setup()
      S.okr(limit(2))
      S.okr(S.req("helper_spawn", {}, "h1"))
      local registry = require("scripts.core.registry")
      S.eq(registry.info("p1"), { body = "player", module_errors = 0 })
      S.eq(registry.info("h1"), { body = "character", module_errors = 0 })
      S.eq(registry.info("nobody").body, "character")
      S.eq(registry.body_kind("p1"), "player")
      require("scripts.core.err").count_module_error()
      S.eq(registry.info("h1").module_errors, 1, "тот же счётчик, что в hello")
      S.eq(S.okr(S.req("hello")).module_errors, 1)
  end },

  { "сохранение и загрузка в состоянии away: запись, лимит и возврат работают", function()
      local _, friend = P.setup()
      P.tick(3)
      P.leave(friend)
      P.reload()
      S.eq(item("p1").state, "away")
      S.eq(item("p1").away, "player_left")
      S.err(S.req("helper_spawn", {}, "h1"), "limit")
      P.tick(50)
      P.join(friend)
      S.eq(item("p1").state, "alive")
      S.eq(S.okr(S.req("hello")).module_errors, 0)
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },

  { "миграция схемы 2 -> 3: прежнее `dead` + away становится `away`", function()
      local _, friend = P.setup()
      P.tick(3)
      P.leave(friend)
      -- сейв прошлой версии: игрок вышел, запись была state="dead" с полем away
      local rec = P.rec()
      rec.state = "dead"
      rec.died_pos = { x = 20, y = 0 }
      rec.away_pos = nil
      rec.away_surface = nil
      storage.proto.version = 2
      storage.mining_last = nil
      P.reload{ changed = { mod_changes = { ["factorio-partner"] = { old_version = "0.1.0", new_version = "0.4.0" } } } }
      S.eq(storage.proto.version, 3)
      S.eq(P.rec().state, "away")
      S.eq(P.rec().away, "player_left")
      S.eq(item("p1").pos, { x = 20, y = 0 })
      S.eq(storage.mining_last, {})
      -- настоящая смерть тела-игрока (away нет) остаётся dead
      P.join(friend)
      P.tick(2)
      P.kill(friend)
      storage.proto.version = 2
      P.reload{ changed = { mod_changes = {} } }
      S.eq(P.rec().state, "dead")
  end },
})
