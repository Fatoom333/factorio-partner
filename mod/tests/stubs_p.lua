-- Заглушки тела-игрока (PROTOCOL §7 «Два вида тела»). Дополняют stubs.lua и
-- stubs_b.lua (ходьба по walking_state и «движок пути»).
--
--   local S = require("stubs"); local P = require("stubs_p")
--   local owner, friend = P.setup()      -- мод, хозяин Tartaluga в (0,0), второй игрок Second в
--                                        -- (20,0), помощник p1 привязан к Second (attach=false — нет)
--   P.tick(n)                            -- B.tick; перед on_tick «клиент» сбрасывает ввод игроков
--   local A = P.action()                 -- действие p_once: включает ходьбу/добычу ОДИН раз
--   P.leave(friend) / P.join(friend) / P.kill(friend) / P.respawn(friend)
--
-- «Клиент»: у персонажа подключённого игрока ввод клиента каждый тик сбрасывает walking_state,
-- mining_state и selected (у тела без игрока они держатся сами). Заглушка делает это прямо перед
-- обработчиком on_tick мода — так же, как игра применяет ввод до on_tick. P.client = false
-- выключает сброс; P.client_input = function(player, character) — «человек жмёт кнопки».
local S = require("stubs")
local B = require("stubs_b")

local P = {}

P.client = true
P.client_input = nil

local function reset_inputs()
  if not P.client then return end
  for _, p in ipairs(S._players_list) do
    local ch = rawget(p, "character")
    if p.connected and ch ~= nil and ch.valid then
      local ws = ch.walking_state
      ch.walking_state = { walking = false, direction = ws and ws.direction or defines.direction.north }
      ch.mining_state = { mining = false }
      rawset(ch, "selected", nil)
      if P.client_input then P.client_input(p, ch) end
    end
  end
end

--- Поставить «клиент» перед обработчиком on_tick мода (после каждой загрузки control.lua).
function P.install_client()
  local h = S.handlers[defines.events.on_tick]
  if h == nil then error("мод не подписан на on_tick", 2) end
  local orig = h.fn
  h.fn = function(e)
    reset_inputs()
    return orig(e)
  end
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

--- Мод + хозяин + второй игрок. opts.attach=false — не привязывать p1; opts.friend — опции
--- S.add_player второго игрока; opts.load — опции S.load_mod.
function P.setup(opts)
  opts = opts or {}
  P.client = true
  P.client_input = nil
  P.target = nil
  P.turn = nil
  P.finish = nil
  P._action = nil
  B.reset_world()
  S.load_mod(opts.load)
  install_extras()
  P.install_client()
  local owner = S.add_player{ name = "Tartaluga", position = { x = 0, y = 0 } }
  local fo = { name = "Second", position = { x = 20, y = 0 } }
  for k, v in pairs(opts.friend or {}) do fo[k] = v end
  local friend = S.add_player(fo)
  if opts.attach ~= false then S.okr(P.attach("p1", friend.name)) end
  return owner, friend
end

--- Сохранение и загрузка: storage остаётся, обработчики и действия ставятся заново.
function P.reload(opts)
  S.reload(opts)
  P.install_client()
  if P._action then require("scripts.core.jobs").register(P._action) end
end

function P.attach(id, player, extra)
  local args = { player = player }
  for k, v in pairs(extra or {}) do args[k] = v end
  return S.req("helper_attach", args, id)
end

function P.rec(id) return storage.helpers[id or "p1"] end

P.tick = B.tick
P.events = B.events

