extends Node

# Npc: other ships' lives and deaths across machines (M4 Ships track). See docs/M4-OWNERSHIP.md.
#
# s.die  the owner's ship started exploding. Everyone else plays the stock explosion on its puppet as a picture
#        (Reactor ext: no story flag; ship-ctrl ext: the puppet hides instead of vanishing, no lifepod, no save
#        writes). The blast's push on rocks happens on the machine simulating the rocks (Reactor ext).
# pods   a player whose ship died flies its lifepod (beacon kind "pod"). A lifepod is a plain RigidBody2D, not a
#        ship-ctrl ship, so it can't be a CoopNet puppet; it is mirrored here as a kinematic Lifepod placed from
#        the owner's 20 Hz state (peers[id].state), tagged dvnet_puppet so claws and holds leave it alone.
# NPCs   whoever simulates an NPC ship streams it to the rest of the cell: the authority for everything its spawner
#        and story make (members' spawners and story are off), and a member for the save- or story-bound NPCs it
#        brought with it (on joining, its other NPCs are freed quietly; see _onCellJoined). Each NPC built by Shipyard
#        gets a net id (meta dvnet_npc). Its runner sends its recipe (n.s: Shipyard fullConfig with transponder,
#        madeIn, faction and name filled in, so building it writes nothing to the member's save) to each member it
#        is within NPC_RANGE of, then state (n.u) and intent (n.i: thrusters, fired systems, turrets) at 10 Hz, and
#        n.d when it leaves range, despawns or explodes. Members build a netControlled mirror tagged
#        dvnet_mirror = authority id, which the ship-ctrl ext corrects and fires like a player puppet.
# d.ship a member's weapon hitting a mirror forwards the hit and the stock hostility to the authority, which applies
#        them to the real NPC, once, so it turns on the "player" faction there.
#
# Dev: --coop-dev-explode=<s>  s seconds after my dive cutscene ends, blow up my own ship (gate 8).
#      --coop-dev-pirate=<s>   as cell authority, s seconds into the cell, spawn a pirate TRTL near a member (gate 9).
#      --coop-dev-fireall=<s>[,<d>]  s seconds after my dive cutscene ends, hold every non-thruster command (weapons,
#                              claws, drones) for d seconds (default 10), so the puppets of my ship replay them (gate 7).
#      --coop-dev-explode-member=<s>  like --coop-dev-explode, but only while I'm a cell member (gate 8: the blast is
#                              then simulated by the authority, not by the dying ship).
#      --coop-dev-story-npc    while I'm solo after my dive, spawn two NPC TRTLs beside me, one marked essential (a
#                              story NPC), one plain; once I've joined a cell, bring the kept one next to me (gate 9
#                              sub-check: the plain one is freed on joining, the essential one is kept and seen).
#      --coop-dev-kill-npc=<s> as authority, s seconds after the dev pirate spawned, blow it up with a lifepod set
#                              (audit site: an NPC's lifepod exists once, on the machine running the NPC).
#      --coop-dev-poi=<event>  while solo after my dive, put a non-ephemeral test POI with that ring event (e.g.
#                              Addlet, a moonlet) 30 km ahead of me, so my spawner makes the oddity (gate 9c).
#      --coop-dev-return=<s>   s seconds after joining a cell, jump back to where I placed the test POI, which takes
#                              me out of the cell, so the freed oddity must come back from its POI (gate 9c).
#      --coop-dev-pause=<s>    s seconds into a cell, drive every pause entry point in turn (window focus loss,
#                              Steam overlay closed, pause key open and close, overlay open and closed), logging my
#                              ship's position at each step (gate 11: the cell keeps running).
#      --coop-dev-menu-quit=<s>,<member|auth>  (repeatable) s seconds into a cell, if my role matches, leave to the
#                              title through the pause menu's Menu button (gate 11b: instant handoff, no silence).
#      --coop-dev-shoot=<s>    as member, s seconds after a mirror appears, hit the nearest mirror the way a laser
#                              does, for 5 s, through the real forwarding path (gate 9).

var net = null   # CoopNet

var explodeAfter = -1.0
var explodeClock = 0.0
var exploded = false

const LIFEPOD = "res://ships/Lifepod.tscn"
const POD_MAX_EXTRAPOLATION = 0.25
var pods = {}    # peer id -> mirror Lifepod

