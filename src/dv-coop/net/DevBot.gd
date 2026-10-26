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
#   --coop-bot=claw[,N]   gates 3-4. Run it on a member whose dev save's ship carries a salvage arm (the bot never
#                         changes a loadout). Each trial: pick the nearest tracked rock the arm can lift, teleport so the arm's dock
#                         area covers it at matching velocity, let the stock arm lock (= Own claim), hold CLAW_HOLD s,
#                         release (arm off). Lines: COOP: BOT claw trial=i id=... result=granted|denied:<why>|nolock
#                         and, while held, "COOP: BOT claw holding id=... at x,y" every second (for gates 3 and 4).
#                         --coop-bot=claw,N,hold keeps the last rock in the claw instead of releasing it.
#   --coop-bot=frac[,N]   gate 2, on every instance. The authority picks a rock a member can lift and that splits,
#                         sends bot.frac {trial, id, at}, and at wall-clock `at` pushes it past its split threshold
#                         (only if it still owns it). The member (salvage arm on its ship) reaches for it so the lock lands
#                         around `at`. Lines: COOP: BOT frac trial=i id=... result=rock (claim granted first) |
#                         shards (denied: fracturing, then the arm took a shard) | neither.
#                         --coop-bot=frac,N,noarm: the member claims directly (Own.touch) at `at` +-jitter instead of
#                         with an arm, and after a "fracturing" deny claims the first new rock near the parent.
#   --coop-bot=mpu[,N]    gate 10 with a real MPU, on a member whose dev save's ship has one. Each trial picks the
#                         nearest tracked rock nobody owns, keeps the ship placed so the MPU intake covers it at matched
#                         velocity, and lets the stock MPU claim (Own.touch "mpu"), process and free it (o.eat). Lines:
#                         COOP: BOT mpu trial=i id=... result=eaten|denied:<why>|nograb|timeout, and "no MPU" if none.
#   --coop-bot=haul[,N]   on a member whose ship has haul drones (SYSTEM_DND_HAUL; Cothon-V in savegame.dv). Each
#                         trial places the ship HAUL_OFFSET px from the nearest tracked mineral rock nobody owns (haul
#                         drones only take "pickable" rocks), switches the haul plants on and watches HAUL_TIME s while
#                         the drones claim it (Own.touchFor "haul") and push it to the excavator (the MPU intake).
#                         Lines: COOP: BOT haul trial=i id=... d0=<px to excavator> ... result=eaten|closer|nograb
#                         owned=<did we own it while hauling> d1=<px at the end>.
#   --coop-bot=laser[,N] / --coop-bot=massdriver[,N]   gates 5 and 6. On a member with that weapon: each trial picks
#                         a rock the authority owns, keeps the ship placed so the rock sits on the weapon's line
#                         of fire at matched velocity, fires for SHOOT_TIME s. Lines: COOP: BOT <mode> trial=i id=...
#                         firing / done. The damage evidence is Own's 5 s "COOP: OWN dmg" lines on every machine.
#   --coop-bot=eat[,N]    gate 10 (protocol level, no MPU fitted), on a member. Each trial claims a tracked rock the
#                         authority owns (outside the frac bot's pool, mineral rocks first), strips half its filler
#                         (ice rocks: half their mass) the way the MPU does,
#                         then frees it the way the MPU does (disabled layer, deferred Tool.remove), so Own sends o.eat.
#                         Nothing goes into ship state. Lines: COOP: BOT eat trial=i id=... granted comp=... /
#                         result=denied:<why>|noanswer. The authority's evidence is "COOP: OWN eat-audit" + conserve.

