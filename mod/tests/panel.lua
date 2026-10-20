-- Панель хозяина (scripts/core/panel.lua): окно, события owner_panel, боевой режим, права.
local S = require("stubs")
local B = require("stubs_b")
local P = require("stubs_panel")

-- права из настроек мода: ключ -> "auto"|"ask"|"deny" (здесь заглушка модуля perms)
local perms_table
local perms_stub = {
  get = function(key) return perms_table[key] or "auto" end,
  -- гейт здесь не проверяется (его покрывает perms.lua): заглушки пропускают всё
  enforce = function() end,
  demand = function() end,
  refusal = function() return nil end,
  check = function() return nil end,
  find = function() return nil end,
  snapshot = function() return {} end,
  leave_set = function() return nil end,
  allowed = function() return false end,
  add = function(keys, key) keys[#keys + 1] = key return keys end,
  add_spend = function(keys) return keys end,
  dig_keys = function(_, keys) return keys or {} end,
  owner_built = function() return false end,
  label = function(key) return "подпись " .. tostring(key) end,
}

local function setup()
  perms_table = {}
  local p, h = B.setup({ load = { replace = { ["scripts.core.perms"] = perms_stub } } })
  P.attach(p)
  return p, h
end

local function panel_events()
  return B.events("owner_panel")
end

local function last_panel()
  local list = panel_events()
  return list[#list]
end

local function el(p, name) return P.find(P.window(p), name) end

local function busy()
  local p, h = setup()
  B.act("wait", { seconds = 600 })
  B.act("wait", { seconds = 5 })
  B.tick(3)
  return p, h
end

S.suite("panel", {
  { "ярлык открывает окно с телом помощника, повторное нажатие и крестик закрывают", function()
      local p = setup()
      S.eq(P.window(p), nil)
      S.ok(P.shortcut(p))
      S.ok(P.window(p) ~= nil)
      S.eq(p.toggled["partner-panel"], true)
      S.ok(el(p, "status_h1") ~= nil, "строка помощника")
      S.ok(el(p, "status_h1").caption:find("свободен", 1, true), el(p, "status_h1").caption)
      P.shortcut(p)
      S.eq(P.window(p), nil)
      S.eq(p.toggled["partner-panel"], false)
      P.hotkey(p)
      S.ok(P.window(p) ~= nil)
      P.click(p, el(p, "partner_panel_close"))
      S.eq(P.window(p), nil)
      S.eq(p.toggled["partner-panel"], false)
      -- чужой ярлык ничего не открывает
      S.fire(defines.events.on_lua_shortcut, { player_index = p.index, prototype_name = "other" })
      S.eq(P.window(p), nil)
  end },

  { "окно: впервые по центру, потом там, куда его перетащили; место за краем экрана — снова по центру", function()
      local p = setup()
      p.display_resolution = { width = 1920, height = 1080 }
      P.shortcut(p)
      local w = P.window(p)
      S.eq(w.auto_center, true)
      S.ok(el(p, "partner_panel_hold") ~= nil, "кнопки окна собраны")
      w.location = { x = 700, y = 300 }
      S.fire(defines.events.on_gui_location_changed, { player_index = p.index, element = w })
      P.shortcut(p)
      P.shortcut(p)
      w = P.window(p)
      S.eq(w.location.x, 700)
      S.eq(w.location.y, 300)
      S.eq(w.auto_center, nil)
      p.display_resolution = { width = 640, height = 480 }
      P.shortcut(p)
      P.shortcut(p)
      S.eq(P.window(p).auto_center, true)
  end },

  { "не хозяин видит только «панель для хозяина»; его нажатия событий не дают", function()
      local owner = setup()
      local guest = P.attach(S.add_player{ name = "Guest", position = { x = 5, y = 5 } })
      P.shortcut(owner)
      local owner_apply = el(owner, "partner_panel_apply")
      local owner_hold = el(owner, "partner_panel_hold")
      local owner_combat = el(owner, "partner_panel_combat")
      local owner_thoughts = el(owner, "partner_panel_thoughts")
      P.shortcut(guest)
      local w = P.window(guest)
      S.ok(w ~= nil)
      S.eq(P.find(w, "partner_panel_apply"), nil)
      S.eq(P.find(w, "status_h1"), nil)
      S.ok(P.find(w, "partner_panel_close") ~= nil)
      -- подделанное событие: элемент окна хозяина, но игрок чужой
      P.click(guest, owner_apply)
      P.click(guest, owner_hold)
      P.check(guest, owner_combat, true)
      P.check(guest, owner_thoughts, true)
      S.eq(#panel_events(), 0)
      S.eq(require("scripts.core.reflexes").get("h1"), nil)
      -- закрыть своё окно чужой может
      P.click(guest, P.find(w, "partner_panel_close"))
      S.eq(P.window(guest), nil)
  end },

  { "число помощников: границы 1..5, «Применить» шлёт scale", function()
      local p = setup()
      P.shortcut(p)
      local n = el(p, "partner_panel_n")
      S.eq(n.caption, "1")
      P.click(p, el(p, "partner_panel_minus"))
      S.eq(n.caption, "1")
      for _ = 1, 7 do P.click(p, el(p, "partner_panel_plus")) end
      S.eq(n.caption, "5")
      P.click(p, el(p, "partner_panel_minus"))
      S.eq(n.caption, "4")
      S.eq(#panel_events(), 0, "кнопки +/- событий не шлют")
      P.click(p, el(p, "partner_panel_apply"))
      local ev = last_panel()
      S.eq(ev.data, { action = "scale", n = 4 })
      S.eq(ev.loud, true)
      S.eq(ev.helper, nil)
  end },

  { "«Все стоп» и «Продолжайте»: тот же путь, что слово хозяина, и события hold/resume", function()
      local p = busy()
      local jobs = require("scripts.core.jobs")
      S.ok(jobs.active("h1") ~= nil)
      P.shortcut(p)
      P.click(p, el(p, "partner_panel_hold"))
      S.eq({ jobs.active("h1"), jobs.queue_len("h1") }, { nil, 0 })
      S.ok(storage.owner_hold.h1 ~= nil)
      S.eq(storage.owner_hold.h1.kind, "stop")
      S.eq(last_panel().data, { action = "hold" })
      S.eq(#B.events("owner_stop"), 1)
      P.click(p, el(p, "partner_panel_resume"))
      S.eq(storage.owner_hold.h1, nil)
      S.eq(last_panel().data, { action = "resume" })
      S.eq(#B.events("owner_resume"), 1)
  end },

  { "флажки: мысли стратега и AUTO с целью", function()
      local p = setup()
      P.shortcut(p)
      P.check(p, el(p, "partner_panel_thoughts"), true)
      S.eq(last_panel().data, { action = "thoughts", on = true })
      P.check(p, el(p, "partner_panel_thoughts"), false)
      S.eq(last_panel().data, { action = "thoughts", on = false })
      -- AUTO без цели
      P.check(p, el(p, "partner_panel_auto"), true)
      S.eq(last_panel().data, { action = "auto", on = true })
      -- цель уходит по Enter при включённом AUTO; текст чистится и режется
      local goal = el(p, "partner_panel_goal")
      P.type_text(p, goal, "  построить\nплавильню  ")
      S.eq(#panel_events(), 3, "ввод текста событий не шлёт")
      P.confirm(p, goal)
      S.eq(last_panel().data, { action = "auto", on = true, goal = "построить плавильню" })
      P.type_text(p, goal, string.rep("я", 500))
      P.confirm(p, goal)
      S.eq(#last_panel().data.goal, 200 * 2, "200 символов UTF-8")
      P.check(p, el(p, "partner_panel_auto"), false)
      S.eq(last_panel().data, { action = "auto", on = false })
      -- с выключенным AUTO Enter события не шлёт
      local n = #panel_events()
      P.confirm(p, goal)
      S.eq(#panel_events(), n)
      -- состояние переживает закрытие и открытие
      P.check(p, el(p, "partner_panel_thoughts"), true)
      P.shortcut(p)
      P.shortcut(p)
      S.eq(el(p, "partner_panel_thoughts").state, true)
      S.eq(el(p, "partner_panel_auto").state, false)
  end },

  { "боевой режим: shoot и ammo всем телам, остальные рефлексы целы; выключение снимает только их", function()
      local p = setup()
      local refl = require("scripts.core.reflexes")
      S.okr(S.req("reflexes", { set = { { type = "flee" }, { type = "ammo", min = 33 } } }, "h1"))
      P.shortcut(p)
      S.eq(el(p, "partner_panel_combat").state, false)
      P.check(p, el(p, "partner_panel_combat"), true)
      local kinds = {}
      for _, r in ipairs(refl.get("h1")) do kinds[r.type] = r end
      S.ok(kinds.flee and kinds.shoot and kinds.ammo, S.dump(refl.get("h1")))
      S.eq(kinds.ammo.min, 33, "параметры уже стоящего ammo сохранены")
      S.eq(last_panel().data, { action = "combat", on = true })
      S.eq(el(p, "partner_panel_combat").state, true)
      -- после переоткрытия окно знает, что режим включён
      P.shortcut(p)
      P.shortcut(p)
      S.eq(el(p, "partner_panel_combat").state, true)
      P.check(p, el(p, "partner_panel_combat"), false)
      local left = {}
      for _, r in ipairs(refl.get("h1")) do left[#left + 1] = r.type end
      S.eq(left, { "flee" })
      S.eq(last_panel().data, { action = "combat", on = false })
  end },

  { "боевой режим: служебное поле старого сейва в наборе (nests_ok у shoot) не ломает включение", function()
      local p = setup()
      local refl = require("scripts.core.reflexes")
      S.okr(S.req("reflexes", { set = { { type = "shoot" }, { type = "flee" } } }, "h1"))
      refl.get("h1")[1].nests_ok = true
      P.shortcut(p)
      P.check(p, el(p, "partner_panel_combat"), true)
      local kinds = {}
      for _, r in ipairs(refl.get("h1")) do kinds[r.type] = r end
      S.ok(kinds.flee and kinds.shoot and kinds.ammo, S.dump(refl.get("h1")))
      S.eq(kinds.shoot.nests_ok, nil)
      S.eq(el(p, "partner_panel_combat").state, true)
  end },

  { "боевой режим уважает запрет в настройках: рефлекс не включается, окно пишет почему", function()
      local p = setup()
      local refl = require("scripts.core.reflexes")
      perms_table["perm-shoot"] = "deny"
      P.shortcut(p)
      P.check(p, el(p, "partner_panel_combat"), true)
      local left = {}
      for _, r in ipairs(refl.get("h1")) do left[#left + 1] = r.type end
      S.eq(left, { "ammo" })
      S.eq(last_panel().data, { action = "combat", on = true, denied = { "shoot" } })
      local note = el(p, "partner_panel_note").caption
      S.eq(note[1], "partner-panel.note-denied")
      S.eq(note[2], "shoot")
      S.eq(el(p, "partner_panel_combat").state, true)
      -- запрещено всё: режим не включается
      perms_table["perm-turrets"] = "deny"
      S.okr(S.req("reflexes", { set = {} }, "h1"))
      P.check(p, el(p, "partner_panel_combat"), true)
      S.eq(refl.get("h1"), {})
      S.eq(el(p, "partner_panel_combat").state, false)
      S.eq(last_panel().data, { action = "combat", on = false, denied = { "shoot", "ammo" } })
      -- «спросить» не запрещает: это слово хозяина
      perms_table = { ["perm-shoot"] = "ask", ["perm-turrets"] = "ask" }
      P.check(p, el(p, "partner_panel_combat"), true)
      S.eq(#refl.get("h1"), 2)
  end },

  { "охрана: строка окна, радиус 50, «нельзя» в настройках — отказ с причиной; тела нет — окно пишет почему", function()
      local p = setup()
      local refl = require("scripts.core.reflexes")
      P.shortcut(p)
      S.eq(el(p, "partner_panel_guard_r").text, "50")
      S.ok(el(p, "partner_panel_unguard") ~= nil)
      S.eq(el(p, "partner_panel_guard_who").selected_index, 1, "по умолчанию — ближайшее тело")
      perms_table["perm-build"] = "deny"
      P.click(p, el(p, "partner_panel_guard"))
      S.eq(last_panel().data.refused, "owner_forbids")
      local note = el(p, "partner_panel_note").caption
      S.eq({ note[1], note[2] }, { "partner-panel.note-guard-denied", "подпись build" })
      S.eq(refl.get("h1"), nil, "охрана не включена")
      perms_table = { ["perm-build"] = "ask", ["perm-deconstruct-owner"] = "ask" }
      P.click(p, el(p, "partner_panel_guard"))
      S.eq(last_panel().data, { action = "guard", helper = "h1", center = { x = 0, y = 0 }, radius = 50 })
      S.eq(refl.get("h1")[1].type, "evacuate")
      S.okr(S.req("helper_remove", {}, "h1"))
      B.tick(61)
      P.click(p, el(p, "partner_panel_guard"))
      S.eq(last_panel().data, { action = "guard", refused = "no_helper" })
      S.eq(el(p, "partner_panel_note").caption[1], "partner-panel.note-no-body")
  end },

  { "раз в секунду статусы обновляются, список тел изменился — окно собирается заново", function()
      local p = setup()
      P.shortcut(p)
      S.ok(el(p, "status_h1").caption:find("свободен", 1, true))
      B.act("wait", { seconds = 600 })
      B.tick(61)
      S.ok(el(p, "status_h1").caption:find("жду", 1, true), el(p, "status_h1").caption)
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h2"))
      B.tick(61)
      S.ok(el(p, "status_h2") ~= nil, "строка нового тела")
      S.eq(el(p, "partner_panel_n").caption, "1", "выбранное число помощников не сбрасывается")
      S.okr(S.req("helper_remove", {}, "h2"))
      B.tick(61)
      S.eq(P.find(P.window(p), "status_h2"), nil)
  end },

  { "окно закрыли не мы: ярлык отпускается; убранный игрок забывается", function()
      local p = setup()
      P.shortcut(p)
      P.window(p).destroy()
      B.tick(61)
      S.eq(p.toggled["partner-panel"], false)
      S.eq(storage.panel[p.index].open, false)
      S.fire(defines.events.on_player_removed, { player_index = p.index })
      S.eq(storage.panel[p.index], nil)
  end },

  { "сохранение и загрузка: состояние окна в storage без функций", function()
      local p = setup()
      P.shortcut(p)
      P.check(p, el(p, "partner_panel_thoughts"), true)
      S.reload()
      S.eq(storage.panel[p.index].thoughts, true)
      S.eq(storage.panel[p.index].open, true)
  end },
})
