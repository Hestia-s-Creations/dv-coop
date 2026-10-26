extends Node

# Own: who may simulate, move, damage and consume each rock in a cell (M4). Design: docs/M4-OWNERSHIP.md.
#
# The cell authority owns every rock by default and streams it (RockSync r.u). A player takes a rock by touching it
# (claw, drone, hold, MPU): o.req -> the authority grants in arrival order (o.ok + o.chg) or denies (o.no). The owner
# simulates it with the stock code and streams it to every member with o.u; everyone else, the authority included,
# keeps a tracked copy corrected toward that stream. Release hands it back (o.rel). Every owner change bumps the
# rock's epoch; a message based on an older epoch is dropped. Alone (no cell), nothing here runs: the stock game
# decides.

const CLAIM_TIMEOUT = 0.5      # s without an answer counts as a deny
const STREAM_HZ = 20.0         # o.u rate for rocks a player owns
const CONSERVE_EVERY = 30.0    # s between conservation log lines (authority)
const TOMB_SECONDS = 30.0
const OWNER_SILENT = 1.2       # s without an o.u from a player who owns rocks: it's gone, take them back

signal denied(id, reason)      # our claim on id was refused (or timed out); whoever touched it lets go
signal granted(id)

var net = null   # CoopNet

var owners = {}        # id -> peer id of the owner (absent = the cell authority)
var epoch = {}        # id -> int
var pending = {}      # member: id -> {at (s), why}
var mine = {}         # member: id -> node, rocks this machine owns (not as authority)
var heldHere = {}     # authority: id -> why, rocks the authority's own player is touching
var tomb = {}         # authority: id -> time (s) it was consumed or fractured
var reasons = {}      # id -> {why: true}: which local systems touch it (claw, hold, mpu, ...); released when empty
var holdRetry = {}    # id -> ship: a hold entry waiting for our claim; re-run when granted
var born = []         # member: ids of rocks born in our field (fracture shards of rocks we own), sent next tick
var fractured = {}    # member: ids of rocks we owned that started fracturing, sent with the next o.new
var fractureIds = {}  # authority: parents tombstoned by o.new (their exit counts as a fracture)
var dmgQueue = {}     # owner peer -> [[id, epoch, kind, amount, point, delta], ...]
var streamAccum = 0.0
var conserveAccum = 0.0
var role = "solo"     # mirrors RockSync's role
var lastAuth = -1     # member: the authority we last reported our rocks to (o.list)
var heard = {}        # authority: peer -> time (s) of its last o.u, or of our last grant to it
var told = {}         # authority: members we've sent the ownership table to
# gate evidence (5 s lines): beam damage forwarded / applied, bullet contacts applied / suppressed, per rock id
var dmgStats = {}     # id -> {fwd_n, fwd_e, app_n, app_e, bul_app, bul_fx}
var dmgLogAccum = 0.0

func stat(id, key, amount = 1.0):
	if not dmgStats.has(id):
		dmgStats[id] = {}
	dmgStats[id][key] = dmgStats[id].get(key, 0.0) + amount

# conservation (authority): every rock that entered and left this field, by reason
var cons = {"born": 0, "gone": 0, "gone_by": {}, "eaten": {}}
var eatenIds = {}     # id -> true for rocks whose exit is an o.eat (so the exit is not counted as a despawn)

func _ready():
	name = "Own"
	for t in ["o.req", "o.ok", "o.no", "o.chg", "o.u", "o.rel", "d.ev", "o.list", "o.eat", "o.new", "b.new"]:
		net.on(t, self, "_on_" + t.replace(".", "_"))
	call_deferred("_hook")

func _hook():
	var rs = _rs()
	if rs != null:
		rs.connect("rock_born", self, "_onRockBorn")
		rs.connect("body_born", self, "_onBodyBorn")
		rs.connect("rock_gone", self, "_onRockGone")

func _rs():
	return net.get_node_or_null("RockSync")

func _cell():
	var c = net.get_node_or_null("Cell")
	return c if c != null and c.has_method("inCell") else null

func _now() -> float:
	return OS.get_ticks_msec() / 1000.0

func _isAuthority() -> bool:
	var c = _cell()
	return c != null and c.inCell() and c.isAuthority()

func _inCell() -> bool:
	var c = _cell()
	return c != null and c.inCell()

func ownerOf(id):
	var c = _cell()
	return owners.get(id, c.authority() if c != null else net.myId)

