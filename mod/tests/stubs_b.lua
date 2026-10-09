-- Заглушки потока B (движение). Дополняют mod/tests/stubs.lua потока A (TESTING.md §1).
--
--   local S = require("stubs"); local B = require("stubs_b")
--   local p, h = B.setup()          -- мод, хозяин Tartaluga в (0,0), помощник h1 в (2,0)
--   B.tick(n)                       -- S.tick + движение персонажей по walking_state + «движок пути»
--   B.pathfinder = function(params) -> {path=...} | {try_again_later=true} | {} (нет пути) | nil (не отвечать)
--   B.blocked = function(entity, new_pos) -> true (шаг не делается)
--   B.answer(id, resp)              -- ответить на запрос пути вручную
--
-- Ходьба: за тик персонаж сдвигается на character_running_speed в направлении walking_state
-- (диагональ — speed/√2 по каждой оси, как в игре). Ответ на запрос пути приходит в конце того
-- же тика (on_script_path_request_finished), path.step забирает его на следующем.
local S = require("stubs")

local B = {}

local SQ = math.sqrt(0.5)

--- Вектор шага для defines.direction (16 направлений, ходьба — только чётные).
function B.dir_vector(d)
  local v = {
    [0] = { 0, -1 }, [2] = { SQ, -SQ }, [4] = { 1, 0 }, [6] = { SQ, SQ },
    [8] = { 0, 1 }, [10] = { -SQ, SQ }, [12] = { -1, 0 }, [14] = { -SQ, -SQ },
  }
  local x = v[d]
  if x == nil then error("ходьба только по 8 направлениям, получено " .. tostring(d), 2) end
  return x[1], x[2]
end

--- Прямой маршрут от start к goal с шагом 1, до радиуса radius от цели.
function B.straight_path(params)
  local s, g = S.norm_pos(params.start), S.norm_pos(params.goal)
  local r = params.radius or 1
  local dx, dy = g.x - s.x, g.y - s.y
  local len = math.sqrt(dx * dx + dy * dy)
  local path = { { position = { x = s.x, y = s.y }, needs_destroy_to_reach = false } }
  if len <= r then return { path = path } end
  local n = math.ceil(len - r)
  for k = 1, n do
    local t = math.min(k, len - r) / len
    path[#path + 1] = { position = { x = s.x + dx * t, y = s.y + dy * t }, needs_destroy_to_reach = false }
  end
  return { path = path }
end

function B.reset_world()
  B.pathfinder = B.straight_path
  B.blocked = nil
  B.answered = {}
  B.requests = {} -- id -> {surface, params}
  B.moves = 0
end

--- Ответить на запрос пути id ответом resp ({path=}|{try_again_later=true}|{}).
function B.answer(id, resp)
  B.answered[id] = true
  local data = { id = id, try_again_later = resp.try_again_later or false }
  if resp.path then data.path = resp.path end
  S.fire(defines.events.on_script_path_request_finished, data)
end

--- Все запросы пути по порядку: { {id, surface, params}, ... }.
function B.all_requests()
  local out = {}
  for _, s in ipairs(S._surfaces_list) do
    for id, params in pairs(s.path_requests or {}) do out[#out + 1] = { id = id, surface = s, params = params } end
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

function B.last_request()
  local all = B.all_requests()
  return all[#all]
end

local function answer_pending()
  if B.pathfinder == nil then return end
  for _, r in ipairs(B.all_requests()) do
    if not B.answered[r.id] then
      local resp = B.pathfinder(r.params, r.id)
      if resp ~= nil then B.answer(r.id, resp) end
    end
  end
end

local function move_characters()
  for _, s in ipairs(S._surfaces_list) do
    for _, e in ipairs(s._entities) do
      local ws = rawget(e, "walking_state")
      if e.valid and e.type == "character" and ws and ws.walking then
        local vx, vy = B.dir_vector(ws.direction)
        local sp = e.character_running_speed or 0.15
        local np = { x = e.position.x + vx * sp, y = e.position.y + vy * sp }
        if not (B.blocked and B.blocked(e, np)) then
          e.position = np
          B.moves = B.moves + 1
        end
      end
    end
  end
end

--- n тиков: скрипт (on_tick и т.д.), затем движение и ответы «движка пути».
function B.tick(n)
  for _ = 1, (n or 1) do
    S.tick(1)
    move_characters()
    answer_pending()
  end
end

--- Тикать, пока fn() не вернёт истину (не больше max тиков). Возвращает число тиков.
function B.until_(fn, max)
  for i = 1, max or 3000 do
    if fn() then return i - 1 end
    B.tick(1)
  end
  if fn() then return max end
  error("условие не наступило за " .. tostring(max or 3000) .. " тиков", 2)
end

local function install_extras()
  prototypes.entity.character.collision_mask = { layers = { player = true, train = true, is_object = true } }
  game.get_entity_by_unit_number = function(n)
    for _, s in ipairs(S._surfaces_list) do
      for _, e in ipairs(s._entities) do
        if e.valid and e.unit_number == n then return e end
      end
    end
    return nil
  end
end

--- Мод + хозяин + помощник h1. opts.load — опции S.load_mod; opts.owner — опции S.add_player.
function B.setup(opts)
  opts = opts or {}
  B.reset_world()
  S.load_mod(opts.load)
  install_extras()
  local po = { name = "Tartaluga" }
  for k, v in pairs(opts.owner or {}) do po[k] = v end
  local p = S.add_player(po)
  S.okr(S.req("helper_spawn", {}, "h1"))
  local h = storage.helpers.h1.entity
  return p, h
end

--- Поставить задачу помощнику h1.
function B.act(d, args, extra)
  local a = { ["do"] = d, args = args }
  for k, v in pairs(extra or {}) do a[k] = v end
  return S.okr(S.req("act", a, "h1"))
end

function B.events(kind)
  local evs = S.okr(S.req("events", { since = 0, limit = 200 })).events
  if kind == nil then return evs end
  local out = {}
  for _, e in ipairs(evs) do if e.kind == kind then out[#out + 1] = e end end
  return out
end

--- Итог задачи job: событие job_done/job_failed или nil.
function B.result(job)
  for _, e in ipairs(B.events()) do
    if (e.kind == "job_done" or e.kind == "job_failed") and e.data.job == job then return e end
  end
  return nil
end

--- Тикать до итога задачи job (не больше max тиков).
function B.run(job, max)
  local res
  B.until_(function() res = B.result(job) return res ~= nil end, max or 5000)
  return res
end

function B.chunk_key(surface, x, y)
  return S.chunk_key(surface, { x = math.floor(x / 32), y = math.floor(y / 32) })
end

function B.count(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

return B
