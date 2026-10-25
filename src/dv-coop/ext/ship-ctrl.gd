extends "res://ships/ship-ctrl.gd"

# dv-coop ship controller extension.
#
# Three control modes now exist on a ship:
#   playerControlled  (game)  input -> manualControl -> thrusterShedule
#   ai                (game)  aiControl -> thrusterShedule
#   netControlled     (mod)   thrusterShedule arrives over the wire; transform is
#                             corrected toward the owning machine's reported state.
#
# The local player's ship additionally publishes its thrusterShedule every frame
# (captureIntent) so the other machine's puppet fires the same thrusters. Systems that are not thrusters
# (weapons, claws, drone plants) fire outside the schedule (fireMatching -> node.fire), so their powers ride
# along in the same intent under "_f" (node path -> power), and turret aim and fire under "_pdt".

var coopExtensionActive = true

var netControlled = false
var netSchedule = null     # {thrusterName: [power, Vector2|null]} last received
var netState = null        # {p: Vector2 global, r: float, v: Vector2, w: float, at: msec received}
var netFired = {}          # puppet: node path -> power, non-thruster systems the owner is firing
var netPdt = {}            # puppet: turret path -> [pivot rotation, fire power]
var netDying = false       # puppet: its owner's ship is exploding (s.die)
var coopTurrets = null     # owner: turrets found once the ship is set up
var coopIntent = null      # authority: this NPC's last intent, streamed to mirrors by Npc.gd

export var netSnapDistance = 400.0
export var netSnapAngle = 0.6
export var netCorrectionGain = 4.0
export var netMaxExtrapolation = 0.25

# Godot 3 calls _ready, _process and _physics_process on every level of a script chain by itself (base first
# for _ready, derived first for _process). Never call them with a leading dot here: until 2026-10-25 this file
# did, and stock ship-ctrl ran its _ready and _process twice per frame on every ship (measured: 2.0 -> 1.0 runs).
func _ready():
	Debug.l("COOP: ship-ctrl extension active on '%s' (playerControlled=%s ai=%s net=%s)" % [name, playerControlled, ai, netControlled])

func _coopNet():
	if ModLoader.has_meta("dvcoop"):
		return ModLoader.get_meta("dvcoop")
	return null

# runs before the stock _process (Godot 3 order: this level first)
func _process(delta):
	if netControlled:
		autopilot = false
		if netSchedule != null:
			var s = netSchedule.duplicate(true)
			netFired = s.get("_f", {})
			netPdt = s.get("_pdt", {})
			s.erase("_f")
			s.erase("_pdt")
			thrusterShedule = s

# Called by the stock _process after `fired` is reset and the controls ran, before the stock zeroes every
# system nobody fired this frame.
func executeThrusterFire(solve: bool, delta: float):
	if netControlled:
		for path in netFired:
			var node = get_node_or_null(NodePath(path))
			if node != null and node.has_method("fire"):
				node.fire(netFired[path])
				fired[node] = netFired[path]
		if netFired.size() > 0:
			_coopCount("replayed", netFired.size())
	elif playerControlled or has_meta("dvnet_npc"):
		if playerControlled and Engine.has_meta("dvcoop_dev_fireall"):
			# dev (Npc --coop-dev-fireall): hold every non-thruster command, so puppets have systems to replay
			for cmd in Engine.get_meta("dvcoop_dev_fireall"):
				fireMatching(cmd, 1.0)
		var intent = thrusterShedule.duplicate()
		intent["_f"] = _coopFired()
		intent["_pdt"] = _coopTurretStates()
		if playerControlled:
			var net = _coopNet()
			if net != null:
				net.captureIntent(self, intent)
		else:
			coopIntent = intent
	.executeThrusterFire(solve, delta)

func _coopFired() -> Dictionary:
	var out = {}
	for node in fired:
		if fired[node] != 0 and is_instance_valid(node) and not (node.name in thrusters):
			out[str(get_path_to(node))] = fired[node]
	return out

func _coopTurretStates() -> Dictionary:
	if coopTurrets == null and setup:
		coopTurrets = []
		var stack = [self]
		while stack.size() > 0:
			var n = stack.pop_back()
			if n.has_method("coopState"):
				coopTurrets.append(n)
			for c in n.get_children():
				stack.append(c)
	var out = {}
	if coopTurrets != null:
		for t in coopTurrets:
			if is_instance_valid(t):
				out[str(get_path_to(t))] = t.coopState()
	return out

func _integrate_forces(state):
	if netControlled:
		# Our corrections are not forces the ship felt: keep the stock acceleration-shock damage
		# (damageAcceleration -> reactor stress) at zero on puppets.
		initialShockSupress = 1.0
	if netControlled and netState != null:
		var age = clamp((OS.get_ticks_msec() - netState.at) / 1000.0, 0.0, netMaxExtrapolation)
		var target = CurrentGame.localCoords(netState.p) + netState.v * age
		var err = target - state.transform.origin
		var targetRot = netState.r + netState.w * age
		var rerr = wrapf(targetRot - state.transform.get_rotation(), - PI, PI)
		if err.length() > netSnapDistance or abs(rerr) > netSnapAngle:
			state.transform = Transform2D(targetRot, target)
			state.linear_velocity = netState.v
			state.angular_velocity = netState.w
		else:
			state.linear_velocity = netState.v + err * netCorrectionGain
			state.angular_velocity = netState.w + rerr * netCorrectionGain
	._integrate_forces(state)

