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
	a("Window!imsvale-pathvis-settings Window::Content", {
		padding = { 4, 12, 10, 12 },
	})

	-- The setting rows (script_param_util.buildScriptParamComp: a script-param-wrap with the
	-- label, left-parameters, and the button group, right-parameters). Nothing sizes them
	-- outside the construction menu: without these the buttons didn't show. As the map editor
	-- sizes its settings (::/gui/map_editor/map_editor.css.lua, Window!map-editor-window).
	a("Window!imsvale-pathvis-settings !script-param-wrap", {
		gravity = { -1, 0.5 },
	})
	a("Window!imsvale-pathvis-settings !script-param-wrap > BoxLayout", {
		gravity = { -1, 0.5 },
	})
	a("Window!imsvale-pathvis-settings !script-param-wrap !left-parameters", {
		size = { -1, 30 },
		gravity = { 0, 0.5 },
		margin = { 0, 16, 0, 0 },
	})
	a("Window!imsvale-pathvis-settings !script-param-wrap !right-parameters", {
		size = { 140, -1 },
		gravity = { 1, -1 },
	})
	a("Window!imsvale-pathvis-settings !right-parameters > BoxLayout", {
		innerSpacing = { 4, 4 },
	})
	a("Window!imsvale-pathvis-settings !script-param-wrap ToggleButton", {
		padding = { 4, 4, 4, 4 },
	})
	a("Window!imsvale-pathvis-settings !script-param-wrap ToggleButton > FloatingLayout > TextView", {
		size = { 50, 24 },
		textAlignment = { 0.5, 0.5 },
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