func epochOf(id) -> int:
	return epoch.get(id, 0)

func ownsHere(id) -> bool:
	if mine.has(id):
		return true
	return _isAuthority() and not owners.has(id)

# ---------------------------------------------------------------- touch / release (called by the ext seams)

# A local system touched `node`. Returns true when this machine may act on it now (it owns it), false otherwise.
# A false for a tracked rock means a claim is in flight; `granted` or `denied` follows.
func touch(node, why) -> bool:
	if not _inCell() or node == null or not node.has_meta("dvnet"):
		return true
	var id = node.get_meta("dvnet")
	if not reasons.has(id):
		reasons[id] = {}
	reasons[id][why] = true
	if _isAuthority():
		if owners.has(id):
			reasons.erase(id)
			emit_signal("denied", id, "held")
			return false
		heldHere[id] = why
		return true
	if mine.has(id):
		return true
	if pending.has(id):
		return false
	if not node.has_meta("dvnet_tracked"):
		return true   # not a replicated rock (an oddity, our own debris): stock behaviour
	var rs = _rs()
	var t = rs.trackedState(id)
	if t != null:
		t.hold = true   # optimistic: our system acts on our copy, correction paused
	pending[id] = {"at": _now(), "why": why}
	var c = _cell()
	net.send(c.authority(), {"t": "o.req", "id": id, "e": epochOf(id), "why": why,
		"p": node.global_position, "r": node.global_rotation, "v": node.linear_velocity, "w": node.angular_velocity}, true)
	Debug.l("COOP: OWN claim %s (%s) e=%d" % [id, why, epochOf(id)])
	return false

# The local system let go of `node`.
func untouch(node, why):
	if node == null or not is_instance_valid(node) or not node.has_meta("dvnet"):
		return
	var id = node.get_meta("dvnet")
	if reasons.has(id):
		reasons[id].erase(why)
		if not reasons[id].empty():
			return   # another local system still touches it (e.g. the claw fed it into the hold)
		reasons.erase(id)
	if heldHere.has(id):
		heldHere.erase(id)
		return
	if pending.has(id):
		pending.erase(id)
		_resumeCorrection(id)
		# a grant may still arrive; _on_o_ok answers it with an immediate release
		return
	if mine.has(id):
		_release(id, node, why)

func _release(id, node, why):
	mine.erase(id)
	var c = _cell()
	var e = epochOf(id)
	net.send(c.authority(), {"t": "o.rel", "id": id, "e": e, "why": why,
		"p": node.global_position, "r": node.global_rotation, "v": node.linear_velocity, "w": node.angular_velocity,
		"te": node.get("totalEnergy") if node.get("totalEnergy") != null else 0.0}, true)
	_rs().track(id, node, node.global_position, node.global_rotation, node.linear_velocity, node.angular_velocity)
	Debug.l("COOP: OWN release %s (%s) e=%d" % [id, why, e])

func _resumeCorrection(id):
	var t = _rs().trackedState(id)
	if t != null:
		t.erase("hold")

# ---------------------------------------------------------------- cargo hold and consumption (hooks for ext/ship-ctrl.gd)

static func _isOtherPlayers(body) -> bool:
	return body.has_meta("dvnet_puppet") or body.has_meta("dvnet_mirror")

# Stock processEnteringCargoBay is about to count `body` into `ship`'s hold. False: don't count it (yet).
func holdEnter(ship, body) -> bool:
	if body == null or not is_instance_valid(body):
		return false
	if _isOtherPlayers(body):
		return false   # never scoop another player's ship, pod or drone
	if not _inCell() or not body.has_meta("dvnet") or not _rs().isRock(body):
		return true
	var ok = touch(body, "hold")
	if not ok and pending.has(body.get_meta("dvnet")):
		holdRetry[body.get_meta("dvnet")] = ship
	return ok

# Stock processExitingCargoBay just ran for `body`.
func holdExit(ship, body):
	if body == null or not is_instance_valid(body) or not body.has_meta("dvnet"):
		return
	holdRetry.erase(body.get_meta("dvnet"))
	if not ship.cargo.has(body):
		untouch(body, "hold")

# Stock claimCargo is about to turn `ship`'s hold into ship-state numbers and free the bodies.
func beforeClaimCargo(ship):
	for item in ship.cargo:
		if is_instance_valid(item) and item.has_meta("dvnet") and _rs().isRock(item):
			eat(item, "claimCargo")

