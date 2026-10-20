-- Действие `build_blueprint`: разложить чертёж призраками и построить их.
-- Контракт: docs/ACTIONS.md («build_blueprint»), PROTOCOL.md §4 (blob_put), §6.5, §6.12, §7.
-- Оценка, поиск места, постановка и уборка пометок — общие с build_layout: scripts/lib/blueprint.lua.
--
-- args: blob (id из blob_put), anchor (центр чертежа), direction? = 0 (0/4/8/12),
--       auto_supply? = false (предметы кончились — добыть недостающее как `get_items`, как у build_ghosts),
--       mode? = "auto"│"hand"│"robots" (кто строит), force? = "forced" (как ставится чертёж:
--       "normal" — клик, "forced" — Shift, "superforced" — Ctrl+Shift),
--       search? = 16 (0..32, радиус поиска сдвига `fit`; 0 — не искать), rotate? = false (в поиске
--       сдвига перебирать ещё повороты и зеркало), partial? = false (ставить обрезанный чертёж),
--       mirror? = false (поставить чертёж зеркально — так, как сказал `fit.mirror`), dry_run? = false.
-- done.detail: {ghosts, tiles:int, skipped:[{name,pos,reason}], skipped_total, tiles_skipped,
--               on_liquid:int, liquids?:{плитка: число}, fit?, to_remove:[{name,pos}], to_remove_total,
--               missing, + после стройки поля build_ghosts: built, tiles_built, left, removed, …}.
-- Ход: строка из storage.blobs → game.create_inventory(1) → import_stack (1 → bad_args; -1 —
-- импорт с предупреждениями — принимается; книги и планировщики → bad_args) → для каждой
-- сущности проверка постановки призрака (manual_ghost, §6.5) →
-- build_blueprint{build_mode = defines.build_mode[force], skip_fog_of_war = false} создаёт
-- призраки построек и плиток (и, в режимах forced/superforced, помечает помехи к сносу) →
-- inventory.destroy() → дальше как build_ghosts по площади чертежа: снос помеченного, плитки,
-- постройки.
--
-- Плитки без опоры (вода, лава, мазут, плитки планет из модов) — по правилам из игры (PROTOCOL
-- §6.12), имён плиток здесь нет:
-- * клетка «без опоры» для постройки — та, где маска плитки пересекается с маской постройки;
-- * подложка возможна — у плитки есть default_cover_tile, и предмет подложки открыт силе либо уже
--   есть у помощника или на складах: тогда в forced/superforced призрак подложки ставит сам движок,
--   помощник кладёт её из инвентаря;
-- * подложка невозможна хотя бы под одной клеткой (forced/superforced) → чертёж НЕ ставится вовсе:
--   failed{cannot_place}, detail.on_liquid (число таких клеток), detail.liquids {плитка: число},
--   detail.fit — ближайший сдвиг, при котором чертёж встаёт целиком: {anchor, shift:{dx,dy},
--   direction?, mirror?} (нет поля — не нашлось). Поиск — по кольцам вокруг anchor в пределах
--   search клеток, в несколько тиков (бюджет работы на тик и на весь поиск); с rotate:true
--   перебираются ещё повороты и зеркало. dry_run отдаёт то же без ошибки;
-- * partial:true (только по согласию хозяина) — чертёж ставится обрезанным: такие клетки идут в
--   skipped с reason "liquid";
-- * normal (клик) подложку не ставит никогда, поэтому любая клетка на плитке без опоры для него
--   «без возможной подложки»: чертёж так же не ставится и ищется сдвиг.
--
-- Пометки к сносу, которые поставила сама задача (forced/superforced), она снимает при failed,
-- cancel и stuck (M.stop → cancel_deconstruction): иначе дроны хозяина снесут помеченное без замены.
-- После постановки каждый свой призрак постройки проверяется ghost_revive: заблокированный (над
-- ним дроны висели бы вечно) и призрак не-normal качества сразу убираются и попадают в skipped.
-- Призрак, который ждёт плитку под собой или сноса помеченного, заблокированным не считается.
-- to_remove — что помечено к сносу этой постановкой (после неё — по факту; в dry_run — оценка:
-- деревья и камни на местах построек, а для superforced — ещё и постройки своей силы).
-- dry_run — только проверки, призраков и пометок нет.
-- Ошибки: bad_args (blob, не чертёж, пустой, direction), limit (> 1000 сущностей, > 4000 плиток,
-- сторона > 128), not_charted, reserved, cannot_place (ничего не встало либо клетки без подложки),
-- дальше — как build_ghosts.
local err = require("scripts.core.err")
local blobs = require("scripts.core.blobs")
local reserve = require("scripts.core.reserve")
local B = require("scripts.lib.build")
local G = require("scripts.lib.getitems")
local BP = require("scripts.lib.blueprint")