# A puppet is a picture of another player's ship. Its owner's machine decides what damages it, so locally it
# takes no damage, and it must never vanish: the stock vanish() erases the transponder from OUR save
# (CurrentGame.forgetTransponser), may remove a ship from our garage, and spawns a lifepod. Only CoopNet
# frees a puppet. Ship damage and destruction get replicated from the owner in M4.

func _coopNoDamage() -> bool:
	if Engine.has_meta("dvcoop_fx_only"):
		_coopCount("fxOnly", 1)
		return true
	return netControlled

func _coopCount(what, n):
	var net = _coopNet()
	var npc = net.get_node_or_null("Npc") if net != null else null
	if npc != null:
		npc.count(what, n)

# A local weapon hitting the mirror of an NPC another machine runs: send it there (Npc.gd d.ship). Beam damage
# forwards only inside a local weapon's forwarding window. Hostility forwards from any local context that isn't a
# puppet's replay: bullets (projectile.gd :83) apply it on the shooter's machine only, since the other machines'
# b.new copies carry no shooter; their damage needs no forwarding, the owner's copy of the bullet hits the real ship.
func _coopForward(kind, a, b = null, c = null) -> bool:
	if not (netControlled and has_meta("dvnet_mirror")) or Engine.has_meta("dvcoop_fx_only"):
		return false
	if kind != "h" and not Engine.has_meta("dvcoop_forward"):
		return false
	var net = _coopNet()
	var npc = net.get_node_or_null("Npc") if net != null else null
	if npc != null:
		npc.forwardShipHit(self, kind, a, b, c)
	return true

func applyKineticDamage(energy, point, delta = null):
	if _coopForward("k", energy, point, delta) or _coopNoDamage():
		return
	.applyKineticDamage(energy, point, delta)

func applyEnergyDamage(energy, point, delta):
	if _coopForward("e", energy, point, delta) or _coopNoDamage():
		return energy   # absorbed, so beams still stop at the hull
	return .applyEnergyDamage(energy, point, delta)

func applyEmpDamage(energy, point, delta):
	if _coopForward("m", energy, point, delta) or _coopNoDamage():
		return
	.applyEmpDamage(energy, point, delta)

func applyHostility(f, amt, broadcast = true, factor = 0.25, includeIndependents = false):
	if _coopForward("h", f, amt) or _coopNoDamage():
		return
	.applyHostility(f, amt, broadcast, factor, includeIndependents)

# The stock setDummy(false) points a non-player ship's disposition at CurrentGame.state.dispositions[transponder],
# creating that entry in OUR save. A puppet or mirror is someone else's ship: keep its disposition private.
func setDummy(how, always = false):
	var id = getId()
	var had = CurrentGame.state.get("dispositions", {}).has(id)
	.setDummy(how, always)
	if netControlled and not had and CurrentGame.state.get("dispositions", {}).has(id):
		disposition = CurrentGame.state.dispositions[id].duplicate(true)
		CurrentGame.state.dispositions.erase(id)

# Cargo hold and ore accounting (tim-58's Own.gd): a body only counts in my hold once I own it, leaving releases
# it, and carrying cargo out of the ring reports what was eaten first. Puppets never run a hold of their own.

func _coopOwn():
	var net = _coopNet()
	return net.get_node_or_null("Own") if net != null else null

func processCargoBodyEntry(delta: float):
	if netControlled:
		return
	.processCargoBodyEntry(delta)

func processEnteringCargoBay(body):
	var own = _coopOwn()
	if not netControlled and own != null and not own.holdEnter(self, body):
		return
	return .processEnteringCargoBay(body)

func processExitingCargoBay(body):
	var r = .processExitingCargoBay(body)
	var own = _coopOwn()
	if own != null:
		own.holdExit(self, body)
	return r

func claimCargo(claimFor = self):
	if netControlled:
		return
	var own = _coopOwn()
	if own != null:
		own.beforeClaimCargo(self)
	return .claimCargo(claimFor)

func vanish(except = []):
	if netControlled:
		if netDying:
			# the explosion's picture: hide and stop colliding, none of the stock save writes or lifepod
			for c in get_children():
				if not (c in except):
					if "visible" in c:
						c.visible = false
					if "playing" in c:
						c.stop()
			disableCollisionsOn(self)
			Debug.l("COOP: puppet '%s' exploded" % name)
		else:
			Debug.l("COOP: blocked vanish() on puppet '%s'" % name)
		return
	.vanish(except)
