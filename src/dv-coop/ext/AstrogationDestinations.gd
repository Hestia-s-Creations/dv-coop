extends "res://enceladus/AstrogationDestinations.gd"

# dv-coop (M5): dive to a friend. The Enceladus dive picker lists every friend in the rings after the stock rows,
# as "<name> (friend)". A friend row is a destination with a time (so DiveTarget treats its vector as absolute) at the
# friend's beacon position: the stock price, depth and remass panels then price a dive there. The friend's id rides
# along in the destination ("friend"), and ext/DiveTarget.gd sends the dive to where the friend is at launch.

func _ready():
	add_to_group("dvcoop_divelist")

func fillDestinations():
	.fillDestinations()
	if not ModLoader.has_meta("dvcoop"):
		return
	var travel = ModLoader.get_meta("dvcoop").get_node_or_null("Travel")
	if travel == null:
		return
	for f in travel.friends():
		var key = travel.friendKey(f.id)
		destinations[key] = {"vector": f.p, "time": 1, "trackable": true, "friend": f.id}
		destinationLut.append(key)
		add_item("%s (friend)" % f.name)
