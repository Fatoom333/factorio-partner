-- Тело-игрок: ядро каждый тик выставляет состояния ходьбы и добычи, которые сбрасывает
-- ввод клиента. PROTOCOL §7 «Два вида тела». «Клиент» — stubs_p.lua (сброс перед on_tick).
local S = require("stubs")
local B = require("stubs_b")
local C = require("stubs_c")
local P = require("stubs_p")

local EAST, SOUTH = 4, 8

local function all_seen(A, field, want, from)
  for i = from or 1, #A.seen do
    if A.seen[i][field] ~= want then return false, i end
  end
  return true
end

S.suite("attach_hold", {
  { "клиент сбрасывает ходьбу каждый тик — ядро выставляет её снова, тело идёт", function()
      local _, friend = P.setup()
      local A = P.action()
      local h = friend.character
      P.act("p_once", {})
      P.tick(101)
      S.ok(#A.seen >= 99, "действие тикало: " .. #A.seen)
      S.ok(all_seen(A, "walking", true), "действие каждый тик видит ходьбу включённой")
      S.ok(all_seen(A, "direction", EAST))
      S.near(h.position.x, 20 + 0.15 * 100, 0.31, "прошёл ~15 клеток: " .. h.position.x)
      S.eq(h.position.y, 0)
      local hold = P.rec().hold
      S.eq(hold.walking, true)
      S.eq(hold.direction, EAST)
      S.eq(hold.mining, false)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },

  { "контроль: без удержания то же действие у тела-игрока встаёт на втором тике", function()
      local _, friend = P.setup()
      local A = P.action()
      local jobs = require("scripts.core.jobs")
      jobs.body_hooks.before_tick = nil
      jobs.body_hooks.after_tick = nil
      P.act("p_once", {})
      P.tick(101)
      S.ok(friend.character.position.x < 20.2, "сделал один шаг и встал: " .. friend.character.position.x)
      S.eq(all_seen(A, "walking", false), true, "ввод клиента сбросил ходьбу")
  end },

  { "тело без игрока ядро не трогает: состояния держатся сами, hold не заводится", function()
      P.setup{ attach = false }
      local A = P.action()
      S.okr(S.req("helper_spawn", {}, "h1"))
      local h = storage.helpers.h1.entity
      local x0 = h.position.x
      P.act("p_once", {}, "h1")
      P.tick(51)
      S.eq(storage.helpers.h1.hold, nil)
      S.ok(all_seen(A, "walking", true))
      S.near(h.position.x, x0 + 0.15 * 50, 0.31)
  end },

  { "действие сменило направление — держится новое", function()
      local _, friend = P.setup()
      local A = P.action()
      P.act("p_once", {})
      P.tick(11)
      P.turn = SOUTH
      P.tick(1)
      local at = #A.seen
      local pos = S.copy(friend.character.position)
      P.tick(40)
      S.ok(all_seen(A, "direction", SOUTH, at + 1), "после поворота — юг")
      S.eq(P.rec().hold.direction, SOUTH)
      S.near(friend.character.position.x, pos.x, 0.001, "на восток больше не идёт")
      S.near(friend.character.position.y, pos.y + 0.15 * 40, 0.31)
  end },

  { "действие завершилось — держать нечего: hold пуст, тело стоит", function()
      local _, friend = P.setup()
      P.action()
      local job = P.act("p_once", {}).job
      P.tick(20)
      P.finish = true
      P.tick(1)
      S.eq(P.result(job).kind, "job_done")
      S.eq(P.rec().hold, nil)
      local x = friend.character.position.x
      P.tick(30)
      S.eq(friend.character.position.x, x, "стоит")
      S.eq(friend.character.walking_state.walking, false)
  end },

  { "cancel и replace: stop выключает ходьбу, удержание её не возвращает", function()
      local _, friend = P.setup()
      local A = P.action()
      local job = P.act("p_once", {}).job
      P.tick(20)
      S.okr(S.req("cancel", { job = job }, "p1"))
      S.eq(A.stops, 1)
      local x = friend.character.position.x
      P.tick(30)
      S.eq(P.rec().hold, nil)
      S.eq(friend.character.position.x, x, "после отмены стоит")
      -- replace: новая задача начинается с чистого листа
      P.act("p_once", {})
      P.tick(10)
      P.act("p_once", { walk = false }, "p1", { replace = true })
      S.eq(A.stops, 2)
      local x2 = friend.character.position.x
      local at = #A.seen
      P.tick(30)
      S.eq(P.rec().hold, nil)
      S.eq(all_seen(A, "walking", false, at + 1), true, "новая задача ходьбу прошлой не видит")
      S.eq(friend.character.position.x, x2, "стоит на месте: ходьба прошлой задачи не воскресла")
  end },

  { "добыча: selected и mining_state выставляются каждый тик", function()
      local _, friend = P.setup()
      local A = P.action()
      P.target = S.nauvis.create_entity{ name = "tree-01", position = { x = 21.5, y = 0.5 }, force = "neutral" }
      P.act("p_once", { walk = false, mine = true })
      P.tick(61)
      S.ok(#A.seen >= 59)
      S.ok(all_seen(A, "mining", true), "добыча включена каждый тик")
      S.ok(all_seen(A, "selected", P.target), "цель выбрана каждый тик")
      S.ok(all_seen(A, "walking", false), "ходьбу никто не включал")
      S.eq(A.seen[#A.seen].position, { x = 21.5, y = 0.5 })
      local hold = P.rec().hold
      S.eq(hold.mining, true)
      S.eq(hold.walking, false)
      S.ok(hold.selected == P.target)
      S.eq(hold.selected_unit, P.target.unit_number, "рядом с LuaEntity в storage — её номер")
      S.eq(hold.mining_pos, { x = 21.5, y = 0.5 })
      S.eq(friend.character.position, { x = 20, y = 0 }, "тело не двигалось")
  end },

  { "цель добычи исчезла — удержание снимается без ошибок, действие видит пустые руки", function()
      P.setup()
      local A = P.action()
      P.target = S.nauvis.create_entity{ name = "tree-01", position = { x = 21.5, y = 0.5 }, force = "neutral" }
      P.act("p_once", { walk = false, mine = true })
      P.tick(20)
      P.target.destroy()
      local at = #A.seen
      P.tick(5)
      S.eq(all_seen(A, "mining", false, at + 1), true, "добыча не держится без цели")
      S.eq(all_seen(A, "selected", nil, at + 1), true)
      S.eq(P.rec().hold, nil)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },

  { "добыча плитки (без выбранной сущности) держится по позиции", function()
      P.setup()
      local A = P.action()
      P.act("p_once", { walk = false, tile = true })
      P.tick(31)
      S.ok(all_seen(A, "mining", true))
      S.ok(all_seen(A, "selected", nil))
      S.eq(A.seen[#A.seen].position, { x = 30.5, y = 1.5 })
      S.eq(P.rec().hold.selected_unit, false)
  end },

  { "ходьба и добыча вместе", function()
      local _, friend = P.setup()
      local A = P.action()
      P.target = S.nauvis.create_entity{ name = "tree-01", position = { x = 21.5, y = 0.5 }, force = "neutral" }
      P.act("p_once", { walk = true, mine = true })
      P.tick(31)
      S.ok(all_seen(A, "walking", true))
      S.ok(all_seen(A, "mining", true))
      S.ok(friend.character.position.x > 24)
  end },

  { "нет задачи — мод ввод игрока не трогает: человек за вторым клиентом ходит сам", function()
      local _, friend = P.setup()
      P.action()
      local h = friend.character
      P.client_input = function(p, ch)
        if p.name == "Second" then ch.walking_state = { walking = true, direction = SOUTH } end
      end
      P.tick(40)
      S.eq(P.rec().hold, nil)
      S.near(h.position.y, 0.15 * 40, 0.31, "игрок идёт на юг сам")
      S.eq(h.position.x, 20)
      -- и после задачи руки игроку возвращаются
      P.client_input = nil
      local job = P.act("p_once", {}).job
      P.tick(10)
      P.finish = true
      P.tick(1)
      S.eq(P.result(job).kind, "job_done")
      local y = h.position.y
      P.client_input = function(p, ch)
        if p.name == "Second" then ch.walking_state = { walking = true, direction = SOUTH } end
      end
      P.tick(20)
      S.near(h.position.y, y + 0.15 * 20, 0.31)
  end },

  { "удержание — одно место в ядре: хозяина и не привязанных игроков оно не касается", function()
      local owner = P.setup()
      P.action()
      P.act("p_once", {})
      P.tick(50)
      S.eq(owner.character.position, { x = 0, y = 0 })
      S.eq(owner.character.walking_state.walking, false)
  end },

  { "сохранение и загрузка: удержание лежит в storage и продолжается", function()
      local _, friend = P.setup()
      local A = P.action()
      P.act("p_once", {})
      P.tick(21)
      local x = friend.character.position.x
      P.reload()
      S.eq(P.rec().hold.walking, true)
      local at = #A.seen
      P.tick(20)
      S.ok(all_seen(A, "walking", true, at + 1), "после загрузки ходьба держится")
      S.near(friend.character.position.x, x + 0.15 * 20, 0.31)
  end },

  { "сбой внутри удержания не роняет очередь задач: module_errors растёт, остальные работают", function()
      P.setup{ attach = false }
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.okr(P.attach("p1", "Second"))
      P.action()
      P.act("p_once", {})
      local j = P.act("wait", { seconds = 1 }, "h1").job
      P.tick(5)
      local real = game.get_player
      game.get_player = function(x)
        if x == 2 then error("boom") end
        return real(x)
      end
      P.tick(80)
      game.get_player = real
      S.eq(P.result(j).kind, "job_done", "задача другого помощника дошла до конца")
      S.ok(S.okr(S.req("hello")).module_errors >= 1)
      S.eq(#S.logs, 1, "в журнал — не чаще раза в минуту: " .. table.concat(S.logs, "\n"))
      S.ok(not S.logs[1]:find("stubs", 1, true), "без путей в тексте")
      -- сбой прошёл — удержание возвращается
      P.tick(5)
      S.eq(P.rec().hold.walking, true)
  end },

  { "настоящее действие walk: тело-игрок доходит до цели под сбросами клиента", function()
      local _, friend = P.setup()
      local job = P.act("walk", { to = { x = 52, y = 0 } }).job
      local res = B.run(job, 1500)
      S.eq(res.kind, "job_done", S.dump(res))
      S.ok(S.dist(friend.character.position, { x = 52, y = 0 }) <= 1.05, "у цели: " .. S.dump(friend.character.position))
      S.ok(res.data.detail.walked >= 28, "walked=" .. tostring(res.data.detail.walked))
      P.tick(5)
      S.eq(P.rec().hold, nil)
      S.eq(friend.character.walking_state.walking, false)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "настоящее действие mine: тело-игрок копает руду под сбросами клиента", function()
      local W = C.setup()
      P.client = true
      P.client_input = nil
      P.install_client()
      S.okr(S.req("helper_limit", { max = 2 }))
      local friend = S.add_player{ name = "Second", position = { x = 4, y = 0 } }
      S.okr(P.attach("p1", "Second"))
      local h = C.equip(friend.character)
      local ore = C.resource("iron-ore", { x = 5.5, y = 0.5 }, 100)
      local job = S.okr(S.req("act", { ["do"] = "mine", args = { resource = "iron-ore", count = 3 } }, "p1")).job
      local d, kind = C.wait(job, 3000)
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail, { mined = { ["iron-ore"] = 3 } })
      S.eq(h.get_item_count("iron-ore"), 3)
      S.eq(ore.amount, 97)
      S.eq(W.h.get_item_count("iron-ore"), 0, "обычный помощник h1 ни при чём")
      C.run(3)
      S.eq(P.rec().hold, nil)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },
})
