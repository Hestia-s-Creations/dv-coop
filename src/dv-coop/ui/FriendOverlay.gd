extends CanvasLayer

# Friend markers: for every peer in the ring, a chevron at the screen edge pointing
# toward them (or over them when on screen) with name and distance. Peers at the
# station or on the title screen are listed in the corner. Data comes from CoopNet
# beacons, so this works at any distance, independent of LIDAR range.

var net = null
var ctl = null

const MARGIN = 48.0
const CHEVRON = 12.0
const COLOR_FRIEND = Color(0.35, 0.9, 1.0, 0.9)
const COLOR_NEAR = Color(0.5, 1.0, 0.5, 0.9)
const COLOR_DIM = Color(0.7, 0.7, 0.7, 0.7)

func _ready():
	layer = 60
	ctl = Control.new()
	ctl.name = "FriendOverlayDraw"
	ctl.anchor_right = 1
	ctl.anchor_bottom = 1
	ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ctl)
	ctl.connect("draw", self, "_onDraw")

func _process(delta):
	if ctl != null:
		ctl.update()

func _onDraw():
	if net == null or not is_instance_valid(net):
		return
	var font = ctl.get_font("font")
	var ship = net.localShip
	var haveShip = net.dived and ship != null and is_instance_valid(ship) and ship.is_inside_tree()
	var size = ctl.get_viewport_rect().size
	var center = size / 2
	var y = 40.0
	var now = OS.get_ticks_msec() / 1000.0
	placed = []
	for id in net.peers.keys():
		var pr = net.peers[id]
		var b = pr.beacon
		if b == null or now - pr.beaconAt > net.BEACON_TIMEOUT:
			ctl.draw_string(font, Vector2(16, y), "%s: no signal" % pr.name, COLOR_DIM)
			y += 18
			continue
		if b.get("zone") != "rings" or not b.has("p") or not haveShip:
			var where = "at Enceladus" if b.get("zone") == "station" else "in menu"
			ctl.draw_string(font, Vector2(16, y), "%s: %s" % [pr.name, where], COLOR_DIM)
			y += 18
			continue
		var myGlobal = CurrentGame.globalCoords(ship.global_position)
		var delta = b.p - myGlobal
		var dist = delta.length()
		var localPos = CurrentGame.localCoords(b.p)
		var screen = ship.get_viewport().get_canvas_transform().xform(localPos)
		var onScreen = screen.x > MARGIN and screen.x < size.x - MARGIN and screen.y > MARGIN and screen.y < size.y - MARGIN
		var col = COLOR_NEAR if pr.inRange else COLOR_FRIEND
		var label = "%s  %s" % [pr.name, _fmtDist(dist)]
		if onScreen:
			ctl.draw_arc(screen, 22, 0, TAU, 24, col, 1.5)
			ctl.draw_string(font, screen + Vector2(26, 4), label, col)
		else:
			var dir = (screen - center)
			if dir.length() < 1:
				dir = Vector2(0, - 1)
			dir = dir.normalized()
			var half = center - Vector2(MARGIN, MARGIN)
			var tx = half.x / max(abs(dir.x), 0.0001)
			var ty = half.y / max(abs(dir.y), 0.0001)
			var edge = center + dir * min(tx, ty)
			var tip = edge
			var base = edge - dir * CHEVRON
			var perp = Vector2(- dir.y, dir.x) * CHEVRON * 0.6
			ctl.draw_colored_polygon(PoolVector2Array([tip, base + perp, base - perp]), col)
			var lp = base - dir * 6
			var w = font.get_string_size(label).x
			var textPos = lp + Vector2(- w / 2, 5)
			textPos.x = clamp(textPos.x, 8, size.x - w - 8)
			textPos.y = clamp(textPos.y, 20, size.y - 8)
			# stack labels that land on each other (friends in the same direction)
			var rect = Rect2(textPos + Vector2(0, - 14), Vector2(w, 18))
			var tries = 0
			while _collides(rect) and tries < 8:
				var push = Vector2(0, 18) if textPos.y < size.y / 2 else Vector2(0, - 18)
				textPos += push
				rect.position += push
				tries += 1
			placed.append(rect)
			ctl.draw_string(font, textPos, label, col)

var placed = []

func _collides(r: Rect2) -> bool:
	for p in placed:
		if p.intersects(r):
			return true
	return false

func _fmtDist(px: float) -> String:
	if px < 1000:
		return "%d m" % int(px)
	if px < 100000:
		return "%.1f km" % (px / 1000.0)
	return "%d km" % int(px / 1000.0)
