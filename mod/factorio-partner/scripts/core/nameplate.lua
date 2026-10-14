-- Имя помощника в игре (решение автора 14.10): у тела без игрока нет ни подписи над головой, ни точки
-- на карте, а строка в списке игроков хозяину не нужна. Мод рисует подпись над телом и держит метку
-- на карте силы рядом с ним; тем же именем подписаны сообщения `say`. У тела-игрока всё это есть от
-- самой игры — для него мод ничего не рисует.
--
-- Имя — настройка `partner-helper-name` (по умолчанию «Claude»): у h1 — оно само, у остальных —
-- «<имя> <id>». Квадратные скобки вырезаются (rich-text тег из имени не сложится, PROTOCOL §4).
-- storage.nameplates[id] = {name, unit, text = LuaRenderObject?, tag = LuaCustomChartTag?, tag_pos}.
local M = {}
M.name = "nameplate"

M.DEFAULT = "Claude"
M.MAX_NAME = 24
M.COLOR = { r = 1, g = 0.62, b = 0.25 }
M.LABEL_OFFSET = { 0, -2.4 }
M.TAG_MOVE = 4 -- метка карты переставляется, когда тело ушло от неё дальше этого

local function base_name()
  local s = settings and settings.global and settings.global["partner-helper-name"]
  local v = s and s.value
  if type(v) ~= "string" then v = M.DEFAULT end
  v = v:gsub("[%[%]]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  if v == "" then v = M.DEFAULT end
  if #v > M.MAX_NAME then v = v:sub(1, M.MAX_NAME) end
  return v
end

--- Имя помощника для подписи, метки и чата.
function M.display_name(id)
  local b = base_name()
  if id == "h1" then return b end
  return b .. " " .. tostring(id)
end

local function plates()
  storage.nameplates = storage.nameplates or {}
  return storage.nameplates
end

local function drop(np)
  if np == nil then return end
  if np.text ~= nil and np.text.valid then np.text.destroy() end
  if np.tag ~= nil and np.tag.valid then np.tag.destroy() end
  np.text, np.tag, np.tag_pos = nil, nil, nil
end

local function dist(a, b)
  local dx, dy = a.x - b.x, a.y - b.y
  return math.sqrt(dx * dx + dy * dy)
end

--- Привести подпись и метку одного помощника в порядок.
function M.refresh(id, rec)
  local all = plates()
  local np = all[id]
  local e = rec and rec.entity
  local body_ok = rec ~= nil and rec.state == "alive" and rec.player_index == nil and e ~= nil and e.valid
  if not body_ok then
    if np ~= nil then drop(np); all[id] = nil end
    return
  end
  local name = M.display_name(id)
  if np == nil then
    np = {}
    all[id] = np
  end
  if np.name ~= name or np.unit ~= e.unit_number then
    drop(np)
    np.name, np.unit = name, e.unit_number
  end
  if np.text == nil or not np.text.valid then
    np.text = rendering.draw_text{
      text = name, surface = e.surface, target = { entity = e, offset = M.LABEL_OFFSET },
      color = M.COLOR, scale = 1.2, alignment = "center", vertical_alignment = "middle",
      use_rich_text = false,
    }
  end
  local pos = e.position
  local tag = np.tag
  local stale = tag == nil or not tag.valid or tag.surface ~= e.surface
    or np.tag_pos == nil or dist(np.tag_pos, pos) > M.TAG_MOVE
  if stale then
    if tag ~= nil and tag.valid then tag.destroy() end
    np.tag = e.force.add_chart_tag(e.surface, { position = pos, text = name }) -- в неоткрытом чанке — nil
    np.tag_pos = np.tag ~= nil and { x = pos.x, y = pos.y } or nil
  end
end

function M.refresh_all()
  local helpers = storage.helpers or {}
  for id, rec in pairs(helpers) do M.refresh(id, rec) end
  for id, np in pairs(plates()) do
    if helpers[id] == nil then drop(np); plates()[id] = nil end
  end
end

M.on_nth = {
  [60] = function() M.refresh_all() end,
}

return M
