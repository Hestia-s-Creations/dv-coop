extends Node

# Cell: which peers share a simulation, who is its authority, and origin adoption (M3). See docs/M3.md.
#
# Every machine builds the same proximity graph from beacons: two players in the rings are linked under
# RANGE_JOIN and stay linked until RANGE_LEAVE. The connected group that contains me is my cell. Its authority
# is the incumbent: every authority advertises its cell to everyone (c.ad: member count, formation time), and
# in a group the cell with the most members wins, then the oldest, then the lowest id. A player joining an
# existing cell never takes authority; two solo players meeting pick the lowest id. A losing authority
# resigns (c.leave with "to") and its members switch on the winner's c.state. When the authority leaves for
# good, the lowest id of the rest promotes. The authority confirms the cell with c.state (reliable, on change
# and every STATE_EVERY s); members act only on that. A member joining shifts its whole world onto the authority's
# CurrentGame.globalOffset in one physics frame (same loop as the stock slipstream), suspends its spawner,
# emits cell_joined and answers c.join. RockSync listens to the signals and frees, snaps and promotes rocks.
#
# Signal order RockSync relies on:
#   handoff in a live cell:          authority_changed(new)  (isAuthority() already true when new == me)
#   authority vanishes, I'm alone:   authority_changed(me), then cell_left()
#   switching cells:                 cell_left(), then cell_joined(newAuth) in the same tick
#
# Dev: --coop-warp-to-peer=<s>[,<px>]  s seconds after the dive cutscene ends, jump to <px> (default 20,000) beside a
#      cell authority (else the lowest-id peer), off to the side of its course, matching its velocity.
#      --coop-dev-slipstream=<s> as authority with confirmed members, force the stock slipstream every s seconds.

signal cell_joined(authority_id)
signal cell_left()
signal authority_changed(new_id)

const RANGE_JOIN = 40000.0
const RANGE_LEAVE = 45000.0
const VIEW_HZ = 10.0
const STATE_EVERY = 2.0
const HB_HZ = 5.0
const AUTH_SILENT = 1.5        # member: authority quiet this long (crash) -> gone, next-lowest takes over
const STALL = 0.25             # a frame of mine longer than this restarts the silence clock
const ORPHAN_WAIT = 2.0        # member: authority out of my view and nobody claimed the cell -> leave
const BEACON_EXTRAP_MAX = 2.0
const SLIP_MARGIN = 150000.0   # authority slipstreams early once any member gets this close to the radius
const WARP_DISTANCE = 20000.0
const LOG_EVERY = 5.0
const PEER_STALE = 6.0          # same as CoopNet.BEACON_TIMEOUT
const AD_EVERY = 1.0
const AD_STALE = 3.5
const RESIGN_GRACE = 2.0       # a resigned authority's in-flight beacons don't bring it back into the graph
const MERGE_WAIT = 4.0         # member: our authority resigned to a bigger cell; wait this long for its c.state

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
var born = 0                   # formation time of the cell (system ms), carried through handoffs
var mergeTo = 0                # member: our authority resigned in favour of this authority's cell
var mergeSince = 0.0
var adverts = {}               # authority id -> {cid, n, born, at}: cells other machines run
var resigned = {}              # id -> cid it resigned; its late packets for that cid are ignored
var lastWinner = 0
var ghost = null               # member: {n, born, until} of our cell after its authority died, held by the heir
var adAccum = 0.0

var edges = {}                 # "a:b" (a < b) -> linked, for hysteresis
var lastComp = []
var lost = {}                  # id -> s: authority resigned or went silent; out of the graph until heard again
var heardAt = {}               # id -> s, last c.* packet from it
var orphanSince = -1.0
var lastTickAt = -1.0

var viewAccum = 0.0
var stateAccum = 0.0
var hbAccum = 0.0
var logAccum = 0.0
var stateDirty = false
var pinned = false

var warpAfter = -1.0
var warpClock = 0.0
var warpDone = false
var warpDist = WARP_DISTANCE

var devSlipEvery = -1.0
var devSlipClock = 0.0

