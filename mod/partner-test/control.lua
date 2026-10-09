-- Тестовый мод стенда factorio-partner (поток E). Только для копии сейва на тестовом сервере.
--
-- Регистрирует команду /partner с конвертом протокола (docs/PROTOCOL.md §1–2), но ТОЛЬКО если
-- настоящий мод factorio-partner не включён: тогда /partner принадлежит ему. Операции — тестовые,
-- с префиксом e_ (замеры стенда), плюс урезанный hello, чтобы сценарий понял, с каким модом говорит.
--
-- Правила те же, что у настоящего мода: ответ — одна строка JSON в rcon.print; из чата игрока
-- команда отклоняется; никакого произвольного Lua; без телепорта; без предметов из воздуха.
-- Проверка обзора (e_chart) идёт на СИЛЕ ИГРОКА и на далёком сгенерированном, но не открытом
-- чанке: живой замер 08.10 показал, что force.chart без игроков онлайн работает для силы игрока,
-- но не для силы из create_force. Тело не создаётся: сущностей в мире тест не оставляет.

local PROTO = 1
local MOD_NAME = "partner-test"
local DEFAULT_RADIUS = 64
local MAX_RADIUS = 256
local WINDOW = 2 -- окно (2*WINDOW+1)^2 чанков вокруг проверяемого чанка для подсчёта открытых
local FIND_MIN, FIND_MAX = 8, 64 -- искать чанк на таком расстоянии (в чанках) от игрока 1
local MAX_ERROR_BYTES = 200 -- текст ошибки internal, байт UTF-8
local MAX_BIG = 199000 -- e_big: строка в ответе, чтобы весь ответ был ≤ 200 000 байт (PROTOCOL §2)

local M = {}

local function round1(v)
  return math.floor(v * 10 + 0.5) / 10
end

local function pos_of(p)
  return { x = round1(p.x), y = round1(p.y) }
end

local function chunk_of(p)
  return { x = math.floor(p.x / 32), y = math.floor(p.y / 32) }
end

local function fail(code, text)
  error({ partner_code = code, text = text }, 0)
end

-- Текст ошибки: без путей и управляющих символов, не длиннее MAX_ERROR_BYTES байт. Режем только
-- по границе символа UTF-8 (PROTOCOL §3: «не резать UTF-8 посреди символа»), кириллицу сохраняем.
local function clean_error(text)
  text = tostring(text):gsub("^.-:%d+: ", ""):gsub("[\0-\31\127]", " ") -- не %c: в части сборок он ловит байты ≥128
  if #text > MAX_ERROR_BYTES then
    local cut = MAX_ERROR_BYTES
    -- следующий байт — продолжение символа (10xxxxxx)? отступаем к началу этого символа
    while cut > 0 do
      local b = text:byte(cut + 1)
      if b < 128 or b >= 192 then break end
      cut = cut - 1
    end
    text = text:sub(1, cut)
  end
  return text
end

-- ---------- операции ----------
local ops = {}