# `node`, a rock we own, is about to be freed into ship state (claimCargo, MPU). Tell the authority once.
func eat(node, why):
	if not _inCell() or node == null or not node.has_meta("dvnet"):
		return
	var id = node.get_meta("dvnet")
	var comp = node.getComposition().duplicate() if node.has_method("getComposition") else {}
	reasons.erase(id)
	if _isAuthority():
		if owners.has(id):
			Debug.l("COOP: OWN refusing to eat %s: owned by %s" % [id, owners[id]])
			return
		heldHere.erase(id)
		_tombstone(id, comp, why)
		return
	if not mine.has(id):
		Debug.l("COOP: OWN eat %s (%s) but we don't own it" % [id, why])
		return
	mine.erase(id)
	net.send(_cell().authority(), {"t": "o.eat", "id": id, "e": epochOf(id), "c": comp, "why": why}, true)
	Debug.l("COOP: OWN eat %s (%s) %s" % [id, why, comp])

func _tombstone(id, comp, why):
	tomb[id] = _now()
	eatenIds[id] = true
	for k in comp:
		cons.eaten[k] = cons.eaten.get(k, 0.0) + float(comp[k])
	Debug.l("COOP: OWN eaten %s (%s) %s" % [id, why, comp])

func _on_o_eat(from, msg):
	if not _isAuthority():
		return
	var id = str(msg.get("id"))
	if owners.get(id) != from or int(msg.get("e", -1)) != epochOf(id):
		Debug.l("COOP: OWN stale eat %s from %s (owner %s e=%d)" % [id, from, owners.get(id), epochOf(id)])
		return
	owners.erase(id)
	var comp = msg.get("c", {})
	if not comp is Dictionary:
		comp = {}
	_eatAudit(id, _rs().nodeOf(id), comp)
	_tombstone(id, comp, str(msg.get("why")))
	var node = _rs().untrack(id)
	if node != null:
		Tool.remove(node)   # its exit sends r.d to every member that knows it

# Ore audit (gate 10): the composition we handed the owner (our copy never sees its processing) against what it
# reports at the eat. An MPU only strips filler into reactive mass, so every other key must come back unchanged.
func _eatAudit(id, node, out):
	var into = node.getComposition() if node != null and node.has_method("getComposition") else null
	if into == null:
		Debug.l("COOP: OWN eat-audit %s in=? out=%s" % [id, out])
		return
	var filler = node.get("filler") if node.get("filler") != null else "H2O"
	var processed = {}
	var ok = true
	for k in into:
		var d = float(into[k]) - float(out.get(k, 0.0))
		if abs(d) > 0.001:
			processed[k] = d
			if k != filler or d < 0:
				ok = false
	for k in out:
		if not into.has(k):
			ok = false
	Debug.l("COOP: OWN eat-audit %s in=%s out=%s processed=%s %s" % [id, into, out, processed, "OK" if ok else "BAD"])

# ---------------------------------------------------------------- shards of rocks a member owns (o.new)

# Member: rocks we owned started fracturing and their shards were spawned here (stock code). Hand them over.
func _sendBorn():
	for id in mine.keys():
		var n = mine[id]
		if is_instance_valid(n) and n.get("fracturing") == true and not fractured.has(id):
			fractured[id] = true
	if born.empty() and fractured.empty():
		return
	var rs = _rs()
	var l = []
	for id in born:
		var rc = rs.recipeOf(id)
		if rc != null:
			l.append(rc)
	var parents = fractured.keys()
	net.send(_cell().authority(), {"t": "o.new", "l": l, "parents": parents}, true)
	for rc in l:
		rs.handOver(rc[0])
	for id in parents:
		mine.erase(id)
		reasons.erase(id)
	Debug.l("COOP: OWN o.new: %d shards, parents %s" % [l.size(), parents])
	born.clear()
	fractured.clear()

func _on_o_new(from, msg):
	if not _isAuthority():
		return
	var rs = _rs()
	for pid in msg.get("parents", []):
		var id = str(pid)
		if owners.get(id) != from:
			continue
		owners.erase(id)
		tomb[id] = _now()
		fractureIds[id] = true
		var n = rs.untrack(id)
		if n != null:
			Tool.remove(n)   # members see it vanish (r.d) as the shards arrive
	var built = 0
	for rc in msg.get("l", []):
		if rs.buildSimulated(rc) != null:
			built += 1
	Debug.l("COOP: OWN o.new from %s: %d shards built, parents %s" % [from, built, msg.get("parents")])

