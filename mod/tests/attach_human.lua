-- Тело-игрок: ввод человека за вторым клиентом и удержание состояний.
-- PROTOCOL §7 «Удержание и ввод человека»: мод держит только то, что в этом тике
-- выставило АКТИВНОЕ ДЕЙСТВИЕ. Пока у помощника есть задача, ходьбой управляет только мод: ходьбу,
-- включённую не действием, он выключает и после тика НЕ возвращает (возврат делал её вечной — дрейф
-- и дребезг в живом прогоне 14.10). Задачи нет — мод тело не трогает, человек ходит сам.
-- «Клиент» — stubs_p.lua: перед on_tick сбрасывает состояния и применяет P.client_input.
local S = require("stubs")
local P = require("stubs_p")

local EAST, SOUTH = 4, 8
local STEP = 0.15 -- клеток за тик (stubs_b)

--- Человек за вторым клиентом держит клавишу ходьбы, пока keys.walk ~= nil; добычу — keys.mine.
local function human(keys)
  P.client_input = function(p, ch)
    if p.name ~= "Second" then return end
    if keys.walk ~= nil then ch.walking_state = { walking = true, direction = keys.walk } end
    if keys.mine ~= nil then ch.mining_state = { mining = true, position = { x = keys.mine.x, y = keys.mine.y } } end
  end
end

local function all_seen(A, field, want, from)
  for i = from or 1, #A.seen do
    if A.seen[i][field] ~= want then return false, i end
  end
  return true
end