--- Виды событий по порядку (для сообщений об ошибках).
function P.kinds()
  local out = {}
  for _, e in ipairs(B.events()) do out[#out + 1] = e.kind end
  return table.concat(out, ",")
end

function P.act(d, args, helper, extra)
  local a = { ["do"] = d, args = args }
  for k, v in pairs(extra or {}) do a[k] = v end
  return S.okr(S.req("act", a, helper or "p1"))
end

--- Итог задачи job: событие job_done/job_failed или nil.
P.result = B.result

--- Действие p_once: в start ОДИН раз включает ходьбу на восток (args.walk, по умолчанию да)
--- и/или добычу P.target (args.mine) либо плитки (args.tile), дальше только смотрит.
---   A.seen[i] = что действие видело на i-м тике (после удержания ядра);
---   P.turn = направление — действие один раз сменит направление; P.finish = true — завершится.
function P.action()
  local A = { name = "p_once", seen = {}, stops = 0, stop_entity = nil }
  A.schema = {
    walk = { type = "bool", default = true },
    mine = { type = "bool", default = false },
    tile = { type = "bool", default = false },
  }
  function A.start(task, ctx)
    local e = ctx.entity
    if task.args.walk then e.walking_state = { walking = true, direction = defines.direction.east } end
    if task.args.mine then
      e.selected = P.target
      e.mining_state = { mining = true, position = { x = P.target.position.x, y = P.target.position.y } }
    elseif task.args.tile then
      e.mining_state = { mining = true, position = { x = 30.5, y = 1.5 } }
    end
    return nil
  end
  function A.tick(task, ctx)
    local e = ctx.entity
    local ws, ms = e.walking_state, e.mining_state
    A.seen[#A.seen + 1] = {
      walking = ws.walking, direction = ws.direction, mining = ms.mining, position = ms.position,
      selected = rawget(e, "selected"),
    }
    task.progress_tick = ctx.tick
    if P.turn ~= nil then
      e.walking_state = { walking = true, direction = P.turn }
      P.turn = nil
    end
    if P.finish then
      P.finish = nil
      e.walking_state = { walking = false, direction = ws.direction }
      e.mining_state = { mining = false }
      return { status = "done", detail = {} }
    end
    return nil
  end
  function A.stop(task, ctx)
    A.stops = A.stops + 1
    A.stop_entity = ctx.entity
    local e = ctx.entity
    if e ~= nil and e.valid then
      e.walking_state = { walking = false, direction = defines.direction.north }
      e.mining_state = { mining = false }
    end
  end
  require("scripts.core.jobs").register(A)
  P._action = A
  return A
end

-- ------------------------------------------------------------------ жизнь игрока

--- Игрок вышел из игры. У отключённого игрока `character` = nil; тело убирается с поверхности
--- (opts.destroy = true — сущность ещё и становится invalid, придёт on_object_destroyed).
--- opts.silent = true — без события on_player_left_game.
function P.leave(p, opts)
  opts = opts or {}
  local ch = rawget(p, "character")
  p.connected = false
  if ch ~= nil then
    p.character = nil
    if ch.valid then
      ch.surface._remove(ch)
      if opts.destroy then S.invalidate(ch) else p._stash = ch end
    end
  end
  if not opts.silent then
    S.fire(defines.events.on_player_left_game, { player_index = p.index, reason = 0 })
  end
end

--- Игрок вернулся: прежнее тело (или новое, если его не сохранили). opts.character = false —
--- вернулся без тела (ждёт возрождения); opts.silent = true — без события.
function P.join(p, opts)
  opts = opts or {}
  p.connected = true
  if opts.character ~= false then
    local ch = p._stash
    p._stash = nil
    if ch ~= nil and ch.valid then
      local list = ch.surface._entities
      list[#list + 1] = ch
    else
      ch = p.surface.create_entity{ name = "character", position = p.position, force = p.force }
      ch.player = p
    end
    p.character = ch
  end
  if not opts.silent then
    S.fire(defines.events.on_player_joined_game, { player_index = p.index })
  end
  return rawget(p, "character")
end

--- Персонаж игрока погиб (движок: on_entity_died, труп, у игрока больше нет тела).
function P.kill(p)
  local ch = p.character
  p.position = S.norm_pos(ch.position)
  ch.die()
  p.character = nil
  S.fire(defines.events.on_player_died, { player_index = p.index })
end

--- Движок возродил игрока: новое тело с пустым инвентарём. opts.silent — без события.
function P.respawn(p, pos, opts)
  opts = opts or {}
  local ch = p.surface.create_entity{ name = "character", position = pos or { x = 0, y = 5 }, force = p.force }
  ch.player = p
  p.character = ch
  if not opts.silent then
    S.fire(defines.events.on_player_respawned, { player_index = p.index })
  end
  return ch
end

--- Сколько раз мод создал сущность name (по журналу create_entity поверхности).
function P.created(name, surface)
  local n = 0
  for _, params in ipairs((surface or S.nauvis).created or {}) do
    if params.name == name then n = n + 1 end
  end
  return n
end

return P
