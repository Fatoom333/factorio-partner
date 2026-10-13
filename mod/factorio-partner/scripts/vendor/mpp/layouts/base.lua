-- Vendored from Mining Patch Planner 1.7.19 by Rimbas (MIT License, see ../LICENSE):
-- https://github.com/rimbas/mining-patch-planner, commit 95be67cf, file layouts/base.lua.
-- Copyright (c) 2021 Rimbas. Changes made for factorio-partner are marked [partner]
-- and listed in ../README.md.
local floor, ceil = math.floor, math.ceil
local min, max = math.min, math.max

local mpp_util = require("scripts.vendor.mpp.mpp.mpp_util")

---@class Layout
local layout = {}

layout.name = "Base"
layout.translation = {"mpp.settings_layout_choice_base"}

---@diagnostic disable-next-line: missing-fields
layout.defaults = {}
layout.defaults.miner = "electric-mining-drill"
layout.defaults.belt = "transport-belt"
layout.defaults.pole = "medium-electric-pole"
layout.defaults.logistics = "logistic-chest-passive-provider"
layout.defaults.pipe = "pipe"

---@diagnostic disable-next-line: missing-fields
layout.restrictions = {}
layout.restrictions.miner_available = true
layout.restrictions.miner_size = {0, 10e3}
layout.restrictions.miner_radius = {0, 10e3}
layout.restrictions.belt_available = true
layout.restrictions.uses_underground_belts = false
layout.restrictions.belt_underground_length = 0
layout.restrictions.pole_available = true
layout.restrictions.pole_omittable = true
layout.restrictions.pole_zero_gap = false
layout.restrictions.pole_width = {1, 1}
layout.restrictions.pole_length = {5, 10e3}
layout.restrictions.pole_supply_area = {2.5, 10e3}
layout.restrictions.lamp_available = true
layout.restrictions.coverage_tuning = false
layout.restrictions.logistics_available = false
layout.restrictions.landfill_omit_available = true
layout.restrictions.start_alignment_tuning = false
layout.restrictions.deconstruction_omit_available = true
layout.restrictions.module_available = false
layout.restrictions.pipe_available = false
layout.restrictions.placement_info_available = false
layout.restrictions.lane_filling_info_available = false
layout.restrictions.belt_merging_available = false
layout.restrictions.belt_planner_available = false

---@diagnostic disable-next-line: missing-fields
layout.belt_merging_strategies = {}
layout.belt_merging_strategies.back_merging = true
layout.belt_merging_strategies.side_merging_front = true
layout.belt_merging_strategies.side_merging_back = true
layout.belts_and_power_inline = false
layout.do_power_pole_joiners = false

--- Called from script.on_load
--- ONLY FOR SETMETATABLE USE
---@param self Layout
---@param state State
function layout:on_load(state) end

---@param proto MinerStruct
function layout:restriction_miner(proto)
	return true
end

--- Validate the selection
---@param self Layout
---@param state State
function layout:validate(state)
	local r = self.restrictions
	return true
end

---Layout-specific state initialisation
---@param self Layout
---@param state State
function layout:initialize(state)
	state.miner = mpp_util.miner_struct(state.miner_choice)
	state.pole = mpp_util.pole_struct(state.pole_choice, state.pole_quality_choice)
	if layout.restrictions.belt_available then
		state.belt = mpp_util.belt_struct(state.belt_choice)
	end
end

---Starting step
---@param self Layout
---@param state State
---@return CallbackState
function layout:start(state)
	return false
end

---Probably too much indirection at this point
---@param self Layout
---@param state State
function layout:tick(state)
	state.tick = state.tick + 1
	return self[state._callback](self, state)
end

---@param self Layout
---@param state State
function layout:deconstruct_previous_ghosts(state)
	-- [partner] removed: the undo of the previous plan of the same player
	return "initialize_grid"
end

return layout
