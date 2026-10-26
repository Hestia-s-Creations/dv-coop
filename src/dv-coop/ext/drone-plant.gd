extends "res://weapons/drone-plant.gd"

# dv-coop: on a puppet the drone swarm is a picture. Its hits (tug and haul impulses on rocks, repairs on ships)
# belong to the owner's machine, so a puppet's drones fly and land but change nothing.
# Our own haul and tug drones claim the rock they push (Own.touchFor, M4): a copy of a rock someone else owns would
# otherwise be pulled back by RockSync's correction after every push. The claim lapses HAUL_LINGER s after the last
# hit. While a claim is in flight the push still lands on our copy (Own pauses its correction); after a deny the
# push is skipped until Own's backoff ends, since it would only be corrected away.

const HAUL_LINGER = 2.0

func _on_DroneLaunchManager_droneHit(pt, delta, drones):
	if ship != null and ship.get("netControlled"):
		return
	if (droneFunction == "haul" or droneFunction == "tug") and target != null and is_instance_valid(target) \
			and target.has_meta("dvnet") and ModLoader.has_meta("dvcoop"):
		var own = ModLoader.get_meta("dvcoop").get_node_or_null("Own")
		if own != null and not own.touchFor(target, droneFunction, HAUL_LINGER) and own.backingOff(target):
			return
	._on_DroneLaunchManager_droneHit(pt, delta, drones)
