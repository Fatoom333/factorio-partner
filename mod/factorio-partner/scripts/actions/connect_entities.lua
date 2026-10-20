-- Действие `connect_entities`: проложить ленту, трубу или линию опор между двумя концами и построить.
-- Контракт: docs/ACTIONS.md «connect_entities», PROTOCOL.md §6.5 (постановка призрака), §6.7 (открытые
-- чанки), §6.12 (свойства мира — из игры).
--
-- args: kind = "belt" │ "pipe" │ "power", from, to = конец: ровно одно из {pos, dir?}, {target},
--       {layout, port}, {layout, i}; via? (≤ 8 клеток по порядку), max_length = 200 (звеньев),
--       belt? │ pipe? │ pole?, underground = "auto" │ "never" │ "prefer", fluid?, build = true,
--       mode = "auto" │ "hand" │ "robots", auto_supply = false, dry_run = false.
--
-- Ход задачи (по тикам, состояние — task.cn, переживает сохранение):
--   search — поиск пути кусками from → via… → to (лента и труба — решатель scripts/vendor/router через
--            scripts/lib/beltpath.lua, опоры — A* scripts/lib/connect.lua); ни один призрак не
--            ставится, пока не найден весь путь;
--   check  — проверка постановки каждого звена, предупреждения, счёт предметов; звено уже не
--            ставится (мир изменился) — поиск заново (до 2 раз);
--   supply — auto_supply: весь недостающий счёт добывается как get_items до призраков;
--   place  — постановка призраков пачками; память прокладки storage.connect_last[helper];
--   build  — стройка B.ghosts_* кусками вдоль пути (только build = true).
-- Отказ, отмена, stuck: свои непостроенные призраки задачи убираются, пометки к сносу снимаются
-- (detail.removed, detail.unmarked). Отступление flee (отмена с req рефлекса) призраки оставляет:
-- после него задача с теми же аргументами находит их по памяти и не ищет путь заново (resumed).
-- Оставленное запоминается в storage.connect_fled[helper]; не вернулись за FLED_TTL тиков или
-- начали другую прокладку — свои призраки и пометки той задачи убираются.
local beltpath = require("scripts.lib.beltpath")
local C = require("scripts.lib.connect")
local B = require("scripts.lib.build")
local G = require("scripts.lib.getitems")
local vis = require("scripts.core.vis")
local err = require("scripts.core.err")

local perms = require("scripts.core.perms")

local M = {}
M.name = "connect_entities"

--- Разрешения хозяина (scripts/core/perms.lua): какие ключи задевают эти аргументы.
function M.perms(a, ctx)
  if a.dry_run or a.build == false then return {} end
  return { "perm-build" }
end

local ENDPOINT = {
  type = "object",
  fields = {
    pos = { type = "pos" },
    dir = { type = "enum", values = { 0, 4, 8, 12 } },   -- только при pos: направление, как у порта
    target = { type = "target" },
    layout = { type = "string", max = 32, pattern = "^[a-z0-9%-]+$" },   -- как tag у build_layout
    port = { type = "string", max = 16, pattern = "^[a-z0-9_%-]+$" },
    i = { type = "int", min = 1, max = 100 },
  },
}

M.schema = {
  kind = { type = "enum", values = { "belt", "pipe", "power" }, required = true },
  from = { type = ENDPOINT.type, fields = ENDPOINT.fields, required = true },
  to = { type = ENDPOINT.type, fields = ENDPOINT.fields, required = true },
  via = { type = "list", max = 8, of = "pos" },
  max_length = { type = "int", min = 1, max = 200, default = 200 },
  belt = { type = "string", max = 100 },
  pipe = { type = "string", max = 100 },
  pole = { type = "string", max = 100 },
  underground = { type = "enum", values = { "auto", "never", "prefer" } },
  fluid = { type = "string", max = 100 },
  build = { type = "bool", default = true },
  mode = { type = "enum", values = { "auto", "hand", "robots" }, default = "auto" },
  auto_supply = { type = "bool", default = false },
  dry_run = { type = "bool", default = false },
}

M.WORK_PER_TICK = 256         -- раскрытий решателя за тик (лента, труба)
M.POWER_WORK_PER_TICK = 4096  -- проверок клеток-кандидатов опор за тик
M.BASE_EXPANSIONS = 20000     -- бюджет одного куска: BASE + PER_TILE × расстояние
M.EXPANSIONS_PER_TILE = 100
M.TASK_BUDGETS = 4            -- на всю задачу — не больше стольких бюджетов куска
M.CHECK_PER_TICK = 50
M.PLACE_PER_TICK = 50
M.MAX_TICKS = 60 * 60 * 2     -- поиск, проверка и постановка дольше двух минут — сбой
M.MAX_CORNERS = 40
M.MAX_AREA_SIDE = 128
M.BUILD_PART = 32             -- стройка кусками вдоль пути: сторона куска
M.ENEMY_RADIUS = 32
M.ENEMY_EVERY = 16
M.RESEARCH = 2                -- повторов поиска, если звено перестало ставиться
M.CONFLICT_RETRIES = 3
M.FLEE_REQ = "reflex:flee"    -- req задачи отступления (scripts/reflexes/flee.lua)
M.FLED_TTL = 60 * 60 * 5      -- столько тиков ждут возврата призраки, оставленные отступлением
M.FLED_EVERY = 600

local floor, abs, min, max, ceil = math.floor, math.abs, math.min, math.max, math.ceil

local function failed(code, text, detail)
  return { status = "failed", code = code, text = text, detail = detail or {} }
end

local function center(c) return { x = c.x + 0.5, y = c.y + 0.5 } end

