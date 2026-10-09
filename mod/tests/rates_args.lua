-- op `rates`: проверка аргументов и чисел, независимость от целочисленного подтипа Lua 5.3.
local L = require("stubs_l")
local rates = require("scripts.perception.rates")
local op = rates.ops.rates
local I = rates._internal

local surf = L.surface { name = "nauvis" }
local force = L.force {}
L.install { surfaces = { surf }, forces = { player = force }, items = { "iron-plate" }, fluids = { "water" } }
local ctx = { helper_id = "h1", entity = L.character(force, surf) }

L.case("модуль отдаёт только ops.rates", function()
  L.eq(type(rates.ops.rates), "function")
  L.eq(rates.events, nil); L.eq(rates.on_nth, nil); L.eq(rates.reflexes, nil)
end)

L.case("значения по умолчанию: scope=surface, period=1m, top=20", function()
  local a = I.parse_args({})
  L.eq(a.scope, "surface"); L.eq(a.period, "1m"); L.eq(a.top, 20)
  a = I.parse_args(nil)
  L.eq(a.scope, "surface")
end)

L.case("bad_args на неверные значения", function()
  local bad = {
    { scope = "planet" }, { period = "5s" }, { period = 1 }, { top = 0 }, { top = 201 }, { top = 2.5 },
    { top = "5" }, { items = "iron-plate" }, { items = { 1 } }, { items = { "" } },
    { items = { a = "iron-plate" } }, { surface = 7 }, { surface = "" }, { foo = 1 },
    { scope = "area" },
  }
  for i, a in ipairs(bad) do
    local ok, e = pcall(op, a, ctx)
    if ok or type(e) ~= "table" or e.code ~= "bad_args" then
      error("случай " .. i .. ": ожидался bad_args, получено " .. (ok and "успех" or tostring(type(e) == "table" and e.code or e)))
    end
  end
  L.raises("bad_args", function() op("x", ctx) end)
end)

L.case("длинные списки и имена", function()
  local many = {}
  for i = 1, 101 do many[i] = "iron-plate" end
  L.raises("limit", function() op({ items = many }, ctx) end)
  L.raises("bad_args", function() op({ items = { string.rep("a", 201) } }, ctx) end)
  L.raises("bad_args", function() op({ surface = string.rep("a", 201) }, ctx) end)
end)

L.case("top на границах проходит", function()
  op({ top = 1 }, ctx); op({ top = 200 }, ctx)
end)

L.case("product_amounts", function()
  local e, p = I.product_amounts { amount = 3 }
  L.eq(e, 3); L.eq(p, 3)
  e, p = I.product_amounts { amount = 2, probability = 0.25, ignored_by_productivity = 1 }
  L.near(e, 0.5); L.near(p, 0.25)
  e, p = I.product_amounts { amount = 1, ignored_by_productivity = 5 }
  L.eq(e, 1); L.eq(p, 0)
  e, p = I.product_amounts { amount = 0, extra_count_fraction = 0.5 }
  L.near(e, 0.5)
end)

L.case("round2 симметрично и без целочисленных операций", function()
  L.eq(I.round2(1.005 + 1e-9), 1.01)
  L.eq(I.round2(-2.345), -2.35)
  L.eq(I.round2(0), 0)
  L.eq(I.round2(1200), 1200)
end)

L.case("код модуля не использует подтипы чисел Lua 5.3 и запрещённое", function()
  local f = io and io.open and (io.open("mod/factorio-partner/scripts/perception/rates.lua", "r"))
  if not f then return end -- раннер без io: проверка пропускается
  local src = f:read("*a"); f:close()
  for _, bad in ipairs({ "math%.type", "//", "teleport", "insert%(", "storage%.", "script%.on_",
    "commands%.", "loadstring", "load%(", "rcon%.print" }) do
    -- комментарии «--» не трогаем: ищем только вне строк-комментариев
    for line in src:gmatch("[^\n]+") do
      local code = line:gsub("%-%-.*$", "")
      if code:find(bad) then error("найдено запрещённое: " .. bad .. " в: " .. line) end
    end
  end
end)

L.finish("rates_args")
