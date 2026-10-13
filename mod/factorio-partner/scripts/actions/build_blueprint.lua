-- Действие `build_blueprint` (поток F): разложить чертёж призраками и построить их.
-- Контракт: docs/ACTIONS.md («build_blueprint»), PROTOCOL.md §4 (blob_put), §6.5, §6.12, §7.
--
-- args: blob (id из blob_put), anchor (центр чертежа), direction? = 0 (0/4/8/12),
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
-- * normal (клик) подложку не ставит никогда: клетка на плитке без опоры — в skipped с reason
--   "liquid", как любая другая помеха этого режима (чертёж при этом не отменяется).
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
local util = require("scripts.core.util")
local blobs = require("scripts.core.blobs")
local reserve = require("scripts.core.reserve")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")

local M = {}
M.name = "build_blueprint"
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
}
M.MAX_ENTITIES = 1000
M.MAX_TILES = 4000
M.MAX_SIDE = 128
M.MATCH_DIST = 1.5   -- призрак «тот самый», если встал не дальше этого от расчётного места
M.PAD = 1.5          -- запас области вокруг чертежа
M.SHORT_LIST = 10    -- длина списков в detail, когда заполнены все три
-- Поиск сдвига: «работа» одного кандидата ≈ FIT_BASE + число сущностей и плиток чертежа (и ещё
-- столько же ×FIT_FULL, если дошло до полной проверки can_place_entity).
M.FIT_OPS_TICK = 2000     -- работы за тик
M.FIT_MAX_OPS = 600000    -- работы на весь поиск (≈ 5 с); исчерпано — fit нет, detail.fit_limit
M.FIT_BASE = 10
M.FIT_FULL = 4

local function rot(dx, dy, dir)
  if dir == 4 then return -dy, dx end
  if dir == 8 then return -dx, -dy end
  if dir == 12 then return dy, -dx end
  return dx, dy
end

--- Направление после зеркала по вертикальной оси (x → −x): север и юг остаются, восток ↔ запад.
local function mirror_dir(d)
  return (16 - (d or 0)) % 16
end
M.mirror_dir = mirror_dir

-- постройка нечётной ширины стоит центром в середине клетки, чётной — на границе клеток
local function snap(v, tiles)
  if tiles % 2 == 1 then return math.floor(v) + 0.5 end
  return math.floor(v + 0.5)
end

--- Расчётные места сущностей и плиток чертежа в мире: anchor — центр рамки чертежа, dir — поворот,
--- mirror — чертёж сначала отражается по вертикальной оси (x → −x), потом поворачивается.
--- Рамка — по клеткам, которые занимают постройки (размер в клетках, а не коробка столкновений)
--- и плитки; первая постройка привязывается к сетке (половина округляется вверх), остальное
--- сдвигается вместе с ней. Сверено с движком 2.0.77 на чертеже «печь 2×2 + сундук» во всех
--- четырёх поворотах (живой сценарий build_2x2, 2026-10-13).
--- → {{name, proto, pos, dir, quality}, ...}, {{name, pos = центр клетки}, ...}
function M.layout(entities, anchor, dir, tiles, mirror)
  local x0, y0, x1, y1
  local function grow(ax, ay, bx, by)
    x0 = math.min(x0 or ax, ax)
    y0 = math.min(y0 or ay, ay)
    x1 = math.max(x1 or bx, bx)
    y1 = math.max(y1 or by, by)
  end
  local items = {}
  for i, be in ipairs(entities or {}) do
    local proto = prototypes.entity[be.name]
    local p = util.xy(be.position)
    local edir = be.direction or 0
    if mirror then p.x, edir = -p.x, mirror_dir(edir) end
    local tw, th = B.tile_size(proto, edir)
    local hx, hy = tw / 2, th / 2
    grow(p.x - hx, p.y - hy, p.x + hx, p.y + hy)
    items[i] = { name = be.name, proto = proto, p = p, dir = edir, quality = be.quality }
  end
  local cells = {}
  for i, bt in ipairs(tiles or {}) do
    local p = util.xy(bt.position)
    if mirror then p.x = -p.x - 1 end
    grow(p.x, p.y, p.x + 1, p.y + 1)
    cells[i] = { name = bt.name, p = { x = p.x + 0.5, y = p.y + 0.5 } }
  end
  local out, tout = {}, {}
  if #items == 0 and #cells == 0 then return out, tout end
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local sx, sy
  for i, it in ipairs(items) do
    local dx, dy = rot(it.p.x - cx, it.p.y - cy, dir)
    local wx, wy = anchor.x + dx, anchor.y + dy
    local wdir = (it.dir + dir) % 16
    if sx == nil then
      local tw, th = B.tile_size(it.proto, wdir)
      sx, sy = snap(wx, tw) - wx, snap(wy, th) - wy
    end
    out[i] = { name = it.name, proto = it.proto, pos = { x = wx + sx, y = wy + sy }, dir = wdir, quality = it.quality }
  end
  for i, c in ipairs(cells) do
    local dx, dy = rot(c.p.x - cx, c.p.y - cy, dir)
    local wx, wy = anchor.x + dx, anchor.y + dy
    if sx == nil then sx, sy = snap(wx, 1) - wx, snap(wy, 1) - wy end
    tout[i] = { name = c.name, pos = { x = wx + sx, y = wy + sy } }
  end
  return out, tout