const RACE_EVERY = 3.0      # s between trials
const RACE_LEAD = 0.6       # s between bot.go and the claim instant
const RACE_HOLD = 0.8       # s a winner holds the rock before releasing
const SETTLE = 10.0         # s in a cell before the first trial
const CLAW_WAIT = 6.0       # s for the arm to lock and the claim to resolve
const CLAW_HOLD = 3.0       # s a claw trial holds its rock
const CLAW_GAP = 2.0        # s between claw trials
const CLAW_MASS = 1200.0    # salvage arm massLimit is 1500
const FRAC_EVERY = 8.0       # s between fracture-race trials
const FRAC_LEAD = 1.5        # s between bot.frac and the fracture instant
const FRAC_SHARD_WAIT = 6.0  # s a member whose claim lost to the fracture chases a shard with its arm
const FRAC_ARM_LEAD = 1.2    # s before the fracture instant the arm starts reaching, at most (random per trial)
const FRAC_REACH_AFTER = 3.0 # s after that the reach gives up on the parent (it should have locked or broken)
const FRAC_EVERY_ARM = 12.0  # s between trials with a real arm: lead + reach + shard chase
const EAT_EVERY = 4.0        # s between eat trials
const MPU_WAIT = 6.0         # s for the intake to take a rock and the claim to resolve
const MPU_EAT = 90.0         # s for the MPU to finish processing it
const HAUL_OFFSET = 700.0   # px from the rock to the ship when a haul trial starts
const HAUL_TIME = 40.0      # s a haul trial watches the drones
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
var claw = {"state": "idle", "id": "", "until": 0.0, "result": ""}
var holdLogAt = 0.0
var shoot = {"state": "idle", "id": "", "until": 0.0}
var pressed = ""     # input action held down for the current shot
var noWeaponLogged = false
var frac = {"state": "idle"}  # member: {state, trial, id, at (wall ms), until (s), pos}
var fracPlan = []             # authority: [{trial, id, at}]
var fracWatch = []            # authority: [{trial, id, pos, until, n}] counting the shards each fracture spawned
var noArm = false             # frac,N,noarm: claim through Own directly (protocol race, no salvage arm needed)
var attempts = 0     # claw hold mode: failed attempts so far (each retries the same trial, up to MAX_ATTEMPTS)
const MAX_ATTEMPTS = 10
var skipIds = {}     # claw: rocks a failed attempt used; not picked again
var eatJob = {"id": "", "until": 0.0, "result": ""}
var mpuJob = {"state": "idle", "id": "", "until": 0.0}   # mpu: feed (intake on the rock, claim pending) -> eat
var mpuChecked = false
var haulJob = {"state": "idle", "id": "", "until": 0.0}   # haul: watch -> result

func _ready():
	name = "DevBot"
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-bot="):
			var parts = arg.substr(11).split(",")
			mode = parts[0]
			trials = int(parts[1]) if parts.size() > 1 else 100
			keepLast = parts.size() > 2 and parts[2] == "hold"
			noArm = parts.size() > 2 and parts[2] == "noarm"
	if mode == "":
		Debug.l("COOP: BOT inactive")
		set_physics_process(false)
		return
	Debug.l("COOP: BOT active mode=%s trials=%d" % [mode, trials])
	net.on("bot.go", self, "_onGo")
	net.on("bot.frac", self, "_onFrac")
	call_deferred("_hook")

func _hook():
	var own = _own()
	if own != null:
		own.connect("granted", self, "_onGranted")
		own.connect("denied", self, "_onDenied")
	var rs = _rs()
	if rs != null:
		rs.connect("rock_born", self, "_onRockBorn")

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
	_fitArm()
	if mode == "claw":
		_clawTick()
		return
	if mode == "laser" or mode == "massdriver":
		_shootTick()
		return
	if mode == "frac":
		_fracTick()
		return
	if mode == "eat":
		_eatTick()
		return
	if mode == "mpu":
		_mpuTick()
		return
	if mode == "haul":
		_haulTick()
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

# ---------------------------------------------------------------- ore audit (gate 10)

