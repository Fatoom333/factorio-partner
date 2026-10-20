-- «Иди ко мне» из узкого прохода: follow и модуль пути (ACTIONS.md `follow`, «Модуль пути»).
-- Мир: два ряда литейных 5×5 (по четыре), между ними проход в одну клетку (y от 0 до 1), хозяин —
-- за верхним рядом. Squeak Through: рамки построек меньше их клеток на 0.4, и тело, идущее к хозяину
-- напрямую, заходит центром на клетку литейной; оттуда «движок пути» маршрута не строит.
local S = require("stubs")
local B = require("stubs_b")

local X1, X2 = -10, 10            -- ряд литейных по x
local TOP = { y1 = -5, y2 = 0 }   -- верхний ряд: клетки y -5..0
local BOT = { y1 = 1, y2 = 6 }    -- нижний ряд: клетки y 1..6
local SQUEEZE = 0.4               -- на столько рамка меньше клеток
local BODY = 0.2
local OWNER = { x = 0.5, y = -6.5 }

local function in_box(p, r, x1, y1, x2, y2)
  return p.x + r > x1 and p.x - r < x2 and p.y + r > y1 and p.y - r < y2
end

--- Шаг тела упирается в рамку литейной (уменьшенную).
local function blocked(_, np)
  local s = SQUEEZE
  return in_box(np, BODY, X1 + s, TOP.y1 + s, X2 - s, TOP.y2 - s)
    or in_box(np, BODY, X1 + s, BOT.y1 + s, X2 - s, BOT.y2 - s)
end

--- Центр тела на клетке литейной.
local function on_foundry_tile(p)
  if p.x < X1 or p.x >= X2 then return false end
  local ty = math.floor(p.y)
  return (ty >= TOP.y1 and ty < TOP.y2) or (ty >= BOT.y1 and ty < BOT.y2)
end

--- «Движок пути»: с клетки литейной — нет пути; из прохода — вдоль прохода на восток и в обход.
local function pathfinder(params)
  local s, g = S.norm_pos(params.start), S.norm_pos(params.goal)
  if on_foundry_tile(s) then return {} end
  local wps = {}
  if s.x < X2 + 0.5 and s.y >= 0 and s.y < 1 then
    wps[#wps + 1] = { position = { x = X2 + 0.5, y = 0.5 } }
  end
  wps[#wps + 1] = { position = { x = X2 + 0.5, y = g.y } }
  wps[#wps + 1] = { position = { x = g.x, y = g.y } }
  return { path = wps }
end

--- find_non_colliding_position(…, force_to_tile_center): ближайший центр свободной клетки.
local function non_colliding(_, _, c, radius)
  local best, bd
  for dx = -3, 3 do
    for dy = -3, 3 do
      local p = { x = math.floor(c.x) + dx + 0.5, y = math.floor(c.y) + dy + 0.5 }
      local d = S.dist(p, c)
      if d <= radius and not on_foundry_tile(p) and not blocked(nil, p) and (bd == nil or d < bd) then
        best, bd = p, d
      end
    end
  end
  return best
end

local function world(opts)
  opts = opts or {}
  local p, h = B.setup()
  S.move(p.character, OWNER)
  S.move(h, { x = 0.5, y = 0.5 })
  B.blocked = blocked
  B.pathfinder = opts.pathfinder or pathfinder
  h.surface.non_colliding = opts.non_colliding or non_colliding
  return p, h
end

local function said()
  local out = {}
  for _, m in ipairs(game.printed) do out[#out + 1] = m end
  return table.concat(out, "\n")
end

S.suite("move_follow_corridor", {
  { "иди ко мне из прохода между литейными: выходит на свободную клетку, доходит по маршруту", function()
      local p, h = world()
      S.chat(1, "иди ко мне")
      local ok = pcall(B.until_, function() return S.dist(h.position, p.character.position) <= 3.05 end, 1500)
      S.ok(ok, "дошёл до хозяина; стоит в " .. S.dump(h.position) .. ", сказал: " .. said())
      local t = require("scripts.core.jobs").active("h1")
      S.ok(t ~= nil and t["do"] == "follow", "follow продолжается")
      S.eq(storage.owner_hold.h1.kind, "come")
  end },

  { "медленный «движок пути»: прямой ход не сбрасывает подход и не крутится по кругу", function()
      local seen = {}
      local slow = function(params, id)
        seen[id] = seen[id] or game.tick
        if game.tick - seen[id] < 400 then return nil end
        return pathfinder(params)
      end
      local p, h = world({ pathfinder = slow })
      local job = B.act("follow", { distance = 3, duration_s = 120 }).job
      local ok = pcall(B.until_, function() return S.dist(h.position, p.character.position) <= 3.05 end, 2500)
      S.ok(ok, "дошёл; стоит в " .. S.dump(h.position) .. ", запросов пути: " .. #B.all_requests())
      S.eq(B.result(job), nil, "ещё следует")
      S.ok(#B.all_requests() <= 6, "не перезапускал поиск по кругу: " .. #B.all_requests())
  end },

  { "пути нет нигде — follow кончается path_failed, хозяин слышит честный ответ", function()
      local _, h = world({ pathfinder = function() return {} end })
      S.chat(1, "иди ко мне")
      B.tick(2)
      local job = require("scripts.core.jobs").active("h1").job
      local res = B.run(job, 4000)
      S.eq(res.kind, "job_failed")
      S.ok(res.data.code == "path_failed" or res.data.code == "stuck", res.data.code)
      S.ok(said():find("Не могу пройти к тебе", 1, true) ~= nil, said())
      S.eq(h.walking_state.walking, false)
      S.eq(storage.owner_hold.h1.kind, "come", "hold остаётся")
  end },

  { "follow не от слова хозяина: при неудаче в чат не пишет", function()
      world({ pathfinder = function() return {} end })
      local before = #game.printed
      local job = B.act("follow", { distance = 3, duration_s = 120 }).job
      local res = B.run(job, 4000)
      S.eq(res.kind, "job_failed")
      S.eq(#game.printed, before)
  end },
})
