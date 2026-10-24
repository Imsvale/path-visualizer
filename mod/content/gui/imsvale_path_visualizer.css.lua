local ssu = require "::/gui/main/stylesheetutil.lua"

-- The settings popover (path_visualizer_button.script.lua). The game's popovers open upward
-- from the bottom bar: Window!popover anchors at the bottom left ({ 0, 1 }) and is 440 wide
-- (::/gui/main/popover_react_util.css.lua). Ours opens downward from the top left button
-- area: anchored at the top left, narrow, with padding. Two classes to outrank the game's
-- rule. padding: { top, right, bottom, left }.

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	a("Window!popover!imsvale-pathvis-settings", {
		size = { 220, -1 },
		anchorPoint = { 0.0, 0.0 },
	})
	a("Window!popover!imsvale-pathvis-settings Window::Content", {
		padding = { 8, 12, 10, 12 },
	})

	-- A setting's overlay colour beside it: a plain white image, tinted by the inline
	-- backgroundColor1 (a colour alone draws nothing: the game's colour dots tint an image
	-- too, Component!color-dot-view in ::/gui/line_vehicle_mgmt/line_vehicle_mgmt.css.lua).
	a("Component!imsvale-pathvis-swatch", {
		size = { 18, 4 },
		gravity = { 0.5, 0.5 },
		margin = { 0, 0, 0, 8 },
		backgroundImage1 = { fileName = "::/gui/menu/design/allwhite_main.tga" },
	})

	return result
end