local KIND_FIELD = { belt = "belt", pipe = "pipe", power = "pole" }

-- ------------------------------------------------------------------ итог

local function grow(box, x, y, w)
  w = w or 1
  if box.x1 == nil then
    box.x1, box.y1, box.x2, box.y2 = x, y, x + w, y + w
    return
  end
  box.x1, box.y1 = min(box.x1, x), min(box.y1, y)
  box.x2, box.y2 = max(box.x2, x + w), max(box.y2, y + w)
end

local function as_area(box)
  return { left_top = { x = box.x1, y = box.y1 }, right_bottom = { x = box.x2, y = box.y2 } }
end

local function step_center(s)
  local w = s.w or 1
  return { x = s.x + w / 2, y = s.y + w / 2 }
end

--- Охват звеньев (only — какие считать: nil — все) и куски ≤ 128 для areas.
local function boxes_of(cn, only)
  local box, parts = {}, {}
  for _, s in ipairs(cn.flat) do
    if only == nil or only(s) then
      grow(box, s.x, s.y, s.w)
      local pk = floor(s.x / M.MAX_AREA_SIDE) * 100000 + floor(s.y / M.MAX_AREA_SIDE)
      parts[pk] = parts[pk] or {}
      grow(parts[pk], s.x, s.y, s.w)
    end
  end
  return box, parts
end