const NPC_RANGE = 30000.0
const NPC_DROP = 34000.0
const NPC_HZ = 10.0
var npcSeq = 0
var npcs = {}       # authority: id -> NPC ship
var known = {}      # authority: member -> {id: true} mirrors that member holds
var mirrors = {}    # member: id -> mirror ship
var npcAccum = 0.0
var hits = {}       # member: owner -> [entries] forwarded this tick

var pirateAfter = -1.0
var pirateClock = 0.0
var pirateDone = false
var devPirate = null
var killAfter = -1.0
var killClock = 0.0
var shootAfter = -1.0
var shootClock = 0.0
var poiEvent = ""
var poiAt = null
var returnAfter = -1.0
var returnClock = 0.0
var returned = false
var menuQuits = []   # [[seconds, "member"|"auth"], ...]
var menuClock = 0.0
var menuDone = false
var pauseAfter = -1.0
var pauseClock = 0.0
var pauseStep = 0
var pauseKeyUp = -1.0     # release the pause key at this pauseClock (a press and its release in one frame never registers)
var storyNpc = false
var storyDone = false
var storyKept = null
var storyMoved = false
var devLogAccum = 0.0
var fireAfter = -1.0
var fireFor = 10.0
var explodeMemberOnly = false
var fireClock = 0.0
var counts = {}      # 5 s summary: puppet systems replayed, hits turned into effects only
var countAccum = 0.0

func _ready():
	name = "Npc"
	net.on("s.die", self, "_onDie")
	net.on("n.s", self, "_onNpcSpawn")
	net.on("n.u", self, "_onNpcState")
	net.on("n.i", self, "_onNpcIntent")
	net.on("n.d", self, "_onNpcGone")
	net.on("d.ship", self, "_onShipHits")
	call_deferred("_hookCell")
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-dev-explode="):
			explodeAfter = float(arg.substr(19))
		elif arg.begins_with("--coop-dev-pirate="):
			pirateAfter = float(arg.substr(18))
		elif arg.begins_with("--coop-dev-shoot="):
			shootAfter = float(arg.substr(17))
		elif arg.begins_with("--coop-dev-kill-npc="):
			killAfter = float(arg.substr(20))
		elif arg.begins_with("--coop-dev-poi="):
			poiEvent = arg.substr(15)
		elif arg.begins_with("--coop-dev-return="):
			returnAfter = float(arg.substr(18))
		elif arg.begins_with("--coop-dev-menu-quit="):
			var mq = arg.substr(21).split(",")
			menuQuits.append([float(mq[0]), mq[1] if mq.size() > 1 else "member"])
		elif arg.begins_with("--coop-dev-pause="):
			pauseAfter = float(arg.substr(17))
		elif arg == "--coop-dev-story-npc":
			storyNpc = true
		elif arg.begins_with("--coop-dev-fireall="):
			var fa = arg.substr(19).split(",")
			fireAfter = float(fa[0])
			if fa.size() > 1:
				fireFor = float(fa[1])
		elif arg.begins_with("--coop-dev-explode-member="):
			explodeAfter = float(arg.substr(26))
			explodeMemberOnly = true

func _hookCell():
	var cell = net.get_node_or_null("Cell")
	if cell != null:
		cell.connect("cell_joined", self, "_onCellJoined")

# Joining someone else's cell: the NPCs my spawner and story made are this machine's alone, so they go, like my
# rocks. Quietly (the field's kill(), the stock despawn path), never vanish(), which writes the save and drops
# lifepods. Kept and streamed as mine: ships the game marks essential (story ships, anyone mid-dialog), player-faction
# ships (my drones and fleet), anything docked to or held by my ship, and ships my save records individually
# (an encounter in state.encounteredShips, or a non-empty state.dispositions entry, both keyed by transponder).
# Read-only: CurrentGame.getDispositionReferenceOfTransponder would create the entry it looks up.
func _inMySave(transponder) -> bool:
	var st = CurrentGame.state
	if st.get("encounteredShips", {}).has(transponder):
		return true
	var d = st.get("dispositions", {}).get(transponder)
	return d is Dictionary and d.size() > 0

