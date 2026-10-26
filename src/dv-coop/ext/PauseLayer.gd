extends "res://PauseLayer.gd"

# dv-coop: in a cell the pause menu opens without pausing the game. One player's menu, alt-tab or Steam overlay must
# not freeze the cell (a paused tree would stop that player's ship and network for everyone). Alone, the stock pause
# is untouched.
#
# Every pause request (pause key, window focus loss, gamepad connect, the Steam overlay through CurrentGame.pauseGame)
# goes through pauseGame, so this one override covers them. The stock pause key toggles with `not tree.paused`, which
# stays false in a cell, so a pause-key press while the menu is open is read here as "close". While the menu is open
# the local ship takes no manual input (ship-ctrl ext), so clicking the menu doesn't fly the ship.

func _coopInCell() -> bool:
	if not ModLoader.has_meta("dvcoop"):
		return false
	var cell = ModLoader.get_meta("dvcoop").get_node_or_null("Cell")
	return cell != null and cell.inCell()

func pauseGame(pause):
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
