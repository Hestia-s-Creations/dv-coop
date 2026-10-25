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
# (captureIntent) so the other machine's puppet fires the same thrusters.

var coopExtensionActive = true

var netControlled = false
var netSchedule = null     # {thrusterName: [power, Vector2|null]} last received
var netState = null        # {p: Vector2 global, r: float, v: Vector2, w: float, at: msec received}

export var netSnapDistance = 400.0
export var netSnapAngle = 0.6
export var netCorrectionGain = 4.0
export var netMaxExtrapolation = 0.25

func _ready():
	._ready()
	Debug.l("COOP: ship-ctrl extension active on '%s' (playerControlled=%s ai=%s net=%s)" % [name, playerControlled, ai, netControlled])

func _coopNet():
	if ModLoader.has_meta("dvcoop"):
		return ModLoader.get_meta("dvcoop")
	return null

func _process(delta):
	if netControlled:
		autopilot = false
		if netSchedule != null:
			thrusterShedule = netSchedule.duplicate(true)
	._process(delta)

func executeThrusterFire(solve: bool, delta: float):
	if playerControlled and not netControlled:
		var net = _coopNet()
		if net != null:
			net.captureIntent(self, thrusterShedule)
	.executeThrusterFire(solve, delta)

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

func applyKineticDamage(energy, point, delta = null):
	if netControlled:
		return
	.applyKineticDamage(energy, point, delta)

func applyEnergyDamage(energy, point, delta):
	if netControlled:
		return energy   # absorbed, so beams still stop at the hull
	return .applyEnergyDamage(energy, point, delta)

func applyEmpDamage(energy, point, delta):
	if netControlled:
		return
	.applyEmpDamage(energy, point, delta)

func vanish(except = []):
	if netControlled:
		Debug.l("COOP: blocked vanish() on puppet '%s'" % name)
		return
	.vanish(except)