func _onCellJoined(authority_id):
	var cell = _cell()
	var field = _field()
	if cell == null or field == null or cell.isAuthority():
		return
	var me = net.localShip
	var freed = []
	var kept = []
	for c in field.get_children():
		if not _isNpc(c):
			continue
		var held = me != null and is_instance_valid(me) and (c.get("docked") == me or me.temporaryCargo.has(c) or me.cargo.has(c))
		if c.essential or c.faction == "player" or held or _inMySave(c.transponder):
			kept.append("%s/%s" % [c.transponder, c.getShipName()])
		else:
			freed.append(c.transponder)
			field.kill(c)
	_log("joined %s's cell: freed %d NPCs of mine %s, kept %d as mine %s" % [authority_id, freed.size(), freed, kept.size(), kept])
	_freeOddities(field, me)

# The oddities my spawner placed while I was solo (moonlets, habitats, stations, storm beacons, wrecks, loot) are
# nobody else's world, so they go too, quietly (field.kill: no vanish, no setStory, no POI change). A non-ephemeral POI
# stays in my save and brings its oddity back when I'm solo near it again. Kept: anything held, in a cargo hold, or
# docked; anything essential or mid-dialog; and anything mid-event whose completion the save would record (a pirate
# station whose reactors have started to fry: BigExplosion sets its story flag when it blows).
func _freeOddities(field, me):
	var freed = []
	var kept = []
	for c in field.get_children():
		if not (c is RigidBody2D) or c == me or _isNpc(c) or "selfRemove" in c:
			continue
		if c.has_meta("dvnet_puppet") or c.has_meta("dvnet_mirror") or c.has_meta("dvnet_tracked"):
			continue
		var rs = net.get_node_or_null("RockSync")
		if rs != null and rs.isRock(c):
			continue   # RockSync frees my rocks
		var tag = "%s/%s" % [c.filename.get_file().get_basename() if c.filename else c.name, c.get("transponder") if c.get("transponder") else c.name]
		var why = _keepOddity(c, me)
		if why != "":
			kept.append("%s: %s" % [tag, why])
		else:
			freed.append(tag)
			field.kill(c)
	_log("joined: freed %d oddities of mine %s, kept %d %s" % [freed.size(), freed, kept.size(), kept])

func _keepOddity(c, me) -> String:
	if me != null and is_instance_valid(me) and (me.temporaryCargo.has(c) or me.cargo.has(c) or c.get("docked") == me):
		return "held"
	var hold = c.get("inCargoHold")
	if hold != null and hold:
		return "in a hold"
	if c.get("essential") == true:
		return "essential"
	if c.get("talkingWith") != null:
		return "mid-dialog"
	var stack = [c]
	while stack.size() > 0:
		var n = stack.pop_back()
		if "explodeNow" in n and "reactors" in n:
			if n.explodeNow:
				return "mid-event"
			for rr in n.reactors:
				if is_instance_valid(rr) and rr.get("fried"):
					return "mid-event"
		for k in n.get_children():
			stack.append(k)
	return ""

func _log(s):
	Debug.l("COOP: NPC " + s)

# Reactor ext: my own ship's reactor just started its explosion.
func localShipExploding(ship):
	var msg = {
		"t": "s.die",
		"p": CurrentGame.globalCoords(ship.global_position),
		"r": ship.global_rotation,
		"v": ship.linear_velocity,
		"w": ship.angular_velocity,
	}
	net.sendTo(net.peers.keys(), msg, true)
	_log("s.die sent: my ship '%s' exploding at %s" % [ship.name, msg.p])

func _onDie(from, msg):
	# The dead ship's config must not come back as a puppet; CoopNet asks the owner for its new ship.
	if net.peers.has(from):
		net.peers[from].cfg = null
	var pp = net._puppetOf(from)
	if pp == null:
		_log("s.die from %s: no puppet here" % from)
		return
	pp.netDying = true
	pp.netState = {"p": msg.p, "r": msg.r, "v": msg.v, "w": msg.w, "at": OS.get_ticks_msec()}
	for c in pp.get_children():
		if c.has_method("initExplosion"):
			c.initExplosion()
			_log("s.die from %s: puppet '%s' exploding at %s" % [from, pp.name, msg.p])
			return
	_log("s.die from %s: puppet '%s' has no reactor to explode" % [from, pp.name])

