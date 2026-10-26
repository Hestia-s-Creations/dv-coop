extends Node

# RockSync: net ids for world bodies, the authority's rock stream, and members' tracked rocks (M3). See docs/M3.md.
#
# Every RigidBody2D that enters the AsteroidField gets a net id "<peer>:<counter>" (meta "dvnet") and a registry
# entry. Rocks (asteroids/class-*.tscn, asteroids/mineral-*.tscn) are replicated inside a cell:
#   authority  keeps, per member, the set of rock ids that member knows. Rocks within FAR of the member's ship are
#              spawned on it (r.s), rocks past FAR_DROP or gone/fracturing are despawned (r.d), known rocks are updated
#              (r.u) at NEAR_HZ within NEAR and FAR_HZ beyond. A new member gets everything in range as r.snap.
#   member     builds tracked rocks (meta "dvnet_tracked") from recipes and pulls them toward r.u by velocity
#              correction; it never spawns, fractures or despawns one itself.
#   alone      nothing; the stock game runs untouched.
# Roles are polled from Cell every physics tick, so transitions don't depend on signal order.

const NEAR = 6000.0
const FAR = 30000.0
const FAR_DROP = 34000.0
const NEAR_HZ = 10.0
const FAR_HZ = 2.0
const INTEREST_HZ = 2.0
const BATCH = 200
const DEFER_MARGIN = 150.0   # authority: a rock this close to a member's ship (puppet here) is not sent to it yet
const SNAP_DISTANCE = 400.0
const SNAP_ANGLE = 0.8
const CORRECTION_GAIN = 3.0
const MAX_EXTRAPOLATION = 1.0
const LOG_EVERY = 5.0
const ROCK_PREFIX = "res://asteroids/"

var net = null   # CoopNet

signal rock_born(id, node)    # a rock entered the field on this machine (spawned here or built from a recipe)
signal rock_gone(id, node)    # a rock is leaving the field (despawn, fracture, consumed, pruned)
signal body_born(id, node)    # any RigidBody2D entered the field (bullets, ships, rocks)

var field = null
var counter = 0
var bodies = {}      # id -> node, every body with a net id in the current field
var rocks = {}       # id -> node, the replicable subset (authority side: those still streamable)
var tracked = {}     # member: id -> {n, p, r, v, w, at}
var receivers = {}   # authority: peer -> {known: {id: true}, slept: {id: true}, snap: bool}
var fresh = []       # authority: ids that entered the field since the last tick
var gone = []        # authority: ids that left the field (or started fracturing) since the last tick
var held = []        # member: reliable packets [from, msg] waiting for the cell to be ready
var snapSeen = null  # member: ids seen in the r.snap being received, or null
var scenes = {}      # kind -> PackedScene: the only scenes a recipe may name (from the field's objectClass)
var role = "solo"    # solo | authority | member
var nearAccum = 0.0
var farAccum = 0.0
var interestAccum = 0.0
var logAccum = 0.0
var screenDump = false     # dev: DVCOOP_RS_SCREEN=1 also logs the camera transform and every rock on screen
var puppetProbe = false   # dev: DVCOOP_RS_PUPPETS=1 logs rock clearance around ships after a snapshot, and hull impacts
var probeUntil = 0
var mineralLog = 0         # dev: DVCOOP_RS_MINERALS=1 logs the first few minerals sent (authority) / built (member)
var logEvery = LOG_EVERY   # dev: DVCOOP_RS_SAMPLE=<seconds> logs the RS line (and its nearest-rock samples) that often
var sent = {"s": 0, "d": 0, "u": 0, "bytes": 0, "defer": 0}
var lastGen = -1     # authority: origin generation the receivers' sleep marks belong to
var hooked = null    # the Cell whose signals we listen to
var replaying = false
var fader = null     # RockFade: the stock fade-in for the rocks we build, robust to the long frame a batch build makes

