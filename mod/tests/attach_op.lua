-- Тело-игрок (поток P): операция helper_attach. PROTOCOL §7 «Два вида тела», §3 (коды ошибок).
local S = require("stubs")
local P = require("stubs_p")

local function limit(n) return S.okr(S.req("helper_limit", { max = n })) end

S.suite("attach_op", {
  { "helper_attach {player} -> {helper, pos, surface}; запись с player_index, тело — персонаж игрока", function()
      local _, friend = P.setup{ attach = false }
      local created = #S.nauvis.created
      local d = S.okr(P.attach("p1", "Second"))
      S.eq(d, { helper = "p1", pos = { x = 20, y = 0 }, surface = "nauvis" })
      local rec = P.rec()
      S.eq(rec.state, "alive")
      S.eq(rec.player_index, friend.index)
      S.ok(rec.entity == friend.character, "тело — тот же LuaEntity, что у игрока")
      S.eq(rec.unit_number, friend.character.unit_number)
      S.eq(rec.away, nil)
      S.eq(rec.hold, nil)
      S.eq(require("scripts.core.registry").is_player_body("p1"), true)
      -- честность: тело не создаётся и не переносится, инвентарь не трогается
      S.eq(#S.nauvis.created, created, "мод не создал ни одной сущности")
      S.eq(friend.character.position, { x = 20, y = 0 })
      S.eq(friend.character.get_main_inventory().is_empty(), true)
      -- помощник виден в hello и helper_list
      S.eq(S.okr(S.req("hello")).helpers, { "p1" })
      local list = S.okr(S.req("helper_list")).helpers
      S.eq(#list, 1)
      S.eq(list[1].id, "p1")
      S.eq(list[1].state, "alive")
      S.eq(list[1].pos, { x = 20, y = 0 })
      S.eq(list[1].surface, "nauvis")
      S.eq(list[1].cooldown_s, nil)
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },

  { "обычные операции идут по телу-игроку тем же кодом: act, jobs, cancel, say", function()
      P.setup()
      local job = P.act("wait", { seconds = 1 }).job
      S.eq(S.okr(S.req("jobs", {}, "p1")).queue[1].job, job)
      P.tick(70)
      local res = P.result(job)
      S.ok(res, "задача завершилась: " .. P.kinds())
      S.eq(res.kind, "job_done")
      local j2 = P.act("wait", { seconds = 30 }).job
      P.tick(2)
      S.eq(S.okr(S.req("cancel", { job = j2 }, "p1")).cancelled, { j2 })
      S.okr(S.req("say", { text = "привет" }, "p1"))
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "схема: нужен id помощника и строка player; лишние поля, пустое и мусор — bad_args", function()
      P.setup{ attach = false }
      S.err(S.req("helper_attach", { player = "Second" }), "bad_request", "без id помощника")
      S.err(P.attach("p1", nil), "bad_args", "нет player")
      S.err(S.req("helper_attach", { player = 2 }, "p1"), "bad_args", "player — число")
      S.err(S.req("helper_attach", { player = "" }, "p1"), "bad_args", "пустое имя")
      S.err(S.req("helper_attach", { player = "Sec\nond" }, "p1"), "bad_args", "перевод строки в имени")
      S.err(S.req("helper_attach", { player = string.rep("a", 61) }, "p1"), "bad_args", "имя длиннее 60")
      S.err(P.attach("p1", "Second", { force = "enemy" }), "bad_args", "лишнее поле")
      S.eq(storage.helpers.p1, nil, "после отказов записи нет")
  end },

  { "no_player: нет такого игрока, игрок офлайн, без персонажа, в другой силе", function()
      local _, friend = P.setup{ attach = false }
      S.err(P.attach("p1", "Nobody"), "no_player")
      S.err(P.attach("p1", "second"), "no_player", "имя — точное, с учётом регистра")
      friend.connected = false
      S.err(P.attach("p1", "Second"), "no_player", "офлайн")
      friend.connected = true
      local ch = friend.character
      friend.character = nil
      S.err(P.attach("p1", "Second"), "no_player", "без персонажа (редактор, смерть)")
      friend.character = ch
      local other = S.force{ name = "rivals" }
      friend.force = other
      S.err(P.attach("p1", "Second"), "no_player", "чужая сила: помощник всегда в силе хозяина")
      friend.force = game.forces.player
      S.okr(P.attach("p1", "Second"))
  end },

  { "хозяина привязать нельзя — ни по умолчанию (игрок 1), ни заданного настройкой", function()
      P.setup{ attach = false }
      S.err(P.attach("p1", "Tartaluga"), "no_player", "хозяин по умолчанию — игрок с индексом 1")
      S.eq(storage.helpers.p1, nil)
      S.set_setting("partner-owner", "Second")
      S.err(P.attach("p1", "Second"), "no_player", "хозяин из настройки partner-owner")
      S.okr(P.attach("p1", "Tartaluga"), "не хозяин — можно")
  end },

  { "helper_exists: id уже жив (тело без игрока или тело-игрок); игрок уже чьё-то тело", function()
      local _, friend = P.setup{ attach = false }
      limit(3)
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.err(P.attach("h1", "Second"), "helper_exists", "h1 жив как тело без игрока")
      S.okr(P.attach("p1", "Second"))
      S.err(P.attach("p1", "Second"), "helper_exists", "p1 уже жив")
      S.err(P.attach("p2", "Second"), "helper_exists", "один игрок — одно тело")
      S.eq(storage.helpers.p2, nil)
      S.eq(P.rec().player_index, friend.index)
  end },

  { "лимит max_helpers общий для обоих видов тела; ждущий возрождения место держит", function()
      P.setup{ attach = false }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.err(P.attach("p1", "Second"), "limit", "max_helpers = 1, место занято h1")
      limit(2)
      S.okr(P.attach("p1", "Second"))
      S.eq(limit(2), { max = 2, alive = 2 })
      S.err(S.req("helper_limit", { max = 1 }), "limit")
      -- тело-игрок занимает место и для helper_spawn
      S.err(S.req("helper_spawn", {}, "h2"), "limit")
  end },

  { "повтор запроса с тем же id — тот же ответ, операция не исполняется дважды", function()
      P.setup{ attach = false }
      local a = S.req("helper_attach", { player = "Second" }, "p1", "same-1")
      local b = S.req("helper_attach", { player = "Second" }, "p1", "same-1")
      S.okr(a)
      S.eq(b, a, "сохранённый ответ, а не helper_exists")
  end },

  { "helper_remove только отвязывает: персонаж жив, перезарядки нет, можно привязать снова", function()
      local _, friend = P.setup()
      friend.character.insert{ name = "iron-plate", count = 7 }
      local job = P.act("wait", { seconds = 30 }).job
      P.tick(3)
      S.eq(S.okr(S.req("helper_remove", {}, "p1")), {})
      S.eq(P.result(job).data.code, "cancelled", "задачи снимаются как cancelled")
      S.eq(friend.character.valid, true, "персонажа игрока не убиваем")
      S.eq(friend.character.get_item_count("iron-plate"), 7, "вещи на месте")
      S.eq(P.created("character-corpse"), 0, "трупа нет")
      local rec = P.rec()
      S.eq(rec.state, "removed")
      S.eq(rec.entity, nil)
      S.eq(rec.hold, nil)
      S.eq(S.okr(S.req("helper_list")).helpers[1].cooldown_s, nil)
      S.err(S.req("jobs", {}, "p1"), "no_helper")
      -- отвязанный игрок мод больше не интересует
      local seq = S.okr(S.req("hello")).seq
      P.leave(friend)
      P.tick(5)
      P.join(friend)
      P.tick(5)
      S.eq(S.okr(S.req("hello")).seq, seq, "событий об отвязанном игроке нет: " .. P.kinds())
      S.eq(P.rec().state, "removed")
      -- сразу снова, без перезарядки; можно и под другим id
      S.okr(P.attach("p2", "Second"))
      S.okr(S.req("helper_remove", {}, "p2"))
      S.okr(P.attach("p1", "Second"))
      S.eq(P.rec().state, "alive")
  end },

  { "id с мёртвым телом без игрока: привязка заменяет запись, мод старое тело не возрождает", function()
      P.setup{ attach = false }
      S.okr(S.req("helper_spawn", {}, "h1"))
      P.tick(5)
      storage.helpers.h1.entity.die()
      S.eq(storage.helpers.h1.state, "dead")
      local created = P.created("character")
      S.okr(P.attach("h1", "Second"))
      S.eq(storage.helpers.h1.state, "alive")
      P.tick(1300)
      S.eq(P.created("character"), created, "возрождение отменено: тело теперь — персонаж игрока")
      S.eq(#P.events("respawned"), 0)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "/partner из чата игрока (в том числе второго клиента) не исполняется", function()
      local _, friend = P.setup{ attach = false }
      local n = S.chat_command(friend.index, '{"v":1,"id":"c1","op":"helper_attach","helper":"p1","args":{"player":"Second"}}')
      S.eq(n, 0, "в RCON ничего")
      S.eq(storage.helpers.p1, nil)
  end },
})
