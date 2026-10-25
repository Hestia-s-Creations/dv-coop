extends "res://ships/modules/PDT.gd"

# dv-coop: PDT / ACT turrets pick targets and aim on their own. On a puppet they don't: the owner streams each
# turret's pivot angle and its weapon's fire power in the intent (ship-ctrl ext, "_pdt"), and the puppet turret
# copies them. The wrapped weapon fires for effects only (weapon exts read coopTurretFire).
# Godot 3 runs this _physics_process before the stock one; with `enabled` off the stock tick only zeroes the
# weapon's own fire, which the weapon ext overrides from coopTurretFire.

func _ready():
	if ship != null and ship.get("netControlled"):
		set_physics_process(true)

func _physics_process(delta):
	if ship == null or not ship.get("netControlled"):
		return
	enabled = false
	var pdt = ship.get("netPdt")
	var st = pdt.get(str(ship.get_path_to(self))) if pdt != null else null
	if st != null:
		pivot.rotation = st[0]
	if "coopTurretFire" in system:
		system.coopTurretFire = st[1] if st != null else 0.0

# owner side: what a puppet needs to copy this turret
func coopState():
	var f = system.get("firepower")
	return [pivot.rotation, f if f != null else 0.0]
