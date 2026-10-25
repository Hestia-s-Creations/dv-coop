extends Node

# DevBot: scripted players for the M4 gate (docs/M4.md). Inert unless the game was started with --coop-bot=<mode>.
#
#   --coop-bot=race[,N]   gate 1. The cell authority picks a rock every member has and nobody owns, and sends
#                         bot.go {trial, id, at} to everyone; at wall-clock `at` (ms) every member claims it
#                         (Own.touch "bot"), holds it HOLD s if granted, then releases. Lines to count:
#                           COOP: BOT race trial=i id=... result=granted|denied:<why>|missing  (members)
#                           COOP: BOT race trial=i id=... owner=<peer> after claims, owner=<peer> after release (authority)
#                         Members log the measured clock skew to the coordinator (sent time vs local time - rtt/2);
#                         on one PC it is ~0, across machines it is what the agreed `at` is off by.
#   --coop-bot=claw[,N]   gates 2-4. Run it on a member (dev3: C, which always joins as a member). Before the
#                         dive it fits a salvage arm (SYSTEM_SALVAGE_ARM) into a weapon slot of the dev save's ship.
#                         Each trial: pick the nearest tracked rock the arm can lift, teleport so the arm's dock
#                         area covers it at matching velocity, let the stock arm lock (= Own claim), hold CLAW_HOLD s,
#                         release (arm off). Lines: COOP: BOT claw trial=i id=... result=granted|denied:<why>|nolock
#                         and, while held, "COOP: BOT claw holding id=... at x,y" every second (for gates 3 and 4).
#                         --coop-bot=claw,N,hold keeps the last rock in the claw instead of releasing it.
#   --coop-bot=laser[,N] / --coop-bot=massdriver[,N]   gates 5 and 6. On a member with that weapon: each trial picks
#                         a rock the authority owns, keeps the ship placed so the rock sits on the weapon's line
#                         of fire at matched velocity, fires for SHOOT_TIME s. Lines: COOP: BOT <mode> trial=i id=...
#                         firing / done. The damage evidence is Own's 5 s "COOP: OWN dmg" lines on every machine.

const RACE_EVERY = 3.0      # s between trials
const RACE_LEAD = 0.6       # s between bot.go and the claim instant
const RACE_HOLD = 0.8       # s a winner holds the rock before releasing
const SETTLE = 10.0         # s in a cell before the first trial
const CLAW_WAIT = 6.0       # s for the arm to lock and the claim to resolve
const CLAW_HOLD = 3.0       # s a claw trial holds its rock
const CLAW_GAP = 2.0        # s between claw trials
const CLAW_MASS = 1200.0    # salvage arm massLimit is 1500
const SHOOT_TIME = 3.0
const SHOOT_GAP = 3.0
const SHOOT_DIST = {"laser": 600.0, "massdriver": 900.0}

var net = null   # CoopNet

var mode = ""
var trials = 0
var trial = 0
var nextAt = 0.0
var inCellSince = -1.0
var plan = {}        # member: trial -> {id, at (wall ms)}
var holding = {}     # member: id -> release time (s)
var results = {}     # member: id -> trial waiting for granted / denied
var checks = []      # authority: [{trial, id, at (s), what}]
var keepLast = false # claw: hold the last rock instead of releasing it
var armFitted = false
var fitted = null    # {slot, was}: what _fit changed in CurrentGame.state.ship, restored by _restore()
var ammoAdded = 0.0
var wasDived = false
var claw = {"state": "idle", "id": "", "until": 0.0, "result": ""}
var holdLogAt = 0.0
var shoot = {"state": "idle", "id": "", "until": 0.0}
var pressed = ""     # input action held down for the current shot
var noWeaponLogged = false
var attempts = 0     # claw hold mode: failed attempts so far (each retries the same trial, up to MAX_ATTEMPTS)
const MAX_ATTEMPTS = 10
var skipIds = {}     # claw: rocks a failed attempt used; not picked again

