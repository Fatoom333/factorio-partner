-- Действие `plan_mining`: разметка рудного пятна призраками по алгоритму мода
-- Mining Patch Planner (Rimbas, MIT; код раскладок — scripts/vendor/mpp, см. его README.md).
-- Контракт: docs/ACTIONS.md «plan_mining», PROTOCOL.md §6.5 (постановка призрака), §6.7 (открытые чанки).
--
-- args: resource?, area │ near, layout = "simple", direction = "north", miner?, belt?, pole?, pipe?,
--       options? (флаги — adapter.OPTIONS_SCHEMA), dry_run?
-- done.detail: {ghosts, area, need, layout, warnings, drills, skipped, tiles, chosen = {miner, belt│chest, pole, pipe}}
-- failed: not_found (руды нет), not_charted (точка в неоткрытом чанке), limit (пятно больше 128×128),
--         bad_args (раскладка не подходит буру/руде, неизвестное имя постройки),
--         cannot_place (ни один призрак поставить нельзя; detail — как у done).
--
-- Раскладка считается автоматом состояний MPP: один шаг автомата за тик задачи (как в самом моде),
-- состояние — в task.mpp (переживает сохранение). Тело помощника никуда не идёт: разметка — то же,
-- что рамка MPP у игрока на карте; стройка — отдельно, `build_ghosts` по `detail.area`.
-- Призраки принадлежат силе помощника (она же сила хозяина, PROTOCOL §6.8).
--
-- Ревизия 3.3:
-- * свойства плиток — из игры (PROTOCOL §6.12): `avoid_water` (по умолчанию true) — любая плитка,
--   на которой бур стоять не может; предупреждение `on_liquid:N` — сколько клеток руды пропущено;
-- * выходы с участка считает `access.compute` (STATE.md «access»): предупреждения `narrow_access`,
--   `enclosed`, `access_side:<сторона>`; если `direction` не задан, лента выходит к лучшему выходу
--   (на открытом со всех сторон месте — на север);
-- * расчёт идёт дважды: сначала всегда сухой прогон (ничего не ставится) — по нему проверяется
--   итоговая область с полями (больше 128×128 → `limit`) и «встанет ли вообще», и только потом
--   настоящий; `dry_run` — один сухой прогон;
-- * после настоящей разметки концы выходных лент пишутся в `storage.mining_last[helper]` =
--   {surface (имя), surface_index, outputs = [{pos, direction (defines.direction), side}], tick}.
local adapter = require("scripts.vendor.mpp.partner.adapter")
local access = require("scripts.perception.access")
local tiles = require("scripts.perception.tiles")

local M = {}
M.name = "plan_mining"
M.schema = {
  resource = { type = "string", max = 100 },
  area = { type = "area" },
  near = { type = "pos" },
  layout = { type = "enum", values = adapter.LAYOUT_NAMES, default = "simple" },
  -- без default: «не задано» отличается от «север» (тогда сторону выбирает access)
  direction = { type = "enum", values = adapter.DIRECTIONS },
  miner = { type = "string", max = 100 },
  belt = { type = "string", max = 100 },
  pole = { type = "string", max = 100 },
  pipe = { type = "string", max = 100 },
  options = { type = "object", fields = adapter.OPTIONS_SCHEMA },
  dry_run = { type = "bool" },
}

M.MAX_SIDE = 128        -- пятно не больше 128×128 (ACTIONS.md)
M.SEED_RADIUS = 10      -- `near`: руда ищется не дальше 10 клеток от точки
M.GROW = 32             -- шаг расширения окна поиска связного пятна
M.MAX_TICKS = 60 * 60   -- раскладка считается секунды; минута на прогон — заведомо сбой
M.MAX_WARNINGS = 20
M.DEFAULT_DIRECTION = "north"

local floor = math.floor

local function failed(code, text, detail)
  return { status = "failed", code = code, text = text, detail = detail or {} }
end

-- ------------------------------------------------------------------ открытые чанки

local function charted_view(force, surface)
  local cache = {}
  return function(pos)
    local cx, cy = floor(pos.x / 32), floor(pos.y / 32)
    local key = cx * 4194304 + cy
    local v = cache[key]
    if v == nil then
      v = force.is_chunk_charted(surface, { x = cx, y = cy }) and true or false
      cache[key] = v
    end
    return v
  end
