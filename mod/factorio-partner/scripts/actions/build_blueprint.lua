-- Действие `build_blueprint` (поток F): разложить чертёж призраками и построить их.
-- Контракт: docs/ACTIONS.md («build_blueprint»), PROTOCOL.md §4 (blob_put), §6.5, §7.
--
-- args: blob (id из blob_put), anchor (центр чертежа), direction? = 0 (0/4/8/12),
--       mode? = "auto"│"hand"│"robots" (кто строит), force? = "forced" (как ставится чертёж:
--       "normal" — клик, "forced" — Shift, "superforced" — Ctrl+Shift), dry_run? = false.
-- done.detail: {ghosts, skipped:[{name,pos,reason}], skipped_total, tiles:{имя: число},
--               tiles_skipped, to_remove:[{name,pos}], to_remove_total, missing,
--               + после стройки поля build_ghosts: built, left, blocked, blocked_total, …}.
-- Ход: строка из storage.blobs → game.create_inventory(1) → import_stack (1 → bad_args; -1 —
-- импорт с предупреждениями — принимается; книги и планировщики → bad_args) → для каждой
-- сущности проверка постановки призрака (manual_ghost, §6.5) →
-- build_blueprint{build_mode = defines.build_mode[force], skip_fog_of_war = false} создаёт
-- призраки построек и плиток (и, в режимах forced/superforced, помечает помехи к сносу) →
-- inventory.destroy() → дальше как build_ghosts по площади чертежа: снос помеченного, плитки,
-- постройки.
-- После постановки каждый свой призрак постройки проверяется ghost_revive: заблокированный (над
-- ним дроны висели бы вечно) и призрак не-normal качества сразу убираются и попадают в skipped.
-- Призрак, который ждёт плитку под собой или сноса помеченного, заблокированным не считается.
-- to_remove — что помечено к сносу этой постановкой (после неё — по факту; в dry_run — оценка:
-- деревья и камни на местах построек, а для superforced — ещё и постройки своей силы).
-- dry_run — только проверки, призраков и пометок нет.
-- Ошибки: bad_args (blob, не чертёж, пустой, direction), limit (> 1000 сущностей, > 4000 плиток,
-- сторона > 128), not_charted, reserved, cannot_place (ничего не встало), дальше — как build_ghosts.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local blobs = require("scripts.core.blobs")
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
  dry_run = { type = "bool", default = false },
}
M.MAX_ENTITIES = 1000
M.MAX_TILES = 4000
M.MAX_SIDE = 128
M.MATCH_DIST = 1.5   -- призрак «тот самый», если встал не дальше этого от расчётного места
M.PAD = 1.5          -- запас области вокруг чертежа
M.SHORT_LIST = 10    -- длина списков в detail, когда заполнены все три

local function rot(dx, dy, dir)
  if dir == 4 then return -dy, dx end
  if dir == 8 then return -dx, -dy end
  if dir == 12 then return dy, -dx end
  return dx, dy
end

-- постройка нечётной ширины стоит центром в середине клетки, чётной — на границе клеток
local function snap(v, tiles)
  if tiles % 2 == 1 then return math.floor(v) + 0.5 end
  return math.floor(v + 0.5)
end

--- Расчётные места сущностей и плиток чертежа в мире: anchor — центр рамки чертежа, dir — поворот.
--- Рамка — по клеткам, которые занимают постройки (размер в клетках, а не коробка столкновений)
--- и плитки; первая постройка привязывается к сетке (половина округляется вверх), остальное
--- сдвигается вместе с ней. Сверено с движком 2.0.77 на чертеже «печь 2×2 + сундук» во всех
--- четырёх поворотах (живой сценарий build_2x2, 2026-10-13).
--- → {{name, proto, pos, dir, quality}, ...}, {{name, pos = центр клетки}, ...}
function M.layout(entities, anchor, dir, tiles)
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
    local tw, th = B.tile_size(proto, edir)
    local hx, hy = tw / 2, th / 2
    grow(p.x - hx, p.y - hy, p.x + hx, p.y + hy)
    items[i] = { name = be.name, proto = proto, p = p, dir = edir, quality = be.quality }
  end
  local cells = {}
  for i, bt in ipairs(tiles or {}) do
    local p = util.xy(bt.position)
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

--- Предмет плитки-подложки доступен силе (его рецепт открыт)? Живой замер 2026-10-13 (2.0.77,
--- лава Вулкануса, «фундамент» не исследован): forced не ставит ни подложку, ни постройку.
local function cover_known(h, tile_name)
  local tp = prototypes.tile[tile_name]
  local item = tp and B.place_items(tp)[1]
  if item == nil then return false end
  local r = h.force.recipes[item.name]
  return r ~= nil and r.enabled == true