func _ready():
	name = "RockSync"
	fader = load("res://dv-coop/net/RockFade.gd").new()
	add_child(fader)
	# coop:dev{
	var sample = OS.get_environment("DVCOOP_RS_SAMPLE")
	if sample != "" and float(sample) > 0:
		logEvery = max(0.2, float(sample))
		Debug.l("COOP: RS logging every %.1f s (DVCOOP_RS_SAMPLE)" % logEvery)
	screenDump = OS.get_environment("DVCOOP_RS_SCREEN") == "1"
	puppetProbe = OS.get_environment("DVCOOP_RS_PUPPETS") == "1"
	mineralLog = 5 if OS.get_environment("DVCOOP_RS_MINERALS") == "1" else 0
	# coop:dev}
	net.on("r.s", self, "_onSpawn")
	net.on("r.snap", self, "_onSpawn")
	net.on("r.d", self, "_onDespawn")
	net.on("r.u", self, "_onUpdate")
	net.on("r.clk", self, "_onClk")
	net.on("r.clk2", self, "_onClk2")

# ---------------------------------------------------------------- interface (docs/M3.md)

func trackedCount() -> int:
	return tracked.size()

# Member leaving a cell: free tracked rocks (the spawner refills).
func releaseAll():
	var n = tracked.size()
	for id in tracked.keys():
		var node = tracked[id].n
		if is_instance_valid(node):
			Tool.remove(node)
	tracked.clear()
	held.clear()
	snapSeen = null
	Debug.l("COOP: RS released %d tracked rocks" % n)

# Handoff: tracked rocks become locally simulated and start streaming.
func promoteToAuthority():
	var n = 0
	for id in tracked.keys():
		var node = tracked[id].n
		if not is_instance_valid(node):
			continue
		node.remove_meta("dvnet_tracked")
		rocks[id] = node   # streamable from here on, under the same id the members already know
		# tracked rocks were never counted in this machine's density map; count them so the stock despawn balances
		var oc = node.get("asteroidClass")
		if field != null and oc != null and oc >= 0 and oc < 5:
			field.getDensityByPosition(node.global_position)[oc] += 1
		n += 1
	tracked.clear()
	held.clear()
	snapSeen = null
	receivers.clear()
	role = "authority"
	Debug.l("COOP: RS promoted to authority, %d rocks now simulated here" % n)

# ---------------------------------------------------------------- clocks (M4: extrapolate from the sender's sample time)
#
# Streams (r.u, o.u) carry the sender's wall-clock ms at sampling. Every CLOCK_EVERY s each machine pings the other cell
# members (r.clk / r.clk2) and keeps, per peer, the offset (their clock - ours) from the lowest-RTT sample of the last
# CLOCK_KEEP. A stream's sample time in our clock is then ts - offset, so a tracked copy is extrapolated from when the
# owner sampled it, not from when the packet happened to arrive (M3 known issue: ~6 px at 95 px/s on one PC).

const CLOCK_EVERY = 2.0
const CLOCK_KEEP = 8
var clocks = {}      # peer -> [[rtt, offset], ...] newest last
var clockAccum = 0.0

func _ms() -> int:
	return OS.get_system_time_msecs()

func clockOffset(peer):
	var l = clocks.get(peer)
	if l == null or l.empty():
		return null
	var best = l[0]
	for e in l:
		if e[0] < best[0]:
			best = e
	return best

# A sender's sample time in our wall clock. Without a measured offset, assume half the CoopNet ping ago.
func localSampleMs(peer, ts) -> int:
	var now = _ms()
	if ts == null or int(ts) < 0:
		return now
	var b = clockOffset(peer)
	if b == null:
		return now - int(max(0, net.stats.rtt_ms) / 2)
	return int(min(now, int(ts) - b[1]))

func _clockTick(delta, cell):
	clockAccum += delta
	if clockAccum < CLOCK_EVERY:
		return
	clockAccum = 0.0
	for p in cell.members():
		if p != net.myId:
			net.send(p, {"t": "r.clk", "a": _ms()}, false)

func _onClk(from, msg):
	net.send(from, {"t": "r.clk2", "a": msg.get("a", 0), "b": _ms()}, false)

func _onClk2(from, msg):
	var now = _ms()
	var a = int(msg.get("a", 0))
	var rtt = now - a
	if rtt < 0 or rtt > 2000:
		return
	var off = int(msg.get("b", 0)) - a - rtt / 2.0
	if not clocks.has(from):
		clocks[from] = []
	clocks[from].append([rtt, off])
	if clocks[from].size() > CLOCK_KEEP:
		clocks[from].pop_front()

# ---------------------------------------------------------------- ownership hooks (M4, used by Own.gd)

func nodeOf(id):
	var n = bodies.get(id)
	return n if n != null and is_instance_valid(n) else null

