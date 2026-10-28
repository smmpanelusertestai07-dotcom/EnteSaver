class_name HudDraw
extends RefCounted
## Drawing helpers shared by the in-match HUD, its minimap / panels and the HUD editor. Every
## helper draws into the CanvasItem it is given, so the parts can live on separate canvas items.
## Icon textures are loaded once and cached (res://assets/ui/icons/, white glyphs tinted on draw).

const ICON_DIR := "res://assets/ui/icons/"

# Palette (reference look: dark translucent disks, white glyphs, team blue vs enemy orange).
const BTN_BG := Color(0.13, 0.135, 0.15, 0.52)
const BTN_RIM := Color(1, 1, 1, 0.24)
const GLYPH := Color(1, 1, 1, 0.96)
const GOLD := Color(1.0, 0.8, 0.26)
const YELLOW := Color(1.0, 0.82, 0.22)
const BLUE := Color(0.106, 0.569, 0.851)
const BLUE_DARK := Color(0.05, 0.36, 0.6)
const ORANGE := Color(0.875, 0.447, 0.216)
const ORANGE_DARK := Color(0.62, 0.27, 0.1)
const RED := Color(0.93, 0.2, 0.18)
const KILL_RED := Color(0.792, 0.306, 0.259)
const DMG_BODY := Color(0.93, 0.86, 0.36)
const DMG_HEAD := Color(0.898, 0.224, 0.208)
const FEED_ELIM := Color(0.85, 0.78, 0.32)
const FEED_HEAD := Color(1.0, 0.6, 0.18)
const HP_WHITE := Color(0.92, 0.94, 0.95)
const HEAL_GREEN := Color(0.36, 0.86, 0.42)
const PANEL_BG := Color(0.035, 0.04, 0.05, 0.9)
const CARD_BG := Color(0.11, 0.12, 0.14, 0.92)
const SHADOW := Color(0, 0, 0, 0.7)

static var _tex := {}


## Cached icon texture by name ("v_fire", "weapon_ar", ...); `fallback` is used when missing.
static func tex(icon_name: String, fallback := "") -> Texture2D:
	if _tex.has(icon_name):
		var t: Texture2D = _tex[icon_name]
		if t == null and fallback != "":
			return tex(fallback)
		return t
	var found: Texture2D = null
	var path := ICON_DIR + icon_name + ".png"
	if icon_name != "" and ResourceLoader.exists(path):
		found = load(path)
	_tex[icon_name] = found
	if found == null and fallback != "":
		return tex(fallback)
	return found


## Loads every listed icon now (avoids a hitch the first time a widget shows up mid-match).
static func preload_icons(names: Array) -> void:
	for n in names:
		tex(String(n))


## Weapon silhouette for a weapon definition (missing icons fall back to the AR).
static func weapon_tex(def: Dictionary) -> Texture2D:
	return tex(String(def.get("icon", "weapon_ar")), "weapon_ar")


static func font(kind := "bold") -> Font:
	return UI.font(kind)


## Draws `t` with its vertical centre at pos.y; align: 0 left, 1 centre, 2 right (of pos.x).
## Returns the text width.
static func text(ci: CanvasItem, t: String, pos: Vector2, size: int, col: Color, align := 1,
		outline := 0, kind := "bold", outline_col := SHADOW) -> float:
	if t == "" or col.a <= 0.003:
		return 0.0
	var f := UI.font(kind)
	size = maxi(size, 6)
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var x := pos.x
	if align == 1:
		x -= w * 0.5
	elif align == 2:
		x -= w
	var base := Vector2(x, pos.y + (f.get_ascent(size) - f.get_descent(size)) * 0.5)
	if outline > 0:
		ci.draw_string_outline(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, outline, Color(outline_col, outline_col.a * col.a))
	ci.draw_string(f, base, t, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	return w


static func text_width(t: String, size: int, kind := "bold") -> float:
	return UI.font(kind).get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, maxi(size, 6)).x


## Text made of coloured parts: [[text, Color], ...] laid out on one line.
static func text_parts(ci: CanvasItem, parts: Array, pos: Vector2, size: int, align := 1, outline := 0,
		kind := "bold", alpha := 1.0) -> float:
	var total := 0.0
	for p in parts:
		total += text_width(String(p[0]), size, kind)
	var x := pos.x
	if align == 1:
		x -= total * 0.5
	elif align == 2:
		x -= total
	for p in parts:
		var c: Color = p[1]
		c.a *= alpha
		x += text(ci, String(p[0]), Vector2(x, pos.y), size, c, 0, outline, kind)
	return total


