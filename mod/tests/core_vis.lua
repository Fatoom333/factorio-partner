-- scripts.core.vis: видимость живых данных (PROTOCOL §6.7): видимый чанк ИЛИ ≤ 32 клеток от
-- живого тела помощника; helper_id=nil — только is_chunk_visible.
local S = require("stubs")

local function setup()
  S.load_mod()
  S.add_player{ name = "Tartaluga", position = { x = 0, y = 0 } }
  S.okr(S.req("helper_spawn", {}, "h1"))
  return storage.helpers.h1.entity
end

local function hide(cx, cy) game.forces.player.invisible[S.chunk_key(S.nauvis, { x = cx, y = cy }) ] = true end

S.suite("core_vis", {
  { "без помощника — только is_chunk_visible", function()
      setup()
      local vis = require("scripts.core.vis")
      S.eq(vis.visible(nil, S.nauvis, { x = 5, y = 5 }), true)
      hide(0, 0)
      S.eq(vis.visible(nil, S.nauvis, { x = 5, y = 5 }), false)
      S.eq(vis.visible("h1", S.nauvis, { x = 5, y = 5 }), true, "тело рядом — глаза помощника")
  end },
  { "≤ 32 клеток от тела виден и в невидимом чанке, дальше — нет", function()
      local h = setup()
      local vis = require("scripts.core.vis")
      hide(0, 0); hide(1, 0); hide(2, 0); hide(0, -1); hide(0, -2)
      S.move(h, { x = 10, y = 0 })
      S.eq(vis.visible("h1", S.nauvis, { x = 41, y = 0 }), true, "31 клетка")
      S.eq(vis.visible("h1", S.nauvis, { x = 42, y = 0 }), true, "ровно 32")
      S.eq(vis.visible("h1", S.nauvis, { x = 42.5, y = 0 }), false, "дальше 32")
      S.eq(vis.visible("h1", S.nauvis, { x = 10, y = -32 }), true)
      S.eq(vis.visible("h1", S.nauvis, { x = 10, y = -33 }), false)
      S.eq(vis.visible("h1", S.nauvis, { 11, 1 }), true, "позиция массивом {x, y}")
  end },
  { "видимый чанк виден и далеко от тела (радар, игрок)", function()
      local h = setup()
      local vis = require("scripts.core.vis")
      S.move(h, { x = 0, y = 0 })
      S.eq(vis.visible("h1", S.nauvis, { x = 500, y = 500 }), true)
      hide(15, 15)
      S.eq(vis.visible("h1", S.nauvis, { x = 500, y = 500 }), false)
  end },
  { "мёртвый, удалённый и неизвестный помощник глаз не имеют", function()
      local h = setup()
      local vis = require("scripts.core.vis")
      hide(0, 0)
      S.eq(vis.visible("h1", S.nauvis, { x = 5, y = 5 }), true)
      S.eq(vis.visible("h9", S.nauvis, { x = 5, y = 5 }), false, "нет такого помощника")
      storage.helpers.h1.state = "dead"
      S.eq(vis.visible("h1", S.nauvis, { x = 5, y = 5 }), false, "мёртвый")
      storage.helpers.h1.state = "removed"
      S.eq(vis.visible("h1", S.nauvis, { x = 5, y = 5 }), false, "удалённый")
  end },
  { "другая поверхность: тело нашей поверхности не видит чужую", function()
      local h = setup()
      local vis = require("scripts.core.vis")
      local other = S.surface{ name = "vulcanus" }
      hide(0, 0)
      game.forces.player.invisible[S.chunk_key(other, { x = 0, y = 0 })] = true
      S.eq(vis.visible("h1", other, { x = 5, y = 5 }), false)
      S.eq(vis.visible("h1", S.nauvis, { x = 5, y = 5 }), true)
  end },
  { "viewer кэширует is_chunk_visible по чанкам", function()
      setup()
      local vis = require("scripts.core.vis")
      local force = game.forces.player
      local calls = 0
      local orig = force.is_chunk_visible
      force.is_chunk_visible = function(...) calls = calls + 1 return orig(...) end
      local eyes = vis.viewer(nil, S.nauvis, force)
      for i = 1, 20 do eyes({ x = i, y = 1 }) end
      S.eq(calls, 1, "один чанк — один вызов")
      eyes({ x = 40, y = 1 })
      S.eq(calls, 2)
  end },
})
