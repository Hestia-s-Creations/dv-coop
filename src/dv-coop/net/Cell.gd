extends Node

# Cell: which peers share a simulation, who is its authority, and origin adoption (M3). See docs/M3.md.
#
# Every machine builds the same proximity graph from beacons: two players in the rings are linked under
# RANGE_JOIN and stay linked until RANGE_LEAVE. The connected group that contains me is my cell, and its
# lowest peer id is the authority. The authority confirms the cell with c.state (reliable, on change and every
# STATE_EVERY s); members act only on that. A member joining shifts its whole world onto the authority's
# CurrentGame.globalOffset in one physics frame (same loop as the stock slipstream), suspends its spawner,
# emits cell_joined and answers c.join. RockSync listens to the signals and frees, snaps and promotes rocks.
#
# Signal order RockSync relies on:
#   handoff in a live cell:          authority_changed(new)  (isAuthority() already true when new == me)
#   authority vanishes, I'm alone:   authority_changed(me), then cell_left()
#   switching cells:                 cell_left(), then cell_joined(newAuth) in the same tick
#
# Dev: --coop-warp-to-peer=<s>  s seconds after the dive cutscene ends, jump 20,000 px from the lowest-id peer.

signal cell_joined(authority_id)
signal cell_left()
signal authority_changed(new_id)

const RANGE_JOIN = 40000.0
const RANGE_LEAVE = 45000.0
const VIEW_HZ = 10.0
const STATE_EVERY = 2.0
const HB_HZ = 5.0
const AUTH_SILENT = 0.9        # member: authority quiet this long -> treated as gone, next-lowest takes over
const ORPHAN_WAIT = 2.0        # member: authority out of my view and nobody claimed the cell -> leave
const BEACON_EXTRAP_MAX = 2.0
const SLIP_MARGIN = 150000.0   # authority slipstreams early once any member gets this close to the radius
const WARP_DISTANCE = 20000.0
const LOG_EVERY = 5.0

enum Role { SOLO, MEMBER, AUTHORITY }

var net = null   # CoopNet

var role = Role.SOLO
var auth = 0
var cid = ""
var off = Vector2(0, 0)        # the cell's globalOffset (authority's)
var originGen = -1
var cellMembers = []           # authority: my view of the cell; member: the authority's c.state list
var confirmed = {}             # authority: id -> true once its c.join arrived
var cellSeq = 0

var edges = {}                 # "a:b" (a < b) -> linked, for hysteresis
var lastComp = []
var lost = {}                  # id -> true: authority went silent; out of the graph until heard again
var heardAt = {}               # id -> s, last c.* packet from it
var orphanSince = -1.0

var viewAccum = 0.0
var stateAccum = 0.0
var hbAccum = 0.0
var logAccum = 0.0
var stateDirty = false
var pinned = false

var warpAfter = -1.0
var warpClock = 0.0
var warpDone = false

func _ready():
	name = "Cell"
	# Run after BulletTimer and the rest of the game so the time-scale pin has the last word each tick.
	process_priority = 1000
	net.on("c.state", self, "_onState")
	net.on("c.join", self, "_onJoin")
	net.on("c.leave", self, "_onLeave")
	net.on("c.hb", self, "_onHb")
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-warp-to-peer="):
			warpAfter = float(arg.substr(20))

# ---------------------------------------------------------------- interface (docs/M3.md)

func inCell() -> bool:
	return role != Role.SOLO

func isAuthority() -> bool:
	return role != Role.MEMBER

func authority() -> int:
	return auth if role != Role.SOLO else net.myId

func members() -> Array:
	match role:
		Role.AUTHORITY:
			var m = [net.myId]
			for id in confirmed:
				m.append(id)
			m.sort()
			return m
		Role.MEMBER:
			return cellMembers.duplicate()
	return [net.myId]

# Origin generation of the cell, +1 per slipstream on the authority; -1 when alone.
func gen() -> int:
	return originGen if role != Role.SOLO else -1

# ---------------------------------------------------------------- tick

func _now():
	return OS.get_ticks_msec() / 1000.0

func _log(s):
	Debug.l("COOP: CELL " + s)

func _field():
	var g = net._gameScene()
	if g != null:
		return g.get_node("AsteroidField")
	return null

func _ship():
	if net.dived and net.localShip != null and is_instance_valid(net.localShip):
		return net.localShip
	return null

