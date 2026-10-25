extends Node

# Npc: other ships' lives and deaths across machines (M4 Ships track). See docs/M4-OWNERSHIP.md.
#
# s.die  the owner's ship started exploding. Everyone else plays the stock explosion on its puppet as a picture
#        (Reactor ext: no story flag; ship-ctrl ext: the puppet hides instead of vanishing, no lifepod, no save
#        writes). The blast's push on rocks happens on the machine simulating the rocks (Reactor ext).
# pods   a player whose ship died flies its lifepod (beacon kind "pod"). A lifepod is a plain RigidBody2D, not a
#        ship-ctrl ship, so it can't be a CoopNet puppet; it is mirrored here as a kinematic Lifepod placed from
#        the owner's 20 Hz state (peers[id].state), tagged dvnet_puppet so claws and holds leave it alone.
#
# Dev: --coop-dev-explode=<s>  s seconds after my dive cutscene ends, blow up my own ship (gate 8).

var net = null   # CoopNet

var explodeAfter = -1.0
var explodeClock = 0.0
var exploded = false

const LIFEPOD = "res://ships/Lifepod.tscn"
const POD_MAX_EXTRAPOLATION = 0.25
var pods = {}    # peer id -> mirror Lifepod

func _ready():
	name = "Npc"
	net.on("s.die", self, "_onDie")
	for arg in OS.get_cmdline_args():
		if arg.begins_with("--coop-dev-explode="):
			explodeAfter = float(arg.substr(19))

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
	_podsTick()
	_devExplodeTick(delta)

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
