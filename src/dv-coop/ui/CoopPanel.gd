extends PanelContainer

# dv-coop (M5): the co-op panel. Host, invite, leave, join a friend, and answer a join request (a Steam invite, or
# a friend's "Join game"). One script for both places it lives: the title screen (ext/TitleMenu.gd puts it in the
# stock NoMargins/Popups CenterContainer) and the pause menu in flight and at Enceladus (ext/PauseLayer.gd puts it
# in PauseContainer/NoMargins/CenterContainer). Both containers are the game's own and centre it.
#
# Resolution: Containers only, no pixel positions; the game's menu theme, so it scales with the UI-scale setting
# like the menus around it. The font is the menu font with the HUD's Noto faces as fallbacks, since Steam names can
# be in any script.
#
# At the title a join also needs a save: the player picks a slot that holds one, and Join loads it with the stock
# Continue (Enceladus, in the lobby). With no save Join stays disabled.

var net = null
var atTitle = false
var titleMenu = null       # title: the stock TitleMenu, for its save slots and Continue
var body = null
var buttons = {}           # name -> Button, for the dev driver (net/Travel.gd)
var slotPick = null
var slots = []             # [[file, label]]
var memberLabels = []
var shown = ""             # what the panel shows now; rebuilt only when it changes, so focus survives
var refreshAccum = 0.0

const FALLBACKS = ["res://hud/NotoMono-Regular.ttf", "res://hud/NotoSansMonoCJKsc-Regular.otf", "res://hud/NotoSansJP-Regular.ttf", "res://hud/NotoSerifThai-Regular.ttf"]

func _ready():
	name = "CoopPanel"
	pause_mode = Node.PAUSE_MODE_PROCESS
	mouse_filter = Control.MOUSE_FILTER_STOP
	var th = load("res://menu/MenuTheme.tres")
	if th != null:
		th = th.duplicate()
		for type in ["Label", "Button", "OptionButton", "PopupMenu"]:
			var f = th.get_font("font", type)
			if f is DynamicFont:
				th.set_font("font", type, _withFallbacks(f))
		if th.default_font is DynamicFont:
			th.default_font = _withFallbacks(th.default_font)
		theme = th
	var margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_constant_override("margin_" + side, 16)
	add_child(margin)
	body = VBoxContainer.new()
	body.add_constant_override("separation", 8)
	margin.add_child(body)
	visible = false
	if ModLoader.has_meta("dvcoop"):
		net = ModLoader.get_meta("dvcoop")
		net.connect("session_changed", self, "_refresh")

func _withFallbacks(f: DynamicFont) -> DynamicFont:
	var c = f.duplicate()
	for path in FALLBACKS:
		var data = load(path)
		if data != null:
			c.add_fallback(data)
	return c

func open():
	visible = true
	shown = ""
	_refresh()
	Debug.l("COOP: UI co-op panel opened (%s)" % ("title" if atTitle else "pause"))

func close():
	if not visible:
		return
	visible = false
	if net != null and typeof(net.pendingJoin) != TYPE_NIL:
		net.answerJoin(false)
	Debug.l("COOP: UI co-op panel closed")

func _process(delta):
	if not visible:
		return
	refreshAccum += delta
	if refreshAccum >= 0.5:
		refreshAccum = 0.0
		_refresh()

# ---------------------------------------------------------------- content

func _friends() -> Array:
	# [{name, lobby, where}]: friends in a co-op lobby we could join
	var out = []
	if net == null:
		return out
	if net.devEnet != "":
		if not net.sameLobby(net.wantLobby, net.devEnet):
			out.append({"name": "Dev relay", "lobby": net.devEnet, "where": net.devEnet})
		return out
	if not net.steamReady:
		return out
	var flags = 4   # k_EFriendFlagImmediate
	var app = Steam.getAppID()
	for i in range(Steam.getFriendCount(flags)):
		var fid = Steam.getFriendByIndex(i, flags)
		var gp = Steam.getFriendGamePlayed(fid)
		if not (gp is Dictionary) or int(gp.get("id", 0)) != app:
			continue
		var lobby = int(gp.get("lobby", 0))
		if lobby == 0 or net.sameLobby(lobby, net.wantLobby):
			continue
		out.append({"name": Steam.getFriendPersonaName(fid), "lobby": lobby, "where": "in a co-op lobby"})
	return out

func _members() -> Array:
	var out = []
	if net == null:
		return out
	for id in net.peers:
		var pr = net.peers[id]
		var where = "connecting"
		var b = pr.beacon
		var zone = b.get("zone") if b != null else ""
		if b != null:
			match zone:
				"rings":
					where = "in the rings"
					if b.has("p") and net.dived and net.localShip != null and is_instance_valid(net.localShip):
						var km = CurrentGame.globalCoords(net.localShip.global_position).distance_to(b.p) / 10000.0
						where = "in the rings, %s km" % _km(km)
				"station":
					where = "at Enceladus"
				"title":
					where = "on the title screen"
		out.append({"name": pr.name, "where": where, "zone": zone})
	return out

func _km(km: float) -> String:
	return "%.1f" % km if km < 10 else "%d" % int(km)

func _status() -> String:
	if net == null:
		return "Co-op is not running"
	match net.state:
		"hosting":
			return "Creating a lobby..."
		"joining":
			return "Joining..."
		"in lobby":
			return "In a lobby, %d player(s)" % (net.peers.size() + 1)
		"reconnecting":
			return "Connection lost, reconnecting..."
	return "Not in a lobby"

