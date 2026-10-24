-- Reservation logger: watches every train's MOVE_PATH and logs a line whenever the end of its
-- reservation (reservedTo), its path (a new one for each leg, and at a stop) or its
-- waiting-for-free-path flag changes. reservedFrom alone isn't logged: it follows the train's
-- rear edge by edge. "path end" in a line: the reservation reaches the end of the leg's path.
-- Findings so far: docs/MOVE_PATH.md.

-- dev switch reservationLog (scripts/path_visualizer_dev.lua): off in a release
local devOk, dev = pcall(ug_require, "/scripts/path_visualizer_dev.lua")
local ENABLED = devOk and type(dev) == "table" and dev.reservationLog == true

local function log(fmt, ...)
	local args = { ... }
	pcall(function() print("[pathvis] " .. string.format(fmt, (table.unpack or unpack)(args))) end)
end

local function gameTime()
	local t
	pcall(function()
		t = api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
	end)
	return t
end

-- Path indices are 0-based; path.edges is a Lua table of EdgeIdDir.
local function pathEdge(mp, i)
	local e = mp.path.edges[i + 1]
	if e then return e.edgeId, e.dir end
end

local function edgeLength(edgeId)
	local len = 0
	pcall(function()
		local tn = api.engine.getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK)
		len = tn.edges[edgeId.index + 1].geometry.length
	end)
	return len
end

-- Metres along the path from (fromIndex, fromPos metres into that edge) to the start of edge toIndex.
local function distAlong(mp, fromIndex, fromPos, toIndex)
	local d = -fromPos
	if toIndex >= fromIndex then
		for i = fromIndex, toIndex - 1 do d = d + edgeLength(pathEdge(mp, i)) end
	else
		for i = toIndex, fromIndex - 1 do d = d - edgeLength(pathEdge(mp, i)) end
	end
	return d
end

-- What the reservation [.., index) ends at: the end of the path, or the signal facing the train on edge index.
local function endText(mp, n, index)
	if index >= n then return "path end" end
	local text = "edge " .. index .. " no signal"
	pcall(function()
		local id, dir = pathEdge(mp, index)
		local sid = api.engine.system.signalSystem.getSignal(id, dir)
		if sid and sid.entity >= 0 then
			text = "signal " .. sid.entity
			local list = api.engine.getComponent(sid.entity, api.type.ComponentType.SIGNAL_LIST)
			local s = list and list.signals[sid.index + 1]
			if s then text = text .. " st=" .. tostring(s.state) end
		end
	end)
	return text
end

local function pathKey(mp, n)
	if n == 0 then return "0" end
	local a, b = pathEdge(mp, 0), pathEdge(mp, n - 1)
	return string.format("%d:%d:%d:%d:%d", n, a.entity, a.index, b.entity, b.index)
end

local function check(trains, train, now)
	local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
	if not mp then return end
	local n = #mp.path.edges
	local cur = {
		path = pathKey(mp, n),
		to = mp.reservedTo,
		waiting = api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(train),
	}
	local key = tostring(train)
	local old = trains[key]
	trains[key] = cur
	if old and old.path == cur.path and old.to == cur.to and old.waiting == cur.waiting then return end

	local kind = not old and "first" or old.path ~= cur.path and "newpath" or old.to ~= cur.to and "extend" or "wait"
	local pp, dyn = mp.dyn.pathPos, mp.dyn
	local line = string.format(
		"t=%.1f train=%s %s n=%d res=[%d,%d) occ=%d..%d P=%d@%.1f v=%.2f a=%.2f b=%.2f wait=%s end=%s",
		now / 1000, key, kind, n, mp.reservedFrom, mp.reservedTo, mp.occupiedBackIndex, mp.occupiedFrontIndex,
		pp.edgeIndex, pp.pos, dyn.speed, dyn.accel, dyn.brakeDecel, tostring(cur.waiting), endText(mp, n, mp.reservedTo))
	if kind == "extend" and old.to < n then
		-- Where the train was relative to the old end (now passed by the reservation): from pathPos, and
		-- from the start of the front edge (the front is somewhere on that edge, frontLen long).
		local front = mp.occupiedFrontIndex
		line = line .. string.format(" | old end %d (%s): dP=%.1f dFrontEdge=%.1f frontLen=%.1f",
			old.to, endText(mp, n, old.to), distAlong(mp, pp.edgeIndex, pp.pos, old.to),
			distAlong(mp, front, 0, old.to), edgeLength(pathEdge(mp, front)))
	end
	log("%s", line)
end

-- GUI state: state is read-only here; guiState is per session (not saved).
local function guiUpdate(_userParams, _state, guiState)
	if not ENABLED then return end
	local gs = guiState:get() or {}
	local now = gameTime()
	if not now or now == gs.lastTime then return end -- paused
	gs.lastTime = now
	gs.trains = gs.trains or {}

	local ok, err = pcall(function()
		-- the trains (landVehicleMoveSystem.forEach also goes over road vehicles)
		local seen = {}
		for _, e in ipairs(api.engine.util.vehicle.getVehiclesByCarrier(api.type.enum.Carrier.RAIL)) do
			seen[tostring(e)] = true
			check(gs.trains, e, now)
		end
		for key in pairs(gs.trains) do
			if not seen[key] then gs.trains[key] = nil end
		end
	end)
	-- an error here would repeat every frame: log it once per session
	if not ok and not gs.errorLogged then
		log("error: %s", tostring(err))
		gs.errorLogged = true
	end
	guiState:set(gs)
end

function data()
	return { guiUpdate = guiUpdate }
end
