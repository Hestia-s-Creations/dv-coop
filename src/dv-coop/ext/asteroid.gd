extends "res://asteroids/asteroid.gd"

# dv-coop asteroid extension (M3).
#
# A rock tracked by RockSync (meta "dvnet_tracked") is a copy of the cell authority's rock.
# Only the authority may fracture it, so damage on a tracked rock only plays its effects here.
# M4 forwards the damage to the authority instead.

func applyEnergyDamage(energy, point, delta):
	if has_meta("dvnet_tracked"):
		applyEnergyEffect(energy * energyDamageScale, point)
		return 0.0
	return .applyEnergyDamage(energy, point, delta)

func applyKineticDamage(energy, point, delta = null):
	if has_meta("dvnet_tracked"):
		applyEnergyEffect(energy * kineticDamageScale, point)
		return
	.applyKineticDamage(energy, point, delta)
