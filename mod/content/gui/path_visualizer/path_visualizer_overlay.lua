-- The trains' reservations as lines, with a bar across the track where each one ends.
--
-- Terms (as in the README): the leg is the train's way to its next stop; the game's path for
-- it is MOVE_PATH path.edges, which ends at the far end of the platform where the train
-- reverses there, and runs on past the stop to the next signal where its line continues
-- (docs/MOVE_PATH.md). The reservation is the part of that path the train has claimed,
-- path.edges [reservedFrom, reservedTo), released behind the train edge by edge; drawn from
-- the train's front edge on.
-- Line colour: whether the train is waiting for a free path (it tried to extend its
-- reservation and was refused). A bar marks where the reservation ends, coloured by the next
-- section beyond it (to the next signal facing the train): white if it's free, red if another
-- train holds an edge of it or a node inside it, grey where the reservation already reaches
-- the end of the leg's path (the next leg's path doesn't exist yet). Selected trains (an open entity window) get wider lines with a
-- white outline and, if switched on, bars where they would stop braking now (normally and in
-- an emergency stop).
--
-- A 3D overlay only renders inside the active action's ActionDescriptor (network-wireframe,
-- parallelism), so path_visualizer_replace.script.lua puts these lines into every
-- descriptor. subscribe() runs in the action's recipe: its onStep polls the trains (once per
-- game time step, or when the selection changes) and redraws the action when the lines
-- changed.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"

local overlay = {}

local MAX_EDGES = 4000
local WIDTH = 0.6
local WIDTH_SELECTED = 1.2
local BAR = 1.25 -- half length of the bars across the track (metres)
local BAR_WIDTH = 0.3

local function v2(x, y) return api.type.Vec2f.new(x, y) end
local function v4(c) return api.type.Vec4f.new(c[1], c[2], c[3], c[4]) end

local COLOR_PATH = { 0.2, 0.85, 1.0, 0.75 }
local COLOR_WAITING = { 1.0, 0.6, 0.1, 0.75 }
local COLOR_END_FREE = { 1.0, 1.0, 1.0, 1.0 }
local COLOR_END_TAKEN = { 1.0, 0.15, 0.15, 1.0 }
local COLOR_END_LEG = { 0.6, 0.6, 0.6, 1.0 }
local COLOR_BRAKING = { 1.0, 0.9, 0.1, 1.0 }
local COLOR_PATHPOS = { 1.0, 0.2, 1.0, 1.0 }
local COLOR_EMERGENCY = { 0.6, 0.45, 1.0, 1.0 }
local COLOR_OUTLINE = { 1.0, 1.0, 1.0, 0.9 }
local OUTLINE_WIDTH = 0.15

-- for the settings popover's colour swatches
overlay.colors = { braking = COLOR_BRAKING, emergency = COLOR_EMERGENCY }

-- A manual stop braked at three times the train's brake deceleration (docs/MOVE_PATH.md,
-- one observation; no setting for it found).
local EMERGENCY_FACTOR = 3

-- dev switches (scripts/path_visualizer_dev.lua): off in a release
local devOk, dev = pcall(ug_require, "imsvale_path_visualizer::/scripts/path_visualizer_dev.lua")
if not devOk or type(dev) ~= "table" then dev = {} end
local LOG_SELECTED = dev.logSelected == true -- selected trains' dynamics, a log line per step
local PATHPOS_MARKER = dev.pathPosMarker == true -- a bar at selected trains' pathPos
local TIMING = dev.timing == true -- the overlay's time per frame, logged every 10 s

local state = {
	-- settings, per session: the HUD button (path_visualizer_button.script.lua) and its popover
	on = true,
	braking = true,
	emergency = false,

	version = 0,
	lines = nil, -- what the EdgeRenderable gets: the static lines plus the braking bars
	static = {}, -- reservations, rebuilt when the signature changes
	signature = nil,
	time = nil,
	trains = {}, -- train entities seen in the last build
	selected = {}, -- train -> true
	selectionKey = "",
	vehicleData = {}, -- train -> { brake = deceleration, front = metres ahead of pathPos }
	failed = false,
	logged = {},
	sectionInfo = {}, -- dev log: train -> the next section's verdict
	timing = { polls = 0, builds = 0, total = 0, max = 0, since = nil }, -- dev timing log
}

