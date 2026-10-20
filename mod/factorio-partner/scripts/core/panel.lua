-- Панель хозяина: окно в игре с кнопками для всех помощников. Контракт: docs/EVENTS.md
-- «owner_panel».
--
-- Открывается ярлыком `partner-panel` (панель быстрых кнопок) или горячей клавишей
-- `partner-toggle-panel`; закрывается крестиком и повторным нажатием. Состояние окна —
-- storage.panel[player_index] = {open, n, thoughts, auto, goal}; сами элементы окна всегда
-- ищутся в `player.gui.screen` по имени, в storage их нет.
--
-- В окне: строка на каждое тело (имя и что делает — owner_words.status_text); «Помощников: N» и
-- «Применить» (событие scale); «Все стоп» и «Продолжайте» (то же, что слово хозяина для всех тел:
-- owner_words) и события hold/resume; флажки «Мысли стратега» (thoughts), «AUTO» с полем цели
-- (auto), «Боевой режим» (combat: мод сам включает всем телам рефлексы shoot и ammo; запрет
-- `deny` в настройках мода уважается — такой рефлекс не включается, окно пишет почему).
--
-- Событие owner_panel (без помощника, громкое) шлётся только от хозяина: чужое нажатие, даже
-- если оно дошло до обработчика, игнорируется, а чужой игрок видит окно «только для хозяина».
local util = require("scripts.core.util")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local owner = require("scripts.core.owner")
local owner_words = require("scripts.core.owner_words")
local nameplate = require("scripts.core.nameplate")
local reflexes = require("scripts.core.reflexes")
local perms = require("scripts.core.perms")

local M = {}
M.name = "core.panel"

M.SHORTCUT = "partner-panel"
M.INPUT = "partner-toggle-panel"
M.WINDOW = "partner_panel"
M.MIN_HELPERS = 1
M.MAX_HELPERS = 5
M.GOAL_MAX = 200        -- длина цели AUTO в символах
M.STATUS_WIDTH = 360

-- рефлексы боевого режима -> ключ разрешения из настроек мода (perms.get)
M.COMBAT = { { type = "shoot", perm = "perm-shoot" }, { type = "ammo", perm = "perm-turrets" } }

-- ------------------------------------------------------------------ состояние

local function all_state()
  if type(storage.panel) ~= "table" then storage.panel = {} end
  return storage.panel
end

local function state_of(index)
  local all = all_state()
  local st = all[index]
  if type(st) ~= "table" then
    st = { open = false, n = nil, thoughts = false, auto = false, goal = "" }
    all[index] = st
  end
  return st
end

local function clamp_n(n)
  n = math.floor(tonumber(n) or M.MIN_HELPERS)
  if n < M.MIN_HELPERS then return M.MIN_HELPERS end
  if n > M.MAX_HELPERS then return M.MAX_HELPERS end
  return n
end

