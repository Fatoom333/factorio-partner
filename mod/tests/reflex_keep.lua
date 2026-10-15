-- Срок жизни набора рефлексов. EVENTS.md «Рефлексы v1»: набор хранится в
-- storage.reflexes и ПЕРЕЖИВАЕТ возрождение, перезагрузку сейва и возврат тела-игрока;
-- сбрасывается только helper_remove. `flee.to` по умолчанию "away".
local S = require("stubs")
local B = require("stubs_b")
local H = require("stubs_h")
local P = require("stubs_p")

local SET = { { type = "flee", radius = 6, health = 0.5 }, { type = "watch", every_s = 1 } }
local STORED = {
  { type = "flee", radius = 6, distance = 30, health = 0.5, on_attack = true, to = "away", resume = true, resume_health = 0.8 },
  { type = "watch", radius = 32, every_s = 1 },
}

local function seq() return S.okr(S.req("hello")).seq end

local function count_since(kind, since)
  local n = 0
  for _, e in ipairs(B.events(kind)) do
    if e.seq > since then n = n + 1 end
  end
  return n
end

S.suite("reflex_keep", {
  { "умолчания: flee.to = away, on_attack = true; ответ reflexes — набор как он хранится", function()
      H.setup()
      S.eq(H.set{ { type = "flee" } }, { { type = "flee", radius = 20, distance = 30, health = 1, on_attack = true, to = "away", resume = true, resume_health = 0.8 } })
      S.eq(H.set(SET), STORED)
      S.eq(storage.reflexes.h1, STORED)
      S.eq(require("scripts.core.reflexes").get("h1"), STORED)
      S.eq(require("scripts.core.reflexes").get("nobody"), nil)
  end },

  { "смерть и возрождение: набор тот же и снова работает на новом теле", function()
      local _, h = H.setup()
      S.move(h, { x = 20, y = 0 })
      H.set(SET)
      B.tick(15)
      H.damage(h, 300, H.enemy({ x = 21, y = 0 }))
      S.eq(storage.helpers.h1.state, "dead")
      S.eq(storage.reflexes.h1, STORED, "смерть набор не сбрасывает")
      S.err(S.req("reflexes", { set = {} }, "h1"), "no_helper", "мёртвому набор не поменять")
      S.eq(storage.reflexes.h1, STORED)
      local quiet = seq()
      B.tick(300)
      S.eq(count_since("saw_enemy", quiet), 0, "пока тела нет, проверки не идут")
      local ev = H.wait("respawned")
      S.ok(ev, "возродился: " .. H.kinds())
      S.eq(storage.helpers.h1.state, "alive")
      S.eq(storage.reflexes.h1, STORED, "возрождение набор не сбрасывает")
      -- watch работает на новом теле без повторного reflexes{set}
      local body = H.body()
      H.enemy({ x = body.position.x + 10, y = body.position.y }, "biter-spawner")
      local s0 = seq()
      B.tick(80)
      S.ok(count_since("saw_enemy", s0) >= 1, "watch сработал после возрождения: " .. H.kinds())
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "сохранение и загрузка сейва: набор на месте и работает", function()
      local _, h = H.setup()
      H.set(SET)
      B.tick(25)
      S.reload()
      S.eq(storage.reflexes.h1, STORED)
      H.enemy({ x = h.position.x + 12, y = h.position.y })
      local s0 = seq()
      B.tick(80)
      S.ok(count_since("saw_enemy", s0) >= 1, "watch после загрузки: " .. H.kinds())
      -- обновление мода (on_configuration_changed) набор тоже не трогает
      S.reload{ changed = { mod_changes = { ["factorio-partner"] = { old_version = "0.1.0", new_version = "0.4.0" } } } }
      S.eq(storage.reflexes.h1, STORED)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },

  { "сохранение и загрузка, пока помощник мёртв: после возрождения набор тот же", function()
      local _, h = H.setup()
      H.set(SET)
      B.tick(15)
      H.damage(h, 300, H.enemy({ x = 30, y = 0 }))
      B.tick(100)
      S.reload()
      S.ok(H.wait("respawned"), "возродился после загрузки: " .. H.kinds())
      S.eq(storage.reflexes.h1, STORED)
  end },

  { "helper_remove сбрасывает набор; новое тело с тем же id начинает без рефлексов", function()
      local _, h = H.setup()
      H.set(SET)
      B.tick(5)
      S.okr(S.req("helper_remove", {}, "h1"))
      S.eq(storage.reflexes.h1, nil, "helper_remove — единственное, что сбрасывает набор")
      game.tick = game.tick + 5 * 60 * 60 + 1
      S.okr(S.req("helper_spawn", {}, "h1"))
      S.eq(storage.reflexes.h1, nil)
      H.enemy({ x = 10, y = 0 })
      local s0 = seq()
      B.tick(80)
      S.eq(count_since("saw_enemy", s0), 0, "старый watch на новое тело не перешёл")
  end },

  { "helper_remove мёртвого помощника тоже сбрасывает набор", function()
      local _, h = H.setup()
      H.set(SET)
      B.tick(15)
      H.damage(h, 300, H.enemy({ x = 3, y = 0 }))
      S.eq(storage.reflexes.h1, STORED)
      S.okr(S.req("helper_remove", {}, "h1"))
      S.eq(storage.reflexes.h1, nil)
  end },

  { "набор одного помощника удаление другого не задевает", function()
      H.setup()
      S.okr(S.req("helper_limit", { max = 2 }))
      S.okr(S.req("helper_spawn", {}, "h2"))
      H.set(SET)
      H.set({ { type = "watch" } }, "h2")
      S.okr(S.req("helper_remove", {}, "h2"))
      S.eq(storage.reflexes.h1, STORED)
      S.eq(storage.reflexes.h2, nil)
  end },

  { "тело-игрок: набор переживает выход и возврат игрока, а также смерть и возрождение движком", function()
      local _, friend = P.setup()
      S.add_prototype("entity", { name = "biter-spawner", type = "unit-spawner", max_health = 350 })
      S.eq(S.okr(S.req("reflexes", { set = SET }, "p1")).set, STORED)
      P.tick(5)
      P.leave(friend)
      S.eq(P.rec().state, "away")
      S.eq(storage.reflexes.p1, STORED, "выход игрока набор не сбрасывает")
      local quiet = seq()
      S.nauvis.create_entity{ name = "biter-spawner", position = { x = 30, y = 0 }, force = "enemy" }
      P.tick(100)
      S.eq(count_since("saw_enemy", quiet), 0, "пока игрока нет, проверки не идут")
      P.join(friend)
      S.eq(storage.reflexes.p1, STORED, "возврат игрока набор не сбрасывает")
      local s0 = seq()
      P.tick(80)
      S.ok(count_since("saw_enemy", s0) >= 1, "watch работает после возврата: " .. P.kinds())
      -- смерть и возрождение движком
      P.kill(friend)
      S.eq(storage.reflexes.p1, STORED)
      P.respawn(friend, { x = 22, y = 0 })
      S.eq(storage.reflexes.p1, STORED)
      -- отвязали — набор сброшен
      S.okr(S.req("helper_remove", {}, "p1"))
      S.eq(storage.reflexes.p1, nil)
      S.eq(S.okr(S.req("hello")).module_errors, 0)
  end },
})