func _ready():
	name = "DevBot"
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-bot="):
			var parts = arg.substr(11).split(",")
			mode = parts[0]
			trials = int(parts[1]) if parts.size() > 1 else 100
			keepLast = parts.size() > 2 and parts[2] == "hold"
	if mode == "":
		Debug.l("COOP: BOT inactive")
		set_physics_process(false)
		return
	Debug.l("COOP: BOT active mode=%s trials=%d" % [mode, trials])
	net.on("bot.go", self, "_onGo")
	call_deferred("_hook")

func _hook():
	var own = _own()
	if own != null:
		own.connect("granted", self, "_onGranted")
		own.connect("denied", self, "_onDenied")

func _own():
	return net.get_node_or_null("Own")

func _rs():
	return net.get_node_or_null("RockSync")

func _cell():
	var c = net.get_node_or_null("Cell")
	return c if c != null and c.has_method("inCell") else null

func _secs() -> float:
	return OS.get_ticks_msec() / 1000.0

func _physics_process(delta):
	if net.dived:
		wasDived = true
	elif wasDived:
		wasDived = false
		_restore()   # the dive ended
	if mode == "claw":
		_clawTick()
		return
	if mode == "laser" or mode == "massdriver":
		_shootTick()
		return
	if mode != "race":
		return
	var c = _cell()
	if c == null or not c.inCell():
		inCellSince = -1.0
		return
	var now = _secs()
	if inCellSince < 0:
		inCellSince = now
	if c.isAuthority():
		_coordinate(c, now)
	else:
		_member(now)

# ---------------------------------------------------------------- authority: coordinator

func _coordinate(c, now):
	for ch in checks.duplicate():
		if now >= ch.at:
			checks.erase(ch)
			var own = _own()
			Debug.l("COOP: BOT race trial=%d id=%s %s owner=%s" % [ch.trial, ch.id, ch.what, own.ownerOf(ch.id)])
	if trial >= trials or now - inCellSince < SETTLE or now < nextAt:
		return
	var members = []
	for p in c.members():
		if p != net.myId:
			members.append(p)
	if members.size() < 2:
		return   # a race needs two claimants
	var id = _pickShared(members)
	if id == "":
		return
	nextAt = now + RACE_EVERY
	trial += 1
	var at = OS.get_system_time_msecs() + int(RACE_LEAD * 1000)
	for p in members:
		net.send(p, {"t": "bot.go", "trial": trial, "id": id, "at": at, "sent": OS.get_system_time_msecs()}, true)
	checks.append({"trial": trial, "id": id, "at": now + RACE_LEAD + 0.4, "what": "after claims"})
	checks.append({"trial": trial, "id": id, "at": now + RACE_LEAD + RACE_HOLD + 0.8, "what": "after release"})
	Debug.l("COOP: BOT race trial=%d id=%s go at %d to %s" % [trial, id, at, members])
	if trial == trials:
		Debug.l("COOP: BOT race done, %d trials sent" % trials)

# A rock every member has been sent, that nobody owns and that isn't fracturing: lowest id for determinism.
func _pickShared(members) -> String:
	var rs = _rs()
	var own = _own()
	var best = ""
	for id in rs.rocks:
		var n = rs.rocks[id]
		if not is_instance_valid(n) or n.get("fracturing") == true or not rs.isStreamed(id):
			continue
		var all = true
		for p in members:
			if not rs.receivers.has(p) or not rs.receivers[p].known.has(id):
				all = false
				break
		if all and own.ownerOf(id) == net.myId and (best == "" or id < best):
			best = id
	return best

# ---------------------------------------------------------------- member: claimant

func _onGo(from, msg):
	var sent = int(msg.get("sent", 0))
	var skew = OS.get_system_time_msecs() - sent - net.stats.rtt_ms / 2.0
	plan[int(msg.trial)] = {"id": str(msg.id), "at": int(msg.at)}
	Debug.l("COOP: BOT race trial=%d id=%s scheduled, skew to coordinator %.0f ms (rtt %d)" % [msg.trial, msg.id, skew, net.stats.rtt_ms])

