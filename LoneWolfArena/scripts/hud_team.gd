class_name HudTeam
extends Control
## DUO / SQUAD on the match HUD (HUD.bind attaches it when arena.team_size > 1, node "HudTeam", over
## the HUD like HudNet: its buttons take their touches first). Reads the TeamArena API only
## (members, status_of, revive_candidate, start_revive, cancel_revive, revive_progress, spectated,
## spectate_next, my_team), so a stand-in arena drives it in the unit tests:
##  - the TEAMMATES PANEL near the minimap: a numbered badge in the team's blue (1..n in slot order,
##    the player too), the name and an HP bar; KNOCKED: a red cross and the bleed-out bar (green while
##    a teammate revives them); OUT: grey; LEFT: grey with LEFT. It takes the first free place of:
##    right of the minimap, right of / under HudNet's buttons, under the zone strip (never on a
##    button: panel_rect);
##  - ALLY TAGS: a blue numbered badge and the name over each teammate's head (Camera3D
##    unproject_position; hidden behind the camera or off screen: tag_point);
##  - KNOCKED-ALLY MARKERS: a red cross with the distance on a knocked teammate, pinned to the screen
##    edge toward them when they are off screen or behind (edge_point);
##  - REVIVE beside FIRE while arena.revive_candidate(player) is not null (a tap: arena.start_revive;
##    while reviving a ring shows the progress and a second tap stops it: arena.cancel_revive;
##    moving or firing stops it too, the arena's rule) and a REVIVING bar over the crosshair;
##  - the player's own KNOCKED overlay: BLEEDING OUT with the knock HP left, BEING REVIVED BY <NAME>
##    with the revive's progress;
##  - once out: SPECTATING <NAME> and NEXT (node-less button "next": arena.spectate_next()).
## Every touch target is at least UI.TOUCH_MIN (56 px) across.

const BLUE_TEXT := Color(0.55, 0.82, 1.0)
const ORANGE_TEXT := Color(1.0, 0.68, 0.45)
const KNOCK_RED := Color(0.95, 0.24, 0.2)
const OUT_GREY := Color(0.55, 0.56, 0.6)
const TAG_UP := 2.2               # m over a standing teammate's feet: the tag
const TAG_UP_KNOCKED := 0.9       # ... over a knocked one: the marker
const EDGE_MARGIN := 46.0         # px a pinned marker keeps from the screen edge

var hud: HUD
var arena: Node
var _touch := {}                  # touch index -> "revive" | "next"
var _pressed := {}                # id -> seconds of press highlight
var _time := 0.0


static func attach(h: HUD, a: Node) -> HudTeam:
	var t := HudTeam.new()
	t.name = "HudTeam"
	t.hud = h
	t.arena = a
	h.add_child(t)
	if h.panels != null:
		h.move_child(t, h.panels.get_index())     # under the weapon pick and the scoreboard
	return t


## Whether a HUD bound to `a` gets the team layer: a team arena with more than one player a team.
static func wanted(a: Object) -> bool:
	if a == null:
		return false
	var n: Variant = a.get("team_size")
	return (n is int or n is float) and int(n) > 1


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# ---------------------------------------------------------------- the arena's read API

func player() -> Fighter:
	if arena == null:
		return null
	var p: Variant = arena.get("player")
	return p as Fighter if p is Fighter else null


func my_team() -> int:
	var t: Variant = arena.get("my_team") if arena != null else null
	if t is int:
		return t
	var p := player()
	return p.team if p != null else 0


## The fighters of team `t` in slot order.
func members(t: int) -> Array:
	if arena == null or not arena.has_method("members"):
		return []
	var out: Variant = arena.call("members", t)
	return out if out is Array else []


func status(f: Fighter) -> String:
	if arena != null and arena.has_method("status_of"):
		return String(arena.call("status_of", f))
	return "out" if f == null or not f.alive else ("knocked" if f.knocked else "up")