func _eatTick():
	var c = _cell()
	if c == null or not c.inCell() or c.isAuthority():
		inCellSince = -1.0
		return
	var now = _secs()
	if inCellSince < 0:
		inCellSince = now
	var rs = _rs()
	if eatJob.id != "":
		var n = rs.nodeOf(eatJob.id)
		if eatJob.result == "granted":
			if n == null:
				Debug.l("COOP: BOT eat trial=%d id=%s result=lost (gone before the eat)" % [trial, eatJob.id])
			else:
				_mpuEat(n)
			eatJob.id = ""
		elif eatJob.result.begins_with("denied"):
			Debug.l("COOP: BOT eat trial=%d id=%s result=%s" % [trial, eatJob.id, eatJob.result])
			eatJob.id = ""
		elif now > eatJob.until:
			Debug.l("COOP: BOT eat trial=%d id=%s result=noanswer" % [trial, eatJob.id])
			if n != null:
				_own().untouch(n, "bot")
			eatJob.id = ""
		return
	if trial >= trials or now - inCellSince < SETTLE or now < nextAt:
		return
	var own = _own()
	var best = ""
	var bestKey = ""
	for id in rs.tracked:
		var n = rs.tracked[id].n
		if not is_instance_valid(n) or n.get("fracturing") == true or own.owners.has(id) and own.owners[id] != c.authority():
			continue
		if n.get("asteroidClass") != null and n.asteroidClass < 4 and n.get("mineralContent") == null:
			continue   # the frac bot's pool (gate 2 may run alongside); mineral rocks are fine to take
		var key = ("0" if n.get("mineralContent") != null else "1") + id   # mineral rocks first
		if best == "" or key < bestKey:
			best = id
			bestKey = key
	if best == "":
		return
	nextAt = now + EAT_EVERY
	trial += 1
	eatJob = {"id": best, "until": now + 3.0, "result": ""}
	if own.touch(rs.nodeOf(best), "bot"):
		eatJob.result = "granted"

# Real MPU: hold the intake on a rock until the stock MPU has processed and freed it.

func _mpu():
	var ship = net.localShip
	if ship == null or not is_instance_valid(ship):
		return null
	return _findMpu(ship)

func _findMpu(n):
	for c in n.get_children():
		if c.get("processing") != null and c.has_method("_on_MineralProcessingUnit_body_entered"):
			return c
		var r = _findMpu(c)
		if r != null:
			return r
	return null

func _mpuTick():
	var ship = net.localShip
	if ship == null or not is_instance_valid(ship) or ship.get("setup") != true:
		return
	var mpu = _mpu()
	if not mpuChecked:
		mpuChecked = true
		if mpu == null:
			Debug.l("COOP: BOT mpu: no MPU on this ship (the bot never changes a loadout); use a dev save that has one")
	var c = _cell()
	if mpu == null or c == null or not c.inCell() or c.isAuthority():
		inCellSince = -1.0
		return
	var now = _secs()
	if inCellSince < 0:
		inCellSince = now
	if ship.get("cutscene") == true or now - inCellSince < SETTLE:
		return
	var rs = _rs()
	var own = _own()
	match mpuJob.state:
		"idle":
			if trial >= trials or now < mpuJob.until:
				return
			var best = ""
			var bestD = 0.0
			for id in rs.tracked:
				var n = rs.tracked[id].n
				if not is_instance_valid(n) or n.get("fracturing") == true or own.owners.has(id) or skipIds.has(id):
					continue
				var d = n.global_position.distance_to(ship.global_position)
				if best == "" or d < bestD:
					best = id
					bestD = d
			if best == "":
				return
			trial += 1
			skipIds[best] = true
			mpuJob = {"state": "feed", "id": best, "until": now + MPU_WAIT}
			Debug.l("COOP: BOT mpu trial=%d id=%s feeding" % [trial, best])
		"feed", "eat":
			var rock = rs.nodeOf(mpuJob.id)
			if rock == null or not is_instance_valid(rock):
				# freed: an eat if we owned it up to the end (Own logged "eat <id> (mpu)")
				_mpuEnd("eaten" if mpuJob.state == "eat" else "missing", now)
				return
			var area = mpu.get_node_or_null("MineralProcessingUnit")
			if area != null:
				var off = rock.global_position - area.global_position
				if off.length() > 10.0:
					ship.global_position += off
					ship.reset_physics_interpolation()
				ship.linear_velocity = rock.linear_velocity
			if mpuJob.state == "feed":
				if own.mine.has(mpuJob.id) and mpu.processing.has(rock):
					mpuJob.state = "eat"
					mpuJob.until = now + MPU_EAT
					Debug.l("COOP: BOT mpu trial=%d id=%s processing comp=%s" % [trial, mpuJob.id, rock.getComposition() if rock.has_method("getComposition") else {}])
				elif now > mpuJob.until:
					_mpuEnd("nograb", now)
			elif now > mpuJob.until:
				_mpuEnd("timeout", now)

