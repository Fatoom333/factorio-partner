-- Автосортировка инвентаря помощника (просьба хозяина 15.10: «открываешь — будто сундук, а не
-- личность»). У игрока инвентарь сортирует игра по его настройке; у тела без игрока настройки нет —
-- мод раз в EVERY тиков зовёт `sort_and_merge` главного инвентаря (то же, что кнопка сортировки:
-- порядок ячеек и слияние стопок, ни предмета больше или меньше). Тело-игрок (второй клиент) не
-- трогается — у него своя настройка в игре.
local M = {}
M.name = "tidy"
M.EVERY = 300

function M.sweep()
  for _, rec in pairs(storage.helpers or {}) do
    local e = rec.entity
    if rec.state == "alive" and rec.player_index == nil and e ~= nil and e.valid then
      local inv = e.get_main_inventory()
      if inv ~= nil then pcall(function() inv.sort_and_merge() end) end
    end
  end
end

M.on_nth = {
  [M.EVERY] = function() M.sweep() end,
}

return M