func trackedState(id):
	return tracked.get(id)

# Member won a claim: its tracked copy becomes the simulated body, in place (never rebuilt).
func untrack(id):
	var t = tracked.get(id)
	if t == null:
		return null
	tracked.erase(id)
	if is_instance_valid(t.n):
		t.n.remove_meta("dvnet_tracked")
		return t.n
	return null

# A body this machine no longer owns: correct it toward its owner's stream from now on.
func track(id, node, p, r, v, w):
	if node == null or not is_instance_valid(node):
		return
	node.set_meta("dvnet_tracked", true)
	tracked[id] = {"n": node, "p": p, "r": r, "v": v, "w": w, "at": _ms()}

func updateTracked(id, p, r, v, w, at = -1):
	var t = tracked.get(id)
	if t != null:
		t.p = p
		t.r = r
		t.v = v
		t.w = w
		t.at = at if at >= 0 else _ms()

# Authority: does it currently stream this rock with r.u (i.e. no player owns it)?
func isStreamed(id) -> bool:
	return rocks.has(id) and not tracked.has(id)

# ---------------------------------------------------------------- registry

func _cell():
	var c = net.get_node_or_null("Cell")
	if c != null and c.has_method("inCell"):
		if hooked != c and c.has_signal("authority_changed"):
			c.connect("authority_changed", self, "_onAuthorityChanged")
			hooked = c
		return c
	return null

# Origin generation from Cell (+1 per slipstream); r.s/r.snap/r.u carry it so nothing lands across a shift.
func _gen(cell) -> int:
	if cell != null and cell.has_method("gen"):
		return cell.gen()
	return 0

# Fires before cell_left when the authority vanished and we're the one left, so promote here (gate 5):
# polling alone would see member -> solo and release the rocks.
func _onAuthorityChanged(newId):
	if newId == net.myId and role == "member" and field != null:
		Debug.l("COOP: RS authority_changed to me")
		promoteToAuthority()

func _attach(f):
	_detach()
	field = f
	_collectScenes()
	field.connect("child_entered_tree", self, "_onChildEntered")
	field.connect("child_exiting_tree", self, "_onChildExiting")
	for c in field.get_children():
		_onChildEntered(c)
	Debug.l("COOP: RS attached to field, %d bodies (%d rocks)" % [bodies.size(), rocks.size()])

func _detach():
	if field != null and is_instance_valid(field):
		if field.is_connected("child_entered_tree", self, "_onChildEntered"):
			field.disconnect("child_entered_tree", self, "_onChildEntered")
			field.disconnect("child_exiting_tree", self, "_onChildExiting")
	field = null
	bodies.clear()
	rocks.clear()
	tracked.clear()
	receivers.clear()
	fresh.clear()
	gone.clear()
	held.clear()
	snapSeen = null
	scenes.clear()
	role = "solo"

# Everything spawnAsteroidByClass can produce, fracture shards included (they come from the same table).
func _collectScenes():
	scenes.clear()
	for entry in field.objectClass:
		var lists = entry.values() if entry is Dictionary else [entry]
		for l in lists:
			for ps in l:
				var path = ps.resource_path
				if path.begins_with(ROCK_PREFIX):
					scenes[path.substr(ROCK_PREFIX.length()).trim_suffix(".tscn")] = ps

static func isRock(node) -> bool:
	var f = node.filename
	return f.begins_with(ROCK_PREFIX + "class-") or f.begins_with(ROCK_PREFIX + "mineral-")

func _onChildEntered(node):
	if not (node is RigidBody2D):
		return
	var id
	if node.has_meta("dvnet"):
		id = node.get_meta("dvnet")
	else:
		counter += 1
		id = "%d:%d" % [net.myId, counter]
		node.set_meta("dvnet", id)
	bodies[id] = node
	emit_signal("body_born", id, node)
	if isRock(node):
		emit_signal("rock_born", id, node)
		if not node.has_meta("dvnet_tracked"):
			rocks[id] = node
			fresh.append(id)

func _onChildExiting(node):
	if not node.has_meta("dvnet"):
		return
	var id = node.get_meta("dvnet")
	if isRock(node):
		emit_signal("rock_gone", id, node)
	bodies.erase(id)
	tracked.erase(id)
	if rocks.has(id):
		rocks.erase(id)
		gone.append(id)

