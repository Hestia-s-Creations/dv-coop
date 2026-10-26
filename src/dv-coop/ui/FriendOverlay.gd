extends CanvasLayer

# Friend markers: for every peer in the ring, a chevron at the screen edge pointing
# toward them (or over them when on screen) with name and distance. Peers at the
# station or on the title screen are listed at the top. Data comes from CoopNet
# beacons, so this works at any distance, independent of LIDAR range.
#
# Resolution: everything is drawn in canvas units, the same units the game's HUD uses
# (Settings scales the canvas to the window by its UI-scale setting), so sizes follow the
# HUD at every resolution and UI scale. The font is the HUD's own face with an outline.
# Markers and labels steer clear of the HUD's panels, whichever ship display is fitted.
#
# Dev: --coop-dev-zoomout holds the camera at its zoom-out limit (resolution checks at max view).
#      --coop-dev-jitter logs how far tracked rocks stray from a straight line over 1 s, in screen pixels,
#      split at RockSync's 10 Hz / 2 Hz tier boundary (6,000 px).
#      --coop-dev-view logs the area the view covers and where the friend markers went, every 5 s.

var net = null
var ctl = null
var font = null

const MARGIN = 24.0
const CHEVRON = 12.0
const RING = 22.0
const FONT_SIZE = 13
const COLOR_FRIEND = Color(0.35, 0.9, 1.0, 0.95)
const COLOR_NEAR = Color(0.5, 1.0, 0.5, 0.95)
const COLOR_DIM = Color(0.75, 0.75, 0.75, 0.85)
const HUD_EVERY = 0.5

var hudRects = []      # visible HUD panels, canvas units
var hudAccum = HUD_EVERY
var placed = []
var devZoomOut = false
var devJitter = false
var devView = false
var jit = {}           # rock node id -> [Vector2 ...] last JIT_N physics positions
const JIT_N = 60
const JIT_NEAR = 6000.0

func _ready():
	layer = 60
	ctl = Control.new()
	ctl.name = "FriendOverlayDraw"
	ctl.anchor_right = 1
	ctl.anchor_bottom = 1
	ctl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(ctl)
	ctl.connect("draw", self, "_onDraw")
	# coop:dev{
	devZoomOut = "--coop-dev-zoomout" in OS.get_cmdline_args()
	devJitter = "--coop-dev-jitter" in OS.get_cmdline_args()
	devView = "--coop-dev-view" in OS.get_cmdline_args()
	# coop:dev}
	set_physics_process(devJitter)
	font = DynamicFont.new()
	font.font_data = load("res://hud/NotoMono-Regular.ttf")
	font.size = FONT_SIZE
	font.outline_size = 1
	font.outline_color = Color(0, 0, 0, 0.9)
	font.use_filter = true
	# Steam names can be in any script
	for path in ["res://hud/NotoSansMonoCJKsc-Regular.otf", "res://hud/NotoSansJP-Regular.ttf", "res://hud/NotoSerifThai-Regular.ttf"]:
		var data = load(path)
		if data != null:
			font.add_fallback(data)

var diagAccum = 0.0

func _process(delta):
	if devZoomOut:
		var cam = CurrentGame.getCurrentCamera()
		if cam != null:
			cam.zoomAdjust = cam.maxZoomAdjust
	hudAccum += delta
	if hudAccum >= HUD_EVERY:
		hudAccum = 0.0
		_scanHud()
	if ctl != null:
		ctl.update()
	# coop:dev{
	diagAccum += delta
	if diagAccum >= 5.0:
		diagAccum = 0.0
		if devView:
			_logView()
		if devJitter:
			_logJitter()
	# coop:dev}

func _physics_process(delta):
	var rs = net.get_node_or_null("RockSync") if net != null else null
	if rs == null or not ("tracked" in rs):
		return
	var seen = {}
	for id in rs.tracked:
		var n = rs.tracked[id].n
		if n == null or not is_instance_valid(n):
			continue
		var k = n.get_instance_id()
		seen[k] = true
		if not jit.has(k):
			jit[k] = []
		jit[k].append(n.global_position)
		if jit[k].size() > JIT_N:
			jit[k].pop_front()
	for k in jit.keys():
		if not seen.has(k):
			jit.erase(k)

