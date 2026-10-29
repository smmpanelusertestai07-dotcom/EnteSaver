class_name HudMinimap
extends Control
## The HUD's square minimap, north up: a window of the arena's top-down render
## (arena.minimap_texture over arena.map_rect) that follows the player, the player arrow with its
## view cone, the enemy as a red dot while revealed (shots / footsteps) or in sight, and the white
## safe-zone circle. It clips its drawing to its own rect; until the render exists (first frames)
## a dark floor plan from arena.obstacles stands in. The HUD places it from its layout.

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


func _draw() -> void:
	var s := size
	var o := opacity
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.075, 0.085, 0.095, 0.9 * o))
	if hud == null or hud.editor_mode or hud.arena == null or hud.player == null:
		_placeholder(s, o)
		_frame(s, o)
		return
	var arena: Node = hud.arena
	var player: Player = hud.player
	var mr: Rect2 = arena.get("map_rect")
	var pp := Vector2(player.global_position.x, player.global_position.z)
	var half := VIEW_M * 0.5
	var origin := pp - Vector2(half, half)
	origin.x = clampf(origin.x, mr.position.x, mr.end.x - VIEW_M) if mr.size.x > VIEW_M else mr.get_center().x - half
	origin.y = clampf(origin.y, mr.position.y, mr.end.y - VIEW_M) if mr.size.y > VIEW_M else mr.get_center().y - half
	var k := s.x / VIEW_M
	var tex := _map_texture(arena)
	if tex != null:
		var ts := tex.get_size()
		var src := Rect2((origin - mr.position) / mr.size * ts, Vector2(VIEW_M, VIEW_M) / mr.size * ts)
		draw_texture_rect_region(tex, Rect2(Vector2.ZERO, s), src, Color(1, 1, 1, o))
	else:
		for r: Rect2 in arena.get("obstacles"):
			draw_rect(Rect2((r.position - origin) * k, r.size * k), Color(0.55, 0.6, 0.66, 0.55 * o))
		draw_rect(Rect2((mr.position - origin) * k, mr.size * k), Color(1, 1, 1, 0.6 * o), false, 2.0)
	# Safe zone (once the fight started).
	var zr: float = arena.get("zone_radius")
	if zr < 200.0:
		var zc: Vector3 = arena.get("zone_center")
		var zp := (Vector2(zc.x, zc.z) - origin) * k
		draw_arc(zp, zr * k, 0.0, TAU, 72, Color(0.35, 0.6, 1.0, 0.35 * o), 4.0, true)
		draw_arc(zp, zr * k, 0.0, TAU, 72, Color(1, 1, 1, 0.92 * o), 1.6, true)
	# Enemy: red dot while revealed or in sight.
	var reveal: Dictionary = hud._reveal
	var seen: Dictionary = hud.seen
	for f: Fighter in arena.get("fighters"):
		if f == player or not f.alive:
			continue
		if not (reveal.has(f) or seen.get(f, false)):
			continue
		var ep := (Vector2(f.global_position.x, f.global_position.z) - origin) * k
		var pulse := 1.0 + 0.25 * sin(Time.get_ticks_msec() / 90.0) if reveal.has(f) else 1.0
		draw_circle(ep, 6.0 * pulse, Color(0, 0, 0, 0.55 * o), true, -1.0, true)
		draw_circle(ep, 4.6 * pulse, Color(1.0, 0.22, 0.2, o), true, -1.0, true)
	# Player: view cone + arrow.
	var p := (pp - origin) * k
	var dir := Vector2(-sin(player.aim_yaw), -cos(player.aim_yaw))
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
	_frame(s, o)


func _frame(s: Vector2, o: float) -> void:
	draw_rect(Rect2(Vector2.ZERO, s), Color(0, 0, 0, 0.55 * o), false, 2.0)
	draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), Color(1, 1, 1, 0.16 * o), false, 1.0)


## Editor / loading stand-in: dark plan with a few blocks and the arrow.
func _placeholder(s: Vector2, o: float) -> void:
	var g := Color(1, 1, 1, 0.05 * o)
	for i in range(1, 6):
		draw_line(Vector2(s.x * i / 6.0, 0), Vector2(s.x * i / 6.0, s.y), g, 1.0)
		draw_line(Vector2(0, s.y * i / 6.0), Vector2(s.x, s.y * i / 6.0), g, 1.0)
	var blocks := [Rect2(0.18, 0.2, 0.22, 0.1), Rect2(0.55, 0.32, 0.1, 0.28), Rect2(0.25, 0.62, 0.3, 0.1), Rect2(0.7, 0.7, 0.16, 0.1)]
	var cols := [Color(0.35, 0.6, 0.85), Color(0.8, 0.42, 0.25), Color(0.85, 0.55, 0.2), Color(0.35, 0.6, 0.85)]
	for i in blocks.size():
		var b: Rect2 = blocks[i]
		draw_rect(Rect2(b.position * s, b.size * s), Color(cols[i], 0.55 * o))
	draw_rect(Rect2(s * 0.06, s * 0.88), Color(1, 1, 1, 0.45 * o), false, 1.5)
	var p := s * Vector2(0.45, 0.55)
	var d := Vector2(0, -1)
	draw_colored_polygon(PackedVector2Array([p + d * 10.0, p + Vector2(7, 7), p + d * -2.0, p + Vector2(-7, 7)]), Color(ARROW, o))
