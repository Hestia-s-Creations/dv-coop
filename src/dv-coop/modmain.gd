extends Node

# dv-coop: networked 2-player co-op for ΔV: Rings of Saturn.
# Entry point found by the game's ModLoader (modmain*.gd inside the mod zip).
# ModLoader instantiates this with `packedScript.new(modLoader)` and then add_child()s it.

const MOD_PRIORITY = 0
const MOD_VERSION = "0.0.1-m0"
const Compat = preload("res://dv-coop/Compat.gd")   # the game build pin (Compat.BUILD)

# Order matters: asteroid.gd before AsteroidSpawner.gd, which preloads the asteroid scenes that use asteroid.gd.
# Missing files are skipped, so each module's extension can land on its own branch first.
const EXTENSIONS = [
	"res://dv-coop/ext/asteroid.gd",
	"res://dv-coop/ext/AsteroidSpawner.gd",
	"res://dv-coop/ext/ship-ctrl.gd",
	"res://dv-coop/ext/CurrentGame.gd",
]

var modLoader = null
var selfTest = false

func _init(loader = null):
	modLoader = loader
	# Only on the game build this mod was made for; otherwise install nothing and say why (Compat.gd, docs/UPDATING.md).
	if Compat.refuse(self): return
	Debug.l("COOP: modmain %s loading (game %s)" % [MOD_VERSION, Compat.BUILD])
	# Install script extensions here, in _init, before later autoloads (Shipyard etc.)
	# get a chance to load the original scripts.
	if modLoader and modLoader.has_method("installScriptExtension"):
		for ext in EXTENSIONS:
			if not ResourceLoader.exists(ext):
				continue
			modLoader.installScriptExtension(ext)
			Debug.l("COOP: installed extension %s" % ext)
	else:
		Debug.l("COOP: no ModLoader handle, extensions NOT installed")

func _ready():
	if has_meta("dvcoop_refused"): return
	name = "DvCoop"
	# The game pauses the whole tree on focus loss, the pause key and the Steam overlay. Our networking must keep
	# running through that, or one player alt-tabbing drops out of the cell after 1.5 s (children inherit this).
	pause_mode = Node.PAUSE_MODE_PROCESS
	if "--coop-selftest" in OS.get_cmdline_args():
		selfTest = true
	var net = load("res://dv-coop/net/CoopNet.gd").new()
	net.name = "CoopNet"
	add_child(net)
	Debug.l("COOP: modmain ready, CoopNet attached; args=%s" % [OS.get_cmdline_args()])
	if selfTest:
		call_deferred("_runSelfTest")

func _runSelfTest():
	# Wait for the rest of the autoloads (Shipyard) and the boot scene to settle.
	yield(get_tree().create_timer(4.0), "timeout")
	var build = CurrentGame.get("version")
	Debug.l("COOP-SELFTEST: game version %s, VersionLabel.tscn %s (expected %s)" % [build, Compat.gameBuild(), Compat.BUILD])
	var ship = Shipyard.createShipByName("MADCERF", "helper")
	if ship == null:
		Debug.l("COOP-SELFTEST: FAIL, createShipByName returned null")
		return
	var script = ship.get_script()
	var path = script.resource_path if script else "?"
	var hasExt = ("coopExtensionActive" in ship)
	Debug.l("COOP-SELFTEST: ship script=%s extensionActive=%s" % [path, hasExt])
	Debug.l("COOP-SELFTEST: %s" % ("PASS" if hasExt else "FAIL"))
	ship.free()
