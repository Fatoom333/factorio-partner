-- Фоновый крафт (`craft{wait:false}`): как у игрока — крафт брошен в очередь персонажа,
-- задача сразу done, а помощник занимается другим (ходит, копает, строит), пока движок крафтит.
-- Событий крафта у персонажа без игрока нет — модуль раз в EVERY тиков смотрит прирост продукта и
-- очередь крафта и шлёт громкое `craft_done{recipe, crafted, queued}`, когда продукт вырос на queued или
-- очередь крафта опустела (тогда crafted — фактический прирост; он может быть меньше, если продукт
-- тем временем потратили или крафт сняли). Тело пропало — запись молча снимается (смерть и так видна).
-- storage.bg_crafts[id] = {{recipe, product, base, expected}, ...}.
local events = require("scripts.core.events")

local M = {}
M.name = "bgcraft"
M.EVERY = 30

--- Запомнить фоновый крафт помощника.
function M.add(id, rec)
  storage.bg_crafts = storage.bg_crafts or {}
  local list = storage.bg_crafts[id] or {}
  storage.bg_crafts[id] = list
  list[#list + 1] = rec
end

local function count(h, name)
  local inv = h.get_main_inventory()
  return inv and inv.get_item_count(name) or 0
end

function M.check()
  local all = storage.bg_crafts
  if all == nil then return end
  for id, list in pairs(all) do
    local rec = storage.helpers and storage.helpers[id]
    local h = rec and rec.entity
    if h == nil or not h.valid then
      all[id] = nil
    else
      local qsize = h.crafting_queue_size or 0
      local keep = {}
      for _, c in ipairs(list) do
        local got = count(h, c.product) - c.base
        if got < 0 then got = 0 end
        if got >= c.expected or qsize == 0 then
          if got > c.expected then got = c.expected end
          events.emit(id, "craft_done", { recipe = c.recipe, crafted = { [c.product] = got }, queued = c.expected },
            { loud = true })
        else
          keep[#keep + 1] = c
        end
      end
      all[id] = keep[1] ~= nil and keep or nil
    end
  end
end

M.on_nth = {
  [M.EVERY] = function() M.check() end,
}

return M
