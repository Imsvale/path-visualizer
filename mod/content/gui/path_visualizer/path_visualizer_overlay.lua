-- The trains' reserved paths as lines, with a bar across the track where each reservation ends.
--
-- From each train's MOVE_PATH (docs/MOVE_PATH.md): the reservation is path.edges
-- [reservedFrom, reservedTo), released behind the train edge by edge; drawn from the train's
-- front edge on. Line colour: whether the train is waiting for a free path (it failed to
-- extend its reservation). End bar: red or green for the signal facing the train at the
-- end, white for the end of the path. Selected trains (an open entity window) get wider
-- lines and, if switched on, a yellow bar where they would stop braking now.
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
local BAR = 2.5 -- half length of the bars across the track (metres)

local function v2(x, y) return api.type.Vec2f.new(x, y) end
local function v4(c) return api.type.Vec4f.new(c[1], c[2], c[3], c[4]) end

local COLOR_PATH = { 0.2, 0.85, 1.0, 0.75 }
local COLOR_WAITING = { 1.0, 0.6, 0.1, 0.75 }
local COLOR_RED = { 1.0, 0.15, 0.15, 1.0 }
local COLOR_GREEN = { 0.2, 1.0, 0.3, 1.0 }
local COLOR_PATH_END = { 1.0, 1.0, 1.0, 1.0 }
local COLOR_BRAKING = { 1.0, 0.9, 0.1, 1.0 }

local state = {
	-- settings, per session: the HUD button (path_visualizer_button.script.lua) and its popover
	on = true,
	braking = false,

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
	local selected = state.selected[train] == true
	return {
		ids = ids,
		prevId = from > 0 and mp.path.edges[from].edgeId or nil,
		nextId = nextId,
		endKind = endKind,
		selected = selected,
		waiting = api.engine.system.landVehicleMoveSystem.isTrainWaitingForFreePath(train),
		key = string.format("%s:%d:%d:%d:%d:%s", tostring(train), n, from, to, ids[1].entity, tostring(selected)),
	}
end

local function buildStatic()
	local trains, parts, entities = {}, {}, {}
	api.engine.system.landVehicleMoveSystem.forEach(function(train)
		entities[#entities + 1] = train
		local t = readTrain(train)
		if t then
			trains[#trains + 1] = t
			parts[#parts + 1] = t.key .. ":" .. tostring(t.waiting) .. ":" .. t.endKind
		end
	end)
	state.trains = entities
	local signature = table.concat(parts, "|")
	if signature == state.signature then return false end
	state.signature = signature

	local networks, lines = {}, {}
	for _, t in ipairs(trains) do
		local color = t.waiting and COLOR_WAITING or COLOR_PATH
		local width = t.selected and WIDTH_SELECTED or WIDTH
		if t.selected then color = { color[1], color[2], color[3], 1.0 } end
		local last
		for _, id in ipairs(t.ids) do
			if #lines >= MAX_EDGES then break end
			local g = geometryOf(networks, id)
			-- (a zero-length edge crashed the game drawing it, parallelism)
			if g and g.length >= 0.1 then
				lines[#lines + 1] = makeEdge(g, color, width)
			end
			last = g or last
		end
		if last and #lines < MAX_EDGES then
			local prev = #t.ids > 1 and geometryOf(networks, t.ids[#t.ids - 1]) or geometryOf(networks, t.prevId)
			local fw = forward(prev, last, geometryOf(networks, t.nextId))
			local endColor = t.endKind == "green" and COLOR_GREEN or t.endKind == "end" and COLOR_PATH_END or COLOR_RED
			addBar(lines, last, fw and 1 or 0, endColor, width * 1.5)
		end
	end
	state.static = lines
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

-- Where each selected train would stop if it started braking now: a bar v² / 2a ahead of
-- its front.
local function buildBraking()
	local lines = {}
	if not state.braking then return lines end
	for train in pairs(state.selected) do
		pcall(function()
			local d = vehicleData(train)
			if not d then
				logOnce("nodata" .. tostring(train), "no brake deceleration for train " .. tostring(train))
				return
			end
			local mp = api.engine.getComponent(train, api.type.ComponentType.MOVE_PATH)
			local n = #mp.path.edges
			local v = mp.dyn.speed
			local networks = {}
			local i, rem = mp.dyn.pathPos.edgeIndex, mp.dyn.pathPos.pos + d.front + v * v / (2 * d.brake)
			local g = geometryOf(networks, mp.path.edges[i + 1].edgeId)
			while g and rem > g.length and i < n - 1 do
				rem = rem - g.length
				i = i + 1
				g = geometryOf(networks, mp.path.edges[i + 1].edgeId)
			end
			if not g or g.length < 0.1 then return end
			local prev = i > 0 and geometryOf(networks, mp.path.edges[i].edgeId) or nil
			local next = i < n - 1 and geometryOf(networks, mp.path.edges[i + 2].edgeId) or nil
			local t = math.min(1, math.max(0, rem / g.length))
			if not forward(prev, g, next) then t = 1 - t end
			addBar(lines, g, t, COLOR_BRAKING, WIDTH_SELECTED * 1.5)
		end)
	end
	return lines
end

local function publish(braking)
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

-- Reads the trains once per game time step (time stands still while paused), and when the
-- selection changes.
function overlay.poll()
	if state.failed or not state.on then return end
	local ok, err = pcall(function()
		local selectionChanged = updateSelection()
		local now = gameTime()
		if now == state.time and not selectionChanged then return end
		state.time = now
		if selectionChanged then state.signature = nil end
		local staticChanged = buildStatic()
		local braking = buildBraking()
		if staticChanged or #braking > 0 or selectionChanged or state.hadBraking then
			publish(braking)
		end
		state.hadBraking = #braking > 0
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