local perms = require("scripts.core.perms")

local M = {}
M.name = "build_blueprint"

--- Сколько предметов уйдёт на сущности и плитки чертежа: по одному на каждую и все запросы
--- предметов (BlueprintEntity.items: id + items.in_inventory[].count).
function M.spend_of(entities, tiles)
  local n = 0
  for _, e in ipairs(entities or {}) do
    n = n + 1
    if type(e) == "table" and type(e.items) == "table" then
      for _, req in ipairs(e.items) do
        local places = type(req) == "table" and type(req.items) == "table" and req.items.in_inventory or nil
        if type(places) == "table" then
          for _, pl in ipairs(places) do
            n = n + ((type(pl) == "table" and type(pl.count) == "number") and pl.count or 1)
          end
        end
      end
    end
  end
  return n + #(tiles or {})
end

--- Разрешения хозяина (scripts/core/perms.lua): какие ключи задевают эти аргументы.
--- Трату (perm-spend) по аргументам не узнать — чертёж ещё в blob: её проверяет start по тому,
--- что ставится на самом деле (по задаче: perm_gate и owner_ok), до первого призрака.
function M.perms(a, ctx)
  if a.dry_run then return {} end
  if a.force == "superforced" then return { "perm-build", "perm-superforced" } end
  return { "perm-build" }
end
M.schema = {
  blob = { type = "string", required = true, max = 32, pattern = "^[a-z0-9%-]+$" },
  anchor = { type = "pos", required = true },
  direction = { type = "int", min = 0, max = 15, default = 0 },
  mode = { type = "enum", values = { "auto", "hand", "robots" }, default = "auto" },
  force = { type = "enum", values = { "normal", "forced", "superforced" }, default = "forced" },
  search = { type = "int", min = 0, max = 32, default = 16 },
  rotate = { type = "bool", default = false },
  partial = { type = "bool", default = false },
  mirror = { type = "bool", default = false },
  dry_run = { type = "bool", default = false },
  auto_supply = { type = "bool", default = false },
}
M.MAX_ENTITIES = 1000
M.MAX_TILES = 4000
M.MAX_SIDE = 128
M.SHORT_LIST = 10    -- длина списков в detail, когда заполнены все три
-- Поиск сдвига: «работа» одного кандидата ≈ FIT_BASE + число сущностей и плиток чертежа (и ещё
-- столько же ×FIT_FULL, если дошло до полной проверки can_place_entity).
M.FIT_OPS_TICK = 2000     -- работы за тик
M.FIT_MAX_OPS = 600000    -- работы на весь поиск (≈ 5 с); исчерпано — fit нет, detail.fit_limit
M.FIT_BASE = 10
M.FIT_FULL = 4

M.MATCH_DIST = BP.MATCH_DIST
M.PAD = BP.PAD
M.layout = BP.layout
M.ring = BP.ring
M.mirror_dir = BP.mirror_dir

