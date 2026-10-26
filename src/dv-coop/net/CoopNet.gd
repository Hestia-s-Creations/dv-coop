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
#   +connect_lobby <id>         Steam's own: a friend's invite accepted with the game closed (goes through requestJoin)
#   --coop-dev-enet=<host:port> dev (M5): the co-op panel's Host and Join use this ENet relay instead of Steam
#
# M5 session API, driven by the co-op panel (ui/CoopPanel.gd): host(), join(lobby), leave(), requestJoin(lobby, from)
# for every outside join request, answerJoin(yes). A lobby is a Steam lobby id (int) or, on the ENet dev transport, a
# "host:port" string. A drop without leave() reconnects to the same lobby with backoff (1, 2, 4, 8 s, then 15 s).

const CHANNEL = 0
const P2P_UNRELIABLE = 0
const P2P_RELIABLE = 2
const LOBBY_FRIENDS_ONLY = 1
const LOBBY_MAX = 5
const PING_EVERY = 1.0
const BEACON_HZ = 1.0
const INTENT_HZ = 30.0
const STATE_HZ = 20.0
# Wire protocol version: bump on any incompatible packet change. hello carries it with the mod version and game
# build, and peers that differ are turned away (review R10).
const PROTO = 1
const RANGE_PUPPET = 40000.0
const RANGE_PUPPET_DROP = 45000.0
const BEACON_TIMEOUT = 6.0
const GAME_SCENE = "res://Game.tscn"
const DEV_DIVE_TARGET = Vector2(15000, 12345678)
# Child modules, in order. Missing files are skipped, so a module can land on its own branch first.
const MODULES = ["res://dv-coop/net/Cell.gd", "res://dv-coop/net/RockSync.gd", "res://dv-coop/net/Own.gd", "res://dv-coop/net/Npc.gd", "res://dv-coop/net/Travel.gd", "res://dv-coop/net/DevBot.gd"]

enum Transport { NONE, STEAM, ENET }

signal session_changed

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

# --- session (M5)
var devEnet = ""          # --coop-dev-enet: Host / Join go to this ENet relay
var steamHooked = false
var wantLobby = null      # the lobby we are in or on our way to; null = none. -1: a Steam lobby we are creating
var wantRole = ""         # "host" | "join"
var state = "idle"        # idle, hosting, joining, in lobby, reconnecting
var retryAt = -1.0
var retryN = 0
var holdUntil = 0.0       # dev drop: no reconnect before this
var pendingJoin = null    # {lobby, from, shown}: an outside join request waiting for the player
var connectLobby = ""     # +connect_lobby from the launch options
const RETRY_STEPS = [1.0, 2.0, 4.0, 8.0, 15.0]

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

# --- modules (M3+): packet type -> [object, method], called as method(from, msg) on the physics tick
var handlers = {}

# peers turned away by the hello check: id -> "name: why", for the friend list (review R10)
var incompatible = {}

func _ready():
	for path in MODULES:
		if not ResourceLoader.exists(path):
			continue
		var m = load(path).new()
		m.net = self
		add_child(m)
	var args = OS.get_cmdline_args()
	for i in range(args.size()):
		var arg = args[i]
		if arg == "+connect_lobby" and i + 1 < args.size():
			connectLobby = args[i + 1]
		elif arg.begins_with("--coop-dev-enet="):
			devEnet = arg.substr(16)
		elif arg == "--coop-host":
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

	if enetHostPort > 0:
		_startEnet()
	elif enetJoin != "":
		join(enetJoin)
	elif wantHost:
		host()
	elif joinLobbyId != 0:
		join(joinLobbyId)
	else:
		Debug.l("COOP: no session requested, CoopNet idle (co-op panel: host / join)")
	if connectLobby != "":
		call_deferred("requestJoin", lobbyKey(connectLobby), "Steam invite")

