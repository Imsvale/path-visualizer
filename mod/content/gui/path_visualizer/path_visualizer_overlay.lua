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
-- the end of the leg's path (the next leg's path doesn't exist yet). Selected trains (an open
-- entity window) get wider lines with a white outline, a thin red line and bar along a taken
-- next section and, if switched on, bars where they would stop braking now (normally and in
-- an emergency stop).
--
-- A 3D overlay only renders inside the active action's ActionDescriptor (network-wireframe,
-- parallelism), so path_visualizer_replace.script.lua puts these lines into every
-- descriptor. subscribe() runs in the action's recipe: its onStep polls the trains (once per
-- game time step, or when the selection changes) and redraws the action when the lines
-- changed.
--
-- Nothing is worked out again that can't have changed (2026-10-24):
-- * the network (each track entity's edges: geometry, end nodes), signal lookups and line
--   pieces are cached until a build (onProposalApply);
-- * each train's path is read into plain numbers once per leg (entity, index, direction per
--   edge; lengths, directions along the geometry and signals filled in as needed);
-- * a reservation is a queue that changes at its ends: who holds which edge and node is
--   updated by the difference, and a train's line pieces only rebuilt when its own ends,
--   colour or selection changed;
-- * the selected trains' moving bars are only published when they've visibly moved.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"

local overlay = {}

local MAX_EDGES = 4000
local WIDTH = 0.6
local WIDTH_SELECTED = 1.2
local WIDTH_NEXT = 0.2 -- the next section, when it's taken
local OFFSET_Z_NEXT = 1.05
local BAR = 1.25 -- half length of the bars across the track (metres)
local BAR_NEXT = BAR * 2 / 3 -- the same, for the next section's bar
local BAR_WIDTH = 0.3
local BAR_MOVE = 0.3 -- metres a moving bar has to move before it's redrawn
local SELECTION_INTERVAL = 0.25 -- seconds between checks for open train windows

local function v2(x, y) return api.type.Vec2f.new(x, y) end
local function v4(c) return api.type.Vec4f.new(c[1], c[2], c[3], c[4]) end

local COLOR_PATH = { 0.2, 0.85, 1.0, 0.75 }
local COLOR_WAITING = { 1.0, 0.6, 0.1, 0.75 }
local COLOR_END_FREE = { 1.0, 1.0, 1.0, 1.0 }
local COLOR_END_TAKEN = { 1.0, 0.15, 0.15, 1.0 }
local COLOR_END_LEG = { 0.6, 0.6, 0.6, 1.0 }
local COLOR_NEXT = { 1.0, 0.15, 0.15, 0.75 }
local COLOR_BRAKING = { 1.0, 0.9, 0.1, 1.0 }
local COLOR_PATHPOS = { 1.0, 0.2, 1.0, 1.0 }
local COLOR_EMERGENCY = { 0.6, 0.45, 1.0, 1.0 }
local COLOR_OUTLINE = { 1.0, 1.0, 1.0, 0.9 }
local OUTLINE_WIDTH = 0.15

local END_COLORS = { leg = COLOR_END_LEG, taken = COLOR_END_TAKEN, free = COLOR_END_FREE }

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
local LOG_INFO = dev.logInfo == true -- one-off information lines (errors are always logged)

local state = {
	-- settings, per session: the HUD button (path_visualizer_button.script.lua) and its popover
	on = true,
	braking = true,
	emergency = false,

	version = 0,
	lines = nil, -- what the EdgeRenderable gets: the static lines plus the moving bars
	static = {}, -- every train's line pieces, joined when one of them changed
	bars = {}, -- the moving bars last published
	barsKey = nil, -- where they were, rounded to BAR_MOVE
	time = nil,
	trainList = {}, -- train entities seen in the last build
	tr = {}, -- train -> its state (see readTrain)
	heldEdges = {}, -- edge key -> the train holding it
	heldNodes = {}, -- node key -> { train -> how many of its held edges end there }
	selected = {}, -- train -> true
	selectionKey = "",
	selectionChecked = nil, -- clock() of the last check
	vehicleData = {}, -- train -> { brake = deceleration, front = metres ahead of pathPos }
	failed = false,
	logged = {},
	sectionInfo = {}, -- dev log: train -> the next section's verdict
	edgeCache = {}, -- track entity -> its edges (entityEdges)
	signalCache = {}, -- edge and direction -> whether a signal faces that way (hasSignal)
	lineCache = {}, -- edge and style -> its line piece(s)
	cacheSince = nil, -- clock() when the caches were last cleared
	cacheDirtyUntil = nil, -- clock() until which they're cleared on every build (after a build)
	timing = { polls = 0, builds = 0, total = 0, max = 0, since = nil }, -- dev timing log
}