# ---------------------------------------------------------------- recipes

# [id, kind, scale, p, r, v, w, class, k, estimatedRadius, splitsTo]
# kind: scene name under res://asteroids/; k: asteroid rnd, or mineral mineralContent. Positions are origin-relative.
func _recipe(id, n) -> Array:
	var kind = n.filename.substr(ROCK_PREFIX.length()).trim_suffix(".tscn")
	var mineral = n.get("mineralContent") != null
	if mineral:
		_logMineral("sent", id, n)
	return [id, kind, 1.0 if mineral else n.additionalScale, n.global_position, n.global_rotation,
		n.linear_velocity, n.angular_velocity, n.asteroidClass, n.mineralContent if mineral else n.rnd,
		n.estimatedRadius, 0 if mineral else n.splitsTo]

static func _isNum(x) -> bool:
	return x is float or x is int

static func _validRecipe(rc) -> bool:
	return rc is Array and rc.size() == 11 and rc[0] is String and rc[1] is String and _isNum(rc[2]) \
		and rc[3] is Vector2 and _isNum(rc[4]) and rc[5] is Vector2 and _isNum(rc[6]) and _isNum(rc[7]) \
		and _isNum(rc[8]) and _isNum(rc[9]) and _isNum(rc[10])

# Authority: build a rock a member created (fracture shards, o.new) as one we simulate and stream.
func buildSimulated(rc):
	if not _validRecipe(rc) or bodies.has(rc[0]):
		return null
	return _build(rc, false)

func _build(rc, asTracked = true):
	var id = rc[0]
	var kind = rc[1]
	if not scenes.has(kind):
		Debug.l("COOP: RS dropped recipe %s: kind %s is not a spawner rock scene" % [id, kind])
		return null
	var n = scenes[kind].instance()
	n.set_meta("dvnet", id)
	if asTracked:
		n.set_meta("dvnet_tracked", true)
	n.position = rc[3]
	n.rotation = rc[4]
	n.asteroidClass = int(rc[7])
	n.estimatedRadius = rc[9]
	var mineral = n.get("mineralContent") != null
	if not mineral:
		n.additionalScale = rc[2]   # asteroid._ready() applies it through setScale
		n.splitsTo = int(rc[10])
	field.add_child(n)
	fader.add(n)
	n.linear_velocity = rc[5]
	n.angular_velocity = rc[6]
	if mineral:
		_setMineralContent(n, rc[8])
		_logMineral("built", id, n)
	else:
		n.rnd = rc[8]
	if asTracked:
		tracked[id] = {"n": n, "p": rc[3], "r": rc[4], "v": rc[5], "w": rc[6], "at": _ms()}
	return n

func recipeOf(id):
	var n = nodeOf(id)
	return _recipe(id, n) if n != null else null

# Member: a rock born here (a fracture shard) is handed to the authority; from now on it is a tracked copy.
func handOver(id):
	var n = nodeOf(id)
	if n == null:
		return
	rocks.erase(id)
	fresh.erase(id)
	track(id, n, n.global_position, n.global_rotation, n.linear_velocity, n.angular_velocity)

var mineralsLogged = {}
func _logMineral(what, id, n):
	if mineralLog <= 0 or mineralsLogged.has(id) or mineralsLogged.size() >= mineralLog:
		return
	mineralsLogged[id] = true
	Debug.l("COOP: RS mineral %s %s %s content=%.6f mass=%.4f composition=%s" % [what, id, n.filename.get_file(), n.mineralContent, n.mass, n.composition])

# mineral._ready() rolls its own content and scales by it; redo that with the authority's roll.
func _setMineralContent(n, k):
	var rolled = lerp(n.scaleMax, n.scaleMin, clamp(n.mineralContent, 0, 1))
	var want = lerp(n.scaleMax, n.scaleMin, clamp(k, 0, 1))
	var f = want / rolled if rolled != 0 else 1.0
	n.sprite.scale *= f
	n.getCollider().scale *= f
	n.mineralContent = k
	n.fillerContent = 1 - k
	if k > 0:
		n.composition[n.mineral] = k * n.baseMass * n.massScale
		n.mass = n.composition[n.mineral] + n.composition[n.filler]
	else:
		n.composition.erase(n.mineral)
		n.mass = n.composition[n.filler]

