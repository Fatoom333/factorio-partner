-- scripts.core.index: индекс построек хозяина по событиям (построено, снесено, умерло, клон),
-- выборка в радиусе, раскрутка сейва без индекса с бюджетом на тик.
local S = require("stubs")

local function setup()
  S.load_mod()
  for name, t in pairs {
    ["assembling-machine-1"] = "assembling-machine", ["stone-furnace"] = "furnace", ["lab"] = "lab",
    ["burner-inserter"] = "inserter", ["steel-chest"] = "container", ["wooden-chest"] = "container",
  } do
    prototypes.entity[name] = { name = name, type = t }
  end
  return require("scripts.core.index")
end

local function make(name, x, y, o)
  o = o or {}
  return S.nauvis.create_entity{
    name = name, position = { x = x, y = y }, force = o.force or "player", raise_built = o.built ~= false,
    fields = o.fields,
  }
end

-- чанки поверхности для раскрутки: n штук в ряд по x (как LuaSurface.get_chunks)
local function chunks(n)
  rawset(S.nauvis, "get_chunks", function()
    local i = 0
    return function()
      if i >= n then return nil end
      i = i + 1
      return { x = i - 1, y = 0 }
    end
  end)
end

S.suite("core_index", {
  { "построено: машина, лаборатория, горелка попадают; чужая сила и сундук — нет", function()
      local index = setup()
      make("assembling-machine-1", 10, 0)
      make("lab", 12, 0)
      make("stone-furnace", 14, 0, { fields = { burner = { inventory = {} } } })
      make("assembling-machine-1", 16, 0, { force = "enemy" })
      make("steel-chest", 18, 0)
      local c = index.counts()
      S.eq(c.total, 3)
      S.eq(c.machine, 3)
      S.eq(c.lab, 1)
      S.eq(c.burner, 1)
      local near = index.near("machine", 1, { x = 0, y = 0 }, 50, "player")
      S.eq(#near, 3)
      S.eq(near[1].name, "assembling-machine-1")
      S.eq(near[1].pos, { x = 10, y = 0 })
  end },

  { "манипулятор: только с горелкой и не как машина", function()
      local index = setup()
      make("burner-inserter", 5, 5)
      make("burner-inserter", 6, 5, { fields = { burner = {} } })
      local c = index.counts()
      S.eq(c.total, 1)
      S.eq(c.burner, 1)
      S.eq(c.machine, 0)
  end },

  { "повторное событие не дублирует запись; клон добавляется", function()
      local index = setup()
      local e = make("assembling-machine-1", 10, 0)
      S.fire(defines.events.script_raised_built, { entity = e })
      S.eq(index.counts().total, 1)
      local copy = make("assembling-machine-1", 30, 0, { built = false })
      S.eq(index.counts().total, 1)
      S.fire(defines.events.on_entity_cloned, { source = e, destination = copy })
      S.eq(index.counts().total, 2)
  end },

  { "построено руками и роботом, призрак после восстановления", function()
      local index = setup()
      local a = make("assembling-machine-1", 10, 0, { built = false })
      S.fire(defines.events.on_built_entity, { entity = a })
      local b = make("stone-furnace", 20, 0, { built = false })
      S.fire(defines.events.on_robot_built_entity, { entity = b })
      local c = make("lab", 30, 0, { built = false })
      S.fire(defines.events.script_raised_revive, { entity = c })
      S.eq(index.counts().total, 3)
  end },

  { "снесено: добыто, script_raised_destroy, умерло (on_object_destroyed в тот же тик)", function()
      local index = setup()
      local a = make("assembling-machine-1", 10, 0)
      local b = make("stone-furnace", 20, 0)
      local c = make("lab", 30, 0)
      S.eq(index.counts().total, 3)
      S.fire(defines.events.on_player_mined_entity, { entity = a })
      S.eq(index.counts().total, 2)
      b.destroy{ raise_destroy = true }
      S.eq(index.counts().total, 1)
      c.die()
      S.tick(1)
      S.eq(index.counts().total, 0, "умершую снимает on_object_destroyed")
      S.eq(index.counts().machine, 0)
  end },

  { "невалидная сущность снимается при чтении", function()
      local index = setup()
      local a = make("assembling-machine-1", 10, 0)
      S.invalidate(a)
      S.eq(#index.near("machine", 1, { x = 0, y = 0 }, 50, "player"), 0)
      S.eq(index.counts().total, 0)
  end },

  { "выборка в радиусе: ближние первыми, чанки соседние и дальние, чужая сила не берётся", function()
      local index = setup()
      make("assembling-machine-1", 40, 0)
      make("assembling-machine-1", 10, 0)
      make("assembling-machine-1", 200, 0)
      make("assembling-machine-1", -33, -33)
      local list = index.near("machine", 1, { x = 0, y = 0 }, 50, "player")
      S.eq(#list, 3)
      S.eq(list[1].pos.x, 10)
      S.eq(list[2].pos.x, 40)
      S.eq(list[3].pos.x, -33)
      S.eq(#index.near("machine", 1, { x = 0, y = 0 }, 50, "enemy"), 0)
      S.eq(#index.near("machine", 2, { x = 0, y = 0 }, 50, "player"), 0, "другая поверхность")
      S.eq(#index.near("machine", 1, { x = 0, y = 0 }, 300, "player"), 4)
      S.raises(function() index.near("chest", 1, { x = 0, y = 0 }, 5) end, "unknown kind")
  end },

  { "поверхность удалена — её записи уходят", function()
      local index = setup()
      make("assembling-machine-1", 10, 0)
      S.fire(defines.events.on_surface_deleted, { surface_index = S.nauvis.index })
      S.eq(index.counts().total, 0)
  end },

  { "раскрутка: открытые чанки, не больше BOOT_CHUNKS за тик, ready в конце", function()
      local index = setup()
      for i = 0, 8 do make("assembling-machine-1", i * 32 + 5, 5, { built = false }) end
      chunks(9)
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 3, y = 0 })] = true
      S.eq(index.ready(), false)
      S.tick(1) -- список поверхностей
      S.tick(1) -- список открытых чанков поверхности
      S.eq(index.counts().total, 0)
      S.tick(1)
      S.eq(index.counts().total, 4, "BOOT_CHUNKS = 4 за тик")
      S.eq(index.ready(), false)
      S.tick(1)
      S.eq(index.counts().total, 8)
      S.tick(1)
      S.eq(index.ready(), true)
      S.eq(index.counts().total, 8, "чанк (3, 0) не открыт — его машина не в индексе")
      local before = #S.nauvis.created
      S.tick(5)
      S.eq(#S.nauvis.created, before)
  end },

  { "раскрутка: больше BOOT_ENTITIES за тик не берёт новых чанков", function()
      local index = setup()
      index.BOOT_ENTITIES = 2
      for i = 0, 3 do
        for k = 1, 3 do make("assembling-machine-1", i * 32 + k * 3, 5, { built = false }) end
      end
      chunks(4)
      S.tick(2)
      S.tick(1)
      S.eq(index.counts().total, 3, "первый чанк дал 3 ≥ 2 — остальные ждут следующего тика")
      S.tick(1)
      S.eq(index.counts().total, 6)
  end },

  { "раскрутка: список открытых чанков собирается порциями по LIST_CHUNKS за тик", function()
      local index = setup()
      index.LIST_CHUNKS = 3
      for i = 0, 6 do make("assembling-machine-1", i * 32 + 5, 5, { built = false }) end
      chunks(7)
      game.forces.player.uncharted[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      S.tick(1) -- список поверхностей
      S.tick(1) -- чанки 0..2
      S.tick(1) -- чанки 3..5
      S.eq(storage.index.boot.ci, nil, "список ещё не закончен")
      S.eq(#storage.index.boot.list, 10, "из первых шести чанков открыты пять, по две координаты")
      S.tick(1) -- чанк 6, список готов
      S.eq(storage.index.boot.ci, 1)
      S.eq(#storage.index.boot.list, 12, "из семи чанков открыты шесть")
      S.tick(10)
      S.eq(index.ready(), true)
      S.eq(index.counts().total, 6)
  end },

  { "раскрутка: список чанков без прохода с начала — вызовов итератора порядка n, не n^2/порция", function()
      local index = setup()
      index.LIST_CHUNKS = 10
      local n, calls = 200, 0
      rawset(S.nauvis, "get_chunks", function()
        local i = 0
        return function()
          calls = calls + 1
          if i >= n then return nil end
          i = i + 1
          return { x = i - 1, y = 0 }
        end
      end)
      for i = 0, n - 1, 20 do make("assembling-machine-1", i * 32 + 5, 5, { built = false }) end
      S.tick(400)
      S.eq(index.ready(), true)
      S.eq(index.counts().total, 10, "все машины найдены")
      -- 200 чанков порциями по 10: 20 порций; с проходом с начала было бы около 2000 вызовов
      S.ok(calls <= n + 2, "вызовов итератора " .. calls)
      S.eq(index.stats.opened, 1, "итератор создан один раз")
  end },

  { "раскрутка в сетевой игре: итератор без кэша модуля, каждая порция с проматыванием по счётчику", function()
      local index = setup()
      index.LIST_CHUNKS = 10
      local n = 50
      rawset(game, "is_multiplayer", function() return true end)
      rawset(S.nauvis, "get_chunks", function()
        local i = 0
        return function()
          if i >= n then return nil end
          i = i + 1
          return { x = i - 1, y = 0 }
        end
      end)
      for i = 0, n - 1, 10 do make("assembling-machine-1", i * 32 + 5, 5, { built = false }) end
      S.tick(200)
      rawset(game, "is_multiplayer", function() return false end)
      S.eq(index.ready(), true)
      S.eq(index.counts().total, 5, "все машины найдены")
      S.ok(index.stats.opened >= 5, "итератор создаётся на каждую порцию: " .. index.stats.opened)
  end },

  { "раскрутка: после загрузки сейва посреди списка итератор один раз проматывается по счётчику", function()
      local index = setup()
      index.LIST_CHUNKS = 10
      local n, calls = 50, 0
      local function install()
        rawset(S.nauvis, "get_chunks", function()
          local i = 0
          return function()
            calls = calls + 1
            if i >= n then return nil end
            i = i + 1
            return { x = i - 1, y = 0 }
          end
        end)
      end
      install()
      for i = 0, n - 1, 5 do make("assembling-machine-1", i * 32 + 5, 5, { built = false }) end
      S.tick(3) -- поверхности, затем две порции по 10
      local skip = storage.index.boot.skip
      S.ok(skip > 0 and skip < n and storage.index.boot.ci == nil, "список ещё собирается: " .. skip)
      S.eq(calls, skip)
      S.reload()
      install()
      index = require("scripts.core.index")
      S.tick(300)
      S.eq(index.ready(), true)
      S.eq(index.counts().total, 10)
      -- до загрузки skip, перемотка skip, оставшиеся n - skip и один пустой шаг: проход с начала один раз
      S.ok(calls <= skip + skip + (n - skip) + 2, "вызовов итератора " .. calls)
  end },

  { "телепорт: позиция записи сверяется при выдаче, запись перекладывается в чанк", function()
      local index = setup()
      local e = make("assembling-machine-1", 10, 0)
      S.eq(#index.near("machine", 1, { x = 200, y = 0 }, 20, "player"), 0)
      S.move(e, { x = 200, y = 0 })
      local list = index.near("machine", 1, { x = 0, y = 0 }, 20, "player")
      S.eq(#list, 0, "из старого места ушла")
      list = index.near("machine", 1, { x = 200, y = 0 }, 20, "player")
      S.eq(#list, 1)
      S.eq(list[1].pos, { x = 200, y = 0 })
      S.eq(index.counts().total, 1)
      -- перенос внутри круга, в чанк, который обходится позже: запись не дублируется
      S.move(e, { x = 230, y = 0 })
      list = index.near("machine", 1, { x = 215, y = 0 }, 40, "player")
      S.eq(#list, 1)
      S.eq(list[1].pos.x, 230)
  end },

  { "смена силы: запись снимается при выдаче", function()
      local index = setup()
      local e = make("assembling-machine-1", 10, 0)
      S.eq(#index.near("machine", 1, { x = 0, y = 0 }, 50, "player"), 1)
      e.force = game.forces.enemy
      S.eq(#index.near("machine", 1, { x = 0, y = 0 }, 50, "player"), 0)
      S.eq(index.counts().total, 0)
  end },

  { "раскрутка не удваивает то, что уже пришло событием; сбой раскрутки не роняет игру", function()
      local index = setup()
      make("assembling-machine-1", 5, 5)
      chunks(2)
      S.tick(10)
      S.eq(index.counts().total, 1)
      S.eq(index.ready(), true)
      -- у поверхности без get_chunks раскрутка ошибается внутри pcall: ready остаётся false
      local S2 = require("stubs")
      S2.load_mod()
      S2.tick(5)
      S.eq(require("scripts.core.index").ready(), false)
      S.eq(storage.index.error ~= nil, true)
  end },

  { "сейв: индекс переживает перезагрузку, смена модов запускает раскрутку заново", function()
      local index = setup()
      make("assembling-machine-1", 10, 0)
      chunks(1)
      S.tick(10)
      S.eq(index.ready(), true)
      S.reload()
      S.eq(require("scripts.core.index").counts().total, 1)
      S.eq(require("scripts.core.index").ready(), true)
      S.reload{ changed = { mod_changes = {} } }
      S.eq(require("scripts.core.index").ready(), false)
      S.eq(require("scripts.core.index").counts().total, 1, "записи остаются")
  end },
})
