extends "res://hud/AstrogatorPanel.gd"

# dv-coop (M5): plot a course to a friend. The flight astrogator lists every friend in the rings after the stock
# rows, "<name> (friend), <range> km", with no uncertainty, under the stock 150 km minimum (closer friends are
# reached by flying; the row shows but Plot Course stays disabled). Plot Course on a friend row goes to
# net/Travel.gd, which emits the stock plotCourseTo and keeps the target on the friend until the jump. Rows are
# appended, never prepended: index 0 is Enceladus to the stock code.

const FRIEND_COLOUR = Color(0.35, 0.9, 1.0, 0.9)

func _travel():
	if not ModLoader.has_meta("dvcoop"):
		return null
	return ModLoader.get_meta("dvcoop").get_node_or_null("Travel")

func fillDestinations():
	.fillDestinations()
	var travel = _travel()
	if travel == null or not is_visible_in_tree() or not Tool.claim(ship):
		return
	var here = CurrentGame.globalCoords(ship.global_position)
	Tool.release(ship)
	for f in travel.friends():
		var key = travel.friendKey(f.id)
		destinations[key] = {"vector": f.p, "time": null, "friend": f.id}
		destinationNode.add_item("%s (friend), %d km" % [f.name, int(here.distance_to(f.p) / 10000.0)], alwaysIcon)
		destinationLut.append(key)
		var i = destinationLut.size() - 1
		destinationNode.set_item_tooltip_enabled(i, false)
		setDestinationColour(i, FRIEND_COLOUR)

func _on_PlotCourse_pressed():
	var travel = _travel()
	if travel != null and travel.friendOf(currentDestination) != null:
		Debug.l("Fast travel to %s" % currentDestination)
		travel.plotToFriend(travel.friendOf(currentDestination))
		return
	._on_PlotCourse_pressed()