## A teammate's number (1..team size, slot order; 0 for anyone else).
func badge(f: Fighter) -> int:
	var i := members(my_team()).find(f)
	return i + 1


## How far a revive of `f` has come (0..1), -1 when nobody revives them.
func revive_progress(f: Fighter) -> float:
	if arena == null or not arena.has_method("revive_progress"):
		return -1.0
	return float(arena.call("revive_progress", f))


## The panel's rows: {"n", "name", "me", "status" (up / knocked / out / left), "hp" (0..1), "bleed"
## (0..1 of the knock HP while knocked), "revive" (0..1 while revived, else -1)}.
func team_rows() -> Array:
	var rows := []
	var p := player()
	var i := 0
	for f: Fighter in members(my_team()):
		i += 1
		var st := status(f)
		rows.append({"n": i, "name": f.display_name, "me": f == p, "status": st,
			"hp": clampf(f.hp / Fighter.MAX_HP, 0.0, 1.0) if st == "up" else 0.0,
			"bleed": clampf(f.knock_hp / Fighter.KNOCK_HP, 0.0, 1.0) if st == "knocked" else 0.0,
			"revive": revive_progress(f) if st == "knocked" else -1.0})
	return rows


## The knocked teammate the REVIVE button would revive now (null: no button).
func revive_target() -> Fighter:
	var p := player()
	if p == null or not p.alive or p.knocked or hud == null or hud.match_over or arena == null or not arena.has_method("revive_candidate"):
		return null
	var t: Variant = arena.call("revive_candidate", p)
	return t as Fighter if t is Fighter else null


## The teammate the player is reviving now (null: none).
func reviving() -> Fighter:
	var p := player()
	if p == null or p.reviving == null or not is_instance_valid(p.reviving):
		return null
	return p.reviving


func revive_shown() -> bool:
	return revive_target() != null or reviving() != null


## Who is reviving `f` now (null: nobody).
func reviver_of(f: Fighter) -> Fighter:
	for m: Fighter in members(f.team if f != null else my_team()):
		if m != f and m.reviving == f:
			return m
	return null


## Whom the camera follows while the player is out: the arena's teammate, else the 1 vs 1's killer
## view (null: the player is not out, or nobody to follow yet).
func spectated() -> Fighter:
	var p := player()
	if p == null or p.alive:
		return null
	if arena != null and arena.has_method("spectated"):
		var s: Variant = arena.call("spectated")
		if s is Fighter:
			return s
	return p.spectating_now()


## Total HP of team `t`'s fighters still UP over the team's full HP (the score bar's team bars).
func team_hp(t: int) -> float:
	var list := members(t)
	if list.is_empty():
		return 0.0
	var sum := 0.0
	for f: Fighter in list:
		if status(f) == "up":
			sum += f.hp
	return clampf(sum / (Fighter.MAX_HP * list.size()), 0.0, 1.0)


# ---------------------------------------------------------------- geometry (static: unit tests)

## The screen point of `world` for a tag, or null when it is behind the camera or off the screen.
static func tag_point(cam: Camera3D, world: Vector3, vs: Vector2) -> Variant:
	if cam == null or not cam.is_inside_tree() or cam.is_position_behind(world):
		return null
	var p := cam.unproject_position(world)
	if not Rect2(Vector2.ZERO, vs).grow(-4.0).has_point(p):
		return null
	return p


## A marker's place: `p` (the projected point) while it is on screen and in front, else pinned to
## the screen edge (keeping `margin`) in its direction from the centre; a point behind the camera
## projects mirrored, so its direction is turned round. {"pos": Vector2, "edge": bool}.
static func edge_point(p: Vector2, behind: bool, vs: Vector2, margin: float) -> Dictionary:
	var inner := Rect2(Vector2(margin, margin), (vs - Vector2(margin, margin) * 2.0).max(Vector2.ONE))
	if not behind and inner.has_point(p):
		return {"pos": p, "edge": false}
	var c := vs * 0.5
	var d := p - c
	if behind:
		d = -d
		if d.y < 0.0 and absf(d.y) > absf(d.x):
			d.y = -d.y          # straight behind: at the bottom edge (turn round), not the top
	if d.length() < 0.001:
		d = Vector2(0, 1)
	var k := minf(inner.size.x * 0.5 / maxf(absf(d.x), 0.001), inner.size.y * 0.5 / maxf(absf(d.y), 0.001))
	return {"pos": c + d * k, "edge": true}