end

local function layers_of(mask)
  if type(mask) ~= "table" then return nil end
  return mask.layers or mask
end

local function collide(a, b)
  a, b = layers_of(a), layers_of(b)
  if a == nil or b == nil then return false end
  for layer, on in pairs(a) do
    if on and b[layer] then return true end
  end
  return false
end

local function tile_proto_at(surface, x, y)
  local ok, t = pcall(function() return surface.get_tile(math.floor(x), math.floor(y)) end)
  if not ok or t == nil then return nil end
  return prototypes.tile[t.name]
end

--- Клетки под постройкой, где она не встанет без плитки (вода, лава): → плитки-подложки
--- {имя: число} (default_cover_tile), число таких клеток (вместе с теми, куда плитку кладёт сам
--- чертёж), bad = true — есть клетка, которую закрыть нечем.
--- bp_cells — клетки, куда чертёж сам кладёт плитку.
local function cover_cells(h, it, bp_cells)
  local hx, hy = B.half_size(it.proto, it.dir)
  local cover, n, bad = {}, 0, false
  local mask = it.proto.collision_mask
  for cx = math.floor(it.pos.x - hx + B.EPS), math.floor(it.pos.x + hx - B.EPS) do
    for cy = math.floor(it.pos.y - hy + B.EPS), math.floor(it.pos.y + hy - B.EPS) do
      local tp = tile_proto_at(h.surface, cx, cy)
      if tp ~= nil and collide(mask, tp.collision_mask) and bp_cells[cx .. "," .. cy] then
        n = n + 1   -- плитку под постройку кладёт сам чертёж
      elseif tp ~= nil and collide(mask, tp.collision_mask) then
        local c = tp.default_cover_tile
        local cname = type(c) == "string" and c or (c and c.name)
        if cname and cover_known(h, cname) then
          cover[cname] = (cover[cname] or 0) + 1
          n = n + 1
        else
          bad = true
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
local function tile_fits(h, t)
  local item = tile_item(t.name)
  if item == nil then return false end
  local ip = prototypes.item[item.name]
  local place = ip and ip.place_as_tile_result
  local now = tile_proto_at(h.surface, t.pos.x, t.pos.y)
  if place == nil or now == nil then return true end
  if collide(place.condition, now.collision_mask) then return false end
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