func _mpuEnd(result, now):
	Debug.l("COOP: BOT mpu trial=%d id=%s result=%s" % [trial, mpuJob.id, result])
	mpuJob = {"state": "idle", "id": "", "until": now + CLAW_GAP}
	if trial >= trials:
		Debug.l("COOP: BOT mpu done, %d trials" % trials)

# ---------------------------------------------------------------- haul drones

func _haulPlants(n, out):
	for c in n.get_children():
		if c.get("droneFunction") == "haul" and c.has_method("scanForTarget"):
			out.append(c)
		else:
			_haulPlants(c, out)
	return out

func _haulTick():
	var ship = net.localShip
	var c = _cell()
	if ship == null or not is_instance_valid(ship) or c == null or not c.inCell() or c.isAuthority() or not armFitted:
		inCellSince = -1.0
		return
	var now = _secs()
	if inCellSince < 0:
		inCellSince = now
	if ship.get("cutscene") == true or now - inCellSince < SETTLE:
		return
	var plants = _haulPlants(ship, [])
	if plants.empty():
		if not noWeaponLogged:
			noWeaponLogged = true
			Debug.l("COOP: BOT haul: no haul drones on this ship (the bot never changes a loadout)")
		return
	var rs = _rs()
	var own = _own()
	match haulJob.state:
		"idle":
			if trial >= trials or now < haulJob.until:
				return
			var best = ""
			var bestD = 0.0
			for id in rs.tracked:
				var n = rs.tracked[id].n
				if not is_instance_valid(n) or not n.is_in_group("pickable") or n.get("fracturing") == true \
						or own.owners.has(id) or skipIds.has(id):
					continue
				var d = n.global_position.distance_to(ship.global_position)
				if best == "" or d < bestD:
					best = id
					bestD = d
			if best == "":
				return
			trial += 1
			skipIds[best] = true
			var rock = rs.nodeOf(best)
			var away = (ship.global_position - rock.global_position).normalized()
			if away == Vector2.ZERO:
				away = Vector2(0, 1)
			ship.global_position = rock.global_position + away * HAUL_OFFSET
			ship.linear_velocity = rock.linear_velocity
			ship.reset_physics_interpolation()
			for p in plants:
				p.enabled = true
			haulJob = {"state": "watch", "id": best, "until": now + HAUL_TIME, "d0": _toExcavator(plants, rock),
				"owned": false, "logAt": now + 2.0}
			Debug.l("COOP: BOT haul trial=%d id=%s d0=%.0f placed" % [trial, best, haulJob.d0])
		"watch":
			var rock = rs.nodeOf(haulJob.id)
			if rock == null or not is_instance_valid(rock):
				_haulEnd(plants, "eaten", -1.0, now)
				return
			if own.mine.has(haulJob.id):
				haulJob.owned = true
			var d = _toExcavator(plants, rock)
			if now >= haulJob.logAt:
				haulJob.logAt = now + 2.0
				Debug.l("COOP: BOT haul trial=%d id=%s d=%.0f mine=%s" % [trial, haulJob.id, d, own.mine.has(haulJob.id)])
			if now > haulJob.until:
				_haulEnd(plants, "closer" if d < haulJob.d0 - 200.0 else "nograb", d, now)

