extends Node

# Fade-in for rocks RockSync builds (child of RockSync). The stock asteroid fades its sprite in over fadeInTime
# (0.5 s) from _ready, advancing by the frame's delta, so it takes 0.5 s / frame time steps: ~30 at 60 fps, but only
# 2 in a window running at 4 fps (measured: background dev windows run 200-275 ms frames; a snapshot build frame adds
# 77-100 ms), which reads as the rock blipping in. Here the fade advances by at most MAX_STEP per frame and runs after
# every rock's own _process (process_priority), overwriting the stock alpha until the ramp reaches 1: at normal frame
# rates that is exactly the stock fade, in a slow window it still takes ~5 visible steps. Rocks without the stock fade
# (mineral.gd) are left alone, as in single player.

const MAX_STEP = 0.1   # s of fade per frame, however long the frame
const LOG_EVERY = 5.0

var fading = {}   # node -> s of fade so far
var worst = 0.0   # longest frame seen while fading, since the last log line
var started = 0
var logAt = 0.0

func _ready():
	name = "RockFade"
	process_priority = 1000   # after the rocks' own _process
	set_process(false)

func add(n):
	if n == null or n.get("fade") == null or n.get("sprite") == null:
		return
	fading[n] = 0.0
	n.fade = 0.0
	started += 1
	set_process(true)

func _process(delta):
	worst = max(worst, delta)
	for n in fading.keys():
		if not is_instance_valid(n) or n.sprite == null:
			fading.erase(n)
			continue
		var t = fading[n] + min(delta, MAX_STEP)
		var a = clamp(t / n.fadeInTime, 0, 1) if n.fadeInTime > 0 else 1.0
		n.fade = a
		n.sprite.modulate.a = a
		if a >= 1.0:
			fading.erase(n)
		else:
			fading[n] = t
	logAt -= delta
	if logAt <= 0 and started > 0:
		logAt = LOG_EVERY
		Debug.l("COOP: RS fade %d rocks started, %d fading, worst frame %.0f ms (the stock fade would have jumped %.0f%%)" % [
			started, fading.size(), worst * 1000.0, min(1.0, worst * 2.0) * 100.0])
		started = 0
		worst = 0.0
	if fading.empty() and started == 0:
		set_process(false)