func _member(now):
	var wall = OS.get_system_time_msecs()
	for t in plan.keys():
		if wall >= plan[t].at:
			var id = plan[t].id
			var at = plan[t].at
			plan.erase(t)
			var node = _rs().nodeOf(id)
			if node == null:
				Debug.l("COOP: BOT race trial=%d id=%s result=missing" % [t, id])
				continue
			Debug.l("COOP: BOT race trial=%d id=%s claim at %d (late %d ms)" % [t, id, wall, wall - at])
			results[id] = t
			if _own().touch(node, "bot"):
				_onGranted(id)
	for id in holding.keys():
		if now >= holding[id]:
			holding.erase(id)
			var node = _rs().nodeOf(id)
			if node != null:
				_own().untouch(node, "bot")

# ---------------------------------------------------------------- laser / mass driver

func _findWeapon(n):
	for c in n.get_children():
		if c.has_method("fire"):
			if mode == "laser" and c.get("pulsesPerSecond") != null and c.get("ray") != null:
				return c
			if mode == "massdriver" and c.get("ammoWeight") != null and c.get("bullet") != null:
				return c
		var r = _findWeapon(c)
		if r != null:
			return r
	return null

var ammoGiven = false

func _shootTick():
	if mode == "massdriver":
		_fit("SYSTEM_EMD14", "right")
	var c = _cell()
	if c == null or not c.inCell() or c.isAuthority():
		inCellSince = -1.0
		return
	var now = _secs()
	if inCellSince < 0:
		inCellSince = now
	var ship = net.localShip
	if ship == null or not is_instance_valid(ship) or ship.get("cutscene") == true or now - inCellSince < SETTLE:
		return
	if mode == "massdriver" and not ammoGiven and ship.has_method("addAmmo"):
		ammoGiven = true
		ship.addAmmo(5000)
		ammoAdded = 5000.0
		Debug.l("COOP: BOT massdriver: +5000 kg ammo")
	var w = _findWeapon(ship)
	if w == null:
		if not noWeaponLogged:
			noWeaponLogged = true
			Debug.l("COOP: BOT %s: no %s on this ship, idle" % [mode, mode])
		return
	match shoot.state:
		"idle":
			if trial >= trials or now < shoot.until:
				return
			var id = _pickTarget()
			if id == "":
				return
			trial += 1
			shoot = {"state": "fire", "id": id, "until": now + SHOOT_TIME}
			# fire the way a player does: the ship zeroes every weapon each frame unless its command input is held
			pressed = _fireAction(ship, w)
			if pressed != "":
				Input.action_press(pressed)
			Debug.l("COOP: BOT %s trial=%d id=%s firing (action %s)" % [mode, trial, id, pressed])
		"fire":
			var rock = _rs().nodeOf(shoot.id)
			if rock == null or now >= shoot.until:
				if pressed != "":
					Input.action_release(pressed)
					pressed = ""
				Debug.l("COOP: BOT %s trial=%d id=%s done%s" % [mode, trial, shoot.id, "" if rock != null else " (rock gone)"])
				shoot = {"state": "idle", "id": "", "until": now + SHOOT_GAP}
				if trial >= trials:
					Debug.l("COOP: BOT %s done, %d trials" % [mode, trials])
				return
			var dir = Vector2(0, -1).rotated(w.global_rotation)
			var want = rock.global_position - dir * SHOOT_DIST[mode]
			var off = want - w.global_position
			if off.length() > 10.0:
				ship.global_position += off
				ship.reset_physics_interpolation()
			ship.linear_velocity = rock.linear_velocity
			ship.angular_velocity = 0.0
			w.fire(1.0)   # also directly: the stock laser tick runs before the ship's next reset (seen working in m4-gate5)
			if now >= holdLogAt:
				holdLogAt = now + 1.0
				var to = rock.global_position - w.global_position
				var side = to.cross(dir)
				var hit = w.get_world_2d().direct_space_state.intersect_ray(w.global_position, w.global_position + dir * 4000.0, ship.physicsExclude, 35)
				var what = "nothing"
				if hit:
					what = "%s%s" % [hit.collider.get_meta("dvnet") if hit.collider.has_meta("dvnet") else hit.collider.name, " (target)" if hit.collider == rock else ""]
				Debug.l("COOP: BOT %s aim id=%s along=%.0f side=%.0f ray hits %s readpower=%s energy=%.0f" % [mode, shoot.id, to.dot(dir), side, what, w.get("readpower"), ship.get("energy") if ship.get("energy") != null else -1])

