extends Node

# Travel: getting to a friend (M5), plus showing join requests where the player is. See docs/M5.md.
#
# friends()  every peer whose fresh beacon says it is in the rings: {id, name, p, v} (global ring coordinates).
#            The dive picker (ext/AstrogationDestinations.gd) and the astrogator (ext/AstrogatorPanel.gd) list them.
# dive       ext/DiveTarget.gd calls diveTo(id) after the stock Dive press (pre-dive save, charge, random spread):
#            CurrentGame.diveTarget becomes the friend's position, led by their velocity over the dive cutscene, so
#            the player arrives next to where the friend is when the cutscene ends.
# course     plotToFriend(id) does what the stock Plot Course does for a save destination, for a friend: it emits
#            CurrentGame.plotCourseTo, and the game's own burn, time and remass apply. The ship's fast travel reads the
#            target's vector at the jump (5 s after the burn), so until then the vector follows the friend's beacon.
#            Nothing is written to state.astrogation.
# offers     CoopNet.requestJoin parks a join request; it is shown here once the player is somewhere it can be
#            answered: the title screen (with the save picker), Enceladus, or a dive after its cutscene.
#
# Dev (each s counts from when the named scene is ready: title, station = Enceladus, dive = after the cutscene):
#      --coop-dev-ui=<s>:<action>[,<s>:<action>...]  run the co-op panel's real buttons in order, each s seconds after
#                              the previous one: coop (open the panel), host, join (the request's Join, or else the
#                              first friend's), leave, invite, no, close, slot=<file>, capture (log the panel's rect
#                              and the viewport, for the resolution matrix)
#      --coop-dev-invite=<scene>:<s>,<lobby>  (repeatable) a join request for <lobby> (ENet: host:port) arriving s
#                              seconds into that scene, as a Steam join_requested would
#      --coop-dev-answer=<yes|no>[,...]  answer the join requests in turn, 3 s after each is shown
#      --coop-dev-dive-friend=<s>  at Enceladus: open the dive picker, pick the first friend, press Dive
#      --coop-dev-plot-friend=<s>  in a dive: plot a course to the first friend with the stock autopilot burn
#      --coop-dev-drop=<s>,<d>     in a dive: cut the link for d seconds without a bye, then reconnect

var net = null   # CoopNet

const FRIEND = "FRIEND|"
const DIVE_LEAD = 15.0       # s: the dive cutscene, over which the friend keeps moving
const DIVE_SIDE = Vector2(0, 20000)   # arrive 2 km beside the friend, not on top of them
const JUMP_LEAD = 1.5        # s: from the jump to the end of the fast-travel cutscene

var scene = null             # instance id of Loader.current
var sceneKind = ""           # title, station, dive (after its cutscene), or "" while loading / in a cutscene
var sceneClock = 0.0

var diveFriend = null        # {id, name, at}: a dive to this friend was launched; log the arrival
var course = null            # {id, name, ship, dict, phase}: a course to a friend in progress

# dev
var uiSteps = []             # [[s, action]]
var uiClock = 0.0
var invites = []             # [[scene, s, lobby]]
var answers = []
var answerAt = -1.0
var diveFriendAfter = -1.0
var diveFriendStep = 0
var plotFriendAfter = -1.0
var dropAt = -1.0
var dropFor = 0.0

func _ready():
	net.connect("session_changed", self, "_sessionChanged")
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-dev-ui="):
			for step in arg.substr(14).split(","):
				var kv = step.split(":", true, 1)
				uiSteps.append([float(kv[0]), kv[1] if kv.size() > 1 else ""])
		elif arg.begins_with("--coop-dev-invite="):
			var parts = arg.substr(18).split(",", true, 1)
			var at = parts[0].split(":")
			invites.append([at[0], float(at[1]) if at.size() > 1 else 0.0, net.lobbyKey(parts[1]) if parts.size() > 1 else net.devEnet])
		elif arg.begins_with("--coop-dev-answer="):
			answers = Array(arg.substr(18).split(","))
		elif arg.begins_with("--coop-dev-dive-friend="):
			diveFriendAfter = float(arg.substr(23))
		elif arg.begins_with("--coop-dev-plot-friend="):
			plotFriendAfter = float(arg.substr(23))
		elif arg.begins_with("--coop-dev-drop="):
			var sd = arg.substr(16).split(",")
			dropAt = float(sd[0])
			dropFor = float(sd[1]) if sd.size() > 1 else 20.0

func _log(s):
	Debug.l("COOP: TRAVEL " + s)

# ---------------------------------------------------------------- friends

