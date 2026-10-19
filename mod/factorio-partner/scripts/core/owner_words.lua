-- Слово хозяина: разбор сообщения хозяина в том же тике, без модели. Контракт: docs/EVENTS.md
-- «Слово хозяина».
--
-- Что распознаётся (сообщение целиком — данные, ничего из него не исполняется; сравниваются
-- только слова с таблицей ниже):
--   стоп      — слово из списка настройки `partner-stop-words`. «Стоп», «стой», «stop» — только если
--               все остальные слова сообщения из короткого списка хвостов M.STOP_TAILS («стоп», «стой
--               там», «stop it now»); «стоп, ставь печи» — не стоп, а обычное сообщение агенту.
--               Остальные слова списка — первое или последнее слово (не после «не») сообщения до
--               SHORT_MAX слов (слова-наполнители не считаются). Снять все задачи и ручной крафт,
--               включить hold, ответ «Стою.», громкое owner_stop{kind="stop"}.
--   подойти   — сообщение целиком равно фразе из `partner-come-phrases`: снять задачи и старый hold,
--               поставить follow к хозяину, hold, ответ «Иду.», owner_stop{kind="come"}; follow не
--               встал — честный ответ «Не могу подойти…», hold всё равно стоит.
--   статус    — «что делаешь», «чем занят», «что происходит», «статус»: мгновенный ответ шаблоном
--               из состояния мода, работа не прерывается.
--   продолжай — «продолжай», «continue» и т.п. при включённом hold: hold снимается, owner_resume.
-- Адрес: имя помощника в начале или конце сообщения («Claude2, стоп») — только он; без имени — все
-- живые помощники. Имя — как в подписи (nameplate.display_name): у h1 это «Claude», у остальных
-- «Claude h2»; принимаются «claude2», «claude h2», «claudeh2», «h2». Имя и сообщение приводятся к
-- словам одинаково (M.tokens): регистр, пробелы и знаки препинания («Mr. Bot») не важны.
-- Сообщения не хозяина сюда не попадают вовсе (вызывает events.on_console_chat только для хозяина).
--
-- hold: storage.owner_hold[id] = {kind="stop"|"come", tick, seq}. Пока он есть, `act` отвечает
-- owner_hold (jobs.op_act) запросам агента и рефлексам, кроме самого отступления flee; возврат к делу
-- после отступления не делается. Проверка для рефлексов — jobs.held(id) (здесь же M.held).
-- Снимается словом «продолжай» (сам мод) или операцией owner_hold{release=true, seq} с номером нового
-- сообщения хозяина, которое мод не разобрал как слово (правила — у M.op_owner_hold). Смерть помощника
-- hold не снимает: он переживает возрождение; сам hold снимается только у убранного помощника.
local util = require("scripts.core.util")
local err = require("scripts.core.err")
local schema = require("scripts.core.schema")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local jobs = require("scripts.core.jobs")
local nameplate = require("scripts.core.nameplate")
local ops = require("scripts.core.ops")
local bgcraft = require("scripts.core.bgcraft")

local M = {}
M.name = "owner_words"

M.SETTING_ENABLED = "partner-owner-words"
M.SETTING_STOP = "partner-stop-words"
M.SETTING_COME = "partner-come-phrases"
M.DEFAULT_STOP = "стоп,стой,остановись,отмена,stop"
M.DEFAULT_COME = "иди сюда,ко мне,иди ко мне,come,come here"
M.COME_DURATION_S = 600   -- follow после «иди сюда»
M.COME_DISTANCE = 3
M.STRONG_STOP = { ["стоп"] = true, ["стой"] = true, ["stop"] = true }
-- слова, которые могут стоять рядом с «стоп»/«стой»/«stop», не делая из сообщения поручение
-- (сравнение после M.tokens: нижний регистр, ё -> е)
M.STOP_TAILS = {
  ["все"] = true, ["там"] = true, ["тут"] = true, ["сейчас"] = true, ["быстро"] = true, ["быстрее"] = true,
  ["немедленно"] = true, ["срочно"] = true, ["пожалуйста"] = true, ["плиз"] = true, ["ну"] = true,
  ["же"] = true, ["эй"] = true, ["ладно"] = true, ["так"] = true, ["уже"] = true, ["ты"] = true,
  ["it"] = true, ["now"] = true, ["right"] = true, ["please"] = true, ["hey"] = true, ["ok"] = true,
  ["okay"] = true, ["there"] = true, ["all"] = true,
}
M.SHORT_MAX = 3           -- остальные стоп-слова: сообщение не длиннее стольких слов
M.CRAFT_CANCEL_MAX = 200  -- сколько раз за «стоп» снимать запись очереди ручного крафта
M.ADDRESS_SPAN = 4        -- имя помощника — не больше стольких слов подряд

