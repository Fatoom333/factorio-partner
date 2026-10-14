-- Простые операции ядра (поток A): hello, say. PROTOCOL.md §4.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local schema = require("scripts.core.schema")
local owner = require("scripts.core.owner")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")
local nameplate = require("scripts.core.nameplate")

local M = {}

M.MAX_PLAYERS = 64
M.SAY_MAX = 200

function M.hello(args, ctx)
  schema.validate({}, args)
  local players, online = {}, 0
  for _, p in pairs(game.players) do
    if p.connected then online = online + 1 end -- считаем всех, список же ограничен MAX_PLAYERS
    if #players < M.MAX_PLAYERS then
      local item = { index = p.index, name = p.name, online = p.connected and true or false }
      local ok = pcall(function()
        item.surface = p.physical_surface.name
        item.pos = util.pos(p.physical_position)
      end)
      if not ok then item.surface, item.pos = nil, nil end
      players[#players + 1] = item
    end
  end
  table.sort(players, function(a, b) return a.index < b.index end)
  local ids = {}
  for _, id in ipairs(registry.ids()) do
    if registry.get(id).state ~= "removed" then ids[#ids + 1] = id end
  end
  return {
    proto = 1,
    mod = script.active_mods[script.mod_name] or "?",
    tick = game.tick,
    seq = events.last_seq(),
    owner = owner.name(),
    players_online = online,
    players = players,
    helpers = ids,
    module_errors = err.module_errors(),
  }
end

local SAY_SCHEMA = { text = { type = "string", required = true, max = 4000 } }

-- Метки карты в чате помощника (ревизия 3.13): из всего rich-text остаётся только `[gps=x,y,поверхность]`,
-- собранная заново из чисел и имени существующей поверхности, — хозяин кликает и видит место. Место
-- числами в скобках «(x,y)» мод сам делает такой меткой на поверхности помощника. Прочие теги
-- вырезаются, как раньше (PROTOCOL §4).
local GPS_MAX = 5
-- заглушки U+E000 / U+E001 (личная зона Unicode, байтами — Lua 5.2 без \u{}): chat_text их не трогает
local MARK_L, MARK_R = "\238\128\128", "\238\128\129"

local function gps_tag(x, y, surf)
  x, y = tonumber(x), tonumber(y)
  if x == nil or y == nil or math.abs(x) > 1e7 or math.abs(y) > 1e7 then return nil end
  local tag = string.format("[gps=%d,%d", math.floor(x + 0.5), math.floor(y + 0.5))
  if surf ~= nil and surf ~= "" and string.match(surf, "^[%w%-_]+$") and game.surfaces[surf] ~= nil then
    tag = tag .. "," .. surf
  end
  return tag .. "]"
end

local function with_gps(raw, ctx)
  local h = ctx and ctx.entity
  local own = (h and h.valid) and h.surface.name or nil
  local tags = {}
  local function keep(tag)
    if tag == nil or #tags >= GPS_MAX then return "" end
    tags[#tags + 1] = tag
    return MARK_L .. #tags .. MARK_R
  end
  local s = util.one_line(raw)
  s = s:gsub("%[gps=(%-?[%d%.]+),(%-?[%d%.]+),?([^%]]*)%]", function(x, y, surf)
    return keep(gps_tag(x, y, surf ~= "" and surf or own))
  end)
  s = s:gsub("%((%-?%d+)%s*,%s*(%-?%d+)%)", function(x, y) return keep(gps_tag(x, y, own)) end)
  s = util.chat_text(s, M.SAY_MAX)
  s = s:gsub(MARK_L .. "(%d+)" .. MARK_R, function(i) return tags[tonumber(i)] or "" end)
  -- обрезка по длине могла разрезать заглушку
  return (s:gsub(MARK_L .. "%d*", ""):gsub(MARK_R, ""))
end

function M.say(args, ctx)
  local a = schema.validate(SAY_SCHEMA, args)
  local text = with_gps(a.text, ctx)
  if text == "" then err.raise("bad_args", "args.text: empty after cleanup") end
  -- префикс без квадратных скобок (PROTOCOL §4): имя помощника не должно сложиться в rich-text тег
  game.print(nameplate.display_name(ctx.helper_id) .. ": " .. text, { color = nameplate.COLOR })
  return {}
end

return M
