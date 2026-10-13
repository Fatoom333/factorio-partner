-- Wuastbude Belt & Pipe Router: which blockers are ignored (marked for deconstruction).
-- Author: wuast94. License: MIT (see LICENSE in this folder). Version 0.19.3,
-- https://git.wuastbude.de/Wuast94/wuastbude-pack, commit ad626eff, file wuastbude-router/scripts/entity_policy.lua.
-- Changes for factorio-partner: none (this header only).
local entity_policy = {}

function entity_policy.is_ignored_blocker(entity)
  return entity.valid ~= false and entity.to_be_deconstructed and entity.to_be_deconstructed() == true
end

return entity_policy
