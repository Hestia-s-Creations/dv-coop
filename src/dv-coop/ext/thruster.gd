extends "res://sfx/thruster.gd"

# dv-coop thruster extension (M4). The heat beam (stock :622-640) damages bodies inline in the stock tick, so the
# tick runs inside a context, driven by net/Tick.gd (Ships track): on a puppet every hit is effects only; on a local
# ship a hit on a rock we don't own is forwarded to its owner (ext/asteroid.gd). Exhaust plumes need nothing: they are
# bodies, the puppet's replayed thrusters emit them on every machine, and contact damage counts only on the owner.

func _ready():
	if ResourceLoader.exists("res://dv-coop/net/Tick.gd"):
		load("res://dv-coop/net/Tick.gd").attach(self)
	else:
		Debug.l("COOP: thruster %s: net/Tick.gd missing, heat beam not wrapped" % name)

func coopTick(delta):
	var key = "dvcoop_fx_only" if ship != null and is_instance_valid(ship) and ship.get("netControlled") else "dvcoop_forward"
	Engine.set_meta(key, ship)
	._physics_process(delta)
	Engine.remove_meta(key)
