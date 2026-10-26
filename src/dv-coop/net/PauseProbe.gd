extends Node

# Dev probe (gate 11 harness): logs every "pause" input event this node sees, in _input and in _unhandled_input,
# and the "pause" action state for a few frames after Npc's synthetic press. Only created by --coop-dev-pause.

var npc = null

func _ready():
	pause_mode = Node.PAUSE_MODE_PROCESS

func _input(ev):
	if ev.is_action("pause"):
		npc._log("dev pause probe: _input sees %s pressed=%s; just=%s; focused=%s" % [ev.as_text(), ev.is_pressed(),
			Input.is_action_just_pressed("pause"), Settings.focused])

func _unhandled_input(ev):
	if ev.is_action("pause"):
		npc._log("dev pause probe: _unhandled_input sees %s pressed=%s; just=%s" % [ev.as_text(), ev.is_pressed(),
			Input.is_action_just_pressed("pause")])

func _process(_delta):
	if npc.pauseProbeFrames > 0:
		npc.pauseProbeFrames -= 1
		npc._log("dev pause probe: idle frame %d: pressed=%s just=%s tree paused=%s" % [Engine.get_idle_frames(),
			Input.is_action_pressed("pause"), Input.is_action_just_pressed("pause"), get_tree().paused])
