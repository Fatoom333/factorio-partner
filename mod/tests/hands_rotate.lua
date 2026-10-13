-- Действие rotate: поворот своей постройки в досягаемости (как клавиша R).
local S = require("stubs")
local C = require("stubs_c")

local function job_of(d, args) return S.okr(C.act(d, args)).job end

local function belt(pos, force)
  local e = C.chest(pos, {})
  rawset(e, "supports_direction", true)
  rawset(e, "rotatable", true)
  rawset(e, "direction", 4)
  if force then rawset(e, "force", force) end
  return e
end

S.suite("hands_rotate", {
  { "подходит на reach и поворачивает свою постройку", function()
      local W = C.setup()
      local e = belt({ x = 30.5, y = 0.5 })
      local d, kind = C.wait(job_of("rotate", { target = { unit_number = e.unit_number }, direction = 0 }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.direction, d.detail.was }, { 0, 4 })
      S.eq(e.direction, 0)
      S.ok(W.h.can_reach_entity(e), "поворачивал только в досягаемости")
  end },
  { "уже смотрит туда — done без изменений", function()
      C.setup()
      local e = belt({ x = 3.5, y = 0.5 })
      local d, kind = C.wait(job_of("rotate", { target = { unit_number = e.unit_number }, direction = 4 }))
      S.eq(kind, "job_done", S.dump(d))
      S.eq({ d.detail.direction, d.detail.was, e.direction }, { 4, 4, 4 })
  end },
  { "неповоротная постройка — bad_args, направление не тронуто", function()
      C.setup()
      local e = belt({ x = 3.5, y = 0.5 })
      rawset(e, "rotatable", false)
      local d, kind = C.wait(job_of("rotate", { target = { unit_number = e.unit_number }, direction = 0 }))
      S.eq(kind, "job_failed", S.dump(d))
      S.eq({ d.code, e.direction }, { "bad_args", 4 })
  end },
  { "направление не из четырёх сторон — bad_args", function()
      C.setup()
      local e = belt({ x = 3.5, y = 0.5 })
      S.err(C.act("rotate", { target = { unit_number = e.unit_number }, direction = 2 }), "bad_args")
  end },
})