func _physics_process(delta):
	if net.myId == 0 or not net.is_physics_processing():
		return
	var now = _now()

	if role == Role.MEMBER and not lost.has(auth) and now - heardAt.get(auth, now) > AUTH_SILENT:
		lost[auth] = true
		_log("authority %s silent %.1f s, treating as gone" % [auth, now - heardAt.get(auth, now)])
		viewAccum = 1.0

	viewAccum += delta
	if viewAccum >= 1.0 / VIEW_HZ:
		viewAccum = 0.0
		lastComp = _view()
		_decide(lastComp, now)

	match role:
		Role.AUTHORITY:
			_authorityTick(delta)
		Role.MEMBER:
			if CurrentGame.globalOffset != off:
				_log("member origin drifted to %s (own slipstream?), re-adopting %s" % [CurrentGame.globalOffset, off])
				_adopt(off)

	_warpTick(delta)
	_timeTick()

	logAccum += delta
	if logAccum >= LOG_EVERY and net.peers.size() > 0:
		logAccum = 0.0
		var ship = _ship()
		var where = CurrentGame.globalCoords(ship.global_position) if ship != null else null
		_log("status role=%s auth=%s cid=%s gen=%d members=%s view=%s off=%s ship=%s ts=%.2f" % [Role.keys()[role], authority(), cid, gen(), members(), lastComp, CurrentGame.globalOffset, where, Engine.time_scale])

# ---------------------------------------------------------------- membership

# Global position of a player for cell purposes, or null if it isn't in the rings / is stale / lost.
func _peerPos(id, now):
	if lost.has(id):
		return null
	var pr = net.peers[id]
	var b = pr.beacon
	if b == null or now - pr.beaconAt > net.BEACON_TIMEOUT or b.get("zone") != "rings" or not b.has("p"):
		return null
	var pp = net._puppetOf(id)
	if pp != null:
		return CurrentGame.globalCoords(pp.global_position)
	return b.p + b.get("v", Vector2(0, 0)) * min(now - pr.beaconAt, BEACON_EXTRAP_MAX)

# My connected group, sorted by id (lowest = authority). [myId] when I'm not in the rings.
func _view() -> Array:
	var ship = _ship()
	if ship == null:
		edges = {}
		return [net.myId]
	var now = _now()
	var pos = {net.myId: CurrentGame.globalCoords(ship.global_position)}
	for id in net.peers:
		var p = _peerPos(id, now)
		if p != null:
			pos[id] = p
	var ids = pos.keys()
	ids.sort()
	var newEdges = {}
	var adj = {}
	for id in ids:
		adj[id] = []
	for i in range(ids.size()):
		for j in range(i + 1, ids.size()):
			var a = ids[i]
			var b = ids[j]
			var key = "%s:%s" % [a, b]
			var linked = pos[a].distance_to(pos[b]) < (RANGE_LEAVE if edges.get(key, false) else RANGE_JOIN)
			newEdges[key] = linked
			if linked:
				adj[a].append(b)
				adj[b].append(a)
	edges = newEdges
	var comp = [net.myId]
	var i = 0
	while i < comp.size():
		for n in adj[comp[i]]:
			if not comp.has(n):
				comp.append(n)
		i += 1
	comp.sort()
	return comp

func _decide(comp, now):
	if comp.size() < 2:
		orphanSince = -1.0
		if role == Role.MEMBER and lost.has(auth):
			_promote(comp)
		if role != Role.SOLO:
			_leave("alone in view")
		return

	if comp[0] == net.myId:
		match role:
			Role.SOLO:
				_becomeAuthority(comp)
			Role.MEMBER:
				if lost.has(auth) or not comp.has(auth):
					_promote(comp)
				else:
					_leave("authority %s no longer lowest" % auth)
					_becomeAuthority(comp)
			Role.AUTHORITY:
				if comp != cellMembers:
					_log("view %s -> %s" % [cellMembers, comp])
					cellMembers = comp
					for id in confirmed.keys():
						if not comp.has(id):
							confirmed.erase(id)
							_log("member %s dropped" % id)
					stateDirty = true
		return

	# someone lower is in my group: wait for its c.state (handled in _onState)
	match role:
		Role.AUTHORITY:
			_leave("lower id %s in view" % comp[0])
		Role.MEMBER:
			if comp.has(auth):
				orphanSince = -1.0
			elif orphanSince < 0:
				orphanSince = now
			elif now - orphanSince > ORPHAN_WAIT:
				_leave("authority %s out of view, nobody took over" % auth)