# ---------------------------------------------------------------- tick

func _physics_process(delta):
	if net == null or net.transport == net.Transport.NONE:
		return
	var game = net._gameScene() if net.dived else null
	var f = game.get_node("AsteroidField") if game != null else null
	if f != field:
		if f == null:
			_detach()
		else:
			_attach(f)
	if field == null:
		return

	var cell = _cell()
	var want = "solo"
	if cell != null and cell.inCell():
		want = "authority" if cell.isAuthority() else "member"
	if want != role:
		_changeRole(role, want)

	if role != "solo":
		_clockTick(delta, cell)
	match role:
		"authority":
			_authorityTick(delta, cell)
		"member":
			_memberTick(delta, cell)
		_:
			fresh.clear()
			gone.clear()

	logAccum += delta
	if logAccum >= logEvery:
		logAccum = 0.0
		_logState()

func _changeRole(from, to):
	Debug.l("COOP: RS role %s -> %s (bodies=%d rocks=%d tracked=%d)" % [from, to, bodies.size(), rocks.size(), tracked.size()])
	if from == "member" and to == "authority":
		promoteToAuthority()
	elif from == "member":
		releaseAll()
	if to == "member":
		_freeOwnRocks()
	else:
		held.clear()   # r.s held for a member session; nothing will ever release them now
	receivers.clear()
	fresh.clear()
	gone.clear()
	role = to

# Joining someone else's cell: our own rocks go, the authority's arrive.
func _freeOwnRocks():
	var n = 0
	for id in rocks.keys():
		var node = rocks[id]
		if is_instance_valid(node) and not node.has_meta("dvnet_tracked") and not node.has_meta("dvnet_puppet"):
			field.kill(node, true)
			n += 1
	rocks.clear()
	Debug.l("COOP: RS freed %d own rocks on joining a cell" % n)

# ---------------------------------------------------------------- authority

func _receiverPos(peer):
	if not net.peers.has(peer):
		return null
	var pp = net._puppetOf(peer)
	if pp != null:
		return pp.global_position
	var b = net.peers[peer].beacon
	if b != null and b.has("p"):
		return CurrentGame.localCoords(b.p)
	return null

func _authorityTick(delta, cell):
	# rocks that started fracturing leave the stream now; their shards arrive as spawns
	for id in rocks.keys():
		var node = rocks[id]
		if not is_instance_valid(node) or node.get("fracturing") == true:
			rocks.erase(id)
			gone.append(id)

	var g = _gen(cell)
	if g != lastGen:
		lastGen = g
		for peer in receivers:
			receivers[peer].slept.clear()   # every rock moved; sleepers need one fresh update

	# membership
	var members = cell.members()
	for peer in members:
		if peer != net.myId and not receivers.has(peer):
			receivers[peer] = {"known": {}, "slept": {}, "snap": true}
			Debug.l("COOP: RS new member %s, sending snapshot" % peer)
	for peer in receivers.keys():
		if not (peer in members):
			receivers.erase(peer)
			Debug.l("COOP: RS member %s left" % peer)

	interestAccum += delta
	var interest = interestAccum >= 1.0 / INTEREST_HZ
	if interest:
		interestAccum = 0.0
	nearAccum += delta
	var near = nearAccum >= 1.0 / NEAR_HZ
	if near:
		nearAccum = 0.0
	farAccum += delta
	var far = farAccum >= 1.0 / FAR_HZ
	if far:
		farAccum = 0.0

	for peer in receivers.keys():
		var rv = receivers[peer]
		var at = _receiverPos(peer)
		if at == null:
			continue
		var spawn = []
		var despawn = []
		for id in gone:
			if rv.known.has(id):
				rv.known.erase(id)
				rv.slept.erase(id)
				despawn.append(id)
		if rv.snap or interest:
			for id in rocks:
				var d = rocks[id].global_position.distance_to(at)
				if rv.known.has(id):
					if d > FAR_DROP:
						rv.known.erase(id)
						rv.slept.erase(id)
						despawn.append(id)
				elif d < FAR and not _overlapsShipOf(peer, rocks[id]):
					rv.known[id] = true
					spawn.append(_recipe(id, rocks[id]))
		else:
			for id in fresh:
				if rocks.has(id) and not rv.known.has(id) and rocks[id].global_position.distance_to(at) < FAR \
						and not _overlapsShipOf(peer, rocks[id]):
					rv.known[id] = true
					spawn.append(_recipe(id, rocks[id]))
		if rv.snap:
			_sendBatches(peer, "r.snap", spawn, true, g)
			Debug.l("COOP: RS snapshot to %s: %d rocks" % [peer, spawn.size()])
			rv.snap = false
		elif spawn.size() > 0:
			_sendBatches(peer, "r.s", spawn, false, g)
		if despawn.size() > 0:
			for i in range(0, despawn.size(), BATCH):
				_out(peer, {"t": "r.d", "l": despawn.slice(i, min(i + BATCH, despawn.size()) - 1)}, true)
			sent.d += despawn.size()
		if near or far:
			_sendUpdates(peer, rv, at, near, far, g)
	fresh.clear()
	gone.clear()
	_correct()

