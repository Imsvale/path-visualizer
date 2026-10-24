-- The trains' reserved paths as lines, and a square where each reservation ends.
--
-- From each train's MOVE_PATH (docs/MOVE_PATH.md): the reservation is path.edges
-- [reservedFrom, reservedTo), released behind the train edge by edge; drawn from the train's
-- front edge on. Line colour: whether the train is waiting for a free path (it failed to
-- extend its reservation). End square: red or green for the signal facing the train at the
-- end, white for the end of the path.
--
-- A 3D overlay only renders inside the active action's ActionDescriptor (network-wireframe,
-- parallelism), so path_visualizer_replace.script.lua puts these lines into every
-- descriptor. subscribe() runs in the action's recipe: its onStep polls the trains (once per
-- game time step) and redraws the action when the lines changed.

local react = ug_require "::/gui/main/react.lua"
local builtin = ug_require "::/gui/main/builtin.lua"

local overlay = {}

local MAX_EDGES = 4000
local WIDTH = 0.6
local MARKER = 1.5 -- half size of the end square (metres)

local function v2(x, y) return api.type.Vec2f.new(x, y) end
local function v4(c) return api.type.Vec4f.new(c[1], c[2], c[3], c[4]) end

local COLOR_PATH = { 0.2, 0.85, 1.0, 0.9 }
local COLOR_WAITING = { 1.0, 0.6, 0.1, 0.9 }
local COLOR_RED = { 1.0, 0.15, 0.15, 1.0 }
local COLOR_GREEN = { 0.2, 1.0, 0.3, 1.0 }
local COLOR_PATH_END = { 1.0, 1.0, 1.0, 1.0 }

local state = {
	on = true, -- the HUD button (path_visualizer_button.script.lua); per session
	version = 0,
	lines = nil,
	signature = nil,
	time = nil,
	failed = false,
}

local function log(msg)
	print("[pathvis] " .. msg)
end

local function gameTime()
	return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME).gameTime
end

local function makeEdge(geometry, color)
	local e = builtin.type.EdgeRenderable.Edge.new(geometry)
	e.colors = { v4(color) }
	e.width = WIDTH
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

local function addSquare(lines, p, color)
	local h = MARKER
	local corners = { { -h, -h }, { h, -h }, { h, h }, { -h, h } }
	for i = 1, 4 do
		local a, b = corners[i], corners[i % 4 + 1]
		lines[#lines + 1] = makeEdge(straightGeometry(p.x + a[1], p.y + a[2], p.x + b[1], p.y + b[2], p.z), color)
	end
end

local function dist2(p, q)
	return (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2
end

-- The end of geometry g in the direction of travel: the end shared with the next edge, or,
-- at the end of the path, the end away from the previous one. (Which way EdgeIdDir.dir
-- runs along the geometry isn't known yet.)
local function travelEnd(prev, g, next)
	local calc = api.engine.util.transport.calcPosition
	local a, b = calc(g, 0), calc(g, 1)
	local function near(p, other)
		return math.min(dist2(p, calc(other, 0)), dist2(p, calc(other, 1)))
	end
	if next then
		return near(a, next) < near(b, next) and a or b
	elseif prev then
		return near(a, prev) < near(b, prev) and b or a
	end
	return b
end

-- One train's reservation ahead of it, or nil: its edge ids and what ends it.
local function readTrain(train)
	local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
	if not mp or not mp.reservedTo then return nil end
	local n = #mp.path.edges
	local from = math.max(mp.occupiedFrontIndex, mp.reservedFrom, 0)
	local to = math.min(mp.reservedTo, n)
	if to <= from then return nil end
	local ids = {}
	for i = from, to - 1 do
		ids[#ids + 1] = mp.path.edges[i + 1].edgeId
	end
	-- the edge after the end, to find where the end is; and its signal facing the train
	local nextId, endKind = nil, "end"
	if to < n then
		local e = mp.path.edges[to + 1]
		nextId = e.edgeId
		endKind = "none"
		local sid = api.engine.system.signalSystem.getSignal(e.edgeId, e.dir)
		if sid and sid.entity >= 0 then
			local list = api.engine.getComponent(sid.entity, api.type.ComponentType.SIGNAL_LIST)
			local s = list and list.signals[sid.index + 1]
			endKind = s and s.state == 1 and "green" or "red"
		end
	end
	local prevId = from > 0 and mp.path.edges[from].edgeId or nil
	return {
		ids = ids,
		prevId = prevId,
		nextId = nextId,
		endKind = endKind,
		waiting = api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(train),
		key = string.format("%s:%d:%d:%d:%d", tostring(train), n, from, to, ids[1].entity),
	}
end

local function build()
	local trains, parts = {}, {}
	api.engine.system.landVehicleMoveSystem.forEach(function(train)
		local t = readTrain(train)
		if t then
			trains[#trains + 1] = t
			parts[#parts + 1] = t.key .. ":" .. tostring(t.waiting) .. ":" .. t.endKind
		end
	end)
	local signature = table.concat(parts, "|")
	if signature == state.signature then return end
	state.signature = signature

	local networks = {}
	local function geometry(id)
		if not id then return nil end
		local tn = networks[id.entity]
		if tn == nil then
			tn = api.engine.getComponent(id.entity, api.type.ComponentType.TRANSPORT_NETWORK) or false
			networks[id.entity] = tn
		end
		local lane = tn and tn.edges[id.index + 1]
		return lane and lane.geometry
	end

	local lines = {}
	for _, t in ipairs(trains) do
		local color = t.waiting and COLOR_WAITING or COLOR_PATH
		local last
		for _, id in ipairs(t.ids) do
			if #lines >= MAX_EDGES then break end
			local g = geometry(id)
			-- (a zero-length edge crashed the game drawing it, parallelism)
			if g and g.length >= 0.1 then
				lines[#lines + 1] = makeEdge(g, color)
			end
			last = g or last
		end
		if last and #lines < MAX_EDGES then
			local prev = #t.ids > 1 and geometry(t.ids[#t.ids - 1]) or geometry(t.prevId)
			local p = travelEnd(prev, last, geometry(t.nextId))
			local endColor = t.endKind == "green" and COLOR_GREEN or t.endKind == "end" and COLOR_PATH_END or COLOR_RED
			addSquare(lines, p, endColor)
		end
	end
	state.lines = #lines > 0 and lines or nil
	state.version = state.version + 1
end

function overlay.isOn()
	return state.on
end

function overlay.setOn(on)
	state.on = on and true or false
	state.lines, state.signature, state.time = nil, nil, nil
	state.version = state.version + 1
	-- read at once, also while paused
	overlay.poll()
end

-- Reads the trains once per game time step (time stands still while paused).
function overlay.poll()
	if state.failed or not state.on then return end
	local ok, err = pcall(function()
		local now = gameTime()
		if now == state.time then return end
		state.time = now
		build()
	end)
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
