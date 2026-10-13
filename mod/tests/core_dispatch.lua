-- Команда /partner: конверт, ошибки, идемпотентность, лимиты (PROTOCOL §1–§4).
local S = require("stubs")

local function spawn()
  S.add_player{ name = "Tartaluga" }
  return S.okr(S.req("helper_spawn", {}, "h1"))
end

-- подменный модуль восприятия с управляемым ответом
local function fake_state(fn)
  return { ["scripts.perception.state"] = { ops = { state = fn } } }
end

S.suite("dispatch", {
  { "hello: конверт и данные", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga", position = { 1.26, -3.04 } }
      local r = S.call{ v = 1, id = "r-1", op = "hello", args = {} }
      S.eq({ r.v, r.id, r.ok, r.tick, r.seq }, { 1, "r-1", true, 0, 0 })
      S.eq(r.data.proto, 1)
      S.eq(r.data.mod, "0.1.0")
      S.eq(r.data.owner, "Tartaluga")
      S.eq(r.data.players, { { index = 1, name = "Tartaluga", online = true, surface = "nauvis", pos = { x = 1.3, y = -3 } } })
      S.eq(r.data.helpers, {})
      S.eq(r.data.players_online, 1)
      S.eq(r.data.module_errors, 0)
  end },
  { "hello: players_online считает только подключённых; офлайн-игрок в списке с online=false", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.add_player{ name = "Friend", connected = false, position = { 7, 8 } }
      S.add_player{ name = "Third" }
      local d = S.okr(S.call{ v = 1, id = "r-2", op = "hello" })
      S.eq(d.players_online, 2)
      S.eq(#d.players, 3)
      S.eq({ d.players[2].name, d.players[2].online, d.players[2].pos }, { "Friend", false, { x = 7, y = 8 } })
      S.eq(S.okr(S.call{ v = 1, id = "r-3", op = "hello" }).helpers, {})
  end },
  { "hello: helpers — живые и мёртвые, но не удалённые", function()
      S.load_mod()
      S.okr(S.req("helper_limit", { max = 3 }))
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.okr(S.req("helper_spawn", {}, "h2"))
      S.okr(S.req("helper_spawn", {}, "h3"))
      storage.helpers.h2.entity.die()
      S.okr(S.req("helper_remove", {}, "h3"))
      S.eq(S.okr(S.req("hello")).helpers, { "h1", "h2" })
  end },
  { "ровно одна строка в RCON, без переводов строк", function()
      S.load_mod()
      local line = S.rcon('{"v":1,"id":"a","op":"hello","args":{}}')
      S.ok(type(line) == "string" and not line:find("\n"))
  end },
  { "не JSON / пусто / не объект -> bad_request без id", function()
      S.load_mod()
      for _, p in ipairs({ "{oops", "", "123", '"str"' }) do
        local r = helpers.json_to_table(S.rcon(p))
        S.err(r, "bad_request", p)
        S.eq(r.id, nil)
      end
  end },
  { "неверный id -> bad_request", function()
      S.load_mod()
      for _, id in ipairs({ "", string.rep("a", 41), "a b", "ид", 5 }) do
        local r = S.call{ v = 1, id = id, op = "hello" }
        S.err(r, "bad_request", tostring(id))
      end
      S.okr(S.call{ v = 1, id = "Az09_.:-" .. string.rep("x", 32), op = "hello" })
  end },
  { "v: нет -> bad_request, другая -> version_mismatch", function()
      S.load_mod()
      S.err(S.call{ id = "a", op = "hello" }, "bad_request")
      S.err(S.call{ v = "1", id = "b", op = "hello" }, "bad_request")
      local r = S.call{ v = 2, id = "c", op = "hello" }
      S.err(r, "version_mismatch")
      S.eq(r.id, "c")
  end },
  { "op: нет -> bad_request, неизвестная -> unknown_op", function()
      S.load_mod()
      S.err(S.call{ v = 1, id = "a" }, "bad_request")
      S.err(S.call{ v = 1, id = "b", op = "teleport" }, "unknown_op")
  end },
  { "лишнее поле конверта, args не объект, плохой helper -> bad_request", function()
      S.load_mod()
      S.err(S.call{ v = 1, id = "a", op = "hello", key = "secret" }, "bad_request")
      S.err(S.call{ v = 1, id = "b", op = "hello", args = { 1, 2 } }, "bad_request")
      S.err(S.call{ v = 1, id = "c", op = "hello", args = "x" }, "bad_request")
      S.err(S.call{ v = 1, id = "d", op = "jobs", helper = "H1" }, "bad_request")
      S.err(S.call{ v = 1, id = "e", op = "jobs", helper = string.rep("a", 17) }, "bad_request")
      -- пустой массив [] == {} (PROTOCOL §1)
      S.okr(S.call{ v = 1, id = "f", op = "hello", args = {} })
      S.okr(helpers.json_to_table(S.rcon('{"v":1,"id":"g","op":"hello","args":[]}')))
  end },
  { "операция h без helper -> bad_request, с мёртвым/отсутствующим -> no_helper", function()
      S.load_mod()
      S.err(S.req("jobs", {}), "bad_request")
      S.err(S.req("jobs", {}, "h1"), "no_helper")
      S.err(S.req("say", { text = "hi" }, "h9"), "no_helper")
  end },
  { "h?: без helper — ctx без помощника, с отсутствующим — no_helper", function()
      local seen
      S.load_mod{ replace = { ["scripts.perception.map"] = { ops = { map = function(a, ctx) seen = ctx return { ok = 1 } end } } } }
      S.okr(S.req("map", {}))
      S.eq(seen.helper_id, nil)
      S.err(S.req("map", {}, "h1"), "no_helper")
      spawn()
      S.okr(S.req("map", {}, "h1"))
      S.eq(seen.helper_id, "h1")
      S.ok(seen.entity and seen.entity.valid)
      S.eq(seen.request_id ~= nil, true)
  end },
  { "/partner из чата игрока: отказ игроку, в RCON ничего", function()
      S.load_mod()
      local p = S.add_player{ name = "Tartaluga" }
      local n = S.chat_command(1, '{"v":1,"id":"x","op":"hello"}')
      S.eq(n, 0)
      S.eq(p.printed, { "[partner] только для RCON" })
      -- и не попало в recent: тот же id из RCON исполняется
      S.okr(S.call{ v = 1, id = "x", op = "hello" })
  end },
  { "идемпотентность: тот же id -> тот же ответ, операция не повторяется", function()
      S.load_mod()
      spawn()
      local env = { v = 1, id = "act-1", op = "act", helper = "h1", args = { ["do"] = "wait", args = { seconds = 5 } } }
      local r1, l1 = S.call(env)
      S.tick(3)
      local r2, l2 = S.call(env)
      S.eq(l2, l1, "сохранённая строка")
      local jobs = S.okr(S.req("jobs", {}, "h1"))
      S.eq(jobs.active.job, r1.data.job)
      S.eq(#jobs.queue, 0, "вторая задача не поставлена")
  end },
  { "идемпотентность: ошибка тоже сохраняется", function()
      S.load_mod()
      local _, l1 = S.call{ v = 1, id = "s1", op = "helper_spawn", helper = "h1" }
      S.add_player{ name = "Tartaluga" }
      local _, l2 = S.call{ v = 1, id = "s1", op = "helper_spawn", helper = "h1" }
      S.eq(l2, l1)
      S.err(helpers.json_to_table(l2), "no_player")
  end },
  { "кольцо recent: 128 последних", function()
      S.load_mod()
      local _, first = S.call{ v = 1, id = "id-0", op = "hello" }
      for i = 1, 127 do S.call{ v = 1, id = "id-" .. i, op = "hello" } end
      S.tick()
      local _, again = S.call{ v = 1, id = "id-0", op = "hello" }
      S.eq(again, first, "ещё в кольце")
      S.call{ v = 1, id = "id-128", op = "hello" }
      local r = S.call{ v = 1, id = "id-0", op = "hello" }
      S.eq(r.tick, 1, "вытеснен — исполнен заново")
      local n = 0
      for _ in pairs(storage.recent.map) do n = n + 1 end
      S.eq(n, 128)
  end },
  { "запрос > 8 КБ -> limit", function()
      S.load_mod()
      local big = '{"v":1,"id":"big","op":"say","helper":"h1","args":{"text":"' .. string.rep("a", 8200) .. '"}}'
      local r = helpers.json_to_table(S.rcon(big))
      S.err(r, "limit")
      S.eq(r.id, "big", "id из разобранного запроса — сервер сопоставит ответ")
      local bad = '{"v":1,"id":"a b","op":"say","args":{"text":"' .. string.rep("a", 8200) .. '"}}'
      r = helpers.json_to_table(S.rcon(bad))
      S.err(r, "limit")
      S.eq(r.id, nil)
      r = helpers.json_to_table(S.rcon("{oops" .. string.rep("a", 8200)))
      S.err(r, "limit")
      S.eq(storage.recent.map.big, nil, "limit не кладётся в recent")
  end },
  { "исключение внутри process -> internal одной строкой", function()
      S.load_mod()
      local d = require("scripts.core.dispatch")
      d.process = function() error("boom at x.lua:1") end
      local line = S.rcon('{"v":1,"id":"a","op":"hello","args":{}}')
      local r = helpers.json_to_table(line)
      S.err(r, "internal")
      S.eq(r.id, nil)
      S.ok(not line:find("boom", 1, true), line)
  end },
  { "hello: игрок без тела и поверхности — без surface/pos, без падения", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      local p2 = S.add_player{ name = "Ghost", character = false }
      p2.surface = nil
      local r = S.okr(S.req("hello"))
      S.eq(r.players[2], { index = 2, name = "Ghost", online = true })
  end },
  { "recent: ответ только-для-чтения > 16 КБ не хранится, повтор исполняется заново", function()
      local calls = 0
      S.load_mod{ replace = fake_state(function() calls = calls + 1; return { s = string.rep("x", 17000) } end) }
      spawn()
      S.okr(S.req("state", {}, "h1", "big-read"))
      S.okr(S.req("state", {}, "h1", "big-read"))
      S.eq(calls, 2)
      S.eq(storage.recent.map["big-read"], nil)
      S.okr(S.req("state", {}, "h1", "small"))
  end },
  { "ответ > 200 000 байт -> too_large", function()
      S.load_mod{ replace = fake_state(function() return { s = string.rep("x", 200001) } end) }
      spawn()
      local r = S.req("state", {}, "h1")
      S.err(r, "too_large")
  end },
  { "LuaObject в ответе -> internal, а не падение", function()
      S.load_mod{ replace = fake_state(function(a, ctx) return { e = ctx.entity } end) }
      spawn()
      S.err(S.req("state", {}, "h1"), "internal")
  end },
  { "ошибка Lua в операции -> internal без путей к файлам", function()
      S.load_mod{ replace = fake_state(function() local t = nil; return t.x end) }
      spawn()
      local e = S.err(S.req("state", {}, "h1"), "internal")
      S.ok(not e.text:find(".lua", 1, true), e.text)
      S.ok(not e.text:find("__factorio", 1, true), e.text)
  end },
  { "err.raise из операции -> свой код и текст", function()
      S.load_mod{ replace = fake_state(function() require("scripts.core.err").raise("not_visible", "dark") end) }
      spawn()
      local e = S.err(S.req("state", {}, "h1"), "not_visible")
      S.eq(e.text, "dark")
  end },
  { "неизвестный код ошибки модуля -> internal", function()
      S.load_mod{ replace = fake_state(function() require("scripts.core.err").raise("weird", "x") end) }
      spawn()
      S.err(S.req("state", {}, "h1"), "internal")
  end },
  { "seq в ответе = последний номер события", function()
      S.load_mod()
      spawn()
      S.req("act", { ["do"] = "wait", args = { seconds = 1 } }, "h1")
      S.tick(61)
      local r = S.req("hello")
      S.eq(r.seq, 1)
      S.eq(r.data.seq, 1)
  end },
  { "ответ ok без data у операции -> data = {}", function()
      S.load_mod{ replace = fake_state(function() return nil end) }
      spawn()
      S.eq(S.okr(S.req("state", {}, "h1")), {})
  end },
})
