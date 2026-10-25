extends "res://weapons/emp.gd"

# dv-coop: the stock tick does its raycast damage inline, so it runs inside a context instead of being changed.
# On a puppet (another player's ship replaying its fired systems) every hit is effects only; the shooter's own
# machine applies or forwards the damage. On a local ship, hits on bodies we don't own are forwarded to their owner.

var coopTurretFire = null   # set by a puppet turret (PDT ext): the owner's fire power for this weapon

func _ready():
	load("res://dv-coop/net/Tick.gd").attach(self)

func coopTick(delta):
	var key = "dvcoop_fx_only" if ship != null and ship.get("netControlled") else "dvcoop_forward"
	if key == "dvcoop_fx_only" and get("coopTurretFire") != null:
		fire(get("coopTurretFire"))
	Engine.set_meta(key, ship)
	._physics_process(delta)
	Engine.remove_meta(key)
