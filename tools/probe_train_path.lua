-- Probe a train's MOVE_PATH to learn what its index fields mean (reserved path, occupied edges, ...).
-- Read-only: doesn't change the save.
-- Paste into the in-game console (it has no dofile). Pasting defines these and runs pv() once:
--   pv()                   same train again (one block per call; call it repeatedly as the train moves)
--   pv(<entity id>)        switch train
--   pv(nil, true)          full edge list instead of the window around the index fields
--   pvSignal(<entity id>)  dump a SIGNAL_LIST entity (select a signal; the log prints "Selected entity <id>")
-- Without an id pv picks a train waiting for a free path, else the first train found.
-- Output goes to stdout.txt (see CLAUDE.md).

local function log(fmt, ...)
	local args = { ... }
	pcall(function() print("[pv] " .. string.format(fmt, (table.unpack or unpack)(args))) end)
end

-- pcall that logs the error instead of hiding it
local function try(what, fn)
	local ok, err = pcall(fn)
	if not ok then log("ERR %s: %s", what, tostring(err)) end
end

-- getComponent on an entity that doesn't exist crashed the game (a train id remembered from another save):
-- only use ids that exist and are trains.
local function isTrain(entity)
	local result = false
	pcall(function()
		if type(entity) ~= "number" or not api.engine.entityExists(entity) then return end
		api.engine.system.landVehicleMoveSystem.forEach(function(e)
			if e == entity then result = true end
		end)
	end)
	return result
end

local function pickTrain()
	local found, waiting
	pcall(function()
		api.engine.system.landVehicleMoveSystem.forEach(function(e)
			found = found or e
			if not waiting and api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(e) then
				waiting = e
			end
		end)
	end)
	return waiting or found
end

-- A path edge is an EdgeIdDir userdata; try the likely field names.
local function unpackPathEdge(e)
	local id, dir = e.edgeId, e.dir
	if id == nil then id, dir = e.first, e.second end
	if id == nil then id, dir = e[1], e[2] end
	return id, dir
end