--- Оценка постановки (PROTOCOL §6.5, manual_ghost) для режима mode: у каждой сущности — reason
--- или nil; → pre = {to_remove = {...}, to_remove_total, tiles = {имя: число}, tiles_skipped}.
local function precheck(h, plan, tplan, mode)
  local pre = { to_remove = {}, to_remove_total = 0, tiles = {}, tiles_skipped = 0 }
  local bp_cells = {}
  for _, t in ipairs(tplan) do
    local now = tile_proto_at(h.surface, t.pos.x, t.pos.y)
    if now ~= nil and now.name == t.name then
      t.have = true
    elseif tile_fits(h, t) then
      pre.tiles[t.name] = (pre.tiles[t.name] or 0) + 1
      bp_cells[B.cell_key(t.pos.x, t.pos.y)] = true
    else
      t.skip = true
      pre.tiles_skipped = pre.tiles_skipped + 1
    end
  end
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
    elseif mode == "normal" then
      it.reason = "cannot_place"
    else
      local nat, own, same, foreign = obstacles(h, it)
      local cover, n_cover, bad = cover_cells(h, it, bp_cells)
      if same then
        it.reason = "exists"
      elseif bad or foreign or (#own > 0 and mode ~= "superforced") then
        it.reason = "cannot_place"
      elseif n_cover == 0 and #own == 0 and not can_ghost(h, it, true) then
        -- проверка движка с forced не считает помехой только то, что сносит Shift (деревья, камни);
        -- свои постройки (Ctrl+Shift) она помехой считает, поэтому при них на неё не опираемся
        it.reason = "cannot_place"
      else
        for _, e in ipairs(nat) do remove(e) end
        for _, e in ipairs(own) do remove(e) end
        for name, n in pairs(cover) do pre.tiles[name] = (pre.tiles[name] or 0) + n end
      end
    end
  end
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

--- Итог постановки (или её оценки): pre — tiles, tiles_skipped, to_remove, to_remove_total.
local function summary(h, plan, pre)
  local skipped, total, ghosts, need = {}, 0, 0, {}
  for _, it in ipairs(plan) do
    if it.reason ~= nil then
      total = total + 1
      if #skipped < B.MAX_LIST then
        skipped[#skipped + 1] = { name = it.name, pos = util.pos(it.pos), reason = it.reason }
      end
    else
      ghosts = ghosts + 1
      local item = B.place_items(it.proto)[1]
      if item ~= nil then need[item.name] = (need[item.name] or 0) + item.count end
    end
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
  return {
    ghosts = ghosts, skipped = skipped, skipped_total = total, missing = missing,
    tiles = pre.tiles, tiles_skipped = pre.tiles_skipped,
    to_remove = pre.to_remove, to_remove_total = pre.to_remove_total,
  }, n_tiles
end

local function tile_ghosts_in(h, area)
  return h.surface.find_entities_filtered{
    area = { area.left_top, area.right_bottom }, type = "tile-ghost", force = h.force,
  }
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
    local plan, tplan = M.layout(count > 0 and st.get_blueprint_entities() or {}, a.anchor, a.direction, bp_tiles)
    if #plan == 0 and #tplan == 0 then err.raise("bad_args", "args.blob: blueprint has no entities and no tiles") end
    local area = area_of(plan, tplan)
    if area.right_bottom.x - area.left_top.x > M.MAX_SIDE or area.right_bottom.y - area.left_top.y > M.MAX_SIDE then
      err.raise("limit", "blueprint is larger than " .. M.MAX_SIDE .. " tiles")
    end
    if not B.area_charted(h, area) then err.raise("not_charted", "blueprint area is in uncharted chunks") end
    local pre = precheck(h, plan, tplan, a.force)
    if a.dry_run then
      B.check_free(ctx, area)
      local s, n_tiles = summary(h, plan, pre)
      return { summary = s, n_tiles = n_tiles }
    end

    B.hold_area(ctx, area)
    -- что стояло здесь до нас: призраки (план хозяина — если движок вернёт такой в списке при
    -- наложении на одинаковый призрак, он считается поставленным, но убирать его нельзя),
    -- призраки плиток и уже помеченное к сносу (это не «наше» to_remove)
    local own_before, tiles_before, marked_before = {}, {}, {}
    for _, g in ipairs(h.surface.find_entities_filtered{
      area = { area.left_top, area.right_bottom }, type = "entity-ghost",
    }) do
      if g.valid then own_before[B.ghost_key(g.ghost_name, util.xy(g.position))] = true end
    end
    for _, g in ipairs(tile_ghosts_in(h, area)) do
      if g.valid then tiles_before[B.ghost_key(g.ghost_name, util.xy(g.position))] = true end
    end
    for _, m in ipairs(B.marked(h, area)) do marked_before[m.key] = true end

    local built = st.build_blueprint{
      surface = h.surface, force = h.force, position = a.anchor, direction = a.direction,
      build_mode = defines.build_mode[a.force], skip_fog_of_war = false, raise_built = true,
    }

    -- плитки: что появилось (плитки чертежа и подложки, которые добавил движок)
    local after_tiles = tile_ghosts_in(h, area)
    local bp_names, post = {}, { tiles = {}, tiles_skipped = 0, to_remove = {}, to_remove_total = 0 }
    for _, t in ipairs(tplan) do bp_names[t.name] = true end
    local created_bp = 0
    for _, g in ipairs(after_tiles) do
      if g.valid and not tiles_before[B.ghost_key(g.ghost_name, util.xy(g.position))] then
        post.tiles[g.ghost_name] = (post.tiles[g.ghost_name] or 0) + 1
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
    local created = {}
    for _, g in ipairs(built or {}) do
      if g.valid and g.type == "entity-ghost" then
        local c = { name = g.ghost_name, pos = util.xy(g.position) }
        if not inv.is_normal(g.quality) then
          c.why = "quality"
        elseif B.waits_for(sv, g.ghost_prototype, c.pos, g.direction) == nil
            and B.blocked(g.surface, g) and not B.body_inside(h, g.ghost_prototype, c.pos, g.direction) then
          c.why = "blocked"
        end
        if c.why ~= nil and not own_before[B.ghost_key(c.name, c.pos)] then
          g.destroy{ raise_destroy = true }
        end
        created[#created + 1] = c
      end
    end
    reconcile(plan, created)
    local s, n_tiles = summary(h, plan, post)
    return { summary = s, area = area, n_tiles = n_tiles }
  end)

  local s = out.summary
  if a.dry_run then return B.done(s) end
  task.bp = s
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
  local r = B.ghosts_tick(task, ctx)
  if r == nil then return nil end
  return merged(task, r)
end

function M.stop(task, ctx)
  if task.g ~= nil then B.ghosts_stop(task, ctx) else B.stop_approach(task, ctx) end
end

return M
