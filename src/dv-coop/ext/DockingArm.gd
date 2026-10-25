extends "res://ships/modules/DockingArm.gd"

# dv-coop docking arm / claw extension (M4). Design: docs/M4-OWNERSHIP.md "Claim flow".
#
# Local ship: locking onto a replicated rock is a touch (Own.touch "claw"); unlocking or switching target releases
# it. While the claim is pending the arm already holds our copy (correction paused); a deny drops the rock from the
# queue for a moment, and the stock code releases it as an invalid target.
# Puppet (another player's ship on this machine): the arm never takes a target, so it never locks, pushes or pins
# anything here. The owner's arm does that, and the rock arrives through ownership.
# Never a target: other players' ships (meta dvnet_puppet) and mirrors of other players' drones / NPCs (dvnet_mirror).

const DENY_COOLDOWN = 2.0
const RELEASE_GRACE = 0.5   # s the arm must stay unlocked before we hand the rock back (the stock lock flickers)

var coopLocked = null       # the rock we last reported as touched
var coopCooldown = {}       # net id -> time (s) until which we don't target it again
var coopUnlockedSince = -1.0

func _coopOwn():
	if ModLoader.has_meta("dvcoop"):
		return ModLoader.get_meta("dvcoop").get_node_or_null("Own")
	return null

func _coopPuppet() -> bool:
	return ship != null and ship.get("netControlled") == true

# Godot 3 calls _ready / _physics_process on every script level (base first), so no explicit super calls here:
# this runs right after the stock arm's own tick.
func _ready():
	var own = _coopOwn()
	if own != null:
		own.connect("denied", self, "_coopDenied")

func isValidTarget(body: RigidBody2D) -> bool:
	if _coopPuppet():
		return false
	if body != null and is_instance_valid(body):
		if body.has_meta("dvnet_puppet") or body.has_meta("dvnet_mirror"):
			return false
		if body.has_meta("dvnet") and coopCooldown.get(body.get_meta("dvnet"), 0.0) > OS.get_ticks_msec() / 1000.0:
			return false
	return .isValidTarget(body)

func addToQueue(body):
	if _coopPuppet():
		return
	.addToQueue(body)

func _physics_process(delta):
	if _coopPuppet():
		return
	var own = _coopOwn()
	if own == null:
		return
	var now = target if (locked and target != null and is_instance_valid(target)) else null
	var t = OS.get_ticks_msec() / 1000.0
	if now == coopLocked:
		coopUnlockedSince = -1.0
		return
	if now == null and coopLocked != null and is_instance_valid(coopLocked):
		# let go only after RELEASE_GRACE without a lock
		if coopUnlockedSince < 0:
			coopUnlockedSince = t
			return
		if t - coopUnlockedSince < RELEASE_GRACE:
			return
	coopUnlockedSince = -1.0
	if coopLocked != null and is_instance_valid(coopLocked):
		own.untouch(coopLocked, "claw")
	coopLocked = now
	if now != null:
		own.touch(now, "claw")

func _coopDenied(id, reason):
	if coopLocked != null and is_instance_valid(coopLocked) and coopLocked.get_meta("dvnet") == id:
		coopCooldown[id] = OS.get_ticks_msec() / 1000.0 + DENY_COOLDOWN
		queue.erase(coopLocked)
		Debug.l("COOP: OWN claw %s lets go of %s (%s)" % [name, id, reason])
		coopLocked = null

func _exit_tree():
	var own = _coopOwn()
	if own != null and coopLocked != null and is_instance_valid(coopLocked):
		own.untouch(coopLocked, "claw")
	coopLocked = null