func _toExcavator(plants, rock) -> float:
	for p in plants:
		var x = p.get("excavator")
		if x != null and is_instance_valid(x):
			return rock.global_position.distance_to(x.global_position)
	return rock.global_position.distance_to(net.localShip.global_position)

func _haulEnd(plants, result, d, now):
	Debug.l("COOP: BOT haul trial=%d id=%s result=%s owned=%s d0=%.0f d1=%.0f" % [trial, haulJob.id, result, haulJob.owned,
		haulJob.d0, d])
	for p in plants:
		p.enabled = false
	haulJob = {"state": "idle", "id": "", "until": now + CLAW_GAP + 3.0}   # past the claim's linger
	if trial >= trials:
		Debug.l("COOP: BOT haul done, %d trials" % trials)

# What the MPU does to a rock it owns: strip filler (mass drops, the mineral stays), then free it on the disabled
# layer. Own sees it leave and sends o.eat with what is left.
func _mpuEat(n):
	var before = n.getComposition().duplicate() if n.has_method("getComposition") else {}
	if n.get("mineralContent") != null and n.get("fillerContent") != null and n.fillerContent > 0.05:
		var mm = n.mass * n.mineralContent
		var nm = max(mm, n.mass - n.fillerContent * n.mass * 0.5)
		if nm > 0:
			n.mass = nm
			n.mineralContent = mm / nm
		n.fillerContent = 1 - n.mineralContent
	elif n.get("mineralContent") == null:
		n.mass *= 0.5   # an ice rock: the MPU turns it into reactive mass
	Debug.l("COOP: BOT eat trial=%d id=%s granted comp=%s left=%s" % [trial, n.get_meta("dvnet"), before,
		n.getComposition() if n.has_method("getComposition") else {}])
	Tool.release(n)
	n.collision_mask = 0
	n.collision_layer = 2147483648
	Tool.deferCallInPhysics(Tool, "remove", [n])

# ---------------------------------------------------------------- fracture race (gate 2)

func _fracTick():
	_fitArm()
	var c = _cell()
	if c == null or not c.inCell():
		inCellSince = -1.0
		return
	var now = _secs()
	if inCellSince < 0:
		inCellSince = now
	if c.isAuthority():
		_fracCoordinate(c, now)
	else:
		_fracMember(now)

