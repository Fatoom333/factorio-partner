-- Действие `build_layout`: поставить блок построек по смещениям от клетки-якоря — без строки
-- чертежа. Контракт: docs/ACTIONS.md («build_layout»), PROTOCOL.md §6.5, §6.12, §7 (layouts).
--
-- args: anchor (клетка-якорь, floor(x), floor(y)), entities (1..100) │ blob (id из blob_put:
--       JSON {entities, ports?}), direction? = 0 (0/4/8/12 — поворот блока вокруг якоря по часовой),
--       search? = 0 (0..32), rotate? = false, on_resource?, ports? (≤ 16), tag?, mode? = "auto",
--       auto_supply? = false, keep_ghosts? = false, dry_run? = false.
-- Постройка: {name, dx, dy │ cx, cy, direction? = 0, recipe?, type?, insert?}. dx, dy — левая
-- верхняя клетка постройки в её направлении; cx, cy — её центр от левого верхнего угла клетки
-- якоря (как в чертеже).
--
-- Ход: проверка аргументов (имена, рецепты, type, пересечения, рамка ≤ 64) → поиск места по
-- кольцам × поворотам с бюджетом работы на тик (место годно, если у каждой постройки оценка
-- manual_ghost — nil или «уже стоит», нет клеток без подложки, область открыта и не в чужом
-- резерве, буры стоят на руде on_resource) → dry_run: ответ → весь счёт предметов (постройки,
-- insert, подложка) и снабжение до призраков → призраки временным чертежом
-- (set_blueprint_entities с recipe и type, build_blueprint{build_mode=forced}; позиция считается
-- так, чтобы каждая постройка встала в расчётную клетку; сверка, при общем сдвиге — одна
-- перестановка) → стройка как build_ghosts → рецепт (призрак не донёс — set_recipe) и insert из
-- карманов → память блока под tag (scripts/lib/layout.lua).
-- Только режим forced: деревья и камни помечаются и разбираются самим помощником, постройки
-- хозяина и чужая сила не трогаются никогда. Отказ, отмена, застревание: свои пометки к сносу
-- снимаются, без keep_ghosts свои непостроенные призраки убираются.
local err = require("scripts.core.err")
local util = require("scripts.core.util")
local schema = require("scripts.core.schema")
local blobs = require("scripts.core.blobs")
local reserve = require("scripts.core.reserve")
local inv = require("scripts.lib.inventory")
local B = require("scripts.lib.build")
local G = require("scripts.lib.getitems")
local BP = require("scripts.lib.blueprint")
local layout = require("scripts.lib.layout")
local place_action = require("scripts.actions.place")

local perms = require("scripts.core.perms")

local M = {}
M.name = "build_layout"

