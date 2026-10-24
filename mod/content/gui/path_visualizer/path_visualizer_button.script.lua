-- The overlay's switch: a toggle button in the HUD's mod button area (top left).

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl"
local overlay = ug_require "imsvale_path_visualizer::/gui/path_visualizer/path_visualizer_overlay.lua"

local Button = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "ImsvalePathVisualizerButton", function()
	local on = react.useState(overlay.isOn() and 1 or 0)
	return builtin.BoxLayout{
		children = {
			builtin.ToggleButton{
				meta = {
					id = "imsvale_path_visualizer.button",
					tooltip = _("Reserved train paths"),
				},
				value = on:old(),
				onValueChange = function(value)
					on:set(value)
					overlay.setOn(value == 1)
				end,
				content = builtin.ImageView{
					path = "::/gui/construction/menu/menu_categories/category_rail_signals.tga",
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
			},
		},
	}
end)

function data()
	return { Button = Button }
end