func _fracCoordinate(c, now):
	var wall = OS.get_system_time_msecs()
	for f in fracPlan.duplicate():
		if wall >= f.at:
			fracPlan.erase(f)
			var n = _rs().nodeOf(f.id)
			if n == null:
				Debug.l("COOP: BOT frac trial=%d id=%s fracture skipped (gone)" % [f.trial, f.id])
			elif _own().owners.has(f.id):
				Debug.l("COOP: BOT frac trial=%d id=%s fracture skipped (owned by %s)" % [f.trial, f.id, _own().owners[f.id]])
			else:
				n.totalEnergy = n.splitEnergyThreshold * 1.5
				n.set_physics_process(true)
				n.set_process(true)   # fractureTime counts down in _process; the stock damage path wakes both
				fracWatch.append({"trial": f.trial, "id": f.id, "pos": n.global_position, "until": now + 3.5, "n": 0})
				Debug.l("COOP: BOT frac trial=%d id=%s fracture set" % [f.trial, f.id])
	for w in fracWatch.duplicate():
		if now >= w.until:
			fracWatch.erase(w)
			Debug.l("COOP: BOT frac trial=%d id=%s shards spawned=%d" % [w.trial, w.id, w.n])
	if trial >= trials or now - inCellSince < SETTLE or now < nextAt:
		return
	var members = []
	for p in c.members():
		if p != net.myId:
			members.append(p)
	if members.empty():
		return
	var rs = _rs()
	var best = ""
	for id in rs.rocks:
		var n = rs.rocks[id]
		if not is_instance_valid(n) or n.get("fracturing") == true or not rs.isStreamed(id) or not noArm and n.mass > CLAW_MASS:
			continue
		if n.get("asteroidClass") == null or n.asteroidClass >= 4 or n.get("splitEnergyThreshold") == null:
			continue
		if n.get("mineralContent") != null:
			continue   # the eat bot's (gate 10 may run alongside)
		if net.localShip == null or n.global_position.distance_to(net.localShip.global_position) > 10000.0:
			continue   # stock fracture spawns shards only inside the authority's simulator range (12 km of its ship)
		var all = true
		for p in members:
			if not rs.receivers.has(p) or not rs.receivers[p].known.has(id):
				all = false
				break
		if all and (best == "" or id < best):
			best = id
	if best == "":
		return
	nextAt = now + (FRAC_EVERY if noArm else FRAC_EVERY_ARM)
	trial += 1
	var at = OS.get_system_time_msecs() + int(FRAC_LEAD * 1000)
	fracPlan.append({"trial": trial, "id": best, "at": at})
	for p in members:
		net.send(p, {"t": "bot.frac", "trial": trial, "id": best, "at": at}, true)
	Debug.l("COOP: BOT frac trial=%d id=%s at %d" % [trial, best, at])

func _onRockBorn(id, node):
	for w in fracWatch:
		if node.global_position.distance_to(w.pos) < 1500.0:
			w.n += 1

func _onFrac(from, msg):
	if mode != "frac" or frac.state != "idle":
		return
	frac = {"state": "wait", "trial": int(msg.trial), "id": str(msg.id), "at": int(msg.at), "until": 0.0, "pos": null}
	var n = _rs().nodeOf(frac.id)
	if n != null:
		frac.pos = n.global_position

func _fracMember(now):
	if noArm:
		_fracClaim(now)
		return
	var arm = _arm()
	var ship = net.localShip
	if arm == null or ship == null or ship.get("cutscene") == true:
		return
	var wall = OS.get_system_time_msecs()
	var rs = _rs()
	match frac.state:
		"wait":
			if not frac.has("lead"):
				# the stock arm locks 0-1 s after its dock area covers a rock: start reaching up to FRAC_ARM_LEAD early,
				# at random, so both orders (lock first / fracture first) occur
				frac.lead = int(rand_range(0, FRAC_ARM_LEAD * 1000))
				frac.before = {}
				for id in rs.tracked:
					frac.before[id] = true
				for p in _haulPlants(ship, []):
					p.enabled = false   # the ship's own haul drones would claim the rocks we race for
			if wall >= frac.at - frac.lead:
				frac.state = "reach"
				frac.until = now + frac.lead / 1000.0 + FRAC_REACH_AFTER
				claw.id = frac.id
				claw.result = ""
				arm.enabled = true
		"reach":
			var rock = rs.nodeOf(frac.id)
			if rock != null:
				frac.pos = rock.global_position
				_aimArm(arm, ship, rock.global_position, rock.linear_velocity)
			if claw.result == "granted":
				_fracEnd(arm, "rock", now)
			elif claw.result.begins_with("denied") or rock == null:
				# the fracture won (denied "fracturing", or the parent already left our field): go for a shard
				frac.state = "shards"
				frac.until = now + FRAC_SHARD_WAIT
				frac.skip = {}
				claw.id = ""
				claw.result = ""
				Debug.l("COOP: BOT frac trial=%d id=%s parent %s, reaching for a shard" % [frac.trial, frac.id,
					"gone" if rock == null else claw.result])
			elif now > frac.until:
				_fracEnd(arm, "neither", now)
		"shards":
			for id in _own().mine:
				if id != frac.id and not frac.before.has(id):
					_fracEnd(arm, "shards", now, id)
					return
			if claw.id != "" and (claw.result.begins_with("denied") or rs.nodeOf(claw.id) == null):
				frac.skip[claw.id] = true
				claw.id = ""
				claw.result = ""
			if claw.id == "" and frac.pos != null:
				var best = ""
				var bestD = 0.0
				for id in rs.tracked:
					var n = rs.tracked[id].n
					if frac.before.has(id) or frac.skip.has(id) or not is_instance_valid(n) or n.mass > CLAW_MASS:
						continue
					var d = n.global_position.distance_to(frac.pos)
					if d < 1500.0 and (best == "" or d < bestD):
						best = id
						bestD = d
				claw.id = best
			var shard = rs.nodeOf(claw.id) if claw.id != "" else null
			if shard != null:
				_aimArm(arm, ship, shard.global_position, shard.linear_velocity)
			if now > frac.until:
				_fracEnd(arm, "neither", now)

