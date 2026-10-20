-- Слово хозяина (scripts/core/owner_words.lua): стоп, «иди сюда», «что делаешь», адрес, hold.
local S = require("stubs")
local B = require("stubs_b")
local H = require("stubs_h")
local C = require("stubs_c")

local function words() return require("scripts.core.owner_words") end

local function say_lines()
  local out = {}
  for _, m in ipairs(game.printed) do out[#out + 1] = m end
  return out
end

local function last_of(kind)
  local r
  for _, e in ipairs(B.events()) do if e.kind == kind then r = e end end
  return r
end

local function count_of(kind)
  local n = 0
  for _, e in ipairs(B.events()) do if e.kind == kind then n = n + 1 end end
  return n
end

--- Стоящий на месте помощник h1 с одной длинной задачей и очередью из двух.
local function busy()
  local p, h = B.setup()
  B.act("wait", { seconds = 600 })
  B.act("wait", { seconds = 5 })
  B.act("wait", { seconds = 5 })
  B.tick(3)
  return p, h
end

S.suite("owner_words", {
  { "разбор: слова, адрес, отрицания, посторонний текст", function()
      B.setup()
      local W = words()
      local function kind(text) return W.classify(W.tokens(text)) end
      for _, t in ipairs({ "стоп", "Стоп!", "СТОЙ", "остановись, пожалуйста", "отмена", "stop",
        "Stop it", "ладно, стоп", "стоп стоп", "[gps=1,2] стоп", "stop it right now", "Стоп! Всё!",
        "стой там", "ну стоп же", "стоп немедленно", "stop now please" }) do
        S.eq(kind(t), "stop", t)
      end
      for _, t in ipairs({ "иди сюда", "Ко мне!", "иди ко мне", "come", "come here", "иди сюда, пожалуйста" }) do
        S.eq(kind(t), "come", t)
      end
      for _, t in ipairs({ "что делаешь?", "Чем занят", "что ты сейчас делаешь", "Что происходит?", "статус" }) do
        S.eq(kind(t), "status", t)
      end
      S.eq(kind("продолжай"), "resume")
      for _, t in ipairs({ "не стопорись", "стоп-кран", "это не стоп", "не стой", "постой", "остановка рядом",
        "построй печь", "иди сюда и копай", "что делаешь с моим сундуком", "привет", "", "ко мне не надо",
        "don't stop", "стопка досок", "брось это", "брось",
        -- длинное сообщение со стоп-словом — новое поручение агенту, а не стоп
        "stop mining and build furnaces", "стоп, теперь ставь печи у железа", "остановись у печи и жди",
        "отмена всех заказов на печи", "ладно, теперь отмена всего",
        -- «стоп» с поручением рядом — сообщение агенту
        "стоп, ставь печи", "стоп, а теперь строй печи", "СТОП! там кусаки, беги", "стой у сундука",
        "stop and wait", "не стоп" }) do
        S.eq(kind(t), nil, t)
      end
      S.eq(W.lower("СТОП Ёлка ABC"), "стоп елка abc")
  end },

  { "разбор: «не охраняй» и похожие — снять охрану; поручения про охрану — нет", function()
      B.setup()
      local W = words()
      local function kind(text) return W.classify(W.tokens(text)) end
      for _, t in ipairs({ "не охраняй", "Не охраняй!", "сними охрану", "Сними охрану, пожалуйста", "хватит охранять",
        "перестань охранять", "stop guarding", "Unguard", "don't guard", "не надо охранять" }) do
        S.eq(kind(t), "unguard", t)
      end
      for _, t in ipairs({ "охраняй", "охраняй печи", "не охраняй печи, охраняй буры", "сними охрану и иди сюда",
        "guard here" }) do
        S.eq(kind(t), nil, t)
      end
  end },

  { "«не охраняй» без охраны хозяина — обычное сообщение агенту; без hold и без снятия задач", function()
      busy()
      local jobs = require("scripts.core.jobs")
      S.chat(1, "не охраняй")
      S.eq(last_of("player_said").data.word, nil)
      S.eq(jobs.queue_len("h1"), 2)
      S.eq(storage.owner_hold and storage.owner_hold.h1, nil)
  end },

  { "стоп: задачи сняты, ответ «Стою.», hold, owner_stop, player_said с пометкой", function()
      busy()
      local before = #say_lines()
      S.chat(1, "стоп")
      local jobs = require("scripts.core.jobs")
      S.eq({ jobs.active("h1"), jobs.queue_len("h1") }, { nil, 0 })
      local lines = say_lines()
      S.eq(#lines, before + 1)
      S.eq(lines[#lines], "Claude: Стою.")
      local ps = last_of("player_said")
      S.eq(ps.data.auto_reply, true)
      S.eq(ps.data.word, { kind = "stop", helpers = { "h1" } })
      local os = last_of("owner_stop")
      S.eq(os.data, { kind = "stop", seq = ps.seq, helpers = { "h1" } })
      S.eq({ os.loud, os.helper }, { true, nil })
      local failed = 0
      for _, e in ipairs(B.events()) do
        if e.kind == "job_failed" and e.data.code == "cancelled" then failed = failed + 1 end
      end
      S.eq(failed, 3)
      S.eq(storage.owner_hold.h1.kind, "stop")
      S.eq(storage.owner_hold.h1.seq, ps.seq)
  end },

  { "hold: act отказывает (owner_hold), cancel и say работают; «продолжай» снимает", function()
      busy()
      S.chat(1, "Стоп!")
      S.err(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1"), "owner_hold")
      S.eq(require("scripts.core.err").CODES.owner_hold, true)
      S.eq(words().held("h1"), true)
      S.eq(require("scripts.core.jobs").held("h1").kind, "stop")
      S.okr(S.req("say", { text = "жду" }, "h1"))
      S.okr(S.req("cancel", { all = true }, "h1"))
      local q = S.okr(S.req("owner_hold", {}, "h1"))
      S.eq(q.hold.h1.kind, "stop")
      S.chat(1, "продолжай")
      S.eq(storage.owner_hold.h1, nil)
      local lines = say_lines()
      S.eq(lines[#lines], "Claude: Продолжаю.")
      S.eq(last_of("owner_resume").data.helpers, { "h1" })
      S.okr(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1"))
      -- «продолжай» без hold — просто сообщение агенту
      S.chat(1, "продолжай")
      S.eq(last_of("player_said").data.auto_reply, nil)
  end },

  { "hold снимается операцией только по seq нового сообщения хозяина", function()
      busy()
      S.add_player{ name = "Guest", position = { 1, 1 } }
      S.chat(1, "стой")
      S.err(S.req("owner_hold", { release = true }, "h1"), "bad_args")
      local old = storage.owner_hold.h1.seq
      S.err(S.req("owner_hold", { release = true, seq = old }, "h1"), "bad_args") -- само слово «стой»
      S.err(S.req("owner_hold", { release = true, seq = 9999 }, "h1"), "bad_args")
      S.chat(2, "привет, строй печь")
      local guest = last_of("player_said").seq
      S.err(S.req("owner_hold", { release = true, seq = guest }, "h1"), "bad_args") -- не хозяин
      S.chat(1, "поставь печь у железа")
      local order = last_of("player_said").seq
      local r = S.okr(S.req("owner_hold", { release = true, seq = order }, "h1"))
      S.eq(r.released, { "h1" })
      S.eq(storage.owner_hold.h1, nil)
      S.okr(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1"))
  end },

  { "release: без helper, по слову мода (auto_reply), чужому адресату, дважды — отказ", function()
      B.setup()
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.chat(1, "стоп")
      local stop = last_of("player_said").seq
      S.eq({ storage.owner_hold.h1.seq, storage.owner_hold.h2.seq }, { stop, stop })
      S.chat(1, "что делаешь?")
      local status = last_of("player_said").seq
      S.eq(last_of("player_said").data.auto_reply, true)
      S.err(S.req("owner_hold", { release = true, seq = status }, "h1"), "bad_args") -- ответил мод
      S.chat(1, "строй печи")
      local order = last_of("player_said").seq
      S.err(S.req("owner_hold", { release = true, seq = order }), "bad_args") -- без helper
      S.ok(storage.owner_hold.h1 ~= nil and storage.owner_hold.h2 ~= nil, "без helper ничего не снято")
      S.eq(S.okr(S.req("owner_hold", { release = true, seq = order }, "h1")).released, { "h1" })
      S.chat(1, "Claude h2, стой")
      S.ok(storage.owner_hold.h2 ~= nil)
      S.chat(1, "Claude, неси уголь")
      local to_h1 = last_of("player_said").seq
      S.err(S.req("owner_hold", { release = true, seq = to_h1 }, "h2"), "bad_args") -- адресовано h1
      S.chat(1, "Claude h2, неси медь")
      local to_h2 = last_of("player_said").seq
      S.eq(S.okr(S.req("owner_hold", { release = true, seq = to_h2 }, "h2")).released, { "h2" })
      S.okr(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h2"))
      -- hold нет — снимать нечего, seq не тратится
      S.chat(1, "и ещё железо")
      S.eq(S.okr(S.req("owner_hold", { release = true, seq = last_of("player_said").seq }, "h1")).released, {})
  end },

  { "стоп, потом атака: отступление идёт, возврата к делу нет", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      S.chat(1, "стоп")
      local foe = H.enemy({ x = h.position.x + 10, y = h.position.y })
      local fired = H.wait("reflex_fired")
      S.eq(fired.data.type, "flee")
      local jobs = S.okr(S.req("jobs", {}, "h1"))
      local walk = jobs.active or jobs.queue[1]
      S.eq({ walk["do"], walk.req }, { "walk", "reflex:flee" })
      foe.destroy()
      local done = H.wait("reflex_done")
      S.eq(done.data.outcome, "ok", S.dump(done.data))
      S.eq(storage.owner_hold.h1.kind, "stop", "hold пережил отступление")
      B.tick(600)
      S.eq(#B.events("reflex_resumed"), 0, "стоп снял задачи — возвращать нечего")
  end },

  { "иди сюда, потом атака: отступление идёт, возврат к follow запрещён hold (reason owner_hold)", function()
      local _, h = H.setup()
      H.set{ { type = "flee" } }
      S.chat(1, "иди сюда")
      B.tick(3)
      S.eq(require("scripts.core.jobs").active("h1")["do"], "follow")
      local foe = H.enemy({ x = h.position.x + 10, y = h.position.y })
      H.wait("reflex_fired")
      foe.destroy()
      S.eq(H.wait("reflex_done").data.outcome, "ok")
      local r = H.wait("reflex_resumed")
      S.eq(r.data, { type = "flee", jobs = {}, reason = "owner_hold" })
      S.eq(require("scripts.core.jobs").active("h1"), nil)
  end },

  { "стоп, потом «иди сюда»: старый hold снят, follow встал, hold come", function()
      busy()
      S.chat(1, "стоп")
      S.chat(1, "иди сюда")
      B.tick(2)
      S.eq(require("scripts.core.jobs").active("h1")["do"], "follow")
      S.eq(storage.owner_hold.h1.kind, "come")
      local lines = say_lines()
      S.eq(lines[#lines], "Claude: Иду.")
      S.eq(last_of("owner_stop").data.follow_failed, nil)
  end },

  { "иди сюда: follow не встал — честный ответ, follow_failed, hold стоит", function()
      busy()
      local W = words()
      local keep = W.COME_DISTANCE
      W.COME_DISTANCE = -1 -- follow отвергнет аргументы
      S.chat(1, "иди сюда")
      W.COME_DISTANCE = keep
      S.eq(require("scripts.core.jobs").queue_len("h1"), 0)
      local lines = say_lines()
      S.eq(lines[#lines], "Claude: Не могу подойти (bad_args). Стою.")
      local os = last_of("owner_stop").data
      S.eq({ os.kind, os.follow_failed }, { "come", { "h1" } })
      S.eq(storage.owner_hold.h1.kind, "come")
  end },

  { "стоп снимает весь ручной крафт и фоновые крафты", function()
      local W = C.setup{ items = { ["iron-plate"] = 40 } }
      S.okr(C.act("craft", { recipe = "iron-gear-wheel", count = 5, wait = false }))
      S.okr(C.act("craft", { recipe = "iron-gear-wheel", count = 7, wait = false }))
      C.run(5)
      S.ok(W.h.crafting_queue_size > 0, "крафт идёт")
      S.ok(storage.bg_crafts and storage.bg_crafts.h1 ~= nil, "фоновые крафты записаны")
      S.chat(1, "стоп")
      S.eq(W.h.crafting_queue_size, 0)
      S.eq(storage.bg_crafts.h1, nil)
      local gears = C.counts(W.main)["iron-gear-wheel"] or 0
      S.eq((C.counts(W.main)["iron-plate"] or 0) + 2 * gears, 40, "ингредиенты вернулись")
      C.run(200)
      S.eq(#C.events("craft_done"), 0, "craft_done по снятому крафту нет")
  end },

  { "имя с точкой и пробелами («Mr. Bot») — обращение", function()
      B.setup()
      S.set_setting("partner-helper-name", "Mr. Bot")
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h2"))
      local W = words()
      S.eq(W.squash("Mr. Bot"), "mrbot")
      S.chat(1, "Mr. Bot, стоп")
      S.eq(storage.owner_hold.h1.kind, "stop")
      S.eq(storage.owner_hold.h2, nil)
      S.chat(1, "mr bot h2 стой")
      S.eq(storage.owner_hold.h2.kind, "stop")
      S.chat(1, "MR.BOT2: продолжай")
      S.eq(storage.owner_hold.h2, nil)
      S.eq(storage.owner_hold.h1.kind, "stop")
  end },

  { "иди сюда: задачи сняты, ставится follow к хозяину, ответ, hold kind=come", function()
      busy()
      S.chat(1, "иди сюда")
      local jobs = require("scripts.core.jobs")
      S.eq(jobs.queue_len("h1"), 1)
      B.tick(2)
      S.eq(jobs.active("h1")["do"], "follow")
      local lines = say_lines()
      S.eq(lines[#lines], "Claude: Иду.")
      S.eq(last_of("owner_stop").data.kind, "come")
      S.eq(storage.owner_hold.h1.kind, "come")
  end },

  { "что делаешь: ответ шаблоном, задачи и очередь не тронуты, hold не ставится", function()
      busy()
      local jobs = require("scripts.core.jobs")
      local active = jobs.active("h1")
      S.chat(1, "чем занят?")
      S.eq(jobs.active("h1"), active)
      S.eq(jobs.queue_len("h1"), 2)
      local lines = say_lines()
      S.eq(lines[#lines], "Claude: Сейчас: жду. В очереди ещё 2.")
      S.eq(next(storage.owner_hold or {}), nil)
      S.eq(last_of("owner_stop"), nil)
      S.eq(last_of("player_said").data.word.kind, "status")
  end },

  { "адресация: имя — только он; без имени — все; чужое имя — ничего", function()
      B.setup()
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.okr(S.req("act", { ["do"] = "wait", args = { seconds = 600 } }, "h1"))
      S.okr(S.req("act", { ["do"] = "wait", args = { seconds = 600 } }, "h2"))
      B.tick(3)
      local jobs = require("scripts.core.jobs")
      S.chat(1, "Claude2, стоп")
      S.eq(jobs.active("h2"), nil)
      S.ok(jobs.active("h1") ~= nil, "h1 не затронут")
      S.eq(storage.owner_hold.h1, nil)
      S.eq(storage.owner_hold.h2.kind, "stop")
      S.eq(last_of("owner_stop").data.helpers, { "h2" })
      S.chat(1, "Claude, продолжай") -- h1 не держится: слово не для него
      S.eq(storage.owner_hold.h2.kind, "stop")
      S.chat(1, "claude h2 продолжай")
      S.eq(storage.owner_hold.h2, nil)
      S.chat(1, "Claude7, продолжай") -- такого помощника нет, hold нигде не стоит
      S.ok(jobs.active("h1") ~= nil)
      S.eq(count_of("owner_stop"), 1)
      S.chat(1, "стоп, h1")
      S.eq(storage.owner_hold.h1.kind, "stop")
      S.eq(storage.owner_hold.h2, nil)
      S.chat(1, "продолжай")
      S.okr(S.req("act", { ["do"] = "wait", args = { seconds = 600 } }, "h1"))
      B.tick(3)
      S.chat(1, "стоп")
      S.eq(storage.owner_hold.h1.kind, "stop")
      S.eq(storage.owner_hold.h2.kind, "stop")
      S.eq(last_of("owner_stop").data.helpers, { "h1", "h2" })
  end },

  { "не хозяин не срабатывает никогда", function()
      busy()
      S.add_player{ name = "Guest", position = { 1, 1 } }
      local jobs = require("scripts.core.jobs")
      S.chat(2, "стоп")
      S.chat(2, "иди сюда")
      S.chat(2, "что делаешь")
      S.ok(jobs.active("h1") ~= nil)
      S.eq(next(storage.owner_hold or {}), nil)
      S.eq(last_of("owner_stop"), nil)
      local ps = last_of("player_said")
      S.eq({ ps.data.owner, ps.data.auto_reply, ps.loud }, { false, nil, false })
  end },

  { "настройки: выключатель и свой список стоп-слов", function()
      busy()
      local jobs = require("scripts.core.jobs")
      S.set_setting("partner-owner-words", false)
      S.chat(1, "стоп")
      S.ok(jobs.active("h1") ~= nil)
      S.set_setting("partner-owner-words", true)
      S.set_setting("partner-stop-words", "замри, hold on")
      S.chat(1, "стоп")
      S.ok(jobs.active("h1") ~= nil, "«стоп» больше не в списке")
      S.chat(1, "Замри!")
      S.eq(jobs.active("h1"), nil)
      S.eq(storage.owner_hold.h1.kind, "stop")
  end },

  { "одно сообщение без имени снимает hold у каждого помощника по разу; повтор пары — отказ", function()
      B.setup()
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.chat(1, "стоп")
      local stop = last_of("player_said").seq
      S.chat(1, "строй печи")
      local order = last_of("player_said").seq
      S.eq(S.okr(S.req("owner_hold", { release = true, seq = order }, "h1")).released, { "h1" })
      S.eq(storage.owner_hold_used[order], { h1 = true }, "h2 ещё держится: пара запомнена")
      S.eq(S.okr(S.req("owner_hold", { release = true, seq = order }, "h2")).released, { "h2" })
      S.eq(next(storage.owner_hold), nil)
      S.eq(next(storage.owner_hold_used), nil, "hold не осталось — память пар не нужна")
      -- та же пара при стоящем hold (старее сообщения) — отказ по памяти пар
      S.chat(1, "стоп")
      S.chat(1, "неси уголь")
      local coal = last_of("player_said").seq
      S.eq(S.okr(S.req("owner_hold", { release = true, seq = coal }, "h1")).released, { "h1" })
      storage.owner_hold.h1 = { kind = "stop", tick = game.tick, seq = stop }
      S.err(S.req("owner_hold", { release = true, seq = coal }, "h1"), "bad_args")
      S.ok(storage.owner_hold.h1 ~= nil)
      S.eq(S.okr(S.req("owner_hold", { release = true, seq = coal }, "h2")).released, { "h2" })
  end },

  { "«стоп, ставь печи» — не стоп: задачи и hold не тронуты, сообщение уходит агенту", function()
      busy()
      local jobs = require("scripts.core.jobs")
      S.chat(1, "стоп, ставь печи")
      S.ok(jobs.active("h1") ~= nil)
      S.eq(jobs.queue_len("h1"), 2)
      S.eq(next(storage.owner_hold or {}), nil)
      local ps = last_of("player_said")
      S.eq({ ps.data.auto_reply, ps.data.word }, { nil, nil })
      S.eq(last_of("owner_stop"), nil)
      S.chat(1, "Claude, стоп немедленно")
      S.eq(jobs.active("h1"), nil)
      S.eq(storage.owner_hold.h1.kind, "stop")
  end },

  { "hold переживает смерть и возрождение помощника", function()
      busy()
      S.chat(1, "стоп")
      local seq = storage.owner_hold.h1.seq
      storage.helpers.h1.entity.die()
      S.eq(storage.helpers.h1.state, "dead")
      B.tick(61)
      S.eq(storage.owner_hold.h1.seq, seq, "мёртвый помощник держится")
      B.tick(require("scripts.reflexes.death").RESPAWN_TICKS + 120)
      S.eq(storage.helpers.h1.state, "alive")
      S.eq(storage.owner_hold.h1.seq, seq, "возрождённый помощник держится")
      S.err(S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1"), "owner_hold")
  end },

  { "стоп снимает крафт с промежуточными записями: с конца, без prerequisite; не снялось — craft_done не теряется", function()
      local W = C.setup{}
      local h = W.h
      -- очередь как в игре: промежуточные записи (prerequisite) стоят перед своим главным крафтом и
      -- напрямую не снимаются; отмена главного снимает и их
      local q = {}
      local function refresh()
        local out, size = {}, 0
        for i, e in ipairs(q) do
          out[i] = { index = i, recipe = e.recipe, count = e.count, prerequisite = e.pre ~= nil }
          size = size + e.count
        end
        rawset(h, "crafting_queue", #out > 0 and out or nil)
        rawset(h, "crafting_queue_size", size)
      end
      local function fill()
        local a, b = { recipe = "a", count = 1 }, { recipe = "b", count = 2 }
        q = { { recipe = "gear", count = 2, pre = a }, a, { recipe = "gear", count = 4, pre = b }, b }
        refresh()
      end
      local calls = {}
      rawset(h, "cancel_crafting", function(p)
        local e = q[p.index]
        if e == nil or e.pre ~= nil then error("cannot cancel a prerequisite", 2) end
        calls[#calls + 1] = e.recipe
        local keep = {}
        for _, x in ipairs(q) do if x ~= e and x.pre ~= e then keep[#keep + 1] = x end end
        q = keep
        refresh()
      end)
      fill()
      storage.bg_crafts = { h1 = { { recipe = "b", product = "b", base = 0, expected = 2 } } }
      S.chat(1, "стоп")
      S.eq(calls, { "b", "a" })
      S.eq({ h.crafting_queue, h.crafting_queue_size }, { nil, 0 })
      S.eq(storage.bg_crafts.h1, nil, "очередь пуста — фоновые крафты забыты")
      -- снять не удалось — фоновые крафты остаются, craft_done придёт от bgcraft
      S.chat(1, "продолжай")
      fill()
      rawset(h, "cancel_crafting", function() error("cannot cancel") end)
      storage.bg_crafts = { h1 = { { recipe = "b", product = "b", base = 0, expected = 2 } } }
      S.chat(1, "стоп")
      S.ok(h.crafting_queue_size > 0)
      S.ok(storage.bg_crafts.h1 ~= nil, "крафт не снят — запись осталась")
  end },

  { "hold сбрасывается, когда помощника убрали; убранного сообщение не трогает", function()
      busy()
      S.chat(1, "стоп")
      S.okr(S.req("helper_remove", {}, "h1"))
      B.tick(61)
      S.eq(storage.owner_hold.h1, nil)
      S.chat(1, "стоп")
      S.eq(count_of("owner_stop"), 1)
  end },
})
