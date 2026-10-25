extends Node

# RockSync: net ids for world bodies, the authority's rock stream, and members' tracked rocks (M3). See docs/M3.md.

var net = null   # CoopNet

func _ready():
	name = "RockSync"