# The input action that fires `w`: its own command letter, or its weapon slot's.
func _fireAction(ship, w) -> String:
	var n = w
	while n != null and n != ship:
		var cmd = n.get("command")
		if cmd is String and cmd != "" and ship.has_method("actionForEvent"):
			return ship.actionForEvent(cmd.substr(0, 1))
		n = n.get_parent()
	Debug.l("COOP: BOT %s: no command letter found for %s" % [mode, w.name])
	return ""

# A rock the authority owns and streams, not held by anyone: the nearest one, preferring heavy rocks (they last).
func _pickTarget() -> String:
	var rs = _rs()
	var ship = net.localShip
	var best = ""
	var bestD = 0.0
	for id in rs.tracked:
		var n = rs.tracked[id].n
		if not is_instance_valid(n) or n.get("fracturing") == true or _own().owners.has(id) or n.mass < 300:
			continue
		var d = n.global_position.distance_to(ship.global_position)
		if best == "" or d < bestD:
			best = id
			bestD = d
	return best

# ---------------------------------------------------------------- claw

# Fit a salvage arm into the dev save's ship right after autodive loads the save, before the Game scene builds it.
func _fitArm():
	_fit("SYSTEM_SALVAGE_ARM", "left")

# Fit `system` into a weapon slot of the dev save's ship right after autodive loads the save, before the Game
# scene builds the ship (dev data only; the bot never runs without its flag).
func _fit(system, prefer):
	if armFitted or not net.autoDiveStarted:
		return
	armFitted = true
	var cfg = CurrentGame.state.ship.get("config", {})
	var ws = cfg.get("weaponSlot", {})
	if ws.empty():
		Debug.l("COOP: BOT %s: ship has no weapon slots in its config, cannot fit %s" % [mode, system])
		return
	for k in ws:
		if ws[k].get("type") == system:
			Debug.l("COOP: BOT %s: %s already fitted in weaponSlot.%s" % [mode, system, k])
			return
	var slot = prefer if ws.has(prefer) else ws.keys()[0]
	Debug.l("COOP: BOT %s: fitting %s to weaponSlot.%s (was %s)" % [mode, system, slot, ws[slot].get("type")])
	fitted = {"slot": slot, "was": ws[slot].get("type")}
	ws[slot]["type"] = system

# Put the dev save's ship back as it was: the fitting lives in CurrentGame.state.ship (the live ship's shipConfig is
# that same dict), so undo it before anything could save it. Runs when the dive ends, on quit and on exit.
func _restore():
	if fitted != null:
		var ws = CurrentGame.state.ship.get("config", {}).get("weaponSlot", {})
		if ws.has(fitted.slot):
			ws[fitted.slot]["type"] = fitted.was
			Debug.l("COOP: BOT restored weaponSlot.%s to %s" % [fitted.slot, fitted.was])
		fitted = null
	if ammoAdded > 0:
		var ship = net.localShip
		if ship != null and is_instance_valid(ship) and ship.has_method("drawAmmo"):
			ship.drawAmmo(ammoAdded)
			Debug.l("COOP: BOT took back %.0f kg ammo" % ammoAdded)
		ammoAdded = 0.0

func _notification(what):
	if what == NOTIFICATION_WM_QUIT_REQUEST or what == NOTIFICATION_PREDELETE:
		_restore()

func _exit_tree():
	_restore()

func _arm():
	var ship = net.localShip
	if ship == null or not is_instance_valid(ship):
		return null
	return _findArm(ship)

func _findArm(n):
	for c in n.get_children():
		if c.has_method("isValidTarget") and c.has_method("switchTarget"):
			return c
		var r = _findArm(c)
		if r != null:
			return r
	return null

