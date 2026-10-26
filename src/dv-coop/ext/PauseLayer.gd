extends "res://PauseLayer.gd"

# dv-coop: in a cell the pause menu opens without pausing the game. One player's menu, alt-tab or Steam overlay must
# not freeze the cell (a paused tree would stop that player's ship and network for everyone). Alone, the stock pause
# is untouched.
#
# Every pause request (pause key, window focus loss, gamepad connect, the Steam overlay through CurrentGame.pauseGame)
# goes through pauseGame, so this one override covers them. The stock pause key toggles with `not tree.paused`, which
# stays false in a cell, so a pause-key press while the menu is open is read here as "close". While the menu is open
# the local ship takes no manual input (ship-ctrl ext), so clicking the menu doesn't fly the ship.
#
# M5: a "Co-op" button after Resume opens the co-op panel (ui/CoopPanel.gd) in the menu's own CenterContainer, in
# flight and at Enceladus. A join request (a Steam invite while playing) opens the menu with the question on it.

var coopPanel = null

func _ready():
	add_to_group("dvcoop_pause")
	var box = $PauseContainer/MarginContainer/VBoxContainer
	var b = Button.new()
	b.name = "Coop"
	b.text = "Co-op"
	box.add_child(b)
	box.move_child(b, box.get_node("Resume").get_index() + 1)
	b.connect("pressed", self, "coopOpen")
	coopPanel = load("res://dv-coop/ui/CoopPanel.gd").new()
	$PauseContainer/NoMargins/CenterContainer.add_child(coopPanel)

func coopOpen():
	if not $PauseContainer.visible:
		pauseGame(true)
	coopPanel.open()

func coopAsk():
	coopOpen()

func _coopInCell() -> bool:
	if not ModLoader.has_meta("dvcoop"):
		return false
	var cell = ModLoader.get_meta("dvcoop").get_node_or_null("Cell")
	return cell != null and cell.inCell()

func pauseGame(pause):
	if not pause and coopPanel != null:
		coopPanel.close()
	if not _coopInCell():
		if Engine.has_meta("dvcoop_menu"):
			Engine.remove_meta("dvcoop_menu")
		.pauseGame(pause)
		return
	if pause and $PauseContainer.visible and Input.is_action_just_pressed("pause"):
		pause = false
	.pauseGame(pause)
	# the stock call paused the tree and showed the menu (visible = tree.paused); keep the menu, run the game
	get_tree().paused = false
	if pause:
		Engine.set_meta("dvcoop_menu", true)
	elif Engine.has_meta("dvcoop_menu"):
		Engine.remove_meta("dvcoop_menu")
	Debug.l("COOP: SHIPS pause menu %s in a cell, game keeps running" % ("open" if pause else "closed"))
