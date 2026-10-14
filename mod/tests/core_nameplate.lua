-- Подпись над телом помощника и метка на карте (решение автора 14.10).
local S = require("stubs")

local function fake_rendering()
  local drawn = {}
  _G.rendering = {
    draw_text = function(t)
      local o = S.game_object{ args = t }
      drawn[#drawn + 1] = o
      return o
    end,
  }
  return drawn
end

local function fake_tags(force)
  local tags = {}
  rawset(force, "add_chart_tag", function(surface, t)
    local o = S.game_object{ surface = surface, position = { x = t.position.x, y = t.position.y }, text = t.text }
    tags[#tags + 1] = o
    return o
  end)
  return tags
end

S.suite("core_nameplate", {
  { "тело без игрока: подпись над головой и метка на карте с именем; ушёл далеко — метка переставлена", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      local drawn = fake_rendering()
      S.okr(S.req("helper_spawn", {}, "h1"))
      local e = storage.helpers.h1.entity
      local tags = fake_tags(e.force)
      local np = require("scripts.core.nameplate")
      np.refresh_all()
      S.eq(#drawn, 1)
      S.eq(e.color, require("scripts.core.nameplate").COLOR, "тело покрашено в цвет подписи")
      S.eq(drawn[1].args.text, "Claude")
      S.eq(drawn[1].args.target.entity, e)
      S.eq(#tags, 1)
      S.eq(tags[1].text, "Claude")
      np.refresh_all()
      S.eq({ #drawn, #tags }, { 1, 1 }, "ничего не изменилось — ничего не перерисовано")
      local p = e.position
      p.x = p.x + 10 -- тело ушло (в тесте позиция меняется напрямую, телепорт мод запрещает)
      np.refresh_all()
      S.eq(#tags, 2)
      S.eq(tags[1].valid, false, "старая метка убрана")
      S.near(tags[2].position.x, e.position.x, 0.001)
  end },
  { "имя из настройки, скобки вырезаны; у h2 — с id", function()
      S.load_mod()
      settings.global["partner-helper-name"] = { value = "  [Бот] " }
      local np = require("scripts.core.nameplate")
      S.eq(np.display_name("h1"), "Бот")
      S.eq(np.display_name("h2"), "Бот h2")
      settings.global["partner-helper-name"] = { value = "" }
      S.eq(np.display_name("h1"), "Claude")
  end },
  { "помощник удалён — подпись и метка убраны", function()
      S.load_mod()
      S.add_player{ name = "Tartaluga" }
      local drawn = fake_rendering()
      S.okr(S.req("helper_spawn", {}, "h1"))
      local tags = fake_tags(storage.helpers.h1.entity.force)
      local np = require("scripts.core.nameplate")
      np.refresh_all()
      S.okr(S.req("helper_remove", {}, "h1"))
      np.refresh_all()
      S.eq({ drawn[1].valid, tags[1].valid }, { false, false })
      S.eq(storage.nameplates.h1, nil)
  end },
})