func _becomeAuthority(comp):
	role = Role.AUTHORITY
	auth = net.myId
	cellSeq += 1
	cid = "%s:%d" % [net.myId, cellSeq]
	off = CurrentGame.globalOffset
	originGen = 0
	cellMembers = comp
	confirmed = {}
	_setSpawner(true)
	_log("FORMED cell %s as authority, view=%s off=%s" % [cid, comp, off])
	emit_signal("cell_joined", net.myId)
	_sendState()

# Member -> authority of the same cell (the old authority left). Origin and cid carry over.
func _promote(comp):
	var old = auth
	role = Role.AUTHORITY
	auth = net.myId
	off = CurrentGame.globalOffset
	cellMembers = comp
	confirmed = {}
	_setSpawner(true)
	_log("PROMOTED to authority of %s (was %s), view=%s gen=%d" % [cid, old, comp, originGen])
	emit_signal("authority_changed", net.myId)
	if comp.size() > 1:
		_sendState()

func _leave(why):
	if role == Role.SOLO:
		return
	if role == Role.MEMBER:
		if not lost.has(auth) and net.peers.has(auth):
			net.send(auth, {"t": "c.leave", "cid": cid, "gen": originGen}, true)
	else:
		# tell my members they're out; anyone still in range of a lower id gets that one's c.state
		net.sendTo(cellMembers, {"t": "c.state", "cid": cid, "auth": net.myId, "members": [net.myId], "off": off, "gen": originGen}, true)
	_log("LEFT cell %s as %s (%s)" % [cid, Role.keys()[role], why])
	role = Role.SOLO
	auth = net.myId
	cid = ""
	originGen = -1
	cellMembers = []
	confirmed = {}
	orphanSince = -1.0
	_setSpawner(true)
	emit_signal("cell_left")

func _join(from, msg):
	role = Role.MEMBER
	auth = from
	cid = msg.cid
	cellMembers = msg.members
	originGen = msg.gen
	orphanSince = -1.0
	_adopt(msg.off)
	_setSpawner(false)
	_log("JOINED cell %s, authority %s, members=%s gen=%d" % [cid, auth, cellMembers, originGen])
	emit_signal("cell_joined", auth)
	net.send(auth, {"t": "c.join", "cid": cid, "gen": originGen}, true)

func _setSpawner(on):
	var f = _field()
	if f != null and f.spawnThings != on:
		f.spawnThings = on
		_log("spawner %s" % ("resumed" if on else "suspended"))

# ---------------------------------------------------------------- authority

func _authorityTick(delta):
	if CurrentGame.globalOffset != off:
		_log("origin moved %s -> %s, gen %d -> %d" % [off, CurrentGame.globalOffset, originGen, originGen + 1])
		off = CurrentGame.globalOffset
		originGen += 1
		stateDirty = true

	stateAccum += delta
	if stateDirty or stateAccum >= STATE_EVERY:
		_sendState()

	hbAccum += delta
	if hbAccum >= 1.0 / HB_HZ:
		hbAccum = 0.0
		net.sendTo(cellMembers, {"t": "c.hb", "cid": cid, "gen": originGen}, false)

	# Members may sit up to RANGE_LEAVE from me; slipstream before any of them reaches its own radius,
	# because a member's stock slipstream would move its origin away from the cell's.
	var f = _field()
	if f != null:
		var now = _now()
		for id in cellMembers:
			if id == net.myId or not net.peers.has(id):
				continue
			var p = _peerPos(id, now)
			if p != null and CurrentGame.localCoords(p).length() > f.slipstreamRadius - SLIP_MARGIN:
				_log("member %s near the slipstream radius, slipstreaming early" % id)
				Tool.deferCallWhenIdle(f, "slipstream", [], true)
				break

func _sendState():
	stateDirty = false
	stateAccum = 0.0
	net.sendTo(cellMembers, {"t": "c.state", "cid": cid, "auth": net.myId, "members": cellMembers, "off": off, "gen": originGen}, true)

func _onJoin(from, msg):
	_heard(from)
	if role != Role.AUTHORITY or msg.get("cid") != cid:
		_log("c.join from %s for %s ignored (role=%s cid=%s)" % [from, msg.get("cid"), Role.keys()[role], cid])
		return
	if not cellMembers.has(from):
		return
	if msg.get("gen") != originGen:
		_log("c.join from %s at gen %s, current %d: resending state" % [from, msg.get("gen"), originGen])
		_sendState()
		return
	if not confirmed.has(from):
		confirmed[from] = true
		_log("member %s confirmed, members=%s" % [from, members()])