# ---------------------------------------------------------------- bullets (b.new)
#
# A bullet is a physics body; its push and its kinetic damage come from contact, so it can't be forwarded as an event.
# The shooter announces it (b.new) and every machine runs a ballistic copy. Damage on a rock counts only where the rock
# is owned: on everyone else the rock is a tracked copy, which takes effects only. A bullet that a puppet's mass driver
# spawns here (the stock tick replaying the owner's fire) is removed: the owner's b.new replaces it. Copies carry no
# shooter, so hostility is applied once, by the Ships track on the target's owner.

const BULLET_PREFIX = "res://weapons/projectiles/"

func _onBodyBorn(id, node):
	if not _inCell() or node.get("shooter") == null or node.has_meta("dvnet_bullet"):
		return
	var shooter = node.shooter
	if not is_instance_valid(shooter):
		return
	if shooter.has_meta("dvnet_puppet") or shooter.has_meta("dvnet_mirror"):
		node.set_meta("dvnet_bullet", "replaced")
		node.collision_layer = 0
		node.collision_mask = 0
		Tool.deferCallInPhysics(Tool, "remove", [node])   # not from inside its own tree-entered callback
		return
	if shooter != net.localShip or not node.filename.begins_with(BULLET_PREFIX):
		return
	var li = node.get("lingeringImpulse")
	var msg = {"t": "b.new", "id": id, "s": node.filename, "p": node.global_position, "r": node.global_rotation,
		"v": node.linear_velocity, "li": li if li is Vector2 else Vector2(), "g": _rs()._gen(_cell())}
	for p in _cell().members():
		if p != net.myId:
			net.send(p, msg, true)

func _on_b_new(from, msg):
	var c = _cell()
	if c == null or not c.inCell() or int(msg.get("g", -1)) != _rs()._gen(c):
		return
	var path = str(msg.get("s", ""))
	if not path.begins_with(BULLET_PREFIX) or not path.ends_with(".tscn") or ".." in path or not ResourceLoader.exists(path):
		Debug.l("COOP: OWN dropped b.new from %s: %s is not a projectile scene" % [from, path])
		return
	var rs = _rs()
	if rs.field == null or not (msg.get("p") is Vector2) or not (msg.get("v") is Vector2):
		return
	var b = load(path).instance()
	b.set_meta("dvnet", str(msg.get("id")))
	b.set_meta("dvnet_bullet", from)
	b.shooter = null
	b.global_position = msg.p
	b.rotation = float(msg.get("r", 0.0))
	b.linear_velocity = msg.v
	if msg.get("li") is Vector2 and msg.li != Vector2():
		b.lingeringImpulse = msg.li
	rs.field.add_child(b)

# ---------------------------------------------------------------- authority: arbitration

func _on_o_req(from, msg):
	if not _isAuthority():
		net.send(from, {"t": "o.no", "id": msg.get("id"), "why": "stale", "owner": -1, "e": -1}, true)
		return
	var id = str(msg.get("id"))
	var rs = _rs()
	var node = rs.nodeOf(id)
	var reason = ""
	if tomb.has(id):
		reason = "tomb"
	elif node == null:
		reason = "gone"
	elif node.get("fracturing") == true:
		reason = "fracturing"
	elif owners.has(id) and owners[id] != from:
		reason = "held"
	elif heldHere.has(id):
		reason = "held"
	if reason != "":
		net.send(from, {"t": "o.no", "id": id, "why": reason, "owner": ownerOf(id), "e": epochOf(id)}, true)
		Debug.l("COOP: OWN deny %s to %s (%s)" % [id, from, reason])
		return
	if owners.get(id) == from:
		return   # duplicate request; the earlier grant stands
	var e = epochOf(id) + 1
	epoch[id] = e
	owners[id] = from
	heard[from] = _now()
	rs.track(id, node, node.global_position, node.global_rotation, node.linear_velocity, node.angular_velocity)
	net.send(from, {"t": "o.ok", "id": id, "e": e,
		"p": node.global_position, "r": node.global_rotation, "v": node.linear_velocity, "w": node.angular_velocity}, true)
	_broadcast({"t": "o.chg", "id": id, "owner": from, "e": e}, from)
	Debug.l("COOP: OWN grant %s to %s e=%d (%s)" % [id, from, e, msg.get("why")])

