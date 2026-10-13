-- scripts.core.target: поиск цели по ACTIONS.md «target»: {unit_number, pos?} │ {name, pos},
-- своей силы или neutral. get_entity_by_unit_number в 2.0 находит не все сущности — запасной
-- поиск find_entities_filtered{position=pos, radius=2} с тем же unit_number.
local S = require("stubs")

local function world()
  S.load_mod()
  S.add_prototype("entity", { name = "iron-chest", type = "container" })
  S.add_prototype("entity", { name = "rock-big", type = "simple-entity" })
  S.add_player{ name = "Tartaluga", position = { x = 0, y = 0 } }
  local calls = { by_unit = 0 }
  local engine_knows = true
  game.get_entity_by_unit_number = function(n)
    calls.by_unit = calls.by_unit + 1
    if not engine_knows then return nil end
    for _, s in ipairs(S._surfaces_list) do
      for _, e in ipairs(s._entities) do
        if e.valid and e.unit_number == n then return e end
      end
    end
    return nil
  end
  return calls, function(v) engine_knows = v end
end

local function chest(pos, force, surface)
  return (surface or S.nauvis).create_entity{ name = "iron-chest", position = pos, force = force or "player" }
end

S.suite("core_target", {
  { "unit_number: своя сила и neutral находятся, чужая — nil/foreign", function()
      world()
      local target = require("scripts.core.target")
      local own = chest({ x = 3.5, y = 3.5 })
      local rock = S.nauvis.create_entity{ name = "rock-big", position = { x = 8, y = 8 }, force = "neutral" }
      local foe = chest({ x = 5.5, y = 5.5 }, "enemy")
      S.eq(target.resolve(S.nauvis, { unit_number = own.unit_number }), own)
      S.eq(target.resolve(S.nauvis, { unit_number = rock.unit_number }), rock)
      local e, why = target.resolve(S.nauvis, { unit_number = foe.unit_number })
      S.eq({ e, why }, { nil, "foreign" })
      local e2, why2 = target.resolve(S.nauvis, { unit_number = 99999 })
      S.eq({ e2, why2 }, { nil, "not_found" })
  end },
  { "сила помощника передаётся третьим аргументом", function()
      world()
      local target = require("scripts.core.target")
      local other = S.force{ name = "other" }
      local c = chest({ x = 1.5, y = 1.5 }, other)
      local e, why = target.resolve(S.nauvis, { unit_number = c.unit_number })
      S.eq({ e, why }, { nil, "foreign" }, "по умолчанию — сила хозяина")
      S.eq(target.resolve(S.nauvis, { unit_number = c.unit_number }, other), c)
      S.eq(target.resolve(S.nauvis, { unit_number = c.unit_number }, "other"), c)
  end },
  { "get_entity_by_unit_number не нашёл — поиск вокруг pos (радиус 2) с тем же unit_number", function()
      local _, knows = world()
      local target = require("scripts.core.target")
      local c = chest({ x = 10.5, y = 10.5 })
      local near = chest({ x = 11.5, y = 10.5 })
      knows(false)
      S.eq(target.resolve(S.nauvis, { unit_number = c.unit_number, pos = { x = 11, y = 11 } }), c)
      S.eq(target.resolve(S.nauvis, { unit_number = near.unit_number, pos = { x = 11, y = 11 } }), near,
        "из двух рядом — с нужным unit_number")
      local e, why = target.resolve(S.nauvis, { unit_number = c.unit_number })
      S.eq({ e, why }, { nil, "not_found" }, "без pos запасного поиска нет")
      local e2, why2 = target.resolve(S.nauvis, { unit_number = c.unit_number, pos = { x = 20, y = 20 } })
      S.eq({ e2, why2 }, { nil, "not_found" }, "pos дальше 2 клеток")
  end },
  { "другая поверхность: other_surface, а не nil без причины", function()
      world()
      local target = require("scripts.core.target")
      local other = S.surface{ name = "vulcanus" }
      local c = chest({ x = 1.5, y = 1.5 }, "player", other)
      local e, why = target.resolve(S.nauvis, { unit_number = c.unit_number })
      S.eq({ e, why }, { nil, "other_surface" })
      S.eq(target.resolve(other, { unit_number = c.unit_number }), c)
  end },
  { "{name, pos}: ближайшая в радиусе 1; неизвестное имя и чужая сила — nil", function()
      world()
      local target = require("scripts.core.target")
      local a = chest({ x = 10.5, y = 10.5 })
      local b = chest({ x = 11.2, y = 10.5 })
      S.eq(target.resolve(S.nauvis, { name = "iron-chest", pos = { x = 10.6, y = 10.5 } }), a)
      S.eq(target.resolve(S.nauvis, { name = "iron-chest", pos = { x = 11.1, y = 10.5 } }), b)
      local e, why = target.resolve(S.nauvis, { name = "iron-chest", pos = { x = 40, y = 40 } })
      S.eq({ e, why }, { nil, "not_found" })
      local e2, why2 = target.resolve(S.nauvis, { name = "no-such-entity", pos = { x = 10, y = 10 } })
      S.eq({ e2, why2 }, { nil, "not_found" })
      chest({ x = 30.5, y = 30.5 }, "enemy")
      local e3, why3 = target.resolve(S.nauvis, { name = "iron-chest", pos = { x = 30.5, y = 30.5 } })
      S.eq({ e3, why3 }, { nil, "foreign" })
  end },
  { "мусор на входе не роняет: nil вместо ошибки", function()
      world()
      local target = require("scripts.core.target")
      S.eq((target.resolve(S.nauvis, nil)), nil)
      S.eq((target.resolve(S.nauvis, {})), nil)
      S.eq((target.resolve(nil, { unit_number = 1 })), nil)
  end },
})