func _exit_tree():
	# Tell everyone we're going, so cells hand over at once instead of waiting out the heartbeat.
	if peers.size() > 0 and transport != Transport.NONE:
		_broadcast({"t": "bye"}, true)
		if enet != null:
			enet.poll()
	if transport == Transport.STEAM and lobbyId != 0:
		Steam.leaveLobby(lobbyId)
	if ModLoader.has_meta("dvcoop"):
		ModLoader.remove_meta("dvcoop")

# ---------------------------------------------------------------- Steam

var steamMissingLogged = false

func _process(delta):
	if not steamHooked:
		if Engine.has_singleton("Steam"):
			if Steam.loggedOn():
				_onSteamReady()
		elif transport == Transport.STEAM and not steamMissingLogged:
			steamMissingLogged = true
			Debug.l("COOP: Steam singleton missing, cannot use Steam transport")
	_retryTick()

func _onSteamReady():
	steamHooked = true
	steamReady = true
	if transport != Transport.ENET:
		myId = Steam.getSteamID()
	Debug.l("COOP: Steam ready, I am %d (%s)" % [Steam.getSteamID(), Steam.getPersonaName()])
	Steam.connect("lobby_created", self, "_onLobbyCreated")
	Steam.connect("lobby_joined", self, "_onLobbyJoined")
	Steam.connect("lobby_chat_update", self, "_onLobbyChatUpdate")
	Steam.connect("p2p_session_request", self, "_onP2PSessionRequest")
	Steam.connect("p2p_session_connect_fail", self, "_onP2PConnectFail")
	Steam.connect("join_requested", self, "_onJoinRequested")
	Steam.allowP2PPacketRelay(true)
	if transport == Transport.STEAM:
		_steamGo()

# Start what host() / join() asked for, once Steam is up.
func _steamGo():
	if wantRole == "host" and typeof(wantLobby) == TYPE_INT and wantLobby == -1:
		isHost = true
		Debug.l("COOP: creating lobby")
		Steam.createLobby(LOBBY_FRIENDS_ONLY, LOBBY_MAX)
	elif typeof(wantLobby) == TYPE_INT and wantLobby > 0:
		Debug.l("COOP: joining lobby %d" % wantLobby)
		Steam.joinLobby(wantLobby)

func _onLobbyCreated(result, lobby):
	Debug.l("COOP: lobby_created result=%s lobby=%d" % [result, lobby])
	if result != 1:
		return
	lobbyId = lobby
	wantLobby = lobby
	Steam.setLobbyData(lobbyId, "dvcoop", "1")
	Steam.setLobbyData(lobbyId, "build", str(CurrentGame.get("version")))
	Steam.setLobbyJoinable(lobbyId, true)
	Debug.l("COOP: LOBBY ID %d  (others run: --enable-mods --coop-join=%d)" % [lobbyId, lobbyId])
	_steamPresence()
	_inLobby()
	if wantInvite:
		Steam.activateGameOverlayInviteDialog(lobbyId)

func _onLobbyJoined(lobby, permissions, locked, response):
	Debug.l("COOP: lobby_joined lobby=%d response=%s" % [lobby, response])
	if response != 1:
		if retryAt < 0:
			Debug.l("COOP: SESSION join of lobby %d failed (response %s)" % [lobby, response])
			_reset()
		return
	lobbyId = lobby
	wantLobby = lobby
	_steamPresence()
	_inLobby()
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
	# only players in our lobby may open a session with us
	var member = false
	if lobbyId != 0:
		for i in range(Steam.getNumLobbyMembers(lobbyId)):
			if Steam.getLobbyMemberByIndex(lobbyId, i) == remoteId:
				member = true
	Debug.l("COOP: p2p_session_request from %d (%s)" % [remoteId, "lobby member, accepted" if member else "not in our lobby, ignored"])
	if member:
		Steam.acceptP2PSessionWithUser(remoteId)

