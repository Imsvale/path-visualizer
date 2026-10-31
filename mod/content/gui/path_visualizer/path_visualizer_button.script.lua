-- The overlay's switch: a toggle button in the HUD's mod button area (top left). Right-click
-- opens the settings, a window right under the button that closes on a click outside it or
-- Escape (as the game's popovers do).
--
-- The settings window is an ordinary builtin.Window (the game's PopoverWindow, used at first,
-- is styled as a bare box by its class popover) holding a checkbox per setting.
--
-- The mod button area passes its plugins no game context; the window container comes from
-- gui/main/game_react_globals.tl (the global gameGlobals behind it isn't visible to mods).

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl"
local styleutil = ug_require "::/gui/main/styleutil.tl"
local overlay = ug_require "imsvale_path_visualizer::/gui/path_visualizer/path_visualizer_overlay.lua"

local function log(msg)
	print("[pathvis] " .. msg)
end

local function windowApi()
	local wc
	local ok, err = pcall(function()
		local globals = ug_require "::/gui/main/game_react_globals.tl"
		wc = globals.getDefaultWindowContainer():get():getApi()
	end)
	if not ok then log("window container: " .. tostring(err)) end
	return wc
end

-- A short bar in an overlay colour (image and size: the stylesheet, R::Component!imsvale-pathvis-swatch).
local function swatch(color)
	return builtin.Component{
		meta = {
			class = "imsvale-pathvis-swatch",
			styleSheet = styleutil.makeStyle{ backgroundColor1 = { color[1], color[2], color[3], 1.0 } },
		},
	}
end

-- A checkbox with its overlay colour in front.
local function settingRow(label, on, color, set)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = {
			swatch(color),
			builtin.CheckBox{
				label = label,
				initialValue = on and 1 or 0,
				onValueChange = function(value) set(value == 1) end,
			},
		},
	}
end

local SettingsContent = react.RegisterRecipe("ImsvalePathVisualizerSettingsContent", function(params)
	-- close on a click outside or Escape, as PopoverWindowContent does (gui/main/popover_react_util.tl)
	react.useInputAction("IA_MENU_BACK", react.iaHandler(function() params.onClose() end))
	react.onMouseEvent(function(evt)
		if evt.type == api.gui.mouse.Event.Type.PressedOutside and evt.button == 0 then
			params.onClose()
			return true
		end
		return false
	end)
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			settingRow(_("Braking distance"), overlay.isBraking(), overlay.colors.braking, overlay.setBraking),
			settingRow(_("Manual stop"), overlay.isEmergency(), overlay.colors.emergency, overlay.setEmergency),
		},
	}
end)

local SettingsWindow = react.RegisterWrapperRecipe("ImsvalePathVisualizerSettingsWindow", builtin.Window, function(params)
	-- no-close-button: the game's rule for it hides the close button and with it the notch it
	-- cut in the frame's top right corner (Window!no-close-button Window::TitleLayout
	-- Button!close, builtin.css.lua). Not compact: that dropped the title bar but shifted the
	-- drop shadow and darkened a band of the background (2026-10-24); the title is made small
	-- in the stylesheet instead.
	return builtin.Window{
		meta = { class = "no-close-button, imsvale-pathvis-settings" },
		title = _("Settings"),
		closable = false,
		movable = false,
		initialX = params.x,
		initialY = params.y,
		onClose = params.onClose,
		content = SettingsContent{ onClose = params.onClose },
	}
end)

local settingsOpen = false

local function closeSettings()
	local wc = windowApi()
	if wc then wc.removeAllWindows(SettingsWindow) end
	settingsOpen = false
end

local function openSettings(pos)
	local wc = windowApi()
	if not wc then
		log("no window container: settings unavailable")
		return
	end
	wc.removeAllWindows(SettingsWindow)
	wc.addSingletonWindow(SettingsWindow, { x = pos.x, y = pos.y, onClose = closeSettings })
	settingsOpen = true
end

local Button = react.RegisterPluginRecipe(main_mod_button_area.MainModButtonAreaExtension, "ImsvalePathVisualizerButton", function()
	local on = react.useState(overlay.isOn() and 1 or 0)
	local selfRef = react.useSelfRef()

	react.onMouseEvent(function(evt)
		if evt.type == api.gui.mouse.Event.Type.Pressed and evt.button ~= 0 then
			if settingsOpen then
				closeSettings()
			else
				-- right under the button: its top left corner plus its height
				local pos = { x = 0, y = 0 }
				pcall(function()
					local p = selfRef:get():getPosition(0.0, 0.0)
					local size = api.gui.byId.getSize("imsvale_path_visualizer.button")
					pos = { x = p.x, y = p.y + size.y }
				end)
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
					path = "imsvale_path_visualizer::/gui/path.tga",
					scaling = builtin.type.ImageViewScaling.AutoFit,
				},
			},
		},
	}
end)

function data()
	return { Button = Button }
end