function ops.hello(args, cmd)
  local players = {}
  for _, p in pairs(game.players) do
    local entry = { index = p.index, name = p.name, online = p.connected }
    -- PROTOCOL §4: тело игрока (physical_*), а не камера удалённого вида.
    local surface = p.physical_surface
    if surface and surface.valid then
      entry.surface = surface.name
      entry.pos = pos_of(p.physical_position)
    end
    players[#players + 1] = entry
  end
  return {
    proto = PROTO,
    mod = MOD_NAME .. " " .. (script.active_mods[MOD_NAME] or "?"),
    tick = game.tick,
    seq = 0,
    owner = game.players[1] and game.players[1].name or "",
    players = players,
    helpers = {},
    players_online = #game.connected_players,
  }
end

-- Замер длины команды: вернуть длину параметра, которую увидел мод.
function ops.e_echo(args, cmd)
  if type(args.pad) ~= "string" then fail("bad_args", "pad: нужна строка") end
  return { len = #cmd.parameter, pad = #args.pad }
end

-- Большой ответ: проверка, что RCON отдаёт его одним пакетом (клиент стенда собирает ответ из одного).
function ops.e_big(args, cmd)
  local n = args.bytes
  if type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > MAX_BIG then
    fail("bad_args", "bytes: 1.." .. MAX_BIG)
  end
  return { bytes = n, pad = string.rep("x", n) }
end

local function charted_window(force, surface, center)
  local n, total = 0, 0
  for dx = -WINDOW, WINDOW do
    for dy = -WINDOW, WINDOW do
      total = total + 1
      if force.is_chunk_charted(surface, { center.x + dx, center.y + dy }) then n = n + 1 end
    end
  end
  return n, total
end

local function valid_chunk(ch)
  return type(ch) == "table" and type(ch.x) == "number" and type(ch.y) == "number"
    and ch.x == math.floor(ch.x) and ch.y == math.floor(ch.y)
end

-- Обзор силы игрока без игроков онлайн (PROTOCOL §6.8). Одна операция, три режима:
--   find  — ближайший сгенерированный, но не открытый силой игрока чанк (FIND_MIN..FIND_MAX чанков
--           от игрока 1 по четырём осям);
--   chart — force.chart вокруг центра чанка на radius тайлов (как будет делать обзор помощника);
--   check — открыт ли чанк и сколько открыто в окне вокруг него.
-- Поверхность — тело игрока 1 (physical_*), а не камера удалённого вида (PROTOCOL §4).
function ops.e_chart(args, cmd)
  local anchor = game.players[1]
  if not anchor then fail("no_player", "в сейве нет игроков") end
  local surface = anchor.physical_surface
  if not (surface and surface.valid) then fail("no_player", "у игрока 1 нет поверхности") end
  local force = game.forces["player"]
  if not force then fail("no_player", "нет силы player") end
  local mode = args.mode
  if mode == "find" then
    local c0 = chunk_of(anchor.physical_position)
    for d = FIND_MIN, FIND_MAX do
      for _, v in ipairs({ { d, 0 }, { -d, 0 }, { 0, d }, { 0, -d } }) do
        local ch = { x = c0.x + v[1], y = c0.y + v[2] }
        if surface.is_chunk_generated(ch) and not force.is_chunk_charted(surface, ch) then
          return { chunk = ch, dist = d, surface = surface.name, force = force.name,
            players_online = #game.connected_players, tick = game.tick }
        end
      end
    end
    fail("not_found", "нет сгенерированного неоткрытого чанка")
  end
  if mode ~= "chart" and mode ~= "check" then fail("bad_args", "mode: find|chart|check") end
  local ch = args.chunk
  if not valid_chunk(ch) then fail("bad_args", "chunk: {x,y} целые") end
  if mode == "chart" then
    local radius = args.radius
    if radius == nil then radius = DEFAULT_RADIUS end
    if type(radius) ~= "number" or radius < 1 or radius > MAX_RADIUS then
      fail("bad_args", "radius: 1.." .. MAX_RADIUS)
    end
    local cx, cy = ch.x * 32 + 16, ch.y * 32 + 16
    force.chart(surface, { { cx - radius, cy - radius }, { cx + radius, cy + radius } })
    -- Чартинг в игре асинхронный: открытие применяется через несколько тиков, поэтому поле charted
    -- в ответе chart почти всегда false. Это не баг: сценарий e_chart дожидается результата опросом
    -- режима check.
  end
  local n, total = charted_window(force, surface, ch)
  return { force = force.name, chunk = ch, charted = force.is_chunk_charted(surface, ch),
    window_charted = n, window = total, tick = game.tick, players_online = #game.connected_players }
end

-- ---------- конверт ----------
local ID_PATTERN = "^[A-Za-z0-9_.:%-]+$"

local function respond(id, ok, payload)
  local r = { v = PROTO, ok = ok, tick = game.tick, seq = 0 }
  if id ~= nil then r.id = id end
  if ok then r.data = payload else r.error = payload end
  rcon.print(helpers.table_to_json(r))
end

function M.handle(cmd)
  if cmd.player_index then
    local p = game.get_player(cmd.player_index)
    if p then p.print("[partner] только для RCON") end
    return
  end
  local param = cmd.parameter
  if type(param) ~= "string" or param == "" then
    return respond(nil, false, { code = "bad_request", text = "пустой запрос" })
  end
  local req = helpers.json_to_table(param)
  if type(req) ~= "table" then
    return respond(nil, false, { code = "bad_request", text = "не JSON" })
  end
  local id = req.id
  if type(id) ~= "string" or #id < 1 or #id > 40 or not id:match(ID_PATTERN) then
    return respond(nil, false, { code = "bad_request", text = "id" })
  end
  if type(req.v) ~= "number" then
    return respond(id, false, { code = "bad_request", text = "v" })
  end
  if req.v ~= PROTO then
    return respond(id, false, { code = "version_mismatch", text = "proto " .. PROTO })
  end
  if type(req.op) ~= "string" then
    return respond(id, false, { code = "bad_request", text = "op" })
  end
  local args = req.args
  if args == nil then args = {} end
  if type(args) ~= "table" then
    return respond(id, false, { code = "bad_request", text = "args" })
  end
  local fn = ops[req.op]
  if not fn then
    return respond(id, false, { code = "unknown_op", text = req.op })
  end
  local ok, res = pcall(fn, args, cmd)
  if ok then
    return respond(id, true, res or {})
  end
  if type(res) == "table" and res.partner_code then
    return respond(id, false, { code = res.partner_code, text = res.text })
  end
  return respond(id, false, { code = "internal", text = clean_error(res) })
end

-- ---------- регистрация ----------
-- Разовая чистка остатков версии 0.2.1 (тело и сила fp-e-chart) в сейве, пересохранённом старым
-- модом. Слотовые копии сейва на стенде одноразовые, но чистка делает переиспользование безопасным.
local LEGACY_FORCE = "fp-e-chart"
local function cleanup_legacy()
  local e = storage and storage.e
  if type(e) == "table" and e.body and e.body.valid then e.body.destroy() end
  if storage then storage.e = nil end
  local f = game.forces[LEGACY_FORCE]
  if f and game.forces["player"] then game.merge_forces(f, game.forces["player"]) end
end
M.cleanup_legacy = cleanup_legacy

M.ops = ops
M.clean_error = clean_error

if script and commands then
  script.on_configuration_changed(cleanup_legacy)
  -- /partner принадлежит настоящему моду, если он включён.
  if not script.active_mods["factorio-partner"] then
    commands.add_command("partner", "Тестовый /partner стенда (только RCON).", M.handle)
  end
  commands.add_command("partner-ping", "Проверка связи: ответить pong и тиком.", function(cmd)
    local text = "pong tick=" .. game.tick .. " players_online=" .. #game.connected_players
    if cmd.player_index then
      local p = game.get_player(cmd.player_index)
      if p then p.print("[partner] " .. text) end
    else
      rcon.print(text)
    end
  end)
end

return M
