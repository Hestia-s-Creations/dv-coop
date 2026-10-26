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
var coopShardBlockedBy = ""

# What the stock overlap test (asteroidIntersectionTest layers) finds at a shard spot: a circle of the class's
# estimated radius, which is close to the shard's own shape. Evidence only.
func _coopWhatBlocks(oc, spot) -> String:
	var shape = CircleShape2D.new()
	shape.radius = estimatedRadiusByClass[clamp(oc, 0, estimatedRadiusByClass.size() - 1)]
	var params = Physics2DShapeQueryParameters.new()
	params.set_shape(shape)
	params.margin = initialMargin
	params.transform = Transform2D(0, spot)
	params.collision_layer = asteroidIntersectionTest
	params.collide_with_areas = true
	params.collide_with_bodies = true
	var hits = get_world_2d().direct_space_state.intersect_shape(params, 4)
	var out = []
	for h in hits:
		var c = h.collider
		if c == null or not is_instance_valid(c):
			continue
		var tag = "ship" if c.has_method("isPlayerControlled") else ("rock" if c.has_meta("dvnet") else c.get_class())
		for m in ["dvnet_puppet", "dvnet_tracked", "dvnet_mirror"]:
			if c.has_meta(m):
				tag += "+" + m
		out.append("%s[%s layer=%x]" % [c.name, tag, c.collision_layer if "collision_layer" in c else 0])
	return PoolStringArray(out).join(", ") if out.size() > 0 else "nothing found by a circle query"

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
			if coopShardBlockedBy == "":
				coopShardBlockedBy = _coopWhatBlocks(oc, spot)
		var t = OS.get_ticks_msec()
		if t >= coopShardLogAt:
			coopShardLogAt = t + 5000
			Debug.l("COOP: RS member shards: tries=%d ok=%d despawn=%d blocked=%d none=%d%s" % [coopShardStats.tries,
				coopShardStats.ok, coopShardStats.despawn, coopShardStats.blocked, coopShardStats.none,
				"" if coopShardBlockedBy == "" else " (first blocked by %s)" % coopShardBlockedBy])
			for k in coopShardStats:
				coopShardStats[k] = 0
			coopShardBlockedBy = ""
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
