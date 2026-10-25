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
#      --coop-dev-fireall=<s>  s seconds after my dive cutscene ends, hold every non-thruster command (weapons,
#                              claws, drones) for 10 s, so the puppets of my ship replay them (gate 7).
#      --coop-dev-story-npc    when the Cell dev warp lands me next to a cell (before I join it), spawn two NPC
#                              TRTLs beside me, one marked essential (a story NPC), one plain (gate 9 sub-check:
#                              the plain one is freed on joining, the essential one is kept and seen by the others).
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
var shootAfter = -1.0
var shootClock = 0.0
var storyNpc = false
var storyDone = false
var fireAfter = -1.0
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
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-dev-explode="):
			explodeAfter = float(arg.substr(19))
		elif arg.begins_with("--coop-dev-pirate="):
			pirateAfter = float(arg.substr(18))
		elif arg.begins_with("--coop-dev-shoot="):
			shootAfter = float(arg.substr(17))
		elif arg == "--coop-dev-story-npc":
			storyNpc = true
		elif arg.begins_with("--coop-dev-fireall="):
			fireAfter = float(arg.substr(19))

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
	_pruneMirrors()
	_podsTick()
	_npcTick(delta)
	_flushHits()
	_devExplodeTick(delta)
	_devPirateTick(delta)
	_devShootTick(delta)
	_devFireTick(delta)
	_devStoryTick()
	countAccum += delta
	if countAccum >= 5.0:
		countAccum = 0.0
		if counts.size() > 0:
			_log("ships 5 s: %s, mirrors=%d npcs=%d pods=%d" % [counts, mirrors.size(), npcs.size(), pods.size()])
		counts = {}
		_saveWatch()

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
	if not storyNpc or storyDone:
		return
	var cell = _cell()
	var field = _field()
	var ship = net.localShip
	if cell == null or field == null or not cell.warpDone or ship == null or not is_instance_valid(ship):
		return
	storyDone = true
	for essential in [true, false]:
		var npc = Shipyard.createShipByConfig({"model": "TRTL", "faction": "civilian", "config": {}}, true)
		npc.ai = true
		npc.preheat = true
		npc.essential = essential
		var ok = field.spawnByBlueprint(npc, ship.global_position + Vector2(0, 1500 if essential else -1500), 0, 300)
		_log("dev: %s NPC %s '%s' spawned beside me before joining: %s" % ["essential" if essential else "plain", npc.transponder, npc.getShipName(), ok])

func count(what, n):
	counts[what] = counts.get(what, 0) + n

func _devFireTick(delta):
	if fireAfter < 0:
		return
	var ship = net.localShip
	if ship == null or not is_instance_valid(ship) or ship.cutscene or not ship.get("setup"):
		return
	fireClock += delta
	if fireClock >= fireAfter and fireClock < fireAfter + 10.0:
		if not Engine.has_meta("dvcoop_dev_fireall"):
			var cmds = []
			var systems = ship.getSystems()
			for k in systems:
				var ref = systems[k].ref
				var cmd = ref.get("command") if is_instance_valid(ref) else null
				if cmd is String and cmd != "" and not (ref.name in ship.thrusters) and not cmds.has(cmd):
					cmds.append(cmd)
			Engine.set_meta("dvcoop_dev_fireall", cmds)
			_log("dev: firing %s on my ship for 10 s" % [cmds])
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