func _physics_process(delta):
	devLogAccum += delta
	var trace = devLogAccum >= 10.0 and (explodeAfter >= 0 or pirateAfter >= 0 or fireAfter >= 0)
	if trace:
		devLogAccum = 0.0
		var sh = net.localShip
		var ok = sh != null and is_instance_valid(sh)
		_log("dev state: ship=%s cutscene=%s clocks fire=%.0f explode=%.0f pirate=%.0f" % [sh.name if ok else "-", str(sh.cutscene) if ok else "-", fireClock, explodeClock, pirateClock])
	devStep = 0
	_pruneMirrors()
	devStep = 1
	_podsTick()
	devStep = 2
	_npcTick(delta)
	devStep = 3
	_flushHits()
	devStep = 4
	_devExplodeTick(delta)
	_devPirateTick(delta)
	_devShootTick(delta)
	_devFireTick(delta)
	_devStoryTick()
	_devKillTick(delta)
	_devPoiTick(delta)
	_devPauseTick(delta)
	_devMenuQuitTick(delta)
	devStep = 5
	if trace:
		_log("dev trace: reached step %d" % devStep)
	countAccum += delta
	if countAccum >= 5.0:
		countAccum = 0.0
		if counts.size() > 0:
			_log("ships 5 s: %s, mirrors=%d npcs=%d pods=%d step=%d" % [counts, mirrors.size(), npcs.size(), pods.size(), devStep])
		counts = {}
		_saveWatch()

var devStep = -1

# Dev evidence for "nothing written to the viewer's save": sizes of the per-ship save tables, logged when they change.
var lastSave = ""
func _saveWatch():
	var st = CurrentGame.state
	var w = "transponders=%d shipNames=%d dispositions=%d encounteredShips=%d story=%d" % [
		st.get("transponders", {}).get("lookup", {}).size(), st.get("shipNames", {}).size(),
		st.get("dispositions", {}).size(), st.get("encounteredShips", {}).size(), st.get("story", {}).size()]
	if w != lastSave:
		_log("save watch: %s" % w)
		lastSave = w

func _devStoryTick():
	if not storyNpc:
		return
	var cell = _cell()
	var field = _field()
	var ship = net.localShip
	if cell == null or field == null or ship == null or not is_instance_valid(ship) or ship.cutscene:
		return
	if storyDone:
		if not storyMoved and cell.inCell() and not cell.isAuthority() and storyKept != null:
			storyMoved = true
			if is_instance_valid(storyKept) and storyKept.is_inside_tree():
				storyKept.global_position = ship.global_position + Vector2(0, 1500)
				storyKept.linear_velocity = ship.linear_velocity
				storyKept.reset_physics_interpolation()
				_log("dev: kept essential NPC %s brought beside me in the cell" % storyKept.transponder)
			else:
				_log("dev: the essential NPC did not survive joining")
		return
	if cell.inCell():
		return
	storyDone = true
	for essential in [true, false]:
		var npc = Shipyard.createShipByConfig({"model": "TRTL", "faction": "civilian", "config": {}}, true)
		npc.ai = true
		npc.preheat = true
		npc.essential = essential
		if essential:
			storyKept = npc
		var ok = field.spawnByBlueprint(npc, ship.global_position + Vector2(0, 1500 if essential else -1500), 0, 300)
		_log("dev: %s NPC %s '%s' spawned beside me before joining: %s" % ["essential" if essential else "plain", npc.transponder, npc.getShipName(), ok])

func _devPoiTick(delta):
	if poiEvent == "":
		return
	var cell = _cell()
	var ship = net.localShip
	if cell == null or ship == null or not is_instance_valid(ship) or ship.cutscene or not ship.get("setup"):
		return
	if poiAt == null:
		if cell.inCell():
			return
		poiAt = CurrentGame.globalCoords(ship.global_position)
		var ahead = ship.linear_velocity.normalized() if ship.linear_velocity.length() > 1.0 else Vector2(1, 0)
		CurrentGame.createOrUpdatePoi("dvcoop-test-" + poiEvent, poiEvent, 3.0, ahead, "poi", 24 * 3600, false)
		var d = CurrentGame.state.astrogation.get("dvcoop-test-" + poiEvent, {})
		_log("dev: test POI %s (event %s) at %s, placed from %s" % ["dvcoop-test-" + poiEvent, poiEvent, d.get("vector"), poiAt])
		return
	if returnAfter < 0 or returned or not cell.inCell() or cell.isAuthority():
		return
	returnClock += delta
	if returnClock < returnAfter:
		return
	returned = true
	ship.teleportBy(CurrentGame.localCoords(poiAt) - ship.global_position)
	ship.reset_physics_interpolation()
	_log("dev: returned to %s, near the test POI, to leave the cell" % [poiAt])