end

local function area_of(plan, tplan)
  local x0, y0, x1, y1
  local function grow(px, py, hx, hy)
    x0 = math.min(x0 or px - hx, px - hx)
    y0 = math.min(y0 or py - hy, py - hy)
    x1 = math.max(x1 or px + hx, px + hx)
    y1 = math.max(y1 or py + hy, py + hy)
  end
  for _, it in ipairs(plan) do
    local hx, hy = B.half_size(it.proto, it.dir)
    grow(it.pos.x, it.pos.y, hx, hy)
  end
  for _, t in ipairs(tplan) do grow(t.pos.x, t.pos.y, 0.5, 0.5) end
  return {
    left_top = { x = x0 - M.PAD, y = y0 - M.PAD },
    right_bottom = { x = x1 + M.PAD, y = y1 + M.PAD },
  }
end

--- Открыть строку чертежа во временном инвентаре, вызвать fn(stack); инвентарь уничтожается всегда.
local function with_blueprint(str, fn)
  local binv = game.create_inventory(1)
  local ok, res = pcall(function()
    local st = binv[1]
    -- 0 — ок; -1 — импорт с предупреждениями (например, сущности отсутствующего мода: движок
    -- их отбрасывает, остальное ставится); провал — только 1 (ACTIONS.md) и всё прочее
    local rc = st.import_stack(str)
    if rc ~= 0 and rc ~= -1 then
      err.raise("bad_args", "args.blob: not a valid blueprint string")
    end
    if not st.valid_for_read or not st.is_blueprint then
      err.raise("bad_args", "args.blob: only a single blueprint is supported (no books or planners)")
    end
    if not st.is_blueprint_setup() then err.raise("bad_args", "args.blob: blueprint is empty") end
    return fn(st)
  end)
  binv.destroy()
  if not ok then error(res, 0) end
  return res
end

-- ------------------------------------------------------------------ зеркало

--- Типы прототипов, которые ручное зеркало отражать не умеет: у них отражение по x — это не
--- (16 − d) % 16 и не флаг mirror. Бак (storage-tank) имеет два положения, 0 и 4, и зеркало
--- переводит одно в другое — входы встали бы не туда. Это типы прототипов, а не имена
--- (PROTOCOL §6.12): баки и станции из модов подпадают сами.
local NO_MIRROR = { ["train-stop"] = true, ["storage-tank"] = true }

