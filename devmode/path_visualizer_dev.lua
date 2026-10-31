-- Dev switches, the dev build's version (dev mode copies it over
-- mod/content/scripts/path_visualizer_dev.lua, whose committed version has them all off).
return {
	reservationLog = true, -- game script: a log line whenever a train's reservation, path or waiting flag changes
	logSelected = true, -- overlay: selected trains' MOVE_PATH dynamics, a log line per game time step
	pathPosMarker = true, -- overlay: a magenta bar at selected trains' pathPos (the middle of the train)
	timing = true, -- overlay: its time per frame, a log line every 10 s
	logInfo = true, -- overlay: one-off information lines (errors are always logged)
}
