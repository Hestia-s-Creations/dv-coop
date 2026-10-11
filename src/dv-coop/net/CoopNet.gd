extends Node

# CoopNet: transport + session for dv-coop (spec v2: local bubbles, shared cells).
#
# M0: Steam lobby / ENet transport, hello/ping/pong.
# M1: two ships, owner-authoritative transforms, netControlled puppets.
# M2: N players. Every peer sends a 1 Hz beacon; peers whose ships are within
#     RANGE_PUPPET get a puppet fed by intent (30 Hz) + state (20 Hz). Nobody is
#     special: there is no host in the session logic, only in the transport.
#
# Command line:
#   --coop-host                 create a friends-only Steam lobby (max 5) and wait
#   --coop-join=<lobby_id>      join that Steam lobby
#   --coop-enet-host=<port>     ENet server on <port> (dev; server relays to other clients)
#   --coop-enet-join=<host:port>
#   --coop-invite               (with --coop-host) pop the Steam invite overlay once the lobby exists
#   --coop-autodive             dev: skip the menus, load the save, dive at DEV_DIVE_TARGET
#   --coop-dive-offset=x,y      dev: offset the auto-dive target (px) so instances start apart
#   --coop-slot=savegame-b.dv   dev: use another save slot

const CHANNEL = 0
const P2P_UNRELIABLE = 0
const P2P_RELIABLE = 2
const LOBBY_FRIENDS_ONLY = 1
const LOBBY_MAX = 5
const PING_EVERY = 1.0
const BEACON_HZ = 1.0
const INTENT_HZ = 30.0
const STATE_HZ = 20.0
const RANGE_PUPPET = 40000.0
const RANGE_PUPPET_DROP = 45000.0
const BEACON_TIMEOUT = 6.0
const GAME_SCENE = "res://Game.tscn"
const DEV_DIVE_TARGET = Vector2(15000, 12345678)

enum Transport { NONE, STEAM, ENET }

var transport = Transport.NONE
var isHost = false
var wantHost = false
var wantInvite = false
var autoDive = false
var autoDiveOffset = Vector2(0, 0)
var joinLobbyId = 0
var enetHostPort = 0
var enetJoin = ""

var steamReady = false
var myId = 0            # Steam id, or ENet unique id
var lobbyId = 0
var enet = null

# peers: id -> {name, beacon, beaconAt, cfg, puppet, inRange}
var peers = {}

var pingTimer = 0.0
var pingSent = {}
var pingSeq = 0
var stats = {"rtt_ms": -1, "bytes_out": 0, "bytes_in": 0}

# --- session
var dived = false
var localShip = null
var autoDiveStarted = false
var lastIntent = null
var beaconAccum = 0.0
var intentAccum = 0.0
var stateAccum = 0.0
var statsAccum = 0.0

func _ready():
	for arg in OS.get_cmdline_args():
		if arg == "--coop-host":
			wantHost = true
		elif arg == "--coop-invite":
			wantInvite = true
		elif arg == "--coop-autodive":
			autoDive = true
		elif arg.begins_with("--coop-dive-offset="):
			var xy = arg.substr(19).split(",")
			if xy.size() == 2:
				autoDiveOffset = Vector2(float(xy[0]), float(xy[1]))
		elif arg.begins_with("--coop-slot="):
			CurrentGame.changeSaveSlot("user://" + arg.substr(12))
		elif arg.begins_with("--coop-join="):
			joinLobbyId = int(arg.substr(12))
		elif arg.begins_with("--coop-enet-host="):
			enetHostPort = int(arg.substr(17))
		elif arg.begins_with("--coop-enet-join="):
			enetJoin = arg.substr(17)

	ModLoader.set_meta("dvcoop", self)

	if enetHostPort > 0 or enetJoin != "":
		_startEnet()
	elif wantHost or joinLobbyId != 0:
		transport = Transport.STEAM
		Debug.l("COOP: waiting for Steam (host=%s join=%s)" % [wantHost, joinLobbyId])
	else:
		Debug.l("COOP: no session requested, CoopNet idle")
		set_process(false)
		set_physics_process(false)

func _exit_tree():
	if ModLoader.has_meta("dvcoop"):
		ModLoader.remove_meta("dvcoop")

# ---------------------------------------------------------------- Steam

func _process(delta):
	if transport == Transport.STEAM and not steamReady:
		if not Engine.has_singleton("Steam"):
			Debug.l("COOP: Steam singleton missing, cannot use Steam transport")
			set_process(false)
			return
		if Steam.loggedOn():
			_onSteamReady()

