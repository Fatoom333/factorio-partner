-- Настройки мода и разрешения хозяина (scripts/core/perms.lua): операция settings, гейт «сам / спросить /
-- нельзя» в act, plan и reflexes, поле конверта owner_ok, бой по настройкам.
-- По умолчанию в тестах owner_ok — все ключи в каждом запросе (stubs.lua); здесь его снимают (S.owner_ok = nil)
-- или дают только нужные ключи.
local S = require("stubs")
local C = require("stubs_c")
local A = require("stubs_armor")
local H = require("stubs_h")
local B = require("stubs_b")

local function set_perm(key, value) settings.global["partner-perm-" .. key] = { value = value } end
local function set_setting(name, value) settings.global["partner-" .. name] = { value = value } end

local function act(d, args) return C.act(d, args) end

local function bp() return act("build_blueprint", { blob = "abc", anchor = { x = 5, y = 5 }, force = "superforced" }) end

local function machine(pos, owned)
  local e = S.nauvis.create_entity{ name = "assembling-machine-1", position = pos, force = "player" }
  rawset(e, "get_recipe", function() return nil, nil end)
  rawset(e, "set_recipe", function() return {} end)
  if owned then rawset(e, "last_user", { name = "Tartaluga" }) end
  return e
end

S.suite("perms", {
  { "settings: снимок по умолчанию — ровно как в проекте, без помощника", function()
      C.setup()
      local d = S.okr(S.req("settings", {}))
      S.eq(d.perms, {
        take_chests = "auto", take_lines = "ask", take_inputs = "deny", build = "auto", superforced = "ask",
        deconstruct_own = "auto", deconstruct_owner = "ask", set_recipe = "ask", chop = "auto", smelt = "auto",
        spend = "ask", shoot = "ask", turrets = "auto", upkeep = "ask", attack_nests = "deny", walk_far = "auto",
        leave_planet = "deny", auto = "ask",
      })
      S.eq(d.limits, { spend = 200, far = 300 })
      S.eq(d.agents, { helpers = 1, pilot_model = "sonnet", strategist_model = "sonnet", thoughts = false,
        voice_pause = 2.5, budget = { strategist = 70, voice_only = 85, weekly = 90 } })
      S.eq(d.combat, { flee_health = 40, auto_armor = true, turret_standoff = true, turret_gap = 3 })
      S.eq(d.chat, { answer_every = true, reply_lines = 2 })
      S.err(S.req("settings", { x = 1 }), "bad_args")
  end },

  { "settings: значения из настроек игры; мусор в настройке — значение по умолчанию", function()
      C.setup()
      set_perm("build", "deny")
      set_perm("chop", "бред")
      set_setting("spend-limit", 50)
      set_setting("pilot-model", "haiku")
      set_setting("turret-gap", 9)
      local d = S.okr(S.req("settings", {}))
      S.eq({ d.perms.build, d.perms.chop, d.limits.spend, d.agents.pilot_model, d.combat.turret_gap },
        { "deny", "auto", 50, "haiku", 9 })
  end },

  { "ask без owner_ok — needs_owner_ok с подписью и perm; с owner_ok — задача поставлена", function()
      C.setup()
      S.owner_ok = nil
      local r = bp()
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "superforced" })
      S.ok(r.error.text:find("Сверхсильная стройка", 1, true), r.error.text)
      S.ok(r.error.text:find("разрешение хозяина", 1, true), r.error.text)
      S.owner_ok = { "superforced" }
      S.okr(bp())
  end },

  { "deny — отказ даже с owner_ok: owner_forbids, perm, текст с подписью настройки", function()
      C.setup()
      set_perm("superforced", "deny")
      S.owner_ok = S.all_leave()
      local r = bp()
      S.err(r, "owner_forbids")
      S.eq(r.error.data, { perm = "superforced" })
      S.ok(r.error.text:find("запрещено в настройках мода", 1, true) and r.error.text:find("Сверхсильная стройка", 1, true),
        r.error.text)
  end },

  { "auto — без owner_ok как раньше; owner_ok не список известных ключей — bad_request", function()
      C.setup()
      set_perm("superforced", "auto")
      S.owner_ok = nil
      S.okr(bp())
      for i, v in ipairs({ "yes", true, { "superforced", "fly" }, { 1 }, { a = "build" } }) do
        local r = S.call{ v = 1, id = "x-" .. i, op = "act", helper = "h1", owner_ok = v,
          args = { ["do"] = "wait", args = { seconds = 1 } } }
        S.err(r, "bad_request")
      end
  end },

  { "owner_ok снимает «спросить» только с тех ключей, о которых спрашивали", function()
      C.setup()
      S.owner_ok = { "take_lines" }
      local r = bp()
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "superforced" })
      local theirs = C.chest({ x = 5.5, y = 0.5 }, {})
      rawset(theirs, "last_user", { name = "Tartaluga" })
      S.err(act("deconstruct", { target = { unit_number = theirs.unit_number } }), "needs_owner_ok")
      S.owner_ok = { "perm-superforced" }
      S.okr(bp())
      S.owner_ok = { "deconstruct-owner" }
      S.okr(act("deconstruct", { target = { unit_number = theirs.unit_number } }))
  end },

  { "действия без ключей не трогает ни одна настройка", function()
      C.setup()
      for _, k in ipairs({ "build", "take-chests", "chop", "walk-far" }) do set_perm(k, "deny") end
      S.owner_ok = nil
      S.okr(act("wait", { seconds = 1 }))
  end },

  { "build deny: place и план с place — owner_forbids; шаг назван в тексте", function()
      C.setup()
      set_perm("build", "deny")
      S.err(act("place", { item = "wooden-chest", pos = { x = 4.5, y = 0.5 } }), "owner_forbids")
      local r = act("plan", { steps = {
        { ["do"] = "wait", args = { seconds = 1 } },
        { ["do"] = "place", args = { item = "wooden-chest", pos = { x = 4.5, y = 0.5 } } },
      } })
      S.err(r, "owner_forbids")
      S.ok(r.error.text:find("шаг 2", 1, true), r.error.text)
      -- dry_run ничего не строит
      set_perm("build", "deny")
  end },

  { "план: шаг с ключом ask без owner_ok — needs_owner_ok; с owner_ok — принят", function()
      C.setup()
      S.owner_ok = nil
      local steps = { { ["do"] = "wait", args = { seconds = 1 } },
        { ["do"] = "build_blueprint", args = { blob = "abc", anchor = { x = 5, y = 5 }, force = "superforced" } } }
      local r = act("plan", { steps = steps })
      S.err(r, "needs_owner_ok")
      S.ok(r.error.text:find("шаг 2", 1, true), r.error.text)
      S.owner_ok = { "superforced" }
      S.okr(act("plan", { steps = steps }))
  end },

  { "take: from_lines — take-lines, без флага — take-chests (get_items и collect)", function()
      C.setup()
      set_perm("take-lines", "ask")
      set_perm("take-chests", "deny")
      S.owner_ok = nil
      S.err(act("get_items", { items = { coal = 1 } }), "owner_forbids")
      S.err(act("collect", { items = { coal = 1 } }), "owner_forbids")
      S.err(act("get_items", { items = { coal = 1 }, from_lines = true }), "needs_owner_ok")
      S.err(act("collect", { items = { coal = 1 }, from_lines = true }), "needs_owner_ok")
      S.owner_ok = { "take_lines" }
      S.okr(act("get_items", { items = { coal = 1 }, from_lines = true }))
  end },

  { "extract: свободный сундук — take-chests, машина — take-lines; персонажа и пустую цель гейт не трогает", function()
      local W = C.setup()
      local ch = C.chest({ x = 3.5, y = 0.5 }, { coal = 5 })
      rawset(ch, "last_user", { name = "Tartaluga" })
      local m = S.nauvis.create_entity{ name = "assembling-machine-1", position = { x = 6.5, y = 0.5 }, force = "player" }
      rawset(m, "last_user", { name = "Tartaluga" })
      local outv = C.inventory{ size = 2, items = { ["iron-gear-wheel"] = 1 } }
      rawset(m, "get_output_inventory", function() return outv end)
      S.owner_ok = nil
      S.okr(act("extract", { target = { unit_number = ch.unit_number } }))
      local r = act("extract", { target = { unit_number = m.unit_number } })
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "take-lines" })
      set_perm("take-chests", "deny")
      S.err(act("extract", { target = { unit_number = ch.unit_number } }), "owner_forbids")
      S.ok(W.h ~= nil)
  end },

  { "extract: свои машина и сундук помощника — без разрешений хозяина, даже при «нельзя»", function()
      C.setup()
      set_perm("take-chests", "deny")
      set_perm("take-lines", "deny")
      local ch = C.chest({ x = 3.5, y = 0.5 }, { coal = 5 })
      local m = S.nauvis.create_entity{ name = "assembling-machine-1", position = { x = 6.5, y = 0.5 }, force = "player" }
      local outv = C.inventory{ size = 2, items = { ["iron-gear-wheel"] = 1 } }
      rawset(m, "get_output_inventory", function() return outv end)
      S.owner_ok = nil
      S.okr(act("extract", { target = { unit_number = ch.unit_number } }))
      S.okr(act("extract", { target = { unit_number = m.unit_number } }))
  end },

  { "проверка на ходу: цель стала хозяйской, пока задача ждала, — start отказывает (extract, set_recipe, deconstruct)", function()
      C.setup()
      set_perm("take-chests", "ask")
      local ch = C.chest({ x = 3.5, y = 0.5 }, { coal = 5 })
      local mc = machine({ x = 5.5, y = 2.5 }, false)
      local dc = C.chest({ x = 7.5, y = 0.5 }, {})
      S.owner_ok = nil
      S.okr(act("wait", { seconds = 1 }))
      local j1 = S.okr(act("extract", { target = { unit_number = ch.unit_number } })).job
      local j2 = S.okr(act("set_recipe", { target = { unit_number = mc.unit_number }, recipe = "iron-gear-wheel" })).job
      local j3 = S.okr(act("deconstruct", { target = { unit_number = dc.unit_number } })).job
      for _, e in ipairs({ ch, mc, dc }) do rawset(e, "last_user", { name = "Tartaluga" }) end
      for _, x in ipairs({ { j1, "take-chests" }, { j2, "set-recipe" }, { j3, "deconstruct-owner" } }) do
        local d, kind = C.wait(x[1])
        S.eq({ kind, d.code, d.detail.perm }, { "job_failed", "needs_owner_ok", x[2] }, S.dump(d))
      end
      S.ok(dc.valid, "постройка хозяина цела")
      S.eq(C.counts(ch.get_inventory(defines.inventory.chest)).coal, 5, "из сундука хозяина ничего не взято")
  end },

  { "проверка на ходу: deconstruct области, где при постановке было пусто, — постройку хозяина не трогает", function()
      C.setup()
      S.owner_ok = nil
      S.okr(act("wait", { seconds = 1 }))
      local j = S.okr(act("deconstruct", { area = { left_top = { x = 2, y = -2 }, right_bottom = { x = 6, y = 2 } } })).job
      local theirs = C.chest({ x = 3.5, y = 0.5 }, {})
      rawset(theirs, "last_user", { name = "Tartaluga" })
      local d, kind = C.wait(j)
      S.eq({ kind, d.code, d.detail.perm }, { "job_failed", "needs_owner_ok", "deconstruct-owner" }, S.dump(d))
      S.ok(theirs.valid)
  end },

  { "mine{target}: постройка хозяина — как её разбор (deconstruct-owner)", function()
      C.setup()
      local theirs = C.chest({ x = 3.5, y = 0.5 }, {})
      rawset(theirs, "last_user", { name = "Tartaluga" })
      S.owner_ok = nil
      local r = act("mine", { target = { unit_number = theirs.unit_number }, count = 1 })
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "deconstruct-owner" })
  end },

  { "deconstruct: постройка игрока — deconstruct-owner (спросить), помощника — deconstruct-own (сам)", function()
      C.setup()
      local mine_ = C.chest({ x = 3.5, y = 0.5 }, {})
      local theirs = C.chest({ x = 5.5, y = 0.5 }, {})
      rawset(theirs, "last_user", { name = "Tartaluga" })
      S.owner_ok = nil
      S.okr(act("deconstruct", { target = { unit_number = mine_.unit_number } }))
      local r = act("deconstruct", { target = { unit_number = theirs.unit_number } })
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "deconstruct-owner" })
      set_perm("deconstruct-own", "deny")
      S.err(act("deconstruct", { target = { unit_number = mine_.unit_number } }), "owner_forbids")
  end },

  { "set_recipe: машина игрока — спросить; машина помощника — как разбор своего", function()
      C.setup()
      local owned = machine({ x = 3.5, y = 0.5 }, true)
      local own = machine({ x = 5.5, y = 2.5 }, false)
      S.owner_ok = nil
      local r = act("set_recipe", { target = { unit_number = owned.unit_number }, recipe = "iron-gear-wheel" })
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "set-recipe" })
      S.okr(act("set_recipe", { target = { unit_number = own.unit_number }, recipe = "iron-gear-wheel" }))
      S.owner_ok = { "set_recipe" }
      S.okr(act("set_recipe", { target = { unit_number = owned.unit_number }, recipe = "iron-gear-wheel" }))
  end },

  { "mine: дерево по resource — chop; руда не затронута; item: деревья отсекаются, остаётся руда", function()
      C.setup()
      S.add_prototype("entity", { name = "dead-tree", type = "tree", max_health = 20 })
      set_perm("chop", "deny")
      S.err(act("mine", { resource = "dead-tree", count = 1 }), "owner_forbids")
      S.okr(act("mine", { resource = "iron-ore", count = 1 }))
      set_perm("chop", "ask")
      S.owner_ok = nil
      S.err(act("mine", { resource = "dead-tree", count = 1 }), "needs_owner_ok")
  end },

  { "walk/approach: дальше предела от хозяина — walk-far; ближе и без хозяина — нет", function()
      C.setup()
      set_perm("walk-far", "ask")
      S.owner_ok = nil
      S.okr(act("walk", { to = { x = 20, y = 0 } }))
      local r = act("walk", { to = { x = 900, y = 0 } })
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "walk-far" })
      S.err(act("approach", { to = { x = 0, y = 900 } }), "needs_owner_ok")
      set_setting("far-distance", 1000)
      S.okr(act("walk", { to = { x = 900, y = 0 } }))
  end },

  { "build_layout: трата выше предела — spend; dry_run ничего не тратит", function()
      C.setup()
      set_setting("spend-limit", 2)
      S.owner_ok = nil
      local ents = { { name = "wooden-chest", dx = 0, dy = 0 }, { name = "wooden-chest", dx = 2, dy = 0 },
        { name = "wooden-chest", dx = 4, dy = 0 } }
      local r = act("build_layout", { anchor = { x = 5, y = 5 }, entities = ents })
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "spend" })
      S.okr(act("build_layout", { anchor = { x = 5, y = 5 }, entities = ents, dry_run = true }))
  end },

  { "build_ghosts: призраков в области больше предела — spend; с разрешением на spend — принят", function()
      C.setup()
      set_setting("spend-limit", 2)
      local F = require("stubs_f")
      for i = 1, 3 do F.ghost("iron-chest", { x = 10.5 + i, y = 0.5 }) end
      S.owner_ok = nil
      local r = act("build_ghosts", { radius = 20 })
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "spend" })
      S.owner_ok = { "spend" }
      S.okr(act("build_ghosts", { radius = 20, mode = "hand" }))
  end },

  { "reflexes: набор читается без служебных полей и уходит обратно как есть; разрешение на гнёзда — отдельно", function()
      H.setup()
      set_perm("attack-nests", "ask")
      S.owner_ok = { "shoot", "attack_nests" }
      local function set(list) return S.req("reflexes", { set = list }, "h1") end
      local R = require("scripts.core.reflexes")
      local d = S.okr(set{ { type = "shoot" } })
      S.eq(d.set[1].nests_ok, nil)
      S.ok(R.nests_leave("h1"))
      S.owner_ok = nil
      local cur = S.okr(S.req("reflexes", {}, "h1")).set
      S.eq(cur[1].nests_ok, nil)
      cur[#cur + 1] = { type = "ammo" }
      S.okr(set(cur))
      S.ok(R.nests_leave("h1"), "разрешение держится, пока shoot в наборе")
      S.okr(set{ { type = "ammo" } })
      S.ok(not R.nests_leave("h1"), "shoot сняли — разрешения нет")
      set_perm("shoot", "auto")
      S.owner_ok = { "shoot" }
      S.okr(set{ { type = "shoot" } })
      S.ok(not R.nests_leave("h1"), "разрешение на стрельбу — не на гнёзда")
  end },

  { "reflexes: shoot/upkeep — спросить, ammo — сам; уже включённый рефлекс заново не спрашивают", function()
      H.setup()
      S.owner_ok = nil
      local function set(list) return S.req("reflexes", { set = list }, "h1") end
      S.okr(set{ { type = "ammo" } })
      local r = set{ { type = "shoot" } }
      S.err(r, "needs_owner_ok")
      S.eq(r.error.data, { perm = "shoot" })
      S.err(set{ { type = "upkeep" } }, "needs_owner_ok")
      S.owner_ok = { "shoot" }
      S.okr(set{ { type = "shoot" } })
      S.owner_ok = nil
      S.okr(set{ { type = "shoot" }, { type = "ammo" } })
      set_perm("turrets", "deny")
      S.owner_ok = { "shoot", "upkeep" }
      S.okr(set{ { type = "shoot" } })
      S.err(set{ { type = "shoot" }, { type = "upkeep" }, { type = "ammo" } }, "owner_forbids")
      -- nests_ok агент задать не может
      S.err(set{ { type = "shoot", nests_ok = true } }, "bad_args")
  end },

  { "flee: порог по умолчанию — настройка partner-flee-health; свой health важнее", function()
      local _, h = H.setup()
      set_setting("flee-health", 40)
      H.set{ { type = "flee" } }
      H.enemy({ x = -8, y = 0 })
      B.tick(60)
      S.eq(#B.events("reflex_fired"), 0, "при полном здоровье не отступает")
      H.damage(h, 160, nil, "poison") -- 90/250 = 36 %
      S.eq(#B.events("reflex_fired"), 1, "ниже 40 % — отступает")
  end },

  { "flee: свой health в рефлексе важнее настройки", function()
      local _, h = H.setup()
      set_setting("flee-health", 40)
      H.set{ { type = "flee", health = 0.9 } }
      H.enemy({ x = -8, y = 0 })
      B.tick(60)
      S.eq(#B.events("reflex_fired"), 0)
      H.damage(h, 50, nil, "poison") -- 80 %
      S.eq(#B.events("reflex_fired"), 1)
  end },

  { "auto-armor: выключена — слот не заполняется ни рефлексом возрождения, ни auto_wear", function()
      local g = A.grid(10, 10)
      local W = A.setup{ items = { { name = "power-armor-mk2", grid = g } } }
      set_setting("auto-armor", false)
      storage.reflex_state = { h1 = { rearm = { dead_unit = -1 } } }
      C.run(61)
      S.ok(not W.armor[1].valid_for_read, "броня не надета")
      S.eq(#C.events("armor_equipped"), 0)
      set_setting("auto-armor", true)
      C.run(61)
      S.eq(W.armor[1].name, "power-armor-mk2")
  end },

  { "ammo: зазор до турелей по умолчанию — настройка; свой turret_gap важнее", function()
      H.setup()
      set_setting("turret-gap", 7)
      local r = H.set{ { type = "ammo" } }
      S.eq(r[1].turret_gap, nil, "в наборе не хранится, берётся из настройки на ходу")
      local r2 = H.set{ { type = "ammo", turret_gap = 2 } }
      S.eq(r2[1].turret_gap, 2)
  end },
})

-- ------------------------------------------------------------------ shoot по гнёздам и червям

local function ammo_type(effect)
  return function()
    return { action = { type = "direct", action_delivery = { type = "instant", target_effects = { { type = effect } } } } }
  end
end

local function shoot_setup()
  local W = C.setup()
  defines.shooting = defines.shooting or { not_shooting = 0, shooting_enemies = 1, shooting_selected = 2 }
  prototypes.item["submachine-gun"] = { name = "submachine-gun", type = "gun", stack_size = 5, attack_parameters = { range = 18 } }
  prototypes.item["firearm-magazine"] = { name = "firearm-magazine", type = "ammo", stack_size = 200, get_ammo_type = ammo_type("damage") }
  prototypes.entity["small-worm-turret"] = { name = "small-worm-turret", type = "turret", attack_parameters = { range = 25 } }
  prototypes.entity["biter-spawner"] = { name = "biter-spawner", type = "unit-spawner" }
  W.h.get_inventory(defines.inventory.character_guns)[1].set("submachine-gun", 1)
  W.h.get_inventory(defines.inventory.character_ammo)[1].set("firearm-magazine", 10)
  return W
end

local function shooting(W)
  local st = W.h.shooting_state
  return st ~= nil and st.state == defines.shooting.shooting_enemies
end

local function foe(W, name, dx)
  local p = S.norm_pos(W.h.position)
  return S.nauvis.create_entity{ name = name, position = { x = p.x + dx, y = p.y }, force = "enemy" }
end

S.suite("perms_nests", {
  { "attack-nests deny: червь вне радиуса его дальности и гнездо — не цель; червь, под которым стоит тело, — цель", function()
      local W = shoot_setup()
      S.okr(S.req("reflexes", { set = { { type = "shoot" } } }, "h1"))
      local spawner = foe(W, "biter-spawner", 10)
      local worm = foe(W, "small-worm-turret", 28) -- дальность 25: тело вне её радиуса
      C.run(20)
      S.ok(not shooting(W), "ни гнездо, ни далёкий червь")
      worm.destroy()
      foe(W, "small-worm-turret", 12) -- тело в радиусе червя
      C.run(20)
      S.ok(shooting(W), "червь, под ударом которого стоит тело")
      spawner.destroy()
  end },

  { "attack-nests auto: стреляет и по гнезду", function()
      local W = shoot_setup()
      set_perm("attack-nests", "auto")
      S.okr(S.req("reflexes", { set = { { type = "shoot" } } }, "h1"))
      foe(W, "biter-spawner", 10)
      C.run(20)
      S.ok(shooting(W))
  end },

  { "attack-nests ask: только если рефлекс включили с owner_ok", function()
      local W = shoot_setup()
      set_perm("attack-nests", "ask")
      S.owner_ok = nil
      set_perm("shoot", "auto")
      S.okr(S.req("reflexes", { set = { { type = "shoot" } } }, "h1"))
      foe(W, "biter-spawner", 10)
      C.run(20)
      S.ok(not shooting(W), "без разрешения хозяина")
      S.owner_ok = { "attack_nests" }
      S.okr(S.req("reflexes", { set = { { type = "shoot" } } }, "h1"))
      C.run(20)
      S.ok(shooting(W), "включили с owner_ok")
  end },
})