# Would this rock, built on the member's machine, sit inside or against that member's ship? Its ship is the puppet
# here. Same shape query as the stock spawner's placement test, with a margin for the puppet's lag. A deferred rock
# stays unknown to that member, so the next interest pass (0.5 s) tries again.
func _overlapsShipOf(peer, rock) -> bool:
	var pp = net._puppetOf(peer)
	if pp == null or rock.global_position.distance_to(pp.global_position) > 4000.0:
		return false
	var collider = rock.getCollider() if rock.has_method("getCollider") else null
	if collider == null:
		return false
	var shape
	if collider.has_method("get_shape"):
		shape = collider.get_shape()
	else:
		shape = ConvexPolygonShape2D.new()
		shape.points = collider.polygon
	var params = Physics2DShapeQueryParameters.new()
	params.set_shape(shape)
	params.transform = collider.global_transform
	params.margin = DEFER_MARGIN
	params.collision_layer = field.asteroidIntersectionTest
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.exclude = [rock.get_rid()]
	for hit in rock.get_world_2d().direct_space_state.intersect_shape(params, 16):
		var c = hit.collider
		while c != null and c != field:
			if c == pp:
				sent.defer += 1
				return true
			c = c.get_parent()
	return false

func _sendBatches(peer, t, recipes, snap, g):
	var n = recipes.size()
	if n == 0 and snap:
		_out(peer, {"t": t, "g": g, "l": [], "first": true, "last": true}, true)
		return
	for i in range(0, n, BATCH):
		var msg = {"t": t, "g": g, "l": recipes.slice(i, min(i + BATCH, n) - 1)}
		if snap:
			msg.first = (i == 0)
			msg.last = (i + BATCH >= n)
		_out(peer, msg, true)
	sent.s += n

func _sendUpdates(peer, rv, at, near, far, g):
	var ids = PoolStringArray()
	var f = PoolRealArray()
	for id in rv.known:
		var node = rocks.get(id)
		if node == null or node.has_meta("dvnet_tracked"):
			continue   # gone, or owned by a player who streams it with o.u
		var d = node.global_position.distance_to(at)
		if not ((near and d < NEAR) or (far and d >= NEAR)):
			continue
		if node.sleeping:
			if rv.slept.has(id):
				continue
			rv.slept[id] = true
		else:
			rv.slept.erase(id)
		var p = node.global_position
		var v = node.linear_velocity
		ids.append(id)
		f.append_array([p.x, p.y, node.global_rotation, v.x, v.y, node.angular_velocity])
		if ids.size() >= BATCH:
			_out(peer, {"t": "r.u", "g": g, "ts": _ms(), "i": ids, "f": f}, false)
			sent.u += ids.size()
			ids = PoolStringArray()
			f = PoolRealArray()
	if ids.size() > 0:
		_out(peer, {"t": "r.u", "g": g, "ts": _ms(), "i": ids, "f": f}, false)
		sent.u += ids.size()

func _out(peer, msg, reliable):
	sent.bytes += var2bytes(msg).size()
	net.send(peer, msg, reliable)

# ---------------------------------------------------------------- member

# A member holds the authority's rocks while its own ship is in the dive cutscene: the stock spawner keeps the
# cutscene corridor clear, the authority's field doesn't, and the ship would plough through it at dive speed.
func _ready_for(from, cell) -> bool:
	return role == "member" and cell != null and cell.authority() == from and not _inCutscene()

