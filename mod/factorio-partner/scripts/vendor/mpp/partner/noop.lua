-- factorio-partner (stream M): stand-in for the Mining Patch Planner modules that are NOT vendored
-- (mpp.render_util, mpp.drawing, mpp.belt_planner — overlays and tools in the player's hand).
-- The vendored layouts only keep their `require` lines; every call that is left is a no-op.
local function nothing() end

return setmetatable({}, {
  __index = function() return nothing end,
  __call = function() return nil end,
})
