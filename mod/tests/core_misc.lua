-- say, reflexes, склейка событий модулей, жизненный цикл, миграции, честность (PROTOCOL §4, §6; PLAN «Модульный интерфейс»).
local S = require("stubs")

local function spawn()
  S.add_player{ name = "Tartaluga" }
  S.okr(S.req("helper_spawn", {}, "h1"))
end

S.suite("misc", {
  { "say: префикс «<helper>: » (без скобок), без переводов строк и rich-text, ≤ 200 символов", function()
      S.load_mod()
      spawn()
      S.okr(S.req("say", { text = "привет\nмир [gps=1,2] [img=item/iron-plate]ок" }, "h1"))
      S.eq(game.printed[#game.printed], "h1: привет мир  ок")
      S.okr(S.req("say", { text = string.rep("ё", 300) }, "h1"))
      S.eq(game.printed[#game.printed], "h1: " .. string.rep("ё", 200))
      S.okr(S.req("say", { text = "[color=red" }, "h1"))
      S.eq(game.printed[#game.printed], "h1: color=red", "незакрытая скобка тоже убрана")
      S.err(S.req("say", { text = "[item=coal]" }, "h1"), "bad_args")
      S.err(S.req("say", {}, "h1"), "bad_args")
      S.err(S.req("say", { text = 5 }, "h1"), "bad_args")
  end },
  { "reflexes: полная замена, схема типа, check зовётся для живого помощника", function()
      local calls = {}
      local refl = { reflexes = {
        flee = { schema = { radius = { type = "number", min = 1, max = 50, default = 20 } },
          check = function(h, e, params, tick) calls[#calls + 1] = { h, e.valid, params.radius, tick } end },
      } }
      S.load_mod{ replace = { ["scripts.reflexes.flee"] = refl } }
      spawn()
      local d = S.okr(S.req("reflexes", { set = { { type = "flee" }, { type = "flee", radius = 5 } } }, "h1"))
      S.eq(d.set, { { type = "flee", radius = 20 }, { type = "flee", radius = 5 } })
      S.tick(10)
      S.eq(calls, { { "h1", true, 20, 10 }, { "h1", true, 5, 10 } })
      S.err(S.req("reflexes", { set = { { type = "dance" } } }, "h1"), "bad_args")
      S.err(S.req("reflexes", { set = { { type = "flee", radius = 99 } } }, "h1"), "limit")
      S.err(S.req("reflexes", { set = { { type = "flee", radius = 0 } } }, "h1"), "bad_args")
      S.err(S.req("reflexes", { set = { { radius = 1 } } }, "h1"), "bad_args")
      S.err(S.req("reflexes", {}, "h1"), "bad_args")
      local many = {}
      for i = 1, 17 do many[i] = { type = "flee" } end
      S.err(S.req("reflexes", { set = many }, "h1"), "limit")
      S.eq(#storage.reflexes.h1, 2, "неудачная замена не трогает старый набор")
      S.okr(S.req("reflexes", { set = {} }, "h1"))
      calls = {}
      S.tick(20)
      S.eq(calls, {})
  end },
  { "reflexes: ошибка в check не роняет тик, мёртвого не проверяют", function()
      local n = 0
      local refl = { reflexes = { flee = { check = function() n = n + 1 error("bad") end } } }
      S.load_mod{ replace = { ["scripts.reflexes.flee"] = refl } }
      spawn()
      S.okr(S.req("reflexes", { set = { { type = "flee" } } }, "h1"))
      S.tick(30)
      S.eq(n, 3)
      S.eq(#S.logs, 1, "ошибка в журнале один раз")
      storage.helpers.h1.entity.die()
      S.tick(30)
      S.eq(n, 3)
  end },
  { "события модулей: склейка, фильтры, ошибка одного не мешает другим", function()
      local order = {}
      local a = { events = {
        [defines.events.on_entity_died] = { handler = function(e) order[#order + 1] = "a:" .. e.entity.name end,
          filter = { { filter = "type", type = "character" } } },
        [defines.events.on_player_joined_game] = function() error("a fails") end,
      } }
      local b = { events = {
        [defines.events.on_entity_died] = { handler = function(e) order[#order + 1] = "b:" .. e.entity.name end,
          filter = { { filter = "type", type = "container" } } },
        [defines.events.on_player_joined_game] = { handler = function() order[#order + 1] = "b:joined" end },
      } }
      S.load_mod{ replace = { ["scripts.reflexes.flee"] = a, ["scripts.reflexes.death"] = b } }
      local f = S.handlers[defines.events.on_entity_died].filters
      S.eq(#f, 3, "фильтры склеены (a + b + ядро)")
      S.nauvis.create_entity{ name = "iron-chest", position = { 0, 0 }, force = "player" }.die()
      S.nauvis.create_entity{ name = "small-biter", position = { 0, 0 }, force = "enemy" }.die()
      S.fire(defines.events.on_player_joined_game, { player_index = 1 })
      S.eq(order, { "a:iron-chest", "b:iron-chest", "b:joined" })
      S.eq(#S.logs, 1)
  end },
  { "фильтр модуля с mode=\"and\" -> ошибка при загрузке", function()
      local a = { events = { [defines.events.on_entity_died] = { handler = function() end,
        filter = { { filter = "type", type = "character" }, { filter = "name", name = "character", mode = "and" } } } } }
      S.raises(function() S.load_mod{ replace = { ["scripts.reflexes.flee"] = a } } end, "mode")
  end },
  { "событие без фильтра у одного модуля -> регистрация без фильтра", function()
      local a = { events = { [defines.events.on_entity_died] = function() end } }
      S.load_mod{ replace = { ["scripts.reflexes.flee"] = a } }
      S.eq(S.handlers[defines.events.on_entity_died].filters, nil)
  end },
  { "on_nth модулей склеиваются, on_init/on_configuration_changed зовутся у всех", function()
      local log = {}
      local a = { on_nth = { [60] = function(e) log[#log + 1] = "a60:" .. e.tick end },
        on_init = function() log[#log + 1] = "a:init" end,
        on_configuration_changed = function(d) log[#log + 1] = "a:changed" end }
      local b = { on_nth = { [60] = function(e) log[#log + 1] = "b60:" .. e.tick end, [600] = function() log[#log + 1] = "b600" end },
        on_init = function() error("b init fails") end }
      S.load_mod{ replace = { ["scripts.reflexes.flee"] = a, ["scripts.reflexes.death"] = b } }
      S.eq(log, { "a:init" })
      S.eq(#S.logs, 1, "ошибка on_init модуля — в журнал")
      S.tick(60)
      S.eq(log, { "a:init", "a60:60", "b60:60" })
      S.reload{ changed = { mod_changes = {} } }
      S.eq(log[#log], "a:changed")
  end },
  { "модули не могут зарегистрировать одну операцию дважды", function()
      local a = { ops = { state = function() return {} end } }
      S.raises(function() S.load_mod{ replace = { ["scripts.reflexes.flee"] = a } } end, "twice")
  end },
  { "storage: все ключи PROTOCOL §7 после on_init и после миграции старого сейва", function()
      S.load_mod()
      for _, k in ipairs({ "proto", "helpers", "jobs", "events", "recent", "blobs", "reservations", "vision", "reflexes",
        "reflex_state", "path_requests" }) do
        S.ok(type(storage[k]) == "table", "нет storage." .. k)
      end
      S.eq(storage.proto, { version = 2, max_helpers = 1 })
      -- сейв без части ключей (например, мод добавили в старую игру) — on_configuration_changed
      storage = { helpers = { h1 = { state = "removed", removed_tick = 0 } } }
      S.reload{ changed = { mod_changes = { ["factorio-partner"] = { old_version = nil, new_version = "0.1.0" } } } }
      S.eq(storage.helpers.h1.state, "removed")
      S.ok(storage.events.next_seq == 1 and storage.jobs.next_job == 1)
      S.eq(storage.proto, { version = 2, max_helpers = 1 })
      S.eq(storage.reflex_state, {})
  end },
  { "миграция схемы 1 -> 2: proto-число становится таблицей, max_helpers не меньше уже занятых мест", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      S.okr(S.req("helper_limit", { max = 3 }))
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.okr(S.req("helper_spawn", {}, "h2"))
      -- сейв прошлой версии мода: proto — число, ключа reflex_state нет, помощников двое
      storage.proto = 1
      storage.reflex_state = nil
      S.reload{ changed = { mod_changes = { ["factorio-partner"] = { old_version = "0.1.0", new_version = "0.1.0" } } } }
      S.eq(storage.proto, { version = 2, max_helpers = 2 })
      S.eq(storage.reflex_state, {})
      S.eq(storage.helpers.h1.state, "alive")
      S.err(S.req("helper_spawn", {}, "h3"), "limit")
      -- повторная миграция ничего не портит; заданное игроком значение сохраняется
      S.okr(S.req("helper_limit", { max = 5 }))
      S.reload{ changed = { mod_changes = {} } }
      S.eq(storage.proto, { version = 2, max_helpers = 5 })
      -- испорченное значение приводится к умолчанию
      storage.proto.max_helpers = "many"
      S.reload{ changed = { mod_changes = {} } }
      S.eq(storage.proto.max_helpers, 1)
  end },
  { "схема 1 без миграции (on_load): лимит по умолчанию, helper_limit сохраняет версию", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      storage.proto = 1
      S.reload()
      S.eq(require("scripts.core.registry").max_helpers(), 1)
      S.okr(S.req("helper_limit", { max = 2 }))
      S.eq(storage.proto, { version = 1, max_helpers = 2 })
  end },
  { "hello.module_errors: падения модулей, рефлексов и действий под pcall считаются с загрузки", function()
      local boom = {
        name = "boom",
        on_nth = { [7] = function() error("nth boom") end },
        reflexes = { boom = { schema = {}, check = function() error("check boom") end } },
        ops = { boom_op = function() error("op boom") end,
                boom_soft = function() require("scripts.core.err").raise("not_found", "нет такого") end },
      }
      S.load_mod{ replace = { ["scripts.reflexes.flee"] = boom } }
      S.add_player{ name = "Tartaluga" }
      S.eq(S.okr(S.req("hello")).module_errors, 0)
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.tick(7)
      S.eq(S.okr(S.req("hello")).module_errors, 1, "on_nth модуля")
      S.tick(7)
      S.eq(S.okr(S.req("hello")).module_errors, 2, "считается каждое падение, а не раз в минуту")
      S.eq(#S.logs, 1, "а в журнал — не чаще раза в минуту")
      S.okr(S.req("reflexes", { set = { { type = "boom" } } }, "h1"))
      S.tick(6) -- тик 20: проверка рефлексов (раз в 10 тиков)
      S.eq(S.okr(S.req("hello")).module_errors, 3, "check рефлекса")
      S.okr(S.req("reflexes", { set = {} }, "h1"))
      S.err(S.req("boom_op"), "internal")
      S.eq(S.okr(S.req("hello")).module_errors, 4, "операция упала с internal")
      S.err(S.req("boom_soft"), "not_found")
      S.eq(S.okr(S.req("hello")).module_errors, 4, "ошибка с кодом — не падение")
      -- после загрузки сейва счёт с нуля
      S.reload()
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },
  { "control.lua: необязательные модули волны 3 (plan_mining, attach) — нет файла не ошибка, сбой внутри — ошибка", function()
      S.load_mod()
      local d = require("scripts.core.dispatch")
      S.ok(d.ops.helper_attach, "файл scripts/core/attach.lua есть (поток P) — операция зарегистрирована")
      -- модуль есть: его операции и действия регистрируются
      local attach = { name = "core.attach", ops = { helper_attach = function(args, ctx) return { helper = ctx.helper_id } end } }
      local mining = { name = "plan_mining", schema = {}, start = function() return { status = "done" } end,
        tick = function() end, stop = function() end }
      S.load_mod{ replace = { ["scripts.core.attach"] = attach, ["scripts.actions.plan_mining"] = mining } }
      S.eq(S.okr(S.req("helper_attach", {}, "p1")).helper, "p1")
      S.err(S.req("helper_attach", {}), "bad_request", "helper_attach требует id помощника")
      S.ok(require("scripts.core.jobs").actions.plan_mining, "действие plan_mining")
  end },
  { "control.lua регистрирует все действия, операции и /partner", function()
      S.load_mod()
      local jobs = require("scripts.core.jobs")
      for _, a in ipairs({ "walk", "approach", "follow", "mine", "craft", "insert", "extract", "collect", "pickup",
        "place", "build_blueprint", "build_ghosts", "deconstruct", "wait" }) do
        S.ok(jobs.actions[a], "действие " .. a)
      end
      local d = require("scripts.core.dispatch")
      for _, op in ipairs({ "hello", "helper_spawn", "helper_remove", "helper_list", "act", "cancel", "jobs", "events",
        "reflexes", "vision", "say", "blob_put", "state", "map", "resources", "stock", "ghosts", "recipes", "rates",
        "helper_limit", "find" }) do
        S.ok(d.ops[op], "операция " .. op)
      end
      S.ok(S.commands.partner)
      S.eq(S.unknown_events, {}, "все defines.events известны")
  end },
  { "без хозяина hello отдаёт owner=nil", function()
      S.load_mod()
      S.eq(S.okr(S.req("hello")).owner, nil)
  end },
  { "резерв области: пересечение с чужой -> reserved", function()
      S.load_mod()
      local reserve = require("scripts.core.reserve")
      reserve.hold_area("h1", { left_top = { x = 0, y = 0 }, right_bottom = { x = 10, y = 10 } })
      S.raises(function() reserve.hold_area("h2", { left_top = { x = 5, y = 5 }, right_bottom = { x = 20, y = 20 } }) end, "reserved")
      reserve.hold_area("h2", { left_top = { x = 10, y = 0 }, right_bottom = { x = 20, y = 10 } })
      reserve.add_items("h1", { coal = 5 })
      S.eq(reserve.reserved_by_others("h2", "coal"), 5)
      S.eq(reserve.reserved_by_others("h1", "coal"), 0)
      reserve.release_all("h1")
      S.eq(storage.reservations.items, {})
  end },
})
