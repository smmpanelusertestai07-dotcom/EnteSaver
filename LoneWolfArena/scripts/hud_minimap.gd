class_name HudMinimap
extends Control
## The HUD's square minimap: a window of the arena's top-down render (arena.minimap_texture over
## arena.map_rect) around the player, the player arrow with its view cone, the enemy as a red
## arrowhead at its place, pointing where it faces, only while in sight; out of sight its shots
## leave small red marks where they were fired that fade over HUD.SHOT_SHOW s (never its live
## position), its running steps red footprints; and the white safe-zone circle. By default (the
## setting minimap_turns, SETTINGS > DISPLAY > MINIMAP: TURNS WITH VIEW) the map turns with the
## view: the player stays in the middle with its arrow pointing up, so what is ahead is drawn above
## it and what is to its right to its right, and everything on it (marks, teammates, footprints,
## shots, the zone) turns with the map; a small N on the edge shows where north is. NORTH UP keeps
## north up: the window follows the player, stops at the map's edges, and the arrow turns.
## Both are one transform in the draw (view_xform: world X/Z to minimap pixels), no extra
## viewport. It clips its drawing to its own rect; until the render exists (first frames) a dark
## floor plan from arena.obstacles stands in, and the HUD editor shows a stand-in plan turned the
## way the setting says. The HUD places it from its layout. DUO / SQUAD (the HUD's HudTeam):
## teammates always, as blue dots with their number (a knocked one in a red ring, one out of the
## round not at all); every enemy as in the 1 vs 1 (ally_marks, enemy_marks).

const VIEW_M := 28.0                       # metres shown edge to edge
const ARROW := Color(0.16, 0.8, 0.88)      # player arrow (cyan, like the reference)

var hud                                    # the HUD (untyped: data is read dynamically)
var opacity := 1.0
var _src: Texture2D
var _tex: Texture2D


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


## A mipmapped copy of the arena's render (it is drawn ~2.5x smaller than rendered).
func _map_texture(arena: Node) -> Texture2D:
	var src: Texture2D = arena.get("minimap_texture")
	if src != _src:
		_src = src
		_tex = null
		if src != null:
			var img := src.get_image()
			if img != null and not img.is_empty():
				if img.is_compressed():
					img.decompress()
				# Darker, punchier plan (the render is lit like the hall): grey floor, bold colours.
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)
				img.adjust_bcs(0.6, 1.3, 1.25)
				img.generate_mipmaps()
				_tex = ImageTexture.create_from_image(img)
	return _tex


## Whether the minimap turns with the view (the setting minimap_turns; true unless set to NORTH UP).
static func turns() -> bool:
	return bool(Game.settings.get("minimap_turns", true))


## World X/Z (metres) to minimap pixels for a minimap `side` px square around the player at `pp`
## looking along `yaw` (Fighter.aim_yaw: forward is (-sin, -cos) in X/Z, north is -Z). `turn`: the
## player in the middle with its forward up (the map turned by yaw); else north up, a VIEW_M
## window following the player that stops at the map's edges (`mr`).
static func view_xform(pp: Vector2, yaw: float, side: float, mr: Rect2, turn: bool) -> Transform2D:
	var k := side / VIEW_M
	if turn:
		return Transform2D(yaw, Vector2(k, k), 0.0, Vector2(side, side) * 0.5) * Transform2D(0.0, -pp)
	var half := VIEW_M * 0.5
	var origin := pp - Vector2(half, half)
	origin.x = clampf(origin.x, mr.position.x, mr.end.x - VIEW_M) if mr.size.x > VIEW_M else mr.get_center().x - half
	origin.y = clampf(origin.y, mr.position.y, mr.end.y - VIEW_M) if mr.size.y > VIEW_M else mr.get_center().y - half
	return Transform2D(0.0, Vector2(k, k), 0.0, -origin * k)


## A world direction (X/Z) as drawn on the minimap, unit length.
static func view_dir(xf: Transform2D, d: Vector2) -> Vector2:
	return xf.basis_xform(d).normalized()


## The part of the world the minimap shows (X/Z), as a rect that covers it: a turned map's
## corners reach out to half the diagonal.
static func view_world_rect(xf: Transform2D, side: float) -> Rect2:
	var inv := xf.affine_inverse()
	var r := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	for c: Vector2 in [Vector2(side, 0), Vector2(0, side), Vector2(side, side)]:
		r = r.expand(inv * c)
	return r