## The first of `cands` that touches none of `blocked`; else the one that covers the least.
static func free_spot(cands: Array[Rect2], blocked: Array[Rect2]) -> Rect2:
	var best := cands[0] if not cands.is_empty() else Rect2()
	var best_a := INF
	for r in cands:
		var a := 0.0
		for b in blocked:
			a += r.intersection(b).get_area()
		if a <= 0.0:
			return r
		if a < best_a:
			best_a = a
			best = r
	return best


# ---------------------------------------------------------------- places

func _u() -> float:
	return HudLayout.unit(size)


## Screen rects the team layer keeps clear of: every round button the HUD shows (at its touch
## size), the weapon panel, the minimap with its strip, the score bar, the stick's home and
## HudNet's buttons and ping chip.
func blocked_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if hud == null or hud.layout.is_empty():
		return out
	var vs := size
	for id: String in HudLayout.ORDER:
		var w: Dictionary = hud.layout[id]
		match HudLayout.kind(id):
			"button":
				if id != "settings" and not hud._button_visible(id):
					continue
				var c := HudLayout.center(w, vs)
				var r := HudLayout.touch_radius(w, vs) * (1.17 if id == "fire_r" else 1.0)
				out.append(Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0))
			"joy":
				var jc := HudLayout.center(w, vs)
				var jr := HudLayout.radius(w, vs)
				out.append(Rect2(jc - Vector2(jr, jr), Vector2(jr, jr) * 2.0))
			"square":
				var mr := HudLayout.minimap_rect(w, vs)
				mr.size.y += mr.size.x * HudLayout.STRIP_H + 2.0
				if bool(Game.settings.get("show_fps", false)):
					mr.size.y += 0.05 * _u()
				out.append(mr)
	var wp := HudLayout.weapon_main(hud.layout.weapons, vs)
	for r: Rect2 in HudLayout.weapon_slots(hud.layout.weapons, vs):
		wp = wp.merge(r)
	out.append(wp)
	out.append(hud.score_rect())
	var net := hud.get_node_or_null("HudNet") as HudNet
	if net != null:
		var cs := net.button_centers()
		for id: String in cs:
			var c: Vector2 = cs[id]
			out.append(Rect2(c - Vector2(HudNet.R, HudNet.R) * 1.15, Vector2(HudNet.R * 2.3, HudNet.R * 2.3 + 22.0)))
		var right := vs.x - HudLayout.inset.y
		out.append(Rect2(wp.end.x, 0.0, maxf(right - wp.end.x, 1.0), 96.0))
	return out


## Row height and width of the teammates panel.
func panel_size(rows: int) -> Vector2:
	var u := _u()
	return Vector2(0.24 * u, rows * 0.036 * u + 0.012 * u)