--- Все не удалённые помощники (для строк окна).
local function listed_ids()
  local out = {}
  for _, id in ipairs(registry.ids()) do
    local rec = registry.get(id)
    if rec ~= nil and rec.state ~= "removed" then out[#out + 1] = id end
  end
  return out
end

local function alive_ids()
  local out = {}
  for _, id in ipairs(registry.ids("alive")) do
    if registry.alive(id) then out[#out + 1] = id end
  end
  return out
end

local function emit(data)
  events.emit(nil, "owner_panel", data, { loud = true })
end

-- ------------------------------------------------------------------ боевой режим

local function has_reflex(set, type_)
  for _, r in ipairs(set or {}) do
    if r.type == type_ then return true end
  end
  return false
end

--- Типы рефлексов боевого режима, не запрещённые в настройках мода (perm = deny), и запрещённые.
local function combat_types()
  local allowed, denied = {}, {}
  for _, c in ipairs(M.COMBAT) do
    if perms.get(c.perm) == "deny" then denied[#denied + 1] = c.type else allowed[#allowed + 1] = c.type end
  end
  return allowed, denied
end

--- Боевой режим включён: у каждого живого помощника стоят все незапрещённые рефлексы боя.
local function combat_is_on()
  local ids = alive_ids()
  local allowed = combat_types()
  if #ids == 0 or #allowed == 0 then return false end
  for _, id in ipairs(ids) do
    local set = reflexes.get(id)
    for _, t in ipairs(allowed) do
      if not has_reflex(set, t) then return false end
    end
  end
  return true
end

--- Включить или выключить shoot и ammo всем живым телам; остальные рефлексы тела не трогаются,
--- параметры уже стоящих shoot/ammo сохраняются. Запрещённый (deny) рефлекс не включается.
--- Возвращает список запрещённых типов и число тел, у которых набор не удалось изменить.
local function set_combat(on)
  local allowed, denied = combat_types()
  local want = {}
  for _, t in ipairs(allowed) do want[t] = true end
  local failed = 0
  for _, id in ipairs(alive_ids()) do
    local set, present = {}, {}
    for _, r in ipairs(reflexes.get(id) or {}) do
      local is_combat = false
      for _, c in ipairs(M.COMBAT) do if c.type == r.type then is_combat = true end end
      if not is_combat or (on and want[r.type]) then
        set[#set + 1] = reflexes.public({ r })[1] -- только поля схемы: служебные отвергла бы проверка
        present[r.type] = true
      end
    end
    if on then
      for _, t in ipairs(allowed) do
        if not present[t] then set[#set + 1] = { type = t } end
      end
    end
    if not pcall(reflexes.op_reflexes, { set = set }, { helper_id = id }) then failed = failed + 1 end
  end
  return on and denied or {}, failed
end

-- ------------------------------------------------------------------ слова хозяина всем телам

--- Слово хозяина «стоп» / «продолжай» для всех тел: тем же путём, что сообщение в чате
--- (owner_words.on_owner_chat), без дублирования логики hold. Возвращает true, если слово применено.
local function apply_word(text)
  local fn = owner_words.apply_word
  if type(fn) == "function" then return fn(text) ~= nil end
  local extra, after = owner_words.on_owner_chat({ text = text })
  if after == nil then return false end
  after(events.last_seq())
  return extra ~= nil
end

-- ------------------------------------------------------------------ окно

local function screen_of(p)
  local ok, s = pcall(function() return p.gui.screen end)
  return ok and s or nil
end

local function window_of(p)
  local s = screen_of(p)
  if s == nil then return nil end
  local w = s[M.WINDOW]
  if w ~= nil and w.valid then return w end
  return nil
end

--- Элемент окна по имени (поиск по всем вложенным).
local function find(parent, name)
  for _, ch in ipairs(parent.children or {}) do
    if ch.name == name then return ch end
    local r = find(ch, name)
    if r then return r end
  end
  return nil
end

local function set_toggled(p, on)
  pcall(function() p.set_shortcut_toggled(M.SHORTCUT, on and true or false) end)
end

local function destroy_window(p)
  local w = window_of(p)
  if w ~= nil then w.destroy() end
end

local function helper_row_text(id)
  if registry.alive(id) then return owner_words.status_text(id) end
  return "Не в игре (ждёт возрождения)."
end

local function ids_key(ids)
  return table.concat(ids, ",")
end

local function title_bar(w)
  local bar = w.add{ type = "flow", name = "bar", direction = "horizontal" }
  bar.drag_target = w
  bar.style.horizontal_spacing = 8
  local t = bar.add{ type = "label", caption = { "partner-panel.title" }, style = "frame_title" }
  t.ignored_by_interaction = true
  local drag = bar.add{ type = "empty-widget", style = "draggable_space_header" }
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  drag.style.minimal_width = 24
  drag.ignored_by_interaction = true
  bar.add{ type = "sprite-button", name = M.WINDOW .. "_close", style = "frame_action_button",
    sprite = "utility/close", tooltip = { "gui.close-instruction" } }
end

--- Окно встаёт туда, куда хозяин его перетащил в прошлый раз; впервые (или если место ушло за
--- край экрана после смены разрешения) — по центру.
local function place(p, w, st)
  local loc = st and st.location
  local res = p.display_resolution
  local x, y = type(loc) == "table" and tonumber(loc.x), type(loc) == "table" and tonumber(loc.y)
  if x and y and x >= 0 and y >= 0 and (type(res) ~= "table" or (x < res.width - 40 and y < res.height - 40)) then
    w.location = { x = x, y = y }
  else
    w.auto_center = true
  end
end

local function build_foreign(p, st)
  local w = screen_of(p).add{ type = "frame", name = M.WINDOW, direction = "vertical" }
  title_bar(w)
  w.add{ type = "label", caption = { "partner-panel.owner-only" } }
  place(p, w, st)
  return w
end

local function build_owner(p, st)
  local w = screen_of(p).add{ type = "frame", name = M.WINDOW, direction = "vertical" }
  title_bar(w)
  local inset = w.add{ type = "frame", name = "inset", direction = "vertical",
    style = "inside_shallow_frame_with_padding" }
  -- промежутки между строками задаются у flow: у рамки такого свойства нет
  local body = inset.add{ type = "flow", name = "body", direction = "vertical" }
  body.style.vertical_spacing = 8

  body.add{ type = "label", caption = { "partner-panel.helpers" }, style = "caption_label" }
  local ids = listed_ids()
  local rows = body.add{ type = "flow", name = "rows", direction = "vertical" }
  rows.tags = { ids = ids_key(ids) }
  if #ids == 0 then
    rows.add{ type = "label", name = "none", caption = { "partner-panel.no-helpers" } }
  end
  for _, id in ipairs(ids) do
    local row = rows.add{ type = "flow", name = "row_" .. id, direction = "horizontal" }
    row.style.horizontal_spacing = 8
    row.add{ type = "label", caption = nameplate.display_name(id), style = "bold_label" }
    local s = row.add{ type = "label", name = "status_" .. id, caption = helper_row_text(id) }
    s.style.single_line = false
    s.style.maximal_width = M.STATUS_WIDTH
  end

  local scale = body.add{ type = "flow", name = "scale", direction = "horizontal" }
  scale.style.vertical_align = "center"
  scale.add{ type = "label", caption = { "partner-panel.count" } }
  scale.add{ type = "button", name = M.WINDOW .. "_minus", caption = "-", style = "tool_button" }
  scale.add{ type = "label", name = M.WINDOW .. "_n", caption = tostring(st.n) }
  scale.add{ type = "button", name = M.WINDOW .. "_plus", caption = "+", style = "tool_button" }
  scale.add{ type = "button", name = M.WINDOW .. "_apply", caption = { "partner-panel.apply" },
    tooltip = { "partner-panel.apply-tip" } }

  local hold = body.add{ type = "flow", name = "hold", direction = "horizontal" }
  hold.add{ type = "button", name = M.WINDOW .. "_hold", caption = { "partner-panel.hold" },
    tooltip = { "partner-panel.hold-tip" } }
  hold.add{ type = "button", name = M.WINDOW .. "_resume", caption = { "partner-panel.resume" },
    tooltip = { "partner-panel.resume-tip" } }

  body.add{ type = "checkbox", name = M.WINDOW .. "_thoughts", state = st.thoughts and true or false,
    caption = { "partner-panel.thoughts" }, tooltip = { "partner-panel.thoughts-tip" } }

  local auto = body.add{ type = "flow", name = "auto_row", direction = "horizontal" }
  auto.style.vertical_align = "center"
  auto.add{ type = "checkbox", name = M.WINDOW .. "_auto", state = st.auto and true or false,
    caption = { "partner-panel.auto" }, tooltip = { "partner-panel.auto-tip" } }
  local goal = auto.add{ type = "textfield", name = M.WINDOW .. "_goal", text = st.goal or "" }
  goal.style.horizontally_stretchable = true
  goal.style.minimal_width = 200
  goal.tooltip = { "partner-panel.goal-tip" }

  body.add{ type = "checkbox", name = M.WINDOW .. "_combat", state = combat_is_on(),
    caption = { "partner-panel.combat" }, tooltip = { "partner-panel.combat-tip" } }

  local note = body.add{ type = "label", name = M.WINDOW .. "_note", caption = "" }
  note.style.single_line = false
  note.style.maximal_width = M.STATUS_WIDTH + 80
  place(p, w, st)
  return w
end

local function default_n(st)
  if st.n == nil then st.n = clamp_n(math.max(#alive_ids(), M.MIN_HELPERS)) end
end

local function open(p)
  local st = state_of(p.index)
  destroy_window(p)
  if owner.is_owner(p) then
    default_n(st)
    build_owner(p, st)
  else
    build_foreign(p, st)
  end
  st.open = true
  set_toggled(p, true)
end

local function close(p)
  destroy_window(p)
  state_of(p.index).open = false
  set_toggled(p, false)
end

local function toggle(p)
  if window_of(p) ~= nil then close(p) else open(p) end
end

local function set_note(w, key, extra)
  local note = find(w, M.WINDOW .. "_note")
  if note == nil then return end
  if key == nil then note.caption = "" else note.caption = { key, extra } end
end

-- ------------------------------------------------------------------ обработчики событий

local function player_of(e)
  if e.player_index == nil then return nil end
  return game.get_player(e.player_index)
end

--- Имя элемента нашего окна без префикса «partner_panel_» или nil.
local function own_name(el)
  if el == nil or not el.valid then return nil end
  local n = el.name
  if type(n) ~= "string" then return nil end
  return n:match("^" .. M.WINDOW .. "_(.+)$")
end

local function on_shortcut(e)
  if e.prototype_name ~= M.SHORTCUT then return end
  local p = player_of(e)
  if p ~= nil then toggle(p) end
end

local function on_input(e)
  local p = player_of(e)
  if p ~= nil then toggle(p) end
end

local function current_goal(w)
  local f = find(w, M.WINDOW .. "_goal")
  local text = util.utf8_head(util.one_line(f and f.text or ""), M.GOAL_MAX)
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function emit_auto(w, st)
  local data = { action = "auto", on = st.auto and true or false }
  local goal = current_goal(w)
  if st.auto and goal ~= "" then data.goal = goal end
  emit(data)
end

local function on_click(e)
  local name = own_name(e.element)
  if name == nil then return end
  local p = player_of(e)
  if p == nil then return end
  if name == "close" then close(p) return end
  if not owner.is_owner(p) then return end -- чужое нажатие ничего не делает
  local w = window_of(p)
  if w == nil then return end
  local st = state_of(p.index)
  default_n(st)
  if name == "minus" or name == "plus" then
    st.n = clamp_n(st.n + (name == "plus" and 1 or -1))
    local lbl = find(w, M.WINDOW .. "_n")
    if lbl then lbl.caption = tostring(st.n) end
  elseif name == "apply" then
    emit({ action = "scale", n = st.n })
    set_note(w, "partner-panel.note-scale", st.n)
  elseif name == "hold" then
    apply_word("стоп")
    emit({ action = "hold" })
    set_note(w, nil)
  elseif name == "resume" then
    apply_word("продолжай")
    emit({ action = "resume" })
    set_note(w, nil)
  end
end

local function on_checked(e)
  local name = own_name(e.element)
  if name == nil then return end
  local p = player_of(e)
  if p == nil or not owner.is_owner(p) then return end
  local w = window_of(p)
  if w == nil then return end
  local st = state_of(p.index)
  local on = e.element.state and true or false
  if name == "thoughts" then
    st.thoughts = on
    emit({ action = "thoughts", on = on })
  elseif name == "auto" then
    st.auto = on
    emit_auto(w, st)
  elseif name == "combat" then
    local denied, failed = set_combat(on)
    local real = on and combat_is_on()
    e.element.state = real
    if on and #denied > 0 then
      set_note(w, "partner-panel.note-denied", table.concat(denied, ", "))
    elseif failed > 0 then
      set_note(w, "partner-panel.note-failed", failed)
    else
      set_note(w, nil)
    end
    local data = { action = "combat", on = real }
    if #denied > 0 then data.denied = denied end
    emit(data)
  end
end

local function on_text(e)
  if own_name(e.element) ~= "goal" then return end
  local p = player_of(e)
  if p == nil or not owner.is_owner(p) then return end
  state_of(p.index).goal = util.utf8_head(util.one_line(e.element.text or ""), M.GOAL_MAX)
end

--- Enter в поле цели при включённом AUTO: новая цель уходит событием.
local function on_confirmed(e)
  if own_name(e.element) ~= "goal" then return end
  local p = player_of(e)
  if p == nil or not owner.is_owner(p) then return end
  local st = state_of(p.index)
  st.goal = util.utf8_head(util.one_line(e.element.text or ""), M.GOAL_MAX)
  if not st.auto then return end
  local w = window_of(p)
  if w ~= nil then emit_auto(w, st) end
end

--- Хозяин перетащил окно: запомнить место для следующего открытия.
local function on_moved(e)
  local el = e.element
  if el == nil or not el.valid or el.name ~= M.WINDOW then return end
  local p = player_of(e)
  if p == nil then return end
  local loc = el.location
  if type(loc) == "table" and tonumber(loc.x) and tonumber(loc.y) then
    state_of(p.index).location = { x = tonumber(loc.x), y = tonumber(loc.y) }
  end
end

local function on_removed(e)
  if e.player_index ~= nil then all_state()[e.player_index] = nil end
end

M.events = {
  [defines.events.on_lua_shortcut] = on_shortcut,
  [M.INPUT] = on_input,
  [defines.events.on_gui_click] = on_click,
  [defines.events.on_gui_checked_state_changed] = on_checked,
  [defines.events.on_gui_text_changed] = on_text,
  [defines.events.on_gui_confirmed] = on_confirmed,
  [defines.events.on_gui_location_changed] = on_moved,
  [defines.events.on_player_removed] = on_removed,
}

-- ------------------------------------------------------------------ обновление

--- Раз в секунду: статусы в открытых окнах; список тел изменился — окно собирается заново.
local function refresh(p, st)
  local w = window_of(p)
  if w == nil then
    -- окно закрыто не нами (смена игры, чужой мод): ярлык больше не «нажат»
    st.open = false
    set_toggled(p, false)
    return
  end
  if not owner.is_owner(p) then return end
  local rows = find(w, "rows")
  local ids = listed_ids()
  if rows == nil or (rows.tags or {}).ids ~= ids_key(ids) then
    open(p)
    return
  end
  for _, id in ipairs(ids) do
    local lbl = find(w, "status_" .. id)
    if lbl then lbl.caption = helper_row_text(id) end
  end
end

M.on_nth = {
  [60] = function()
    for index, st in pairs(all_state()) do
      local p = game.get_player(index)
      if p ~= nil and p.valid and st.open then refresh(p, st) end
    end
  end,
}

return M