func _ready():
	name = "Cell"
	# Run after BulletTimer and the rest of the game so the time-scale pin has the last word each tick.
	process_priority = 1000
	net.on("c.state", self, "_onState")
	net.on("c.join", self, "_onJoin")
	net.on("c.leave", self, "_onLeave")
	net.on("c.hb", self, "_onHb")
	net.on("c.ad", self, "_onAd")
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-warp-to-peer="):
			var parts = arg.substr(20).split(",")
			warpAfter = float(parts[0])
			if parts.size() > 1:
				warpDist = float(parts[1])
		elif arg.begins_with("--coop-dev-slipstream="):
			devSlipEvery = float(arg.substr(22))

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

	# My own stall (building a snapshot, loading) is not the authority going quiet.
	if lastTickAt >= 0 and now - lastTickAt > STALL and role == Role.MEMBER:
		heardAt[auth] = max(heardAt.get(auth, now), now)
	lastTickAt = now

	if role == Role.MEMBER and mergeTo == 0 and not lost.has(auth) and now - heardAt.get(auth, now) > AUTH_SILENT:
		lost[auth] = now
		_setGhost(now)
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
	var pr = net.peers[id]
	if lost.has(id):
		if pr.beaconAt <= lost[id]:
			return null
		lost.erase(id)   # a fresh beacon: it's alive (resigned to join a lower id, or hitched)
	var b = pr.beacon
	if b == null or now - pr.beaconAt > PEER_STALE or b.get("zone") != "rings" or not b.has("p"):
		return null
	var pp = net._puppetOf(id)
	if pp != null:
		return CurrentGame.globalCoords(pp.global_position)
	return b.p + b.get("v", Vector2(0, 0)) * min(now - pr.beaconAt, BEACON_EXTRAP_MAX)

# My connected group, sorted by id. [myId] when I'm not in the rings.
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

	if role == Role.SOLO and _inCutscene():
		return   # no forming or joining while my own dive cutscene flies its corridor

	var win = _winner(comp, now)
	if win != lastWinner:
		_log("winner of %s is %s" % [comp, win])
		lastWinner = win

	if win == net.myId:
		match role:
			Role.SOLO:
				_becomeAuthority(comp)
			Role.MEMBER:
				# only when my authority is gone; a live one keeps the cell even if its advert went stale
				if lost.has(auth) or not comp.has(auth):
					_promote(comp)
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

	# another cell (or a lower solo id) wins: wait for its c.state (handled in _onState)
	match role:
		Role.AUTHORITY:
			_leave("cell of %s wins" % win, win)
		Role.MEMBER:
			if mergeTo != 0:
				if now - mergeSince > MERGE_WAIT:
					_leave("no c.state from %s after the merge" % mergeTo)
			elif comp.has(auth):
				orphanSince = -1.0
			elif orphanSince < 0:
				orphanSince = now
			elif now - orphanSince > ORPHAN_WAIT:
				_leave("authority %s out of view, nobody took over" % auth)

func _becomeAuthority(comp):
	role = Role.AUTHORITY
	auth = net.myId
	cellSeq += 1
	born = OS.get_system_time_msecs()
	# born makes the id unique across restarts: Steam ids are stable and cellSeq restarts at 1, so a restarted
	# player's new cell would otherwise reuse a cid that peers still hold in `resigned` and ignore it
	cid = "%s:%d:%d" % [net.myId, born, cellSeq]
	off = CurrentGame.globalOffset
	originGen = 0
	cellMembers = comp
	confirmed = {}
	_setSpawner(true)
	_log("FORMED cell %s as authority, view=%s off=%s" % [cid, comp, off])
	emit_signal("cell_joined", net.myId)
	_sendState()
	_sendAd()

# Member -> authority of the same cell (the old authority left). Origin and cid carry over.
func _promote(comp):
	var old = auth
	role = Role.AUTHORITY
	auth = net.myId
	off = CurrentGame.globalOffset
	# the others already sit on this origin with the same rocks: keep them in members() (no re-snap)
	confirmed = {}
	for id in comp:
		if id != net.myId and cellMembers.has(id):
			confirmed[id] = true
	cellMembers = comp
	_setSpawner(true)
	_log("PROMOTED to authority of %s (was %s), view=%s gen=%d" % [cid, old, comp, originGen])
	mergeTo = 0
	ghost = null
	emit_signal("authority_changed", net.myId)
	if comp.size() > 1:
		_sendState()
		_sendAd()