local area_of = BP.area_of
local with_blueprint = BP.with_blueprint
local can_mirror = BP.can_mirror
local mirror_stack = BP.mirror_stack
local plain_source = BP.plain_source
local new_env = BP.new_env
local wet_cells = BP.wet_cells
local tiles_check = BP.tiles_check
local precheck = BP.precheck
local summary = BP.summary
local ring = BP.ring
local unmark = BP.unmark

-- ------------------------------------------------------------------ поиск сдвига (fit)

--- Положения чертежа, которые перебирает поиск: заданное первым; с rotate — ещё повороты и зеркало.
local function orientations(a, src)
  return BP.orientations(a, a.rotate and can_mirror(src.entities))
end

--- Чертёж встаёт целиком в этом положении? → bool, потраченная «работа».
--- Сначала дешёвая проверка плиток под клетками (без can_place_entity), потом полная оценка.
local function try_fit(ctx, src, anchor, o, mode, env)
  local h = ctx.entity
  local plan, tplan = M.layout(src.entities, anchor, o.dir, src.tiles, o.mirror)
  local size = #plan + #tplan
  local used = M.FIT_BASE + size
  local bp_cells, wet = tiles_check(h, tplan, env, nil)
  if wet then return false, used end
  for _, it in ipairs(plan) do
    if it.proto ~= nil then
      local _, _, bad = wet_cells(h, it, bp_cells, env, mode)
      if bad then return false, used end
    end
  end
  local area = area_of(plan, tplan, M.PAD)
  if not B.area_charted(h, area) or reserve.area_holder(ctx.helper_id, area) ~= nil then return false, used end
  used = used + size * M.FIT_FULL
  for _, t in ipairs(tplan) do t.have, t.skip, t.liquid = nil, nil, nil end
  local pre = precheck(h, plan, tplan, mode, env)
  if pre.on_liquid > 0 or pre.tiles_skipped > 0 then return false, used end
  for _, it in ipairs(plan) do
    -- unknown и quality от места не зависят — сдвигом их не вылечить, «целиком» считается без них
    if it.reason ~= nil and it.reason ~= "unknown" and it.reason ~= "quality" then return false, used end
  end
  return true, used
end

--- Итог задачи, когда под чертежом есть клетки без возможной подложки: dry_run — done, иначе
--- failed{cannot_place}; в detail — оценка (task.bp), fit и, если поиск оборван бюджетом, fit_limit.
local function liquid_result(task, fit, limited)
  local d = task.bp
  d.fit = fit
  if limited then d.fit_limit = true end
  -- fit_checked есть всегда, когда чертёж не встал из-за плиток без опоры (0 — поиск не шёл,
  -- search = 0). JSON из Lua не несёт null: сдвиг не найден = fit_checked есть, а fit нет; поле
  -- `fit: null` по этому признаку дописывает сервер (ACTIONS.md, уточнения 3.4).
  local f = task.fit
  d.fit_checked = f ~= nil and f.checked or 0
  task.fit = nil
  if task.args.dry_run then return B.done(d) end
  return B.failed("cannot_place", "blueprint has " .. tostring(d.on_liquid) ..
    " cell(s) on a tile that cannot be covered; nothing was placed", d)
end