func _onSteamReady():
	steamReady = true
	myId = Steam.getSteamID()
	Debug.l("COOP: Steam ready, I am %d (%s)" % [myId, Steam.getPersonaName()])
	Steam.connect("lobby_created", self, "_onLobbyCreated")
	Steam.connect("lobby_joined", self, "_onLobbyJoined")
	Steam.connect("lobby_chat_update", self, "_onLobbyChatUpdate")
	Steam.connect("p2p_session_request", self, "_onP2PSessionRequest")
	Steam.connect("p2p_session_connect_fail", self, "_onP2PConnectFail")
	Steam.connect("join_requested", self, "_onJoinRequested")
	Steam.allowP2PPacketRelay(true)
	if wantHost:
		isHost = true
		Debug.l("COOP: creating lobby")
		Steam.createLobby(LOBBY_FRIENDS_ONLY, LOBBY_MAX)
	elif joinLobbyId != 0:
		Debug.l("COOP: joining lobby %d" % joinLobbyId)
		Steam.joinLobby(joinLobbyId)

func _onLobbyCreated(result, lobby):
	Debug.l("COOP: lobby_created result=%s lobby=%d" % [result, lobby])
	if result != 1:
		return
	lobbyId = lobby
	Steam.setLobbyData(lobbyId, "dvcoop", "1")
	Steam.setLobbyData(lobbyId, "build", str(CurrentGame.get("version")))
	Steam.setLobbyJoinable(lobbyId, true)
	Debug.l("COOP: LOBBY ID %d  (others run: --enable-mods --coop-join=%d)" % [lobbyId, lobbyId])
	if wantInvite:
		Steam.activateGameOverlayInviteDialog(lobbyId)

func _onLobbyJoined(lobby, permissions, locked, response):
	Debug.l("COOP: lobby_joined lobby=%d response=%s" % [lobby, response])
	if response != 1:
		return
	lobbyId = lobby
	isHost = (Steam.getLobbyOwner(lobbyId) == myId)
	var n = Steam.getNumLobbyMembers(lobbyId)
	for i in range(n):
		var id = Steam.getLobbyMemberByIndex(lobbyId, i)
		if id != myId:
			_peerSeen(id)
			_sendHello(id)
	Debug.l("COOP: in lobby, host=%s members=%d peers=%s" % [isHost, n, peers.keys()])

func _onLobbyChatUpdate(lobby, changedId, makingChangeId, chatState):
	# chatState: 1 entered, 2 left, 4 disconnected, 8 kicked, 16 banned
	Debug.l("COOP: lobby_chat_update who=%d state=%d" % [changedId, chatState])
	if chatState == 1 and changedId != myId:
		_peerSeen(changedId)
		_sendHello(changedId)
	elif chatState != 1:
		_peerGone(changedId)
		Steam.closeP2PSessionWithUser(changedId)

func _onP2PSessionRequest(remoteId):
	Debug.l("COOP: p2p_session_request from %d" % remoteId)
	Steam.acceptP2PSessionWithUser(remoteId)

func _onP2PConnectFail(steamId, sessionError):
	Debug.l("COOP: p2p_session_connect_fail %d err=%s" % [steamId, sessionError])

func _onJoinRequested(lobby, friendId):
	Debug.l("COOP: join_requested lobby=%d from=%d" % [lobby, friendId])
	Steam.joinLobby(lobby)

# ---------------------------------------------------------------- ENet (dev star, server relays)

func _startEnet():
	transport = Transport.ENET
	enet = NetworkedMultiplayerENet.new()
	var err
	if enetHostPort > 0:
		isHost = true
		err = enet.create_server(enetHostPort, LOBBY_MAX - 1)
		Debug.l("COOP: ENet server on %d -> %s" % [enetHostPort, err])
	else:
		var parts = enetJoin.split(":")
		var host = parts[0]
		var port = int(parts[1]) if parts.size() > 1 else 7777
		err = enet.create_client(host, port)
		Debug.l("COOP: ENet client to %s:%d -> %s" % [host, port, err])
	myId = enet.get_unique_id()
	enet.connect("peer_connected", self, "_onEnetPeer")
	enet.connect("peer_disconnected", self, "_onEnetPeerGone")
	enet.connect("connection_succeeded", self, "_onEnetConnected")
	enet.connect("connection_failed", self, "_onEnetFailed")