func panel_rect() -> Rect2:
	var vs := size
	var n := maxi(members(my_team()).size(), 1)
	var ps := panel_size(n)
	var mr := HudLayout.minimap_rect(hud.layout.minimap, vs)
	var strip_end := mr.end.y + mr.size.x * HudLayout.STRIP_H + 4.0
	if bool(Game.settings.get("show_fps", false)):
		strip_end += 0.05 * _u()
	var gap := 10.0
	var cands: Array[Rect2] = []
	var right_side := mr.position.x < vs.x * 0.5
	var x_beside := mr.end.x + gap if right_side else mr.position.x - gap - ps.x
	cands.append(Rect2(Vector2(x_beside, mr.position.y), ps))
	var net := hud.get_node_or_null("HudNet") as HudNet
	if net != null:
		var cs := net.button_centers()
		if not cs.is_empty():
			var lo := Vector2(INF, INF)
			var hi := Vector2(-INF, -INF)
			for id: String in cs:
				lo = lo.min(cs[id])
				hi = hi.max(cs[id])
			var nr := Rect2(lo - Vector2(HudNet.R, HudNet.R) * 1.15, hi - lo + Vector2(HudNet.R * 2.3, HudNet.R * 2.3 + 22.0))
			cands.append(Rect2(Vector2(nr.end.x + gap if right_side else nr.position.x - gap - ps.x, mr.position.y), ps))
			cands.append(Rect2(Vector2(x_beside, nr.end.y + 4.0), ps))
	cands.append(Rect2(Vector2(mr.position.x, strip_end), ps))
	return free_spot(cands, blocked_rects())


## The REVIVE button's centre: beside FIRE, on the first free spot round it (never on a button).
func revive_center() -> Vector2:
	var vs := size
	var w: Dictionary = hud.layout.fire_r
	var fc := HudLayout.center(w, vs)
	var fr := HudLayout.radius(w, vs) * 1.17
	var r := revive_radius()
	var blocked := blocked_rects()
	var cands: Array[Rect2] = []
	for extra: float in [0.0, 0.6, 1.4]:
		for deg: float in [-150.0, -165.0, -135.0, 180.0, -120.0, 165.0, -105.0, 150.0, -90.0]:
			var c := fc + Vector2.from_angle(deg_to_rad(deg)) * (fr + r * (1.25 + extra) + 6.0)
			if c.x < r or c.y < r or c.x > vs.x - r or c.y > vs.y - r:
				continue
			cands.append(Rect2(c - Vector2(r, r) * 1.15, Vector2(r, r) * 2.3 + Vector2(0, 0.03 * _u())))
	if cands.is_empty():
		return fc + Vector2(-fr - r * 1.3, -fr * 0.5)
	var spot := free_spot(cands, blocked)
	return spot.position + Vector2(r, r) * 1.15


func revive_radius() -> float:
	return maxf(0.05 * _u(), UI.TOUCH_MIN * 0.5 + 4.0)


## SPECTATING <NAME> (plate) and NEXT (button) side by side, centred under the crosshair on the first
## free height. [plate, next].
func spectate_rects() -> Array[Rect2]:
	var vs := size
	var u := _u()
	var who := spectated()
	var nm := who.display_name.to_upper() if who != null else "PLAYER"
	var pw := maxf(HudDraw.text_width(nm, int(0.03 * u), "bold"), HudDraw.text_width("SPECTATING", int(0.022 * u), "bold")) + 0.1 * u
	var h := maxf(0.085 * u, UI.TOUCH_MIN)
	var nw := maxf(0.16 * u, UI.TOUCH_MIN * 2.0)
	var gw := pw + 0.02 * u + nw
	var blocked := blocked_rects()
	var cands: Array[Rect2] = []
	for fy: float in [0.63, 0.58, 0.68, 0.53]:
		cands.append(Rect2(Vector2(vs.x * 0.5 - gw * 0.5, vs.y * fy - h * 0.5), Vector2(gw, h)))
	var g := free_spot(cands, blocked)
	return [Rect2(g.position, Vector2(pw, h)), Rect2(g.position + Vector2(pw + 0.02 * u, 0), Vector2(nw, h))]


func next_shown() -> bool:
	var s := spectated()
	return s != null and s.team == my_team() and not (hud != null and hud.match_over)


# ---------------------------------------------------------------- input

