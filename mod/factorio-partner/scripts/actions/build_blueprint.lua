-- Действие `build_blueprint` (поток F): разложить чертёж призраками и построить их.
-- Контракт: docs/ACTIONS.md («build_blueprint»), PROTOCOL.md §4 (blob_put), §6.5, §7.
--
-- args: blob (id из blob_put), anchor (центр чертежа), direction? = 0 (0/4/8/12),
--       mode? = "auto"│"hand"│"robots", dry_run? = false.
-- done.detail: {ghosts, skipped:[{name,pos,reason}], skipped_total, missing,
--               + после стройки: built, left, blocked, blocked_total}.
-- Ход: строка из storage.blobs → game.create_inventory(1) → import_stack (1 → bad_args; -1 —
-- импорт с предупреждениями — принимается;
-- книги и планировщики → bad_args) → для каждой сущности проверка постановки призрака
-- (manual_ghost, §6.5) → build_blueprint{build_mode = normal, skip_fog_of_war = false} создаёт
-- призраки → inventory.destroy() → дальше как build_ghosts по площади чертежа.
-- После постановки каждый свой призрак проверяется ghost_revive: заблокированный (над ним
-- дроны висели бы вечно) и призрак не-normal качества сразу убираются и попадают в skipped.
-- dry_run — только проверки: {ghosts, skipped, missing}, призраков нет.
-- Плитки чертежа в v1 не ставятся (detail.tiles_skipped). Режимы forced/superforced запрещены.
-- Ошибки: bad_args (blob, не чертёж, пустой, direction), limit (> 1000 сущностей, сторона > 128),
-- not_charted, reserved, cannot_place (ни один призрак не встал), дальше — как build_ghosts.
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
  dry_run = { type = "bool", default = false },
}
M.MAX_ENTITIES = 1000
M.MAX_SIDE = 128
M.MATCH_DIST = 1.5   -- призрак «тот самый», если встал не дальше этого от расчётного места
M.PAD = 1.5          -- запас области вокруг чертежа

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

--- Расчётные места сущностей чертежа в мире: anchor — центр рамки чертежа, dir — поворот.
--- → {{name, proto, pos, dir, quality}, ...}
function M.layout(entities, anchor, dir)
  local x0, y0, x1, y1
  local items = {}
  for i, be in ipairs(entities) do
    local proto = prototypes.entity[be.name]
    local p = util.xy(be.position)
    local edir = be.direction or 0
    local hx, hy = B.half_size(proto, edir)
    x0 = math.min(x0 or p.x - hx, p.x - hx)
    y0 = math.min(y0 or p.y - hy, p.y - hy)
    x1 = math.max(x1 or p.x + hx, p.x + hx)
    y1 = math.max(y1 or p.y + hy, p.y + hy)
    items[i] = { name = be.name, proto = proto, p = p, dir = edir, quality = be.quality }
  end
  local out = {}
  if #items == 0 then return out end
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
  return out
end

local function area_of(plan)
  local x0, y0, x1, y1
  for _, it in ipairs(plan) do
    local hx, hy = B.half_size(it.proto, it.dir)
    x0 = math.min(x0 or it.pos.x - hx, it.pos.x - hx)
    y0 = math.min(y0 or it.pos.y - hy, it.pos.y - hy)
    x1 = math.max(x1 or it.pos.x + hx, it.pos.x + hx)
    y1 = math.max(y1 or it.pos.y + hy, it.pos.y + hy)
  end
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

--- Проверка «сюда можно поставить призрак» (PROTOCOL §6.5, manual_ghost) для каждой сущности.
local function precheck(h, plan)
  for _, it in ipairs(plan) do
    if it.proto == nil then
      it.reason = "unknown"
    elseif not inv.is_normal(it.quality) then
      it.reason = "quality"
    elseif not h.surface.can_place_entity{
      name = it.name, position = it.pos, direction = it.dir, force = h.force,
      build_check_type = defines.build_check_type.manual_ghost,
    } then
      it.reason = "cannot_place"
    end
  end