func _onP2PConnectFail(steamId, sessionError):
	Debug.l("COOP: p2p_session_connect_fail %d err=%s" % [steamId, sessionError])

func _onJoinRequested(lobby, friendId):
	Debug.l("COOP: join_requested lobby=%d from=%d" % [lobby, friendId])
	requestJoin(lobby, Steam.getFriendPersonaName(friendId))

func _steamPresence():
	Steam.setRichPresence("connect", "+connect_lobby %d" % lobbyId)
	Steam.setRichPresence("status", "dV co-op")

# ---------------------------------------------------------------- session (M5)

func lobbyKey(s):
	# a Steam lobby id, or "host:port" on the ENet dev transport
	return s if ":" in str(s) else int(s)

# Lobbies are ints or strings, and Godot 3 errors on == between the two.
func sameLobby(a, b) -> bool:
	return typeof(a) == typeof(b) and a == b

func inLobby() -> bool:
	return state == "in lobby"

func host():
	leave()
	wantRole = "host"
	if devEnet != "":
		wantLobby = devEnet
		_enetConnect(devEnet)
	else:
		transport = Transport.STEAM
		wantLobby = -1
		if steamReady:
			_steamGo()
	_setState("hosting")

func join(lobby):
	leave()
	wantRole = "join"
	wantLobby = lobby
	if typeof(lobby) == TYPE_STRING:
		_enetConnect(lobby)
	else:
		transport = Transport.STEAM
		if steamReady:
			_steamGo()
	_setState("joining")

func leave():
	if transport == Transport.NONE and typeof(wantLobby) == TYPE_NIL:
		return
	Debug.l("COOP: SESSION leaving lobby %s" % [wantLobby])
	if peers.size() > 0:
		_broadcast({"t": "bye"}, true)
		if enet != null:
			enet.poll()
	_dropLink()
	_reset()

# An outside request to join a lobby: Steam's join_requested, +connect_lobby, a friend row's Join. Nothing happens
# until the player answers: the co-op panel shows the question where the player is (net/Travel.gd decides when).
func requestJoin(lobby, from):
	if sameLobby(lobby, wantLobby) and inLobby():
		Debug.l("COOP: SESSION join request for lobby %s: already in it" % [lobby])
		return
	pendingJoin = {"lobby": lobby, "from": str(from), "shown": false}
	Debug.l("COOP: SESSION join request for lobby %s from %s" % [lobby, from])
	emit_signal("session_changed")

func answerJoin(yes: bool):
	if typeof(pendingJoin) == TYPE_NIL:
		return
	var lobby = pendingJoin.lobby
	Debug.l("COOP: SESSION join request for lobby %s answered %s" % [lobby, "yes" if yes else "no"])
	pendingJoin = null
	if yes:
		join(lobby)
	else:
		emit_signal("session_changed")

func _setState(s):
	if state == s:
		return
	state = s
	Debug.l("COOP: SESSION %s (lobby %s)" % [s, wantLobby])
	emit_signal("session_changed")

func _inLobby():
	if retryAt >= 0:
		Debug.l("COOP: SESSION reconnected to lobby %s after %d attempt(s)" % [wantLobby, retryN])
	retryAt = -1.0
	retryN = 0
	_setState("in lobby")

func _reset():
	transport = Transport.NONE
	isHost = false
	lobbyId = 0
	wantLobby = null
	wantRole = ""
	retryAt = -1.0
	retryN = 0
	_setState("idle")

# Close the transport link without forgetting the lobby.
func _dropLink():
	for id in peers.keys():
		_peerGone(id)
	if enet != null:
		enet.close_connection()
		enet = null
	if transport == Transport.STEAM and lobbyId != 0:
		Steam.leaveLobby(lobbyId)
		Steam.clearRichPresence()
		lobbyId = 0

