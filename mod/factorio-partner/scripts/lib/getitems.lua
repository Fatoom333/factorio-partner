-- «Достать предметы»: общий механизм действия `get_items` и флага `auto_supply`
-- (docs/ACTIONS.md «get_items»). Работает внутри задачи-хозяйки (task.supply) и гоняет по очереди
-- шаги на готовых модулях: collect (склады), craft (ручной крафт, промежуточные — явными шагами),
-- плавка (печи своей силы рядом, этот файл), mine{item} (руками).
--
-- Цель — «в карманах не меньше N». Порядок источников для каждого предмета: уже есть → склады →
-- ручной крафт → плавка → добыча руками. План строится заново перед каждым шагом по живому миру
-- (инвентарь, склады, печи), выполняется его первый шаг; шаг, не давший прироста, запрещает свой
-- способ до конца задачи, и план перестраивается. Мира не выдумывает: предметов из воздуха нет,
-- склады и печи — только видимые (PROTOCOL §6.7), своей силы, рецепты — своей силы, открытые.
--
-- Склады — свои сундуки хозяина; выходы его линий (сундук, в который кладёт манипулятор или загрузчик)
-- и выходные слоты машин — только с from_lines (scripts/lib/lines.lua). Без флага недостающее, что
-- лежит в таких выходах, называется в shortfall (in_lines, lines_at, hint).
--
-- Состояние — task.supply = {want, from, blocked, reasons, start, radius, cur, replans, fueled,
-- from_lines, seen_stock}: только данные (в storage нет функций и тяжёлых таблиц).
--   cur = {step, kind, t, before} — текущий шаг как дочерняя задача; модуль действия по kind берётся
--   из локальной таблицы MODS. Индекс рецептов — кэш модуля (пересобирается после загрузки).
-- API: begin(task, ctx, want, opts) → nil │ result; step(task, ctx) → nil │ result;
--      stop(task, ctx); result — как у действий ({status, code?, text?, detail}).
local util = require("scripts.core.util")
local inv = require("scripts.lib.inventory")
local reserve = require("scripts.core.reserve")
local lines = require("scripts.lib.lines")
local recipes_p = require("scripts.perception.recipes")
local collect = require("scripts.actions.collect")
local craft = require("scripts.actions.craft")
local mine = require("scripts.actions.mine")
local build = require("scripts.lib.build")

local M = {}

M.MAX_DEPTH = 8          -- глубина дерева рецептов
M.MAX_REPLANS = 400      -- шагов за задачу
M.MAX_FURNACES = 4       -- печей одновременно
M.DEFAULT_RADIUS = 64
M.WAIT_CHECK = 30        -- тиков между опросами печей
M.DEFAULT_USAGE = 90000  -- Вт, если мощность печи не прочесть
M.MAX_CALLS = 2000       -- вызовов resolve на один план; больше — причина too_complex
M.FUELS = { "coal", "wood", "solid-fuel" }

-- индекс рецептов по задаче-снабжению: кэш, не storage (после загрузки сейва пересобирается)
local IDX = setmetatable({}, { __mode = "k" })

local function add(acc, name, n)
  if n and n > 0 then acc[name] = (acc[name] or 0) + n end
end

-- ------------------------------------------------------------------ индекс рецептов

local function amount_of(p)
  local a = p.amount
  if type(a) ~= "number" then a = ((p.amount_min or 0) + (p.amount_max or p.amount_min or 0)) / 2 end
  local pr = type(p.probability) == "number" and p.probability or 1
  return a * pr
end

local function is_item(p) return p.type == nil or p.type == "item" end

local function main_name(r)
  local ok, rp = pcall(function() return r.prototype end)
  if not ok or rp == nil then return nil end
  local ok2, mp = pcall(function() return rp.main_product end)
  if ok2 and type(mp) == "table" and mp.name then return mp.name end
  return nil
end

local function hand_hidden(r)
  local ok, rp = pcall(function() return r.prototype end)
  if not ok or rp == nil then return false end
  local ok2, v = pcall(function() return rp.hidden_from_player_crafting end)
  return ok2 and v == true
end