func _draw() -> void:
	var s := size
	var o := opacity
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.075, 0.085, 0.095, 0.9 * o))
	if hud == null or hud.editor_mode or hud.arena == null or hud.player == null:
		_placeholder(s, o, turns())
		_frame(s, o)
		return
	var arena: Node = hud.arena
	var player: Player = hud.player
	var mr: Rect2 = arena.get("map_rect")
	var pp := Vector2(player.global_position.x, player.global_position.z)
	var turn := turns()
	var xf := view_xform(pp, player.aim_yaw, s.x, mr, turn)
	var k := s.x / VIEW_M
	# The floor plan: drawn in world units through the view's transform, only the part on screen.
	var shown := view_world_rect(xf, s.x).intersection(mr)
	var tex := _map_texture(arena)
	if tex != null:
		if shown.has_area():
			var ts := tex.get_size()
			draw_set_transform_matrix(xf)
			draw_texture_rect_region(tex, shown, Rect2((shown.position - mr.position) / mr.size * ts, shown.size / mr.size * ts), Color(1, 1, 1, o))
			draw_set_transform_matrix(Transform2D.IDENTITY)
	else:
		draw_set_transform_matrix(xf)
		for r: Rect2 in arena.get("obstacles"):
			draw_rect(r, Color(0.55, 0.6, 0.66, 0.55 * o))
		draw_set_transform_matrix(Transform2D.IDENTITY)
		draw_polyline(PackedVector2Array([xf * mr.position, xf * Vector2(mr.end.x, mr.position.y), xf * mr.end,
			xf * Vector2(mr.position.x, mr.end.y), xf * mr.position]), Color(1, 1, 1, 0.6 * o), 2.0)
	# Safe zone (once the fight started).
	var zr: float = arena.get("zone_radius")
	if zr < 200.0:
		var zc: Vector3 = arena.get("zone_center")
		var zp := xf * Vector2(zc.x, zc.z)
		draw_arc(zp, zr * k, 0.0, TAU, 72, Color(0.35, 0.6, 1.0, 0.35 * o), 4.0, true)
		draw_arc(zp, zr * k, 0.0, TAU, 72, Color(1, 1, 1, 0.92 * o), 1.6, true)
	# Enemy footsteps: red footprints that fade out.
	for st: Dictionary in hud.steps:
		var d := view_dir(xf, st.dir)
		var fp := xf * Vector2(st.p) + Vector2(-d.y, d.x) * float(st.side) * 2.6
		draw_set_transform(fp, atan2(-d.x, d.y), Vector2(0.6, 1.0))
		draw_circle(Vector2.ZERO, 4.4, Color(1.0, 0.3, 0.22, 0.85 * o * clampf(float(st.t) / 0.8, 0.0, 1.0)), true, -1.0, true)
	draw_set_transform(Vector2.ZERO)
	# Teammates (DUO / SQUAD): numbered blue dots, always.
	var team: HudTeam = hud.get("team")
	for m: Dictionary in ally_marks(team, xf):
		var ap: Vector2 = m.pos
		if bool(m.knocked):
			draw_circle(ap, 10.0, Color(0.95, 0.24, 0.2, 0.95 * o), false, 2.5, true)
		draw_circle(ap, 7.5, Color(0, 0, 0, 0.6 * o), true, -1.0, true)
		draw_circle(ap, 6.2, Color(HudDraw.BLUE, o), true, -1.0, true)
		HudDraw.text(self, str(int(m.n)), ap + Vector2(0, 0.5), 10, Color(1, 1, 1, o), 1, 0, "number")
	# Enemy shots fired out of sight: small red marks where they were, fading.
	for sh: Dictionary in hud.shots_heard:
		var sp := xf * Vector2(sh.p)
		var fade := clampf(float(sh.t) / float(HUD.SHOT_SHOW), 0.0, 1.0)
		draw_circle(sp, 4.2, Color(0, 0, 0, 0.45 * o * fade), true, -1.0, true)
		draw_circle(sp, 3.0, Color(1.0, 0.24, 0.2, 0.95 * o * fade), true, -1.0, true)
	# Enemies in sight: a red arrowhead pointing where each one faces.
	for m: Dictionary in enemy_marks(arena.get("fighters"), player, team, hud.seen, xf):
		var ep: Vector2 = m.pos
		var ed: Vector2 = m.dir
		var es := ed.orthogonal()
		var e := 6.5
		var head := PackedVector2Array([ep + ed * e * 1.35, ep - ed * e * 0.8 + es * e * 0.95, ep - ed * e * 0.3, ep - ed * e * 0.8 - es * e * 0.95])
		draw_colored_polygon(head, Color(1.0, 0.22, 0.2, o))
		head.append(head[0])
		draw_polyline(head, Color(0, 0, 0, 0.7 * o), 1.4, true)
	# Player: view cone + arrow (straight up on a turned map).
	_player_arrow(xf * pp, view_dir(xf, Vector2(-sin(player.aim_yaw), -cos(player.aim_yaw))), s, o)
	if turn:
		_north_mark(view_dir(xf, Vector2(0, -1)), s, o)
	_frame(s, o)


