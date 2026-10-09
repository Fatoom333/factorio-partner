-- Самопроверка заглушек и JSON-моста раннера (поток A).
local S = require("stubs")

S.suite("stubs", {
  { "json: массивы, объекты, пустая таблица, целые", function()
      local s = helpers.table_to_json({ a = { 1, 2, 3 }, b = {}, c = 3.0, d = 0.5, e = "тест", f = true })
      local t = helpers.json_to_table(s)
      S.eq(t, { a = { 1, 2, 3 }, b = {}, c = 3, d = 0.5, e = "тест", f = true })
      S.ok(s:find('"c":3', 1, true), "целое без .0: " .. s)
      S.ok(s:find('"b":{}', 1, true), "пустая таблица -> {}: " .. s)
      S.ok(not s:find("\n", 1, true))
  end },
  { "json: дырявый массив -> объект со строковыми ключами", function()
      local s = helpers.table_to_json({ [1] = "a", [3] = "c" })
      S.eq(helpers.json_to_table(s), { ["1"] = "a", ["3"] = "c" })
  end },
  { "json: невалидный текст -> nil", function()
      S.eq(helpers.json_to_table("{nope"), nil)
      S.eq(helpers.json_to_table(""), nil)
  end },
  { "json: LuaObject сериализовать нельзя", function()
      local e = S.nauvis.create_entity{ name = "iron-chest", position = { 1, 2 }, force = "player" }
      S.raises(function() helpers.table_to_json({ e = e }) end, "LuaObject")
      S.raises(function() helpers.table_to_json({ f = function() end }) end, "function")
  end },
  { "Lua 5.2: нет целочисленного подтипа; JSON не зависит от подтипа", function()
      if _VERSION == "Lua 5.2" then S.eq(math.type, nil, "math.type есть только в 5.3+") end
      local s = helpers.table_to_json({ a = 3.0, b = 3, c = 6 / 2 })
      S.ok(not s:find(".0", 1, true), s)
      S.eq(helpers.json_to_table(s), { a = 3, b = 3, c = 3 })
  end },
  { "игрок, тело, физическая позиция", function()
      local p = S.add_player{ name = "Tartaluga", position = { 5, 6 } }
      S.eq(game.get_player("Tartaluga"), p)
      S.eq(game.get_player(1), p)
      S.eq(#game.connected_players, 1)
      S.eq(p.physical_position, { x = 5, y = 6 })
      S.move(p.character, { x = 7, y = 8 })
      S.eq(p.physical_position, { x = 7, y = 8 })
      S.eq(p.physical_surface, S.nauvis)
      S.raises(function() p.character.teleport({ 0, 0 }) end, "teleport")
  end },
  { "die: события, труп, on_object_destroyed в конце тика", function()
      local seen = {}
      script.on_event(defines.events.on_entity_died, function(e) seen[#seen + 1] = "died:" .. e.entity.name end,
        { { filter = "type", type = "character" } })
      script.on_event(defines.events.on_post_entity_died, function(e) seen[#seen + 1] = "post:" .. #e.corpses end)
      script.on_event(defines.events.on_object_destroyed, function(e) seen[#seen + 1] = "destroyed:" .. e.useful_id end)
      local ch = S.nauvis.create_entity{ name = "character", position = { 0, 0 }, force = "player" }
      ch.insert{ name = "iron-plate", count = 5 }
      local chest = S.nauvis.create_entity{ name = "iron-chest", position = { 3, 0 }, force = "player" }
      script.register_on_object_destroyed(ch)
      chest.die()
      ch.die()
      S.eq(seen, { "post:0", "died:character", "post:1" }, "фильтр type=character")
      S.tick()
      S.eq(seen[4], "destroyed:" .. ch.unit_number)
      local corpse = S.nauvis.find_entities_filtered{ type = "character-corpse" }[1]
      S.eq(corpse.get_inventory(defines.inventory.character_corpse).get_item_count("iron-plate"), 5)
  end },
  { "tick: on_tick и on_nth_tick", function()
      local n, m = 0, 0
      script.on_event(defines.events.on_tick, function() n = n + 1 end)
      script.on_nth_tick(60, function() m = m + 1 end)
      S.tick(120)
      S.eq({ n, m, game.tick }, { 120, 2, 120 })
  end },
  { "инвентарь: insert/remove/get_contents", function()
      local inv = S.inventory{ cap = 10 }
      S.eq(inv.insert{ name = "coal", count = 7 }, 7)
      S.eq(inv.insert{ name = "stone", count = 7 }, 3)
      S.eq(inv.remove_item{ name = "coal", count = 10 }, 7)
      S.eq(inv.get_contents(), { { name = "stone", count = 3, quality = "normal" } })
  end },
})
