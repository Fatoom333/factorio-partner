-- Простые операции ядра (поток A): hello, say. PROTOCOL.md §4.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local schema = require("scripts.core.schema")
local owner = require("scripts.core.owner")
local events = require("scripts.core.events")
local registry = require("scripts.core.registry")

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
  }
end

local SAY_SCHEMA = { text = { type = "string", required = true, max = 4000 } }

function M.say(args, ctx)
  local a = schema.validate(SAY_SCHEMA, args)
  local text = util.chat_text(a.text, M.SAY_MAX)
  if text == "" then err.raise("bad_args", "args.text: empty after cleanup") end
  -- префикс без квадратных скобок (PROTOCOL §4): имя помощника не должно сложиться в rich-text тег
  game.print(ctx.helper_id .. ": " .. text)
  return {}
end

return M