local STATUS_PHRASES = {
  { "что", "делаешь" }, { "чем", "занят" }, { "чем", "занята" }, { "что", "происходит" },
  { "статус" }, { "status" }, { "what", "doing" }, { "what", "happening" },
}
local RESUME_PHRASES = {
  { "продолжай" }, { "продолжи" }, { "продолжай", "работу" }, { "продолжай", "работать" },
  { "работай" }, { "давай", "дальше" }, { "continue" }, { "resume" }, { "carry", "on" }, { "go", "on" },
}
-- слова-наполнители: выбрасываются перед точным сравнением со статусом, «подойти», «продолжай»
local FILLERS = {
  ["ты"] = true, ["сейчас"] = true, ["там"] = true, ["вообще"] = true, ["ну"] = true, ["а"] = true,
  ["же"] = true, ["эй"] = true, ["hey"] = true, ["пожалуйста"] = true, ["плиз"] = true,
  ["please"] = true, ["быстро"] = true, ["быстрее"] = true, ["скорее"] = true, ["are"] = true,
  ["you"] = true, ["is"] = true, ["the"] = true, ["now"] = true, ["right"] = true,
}
local NEGATIONS = {
  ["не"] = true, ["no"] = true, ["not"] = true, ["don"] = true, ["dont"] = true, ["don't"] = true,
  ["без"] = true, ["ни"] = true, ["нельзя"] = true, ["never"] = true,
}

-- ------------------------------------------------------------------ текст

--- Нижний регистр с русскими буквами (string.lower их не трогает), ё -> е.
function M.lower(s)
  s = s:lower()
  s = s:gsub("\208\129", "\209\145")                      -- Ё -> ё
  s = s:gsub("\208([\144-\159])", function(c) return "\208" .. string.char(c:byte() + 32) end)
  s = s:gsub("\208([\160-\175])", function(c) return "\209" .. string.char(c:byte() - 32) end)
  s = s:gsub("\209\145", "\208\181")                      -- ё -> е
  return s
end

