extends "res://AsteroidSpawner.gd"

# dv-coop AsteroidField extension (M3).
#
# A cell member's spawner is suspended (spawnThings = false), which shrinks its despawn bubble to
# enceladusTravelBubble; rocks tracked by RockSync and other players' puppets must still never be despawned locally.
# A cell member never slipstreams its own origin; the authority does it for the cell (Cell shifts members).

func despawn(body):
	if body != null and is_instance_valid(body) and (body.has_meta("dvnet_tracked") or body.has_meta("dvnet_puppet")):
		return
	.despawn(body)

func slipstream():
	if ModLoader.has_meta("dvcoop"):
		var cell = ModLoader.get_meta("dvcoop").get_node_or_null("Cell")
		if cell != null and cell.has_method("inCell") and cell.inCell() and not cell.isAuthority():
			Debug.l("COOP: RS member slipstream suppressed")
			return
	.slipstream()