local function fit_tick(task, ctx)
  local a, f = task.args, task.fit
  local env = new_env(ctx.entity)
  -- кэш «подложка доступна» — один на весь поиск (простые данные в task.fit): иначе при закрытом
  -- рецепте каждый тик заново перебирались бы все рецепты игры
  f.cover = f.cover or {}
  env.cover = f.cover
  local list = orientations(a, f.src)
  local budget = M.FIT_OPS_TICK
  local cells = ring(f.r)
  task.progress_tick = ctx.tick   -- законно стоим на месте: идёт расчёт
  while budget > 0 do
    -- следующий кандидат (первый — сдвиг 0 в заданном положении — уже проверен в start)
    f.o = f.o + 1
    if f.o > #list then
      f.o = 1
      f.i = f.i + 1
      if f.i > #cells then
        f.i = 1
        f.r = f.r + 1
        if f.r > a.search then return liquid_result(task, nil, false) end
        cells = ring(f.r)
        task.progress = { done = f.r, total = a.search }
      end
    end
    local sh, o = cells[f.i], list[f.o]
    local anchor = { x = a.anchor.x + sh.dx, y = a.anchor.y + sh.dy }
    local ok, used = try_fit(ctx, f.src, anchor, o, a.force, env)
    budget = budget - used
    f.ops = f.ops + used
    f.checked = f.checked + 1
    if ok then
      local fit = { anchor = { x = anchor.x, y = anchor.y }, shift = { dx = sh.dx, dy = sh.dy } }
      if a.rotate then fit.direction, fit.mirror = o.dir, o.mirror and true or false end
      return liquid_result(task, fit, false)
    end
    if f.ops >= M.FIT_MAX_OPS then return liquid_result(task, nil, true) end
  end
  return nil
end

-- ------------------------------------------------------------------ постановка

--- Поставить чертёж движком и сверить. → {summary, area, n_tiles} │ {rolled_back = true, summary}.
local function place(task, ctx, st, plan, tplan, area, pre)
  local a = task.args
  return BP.place(task, ctx, st, plan, tplan, area, pre, {
    position = a.anchor, direction = a.direction, build_mode = a.force, partial = a.partial,
  })
end