func _onLeave(from, msg):
	_heard(from)
	if confirmed.has(from):
		confirmed.erase(from)
		_log("member %s left, members=%s" % [from, members()])

func _onHb(from, msg):
	_heard(from)

func _heard(from):
	heardAt[from] = _now()
	if lost.has(from):
		lost.erase(from)
		_log("%s heard again" % from)

# ---------------------------------------------------------------- member

func _onState(from, msg):
	_heard(from)
	var listed = msg.members
	if not listed.has(net.myId):
		if role == Role.MEMBER and from == auth:
			_leave("authority %s dropped me" % from)
		return
	# Same cell from another member: the authority handed off (its view lost the old one before mine did).
	var sameCell = role == Role.MEMBER and msg.cid == cid and cellMembers.has(from)
	if not sameCell and (lastComp.size() < 2 or lastComp[0] != from):
		# not the lowest id in my own view (yet); it resends every 2 s
		return

	if sameCell:
		cellMembers = listed
		if from != auth:
			var old = auth
			auth = from
			_log("authority %s -> %s in cell %s" % [old, from, cid])
			if msg.off != off or msg.gen != originGen:
				originGen = msg.gen
				_adopt(msg.off)
			emit_signal("authority_changed", from)
			net.send(auth, {"t": "c.join", "cid": cid, "gen": originGen}, true)
		elif msg.off != off or msg.gen != originGen:
			_log("origin gen %d -> %d" % [originGen, msg.gen])
			originGen = msg.gen
			_adopt(msg.off)
			net.send(auth, {"t": "c.join", "cid": cid, "gen": originGen}, true)
		return

	if role != Role.SOLO:
		_leave("joining %s's cell %s" % [from, msg.cid])
	_join(from, msg)

# Move my world onto another globalOffset without moving anything in global terms: the stock slipstream
# loop (RigidBody2D children of the field, debris layers) with an arbitrary shift, in this physics frame.
func _adopt(newOff):
	off = newOff
	var cur = CurrentGame.globalOffset
	if cur == newOff:
		return
	var shift = cur - newOff
	var ship = _ship()
	var before = CurrentGame.globalCoords(ship.global_position) if ship != null else null
	var f = _field()
	var moved = 0
	if f != null:
		for c in Tool.multiClaimWhatYouCanAndReturnIt(f.get_children()):
			if c is RigidBody2D:
				c.position += shift
				c.reset_physics_interpolation()
				moved += 1
		for d in f.debrises:
			d.slipstream(shift)
		Tool.multiReleaseGlobal()
	CurrentGame.setGlobalOffset(newOff)
	var after = CurrentGame.globalCoords(ship.global_position) if ship != null else null
	var jump = after.distance_to(before) if ship != null else 0.0
	_log("ADOPT origin %s -> %s (shift %s, %d bodies), ship global %s -> %s (jump %.1f px)" % [cur, newOff, shift, moved, before, after, jump])

# ---------------------------------------------------------------- time scale

func _timeTick():
	if role != Role.SOLO:
		CurrentGame.targetTimeScale = 1.0
		Engine.time_scale = 1.0
		if not pinned:
			pinned = true
			_log("time scale pinned to 1.0")
	elif pinned:
		pinned = false
		_log("time scale released")

# ---------------------------------------------------------------- dev warp

func _warpTick(delta):
	if warpAfter < 0 or warpDone:
		return
	var ship = _ship()
	if ship == null or ship.cutscene:
		warpClock = 0.0
		return
	warpClock += delta
	if warpClock < warpAfter:
		return
	var now = _now()
	var ids = net.peers.keys()
	ids.sort()
	for id in ids:
		var p = _peerPos(id, now)
		if p == null:
			continue
		warpDone = true
		var me = CurrentGame.globalCoords(ship.global_position)
		var dir = (me - p).normalized() if me != p else Vector2(0, 1)
		var target = p + dir * WARP_DISTANCE
		ship.teleportBy(CurrentGame.localCoords(target) - ship.global_position)
		ship.reset_physics_interpolation()
		ship.linear_velocity = net.peers[id].beacon.get("v", Vector2(0, 0))
		_log("WARP dev: %s -> %s, %.0f px from %s" % [me, target, WARP_DISTANCE, id])
		return
