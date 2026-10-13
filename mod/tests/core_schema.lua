-- Проверка аргументов по схеме (ACTIONS.md «Типы схемы»).
local S = require("stubs")

local function schema() return require("scripts.core.schema") end

local function bad(sch, args, field, code)
  code = code or "bad_args"
  local e = S.raises(function() schema().validate(sch, args) end, nil, "ожидался " .. code .. " для " .. S.dump(args))
  S.eq(e.code, code, S.dump(args))
  if field then S.ok(e.text:find(field, 1, true), "текст «" .. e.text .. "» должен называть " .. field) end
end

S.suite("schema", {
  { "pos", function()
      S.load_mod()
      local sch = { to = { type = "pos", required = true } }
      S.eq(schema().validate(sch, { to = { x = 1.5, y = -2 } }), { to = { x = 1.5, y = -2 } })
      bad(sch, {}, "args.to")
      bad(sch, { to = { 1, 2 } }, "args.to")
      bad(sch, { to = { x = 1 } }, "args.to")
      bad(sch, { to = { x = 1, y = 2, z = 3 } }, "args.to")
      bad(sch, { to = { x = 2e6, y = 0 } }, "args.to")
      bad(sch, { to = { x = 0 / 0, y = 0 } }, "args.to")
  end },
  { "pos или \"player\" (список типов)", function()
      S.load_mod()
      local sch = { to = { type = { "pos", "string" }, values = { "player" }, required = true } }
      S.eq(schema().validate(sch, { to = "player" }).to, "player")
      S.eq(schema().validate(sch, { to = { x = 1, y = 1 } }).to, { x = 1, y = 1 })
      bad(sch, { to = "home" }, "args.to")
      bad(sch, { to = 5 }, "pos or string")
  end },
  { "список типов: неизвестный тип в альтернативе -> internal, а не bad_args", function()
      S.load_mod()
      local sch = { to = { type = { "no_such_type", "string" } } }
      local e = S.raises(function() schema().validate(sch, { to = 5 }) end)
      S.eq(e.code, "internal")
      local ok_sch = { to = { type = { "string", "no_such_type" } } }
      S.eq(schema().validate(ok_sch, { to = "x" }).to, "x", "подошла первая альтернатива")
  end },
  { "area: порядок углов, сторона ≤ 128", function()
      S.load_mod()
      local sch = { area = { type = "area" } }
      local a = { left_top = { x = 0, y = 0 }, right_bottom = { x = 128, y = 10 } }
      S.eq(schema().validate(sch, { area = a }).area, a)
      bad(sch, { area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 129, y = 1 } } }, "128", "limit")
      bad(sch, { area = { left_top = { x = 5, y = 0 }, right_bottom = { x = 1, y = 1 } } }, "args.area")
      bad(sch, { area = { left_top = { x = 0, y = 0 } } }, "args.area")
  end },
  { "items: имя -> целое 1..100000", function()
      S.load_mod()
      local sch = { items = { type = "items" } }
      S.eq(schema().validate(sch, { items = { ["iron-plate"] = 10 } }).items, { ["iron-plate"] = 10 })
      S.eq(schema().validate(sch, { items = {} }).items, {})
      bad(sch, { items = { ["iron-plate"] = 0 } }, "iron-plate")
      bad(sch, { items = { ["iron-plate"] = 100001 } }, "iron-plate")
      bad(sch, { items = { ["iron-plate"] = 1.5 } }, "iron-plate")
      bad(sch, { items = { 5 } }, "args.items")
  end },
  { "target: {unit_number} или {name, pos}", function()
      S.load_mod()
      local sch = { target = { type = "target", required = true } }
      S.eq(schema().validate(sch, { target = { unit_number = 12 } }).target, { unit_number = 12 })
      S.eq(schema().validate(sch, { target = { name = "tree-01", pos = { x = 1, y = 2 } } }).target,
        { name = "tree-01", pos = { x = 1, y = 2 } })
      S.eq(schema().validate(sch, { target = { unit_number = 12, pos = { x = 1, y = 2 } } }).target,
        { unit_number = 12, pos = { x = 1, y = 2 } }, "unit_number + pos (запасной поиск, ACTIONS.md)")
      bad(sch, { target = { unit_number = 12, pos = { x = 1 } } }, "args.target.pos")
      bad(sch, { target = { unit_number = 12, pos = { x = 1, y = 2 }, name = "x" } }, "args.target")
      bad(sch, { target = { unit_number = 1.5 } }, "unit_number")
      bad(sch, { target = { unit_number = 0 } }, "unit_number") -- целое ≥ 1 (ACTIONS.md)
      bad(sch, { target = { unit_number = -3 } }, "unit_number")
      S.eq(schema().validate(sch, { target = { unit_number = 1 } }).target, { unit_number = 1 })
      bad(sch, { target = { unit_number = 1, name = "x" } }, "args.target")
      bad(sch, { target = { name = "x" } }, "args.target.pos")
  end },
  { "string/number/int/bool/enum: границы и default", function()
      S.load_mod()
      local sch = {
        s = { type = "string", max = 5 }, n = { type = "number", min = 0, max = 1, default = 0.5 },
        i = { type = "int", min = 1, max = 3 }, b = { type = "bool", default = false },
        e = { type = "enum", values = { "auto", "hand" }, default = "auto" },
      }
      S.eq(schema().validate(sch, {}), { n = 0.5, b = false, e = "auto" })
      S.eq(schema().validate(sch, { s = "abc", i = 3, b = true, e = "hand" }), { s = "abc", n = 0.5, i = 3, b = true, e = "hand" })
      bad(sch, { s = "abcdef" }, "args.s")
      bad(sch, { s = 5 }, "args.s")
      bad(sch, { n = 2 }, "args.n", "limit") -- верхняя граница -> limit (PROTOCOL §3)
      bad(sch, { n = -1 }, "args.n")
      bad(sch, { i = 0 }, "args.i")
      bad(sch, { i = 4 }, "args.i", "limit")
      bad(sch, { i = 2.5 }, "args.i")
      bad(sch, { b = "true" }, "args.b")
      bad(sch, { e = "robots" }, "args.e")
      bad(sch, { extra = 1 }, "args.extra")
  end },
  { "list: of, max; object: fields", function()
      S.load_mod()
      local sch = {
        filter = { type = "list", of = "string", max = 2 },
        opt = { type = "object", fields = { k = { type = "int", required = true } } },
      }
      S.eq(schema().validate(sch, { filter = { "a", "b" }, opt = { k = 1 } }), { filter = { "a", "b" }, opt = { k = 1 } })
      S.eq(schema().validate(sch, { filter = {} }).filter, {})
      bad(sch, { filter = { "a", "b", "c" } }, "args.filter", "limit")
      bad(sch, { filter = { "a", 1 } }, "args.filter[2]")
      bad(sch, { filter = { a = 1 } }, "args.filter")
      bad(sch, { opt = {} }, "args.opt.k")
  end },
  { "default копируется, вход не меняется", function()
      S.load_mod()
      local sch = { p = { type = "pos", default = { x = 0, y = 0 } } }
      local r1 = schema().validate(sch, {})
      r1.p.x = 99
      S.eq(schema().validate(sch, {}).p, { x = 0, y = 0 })
      local input = { p = { x = 1, y = 1 } }
      local r2 = schema().validate(sch, input)
      r2.p.x = 5
      S.eq(input.p.x, 1)
  end },
})
