-- Тело-игрок (поток P): игрок вышел и вернулся, смерть и возрождение движком, тело пропало или
-- подменено. PROTOCOL §7 «Два вида тела», §6.8, §6.9; EVENTS.md (helper_lost, respawned, died).
local S = require("stubs")
local P = require("stubs_p")

local function kinds_since(seq)
  local out = {}
  for _, e in ipairs(P.events()) do
    if e.seq > seq then out[#out + 1] = e.kind end
  end
  return out
end

local function seq() return S.okr(S.req("hello")).seq end

local function last(kind)
  local list = P.events(kind)
  return list[#list]
end

S.suite("attach_life", {
  { "игрок вышел: задачи job_failed{no_helper}, потом helper_lost{reason:player_left}", function()
      local _, friend = P.setup()
      local A = P.action()
      local j1 = P.act("p_once", {}).job
      local j2 = P.act("wait", { seconds = 5 }).job
      P.tick(10)
      local s0 = seq()
      P.leave(friend)
      S.eq(kinds_since(s0), { "job_failed", "job_failed", "helper_lost" }, "порядок событий")
      S.eq(P.result(j1).data.code, "no_helper")
      S.eq(P.result(j2).data.code, "no_helper")
      local lost = last("helper_lost")
      S.eq(lost.data, { reason = "player_left" })
      S.eq(lost.helper, "p1")
      S.eq(lost.loud, true)
      S.eq(A.stops, 1, "stop действия вызван")
      local rec = P.rec()
      S.eq(rec.state, "dead", "запись ждёт игрока, как ждущий возрождения")
      S.eq(rec.away, "player_left")
      S.eq(rec.entity, nil)
      S.eq(rec.hold, nil)
      S.eq(rec.player_index, friend.index)
      -- операции помощника — no_helper; в списке он есть, с местом, где пропал
      S.err(S.req("jobs", {}, "p1"), "no_helper")
      S.err(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "p1"), "no_helper")
      local item = S.okr(S.req("helper_list")).helpers[1]
      S.eq(item.state, "dead")
      S.ok(item.pos.x > 20, "pos — где тело было: " .. S.dump(item.pos))
      S.eq(item.cooldown_s, nil)
      S.eq(S.okr(S.req("hello")).helpers, { "p1" })
      -- место в лимите держится: чужой helper_spawn его не займёт
      S.err(S.req("helper_spawn", {}, "h1"), "limit")
      -- дальше тихо: ни событий, ни ошибок
      local s1 = seq()
      P.tick(700)
      S.eq(seq(), s1, "пока игрока нет — тишина: " .. table.concat(kinds_since(s1), ","))
      S.eq(P.created("character"), 2, "мод тел не создаёт (два — игроки заглушки)")
      S.eq(S.okr(S.req("hello")).module_errors, 0)
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },

  { "игрок вышел, тело уничтожено движком: on_object_destroyed не даёт второго helper_lost", function()
      local _, friend = P.setup()
      P.tick(5)
      P.leave(friend, { destroy = true })
      P.tick(3) -- отложенный on_object_destroyed приходит в конце тика
      S.eq(#P.events("helper_lost"), 1)
      S.eq(P.rec().state, "dead", "не removed: запись ждёт игрока")
  end },

  { "игрок вернулся: тело подхватывается, respawned{pos, reason:player_joined}, задачи идут", function()
      local _, friend = P.setup()
      friend.character.insert{ name = "iron-plate", count = 5 }
      P.tick(5)
      P.leave(friend)
      P.tick(100)
      local s0 = seq()
      local ch = P.join(friend)
      S.eq(kinds_since(s0), { "respawned" })
      local ev = last("respawned")
      S.eq(ev.data, { pos = { x = 20, y = 0 }, reason = "player_joined" })
      S.eq(ev.helper, "p1")
      local rec = P.rec()
      S.eq(rec.state, "alive")
      S.eq(rec.away, nil)
      S.ok(rec.entity == ch)
      S.eq(ch.get_item_count("iron-plate"), 5, "вещи игрока на месте")
      local job = P.act("wait", { seconds = 1 }).job
      P.tick(70)
      S.eq(P.result(job).kind, "job_done")
      S.eq(#P.events("respawned"), 1, "событие одно, сверка каждый тик его не повторяет")
      S.eq(#P.events("helper_lost"), 1)
  end },

  { "игрок вернулся с НОВЫМ телом (движок пересоздал персонажа): unit_number обновился", function()
      local _, friend = P.setup()
      local old = friend.character.unit_number
      P.leave(friend, { destroy = true })
      P.tick(10)
      local ch = P.join(friend)
      S.ok(ch.unit_number ~= old)
      S.eq(P.rec().state, "alive")
      S.eq(P.rec().unit_number, ch.unit_number)
      -- новое тело под присмотром: его исчезновение мод заметит
      ch.destroy()
      friend.character = nil
      S.flush_destroyed()
      S.eq(last("helper_lost").data.reason, "destroyed")
  end },

  { "события пропущены — сверка каждый тик: выход и возврат замечаются сами", function()
      local _, friend = P.setup()
      local job = P.act("wait", { seconds = 30 }).job
      P.tick(5)
      P.leave(friend, { silent = true })
      P.tick(1)
      S.eq(last("helper_lost").data.reason, "player_left")
      S.eq(P.result(job).data.code, "no_helper")
      P.tick(20)
      P.join(friend, { silent = true })
      S.eq(P.rec().state, "dead", "до тика — ещё нет")
      P.tick(1)
      S.eq(P.rec().state, "alive")
      S.eq(last("respawned").data.reason, "player_joined")
  end },

  { "смерть: job_failed{no_helper}, died; мод тело НЕ возрождает; движок возродил — respawned{pos}", function()
      local _, friend = P.setup()
      friend.character.insert{ name = "iron-plate", count = 9 }
      local job = P.act("wait", { seconds = 30 }).job
      P.tick(5)
      local s0 = seq()
      P.kill(friend)
      S.eq(kinds_since(s0), { "job_failed", "died" }, "как у тела без игрока: сначала задачи, потом died")
      S.eq(P.result(job).data.code, "no_helper")
      local rec = P.rec()
      S.eq(rec.state, "dead")
      S.eq(rec.away, nil, "это смерть, а не выход игрока")
      S.ok(rec.corpse_pos, "труп с вещами — как обычно")
      S.eq(#P.events("helper_lost"), 0)
      local created = P.created("character")
      P.tick(1300)
      S.eq(P.created("character"), created, "§6.9 для тела-игрока не действует: мод тело не создаёт")
      S.eq(rec.state, "dead")
      S.eq(#P.events("respawned"), 0)
      S.eq(#P.events("reflex_done"), 0)
      -- возрождает движок: новый player.character
      local s1 = seq()
      local body = P.respawn(friend, { x = 3, y = 4 })
      S.eq(kinds_since(s1), { "respawned" })
      S.eq(last("respawned").data, { pos = { x = 3, y = 4 } }, "без reason — обычное возрождение")
      S.eq(rec.state, "alive")
      S.ok(rec.entity == body)
      S.eq(rec.unit_number, body.unit_number)
      S.eq(rec.corpse_pos, nil)
      P.tick(20)
      S.eq(storage.reflex_state.p1 == nil or storage.reflex_state.p1.death == nil, true, "рефлекс смерти забыл прошлое тело")
      S.eq(#P.events("respawned"), 1)
      local j2 = P.act("wait", { seconds = 1 }).job
      P.tick(70)
      S.eq(P.result(j2).kind, "job_done")
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "возрождение без события on_player_respawned — подхват на следующем тике", function()
      local _, friend = P.setup()
      P.tick(5)
      P.kill(friend)
      P.tick(100)
      local body = P.respawn(friend, { x = 1, y = 1 }, { silent = true })
      P.tick(1)
      S.eq(P.rec().state, "alive")
      S.ok(P.rec().entity == body)
      S.eq(#P.events("respawned"), 1)
  end },

  { "умер, вышел до возрождения, вернулся без тела, потом возродился", function()
      local _, friend = P.setup()
      P.tick(5)
      P.kill(friend)
      P.leave(friend)
      S.eq(#P.events("helper_lost"), 0, "он и так мёртв — helper_lost не шлём")
      P.tick(50)
      P.join(friend, { character = false })
      P.tick(5)
      S.eq(P.rec().state, "dead")
      S.eq(#P.events("respawned"), 0)
      P.respawn(friend)
      S.eq(P.rec().state, "alive")
      S.eq(last("respawned").data.reason, nil)
  end },

  { "игрок онлайн, но без персонажа (редактор, режим бога): helper_lost{no_character}, потом подхват", function()
      local _, friend = P.setup()
      local job = P.act("wait", { seconds = 30 }).job
      P.tick(5)
      local ch = friend.character
      friend.character = nil
      P.tick(1)
      S.eq(last("helper_lost").data, { reason = "no_character" })
      S.eq(P.result(job).data.code, "no_helper")
      S.eq(P.rec().state, "dead")
      S.eq(P.rec().away, "no_character")
      P.tick(30)
      friend.character = ch
      P.tick(1)
      S.eq(P.rec().state, "alive")
      S.eq(last("respawned").data, { pos = { x = 20, y = 0 }, reason = "body_restored" })
      S.eq(#P.events("helper_lost"), 1)
  end },

  { "персонаж подменён (другой LuaEntity): задачи сняты, новое тело взято", function()
      local _, friend = P.setup()
      local A = P.action()
      local job = P.act("p_once", {}).job
      P.tick(5)
      local old = friend.character
      local new = S.nauvis.create_entity{ name = "character", position = { x = -7, y = 2 }, force = "player" }
      new.player = friend
      friend.character = new
      local s0 = seq()
      P.tick(1)
      S.eq(kinds_since(s0), { "job_failed", "helper_lost", "respawned" })
      S.eq(P.result(job).data.code, "no_helper")
      S.eq(last("helper_lost").data.reason, "body_changed")
      S.eq(last("respawned").data, { pos = { x = -7, y = 2 }, reason = "body_restored" })
      S.ok(P.rec().entity == new)
      S.ok(A.stop_entity == old, "stop действия — по прежнему телу, пока оно valid")
      S.eq(old.walking_state.walking, false, "прежнее тело остановлено")
      P.tick(30)
      S.eq(new.position, { x = -7, y = 2 }, "ходьба снятой задачи на новое тело не перенеслась")
  end },

  { "тело уничтожено скриптом: helper_lost{destroyed}, запись не удаляется и ждёт новое тело", function()
      local _, friend = P.setup()
      P.tick(5)
      friend.character.destroy()
      friend.character = nil
      S.flush_destroyed()
      S.eq(last("helper_lost").data, { reason = "destroyed" })
      S.eq(P.rec().state, "dead")
      P.tick(10)
      S.eq(#P.events("helper_lost"), 1)
      P.respawn(friend, { x = 2, y = 2 }, { silent = true })
      P.tick(1)
      S.eq(P.rec().state, "alive")
      S.eq(last("respawned").data.reason, "body_restored")
  end },

  { "игрока удалили из сейва: helper_lost{player_removed}, запись removed, место свободно", function()
      local _, friend = P.setup()
      local job = P.act("wait", { seconds = 30 }).job
      P.tick(5)
      S.fire(defines.events.on_player_removed, { player_index = friend.index })
      S.eq(P.result(job).data.code, "no_helper")
      S.eq(last("helper_lost").data, { reason = "player_removed" })
      S.eq(P.rec().state, "removed")
      S.eq(P.rec().entity, nil)
      S.okr(S.req("helper_spawn", {}, "h1"))
      P.tick(10)
      S.eq(#P.events("helper_lost"), 1)
      S.eq(#P.events("respawned"), 0)
  end },

  { "helper_remove, пока игрока нет: запись removed, возврат игрока её не оживляет", function()
      local _, friend = P.setup()
      P.tick(5)
      P.leave(friend)
      S.eq(S.okr(S.req("helper_remove", {}, "p1")), {})
      S.eq(P.rec().state, "removed")
      S.eq(P.rec().away, nil)
      P.join(friend)
      P.tick(10)
      S.eq(P.rec().state, "removed")
      S.eq(#P.events("respawned"), 0)
      S.okr(S.req("helper_spawn", {}, "h1"), "место свободно")
  end },

  { "сохранение и загрузка, пока игрока нет: после загрузки тело подхватывается", function()
      local _, friend = P.setup()
      P.tick(5)
      P.leave(friend)
      P.tick(5)
      P.reload()
      S.eq(P.rec().away, "player_left")
      P.join(friend)
      S.eq(P.rec().state, "alive")
      local job = P.act("wait", { seconds = 1 }).job
      P.tick(70)
      S.eq(P.result(job).kind, "job_done")
  end },

  { "чужие события не трогают: хозяин вышел и вернулся, умер и возродился — p1 живёт", function()
      local owner = P.setup()
      local job = P.act("wait", { seconds = 2 }).job
      P.tick(5)
      P.leave(owner)
      P.tick(5)
      P.join(owner)
      P.kill(owner)
      P.respawn(owner)
      P.tick(130)
      S.eq(P.result(job).kind, "job_done")
      S.eq(#P.events("helper_lost"), 0)
      S.eq(#P.events("respawned"), 0)
      S.eq(P.rec().state, "alive")
  end },

  { "обзор §6.8 для тела-игрока мод не ведёт (карту открывает движок)", function()
      P.setup()
      local force = game.forces.player
      local charts = 0
      rawset(force, "chart", function() charts = charts + 1 end)
      P.tick(200)
      S.eq(charts, 0, "force.chart для тела-игрока мод не звал")
      -- контроль: телу без игрока обзор ведётся (счётчик рабочий)
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h1"))
      P.tick(200)
      S.ok(charts > 0, "тело без игрока карту открывает")
  end },

  { "два тела-игрока: выход одного не задевает другого", function()
      local _, friend = P.setup()
      S.okr(S.req("helper_limit", { max = 2 }))
      local third = S.add_player{ name = "Third", position = { x = -20, y = 0 } }
      S.okr(P.attach("p2", "Third"))
      local A = P.action()
      P.act("p_once", {}, "p1")
      P.act("p_once", {}, "p2")
      P.tick(20)
      P.leave(third)
      P.tick(20)
      S.eq(P.rec("p2").state, "dead")
      S.eq(P.rec("p1").state, "alive")
      S.ok(friend.character.position.x > 25, "p1 идёт дальше: " .. friend.character.position.x)
      S.eq(#P.events("helper_lost"), 1)
      S.eq(last("helper_lost").helper, "p2")
      S.eq(A.stops, 1)
  end },
})