--- Слова сообщения: rich-text теги и знаки препинания выброшены, дефис и апостроф внутри слова
--- остаются («стоп-кран» — одно слово и стоп-словом не считается).
function M.tokens(text)
  local s = M.lower(util.one_line(text or ""))
  s = s:gsub("%[[^%]]*%]", " ")
  for _, mark in ipairs({ "\226\128\148", "\226\128\147", "\226\128\166", "\194\171", "\194\187", "\226\128\156", "\226\128\157" }) do
    s = s:gsub(mark, " ")
  end
  s = s:gsub("[%s,%.!%?;:\"%(%)%[%]{}<>~%*/\\|=]", " ")
  local out = {}
  for w in s:gmatch("%S+") do
    w = w:gsub("^[%-']+", ""):gsub("[%-']+$", "")
    if w ~= "" then out[#out + 1] = w end
  end
  return out
end

local function phrases_from(setting, default)
  local s = settings and settings.global and settings.global[setting]
  local v = s and s.value
  if type(v) ~= "string" or v:match("^%s*$") then v = default end
  local out = {}
  for item in v:gmatch("[^,]+") do
    local t = M.tokens(item)
    if #t > 0 then out[#out + 1] = t end
  end
  return out
end

local function enabled()
  local s = settings and settings.global and settings.global[M.SETTING_ENABLED]
  return not (s and s.value == false)
end

local function without_fillers(tokens)
  local out = {}
  for _, w in ipairs(tokens) do
    if not FILLERS[w] then out[#out + 1] = w end
  end
  return out
end

local function equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function any_equal(tokens, list)
  for _, ph in ipairs(list) do
    if equal(tokens, ph) then return true end
  end
  return false
end

local function prefix_matches(tokens, ph)
  if #tokens < #ph then return false end
  for i = 1, #ph do if tokens[i] ~= ph[i] then return false end end
  return true
end

local function suffix_matches(tokens, ph)
  if #tokens < #ph then return false end
  local off = #tokens - #ph
  for i = 1, #ph do if tokens[off + i] ~= ph[i] then return false end end
  return true
end

-- ------------------------------------------------------------------ адрес

--- Имя, сжатое так же, как слова сообщения: слова M.tokens подряд без пробелов («Mr. Bot» -> «mrbot»).
function M.squash(name)
  return table.concat(M.tokens(name))
end

--- Сжатые имена помощника, которыми к нему можно обратиться.
local function aliases(id)
  local base = M.squash(nameplate.display_name("h1"))
  local n = id:match("^h(%d+)$")
  local out = { [id] = true }
  if id == "h1" and base ~= "" then out[base] = true end
  if n and base ~= "" then
    out[base .. n] = true
    out[base .. "h" .. n] = true
  end
  local own = M.squash(nameplate.display_name(id))
  if own ~= "" then out[own] = true end
  return out
end

--- Снять с начала и конца слов обращения к живым помощникам. Возвращает остаток слов и набор id
--- (пустой — имени не было).
local function strip_addresses(tokens, ids)
  local alias_of = {}
  for _, id in ipairs(ids) do
    for a in pairs(aliases(id)) do alias_of[a] = alias_of[a] or id end
  end
  local named = {}
  local function take(from_start)
    for k = math.min(M.ADDRESS_SPAN, #tokens - 1), 1, -1 do
      local parts = {}
      for i = 1, k do parts[i] = tokens[from_start and i or (#tokens - k + i)] end
      local id = alias_of[table.concat(parts)]
      if id ~= nil then
        named[id] = true
        local rest = {}
        for i = 1, #tokens do
          local inside = from_start and i <= k or (not from_start and i > #tokens - k)
          if not inside then rest[#rest + 1] = tokens[i] end
        end
        tokens = rest
        return true
      end
    end
    return false
  end
  while take(true) do end
  while take(false) do end
  return tokens, named
end

-- ------------------------------------------------------------------ разбор

--- Что за слово: "stop" | "come" | "status" | "resume" | nil. tokens — после снятия адреса.
function M.classify(tokens)
  if #tokens == 0 then return nil end
  local bare = without_fillers(tokens)
  if any_equal(bare, phrases_from(M.SETTING_COME, M.DEFAULT_COME)) then return "come" end
  if any_equal(bare, STATUS_PHRASES) then return "status" end
  if any_equal(bare, RESUME_PHRASES) then return "resume" end
  -- стоп — только без поручения рядом: «stop mining and build furnaces» — новое поручение агенту
  local stops = phrases_from(M.SETTING_STOP, M.DEFAULT_STOP)
  local strong = {}
  for _, ph in ipairs(stops) do
    if #ph == 1 and M.STRONG_STOP[ph[1]] then strong[ph[1]] = true end
  end
  local seen, other = false, false
  for _, w in ipairs(tokens) do
    if strong[w] then seen = true elseif not M.STOP_TAILS[w] then other = true end
  end
  if seen and not other then return "stop" end
  for _, ph in ipairs(stops) do
    if not (#ph == 1 and strong[ph[1]]) and #bare <= M.SHORT_MAX then
      if prefix_matches(tokens, ph) then return "stop" end
      if suffix_matches(tokens, ph) then
        local before = tokens[#tokens - #ph]
        if before == nil or not NEGATIONS[before] then return "stop" end
      end
    end
  end
  return nil
end

-- ------------------------------------------------------------------ hold

local function holds()
  storage.owner_hold = storage.owner_hold or {}
  return storage.owner_hold
end

function M.hold_of(id)
  return holds()[id]
end

--- Стоит ли hold у помощника (та же проверка, что jobs.held): для рефлексов, которые действуют сами.
function M.held(id)
  return jobs.held(id) ~= nil
end

local function set_hold(id, kind, seq)
  holds()[id] = { kind = kind, tick = game.tick, seq = seq }
end

-- ------------------------------------------------------------------ действия

local ACTION_RU = {
  walk = "иду", approach = "подхожу", follow = "иду рядом", mine = "добываю", craft = "кручу крафт",
  insert = "кладу в ящик", extract = "беру из ящика", collect = "собираю", pickup = "подбираю",
  place = "ставлю", rotate = "поворачиваю", set_recipe = "меняю рецепт", build_blueprint = "строю по чертежу",
  build_ghosts = "строю по призракам", deconstruct = "разбираю", plan_mining = "размечаю добычу",
  plan_belt = "прокладываю ленту", wait = "жду", get_items = "достаю предметы", plan = "выполняю план",
}

local function say(id, entity, text)
  pcall(ops.say, { text = text }, { helper_id = id, entity = entity })
end

--- Ответ на «что делаешь»: только чтение состояния мода.
function M.status_text(id)
  local hold = holds()[id]
  local t = jobs.active(id)
  local queued = jobs.queue_len(id)
  local parts = {}
  if t ~= nil then
    local s = ACTION_RU[t["do"]] or tostring(t["do"])
    local p = t.progress
    if t["do"] == "plan" and type(p) == "table" and type(p.step) == "number" and type(p.steps) == "number" then
      -- у плана — номер шага и что делает этот шаг
      s = s .. ", шаг " .. tostring(math.floor(p.step)) .. " из " .. tostring(math.floor(p.steps))
      if type(p["do"]) == "string" then s = s .. ": " .. (ACTION_RU[p["do"]] or p["do"]) end
    elseif type(p) == "table" and type(p.done) == "number" and type(p.total) == "number" then
      s = s .. " (" .. tostring(math.floor(p.done)) .. "/" .. tostring(math.floor(p.total)) .. ")"
    end
    parts[#parts + 1] = "Сейчас: " .. s .. "."
  elseif hold ~= nil then
    parts[#parts + 1] = "Стою по твоему слову."
  else
    parts[#parts + 1] = "Сейчас свободен."
  end
  if queued > 0 then parts[#parts + 1] = "В очереди ещё " .. queued .. "." end
  if hold ~= nil and t ~= nil then parts[#parts + 1] = "Новые задачи не беру, пока не скажешь продолжать." end
  return table.concat(parts, " ")
end

--- Снять весь ручной крафт, как actions/craft.lua: по одной записи с конца очереди, каждый раз
--- перечитывая её (отмена главного крафта сама снимает его промежуточные записи, индексы сдвигаются).
--- Промежуточные записи (prerequisite) напрямую не снимаются — берётся последняя запись без
--- prerequisite. Не больше CRAFT_CANCEL_MAX раз. Фоновые крафты помощника забываются без craft_done,
--- только если запись снята и очередь опустела; иначе bgcraft пришлёт craft_done как обычно.
local function cancel_crafting(id, e)
  local function queue()
    local ok, q = pcall(function() return e.crafting_queue end)
    if not ok or type(q) ~= "table" or #q == 0 then return nil end
    return q
  end
  local cancelled = 0
  for _ = 1, M.CRAFT_CANCEL_MAX do
    local q = queue()
    if q == nil then break end
    local pick = #q
    for i = #q, 1, -1 do
      if not q[i].prerequisite then pick = i break end
    end
    local item = q[pick]
    if not pcall(function() e.cancel_crafting{ index = item.index or pick, count = item.count } end) then break end
    cancelled = cancelled + 1
  end
  local ok, size = pcall(function() return e.crafting_queue_size or 0 end)
  if cancelled > 0 and ok and size <= 0 and queue() == nil then bgcraft.clear(id) end
end

local function drop_resume(id)
  local st = storage.reflex_state and storage.reflex_state[id]
  if type(st) == "table" then st.resume = nil end -- возврат после отступления больше не нужен
end

--- Стоп или «иди сюда». Возвращает nil или код ошибки, если follow к хозяину не встал.
local function do_stop(id, entity, kind, seq)
  jobs.fail_all(id, "cancelled", "stopped by owner", entity)
  cancel_crafting(id, entity)
  drop_resume(id)
  -- старый hold снимается до follow: новое слово хозяина заменяет прежнее, а hold закрыл бы и follow
  holds()[id] = nil
  local failed
  if kind == "come" then
    local ok, res = pcall(jobs.op_act,
      { ["do"] = "follow", args = { distance = M.COME_DISTANCE, duration_s = M.COME_DURATION_S } },
      { helper_id = id, request_id = "owner_words", entity = entity })
    if not ok then failed = (err.normalize(res)) end
  end
  set_hold(id, kind, seq)
  return failed
end

-- ------------------------------------------------------------------ вызов из чата

local function alive_ids()
  local out = {}
  for _, id in ipairs(registry.ids("alive")) do
    if registry.alive(id) then out[#out + 1] = id end
  end
  return out
end

--- Хук events.on_console_chat (только для сообщений хозяина). data — поля будущего player_said.
--- Возвращает (дополнительные поля player_said, after(seq)) или nil, если слова нет.
function M.on_owner_chat(data)
  if not enabled() then return nil end
  local ids = alive_ids()
  if #ids == 0 then return nil end
  local tokens, named = strip_addresses(M.tokens(data.text), ids)
  local kind = M.classify(tokens)
  if kind == nil then return nil end
  local targets = {}
  if next(named) ~= nil then
    for _, id in ipairs(ids) do if named[id] then targets[#targets + 1] = id end end
  else
    targets = ids
  end
  if kind == "resume" then
    local held = {}
    for _, id in ipairs(targets) do if holds()[id] ~= nil then held[#held + 1] = id end end
    targets = held
  end
  if #targets == 0 then return nil end
  local extra = { auto_reply = true, word = { kind = kind, helpers = targets } }
  local function after(seq)
    local done, follow_failed = {}, {}
    for _, id in ipairs(targets) do
      local _, entity = registry.alive(id)
      if entity ~= nil then
        done[#done + 1] = id
        if kind == "stop" or kind == "come" then
          local failed = do_stop(id, entity, kind, seq)
          if failed ~= nil then
            follow_failed[#follow_failed + 1] = id
            say(id, entity, "Не могу подойти (" .. failed .. "). Стою.")
          else
            say(id, entity, kind == "stop" and "Стою." or "Иду.")
          end
        elseif kind == "status" then
          say(id, entity, M.status_text(id))
        elseif kind == "resume" then
          holds()[id] = nil
          say(id, entity, "Продолжаю.")
        end
      end
    end
    if kind == "stop" or kind == "come" then
      events.emit(nil, "owner_stop",
        { kind = kind, seq = seq, helpers = done, follow_failed = follow_failed[1] ~= nil and follow_failed or nil },
        { loud = true })
    elseif kind == "resume" then
      events.emit(nil, "owner_resume", { seq = seq, helpers = done }, { loud = true })
    end
  end
  return extra, after
end
events.chat_hooks.owner_words = M.on_owner_chat

-- ------------------------------------------------------------------ операция owner_hold

local HOLD_SCHEMA = {
  release = { type = "bool", default = false },
  seq = { type = "int", min = 1 },
}

local function used()
  storage.owner_hold_used = storage.owner_hold_used or {}
  return storage.owner_hold_used
end

--- Кому сообщение хозяина адресовано по имени: набор id (пустой — без имени). Смотрятся все не
--- удалённые помощники, чтобы приказ мёртвому h2 не взял h1.
local function named_in(text)
  local ids = {}
  for _, id in ipairs(registry.ids()) do
    local rec = registry.get(id)
    if rec ~= nil and rec.state ~= "removed" then ids[#ids + 1] = id end
  end
  local _, named = strip_addresses(M.tokens(text), ids)
  return named
end

--- owner_hold{release?, seq?}: без release — какие hold стоят (helper необязателен: без него — у всех).
--- release=true снимает hold указанного помощника (helper обязателен) по новому сообщению хозяина.
--- seq должен быть номером player_said хозяина (owner:true), который
---   - новее hold;
---   - не разобран модом как слово (без auto_reply/word: «стоп», «что делаешь», «продолжай»);
---   - не адресован по имени другому помощнику;
---   - ещё не снимал hold у этого помощника (пара seq+помощник — одно снятие: сообщение без имени
---     снимает hold у каждого помощника по разу).
--- Поручение ли это сообщение — решает агент по своим правилам; мод проверяет только условия выше.
function M.op_owner_hold(args, ctx)
  local a = schema.validate(HOLD_SCHEMA, args)
  local all = holds()
  if not a.release then
    local ids = {}
    for id in pairs(all) do
      if ctx.helper_id == nil or ctx.helper_id == id then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local out = {}
    for _, id in ipairs(ids) do out[id] = util.plain(all[id]) end
    return { hold = out }
  end
  local id = ctx.helper_id
  if id == nil then err.raise("bad_args", "helper: release needs the helper whose hold is lifted") end
  if a.seq == nil then err.raise("bad_args", "args.seq: seq of the owner's player_said is required to release") end
  local hold = all[id]
  if hold == nil then return { released = {} } end
  local ev = events.query(a.seq - 1, nil, 1)[1]
  local d = ev ~= nil and ev.seq == a.seq and ev.kind == "player_said" and type(ev.data) == "table" and ev.data or nil
  if d == nil or d.owner ~= true then
    err.raise("bad_args", "args.seq: not a message of the owner (player_said, owner:true)")
  end
  if d.auto_reply ~= nil or d.word ~= nil then
    err.raise("bad_args", "args.seq: the mod already answered this word of the owner; it is not an order")
  end
  if a.seq <= (hold.seq or 0) then err.raise("bad_args", "args.seq: the message is older than the hold") end
  local named = named_in(d.text)
  if next(named) ~= nil and not named[id] then
    err.raise("bad_args", "args.seq: the owner addressed this message to another helper")
  end
  local u = used()
  if type(u[a.seq]) == "table" and u[a.seq][id] then
    err.raise("bad_args", "args.seq: this message of the owner already lifted this helper's hold")
  end
  if type(u[a.seq]) ~= "table" then u[a.seq] = {} end
  u[a.seq][id] = true
  all[id] = nil
  -- забываются только пары, чей seq меньше seq самого старого действующего hold: такой seq не новее
  -- ни одного действующего hold и ни одного будущего, так что снова снять им hold нельзя и без памяти
  local oldest
  for _, h in pairs(all) do
    local s = h.seq or 0
    if oldest == nil or s < oldest then oldest = s end
  end
  for s in pairs(u) do
    if oldest == nil or s < oldest then u[s] = nil end
  end
  return { released = { id } }
end

M.ops = { owner_hold = M.op_owner_hold }

-- Раз в секунду: hold убранного помощника снимается, чтобы его не получил новый помощник с тем же id.
-- Смерть hold не снимает: возрождённый помощник по-прежнему ждёт слова хозяина.
M.on_nth = {
  [60] = function()
    for id in pairs(holds()) do
      local rec = registry.get(id)
      if rec == nil or rec.state == "removed" then holds()[id] = nil end
    end
  end,
}

return M
