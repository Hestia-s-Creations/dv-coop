extends Node

# Drives an extension's physics tick in place of the node's own physics processing.
#
# Godot 3 calls _physics_process on every level of a script chain by itself (derived first, then the stock
# one), so an extension can't run code around the stock tick by overriding it. Instead the extension turns
# its node's physics processing off, adds one of these as a child, and gets coopTick(delta) here, where it
# calls ._physics_process(delta) (the stock tick) inside whatever context it needs.
#
# The stock code turns a system's physics processing back on by itself: ship setup and every un-dummy
# (ship-ctrl setDummy: each system's set_physics_process(not dummy); thrusters and drone launchers on the ship's
# dummyChanged). The engine would then run the stock tick a second time each frame, outside our context: thrusters
# burning twice the remass, reactors drawing twice the turbine mass, beams hitting twice and unforwarded. So every
# frame this turns it off again, and follows what the stock asked for instead: a dummy ship's systems don't tick.

var target = null

static func attach(node):
	node.set_physics_process(false)
	var t = load("res://dv-coop/net/Tick.gd").new()
	t.name = "CoopTick"
	t.target = node
	node.add_child(t)

func _physics_process(delta):
	if target == null or not is_instance_valid(target):
		return
	if target.is_physics_processing():
		target.set_physics_process(false)
		var n = Engine.get_meta("dvcoop_tick_reenabled") + 1 if Engine.has_meta("dvcoop_tick_reenabled") else 1
		Engine.set_meta("dvcoop_tick_reenabled", n)
		if n <= 3 or n == 10 or n == 100 or n == 1000:
			Debug.l("COOP: TICK stock turned physics processing back on for %s (%d so far); off again, no double tick" % [
				target.get_path(), n])
	var s = target.get("ship")
	if s != null and is_instance_valid(s) and s.get("dummy") == true:
		return
	target.coopTick(delta)
