-- Puts the reservation lines (path_visualizer_overlay.lua) into every ActionDescriptor, so they
-- show whatever action is active. Runs through the react-replacement-config
-- (path_visualizer_replace.res.lua), before any recipe; recipes can't be replaced afterwards.
--
-- An ActionDescriptor takes at most one EdgeRenderable (two crash the game, parallelism
-- 2026-10-10), and several tools draw their own. So EdgeRenderable is wrapped as well: one
-- built for a descriptor gets our lines added to its edges, and the descriptor then gets no
-- second one. Children are built before their descriptor, so a flag set by the
-- EdgeRenderable wrapper tells the next descriptor.
--
-- Chained, not replacing: each wrapper calls what was in the recipe's replacement slot when
-- it was installed (_react.recipeReplace[id], another mod's wrapper), and only where that's
-- empty the game's original (_react.originalRecipeFn[id]). Calling the original directly (as
-- react.CallOriginalRecipe does) would drop a wrapper installed before ours. See
-- ../docs/GUI.md, "Replacing recipes".
-- Installed early (order -1000 in the .res.lua), so ours is the innermost wrapper: a mod
-- chaining onto it runs first, and an EdgeRenderable it adds passes through our
-- EdgeRenderable wrapper before our descriptor wrapper decides, so there's never a second one.
-- Were ours outer, it would add its own before an inner wrapper added another: a crash.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local overlay = ug_require "imsvale_path_visualizer::/gui/path_visualizer/path_visualizer_overlay.lua"

local function log(msg)
	print("[pathvis] " .. msg)
end

local function isParams(arg)
	return type(arg) == "table" and not arg.is_react_ref_info and not arg.is_react_style_info
end

local function copyOf(t)
	local copy = {}
	for k, v in pairs(t) do copy[k] = v end
	return copy
end

-- Vanilla children lists can have nil holes (`cond and node or nil`): compacted. Named
-- entries are kept as they are (the line window's action has `lineViewer = lineViewer`;
-- dropping it detached the line viewer, with a "Preserved props" warning every frame).
local function compact(list)
	local out, maxIndex = {}, 0
	for k, v in pairs(list or {}) do
		if type(k) == "number" then
			if k > maxIndex then maxIndex = k end
		else
			out[k] = v
		end
	end
	for i = 1, maxIndex do
		if list[i] ~= nil then out[#out + 1] = list[i] end
	end
	return out
end

-- Recipes are called as Recipe(params) or Recipe(ref, params): wraps fn(params) around the
-- original. Explicit arities: the script sandbox lacks parts of the base library.
local function wrapParams(original, fn)
	return function(a, b, c)
		if c ~= nil then
			return original(a, b, fn(c))
		elseif b ~= nil then
			return original(a, fn(b))
		end
		return original(fn(a))
	end
end

local function doReplace(replacementApi)
	local ok, internal = pcall(function() return _react end)
	if not ok or type(internal) ~= "table" then internal = {} end
	-- what each recipe calls through to: the wrapper already installed, else the original
	local function previous(recipe)
		local id = react.GetRecipeId(recipe)
		if not id then return nil end
		return (internal.recipeReplace and internal.recipeReplace[id])
			or (internal.originalRecipeFn and internal.originalRecipeFn[id])
	end
	local previousAD, previousER = previous(builtin.ActionDescriptor), previous(builtin.EdgeRenderable)
	if not previousAD or not previousER then
		log("ActionDescriptor or EdgeRenderable not reachable: overlay off")
		return
	end

	local erBuilt = false -- an EdgeRenderable was built since the last descriptor
	local ownER = false -- building our own: leave it alone

	replacementApi.ReplaceRecipe(builtin.EdgeRenderable, wrapParams(previousER, function(params)
		if ownER or not isParams(params) then return params end
		erBuilt = true
		local lines = overlay.lines()
		if not lines then return params end
		local ok2, merged = pcall(function()
			local copy = copyOf(params)
			local edges = compact(params.edges)
			for _, e in ipairs(lines) do edges[#edges + 1] = e end
			copy.edges = edges
			return copy
		end)
		return ok2 and merged or params
	end))

	replacementApi.ReplaceRecipe(builtin.ActionDescriptor, wrapParams(previousAD, function(params)
		if not isParams(params) then return params end
		local hadER = erBuilt
		erBuilt = false
		local okSub, err = pcall(overlay.subscribe)
		if not okSub then log("subscribe: " .. tostring(err)) end
		local lines = overlay.lines()
		if hadER or not lines then return params end
		local ok2, injected = pcall(function()
			local copy = copyOf(params)
			local children = compact(params.children)
			ownER = true
			children[#children + 1] = builtin.EdgeRenderable{ edges = lines, ignoreDepth = true }
			ownER = false
			copy.children = children
			return copy
		end)
		ownER = false
		if not ok2 then
			log("inject: " .. tostring(injected))
			return params
		end
		return injected
	end))
	log("ActionDescriptor and EdgeRenderable wrapped")
end

function data()
	return { doReplace = doReplace }
end