const PAUSE_STEPS = [
	[0.0, "window focus lost"],
	[5.0, "Steam overlay closed"],
	[8.0, "pause key (open)"],
	[12.0, "pause key (close)"],
	[15.0, "Steam overlay opened"],
	[20.0, "Steam overlay closed"],
]

func _devPauseTick(delta):
	if pauseKeyUp >= 0:
		pauseClock += delta
		if pauseClock >= pauseKeyUp:
			pauseKeyUp = -1.0
			var up = InputEventAction.new()
			up.action = "pause"
			up.pressed = false
			Input.parse_input_event(up)
			var pm = net._gameScene().get_node_or_null("PauseMenu") if net._gameScene() != null else null
			_log("dev pause key released; tree paused=%s menu=%s" % [get_tree().paused,
				pm.get_node("PauseContainer").visible if pm != null else "-"])
		return
	if pauseAfter < 0 or pauseStep >= PAUSE_STEPS.size():
		return
	var cell = _cell()
	var game = net._gameScene()
	var ship = net.localShip
	if cell == null or game == null or not cell.inCell() or ship == null or not is_instance_valid(ship):
		return
	pauseClock += delta
	if pauseClock < pauseAfter + PAUSE_STEPS[pauseStep][0]:
		return
	var step = PAUSE_STEPS[pauseStep]
	var menu = game.get_node_or_null("PauseMenu")
	match pauseStep:
		0:
			if menu != null:
				menu.notification(MainLoop.NOTIFICATION_WM_FOCUS_OUT)
		1, 5:
			CurrentGame.emit_signal("pauseGame", false)
		2, 3:
			# press now, release a few frames later: the stock handler needs is_action_just_pressed("pause")
			var ev = InputEventAction.new()
			ev.action = "pause"
			ev.pressed = true
			Input.parse_input_event(ev)
			pauseKeyUp = pauseClock + 0.15
		4:
			CurrentGame.emit_signal("pauseGame", true)
	_log("dev pause step %d: %s; tree paused=%s menu=%s ship at %s" % [pauseStep, step[1], get_tree().paused,
		menu.get_node("PauseContainer").visible if menu != null else "-", CurrentGame.globalCoords(ship.global_position)])
	pauseStep += 1

func _devMenuQuitTick(delta):
	if menuQuits.size() == 0 or menuDone:
		return
	var cell = _cell()
	var game = net._gameScene()
	if cell == null or game == null or not cell.inCell():
		return
	menuClock += delta
	var role = "auth" if cell.isAuthority() else "member"
	for q in menuQuits:
		if menuClock >= q[0] and q[1] == role:
			var menu = game.get_node_or_null("PauseMenu")
			if menu == null:
				return
			menuDone = true
			_log("dev: menu quit to title as %s (cell %s, members %s)" % [role, cell.cid, cell.members()])
			menu._on_ConfirmMenu_confirmed()
			return

func count(what, n):
	counts[what] = counts.get(what, 0) + n

func _devFireTick(delta):
	if fireAfter < 0:
		return
	var ship = net.localShip
	if ship == null or not is_instance_valid(ship) or ship.cutscene or not ship.get("setup"):
		return
	fireClock += delta
	if fireClock >= fireAfter and fireClock < fireAfter + fireFor:
		if not Engine.has_meta("dvcoop_dev_fireall"):
			# the same nodes the stock fireMatching walks (ship-ctrl.gd :2641), minus thrusters
			var cmds = []
			for node in ship.get_children() + ship.externalSystems:
				if is_instance_valid(node) and node.has_method("fire") and "command" in node and not (node.name in ship.thrusters):
					var cmd = node.command
					if cmd is String and cmd != "" and not cmds.has(cmd):
						cmds.append(cmd)
			Engine.set_meta("dvcoop_dev_fireall", cmds)
			_log("dev: firing %s on my ship for %.0f s" % [cmds, fireFor])
	elif Engine.has_meta("dvcoop_dev_fireall"):
		Engine.remove_meta("dvcoop_dev_fireall")
		_log("dev: stopped firing")

