local ssu = require "::/gui/main/stylesheetutil.lua"

-- The settings window (path_visualizer_button.script.lua): opened right under the button in
-- the top left button area, so anchored at its top left. padding / margin: { top, right,
-- bottom, left }.

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	a("Window!imsvale-pathvis-settings", {
		anchorPoint = { 0.0, 0.0 },
	})
	-- a small title (the window style itself is the engine's; its title is the one thing the
	-- game's stylesheets touch)
	a("Window!imsvale-pathvis-settings Window::Title", {
		fontSize = 14,
	})
	a("Window!imsvale-pathvis-settings Window::Content", {
		padding = { 2, 14, 10, 14 },
	})
	-- a little space between the rows
	a("Window!imsvale-pathvis-settings CheckBox", {
		margin = { 3, 0, 3, 0 },
	})

	-- A setting's overlay colour in front of it: a plain white image, tinted by the inline
	-- backgroundColor1 (a colour alone draws nothing: the game's colour dots tint an image too,
	-- R::Component!color-dot-view in ::/gui/line_vehicle_mgmt/line_vehicle_mgmt.css.lua).
	-- builtin.Component is a recipe: its selector needs R:: (without it the rule matched
	-- nothing and the swatch didn't show, 2026-10-24).
	a("R::Component!imsvale-pathvis-swatch", {
		size = { 18, 4 },
		gravity = { 0.5, 0.5 },
		margin = { 0, 10, 0, 0 },
		backgroundImage1 = { fileName = "::/gui/menu/design/allwhite_main.tga" },
	})

	return result
end