# Keep the arm's dock area on `at`, moving with the target, until the stock arm locks.
func _aimArm(arm, ship, at, vel):
	var area = arm.get("areaDockArea")
	if area == null or arm.locked:
		return
	var off = at - area.global_position
	if off.length() > 20.0:
		ship.global_position += off
		ship.reset_physics_interpolation()
	ship.linear_velocity = vel

# Protocol race without an arm: claim at the agreed instant (jittered so either side can win), then shards.
func _fracClaim(now):
	var wall = OS.get_system_time_msecs()
	var rs = _rs()
	for id in holding.keys():
		if now >= holding[id]:
			holding.erase(id)
			var hn = rs.nodeOf(id)
			if hn != null:
				_own().untouch(hn, "bot")
	match frac.state:
		"wait":
			if not frac.has("jit"):
				frac.jit = int(rand_range(-150, 400))   # both orders occur: the fracture flag appears a tick after `at`
				frac.before = {}
				for id in rs.tracked:
					frac.before[id] = true
			if wall >= frac.at + frac.jit:
				var n = rs.nodeOf(frac.id)
				if n == null:
					# the authority's fracture won: the parent left the stream before our claim. Go for its shards.
					frac.state = "shards"
					frac.until = _secs() + FRAC_SHARD_WAIT
					claw.id = ""
					claw.result = ""
					return
				frac.pos = n.global_position
				frac.state = "claim"
				frac.until = now + 3.0
				claw.id = frac.id
				claw.result = ""
				if _own().touch(n, "bot"):
					claw.result = "granted"
		"claim":
			if claw.result == "granted":
				_fracDone("rock", frac.id, "jitter %d ms" % frac.jit)
			elif claw.result.begins_with("denied"):
				frac.state = "shards"
				frac.until = now + FRAC_SHARD_WAIT
				claw.id = ""
				claw.result = ""
			elif now > frac.until:
				_fracDone("neither", "", "no answer")
		"shards":
			if claw.id != "":
				if claw.result == "granted":
					_fracDone("shards", claw.id, "jitter %d ms" % frac.jit)
					return
				if claw.result.begins_with("denied"):
					claw.id = ""
					claw.result = ""
			else:
				for id in rs.tracked:
					var n = rs.tracked[id].n
					if not frac.before.has(id) and id != frac.id and is_instance_valid(n) and frac.pos != null \
							and n.global_position.distance_to(frac.pos) < 1500.0:
						claw.id = id
						claw.result = ""
						if _own().touch(n, "bot"):
							claw.result = "granted"
						break
			if now > frac.until:
				var newIds = 0
				var nearest = -1.0
				for id in rs.tracked:
					var tn = rs.tracked[id].n
					if not frac.before.has(id) and is_instance_valid(tn):
						newIds += 1
						if frac.pos != null:
							var d = tn.global_position.distance_to(frac.pos)
							if nearest < 0 or d < nearest:
								nearest = d
				_fracDone("neither", "", "no shard claimed; %d new tracked rocks, nearest %.0f px from the parent, pos known %s" % [newIds, nearest, frac.pos != null])

