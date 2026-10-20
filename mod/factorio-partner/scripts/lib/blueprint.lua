-- Общая часть постановки блока построек призраками через чертёж движка: build_blueprint и
-- build_layout. Контракты: docs/ACTIONS.md («build_blueprint», «build_layout»), PROTOCOL.md §6.5,
-- §6.12.
--
-- Что здесь:
-- * раскладка чертежа в мире L.layout (центр рамки по клеткам, повороты, зеркало, привязка к
--   сетке) и рамка области L.area_of;
-- * временный стак чертежа: L.with_blueprint (строка чертежа), L.with_new_blueprint (пустой
--   чертёж, сущности задаются set_blueprint_entities); стак уничтожается всегда;
-- * зеркало: L.can_mirror, L.mirror_stack, L.mirror_dir;
-- * оценка до постановки L.precheck (manual_ghost, деревья и камни, плитки без опоры, «уже стоит»)
--   и её части L.tiles_check, L.wet_cells, L.new_env;
-- * поиск места: кольца L.ring, положения L.orientations;
-- * постановка L.place: build_blueprint движка, пометки к сносу этой постановки, сверка
--   L.reconcile расчётных мест с призраками, уборка заблокированных призраков, откат, если движок
--   не поставил обещанную подложку;
-- * снятие своих пометок L.unmark и уборка своих непостроенных призраков L.remove_ghosts.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")

local L = {}
L.MATCH_DIST = 1.5   -- призрак «тот самый», если встал не дальше этого от расчётного места
L.PAD = 1.5          -- запас области вокруг чертежа

local function rot(dx, dy, dir)
  if dir == 4 then return -dy, dx end
  if dir == 8 then return -dx, -dy end
  if dir == 12 then return dy, -dx end
  return dx, dy
end
L.rot = rot

--- Направление после зеркала по вертикальной оси (x → −x): север и юг остаются, восток ↔ запад.
local function mirror_dir(d)
  return (16 - (d or 0)) % 16
end
L.mirror_dir = mirror_dir

-- постройка нечётной ширины стоит центром в середине клетки, чётной — на границе клеток
local function snap(v, tiles)
  if tiles % 2 == 1 then return math.floor(v) + 0.5 end
  return math.floor(v + 0.5)
end
L.snap = snap

--- Расчётные места сущностей и плиток чертежа в мире: anchor — центр рамки чертежа, dir — поворот,
--- mirror — чертёж сначала отражается по вертикальной оси (x → −x), потом поворачивается.
--- Рамка — по клеткам, которые занимают постройки (размер в клетках, а не коробка столкновений)
--- и плитки; первая постройка привязывается к сетке (половина округляется вверх), остальное
--- сдвигается вместе с ней. Сверено с движком 2.0.77 на чертеже «печь 2×2 + сундук» во всех
--- четырёх поворотах (живой сценарий build_2x2).
--- → {{name, proto, pos, dir, quality}, ...}, {{name, pos = центр клетки}, ...}
function L.layout(entities, anchor, dir, tiles, mirror)
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

--- Центр рамки чертежа (по клеткам построек) — та точка, которую L.layout ставит в anchor.
function L.frame_center(entities)
  local x0, y0, x1, y1
  for _, be in ipairs(entities) do
    local proto = prototypes.entity[be.name]
    local p = util.xy(be.position)
    local tw, th = B.tile_size(proto, be.direction or 0)
    x0 = math.min(x0 or p.x - tw / 2, p.x - tw / 2)
    y0 = math.min(y0 or p.y - th / 2, p.y - th / 2)
    x1 = math.max(x1 or p.x + tw / 2, p.x + tw / 2)
    y1 = math.max(y1 or p.y + th / 2, p.y + th / 2)
  end
  if x0 == nil then return { x = 0, y = 0 } end
  return { x = (x0 + x1) / 2, y = (y0 + y1) / 2 }
end

--- Область плана (построек и плиток) с запасом pad (по умолчанию L.PAD).
function L.area_of(plan, tplan, pad)
  pad = pad or L.PAD
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
  for _, t in ipairs(tplan or {}) do grow(t.pos.x, t.pos.y, 0.5, 0.5) end
  return {
    left_top = { x = x0 - pad, y = y0 - pad },
    right_bottom = { x = x1 + pad, y = y1 + pad },
  }
end

--- Открыть строку чертежа во временном инвентаре, вызвать fn(stack); инвентарь уничтожается всегда.
function L.with_blueprint(str, fn)
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