## Icon texture fitted into `box` (keeping its aspect) around `center`, tinted by `col`.
static func icon(ci: CanvasItem, t: Texture2D, center: Vector2, box: Vector2, col: Color) -> void:
	if t == null or col.a <= 0.003:
		return
	var ts := t.get_size()
	var k := minf(box.x / ts.x, box.y / ts.y)
	var sz := ts * k
	ci.draw_texture_rect(t, Rect2(center - sz * 0.5, sz), false, col)


static func ring(ci: CanvasItem, c: Vector2, r: float, col: Color, width: float, frac := 1.0, start := -PI * 0.5) -> void:
	if col.a <= 0.003 or frac <= 0.0:
		return
	ci.draw_arc(c, r, start, start + TAU * clampf(frac, 0.0, 1.0), maxi(12, int(72 * frac)), col, width, true)


static func disk(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	if col.a > 0.003:
		ci.draw_circle(c, r, col, true, -1.0, true)


## Round HUD button: dark translucent disk, faint lighter rim, glyph inside.
static func button(ci: CanvasItem, c: Vector2, r: float, glyph: Texture2D, opacity: float, pressed := false,
		active := false, enabled := true, glyph_scale := 0.62) -> void:
	var bg := BTN_BG
	if pressed:
		bg = Color(0.32, 0.33, 0.36, 0.62)
	disk(ci, c, r, Color(bg, bg.a * opacity))
	var rim := GOLD if active else BTN_RIM
	ring(ci, c, r - 0.75, Color(rim, (0.85 if active else rim.a) * opacity), 1.6 if not active else 2.2)
	var gc := GOLD if active else GLYPH
	if not enabled:
		gc = Color(1, 1, 1, 0.38)
	var gs := r * 2.0 * glyph_scale * (0.92 if pressed else 1.0)
	icon(ci, glyph, c, Vector2(gs, gs), Color(gc, gc.a * opacity))


## Small count at the lower right inside a button ("2" medkits).
static func count_badge(ci: CanvasItem, c: Vector2, r: float, n: int, opacity: float) -> void:
	var col := Color(1, 1, 1, 0.95 * opacity) if n > 0 else Color(1, 0.45, 0.4, 0.95 * opacity)
	text(ci, str(n), c + Vector2(r * 0.62, r * 0.5), maxi(int(r * 0.42), 11), col, 1, 3, "bold")


## Parallelogram from its top edge [x0, x1] at y0 to the bottom edge shifted by `slant`.
static func slanted(ci: CanvasItem, x0: float, x1: float, y0: float, h: float, slant: float, col: Color) -> void:
	if col.a <= 0.003:
		return
	var pts := PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1 + slant, y0 + h), Vector2(x0 + slant, y0 + h)])
	ci.draw_colored_polygon(pts, col)


## Thin L-shaped brackets at the four corners of a rect (panel / card decoration).
static func corner_brackets(ci: CanvasItem, r: Rect2, arm: float, col: Color, width := 1.5) -> void:
	var p := r.position
	var e := r.end
	for c in [[p, Vector2(1, 1)], [Vector2(e.x, p.y), Vector2(-1, 1)], [Vector2(p.x, e.y), Vector2(1, -1)], [e, Vector2(-1, -1)]]:
		var o: Vector2 = c[0]
		var d: Vector2 = c[1]
		ci.draw_line(o, o + Vector2(d.x * arm, 0), col, width)
		ci.draw_line(o, o + Vector2(0, d.y * arm), col, width)


## Horizontal gradient band (left colour -> right colour) with vertical edges.
static func band(ci: CanvasItem, r: Rect2, left: Color, right: Color) -> void:
	var pts := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	ci.draw_polygon(pts, PackedColorArray([left, right, right, left]))


## Vertical gradient (top colour -> bottom colour).
static func vband(ci: CanvasItem, r: Rect2, top: Color, bottom: Color) -> void:
	var pts := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	ci.draw_polygon(pts, PackedColorArray([top, top, bottom, bottom]))


## Close button: dark disk with a red X.
static func close_button(ci: CanvasItem, c: Vector2, r: float, alpha := 1.0) -> void:
	disk(ci, c, r, Color(0, 0, 0, 0.45 * alpha))
	var k := r * 0.42
	ci.draw_line(c + Vector2(-k, -k), c + Vector2(k, k), Color(1.0, 0.36, 0.28, alpha), maxf(2.0, r * 0.16), true)
	ci.draw_line(c + Vector2(k, -k), c + Vector2(-k, k), Color(1.0, 0.36, 0.28, alpha), maxf(2.0, r * 0.16), true)


static func time_text(seconds: float) -> String:
	var s := maxi(ceili(maxf(seconds, 0.0) - 0.001), 0)
	return "%02d:%02d" % [s / 60, s % 60]