## The player's view cone and arrow at `p`, pointing along `dir` (minimap pixels).
func _player_arrow(p: Vector2, dir: Vector2, s: Vector2, o: float) -> void:
	var cone := s.x * 0.42
	var half_fov := deg_to_rad(34.0)
	var cone_pts := PackedVector2Array([p, p + dir.rotated(-half_fov) * cone, p + dir * cone * 1.04, p + dir.rotated(half_fov) * cone])
	draw_polygon(cone_pts, PackedColorArray([Color(1, 1, 1, 0.34 * o), Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0), Color(1, 1, 1, 0.0)]))
	var side := dir.orthogonal()
	var a := 7.5
	var arrow := PackedVector2Array([p + dir * a * 1.3, p - dir * a * 0.8 + side * a, p - dir * a * 0.25, p - dir * a * 0.8 - side * a])
	draw_colored_polygon(arrow, Color(ARROW, o))
	arrow.append(arrow[0])
	draw_polyline(arrow, Color(0, 0, 0, 0.6 * o), 1.2, true)


## Where north is on a turned map: a small N on a dark disc at the frame's edge, in north's direction
## from the middle (`n`, unit length, minimap pixels).
func _north_mark(n: Vector2, s: Vector2, o: float) -> void:
	var r := maxf(7.0, s.x * 0.045)
	var c := s * 0.5 + n / maxf(absf(n.x), absf(n.y)) * (s.x * 0.5 - r - 3.0)
	draw_circle(c, r, Color(0, 0, 0, 0.62 * o), true, -1.0, true)
	draw_circle(c, r, Color(1, 1, 1, 0.35 * o), false, 1.0, true)
	HudDraw.text(self, "N", c + Vector2(0, 0.5), int(r * 1.25), Color(1, 1, 1, 0.95 * o), 1, 0, "bold")


## The teammates' marks (the player's own arrow aside): [{"pos" (in the minimap, through the view's
## transform `xf`: view_xform), "n" (badge), "knocked"}] for every teammate still in the round; []
## without a team layer.
static func ally_marks(team: HudTeam, xf: Transform2D) -> Array:
	var out := []
	if team == null:
		return out
	var me := team.player()
	var n := 0
	for f: Fighter in team.members(team.my_team()):
		n += 1
		var st := team.status(f)
		if f == me or st == "out" or st == "left":
			continue
		out.append({"pos": xf * Vector2(f.global_position.x, f.global_position.z), "n": n, "knocked": st == "knocked"})
	return out


## The enemies drawn live: [{"pos" (in the minimap, through `xf`: view_xform), "dir" (where it
## faces, as drawn: turned with the map)}] for every enemy alive and in sight (`seen`: HUD.seen);
## teammates (`team`'s side) and the player never.
static func enemy_marks(fighters: Array, me: Fighter, team: HudTeam, seen: Dictionary, xf: Transform2D) -> Array:
	var out := []
	for f: Fighter in fighters:
		if f == me or not f.alive or not bool(seen.get(f, false)):
			continue
		if team != null and f.team == team.my_team():
			continue
		out.append({"pos": xf * Vector2(f.global_position.x, f.global_position.z),
			"dir": view_dir(xf, Vector2(-sin(f.aim_yaw), -cos(f.aim_yaw)))})
	return out


func _frame(s: Vector2, o: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, s), Color(0, 0, 0, 0.55 * o), false, 2.0)
	draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), Color(1, 1, 1, 0.16 * o), false, 1.0)


## Editor / loading stand-in: dark plan with a few blocks and the arrow. `turn` (the setting): the
## plan turned by PREVIEW_YAW with the arrow up and the N mark; north up, the plan straight and the
## arrow turned instead, so the HUD editor's preview shows the choice.
const PREVIEW_YAW := 0.6


func _placeholder(s: Vector2, o: float, turn := false) -> void:
	var c := s * 0.5
	draw_set_transform(c, PREVIEW_YAW if turn else 0.0)
	var g := Color(1, 1, 1, 0.05 * o)
	for i in range(-3, 10):
		var f := s.x * i / 6.0 - c.x
		draw_line(Vector2(f, -s.y), Vector2(f, s.y), g, 1.0)
		draw_line(Vector2(-s.x, f), Vector2(s.x, f), g, 1.0)
	var blocks := [Rect2(0.18, 0.2, 0.22, 0.1), Rect2(0.55, 0.32, 0.1, 0.28), Rect2(0.25, 0.62, 0.3, 0.1), Rect2(0.7, 0.7, 0.16, 0.1)]
	var cols := [Color(0.35, 0.6, 0.85), Color(0.8, 0.42, 0.25), Color(0.85, 0.55, 0.2), Color(0.35, 0.6, 0.85)]
	for i in blocks.size():
		var b: Rect2 = blocks[i]
		draw_rect(Rect2(b.position * s - c, b.size * s), Color(cols[i], 0.55 * o))
	draw_rect(Rect2(s * 0.06 - c, s * 0.88), Color(1, 1, 1, 0.45 * o), false, 1.5)
	draw_set_transform(Vector2.ZERO)
	var d := Vector2(0, -1) if turn else Vector2(0, -1).rotated(-PREVIEW_YAW)
	var p := c
	draw_colored_polygon(PackedVector2Array([p + d * 10.0, p + (d.orthogonal() - d) * 7.0, p + d * -2.0, p - (d.orthogonal() + d) * 7.0]), Color(ARROW, o))
	if turn:
		_north_mark(Vector2(0, -1).rotated(PREVIEW_YAW), s, o)
