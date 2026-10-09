-- Буфер событий, op events, player_said (EVENTS.md).
local S = require("stubs")

local function ev() return require("scripts.core.events") end

S.suite("events", {
  { "emit: seq монотонный, loud по таблице, helper", function()
      S.load_mod()
      S.tick(5)
      local E = ev()
      S.eq(E.emit("h1", "job_done", { job = 1 }), 1)
      S.eq(E.emit(nil, "saw_enemy", { name = "small-biter" }), 2)
      S.eq(E.emit("h1", "attacked", { damage = 5 }, { loud = false }), 3)
      local r = S.okr(S.req("events", { since = 0 }))
      S.eq(r.seq, 3)
      S.eq(r.lost, false)
      S.eq(r.events[1], { seq = 1, tick = 5, helper = "h1", kind = "job_done", data = { job = 1 }, loud = true })
      S.eq({ r.events[2].loud, r.events[2].helper, r.events[3].loud }, { false, nil, false })
  end },
  { "events: since, фильтр helper (его + мировые), limit и курсор seq", function()
      S.load_mod()
      local E = ev()
      for i = 1, 10 do E.emit(i % 2 == 0 and "h1" or "h2", "job_done", { job = i }) end
      E.emit(nil, "player_said", { owner = false })
      local r = S.okr(S.req("events", { since = 4, helper = "h1" }))
      local jobs = {}
      for _, e in ipairs(r.events) do jobs[#jobs + 1] = e.data.job or "world" end
      S.eq(jobs, { 6, 8, 10, "world" })
      S.eq(r.seq, 11)
      r = S.okr(S.req("events", { since = 0, limit = 3 }))
      S.eq(#r.events, 3)
      S.eq(r.seq, 3, "курсор = последний выданный")
      r = S.okr(S.req("events", { since = r.seq, limit = 3 }))
      S.eq(r.events[1].seq, 4)
      r = S.okr(S.req("events", { since = 11 }))
      S.eq({ #r.events, r.seq }, { 0, 11 })
      r = S.okr(S.req("events", { since = 99 }))
      S.eq({ #r.events, r.seq }, { 0, 11 })
  end },
  { "events: аргументы", function()
      S.load_mod()
      S.err(S.req("events", {}), "bad_args")
      S.err(S.req("events", { since = -1 }), "bad_args")
      S.err(S.req("events", { since = 0, limit = 201 }), "limit") -- верхняя граница -> limit (PROTOCOL §3)
      S.err(S.req("events", { since = 0, limit = 0 }), "bad_args") -- нижняя -> bad_args
      S.err(S.req("events", { since = 0, helper = "H!" }), "bad_args")
      S.okr(S.req("events", { since = 0, limit = 200 }))
  end },
  { "кольцо 500: старые вытесняются, lost=true", function()
      S.load_mod()
      local E = ev()
      for i = 1, 600 do E.emit("h1", "job_progress", { job = i }) end
      local r = S.okr(S.req("events", { since = 0, limit = 200 }))
      S.eq(r.lost, true)
      S.eq(r.events[1].seq, 101)
      r = S.okr(S.req("events", { since = 100, limit = 1 }))
      S.eq(r.lost, false)
      r = S.okr(S.req("events", { since = 99, limit = 1 }))
      S.eq(r.lost, true)
      local n = 0
      for _ in pairs(storage.events.list) do n = n + 1 end
      S.eq(n, 500)
  end },
  { "seq не сбрасывается при загрузке", function()
      S.load_mod()
      ev().emit("h1", "job_done", { job = 1 })
      S.reload()
      S.eq(ev().emit("h1", "job_done", { job = 2 }), 2)
      S.reload{ changed = { mod_changes = {} } }
      S.eq(ev().emit("h1", "job_done", { job = 3 }), 3)
  end },
  { "данные события: LuaObject выкидывается, большие — truncated", function()
      S.load_mod()
      local E = ev()
      local e = S.nauvis.create_entity{ name = "iron-chest", position = { 0, 0 }, force = "player" }
      E.emit("h1", "x", { ent = e, n = 1 })
      E.emit("h1", "y", { s = string.rep("a", 5000) })
      local r = S.okr(S.req("events", { since = 0 }))
      S.eq(r.events[1].data, { n = 1 })
      S.eq(r.events[2].data, { s = string.rep("a", 200), truncated = true })
  end },
  { "emit с мусором вместо data не падает (событие уходит пустым)", function()
      S.load_mod()
      local E = ev()
      E.emit("h1", "x", "строка")
      E.emit("h1", "y", 42)
      E.emit("h1", "z", nil)
      E.emit("h1", "w", { f = function() end, ok = 1 })
      local r = S.okr(S.req("events", { since = 0 }))
      S.eq(#r.events, 4)
      S.eq(r.events[1].data, {})
      S.eq(r.events[4].data, { ok = 1 })
  end },
  { "большой detail не теряет job и code (job_failed ужимается, а не обнуляется)", function()
      S.load_mod()
      local E = ev()
      local blocked = {}
      for i = 1, 300 do blocked[i] = { name = "stone-furnace", pos = { x = i + 0.5, y = -i - 0.5 } } end
      E.emit("h1", "job_failed", { job = 7, ["do"] = "build_ghosts", code = "stuck", text = "no progress",
        detail = { left = 300, blocked = blocked, missing = { ["stone-furnace"] = 300 } } })
      E.emit("h1", "job_done", { job = 8, ["do"] = "build_blueprint", detail = { built = blocked } })
      local r = S.okr(S.req("events", { since = 0 }))
      S.eq(r.events[1].data, { job = 7, ["do"] = "build_ghosts", code = "stuck", text = "no progress",
        detail = { truncated = true }, truncated = true })
      S.eq(r.events[1].loud, true)
      S.eq(r.events[2].data, { job = 8, ["do"] = "build_blueprint", detail = { truncated = true }, truncated = true })
  end },
  { "ужатие: маленькие таблицы остаются, большие выкидываются с truncated", function()
      S.load_mod()
      local E = ev()
      E.emit("h1", "stuck", { job = 3, pos = { x = 1, y = 2 }, reason = "blocked", big = { s = string.rep("b", 5000) } })
      local many = {}
      for i = 1, 600 do many["k" .. i] = i end
      many.job = 4
      many.code = "stuck"
      many.detail = { 1, 2, 3 }
      E.emit("h1", "job_failed", many)
      local r = S.okr(S.req("events", { since = 0 }))
      S.eq(r.events[1].data, { job = 3, pos = { x = 1, y = 2 }, reason = "blocked", truncated = true })
      S.eq(r.events[2].data, { job = 4, code = "stuck", detail = { truncated = true }, truncated = true })
  end },
  { "events: ответ не больше ~150 КБ, курсор продолжает без пропусков", function()
      S.load_mod()
      local E = ev()
      for i = 1, 100 do E.emit("h1", "job_progress", { job = i, s = string.rep("z", 3800) }) end
      local r = S.okr(S.req("events", { since = 0 }))
      S.ok(#r.events < 100 and #r.events > 10, "обрезано по размеру: " .. #r.events)
      S.eq(r.seq, r.events[#r.events].seq, "курсор = последний выданный")
      local got = #r.events
      while got < 100 do
        local r2 = S.okr(S.req("events", { since = r.seq }))
        S.eq(r2.events[1].seq, r.seq + 1)
        got = got + #r2.events
        r = r2
      end
      S.eq({ got, r.seq }, { 100, 100 })
  end },
  { "player_said: хозяин — loud, selected; не хозяин — тихо", function()
      S.load_mod()
      local own = S.add_player{ name = "Tartaluga", position = { 10.04, 20 } }
      S.add_player{ name = "Guest", position = { 1, 1 } }
      own.selected = S.nauvis.create_entity{ name = "iron-ore", position = { 12.5, 20.5 }, force = "neutral" }
      S.chat(1, "поставь\nдобычу\r\nтут")
      S.chat(2, "привет")
      local r = S.okr(S.req("events", { since = 0 }))
      local a, b = r.events[1], r.events[2]
      S.eq({ a.kind, a.loud, a.helper }, { "player_said", true, nil })
      S.eq(a.data, { player = "Tartaluga", owner = true, text = "поставь добычу тут", pos = { x = 10, y = 20 },
        selected = { name = "iron-ore", pos = { x = 12.5, y = 20.5 }, unit_number = own.selected.unit_number } })
      S.eq({ b.loud, b.data.owner, b.data.text, b.data.selected }, { false, false, "привет", nil })
  end },
  { "player_said: ≤ 500 символов, битый UTF-8 чинится, без player_index — игнор", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.chat(1, string.rep("я", 600))
      S.chat(1, "a\255b")
      S.fire(defines.events.on_console_chat, { message = "from server" })
      local r = S.okr(S.req("events", { since = 0 }))
      S.eq(#r.events, 2)
      local t = r.events[1].data.text
      S.eq(#t, 1000, "500 символов по 2 байта")
      S.eq(r.events[2].data.text, "a?b")
  end },
  { "say не порождает player_said", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.okr(S.req("say", { text = "привет" }, "h1"))
      S.eq(S.okr(S.req("events", { since = 0 })).events, {})
  end },
})
