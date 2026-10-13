-- Vendored from Mining Patch Planner 1.7.19 by Rimbas (MIT License, see ../LICENSE):
-- https://github.com/rimbas/mining-patch-planner, commit 95be67cf, file layouts/compact_logistics.lua.
-- Copyright (c) 2021 Rimbas. Changes made for factorio-partner are marked [partner]
-- and listed in ../README.md.
local super_compact = require("scripts.vendor.mpp.layouts.super_compact")
local logistics =require("scripts.vendor.mpp.layouts.logistics")

---@class CompactLogisticsLayout: SuperCompactLayout
local layout = table.deepcopy(super_compact)

layout.name = "compact_logistics"
layout.translation = {"", "[entity=passive-provider-chest] ", {"mpp.settings_layout_choice_compact_logistics"}}

layout.restrictions.lamp_available = false
layout.restrictions.belt_available = false
layout.restrictions.logistics_available = true
layout.restrictions.lane_filling_info_available = false
layout.restrictions.belt_merging_available = false
layout.restrictions.belt_planner_available = false

layout.do_power_pole_joiners = false

layout.prepare_belt_layout = logistics.prepare_belt_layout
layout.finish = logistics.finish

return layout