# Largest distance of the last second's positions from their least-squares line, converted to screen pixels.
func _logJitter():
	var ship = net.localShip
	var cam = CurrentGame.getCurrentCamera()
	if ship == null or not is_instance_valid(ship) or cam == null or ctl == null:
		return
	var pxPerWorld = (OS.window_size.x / ctl.get_viewport_rect().size.x) / cam.zoom.x
	var near = []
	var far = []
	for k in jit:
		var pts = jit[k]
		if pts.size() < JIT_N:
			continue
		var n = float(pts.size())
		var mt = (n - 1) / 2.0
		var mp = Vector2(0, 0)
		for p in pts:
			mp += p
		mp /= n
		var stt = 0.0
		var stp = Vector2(0, 0)
		for i in range(pts.size()):
			stt += (i - mt) * (i - mt)
			stp += (pts[i] - mp) * (i - mt)
		var slope = stp / stt
		var worst = 0.0
		for i in range(pts.size()):
			worst = max(worst, pts[i].distance_to(mp + slope * (i - mt)))
		var d = pts[-1].distance_to(ship.global_position)
		(near if d < JIT_NEAR else far).append(worst * pxPerWorld)
	near.sort()
	far.sort()
	Debug.l("COOP: OVERLAY jitter (screen px, 1 s line fit) near<6km n=%d p50=%.2f p95=%.2f max=%.2f | far n=%d p50=%.2f p95=%.2f max=%.2f" % [near.size(), _pct(near, 0.5), _pct(near, 0.95), _pct(near, 1.0), far.size(), _pct(far, 0.5), _pct(far, 0.95), _pct(far, 1.0)])

func _pct(a, q):
	if a.size() == 0:
		return -1.0
	return a[min(a.size() - 1, int(q * (a.size() - 1)))]

# Screen vs world, for the resolution checks: window, canvas (the game's UI-scaled size), camera zoom,
# the visible world rect, and how far its farthest corner is from my ship (RockSync streams 30,000 px; 10 Hz to 6,000).
func _logView():
	var ship = net.localShip if net != null else null
	if ctl == null or ship == null or not is_instance_valid(ship) or not ship.is_inside_tree():
		return
	var size = ctl.get_viewport_rect().size
	var inv = ship.get_viewport().get_canvas_transform().affine_inverse()
	var far = 0.0
	for c in [Vector2(0, 0), Vector2(size.x, 0), Vector2(0, size.y), size]:
		far = max(far, inv.xform(c).distance_to(ship.global_position))
	var view = inv.basis_xform(size).abs()
	var cam = CurrentGame.getCurrentCamera()
	var zoom = cam.zoom.x if cam != null else -1.0
	Debug.l("COOP: OVERLAY window=%s canvas=%s ui=%s pd=%s zoom=%.2f view=%dx%d far=%d px hud=%d" % [OS.window_size, size, Settings.cfg.ui.scale, Settings.cfg.display.pixelDoubling, zoom, view.x, view.y, far, hudRects.size()])

# The ship displays build their panels from PanelContainers on CanvasLayers; collect the visible ones.
func _scanHud():
	hudRects = []
	if ctl == null:
		return
	var screen = ctl.get_viewport_rect()
	var stack = [get_tree().get_root()]
	while stack.size() > 0:
		var n = stack.pop_back()
		if n == self:
			continue
		if n.name == "AsteroidField":
			# thousands of rocks; the HUD hangs off my own ship
			if net != null and net.localShip != null and is_instance_valid(net.localShip):
				stack.append(net.localShip)
			continue
		if n is CanvasItem and not n.visible:
			continue
		if (n is PanelContainer or n is Panel) and n.is_visible_in_tree():
			var r = n.get_global_rect()
			var cl = _layerOf(n)
			if cl != null:
				r = cl.transform.xform(r)
			if r.size.x > 4 and r.size.y > 4 and r.get_area() < screen.get_area() * 0.5:
				hudRects.append(r.grow(4))
			continue
		for c in n.get_children():
			stack.append(c)

func _layerOf(n):
	var p = n.get_parent()
	while p != null:
		if p is CanvasLayer:
			return p
		p = p.get_parent()
	return null

func _hitsHud(r: Rect2) -> bool:
	for h in hudRects:
		if h.intersects(r):
			return true
	return false

func _collides(r: Rect2) -> bool:
	for p in placed:
		if p.intersects(r):
			return true
	return false