func _on_o_rel(from, msg):
	if not _isAuthority():
		return
	var id = str(msg.get("id"))
	if owners.get(id) != from or int(msg.get("e", -1)) != epochOf(id):
		Debug.l("COOP: OWN stale release %s from %s e=%s (owner %s e=%d)" % [id, from, msg.get("e"), owners.get(id), epochOf(id)])
		return
	var rs = _rs()
	var node = rs.untrack(id)
	owners.erase(id)
	var e = epochOf(id) + 1
	epoch[id] = e
	if node != null:
		node.global_transform = Transform2D(float(msg.r), msg.p)
		node.reset_physics_interpolation()
		node.linear_velocity = msg.v
		node.angular_velocity = float(msg.w)
		if node.get("totalEnergy") != null:
			node.totalEnergy = max(node.totalEnergy, float(msg.get("te", 0.0)))
	_broadcast({"t": "o.chg", "id": id, "owner": net.myId, "e": e}, -1)
	Debug.l("COOP: OWN released %s by %s e=%d" % [id, from, e])

func _broadcast(msg, except):
	var c = _cell()
	for p in c.members():
		if p != net.myId and p != except:
			net.send(p, msg, true)

# ---------------------------------------------------------------- member: answers

func _on_o_ok(from, msg):
	var id = str(msg.get("id"))
	var e = int(msg.get("e", 0))
	epoch[id] = e
	owners[id] = net.myId
	if not pending.has(id):
		# timed out or let go meanwhile: give it straight back
		var node = _rs().nodeOf(id)
		if node != null:
			mine[id] = node
			_release(id, node, "late")
		return
	pending.erase(id)
	var node = _rs().untrack(id)
	if node == null:
		return
	mine[id] = node
	if node.global_position.distance_to(msg.p) > 400.0:
		node.global_transform = Transform2D(float(msg.r), msg.p)
		node.reset_physics_interpolation()
	Debug.l("COOP: OWN granted %s e=%d" % [id, e])
	emit_signal("granted", id)
	if holdRetry.has(id):
		var ship = holdRetry[id]
		holdRetry.erase(id)
		if is_instance_valid(ship) and is_instance_valid(node):
			ship.processEnteringCargoBay(node)   # the stock entry we held back, now on a rock we own

func _on_o_no(from, msg):
	var id = str(msg.get("id"))
	if int(msg.get("e", -1)) >= 0:
		epoch[id] = int(msg.e)
	if int(msg.get("owner", -1)) >= 0:
		owners[id] = int(msg.owner)
	if pending.has(id):
		pending.erase(id)
		reasons.erase(id)
		holdRetry.erase(id)
		_resumeCorrection(id)
		Debug.l("COOP: OWN denied %s (%s)" % [id, msg.get("why")])
		emit_signal("denied", id, str(msg.get("why")))

func _on_o_chg(from, msg):
	var id = str(msg.get("id"))
	var e = int(msg.get("e", 0))
	if e < epochOf(id):
		return
	epoch[id] = e
	var c = _cell()
	if int(msg.owner) == c.authority():
		owners.erase(id)
	else:
		owners[id] = int(msg.owner)
	if mine.has(id) and int(msg.owner) != net.myId:
		# taken from us (the authority thought we were gone): back to a tracked copy, and whoever holds it lets go
		var n = mine[id]
		mine.erase(id)
		reasons.erase(id)
		if is_instance_valid(n):
			_rs().track(id, n, n.global_position, n.global_rotation, n.linear_velocity, n.angular_velocity)
		Debug.l("COOP: OWN %s revoked by the authority e=%d" % [id, e])
		emit_signal("denied", id, "revoked")

# ---------------------------------------------------------------- streams

func _on_o_u(from, msg):
	heard[from] = _now()
	var l = msg.get("l")
	if not (l is Array):
		return
	var rs = _rs()
	var at = rs.localSampleMs(from, msg.get("ts", -1))
	for it in l:
		if not (it is Array) or it.size() != 6:
			continue
		var id = str(it[0])
		if ownerOf(id) != from or int(it[1]) != epochOf(id):
			continue
		rs.updateTracked(id, it[2], float(it[3]), it[4], float(it[5]), at)

