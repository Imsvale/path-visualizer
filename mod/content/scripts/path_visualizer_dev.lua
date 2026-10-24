-- Dev switches, all off: what a release has. In dev mode devmode/path_visualizer_dev.lua
-- (all on) is copied over this file (see ../RELEASING.md).
return {
	reservationLog = false, -- game script: a log line whenever a train's reservation, path or waiting flag changes
	logSelected = false, -- overlay: selected trains' MOVE_PATH dynamics, a log line per game time step
	pathPosMarker = false, -- overlay: a magenta bar at selected trains' pathPos (the middle of the train)
}