local function signalStateText(entity, index)
	local text = ""
	try("SIGNAL_LIST " .. tostring(entity), function()
		local list = api.engine.getComponent(entity, api.type.ComponentType.SIGNAL_LIST)
		if not list then
			text = " (no SIGNAL_LIST)"
			return
		end
		-- index base unknown: guess 0-based (signals[index + 1])
		local s = list.signals[index + 1]
		if s then
			text = string.format(" t=%s st=%s stT=%s", tostring(s.type), tostring(s.state), tostring(s.stateTime))
		else
			text = string.format(" (signals has %d)", #list.signals)
		end
	end)
	return text
end

-- Signal on an edge in one direction, raw: getSignal's return as entity:index, plus state if it has an entity.
local function signalText(edgeId, reversed)
	local text = "?"
	try("getSignal", function()
		local sid = api.engine.system.signalSystem.getSignal(edgeId, reversed)
		if sid == nil then
			text = "nil"
			return
		end
		text = string.format("%s:%s", tostring(sid.entity), tostring(sid.index))
		if type(sid.entity) == "number" and sid.entity >= 0 then
			text = text .. signalStateText(sid.entity, sid.index)
		end
	end)
	return text
end

local function edgeLength(edgeId)
	local len
	pcall(function()
		local tn = api.engine.getComponent(edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK)
		len = tn.edges[edgeId.index + 1].geometry.length
	end)
	return len
end

local function pv(train, full)
	if train then
		if not isTrain(train) then
			log("%s is not a train", tostring(train))
			return
		end
	else
		local ok, last = pcall(function() return _G.pvTrain end)
		train = ok and isTrain(last) and last or pickTrain()
	end
	pcall(rawset, _G, "pvTrain", train)
	if not train then
		log("no train found")
		return
	end

	local time = "?"
	pcall(function()
		time = tostring(api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime)
	end)
	log("==== train %s  gameTime=%s", tostring(train), time)

	try("TRANSPORT_VEHICLE", function()
		local tv = api.engine.getComponent(train, api.type.ComponentType.TRANSPORT_VEHICLE)
		log("TV: state=%s line=%s stopIndex=%s", tostring(tv.state), tostring(tv.line), tostring(tv.stopIndex))
	end)

	try("landVehicleMoveSystem", function()
		local lvms = api.engine.system.landVehicleMoveSystem
		local blockedBy = {}
		for _, pair in ipairs(lvms.getBlockedTrains()) do
			if pair[1] == train then table.insert(blockedBy, "blocked by " .. tostring(pair[2])) end
			if pair[2] == train then table.insert(blockedBy, "blocking " .. tostring(pair[1])) end
		end
		log("waitingForFreePath=%s  %s", tostring(lvms.isTrainWaitingForFreePath(train)), table.concat(blockedBy, ", "))
	end)

	local mp
	pcall(function() mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH) end)
	if not mp then
		log("no MOVE_PATH")
		return
	end

	local n = 0
	pcall(function() n = #mp.path.edges end)
	local p = {}
	pcall(function()
		local pp = mp.dyn.pathPos
		p = { edgeIndex = pp.edgeIndex, pos = pp.pos, pos01 = pp.pos01 }
	end)

	try("path", function()
		log("path: #edges=%d endOffset=%s terminalDecisionOffset=%s earlyArrivalIndices=%s",
			n, tostring(mp.path.endOffset), tostring(mp.path.terminalDecisionOffset), tostring(mp.path.earlyArrivalIndices))
	end)
	try("pathPos", function()
		log("pathPos: edgeIndex=%s pos=%s pos01=%s   (dyn0.edgeIndex=%s)",
			tostring(p.edgeIndex), tostring(p.pos), tostring(p.pos01), tostring(mp.dyn0.pathPos.edgeIndex))
	end)
	try("indices", function()
		log("occupied: back=%s front=%s   reserved: from=%s to=%s   blocked=%s",
			tostring(mp.occupiedBackIndex), tostring(mp.occupiedFrontIndex),
			tostring(mp.reservedFrom), tostring(mp.reservedTo), tostring(mp.blocked))
	end)
	try("state", function()
		log("state=%s endParam=%s endPos=%s allowEarlyArrival=%s",
			tostring(mp.state), tostring(mp.endParam), tostring(mp.endPos), tostring(mp.allowEarlyArrival))
	end)
	try("dyn", function()
		local d = mp.dyn
		log("dyn: speed=%.2f accel=%s brakeDecel=%s timeStanding=%s timeUntilAccel=%s timeToIgnore=%s approachingStation=%s",
			d.speed, tostring(d.accel), tostring(d.brakeDecel), tostring(d.timeStanding),
			tostring(d.timeUntilAccel), tostring(d.timeToIgnore), tostring(d.approachingStation))
	end)

	-- Edge table. Path indices are taken as 0-based (as base game code treats edgeIndex).
	-- Window: around every index field unless full; dist = metres from the train's pathPos to the edge start.
	local marks = {
		{ "P", p.edgeIndex }, { "B", mp.occupiedBackIndex }, { "F", mp.occupiedFrontIndex },
		-- reserved is half-open [reservedFrom, reservedTo): R marks the last reserved edge
		{ "r", mp.reservedFrom }, { "R", mp.reservedTo and mp.reservedTo - 1 }, { "X", mp.blocked }, { "E", mp.path.endOffset },
	}
	local lo, hi = 0, n - 1
	if not full then
		lo, hi = math.huge, -math.huge
		for _, m in ipairs(marks) do
			local v = tonumber(m[2])
			if v and v >= -1 and v <= n then
				lo, hi = math.min(lo, v), math.max(hi, v)
			end
		end
		if lo == math.huge then lo, hi = 0, n - 1 end
		lo, hi = math.max(0, lo - 3), math.min(n - 1, hi + 3)
	end
	log("edges %d..%d  (P=pathPos B/F=occupied back/front r/R=first/last reserved X=blocked E=endOffset; signals as entity:index)", lo, hi)

	local dist = {}
	try("dist", function()
		local cur = tonumber(p.edgeIndex) or 0
		local acc = -(tonumber(p.pos) or 0)
		for i = cur, n - 1 do
			dist[i] = acc
			acc = acc + (edgeLength((unpackPathEdge(mp.path.edges[i + 1]))) or 0)
		end
	end)

	for i = lo, hi do
		try("edge row " .. i, function()
			local id, dir = unpackPathEdge(mp.path.edges[i + 1])
			local tags = ""
			for _, m in ipairs(marks) do
				if m[2] == i then tags = tags .. m[1] end
			end
			local len = edgeLength(id)
			log("%4d %-4s edge(%s:%s) dir=%-5s len=%7s dist=%8s  fwd:%s  rev:%s",
				i, tags, tostring(id.entity), tostring(id.index), tostring(dir),
				len and string.format("%.1f", len) or "?",
				dist[i] and string.format("%.1f", dist[i]) or "",
				signalText(id, false), signalText(id, true))
		end)
	end
end

local function pvSignal(entity)
	log("==== signal entity %s", tostring(entity))
	local exists = false
	pcall(function() exists = api.engine.entityExists(entity) end)
	if not exists then
		log("no such entity")
		return
	end
	local list
	try("SIGNAL_LIST", function() list = api.engine.getComponent(entity, api.type.ComponentType.SIGNAL_LIST) end)
	if not list then
		log("no SIGNAL_LIST")
		return
	end
	log("#signals=%d", #list.signals)
	for i = 1, #list.signals do
		try("signal " .. i, function()
			local s = list.signals[i]
			if i == 1 then log("Signal: %s", tostring(s)) end
			local edge, rev = "?", "?"
			pcall(function()
				local pr = s.edgePr
				local id = pr.first or pr[1] or pr.edgeId
				edge = string.format("%s:%s", tostring(id.entity), tostring(id.index))
				rev = tostring(pr.second or pr[2] or pr.dir)
			end)
			log("[%d] type=%s state=%s stateTime=%s edgePr=(%s, %s)",
				i, tostring(s.type), tostring(s.state), tostring(s.stateTime), edge, rev)
		end)
	end
end

pcall(rawset, _G, "pv", pv)
pcall(rawset, _G, "pvSignal", pvSignal)
pv()