func _input(event: InputEvent) -> void:
	if hud == null or hud.editor_mode:
		return
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			if not is_visible_in_tree() or (hud.panels != null and hud.panels.visible):
				return              # (the weapon pick or the scoreboard over it takes the taps)
			var id := button_at(t.position)
			if id != "":
				_touch[t.index] = id
				press(id)
				get_viewport().set_input_as_handled()
		elif _touch.has(t.index):
			_touch.erase(t.index)
			get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag and _touch.has((event as InputEventScreenDrag).index):
		get_viewport().set_input_as_handled()


## "revive", "next" or "" under `pos`.
func button_at(pos: Vector2) -> String:
	if revive_shown() and pos.distance_to(revive_center()) <= revive_radius() * 1.15:
		return "revive"
	if next_shown() and spectate_rects()[1].grow(4.0).has_point(pos):
		return "next"
	return ""


func press(id: String) -> void:
	_pressed[id] = 0.16
	Audio.play("ui_click", -8.0)
	var p := player()
	match id:
		"revive":
			if reviving() != null:
				arena.call("cancel_revive", p)
			else:
				var target := revive_target()
				if target != null:
					hud.release_all()             # standing still: the stick lets go
					arena.call("start_revive", p, target)
		"next":
			if arena.has_method("spectate_next"):
				arena.call("spectate_next")


# ---------------------------------------------------------------- drawing

func _process(delta: float) -> void:
	_time += delta
	for k in _pressed.keys():
		_pressed[k] -= delta
		if _pressed[k] <= 0.0:
			_pressed.erase(k)
	queue_redraw()


func _draw() -> void:
	if hud == null or arena == null or hud.layout.is_empty() or hud.editor_mode or player() == null:
		return
	var vs := size
	var u := _u()
	if not hud.match_over:
		_draw_tags(u)
		_draw_markers(vs, u)
	_draw_panel(u)
	if hud.match_over:
		return
	_draw_knocked_self(vs, u)
	_draw_reviving(vs, u)
	if revive_shown():
		_draw_revive_button(u)
	_draw_spectating(u)


## Blue numbered badge (grey once out): `n` in a disk.
func _badge(c: Vector2, r: float, n: int, col: Color) -> void:
	HudDraw.disk(self, c, r + 1.5, Color(0, 0, 0, 0.55))
	HudDraw.disk(self, c, r, col)
	HudDraw.text(self, str(n), c + Vector2(0, r * 0.06), int(r * 1.35), Color.WHITE, 1, 0, "number")


## A red cross (knocked).
func _cross(c: Vector2, s: float, col: Color) -> void:
	var t := s * 0.34
	draw_rect(Rect2(c - Vector2(t * 0.5, s * 0.5), Vector2(t, s)), col)
	draw_rect(Rect2(c - Vector2(s * 0.5, t * 0.5), Vector2(s, t)), col)


