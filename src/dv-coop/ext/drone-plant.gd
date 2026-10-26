extends "res://weapons/drone-plant.gd"

# dv-coop: on a puppet the drone swarm is a picture. Its hits (tug and haul impulses on rocks, repairs on ships)
# belong to the owner's machine, so a puppet's drones fly and land but change nothing.
# Our own haul drones claim the rock they push (Own.touchFor "haul", M4): a copy of a rock someone else owns would
# otherwise be pulled back by RockSync's correction after every push. The claim lapses HAUL_LINGER s after the last hit.

const HAUL_LINGER = 2.0

func _on_DroneLaunchManager_droneHit(pt, delta, drones):
	if ship != null and ship.get("netControlled"):
		return
	if droneFunction == "haul" and target != null and is_instance_valid(target) and target.has_meta("dvnet") \
			and ModLoader.has_meta("dvcoop"):
		var own = ModLoader.get_meta("dvcoop").get_node_or_null("Own")
		if own != null:
			own.touchFor(target, "haul", HAUL_LINGER)
	._on_DroneLaunchManager_droneHit(pt, delta, drones)
