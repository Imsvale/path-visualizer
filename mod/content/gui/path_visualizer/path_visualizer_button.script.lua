-- The overlay's switch: a toggle button in the HUD's mod button area (top left). Right-click
-- opens the settings, a popover below the button (the game's PopoverWindow: it closes on a
-- click outside or Escape).
--
-- The mod button area passes its plugins no game context; the window container comes from
-- the game's global gameGlobals (gui/main/game.tl sets it).

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl"
local popover_react_util = ug_require "::/gui/main/popover_react_util.tl"
local overlay = ug_require "imsvale_path_visualizer::/gui/path_visualizer/path_visualizer_overlay.lua"

local function log(msg)
	print("[pathvis] " .. msg)
end

local function windowApi()
	local wc
	pcall(function() wc = gameGlobals.windowContainer:get():getApi() end)
	return wc
end

local Settings = react.RegisterRecipe("ImsvalePathVisualizerSettings", function()
	local braking = react.useState(overlay.isBraking() and 1 or 0)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			builtin.CheckBox{
				label = _("Braking point"),
				value = braking:old(),
				onValueChange = function(value)
					braking:set(value)
					overlay.setBraking(value == 1)
				end,
			},
		},
	}
end)

local popoverOpen = false

local function closeSettings()
	local wc = windowApi()
	if wc then wc.removeAllWindows(popover_react_util.PopoverWindow) end
	popoverOpen = false
end

local function openSettings(pos)
	local wc = windowApi()
	if not wc then
		log("no window container: settings unavailable")
		return
	end
	wc.removeAllWindows(popover_react_util.PopoverWindow)
	wc.addWindow(popover_react_util.PopoverWindow, "imsvale_path_visualizer.settings", {
		onClose = closeSettings,
		x = pos.x,
		y = pos.y,
		windowTitle = _("Path Visualizer"),
		recipe = Settings,
		params = {},
		compact = true,
	})
	popoverOpen = true
end

local Button = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "ImsvalePathVisualizerButton", function()
	local on = react.useState(overlay.isOn() and 1 or 0)
	local selfRef = react.useSelfRef()

	react.onMouseEvent(function(evt)
		if evt.type == api.gui.mouse.Event.Type.Pressed and evt.button ~= 0 then
			if popoverOpen then
				closeSettings()
			else
				local pos = { x = 0, y = 0 }
				pcall(function() pos = selfRef:get():getPosition(0.0, 1.0) end)
				openSettings(pos)
			end
			return true
		end
		return false
	end)

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
