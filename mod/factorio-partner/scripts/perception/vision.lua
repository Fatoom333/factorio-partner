-- Обзор вокруг помощника через force.chart.
-- Контракт: PROTOCOL.md §6.8, STATE.md «vision».
-- Раз в 60 тиков для каждого живого помощника с on: чанки в радиусе 2 чанков от тела,
-- сгенерированные и (не открытые или открывавшиеся >= 10 с назад), не больше 8 за итерацию,
-- ближние первыми. Хранилище: storage.vision = {on={[h]={on=bool, unit=unit_number}},
-- charted={[key]=tick}}; запись on[h] от прошлого тела (другой unit_number) не действует —
-- после helper_spawn обзор снова включён (C.vision_on).
local C = require("scripts.perception.state").common

local M = {}

M.PERIOD = 60          -- тиков между итерациями
M.RADIUS_CHUNKS = 2    -- 64 клетки, как у игрока
M.REFRESH = 600        -- 10 с: раньше этого чанк повторно не открываем
M.MAX_PER_ITER = 8     -- чанков на помощника за итерацию

local floor = math.floor

local function chunk_key(surface_index, cx, cy)
  return surface_index .. ":" .. cx .. ":" .. cy
end
M.chunk_key = chunk_key

-- Выбрать чанки для открытия вокруг тела. → массив {cx, cy, key}
function M.pick_chunks(entity, charted, tick)
  local surface = entity.surface
  local pos = entity.position
  local ccx, ccy = floor(pos.x / 32), floor(pos.y / 32)
  local cands = {}
  local R = M.RADIUS_CHUNKS
  for dx = -R, R do
    for dy = -R, R do
      local cx, cy = ccx + dx, ccy + dy
      local key = chunk_key(surface.index, cx, cy)
      local last = charted[key]
      local fresh = last ~= nil and tick - last < M.REFRESH
      if not fresh and surface.is_chunk_generated({ x = cx, y = cy }) then
        cands[#cands + 1] = { cx = cx, cy = cy, key = key, d = dx * dx + dy * dy }
      end
    end
  end
  table.sort(cands, function(a, b)
    if a.d ~= b.d then return a.d < b.d end
    if a.cx ~= b.cx then return a.cx < b.cx end
    return a.cy < b.cy
  end)
  local out = {}
  for i = 1, math.min(#cands, M.MAX_PER_ITER) do out[i] = cands[i] end
  return out
end

-- Одна итерация обзора (ядро вызывает через on_nth[60]).
function M.run(tick)
  local helpers = storage.helpers
  if type(helpers) ~= "table" then return end
  local vs = C.vision_storage()
  local charted = vs.charted

  -- «Нет записи» и «открывали >= 10 с назад» значат одно и то же — старое забываем.
  for key, t in pairs(charted) do
    if tick - t >= M.REFRESH then charted[key] = nil end
  end

  -- Записи, которые ничего не меняют (on=true, от прошлого тела, от удалённого помощника), —
  -- чистим: «нет записи» = включено.
  for id in pairs(vs.on) do
    if C.vision_on(id) then vs.on[id] = nil end
  end

  for id, h in pairs(helpers) do
    local e = type(h) == "table" and h.entity or nil
    -- тело-игрок (PROTOCOL §7): карту ему открывает движок, мод обзор не ведёт
    if e and h.state == "alive" and h.player_index == nil and e.valid and C.vision_on(id) then
      local surface, force = e.surface, e.force
      for _, c in ipairs(M.pick_chunks(e, charted, tick)) do
        local x0, y0 = c.cx * 32, c.cy * 32
        force.chart(surface, { { x0, y0 }, { x0 + 31, y0 + 31 } })
        charted[c.key] = tick
      end
    end
  end
end

local function vision_op(args, ctx)
  args = C.check_args(args)
  C.allow_only(args, { on = true })
  C.helper_entity(ctx, true)
  if args.on == nil then C.bad("on", "required") end
  local on = C.check_bool(args.on, "on")
  C.set_vision(ctx.helper_id, on)
  return { on = on }
end

M.ops = {
  vision = vision_op,
}

M.on_nth = {
  [M.PERIOD] = function(e) M.run(e.tick) end,
}

function M.on_init()
  C.vision_storage()
end

function M.on_configuration_changed(data)
  C.vision_storage()
end

return M
