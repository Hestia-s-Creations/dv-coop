extends "res://menu/TitleMenu.gd"

# dv-coop (M5): a "Co-op" button above Exit opens the co-op panel (ui/CoopPanel.gd) in the stock Popups
# CenterContainer. A join from the title also picks the save to play and goes through the stock Continue.
# Joining from Steam with the game closed (+connect_lobby) opens the same panel (CoopNet.requestJoin).

var coopPanel = null

func _ready():
	add_to_group("dvcoop_title")
	var opts = $MarginContainer/VBoxContainer/HBoxContainer/Opts
	var b = Button.new()
	b.name = "Coop"
	b.text = "Co-op"
	opts.add_child(b)
	opts.move_child(b, opts.get_node("Exit").get_index())
	b.connect("pressed", self, "coopOpen")
	coopPanel = load("res://dv-coop/ui/CoopPanel.gd").new()
	coopPanel.atTitle = true
	coopPanel.titleMenu = self
	coopPanel.cover = $MarginContainer
	$NoMargins/Popups.add_child(coopPanel)

func coopOpen():
	coopPanel.open()

# a join request (Steam invite) arrived: the panel shows it with the save picker
func coopAsk():
	coopPanel.open()
