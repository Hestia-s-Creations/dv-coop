extends "res://weapons/drone-plant.gd"

# dv-coop: on a puppet the drone swarm is a picture. Its hits (tug and haul impulses on rocks, repairs on ships)
# belong to the owner's machine, so a puppet's drones fly and land but change nothing.

func _on_DroneLaunchManager_droneHit(pt, delta, drones):
	if ship != null and ship.get("netControlled"):
		return
	._on_DroneLaunchManager_droneHit(pt, delta, drones)