func _onDraw():
	if net == null or not is_instance_valid(net) or font == null:
		return
	var ship = net.localShip
	var haveShip = net.dived and ship != null and is_instance_valid(ship) and ship.is_inside_tree()
	var size = ctl.get_viewport_rect().size
	var center = size / 2
	var lh = font.get_height() + 2
	var asc = font.get_ascent()
	var now = OS.get_ticks_msec() / 1000.0
	placed = []
	var listed = []
	for id in net.peers.keys():
		var pr = net.peers[id]
		var b = pr.beacon
		if b == null or now - pr.beaconAt > net.BEACON_TIMEOUT:
			listed.append(["%s: no signal" % pr.name, COLOR_DIM])
			continue
		if b.get("zone") != "rings" or not b.has("p") or not haveShip:
			var where = {"station": "at Enceladus", "rings": "in the rings"}.get(b.get("zone"), "in menu")
			listed.append(["%s: %s" % [pr.name, where], COLOR_DIM])
			continue
		var myGlobal = CurrentGame.globalCoords(ship.global_position)
		var dist = (b.p - myGlobal).length()
		var screen = ship.get_viewport().get_canvas_transform().xform(CurrentGame.localCoords(b.p))
		var col = COLOR_NEAR if pr.inRange else COLOR_FRIEND
		var label = "%s  %s" % [pr.name, _fmtDist(dist)]
		var w = font.get_string_size(label).x
		var onScreen = Rect2(Vector2(MARGIN, MARGIN), size - Vector2(MARGIN, MARGIN) * 2).has_point(screen)
		# behind a HUD panel counts as off screen: a chevron just outside the panel points at them
		var behindHud = onScreen and _hitsHud(Rect2(screen, Vector2(0, 0)).grow(RING))
		if onScreen and not behindHud:
			ctl.draw_arc(screen, RING, 0, TAU, 24, col, 1.5)
			# label right of the ring, or left if that runs into the HUD or off screen
			var textPos = screen + Vector2(RING + 4, asc / 2)
			var rect = Rect2(textPos - Vector2(0, asc), Vector2(w, lh))
			if _hitsHud(rect) or rect.end.x > size.x:
				textPos = screen + Vector2(- RING - 4 - w, asc / 2)
				rect.position = textPos - Vector2(0, asc)
			placed.append(rect)
			ctl.draw_string(font, textPos, label, col)
			continue
		var dir = screen - center
		if dir.length() < 1:
			dir = Vector2(0, - 1)
		dir = dir.normalized()
		# edge of the screen along the bearing, then step inward until chevron and label clear the HUD
		var half = center - Vector2(MARGIN, MARGIN)
		var reach = min(half.x / max(abs(dir.x), 0.0001), half.y / max(abs(dir.y), 0.0001))
		if behindHud:
			reach = min(reach, (screen - center).length())
		var tip
		var textPos
		var rect
		var step = 0
		while true:
			tip = center + dir * reach
			var base = tip - dir * CHEVRON
			var lp = base - dir * (lh * 0.6)
			textPos = Vector2(clamp(lp.x - w / 2, MARGIN, size.x - MARGIN - w), clamp(lp.y + asc / 2, MARGIN + asc, size.y - MARGIN))
			rect = Rect2(textPos - Vector2(0, asc), Vector2(w, lh))
			var chev = Rect2(tip, Vector2(0, 0)).expand(base).grow(CHEVRON * 0.6)
			if (not _hitsHud(rect) and not _hitsHud(chev)) or reach < min(half.x, half.y) * 0.35 or step > 60:
				break
			reach -= lh * 0.5
			step += 1
		# stack labels that land on each other (friends in the same direction)
		var tries = 0
		while _collides(rect) and tries < 8:
			var push = Vector2(0, lh) if textPos.y < center.y else Vector2(0, - lh)
			textPos += push
			rect.position += push
			tries += 1
		placed.append(rect)
		var baseP = tip - dir * CHEVRON
		var perp = Vector2(- dir.y, dir.x) * CHEVRON * 0.6
		ctl.draw_colored_polygon(PoolVector2Array([tip, baseP + perp, baseP - perp]), col)
		ctl.draw_polyline(PoolVector2Array([tip, baseP + perp, baseP - perp, tip]), Color(0, 0, 0, 0.8), 1.0)
		ctl.draw_string(font, textPos, label, col)

	# friends not in the ring: a short list in the first free spot near the top centre
	if listed.size() > 0:
		var w = 0.0
		for e in listed:
			w = max(w, font.get_string_size(e[0]).x)
		var box = Rect2(Vector2(center.x - w / 2, MARGIN), Vector2(w, lh * listed.size()))
		var tries = 0
		while (_hitsHud(box) or _collides(box)) and tries < 40:
			box.position.y += lh
			tries += 1
		var y = box.position.y + asc
		for e in listed:
			ctl.draw_string(font, Vector2(box.position.x, y), e[0], e[1])
			y += lh

func _fmtDist(px: float) -> String:
	if px < 1000:
		return "%d m" % int(px)
	if px < 100000:
		return "%.1f km" % (px / 1000.0)
	return "%d km" % int(px / 1000.0)