func _clawTick():
	_fitArm()
	var c = _cell()
	if c == null or not c.inCell() or c.isAuthority():
		inCellSince = -1.0
		return
	var now = _secs()
	if inCellSince < 0:
		inCellSince = now
	var arm = _arm()
	var ship = net.localShip
	if arm == null or ship == null or ship.get("cutscene") == true or now - inCellSince < SETTLE:
		return
	match claw.state:
		"idle":
			if trial >= trials or now < claw.until:
				return
			var id = _pickClawRock(ship)
			if id == "":
				return
			trial += 1
			claw = {"state": "reach", "id": id, "until": now + CLAW_WAIT, "result": ""}
			results[id] = trial
			arm.enabled = true
			Debug.l("COOP: BOT claw trial=%d id=%s reaching" % [trial, id])
		"reach":
			var rock = _rs().nodeOf(claw.id)
			if rock == null:
				_clawEnd(arm, "missing", now)
				return
			# keep the dock area on the rock until the arm locks
			var area = arm.get("areaDockArea")
			if area != null and not arm.locked:
				var off = rock.global_position - area.global_position
				if off.length() > 20.0:
					ship.global_position += off
					ship.linear_velocity = rock.linear_velocity
					ship.reset_physics_interpolation()
			if claw.result != "":
				if claw.result == "granted":
					claw.state = "hold"
					claw.until = now + CLAW_HOLD
				else:
					_clawEnd(arm, claw.result, now)
			elif now > claw.until:
				_clawEnd(arm, "nolock" if not arm.locked else "nolock:locked-no-answer", now)
		"hold":
			if keepLast and trial >= trials and not _own().mine.has(claw.id) and not arm.locked:
				_clawEnd(arm, "lost", now)   # the arm let go (or ownership was revoked): hold mode tries again
				return
			if now >= holdLogAt:
				holdLogAt = now + 1.0
				var rock = _rs().nodeOf(claw.id)
				if rock != null:
					var g = CurrentGame.globalCoords(rock.global_position)
					Debug.l("COOP: BOT claw holding id=%s at %.0f,%.0f locked=%s mine=%s" % [claw.id, g.x, g.y, arm.locked, _own().mine.has(claw.id)])
			if now >= claw.until and not (keepLast and trial >= trials):
				_clawEnd(arm, "", now)

func _clawEnd(arm, result, now):
	if result != "":
		Debug.l("COOP: BOT claw trial=%d id=%s result=%s" % [trial, claw.id, result])
		if keepLast and attempts < MAX_ATTEMPTS:
			attempts += 1
			skipIds[claw.id] = true
			trial -= 1   # hold mode needs a rock in the claw: try again with another rock
	results.erase(claw.id)
	arm.enabled = false
	claw = {"state": "idle", "id": "", "until": now + CLAW_GAP, "result": ""}
	if trial >= trials:
		Debug.l("COOP: BOT claw done, %d trials" % trials)

func _pickClawRock(ship) -> String:
	var rs = _rs()
	var best = ""
	var bestD = 0.0
	for id in rs.tracked:
		var n = rs.tracked[id].n
		if not is_instance_valid(n) or n.mass > CLAW_MASS or n.get("fracturing") == true or _own().owners.has(id) 				or skipIds.has(id):
			continue
		var d = n.global_position.distance_to(ship.global_position)
		if best == "" or d < bestD:
			best = id
			bestD = d
	return best

func _onGranted(id):
	if mode == "claw":
		if claw.id == id and claw.state == "reach":
			claw.result = "granted"
			Debug.l("COOP: BOT claw trial=%d id=%s result=granted" % [trial, id])
		return
	if not results.has(id):
		return
	Debug.l("COOP: BOT race trial=%d id=%s result=granted" % [results[id], id])
	results.erase(id)
	holding[id] = _secs() + RACE_HOLD

func _onDenied(id, why):
	if mode == "claw":
		if claw.id == id and claw.state == "reach":
			claw.result = "denied:" + str(why)
		return
	if not results.has(id):
		return
	Debug.l("COOP: BOT race trial=%d id=%s result=denied:%s" % [results[id], id, why])
	results.erase(id)
