extends Node

# Npc: other ships' lives and deaths across machines (M4 Ships track). See docs/M4-OWNERSHIP.md.
#
# s.die  the owner's ship started exploding. Everyone else plays the stock explosion on its puppet as a picture
#        (Reactor ext: no story flag; ship-ctrl ext: the puppet hides instead of vanishing, no lifepod, no save
#        writes). The blast's push on rocks happens on the machine simulating the rocks (Reactor ext).
#
# Dev: --coop-dev-explode=<s>  s seconds after my dive cutscene ends, blow up my own ship (gate 8).

var net = null   # CoopNet

var explodeAfter = -1.0
var explodeClock = 0.0
var exploded = false

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