S.suite("attach_human", {
  { "W во время wait: пока идёт задача, клавиша ходьбы человека не действует; hold не заводится", function()
      local _, friend = P.setup()
      local h = friend.character
      local job = P.act("wait", { seconds = 10 }).job
      P.tick(5)
      local keys = { walk = SOUTH }
      human(keys)
      P.tick(10)
      S.eq(P.rec().hold, nil, "wait ходьбой не управляет — запоминать нечего")
      S.eq(h.position.y, 0, "во время задачи тело от клавиши человека не идёт: " .. h.position.y)
      S.eq(h.walking_state.walking, false, "чужая ходьба выключена и не возвращена")
      keys.walk = nil
      P.tick(200)
      S.eq(h.position.y, 0, "клавишу отпустили — тело стоит, где стояло: " .. h.position.y)
      S.eq(h.position.x, 20)
      S.eq(h.walking_state.walking, false)
      S.eq(P.rec().hold, nil)
      -- задача при этом идёт своим чередом
      P.tick(500)
      S.eq(P.result(job).kind, "job_done")
      S.eq(S.okr(S.req("hello")).module_errors, 0)
      S.eq(#S.logs, 0, table.concat(S.logs, "\n"))
  end },

  { "одно короткое нажатие W во время wait — ни шага", function()
      local _, friend = P.setup()
      local h = friend.character
      P.act("wait", { seconds = 5 })
      P.tick(3)
      local keys = { walk = EAST }
      human(keys)
      P.tick(1)
      keys.walk = nil
      P.tick(120)
      S.eq(h.position.x, 20, "ни шага: " .. h.position.x)
      S.eq(P.rec().hold, nil)
  end },

  { "W во время mine: добыча держится, ходьба человека не действует и в hold не попадает", function()
      local _, friend = P.setup()
      local A = P.action()
      local h = friend.character
      P.target = S.nauvis.create_entity{ name = "tree-01", position = { x = 21.5, y = 0.5 }, force = "neutral" }
      P.act("p_once", { walk = false, mine = true })
      P.tick(10)
      S.eq(P.rec().hold.mining, true)
      S.eq(P.rec().hold.walking, false)
      local keys = { walk = SOUTH }
      human(keys)
      P.tick(8)
      S.eq(h.position.y, 0, "во время задачи человек тело не ведёт")
      local hold = P.rec().hold
      S.eq(hold.walking, false, "ходьбу выставило не действие — мод её не запомнил")
      S.eq(hold.direction, nil)
      S.eq(hold.mining, true, "добыча действия держится дальше")
      keys.walk = nil
      local at = #A.seen
      P.tick(100)
      S.eq(h.position.y, 0, "отпустил — стоит: " .. h.position.y)
      S.eq(h.position.x, 20)
      S.ok(all_seen(A, "mining", true), "добыча включена каждый тик, и до, и после нажатия")
      S.ok(all_seen(A, "selected", P.target))
      S.ok(all_seen(A, "walking", false), "действие ни разу не видело чужой ходьбы")
      S.ok(#A.seen > at)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "действие, которое ходьбу не трогает, ввода человека не видит; ходьба не возвращается, добыча — да", function()
      local _, friend = P.setup()
      local A = P.action()
      local h = friend.character
      P.act("p_once", { walk = false })
      human({ walk = SOUTH, mine = { x = 25.5, y = 0.5 } })
      P.tick(20)
      S.ok(#A.seen >= 18)
      S.ok(all_seen(A, "walking", false), "действие видит тело таким, каким оставило его само")
      S.ok(all_seen(A, "mining", false))
      S.eq(h.walking_state, { walking = false, direction = SOUTH }, "ходьба человека во время задачи не возвращается")
      S.eq(h.mining_state.mining, true, "добыча человека возвращена")
      S.eq(h.mining_state.position, { x = 25.5, y = 0.5 })
      S.eq(P.rec().hold, nil)
      S.eq(h.position.y, 0, "тело во время задачи человек не ведёт")
  end },

  { "человек и действие жмут одно и то же направление: ходьбу действия мод всё равно держит", function()
      local _, friend = P.setup()
      local A = P.action()
      local h = friend.character
      local keys = { walk = EAST }
      human(keys)
      P.tick(5) -- человек идёт на восток сам, задачи ещё нет
      S.eq(P.rec().hold, nil)
      P.act("p_once", {}) -- действие ОДИН раз включает ходьбу на восток
      P.tick(5)
      S.eq(P.rec().hold.walking, true, "ходьбу выставило действие, хоть она и совпала с вводом человека")
      S.eq(P.rec().hold.direction, EAST)
      keys.walk = nil
      local x = h.position.x
      P.tick(40)
      S.near(h.position.x, x + STEP * 40, 0.001, "клавишу отпустили — действие идёт дальше")
      S.ok(all_seen(A, "walking", true), "действие каждый тик видит свою ходьбу")
  end },

  { "человек жмёт против действия: ведёт действие; задача кончилась — руки снова у человека", function()
      local _, friend = P.setup()
      local A = P.action()
      local h = friend.character
      human({ walk = SOUTH })
      local job = P.act("p_once", {}).job
      P.tick(30)
      S.eq(h.position.y, 0, "на юг тело не ушло: ходьбой управляет действие")
      S.ok(h.position.x > 20 + STEP * 25, "идёт на восток: " .. h.position.x)
      S.eq(P.rec().hold.direction, EAST)
      S.ok(all_seen(A, "direction", EAST, 2))
      P.finish = true
      P.tick(1)
      S.eq(P.result(job).kind, "job_done")
      S.eq(P.rec().hold, nil)
      local x = h.position.x
      P.tick(20)
      S.near(h.position.x, x, 0.001, "ходьба задачи кончилась")
      S.ok(h.position.y >= STEP * 18, "человек идёт на юг сам: " .. h.position.y)
  end },

  { "действие выключило ходьбу — удержание снято, нажатие человека во время задачи тело не ведёт", function()
      local _, friend = P.setup()
      local A = P.action()
      local h = friend.character
      P.act("p_once", {})
      P.tick(10)
      S.eq(P.rec().hold.walking, true)
      -- действие останавливается само (как walk у цели), задача продолжается
      local real_tick = A.tick
      local stop_now = true
      A.tick = function(task, ctx)
        if stop_now then
          stop_now = false
          ctx.entity.walking_state = { walking = false, direction = EAST }
        end
        return real_tick(task, ctx)
      end
      P.tick(1)
      S.eq(P.rec().hold, nil, "держать больше нечего")
      local x = h.position.x
      local keys = { walk = EAST }
      human(keys)
      P.tick(3)
      keys.walk = nil
      P.tick(60)
      S.near(h.position.x, x, 0.001, "нажатия человека во время задачи не действуют: " .. (h.position.x - x))
      S.eq(P.rec().hold, nil)
  end },

  { "добыча человека во время wait не запоминается", function()
      local _, friend = P.setup()
      local h = friend.character
      P.act("wait", { seconds = 5 })
      P.tick(3)
      local keys = { mine = { x = 22.5, y = 0.5 } }
      human(keys)
      P.tick(10)
      S.eq(P.rec().hold, nil)
      S.eq(h.mining_state.mining, true, "человек копает сам")
      keys.mine = nil
      P.tick(5)
      S.eq(h.mining_state.mining, false, "отпустил кнопку — мод добычу не продолжил")
      S.eq(P.rec().hold, nil)
  end },

  { "задача кончилась, а действие оставило ходьбу включённой — без задачи мод тело не ведёт", function()
      local _, friend = P.setup()
      local h = friend.character
      local sloppy = { name = "p_sloppy", schema = {} }
      function sloppy.start(task, ctx)
        ctx.entity.walking_state = { walking = true, direction = EAST }
        return { status = "done", detail = {} }
      end
      function sloppy.tick() end
      function sloppy.stop() end
      require("scripts.core.jobs").register(sloppy)
      P.client = false -- как у движка без сброса: состояние держалось бы само
      local job = P.act("p_sloppy", {}).job
      P.tick(1)
      S.eq(P.result(job).kind, "job_done")
      S.eq(h.walking_state.walking, false, "ходьба завершённой задачи выключена")
      S.eq(P.rec().hold, nil)
      P.tick(30)
      S.eq(h.position, { x = 20, y = 0 }, "тело никуда не ушло")
  end },

  { "очередь: wait, потом ходьба — ввод человека в паузе на следующую задачу не переносится", function()
      local _, friend = P.setup()
      local A = P.action()
      local h = friend.character
      P.act("wait", { seconds = 1 })
      P.act("p_once", { walk = false })
      local keys = { walk = SOUTH }
      human(keys)
      P.tick(70) -- wait кончился, p_once (без ходьбы) начался
      S.ok(#A.seen > 0, "вторая задача идёт")
      keys.walk = nil
      local y = h.position.y
      P.tick(50)
      S.near(h.position.y, y, 0.001, "после отпускания клавиши тело стоит")
      S.eq(P.rec().hold, nil)
      S.ok(all_seen(A, "walking", false))
  end },

  { "сохранение и загрузка при нажатой клавише: рассинхронизации нет, hold пуст", function()
      local _, friend = P.setup()
      local h = friend.character
      P.act("wait", { seconds = 20 })
      local keys = { walk = SOUTH }
      human(keys)
      P.tick(10)
      P.reload()
      human(keys)
      P.tick(10)
      S.eq(P.rec().hold, nil)
      keys.walk = nil
      local y = h.position.y
      P.tick(40)
      S.near(h.position.y, y, 0.001)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "тело без игрока: подготовка и разбор его не касаются", function()
      P.setup{ attach = false }
      local A = P.action()
      S.okr(S.req("helper_spawn", {}, "h1"))
      local body = storage.helpers.h1.entity
      P.act("p_once", { walk = false }, "h1")
      body.walking_state = { walking = true, direction = SOUTH } -- как будто кто-то включил
      P.tick(10)
      S.eq(storage.helpers.h1.hold, nil)
      S.ok(all_seen(A, "walking", true), "у тела без игрока мод состояния не трогает")
  end },

  { "ходьба осталась включённой после конца задачи между тиками — мод выключает её один раз", function()
      local _, friend = P.setup()
      P.action()
      local h = friend.character
      P.client = false -- как у движка без сброса: состояние держится само
      local job = P.act("p_once", {}).job
      P.tick(10)
      S.eq(P.rec().hold.walking, true)
      S.eq(P.rec().walk_owned, true)
      -- задачу сняли между тиками, а тело осталось с включённой ходьбой
      S.okr(S.req("cancel", { job = job }, "p1"))
      h.walking_state = { walking = true, direction = EAST }
      local x = h.position.x
      P.tick(30)
      S.eq(h.walking_state.walking, false, "мод отпустил ходьбу, которую включал сам")
      S.ok(h.position.x <= x + STEP, "тело не уехало: " .. (h.position.x - x))
      S.eq(P.rec().walk_owned, nil)
  end },
})
