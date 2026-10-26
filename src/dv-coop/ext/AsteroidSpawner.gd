extends "res://AsteroidSpawner.gd"

# dv-coop AsteroidField extension (M3, M4).
#
# A cell member's spawner is suspended (spawnThings = false), which shrinks its despawn bubble to
# enceladusTravelBubble; rocks tracked by RockSync and other players' puppets must still never be despawned locally.
# A cell member never slipstreams its own origin; the authority does it for the cell (Cell shifts members).
#
# Fracture shards on a member (M4): a rock the member owns breaks here (its MPU, laser, claw), and the stock fracture
# asks this field for shards (spawnAsteroidByClass(..., spawned = false)). With the suspended spawner's 1000 px
# bubble, isInDespawnCell puts every position outside it (a 10 km cell's corners are never all that close), so the
# member got no shards at all. A shard spawn on a member is placement-tested with the radius a running spawner uses
# (the stock getLoadDespawnRadius formula), as on the authority or solo; Own then hands the shards over (o.new).
# Until then a fresh shard is neither tracked nor ours to keep, so a member never despawns a replicated rock: the
# authority decides when rocks go (r.d).

var coopShard = false   # inside a fracture-shard spawn on a cell member
var coopShardRefused = false
# member shard requests since the last line: COOP: RS member shards: tries=.. ok=.. despawn=.. blocked=.. none=..
# (despawn: refused by the placement radius; blocked: the stock overlap test, retried next frame; none: the class-5
# table picked no rock for this spot's chaos, a stock "no shard")
var coopShardStats = {"tries": 0, "ok": 0, "despawn": 0, "blocked": 0, "none": 0}
var coopShardLogAt = 0

func _coopMember() -> bool:
	if not ModLoader.has_meta("dvcoop"):
		return false
	var cell = ModLoader.get_meta("dvcoop").get_node_or_null("Cell")
	return cell != null and cell.has_method("inCell") and cell.inCell() and not cell.isAuthority()

func despawn(body):
	if body != null and is_instance_valid(body) and (body.has_meta("dvnet_tracked") or body.has_meta("dvnet_puppet")):
		return
	if body != null and is_instance_valid(body) and body.has_meta("dvnet") and not spawnThings and _coopMember():
		return
	.despawn(body)

func spawnAsteroidByClass(oc, spot, chaos, spawnPointRandomness = 0.0, initialLinearVelocity = Vector2(0, 0), initialAngularVelocity = 0.0, tries = 1, spawned = true):
	coopShard = not spawned and not spawnThings and _coopMember()
	coopShardRefused = false
	var r = .spawnAsteroidByClass(oc, spot, chaos, spawnPointRandomness, initialLinearVelocity, initialAngularVelocity, tries, spawned)
	if coopShard:
		coopShardStats.tries += 1
		if r is Dictionary:
			coopShardStats.none += 1
		elif r != null:
			coopShardStats.ok += 1
		elif coopShardRefused:
			coopShardStats.despawn += 1
		else:
			coopShardStats.blocked += 1
		var t = OS.get_ticks_msec()
		if t >= coopShardLogAt:
			coopShardLogAt = t + 5000
			Debug.l("COOP: RS member shards: tries=%d ok=%d despawn=%d blocked=%d none=%d" % [coopShardStats.tries,
				coopShardStats.ok, coopShardStats.despawn, coopShardStats.blocked, coopShardStats.none])
			for k in coopShardStats:
				coopShardStats[k] = 0
	coopShard = false
	return r

func isInDespawnRadius(pos: Vector2, asteroid: bool) -> bool:
	if coopShard and asteroid and Tool.claim(focusObject):
		var test = focusObject.global_position
		Tool.release(focusObject)
		var running = range_lerp(sqrt(clamp(getThrottleFactor(), 0.05, 1)), 1, 0, despawnRadiusAsteroids, despawnRadiusAsteroidsLoad)
		coopShardRefused = isInDespawnCell(test, pos, running)
		return coopShardRefused
	return .isInDespawnRadius(pos, asteroid)

func slipstream():
	if ModLoader.has_meta("dvcoop"):
		var cell = ModLoader.get_meta("dvcoop").get_node_or_null("Cell")
		if cell != null and cell.has_method("inCell") and cell.inCell() and not cell.isAuthority():
			Debug.l("COOP: RS member slipstream suppressed")
			return
	.slipstream()