# to: the authority whose cell beat mine (my members wait for its c.state); 0 = leaving for good.
func _leave(why, to = 0):
	if role == Role.SOLO:
		return
	if role == Role.MEMBER:
		if not lost.has(auth) and net.peers.has(auth):
			net.send(auth, {"t": "c.leave", "cid": cid, "gen": originGen}, true)
		# follow-ups armed before or during membership would land next to me, stale
		_dropQueuedOddities("leaving a cell")
	else:
		# resign: with to == 0 the lowest of the rest promotes and keeps the cell's rocks
		net.sendTo(cellMembers, {"t": "c.leave", "cid": cid, "gen": originGen, "to": to}, true)
		net.sendTo(net.peers.keys(), {"t": "c.ad", "cid": cid, "n": 0, "born": born}, false)
	_log("LEFT cell %s as %s (%s)" % [cid, Role.keys()[role], why])
	role = Role.SOLO
	auth = net.myId
	cid = ""
	originGen = -1
	cellMembers = []
	confirmed = {}
	orphanSince = -1.0
	mergeTo = 0
	ghost = null
	_setSpawner(true)
	emit_signal("cell_left")

func _join(from, msg):
	role = Role.MEMBER
	auth = from
	cid = msg.cid
	cellMembers = msg.members
	originGen = msg.gen
	born = msg.get("born", 0)
	orphanSince = -1.0
	mergeTo = 0
	ghost = null
	_adopt(msg.off)
	_setSpawner(false)
	_dropQueuedOddities("joining a cell")
	_log("JOINED cell %s, authority %s, members=%s gen=%d" % [cid, auth, cellMembers, originGen])
	emit_signal("cell_joined", auth)
	net.send(auth, {"t": "c.join", "cid": cid, "gen": originGen}, true)

# The stock spawner keeps the dive corridor clear; an authority's field doesn't, so a diving ship stays solo.
func _inCutscene():
	var ship = _ship()
	return ship != null and ship.get("cutscene") == true

# Story follow-ups (FlightForRescue, Vilcy timers) queue bodies in TheRing.spawnNow, and made-but-unplaced events
# wait in unspawnedOddities; only the spawner drains them. A member must not carry them into or out of a cell.
func _dropQueuedOddities(why):
	var g = net._gameScene()
	var ring = g.get_node_or_null("TheRing") if g != null else null
	if ring == null or not ("spawnNow" in ring):
		return
	var dropped = 0
	var bodies = ring.spawnNow.duplicate()
	for k in ring.unspawnedOddities:
		var o = ring.unspawnedOddities[k]
		bodies += o if o is Array else [o]
	for o in bodies:
		if o != null and is_instance_valid(o) and not o.is_inside_tree() and not o.is_queued_for_deletion():
			o.queue_free()
			dropped += 1
	ring.spawnNow.clear()
	ring.unspawnedOddities.clear()
	ring.unspawnedOdditiesLocation.clear()
	_log("dropped %d queued oddities (%s)" % [dropped, why])

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

	adAccum += delta
	if adAccum >= AD_EVERY:
		_sendAd()

	hbAccum += delta
	if hbAccum >= 1.0 / HB_HZ:
		hbAccum = 0.0
		net.sendTo(cellMembers, {"t": "c.hb", "cid": cid, "gen": originGen}, false)

	# Members may sit up to RANGE_LEAVE from me; slipstream before any of them reaches its own radius,
	# because a member's stock slipstream would move its origin away from the cell's.
	var f = _field()
	if f != null and devSlipEvery > 0 and confirmed.size() > 0:
		devSlipClock += delta
		if devSlipClock >= devSlipEvery:
			devSlipClock = 0.0
			_log("dev slipstream forced at gen %d" % originGen)
			Tool.deferCallWhenIdle(f, "slipstream", [], true)
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
	net.sendTo(cellMembers, {"t": "c.state", "cid": cid, "auth": net.myId, "members": cellMembers, "off": off, "gen": originGen, "n": members().size(), "born": born}, true)

func _sendAd():
	adAccum = 0.0
	net.sendTo(net.peers.keys(), {"t": "c.ad", "cid": cid, "n": members().size(), "born": born}, false)

# Our authority died: until the heir advertises, the cell's last advert stands for the heir (lowest surviving
# member), so a solo player in range can't take the cell over during the handoff.
func _setGhost(now):
	var ad = adverts.get(auth)
	ghost = {
		"n": ad.n if ad != null else cellMembers.size(),
		"born": ad.born if ad != null else born,
		"until": now + MERGE_WAIT,
	}

func _heir():
	var h = -1
	for id in cellMembers:
		if id != auth and not lost.has(id) and (id == net.myId or net.peers.has(id)) and (h < 0 or id < h):
			h = id
	return h