# Positions of the rocks this member owns, to everyone else in the cell. (Angular velocity rides in r as rot only;
# the tracked copy's angular velocity is corrected toward 0 extra spin, which is fine at 20 Hz.)
func _stream():
	if mine.empty():
		return
	var l = []
	for id in mine.keys():
		var n = mine[id]
		if not is_instance_valid(n):
			mine.erase(id)
			continue
		l.append([id, epochOf(id), n.global_position, n.global_rotation, n.linear_velocity, n.angular_velocity])
	if l.empty():
		return
	var c = _cell()
	var msg = {"t": "o.u", "ts": OS.get_system_time_msecs(), "l": l}
	for p in c.members():
		if p != net.myId:
			net.send(p, msg, false)

# ---------------------------------------------------------------- damage events (beams on rocks we don't own)

func forwardDamage(node, kind, amount, point, delta):
	if not _inCell() or not node.has_meta("dvnet"):
		return
	var id = node.get_meta("dvnet")
	var to = ownerOf(id)
	if to == net.myId:
		return
	var local = node.global_transform.affine_inverse().xform(point) if point is Vector2 else Vector2()
	stat(id, "fwd_n")
	stat(id, "fwd_e", float(amount))
	if not dmgQueue.has(to):
		dmgQueue[to] = []
	dmgQueue[to].append([id, epochOf(id), kind, float(amount), local, float(delta) if delta != null else 0.0])

func _flushDamage():
	for to in dmgQueue:
		if not dmgQueue[to].empty():
			net.send(to, {"t": "d.ev", "l": dmgQueue[to]}, true)
	dmgQueue.clear()

func _on_d_ev(from, msg):
	var l = msg.get("l")
	if not (l is Array):
		return
	var rs = _rs()
	for it in l:
		if not (it is Array) or it.size() != 6:
			continue
		var id = str(it[0])
		if not ownsHere(id):
			continue   # it moved on; the sender learns the new owner from o.chg
		var node = rs.nodeOf(id)
		if node == null:
			continue
		stat(id, "app_n")
		stat(id, "app_e", float(it[3]))
		var point = node.global_transform.xform(it[4])
		var d = it[5] if it[5] > 0 else null
		match str(it[2]):
			"e":
				node.applyEnergyDamage(it[3], point, d if d != null else 1.0 / 60.0)
			"k":
				node.applyKineticDamage(it[3], point, d)
			"m":
				node.applyEmpDamage(it[3], point, d if d != null else 1.0 / 60.0)

func _logDamage():
	var rs = _rs()
	for id in dmgStats:
		var st = dmgStats[id]
		var n = rs.nodeOf(id)
		var te = n.get("totalEnergy") if n != null and n.get("totalEnergy") != null else -1.0
		Debug.l("COOP: OWN dmg %s owner=%s here=%s fwd=%d/%.0f applied=%d/%.0f bullet applied=%d fx=%d totalEnergy=%.1f" % [
			id, ownerOf(id), "owned" if ownsHere(id) else "copy", st.get("fwd_n", 0), st.get("fwd_e", 0), st.get("app_n", 0),
			st.get("app_e", 0), st.get("bul_app", 0), st.get("bul_fx", 0), te])
	dmgStats.clear()

# ---------------------------------------------------------------- tick

func _physics_process(delta):
	if net == null or net.transport == net.Transport.NONE:
		return
	var want = "solo"
	if _inCell():
		want = "authority" if _isAuthority() else "member"
	if want != role:
		_changeRole(role, want)
	if role == "solo":
		return
	var now = _now()
	for id in pending.keys():
		if now - pending[id].at > CLAIM_TIMEOUT:
			pending.erase(id)
			_resumeCorrection(id)
			Debug.l("COOP: OWN claim %s timed out" % id)
			emit_signal("denied", id, "timeout")
	streamAccum += delta
	if streamAccum >= 1.0 / STREAM_HZ:
		streamAccum = 0.0
		_stream()
	_flushDamage()
	dmgLogAccum += delta
	if dmgLogAccum >= 5.0:
		dmgLogAccum = 0.0
		_logDamage()
	if role == "member":
		_reportOwned()
		_sendBorn()
	if role == "authority":
		_tellNewMembers()
		_reownLost()
		for id in tomb.keys():
			if now - tomb[id] > TOMB_SECONDS:
				tomb.erase(id)
		conserveAccum += delta
		if conserveAccum >= CONSERVE_EVERY:
			conserveAccum = 0.0
			_logConservation()

