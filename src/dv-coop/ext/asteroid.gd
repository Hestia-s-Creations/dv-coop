extends "res://asteroids/asteroid.gd"

# dv-coop asteroid extension (M3, M4).
#
# A rock tracked by RockSync (meta "dvnet_tracked") is a copy of a rock another machine owns. Only the owner may
# damage or fracture it, so damage on a tracked rock only plays its effects here; the shooter forwards beam hits to
# the owner as d.ev (Own.gd). Damage also plays effects only while Engine carries the "dvcoop_fx_only" meta, which
# the Ships track sets around a puppet's weapon tick, so a puppet's laser never hits a rock a second time.
# A local beam weapon (laser, emp, synchrotron, thruster heat beam) wraps its tick in Engine meta "dvcoop_forward";
# a hit on a tracked rock inside that window is forwarded to the rock's owner. Contact damage and bullets never are:
# the owner computes those itself.

func _fxOnly() -> bool:
	if Engine.has_meta("dvcoop_fx_only"):
		_countFxOnly()
		return true
	return has_meta("dvnet_tracked")

# Gate 7 evidence: how many rock damage calls a puppet's weapons made here (all turned into effects only), summed
# into the Ships track's 5 s summary as rockFxOnly.
func _countFxOnly():
	if ModLoader.has_meta("dvcoop"):
		var npc = ModLoader.get_meta("dvcoop").get_node_or_null("Npc")
		if npc != null and npc.has_method("count"):
			npc.count("rockFxOnly", 1)

func _forward(kind, amount, point, delta):
	if Engine.has_meta("dvcoop_fx_only") or not Engine.has_meta("dvcoop_forward") or not has_meta("dvnet_tracked"):
		return
	if ModLoader.has_meta("dvcoop"):
		var own = ModLoader.get_meta("dvcoop").get_node_or_null("Own")
		if own != null:
			own.forwardDamage(self, kind, amount, point, delta)

func applyEnergyDamage(energy, point, delta):
	if _fxOnly():
		_forward("e", energy, point, delta)
		applyEnergyEffect(energy * energyDamageScale, point)
		return 0.0
	return .applyEnergyDamage(energy, point, delta)

func applyKineticDamage(energy, point, delta = null):
	if _fxOnly():
		_forward("k", energy, point, delta)
		applyEnergyEffect(energy * kineticDamageScale, point)
		return
	.applyKineticDamage(energy, point, delta)

func addIntegratedDamage(source: RigidBody2D, energy: float, pt: Vector2):
	if _fxOnly():
		return
	.addIntegratedDamage(source, energy, pt)

func applyEmpDamage(energy, point, delta):
	if _fxOnly():
		_forward("m", energy, point, delta)
		return
	.applyEmpDamage(energy, point, delta)