func _podsTick():
	var game = net._gameScene()
	for id in pods.keys():
		var pr = net.peers.get(id)
		var keep = game != null and pr != null and pr.inRange and pr.beacon != null and pr.beacon.get("kind", "ship") == "pod"
		var pod = pods[id]
		if not keep or not is_instance_valid(pod):
			if is_instance_valid(pod):
				pod.queue_free()
			pods.erase(id)
			_log("pod mirror of %s removed" % id)
	if game == null:
		return
	for id in net.peers:
		var pr = net.peers[id]
		if not pr.inRange or pr.beacon == null or pr.beacon.get("kind", "ship") != "pod" or pr.get("state") == null:
			continue
		if not pods.has(id):
			var pod = load(LIFEPOD).instance()
			pod.transponder = str(pr.beacon.get("tr", ""))   # set before _ready, which would mint one in our save
			pod.mode = RigidBody2D.MODE_KINEMATIC
			pod.set_meta("dvnet_puppet", id)
			pod.global_position = CurrentGame.localCoords(pr.state.p)
			game.get_node("AsteroidField").add_child(pod)
			pods[id] = pod
			_log("pod mirror of %s (%s) at %s" % [id, pr.name, pr.state.p])
		var st = pr.state
		var age = clamp((OS.get_ticks_msec() - st.at) / 1000.0, 0.0, POD_MAX_EXTRAPOLATION)
		var pod = pods[id]
		pod.global_position = CurrentGame.localCoords(st.p) + st.v * age
		pod.global_rotation = st.r + st.w * age

func _devExplodeTick(delta):
	if explodeAfter < 0 or exploded:
		return
	var ship = net.localShip
	if ship == null or not is_instance_valid(ship) or ship.cutscene:
		explodeClock = 0.0
		return
	explodeClock += delta
	if explodeClock < explodeAfter:
		return
	var cell = _cell()
	if explodeMemberOnly and (cell == null or not cell.inCell() or cell.isAuthority()):
		return
	exploded = true
	for c in ship.get_children():
		if c.has_method("initExplosion"):
			_log("dev: exploding my ship '%s'" % ship.name)
			c.initExplosion()
			return

# ---------------------------------------------------------------- NPC mirrors

func _cell():
	return net.get_node_or_null("Cell")

func _field():
	var g = net._gameScene()
	return g.get_node("AsteroidField") if g != null else null

func _isNpc(c) -> bool:
	return c is RigidBody2D and "shipConfig" in c and c.get("fullConfig") is Dictionary and c.fullConfig.has("model") \
		and not c.playerControlled and not c.get("netControlled") and not c.has_meta("dvnet_mirror") \
		and not c.has_meta("dvnet_puppet") and not c.get("dead") and c.is_inside_tree() and c != net.localShip

func _npcId(c) -> String:
	if not c.has_meta("dvnet_npc"):
		npcSeq += 1
		c.set_meta("dvnet_npc", "%s:n%d" % [net.myId, npcSeq])
	return c.get_meta("dvnet_npc")

func _npcTick(delta):
	var cell = _cell()
	var field = _field()
	if cell == null or field == null:
		return
	if not cell.inCell():
		if npcs.size() > 0:
			npcs = {}
			known = {}
		return
	npcAccum += delta
	if npcAccum < 1.0 / NPC_HZ:
		return
	npcAccum = 0.0
	# the NPCs I run, and the ones that died since last tick
	for c in field.get_children():
		if _isNpc(c):
			npcs[_npcId(c)] = c
	var gone = {}
	for id in npcs.keys():
		var c = npcs[id]
		if not is_instance_valid(c) or not c.is_inside_tree() or c.get("dead"):
			gone[id] = is_instance_valid(c) and c.get("dead") == true
			npcs.erase(id)
	var now = OS.get_ticks_msec() / 1000.0
	for peer in cell.members():
		if peer == net.myId or not net.peers.has(peer):
			continue
		var at = cell._peerPos(peer, now)
		if not known.has(peer):
			known[peer] = {}
		var kn = known[peer]
		var spawn = []
		var drop = []
		var upd = []
		var intents = {}
		for id in kn.keys():
			if gone.has(id):
				drop.append([id, gone[id]])
				kn.erase(id)
		for id in npcs:
			var c = npcs[id]
			var g = CurrentGame.globalCoords(c.global_position)
			var d = g.distance_to(at) if at != null else 1e20
			if kn.has(id):
				if d > NPC_DROP:
					drop.append([id, false])
					kn.erase(id)
					continue
			elif d < NPC_RANGE:
				spawn.append(_recipe(id, c))
				kn[id] = true
			else:
				continue
			upd.append([id, g, c.global_rotation, c.linear_velocity, c.angular_velocity])
			if c.get("coopIntent") != null:
				intents[id] = c.coopIntent
		if spawn.size() > 0:
			net.send(peer, {"t": "n.s", "l": spawn}, true)
			_log("n.s to %s: %s" % [peer, _names(spawn)])
		if drop.size() > 0:
			net.send(peer, {"t": "n.d", "l": drop}, true)
			_log("n.d to %s: %s" % [peer, drop])
		if upd.size() > 0:
			net.send(peer, {"t": "n.u", "l": upd}, false)
		if intents.size() > 0:
			net.send(peer, {"t": "n.i", "m": intents}, false)