func _inCutscene() -> bool:
	var ship = net.localShip
	return ship != null and is_instance_valid(ship) and ship.get("cutscene") == true

func _onSpawn(from, msg):
	var cell = _cell()
	if (held.size() > 0 and not replaying) or not _ready_for(from, cell) or msg.get("g", 0) > _gen(cell):
		held.append([from, msg])
		return
	# an older generation is applied anyway (dropping it would lose the rock); its first r.u corrects the offset
	if msg.get("first", false):
		snapSeen = {}
	for rc in msg.get("l", []):
		if not _validRecipe(rc):
			Debug.l("COOP: RS dropped malformed recipe from %s" % from)
			continue
		var id = rc[0]
		if snapSeen != null:
			snapSeen[id] = true
		if tracked.has(id):
			var t = tracked[id]
			t.p = rc[3]
			t.r = rc[4]
			t.v = rc[5]
			t.w = rc[6]
			t.at = _ms()
		elif not bodies.has(id):
			_build(rc)
	if msg.get("last", false) and snapSeen != null:
		var pruned = 0
		for id in tracked.keys():
			if not snapSeen.has(id):
				if is_instance_valid(tracked[id].n):
					Tool.remove(tracked[id].n)
				tracked.erase(id)
				pruned += 1
		Debug.l("COOP: RS snapshot from %s applied: %d tracked, %d pruned" % [from, tracked.size(), pruned])
		snapSeen = null
		if puppetProbe:
			_probeShips()

func _onDespawn(from, msg):
	var cell = _cell()
	if (held.size() > 0 and not replaying) or not _ready_for(from, cell):
		held.append([from, msg])   # keep order with spawns still waiting
		return
	var l = msg.get("l")
	if not (l is Array):
		return
	for id in l:
		if tracked.has(id):
			if is_instance_valid(tracked[id].n):
				Tool.remove(tracked[id].n)
			tracked.erase(id)

func _onUpdate(from, msg):
	var cell = _cell()
	if not _ready_for(from, cell) or msg.get("g", 0) != _gen(cell):
		return
	var ids = msg.get("i")
	var f = msg.get("f")
	if not (ids is PoolStringArray and f is PoolRealArray and f.size() == ids.size() * 6):
		return
	var now = localSampleMs(from, msg.get("ts", -1))
	var i = 0
	for id in ids:
		if tracked.has(id):
			var t = tracked[id]
			t.p = Vector2(f[i], f[i + 1])
			t.r = f[i + 2]
			t.v = Vector2(f[i + 3], f[i + 4])
			t.w = f[i + 5]
			t.at = now
		i += 6

func _memberTick(delta, cell):
	fresh.clear()
	gone.clear()
	if held.size() > 0:
		var auth = cell.authority()
		var pending = held
		held = []
		replaying = true
		for h in pending:
			if h[0] != auth:
				continue   # from an authority we no longer follow
			if h[1].t == "r.d":
				_onDespawn(h[0], h[1])
			else:
				_onSpawn(h[0], h[1])
		replaying = false
	_correct()

# Pull every tracked copy toward its owner's last reported state. Members track the authority's rocks; the authority
# tracks rocks a player owns (M4). A copy whose claim is pending here (Own sets `hold`) is left alone.
func _correct():
	var now = _ms()
	for id in tracked:
		var t = tracked[id]
		var n = t.n
		if not is_instance_valid(n) or t.get("hold", false):
			continue
		var age = (now - t.at) / 1000.0
		if age > MAX_EXTRAPOLATION:
			continue   # stream stalled: let it coast rather than freeze it
		var target = t.p + t.v * age
		var targetRot = t.r + t.w * age
		var err = target - n.global_position
		var rerr = wrapf(targetRot - n.global_rotation, - PI, PI)
		if err.length() > SNAP_DISTANCE or abs(rerr) > SNAP_ANGLE:
			n.global_transform = Transform2D(targetRot, target)
			n.reset_physics_interpolation()
			n.linear_velocity = t.v
			n.angular_velocity = t.w
		else:
			var lv = t.v + err * CORRECTION_GAIN
			var av = t.w + rerr * CORRECTION_GAIN
			if lv.distance_squared_to(n.linear_velocity) > 0.25:
				n.linear_velocity = lv
			if abs(av - n.angular_velocity) > 0.005:
				n.angular_velocity = av

# ---------------------------------------------------------------- dev probe: rocks built onto ships

