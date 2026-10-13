-- Vendored from Mining Patch Planner 1.7.19 by Rimbas (MIT License, see ../LICENSE):
-- https://github.com/rimbas/mining-patch-planner, commit 95be67cf, file layouts/sparse_logistics.lua.
-- Copyright (c) 2021 Rimbas. Changes made for factorio-partner are marked [partner]
-- and listed in ../README.md.
local mpp_util = require("scripts.vendor.mpp.mpp.mpp_util")

local floor, ceil = math.floor, math.ceil
local min, max = math.min, math.max
local EAST, NORTH, SOUTH, WEST = mpp_util.directions()

local sparse = require("scripts.vendor.mpp.layouts.sparse")
local logistics = require("scripts.vendor.mpp.layouts.logistics")

---@class SparseLogisticsLayout : SparseLayout
local layout = table.deepcopy(sparse)

layout.name = "sparse_logistics"
layout.translation = {"", "[entity=passive-provider-chest] ", {"mpp.settings_layout_choice_sparse_logistics"}}

layout.restrictions.belt_available = false
layout.restrictions.belt_merging_available = false
layout.restrictions.belt_planner_available = false
layout.restrictions.logistics_available = true
layout.restrictions.lane_filling_info_available = false

---@param self SparseLogisticsLayout
---@param state SimpleState
function layout:prepare_belt_layout(state)
	local belts = {}
	state.builder_belts = belts
	local output_rotated = state.miner.output_rotated

	for _, miner in ipairs(state.best_attempt.miners) do
		local out_pos = output_rotated[miner.direction]
		belts[#belts+1] = {
			name=state.logistics_choice,
			quality=state.logistics_quality_choice,
			thing="belt",
			grid_x=miner.x + out_pos.x,
			grid_y=miner.y + out_pos.y,
		}
	end

	return "prepare_lamp_layout"
end

layout.finish = logistics.finish

return layout
