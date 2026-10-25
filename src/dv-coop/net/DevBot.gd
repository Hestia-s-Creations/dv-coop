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
# More modes (claw, laser, massdriver) follow the same pattern: an authority-picked target, logged results.

const RACE_EVERY = 3.0      # s between trials
const RACE_LEAD = 0.6       # s between bot.go and the claim instant
const RACE_HOLD = 0.8       # s a winner holds the rock before releasing
const SETTLE = 10.0         # s in a cell before the first trial

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

func _ready():
	name = "DevBot"
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-bot="):
			var parts = arg.substr(11).split(",")
			mode = parts[0]
			trials = int(parts[1]) if parts.size() > 1 else 100
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

func _onGranted(id):
	if not results.has(id):
		return
	Debug.l("COOP: BOT race trial=%d id=%s result=granted" % [results[id], id])
	results.erase(id)
	holding[id] = _secs() + RACE_HOLD

func _onDenied(id, why):
	if not results.has(id):
		return
	Debug.l("COOP: BOT race trial=%d id=%s result=denied:%s" % [results[id], id, why])
	results.erase(id)