func _refresh():
	if not visible or body == null:
		return
	if atTitle:
		_readSlots()
	var friends = _friends()
	var members = _members()
	var pending = net.pendingJoin if net != null else null
	var mkey = []
	for m in members:
		mkey.append([m.name, m.zone])
	var key = str([net.state if net != null else "", friends, mkey, pending, slots, net.incompatible if net != null else {}])
	if key == shown:
		# same layout: only the ranges moved
		for i in range(min(members.size(), memberLabels.size())):
			memberLabels[i].text = "  %s, %s" % [members[i].name, members[i].where]
		return
	shown = key
	var keepSlot = slotPick.selected if slotPick != null else -1
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	buttons = {}
	slotPick = null
	memberLabels = []

	_label("Co-op", true)
	_label(_status())

	if atTitle:
		var row = HBoxContainer.new()
		body.add_child(row)
		var l = Label.new()
		l.text = "Save to play:"
		row.add_child(l)
		if slots.empty():
			var none = Label.new()
			none.text = "none yet - start a game first"
			row.add_child(none)
		else:
			slotPick = OptionButton.new()
			slotPick.size_flags_horizontal = SIZE_EXPAND_FILL
			for s in slots:
				slotPick.add_item(s[1])
			slotPick.select(int(clamp(keepSlot if keepSlot >= 0 else _defaultSlot(), 0, slots.size() - 1)))
			row.add_child(slotPick)

	if typeof(pending) != TYPE_NIL:
		_label("%s invites you to their game." % pending.from)
		if not atTitle:
			_label("You keep your ship and your dive; you leave your current lobby.")
		var row = HBoxContainer.new()
		body.add_child(row)
		var yes = _button(row, "yes", "Join", "_onAnswer", [true])
		yes.disabled = atTitle and slotPick == null
		_button(row, "no", "Not now", "_onAnswer", [false])
	else:
		var row = HBoxContainer.new()
		body.add_child(row)
		if net != null and (net.state == "idle"):
			_button(row, "host", "Host a game", "_onHost", [])
		else:
			var inv = _button(row, "invite", "Invite friends", "_onInvite", [])
			inv.disabled = net == null or not net.inLobby() or net.devEnet != ""
			_button(row, "leave", "Leave", "_onLeave", [])

	if net != null:
		for why in net.incompatible.values():
			_label("  %s" % why)
	if not members.empty():
		_label("In your lobby:")
		for m in members:
			memberLabels.append(_label("  %s, %s" % [m.name, m.where]))

	if typeof(pending) == TYPE_NIL:
		_label("Friends playing co-op:" if not friends.empty() else "No friends in a co-op lobby right now.")
		var i = 0
		for f in friends:
			var row = HBoxContainer.new()
			body.add_child(row)
			var l = Label.new()
			l.text = "%s, %s" % [f.name, f.where]
			l.size_flags_horizontal = SIZE_EXPAND_FILL
			row.add_child(l)
			var b = _button(row, "join%d" % i, "Join", "_onJoinFriend", [f.lobby, f.name])
			b.disabled = atTitle and slotPick == null
			i += 1

	var bottom = HBoxContainer.new()
	bottom.alignment = BoxContainer.ALIGN_END
	body.add_child(bottom)
	_button(bottom, "close", "Close", "close", [])
	var first = buttons.get("yes", buttons.get("host", buttons.get("invite", buttons.get("close"))))
	if first != null and not first.disabled:
		first.call_deferred("grab_focus")

func _label(text, big = false):
	var l = Label.new()
	l.text = text
	l.autowrap = false
	if big:
		l.align = Label.ALIGN_CENTER
	body.add_child(l)
	return l

func _button(row, key, text, method, args):
	var b = Button.new()
	b.text = text
	b.connect("pressed", self, method, args)
	row.add_child(b)
	buttons[key] = b
	return b

# ---------------------------------------------------------------- title: save slots

func _readSlots():
	slots = []
	if titleMenu == null:
		return
	var saves = titleMenu.get_node_or_null("MarginContainer/VBoxContainer/HBoxContainer/Saves")
	if saves == null:
		return
	for btn in saves.get_children():
		if "saveSlotFile" in btn and btn.visible and btn.get("meta") != null:
			slots.append([btn.saveSlotFile, btn.text])

func _defaultSlot() -> int:
	for i in range(slots.size()):
		if slots[i][0] == CurrentGame.saveFile:
			return i
	return 0

func selectSlot(file: String) -> bool:
	_readSlots()
	shown = ""
	_refresh()
	for i in range(slots.size()):
		if slots[i][0] == file or slots[i][0].ends_with("/" + file):
			slotPick.select(i)
			return true
	return false

func _continueOnSlot() -> bool:
	if slotPick == null or slots.empty():
		return false
	var file = slots[slotPick.selected][0]
	Debug.l("COOP: UI joining with save %s" % file)
	CurrentGame.saveFile = file
	visible = false
	titleMenu._on_Continue_pressed()
	return true

# ---------------------------------------------------------------- actions

func _onHost():
	Debug.l("COOP: UI host pressed")
	net.host()

func _onInvite():
	Debug.l("COOP: UI invite pressed")
	if net.lobbyId != 0:
		Steam.activateGameOverlayInviteDialog(net.lobbyId)

func _onLeave():
	Debug.l("COOP: UI leave pressed")
	net.leave()

func _onJoinFriend(lobby, who):
	Debug.l("COOP: UI join pressed for %s (lobby %s)" % [who, lobby])
	if atTitle and slotPick == null:
		return
	net.join(lobby)
	if atTitle:
		_continueOnSlot()

func _onAnswer(yes):
	if yes and atTitle and slotPick == null:
		return
	net.answerJoin(yes)
	if yes and atTitle:
		_continueOnSlot()
