function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "imsvale_path_visualizer::/gui/path_visualizer/path_visualizer_replace.script",
			doReplaceFn = "doReplace",
			-- early (configs run in ascending order): ours becomes the innermost wrapper, so a
			-- mod chaining onto it builds its EdgeRenderable first, which ours then merges into
			-- instead of adding a second one (see path_visualizer_replace.script.lua)
			order = -1000,
		}
	}
end