func _fracDone(result, got, note):
	Debug.l("COOP: BOT frac trial=%d id=%s result=%s%s (%s)" % [frac.trial, frac.id, result, "" if got == "" else " got=%s" % got, note])
	if got != "":
		holding[got] = _secs() + 1.0   # release after a second (member tick in race mode does the release)
	claw.id = ""
	claw.result = ""
	frac = {"state": "idle"}

func _fracEnd(arm, result, now, got = ""):
	Debug.l("COOP: BOT frac trial=%d id=%s result=%s%s" % [frac.trial, frac.id, result, "" if got == "" else " (holding %s)" % got])
	arm.enabled = false
	claw.id = ""
	claw.result = ""
	frac = {"state": "idle"}

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


func _shootTick():
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

# The bot never changes a ship's loadout: that would mean writing CurrentGame.state.ship, which a save could persist.
# Claw / frac modes need a dev save whose ship already carries a salvage arm, massdriver mode one with a mass driver
# (dev3: SLOT_B=savegame-b.dv puts the TRTL, which has an EMD-14, on B).
# Read-only loadout check. Weapon slots mount their systems when idle after ship setup (WeaponSlot.loadPlaceholder),
# so wait until no slot is still a placeholder, then log every slot and whether an arm and an MPU are there:
#   COOP: BOT loadout ship=<name> arm=<bool> mpu=<bool> slots=[slot=SYSTEM_X, ...]
func _fitArm():
	var ship = net.localShip
	if armFitted or ship == null or not is_instance_valid(ship) or ship.get("setup") != true:
		return
	var slots = []
	if not _slots(ship, slots):
		return   # a slot is still mounting
	armFitted = true
	Debug.l("COOP: BOT loadout ship=%s arm=%s mpu=%s slots=%s" % [ship.name, _arm() != null, _mpu() != null, slots])
	if _arm() == null and mode in ["claw", "frac"] and not noArm:
		Debug.l("COOP: BOT %s: no salvage arm on this ship (the bot never changes a loadout); use a dev save that has one" % mode)

func _slots(n, out) -> bool:
	var done = true
	for c in n.get_children():
		if c.get("mounted") != null and c.get("slot") != null and c.has_method("loadPlaceholder"):
			if c.get("system") == null and str(c.mounted) != "SYSTEM_NONE" and c.get_node_or_null(str(c.mounted)) is InstancePlaceholder:
				done = false
			out.append("%s=%s" % [c.slot, c.mounted])
		elif not _slots(c, out):
			done = false
	return done

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
		if not is_instance_valid(n) or n.mass > CLAW_MASS or n.get("fracturing") == true or _own().owners.has(id) \
				or skipIds.has(id):
			continue
		var d = n.global_position.distance_to(ship.global_position)
		if best == "" or d < bestD:
			best = id
			bestD = d
	return best

func _onGranted(id):
	if mode == "eat":
		if eatJob.id == id:
			eatJob.result = "granted"
		return
	if mode == "frac":
		if claw.id == id:
			claw.result = "granted"
		return
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
	if mode == "mpu":
		if mpuJob.id == id and mpuJob.state == "feed":
			_mpuEnd("denied:" + str(why), _secs())
		return
	if mode == "eat":
		if eatJob.id == id:
			eatJob.result = "denied:" + str(why)
		return
	if mode == "frac":
		if claw.id == id:
			claw.result = "denied:" + str(why)
		return
	if mode == "claw":
		if claw.id == id and claw.state == "reach":
			claw.result = "denied:" + str(why)
		return
	if not results.has(id):
		return
	Debug.l("COOP: BOT race trial=%d id=%s result=denied:%s" % [results[id], id, why])
	results.erase(id)