end

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

local function summary(h, plan)
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
  local main = h.get_main_inventory()
  local missing = {}
  for name, n in pairs(need) do
    local lack = n - inv.count(main, name)
    if lack > 0 then missing[name] = lack end
  end
  return { ghosts = ghosts, skipped = skipped, skipped_total = total, missing = missing }
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
    if count == 0 then err.raise("bad_args", "args.blob: blueprint has no entities") end
    if count > M.MAX_ENTITIES then
      err.raise("limit", "blueprint has " .. count .. " entities (≤ " .. M.MAX_ENTITIES .. ")")
    end
    local plan = M.layout(st.get_blueprint_entities() or {}, a.anchor, a.direction)
    if #plan == 0 then err.raise("bad_args", "args.blob: blueprint has no entities") end
    local area = area_of(plan)
    if area.right_bottom.x - area.left_top.x > M.MAX_SIDE or area.right_bottom.y - area.left_top.y > M.MAX_SIDE then
      err.raise("limit", "blueprint is larger than " .. M.MAX_SIDE .. " tiles")
    end
    if not B.area_charted(h, area) then err.raise("not_charted", "blueprint area is in uncharted chunks") end
    precheck(h, plan)
    if a.dry_run then
      B.check_free(ctx, area)
      return { summary = summary(h, plan) }
    end

    B.hold_area(ctx, area)
    -- плитки в v1 не ставим: убираем их из временной копии чертежа
    local tiles = st.get_blueprint_tiles()
    local tiles_skipped = type(tiles) == "table" and #tiles or 0
    if tiles_skipped > 0 then
      local ok = pcall(function() st.set_blueprint_tiles({}) end)
      if not ok then err.raise("bad_args", "args.blob: blueprints with tiles are not supported") end
    end
    -- призраки, которые стояли здесь до нас (план хозяина): если движок вернёт такой в списке
    -- (наложение на одинаковый призрак), он считается поставленным, но убирать его нельзя
    local own_before = {}
    for _, g in ipairs(h.surface.find_entities_filtered{
      area = { area.left_top, area.right_bottom }, type = "entity-ghost",
    }) do
      if g.valid then own_before[B.ghost_key(g.ghost_name, util.xy(g.position))] = true end
    end
    local built = st.build_blueprint{
      surface = h.surface, force = h.force, position = a.anchor, direction = a.direction,
      build_mode = defines.build_mode.normal, skip_fog_of_war = false, raise_built = true,
    }
    -- свои призраки, которые нельзя оживить (или не-normal качества), сразу убираем
    local created = {}
    for _, g in ipairs(built or {}) do
      if g.valid and g.type == "entity-ghost" then
        local c = { name = g.ghost_name, pos = util.xy(g.position) }
        if not inv.is_normal(g.quality) then
          c.why = "quality"
        elseif B.blocked(g.surface, g) and not B.body_inside(h, g.ghost_prototype, c.pos, g.direction) then
          c.why = "blocked"
        end
        if c.why ~= nil and not own_before[B.ghost_key(c.name, c.pos)] then
          g.destroy{ raise_destroy = true }
        end
        created[#created + 1] = c
      end
    end
    reconcile(plan, created)
    local s = summary(h, plan)
    s.tiles_skipped = tiles_skipped > 0 and tiles_skipped or nil
    return { summary = s, area = area }
  end)

  local s = out.summary
  if a.dry_run then return B.done(s) end
  task.bp = s
  if s.ghosts == 0 then
    return B.failed("cannot_place", "no ghost of the blueprint could be placed", s)
  end
  return B.ghosts_start(task, ctx, out.area, a.mode)
end

local function merged(task, res)
  local d = res.detail or {}
  local s = task.bp or {}
  d.ghosts, d.skipped, d.skipped_total, d.tiles_skipped = s.ghosts, s.skipped, s.skipped_total, s.tiles_skipped
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