function M.start(task, ctx)
  local a, h = task.args, ctx.entity
  if a.direction % 4 ~= 0 then
    return B.failed("bad_args", "args.direction: a blueprint turns only by 0, 4, 8 or 12")
  end
  local str, received, total = blobs.get(a.blob)
  if str == nil then
    return B.failed("bad_args", "args.blob: blob " .. a.blob .. " is not complete (" ..
      tostring(received) .. "/" .. tostring(total) .. " parts); send it with blob_put")
  end

  local out = with_blueprint(str, function(st)
    local count = st.get_blueprint_entity_count()
    local bp_tiles = st.get_blueprint_tiles()
    if type(bp_tiles) ~= "table" then bp_tiles = {} end
    if count == 0 and #bp_tiles == 0 then err.raise("bad_args", "args.blob: blueprint has no entities and no tiles") end
    if count > M.MAX_ENTITIES then
      err.raise("limit", "blueprint has " .. count .. " entities (≤ " .. M.MAX_ENTITIES .. ")")
    end
    if #bp_tiles > M.MAX_TILES then
      err.raise("limit", "blueprint has " .. #bp_tiles .. " tiles (≤ " .. M.MAX_TILES .. ")")
    end
    local entities = count > 0 and st.get_blueprint_entities() or {}
    if type(entities) ~= "table" then entities = {} end
    if not a.dry_run then
      -- трата по тому чертежу, что ставится на самом деле (perm-spend; по задаче: perm_gate и owner_ok)
      local pcode, ptext, pdata = perms.refusal(perms.add_spend({}, M.spend_of(entities, bp_tiles)), task)
      if pcode ~= nil then return { refused = B.failed(pcode, ptext, pdata) } end
    end
    if a.mirror and not can_mirror(entities) then
      err.raise("bad_args", "args.mirror: a blueprint with rails, train stops or storage tanks is not mirrored")
    end
    local plan, tplan = M.layout(entities, a.anchor, a.direction, bp_tiles, a.mirror)
    if #plan == 0 and #tplan == 0 then err.raise("bad_args", "args.blob: blueprint has no entities and no tiles") end
    local area = area_of(plan, tplan)
    if area.right_bottom.x - area.left_top.x > M.MAX_SIDE or area.right_bottom.y - area.left_top.y > M.MAX_SIDE then
      err.raise("limit", "blueprint is larger than " .. M.MAX_SIDE .. " tiles")
    end
    if not B.area_charted(h, area) then err.raise("not_charted", "blueprint area is in uncharted chunks") end
    local env = new_env(h)
    local pre = precheck(h, plan, tplan, a.force, env)
    if pre.on_liquid > 0 and not a.partial then
      -- клетки без возможной подложки: чертёж не ставится вовсе, ищем сдвиг (ACTIONS.md)
      B.check_free(ctx, area)
      return { liquid = true, summary = summary(h, plan, tplan, pre), src = plain_source(entities, bp_tiles),
        cover = env.cover }
    end
    if a.dry_run then
      B.check_free(ctx, area)
      local s, n_tiles = summary(h, plan, tplan, pre)
      return { summary = s, n_tiles = n_tiles }
    end
    B.hold_area(ctx, area)
    if a.mirror then mirror_stack(st, entities, bp_tiles) end
    return place(task, ctx, st, plan, tplan, area, pre)
  end)

  if out.refused then return out.refused end
  local s = out.summary
  task.bp = s
  if out.liquid then
    if a.search > 0 then
      task.fit = { src = out.src, r = 0, i = 1, o = 1, ops = 0, checked = 0, cover = out.cover }
      task.progress = { done = 0, total = a.search }
      return nil
    end
    return liquid_result(task, nil, false)
  end
  if a.dry_run then return B.done(s) end
  if out.rolled_back then
    return B.failed("cannot_place", "the engine placed no cover tile under " .. tostring(s.on_liquid) ..
      " cell(s); the blueprint was taken back", s)
  end
  if s.ghosts == 0 and out.n_tiles == 0 then
    return B.failed("cannot_place", "no ghost of the blueprint could be placed", s)
  end
  return B.ghosts_start(task, ctx, out.area, a.mode)
end

local function merged(task, res)
  local d = res.detail or {}
  local s = task.bp or {}
  d.ghosts, d.skipped, d.skipped_total = s.ghosts, s.skipped, s.skipped_total
  d.tiles, d.tiles_skipped, d.to_remove, d.to_remove_total = s.tiles, s.tiles_skipped, s.to_remove, s.to_remove_total
  d.on_liquid, d.liquids = s.on_liquid, s.liquids
  -- три списка по 20 записей не влезают в событие (data ≤ 4000 байт, EVENTS.md) — тогда каждый
  -- урезается до M.SHORT_LIST; полные числа остаются в *_total
  local n = #(d.skipped or {}) + #(d.blocked or {}) + #(d.to_remove or {})
  if n > M.SHORT_LIST * 3 then
    for _, key in ipairs({ "skipped", "blocked", "to_remove" }) do
      local list = d[key]
      if type(list) == "table" and #list > M.SHORT_LIST then
        local short = {}
        for i = 1, M.SHORT_LIST do short[i] = list[i] end
        d[key] = short
      end
    end
  end
  res.detail = d
  return res
end

function M.tick(task, ctx)
  if task.fit ~= nil then return fit_tick(task, ctx) end
  local pre = G.pre_tick(task, ctx)
  if pre == nil then return nil end
  if pre ~= false then return merged(task, G.build_failed(task, pre)) end
  local r = B.ghosts_tick(task, ctx)
  if r == nil then return nil end
  if r.status == "failed" and r.code == "no_items" and G.start_for_build(task, ctx, r) then return nil end
  return merged(task, r)
end

--- Отмена, сбой, застревание: снять свои пометки к сносу, подход, переключатель дронов.
--- Пометки снимаются первыми и без тела помощника (stop зовётся и после его смерти).
--- → {unmarked = N}, если задача ставила пометки: ядро дописывает это в detail события job_failed
--- (failed от самой задачи, cancel, stuck — ACTIONS.md, уточнения 3.4).
function M.stop(task, ctx)
  G.stop(task, ctx)
  unmark(task)
  task.fit = nil
  if task.g ~= nil then B.ghosts_stop(task, ctx) else B.stop_approach(task, ctx) end
  if task.unmarked ~= nil then return { unmarked = task.unmarked } end
  return nil
end

return M
