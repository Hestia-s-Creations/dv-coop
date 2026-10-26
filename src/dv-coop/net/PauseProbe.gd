extends Node

# Dev probe (gate 11 harness): sends Npc's synthetic pause key from an idle frame (as the OS delivers a real key), and
# logs every "pause" event it sees in _input and _unhandled_input, and the action state for a few frames after.
# Only created by --coop-dev-pause.

var npc = null
var send = []              # events to parse on the next idle frame, as an OS key event would arrive
var restoreFocus = null    # Settings.focused to restore after the last send

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
	while not send.empty():
		var ev = send.pop_front()
		Input.parse_input_event(ev)
		npc._log("dev pause probe: sent %s from idle; right after: pressed=%s just=%s; in physics %s" % [ev.as_text(),
			Input.is_action_pressed("pause"), Input.is_action_just_pressed("pause"), Engine.is_in_physics_frame()])
		if not ev.is_pressed() and typeof(restoreFocus) != TYPE_NIL:
			Settings.focused = restoreFocus
			restoreFocus = null
	if npc.pauseProbeFrames > 0:
		npc.pauseProbeFrames -= 1
		npc._log("dev pause probe: idle frame %d: pressed=%s just=%s tree paused=%s" % [Engine.get_idle_frames(),
			Input.is_action_pressed("pause"), Input.is_action_just_pressed("pause"), get_tree().paused])