func _draw_panel(u: float) -> void:
	var rows := team_rows()
	if rows.is_empty():
		return
	var pr := panel_rect()
	draw_rect(pr, Color(0, 0, 0, 0.36))
	var rh := 0.036 * u
	var y := pr.position.y + 0.006 * u
	var fs := int(0.02 * u)
	for row: Dictionary in rows:
		var st := String(row.status)
		var gone := st == "out" or st == "left"
		var cy := y + rh * 0.5
		var bc := Vector2(pr.position.x + 0.022 * u, cy)
		_badge(bc, 0.013 * u, int(row.n), OUT_GREY if gone else HudDraw.BLUE)
		var x := bc.x + 0.022 * u
		var room := pr.end.x - x - 0.01 * u
		var name_col := Color(OUT_GREY, 0.9) if gone else (HudDraw.YELLOW if bool(row.me) else Color.WHITE)
		var nm := String(row.name).to_upper()
		var tag := String({"knocked": "KNOCKED", "out": "OUT", "left": "LEFT"}.get(st, ""))
		var tag_w := HudDraw.text_width(tag, int(fs * 0.85), "bold") + 0.008 * u if tag != "" else 0.0
		var nfs := fs
		var nw := HudDraw.text_width(nm, nfs, "bold")
		if nw > room - tag_w:
			nfs = maxi(8, int(nfs * (room - tag_w) / maxf(nw, 1.0)))
		HudDraw.text(self, nm, Vector2(x, cy - rh * 0.14), nfs, name_col, 0, 2, "bold")
		if tag != "":
			HudDraw.text(self, tag, Vector2(pr.end.x - 0.008 * u, cy - rh * 0.14), int(fs * 0.85),
				KNOCK_RED if st == "knocked" else OUT_GREY, 2, 2, "bold")
		var bar := Rect2(x, cy + rh * 0.2, room, maxf(3.0, 0.0065 * u))
		draw_rect(bar, Color(0, 0, 0, 0.5))
		match st:
			"up":
				draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(row.hp), bar.size.y)),
					HudDraw.HP_WHITE if float(row.hp) > 0.3 else Color(1.0, 0.45, 0.4))
			"knocked":
				var rv := float(row.revive)
				if rv >= 0.0:
					draw_rect(Rect2(bar.position, Vector2(bar.size.x * rv, bar.size.y)), HudDraw.HEAL_GREEN)
				else:
					var pulse := 0.75 + 0.25 * sin(_time * 7.0)
					draw_rect(Rect2(bar.position, Vector2(bar.size.x * float(row.bleed), bar.size.y)), Color(KNOCK_RED, pulse))
				_cross(bc + Vector2(0.013, -0.013) * u, 0.012 * u, HudDraw.HEAL_GREEN if rv >= 0.0 else KNOCK_RED)
		y += rh


## Numbered blue tags over the teammates who stand (knocked ones get the marker instead).
func _draw_tags(u: float) -> void:
	var p := player()
	var cam: Camera3D = p.camera if p != null else null
	if cam == null:
		return
	var vs := size
	for f: Fighter in members(my_team()):
		if f == p or status(f) != "up":
			continue
		var at: Variant = tag_point(cam, f.global_position + Vector3.UP * TAG_UP, vs)
		if at == null:
			continue
		var c: Vector2 = at
		var dist := cam.global_position.distance_to(f.global_position)
		var k := clampf(1.25 - dist / 40.0, 0.7, 1.15)
		var r := 0.017 * u * k
		var tri := PackedVector2Array([c + Vector2(-r * 0.45, r * 0.8), c + Vector2(r * 0.45, r * 0.8), c + Vector2(0, r * 1.45)])
		draw_colored_polygon(tri, HudDraw.BLUE)
		_badge(c, r, badge(f), HudDraw.BLUE)
		HudDraw.text(self, f.display_name.to_upper(), c + Vector2(0, -r - 0.016 * u), int(0.019 * u * k), BLUE_TEXT, 1, 3, "bold")


## A red cross and the distance on every knocked teammate, pinned to the edge when out of view.
func _draw_markers(vs: Vector2, u: float) -> void:
	var p := player()
	var cam: Camera3D = p.camera if p != null else null
	if cam == null or not cam.is_inside_tree():
		return
	for f: Fighter in members(my_team()):
		if f == p or status(f) != "knocked":
			continue
		var w := f.global_position + Vector3.UP * TAG_UP_KNOCKED
		var behind := cam.is_position_behind(w)
		var m := edge_point(cam.unproject_position(w), behind, vs, EDGE_MARGIN)
		var c: Vector2 = m.pos
		var r := 0.024 * u
		var helped := revive_progress(f) >= 0.0
		var col := HudDraw.HEAL_GREEN if helped else KNOCK_RED
		var pulse := 1.0 + 0.12 * sin(_time * 6.0)
		HudDraw.disk(self, c, r * 1.12 * pulse, Color(0, 0, 0, 0.5))
		HudDraw.ring(self, c, r * pulse, Color(col, 0.95), maxf(2.0, 0.004 * u))
		_cross(c, r * 1.05, col)
		if bool(m.edge):
			var d := (c - vs * 0.5).normalized()
			var tip := c + d * r * 1.7
			draw_colored_polygon(PackedVector2Array([tip, c + d * r * 1.15 + d.orthogonal() * r * 0.45,
				c + d * r * 1.15 - d.orthogonal() * r * 0.45]), col)
		var dist := p.global_position.distance_to(f.global_position)
		var label := "%d M" % roundi(dist)
		var ly := c.y + r * 1.6 if c.y < vs.y - r * 3.0 else c.y - r * 1.7
		HudDraw.text(self, label, Vector2(c.x, ly), int(0.022 * u), Color.WHITE, 1, 3, "bold")
		HudDraw.text(self, str(badge(f)), Vector2(c.x + r * 1.15, c.y - r * 0.95), int(0.02 * u), BLUE_TEXT, 1, 3, "number")