func _names(spawn):
	var out = []
	for rc in spawn:
		out.append("%s %s/%s" % [rc.id, rc.cfg.get("model"), rc.cfg.get("faction")])
	return out

func _recipe(id, c) -> Dictionary:
	var cfg = c.fullConfig.duplicate(true)
	cfg.transponder = c.transponder
	cfg.faction = c.faction
	cfg.shipName = c.getShipName()
	if not cfg.has("madeIn"):
		cfg.madeIn = c.get("madeTimestamp")
	return {"id": id, "cfg": cfg, "p": CurrentGame.globalCoords(c.global_position), "r": c.global_rotation, "v": c.linear_velocity, "w": c.angular_velocity}

func _onNpcSpawn(from, msg):
	var cell = _cell()
	var field = _field()
	if field == null or cell == null or not cell.inCell() or not cell.members().has(from):
		return
	for rc in msg.l:
		if mirrors.has(rc.id) and is_instance_valid(mirrors[rc.id]):
			continue
		var ship = Shipyard.createShipByConfig(rc.cfg, false)
		if ship == null:
			_log("mirror %s: Shipyard could not build %s" % [rc.id, rc.cfg.get("model")])
			continue
		ship.netControlled = true
		ship.ai = false
		ship.autopilot = false
		ship.preheat = true
		ship.set_meta("dvnet_mirror", from)
		ship.set_meta("dvnet_npc", rc.id)
		ship.netState = {"p": rc.p, "r": rc.r, "v": rc.v, "w": rc.w, "at": OS.get_ticks_msec()}
		ship.global_position = CurrentGame.localCoords(rc.p)
		ship.rotation = rc.r
		ship.linear_velocity = rc.v
		field.add_child(ship)
		mirrors[rc.id] = ship
		_log("mirror %s: %s '%s' (%s) at %s" % [rc.id, rc.cfg.get("model"), rc.cfg.get("shipName"), rc.cfg.get("faction"), rc.p])

func _onNpcState(from, msg):
	for e in msg.l:
		var m = mirrors.get(e[0])
		if m != null and is_instance_valid(m):
			m.netState = {"p": e[1], "r": e[2], "v": e[3], "w": e[4], "at": OS.get_ticks_msec()}

func _onNpcIntent(from, msg):
	for id in msg.m:
		var m = mirrors.get(id)
		if m != null and is_instance_valid(m):
			m.netSchedule = msg.m[id]

func _onNpcGone(from, msg):
	for e in msg.l:
		var m = mirrors.get(e[0])
		mirrors.erase(e[0])
		if m == null or not is_instance_valid(m):
			continue
		if e[1]:
			m.netDying = true
			for c in m.get_children():
				if c.has_method("initExplosion"):
					c.initExplosion()
					break
			_log("mirror %s exploding" % e[0])
		else:
			m.queue_free()
			_log("mirror %s removed" % e[0])

# Members drop mirrors of an authority they no longer follow.
func _pruneMirrors():
	var cell = _cell()
	for id in mirrors.keys():
		var m = mirrors[id]
		if not is_instance_valid(m) or cell == null or not cell.inCell() or not cell.members().has(m.get_meta("dvnet_mirror")):
			if is_instance_valid(m):
				m.queue_free()
			mirrors.erase(id)
			_log("mirror %s dropped (its runner left the cell, or I did)" % id)

# ---------------------------------------------------------------- d.ship

# ship-ctrl ext: a local weapon hit a mirror. kind: "e" energy, "k" kinetic, "m" emp (a amount, b point, c delta);
# "h" hostility (a faction, b amount).
func forwardShipHit(ship, kind, a, b, c):
	var owner = ship.get_meta("dvnet_mirror")
	if not hits.has(owner):
		hits[owner] = []
	var e = [ship.get_meta("dvnet_npc"), kind, a, b, c]
	if kind != "h":
		e[3] = CurrentGame.globalCoords(b)
	hits[owner].append(e)

