-- blob_put: части в любом порядке, повтор, лимиты, срок жизни (PROTOCOL §4).
local S = require("stubs")

local n = 0
local function put(blob, part, total, data, id)
  n = n + 1
  return S.call{ v = 1, id = id or ("b-" .. n), op = "blob_put",
    args = { blob = blob, part = part, total = total, data = data } }
end

S.suite("blobs", {
  { "части в любом порядке, склейка, повтор части безопасен", function()
      S.load_mod()
      local blobs = require("scripts.core.blobs")
      S.eq(S.okr(put("bp-1", 3, 3, "ccc")), { blob = "bp-1", received = 1, total = 3 })
      S.eq(S.okr(put("bp-1", 1, 3, "aaa")).received, 2)
      S.eq(blobs.get("bp-1"), nil)
      S.eq(S.okr(put("bp-1", 1, 3, "aaa", "again")).received, 2, "повтор")
      S.eq(S.okr(put("bp-1", 2, 3, "bb")).received, 3)
      S.eq(blobs.get("bp-1"), "aaabbccc")
      S.eq(storage.blobs.bytes, 8)
  end },
  { "аргументы: id blob, part ≤ total, data ≤ 3500, total не меняется", function()
      S.load_mod()
      S.err(put("BP", 1, 1, "x"), "bad_args")
      S.err(put(string.rep("a", 33), 1, 1, "x"), "bad_args")
      S.err(put("a", 2, 1, "x"), "bad_args")
      S.err(put("a", 0, 1, "x"), "bad_args")
      S.err(put("a", 1, 1, string.rep("x", 3501)), "limit")
      S.err(put("a", 1, 301, "x"), "limit") -- total больше предела частей
      S.err(S.req("blob_put", { blob = "a", part = 1, total = 1 }), "bad_args")
      S.okr(put("a", 1, 2, string.rep("x", 3500)))
      S.err(put("a", 2, 3, "y"), "bad_args")
  end },
  { "всего ≤ 1 МБ -> limit", function()
      S.load_mod()
      local chunk = string.rep("z", 3500)
      local total = 300
      for i = 1, total - 1 do S.okr(put("big", i, total, chunk)) end
      S.okr(put("big", total, total, string.rep("z", 1048576 - 3500 * (total - 1))))
      S.eq(storage.blobs.bytes, 1048576)
      S.err(put("other", 1, 1, "x"), "limit")
      -- замена части того же размера проходит
      S.okr(put("big", 1, total, string.rep("y", 3500)))
  end },
  { "живут 10 минут с последней части", function()
      S.load_mod()
      local blobs = require("scripts.core.blobs")
      S.okr(put("old", 1, 2, "a"))
      S.tick(36000 - 600)
      S.okr(put("old", 2, 2, "b"))
      S.tick(36000 - 600)
      S.eq(blobs.get("old"), "ab")
      S.tick(600)
      S.eq(blobs.get("old"), nil)
      S.eq(storage.blobs.bytes, 0)
  end },
})