func friends() -> Array:
	var out = []
	var now = OS.get_ticks_msec() / 1000.0
	for id in net.peers:
		var pr = net.peers[id]
		var b = pr.beacon
		if b == null or now - pr.beaconAt > net.BEACON_TIMEOUT or b.get("zone") != "rings" or not b.has("p"):
			continue
		out.append({"id": id, "name": pr.name, "p": b.p, "v": b.get("v", Vector2(0, 0))})
	return out

func friend(id):
	for f in friends():
		if f.id == id:
			return f
	return null

static func friendKey(id) -> String:
	return FRIEND + str(id)

static func friendOf(key):
	# the peer id in a FRIEND| destination key, or null
	if typeof(key) == TYPE_STRING and key.begins_with(FRIEND):
		return int(key.substr(FRIEND.length()))
	return null

# ---------------------------------------------------------------- dive to a friend

func diveTo(id):
	var f = friend(id)
	if f == null:
		_log("dive to friend %s: no fresh beacon, keeping the stock target %s" % [id, CurrentGame.diveTarget])
		return
	var at = f.p + f.v * DIVE_LEAD + DIVE_SIDE
	_log("dive to friend %s (%s): friend at %s moving %s, target %s (stock target was %s)" % [f.name, id, f.p, f.v, at, CurrentGame.diveTarget])
	CurrentGame.diveTarget = at
	diveFriend = {"id": id, "name": f.name}

# ---------------------------------------------------------------- plot a course to a friend

func plotToFriend(id) -> bool:
	var f = friend(id)
	var ship = CurrentGame.getPlayerShip()
	if f == null or ship == null or not is_instance_valid(ship):
		_log("course to friend %s: no fresh beacon or no ship" % id)
		return false
	CurrentGame.inventoryMode = false
	_log("plotting a course to friend %s (%s) at %s, %.0f km away" % [f.name, id, f.p, CurrentGame.globalCoords(ship.global_position).distance_to(f.p) / 10000.0])
	# Game.initiateFastTravel builds ship.trajectoryTarget from this, as for any destination
	CurrentGame.emit_signal("plotCourseTo", friendKey(id), f.p)
	var dict = ship.get("trajectoryTarget")
	if not (dict is Dictionary):
		_log("course to friend %s: the game didn't take it (ship busy)" % id)
		return false
	course = {"id": id, "name": f.name, "ship": ship, "dict": dict, "phase": "burn"}
	return true

func _courseTick():
	if typeof(course) == TYPE_NIL:
		return
	var ship = course.ship
	if not is_instance_valid(ship):
		course = null
		return
	var f = friend(course.id)
	if f != null and course.phase != "arrived":
		course.dict.vector = f.p + f.v * JUMP_LEAD
	match course.phase:
		"burn":
			if ship.get("trajectoryTarget") != course.dict:
				if ship.get("cutscene") == true:
					course.phase = "jump"
					_log("course to friend %s: burn done, jumping" % course.name)
				else:
					_log("course to friend %s: cancelled" % course.name)
					course = null
		"jump":
			if ship.get("cutscene") != true:
				var d = -1.0
				if f != null:
					d = CurrentGame.globalCoords(ship.global_position).distance_to(f.p)
				_log("course to friend %s: arrived %.0f px (%.1f km) from them" % [course.name, d, d / 10000.0])
				course = null

# ---------------------------------------------------------------- scene tracking, offers, dev

func _sceneNow() -> String:
	var c = Loader.current
	if c == null or not is_instance_valid(c):
		return ""
	if net._atTitle():
		return "title"
	if c.filename == "res://enceladus/Enceladus.tscn":
		return "station"
	if net._gameScene() != null:
		if net.dived and c.get("cutscene") != true:
			return "dive"
	return ""

func _physics_process(delta):
	var c = Loader.current
	var cid = c.get_instance_id() if c != null and is_instance_valid(c) else 0
	var kind = _sceneNow()
	if cid != scene or kind != sceneKind:
		if kind == "dive" and typeof(diveFriend) != TYPE_NIL:
			var f = friend(diveFriend.id)
			if f != null and net.localShip != null and is_instance_valid(net.localShip):
				var d = CurrentGame.globalCoords(net.localShip.global_position).distance_to(f.p)
				_log("dive to friend %s: arrived %.0f px (%.1f km) from them" % [diveFriend.name, d, d / 10000.0])
			diveFriend = null
		scene = cid
		sceneKind = kind
		sceneClock = 0.0
	if kind == "":
		return
	sceneClock += delta
	_offerTick()
	_courseTick()
	_devTick(delta)