# Size and age of the cell a player runs, {n, born}, or null if it runs none.
func _cellInfo(id, now):
	if ghost != null and role == Role.MEMBER and now < ghost.until and id == _heir():
		return ghost
	if id == net.myId:
		if role == Role.AUTHORITY:
			return {"n": members().size(), "born": born}
		return null
	var ad = adverts.get(id)
	if ad != null and now - ad.at < AD_STALE:
		return ad
	return null

# The authority for a connected group: the incumbent cell (most members, then oldest, then lowest id);
# with no cell in the group, the lowest id.
func _winner(comp, now):
	var best = comp[0]
	var bestInfo = null
	for id in comp:
		var info = _cellInfo(id, now)
		if info == null:
			continue
		if bestInfo == null or info.n > bestInfo.n or (info.n == bestInfo.n and (info.born < bestInfo.born or (info.born == bestInfo.born and id < best))):
			best = id
			bestInfo = info
	return best

func _noteAd(from, msg):
	if msg.get("n", 0) <= 0:
		adverts.erase(from)
	else:
		adverts[from] = {"cid": msg.get("cid"), "n": msg.get("n"), "born": msg.get("born", 0), "at": _now()}

func _isResigned(from, msg):
	return resigned.has(from) and resigned[from] == msg.get("cid")

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
	if role == Role.MEMBER and from == auth and msg.get("cid") == cid:
		resigned[from] = cid
		var to = msg.get("to", 0)
		if to != 0:
			mergeTo = to
			mergeSince = _now()
			adverts.erase(from)
			_log("authority %s resigned to %s's cell, waiting for its c.state" % [from, to])
		else:
			lost[auth] = _now() + RESIGN_GRACE
			_setGhost(_now())
			_log("authority %s resigned" % from)
		viewAccum = 1.0
		return
	_heard(from)
	if confirmed.has(from):
		confirmed.erase(from)
		_log("member %s left, members=%s" % [from, members()])

func _onHb(from, msg):
	if not _isResigned(from, msg):
		_heard(from)

func _onAd(from, msg):
	if _isResigned(from, msg):
		return
	_noteAd(from, msg)

func _heard(from):
	heardAt[from] = _now()
	if lost.has(from):
		lost.erase(from)
		_log("%s heard again" % from)

# ---------------------------------------------------------------- member

func _onState(from, msg):
	if _isResigned(from, msg):
		_log("late c.state from %s for resigned cell %s ignored" % [from, msg.cid])
		return
	_heard(from)
	_noteAd(from, msg)
	if role == Role.SOLO and _inCutscene():
		return   # join once the dive cutscene is over; the authority resends c.state every 2 s
	var listed = msg.members
	if not listed.has(net.myId):
		if role == Role.MEMBER and from == auth:
			_leave("authority %s dropped me" % from)
		return
	# Same cell from another member: the authority handed off (its view lost the old one before mine did).
	var sameCell = role == Role.MEMBER and msg.cid == cid and cellMembers.has(from)
	if not sameCell and from != mergeTo and (not lastComp.has(from) or _winner(lastComp, _now()) != from):
		# not the winner in my own view (yet); it resends every 2 s
		return

	if sameCell:
		cellMembers = listed
		born = msg.get("born", born)
		if from != auth:
			var old = auth
			auth = from
			ghost = null
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
	var pick = -1
	for id in ids:
		if _peerPos(id, now) == null:
			continue
		if pick < 0 or (_cellInfo(id, now) != null and _cellInfo(pick, now) == null):
			pick = id
	if pick < 0:
		return
	warpDone = true
	var p = _peerPos(pick, now)
	var v = net.peers[pick].beacon.get("v", Vector2(0, 0))
	var me = CurrentGame.globalCoords(ship.global_position)
	var toMe = (me - p).normalized() if me != p else Vector2(0, 1)
	# beside its course, not in front of it; on my side
	var dir = v.normalized().tangent() if v.length() > 1.0 else toMe
	if dir.dot(toMe) < 0:
		dir = - dir
	var target = p + dir * warpDist
	ship.teleportBy(CurrentGame.localCoords(target) - ship.global_position)
	ship.reset_physics_interpolation()
	ship.linear_velocity = v
	_log("WARP dev: %s -> %s, %.0f px beside %s (v %s)" % [me, target, warpDist, pick, v])