func _draw_revive_button(u: float) -> void:
	var c := revive_center()
	var r := revive_radius()
	var rv := reviving()
	var on := rv != null
	var pressed := _pressed.has("revive")
	HudDraw.disk(self, c, r, Color(0.05, 0.12, 0.07, 0.82 if pressed else 0.66))
	HudDraw.ring(self, c, r - 1.0, Color(HudDraw.HEAL_GREEN, 0.95) if on else Color(1, 1, 1, 0.5), 2.0)
	var s := r * 0.62
	var t := s * 0.32
	var ink := HudDraw.HEAL_GREEN if not on else Color.WHITE
	draw_rect(Rect2(c - Vector2(t * 0.5, s * 0.5) - Vector2(0, r * 0.12), Vector2(t, s)), ink)
	draw_rect(Rect2(c - Vector2(s * 0.5, t * 0.5) - Vector2(0, r * 0.12), Vector2(s, t)), ink)
	HudDraw.text(self, "STOP" if on else "REVIVE", c + Vector2(0, r * 0.52), int(0.021 * u), Color.WHITE, 1, 2, "bold")
	if on:
		HudDraw.ring(self, c, r + 4.0, Color(0, 0, 0, 0.5), 6.0)
		HudDraw.ring(self, c, r + 4.0, HudDraw.HEAL_GREEN, 4.0, clampf(revive_progress(rv), 0.0, 1.0))
	else:
		var tg := revive_target()
		if tg != null:
			HudDraw.text(self, tg.display_name.to_upper(), c + Vector2(0, r + 0.022 * u), int(0.019 * u), BLUE_TEXT, 1, 3, "bold")


## A progress bar with a title over it, under the crosshair.
func _bar(vs: Vector2, u: float, fy: float, title: String, title_col: Color, frac: float, col: Color, sub := "") -> void:
	var w := 0.34 * u
	var c := Vector2(vs.x * 0.5, vs.y * fy)
	var bar := Rect2(c.x - w * 0.5, c.y, w, maxf(6.0, 0.012 * u))
	var tw := maxf(HudDraw.text_width(title, int(0.034 * u), "bold"), w) + 0.06 * u
	HudDraw.plate(self, Rect2(c.x - tw * 0.5, c.y - 0.05 * u, tw, 0.085 * u + (0.03 * u if sub != "" else 0.0)), 0.6)
	HudDraw.text(self, title, Vector2(c.x, c.y - 0.022 * u), int(0.034 * u), title_col, 1, 3, "bold")
	draw_rect(bar.grow(1.0), Color(0, 0, 0, 0.6))
	draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(frac, 0.0, 1.0), bar.size.y)), col)
	if sub != "":
		HudDraw.text(self, sub, Vector2(c.x, bar.end.y + 0.02 * u), int(0.022 * u), Color(1, 1, 1, 0.9), 1, 2, "bold")