func _transportLost(why):
	if typeof(wantLobby) == TYPE_NIL:
		return
	Debug.l("COOP: SESSION link to lobby %s lost (%s), reconnecting" % [wantLobby, why])
	_dropLink()
	retryN = 0
	retryAt = max(_now() + RETRY_STEPS[0], holdUntil)
	_setState("reconnecting")

# dev: cut the link for `secs` without a bye, as a pulled cable would, then let the reconnect loop bring it back
func devDrop(secs: float):
	holdUntil = _now() + secs
	_transportLost("dev drop for %.0f s" % secs)

func _retryTick():
	if retryAt < 0 or _now() < retryAt:
		return
	retryN += 1
	retryAt = _now() + RETRY_STEPS[min(retryN, RETRY_STEPS.size() - 1)]
	Debug.l("COOP: SESSION reconnect attempt %d to lobby %s" % [retryN, wantLobby])
	if typeof(wantLobby) == TYPE_STRING:
		_enetConnect(wantLobby)
	elif steamReady and typeof(wantLobby) == TYPE_INT and wantLobby > 0:
		Steam.joinLobby(wantLobby)

func _now():
	return OS.get_ticks_msec() / 1000.0

# Steam has no "you dropped" event for us: if every peer that was beaconing has gone quiet while the lobby still
# lists them, our link is gone.
func _steamWatch():
	if transport != Transport.STEAM or lobbyId == 0 or retryAt >= 0 or peers.size() == 0:
		return
	var now = _now()
	for id in peers:
		if peers[id].beaconAt <= 0.0 or now - peers[id].beaconAt < 2 * BEACON_TIMEOUT:
			return
	_transportLost("every peer silent for %.0f s" % (2 * BEACON_TIMEOUT))

# ---------------------------------------------------------------- ENet (dev star, server relays)

func _startEnet():
	transport = Transport.ENET
	enet = NetworkedMultiplayerENet.new()
	var err
	isHost = true
	err = enet.create_server(enetHostPort, LOBBY_MAX - 1)
	Debug.l("COOP: ENet server on %d -> %s" % [enetHostPort, err])
	myId = enet.get_unique_id()
	enet.connect("peer_connected", self, "_onEnetPeer")
	enet.connect("peer_disconnected", self, "_onEnetPeerGone")
	enet.connect("connection_succeeded", self, "_onEnetConnected")
	enet.connect("connection_failed", self, "_onEnetFailed")

func _enetConnect(addr: String):
	transport = Transport.ENET
	if enet != null:
		enet.close_connection()
	enet = NetworkedMultiplayerENet.new()
	var parts = addr.split(":")
	var port = int(parts[1]) if parts.size() > 1 else 7777
	var err = enet.create_client(parts[0], port)
	Debug.l("COOP: ENet client to %s:%d -> %s" % [parts[0], port, err])
	myId = enet.get_unique_id()
	enet.connect("peer_connected", self, "_onEnetPeer")
	enet.connect("peer_disconnected", self, "_onEnetPeerGone")
	enet.connect("connection_succeeded", self, "_onEnetConnected")
	enet.connect("connection_failed", self, "_onEnetFailed")
	enet.connect("server_disconnected", self, "_onEnetServerGone")

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
	_inLobby()

func _onEnetFailed():
	Debug.l("COOP: ENet connection failed")
	# deferred: these arrive from inside enet.poll(), and _transportLost closes that connection
	if retryAt < 0 and typeof(wantLobby) != TYPE_NIL:
		call_deferred("_transportLost", "connection failed")

func _onEnetServerGone():
	call_deferred("_transportLost", "relay disconnected")

# ---------------------------------------------------------------- packets

func _myName():
	if transport == Transport.STEAM:
		return Steam.getPersonaName()
	var user = OS.get_environment("USERNAME")
	if user == "":
		user = OS.get_environment("USER")
	return "%s-%d" % [user, myId % 1000]