func _onEnetPeer(id):
	Debug.l("COOP: ENet peer %d connected" % id)
	if isHost:
		# tell the newcomer about everyone else and everyone else about the newcomer
		for other in peers.keys():
			_sendRaw(id, {"f": myId, "m": {"t": "peerlist", "ids": [other]}})
			_sendRaw(other, {"f": myId, "m": {"t": "peerlist", "ids": [id]}})
	_peerSeen(id)
	_sendHello(id)

func _onEnetPeerGone(id):
	Debug.l("COOP: ENet peer %d gone" % id)
	_peerGone(id)
	if isHost:
		for other in peers.keys():
			_sendRaw(other, {"f": myId, "m": {"t": "peergone", "id": id}})

func _onEnetConnected():
	myId = enet.get_unique_id()
	Debug.l("COOP: ENet connected to server, I am %d" % myId)

func _onEnetFailed():
	Debug.l("COOP: ENet connection failed")

# ---------------------------------------------------------------- packets

func _myName():
	if transport == Transport.STEAM:
		return Steam.getPersonaName()
	return "%s-%d" % [OS.get_environment("USERNAME"), myId % 1000]

func _peerSeen(id):
	if not peers.has(id):
		peers[id] = {"name": str(id), "beacon": null, "beaconAt": 0.0, "cfg": null, "puppet": null, "inRange": false}

func _peerGone(id):
	if peers.has(id):
		_despawnPuppet(id, "peer gone")
		peers.erase(id)

func _sendHello(peer):
	_send(peer, {"t": "hello", "name": _myName(), "host": isHost, "dived": dived}, true)

