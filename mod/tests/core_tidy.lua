-- Автосортировка инвентаря помощника (core.tidy): раз в 5 с sort_and_merge у тела без игрока.
local S = require("stubs")
local C = require("stubs_c")

S.suite("core_tidy", {
  { "раз в 300 тиков — sort_and_merge главного инвентаря помощника", function()
      local W = C.setup()
      local n = 0
      rawset(W.main, "sort_and_merge", function() n = n + 1 end)
      C.run(299)
      local before = n
      C.run(601)
      S.ok(n - before >= 2, "сортировок: " .. (n - before))
  end },
  { "тело-игрок (второй клиент) не трогается", function()
      local W = C.setup()
      local n = 0
      rawset(W.main, "sort_and_merge", function() n = n + 1 end)
      storage.helpers.h1.player_index = 1
      C.run(900)
      S.eq(n, 0)
  end },
})
