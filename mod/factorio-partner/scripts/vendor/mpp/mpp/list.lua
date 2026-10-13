-- Vendored from Mining Patch Planner 1.7.19 by Rimbas (MIT License, see ../LICENSE):
-- https://github.com/rimbas/mining-patch-planner, commit 95be67cf, file mpp/list.lua.
-- Copyright (c) 2021 Rimbas. Changes made for factorio-partner are marked [partner]
-- and listed in ../README.md.
local table_insert = table.insert

---@class List<T> : {[integer]:T, (push:fun(self:List<T>,v:T):List<T>),(unshift:fun(self:List<T>,value:T):List<T>),(append:fun(self:List<T>,...:T):List<T>),(conditional_append:fun(self:List<T>,check:boolean,...:T):List<T>) }

local list_mt = {}
list_mt.__index = list_mt

-- [partner] guarded: the unit-test stubs of the core have no register_metatable
if script.register_metatable then script.register_metatable("fp_mpp_List", list_mt) end

function list_mt:push(value)
	table_insert(self, value)
	return self
end

function list_mt:unshift(value)
	table_insert(self, 1, value)
	return self
end

function list_mt:append(...)
	for _, value in pairs({...}) do
		table_insert(self, value)
	end
	return self
end

function list_mt:conditional_append(check, ...)
	if not check then return self end
	for _, value in pairs({...}) do
		table_insert(self, value)
	end
	return self
end

---@generic T
---@param t? T[]
---@return List<T>
return function(t)
	return setmetatable(t or {}, list_mt)
end
