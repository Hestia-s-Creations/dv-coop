extends CanvasLayer

# Compat: the mod only runs on the game build it was made for (M6).
#
# Every hook in ext/ and every seam the net code reads was checked against one build. On another build a hooked
# function may have moved or changed meaning, so the mod refuses to start: no script extensions, no CoopNet. It
# says why in the log and on the title screen, and the game itself runs as normal.
#
# Where the game keeps its version: the text of res://VersionLabel.tscn ("1.90.12"). VersionLabel.gd copies it into
# CurrentGame.version, but only once a label enters the tree, which happens after the ModLoader has run our _init.
# Mods load inside the ModLoader autoload's _init, before CurrentGame exists, so we read the scene's stored text
# instead of instancing anything. A demo build (OS feature "demo_build") is refused too.
#
# Hook (modmain.gd): first line of _init after storing the loader, and first line of _ready:
#   if load("res://dv-coop/Compat.gd").refuse(self): return
#   if has_meta("dvcoop_refused"): return
#
# Dev (blanked in release zips): --coop-dev-compat-test pretends the build is wrong, to see the refusal;
#      --coop-any-build runs on any build anyway (re-running the gates on a new game build before bumping BUILD).
#
# Bumping the pin after a game update: docs/UPDATING.md.

const BUILD = "1.90.12"
const VERSION_SCENE = "res://VersionLabel.tscn"
const NOTICE_FONT = "res://hud/NotoMono-Regular.ttf"

var message = ""

# The game build as the game states it, or "" if it can't be found.
static func gameBuild() -> String:
	if not ResourceLoader.exists(VERSION_SCENE):
		return ""
	var ps = load(VERSION_SCENE)
	if not (ps is PackedScene):
		return ""
	var st = ps.get_state()
	if st.get_node_count() == 0:
		return ""
	for i in range(st.get_node_property_count(0)):
		if st.get_node_property_name(0, i) == "text":
			return str(st.get_node_property_value(0, i)).strip_edges()
	return ""

# Why the mod must not run here, or "" if it may.
static func problem() -> String:
	if OS.has_feature("demo_build"):
		return "this is the demo; dv-coop needs the full game, build %s" % BUILD
	var found = gameBuild()
	# coop:dev{
	if "--coop-dev-compat-test" in OS.get_cmdline_args():
		found = "0.0.0-compat-test"   # M6 gate: walk the refusal path on the real build
	# coop:dev}
	if found == BUILD:
		return ""
	# coop:dev{
	if "--coop-any-build" in OS.get_cmdline_args():
		Debug.l("COOP: game build %s, made for %s: running anyway (--coop-any-build, dev only)" % [found, BUILD])
		return ""
	# coop:dev}
	if found == "":
		return "can't tell which game build this is; dv-coop was made for %s" % BUILD
	return "this is game build %s; dv-coop was made for %s" % [found, BUILD]

# Called from modmain._init. On a build we weren't made for: logs, marks the mod refused, attaches the title-screen
# notice, and returns true so modmain stops before installing anything.
static func refuse(mod) -> bool:
	var why = problem()
	if why == "":
		return false
	var msg = "dv-coop is switched off: %s. The game runs normally without it. Update dv-coop (or the game) so the two match." % why
	Debug.l("COOP: REFUSED, " + msg)
	mod.set_meta("dvcoop_refused", why)
	var notice = load("res://dv-coop/Compat.gd").new()
	notice.name = "CoopCompatNotice"
	notice.message = msg
	mod.add_child(notice)
	return true

# ---------------------------------------------------------------- the notice

var shown = false
var label = null

func _ready():
	layer = 100
	pause_mode = Node.PAUSE_MODE_PROCESS

func _process(_delta):
	var c = Loader.current
	var atTitle = c != null and is_instance_valid(c) and c.filename == "res://TitleScreen.tscn"
	if atTitle and not shown:
		shown = true
		_show()
	elif shown and not atTitle:
		queue_free()   # once is enough; the log keeps the reason

func _show():
	var font = DynamicFont.new()
	font.font_data = load(NOTICE_FONT)
	font.size = 14
	font.outline_size = 1
	font.outline_color = Color(0, 0, 0, 0.9)
	label = Label.new()
	label.text = message
	label.autowrap = true
	label.align = Label.ALIGN_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_font_override("font", font)
	label.add_color_override("font_color", Color(1.0, 0.75, 0.35))
	label.anchor_left = 0.15
	label.anchor_right = 0.85
	label.margin_top = 24
	add_child(label)
