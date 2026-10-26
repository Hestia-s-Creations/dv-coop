extends "res://enceladus/DiveTarget.gd"

# dv-coop (M5): dive to a friend. When the picked destination is a friend row (ext/AstrogationDestinations.gd), the
# stock Dive press runs unchanged (pre-dive save, the price for that spot, consumables, the random spread), then
# net/Travel.gd replaces CurrentGame.diveTarget with the friend's position at launch, led over the dive cutscene.
# Picking any other destination, Reset, or steering the trajectory by hand drops the friend.

var coopFriend = null

func _ready():
	add_to_group("dvcoop_dive")

func _on_AstrogationDestinations_newDestination(data):
	coopFriend = data.get("friend", null)
	._on_AstrogationDestinations_newDestination(data)

func _on_Reset_pressed():
	coopFriend = null
	._on_Reset_pressed()

func _on_EntryTrajectory_manualInput():
	coopFriend = null
	._on_EntryTrajectory_manualInput()

func _on_Dive_pressed():
	var was = launching
	var friend = coopFriend
	._on_Dive_pressed()
	if was or friend == null or not ModLoader.has_meta("dvcoop"):
		return
	var travel = ModLoader.get_meta("dvcoop").get_node_or_null("Travel")
	if travel != null:
		travel.diveTo(friend)
