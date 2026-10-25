extends Node

# Cell: which peers share a simulation, who is its authority, and origin adoption (M3). See docs/M3.md.

var net = null   # CoopNet

func _ready():
	name = "Cell"