func _ships() -> Array:
	var out = []
	if net.localShip != null and is_instance_valid(net.localShip):
		out.append(net.localShip)
	for id in net.peers:
		var pp = net._puppetOf(id)
		if pp != null:
			out.append(pp)
	return out

func _probeShips():
	for ship in _ships():
		var best = null
		var bestId = ""
		for id in tracked:
			var n = tracked[id].n
			if is_instance_valid(n):
				var gap = n.global_position.distance_to(ship.global_position) - n.estimatedRadius
				if best == null or gap < best:
					best = gap
					bestId = id
		Debug.l("COOP: RS probe ship '%s' puppet=%s: nearest tracked rock %s, centre gap minus rock radius %.0f px" % [ship.name, ship.has_meta("dvnet_puppet"), bestId, best if best != null else -1])
		if not ship.is_connected("damageImpact", self, "_onProbeImpact"):
			ship.connect("damageImpact", self, "_onProbeImpact", [ship])
	probeUntil = OS.get_ticks_msec() + 20000

func _onProbeImpact(power, point, delta, ship):
	if OS.get_ticks_msec() < probeUntil and power > 50:
		Debug.l("COOP: RS probe impact on '%s' puppet=%s power=%.0f at %s" % [ship.name, ship.has_meta("dvnet_puppet"), power, CurrentGame.globalCoords(point)])

# ---------------------------------------------------------------- logging

func _nearest(pool: Dictionary, at: Vector2, k: int) -> Array:
	var best = []
	for id in pool:
		var node = pool[id] if not (pool[id] is Dictionary) else pool[id].n
		if not is_instance_valid(node):
			continue
		best.append([node.global_position.distance_to(at), id, node.global_position])
	best.sort_custom(self, "_byFirst")
	var out = []
	for e in best.slice(0, min(k, best.size()) - 1) if best.size() > 0 else []:
		var g = CurrentGame.globalCoords(e[2])
		out.append("%s@%.0f,%.0f" % [e[1], g.x, g.y])
	return out

func _byFirst(a, b):
	return a[0] < b[0]

func _logState():
	# ms = wall clock, so lines from different machines can be lined up to the millisecond
	var line = "COOP: RS role=%s ms=%d bodies=%d rocks=%d tracked=%d" % [role, OS.get_system_time_msecs(), bodies.size(), rocks.size(), tracked.size()]
	if role == "authority":
		line += " recv=%d sent s=%d d=%d u=%d deferred=%d up=%.1f kB/s" % [receivers.size(), sent.s, sent.d, sent.u, sent.defer, sent.bytes / 1000.0 / logEvery]
		for peer in receivers:
			var at = _receiverPos(peer)
			if at != null:
				line += " | near[%s]=%s" % [peer, PoolStringArray(_nearest(rocks, at, 3)).join(" ")]
	elif role == "member" and net.localShip != null and is_instance_valid(net.localShip):
		line += " | near[me]=%s" % PoolStringArray(_nearest(tracked, net.localShip.global_position, 3)).join(" ")
	Debug.l(line)
	sent = {"s": 0, "d": 0, "u": 0, "bytes": 0, "defer": 0}
	if screenDump and role != "solo":
		_logScreen()

# Screen position of every rock in view, for matching screenshots between machines: screen = ct * local position,
# in canvas px (vp=); scale by window px / vp for a screenshot.
func _logScreen():
	var vp = get_viewport()
	var ct = vp.canvas_transform
	var size = vp.get_visible_rect().size   # the canvas size ct maps into (the window may stretch it)
	var out = []
	for pool in [rocks, tracked]:
		for id in pool:
			var node = pool[id] if not (pool[id] is Dictionary) else pool[id].n
			if not is_instance_valid(node):
				continue
			var sp = ct.xform(node.global_position)
			if sp.x >= 0 and sp.y >= 0 and sp.x < size.x and sp.y < size.y:
				var g = CurrentGame.globalCoords(node.global_position)
				out.append("%s@%.0f,%.0f>%.0f,%.0f" % [id, g.x, g.y, sp.x, sp.y])
	Debug.l("COOP: RS screen ms=%d vp=%.0fx%.0f n=%d %s" % [OS.get_system_time_msecs(), size.x, size.y, out.size(), PoolStringArray(out).join(" ")])