func _flushHits():
	for owner in hits:
		if hits[owner].size() > 0 and net.peers.has(owner):
			net.send(owner, {"t": "d.ship", "l": hits[owner]}, true)
	hits = {}

func _onShipHits(from, msg):
	var applied = 0
	var hostile = 0.0
	var last = null
	for e in msg.l:
		var c = npcs.get(e[0])
		if c == null or not is_instance_valid(c) or c.get("dead"):
			continue
		match e[1]:
			"e":
				c.applyEnergyDamage(e[2], CurrentGame.localCoords(e[3]), e[4])
			"k":
				c.applyKineticDamage(e[2], CurrentGame.localCoords(e[3]), e[4])
			"m":
				c.applyEmpDamage(e[2], CurrentGame.localCoords(e[3]), e[4])
			"h":
				c.applyHostility(e[2], e[3])
				hostile += e[3]
		applied += 1
		last = c
	if last != null:
		hitLog += applied
		hostileLog += hostile
		var now = OS.get_ticks_msec() / 1000.0
		if now - hitLogAt > 1.0:
			hitLogAt = now
			var disp = last.disposition.get("player", {}).get("hostility", 0.0) if "disposition" in last else 0.0
			_log("d.ship from %s: %d hits applied (hostility +%.3f) on %s; its hostility to player = %.3f" % [from, hitLog, hostileLog, last.get_meta("dvnet_npc"), disp])
			hitLog = 0
			hostileLog = 0.0

var hitLog = 0
var hostileLog = 0.0
var hitLogAt = 0.0

# ---------------------------------------------------------------- dev triggers (gate 9)

func _devPirateTick(delta):
	if pirateAfter < 0 or pirateDone:
		return
	var cell = _cell()
	var field = _field()
	if cell == null or field == null or not cell.inCell() or not cell.isAuthority() or cell.members().size() < 2:
		pirateClock = 0.0
		return
	pirateClock += delta
	if pirateClock < pirateAfter:
		return
	pirateDone = true
	var target = -1
	for id in cell.members():
		if id != net.myId:
			target = id
			break
	var at = cell._peerPos(target, OS.get_ticks_msec() / 1000.0)
	if at == null:
		return
	var pirate = Shipyard.createShipByConfig({"model": "TRTL", "faction": "pirate", "config": {}}, true)
	pirate.ai = true
	pirate.preheat = true
	var ok = field.spawnByBlueprint(pirate, CurrentGame.localCoords(at) + Vector2(2500, 0), 0, 500)
	_log("dev: pirate %s '%s' spawned 2,500 px from %s: %s" % [pirate.transponder, pirate.getShipName(), target, ok])
	devPirate = pirate

func _devKillTick(delta):
	if killAfter < 0 or devPirate == null:
		return
	if not is_instance_valid(devPirate) or devPirate.get("dead"):
		devPirate = null
		return
	killClock += delta
	if killClock < killAfter:
		return
	devPirate.lifepod = load("res://ships/Lifepod.tscn")
	for c in devPirate.get_children():
		if c.has_method("initExplosion"):
			_log("dev: blowing up NPC %s %s (lifepod set)" % [devPirate.get_meta("dvnet_npc") if devPirate.has_meta("dvnet_npc") else "-", devPirate.transponder])
			c.initExplosion()
			break
	devPirate = null

func _devShootTick(delta):
	if shootAfter < 0:
		return
	var ship = net.localShip
	if mirrors.size() == 0 or ship == null or not is_instance_valid(ship):
		return
	shootClock += delta
	if shootClock < shootAfter or shootClock > shootAfter + 5.0:
		return
	var best = null
	for id in mirrors:
		var m = mirrors[id]
		if is_instance_valid(m) and (best == null or m.global_position.distance_to(ship.global_position) < best.global_position.distance_to(ship.global_position)):
			best = m
	if best == null:
		return
	# what a laser does to its target each tick (laser.gd :266-275), inside the same forwarding context
	Engine.set_meta("dvcoop_forward", ship)
	best.applyEnergyDamage(50.0 * delta, best.global_position, delta)
	best.applyHostility(ship.faction, 0.5 * delta)
	Engine.remove_meta("dvcoop_forward")
