-- Рефлекс shoot: выбор ствола по дальности из игры, неоружие (наноботы) не берётся,
-- огонь не у своих построек, skip.
local S = require("stubs")
local C = require("stubs_c")

local function ammo_type(effect, delivery)
  return function()
    return { action = { type = "direct", action_delivery = { type = delivery or "instant",
      target_effects = { { type = effect } } } } }
  end
end

local function setup()
  local W = C.setup()
  defines.shooting = defines.shooting or { not_shooting = 0, shooting_enemies = 1, shooting_selected = 2 }
  local I = prototypes.item
  I["nano-gun"] = { name = "nano-gun", type = "gun", stack_size = 5, attack_parameters = { range = 30 } }
  I["submachine-gun"] = { name = "submachine-gun", type = "gun", stack_size = 5, attack_parameters = { range = 18 } }
  I["flamethrower"] = { name = "flamethrower", type = "gun", stack_size = 5, attack_parameters = { range = 15, min_range = 3 } }
  I["nano-ammo"] = { name = "nano-ammo", type = "ammo", stack_size = 100, get_ammo_type = ammo_type("script") }
  I["firearm-magazine"] = { name = "firearm-magazine", type = "ammo", stack_size = 200, get_ammo_type = ammo_type("damage") }
  I["flamethrower-ammo"] = { name = "flamethrower-ammo", type = "ammo", stack_size = 100,
    get_ammo_type = ammo_type("create-fire", "stream") }
  prototypes.entity["small-biter"] = { name = "small-biter", type = "unit" }
  local guns = W.h.get_inventory(defines.inventory.character_guns)
  local ammo = W.h.get_inventory(defines.inventory.character_ammo)
  guns[1].set("nano-gun", 1); ammo[1].set("nano-ammo", 10)
  guns[2].set("submachine-gun", 1); ammo[2].set("firearm-magazine", 10)
  guns[3].set("flamethrower", 1); ammo[3].set("flamethrower-ammo", 10)
  return W
end

local function set(list) return S.okr(S.req("reflexes", { set = list }, "h1")).set end

local function foe(W, dx)
  local p = S.norm_pos(W.h.position)
  return S.nauvis.create_entity{ name = "small-biter", position = { x = p.x + dx, y = p.y }, force = "enemy" }
end

S.suite("reflex_shoot", {
  { "вблизи — огнемёт, дальше — пулемёт; стреляет по позиции врага; шумное reflex_fired", function()
      local W = setup()
      set{ { type = "shoot" } }
      local b = foe(W, 10)
      C.run(20)
      S.eq(W.h.selected_gun_index, 3, "огнемёт")
      S.eq(W.h.shooting_state.state, defines.shooting.shooting_enemies)
      S.eq(S.norm_pos(W.h.shooting_state.position), S.norm_pos(b.position))
      b.destroy()
      foe(W, 17)
      C.run(20)
      S.eq(W.h.selected_gun_index, 2, "пулемёт")
      local f = C.events("reflex_fired")
      S.ok(#f >= 2 and f[1].data.type == "shoot" and f[1].loud == false, S.dump(f))
  end },
  { "достают только наноботы (не оружие) — не стреляет; враг ушёл — стрельба выключена", function()
      local W = setup()
      set{ { type = "shoot" } }
      local b = foe(W, 10)
      C.run(20)
      S.eq(W.h.shooting_state.state, defines.shooting.shooting_enemies)
      b.destroy()
      foe(W, 25)
      C.run(20)
      S.eq(W.h.shooting_state.state, defines.shooting.not_shooting)
  end },
  { "огонь не у своих построек; skip убирает ствол", function()
      local W = setup()
      set{ { type = "shoot" } }
      local b = foe(W, 10)
      local p = S.norm_pos(b.position)
      C.chest({ x = p.x + 2, y = p.y }, {})
      C.run(20)
      S.eq(W.h.selected_gun_index, 2, "рядом свой сундук — пулемёт вместо огнемёта")
      set{ { type = "shoot", skip = { "submachine-gun" }, fire_near_own = false } }
      C.run(20)
      S.eq(W.h.shooting_state.state, defines.shooting.not_shooting, "огнемёт нельзя, пулемёт в skip")
  end },
  { "рефлекса нет — не стреляет", function()
      local W = setup()
      foe(W, 10)
      C.run(30)
      S.ok(W.h.shooting_state == nil or W.h.shooting_state.state ~= defines.shooting.shooting_enemies)
  end },
})