func _changeRole(from, to):
	Debug.l("COOP: OWN role %s -> %s (mine=%d owned-by-players=%d)" % [from, to, mine.size(), owners.size()])
	var rs = _rs()
	if from == "member" and to == "authority":
		# Handoff: we already know every owner from o.chg. RockSync just turned all our tracked copies into simulated
		# rocks; the ones a player owns go back to tracked (corrected toward that player's o.u). Our own become ours as
		# the authority. o.list from the members then confirms the table.
		for id in mine.keys():
			heldHere[id] = "promoted"
			owners.erase(id)
		mine.clear()
		for id in owners.keys():
			var n = rs.nodeOf(id)
			if n == null or owners[id] == net.myId:
				owners.erase(id)
				continue
			rs.track(id, n, n.global_position, n.global_rotation, n.linear_velocity, n.angular_velocity)
		pending.clear()
		Debug.l("COOP: OWN promoted: keeping %d player-owned rocks, %d held here" % [owners.size(), heldHere.size()])
	else:
		# rocks other players owned: they stay in our field at their last streamed state (RockSync keeps or promotes
		# them), so log where, for the holder-loss gates
		for id in owners.keys():
			if owners[id] != net.myId:
				var n = rs.nodeOf(id)
				if n != null:
					var g = CurrentGame.globalCoords(n.global_position)
					Debug.l("COOP: OWN keeps %s (owner %s gone from our cell) at %.0f,%.0f" % [id, owners[id], g.x, g.y])
		for id in mine.keys():
			var n = mine[id]
			if is_instance_valid(n) and to == "member":
				rs.track(id, n, n.global_position, n.global_rotation, n.linear_velocity, n.angular_velocity)
		mine.clear()
		pending.clear()
		heldHere.clear()
		owners.clear()
		epoch.clear()
	lastAuth = -1
	told.clear()
	heard.clear()
	role = to
	cons = {"born": 0, "gone": 0, "gone_by": {}, "eaten": {}}
	if to == "authority":
		cons.born = _liveRocks().size()   # baseline: everything already in the field

# ---------------------------------------------------------------- disconnect and handoff

# Authority: a member who joined after a rock changed hands never saw that o.chg; without it, it would ignore the
# owner's o.u (wrong sender) and its copy would coast. Send it the table once.
func _tellNewMembers():
	var members = _cell().members()
	for p in told.keys():
		if not (p in members):
			told.erase(p)
	for p in members:
		if p == net.myId or told.has(p):
			continue
		told[p] = true
		for id in owners:
			net.send(p, {"t": "o.chg", "id": id, "owner": owners[id], "e": epochOf(id)}, true)
		for id in heldHere:
			net.send(p, {"t": "o.chg", "id": id, "owner": net.myId, "e": epochOf(id)}, true)
		if not owners.empty():
			Debug.l("COOP: OWN told new member %s about %d player-owned rocks" % [p, owners.size()])

# Authority: a player who owns rocks has left the cell (quit, crashed, flew off). Its rocks come back to us at their
# last streamed state (the tracked copy is already there).
func _reownLost():
	var c = _cell()
	var members = c.members()
	var now = _now()
	var lost = {}
	for id in owners.keys():
		var p = owners[id]
		# gone from the cell, or silent: an owner streams o.u at STREAM_HZ for as long as it owns anything, so a crash
		# shows here well before the cell's own timeout drops it
		if p != net.myId and (not (p in members) or now - heard.get(p, now) > OWNER_SILENT):
			lost[id] = p
	if lost.empty():
		return
	var rs = _rs()
	for id in lost:
		var n = rs.untrack(id)
		owners.erase(id)
		var e = epochOf(id) + 1
		epoch[id] = e
		_broadcast({"t": "o.chg", "id": id, "owner": net.myId, "e": e}, -1)
		Debug.l("COOP: OWN reown %s from lost %s e=%d at %s" % [id, lost[id], e, CurrentGame.globalCoords(n.global_position) if n != null else "?"])

# Member: whenever the authority changes, tell the new one which rocks we own.
func _reportOwned():
	var c = _cell()
	var a = c.authority()
	if a == lastAuth:
		return
	lastAuth = a
	var l = []
	for id in mine:
		var n = mine[id]
		if is_instance_valid(n):
			l.append([id, epochOf(id), n.global_position, n.global_rotation, n.linear_velocity, n.angular_velocity])
	net.send(a, {"t": "o.list", "l": l}, true)
	if not l.empty():
		Debug.l("COOP: OWN o.list to %s: %d rocks" % [a, l.size()])