local function finish_warnings(cn)
  if cn.warned then return end
  cn.warned = true
  local w = cn.warnings
  if cn.kind ~= "power" and cn.tiles and cn.direct and cn.tiles > 2 * (cn.direct + 1) then
    w[#w + 1] = "long_detour"
  end
  if cn.narrow then w[#w + 1] = "narrow" end
  if cn.near_enemy then w[#w + 1] = "near_enemy" end
  if (cn.marked or 0) > 0 then w[#w + 1] = "marked_for_deconstruction:" .. cn.marked end
  if (cn.unseen or 0) > 0 then w[#w + 1] = "unseen:" .. cn.unseen end
  if cn.kind == "pipe" and cn.W ~= nil and cn.box ~= nil and cn.box.x1 ~= nil then
    local boxes = beltpath.pread(prototypes.entity[cn.W.belt], "fluidbox_prototypes")
    local ext = type(boxes) == "table" and boxes[1] and tonumber(beltpath.pread(boxes[1], "max_pipeline_extent")) or nil
    if ext ~= nil and ext > 0 and max(cn.box.x2 - cn.box.x1, cn.box.y2 - cn.box.y1) > ext then
      w[#w + 1] = "over_extent"
    end
  end
end

local function detail_of(cn)
  finish_warnings(cn)
  local d = {
    kind = cn.kind,
    length = #cn.flat,
    ghosts = cn.ghosts or 0,
    need = cn.need or {},
    chosen = cn.chosen,
    from_pos = cn.from_pos,
    to_pos = cn.to_pos,
    warnings = cn.warnings,
    resumed = cn.resumed or nil,
    dry_run = cn.dry or nil,
  }
  if cn.kind == "power" then
    d.poles = #cn.flat
  else
    d.undergrounds = cn.undergrounds or 0
    d.turns = cn.turns or 0
  end
  if cn.missing ~= nil and next(cn.missing) ~= nil then d.missing = cn.missing end
  local path = {}
  local corners = cn.corners or {}
  for i, c in ipairs(corners) do
    if i < M.MAX_CORNERS or i == #corners then path[#path + 1] = { x = c.x, y = c.y } end
  end
  d.path = path
  if #corners > #path then d.path_total = #corners end
  if cn.box ~= nil and cn.box.x1 ~= nil then
    d.area = as_area(cn.box)
    if cn.box.x2 - cn.box.x1 > M.MAX_AREA_SIDE or cn.box.y2 - cn.box.y1 > M.MAX_AREA_SIDE then
      d.areas = {}
      local keys = {}
      for k in pairs(cn.parts) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do d.areas[#d.areas + 1] = as_area(cn.parts[k]) end
    end
  end
  for k, v in pairs(cn.bsum or {}) do d[k] = v end
  return d
end

local function done(cn)
  return { status = "done", detail = detail_of(cn) }
end

local function fail_with(cn, code, text, extra)
  local d = detail_of(cn)
  for k, v in pairs(extra or {}) do d[k] = v end
  return failed(code, text, d)
end

--- Трата пути (perm-spend; по задаче: perm_gate и owner_ok) → failed │ nil. Только стройка.
local function spend_refused(task, cn)
  if not cn.build then return nil end
  local n = 0
  for _, c in pairs(cn.need or {}) do n = n + c end
  local code, text, data = perms.refusal(perms.add_spend({}, n), task)
  if code ~= nil then return fail_with(cn, code, text, data) end
  return nil
end

local function end_failed(code, which, p)
  local pos = center(p)
  if code == beltpath.UNCHARTED then return failed("not_charted", "the " .. which .. " is not charted", { pos = pos }) end
  if code == beltpath.FLUID then
    return failed("cannot_place", "the " .. which .. " touches a fluid box of another fluid", { reason = "fluid_mix", pos = pos })
  end
  return failed("cannot_place", "the " .. which .. " is blocked", { reason = "end_blocked", pos = pos })
end

-- ------------------------------------------------------------------ память и возобновление

local function chosen_from(kind, cells)
  local out = {}
  for _, c in ipairs(cells) do
    if c.u ~= nil then
      out.underground = out.underground or c.n
    else
      out[KIND_FIELD[kind]] = out[KIND_FIELD[kind]] or c.n
    end
  end
  return out
end

local function remember(cn, ctx)
  local cells = {}
  for i, s in ipairs(cn.flat) do
    cells[i] = { x = s.x, y = s.y, n = s.name, d = s.dir, u = s.utype, nat = s.natural or nil, w = s.w }
  end
  local box = boxes_of(cn)
  C.remember(ctx.helper_id, {
    sig = cn.sig, surface = cn.surface_index, area = box.x1 and as_area(box) or nil, cells = cells,
    kind = cn.kind, tick = ctx.tick,
  })
end

--- Память с той же подписью: все клетки — свой призрак или постройка, призраков хотя бы один →
--- "resumed" (cn.flat собран); призраки есть, но путь порван → убрать их, "stale"; иначе nil.
local function try_resume(cn, rec, surface, force)
  local ghosts, broken = 0, false
  local flat = {}
  for i, c in ipairs(rec.cells) do
    if type(c) ~= "table" or type(c.x) ~= "number" or type(c.y) ~= "number" or type(c.n) ~= "string" then return nil end
    local w = c.w or 1
    local g = C.own_ghost(surface, force.name, c.x, c.y, c.n, w)
    if g ~= nil then
      ghosts = ghosts + 1
    elseif not C.built_at(surface, force.name, c.x, c.y, c.n, w) then
      broken = true
    end
    flat[i] = { x = c.x, y = c.y, name = c.n, dir = c.d, utype = c.u, natural = c.nat, w = c.w, placed = g ~= nil or nil }
  end
  if ghosts == 0 then return nil end
  cn.flat = flat
  if broken then return "stale" end
  return "resumed"
end

-- ------------------------------------------------------------------ старт

local function point_dir(d)
  if d == 0 or d == 4 or d == 8 or d == 12 then return d end
  return nil
end

--- Концы ленты.
local function start_belt(cn, a, rf, rt, vias, surface, force)
  local probe = { surface = surface, force = force }
  local fb, fdir = beltpath.belt_at(probe, rf.cell.x, rf.cell.y)
  local tb = beltpath.belt_at(probe, rt.cell.x, rt.cell.y)
  local belt = C.pick("belt", force, a.belt, { fb, tb })
  local under = C.pick_under("belt", force, belt, a.underground or "auto", cn.warnings)
  cn.W = beltpath.new_world(belt, under)
  cn.umode = under and (a.underground or "auto") or "never"
  cn.chosen = { belt = belt, underground = under }
  local points = { { x = rf.cell.x, y = rf.cell.y, dir = rf.dir or point_dir(fdir) } }
  for _, v in ipairs(vias) do points[#points + 1] = { x = v.x, y = v.y } end
  points[#points + 1] = { x = rt.cell.x, y = rt.cell.y, dir = rt.dir }
  return points
end

--- Концы трубы: клетки, разрешённые коробки концов, жидкость.
local function start_pipe(cn, a, rf, rt, vias, surface, force)
  local fp = rf.cell and C.entity_of_type(surface, rf.cell.x, rf.cell.y, "pipe")
  local tp = rt.cell and C.entity_of_type(surface, rt.cell.x, rt.cell.y, "pipe")
  local pipe = C.pick("pipe", force, a.pipe, { fp and fp.name, tp and tp.name })
  local under = C.pick_under("pipe", force, pipe, a.underground or "auto", cn.warnings)
  cn.W = beltpath.new_world(pipe, under, "pipe")
  cn.W.allow = {}
  cn.umode = under and (a.underground or "auto") or "never"
  cn.chosen = { pipe = pipe, underground = under }
  local fluids = {}
  local cells = {}
  for idx, r in ipairs({ rf, rt }) do
    local other = idx == 1 and C.raw_pos(rt) or C.raw_pos(rf)
    local which = idx == 1 and "from" or "to"
    local fl
    if r.entity ~= nil then
      local p, reason = C.pipe_port(surface, force, pipe, r.entity, a.fluid, other)
      if p == nil then
        if reason == "no_fluidbox" then err.raise("bad_args", "args." .. which .. ": " .. r.entity.name .. " has no fluid boxes") end
        return nil, failed("cannot_place", "args." .. which .. ": " .. (reason == "fluid_mix"
          and "no fluid box of " .. r.entity.name .. " takes " .. tostring(a.fluid)
          or "every pipe connection of " .. r.entity.name .. " is taken or blocked"), { reason = reason, pos = r.entity.position })
      end
      cn.W.allow[p.unit] = p.box
      cells[idx] = { x = p.x, y = p.y }
      fl = p.fluid
    else
      cells[idx] = { x = r.cell.x, y = r.cell.y }
      fl = r.port and r.port.fluid or nil
      -- в клетке уже стоит что-то с жидкостью (конец трубы): её коробка — своя
      for _, e in ipairs(surface.find_entities_filtered{ area = { left_top = { x = r.cell.x + 0.05, y = r.cell.y + 0.05 },
          right_bottom = { x = r.cell.x + 0.95, y = r.cell.y + 0.95 } } }) do
        local n, fb = beltpath.boxes(e)
        if e.valid and n > 0 then
          cn.W.allow[e.unit_number] = 1
          fl = fl or C.box_fluid(fb, 1)
        end
      end
    end
    if a.fluid ~= nil and fl ~= nil and fl ~= a.fluid then
      return nil, failed("cannot_place", "args." .. which .. " carries " .. fl .. ", not " .. a.fluid,
        { reason = "fluid_mix", pos = center(cells[idx]) })
    end
    fluids[idx] = fl
  end
  if fluids[1] ~= nil and fluids[2] ~= nil and fluids[1] ~= fluids[2] then
    return nil, failed("cannot_place", "the ends carry different fluids: " .. fluids[1] .. " and " .. fluids[2],
      { reason = "fluid_mix" })
  end
  local points = { { x = cells[1].x, y = cells[1].y } }
  for _, v in ipairs(vias) do points[#points + 1] = { x = v.x, y = v.y } end
  points[#points + 1] = { x = cells[2].x, y = cells[2].y }
  return points
end

--- Концы опор.
local function start_power(cn, a, rf, rt, vias, surface, force)
  local function pole_in(r)
    if r.entity ~= nil then return r.entity.type == "electric-pole" and r.entity or nil end
    return C.entity_of_type(surface, r.cell.x, r.cell.y, "electric-pole")
  end
  local fp, tp = pole_in(rf), pole_in(rt)
  local pole = C.pick("power", force, a.pole, { fp and fp.name, tp and tp.name })
  local P = C.pole_info(pole)
  if P.reach <= 0 then err.raise("bad_args", "args.pole: " .. pole .. " has no wire reach") end
  cn.P = P
  cn.W = beltpath.new_world(pole, nil, "power", P.w)
  cn.chosen = { pole = pole }
  local function desc(r, e)
    if e ~= nil then return C.power_end({ entity = e }) end
    return C.power_end(r)
  end
  local points = { desc(rf, fp) }
  for _, v in ipairs(vias) do points[#points + 1] = { kind = "cell", x = v.x, y = v.y } end
  points[#points + 1] = desc(rt, tp)
  return points
end

local function point_pos(cn, p)
  if p.kind == nil or p.kind == "cell" then
    local w = cn.P and cn.P.w or 1
    return { x = p.x + w / 2, y = p.y + w / 2 }
  end
  return { x = p.pos.x, y = p.pos.y }
end

-- ------------------------------------------------------------------ оставленное отступлением

--- Запомнить свои призраки и пометки задачи, снятой отступлением (простые таблицы).
local function keep_fled(helper_id, cn, tick)
  local mem = storage.connect_fled
  if type(mem) ~= "table" then return end
  local steps = {}
  for _, s in ipairs(cn.flat or {}) do
    if s.placed or s.marks ~= nil then
      steps[#steps + 1] = { x = s.x, y = s.y, name = s.name, w = s.w, placed = s.placed, marks = s.marks }
    end
  end
  if #steps == 0 then mem[helper_id] = nil return end
  mem[helper_id] = { sig = cn.sig, tick = tick, surface = cn.surface, force = cn.force, flat = steps }
end

--- Убрать оставленное отступлением: призраки, пометки и память прокладки той задачи.
local function drop_fled(helper_id, fr)
  storage.connect_fled[helper_id] = nil
  if type(fr) ~= "table" or type(fr.flat) ~= "table" then return end
  C.cleanup(fr)
  C.forget(helper_id, fr.sig)
end

--- Новая прокладка помощника: та же подпись — оставленное подхватит возобновление по памяти,
--- другая — убрать оставленное.
local function take_fled(helper_id, sig)
  local mem = storage.connect_fled
  local fr = type(mem) == "table" and mem[helper_id] or nil
  if fr == nil then return end
  if type(fr) == "table" and fr.sig == sig and C.last(helper_id) ~= nil then
    mem[helper_id] = nil
  else
    drop_fled(helper_id, fr)
  end
end

function M.expire_fled(tick)
  local mem = storage.connect_fled
  if type(mem) ~= "table" then return end
  local old = {}
  for helper_id, fr in pairs(mem) do
    if type(fr) ~= "table" or (tonumber(fr.tick) or 0) + M.FLED_TTL <= tick then old[#old + 1] = helper_id end
  end
  for _, helper_id in ipairs(old) do drop_fled(helper_id, mem[helper_id]) end
end

M.on_nth = { [M.FLED_EVERY] = function(e) M.expire_fled(e.tick) end }

function M.start(task, ctx)
  local a = task.args
  local h = ctx.entity
  local surface, force = h.surface, h.force
  for kind, field in pairs(KIND_FIELD) do
    if a[field] ~= nil and a.kind ~= kind then
      return failed("bad_args", "args." .. field .. ": only for kind " .. kind)
    end
  end
  if a.kind == "power" and a.underground ~= nil then return failed("bad_args", "args.underground: not for kind power") end
  if a.kind ~= "pipe" and a.fluid ~= nil then return failed("bad_args", "args.fluid: only for kind pipe") end
  if a.fluid ~= nil and prototypes.fluid ~= nil and prototypes.fluid[a.fluid] == nil then
    return failed("bad_args", "args.fluid: unknown fluid " .. a.fluid)
  end

  local cn = {
    kind = a.kind, dry = a.dry_run and true or false, build = a.build and not a.dry_run,
    mode = a.mode, max_length = a.max_length, sig = C.signature(a),
    surface = surface.name, surface_index = surface.index, force = force.name,
    warnings = {}, ticks = 0, expansions = 0, flat = {}, corners = {}, turns = 0, undergrounds = 0,
    tiles = 0, marked = 0, research = 0,
  }

  if not cn.dry then take_fled(ctx.helper_id, cn.sig) end
  -- возобновление: те же аргументы, свои призраки прошлой прокладки на месте
  local rec = C.last(ctx.helper_id)
  if rec ~= nil and rec.sig == cn.sig and rec.surface == surface.index then
    local r = try_resume(cn, rec, surface, force)
    if r == "resumed" then
      cn.resumed = true
      cn.chosen = chosen_from(a.kind, rec.cells)
      local first, last = cn.flat[1], cn.flat[#cn.flat]
      cn.from_pos, cn.to_pos = step_center(first), step_center(last)
      cn.box, cn.parts = boxes_of(cn)
      cn.need, cn.ghosts = {}, 0
      for _, s in ipairs(cn.flat) do
        if s.placed then
          cn.ghosts = cn.ghosts + 1
          local item, count = beltpath.item_of(s.name)
          if item then cn.need[item] = (cn.need[item] or 0) + count end
        end
        local cc = step_center(s)
        if #cn.corners == 0 or s == last then cn.corners[#cn.corners + 1] = cc end
      end
      task.cn = cn
      task.progress_tick = ctx.tick
      cn.missing = C.missing(h, cn.need)
      if not cn.build then return done(cn) end
      local refused = spend_refused(task, cn)
      if refused ~= nil then return refused end
      if next(cn.missing) ~= nil then
        if not a.auto_supply then
          return fail_with(cn, "no_items", "not enough items to build the remembered path")
        end
        G.begin(task, ctx, cn.need)
        cn.stage, cn.after_supply = "supply", "build"
        return nil
      end
      cn.stage = "build"
      cn.bsum = nil
      return nil
    elseif r == "stale" and not cn.dry then
      C.cleanup(cn)
      C.forget(ctx.helper_id)
    end
    cn.flat = {}
  end

  local rf = C.raw_end(ctx, a.from, a.kind, "from")
  local rt = C.raw_end(ctx, a.to, a.kind, "to")
  local vias = {}
  for i, v in ipairs(a.via or {}) do
    local c = { x = floor(v.x), y = floor(v.y) }
    if not B.charted(h, center(c)) then return failed("not_charted", "args.via[" .. i .. "] is not charted") end
    vias[#vias + 1] = c
  end

  local points, fail
  if a.kind == "belt" then
    points = start_belt(cn, a, rf, rt, vias, surface, force)
  elseif a.kind == "pipe" then
    points, fail = start_pipe(cn, a, rf, rt, vias, surface, force)
    if points == nil then return fail end
  else
    points = start_power(cn, a, rf, rt, vias, surface, force)
  end
  cn.points = points
  cn.from_pos, cn.to_pos = point_pos(cn, points[1]), point_pos(cn, points[#points])

  -- расстояние, рамка, бюджет, заведомо длинный путь
  local far, direct = 0, 0
  local x1, y1, x2, y2
  for i, p in ipairs(points) do
    local q = point_pos(cn, p)
    x1, y1 = min(x1 or q.x, q.x), min(y1 or q.y, q.y)
    x2, y2 = max(x2 or q.x, q.x), max(y2 or q.y, q.y)
    if i > 1 then
      local o = point_pos(cn, points[i - 1])
      local dm = abs(q.x - o.x) + abs(q.y - o.y)
      far = far + dm
      direct = direct + dm
      if a.kind ~= "power" and dm == 0 then
        return failed("bad_args", "two consecutive points of the path are the same tile")
      end
    end
  end
  cn.direct = direct
  local margin = 48 + floor(far / 4) + (cn.P and ceil(cn.P.reach) or 0)
  cn.bounds = {
    min_x = floor(x1) - margin, min_y = floor(y1) - margin, max_x = floor(x2) + margin, max_y = floor(y2) + margin,
  }
  cn.total = M.TASK_BUDGETS * (M.BASE_EXPANSIONS + M.EXPANSIONS_PER_TILE * far)
  local lower
  if a.kind == "power" then
    local d = 0
    for i = 2, #points do
      local p, q = point_pos(cn, points[i - 1]), point_pos(cn, points[i])
      d = d + math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2)
    end
    lower = ceil(d / cn.P.reach) - 1
    if #points == 2 and C.already(cn.P, points[1], points[2]) then
      cn.warnings[#cn.warnings + 1] = "already_connected"
      cn.box, cn.parts = {}, {}
      return done(cn)
    end
  else
    lower = ceil((direct + 1) / max(1, cn.W.max_under))
  end
  if lower > a.max_length then
    return failed("path_failed", "the path needs more than " .. a.max_length .. " links",
      { reason = "too_long", reached = cn.from_pos, left = direct, expanded = 0 })
  end
  cn.seg, cn.stage = 1, "search"
  task.cn = cn
  task.progress_tick = ctx.tick
  task.progress = { done = 0, total = #points - 1, phase = "search" }
  return nil
end

-- ------------------------------------------------------------------ поиск: лента и труба

local function launch(cn, env, retries)
  local k, pts = cn.seg, cn.points
  local s, g = pts[k], pts[k + 1]
  local last = k + 1 == #pts
  local start = { x = s.x, y = s.y, direction = k == 1 and s.dir or nil }
  local skip_first = false
  if k == 1 then
    local sc = beltpath.cell(env, s.x, s.y)
    if sc == beltpath.ENTITY then
      skip_first = true
    elseif sc <= 0 then
      return end_failed(sc, "start", s)
    end
  else
    skip_first = true
    local prev = cn.flat[#cn.flat]
    -- после выхода подземной пары путь идёт только прямо
    if prev ~= nil and prev.utype == "output" then start.direction = prev.dir end
  end
  local gc = beltpath.cell(env, g.x, g.y)
  local skip_last = false
  if gc == beltpath.ENTITY and last then
    skip_last = true
  elseif gc <= 0 then
    return end_failed(gc, last and "end" or "via point", g)
  end
  local left = cn.total - cn.expansions
  if left < 1 then
    return fail_with(cn, "path_failed", "the search budget of the task is exhausted",
      { reason = "budget", expanded = cn.expansions, reached = center(s), left = abs(s.x - g.x) + abs(s.y - g.y) })
  end
  local dist = abs(s.x - g.x) + abs(s.y - g.y)
  cn.job = {
    start = start,
    goal = { x = g.x, y = g.y, direction = last and g.dir or nil },
    underground = cn.umode,
    final_dir = last and g.dir or nil,
    skip_first = skip_first,
    skip_last = skip_last,
    retries = retries or 0,
  }
  cn.search = beltpath.new_search(cn.W, cn.job, min(M.BASE_EXPANSIONS + M.EXPANSIONS_PER_TILE * dist, left), cn.bounds)
  return nil
end

local function add_corners(cn, list)
  for _, c in ipairs(list) do
    local p = center(c)
    local prev = cn.corners[#cn.corners]
    if prev == nil or prev.x ~= p.x or prev.y ~= p.y then cn.corners[#cn.corners + 1] = p end
  end
end

local function to_check(cn)
  cn.stage, cn.ci = "check", 1
  cn.need, cn.ghosts, cn.marked = {}, 0, 0
  cn.unseen, cn.narrow, cn.near_enemy = 0, nil, nil
  cn.search, cn.psearch, cn.job = nil, nil, nil
end

local function on_route(cn, env, status, route)
  local job = cn.job
  if status == "found" and beltpath.reject_conflict(cn.W, route) then
    if job.retries < M.CONFLICT_RETRIES then return launch(cn, env, job.retries + 1) end
    status = "unreachable"
  end
  if status ~= "found" then
    local reached = job.reached or job.start
    return fail_with(cn, "path_failed", "no " .. cn.kind .. " path (" .. status .. ")", {
      reached = center(reached), left = abs(reached.x - job.goal.x) + abs(reached.y - job.goal.y),
      expanded = cn.expansions, reason = status == "limit" and "budget" or "unreachable", segment = cn.seg,
    })
  end
  local steps, stats = beltpath.route_steps(cn.W, route,
    { skip_first = job.skip_first, skip_last = job.skip_last, final_dir = job.final_dir })
  if #cn.flat + #steps > cn.max_length then
    local lastn = route.nodes[#route.nodes]
    return fail_with(cn, "path_failed", "the path is longer than " .. cn.max_length .. " links", {
      reason = "too_long", reached = center(lastn), left = 0, expanded = cn.expansions,
      length = #cn.flat + #steps,
    })
  end
  if cn.seg > 1 and cn.kind == "belt" then
    -- лента в точке via поворачивает туда, куда пошёл следующий кусок
    local prev, first = cn.flat[#cn.flat], route.edges[1]
    if prev ~= nil and prev.utype == nil and first ~= nil and prev.dir ~= first.direction then
      prev.dir = first.direction
      cn.turns = cn.turns + 1
    end
  end
  beltpath.commit(cn.W, steps)
  for _, s in ipairs(steps) do cn.flat[#cn.flat + 1] = s end
  cn.turns = cn.turns + stats.turns
  cn.undergrounds = cn.undergrounds + stats.undergrounds
  cn.tiles = cn.tiles + stats.length - (cn.seg > 1 and 1 or 0)
  add_corners(cn, stats.corners)
  cn.seg = cn.seg + 1
  if cn.seg >= #cn.points then to_check(cn) end
  return nil
end

-- ------------------------------------------------------------------ поиск: опоры

local function launch_power(cn, env)
  local k, pts = cn.seg, cn.points
  local s, g = pts[k], pts[k + 1]
  local start
  if k == 1 then
    start = s
    if s.kind == "cell" then
      local sc = beltpath.cell(env, s.x, s.y)
      if sc <= 0 then return end_failed(sc, "start", s) end
    end
  else
    start = { kind = "cell", x = s.x, y = s.y, placed = true }
  end
  if g.kind == "cell" then
    local gc = beltpath.cell(env, g.x, g.y)
    if gc <= 0 then return end_failed(gc, k + 1 == #pts and "end" or "via point", g) end
  end
  local left = cn.total - cn.expansions
  if left < 1 then
    return fail_with(cn, "path_failed", "the search budget of the task is exhausted", { reason = "budget", expanded = cn.expansions })
  end
  local a, b = point_pos(cn, s), point_pos(cn, g)
  local dist = abs(a.x - b.x) + abs(a.y - b.y)
  cn.psearch = C.power_new(cn.P, start, g, min(M.BASE_EXPANSIONS + M.EXPANSIONS_PER_TILE * dist, left),
    cn.max_length - #cn.flat, cn.bounds)
  return nil
end

local function on_poles(cn, env, status, cells)
  local S = cn.psearch
  cn.psearch = nil
  if status ~= "found" then
    local reached = S.reached and step_center({ x = S.reached.x, y = S.reached.y, w = cn.P.w }) or point_pos(cn, cn.points[cn.seg])
    local reason = status == "limit" and "budget" or (status == "too_long" and "too_long" or "unreachable")
    return fail_with(cn, "path_failed", "no pole line to the target (" .. status .. ")", {
      reached = reached, left = S.best_h and floor(S.best_h * cn.P.reach + 0.5) or nil,
      expanded = cn.expansions, reason = reason, segment = cn.seg,
    })
  end
  local W, w = cn.W, cn.P.w
  for _, c in ipairs(cells) do
    local code = beltpath.cell(env, c.x, c.y)
    local s = { x = c.x, y = c.y, name = W.belt, dir = 0, w = w > 1 and w or nil, natural = code == beltpath.NATURAL or nil }
    cn.flat[#cn.flat + 1] = s
    cn.corners[#cn.corners + 1] = step_center(s)
    -- клетки опоры и всё, что её бы задело, — заняты для следующих кусков
    for dx = -(w - 1), w - 1 do
      for dy = -(w - 1), w - 1 do W.cells[beltpath.key(c.x + dx, c.y + dy)] = beltpath.PLANNED end
    end
  end
  cn.seg = cn.seg + 1
  if cn.seg >= #cn.points then to_check(cn) end
  return nil
end

local function search_tick(cn, env, task)
  task.progress = { done = cn.seg - 1, total = #cn.points - 1, phase = "search" }
  if cn.kind == "power" then
    if cn.psearch == nil then
      local r = launch_power(cn, env)
      if r ~= nil then return r end
    end
    local S = cn.psearch
    local before = S.expansions
    local status, cells = C.power_step(S, env, cn.P, M.POWER_WORK_PER_TICK)
    cn.expansions = cn.expansions + (S.expansions - before)
    if status == "running" then return nil end
    return on_poles(cn, env, status, cells)
  end
  if cn.search == nil then
    local r = launch(cn, env)
    if r ~= nil then return r end
  end
  local status, route = beltpath.step(cn.search, env, cn.job, M.WORK_PER_TICK)
  if status == "running" then return nil end
  cn.expansions = cn.expansions + (cn.search.expansions or 0)
  cn.search = nil
  return on_route(cn, env, status, route)
end

-- ------------------------------------------------------------------ проверка, постановка

--- Звено перестало ставиться: убрать поставленное, запретить клетку, искать заново.
local function research(cn, bad)
  C.cleanup(cn)
  if cn.research >= M.RESEARCH then
    return fail_with(cn, "path_failed", "the path got blocked while placing", {
      reason = "unreachable", reached = step_center(bad), expanded = cn.expansions,
    })
  end
  cn.research = cn.research + 1
  local W = cn.W
  local w = cn.P and cn.P.w or 1
  for _, s in ipairs(cn.flat) do
    for dx = -(w - 1), w - 1 do
      for dy = -(w - 1), w - 1 do
        local k = beltpath.key(s.x + dx, s.y + dy)
        W.cells[k], W.ucells[k] = nil, nil
      end
    end
  end
  W.pu = nil
  W.cells[beltpath.key(bad.x, bad.y)] = beltpath.ENTITY
  cn.flat, cn.corners, cn.turns, cn.undergrounds, cn.tiles = {}, {}, 0, 0, 0
  cn.seg, cn.stage = 1, "search"
  return nil
end

local function enemy_forces(force)
  local out = {}
  for name, f in pairs(game.forces) do
    if name ~= force.name and name ~= "neutral" and force.is_enemy(f) then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

local function place_one(cn, env, s, dry)
  if cn.kind == "power" then return C.place_pole(env, s, cn.P.w, dry) end
  return beltpath.place(env, s, dry)
end

local function check_tick(cn, env, ctx, task)
  local last = min(#cn.flat, cn.ci + M.CHECK_PER_TICK - 1)
  local enemies
  for i = cn.ci, last do
    local s = cn.flat[i]
    local ok, marked = place_one(cn, env, s, true)
    if not ok then return research(cn, s) end
    cn.marked = cn.marked + marked
    cn.ghosts = cn.ghosts + 1
    local item, count = beltpath.item_of(s.name)
    if item then cn.need[item] = (cn.need[item] or 0) + count end
    if beltpath.unseen(env, s.x, s.y) then cn.unseen = cn.unseen + 1 end
    if cn.kind ~= "power" and not cn.narrow and s.utype == nil and beltpath.width_at(env, s) <= 2 then
      cn.narrow = true
    end
    if not cn.near_enemy and (i - 1) % M.ENEMY_EVERY == 0 then
      enemies = enemies or enemy_forces(env.force)
      if #enemies > 0 then
        for _, e in ipairs(env.surface.find_entities_filtered{
          position = step_center(s), radius = M.ENEMY_RADIUS, force = enemies, is_military_target = true, limit = 20,
        }) do
          if e.valid and vis.visible(ctx.helper_id, env.surface, e.position) then
            cn.near_enemy = true
            break
          end
        end
      end
    end
  end
  cn.ci = last + 1
  task.progress = { done = cn.ci - 1, total = #cn.flat * 2, phase = "place" }
  if cn.ci <= #cn.flat then return nil end

  cn.box, cn.parts = boxes_of(cn)
  cn.missing = C.missing(ctx.entity, cn.need)
  if cn.dry then return done(cn) end
  local refused = spend_refused(task, cn)
  if refused ~= nil then return refused end
  if cn.box.x1 ~= nil then B.check_free(ctx, as_area(cn.box)) end
  if cn.build and next(cn.missing) ~= nil then
    if not task.args.auto_supply then
      return fail_with(cn, "no_items", "not enough items for the path (no ghost placed)")
    end
    G.begin(task, ctx, cn.need)
    cn.stage, cn.after_supply = "supply", "place"
    return nil
  end
  cn.stage, cn.pi, cn.ghosts, cn.marked = "place", 1, 0, 0
  return nil
end

local function build_parts(cn)
  local parts, cur = {}, nil
  for _, s in ipairs(cn.flat) do
    if s.placed then
      local w = s.w or 1
      if cur ~= nil then
        local nx1, ny1 = min(cur.x1, s.x), min(cur.y1, s.y)
        local nx2, ny2 = max(cur.x2, s.x + w), max(cur.y2, s.y + w)
        if nx2 - nx1 > M.BUILD_PART or ny2 - ny1 > M.BUILD_PART then
          parts[#parts + 1] = as_area(cur)
          cur = nil
        else
          cur.x1, cur.y1, cur.x2, cur.y2 = nx1, ny1, nx2, ny2
        end
      end
      if cur == nil then cur = { x1 = s.x, y1 = s.y, x2 = s.x + w, y2 = s.y + w } end
    end
  end
  if cur ~= nil then parts[#parts + 1] = as_area(cur) end
  return parts
end

local function place_tick(cn, env, ctx, task)
  local last = min(#cn.flat, cn.pi + M.PLACE_PER_TICK - 1)
  for i = cn.pi, last do
    local s = cn.flat[i]
    local ok, marked = place_one(cn, env, s, false)
    if not ok then return research(cn, s) end
    s.placed = true
    cn.placed_any = true
    cn.marked = cn.marked + marked
    cn.ghosts = cn.ghosts + 1
  end
  cn.pi = last + 1
  task.progress = { done = #cn.flat + cn.pi - 1, total = #cn.flat * 2, phase = "place" }
  if cn.pi <= #cn.flat then return nil end
  remember(cn, ctx)
  if not cn.build then return done(cn) end
  cn.stage = "build"
  return nil
end

-- ------------------------------------------------------------------ стройка

local SUM = { "built", "tiles_built", "removed", "not_removed", "blocked_total" }

local function add_build(cn, d)
  local t = cn.bsum
  for _, k in ipairs(SUM) do t[k] = (t[k] or 0) + (tonumber(d[k]) or 0) end
  t.left = d.left or 0
  for _, b in ipairs(d.blocked or {}) do
    if #t.blocked < B.MAX_LIST then t.blocked[#t.blocked + 1] = b end
  end
  for name, n in pairs(d.missing or {}) do t.missing[name] = (t.missing[name] or 0) + n end
end

local function build_tick(cn, task, ctx)
  local pre = G.pre_tick(task, ctx)
  if pre == nil then return nil end
  if pre ~= false then
    local r = G.build_failed(task, pre)
    if r.detail then add_build(cn, r.detail) end
    return fail_with(cn, r.code, r.text, { supply = r.detail and r.detail.supply })
  end
  if cn.bparts == nil then
    cn.bparts, cn.bi = build_parts(cn), 0
    cn.bsum = { blocked = {}, missing = {} }
  end
  if task.g == nil then
    cn.bi = cn.bi + 1
    local area = cn.bparts[cn.bi]
    if area == nil then return done(cn) end
    B.hold_area(ctx, area)
    B.ghosts_start(task, ctx, area, cn.mode)
    if task.progress then task.progress.phase = "build" end
    return nil
  end
  local r = B.ghosts_tick(task, ctx)
  if task.progress then task.progress.phase = "build" end
  if r == nil then return nil end
  if r.status == "failed" and r.code == "no_items" and G.start_for_build(task, ctx, r) then return nil end
  add_build(cn, r.detail or {})
  task.g = nil
  if r.status == "failed" then
    return fail_with(cn, r.code, r.text, { supply = r.detail and r.detail.supply })
  end
  return nil
end

-- ------------------------------------------------------------------ действие

function M.tick(task, ctx)
  local cn = task.cn
  if cn == nil then return failed("internal", "connect_entities: state is lost") end
  local h = ctx.entity
  if cn.stage == "supply" then
    local pre = G.pre_tick(task, ctx)
    if pre == nil then
      if task.progress then task.progress.phase = "place" end
      return nil
    end
    if pre ~= false then return G.failed_with(pre, detail_of(cn)) end
    cn.missing = C.missing(h, cn.need)
    if next(cn.missing) ~= nil then
      return failed("no_items", "could not get the items for the path", G.with_supply(task, detail_of(cn)))
    end
    cn.stage = cn.after_supply
    if cn.stage == "place" then cn.pi, cn.ghosts, cn.marked = 1, 0, 0 end
    return nil
  end
  if cn.stage == "build" then return build_tick(cn, task, ctx) end
  cn.ticks = cn.ticks + 1
  task.progress_tick = ctx.tick -- расчёт идёт, тело стоит: «пульс»
  if cn.ticks > M.MAX_TICKS then
    return fail_with(cn, "path_failed", "connect_entities did not finish in time",
      { reason = "budget", expanded = cn.expansions })
  end
  local env = beltpath.env(cn.W, h.surface, h.force)
  if cn.stage == "search" then return search_tick(cn, env, task) end
  if cn.stage == "check" then return check_tick(cn, env, ctx, task) end
  return place_tick(cn, env, ctx, task)
end

--- Задачу сняло отступление flee: призраки остаются, повтор с теми же аргументами их подхватит.
local function fled(res)
  return type(res) == "table" and res.code == "cancelled" and type(res.text) == "string"
    and res.text:find(M.FLEE_REQ, 1, true) ~= nil
end

function M.stop(task, ctx, res)
  G.stop(task, ctx)
  if task.g ~= nil then B.ghosts_stop(task, ctx) else B.stop_approach(task, ctx) end
  local cn = task.cn
  task.cn = nil
  if cn == nil then return nil end
  if fled(res) then
    if not cn.dry then keep_fled(ctx.helper_id, cn, ctx.tick or game.tick) end
    return nil
  end
  local removed, unmarked = C.cleanup(cn)
  if cn.placed_any or cn.resumed then C.forget(ctx.helper_id, cn.sig) end
  local out = {}
  if cn.placed_any or cn.resumed or removed > 0 then out.removed = removed end
  if unmarked > 0 then out.unmarked = unmarked end
  if next(out) == nil then return nil end
  return out
end

return M