local function log(msg)
	print("[pathvis] " .. msg)
end

local function clock()
	local ok, c = pcall(os.clock)
	return ok and c or nil
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

-- A bar across geometry g at parameter t.
local function makeBar(g, t, color, width, halfLength)
	halfLength = halfLength or BAR
	local p = calc(g, t)
	local a, b = calc(g, math.max(0, t - 0.01)), calc(g, math.min(1, t + 0.01))
	local dx, dy = b.x - a.x, b.y - a.y
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 1e-6 then return nil end
	local nx, ny = -dy / len * halfLength, dx / len * halfLength
	return makeEdge(straightGeometry(p.x + nx, p.y + ny, p.x - nx, p.y - ny, p.z), color, width)
end

-- Thin lines along both sides of geometry g, `h` metres out (EdgeRenderable has no lateral
-- offset): the samples shifted sideways, joined by straight edges. A straight edge needs
-- only its two ends; curves are sampled about every 8 m.
local function addOutline(lines, g, h)
	local n = g.type == api.type.EdgeGeometry.Type.STRAIGHT and 1 or math.max(2, math.ceil(g.length / 8))
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

local function edgeKey(id) return id.entity .. ":" .. id.index end
local function nodeKey(id) return id.entity .. ":" .. id.index end

-- Every edge of a track entity's TRANSPORT_NETWORK, read once and cached: { geometry, nodes =
-- the node keys of its two ends (Edge.conns) }, by edge index + 1; false if none. Reading
-- tn.edges per edge was most of the overlay's time (copying a station's whole edge list for
-- each of its edges, 2026-10-24). The network only changes with builds: overlay.poll clears
-- the cache after one (and every 5 minutes as a fallback).
local function entityEdges(entity)
	local cached = state.edgeCache[entity]
	if cached ~= nil then return cached end
	cached = false
	pcall(function()
		local tn = api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_NETWORK)
		if not tn then return end
		local list, edges = {}, tn.edges
		for i = 1, #edges do
			local lane = edges[i]
			local nodes = {}
			-- (if the nodes can't be read, only the node check is lost)
			pcall(function()
				for _, node in ipairs(lane.conns) do nodes[#nodes + 1] = nodeKey(node) end
			end)
			list[i] = { geometry = lane.geometry, nodes = nodes }
		end
		-- The geometries point into the component's data: keep the component and its edge list
		-- alive with them. Cached without them, a geometry outlived its component and
		-- calcPosition on it failed an engine assertion (edge_geometry_util.cpp, 2026-10-24).
		list.tn, list.edges = tn, edges
		cached = list
	end)
	state.edgeCache[entity] = cached
	return cached
end

local function edgeData(id)
	local list = id and entityEdges(id.entity)
	return list and list[id.index + 1]
end

local function geometryOf(id)
	local e = edgeData(id)
	return e and e.geometry
end

local function nodesOf(id)
	local e = edgeData(id)
	return e and e.nodes or {}
end

-- Whether a signal on the edge faces a train running along it in direction dir; cached like
-- the edges. id is a plain { entity, index }: a fresh EdgeId is made for the lookup.
local function hasSignal(id, dir)
	local key = edgeKey(id) .. (dir and "+" or "-")
	local cached = state.signalCache[key]
	if cached == nil then
		cached = false
		pcall(function()
			local eid = api.type.EdgeId.new()
			eid.entity, eid.index = id.entity, id.index
			local sid = api.engine.system.signalSystem.getSignal(eid, dir)
			cached = (sid and sid.entity >= 0) and true or false
		end)
		state.signalCache[key] = cached
	end
	return cached
end

---------------------------------------------------------------------------------------------
-- a train's path, read once per leg

-- The path as plain numbers (edge ids from the component may point into its data, like
-- geometries): ids[i] = { entity, index }, keys[i], dirs[i], for i = 1..n (path index + 1).
-- fw (direction along the geometry) and signal are filled in as needed.
local function readPath(edges, n, key)
	local p = { key = key, n = n, ids = {}, keys = {}, dirs = {}, fw = {}, signal = {} }
	for i = 1, n do
		local e = edges[i]
		local id = { entity = e.edgeId.entity, index = e.edgeId.index }
		p.ids[i], p.keys[i], p.dirs[i] = id, edgeKey(id), e.dir
	end
	return p
end

-- Whether the train runs along path edge i (1-based) from t = 0 to t = 1.
local function pathForward(p, i)
	local fw = p.fw[i]
	if fw == nil then
		local g = geometryOf(p.ids[i])
		fw = true
		if g then
			fw = forward(i > 1 and geometryOf(p.ids[i - 1]) or nil, g, i < p.n and geometryOf(p.ids[i + 1]) or nil)
		end
		p.fw[i] = fw
	end
	return fw
end

-- Whether a signal faces the train on path edge i (1-based).
local function pathSignal(p, i)
	local s = p.signal[i]
	if s == nil then
		s = hasSignal(p.ids[i], p.dirs[i])
		p.signal[i] = s
	end
	return s
end

-- The point `rem` metres along the path from the start of edge index i (0-based; walking on
-- into the following edges, clamped to the path's end): its geometry and parameter t.
local function pathPoint(p, i, rem)
	local g = geometryOf(p.ids[i + 1])
	while g and rem > g.length and i < p.n - 1 do
		rem = rem - g.length
		i = i + 1
		g = geometryOf(p.ids[i + 1])
	end
	if not g or g.length < 0.1 then return nil end
	local t = math.min(1, math.max(0, rem / g.length))
	if not pathForward(p, i + 1) then t = 1 - t end
	return g, t, i, rem
end

-- Metres along the path from (i0, p0) to (i1, p1), positions as edge index and metres into it.
local function pathDistance(p, i0, p0, i1, p1)
	if i1 < i0 then return -pathDistance(p, i1, p1, i0, p0) end
	local d = p1 - p0
	for i = i0, i1 - 1 do
		local g = geometryOf(p.ids[i + 1])
		d = d + (g and g.length or 0)
	end
	return d
end

---------------------------------------------------------------------------------------------
-- who holds what, updated by the difference

local function hold(train, p, i)
	local id = p.ids[i + 1]
	state.heldEdges[p.keys[i + 1]] = train
	for _, k in ipairs(nodesOf(id)) do
		local owners = state.heldNodes[k]
		if not owners then
			owners = {}
			state.heldNodes[k] = owners
		end
		owners[train] = (owners[train] or 0) + 1
	end
end

local function release(train, p, i)
	local key = p.keys[i + 1]
	if state.heldEdges[key] == train then state.heldEdges[key] = nil end
	for _, k in ipairs(nodesOf(p.ids[i + 1])) do
		local owners = state.heldNodes[k]
		if owners and owners[train] then
			owners[train] = owners[train] - 1
			if owners[train] <= 0 then owners[train] = nil end
			if next(owners) == nil then state.heldNodes[k] = nil end
		end
	end
end

-- From holding [a, b) of path pa to holding [c, d) of path pc: releases what's no longer held
-- and holds what's new. On the same path only the ends change: the rear released, the front
-- added.
local function updateHeld(train, pa, a, b, pc, c, d)
	if pa ~= pc then
		if pa then for i = a, b - 1 do release(train, pa, i) end end
		if pc then for i = c, d - 1 do hold(train, pc, i) end end
		return
	end
	for i = a, math.min(b, c) - 1 do release(train, pa, i) end
	for i = math.max(a, d), b - 1 do release(train, pa, i) end
	for i = c, math.min(d, a) - 1 do hold(train, pc, i) end
	for i = math.max(c, b), d - 1 do hold(train, pc, i) end
end

-- Whether another train holds the section ahead, path indices [s, e): one of its edges, or a
-- node inside it (shared by two of its edges: a switch, or a crossing, where tracks meet
-- without sharing an edge). The section's two end nodes don't count: a train right behind it
-- or just past it touches them without being in the way.
local function sectionTaken(train, p, s, e)
	local count = {}
	for i = s, e - 1 do
		local owner = state.heldEdges[p.keys[i + 1]]
		if owner and owner ~= train then return true end
		for _, k in ipairs(nodesOf(p.ids[i + 1])) do count[k] = (count[k] or 0) + 1 end
	end
	for k, c in pairs(count) do
		if c >= 2 then
			for owner in pairs(state.heldNodes[k] or {}) do
				if owner ~= train then return true end
			end
		end
	end
	return false
end

local function isSelected(train)
	local visible = false
	pcall(function() visible = api.gui.byId.isVisible("temp.view.entity_" .. tostring(train)) end)
	return visible
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

---------------------------------------------------------------------------------------------
-- per game step

-- Reads one train and brings its state up to date. Returns true if its line pieces changed.
-- Per train: path (readPath), held = [a, b) path indices held, front (first drawn index), to,
-- waiting, selected, endKind, nextEnd (end of the next section), pieces (its line pieces),
-- nextPieces (those drawn on top of every train's).
local function updateTrain(train)
	local st = state.tr[train]
	if not st then
		st = { a = 0, b = 0, pieces = {}, nextPieces = {} }
		state.tr[train] = st
	end
	local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
	if not mp or not mp.reservedTo then
		updateHeld(train, st.path, st.a, st.b, nil, 0, 0)
		local changed = #st.pieces > 0
		st.path, st.a, st.b, st.pieces, st.key = nil, 0, 0, {}, nil
		st.nextPieces = {}
		st.changed = false
		return changed
	end

	-- the path: read again only for a new leg (its edge list is read once a step to tell)
	local edges = mp.path.edges
	local n = #edges
	local key = n > 0 and string.format("%d:%d:%d:%d:%d", n, edges[1].edgeId.entity, edges[1].edgeId.index,
		edges[n].edgeId.entity, edges[n].edgeId.index) or "0"
	local p = st.path
	if not p or p.key ~= key then p = readPath(edges, n, key) end

	local a = math.max(mp.reservedFrom, 0)
	local b = math.min(mp.reservedTo, n)
	if b < a then b = a end
	updateHeld(train, st.path, st.a, st.b, p, a, b)
	st.path, st.a, st.b = p, a, b

	local front = math.max(mp.occupiedFrontIndex, a, 0)
	local waiting = api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(train)
	local selected = state.selected[train] == true
	local changed = st.key ~= key or st.front ~= front or st.to ~= b or st.waiting ~= waiting or st.selected ~= selected
	st.key, st.front, st.to, st.waiting, st.selected = key, front, b, waiting, selected
	st.changed = changed
	return changed
end

-- The next section's verdict for a train (after every train's holdings are up to date).
local function updateEnd(train)
	local st = state.tr[train]
	local p = st.path
	if not p then return false end
	local kind
	st.nextEnd = nil
	if st.to >= p.n then
		kind = "leg"
	else
		local e = st.to + 1
		while e < p.n and not pathSignal(p, e + 1) do e = e + 1 end
		st.nextEnd = e
		kind = sectionTaken(train, p, st.to, e) and "taken" or "free"
		if LOG_SELECTED and st.selected then
			state.sectionInfo[train] = string.format("next section: %s, %d edges (nodes per edge: %d)",
				kind, e - st.to, #nodesOf(p.ids[st.to + 1]))
		end
	end
	local changed = st.endKind ~= kind
	st.endKind = kind
	return changed
end

-- A train's line pieces, from line pieces cached per track edge (built once each).
local function buildPieces(train)
	local st = state.tr[train]
	local p = st.path
	local pieces = {}
	st.pieces = pieces
	st.nextPieces = {}
	if not p or st.to <= st.front then return end
	local cache = state.lineCache
	local color = st.waiting and COLOR_WAITING or COLOR_PATH
	local width = st.selected and WIDTH_SELECTED or WIDTH
	local style = (st.waiting and "w" or "p") .. (st.selected and "s" or "n")
	local last
	for i = st.front, st.to - 1 do
		local id, key = p.ids[i + 1], p.keys[i + 1]
		local g = geometryOf(id)
		-- (a zero-length edge crashed the game drawing it, parallelism)
		if g and g.length >= 0.1 then
			local line = cache[key .. style]
			if not line then
				line = makeEdge(g, color, width)
				cache[key .. style] = line
			end
			pieces[#pieces + 1] = line
			if st.selected then
				local outline = cache[key .. "outline"]
				if not outline then
					outline = {}
					addOutline(outline, g, (WIDTH_SELECTED + OUTLINE_WIDTH) / 2)
					cache[key .. "outline"] = outline
				end
				for _, e in ipairs(outline) do pieces[#pieces + 1] = e end
			end
			last = i
		end
	end
	if last then
		-- the end bar, at the end of the last edge in the direction of travel
		local fw = pathForward(p, last + 1)
		local key = p.keys[last + 1] .. "end" .. (fw and "1" or "0") .. st.endKind
		local bar = cache[key]
		if bar == nil then
			bar = makeBar(geometryOf(p.ids[last + 1]), fw and 1 or 0, END_COLORS[st.endKind], BAR_WIDTH) or false
			cache[key] = bar
		end
		if bar then pieces[#pieces + 1] = bar end
	end
	if st.selected and st.endKind == "taken" then
		local lastNext
		for i = st.to, st.nextEnd - 1 do
			local key = p.keys[i + 1] .. "next"
			local line = cache[key]
			if line == nil then
				local g = geometryOf(p.ids[i + 1])
				line = g and g.length >= 0.1 and makeEdge(g, COLOR_NEXT, WIDTH_NEXT) or false
				-- a little above the other lines, where a tool's EdgeRenderable tests depth
				if line then line.offsetZ = OFFSET_Z_NEXT end
				cache[key] = line
			end
			if line then
				st.nextPieces[#st.nextPieces + 1] = line
				lastNext = i
			end
		end
		if lastNext then
			-- its own bar, at its far end
			local fw = pathForward(p, lastNext + 1)
			local key = p.keys[lastNext + 1] .. "nextend" .. (fw and "1" or "0")
			local bar = cache[key]
			if bar == nil then
				bar = makeBar(geometryOf(p.ids[lastNext + 1]), fw and 1 or 0, COLOR_NEXT, WIDTH_NEXT, BAR_NEXT) or false
				if bar then bar.offsetZ = OFFSET_Z_NEXT end
				cache[key] = bar
			end
			if bar then st.nextPieces[#st.nextPieces + 1] = bar end
		end
	end
end

-- Brings every train up to date; returns true if the static lines changed.
local function buildStatic()
	local t0 = TIMING and clock() or nil
	local list = railVehicles()
	local seen, changed = {}, false
	for _, train in ipairs(list) do
		seen[train] = true
		if updateTrain(train) then changed = true end
	end
	-- trains gone (sold, or no longer listed)
	for train, st in pairs(state.tr) do
		if not seen[train] then
			updateHeld(train, st.path, st.a, st.b, nil, 0, 0)
			state.tr[train] = nil
			changed = true
		end
	end
	state.trainList = list
	t0 = phase("read", t0)

	local dirty = {}
	for _, train in ipairs(list) do
		local st = state.tr[train]
		if updateEnd(train) or st.changed then dirty[#dirty + 1] = train end
	end
	t0 = phase("tables", t0)
	if #dirty == 0 and not changed then return false end

	for _, train in ipairs(dirty) do buildPieces(train) end
	local lines = {}
	for _, train in ipairs(list) do
		local st = state.tr[train]
		for _, e in ipairs(st.pieces) do
			if #lines >= MAX_EDGES then break end
			lines[#lines + 1] = e
		end
	end
	-- after every train's lines, to draw on top of them
	for _, train in ipairs(list) do
		for _, e in ipairs(state.tr[train].nextPieces) do
			if #lines >= MAX_EDGES then break end
			lines[#lines + 1] = e
		end
	end
	state.static = lines
	phase("lines", t0)
	return true
end

-- Forgets every train's state (after the network caches were cleared: the line pieces and
-- node keys may be stale).
local function resetTrains()
	state.tr, state.heldEdges, state.heldNodes = {}, {}, {}
	state.static, state.barsKey = {}, nil
end

---------------------------------------------------------------------------------------------
-- the selected trains' moving bars, every frame

-- Brake deceleration and the front's distance ahead of pathPos, per train, from
-- carriageListSystem.getVehicleData (bounds.front, the nose measured from pathPos, the middle
-- of the train). Logged once per train.
local function vehicleData(train)
	local d = state.vehicleData[train]
	if d ~= nil then return d or nil end
	d = false
	pcall(function()
		local data = api.engine.system.carriageListSystem.getVehicleData(train)
		local front, back
		pcall(function() front, back = data.bounds.front, data.bounds.back end)
		local brake, length = data.brakeDeceleration, data.length
		if LOG_INFO then
			log(string.format("vehicle data train %s: brakeDeceleration=%s length=%s bounds.front=%s bounds.back=%s",
				tostring(train), tostring(brake), tostring(length), tostring(front), tostring(back)))
		end
		if type(brake) == "number" and brake > 0 then
			d = { brake = brake, front = type(front) == "number" and front or (length or 0) / 2 }
		end
	end)
	state.vehicleData[train] = d
	return d or nil
end

-- For each selected train: a bar at its pathPos (dev), and, if switched on, where it would
-- stop if it started braking now (v² / 2a ahead of its front), normally and in an emergency
-- stop. `fraction` (0..1) of the way from the previous step (dyn0) to the current one (dyn):
-- the game draws a train between the two (taken to be so: drawing at dyn, or pushing on past
-- it, put the bars ahead of the train), so the bars move with it. Returns the bars to draw,
-- or nil if none has moved by BAR_MOVE since the last ones published.
local function buildBars(fraction)
	local wanted = {}
	for train in pairs(state.selected) do
		pcall(function()
			local st = state.tr[train]
			local p = st and st.path
			if not p then return end
			local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
			local pp, pp0 = mp.dyn.pathPos, mp.dyn0.pathPos
			local edge, pos = pp.edgeIndex, pp.pos
			local v = mp.dyn.speed
			if fraction < 1 and pp0.edgeIndex <= pp.edgeIndex then
				edge = pp0.edgeIndex
				pos = pp0.pos + fraction * pathDistance(p, pp0.edgeIndex, pp0.pos, pp.edgeIndex, pp.pos)
				v = mp.dyn0.speed + fraction * (mp.dyn.speed - mp.dyn0.speed)
			end
			if PATHPOS_MARKER then wanted[#wanted + 1] = { p, edge, pos, COLOR_PATHPOS } end
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
				wanted[#wanted + 1] = { p, edge, pos + d.front + v * v / (2 * brake), COLOR_BRAKING }
			end
			if state.emergency then
				wanted[#wanted + 1] = { p, edge, pos + d.front + v * v / (2 * d.brake * EMERGENCY_FACTOR), COLOR_EMERGENCY }
			end
		end)
	end
	-- where they'd go: redrawn only if one moved visibly (a standing train: never)
	local points, keys = {}, {}
	for _, w in ipairs(wanted) do
		local g, t, i, rem = pathPoint(w[1], w[2], w[3])
		if g then
			points[#points + 1] = { g, t, w[4] }
			keys[#keys + 1] = i .. ":" .. math.floor(rem / BAR_MOVE)
		end
	end
	local key = table.concat(keys, "|")
	if key == state.barsKey then return nil end
	state.barsKey = key
	local bars = {}
	for _, pt in ipairs(points) do
		local bar = makeBar(pt[1], pt[2], pt[3], BAR_WIDTH)
		if bar then bars[#bars + 1] = bar end
	end
	return bars
end

local function publish()
	if TIMING then state.timing.publishes = (state.timing.publishes or 0) + 1 end
	local lines = {}
	for _, e in ipairs(state.static) do lines[#lines + 1] = e end
	for _, e in ipairs(state.bars) do lines[#lines + 1] = e end
	state.lines = #lines > 0 and lines or nil
	state.version = state.version + 1
end

-- Which trains have their window open: checked every SELECTION_INTERVAL (an isVisible call
-- per train). Returns true if that changed.
local function updateSelection()
	local c = clock()
	if c and state.selectionChecked and c - state.selectionChecked < SELECTION_INTERVAL then return false end
	state.selectionChecked = c
	local selected, keys = {}, {}
	for _, train in ipairs(state.trainList) do
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
	resetTrains()
	state.lines, state.bars, state.time = nil, {}, nil
	state.version = state.version + 1
	-- read at once, also while paused
	overlay.poll()
end

function overlay.isBraking()
	return state.braking
end

function overlay.setBraking(on)
	state.braking = on and true or false
	state.time, state.barsKey = nil, nil
	overlay.poll()
end

function overlay.isEmergency()
	return state.emergency
end

function overlay.setEmergency(on)
	state.emergency = on and true or false
	state.time, state.barsKey = nil, nil
	overlay.poll()
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
			(tm.read or 0) / s, (tm.tables or 0) / s, (tm.lines or 0) / s, #state.trainList, state.lines and #state.lines or 0))
		state.timing = { polls = 0, builds = 0, total = 0, max = 0, since = c }
	end
end

-- Reads the trains once per game time step (time stands still while paused), and when the
-- selection changes. In between, only the selected trains' bars are moved on.
function overlay.poll()
	if state.failed or not state.on then return end
	local started = TIMING and clock() or nil
	local built = false
	local ok, err = pcall(function()
		local selectionChanged = updateSelection()
		local now = gameTime()
		if now == state.time and not selectionChanged then
			if next(state.selected) ~= nil then
				local bars = buildBars(stepFraction())
				if bars then
					state.bars = bars
					publish()
				end
			end
			return
		end
		if now ~= state.time then
			noteStep(now)
			if LOG_SELECTED then
				for train in pairs(state.selected) do
					pcall(function()
						local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
						local dyn = mp.dyn
						local st = state.tr[train]
						log(string.format("sel t=%.1f train=%s n=%d P=%d@%.2f v=%.3f a=%.3f b=%.3f standing=%.1f untilAccel=%.2f state=%s | %s",
							now / 1000, tostring(train), st and st.path and st.path.n or -1, dyn.pathPos.edgeIndex, dyn.pathPos.pos, dyn.speed,
							dyn.accel, dyn.brakeDecel, dyn.timeStanding, dyn.timeUntilAccel, tostring(mp.state),
							state.sectionInfo[train] or "-"))
					end)
				end
			end
		end
		state.time = now
		-- the network caches: cleared after a build (onProposalApply, see subscribe; for 2 s, in
		-- case the engine applies it a little later), and every 5 minutes for builds made by
		-- script, which may not fire the event (e.g. Parallelism's extra tracks)
		local c = clock()
		if c and (not state.cacheSince or c - state.cacheSince > 300 or (state.cacheDirtyUntil and c < state.cacheDirtyUntil)) then
			state.edgeCache, state.signalCache, state.lineCache, state.cacheSince = {}, {}, {}, c
			resetTrains()
		end
		built = true
		local staticChanged = buildStatic()
		-- the bars: nil if unchanged; none once no train is selected
		local bars
		if next(state.selected) ~= nil then
			bars = buildBars(0)
		elseif #state.bars > 0 then
			bars, state.barsKey = {}, nil
		end
		if bars then state.bars = bars end
		if staticChanged or bars or selectionChanged then publish() end
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
	-- a build was applied (fired by the engine: track, signals, bulldozer, construction tools)
	react.onEvent("onProposalApply", function()
		local c = clock()
		if c then state.cacheDirtyUntil = c + 2 end
	end)
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