--- Пустой чертёж во временном инвентаре с сущностями entities (формат BlueprintEntity), вызвать
--- fn(stack); инвентарь уничтожается всегда.
function L.with_new_blueprint(entities, fn)
  local binv = game.create_inventory(1)
  local ok, res = pcall(function()
    local st = binv[1]
    st.set_stack{ name = "blueprint", count = 1 }
    st.set_blueprint_entities(entities)
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
function L.can_mirror(entities)
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
function L.mirror_stack(st, entities, tiles)
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
function L.plain_source(entities, tiles)
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
function L.new_env(h)
  local ok, mask = pcall(function() return h.prototype.collision_mask end)
  return { cover = {}, body_mask = ok and mask or nil }
end

--- Клетки под постройкой, где плитка ей мешает (PROTOCOL §6.12):
--- cover = {имя подложки: число} — движок накроет сам (forced/superforced, подложка доступна);
--- n_cover — сколько клеток накрыто (подложкой или плиткой самого чертежа);
--- bad = {{key, tile}, ...} — клетки без возможной подложки (nil — таких нет).
--- bp_cells — клетки, куда чертёж сам кладёт плитку.
function L.wet_cells(h, it, bp_cells, env, mode)
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
L.tile_item = tile_item

--- Плитку name можно положить на клетку? Оценка по условиям place_as_tile её предмета: маска
--- столкновений против текущей плитки и, если движок его отдаёт, список разрешённых плиток
--- (tile_condition: отсыпка кладётся только на воду — на лаву Вулкануса движок её не ставит).
--- Точный ответ даёт только сама постановка (tiles_skipped по факту).
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
function L.tiles_check(h, tplan, env, pre)
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
--- или nil (и why — уточнение для cannot_place: occupied │ foreign │ engine; для liquid — liquid);
--- → pre = {to_remove, to_remove_total, tiles = {имя: число}, tiles_skipped, on_liquid,
--- liquids = {плитка: число}}.
function L.precheck(h, plan, tplan, mode, env)
  local pre = { to_remove = {}, to_remove_total = 0, tiles = {}, tiles_skipped = 0, on_liquid = 0, liquids = {} }
  local wet_seen = {}
  function pre.wet(key, tile)
    if wet_seen[key] then return end
    wet_seen[key] = true
    pre.on_liquid = pre.on_liquid + 1
    pre.liquids[tile] = (pre.liquids[tile] or 0) + 1
  end
  local bp_cells = L.tiles_check(h, tplan, env, pre)
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
    -- план оценивают повторно (поиск места, затем постановка после снабжения): старое не тянем
    it.reason, it.why, it.cover = nil, nil, nil
    if it.proto == nil then
      it.reason = "unknown"
    elseif not inv.is_normal(it.quality) then
      it.reason = "quality"
    elseif can_ghost(h, it, false) then
      it.reason = nil
    else
      local cover, n_cover, bad = L.wet_cells(h, it, bp_cells, env, mode)
      local nat, own, same, foreign
      if mode ~= "normal" then nat, own, same, foreign = obstacles(h, it) end
      if same then
        it.reason = "exists"
      elseif bad then
        -- клетка без возможной подложки: из-за неё не ставится весь чертёж (решает M.start),
        -- с partial — пропуск
        it.reason = "liquid"
        for _, c in ipairs(bad) do pre.wet(c.key, c.tile) end
      elseif mode == "normal" then
        it.reason = "cannot_place"
        it.why = "occupied"
      elseif foreign or (#own > 0 and mode ~= "superforced") then
        it.reason = "cannot_place"
        it.why = foreign and "foreign" or "occupied"
      elseif n_cover == 0 and #own == 0 and not can_ghost(h, it, true) then
        -- проверка движка с forced не считает помехой только то, что сносит Shift (деревья, камни);
        -- свои постройки (Ctrl+Shift) она помехой считает, поэтому при них на неё не опираемся
        it.reason = "cannot_place"
        it.why = "engine"
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

--- Сопоставить расчётные места с тем, что поставил движок: у каждого it — reason или nil и, если
--- призрак нашёлся, it.ghost_pos — где он встал.
function L.reconcile(plan, created, match)
  match = match or L.MATCH_DIST
  local by_name = {}
  for _, c in ipairs(created) do
    by_name[c.name] = by_name[c.name] or {}
    local l = by_name[c.name]
    l[#l + 1] = c
  end
  for _, it in ipairs(plan) do
    local best, bd
    -- клетка, пропущенная ещё оценкой (liquid, exists, ...), призрака не ждёт: иначе она заняла бы
    -- призрак соседней клетки (partial: пропуск на воде «съедал» постройку на суше)
    for _, c in ipairs(it.reason == nil and by_name[it.name] or {}) do
      if not c.used then
        local d = util.dist(c.pos, it.pos)
        if d <= match and (bd == nil or d < bd) then best, bd = c, d end
      end
    end
    if best ~= nil then
      best.used = true
      it.reason = best.why
      it.ghost_pos = best.pos
    elseif it.reason ~= nil then
      -- причина из оценки остаётся
    else
      it.reason = "cannot_place"
      it.why = "engine"
    end
  end
end

--- Итог постановки (или её оценки): pre — tiles {имя: число}, tiles_skipped, to_remove,
--- to_remove_total, on_liquid, liquids. → detail, число призраков плиток.
function L.summary(h, plan, tplan, pre)
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

-- ------------------------------------------------------------------ поиск места

--- Клетки кольца r вокруг нуля (|dx| или |dy| = r), ближние к центру первыми.
function L.ring(r)
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

--- Положения, которые перебирает поиск: заданное первым; с rotate — ещё повороты и, если
--- can_mirror, зеркало. a = {direction, mirror?, rotate}.
function L.orientations(a, can_mirror)
  local list = { { dir = a.direction, mirror = a.mirror } }
  if a.rotate then
    local flips = { a.mirror }
    if can_mirror then flips[2] = not a.mirror end
    for _, m in ipairs(flips) do
      for k = 0, 3 do
        local d = (a.direction + 4 * k) % 16
        if not (d == a.direction and m == a.mirror) then list[#list + 1] = { dir = d, mirror = m } end
      end
    end
  end
  return list
end

-- ------------------------------------------------------------------ пометки и призраки задачи

--- Снять пометки к сносу, которые поставила эта задача (failed, cancel, stuck — ACTIONS.md).
--- Число снятых копится в task.unmarked (пометок не ставили — nil) и уходит в detail.unmarked.
function L.unmark(task)
  if task.marks ~= nil then
    task.unmarked = (task.unmarked or 0) + B.unmark(task.marks, task.marks_force)
    task.marks = nil
  end
end

--- Убрать свои ещё не построенные призраки из списка list = {{name, pos, tile?}, ...} (простые
--- данные: призрак ищется заново по имени и месту). Тело помощника не нужно. → сколько убрано.
function L.remove_ghosts(surface_name, force_name, list)
  local surface = surface_name and game.surfaces[surface_name] or nil
  if surface == nil or type(list) ~= "table" then return 0 end
  local n = 0
  for _, g in ipairs(list) do
    local found = surface.find_entities_filtered{
      position = g.pos, radius = 0.1, type = g.tile and "tile-ghost" or "entity-ghost", force = force_name,
    }
    for _, e in ipairs(found) do
      if e.valid and e.ghost_name == g.name then
        e.destroy{ raise_destroy = true }
        n = n + 1
        break
      end
    end
  end
  return n
end

-- ------------------------------------------------------------------ постановка

--- Поставить чертёж движком и сверить. opts = {position, direction, build_mode ("normal"│"forced"│
--- "superforced"), partial}. → {summary, area, n_tiles, own = {{name, pos, tile?}, ...}} │
--- {rolled_back = true, summary}. own — свои новые призраки (построек и плиток) простыми данными.
--- Пометки к сносу этой постановки — в task.marks (их снимает L.unmark).
function L.place(task, ctx, st, plan, tplan, area, pre, opts)
  local h = ctx.entity
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
    surface = h.surface, force = h.force, position = opts.position, direction = opts.direction,
    build_mode = defines.build_mode[opts.build_mode], skip_fog_of_war = false, raise_built = true,
  }

  -- пометки, которые поставила эта постановка: запоминаем сразу — их снимет M.stop
  local marks = task.marks or {}
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
  L.reconcile(plan, created)

  -- Оценка обещала подложку от движка, а он её не поставил (постройка над плиткой без опоры не
  -- встала): значит, подложка на деле невозможна — чертёж не ставится вовсе. Откат: свои призраки
  -- построек и плиток убираются, свои пометки снимаются.
  if not opts.partial then
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
        it.why = "tile"
      end
    end
    if wet > 0 then
      for _, g in ipairs(mine) do
        if g.valid then g.destroy{ raise_destroy = true } end
      end
      for _, g in ipairs(new_tiles) do
        if g.valid then g.destroy{ raise_destroy = true } end
      end
      L.unmark(task)
      local s = L.summary(h, plan, tplan, {
        tiles = {}, tiles_skipped = post.tiles_skipped, to_remove = {}, to_remove_total = 0,
        on_liquid = wet, liquids = liquids,
      })
      s.ghosts = 0
      s.unmarked = task.unmarked
      return { rolled_back = true, summary = s }
    end
  end

  local own = {}
  for _, g in ipairs(mine) do
    if g.valid then own[#own + 1] = { name = g.ghost_name, pos = util.xy(g.position) } end
  end
  for _, g in ipairs(new_tiles) do
    if g.valid then own[#own + 1] = { name = g.ghost_name, pos = util.xy(g.position), tile = true } end
  end
  local s, n_tiles = L.summary(h, plan, tplan, post)
  return { summary = s, area = area, n_tiles = n_tiles, own = own }
end

return L