func _peerSeen(id):
	if not peers.has(id):
		peers[id] = {"name": str(id), "beacon": null, "beaconAt": 0.0, "cfg": null, "puppet": null, "inRange": false}

func _peerGone(id):
	if peers.has(id):
		_despawnPuppet(id, "peer gone")
		peers.erase(id)

func _sendHello(peer):
	_send(peer, {"t": "hello", "name": _myName(), "host": isHost, "dived": dived, "proto": PROTO, "mod": _modVersion(), "build": str(CurrentGame.get("version"))}, true)

func _modVersion() -> String:
	var root = get_parent()
	return str(root.get("MOD_VERSION")) if root != null else "?"

# Transport-level send. On ENet, clients can only talk to the server (1); anything for
# another client goes through the server, which forwards by the envelope's "to".
func _sendRaw(peer, env: Dictionary, reliable: bool = true):
	var bytes = var2bytes(env)
	match transport:
		Transport.STEAM:
			Steam.sendP2PPacket(peer, bytes, P2P_RELIABLE if reliable else P2P_UNRELIABLE, CHANNEL)
		Transport.ENET:
			if enet == null:
				return
			enet.set_transfer_mode(NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
			if isHost or peer == 1:
				enet.set_target_peer(peer)
			else:
				env["to"] = peer
				env["rel"] = reliable
				bytes = var2bytes(env)
				enet.set_target_peer(1)
			enet.put_packet(bytes)
	stats.bytes_out += bytes.size()

func _send(peer, msg: Dictionary, reliable: bool):
	_sendRaw(peer, {"f": myId, "m": msg}, reliable)

func _broadcast(msg: Dictionary, reliable: bool):
	for p in peers.keys():
		_send(p, msg, reliable)

# --- module API (M3+). Modules are child nodes of CoopNet; they read peers, myId, dived and localShip directly.

# Route packets of type t to obj.method(from, msg). Module packet types are namespaced: "c.*" cells, "r.*" rocks.
func on(t: String, obj: Object, method: String):
	handlers[t] = [obj, method]

func send(peer, msg: Dictionary, reliable: bool):
	_send(peer, msg, reliable)

func sendTo(ids: Array, msg: Dictionary, reliable: bool):
	for p in ids:
		if p != myId:
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
					# this game's GodotSteam names the sender "remote_steam_id"; older builds "steam_id_remote"
					_recvRaw(p.get("remote_steam_id", p.get("steam_id_remote", 0)), p.data)
				size = Steam.getAvailableP2PPacketSize(CHANNEL)
			_steamWatch()
		Transport.ENET:
			if enet == null:
				return
			enet.poll()
			while enet != null and enet.get_available_packet_count() > 0:
				var from = enet.get_packet_peer()
				_recvRaw(from, enet.get_packet())

	if peers.size() > 0:
		pingTimer += delta
		if pingTimer >= PING_EVERY:
			pingTimer = 0.0
			pingSeq += 1
			var t = OS.get_ticks_msec()
			pingSent[pingSeq] = t
			# one ping goes to every peer, so keep each entry until its pongs are in (or 5 s, if some are lost)
			for seq in pingSent.keys():
				if t - pingSent[seq] > 5000:
					pingSent.erase(seq)
			_broadcast({"t": "ping", "seq": pingSeq}, false)

	_sessionTick(delta)

func _recvRaw(link, bytes: PoolByteArray):
	stats.bytes_in += bytes.size()
	var env = bytes2var(bytes)
	if not (env is Dictionary) or not env.has("m") or not env.has("f"):
		Debug.l("COOP: bad packet on link %s (%d bytes)" % [link, bytes.size()])
		return
	# The sender is the link, never what the packet claims: on Steam the link is the sender; on ENet the relay
	# (server) checks its clients, and a client hears only the relay, which forwards with the checked sender.
	var forged = false
	match transport:
		Transport.STEAM:
			forged = env.f != link
		Transport.ENET:
			forged = (env.f != link) if isHost else (link != 1)
	if forged:
		Debug.l("COOP: packet on link %s claims sender %s, dropped" % [link, env.f])
		return
	if transport == Transport.ENET and isHost and env.has("to") and env.to != myId:
		# relay client -> client
		var to = env.to
		if not peers.has(to):
			return   # already gone
		env.erase("to")
		var reliable = env.get("rel", true)
		env.erase("rel")
		var out = var2bytes(env)
		enet.set_transfer_mode(NetworkedMultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else NetworkedMultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
		enet.set_target_peer(to)
		enet.put_packet(out)
		stats.bytes_out += out.size()
		return
	_recv(env.f, env.m)

# Field types of the core packets; a packet that doesn't match is dropped, not half-applied (review R26).
const SHAPES = {
	"peerlist": {"ids": TYPE_ARRAY},
	"peergone": {"id": TYPE_INT},
	"ping": {"seq": TYPE_INT},
	"pong": {"seq": TYPE_INT},
	"ship": {"cfg": TYPE_DICTIONARY},
	"intent": {"s": TYPE_DICTIONARY},
	"state": {"p": TYPE_VECTOR2, "r": TYPE_REAL, "v": TYPE_VECTOR2, "w": TYPE_REAL},
}
const BEACON_SHAPE = {"zone": TYPE_STRING, "p": TYPE_VECTOR2, "v": TYPE_VECTOR2, "r": TYPE_REAL}

func _shaped(msg: Dictionary, shape: Dictionary, optional: bool) -> bool:
	for k in shape:
		if msg.has(k):
			if typeof(msg[k]) != shape[k]:
				return false
		elif not optional:
			return false
	return true

func _recv(from, msg: Dictionary):
	if not msg.has("t") or typeof(msg.t) != TYPE_STRING:
		return
	if (SHAPES.has(msg.t) and not _shaped(msg, SHAPES[msg.t], false)) or (msg.t == "beacon" and not _shaped(msg, BEACON_SHAPE, true)):
		Debug.l("COOP: malformed %s from %s dropped" % [msg.t, from])
		return
	if incompatible.has(from) and msg.t != "hello":
		return
	match msg.t:
		"peerlist":
			for id in msg.ids:
				_peerSeen(id)
				_sendHello(id)
		"peergone":
			_peerGone(msg.id)
		"hello":
			var why = _incompatibility(msg)
			if why != "":
				if not incompatible.has(from):
					Debug.l("COOP: HELLO from %s name=%s turned away: %s" % [from, msg.get("name"), why])
				incompatible[from] = "%s: %s" % [msg.get("name"), why]
				_peerGone(from)
				emit_signal("session_changed")
				return
			incompatible.erase(from)
			_peerSeen(from)
			peers[from].name = str(msg.get("name"))
			Debug.l("COOP: HELLO from %s name=%s host=%s dived=%s mod=%s build=%s" % [from, msg.get("name"), msg.get("host"), msg.get("dived"), msg.get("mod"), msg.get("build")])
		"ping":
			_send(from, {"t": "pong", "seq": msg.seq}, false)
		"pong":
			var t0 = pingSent.get(msg.seq, -1)
			if t0 >= 0:
				var rtt = OS.get_ticks_msec() - t0
				stats.rtt_ms = rtt
				if peers.has(from):
					peers[from].rtt = rtt
		"beacon":
			_peerSeen(from)
			var now = OS.get_ticks_msec() / 1000.0
			var old = peers[from].beacon
			# measured ring velocity between two beacons (a paused game still reports its ship's velocity)
			if old != null and old.has("p") and msg.has("p") and now > peers[from].beaconAt:
				peers[from].moved = (msg.p - old.p) / (now - peers[from].beaconAt)
			else:
				peers[from].erase("moved")
			peers[from].beacon = msg
			peers[from].beaconAt = now
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
			if peers.has(from):
				peers[from].state = {"p": msg.p, "r": msg.r, "v": msg.v, "w": msg.w, "at": OS.get_ticks_msec()}
			var pp = _puppetOf(from)
			if pp != null:
				pp.netState = {"p": msg.p, "r": msg.r, "v": msg.v, "w": msg.w, "at": OS.get_ticks_msec()}
		"bye":
			Debug.l("COOP: BYE from %s" % from)
			_peerGone(from)
		_:
			if handlers.has(msg.t):
				handlers[msg.t][0].call(handlers[msg.t][1], from, msg)
			else:
				Debug.l("COOP: unknown packet type %s" % msg.t)

# "" when a hello's sender can play with us, else why not (shown in the friend list).
func _incompatibility(msg: Dictionary) -> String:
	if msg.get("proto") != PROTO:
		return "different co-op protocol (%s, ours %d)" % [msg.get("proto", "none"), PROTO]
	if str(msg.get("mod")) != _modVersion():
		return "different mod version (%s, ours %s)" % [msg.get("mod"), _modVersion()]
	if str(msg.get("build")) != str(CurrentGame.get("version")):
		return "different game build (%s, ours %s)" % [msg.get("build"), CurrentGame.get("version")]
	return ""

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
		b.kind = "ship" if "shipConfig" in localShip else "pod"   # after a ship dies the player flies its lifepod
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

	# --- our ship died: the game hands the player its lifepod (or a rescue ship); follow it
	if dived and (localShip == null or not is_instance_valid(localShip) or localShip.get("dead") == true):
		var next = CurrentGame.getPlayerShip()
		if next != null and is_instance_valid(next) and next != localShip and next.is_inside_tree():
			Debug.l("COOP: local ship is now '%s' (%s)" % [next.name, "ship" if "shipConfig" in next else "pod"])
			localShip = next
			lastIntent = null
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
			if pr.beacon.get("kind", "ship") != "ship":
				# a lifepod is not a ship-ctrl ship; Npc.gd mirrors it from peers[id].state
				_despawnPuppet(id, "flying a lifepod")
			elif pr.cfg == null:
				if not pr.has("cfgAskedAt") or now - pr.cfgAskedAt > 2.0:
					pr.cfgAskedAt = now
					_send(id, {"t": "shipreq"}, true)
			elif _puppetOf(id) == null and game != null and now - pr.get("spawnFailedAt", -9.0) > 1.0:
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
	var claims = _stripClaims(ship)
	if claims > 0:
		Debug.l("COOP: puppet for %s: %d drone/claim spawner(s) emptied" % [id, claims])
	ship.netControlled = true
	ship.set_meta("dvnet_puppet", id)   # the spawner and RockSync must never free a puppet; only _despawnPuppet does
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
		Debug.l("COOP: puppet spawn for %s failed (no free spot), retrying in 1 s" % pr.name)
		pr.spawnFailedAt = OS.get_ticks_msec() / 1000.0
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

# ClaimOwner moves its children (drones, claimed modules) into the field as separate ships when the ship
# enters the tree. On a puppet that would spawn the other player's drones as our own AI ships, so empty
# every ClaimOwner first; the owner's real drones get replicated separately (M4).
const CLAIM_OWNER = "res://ships/modules/ClaimOwner.gd"

func _stripClaims(node) -> int:
	var count = 0
	for child in node.get_children():
		var s = child.get_script()
		if s != null and s.resource_path == CLAIM_OWNER:
			for c in child.get_children():
				child.remove_child(c)
				c.queue_free()
			count += 1
		else:
			count += _stripClaims(child)
	return count

func _despawnPuppet(id, why):
	if not peers.has(id):
		return
	var pp = peers[id].puppet
	if pp != null and is_instance_valid(pp):
		Debug.l("COOP: despawning puppet of %s (%s)" % [peers[id].name, why])
		pp.queue_free()
	peers[id].puppet = null