## The player's own KNOCKED overlay: a red edge, BLEEDING OUT (knock HP left, seconds) or BEING
## REVIVED BY <NAME> with the revive's progress.
func _draw_knocked_self(vs: Vector2, u: float) -> void:
	var p := player()
	if p == null or not p.alive or not p.knocked:
		return
	var a := 0.22 + 0.08 * sin(_time * 4.0)
	_edge_glow(vs, Color(0.75, 0.04, 0.04, a), vs.y * 0.2)
	var rv := revive_progress(p)
	if rv >= 0.0:
		var who := reviver_of(p)
		_bar(vs, u, 0.6, "BEING REVIVED", HudDraw.HEAL_GREEN, rv, HudDraw.HEAL_GREEN,
			("BY " + who.display_name.to_upper()) if who != null else "")
	else:
		var frac := clampf(p.knock_hp / Fighter.KNOCK_HP, 0.0, 1.0)
		_bar(vs, u, 0.6, "BLEEDING OUT", KNOCK_RED, frac, Color(KNOCK_RED, 0.8 + 0.2 * sin(_time * 7.0)),
			"%d s  ·  CRAWL TO A TEAMMATE" % ceili(frac * Fighter.BLEED_S))


## A glow along the four screen edges, fading inwards over `t` px.
func _edge_glow(vs: Vector2, col: Color, t: float) -> void:
	var clear := Color(col, 0.0)
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(vs.x, 0), Vector2(vs.x, t), Vector2(0, t)]), PackedColorArray([col, col, clear, clear]))
	draw_polygon(PackedVector2Array([Vector2(0, vs.y - t), Vector2(vs.x, vs.y - t), Vector2(vs.x, vs.y), Vector2(0, vs.y)]),
		PackedColorArray([clear, clear, col, col]))
	draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(t, 0), Vector2(t, vs.y), Vector2(0, vs.y)]), PackedColorArray([col, clear, clear, col]))
	draw_polygon(PackedVector2Array([Vector2(vs.x - t, 0), Vector2(vs.x, 0), Vector2(vs.x, vs.y), Vector2(vs.x - t, vs.y)]),
		PackedColorArray([clear, col, col, clear]))


## The player reviving a teammate: REVIVING <NAME> with the progress.
func _draw_reviving(vs: Vector2, u: float) -> void:
	var rv := reviving()
	if rv == null:
		return
	_bar(vs, u, 0.53, "REVIVING " + rv.display_name.to_upper(), HudDraw.HEAL_GREEN, maxf(revive_progress(rv), 0.0), HudDraw.HEAL_GREEN,
		"STAY STILL")


func _draw_spectating(u: float) -> void:
	var who := spectated()
	if who == null:
		return
	var rs := spectate_rects()
	var plate: Rect2 = rs[0]
	HudDraw.plate(self, plate, 0.7)
	var ally := who.team == my_team() and who.team >= 0
	HudDraw.text(self, "SPECTATING", Vector2(plate.get_center().x, plate.position.y + plate.size.y * 0.3), int(0.022 * u), HudDraw.YELLOW, 1, 2, "bold")
	HudDraw.text(self, who.display_name.to_upper(), Vector2(plate.get_center().x, plate.position.y + plate.size.y * 0.68), int(0.03 * u),
		BLUE_TEXT if ally else ORANGE_TEXT, 1, 2, "bold")
	if not next_shown():
		return
	var nr: Rect2 = rs[1]
	var pressed := _pressed.has("next")
	draw_rect(nr, Color(0.08, 0.09, 0.1, 0.85 if pressed else 0.7))
	draw_rect(nr, Color(1, 1, 1, 0.45), false, 1.5)
	HudDraw.text(self, "NEXT", nr.get_center() + Vector2(-0.012 * u, 0), int(0.03 * u), Color.WHITE, 1, 2, "bold")
	var ax := nr.end.x - 0.03 * u
	var ay := nr.get_center().y
	draw_colored_polygon(PackedVector2Array([Vector2(ax - 0.008 * u, ay - 0.014 * u), Vector2(ax + 0.008 * u, ay),
		Vector2(ax - 0.008 * u, ay + 0.014 * u)]), HudDraw.YELLOW)