--- Чертёж можно отразить? Рельсы, станции и баки зеркалом не ставим: их формы и направления
--- движок отражает по своим правилам, которых здесь нет (оценка мест разошлась бы с постановкой,
--- а у баков — жидкостные входы). У build_blueprint движка (2.0.77) параметра mirror нет.
--- Один и тот же ответ — и для args.mirror, и для перебора положений в поиске сдвига.
local function can_mirror(entities)
  for _, be in ipairs(entities) do
    local proto = prototypes.entity[be.name]
    local t = proto and proto.type or ""
    if string.find(t, "rail", 1, true) or NO_MIRROR[t] then return false end
  end
  return true
end

local SIDE = { left = "right", right = "left" }

--- Отразить содержимое чертежа во временном стаке (x → −x): места, направления, флаг mirror у
--- построек с жидкостными входами, стороны приоритета у разделителей. Плитки — по клеткам.
local function mirror_stack(st, entities, tiles)
  for _, be in ipairs(entities) do
    local p = util.xy(be.position)
    be.position = { x = -p.x, y = p.y }
    be.direction = mirror_dir(be.direction)
    local proto = prototypes.entity[be.name]
    local ok, boxes = pcall(function() return proto.fluidbox_prototypes end)
    if ok and type(boxes) == "table" and #boxes > 0 then
      if be.mirror then be.mirror = nil else be.mirror = true end
    end
    if SIDE[be.input_priority] then be.input_priority = SIDE[be.input_priority] end
    if SIDE[be.output_priority] then be.output_priority = SIDE[be.output_priority] end
  end
  if #entities > 0 then st.set_blueprint_entities(entities) end
  if #tiles > 0 then
    for _, bt in ipairs(tiles) do
      local p = util.xy(bt.position)
      bt.position = { x = -p.x - 1, y = p.y }
    end
    st.set_blueprint_tiles(tiles)
  end
end

--- Чертёж простыми данными (лежит в task на время поиска сдвига, переживает сохранение).
local function plain_source(entities, tiles)
  local src = { entities = {}, tiles = {} }
  for i, be in ipairs(entities) do
    local p = util.xy(be.position)
    local q = be.quality
    if type(q) ~= "string" and q ~= nil then
      local ok, name = pcall(function() return q.name end)
      q = ok and name or "?"
    end
    src.entities[i] = { name = be.name, position = p, direction = be.direction or 0, quality = q }
  end
  for i, bt in ipairs(tiles) do
    src.tiles[i] = { name = bt.name, position = util.xy(bt.position) }
  end
  return src
end

-- ------------------------------------------------------------------ оценка до постановки

local NATURAL = { tree = true, cliff = true, fish = true }
local NOT_OBSTACLE = {
  character = true, ["entity-ghost"] = true, ["tile-ghost"] = true, resource = true,
  ["item-entity"] = true, ["item-request-proxy"] = true, ["character-corpse"] = true,
  ["construction-robot"] = true, ["logistic-robot"] = true, ["combat-robot"] = true,
  ["deconstructible-tile-proxy"] = true,
}

local function is_natural(e)
  if NATURAL[e.type] then return true end
  if e.type == "simple-entity" then
    local ok, r = pcall(function() return e.prototype.count_as_rock_for_filtered_deconstruction end)
    return ok and r == true
  end
  return false
end