# Transport-level send. On ENet, clients can only talk to the server (1); anything for
# another client goes through the server, which forwards by the envelope's "to".
func _sendRaw(peer, env: Dictionary, reliable: bool = true):
	var bytes = var2bytes(env)
	match transport:
		Transport.STEAM:
			Steam.sendP2PPacket(peer, bytes, P2P_RELIABLE if reliable else P2P_UNRELIABLE, CHANNEL)
		Transport.ENET:
			enet.set_transfer_mode(NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
			if isHost or peer == 1:
				enet.set_target_peer(peer)
			else:
				env["to"] = peer
				bytes = var2bytes(env)
				enet.set_target_peer(1)
			enet.put_packet(bytes)
	stats.bytes_out += bytes.size()

func _send(peer, msg: Dictionary, reliable: bool):
	_sendRaw(peer, {"f": myId, "m": msg}, reliable)

func _broadcast(msg: Dictionary, reliable: bool):
	for p in peers.keys():
		_send(p, msg, reliable)

func _physics_process(delta):
	# All network state is applied here, on the physics tick, never from callbacks.
	match transport:
		Transport.STEAM:
			if not steamReady:
				return
			var size = Steam.getAvailableP2PPacketSize(CHANNEL)
			while size > 0:
				var p = Steam.readP2PPacket(size, CHANNEL)
				if p.has("data"):
					_recvRaw(p.steam_id_remote, p.data)
				size = Steam.getAvailableP2PPacketSize(CHANNEL)
		Transport.ENET:
			enet.poll()
			while enet.get_available_packet_count() > 0:
				var from = enet.get_packet_peer()
				_recvRaw(from, enet.get_packet())

	if peers.size() > 0:
		pingTimer += delta
		if pingTimer >= PING_EVERY:
			pingTimer = 0.0
			pingSeq += 1
			pingSent[pingSeq] = OS.get_ticks_msec()
			_broadcast({"t": "ping", "seq": pingSeq}, false)

	_sessionTick(delta)

func _recvRaw(link, bytes: PoolByteArray):
	stats.bytes_in += bytes.size()
	var env = bytes2var(bytes)
	if not (env is Dictionary) or not env.has("m") or not env.has("f"):
		Debug.l("COOP: bad packet on link %s (%d bytes)" % [link, bytes.size()])
		return
	if transport == Transport.ENET and isHost and env.has("to") and env.to != myId:
		# relay client -> client
		var to = env.to
		env.erase("to")
		var reliable = (env.m.get("t") in ["hello", "ship", "shipreq", "bye", "peerlist", "peergone"])
		var out = var2bytes(env)
		enet.set_transfer_mode(NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
		enet.set_target_peer(to)
		enet.put_packet(out)
		stats.bytes_out += out.size()
		return
	_recv(env.f, env.m)

func _recv(from, msg: Dictionary):
	if not msg.has("t"):
		return
	match msg.t:
		"peerlist":
			for id in msg.ids:
				_peerSeen(id)
				_sendHello(id)
		"peergone":
			_peerGone(msg.id)
		"hello":
			_peerSeen(from)
			peers[from].name = str(msg.get("name"))
			Debug.l("COOP: HELLO from %s name=%s host=%s dived=%s" % [from, msg.get("name"), msg.get("host"), msg.get("dived")])
		"ping":
			_send(from, {"t": "pong", "seq": msg.seq}, false)
		"pong":
			var t0 = pingSent.get(msg.seq, -1)
			if t0 >= 0:
				stats.rtt_ms = OS.get_ticks_msec() - t0
				pingSent.erase(msg.seq)
		"beacon":
			_peerSeen(from)
			peers[from].beacon = msg
			peers[from].beaconAt = OS.get_ticks_msec() / 1000.0
		"shipreq":
			if dived:
				_sendShip(from)
		"ship":
			_peerSeen(from)
			peers[from].cfg = msg.cfg
			Debug.l("COOP: SHIP config from %s (%s)" % [from, peers[from].name])
		"intent":
			var pp = _puppetOf(from)
			if pp != null:
				pp.netSchedule = msg.s
		"state":
			var pp = _puppetOf(from)
			if pp != null:
				pp.netState = {"p": msg.p, "r": msg.r, "v": msg.v, "w": msg.w, "at": OS.get_ticks_msec()}
		"bye":
			Debug.l("COOP: BYE from %s" % from)
			_peerGone(from)
		_:
			Debug.l("COOP: unknown packet type %s" % msg.t)

func _puppetOf(id):
	if peers.has(id):
		var pp = peers[id].puppet
		if pp != null and is_instance_valid(pp):
			return pp
	return null

# ---------------------------------------------------------------- session

func _gameScene():
	var c = Loader.current
	if c != null and is_instance_valid(c) and c.has_node("AsteroidField"):
		return c
	return null

func _atTitle():
	var c = Loader.current
	return c != null and is_instance_valid(c) and c.filename == "res://TitleScreen.tscn"

func _zone():
	if dived:
		return "rings"
	if _atTitle():
		return "title"
	return "station"

func captureIntent(ship, schedule: Dictionary):
	if ship == localShip:
		lastIntent = schedule.duplicate(true)

func _sendShip(peer):
	_send(peer, {"t": "ship", "cfg": CurrentGame.state.ship.duplicate(true)}, true)

func _sendBeacon():
	var b = {"t": "beacon", "zone": _zone(), "name": _myName()}
	if dived and localShip != null and is_instance_valid(localShip):
		b.p = CurrentGame.globalCoords(localShip.global_position)
		b.v = localShip.linear_velocity
		b.r = localShip.global_rotation
		b.ship = localShip.get("shipName")
		b.tr = localShip.get("transponder")
	_broadcast(b, false)

func _sessionTick(delta):
	var game = _gameScene()

	# --- enter / leave dive
	if game != null and not dived:
		var ship = CurrentGame.getPlayerShip()
		if ship != null and is_instance_valid(ship) and ship.is_inside_tree() and ship.get("setup") == true:
			dived = true
			localShip = ship
			Debug.l("COOP: in dive with ship '%s' at %s, peers=%s" % [ship.name, CurrentGame.globalCoords(ship.global_position), peers.keys()])
			_sendBeacon()
			_showOverlay(game)
	elif game == null and dived:
		Debug.l("COOP: left dive")
		dived = false
		localShip = null
		lastIntent = null
		_hideOverlay()
		for id in peers.keys():
			_despawnPuppet(id, "left dive")
		_sendBeacon()

	# --- dev auto-dive: everyone dives on their own, same target (+ offset)
	if autoDive and not autoDiveStarted and _atTitle() and peers.size() > 0:
		autoDiveStarted = true
		Debug.l("COOP: autodive to %s" % [DEV_DIVE_TARGET + autoDiveOffset])
		CurrentGame.loadFromFile()
		CurrentGame.diveTarget = DEV_DIVE_TARGET + autoDiveOffset
		Loader.go(GAME_SCENE)

	# --- beacons
	beaconAccum += delta
	if beaconAccum >= 1.0 / BEACON_HZ and peers.size() > 0:
		beaconAccum = 0.0
		_sendBeacon()

	# --- range and puppets
	var now = OS.get_ticks_msec() / 1000.0
	var inRange = []
	for id in peers.keys():
		var pr = peers[id]
		var b = pr.beacon
		var stale = (b == null) or (now - pr.beaconAt > BEACON_TIMEOUT)
		var dist = -1.0
		if not stale and b.get("zone") == "rings" and b.has("p") and dived and localShip != null and is_instance_valid(localShip):
			dist = CurrentGame.globalCoords(localShip.global_position).distance_to(b.p)
		var want = false
		if dist >= 0:
			want = dist < (RANGE_PUPPET_DROP if pr.inRange else RANGE_PUPPET)
		if want:
			inRange.append(id)
			if not pr.inRange:
				pr.inRange = true
				Debug.l("COOP: %s (%s) entered range at %.0f px" % [id, pr.name, dist])
			if pr.cfg == null:
				if not pr.has("cfgAskedAt") or now - pr.cfgAskedAt > 2.0:
					pr.cfgAskedAt = now
					_send(id, {"t": "shipreq"}, true)
			elif _puppetOf(id) == null and game != null:
				_spawnPuppet(id, game)
		else:
			if pr.inRange:
				pr.inRange = false
				Debug.l("COOP: %s (%s) left range (dist %.0f, stale %s)" % [id, pr.name, dist, stale])
			_despawnPuppet(id, "out of range")

	# --- streams to peers in range
	if dived and localShip != null and is_instance_valid(localShip) and inRange.size() > 0:
		intentAccum += delta
		if intentAccum >= 1.0 / INTENT_HZ and lastIntent != null:
			intentAccum = 0.0
			for id in inRange:
				_send(id, {"t": "intent", "s": lastIntent}, false)
		stateAccum += delta
		if stateAccum >= 1.0 / STATE_HZ:
			stateAccum = 0.0
			var st = {
				"t": "state",
				"p": CurrentGame.globalCoords(localShip.global_position),
				"r": localShip.global_rotation,
				"v": localShip.linear_velocity,
				"w": localShip.angular_velocity,
			}
			for id in inRange:
				_send(id, st, false)

	statsAccum += delta
	if statsAccum >= 5.0 and peers.size() > 0:
		statsAccum = 0.0
		var seps = []
		for id in inRange:
			var pp = _puppetOf(id)
			if pp != null and localShip != null and is_instance_valid(localShip):
				seps.append("%s:%.0f" % [peers[id].name, localShip.global_position.distance_to(pp.global_position)])
		Debug.l("COOP: rtt=%d ms out=%.1f kB/s in=%.1f kB/s peers=%d inRange=%d sep=[%s]" % [stats.rtt_ms, stats.bytes_out / 5000.0, stats.bytes_in / 5000.0, peers.size(), inRange.size(), PoolStringArray(seps).join(" ")])
		stats.bytes_out = 0
		stats.bytes_in = 0

func _spawnPuppet(id, game):
	var pr = peers[id]
	if localShip == null or not is_instance_valid(localShip) or pr.cfg == null or pr.beacon == null:
		return
	var field = game.get_node("AsteroidField")
	var ship = Shipyard.createShipByConfig(pr.cfg.duplicate(true), false)
	if ship == null:
		Debug.l("COOP: puppet createShipByConfig failed for %s" % id)
		pr.cfg = null
		return
	ship.netControlled = true
	ship.ai = false
	ship.playerControlled = false
	ship.autopilot = false
	ship.preheat = true
	var spot = CurrentGame.localCoords(pr.beacon.p) if pr.beacon.has("p") else localShip.global_position + Vector2(0, - 1500)
	var vel = pr.beacon.v if pr.beacon.has("v") else Vector2(0, 0)
	var ok = field.spawnByBlueprint(ship, spot, 0, 200, vel)
	if ok:
		pr.puppet = ship
		Debug.l("COOP: puppet '%s' for %s spawned at %s" % [ship.name, pr.name, CurrentGame.globalCoords(ship.global_position)])
	else:
		Debug.l("COOP: puppet spawn for %s failed (no free spot), retrying" % pr.name)
		ship.free()

var overlay = null

func _showOverlay(game):
	_hideOverlay()
	overlay = load("res://dv-coop/ui/FriendOverlay.gd").new()
	overlay.name = "CoopFriendOverlay"
	overlay.net = self
	game.add_child(overlay)

func _hideOverlay():
	if overlay != null and is_instance_valid(overlay):
		overlay.queue_free()
	overlay = null

func _despawnPuppet(id, why):
	if not peers.has(id):
		return
	var pp = peers[id].puppet
	if pp != null and is_instance_valid(pp):
		Debug.l("COOP: despawning puppet of %s (%s)" % [peers[id].name, why])
		pp.queue_free()
	peers[id].puppet = null