--- item → [{name, kind="craft"|"smelt", yield, ingr=[{name,amount}], time, category}], ручные
--- рецепты раньше плавильных, внутри вида — рецепт с именем предмета первым, остальные по имени.
local function build_index(h)
  local cats = recipes_p.categories(h)
  local idx = {}
  for name, r in pairs(h.force.recipes) do
    if r.enabled and not r.hidden then
      local kind
      if cats[r.category] then
        if not hand_hidden(r) then kind = "craft" end
      elseif r.category == "smelting" then
        kind = "smelt"
      end
      if kind then
        local ingr, fluid = {}, false
        for _, i in ipairs(r.ingredients or {}) do
          if is_item(i) then ingr[#ingr + 1] = { name = i.name, amount = i.amount } else fluid = true end
        end
        if kind == "smelt" and #ingr ~= 1 then fluid = true end -- в печи один ингредиент
        local mains = main_name(r)
        local items = {}
        for _, p in ipairs(r.products or {}) do
          if is_item(p) and p.name then items[p.name] = (items[p.name] or 0) + amount_of(p) end
        end
        local nprod = 0
        for _ in pairs(items) do nprod = nprod + 1 end
        if not fluid and #ingr > 0 then
          for pname, got in pairs(items) do
            local y = got
            for _, i in ipairs(ingr) do if i.name == pname then y = y - i.amount end end
            if y > 0 and (nprod == 1 or mains == pname) then
              local list = idx[pname] or {}
              idx[pname] = list
              list[#list + 1] = { name = name, kind = kind, yield = y, ingr = ingr, time = r.energy or 0.5,
                category = r.category }
            end
          end
        end
      end
    end
  end
  for item, list in pairs(idx) do
    table.sort(list, function(a, b)
      if a.kind ~= b.kind then return a.kind == "craft" end
      local ae, be = a.name == item, b.name == item
      if ae ~= be then return ae end
      return a.name < b.name
    end)
  end
  return idx
end

--- Индекс рецептов задачи-снабжения (кэш модуля, а не storage).
local function idx_of(g, ctx)
  local idx = IDX[g]
  if idx == nil then
    idx = build_index(ctx.entity)
    IDX[g] = idx
  end
  return idx
end

-- ------------------------------------------------------------------ печи

local function inv_of(e, key)
  local ok, i = pcall(function() return e.get_inventory(defines.inventory[key]) end)
  if ok and i ~= nil and i.valid then return i end
  return nil
end

local function is_burner(e)
  local ok, b = pcall(function() return e.prototype.burner_prototype end)
  return ok and b ~= nil
end

local function field(x, key)
  local ok, v = pcall(function() return x[key] end)
  if ok then return v end
  return nil
end

local function same(a, b)
  if a == nil or b == nil then return false end
  local ok, r = pcall(function() return a.valid and b.valid and a.unit_number ~= nil and a.unit_number == b.unit_number end)
  return ok and r == true
end


--- Прямоугольник печи: рамка выбора, иначе рамка по размеру прототипа вокруг центра.
local function furnace_box(e)
  local box = field(e, "selection_box") or field(e, "bounding_box")
  if type(box) == "table" and box.left_top and box.right_bottom then
    local lt, rb = box.left_top, box.right_bottom
    return { l = lt.x or lt[1], t = lt.y or lt[2], r = rb.x or rb[1], b = rb.y or rb[2] }
  end
  local p = e.position
  local w = field(e.prototype, "tile_width") or 2
  local hgt = field(e.prototype, "tile_height") or 2
  return { l = p.x - w / 2, t = p.y - hgt / 2, r = p.x + w / 2, b = p.y + hgt / 2 }
end

--- К печи подключён манипулятор или загрузчик (чужой — хозяина): по типам, без имён прототипов.
--- Манипулятор — pickup_target/drop_target, загрузчик — loader_container. Ищем в рамке печи, расширенной
--- на наибольшую дальность манипуляторов (длинные и модовые тоже находятся).
local function owner_linked(h, e)
  local reach = lines.reach()
  local bx = furnace_box(e)
  local ok, list = pcall(function()
    return h.surface.find_entities_filtered{ type = { "inserter", "loader", "loader-1x1" },
      area = { left_top = { x = bx.l - reach, y = bx.t - reach }, right_bottom = { x = bx.r + reach, y = bx.b + reach } } }
  end)
  if not ok or type(list) ~= "table" then return false end
  for _, x in ipairs(list) do
    if x.valid then
      if x.type == "inserter" then
        if same(field(x, "pickup_target"), e) or same(field(x, "drop_target"), e) then return true end
      elseif same(field(x, "loader_container"), e) then
        return true
      end
    end
  end
  return false
end

--- Топливо в горелке печи не от помощника: в слоте или горит. fueled — печи, куда топливо клал помощник.
local function foreign_fuel(e, fueled)
  if not is_burner(e) then return false end
  if fueled ~= nil and e.unit_number ~= nil and fueled[e.unit_number] then return false end
  local fi = inv_of(e, "fuel")
  if fi ~= nil and not fi.is_empty() then return true end
  local ok, rem = pcall(function() return e.burner.remaining_burning_fuel end)
  return ok and type(rem) == "number" and rem > 0
end

--- Свободные печи своей силы рядом: видимые, открытые чанки, берут категорию, пустые, без манипуляторов
--- хозяина, без чужого топлива, не заняты другим помощником. Круг поиска — вокруг center (точка, где
--- задачу дали: тело по дороге уходит копать руду или топливо), без center — вокруг тела.
--- → список по возрастанию расстояния от центра.
local function free_furnaces(ctx, radius, category, fueled, center)
  local h = ctx.entity
  local at = center or util.xy(h.position)
  local out = {}
  local list = h.surface.find_entities_filtered{ type = "furnace", force = h.force, position = at, radius = radius }
  for _, e in ipairs(list) do
    if e.valid and inv.charted(h, e.position) and inv.visible(ctx, e.position) then
      local ok, cats = pcall(function() return e.prototype.crafting_categories end)
      local src, res = inv_of(e, "furnace_source"), inv_of(e, "furnace_result")
      if ok and type(cats) == "table" and cats[category] and src and res and src.is_empty() and res.is_empty()
          and not (e.unit_number ~= nil and reserve.machine_holder(ctx.helper_id, e.unit_number) ~= nil)
          and not foreign_fuel(e, fueled) and not owner_linked(h, e) then
        out[#out + 1] = { e = e, d = util.dist(at, util.xy(e.position)) }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    return (a.e.unit_number or 0) < (b.e.unit_number or 0)
  end)
  local res = {}
  for _, f in ipairs(out) do res[#res + 1] = f.e end
  return res
end

local function fuel_value(name)
  local p = inv.item_proto(name)
  if p == nil then return 0 end
  local ok, v = pcall(function() return p.fuel_value end)
  return (ok and type(v) == "number") and v or 0
end

--- Топливо для печей: что лежит в карманах (больше всего), иначе первое из FUELS, что есть в игре.
local function pick_fuel(pocket)
  local best, bn
  for name, n in pairs(pocket) do
    if fuel_value(name) > 0 and (bn == nil or n > bn or (n == bn and name < best)) then best, bn = name, n end
  end
  if best then return best end
  for _, name in ipairs(M.FUELS) do
    if fuel_value(name) > 0 then return name end
  end
  return nil
end

local function energy_per_craft(e, time)
  local usage, speed = M.DEFAULT_USAGE, 1
  local ok, u = pcall(function() return e.prototype.get_max_energy_usage() end)
  if ok and type(u) == "number" and u > 0 then usage = u * 60 end -- Дж за тик → Вт
  local ok2, s = pcall(function() return e.prototype.get_crafting_speed() end)
  if ok2 and type(s) == "number" and s > 0 then speed = s end
  local eff = 1
  local ok3, ef = pcall(function() return e.prototype.burner_prototype.effectivity end)
  if ok3 and type(ef) == "number" and ef > 0 then eff = ef end
  return usage * time / speed / eff, speed
end

local function fuel_energy_in(e)
  local fi = inv_of(e, "fuel")
  local total = 0
  if fi then
    for name, n in pairs(inv.counts(fi)) do total = total + fuel_value(name) * n end
  end
  local ok, rem = pcall(function() return e.burner.remaining_burning_fuel end)
  if ok and type(rem) == "number" then total = total + rem end
  return total
end

-- ------------------------------------------------------------------ план

-- Пробы способов идут прямо в S с журналом записей: перед пробой запоминается отметка, после неё
-- записи откатываются назад (undo), а лучшая проба переносится «разностью» (capture/apply). Склад и
-- карманы целиком не копируются: цена пробы — число тронутых позиций, а не размер склада.
-- M.stats.journal — сколько записей прошло через журнал (откат и перенос тоже считаются).
M.stats = { journal = 0 }

--- Записать t[k] = v с пометкой в журнал S.
local function setv(S, t, k, v)
  local n = S.nlog + 1
  S.nlog = n
  S.lt[n], S.lk[n], S.lo[n] = t, k, t[k]
  t[k] = v
  M.stats.journal = M.stats.journal + 1
end

--- Откатить записи журнала до отметки mark (S.nlog в тот момент).
local function undo(S, mark)
  local lt, lk, lo = S.lt, S.lk, S.lo
  for i = S.nlog, mark + 1, -1 do
    lt[i][lk[i]] = lo[i]
    lt[i], lk[i], lo[i] = nil, nil, nil
    M.stats.journal = M.stats.journal + 1
  end
  S.nlog = mark
end

--- Итог записей после отметки mark как разность {t, k, v}: что стало в каждой тронутой позиции.
local function capture(S, mark)
  local d = { n = 0, t = {}, k = {}, v = {} }
  for i = mark + 1, S.nlog do
    local t, k = S.lt[i], S.lk[i]
    d.n = d.n + 1
    d.t[d.n], d.k[d.n], d.v[d.n] = t, k, t[k]
  end
  return d
end

local function apply(S, d)
  for i = 1, d.n do setv(S, d.t[i], d.k[i], d.v[i]) end
end

local function short_sum(S)
  local n = 0
  for _, s in ipairs(S.short) do n = n + s.missing end
  return n
end

local function add_short(S, item, n, reason)
  setv(S, S.short, #S.short + 1, { item = item, missing = n, reason = reason })
end

local function can_mine(S, item)
  local v = S.mineable[item]
  if v == nil then
    local probe = { args = { item = item, count = 1 }, helper = "probe" }
    local ok, res = pcall(mine.start, probe, S.ctx)
    v = ok and res == nil
    S.mineable[item] = v
  end
  return v
end

local function furnaces_for(S, category)
  local f = S.furn[category]
  if f == nil then
    f = free_furnaces(S.ctx, S.radius, category, S.fueled, S.origin)
    S.furn[category] = f
  end
  return f
end

local resolve

--- Один способ получить n штук item; пишет в S через журнал (вызывающий откатывает). → причина отказа │ nil.
local function via(S, item, n, depth, m)
  if m.kind == "mine" then
    setv(S, S.steps, #S.steps + 1, { kind = "mine", item = item, count = n, key = "mine:" .. item })
    return nil
  end
  local rec = m.rec
  local crafts = math.ceil(n / rec.yield - 1e-9)
  if m.kind == "smelt" then
    local fs = furnaces_for(S, rec.category)
    if #fs == 0 then return "no_furnace" end
    local burner = false
    for i = 1, math.min(#fs, M.MAX_FURNACES) do
      if is_burner(fs[i]) then burner = true end
    end
    if burner then
      local need = energy_per_craft(fs[1], rec.time) * crafts
      local present = 0
      for i = 1, math.min(#fs, M.MAX_FURNACES) do present = present + fuel_energy_in(fs[i]) end
      if need > present then
        local fuel = pick_fuel(S.pocket)
        if fuel == nil then return "no_fuel" end
        local before = short_sum(S)
        resolve(S, fuel, math.ceil((need - present) / fuel_value(fuel)), depth + 1)
        if short_sum(S) > before then return "no_fuel" end
      end
    end
  end
  for _, i in ipairs(rec.ingr) do resolve(S, i.name, i.amount * crafts, depth + 1) end
  setv(S, S.steps, #S.steps + 1, { kind = m.kind, item = item, recipe = rec.name, count = crafts, yield = rec.yield,
    key = m.kind .. ":" .. rec.name })
  setv(S, S.pocket, item, (S.pocket[item] or 0) + crafts * rec.yield - n)
  return nil
end

--- Добавить в S всё, чтобы получить ещё n штук item.
resolve = function(S, item, n, depth)
  if n <= 0 then return end
  local use = math.min(n, S.pocket[item] or 0)
  if use > 0 then setv(S, S.pocket, item, S.pocket[item] - use) n = n - use end
  if n <= 0 then return end
  local st = math.min(n, S.stock[item] or 0)
  if st > 0 then
    setv(S, S.stock, item, S.stock[item] - st)
    setv(S, S.collect, item, (S.collect[item] or 0) + st)
    n = n - st
  end
  if n <= 0 then return end
  S.budget.n = S.budget.n + 1
  if S.budget.n > S.budget.max then add_short(S, item, n, "too_complex") return end
  if depth > M.MAX_DEPTH then add_short(S, item, n, "too_deep") return end
  if S.visiting[item] then add_short(S, item, n, "cycle") return end
  setv(S, S.visiting, item, true)

  local methods = {}
  for _, rec in ipairs(S.idx[item] or {}) do
    methods[#methods + 1] = { kind = rec.kind, rec = rec, key = rec.kind .. ":" .. rec.name }
  end
  methods[#methods + 1] = { kind = "mine", key = "mine:" .. item }
  -- предмет уже разбирали в этом плане: берём найденный тогда способ, остальные не перебираем
  local known = S.choice[item]
  if known then
    for _, m in ipairs(methods) do
      if m.key == known then methods = { m } break end
    end
  end

  local best_delta, best_short, best_key, last_reason, applied
  local base = short_sum(S)
  for _, m in ipairs(methods) do
    local blocked = S.blocked[m.key]
    if blocked then
      last_reason = S.reasons[m.key] or "failed"
    elseif m.kind == "mine" and not can_mine(S, item) then
      last_reason = last_reason or "no_source"
    else
      local mark = S.nlog
      local why = via(S, item, n, depth, m)
      if why then
        undo(S, mark)
        last_reason = why
      else
        local sh = short_sum(S) - base
        if sh == 0 then
          -- без нехватки: лучше не бывает, проба остаётся записанной в S
          best_key, applied = m.key, true
          break
        end
        if best_key == nil or sh < best_short then
          best_delta, best_short, best_key = capture(S, mark), sh, m.key
        end
        undo(S, mark)
      end
    end
  end
  if best_key then
    if not applied then apply(S, best_delta) end
    setv(S, S.visiting, item, nil)
    S.choice[item] = best_key
  else
    setv(S, S.visiting, item, nil)
    add_short(S, item, n, last_reason or "no_source")
  end
end

--- План по живому миру. → {steps, short, by_item}; by_item[запрошенный] = {reason, via}.
local function make_plan(g, task, ctx)
  local h = ctx.entity
  local main = h.get_main_inventory()
  local S = {
    h = h, ctx = ctx, idx = idx_of(g, ctx), blocked = g.blocked, reasons = g.reasons, radius = g.radius,
    mineable = g.mineable, furn = {}, fueled = g.fueled, origin = g.origin, budget = { n = 0, max = M.MAX_CALLS }, choice = {},
    pocket = inv.counts(main), stock = {}, collect = {},
    steps = {}, short = {}, visiting = {}, nlog = 0, lt = {}, lk = {}, lo = {},
  }
  if not g.blocked.collect then
    -- склады хозяина; выходы его линий и машин — только с from_lines (scripts/lib/lines.lua)
    local scan = lines.scan(h.surface, h.force, util.xy(h.position), g.radius, nil, ctx.helper_id,
      { from_lines = g.from_lines })
    for name, n in pairs(scan.total) do
      local allowed = n - reserve.reserved_by_others(ctx.helper_id, name)
      if allowed > 0 then
        S.stock[name] = allowed
        if g.want[name] ~= nil then g.seen_stock[name] = true end
      end
    end
  end
  local names = {}
  for name in pairs(g.want) do names[#names + 1] = name end
  table.sort(names)
  local by_item = {}
  for _, name in ipairs(names) do
    local have = S.pocket[name] or 0
    local first = #S.short + 1
    -- сколько нужно добавить к уже лежащему
    local need = g.want[name] - have
    -- запрошенный предмет уже в карманах: pocket[name] расходуется в resolve, поэтому просим полный объём
    if need > 0 then
      resolve(S, name, g.want[name], 0)
      if #S.short >= first then by_item[name] = { reason = S.short[first].reason, via = S.short[first].item } end
    else
      -- уже хватает: держим своё, чтобы промежуточные шаги не съели его
      S.pocket[name] = have - g.want[name]
    end
  end
  if next(S.collect) ~= nil then
    table.insert(S.steps, 1, { kind = "collect", items = S.collect, key = "collect" })
  end
  return { steps = S.steps, short = S.short, by_item = by_item }
end

-- ------------------------------------------------------------------ плавка (шаг)

local smelt = {}
smelt.name = "smelt"

--- t.args = {recipe, item, count (крафтов), yield, time, category, ingredient, amount, radius, fueled, origin}
function smelt.start(t, ctx)
  local a = t.args
  local fs = free_furnaces(ctx, a.radius, a.category, a.fueled, a.origin)
  local list = {}
  for i = 1, #fs do
    if #list >= M.MAX_FURNACES then break end
    local u = fs[i].unit_number
    if u ~= nil and reserve.hold_machine(ctx.helper_id, u) then list[#list + 1] = fs[i] end
  end
  if #list == 0 then return inv.failed("not_found", "no free furnace nearby", { reason = "no_furnace" }) end
  t.furn = list
  t.left = a.count
  t.gained = 0
  t.phase = "load"
  t.i = 1
  t.round = nil
  t.progress = { done = 0, total = a.count }
  return nil
end

local function stack_cap(name, amount)
  local p = inv.item_proto(name)
  local size = p and p.stack_size or 50
  return math.max(1, math.floor(size / amount))
end

local function insert_fuel(t, ctx, e, crafts)
  if not is_burner(e) then return true end
  local a = t.args
  local need = energy_per_craft(e, a.time) * crafts
  local present = fuel_energy_in(e)
  if present >= need then return true end
  local h = ctx.entity
  local main = h.get_main_inventory()
  local fuel = pick_fuel(inv.counts(main))
  if fuel == nil then return false end
  local fv = fuel_value(fuel)
  local want = math.min(inv.count(main, fuel), math.ceil((need - present) / fv))
  if want <= 0 then return false end
  local moved = inv.move(main, { entity = e }, fuel, want, h)
  if moved > 0 and a.fueled ~= nil and e.unit_number ~= nil then a.fueled[e.unit_number] = true end
  return moved > 0
end

local function plan_round(t, ctx)
  local a = t.args
  local cap = stack_cap(a.ingredient, a.amount)
  local main = ctx.entity.get_main_inventory()
  local have = inv.count(main, a.ingredient)
  local avail = math.min(t.left, math.floor(have / a.amount))
  local round = {}
  local per = math.max(1, math.ceil(avail / #t.furn))
  for _, e in ipairs(t.furn) do
    if avail <= 0 then break end
    if e.valid then
      local c = math.min(per, cap, avail)
      avail = avail - c
      round[#round + 1] = { e = e, crafts = c, loaded = false }
    end
  end
  return round
end

local function tick_load(t, ctx)
  local a = t.args
  if t.round == nil then
    t.round = plan_round(t, ctx)
    t.i = 1
    if #t.round == 0 then
      t.phase = "done"
      return nil
    end
  end
  local r = t.round[t.i]
  if r == nil then
    local any = false
    for _, x in ipairs(t.round) do if x.loaded then any = true end end
    if not any then return inv.failed("no_items", "furnaces took nothing", { reason = "no_furnace" }) end
    t.phase, t.wait_from = "wait", ctx.tick
    local longest = 0
    for _, x in ipairs(t.round) do longest = math.max(longest, x.crafts) end
    local _, speed = energy_per_craft(t.round[1].e, a.time)
    t.deadline = ctx.tick + math.ceil(longest * a.time / speed * 60 * 2) + 600
    return nil
  end
  if not r.e.valid then r.crafts = 0 t.i = t.i + 1 return nil end
  local ap = inv.approach(t, ctx, r.e, "reach")
  if ap == nil then return nil end
  if ap ~= true then return ap end
  local main = ctx.entity.get_main_inventory()
  if not insert_fuel(t, ctx, r.e, r.crafts) then
    r.crafts = 0
    t.i = t.i + 1
    inv.stop_approach(t, ctx)
    return nil
  end
  local moved = inv.move(main, { entity = r.e }, a.ingredient, r.crafts * a.amount, ctx.entity)
  local crafts = math.floor(moved / a.amount)
  r.loaded = crafts > 0
  r.crafts = crafts
  r.put = moved
  t.left = t.left - crafts
  t.i = t.i + 1
  inv.stop_approach(t, ctx)
  return nil
end

local function furnace_state(r, a)
  local res = inv_of(r.e, "furnace_result")
  local src = inv_of(r.e, "furnace_source")
  local got = res and inv.count(res, a.item) or 0
  local idle = src ~= nil and src.is_empty()
  return got, idle
end

local function tick_wait(t, ctx)
  local a = t.args
  t.progress_tick = ctx.tick
  if (ctx.tick - t.wait_from) % M.WAIT_CHECK ~= 0 then return nil end
  local all = true
  for _, r in ipairs(t.round) do
    if r.loaded and r.e.valid then
      local got, idle = furnace_state(r, a)
      if not (idle and got >= math.floor(r.crafts * a.yield + 1e-9)) then all = false end
    end
  end
  if all or ctx.tick >= t.deadline then
    t.phase, t.i, t.timeout = "take", 1, (not all)
  end
  return nil
end

local function tick_take(t, ctx)
  local a = t.args
  local r
  while true do
    r = t.round[t.i]
    if r == nil or (r.loaded and r.e.valid) then break end
    t.i = t.i + 1
  end
  if r == nil then
    t.round = nil
    t.phase = (t.left > 0 and not t.timeout) and "load" or "done"
    return nil
  end
  local ap = inv.approach(t, ctx, r.e, "reach")
  if ap == nil then return nil end
  if ap ~= true then return ap end
  local h = ctx.entity
  local main = h.get_main_inventory()
  local res, src = inv_of(r.e, "furnace_result"), inv_of(r.e, "furnace_source")
  -- только своя доля: заложено × выход рецепта; чужое в выходе и входе не трогаем
  local share = math.ceil((r.put or 0) / a.amount * a.yield - 1e-9)
  local got = res and math.min(inv.count(res, a.item), share) or 0
  local moved = got > 0 and inv.move(res, { inv = main }, a.item, got, h) or 0
  t.gained = t.gained + moved
  t.progress.done = t.gained
  -- недоплавленное (срок вышел) возвращаем в карманы, но не больше заложенного за вычетом уже
  -- выплавленного (руда хозяина, подложенная в ту же печь, остаётся)
  local used = math.ceil(got / a.yield - 1e-9) * a.amount
  local rest = src and math.min(inv.count(src, a.ingredient), math.max(0, (r.put or 0) - used)) or 0
  if rest > 0 then
    local back = inv.move(src, { inv = main }, a.ingredient, rest, h)
    t.left = t.left + math.floor(back / a.amount)
  end
  inv.stop_approach(t, ctx)
  if moved < got then
    return inv.full_result(t, ctx, { smelted = { [a.item] = t.gained } })
  end
  t.i = t.i + 1
  return nil
end

function smelt.tick(t, ctx)
  local ph = t.phase
  if ph == "load" then return tick_load(t, ctx) end
  if ph == "wait" then return tick_wait(t, ctx) end
  if ph == "take" then return tick_take(t, ctx) end
  if t.gained <= 0 then
    return inv.failed("stuck", "nothing smelted", { smelted = {}, reason = "smelt_failed" })
  end
  return inv.done({ smelted = { [t.args.item] = t.gained } })
end

function smelt.stop(t, ctx)
  inv.stop_approach(t, ctx)
  reserve.release_machines(ctx.helper_id)
end

local MODS = { collect = collect, craft = craft, mine = mine, smelt = smelt }

-- ------------------------------------------------------------------ шаги

local function new_child(task, ctx, name, args)
  return { ["do"] = name, helper = task.helper, job = task.job, args = args, created_tick = ctx.tick,
    started_tick = ctx.tick }
end

--- Запустить шаг плана. → nil │ result (шаг кончился на старте), c — запись g.cur (всегда есть).
local function start_step(g, task, ctx, step)
  local kind = step.kind
  local args
  local c = { step = step, kind = kind, before = inv.counts(ctx.entity.get_main_inventory()) }
  if kind == "collect" then
    args = { items = step.items, radius = g.radius, from_lines = g.from_lines }
  elseif kind == "craft" then
    args = { recipe = step.recipe, count = step.count, wait = true }
  elseif kind == "mine" then
    args = { item = step.item, count = step.count }
  else
    local rec
    for _, r in ipairs(idx_of(g, ctx)[step.item] or {}) do
      if r.name == step.recipe and r.kind == "smelt" then rec = r end
    end
    if rec == nil then return inv.failed("not_found", "recipe " .. step.recipe .. " disappeared"), c end
    local ing = rec.ingr[1]
    args = { recipe = step.recipe, item = step.item, count = step.count, yield = step.yield, time = rec.time,
      category = rec.category, ingredient = ing.name, amount = ing.amount, radius = g.radius, fueled = g.fueled,
      origin = g.origin }
  end
  c.t = new_child(task, ctx, kind, args)
  local ok, res = pcall(MODS[kind].start, c.t, ctx)
  if not ok then return inv.failed("internal", tostring(res)), c end
  return res, c
end

local function stop_cur(c, ctx)
  if c.t ~= nil then pcall(MODS[c.kind].stop, c.t, ctx) end
end

local function stop_child(g, ctx)
  local c = g.cur
  if c == nil then return end
  g.cur = nil
  stop_cur(c, ctx)
end

local function note_from(g, step, res)
  local d = res.detail or {}
  if step.kind == "collect" then
    for name, n in pairs(d.collected or {}) do add(g.from.storage, name, n) end
  elseif step.kind == "craft" then
    for name, n in pairs(d.crafted or {}) do add(g.from.crafted, name, n) end
  elseif step.kind == "smelt" then
    for name, n in pairs(d.smelted or {}) do add(g.from.smelted, name, n) end
  elseif step.kind == "mine" then
    for name, n in pairs(d.mined or {}) do add(g.from.mined, name, n) end
  end
end

local function step_gain(c, ctx)
  local main = ctx.entity.get_main_inventory()
  if c.step.kind == "collect" then
    local n = 0
    for name in pairs(c.step.items) do
      n = n + math.max(0, inv.count(main, name) - (c.before[name] or 0))
    end
    return n
  end
  return math.max(0, inv.count(main, c.step.item) - (c.before[c.step.item] or 0))
end

-- ------------------------------------------------------------------ итог

local function have_of(ctx, want)
  local main = ctx.entity.get_main_inventory()
  local out = {}
  for name in pairs(want) do out[name] = inv.count(main, name) end
  return out
end

--- Подсказка в shortfall: недостающее лежит в выходах линий хозяина или машин (брать — только с
--- from_lines). Предмет записи — тот, что просили, и «бутылочное горлышко» via.
local function add_line_hints(g, ctx, shortfall)
  local h = ctx.entity
  local filter = {}
  for _, s in ipairs(shortfall) do
    filter[s.item] = true
    if s.via then filter[s.via] = true end
  end
  local ok, scan = pcall(lines.scan, h.surface, h.force, util.xy(h.position), g.radius, filter, ctx.helper_id,
    { hint = true })
  if not ok or scan.lines == nil then return end
  for _, s in ipairs(shortfall) do
    local x, of = lines.hint(scan.lines, s.item), nil
    if x == nil and s.via then x, of = lines.hint(scan.lines, s.via), s.via end
    if x ~= nil then
      s.in_lines, s.lines_at, s.hint = x.count, x.at, x.hint
      if of then s.lines_item = of end
    end
  end
end

local function finish(g, task, ctx, plan)
  stop_child(g, ctx)
  local have = have_of(ctx, g.want)
  local shortfall, gained = {}, 0
  local names = {}
  for name in pairs(g.want) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    gained = gained + math.max(0, have[name] - (g.start[name] or 0))
    local miss = g.want[name] - have[name]
    if miss > 0 then
      local why = plan and plan.by_item[name]
      local entry = { item = name, missing = miss, reason = (why and why.reason) or g.last_reason or "no_source" }
      if why and why.via ~= name then entry.via = why.via end
      -- предмет был на складах, но сбор не удался (путь, досягаемость): причина — код сбора, а не
      -- «нечем получить»
      if entry.reason == "no_source" and g.blocked.collect and g.seen_stock[name] then
        entry.reason = g.reasons.collect or "no_items"
      end
      shortfall[#shortfall + 1] = entry
    end
  end
  if #shortfall > 0 and not g.from_lines then add_line_hints(g, ctx, shortfall) end
  local detail = { have = have, from = g.from }
  for _, k in ipairs({ "inventory", "storage", "crafted", "smelted", "mined" }) do
    if next(g.from[k]) == nil then g.from[k] = nil end
  end
  if #shortfall == 0 then return inv.done(detail) end
  detail.shortfall = shortfall
  if gained == 0 then
    return inv.failed("no_items", "could not get the items", detail)
  end
  return inv.done(detail)
end

-- ------------------------------------------------------------------ API

--- Начать. want = {name = count} — сколько должно быть в карманах.
function M.begin(task, ctx, want, opts)
  opts = opts or {}
  local h = ctx.entity
  inv.check_items(want, "args.items")
  local main = h.get_main_inventory()
  local g = {
    want = util.copy(want), from = { inventory = {}, storage = {}, crafted = {}, smelted = {}, mined = {} },
    blocked = {}, reasons = {}, start = inv.counts_of(main, want), radius = opts.radius or M.DEFAULT_RADIUS,
    mineable = {}, replans = 0, fueled = {}, from_lines = opts.from_lines == true, seen_stock = {},
    -- печи ищутся вокруг точки, где задачу дали: шаг «копать» уводит тело от печи
    origin = util.xy(h.position),
  }
  for name, n in pairs(want) do add(g.from.inventory, name, math.min(n, g.start[name] or 0)) end
  task.supply = g
  return nil
end

local function progress(g, task, ctx)
  local have = have_of(ctx, g.want)
  local done, total = 0, 0
  for name, n in pairs(g.want) do
    total = total + n
    done = done + math.min(n, have[name])
  end
  task.progress = { done = done, total = total }
end

--- Один тик. nil — работаю, result — готово.
function M.step(task, ctx)
  local g = task.supply
  if g.mineable == nil then g.mineable = {} end
  if g.fueled == nil then g.fueled = {} end
  if g.seen_stock == nil then g.seen_stock = {} end
  progress(g, task, ctx)
  if g.cur ~= nil then
    local c = g.cur
    local ok, res = pcall(MODS[c.kind].tick, c.t, ctx)
    if not ok then res = inv.failed("internal", tostring(res)) end
    if res == nil then
      if c.t.progress_tick then task.progress_tick = c.t.progress_tick end
      return nil
    end
    g.cur = nil
    stop_cur(c, ctx)
    note_from(g, c.step, res)
    if res.status == "failed" and (res.code == "no_space" or res.code == "internal") then
      local d = res.detail or {}
      d.have, d.from = have_of(ctx, g.want), g.from
      return { status = "failed", code = res.code, text = res.text, detail = d }
    end
    if step_gain(c, ctx) <= 0 then
      g.blocked[c.step.key] = true
      g.reasons[c.step.key] = res.status == "failed" and res.code or "no_items"
      g.last_reason = g.reasons[c.step.key]
    end
    return nil
  end
  g.replans = g.replans + 1
  local plan = make_plan(g, task, ctx)
  local have = have_of(ctx, g.want)
  local satisfied = true
  for name, n in pairs(g.want) do if have[name] < n then satisfied = false end end
  if satisfied then return finish(g, task, ctx, plan) end
  if #plan.steps == 0 or g.replans > M.MAX_REPLANS then return finish(g, task, ctx, plan) end
  local res, c = start_step(g, task, ctx, plan.steps[1])
  if res == nil then
    g.cur = c
  else
    stop_cur(c, ctx)
    note_from(g, c.step, res)
    g.blocked[c.step.key] = true
    g.reasons[c.step.key] = res.status == "failed" and res.code or "no_items"
    g.last_reason = g.reasons[c.step.key]
    if res.status == "done" and step_gain(c, ctx) > 0 then g.blocked[c.step.key] = nil end
  end
  return nil
end

function M.stop(task, ctx)
  local g = task.supply
  if g ~= nil then stop_child(g, ctx) end
end

-- ------------------------------------------------------------------ флаг auto_supply

--- Предварительное снабжение действия (place, insert, build_*): пока task.supply ≠ nil, шаг идёт здесь.
--- → nil (иду, ждать) │ false (снабжения нет или оно закончилось — дальше обычная работа действия)
---   │ result (снабжение провалилось: failed от get_items с detail).
function M.pre_tick(task, ctx)
  if task.supply == nil then return false end
  local r = M.step(task, ctx)
  if r == nil then return nil end
  M.stop(task, ctx)
  task.supply = nil
  task.supply_spent = r.detail ~= nil and r.detail.shortfall ~= nil
  task.supply_last = r.detail
  if r.status == "failed" then return r end
  if task.g ~= nil then
    task.g.next_scan = 0
    task.g.last_progress = ctx.tick
    -- ghosts_stop перед снабжением вернул переключатель дронов; для стройки он снова наш
    build.dispatch_arm(task, ctx)
  end
  return false
end

--- Стройка кончилась no_items с detail.missing: при флаге auto_supply добыть недостающее (не
--- больше 3 раз за задачу; недобор прошлого раза — повтора нет). → true, если снабжение началось.
function M.start_for_build(task, ctx, r)
  if not task.args.auto_supply then return false end
  -- только когда стройка встала из-за нехватки предметов (признак r.shortage), а не из-за дронов
  if not r.shortage then return false end
  local missing = r.detail and r.detail.missing
  if type(missing) ~= "table" or next(missing) == nil then return false end
  if (task.supply_rounds or 0) >= 3 or task.supply_spent then
    -- повтора нет: итог стройки несёт итог последнего снабжения
    if task.supply_last ~= nil and task.supply_last.shortfall ~= nil then
      r.detail = r.detail or {}
      r.detail.supply = task.supply_last
    end
    return false
  end
  local main = ctx.entity.get_main_inventory()
  local want = {}
  for name, n in pairs(missing) do want[name] = inv.count(main, name) + n end
  task.supply_rounds = (task.supply_rounds or 0) + 1
  task.supply_orig = r
  -- стройка кончилась и вернула переключатель дронов; на время снабжения и дальше он снова наш,
  -- иначе дроны заберут из карманов только что добытое
  if task.g ~= nil then build.dispatch_arm(task, ctx) end
  M.begin(task, ctx, want, {})
  return true
end

--- Итог стройки, когда её снабжение провалилось: исходный no_items стройки + detail.supply;
--- «инвентарь полон» — как есть.
function M.build_failed(task, sres)
  if sres.code == "no_space" then return sres end
  local orig = task.supply_orig
  if orig == nil then return sres end
  orig.detail = orig.detail or {}
  orig.detail.supply = sres.detail
  return orig
end

--- detail результата с итогом частичного снабжения: снабжение закончилось с недобором (done с
--- shortfall) — в итоговый no_items кладётся detail.supply.
function M.with_supply(task, detail)
  detail = detail or {}
  if task.supply_last ~= nil and task.supply_last.shortfall ~= nil then detail.supply = task.supply_last end
  return detail
end

--- Итог места/вставки, когда снабжение провалилось: код и текст снабжения, detail.supply.
function M.failed_with(sres, detail)
  detail = detail or {}
  detail.supply = sres.detail
  return { status = "failed", code = sres.code, text = sres.text, detail = detail }
end

return M