local function log(msg)
	print("[pathvis] " .. msg)
end

local function logOnce(key, msg)
	if state.logged[key] then return end
	state.logged[key] = true
	log(msg)
end

local function gameTime()
	return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
end

local function makeEdge(geometry, color, width)
	local e = builtin.type.EdgeRenderable.Edge.new(geometry)
	e.colors = { v4(color) }
	e.width = width
	e.offsetZ = 1.0
	e.stepSize = 2
	return e
end

local function straightGeometry(x0, y0, x1, y1, z)
	local st = api.type.EdgeGeometry.Straight.new()
	st.pos = { v2(x0, y0), v2(x1, y1) }
	local g = api.type.EdgeGeometry.new()
	g.type = api.type.EdgeGeometry.Type.STRAIGHT
	g.straight = st
	g.height = v2(z, z)
	g.tangent = v2(0, 0)
	g.length = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
	g.width = 0
	return g
end

local calc = function(g, t) return api.engine.util.transport.calcPosition(g, t) end

local function dist2(p, q)
	return (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2
end

-- A bar across geometry g at parameter t, into lines.
local function addBar(lines, g, t, color, width)
	local p = calc(g, t)
	local a, b = calc(g, math.max(0, t - 0.01)), calc(g, math.min(1, t + 0.01))
	local dx, dy = b.x - a.x, b.y - a.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1e-6 then return end
	local nx, ny = -dy / len * BAR, dx / len * BAR
	lines[#lines + 1] = makeEdge(straightGeometry(p.x + nx, p.y + ny, p.x - nx, p.y - ny, p.z), color, width)
end

-- Thin lines along both sides of geometry g, `h` metres out (EdgeRenderable has no lateral
-- offset): g sampled about every 4 m, the samples shifted sideways, joined by straight edges.
local function addOutline(lines, g, h)
	local n = math.max(2, math.ceil(g.length / 4))
	local pts = {}
	for k = 0, n do pts[k] = calc(g, k / n) end
	for _, side in ipairs({ 1, -1 }) do
		local prev
		for k = 0, n do
			local a, b = pts[math.max(0, k - 1)], pts[math.min(n, k + 1)]
			local dx, dy = b.x - a.x, b.y - a.y
			local len = math.sqrt(dx * dx + dy * dy)
			if len > 1e-6 then
				local p = pts[k]
				local q = { x = p.x - dy / len * h * side, y = p.y + dx / len * h * side, z = p.z }
				if prev and (q.x - prev.x) ^ 2 + (q.y - prev.y) ^ 2 >= 0.01 then
					lines[#lines + 1] = makeEdge(straightGeometry(prev.x, prev.y, q.x, q.y, (prev.z + q.z) / 2), COLOR_OUTLINE, OUTLINE_WIDTH)
					prev = q
				elseif not prev then
					prev = q
				end
			end
		end
	end
end

-- Whether the train runs along geometry g from t = 0 to t = 1: its t = 1 end is the one
-- shared with the next edge, or, at the end of the path, the one away from the previous.
-- (Which way EdgeIdDir.dir runs along the geometry isn't known yet.)
local function forward(prev, g, next)
	local a, b = calc(g, 0), calc(g, 1)
	local function near(p, other)
		return math.min(dist2(p, calc(other, 0)), dist2(p, calc(other, 1)))
	end
	if next then
		return near(b, next) <= near(a, next)
	elseif prev then
		return near(a, prev) <= near(b, prev)
	end
	return true
end

-- Geometry of a path edge (EdgeId), with the TRANSPORT_NETWORK components cached in networks.
local function geometryOf(networks, id)
	if not id then return nil end
	local tn = networks[id.entity]
	if tn == nil then
		tn = api.engine.getComponent(id.entity, api.type.ComponentType.TRANSPORT_NETWORK) or false
		networks[id.entity] = tn
	end
	local lane = tn and tn.edges[id.index + 1]
	return lane and lane.geometry
end

local function isSelected(train)
	local visible = false
	pcall(function() visible = api.gui.byId.isVisible("temp.view.entity_" .. tostring(train)) end)
	return visible
end

local function edgeKey(id) return id.entity .. ":" .. id.index end
local function nodeKey(id) return id.entity .. ":" .. id.index end

-- The track edge behind an EdgeId (its conns are its two nodes), with the TRANSPORT_NETWORK
-- components cached in networks.
local function laneOf(networks, id)
	local tn = networks[id.entity]
	if tn == nil then
		tn = api.engine.getComponent(id.entity, api.type.ComponentType.TRANSPORT_NETWORK) or false
		networks[id.entity] = tn
	end
	return tn and tn.edges[id.index + 1]
end

-- The node keys of a track edge's two ends (Edge.conns), or none if they can't be read (so
-- that only the node check is lost, not the overlay).
local function nodesOf(networks, id)
	local keys = {}
	pcall(function()
		local lane = laneOf(networks, id)
		if not lane then return end
		for _, node in ipairs(lane.conns) do keys[#keys + 1] = nodeKey(node) end
	end)
	return keys
end

-- One train's reservation, or nil: the edges it holds, the ones ahead of its front (drawn),
-- and the next section beyond the reservation: from its end to the next signal facing the
-- train (the signal's edge is the first one past it) or the end of the leg's path.
local function readTrain(train)
	local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
	if not mp or not mp.reservedTo then return nil end
	local edges = mp.path.edges
	local n = #edges
	local to = math.min(mp.reservedTo, n)
	local from = math.max(mp.occupiedFrontIndex, mp.reservedFrom, 0)
	local held, ids = {}, {}
	for i = math.max(mp.reservedFrom, 0), to - 1 do
		held[#held + 1] = edges[i + 1].edgeId
		if i >= from then ids[#ids + 1] = edges[i + 1].edgeId end
	end
	local section = {}
	for i = to, n - 1 do
		local e = edges[i + 1]
		if i > to then
			local sid = api.engine.system.signalSystem.getSignal(e.edgeId, e.dir)
			if sid and sid.entity >= 0 then break end
		end
		section[#section + 1] = e.edgeId
	end
	local selected = state.selected[train] == true
	return {
		train = train,
		held = held,
		ids = ids,
		section = section,
		atLegEnd = to >= n,
		-- the edges either side, to find which end of the last edge the reservation ends at
		prevId = from > 0 and edges[from].edgeId or nil,
		nextId = to < n and edges[to + 1].edgeId or nil,
		selected = selected,
		waiting = api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(train),
		key = string.format("%s:%d:%d:%d:%d:%s", tostring(train), n, from, to,
			ids[1] and ids[1].entity or -1, tostring(selected)),
	}
end

-- Whether another train holds the section ahead of t: one of its edges, or a node inside it
-- (shared by two of its edges: a switch, or a crossing, where tracks meet without sharing an
-- edge). The section's two end nodes don't count: a train right behind it or just past it
-- touches them without being in the way.
local function sectionTaken(t, heldEdges, heldNodes, networks)
	local count = {}
	for _, id in ipairs(t.section) do
		local owner = heldEdges[edgeKey(id)]
		if owner and owner ~= t.train then return true end
		for _, k in ipairs(nodesOf(networks, id)) do
			count[k] = (count[k] or 0) + 1
		end
	end
	for k, c in pairs(count) do
		if c >= 2 then
			for owner in pairs(heldNodes[k] or {}) do
				if owner ~= t.train then return true end
			end
		end
	end
	return false
end

-- The trains. (landVehicleMoveSystem.forEach goes over every land vehicle, buses and trucks
-- too: in an organic save the overlay walked all their paths and lagged the game, 2026-10-24.)
local function railVehicles()
	local list = {}
	for _, e in ipairs(api.engine.util.vehicle.getVehiclesByCarrier(api.type.enum.Carrier.RAIL)) do
		list[#list + 1] = e
	end
	return list
end

-- dev timing: adds the time since `since` to phase `name`, returns now
local function phase(name, since)
	if not TIMING or not since then return nil end
	local c = clock()
	if c then state.timing[name] = (state.timing[name] or 0) + (c - since) * 1000 end
	return c
end

local function buildStatic()
	local t0 = TIMING and clock() or nil
	local trains, parts = {}, {}
	local entities = railVehicles()
	for _, train in ipairs(entities) do
		local t = readTrain(train)
		if t then trains[#trains + 1] = t end
	end
	state.trains = entities
	t0 = phase("read", t0)

	-- who holds which edge and node
	local networks, heldEdges, heldNodes = {}, {}, {}
	for _, t in ipairs(trains) do
		for _, id in ipairs(t.held) do
			heldEdges[edgeKey(id)] = t.train
			for _, k in ipairs(nodesOf(networks, id)) do
				heldNodes[k] = heldNodes[k] or {}
				heldNodes[k][t.train] = true
			end
		end
	end
	for _, t in ipairs(trains) do
		t.endKind = t.atLegEnd and "leg" or sectionTaken(t, heldEdges, heldNodes, networks) and "taken" or "free"
		parts[#parts + 1] = t.key .. ":" .. tostring(t.waiting) .. ":" .. t.endKind
		if LOG_SELECTED and t.selected then
			local nodes = t.section[1] and #nodesOf(networks, t.section[1]) or 0
			state.sectionInfo[t.train] = string.format("next section: %s, %d edges (nodes read per edge: %d)", t.endKind, #t.section, nodes)
		end
	end

	local signature = table.concat(parts, "|")
	t0 = phase("tables", t0)
	if signature == state.signature then return false end
	state.signature = signature

	local lines = {}
	for _, t in ipairs(trains) do
		local color = t.waiting and COLOR_WAITING or COLOR_PATH
		local width = t.selected and WIDTH_SELECTED or WIDTH
		local last
		for _, id in ipairs(t.ids) do
			if #lines >= MAX_EDGES then break end
			local g = geometryOf(networks, id)
			-- (a zero-length edge crashed the game drawing it, parallelism)
			if g and g.length >= 0.1 then
				lines[#lines + 1] = makeEdge(g, color, width)
				if t.selected then addOutline(lines, g, (width + OUTLINE_WIDTH) / 2) end
			end
			last = g or last
		end
		if last and #lines < MAX_EDGES then
			local prev = #t.ids > 1 and geometryOf(networks, t.ids[#t.ids - 1]) or geometryOf(networks, t.prevId)
			local fw = forward(prev, last, geometryOf(networks, t.nextId))
			local endColor = t.endKind == "leg" and COLOR_END_LEG or t.endKind == "taken" and COLOR_END_TAKEN or COLOR_END_FREE
			addBar(lines, last, fw and 1 or 0, endColor, BAR_WIDTH)
		end
	end
	state.static = lines
	phase("lines", t0)
	return true
end

-- Brake deceleration and the front's distance ahead of pathPos, per train, from
-- carriageListSystem.getVehicleData. Where the front is relative to pathPos isn't known yet:
-- taken from bounds.front if it reads as a number, else half the length. Logged once per train.
local function vehicleData(train)
	local d = state.vehicleData[train]
	if d ~= nil then return d or nil end
	d = false
	pcall(function()
		local data = api.engine.system.carriageListSystem.getVehicleData(train)
		local front, back
		pcall(function() front, back = data.bounds.front, data.bounds.back end)
		local brake, length = data.brakeDeceleration, data.length
		log(string.format("vehicle data train %s: brakeDeceleration=%s length=%s bounds.front=%s bounds.back=%s",
			tostring(train), tostring(brake), tostring(length), tostring(front), tostring(back)))
		if type(brake) == "number" and brake > 0 then
			d = { brake = brake, front = type(front) == "number" and front or (length or 0) / 2 }
		end
	end)
	state.vehicleData[train] = d
	return d or nil
end

-- The point `rem` metres along the path from the start of edge i (walking on into the
-- following edges, clamped to the path's end): its geometry and parameter t.
local function pathPoint(mp, networks, i, rem)
	local n = #mp.path.edges
	local g = geometryOf(networks, mp.path.edges[i + 1].edgeId)
	while g and rem > g.length and i < n - 1 do
		rem = rem - g.length
		i = i + 1
		g = geometryOf(networks, mp.path.edges[i + 1].edgeId)
	end
	if not g or g.length < 0.1 then return nil end
	local prev = i > 0 and geometryOf(networks, mp.path.edges[i].edgeId) or nil
	local next = i < n - 1 and geometryOf(networks, mp.path.edges[i + 2].edgeId) or nil
	local t = math.min(1, math.max(0, rem / g.length))
	if not forward(prev, g, next) then t = 1 - t end
	return g, t
end

-- Metres along the path from (i0, p0) to (i1, p1), positions as edge index and metres into it.
local function pathDistance(mp, networks, i0, p0, i1, p1)
	if i1 < i0 then return -pathDistance(mp, networks, i1, p1, i0, p0) end
	local d = p1 - p0
	for i = i0, i1 - 1 do
		local g = geometryOf(networks, mp.path.edges[i + 1].edgeId)
		d = d + (g and g.length or 0)
	end
	return d
end

-- For each selected train: a bar at its pathPos, and, if switched on, where it would stop
-- if it started braking now (v² / 2a ahead of its front), normally and in an emergency stop.
-- `fraction` (0..1) of the way from the previous step (dyn0) to the current one (dyn): the
-- game draws a train between the two (taken to be so: drawing at dyn, or pushing on past it,
-- put the bars ahead of the train), so the bars move with it.
local function buildBraking(fraction)
	local lines = {}
	for train in pairs(state.selected) do
		pcall(function()
			local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
			local networks = {}
			local pp, pp0 = mp.dyn.pathPos, mp.dyn0.pathPos
			local edge, pos = pp.edgeIndex, pp.pos
			local v = mp.dyn.speed
			if fraction < 1 and pp0.edgeIndex <= pp.edgeIndex then
				edge = pp0.edgeIndex
				pos = pp0.pos + fraction * pathDistance(mp, networks, pp0.edgeIndex, pp0.pos, pp.edgeIndex, pp.pos)
				v = mp.dyn0.speed + fraction * (mp.dyn.speed - mp.dyn0.speed)
			end
			local g, t
			if PATHPOS_MARKER then
				g, t = pathPoint(mp, networks, edge, pos)
				if g then addBar(lines, g, t, COLOR_PATHPOS, BAR_WIDTH) end
			end
			if not state.braking and not state.emergency then return end
			local d = vehicleData(train)
			if not d then
				logOnce("nodata" .. tostring(train), "no brake deceleration for train " .. tostring(train))
				return
			end
			-- while braking, the train's actual deceleration (logged 2.50..2.60 against a
			-- brakeDeceleration of 2.5: with the nominal value the point lands a little long)
			local brake = (mp.dyn.brakeDecel or 0) > 0 and mp.dyn.brakeDecel or d.brake
			if state.braking then
				g, t = pathPoint(mp, networks, edge, pos + d.front + v * v / (2 * brake))
				if g then addBar(lines, g, t, COLOR_BRAKING, BAR_WIDTH) end
			end
			if state.emergency then
				g, t = pathPoint(mp, networks, edge, pos + d.front + v * v / (2 * d.brake * EMERGENCY_FACTOR))
				if g then addBar(lines, g, t, COLOR_EMERGENCY, BAR_WIDTH) end
			end
		end)
	end
	return lines
end

local function publish(braking)
	if TIMING then state.timing.publishes = (state.timing.publishes or 0) + 1 end
	local lines = {}
	for _, e in ipairs(state.static) do lines[#lines + 1] = e end
	for _, e in ipairs(braking) do lines[#lines + 1] = e end
	state.lines = #lines > 0 and lines or nil
	state.version = state.version + 1
end

local function updateSelection()
	local selected, keys = {}, {}
	for _, train in ipairs(state.trains) do
		if isSelected(train) then
			selected[train] = true
			keys[#keys + 1] = tostring(train)
		end
	end
	local key = table.concat(keys, ",")
	local changed = key ~= state.selectionKey
	state.selected, state.selectionKey = selected, key
	return changed
end

function overlay.isOn()
	return state.on
end

function overlay.setOn(on)
	state.on = on and true or false
	state.lines, state.static, state.signature, state.time = nil, {}, nil, nil
	state.version = state.version + 1
	-- read at once, also while paused
	overlay.poll()
end

function overlay.isBraking()
	return state.braking
end

function overlay.setBraking(on)
	state.braking = on and true or false
	state.time = nil
	overlay.poll()
end

function overlay.isEmergency()
	return state.emergency
end

function overlay.setEmergency(on)
	state.emergency = on and true or false
	state.time = nil
	overlay.poll()
end

local function clock()
	local ok, c = pcall(os.clock)
	return ok and c or nil
end

-- How far into the current step we are (0..1), from the real clock and how fast game time
-- ran over the last step (game speed); 1 once a step's worth has passed (and while paused).
local function stepFraction()
	local c = clock()
	if not c or not state.stepClock or not state.gameRate or not state.stepLength or state.stepLength <= 0 then
		return 1
	end
	return math.min((c - state.stepClock) * state.gameRate / state.stepLength, 1)
end

local function noteStep(now)
	local c = clock()
	if c and state.time and state.stepClock and c > state.stepClock then
		state.stepLength = (now - state.time) / 1000
		state.gameRate = state.stepLength / (c - state.stepClock)
	end
	state.stepClock = c
end

-- Reads the trains once per game time step (time stands still while paused), and when the
-- selection changes. In between, only the selected trains' bars are moved on.
-- dev: the overlay's cost, logged every 10 s of real time
local function noteTiming(started, built)
	local c = clock()
	if not c or not started then return end
	local tm = state.timing
	local ms = (c - started) * 1000
	tm.polls = tm.polls + 1
	tm.builds = tm.builds + (built and 1 or 0)
	tm.total = tm.total + ms
	tm.max = math.max(tm.max, ms)
	tm.since = tm.since or c
	if c - tm.since >= 10 then
		local s = c - tm.since
		log(string.format("timing: %.1f polls/s, %.1f builds/s, %.1f publishes/s, %.2f ms per poll (max %.1f), %.1f ms/s in all"
			.. " (read %.1f, tables %.1f, lines %.1f ms/s); %d trains, %d lines",
			tm.polls / s, tm.builds / s, (tm.publishes or 0) / s, tm.total / tm.polls, tm.max, tm.total / s,
			(tm.read or 0) / s, (tm.tables or 0) / s, (tm.lines or 0) / s, #state.trains, state.lines and #state.lines or 0))
		state.timing = { polls = 0, builds = 0, total = 0, max = 0, since = c }
	end
end

function overlay.poll()
	if state.failed or not state.on then return end
	local started = TIMING and clock() or nil
	local built = false
	local ok, err = pcall(function()
		local selectionChanged = updateSelection()
		local now = gameTime()
		if now == state.time and not selectionChanged then
			if next(state.selected) ~= nil then publish(buildBraking(stepFraction())) end
			return
		end
		if now ~= state.time then
			noteStep(now)
			if LOG_SELECTED then
				for train in pairs(state.selected) do
					pcall(function()
						local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
						local dyn = mp.dyn
						log(string.format("sel t=%.1f train=%s n=%d P=%d@%.2f v=%.3f a=%.3f b=%.3f standing=%.1f untilAccel=%.2f state=%s | %s",
							now / 1000, tostring(train), #mp.path.edges, dyn.pathPos.edgeIndex, dyn.pathPos.pos, dyn.speed,
							dyn.accel, dyn.brakeDecel, dyn.timeStanding, dyn.timeUntilAccel, tostring(mp.state),
							state.sectionInfo[train] or "-"))
					end)
				end
			end
		end
		state.time = now
		if selectionChanged then state.signature = nil end
		built = true
		local staticChanged = buildStatic()
		local braking = buildBraking(0)
		if staticChanged or #braking > 0 or selectionChanged or state.hadBraking then
			publish(braking)
		end
		state.hadBraking = #braking > 0
	end)
	if TIMING then noteTiming(started, built) end
	if not ok then
		state.failed = true
		state.lines = nil
		state.version = state.version + 1
		log("overlay failed, off until the game restarts: " .. tostring(err))
	end
end

-- Called while an ActionDescriptor is built, in its action's recipe: polls the trains every
-- step and redraws the action when the lines changed. Hooks are called unconditionally so
-- the recipe's hook order stays stable.
function overlay.subscribe()
	local seen = react.useState(state.version)
	react.onStep(function()
		overlay.poll()
		if seen:old() ~= state.version then
			seen:set(state.version)
		end
	end)
end

-- The edges for an EdgeRenderable, or nil.
function overlay.lines()
	return state.lines
end

return overlay
