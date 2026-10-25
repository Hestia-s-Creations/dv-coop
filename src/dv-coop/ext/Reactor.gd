extends "res://ships/Reactor.gd"

# dv-coop: ship death across machines.
# - The local player's ship announces its explosion (s.die) when it starts, so everyone plays it together.
# - On a puppet the stock explosion runs as a picture: no story flag (that would write our save) and no vanish
#   (blocked in the ship-ctrl ext; the puppet hides itself instead).
# - The blast particles push and damage rocks, so they are physical only where the rocks are simulated (solo, or the
#   cell authority); elsewhere they fly without collision.

func initExplosion():
	_coopAnnounce()
	.initExplosion()

func explode():
	if ship != null and ship.get("netControlled"):
		var flag = storyFlag
		storyFlag = ""
		.explode()
		storyFlag = flag
		return
	.explode()

func _ready():
	load("res://dv-coop/net/Tick.gd").attach(self)

func coopTick(delta):
	var queued = Tool.physicsQueue.size()
	var kids = get_child_count()
	._physics_process(delta)
	if exploding and not coopBlastLogged and boomCount <= 0:
		coopBlastLogged = true
		Debug.l("COOP: SHIPS blast of '%s' finished: particles %s here" % [ship.name, "physical" if _coopSimulatesRocks() else "ghosted (no collision)"])
	if not exploding or _coopSimulatesRocks():
		return
	for i in range(queued, Tool.physicsQueue.size()):
		var call = Tool.physicsQueue[i]
		if call[1] == "add_child" and call[2].size() > 0 and call[2][0] is CollisionObject2D:
			_coopGhost(call[2][0])
	for i in range(kids, get_child_count()):
		if get_child(i) is CollisionObject2D:
			_coopGhost(get_child(i))

var coopBlastLogged = false

func _coopGhost(body):
	body.collision_layer = 0
	body.collision_mask = 0

func _coopNet():
	return ModLoader.get_meta("dvcoop") if ModLoader.has_meta("dvcoop") else null

func _coopSimulatesRocks() -> bool:
	var net = _coopNet()
	var cell = net.get_node_or_null("Cell") if net != null else null
	return cell == null or not cell.has_method("isAuthority") or cell.isAuthority()

func _coopAnnounce():
	if ship == null or ship.cutscene or ship.get("netControlled") or not ship.isPlayerControlled():
		return
	var net = _coopNet()
	var npc = net.get_node_or_null("Npc") if net != null else null
	if npc != null:
		npc.localShipExploding(ship)