# Authority: a member's list of rocks it owns. Accept what we didn't know (it holds them, the stream proves it);
# drop table entries for that member that it no longer claims.
func _on_o_list(from, msg):
	if not _isAuthority():
		return
	var l = msg.get("l")
	if not (l is Array):
		return
	var rs = _rs()
	var claimed = {}
	for it in l:
		if not (it is Array) or it.size() != 6:
			continue
		var id = str(it[0])
		claimed[id] = true
		if owners.get(id) == from:
			continue
		var n = rs.nodeOf(id)
		if n == null or tomb.has(id) or (owners.has(id) and owners[id] != from):
			continue
		owners[id] = from
		epoch[id] = max(epochOf(id), int(it[1]))
		rs.track(id, n, it[2], float(it[3]), it[4], float(it[5]))
		_broadcast({"t": "o.chg", "id": id, "owner": from, "e": epochOf(id)}, from)
		Debug.l("COOP: OWN o.list adopts %s owned by %s e=%d" % [id, from, epochOf(id)])
	for id in owners.keys():
		if owners[id] == from and not claimed.has(id):
			var n = rs.untrack(id)
			owners.erase(id)
			epoch[id] = epochOf(id) + 1
			_broadcast({"t": "o.chg", "id": id, "owner": net.myId, "e": epochOf(id)}, -1)
			Debug.l("COOP: OWN o.list: %s no longer held by %s, back to the authority" % [id, from])
	Debug.l("COOP: OWN o.list from %s: %d rocks, table now %d player-owned" % [from, claimed.size(), owners.size()])

# ---------------------------------------------------------------- conservation (authority)

func _onRockBorn(id, node):
	if role == "authority":
		cons.born += 1
	elif role == "member" and not node.has_meta("dvnet_tracked"):
		born.append(id)   # only fracture spawns rocks on a member (its spawner is suspended)

const DISABLED_LAYER = 2147483648   # the MPU sets this collision layer on a rock just before freeing it

func _onRockGone(id, node):
	if role == "member" and mine.has(id):
		# a rock we own is leaving our field
		if node.get("fracturing") == true:
			mine.erase(id)
			fractured[id] = true
		elif node.collision_layer == DISABLED_LAYER and node.get("fracturing") != true:
			eat(node, "mpu")
		else:
			_release(id, node, "left-field")
		return
	if role != "authority":
		return
	if fractureIds.has(id):
		fractureIds.erase(id)
		cons.gone += 1
		cons.gone_by["fracture"] = cons.gone_by.get("fracture", 0) + 1
		return
	# the MPU and a fracturing asteroid both park the rock on this layer; only the first is an eat
	if node.collision_layer == DISABLED_LAYER and node.get("fracturing") != true and not eatenIds.has(id) and not owners.has(id):
		_tombstone(id, node.getComposition().duplicate() if node.has_method("getComposition") else {}, "mpu")
		heldHere.erase(id)
	cons.gone += 1
	var why = "despawn"
	if eatenIds.has(id):
		why = "eaten"
		eatenIds.erase(id)
	elif node.get("fracturing") == true:
		why = "fracture"
	cons.gone_by[why] = cons.gone_by.get(why, 0) + 1

# Every rock node in this field, streamed, player-owned or mid-fracture.
func _liveRocks() -> Dictionary:
	var rs = _rs()
	var out = {}
	for id in rs.bodies:
		var n = rs.bodies[id]
		if is_instance_valid(n) and rs.isRock(n):
			out[id] = n
	return out

func _logConservation():
	var all = _liveRocks()
	var live = all.size()
	var comp = {}
	var mass = 0.0
	for id in all:
		var n = all[id]
		mass += n.mass
		var c = n.getComposition() if n.has_method("getComposition") else {}
		for k in c:
			comp[k] = comp.get(k, 0.0) + c[k]
	var parts = []
	for k in comp:
		parts.append("%s=%.0f" % [k, comp[k]])
	var ok = (cons.born - cons.gone) == live
	Debug.l("COOP: OWN conserve born=%d gone=%d %s live=%d %s player-owned=%d mass=%.0f comp{%s} eaten{%s}" % [
		cons.born, cons.gone, cons.gone_by, live, "OK" if ok else "MISMATCH(%d)" % (cons.born - cons.gone - live),
		owners.size(), mass, PoolStringArray(parts).join(" "), cons.eaten])
