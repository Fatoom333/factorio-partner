-- plan_mining (поток M): поиск пятна (near/area, связность, открытые чанки, лимит), проверка
-- аргументов, выбор построек по умолчанию из открытого исследованиями. ACTIONS.md «plan_mining».
local S = require("stubs")
local C = require("stubs_c")
local X = require("stubs_m")

local function fails(args, code, pattern)
  local d, kind = X.plan(args)
  S.eq(kind, "job_failed", S.dump(d))
  S.eq(d.code, code, S.dump(d))
  if pattern then S.ok(tostring(d.text):find(pattern), "текст: " .. tostring(d.text)) end
  S.eq(#X.ghosts(), 0, "при ошибке призраков нет")
  return d
end

local function has(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

S.suite("mining_args", {
  { "near: берётся только связное пятно вокруг точки", function()
      X.setup()
      local a = X.patch("iron-ore", 0, 0, 12, 9)
      X.patch("iron-ore", 20, 0, 12, 9) -- второе пятно через 8 клеток
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(X.covered(a, "electric-mining-drill"))
      for _, g in ipairs(X.ghosts("electric-mining-drill")) do
        S.ok(g.pos.x < 17, "бур на чужом пятне: " .. S.dump(g.pos))
      end
      S.ok(d.detail.area.right_bottom.x <= 17)
  end },
  { "near: диагональное соседство — то же пятно; пятно шире окна поиска находится целиком", function()
      X.setup()
      local ore = X.patch("iron-ore", 0, 0, 6, 6)
      for _, e in ipairs(X.patch("iron-ore", 6, 6, 80, 6)) do ore[#ore + 1] = e end
      local d, kind = X.plan{ near = { x = 2, y = 2 } }
      S.eq(kind, "job_done", S.dump(d))
      local ok, missed = X.covered(ore, "electric-mining-drill")
      S.ok(ok, "не покрыто клеток: " .. missed)
  end },
  { "near: точка у края пятна — берётся ближайшая руда; другая руда рядом в пятно не входит", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.patch("copper-ore", 12, 0, 6, 9) -- вплотную
      local d, kind = X.plan{ near = { x = -3, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      for _, g in ipairs(X.ghosts("electric-mining-drill")) do
        S.ok(g.pos.x < 14, "бур ушёл на медь: " .. S.dump(g.pos))
      end
  end },
  { "near + resource: ищется названная руда", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local copper = X.patch("copper-ore", 0, 12, 12, 9)
      local d, kind = X.plan{ near = { x = 5, y = 10 }, resource = "copper-ore" }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(X.covered(copper, "electric-mining-drill"))
      for _, g in ipairs(X.ghosts("electric-mining-drill")) do
        S.ok(g.pos.y > 9, "бур на железе: " .. S.dump(g.pos))
      end
  end },
  { "area: вся твёрдая руда в области", function()
      X.setup()
      local ore = X.patch("iron-ore", 0, 0, 12, 9)
      X.patch("iron-ore", 40, 0, 12, 9)
      local d, kind = X.plan{ area = { left_top = { x = -2, y = -2 }, right_bottom = { x = 14, y = 11 } } }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(X.covered(ore, "electric-mining-drill"))
      for _, g in ipairs(X.ghosts("electric-mining-drill")) do S.ok(g.pos.x < 20) end
  end },
  { "руды нет → not_found", function()
      X.setup()
      X.patch("iron-ore", 50, 50, 12, 9)
      fails({ near = { x = 0, y = 0 } }, "not_found")
      fails({ area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 20, y = 20 } } }, "not_found")
      fails({ near = { x = 55, y = 54 }, resource = "copper-ore" }, "not_found")
  end },
  { "жидкость (нефть) — не руда для разметки", function()
      X.setup()
      C.resource("crude-oil", { x = 2.5, y = 2.5 }, 100000)
      fails({ near = { x = 2, y = 2 } }, "not_found")
      fails({ near = { x = 2, y = 2 }, resource = "crude-oil" }, "bad_args", "solid")
  end },
  { "неоткрытые чанки: точка → not_charted; руда в неоткрытом чанке не видна", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.patch("iron-ore", 12, 0, 30, 9) -- продолжение пятна уходит в чанк (1,0)
      local force = game.forces.player
      force.uncharted[S.chunk_key(S.nauvis, { x = 1, y = 0 })] = true
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      for _, g in ipairs(X.ghosts("electric-mining-drill")) do
        S.ok(g.pos.x < 36, "бур в неоткрытом чанке: " .. S.dump(g.pos))
      end
      S.ok(d.detail.area.right_bottom.x <= 36)

      force.uncharted[S.chunk_key(S.nauvis, { x = 0, y = 0 })] = true
      local d2, kind2 = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind2, "job_failed")
      S.eq(d2.code, "not_charted")
      local d3, kind3 = X.plan{ area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 20, y = 20 } } }
      S.eq(kind3, "job_failed")
      S.eq(d3.code, "not_charted")
  end },
  { "пятно больше 128 клеток → limit", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 140, 3)
      fails({ near = { x = 5, y = 1 } }, "limit")
  end },
  { "area и near: ровно одно → иначе bad_args", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      fails({}, "bad_args", "area or near")
      fails({ near = { x = 1, y = 1 }, area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 9, y = 9 } } },
        "bad_args", "area or near")
  end },
  { "схема: неизвестный флаг options, раскладка, сторона, лишнее поле → bad_args при постановке; area > 128 → limit", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local near = { x = 5, y = 4 }
      S.err(C.act("plan_mining", { near = near, options = { turbo = true } }), "bad_args")
      S.err(C.act("plan_mining", { near = near, options = { lamps = "yes" } }), "bad_args")
      S.err(C.act("plan_mining", { near = near, layout = "blueprints" }), "bad_args")
      S.err(C.act("plan_mining", { near = near, direction = "up" }), "bad_args")
      S.err(C.act("plan_mining", { near = near, quality = "legendary" }), "bad_args")
      S.err(C.act("plan_mining", { area = { left_top = { x = 0, y = 0 }, right_bottom = { x = 200, y = 9 } } }), "limit")
  end },
  { "неизвестные имена построек и руды → bad_args", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local near = { x = 5, y = 4 }
      fails({ near = near, resource = "unobtainium" }, "bad_args", "resource")
      fails({ near = near, miner = "iron-chest" }, "bad_args", "miner")
      fails({ near = near, miner = "no-such-drill" }, "bad_args", "miner")
      fails({ near = near, belt = "pipe" }, "bad_args", "belt")
      fails({ near = near, pole = "transport-belt" }, "bad_args", "pole")
      fails({ near = near, pipe = "small-lamp" }, "bad_args", "pipe")
      fails({ near = near, options = { chest = "iron-chest" } }, "bad_args", "chest")
      fails({ near = near, layout = "logistics", options = { chest = "small-lamp" } }, "bad_args", "chest")
  end },
  { "раскладка не подходит буру → bad_args с объяснением", function()
      X.setup{ research = { "electric-mining-drill", "big-mining-drill", "transport-belt", "underground-belt", "small-electric-pole" } }
      X.patch("iron-ore", 0, 0, 12, 9)
      local d = fails({ near = { x = 5, y = 4 }, layout = "super_compact", miner = "big-mining-drill" }, "bad_args")
      S.ok(d.text:find("super_compact") and d.text:find("big%-mining%-drill"), d.text)
      -- столб 2×2 раскладкам не подходит
      fails({ near = { x = 5, y = 4 }, pole = "big-electric-pole" }, "bad_args", "pole")
      -- без явного бура super_compact берёт подходящий (3×3), а не «лучший вообще»
      local d2, kind2 = X.plan{ near = { x = 5, y = 4 }, layout = "super_compact" }
      S.eq(kind2, "job_done", S.dump(d2))
      S.eq(d2.detail.chosen.miner, "electric-mining-drill")
  end },
  { "бур не добывает эту руду → bad_args", function()
      X.setup()
      X.patch("tungsten-ore", 0, 0, 12, 9)
      fails({ near = { x = 5, y = 4 }, miner = "electric-mining-drill" }, "bad_args", "can't mine")
      -- по умолчанию подходящего открытого бура нет
      fails({ near = { x = 5, y = 4 } }, "bad_args", "no researched mining drill")
      X.research("big-mining-drill")
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.chosen.miner, "big-mining-drill")
  end },
  { "по умолчанию — лучшее из открытого исследованиями", function()
      X.setup{ research = { "burner-mining-drill", "electric-mining-drill", "transport-belt", "small-electric-pole" } }
      X.patch("iron-ore", 0, 0, 12, 9)
      local near = { x = 5, y = 4 }
      local d = X.plan{ near = near, dry_run = true }
      S.eq(d.detail.chosen, { miner = "electric-mining-drill", belt = "transport-belt", pole = "small-electric-pole" })

      X.research("fast-transport-belt", "medium-electric-pole", "big-electric-pole", "big-mining-drill")
      d = X.plan{ near = near, dry_run = true }
      S.eq(d.detail.chosen, { miner = "big-mining-drill", belt = "fast-transport-belt", pole = "medium-electric-pole" })
      S.ok(d.detail.need["fast-transport-belt"] > 0)

      -- явные имена важнее умолчаний
      d = X.plan{ near = near, dry_run = true, miner = "electric-mining-drill", belt = "transport-belt",
        pole = "small-electric-pole" }
      S.eq(d.detail.chosen, { miner = "electric-mining-drill", belt = "transport-belt", pole = "small-electric-pole" })
  end },
  { "ничего не открыто: бура нет → bad_args; только твердотопливный бур — без столбов", function()
      X.setup{ research = { "transport-belt" } }
      X.patch("iron-ore", 0, 0, 12, 9)
      fails({ near = { x = 5, y = 4 } }, "bad_args", "no researched mining drill")
      X.research("burner-mining-drill")
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.chosen, { miner = "burner-mining-drill", belt = "transport-belt", pole = "none" })
      S.eq(#X.ghosts("small-electric-pole"), 0)
      S.ok(#X.ghosts("burner-mining-drill") > 0)
  end },
  { "явно названная неоткрытая постройка — предупреждение not_researched", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local d, kind = X.plan{ near = { x = 5, y = 4 }, belt = "fast-transport-belt", dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "not_researched:fast-transport-belt"), S.dump(d.detail.warnings))
  end },
  { "compact без открытой подземной ленты: берётся лента, у которой подземная открыта, иначе bad_args", function()
      X.setup{ research = { "electric-mining-drill", "transport-belt", "fast-transport-belt", "underground-belt", "small-electric-pole" } }
      X.patch("iron-ore", 0, 0, 12, 9)
      local d, kind = X.plan{ near = { x = 5, y = 4 }, layout = "compact", dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.chosen.belt, "transport-belt", "у быстрой ленты подземная не открыта")
      X.forget("underground-belt")
      fails({ near = { x = 5, y = 4 }, layout = "compact", dry_run = true }, "bad_args", "transport belt")
  end },
  { "руда с жидкостью: без исследования → bad_args; с ним — трубы между бурами", function()
      X.setup()
      X.patch("uranium-ore", 0, 0, 12, 9)
      fails({ near = { x = 5, y = 4 } }, "bad_args", "fluid")
      game.forces.player.mining_with_fluid = true
      X.research("pipe-to-ground")
      local d, kind = X.plan{ near = { x = 5, y = 4 } }
      S.eq(kind, "job_done", S.dump(d))
      S.eq(d.detail.chosen.pipe, "pipe")
      S.ok((d.detail.need["pipe"] or 0) + (d.detail.need["pipe-to-ground"] or 0) > 0, S.dump(d.detail.need))
      -- без труб — предупреждение
      S.reset()
      X.setup{ fluid = true }
      X.patch("uranium-ore", 0, 0, 12, 9)
      d, kind = X.plan{ near = { x = 5, y = 4 }, pipe = "none", dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(has(d.detail.warnings, "fluid_needed_no_pipes"), S.dump(d.detail.warnings))
      S.eq(d.detail.need["pipe"], nil)
  end },
  { "options: lamps, coverage, pole=none", function()
      X.setup{ research = { "electric-mining-drill", "transport-belt", "underground-belt", "small-electric-pole", "small-lamp" } }
      X.patch("iron-ore", 0, 0, 12, 9)
      local near = { x = 5, y = 4 }
      local base = X.plan{ near = near, dry_run = true }
      local d = X.plan{ near = near, dry_run = true, options = { lamps = true } }
      S.ok((d.detail.need["small-lamp"] or 0) > 0, S.dump(d.detail.need))
      d = X.plan{ near = near, dry_run = true, options = { coverage = true } }
      S.ok(d.detail.drills >= base.detail.drills)
      d = X.plan{ near = near, dry_run = true, pole = "none" }
      S.eq(d.detail.need["small-electric-pole"], nil)
      S.eq(d.detail.chosen.pole, "none")
      -- флаг, которого у раскладки нет
      fails({ near = near, layout = "super_compact", options = { lamps = true } }, "bad_args", "lamps")
  end },
  { "вода: по умолчанию буры её обходят; landfill — призраки отсыпки под постройками", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      local d0 = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      -- вода под первым буром сухого прогона
      local drill
      for _, c in ipairs(X.checks) do
        if c.name == "electric-mining-drill" then drill = c break end
      end
      X.water{ { math.floor(drill.pos.x), math.floor(drill.pos.y) } }
      local d1 = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(d1.detail.tiles, 0)
      S.ok(d1.detail.drills < d0.detail.drills or d1.detail.need["landfill"] == nil)
      local d2, kind2 = X.plan{ near = { x = 5, y = 4 }, options = { landfill = true } }
      S.eq(kind2, "job_done", S.dump(d2))
      S.eq(d2.detail.tiles, 1)
      S.eq(d2.detail.need["landfill"], 1)
      local tiles = 0
      for _, g in ipairs(X.ghosts()) do
        if g.kind == "tile-ghost" then
          tiles = tiles + 1
          S.eq(g.name, "landfill")
          S.eq(g.force, X.W.h.force)
        end
      end
      S.eq(tiles, 1)
      S.eq(d2.detail.ghosts, #X.ghosts())
  end },
  { "плитки без опоры ищутся по маске бура из прототипа, а не по именам слоёв или плиток (PROTOCOL §6.12)", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      local layers = {}
      for layer in pairs(prototypes.entity["electric-mining-drill"].collision_mask.layers) do layers[#layers + 1] = layer end
      table.sort(layers)
      S.eq(X.tile_masks[#X.tile_masks], layers, "раскладка спрашивает плитки, с которыми сталкивается бур")
      -- у бура из мода другая маска — запрос другой
      prototypes.entity["electric-mining-drill"].collision_mask = { layers = { mod_mist_layer = true } }
      X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(X.tile_masks[#X.tile_masks], { "mod_mist_layer" })
      -- маски нет вовсе: плитки не запрашиваются с пустым фильтром (он вернул бы всё подряд)
      prototypes.entity["electric-mining-drill"].collision_mask = nil
      local n = #X.tile_masks
      local d, kind = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      for i = n + 1, #X.tile_masks do S.ok(#X.tile_masks[i] > 0, "пустой фильтр плиток") end
  end },
  { "avoid_water=false без отсыпки: раскладка плитки не запрашивает и on_liquid не пишет", function()
      X.setup()
      X.patch("iron-ore", 0, 0, 12, 9)
      X.pool(0, 0, 3, 3, "lava")
      -- запросы плиток делает ещё расчёт выходов (маска тела) — их не считаем
      local body = {}
      for layer in pairs(prototypes.entity.character.collision_mask.layers) do body[#body + 1] = layer end
      table.sort(body)
      local d, kind = X.plan{ near = { x = 8, y = 4 }, dry_run = true, options = { avoid_water = false } }
      S.eq(kind, "job_done", S.dump(d))
      for _, mask in ipairs(X.tile_masks) do S.eq(mask, body, "запрос плиток не от расчёта выходов") end
      for _, w in ipairs(d.detail.warnings) do S.ok(not w:find("^on_liquid"), w) end
  end },
  { "рецепт с другим именем, чем предмет, тоже открывает постройку", function()
      X.setup{ research = { "transport-belt", "small-electric-pole" } }
      X.patch("iron-ore", 0, 0, 12, 9)
      X.extra_recipes = { ["drill-from-scrap"] = true }
      game.forces.player.recipes["drill-from-scrap"] = { name = "drill-from-scrap", enabled = true, valid = true }
      local d, kind = X.plan{ near = { x = 5, y = 4 }, dry_run = true }
      S.eq(kind, "job_done", S.dump(d))
      S.ok(X.recipe_searches > 0)
  end },
})
