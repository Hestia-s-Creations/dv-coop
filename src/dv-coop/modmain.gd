extends Node

# dv-coop: networked 2-player co-op for ΔV: Rings of Saturn.
# Entry point found by the game's ModLoader (modmain*.gd inside the mod zip).
# ModLoader instantiates this with `packedScript.new(modLoader)` and then add_child()s it.

const MOD_PRIORITY = 0
const MOD_VERSION = "0.0.1-m0"
const GAME_BUILD_EXPECTED = "1.90.12"

const EXTENSIONS = [
	"res://dv-coop/ext/ship-ctrl.gd",
]

var modLoader = null
var selfTest = false

func _init(loader = null):
	modLoader = loader
	Debug.l("COOP: modmain %s loading (expects game %s)" % [MOD_VERSION, GAME_BUILD_EXPECTED])
	# Install script extensions here, in _init, before later autoloads (Shipyard etc.)
	# get a chance to load the original scripts.
	if modLoader and modLoader.has_method("installScriptExtension"):
		for ext in EXTENSIONS:
			modLoader.installScriptExtension(ext)
			Debug.l("COOP: installed extension %s" % ext)
	else:
		Debug.l("COOP: no ModLoader handle, extensions NOT installed")

func _ready():
	name = "DvCoop"
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
	Debug.l("COOP-SELFTEST: game version %s (expected %s)" % [build, GAME_BUILD_EXPECTED])
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