func _sessionChanged():
	pass

# Show a waiting join request where the player can answer it.
func _offerTick():
	var pj = net.pendingJoin
	if typeof(pj) == TYPE_NIL or pj.shown:
		return
	var host = _panelHost()
	if host == null:
		return
	pj.shown = true
	_log("join request from %s shown (%s)" % [pj.from, sceneKind])
	host.coopAsk()
	if not answers.empty():
		answerAt = sceneClock + 3.0

func _panelHost():
	var group = "dvcoop_title" if sceneKind == "title" else "dvcoop_pause"
	for n in get_tree().get_nodes_in_group(group):
		if is_instance_valid(n) and n.is_inside_tree():
			return n
	return null

func _panel():
	var host = _panelHost()
	return host.coopPanel if host != null else null

func _press(key) -> bool:
	var panel = _panel()
	var b = panel.buttons.get(key) if panel != null else null
	if b == null:
		_log("dev: no %s button on the panel" % key)
		return false
	_log("dev: press %s%s" % [key, " (disabled)" if b.disabled else ""])
	if not b.disabled:
		b.emit_signal("pressed")
	return true

func _devTick(delta):
	# scheduled join requests
	for inv in invites:
		if inv[0] == sceneKind and sceneClock >= inv[1]:
			invites.erase(inv)
			_log("dev: join request for lobby %s" % [inv[2]])
			net.requestJoin(inv[2], "DevFriend")
			break
	if answerAt >= 0 and sceneClock >= answerAt and typeof(net.pendingJoin) != TYPE_NIL and not answers.empty():
		answerAt = -1.0
		var a = answers.pop_front()
		_press("yes" if a == "yes" else "no")
	# the co-op panel's buttons
	if not uiSteps.empty():
		uiClock += delta
		if uiClock >= uiSteps[0][0]:
			uiClock = 0.0
			_uiAction(uiSteps.pop_front()[1])
	# dive to a friend from Enceladus
	if diveFriendAfter >= 0 and sceneKind == "station" and sceneClock >= diveFriendAfter + diveFriendStep * 3.0:
		_diveFriendStep()
	# course to a friend
	if plotFriendAfter >= 0 and sceneKind == "dive" and sceneClock >= plotFriendAfter:
		var fs = friends()
		if not fs.empty():
			plotFriendAfter = -1.0
			var ship = CurrentGame.getPlayerShip()
			ship.astrogationVelocityMatch = true   # the stock autopilot flies the burn
			plotToFriend(fs[0].id)
	if dropAt >= 0 and sceneKind == "dive" and sceneClock >= dropAt:
		dropAt = -1.0
		_log("dev: dropping the link for %.0f s" % dropFor)
		net.devDrop(dropFor)

func _uiAction(action: String):
	var panel = _panel()
	var host = _panelHost()
	_log("dev ui: %s (%s)" % [action, sceneKind])
	if action == "coop":
		if host != null:
			host.coopOpen()
	elif action == "join":
		if not _press("yes"):
			_press("join0")
	elif action.begins_with("slot="):
		if panel != null:
			_log("dev: slot %s %s" % [action.substr(5), "picked" if panel.selectSlot(action.substr(5)) else "not found"])
	elif action == "capture":
		if panel != null:
			var r = panel.get_global_rect()
			var vp = panel.get_viewport().get_visible_rect()
			_log("UI capture: panel %s in viewport %s, inside %s, window %s" % [r, vp, vp.encloses(r), OS.window_size])
	else:
		_press(action)

func _diveFriendStep():
	var c = Loader.current
	match diveFriendStep:
		0:
			if friends().empty():
				return
			_log("dev: opening the dive picker")
			c._on_RingDive_pressed()
		1:
			var list = get_tree().get_nodes_in_group("dvcoop_divelist")
			if list.empty():
				return
			var l = list[0]
			var idx = -1
			for i in range(l.destinationLut.size()):
				if friendOf(l.destinationLut[i]) != null:
					idx = i
					break
			if idx < 0:
				_log("dev: no friend row in the dive picker yet")
				l.fillDestinations()
				return
			_log("dev: picking dive destination %d (%s)" % [idx, l.get_item_text(idx)])
			l.select(idx)
			l.emit_signal("item_selected", idx)
		2:
			var dives = get_tree().get_nodes_in_group("dvcoop_dive")
			if dives.empty():
				return
			_log("dev: pressing Dive")
			dives[0]._on_Dive_pressed()
			diveFriendAfter = -1.0
	diveFriendStep += 1
