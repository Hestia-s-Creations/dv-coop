extends Node

# Drives an extension's physics tick in place of the node's own physics processing.
#
# Godot 3 calls _physics_process on every level of a script chain by itself (derived first, then the stock
# one), so an extension can't run code around the stock tick by overriding it. Instead the extension turns
# its node's physics processing off, adds one of these as a child, and gets coopTick(delta) here, where it
# calls ._physics_process(delta) (the stock tick) inside whatever context it needs.

var target = null

static func attach(node):
	node.set_physics_process(false)
	var t = load("res://dv-coop/net/Tick.gd").new()
	t.name = "CoopTick"
	t.target = node
	node.add_child(t)

func _physics_process(delta):
	if target != null and is_instance_valid(target):
		target.coopTick(delta)