--- Разрешения хозяина (scripts/core/perms.lua): какие ключи задевают эти аргументы.
--- Трата — предметы всех построек блока и их insert (аргументы уже развёрнуты из blob).
function M.perms(a, ctx)
  if a.dry_run then return {} end
  local keys = { "perm-build" }
  local n = 0
  for _, e in ipairs(a.entities or {}) do
    n = n + 1
    for _, c in pairs(e.insert or {}) do
      if type(c) == "number" then n = n + c end
    end
  end
  if n > perms.limit("spend") then keys[#keys + 1] = "perm-spend" end
  return keys
end

M.MAX_ENTITIES = 100
M.MAX_OFFSET = 64
M.MAX_FRAME = 64
M.MAX_PORTS = 16
M.MAX_INSERT_KINDS = 4
M.MAX_LIST = 20
M.SHORT_LIST = 10
M.MAX_EVENT = 3800      -- detail в событии (буфер ужимает события больше 4000 байт)
M.MODE = "forced"
-- Поиск места: «работа» кандидата = FIT_BASE + N (дешёвая проверка плиток), полная оценка + N × FIT_FULL.
M.FIT_OPS_TICK = 2000
M.FIT_MAX_OPS = 600000
M.FIT_BASE = 10
M.FIT_FULL = 4
M.SHIFT_EPS = 0.01      -- призрак встал не в расчётную клетку, если сдвинут больше этого

local ENTITY = {
  type = "object",
  fields = {
    name = { type = "string", required = true, max = 100 },
    dx = { type = "int", min = -M.MAX_OFFSET, max = M.MAX_OFFSET },
    dy = { type = "int", min = -M.MAX_OFFSET, max = M.MAX_OFFSET },
    cx = { type = "number", min = -M.MAX_OFFSET, max = M.MAX_OFFSET },
    cy = { type = "number", min = -M.MAX_OFFSET, max = M.MAX_OFFSET },
    direction = { type = "int", min = 0, max = 15 },
    recipe = { type = "string", max = 100 },
    type = { type = "enum", values = { "input", "output" } },
    insert = { type = "items" },
  },
}
local PORT = {
  type = "object",
  fields = {
    id = { type = "string", required = true, max = 16, pattern = "^[a-z0-9_%-]+$" },
    dx = { type = "int", required = true, min = -M.MAX_OFFSET, max = M.MAX_OFFSET },
    dy = { type = "int", required = true, min = -M.MAX_OFFSET, max = M.MAX_OFFSET },
    kind = { type = "enum", required = true, values = { "belt", "pipe", "power" } },
    io = { type = "enum", required = true, values = { "in", "out" } },
    dir = { type = "enum", values = { 0, 4, 8, 12 } },
    items = { type = "list", min = 1, max = 2, of = { type = "string", max = 100 } },
    fluid = { type = "string", max = 100 },
    rate = { type = "number", min = 0, max = 1000000 },   -- справочно (из forge), мод не использует
  },
}
local ENTITIES = { type = "list", min = 1, max = M.MAX_ENTITIES, of = ENTITY }
local PORTS = { type = "list", min = 1, max = M.MAX_PORTS, of = PORT }

M.schema = {
  anchor = { type = "pos", required = true },
  entities = ENTITIES,
  blob = { type = "string", max = 32, pattern = "^[a-z0-9%-]+$" },
  direction = { type = "enum", values = { 0, 4, 8, 12 }, default = 0 },
  search = { type = "int", min = 0, max = 32, default = 0 },
  rotate = { type = "bool", default = false },
  on_resource = { type = "string", max = 100 },
  ports = PORTS,
  tag = { type = "string", max = 32, pattern = "^[a-z0-9%-]+$" },
  mode = { type = "enum", values = { "auto", "hand", "robots" }, default = "auto" },
  auto_supply = { type = "bool", default = false },
  keep_ghosts = { type = "bool", default = false },
  dry_run = { type = "bool", default = false },
}

-- ------------------------------------------------------------------ геометрия блока

local function bad(text) err.raise("bad_args", text) end

--- Клетки постройки до поворота блока: левая верхняя клетка (x0, y0), размер w × h в её
--- направлении и центр (lx, ly) от левого верхнего угла клетки якоря.
local function cells_of(e)
  local proto = prototypes.entity[e.name]
  local w, h = B.tile_size(proto, e.direction or 0)
  local x0, y0
  if e.dx ~= nil then
    x0, y0 = e.dx, e.dy
  else
    x0, y0 = BP.snap(e.cx, w) - w / 2, BP.snap(e.cy, h) - h / 2
  end
  return x0, y0, w, h, x0 + w / 2, y0 + h / 2
end
M.cells_of = cells_of

--- Точка блока (от левого верхнего угла клетки якоря) → мир: поворот dir вокруг центра клетки якоря.
local function to_world(cell, lx, ly, dir)
  local rx, ry = BP.rot(lx - 0.5, ly - 0.5, dir)
  return { x = cell.x + 0.5 + rx, y = cell.y + 0.5 + ry }
end

local function anchor_cell(p)
  return { x = math.floor(p.x), y = math.floor(p.y) }
end

--- План сущностей блока в мире: {{i, name, proto, pos, dir, recipe, type, insert, no_item}, ...}.
function M.plan_at(entities, cell, dir)
  local plan = {}
  for i, e in ipairs(entities) do
    local proto = prototypes.entity[e.name]
    local _, _, _, _, lx, ly = cells_of(e)
    local it = {
      i = i, name = e.name, proto = proto, pos = to_world(cell, lx, ly, dir),
      dir = ((e.direction or 0) + dir) % 16, recipe = e.recipe, type = e.type, insert = e.insert,
    }
    if proto ~= nil and B.place_items(proto)[1] == nil then it.no_item = true end
    plan[i] = it
  end
  return plan
end

--- Порты блока в мире: {{id, kind, io, pos, dir?, items?, fluid?}, ...} (pos — центр клетки порта).
function M.ports_at(ports, cell, dir)
  local out = {}
  for k, p in ipairs(ports or {}) do
    local q = { id = p.id, kind = p.kind, io = p.io, pos = to_world(cell, p.dx + 0.5, p.dy + 0.5, dir) }
    if p.dir ~= nil then q.dir = (p.dir + dir) % 16 end
    if p.items ~= nil then q.items = util.copy(p.items) end
    q.fluid = p.fluid
    out[k] = q
  end
  return out
end

-- ------------------------------------------------------------------ проверка аргументов

local function merge_ports(base, over)
  if base == nil then return over end
  if over == nil then return base end
  local out, at = {}, {}
  for _, p in ipairs(base) do
    out[#out + 1] = p
    at[p.id] = #out
  end
  for _, p in ipairs(over) do
    if at[p.id] then out[at[p.id]] = p else out[#out + 1] = p end
  end
  if #out > M.MAX_PORTS then err.raise("limit", "args.args.ports: more than " .. M.MAX_PORTS .. " ports") end
  return out
end

local function from_blob(id)
  local str, received, total = blobs.get(id)
  if str == nil then
    bad("args.args.blob: blob " .. id .. " is not complete (" .. tostring(received) .. "/" ..
      tostring(total) .. " parts); send it with blob_put")
  end
  local ok, t = pcall(helpers.json_to_table, str)
  if not ok or type(t) ~= "table" then bad("args.args.blob: not a JSON object {entities, ports?}") end
  return schema.validate({ entities = { type = "list", min = 1, max = M.MAX_ENTITIES, of = ENTITY, required = true },
    ports = PORTS }, t, "args.args.blob")
end

--- Проверки, которые не выразить схемой: ровно одно из entities/blob, пары dx/dy │ cx/cy, имена,
--- recipe и type, insert, пересечения, рамка, порты.
function M.check_args(a, ctx)
  if (a.entities ~= nil) == (a.blob ~= nil) then bad("args.args: one of entities / blob is required") end
  if a.blob ~= nil then
    local t = from_blob(a.blob)
    a.entities = t.entities
    a.ports = merge_ports(t.ports, a.ports)
    a.blob = nil
  end
  local boxes = {}
  local fx0, fy0, fx1, fy1
  for i, e in ipairs(a.entities) do
    local path = "args.args.entities[" .. i .. "]"
    local cell = e.dx ~= nil or e.dy ~= nil
    local centre = e.cx ~= nil or e.cy ~= nil
    if cell and centre then bad(path .. ": use either dx, dy or cx, cy, not both") end
    if cell and (e.dx == nil or e.dy == nil) then bad(path .. ": dx and dy go together") end
    if centre and (e.cx == nil or e.cy == nil) then bad(path .. ": cx and cy go together") end
    if not cell and not centre then bad(path .. ": dx, dy or cx, cy is required") end
    local proto = prototypes.entity[e.name]
    if proto == nil then bad(path .. ".name: unknown entity " .. e.name) end
    if e.recipe ~= nil and proto.type ~= "assembling-machine" then
      bad(path .. ".recipe: recipe is only for assembling machines")
    end
    if e.type ~= nil and proto.type ~= "underground-belt" then
      bad(path .. ".type: type is only for underground belts")
    end
    if e.insert ~= nil then
      local n = 0
      for name in pairs(e.insert) do
        n = n + 1
        if inv.item_proto(name) == nil then bad(path .. ".insert: unknown item " .. name) end
        if inv.has_data(name) then bad(path .. ".insert." .. name .. ": items with data are not inserted") end
      end
      if n > M.MAX_INSERT_KINDS then
        err.raise("limit", path .. ".insert: at most " .. M.MAX_INSERT_KINDS .. " item kinds")
      end
    end
    local x0, y0, w, h = cells_of(e)
    for j, o in ipairs(boxes) do
      if x0 < o.x0 + o.w and o.x0 < x0 + w and y0 < o.y0 + o.h and o.y0 < y0 + h then
        bad(path .. ": entities[" .. i .. "] overlaps entities[" .. j .. "]")
      end
    end
    boxes[i] = { x0 = x0, y0 = y0, w = w, h = h }
    fx0, fy0 = math.min(fx0 or x0, x0), math.min(fy0 or y0, y0)
    fx1, fy1 = math.max(fx1 or x0 + w, x0 + w), math.max(fy1 or y0 + h, y0 + h)
  end
  if fx1 - fx0 > M.MAX_FRAME or fy1 - fy0 > M.MAX_FRAME then
    err.raise("limit", "args.args.entities: the block is larger than " .. M.MAX_FRAME .. "×" .. M.MAX_FRAME .. " cells")
  end
  local seen = {}
  for k, p in ipairs(a.ports or {}) do
    if seen[p.id] then bad("args.args.ports[" .. k .. "].id: duplicate port id") end
    seen[p.id] = true
    if p.items ~= nil and p.fluid ~= nil then bad("args.args.ports[" .. k .. "]: use either items or fluid") end
  end
  if a.on_resource ~= nil then
    local rp = prototypes.entity[a.on_resource]
    if rp == nil or rp.type ~= "resource" then bad("args.args.on_resource: unknown resource " .. a.on_resource) end
  end
  return a
end

-- ------------------------------------------------------------------ оценка места

local function drill_on(h, it, resource)
  local ok, r = pcall(function() return it.proto.mining_drill_radius end)
  r = ok and tonumber(r) or nil
  if r == nil then r = (B.half_size(it.proto, it.dir)) end
  local found = h.surface.find_entities_filtered{
    area = { { it.pos.x - r, it.pos.y - r }, { it.pos.x + r, it.pos.y + r } },
    type = "resource", name = resource, limit = 1,
  }
  return #found > 0
end

--- Оценка плана на месте (как при постановке): reason у каждой постройки (nil — встанет).
--- → pre (BP.precheck), область.
local function evaluate(ctx, plan, env)
  local h = ctx.entity
  local area = BP.area_of(plan, {})
  local pre = BP.precheck(h, plan, {}, M.MODE, env)
  for _, it in ipairs(plan) do
    if it.no_item then
      it.reason, it.why = "no_item", nil
    elseif it.reason == nil or it.reason == "exists" then
      local f = B.footprint(it.proto, it.pos, it.dir)
      if not B.area_charted(h, f) then
        it.reason, it.why = "not_charted", nil
      elseif reserve.area_holder(ctx.helper_id, f) ~= nil then
        it.reason, it.why = "reserved", nil
      end
    end
  end
  return pre, area
end

--- Кандидат годен? → ok, «работа», план, pre, область.
local function try_site(ctx, a, cell, dir, env)
  local h = ctx.entity
  local plan = M.plan_at(a.entities, cell, dir)
  local n = #plan
  local used = M.FIT_BASE + n
  for _, it in ipairs(plan) do
    local _, _, bad_cells = BP.wet_cells(h, it, {}, env, M.MODE)
    if bad_cells then return false, used end
  end
  local area = BP.area_of(plan, {})
  if not B.area_charted(h, area) or reserve.area_holder(ctx.helper_id, area) ~= nil then return false, used end
  used = used + n * M.FIT_FULL
  local pre = BP.precheck(h, plan, {}, M.MODE, env)
  if pre.on_liquid > 0 then return false, used end
  for _, it in ipairs(plan) do
    if not it.no_item and it.reason ~= nil and it.reason ~= "exists" then return false, used end
  end
  if a.on_resource ~= nil then
    for _, it in ipairs(plan) do
      if it.proto.type == "mining-drill" and it.reason == nil and not drill_on(h, it, a.on_resource) then
        return false, used
      end
    end
  end
  for _, it in ipairs(plan) do
    if it.no_item then it.reason = "no_item" end
  end
  return true, used, plan, pre, area
end

-- ------------------------------------------------------------------ detail

local CODE = { liquid = "cannot_place" }
local WHY = { liquid = "liquid" }

local function short(list, n)
  if type(list) ~= "table" or #list <= n then return list end
  local out = {}
  for k = 1, n do out[k] = list[k] end
  return out
end

--- Отказы плана простыми данными: [{i, name, pos, code, why?}].
local function failed_of(plan, extra)
  local out = {}
  for _, it in ipairs(plan or {}) do
    local code = it.reason
    if code ~= nil then
      local f = { i = it.i, name = it.name, pos = util.pos(it.pos), code = CODE[code] or code }
      f.why = it.why or WHY[code]
      out[#out + 1] = f
    end
  end
  for _, f in ipairs(extra or {}) do out[#out + 1] = f end
  table.sort(out, function(x, y) return x.i < y.i end)
  return out
end

--- need — предметы построек, которые встанут, их insert и подложка; missing — чего нет в карманах.
local function need_of(h, plan, pre)
  local need = {}
  for _, it in ipairs(plan) do
    if it.reason == nil then
      local item = B.place_items(it.proto)[1]
      if item ~= nil then need[item.name] = (need[item.name] or 0) + item.count end
      for name, n in pairs(it.insert or {}) do need[name] = (need[name] or 0) + n end
    end
  end
  for name, n in pairs(pre and pre.tiles or {}) do
    local item = BP.tile_item(name)
    if item ~= nil then need[item.name] = (need[item.name] or 0) + item.count * n end
  end
  local main = h.get_main_inventory()
  local missing = {}
  for name, n in pairs(need) do
    local lack = n - inv.count(main, name)
    if lack > 0 then missing[name] = lack end
  end
  return need, missing
end

local function json_len(t)
  local ok, json = pcall(helpers.table_to_json, t)
  return ok and #json or math.huge
end

--- Собрать detail: site, placed, failed, need, missing, to_remove, ports и всё из extra.
local function detail_of(task, extra)
  local d = {}
  for k, v in pairs(extra or {}) do d[k] = v end
  d.site = task.site_info
  local placed = task.placed or {}
  local failed = failed_of(task.plan, task.late_failed)
  d.placed, d.placed_total = short(placed, M.MAX_LIST), #placed
  d.failed, d.failed_total = short(failed, M.MAX_LIST), #failed
  d.need = d.need or task.need or {}
  d.missing = d.missing or task.missing or {}
  if task.pre ~= nil then
    d.to_remove = d.to_remove or task.pre.to_remove
    d.to_remove_total = d.to_remove_total or task.pre.to_remove_total
  end
  d.to_remove = d.to_remove or {}
  d.to_remove_total = d.to_remove_total or 0
  if task.ports_w ~= nil and #task.ports_w > 0 then d.ports = task.ports_w end
  if task.args.dry_run then d.dry_run = true end
  -- событие ≤ 4000 байт: списки урезаются, порты остаются
  local keys = { "placed", "failed", "to_remove", "blocked", "not_removed_list" }
  for _, n in ipairs({ M.SHORT_LIST, 5, 2, 0 }) do
    if json_len(d) <= M.MAX_EVENT then break end
    for _, key in ipairs(keys) do d[key] = short(d[key], n) end
  end
  return d
end

-- ------------------------------------------------------------------ ход

-- В task.plan прототипы не хранятся (там только простые данные): на время тика они
-- подставляются по имени и снимаются в конце.
local function attach(task)
  for _, it in ipairs(task.plan or {}) do it.proto = prototypes.entity[it.name] end
end

local function strip(task)
  for _, it in ipairs(task.plan or {}) do it.proto = nil end
end


local function set_phase(task, phase, done, total)
  task.phase = phase
  task.progress = { done = done, total = total, phase = phase }
end

local function site_info(task, cell, dir, shift)
  local s = task.site
  local info = { anchor = { x = cell.x, y = cell.y }, direction = dir, shift = shift, checked = s and s.checked or 0 }
  if s and s.limited then info.limit = true end
  return info
end

--- Место не нашлось: оценка в исходном месте; dry_run — done, иначе отказ.
local function no_site(task, ctx, limited)
  local a = task.args
  local cell = anchor_cell(a.anchor)
  task.site.limited = limited or nil
  local plan = M.plan_at(a.entities, cell, a.direction)
  local env = BP.new_env(ctx.entity)
  local pre = evaluate(ctx, plan, env)
  task.plan, task.pre = plan, pre
  task.ports_w = M.ports_at(a.ports, cell, a.direction)
  task.need, task.missing = need_of(ctx.entity, plan, pre)
  task.site_info = nil
  local d = detail_of(task, { reason = "site_not_found", site_checked = task.site.checked, site_limit = limited or nil })
  d.site = nil
  task.site = nil
  if a.dry_run then return B.done(d) end
  local code, text = "cannot_place", "no place for the whole block within " .. a.search .. " cells"
  local area = BP.area_of(plan, {})
  if not B.area_charted(ctx.entity, area) then
    code, text = "not_charted", "block area is in uncharted chunks"
  elseif reserve.area_holder(ctx.helper_id, area) ~= nil then
    code, text = "reserved", "block area is reserved by helper " .. tostring(reserve.area_holder(ctx.helper_id, area))
  end
  return B.failed(code, text, d)
end

--- Место найдено: dry_run — ответ; иначе резерв, счёт предметов и снабжение.
local function site_found(task, ctx, cell, dir, shift, plan, pre, area)
  local a, h = task.args, ctx.entity
  task.site_info = site_info(task, cell, dir, shift)
  task.cell, task.dir = cell, dir
  task.site = nil
  task.plan, task.pre, task.area = plan, pre, area
  task.ports_w = M.ports_at(a.ports, cell, dir)
  task.need, task.missing = need_of(h, plan, pre)
  if a.dry_run then
    task.placed = {}
    return B.done(detail_of(task))
  end
  B.hold_area(ctx, area)
  if next(task.missing) ~= nil then
    if not a.auto_supply then
      return B.failed("no_items", "not enough items for the block", detail_of(task))
    end
    set_phase(task, "supply", 0, 1)
    G.begin(task, ctx, task.need, {})
    task.pre_supply = true
    return nil
  end
  return M.place(task, ctx)
end

local function site_tick(task, ctx)
  local a, s = task.args, task.site
  local env = BP.new_env(ctx.entity)
  s.cover = s.cover or {}
  env.cover = s.cover
  local base = anchor_cell(a.anchor)
  local dirs = { a.direction }
  if a.rotate then
    for k = 1, 3 do dirs[#dirs + 1] = (a.direction + 4 * k) % 16 end
  end
  local cells = BP.ring(s.r)
  local budget = M.FIT_OPS_TICK
  task.progress_tick = ctx.tick   -- законно стоим на месте: идёт расчёт
  while budget > 0 do
    s.o = s.o + 1
    if s.o > #dirs then
      s.o = 1
      s.i = s.i + 1
      if s.i > #cells then
        s.i = 1
        s.r = s.r + 1
        if s.r > a.search then return no_site(task, ctx, false) end
        cells = BP.ring(s.r)
        set_phase(task, "site", s.r, a.search)
      end
    end
    local sh, dir = cells[s.i], dirs[s.o]
    local cell = { x = base.x + sh.dx, y = base.y + sh.dy }
    local ok, used, plan, pre, area = try_site(ctx, a, cell, dir, env)
    budget = budget - used
    s.ops = s.ops + used
    s.checked = s.checked + 1
    if ok then return site_found(task, ctx, cell, dir, { dx = sh.dx, dy = sh.dy }, plan, pre, area) end
    if s.ops >= M.FIT_MAX_OPS then return no_site(task, ctx, true) end
  end
  return nil
end

--- Сущности временного чертежа из плана (только те, что встанут); координаты — от клетки P.
local function bp_entities(sub, P)
  local list = {}
  for k, it in ipairs(sub) do
    list[k] = {
      entity_number = k, name = it.name, position = { x = it.pos.x - P.x, y = it.pos.y - P.y },
      direction = it.dir, recipe = it.recipe, type = it.type,
    }
  end
  return list
end

--- Общий сдвиг призраков от расчётных мест (все сдвинуты одинаково) или nil.
local function common_shift(sub)
  local off
  for _, it in ipairs(sub) do
    if it.ghost_pos ~= nil then
      local d = { x = it.ghost_pos.x - it.pos.x, y = it.ghost_pos.y - it.pos.y }
      if off == nil then
        off = d
      elseif math.abs(off.x - d.x) > M.SHIFT_EPS or math.abs(off.y - d.y) > M.SHIFT_EPS then
        return nil
      end
    end
  end
  if off == nil or (math.abs(off.x) <= M.SHIFT_EPS and math.abs(off.y) <= M.SHIFT_EPS) then return nil end
  return off
end

local function put_ghosts(task, ctx, sub, pos)
  local P = task.cell
  return BP.with_new_blueprint(bp_entities(sub, P), function(st)
    return BP.place(task, ctx, st, sub, {}, task.area, task.pre, {
      position = pos, direction = 0, build_mode = M.MODE, partial = false,
    })
  end)
end

--- Постановка призраков временным чертежом и начало стройки.
function M.place(task, ctx)
  local h = ctx.entity
  local env = BP.new_env(h)
  -- мир мог измениться, пока шло снабжение: оценка заново
  task.pre = evaluate(ctx, task.plan, env)
  local sub, exists = {}, 0
  for _, it in ipairs(task.plan) do
    if it.reason == nil then sub[#sub + 1] = it end
    if it.reason == "exists" then exists = exists + 1 end
  end
  task.surface, task.force_name = h.surface.name, h.force.name
  set_phase(task, "build", 0, #sub)
  if #sub > 0 then
    local P = task.cell
    local c = BP.frame_center(bp_entities(sub, P))
    local pos = { x = P.x + c.x, y = P.y + c.y }
    local out = put_ghosts(task, ctx, sub, pos)
    local off = not out.rolled_back and common_shift(sub) or nil
    if off ~= nil then
      -- движок поставил все призраки со сдвигом: убрать свои и поставить ещё раз с поправкой
      BP.remove_ghosts(task.surface, task.force_name, out.own)
      BP.unmark(task)
      task.unmarked = nil
      for _, it in ipairs(sub) do it.reason, it.why, it.ghost_pos = nil, nil, nil end
      out = put_ghosts(task, ctx, sub, { x = pos.x - off.x, y = pos.y - off.y })
      task.reshifted = true
    end
    task.own = out.own
    if out.rolled_back then
      task.placed = {}
      return B.failed("cannot_place", "the engine placed no cover tile under the block; the block was taken back",
        detail_of(task, { unmarked = task.unmarked }))
    end
    task.pre = { to_remove = out.summary.to_remove, to_remove_total = out.summary.to_remove_total, tiles = {} }
  end
  local ghosts = 0
  for _, it in ipairs(sub) do
    if it.reason == nil then ghosts = ghosts + 1 end
  end
  task.ghosts = ghosts
  if ghosts == 0 and exists == 0 then
    task.placed = {}
    return B.failed("cannot_place", "no building of the block could be placed", detail_of(task))
  end
  if ghosts == 0 then return M.setup_start(task, ctx) end
  return B.ghosts_start(task, ctx, task.area, task.args.mode)
end

-- ------------------------------------------------------------------ настройка

local function find_built(h, it)
  local list = h.surface.find_entities_filtered{
    name = it.name, position = it.pos, radius = 0.1, force = h.force,
  }
  for _, e in ipairs(list) do
    if e.valid and e.type ~= "entity-ghost" then return e end
  end
  return nil
end

--- Начать настройку построек, которые поставила задача (рецепт, insert).
function M.setup_start(task, ctx)
  local list = {}
  for _, it in ipairs(task.plan) do
    if it.reason == nil then list[#list + 1] = it.i end
  end
  task.setup = { k = 1, list = list }
  task.placed = {}
  task.late_failed = {}
  set_phase(task, "setup", 0, #list)
  return nil
end

local function recipe_of(e)
  local ok, r = pcall(function() return e.get_recipe() end)
  if not ok or r == nil then return nil end
  local okn, name = pcall(function() return r.name end)
  return okn and name or nil
end

local function finish(task, ctx)
  local a, h = task.args, ctx.entity
  if a.tag ~= nil then
    local placed = {}
    for _, it in ipairs(task.plan) do
      if it.reason == "exists" then placed[#placed + 1] = { i = it.i, name = it.name, pos = it.pos } end
    end
    for _, p in ipairs(task.placed) do placed[#placed + 1] = { i = p.i, name = p.name, pos = p.pos_raw } end
    table.sort(placed, function(x, y) return x.i < y.i end)
    local ports = {}
    for _, p in ipairs(task.ports_w or {}) do ports[p.id] = p end
    layout.write(task.helper, a.tag, {
      surface = h.surface.name, anchor = task.cell, direction = task.dir, tick = ctx.tick,
      placed = placed, ports = ports,
    })
  end
  for _, p in ipairs(task.placed) do p.pos_raw = nil end
  task.own = nil
  B.stop_approach(task, ctx)
  return B.done(detail_of(task, task.build_detail))
end

local function setup_tick(task, ctx)
  local s, h = task.setup, ctx.entity
  local i = s.list[s.k]
  if i == nil then return finish(task, ctx) end
  local it = task.plan[i]
  local e = find_built(h, it)
  if e == nil then
    -- призрак не построен (заблокирован) или постройку уже убрали
    it.reason = "blocked"
    s.k = s.k + 1
    return nil
  end
  local p = s.cur
  if p == nil then
    p = { i = it.i, name = it.name, pos = util.pos(e.position), pos_raw = util.xy(e.position), unit_number = e.unit_number }
    if it.recipe ~= nil and recipe_of(e) ~= it.recipe then
      local ok = pcall(function() e.set_recipe(it.recipe, B.NORMAL) end)
      if not ok or (recipe_of(e) ~= nil and recipe_of(e) ~= it.recipe) then p.recipe_set = false end
    end
    s.cur = p
  end
  if it.insert ~= nil and next(it.insert) ~= nil then
    local r = inv.approach(task, ctx, e, "reach")
    if r == nil then return nil end
    local main = h.get_main_inventory()
    local inserted, left = {}, {}
    for name, n in pairs(it.insert) do
      local moved = 0
      if r == true then
        local have = math.min(n, inv.count(main, name))
        if have > 0 then moved = inv.move(main, { entity = e }, name, have, h) end
      end
      inv.add(inserted, name, moved)
      inv.add(left, name, n - moved)
    end
    if next(inserted) ~= nil then p.inserted = inserted end
    if next(left) ~= nil then p.left = left end
    inv.stop_approach(task, ctx)
  end
  task.placed[#task.placed + 1] = p
  s.cur = nil
  s.k = s.k + 1
  set_phase(task, "setup", s.k - 1, #s.list)
  return nil
end

-- ------------------------------------------------------------------ интерфейс модуля

function M.start(task, ctx)
  local a, h = task.args, ctx.entity
  for i, e in ipairs(a.entities) do
    if e.recipe ~= nil then
      local why = place_action.why_bad_recipe(h, prototypes.entity[e.name], e.recipe)
      if why then return B.failed("bad_args", "args.entities[" .. i .. "].recipe: " .. why) end
    end
  end
  task.site = { r = 0, i = 1, o = 0, ops = 0, checked = 0 }
  set_phase(task, "site", 0, a.search)
  local ok, r = pcall(site_tick, task, ctx)
  strip(task)
  if not ok then error(r, 0) end
  return r
end

--- Что из плана уже стоит (стройка оборвалась): placed простыми данными.
local function placed_now(task, ctx)
  local out = {}
  for _, it in ipairs(task.plan or {}) do
    if it.reason == nil then
      local e = find_built(ctx.entity, it)
      if e ~= nil then
        out[#out + 1] = { i = it.i, name = it.name, pos = util.pos(e.position), unit_number = e.unit_number }
      end
    end
  end
  return out
end

local function build_result(task, ctx, r)
  local d = r.detail or {}
  task.build_detail = d
  if r.status == "done" then return nil end
  -- стройка оборвалась: что уже стоит — в placed
  task.placed = placed_now(task, ctx)
  return { status = r.status, code = r.code, text = r.text, detail = detail_of(task, d) }
end

local tick_inner

function M.tick(task, ctx)
  attach(task)
  local ok, r = pcall(tick_inner, task, ctx)
  strip(task)
  if not ok then error(r, 0) end
  return r
end

tick_inner = function(task, ctx)
  if task.site ~= nil then return site_tick(task, ctx) end
  if task.setup ~= nil then return setup_tick(task, ctx) end
  if task.pre_supply then
    local pre = G.pre_tick(task, ctx)
    if pre == nil then
      if task.progress ~= nil then task.progress.phase = "supply" end
      return nil
    end
    task.pre_supply = nil
    if pre ~= false then
      task.placed = {}
      local d = detail_of(task)
      d.supply = pre.detail
      if pre.code == "no_space" then return B.failed(pre.code, pre.text, d) end
      return B.failed("no_items", "could not get the items for the block", d)
    end
    task.need, task.missing = need_of(ctx.entity, task.plan, task.pre)
    if next(task.missing) ~= nil then
      task.placed = {}
      return B.failed("no_items", "not enough items for the block", G.with_supply(task, detail_of(task)))
    end
    return M.place(task, ctx)
  end
  local pre = G.pre_tick(task, ctx)
  if pre == nil then return nil end
  if pre ~= false then
    return build_result(task, ctx, G.build_failed(task, pre))
  end
  local r = B.ghosts_tick(task, ctx)
  if r == nil then
    if task.progress ~= nil then task.progress.phase = "build" end
    return nil
  end
  if r.status == "failed" and r.code == "no_items" and G.start_for_build(task, ctx, r) then return nil end
  local out = build_result(task, ctx, r)
  if out ~= nil then return out end
  return M.setup_start(task, ctx)
end

--- Отказ, отмена, застревание: снять свои пометки к сносу и (без keep_ghosts) убрать свои
--- непостроенные призраки. → {unmarked?, ghosts_removed?} — ядро дописывает это в detail итога.
function M.stop(task, ctx)
  strip(task)
  G.stop(task, ctx)
  BP.unmark(task)
  local out
  if task.own ~= nil and not task.args.keep_ghosts then
    task.ghosts_removed = BP.remove_ghosts(task.surface, task.force_name, task.own)
  end
  task.own = nil
  task.site = nil
  if task.g ~= nil then B.ghosts_stop(task, ctx) else B.stop_approach(task, ctx) end
  if task.unmarked ~= nil or task.ghosts_removed ~= nil then
    out = { unmarked = task.unmarked, ghosts_removed = task.ghosts_removed }
  end
  return out
end

--- Возврат после отступления: те же постройки, найденное место и поворот, без поиска. Уже
--- стоящие постройки дают exists и не мешают.
function M.resume_args(task)
  local a = task.args
  if type(a) ~= "table" or type(a.entities) ~= "table" then return nil end
  local out = util.copy(a)
  out.blob = nil
  if task.cell ~= nil then
    out.anchor = { x = task.cell.x, y = task.cell.y }
    out.direction = task.dir
    out.search = 0
    out.rotate = false
  end
  return out
end

return M
