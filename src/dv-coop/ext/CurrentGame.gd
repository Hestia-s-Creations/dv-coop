extends "res://CurrentGame.gd"

# dv-coop: the stock "simulator range" (12,000 px around the player's ship) decides whether a fracturing rock leaves
# shards (asteroid.gd :212), whether thrusters puff physical plumes (thruster.gd :578, :600) and whether a bullet
# hit does its finishing work (projectile.gd :90). On the cell authority the rocks near every member are simulated
# here too, so the range also covers each member's ship (its puppet); otherwise a rock fractured next to a member
# but far from the authority's own ship would vanish with no shards. Alone, or as a member, it is the stock range.

const COOP_SIM_RANGE = 12000.0

func isInSimulatiorRange(v: Vector2):
	if .isInSimulatiorRange(v):
		return true
	if not ModLoader.has_meta("dvcoop"):
		return false
	var net = ModLoader.get_meta("dvcoop")
	var cell = net.get_node_or_null("Cell")
	if cell == null or not cell.inCell() or not cell.isAuthority():
		return false
	for id in net.peers:
		var pp = net._puppetOf(id)
		if pp != null and pp.global_position.distance_to(v) < COOP_SIM_RANGE:
			return true
	return false
