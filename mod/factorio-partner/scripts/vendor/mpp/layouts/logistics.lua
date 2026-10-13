-- Vendored from Mining Patch Planner 1.7.19 by Rimbas (MIT License, see ../LICENSE):
-- https://github.com/rimbas/mining-patch-planner, commit 95be67cf, file layouts/logistics.lua.
-- Copyright (c) 2021 Rimbas. Changes made for factorio-partner are marked [partner]
-- and listed in ../README.md.
local simple = require("scripts.vendor.mpp.layouts.simple")
local compact = require("scripts.vendor.mpp.layouts.compact")

---@class LogisticsLayout : CompactLayout
local layout = table.deepcopy(compact)

layout.name = "logistics"
layout.translation = {"", "[entity=passive-provider-chest] ", {"mpp.settings_layout_choice_logistics"}}

layout.restrictions.belt_available = false
layout.restrictions.belt_merging_available = false
layout.restrictions.belt_planner_available = false
layout.restrictions.pole_zero_gap = false
layout.restrictions.logistics_available = true
layout.restrictions.lane_filling_info_available = false

layout.do_power_pole_joiners = true

---@param self LogisticsLayout
---@param state SimpleState
function layout:prepare_belt_layout(state)
	local G, M, P = state.grid, state.miner, state.pole
	local belts = state.belts
	local output_rotated = M.output_rotated
	local logistics_choice, quality_choice = state.logistics_choice, state.logistics_quality_choice
	
	local builder_belts = List()
	state.builder_belts = builder_belts
	for _, belt in ipairs(belts) do
		local y, x_collection = belt.y, {}
		
		local function iterate_lane(lane)
			if not lane then return end
			for _, drill in ipairs(lane) do
				local output_pos = output_rotated[drill.direction]
				x_collection[drill.x + output_pos.x] = true
			end
		end
		iterate_lane(belt.lane1)
		iterate_lane(belt.lane2)
		
		for x, _ in pairs(x_collection) do
			builder_belts:push{
				name=logistics_choice,
				quality=quality_choice,
				thing="belt",
				grid_x=x,
				grid_y=y,
			}
			G:build_thing_simple(x, y, "belt")
		end
	end
	
	if (
		self.do_power_pole_joiners
		and state.pole_choice ~= "none"
		and state.pole_choice ~= "zero_gap"
		and M.size * 2 + 1 >= math.floor(P.wire)
		and M.size < (P.wire - 1) * 2
		and state.power_grid:get_y_gap() < P.wire * 2
	) then
		return "prepare_power_pole_joiners"
	end
	
	return "expensive_deconstruct"
end

function layout:prepare_power_pole_joiners(state)
	simple.prepare_power_pole_joiners(self, state)
	return "expensive_deconstruct"
end

---@param self SimpleLayout
---@param state SimpleState
---@return CallbackState
function layout:finish(state)
	-- [partner] removed: chat printout
	return false
end

return layout
