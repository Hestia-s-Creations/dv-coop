extends "res://weapons/synchrotron.gd"

# dv-coop: the stock tick does its raycast damage inline, so it runs inside a context instead of being changed.
# On a puppet (another player's ship replaying its fired systems) every hit is effects only; the shooter's own
# machine applies or forwards the damage. On a local ship, hits on bodies we don't own are forwarded to their owner.

var coopTurretFire = null   # set by a puppet turret (PDT ext): the owner's fire power for this weapon

func _ready():
	load("res://dv-coop/net/Tick.gd").attach(self)

func coopTick(delta):
	var puppet = ship != null and ship.get("netControlled")
	var key = "dvcoop_fx_only" if puppet else "dvcoop_forward"
	if puppet and get("coopTurretFire") != null:
		fire(get("coopTurretFire"))
	var queued = Tool.physicsQueue.size()
	Engine.set_meta(key, ship)
	._physics_process(delta)
	Engine.remove_meta(key)
	if puppet:
		# the lingering storm nodes it just queued are the owner's to make; drop ours
		var keep = Tool.physicsQueue.slice(0, queued - 1) if queued > 0 else []
		for i in range(queued, Tool.physicsQueue.size()):
			var call = Tool.physicsQueue[i]
			if call[1] == "add_child" and call[2].size() > 0 and call[2][0] is Node and not call[2][0].is_inside_tree():
				call[2][0].free()
			else:
				keep.append(call)
		Tool.physicsQueue = keep