end

-- ------------------------------------------------------------------ поиск руды

local OFF, MUL = 1048576, 4194304
local function key(x, y) return (x + OFF) * MUL + (y + OFF) end

--- Твёрдая руда в области (в открытых чанках): список сущностей.
local function solid_in(surface, charted, area, name)
  local filter = { area = area, type = "resource" }
  if name then filter.name = name end
  local out = {}
  local solid = {} -- имя руды → твёрдая ли (прототип спрашиваем один раз на имя, клеток — тысячи)
  for _, e in ipairs(surface.find_entities_filtered(filter)) do
    if e.valid then
      local n = e.name
      local ok = solid[n]
      if ok == nil then
        ok = adapter.is_solid(prototypes.entity[n])
        solid[n] = ok
      end
      if ok and charted(e.position) then out[#out + 1] = e end
    end
  end
  return out
end

--- Связное (8 соседей) пятно руды `name` вокруг сущности `seed`.
--- → список сущностей │ nil, code, text.
local function connected_patch(surface, charted, seed, name)
  local sp = seed.position
  local sx, sy = floor(sp.x), floor(sp.y)
  local box = { x1 = sx - M.GROW, y1 = sy - M.GROW, x2 = sx + M.GROW + 1, y2 = sy + M.GROW + 1 }
  while true do
    local found = solid_in(surface, charted,
      { left_top = { x = box.x1, y = box.y1 }, right_bottom = { x = box.x2, y = box.y2 } }, name)
    local by_key = {}
    for i, e in ipairs(found) do
      local p = e.position
      by_key[key(floor(p.x), floor(p.y))] = i
    end
    local start = by_key[key(sx, sy)]
    if start == nil then return nil, "not_found", "no ore " .. name .. " at the point" end

    local seen, stack, patch = { [start] = true }, { start }, {}
    local minx, miny, maxx, maxy = sx, sy, sx, sy
    while #stack > 0 do
      local i = stack[#stack]
      stack[#stack] = nil
      local e = found[i]
      patch[#patch + 1] = e
      local p = e.position
      local x, y = floor(p.x), floor(p.y)
      if x < minx then minx = x end
      if y < miny then miny = y end
      if x > maxx then maxx = x end
      if y > maxy then maxy = y end
      for dx = -1, 1 do
        for dy = -1, 1 do
          if dx ~= 0 or dy ~= 0 then
            local k = by_key[key(x + dx, y + dy)]
            if k and not seen[k] then
              seen[k] = true
              stack[#stack + 1] = k
            end
          end
        end
      end
    end

    if maxx - minx + 1 > M.MAX_SIDE or maxy - miny + 1 > M.MAX_SIDE then
      return nil, "limit", "ore patch is larger than " .. M.MAX_SIDE .. "x" .. M.MAX_SIDE .. ", use args.area"
    end
    -- пятно упирается в край окна — расширяем окно с этой стороны и ищем заново
    local grown = false
    if minx <= box.x1 then box.x1 = box.x1 - M.GROW grown = true end
    if miny <= box.y1 then box.y1 = box.y1 - M.GROW grown = true end
    if maxx >= box.x2 - 1 then box.x2 = box.x2 + M.GROW grown = true end
    if maxy >= box.y2 - 1 then box.y2 = box.y2 + M.GROW grown = true end
    if not grown then return patch end
  end
end

--- Руда по аргументам → список сущностей │ nil, code, text.
local function find_resources(surface, force, a)
  local charted = charted_view(force, surface)
  if a.resource ~= nil then
    local proto = prototypes.entity[a.resource]
    if proto == nil or proto.type ~= "resource" then
      return nil, "bad_args", "args.resource: unknown resource " .. a.resource
    end
    if not adapter.is_solid(proto) then
      return nil, "bad_args", "args.resource: " .. a.resource .. " is not a solid ore"
    end
  end

  if a.area ~= nil then
    local lt, rb = a.area.left_top, a.area.right_bottom
    local any = false
    for cx = floor(lt.x / 32), floor(rb.x / 32) do
      for cy = floor(lt.y / 32), floor(rb.y / 32) do
        if charted({ x = cx * 32, y = cy * 32 }) then any = true end
      end
    end
    if not any then return nil, "not_charted", "args.area is not charted" end
    local found = solid_in(surface, charted, a.area, a.resource)
    if #found == 0 then return nil, "not_found", "no ore in args.area" end
    return found
  end

  if not charted(a.near) then return nil, "not_charted", "args.near is not charted" end
  local filter = { position = a.near, radius = M.SEED_RADIUS, type = "resource" }
  if a.resource then filter.name = a.resource end
  local seed, seed_d
  for _, e in ipairs(surface.find_entities_filtered(filter)) do
    if e.valid and adapter.is_solid(e.prototype) and charted(e.position) then
      local p = e.position
      local d = (p.x - a.near.x) ^ 2 + (p.y - a.near.y) ^ 2
      if seed == nil or d < seed_d then seed, seed_d = e, d end
    end
  end
  if seed == nil then
    return nil, "not_found", "no ore within " .. M.SEED_RADIUS .. " tiles of args.near"
  end
  return connected_patch(surface, charted, seed, seed.name)
end

-- ------------------------------------------------------------------ итог

--- Итог прогона: detail по таблице ACTIONS.md, признак успеха, сводка адаптера.
--- extra — предупреждения действия (жидкость, выходы с участка), dry_run — что просил агент.
local function detail_of(state, extra, dry_run)
  local s = adapter.summary(state)
  local chosen = { miner = s.choices.miner, pole = s.choices.pole }
  local restrictions = adapter.layouts[state.layout_choice].restrictions
  if restrictions.logistics_available then chosen.chest = s.choices.chest else chosen.belt = s.choices.belt end
  if state.place_pipes then chosen.pipe = s.choices.pipe end
  -- предупреждения о жидкости и выходах — первыми: при обрезке до 20 они важнее остальных
  local warnings = {}
  for _, w in ipairs(extra or {}) do warnings[#warnings + 1] = w end
  for _, w in ipairs(s.warnings) do
    if #warnings < M.MAX_WARNINGS then warnings[#warnings + 1] = w end
  end
  return {
    ghosts = s.ghosts,
    area = s.area,
    need = s.need,
    layout = state.layout_choice,
    warnings = warnings,
    drills = s.drills,
    skipped = s.skipped,
    tiles = s.tiles,
    chosen = chosen,
    dry_run = dry_run and true or nil,
  }, s.ok, s
end

-- ------------------------------------------------------------------ жидкость и выходы

--- Рамка пятна по клеткам руды.
local function patch_area(resources)
  local x1, y1, x2, y2 = math.huge, math.huge, -math.huge, -math.huge
  for _, e in ipairs(resources) do
    local p = e.position
    local x, y = floor(p.x), floor(p.y)
    if x < x1 then x1 = x end
    if y < y1 then y1 = y end
    if x > x2 then x2 = x end
    if y > y2 then y2 = y end
  end
  return { left_top = { x = x1, y = y1 }, right_bottom = { x = x2 + 1, y = y2 + 1 } }
end

--- Сколько клеток руды лежит на плитке, на которой бур стоять не может (PROTOCOL §6.12: маска
--- плитки против маски бура; имён плиток нет).
local function ore_on_liquid(surface, resources, area, miner)
  local blocked = tiles.find_blocked(surface, area, tiles.entity_layers(miner))
  if #blocked == 0 then return 0 end
  local at = {}
  for _, t in ipairs(blocked) do
    local p = t.position
    at[key(floor(p.x), floor(p.y))] = true
  end
  local n = 0
  for _, e in ipairs(resources) do
    local p = e.position
    if at[key(floor(p.x), floor(p.y))] then n = n + 1 end
  end
  return n
end

--- Выходы с участка (операция `access`, STATE.md) → предупреждения и лучшая сторона для ленты.
local function access_of(surface, force, area, body)
  local acc = access.compute{ surface = surface, force = force, area = area, from = body.position, body = body }
  local warnings = {}
  if acc.enclosed then
    warnings[#warnings + 1] = "enclosed"
    return warnings, nil
  end
  if acc.wide_sides >= 4 then return warnings, nil end -- открытое место: сказать нечего
  for _, w in ipairs(acc.warnings) do
    if w == "narrow_access" then warnings[#warnings + 1] = w end
  end
  warnings[#warnings + 1] = "access_side:" .. acc.best
  return warnings, acc.best
end

-- ------------------------------------------------------------------ действие

local function prepare(task, surface, force, resources, dry_run)
  local a, plan = task.args, task.mpp_plan
  return adapter.prepare{
    surface = surface, force = force, resources = resources,
    layout = a.layout, direction = plan.direction,
    miner = a.miner, belt = a.belt, pole = a.pole, pipe = a.pipe,
    options = a.options, dry_run = dry_run,
  }
end

local function forget(task)
  task.mpp, task.mpp_plan = nil, nil
end

function M.start(task, ctx)
  local a = task.args
  if (a.area == nil) == (a.near == nil) then
    return failed("bad_args", "args: use either area or near")
  end
  local h = ctx.entity
  local surface, force = h.surface, h.force

  local resources, code, text = find_resources(surface, force, a)
  if resources == nil then return failed(code, text) end
  local area = patch_area(resources)
  if area.right_bottom.x - area.left_top.x > M.MAX_SIDE or area.right_bottom.y - area.left_top.y > M.MAX_SIDE then
    return failed("limit", "ore patch is larger than " .. M.MAX_SIDE .. "x" .. M.MAX_SIDE .. ", use args.area")
  end

  -- Выходы с участка: предупреждения и сторона ленты, если хозяин её не задал.
  local extra, best = access_of(surface, force, area, h)
  task.mpp_plan = { direction = a.direction or best or M.DEFAULT_DIRECTION, warnings = extra, phase = "dry" }

  -- Первый прогон всегда сухой: итоговая область и «встанет ли вообще» известны до первого призрака.
  local state
  state, code, text = prepare(task, surface, force, resources, true)
  if state == nil then
    forget(task)
    return failed(code, text)
  end
  if state.avoid_water_choice then
    local n = ore_on_liquid(surface, resources, area, state.miner_choice)
    if n > 0 then table.insert(extra, 1, "on_liquid:" .. n) end
  end

  task.mpp = state
  task.mpp_ticks = 0
  task.progress_tick = ctx.tick
  return nil
end

function M.tick(task, ctx)
  local state, plan = task.mpp, task.mpp_plan
  if state == nil or plan == nil then return failed("internal", "plan_mining: state is lost") end
  task.mpp_ticks = task.mpp_ticks + 1
  task.progress_tick = ctx.tick -- расчёт идёт, тело стоит: «пульс» (ACTIONS.md)
  if task.mpp_ticks > M.MAX_TICKS then
    forget(task)
    return failed("internal", "plan_mining: layout did not finish in time")
  end

  if not adapter.step(state) then return nil end

  local dry_run = task.args.dry_run
  local detail, ok, summary = detail_of(state, plan.warnings, dry_run)
  if not ok then
    forget(task)
    return failed("cannot_place", "MPP: unable to place a mining layout here", detail)
  end
  local ar = detail.area
  if ar and (ar.right_bottom.x - ar.left_top.x > M.MAX_SIDE or ar.right_bottom.y - ar.left_top.y > M.MAX_SIDE) then
    forget(task)
    return failed("limit", "planned area with margins is larger than " .. M.MAX_SIDE .. "x" .. M.MAX_SIDE
      .. ", plan in parts with args.area", detail)
  end

  if plan.phase == "dry" and not dry_run then
    -- Сухой прогон прошёл — теперь ставим призраки тем же расчётом.
    local h = ctx.entity
    local real, code, text = prepare(task, h.surface, h.force, state.resources, false)
    if real == nil then
      forget(task)
      return failed(code, text)
    end
    plan.phase = "real"
    task.mpp = real
    task.mpp_ticks = 0
    return nil
  end

  if not dry_run then
    -- Концы выходных лент: их читает plan_belt{from:"patch"} (PROTOCOL §7, ключ storage.mining_last).
    local surface = ctx.entity.surface
    local outputs = {}
    for i, o in ipairs(summary.outputs) do
      outputs[i] = { pos = { x = o.pos.x, y = o.pos.y }, direction = o.direction, side = plan.direction }
    end
    if type(storage.mining_last) ~= "table" then storage.mining_last = {} end
    storage.mining_last[task.helper] = {
      surface = surface.name, surface_index = surface.index, outputs = outputs, tick = ctx.tick,
    }
  end
  forget(task)
  return { status = "done", detail = detail }
end

function M.stop(task, ctx)
  ctx.cancel_approach(task)
  forget(task)
end

return M
