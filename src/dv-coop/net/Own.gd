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

signal denied(id, reason)      # our claim on id was refused (or timed out); whoever touched it lets go
signal granted(id)

var net = null   # CoopNet

var owner = {}        # id -> peer id of the owner (absent = the cell authority)
var epoch = {}        # id -> int
var pending = {}      # member: id -> {at (s), why}
var mine = {}         # member: id -> node, rocks this machine owns (not as authority)
var heldHere = {}     # authority: id -> why, rocks the authority's own player is touching
var tomb = {}         # authority: id -> time (s) it was consumed or fractured
var dmgQueue = {}     # owner peer -> [[id, epoch, kind, amount, point, delta], ...]
var streamAccum = 0.0
var conserveAccum = 0.0
var role = "solo"     # mirrors RockSync's role

# conservation (authority): every rock that entered and left this field, by reason
var cons = {"born": 0, "gone": 0, "gone_by": {}, "eaten": {}}
var eatenIds = {}     # id -> true for rocks whose exit is an o.eat (so the exit is not counted as a despawn)

func _ready():
	name = "Own"
	for t in ["o.req", "o.ok", "o.no", "o.chg", "o.u", "o.rel", "d.ev"]:
		net.on(t, self, "_on_" + t.replace(".", "_"))
	call_deferred("_hook")

func _hook():
	var rs = _rs()
	if rs != null:
		rs.connect("rock_born", self, "_onRockBorn")
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
	return owner.get(id, c.authority() if c != null else net.myId)

func epochOf(id) -> int:
	return epoch.get(id, 0)

func ownsHere(id) -> bool:
	if mine.has(id):
		return true
	return _isAuthority() and not owner.has(id)

# ---------------------------------------------------------------- touch / release (called by the ext seams)

# A local system touched `node`. Returns true when this machine may act on it now (it owns it), false otherwise.
# A false for a tracked rock means a claim is in flight; `granted` or `denied` follows.
func touch(node, why) -> bool:
	if not _inCell() or node == null or not node.has_meta("dvnet"):
		return true
	var id = node.get_meta("dvnet")
	if _isAuthority():
		if owner.has(id):
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
	elif owner.has(id) and owner[id] != from:
		reason = "held"
	elif heldHere.has(id):
		reason = "held"
	if reason != "":
		net.send(from, {"t": "o.no", "id": id, "why": reason, "owner": ownerOf(id), "e": epochOf(id)}, true)
		Debug.l("COOP: OWN deny %s to %s (%s)" % [id, from, reason])
		return
	if owner.get(id) == from:
		return   # duplicate request; the earlier grant stands
	var e = epochOf(id) + 1
	epoch[id] = e
	owner[id] = from
	rs.track(id, node, node.global_position, node.global_rotation, node.linear_velocity, node.angular_velocity)
	net.send(from, {"t": "o.ok", "id": id, "e": e,
		"p": node.global_position, "r": node.global_rotation, "v": node.linear_velocity, "w": node.angular_velocity}, true)
	_broadcast({"t": "o.chg", "id": id, "owner": from, "e": e}, from)
	Debug.l("COOP: OWN grant %s to %s e=%d (%s)" % [id, from, e, msg.get("why")])

func _on_o_rel(from, msg):
	if not _isAuthority():
		return
	var id = str(msg.get("id"))
	if owner.get(id) != from or int(msg.get("e", -1)) != epochOf(id):
		Debug.l("COOP: OWN stale release %s from %s e=%s (owner %s e=%d)" % [id, from, msg.get("e"), owner.get(id), epochOf(id)])
		return
	var rs = _rs()
	var node = rs.untrack(id)
	owner.erase(id)
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
	owner[id] = net.myId
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

func _on_o_no(from, msg):
	var id = str(msg.get("id"))
	if int(msg.get("e", -1)) >= 0:
		epoch[id] = int(msg.e)
	if int(msg.get("owner", -1)) >= 0:
		owner[id] = int(msg.owner)
	if pending.has(id):
		pending.erase(id)
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
		owner.erase(id)
	else:
		owner[id] = int(msg.owner)

# ---------------------------------------------------------------- streams

func _on_o_u(from, msg):
	var l = msg.get("l")
	if not (l is Array):
		return
	var rs = _rs()
	for it in l:
		if not (it is Array) or it.size() != 6:
			continue
		var id = str(it[0])
		if ownerOf(id) != from or int(it[1]) != epochOf(id):
			continue
		rs.updateTracked(id, it[2], float(it[3]), it[4], float(it[5]))

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
	var msg = {"t": "o.u", "l": l}
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
		var point = node.global_transform.xform(it[4])
		var d = it[5] if it[5] > 0 else null
		match str(it[2]):
			"e":
				node.applyEnergyDamage(it[3], point, d if d != null else 1.0 / 60.0)
			"k":
				node.applyKineticDamage(it[3], point, d)
			"m":
				node.applyEmpDamage(it[3], point, d if d != null else 1.0 / 60.0)

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
	if role == "authority":
		for id in tomb.keys():
			if now - tomb[id] > TOMB_SECONDS:
				tomb.erase(id)
		conserveAccum += delta
		if conserveAccum >= CONSERVE_EVERY:
			conserveAccum = 0.0
			_logConservation()

func _changeRole(from, to):
	Debug.l("COOP: OWN role %s -> %s (mine=%d owned-by-players=%d)" % [from, to, mine.size(), owner.size()])
	# M4 TODO (gates 3/4): re-own on disconnect, o.list on handoff. For now a role change resets the table.
	for id in mine.keys():
		var n = mine[id]
		if is_instance_valid(n) and to == "member":
			_rs().track(id, n, n.global_position, n.global_rotation, n.linear_velocity, n.angular_velocity)
	mine.clear()
	pending.clear()
	heldHere.clear()
	owner.clear()
	epoch.clear()
	role = to
	cons = {"born": 0, "gone": 0, "gone_by": {}, "eaten": {}}
	if to == "authority":
		cons.born = _liveRocks().size()   # baseline: everything already in the field

# ---------------------------------------------------------------- conservation (authority)

func _onRockBorn(id, node):
	if role == "authority":
		cons.born += 1

func _onRockGone(id, node):
	if role != "authority":
		return
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
		owner.size(), mass, PoolStringArray(parts).join(" "), cons.eaten])