--- Что стоит на месте будущей постройки: природное (деревья, камни), постройки своей силы,
--- стоит ли там уже такая же постройка, и есть ли чужое (другая сила — снести нельзя).
local function obstacles(h, it)
  local f = B.footprint(it.proto, it.pos, it.dir)
  local nat, own, same, foreign = {}, {}, false, false
  for _, e in ipairs(h.surface.find_entities_filtered{ area = { f.left_top, f.right_bottom } }) do
    if e.valid and e ~= h and not NOT_OBSTACLE[e.type] then
      if is_natural(e) then
        nat[#nat + 1] = e
      elseif e.force ~= nil and e.force.name == h.force.name then
        if e.name == it.name and util.dist(util.xy(e.position), it.pos) < 0.1 then
          same = true
        else
          own[#own + 1] = e
        end
      elseif e.force ~= nil and e.force.name ~= "neutral" then
        foreign = true
      end
    end
  end
  return nat, own, same, foreign
end

--- Окружение одной оценки: кэш «подложка доступна» и маска тела (плитка, по которой тело не
--- ходит, — «без опоры» и для плитки чертежа, которую на неё положить нельзя).
local function new_env(h)
  local ok, mask = pcall(function() return h.prototype.collision_mask end)
  return { cover = {}, body_mask = ok and mask or nil }
end

--- Клетки под постройкой, где плитка ей мешает (PROTOCOL §6.12):
--- cover = {имя подложки: число} — движок накроет сам (forced/superforced, подложка доступна);
--- n_cover — сколько клеток накрыто (подложкой или плиткой самого чертежа);
--- bad = {{key, tile}, ...} — клетки без возможной подложки (nil — таких нет).
--- bp_cells — клетки, куда чертёж сам кладёт плитку.
local function wet_cells(h, it, bp_cells, env, mode)
  local hx, hy = B.half_size(it.proto, it.dir)
  local cover, n, bad = nil, 0, nil
  local mask = it.proto.collision_mask
  for cx = math.floor(it.pos.x - hx + B.EPS), math.floor(it.pos.x + hx - B.EPS) do
    for cy = math.floor(it.pos.y - hy + B.EPS), math.floor(it.pos.y + hy - B.EPS) do
      local tp = B.tile_proto_at(h.surface, cx, cy)
      if tp ~= nil and B.masks_collide(mask, tp.collision_mask) then
        local key = cx .. "," .. cy
        if bp_cells[key] then
          n = n + 1   -- плитку под постройку кладёт сам чертёж
        else
          local c = mode ~= "normal" and B.cover_tile(tp) or nil
          if c ~= nil and B.cover_available(h, c, env.cover) then
            cover = cover or {}
            cover[c.name] = (cover[c.name] or 0) + 1
            n = n + 1
          else
            bad = bad or {}
            bad[#bad + 1] = { key = key, tile = tp.name }
          end
        end
      end
    end
  end
  return cover, n, bad
end

local function tile_item(name)
  local tp = prototypes.tile[name]
  return tp and B.place_items(tp)[1] or nil
end

--- Плитку name можно положить на клетку? Оценка по условиям place_as_tile её предмета: маска
--- столкновений против текущей плитки и, если движок его отдаёт, список разрешённых плиток
--- (tile_condition: отсыпка кладётся только на воду — на лаву Вулкануса движок её не ставит,
--- живой замер 2026-10-13). Точный ответ даёт только сама постановка (tiles_skipped по факту).
local function tile_fits(t, now)
  local item = tile_item(t.name)
  if item == nil then return false end
  local ip = prototypes.item[item.name]
  local place = ip and ip.place_as_tile_result
  if place == nil or now == nil then return true end
  if B.masks_collide(place.condition, now.collision_mask) then return false end
  local ok, only = pcall(function() return place.tile_condition end)
  if ok and type(only) == "table" and #only > 0 then
    for _, n in ipairs(only) do
      local name = type(n) == "string" and n or (type(n) == "table" and n.name) or nil
      if name == now.name then return true end
    end
    return false
  end
  return true
end

local function can_ghost(h, it, forced)
  return h.surface.can_place_entity{
    name = it.name, position = it.pos, direction = it.dir, force = h.force,
    build_check_type = defines.build_check_type.manual_ghost, forced = forced or nil,
  }
end

--- Плитки чертежа: что ляжет (bp_cells), что уже лежит, что положить нельзя; pre — куда считать
--- (nil — только ответ «есть клетка без опоры»). → bp_cells, есть ли плитка чертежа на клетке без опоры.
local function tiles_check(h, tplan, env, pre)
  local bp_cells, wet = {}, false
  for _, t in ipairs(tplan) do
    local now = B.tile_proto_at(h.surface, t.pos.x, t.pos.y)
    local key = B.cell_key(t.pos.x, t.pos.y)
    if now ~= nil and now.name == t.name then
      t.have = true
    elseif tile_fits(t, now) then
      bp_cells[key] = true
      if pre then pre.tiles[t.name] = (pre.tiles[t.name] or 0) + 1 end
    else
      t.skip = true
      -- плитку чертежа сюда не положить; если по текущей плитке и ходить нельзя — это клетка без опоры
      if now ~= nil and B.masks_collide(now.collision_mask, env.body_mask) then
        t.liquid = now.name
        wet = true
        if not pre then return bp_cells, true end
      end
      if pre then
        pre.tiles_skipped = pre.tiles_skipped + 1
        if t.liquid then pre.wet(key, now.name) end
      end
    end
  end
  return bp_cells, wet
end

--- Оценка постановки (PROTOCOL §6.5, manual_ghost) для режима mode: у каждой сущности — reason
--- или nil; → pre = {to_remove, to_remove_total, tiles = {имя: число}, tiles_skipped, on_liquid,
--- liquids = {плитка: число}}.
local function precheck(h, plan, tplan, mode, env)
  local pre = { to_remove = {}, to_remove_total = 0, tiles = {}, tiles_skipped = 0, on_liquid = 0, liquids = {} }
  local wet_seen = {}
  function pre.wet(key, tile)
    if wet_seen[key] then return end
    wet_seen[key] = true
    pre.on_liquid = pre.on_liquid + 1
    pre.liquids[tile] = (pre.liquids[tile] or 0) + 1
  end
  local bp_cells = tiles_check(h, tplan, env, pre)
  local seen = {}
  local function remove(e)
    local p = util.xy(e.position)
    local key = B.ghost_key(e.name, p)
    if seen[key] then return end
    seen[key] = true
    pre.to_remove_total = pre.to_remove_total + 1
    if #pre.to_remove < B.MAX_LIST then pre.to_remove[#pre.to_remove + 1] = { name = e.name, pos = util.pos(p) } end
  end
  for _, it in ipairs(plan) do
    if it.proto == nil then
      it.reason = "unknown"
    elseif not inv.is_normal(it.quality) then
      it.reason = "quality"
    elseif can_ghost(h, it, false) then
      it.reason = nil
    else
      local cover, n_cover, bad = wet_cells(h, it, bp_cells, env, mode)
      local nat, own, same, foreign
      if mode ~= "normal" then nat, own, same, foreign = obstacles(h, it) end
      if same then
        it.reason = "exists"
      elseif bad then
        -- клетка без возможной подложки: в normal — обычный пропуск клетки, в forced/superforced
        -- из-за неё не ставится весь чертёж (решает M.start), с partial — пропуск
        it.reason = "liquid"
        for _, c in ipairs(bad) do pre.wet(c.key, c.tile) end
      elseif mode == "normal" then
        it.reason = "cannot_place"
      elseif foreign or (#own > 0 and mode ~= "superforced") then
        it.reason = "cannot_place"
      elseif n_cover == 0 and #own == 0 and not can_ghost(h, it, true) then
        -- проверка движка с forced не считает помехой только то, что сносит Shift (деревья, камни);
        -- свои постройки (Ctrl+Shift) она помехой считает, поэтому при них на неё не опираемся
        it.reason = "cannot_place"
      else
        for _, e in ipairs(nat) do remove(e) end
        for _, e in ipairs(own) do remove(e) end
        for name, n in pairs(cover or {}) do pre.tiles[name] = (pre.tiles[name] or 0) + n end
        it.cover = cover ~= nil or nil
      end
    end
  end
  pre.wet = nil
  return pre
end

-- ------------------------------------------------------------------ сверка после постановки

--- Сопоставить расчётные места с тем, что поставил движок: у каждого it — reason или nil.
local function reconcile(plan, created)
  local by_name = {}
  for _, c in ipairs(created) do
    by_name[c.name] = by_name[c.name] or {}
    local l = by_name[c.name]
    l[#l + 1] = c
  end
  for _, it in ipairs(plan) do
    local best, bd
    for _, c in ipairs(by_name[it.name] or {}) do
      if not c.used then
        local d = util.dist(c.pos, it.pos)
        if d <= M.MATCH_DIST and (bd == nil or d < bd) then best, bd = c, d end
      end
    end
    if best ~= nil then
      best.used = true
      it.reason = best.why
    else
      it.reason = it.reason or "cannot_place"
    end
  end
end

--- Итог постановки (или её оценки): pre — tiles {имя: число}, tiles_skipped, to_remove,
--- to_remove_total, on_liquid, liquids. → detail, число призраков плиток.
local function summary(h, plan, tplan, pre)
  local skipped, total, ghosts, need = {}, 0, 0, {}
  local function skip(name, pos, reason)
    total = total + 1
    if #skipped < B.MAX_LIST then skipped[#skipped + 1] = { name = name, pos = util.pos(pos), reason = reason } end
  end
  for _, it in ipairs(plan) do
    if it.reason ~= nil then
      skip(it.name, it.pos, it.reason)
    else
      ghosts = ghosts + 1
      local item = B.place_items(it.proto)[1]
      if item ~= nil then need[item.name] = (need[item.name] or 0) + item.count end
    end
  end
  -- плитки чертежа на клетках без опоры — тоже «клетки в skipped с reason liquid» (ACTIONS.md)
  for _, t in ipairs(tplan) do
    if t.liquid then skip(t.name, t.pos, "liquid") end
  end
  local n_tiles = 0
  for name, n in pairs(pre.tiles) do
    n_tiles = n_tiles + n
    local item = tile_item(name)
    if item ~= nil then need[item.name] = (need[item.name] or 0) + item.count * n end
  end
  local main = h.get_main_inventory()
  local missing = {}
  for name, n in pairs(need) do
    local lack = n - inv.count(main, name)
    if lack > 0 then missing[name] = lack end
  end
  local s = {
    ghosts = ghosts, skipped = skipped, skipped_total = total, missing = missing,
    tiles = n_tiles, tiles_skipped = pre.tiles_skipped, on_liquid = pre.on_liquid or 0,
    to_remove = pre.to_remove, to_remove_total = pre.to_remove_total,
  }
  if s.on_liquid > 0 then s.liquids = pre.liquids end
  return s, n_tiles
end

local function tile_ghosts_in(h, area)
  return h.surface.find_entities_filtered{
    area = { area.left_top, area.right_bottom }, type = "tile-ghost", force = h.force,
  }
end

-- ------------------------------------------------------------------ поиск сдвига (fit)

--- Клетки кольца r вокруг нуля (|dx| или |dy| = r), ближние к центру первыми.
local function ring(r)
  if r == 0 then return { { dx = 0, dy = 0 } } end
  local out = {}
  for d = -r, r do
    out[#out + 1] = { dx = d, dy = -r }
    out[#out + 1] = { dx = d, dy = r }
  end
  for d = -r + 1, r - 1 do
    out[#out + 1] = { dx = -r, dy = d }
    out[#out + 1] = { dx = r, dy = d }
  end
  table.sort(out, function(p, q)
    local a, b = p.dx * p.dx + p.dy * p.dy, q.dx * q.dx + q.dy * q.dy
    if a ~= b then return a < b end
    if p.dy ~= q.dy then return p.dy < q.dy end
    return p.dx < q.dx
  end)
  return out
end
M.ring = ring

--- Положения чертежа, которые перебирает поиск: заданное первым; с rotate — ещё повороты и зеркало.
local function orientations(a, src)
  local list = { { dir = a.direction, mirror = a.mirror } }
  if a.rotate then
    local flips = { a.mirror }
    if can_mirror(src.entities) then flips[2] = not a.mirror end
    for _, m in ipairs(flips) do
      for k = 0, 3 do
        local d = (a.direction + 4 * k) % 16
        if not (d == a.direction and m == a.mirror) then list[#list + 1] = { dir = d, mirror = m } end
      end
    end
  end
  return list
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
  local area = area_of(plan, tplan)
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
  local f = task.fit
  if f ~= nil then d.fit_checked = f.checked end
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

-- ------------------------------------------------------------------ пометки задачи

--- Снять пометки к сносу, которые поставила эта задача (failed, cancel, stuck — ACTIONS.md).
local function unmark(task)
  if task.marks ~= nil then
    B.unmark(task.marks, task.marks_force)
    task.marks = nil
  end
end

-- ------------------------------------------------------------------ постановка

--- Поставить чертёж движком и сверить. → {summary, area, n_tiles} │ {rolled_back = true, summary}.
local function place(task, ctx, st, plan, tplan, area, pre)
  local a, h = task.args, ctx.entity
  -- что стояло здесь до нас: призраки (план хозяина — если движок вернёт такой в списке при
  -- наложении на одинаковый призрак, он считается поставленным, но убирать его нельзя),
  -- призраки плиток и уже помеченное к сносу (это не «наше» to_remove)
  local own_before, tiles_before, marked_before, raw_before = {}, {}, {}, {}
  for _, g in ipairs(h.surface.find_entities_filtered{
    area = { area.left_top, area.right_bottom }, type = "entity-ghost",
  }) do
    if g.valid then own_before[B.ghost_key(g.ghost_name, util.xy(g.position))] = true end
  end
  for _, g in ipairs(tile_ghosts_in(h, area)) do
    if g.valid then tiles_before[B.ghost_key(g.ghost_name, util.xy(g.position))] = true end
  end
  for _, m in ipairs(B.marked(h, area)) do marked_before[m.key] = true end
  for _, e in ipairs(B.marked_raw(h, area)) do raw_before[B.mark_key(e)] = true end

  local built = st.build_blueprint{
    surface = h.surface, force = h.force, position = a.anchor, direction = a.direction,
    build_mode = defines.build_mode[a.force], skip_fog_of_war = false, raise_built = true,
  }

  -- пометки, которые поставила эта постановка: запоминаем сразу — их снимет M.stop
  local marks = {}
  for _, e in ipairs(B.marked_raw(h, area)) do
    if not raw_before[B.mark_key(e)] then marks[#marks + 1] = e end
  end
  task.marks, task.marks_force = marks, h.force.name

  -- плитки: что появилось (плитки чертежа и подложки, которые добавил движок)
  local after_tiles = tile_ghosts_in(h, area)
  local bp_names = {}
  local post = {
    tiles = {}, tiles_skipped = 0, to_remove = {}, to_remove_total = 0,
    on_liquid = pre.on_liquid, liquids = pre.liquids,
  }
  for _, t in ipairs(tplan) do bp_names[t.name] = true end
  local created_bp, new_tiles = 0, {}
  for _, g in ipairs(after_tiles) do
    if g.valid and not tiles_before[B.ghost_key(g.ghost_name, util.xy(g.position))] then
      post.tiles[g.ghost_name] = (post.tiles[g.ghost_name] or 0) + 1
      new_tiles[#new_tiles + 1] = g
      if bp_names[g.ghost_name] then created_bp = created_bp + 1 end
    end
  end
  local wanted = 0
  for _, t in ipairs(tplan) do
    if not t.have and not tiles_before[B.ghost_key(t.name, t.pos)] then wanted = wanted + 1 end
  end
  post.tiles_skipped = math.max(0, wanted - created_bp)

  -- помеченное к сносу этой постановкой
  local sv = B.survey(h, area, after_tiles)
  for _, m in ipairs(sv.marked) do
    if not marked_before[m.key] then
      post.to_remove_total = post.to_remove_total + 1
      if #post.to_remove < B.MAX_LIST then post.to_remove[#post.to_remove + 1] = { name = m.name, pos = util.pos(m.pos) } end
    end
  end

  -- свои призраки построек, которые нельзя оживить (или не-normal качества), сразу убираем;
  -- ждущие плитку или сноса помеченного — не «заблокированы»
  local created, mine = {}, {}
  for _, g in ipairs(built or {}) do
    if g.valid and g.type == "entity-ghost" then
      local c = { name = g.ghost_name, pos = util.xy(g.position) }
      local ours = not own_before[B.ghost_key(c.name, c.pos)]
      if not inv.is_normal(g.quality) then
        c.why = "quality"
      elseif B.waits_for(sv, g.ghost_prototype, c.pos, g.direction) == nil
          and B.blocked(g.surface, g) and not B.body_inside(h, g.ghost_prototype, c.pos, g.direction) then
        c.why = "blocked"
      end
      if c.why ~= nil and ours then
        g.destroy{ raise_destroy = true }
      elseif ours then
        mine[#mine + 1] = g
      end
      created[#created + 1] = c
    end
  end
  reconcile(plan, created)

  -- Оценка обещала подложку от движка, а он её не поставил (постройка над плиткой без опоры не
  -- встала): значит, подложка на деле невозможна — чертёж не ставится вовсе. Откат: свои призраки
  -- построек и плиток убираются, свои пометки снимаются.
  if not a.partial then
    local wet, liquids = 0, {}
    for _, it in ipairs(plan) do
      if it.cover and it.reason ~= nil then
        local hx, hy = B.half_size(it.proto, it.dir)
        for cx = math.floor(it.pos.x - hx + B.EPS), math.floor(it.pos.x + hx - B.EPS) do
          for cy = math.floor(it.pos.y - hy + B.EPS), math.floor(it.pos.y + hy - B.EPS) do
            local tp = B.tile_proto_at(h.surface, cx, cy)
            if tp ~= nil and B.masks_collide(it.proto.collision_mask, tp.collision_mask) then
              wet = wet + 1
              liquids[tp.name] = (liquids[tp.name] or 0) + 1
            end
          end
        end
        it.reason = "liquid"
      end
    end
    if wet > 0 then
      for _, g in ipairs(mine) do
        if g.valid then g.destroy{ raise_destroy = true } end
      end
      for _, g in ipairs(new_tiles) do
        if g.valid then g.destroy{ raise_destroy = true } end
      end
      unmark(task)
      local s = summary(h, plan, tplan, {
        tiles = {}, tiles_skipped = post.tiles_skipped, to_remove = {}, to_remove_total = 0,
        on_liquid = wet, liquids = liquids,
      })
      s.ghosts = 0
      return { rolled_back = true, summary = s }
    end
  end

  local s, n_tiles = summary(h, plan, tplan, post)
  return { summary = s, area = area, n_tiles = n_tiles }
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
    if pre.on_liquid > 0 and a.force ~= "normal" and not a.partial then
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
  local r = B.ghosts_tick(task, ctx)
  if r == nil then return nil end
  return merged(task, r)
end

--- Отмена, сбой, застревание: снять свои пометки к сносу, подход, переключатель дронов.
--- Пометки снимаются первыми и без тела помощника (stop зовётся и после его смерти).
function M.stop(task, ctx)
  unmark(task)
  task.fit = nil
  if task.g ~= nil then B.ghosts_stop(task, ctx) else B.stop_approach(task, ctx) end
end

return M
