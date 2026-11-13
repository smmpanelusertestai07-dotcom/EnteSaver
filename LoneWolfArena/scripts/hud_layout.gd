class_name HudLayout
extends RefCounted
## Default places of the movable HUD widgets and helpers that put them on any screen.
## The defaults follow the reference's layout (below). A widget is
##   x: centre x as a fraction of the 20:9 reference width,   y: centre y (fraction of height),
##   s: size as a fraction of the screen height (button diameter, minimap side, weapon slot height),
##   o: opacity 0.1 .. 1,   a: anchor "l" | "c" | "r".
## The anchor keeps the widget's distance to that screen edge (or to the centre) constant in
## screen heights, so the 20:9 layout keeps its look from 16:9 to 22:9; on screens narrower than
## 16:9 (tablets) the whole HUD shrinks to fit. Editor overrides live in Game.hud_layout (saved
## JSON, tagged with "_v"; layouts from older versions are ignored).
## The defaults (still layout version 5: a saved layout is kept as the player made it, every widget
## of it) follow the reference's default layout as measured on its 16:9 screen (left-anchored x =
## frame x * 0.8, right-anchored x = 1 - (1 - frame x) * 0.8 there): the minimap in the top-left
## corner and the gear in the small column right of it (the column's next places, about (0.185,
## 0.11) and (0.185, 0.182) of the frame, are kept free for the voice buttons; the ping sits right
## of the gear, HudNet); the weapon panel smaller in the top-right corner; FIRE smaller and further
## right, JUMP right of it and SCOPE over it at the right edge, CROUCH in the bottom-right corner with
## PRONE left of it and the GRENADE further left; the WALL up and left of FIRE; SPRINT and the stick
## on the left (sprint a little lower than the reference's, clear of the DUO / SQUAD team list
## under the minimap), the MEDKIT bottom left. The reference's quick reload, quick weapon switch and
## left fire button are off (or only while aiming) by default (Game.DEFAULT_SETTINGS); when turned on
## RELOAD and SWITCH sit up and left of the scope, clear of the middle of the screen.
## Earlier defaults (v4 from a 20:9 recording, then the later additions FREE LOOK, LEFT FIRE,
## PRONE under the weapon panel and SWITCH beside RELOAD) live on only in saved layouts and MOVED.
## No two default touch areas overlap from 16:10 to 22:9.
## A camera cutout at a short side of the screen (`inset`, set by the HUD from UI.safe_margins)
## moves the edge-anchored widgets in by its width.

const VERSION := 5
const REF_ASPECT := 20.0 / 9.0
const MIN_ASPECT := 16.0 / 9.0
const SIZE_MIN := 0.5            # editor size range relative to the default (50 .. 200 %)
const SIZE_MAX := 2.0
const OPACITY_MIN := 0.1         # editor opacity range 10 .. 100 %
const PANEL_W := 3.3             # weapon panel width in slot heights
const PANEL_H := 2.05            # main slot (1) + gap + the row of small slots
const STRIP_H := 0.17            # zone status strip under the minimap, in minimap sides
const MIN_TOUCH := 0.036         # smallest touch radius (screen heights) of a round button (taps count to 1.15 x it: 60 px at 720)
## Default places of earlier versions that have moved since: a saved layout that still has the
## widget exactly there takes its new default place (size and opacity stay the player's).
const MOVED := {"prone": [{"x": 0.673, "y": 0.073, "a": "c"}], "swap": [{"x": 0.712, "y": 0.235, "a": "r"}]}

## The screen's sides that a camera cutout covers, in canvas pixels (x left, y right; the HUD and
## the editor keep it up to date from UI.safe_margins): edge-anchored widgets keep their distance
## to the safe area's edge, and nothing is kept on screen under the cutout.
static var inset := Vector2.ZERO

## Hit-test order (first wins when two widgets overlap) and editor list.
const ORDER := ["settings", "weapons", "fire_r", "fire_l", "scope", "freelook", "wall", "jump", "crouch", "prone", "sprint",
	"medkit", "grenade", "reload", "swap", "minimap", "joystick"]
const DEFAULTS := {
	"joystick": {"x": 0.135, "y": 0.75, "s": 0.23, "o": 0.8, "a": "l"},
	"fire_r": {"x": 0.8624, "y": 0.687, "s": 0.17, "o": 0.9, "a": "r"},
	"fire_l": {"x": 0.044, "y": 0.64, "s": 0.13, "o": 0.85, "a": "l"},
	"scope": {"x": 0.964, "y": 0.53, "s": 0.104, "o": 0.85, "a": "r"},
	"freelook": {"x": 0.964, "y": 0.4, "s": 0.09, "o": 0.85, "a": "r"},
	"wall": {"x": 0.7904, "y": 0.757, "s": 0.098, "o": 0.85, "a": "r"},
	"jump": {"x": 0.964, "y": 0.7, "s": 0.115, "o": 0.85, "a": "r"},
	"crouch": {"x": 0.964, "y": 0.9, "s": 0.115, "o": 0.85, "a": "r"},
	"prone": {"x": 0.8952, "y": 0.9, "s": 0.115, "o": 0.85, "a": "r"},
	"sprint": {"x": 0.136, "y": 0.49, "s": 0.115, "o": 0.85, "a": "l"},
	"medkit": {"x": 0.1832, "y": 0.897, "s": 0.104, "o": 0.85, "a": "l"},
	"grenade": {"x": 0.7408, "y": 0.9, "s": 0.1, "o": 0.85, "a": "r"},
	"reload": {"x": 0.9, "y": 0.47, "s": 0.09, "o": 0.85, "a": "r"},
	"swap": {"x": 0.848, "y": 0.47, "s": 0.09, "o": 0.85, "a": "r"},
	"settings": {"x": 0.148, "y": 0.04, "s": 0.06, "o": 0.9, "a": "l"},
	"weapons": {"x": 0.9184, "y": 0.1535, "s": 0.108, "o": 0.95, "a": "r"},
	"minimap": {"x": 0.0625, "y": 0.137, "s": 0.27, "o": 0.95, "a": "l"},
	# Voice (HudNet draws them in an online match only; not in ORDER: the HUD's own touches and the
	# editor leave them to HudNet): the reference's speaker and mic in the column beside the minimap,
	# under the gear.
	"speaker": {"x": 0.148, "y": 0.105, "s": 0.066, "o": 0.9, "a": "l"},
	"mic": {"x": 0.148, "y": 0.19, "s": 0.066, "o": 0.9, "a": "l"},
}
## The default sizes until the defaults followed the reference's 16:9 layout: a saved layout made
## with them keeps its sizes (the size range a saved widget is held to covers both, size_range).
const OLD_SIZES := {"joystick": 0.23, "fire_r": 0.26, "fire_l": 0.15, "scope": 0.104, "freelook": 0.09, "wall": 0.11,
	"jump": 0.166, "crouch": 0.166, "prone": 0.104, "sprint": 0.131, "medkit": 0.104, "grenade": 0.13, "reload": 0.1,
	"swap": 0.1, "settings": 0.046, "weapons": 0.152, "minimap": 0.27}
const LABELS := {
	"joystick": "MOVE", "fire_r": "FIRE", "fire_l": "LEFT FIRE", "scope": "SCOPE", "jump": "JUMP", "crouch": "CROUCH", "prone": "PRONE",
	"sprint": "SPRINT", "medkit": "MEDKIT", "wall": "WALL", "grenade": "GRENADE", "settings": "SETTINGS", "freelook": "FREE LOOK",
	"weapons": "WEAPONS", "minimap": "MAP", "reload": "RELOAD", "swap": "SWITCH", "speaker": "SPEAKER", "mic": "MIC",
}


static func kind(id: String) -> String:
	match id:
		"weapons":
			return "panel"
		"minimap":
			return "square"
		"joystick":
			return "joy"
	return "button"


static func resolve(overrides: Dictionary) -> Dictionary:
	var out := {}
	for id: String in DEFAULTS:
		var def: Dictionary = DEFAULTS[id]
		var d: Dictionary = def.duplicate()
		var o: Variant = overrides.get(id)
		if o is Dictionary:
			var od := o as Dictionary
			if _at_old_default(id, od):
				od = od.duplicate()
				for k in ["x", "y", "a"]:
					od.erase(k)
			for k in ["x", "y", "s", "o"]:
				if od.has(k) and (od[k] is float or od[k] is int):
					d[k] = float(od[k])
			if od.get("a") is String and String(od.a) in ["l", "c", "r"]:
				d.a = String(od.a)
		d.x = clampf(float(d.x), 0.02, 0.98)
		d.y = clampf(float(d.y), 0.04, 0.98)
		var sr := size_range(id)
		d.s = clampf(float(d.s), sr.x, sr.y)
		if float(d.o) < OPACITY_MIN:
			d.o = def.o           # 0 / garbage: an invisible control is never what the player wants
		d.o = clampf(float(d.o), OPACITY_MIN, 1.0)
		d.id = id
		out[id] = d
	return out


## The sizes a saved widget `id` may have: SIZE_MIN .. SIZE_MAX of its default (of the older default
## too, OLD_SIZES, so a layout saved before keeps its sizes), at most 0.45 of the screen height.
static func size_range(id: String) -> Vector2:
	var now := float(DEFAULTS[id].s)
	var old := float(OLD_SIZES.get(id, now))
	return Vector2(minf(now, old) * SIZE_MIN, minf(maxf(now, old) * SIZE_MAX, 0.45))


## True when a saved widget still sits exactly at a default place it had in an earlier version.
static func _at_old_default(id: String, od: Dictionary) -> bool:
	for old: Dictionary in MOVED.get(id, []):
		var x: Variant = od.get("x")
		var y: Variant = od.get("y")
		if (x is float or x is int) and (y is float or y is int) and absf(float(x) - float(old.x)) < 0.0006 \
				and absf(float(y) - float(old.y)) < 0.0006 and String(od.get("a", "")) == String(old.a):
			return true
	return false


static func current() -> Dictionary:
	var saved: Dictionary = Game.hud_layout
	var v: Variant = saved.get("_v", 0)
	return resolve(saved if (v is int or v is float) and int(v) == VERSION else {})


## Layout ready for Game.save_hud_layout().
static func to_save(layout: Dictionary) -> Dictionary:
	var out := {"_v": VERSION}
	for id in layout:
		if DEFAULTS.has(id):
			var w: Dictionary = layout[id]
			out[id] = {"x": snappedf(float(w.x), 0.0001), "y": snappedf(float(w.y), 0.0001),
				"s": snappedf(float(w.s), 0.0001), "o": snappedf(float(w.o), 0.01), "a": String(w.a)}
	return out


## The HUD's size unit: the screen height, or less where the safe width is narrower than 16:9 so
## it all fits.
static func unit(vs: Vector2) -> float:
	return minf(vs.y, maxf(vs.x - inset.x - inset.y, 1.0) / MIN_ASPECT)


static func size_px(w: Dictionary, vs: Vector2) -> float:
	return float(w.s) * unit(vs)


static func radius(w: Dictionary, vs: Vector2) -> float:
	return size_px(w, vs) * 0.5


## Touch radius of a round button: never smaller than MIN_TOUCH (the small corner gear).
static func touch_radius(w: Dictionary, vs: Vector2) -> float:
	return maxf(radius(w, vs), MIN_TOUCH * unit(vs))


## Half size of the widget's box (keeps it on screen, used for hit tests).
static func half_extent(w: Dictionary, vs: Vector2) -> Vector2:
	var s := size_px(w, vs)
	match kind(String(w.get("id", ""))):
		"panel":
			return Vector2(PANEL_W, PANEL_H) * s * 0.5
	return Vector2(s, s) * 0.5


## Centre in pixels before it is kept on screen.
static func raw_center(w: Dictionary, vs: Vector2) -> Vector2:
	var ref_w := REF_ASPECT * unit(vs)
	var x := vs.x * 0.5 + (float(w.x) - 0.5) * ref_w
	match String(w.get("a", "c")):
		"l":
			x = inset.x + float(w.x) * ref_w
		"r":
			x = vs.x - inset.y - (1.0 - float(w.x)) * ref_w
	return Vector2(x, float(w.y) * vs.y)


static func center(w: Dictionary, vs: Vector2) -> Vector2:
	var he := half_extent(w, vs)
	var c := raw_center(w, vs)
	var m := 2.0
	var lo := inset.x + he.x + m
	return Vector2(clampf(c.x, lo, maxf(vs.x - inset.y - he.x - m, lo)), clampf(c.y, he.y + m, maxf(vs.y - he.y - m, he.y + m)))


## Moves a widget so its centre is at `pos` (pixels), picking the anchor from the screen third.
static func place(w: Dictionary, pos: Vector2, vs: Vector2) -> void:
	var ref_w := REF_ASPECT * unit(vs)
	var a := "c"
	if pos.x < vs.x * 0.36:
		a = "l"
	elif pos.x > vs.x * 0.64:
		a = "r"
	var x := 0.5 + (pos.x - vs.x * 0.5) / ref_w
	if a == "l":
		x = (pos.x - inset.x) / ref_w
	elif a == "r":
		x = 1.0 - (vs.x - inset.y - pos.x) / ref_w
	w.a = a
	w.x = clampf(x, 0.02, 0.98)
	w.y = clampf(pos.y / vs.y, 0.04, 0.98)


## Main slot of the weapon panel (the round's gun).
static func weapon_main(w: Dictionary, vs: Vector2) -> Rect2:
	var s := size_px(w, vs)
	var tl := center(w, vs) - Vector2(PANEL_W, PANEL_H) * s * 0.5
	return Rect2(tl, Vector2(PANEL_W * s, s))


## The three small slots under the main slot, left to right: the kit in SWITCH's order
## (Weapons.CYCLE): the gun, the sidearm, the fists.
static func weapon_slots(w: Dictionary, vs: Vector2) -> Array[Rect2]:
	var s := size_px(w, vs)
	var tl := center(w, vs) - Vector2(PANEL_W, PANEL_H) * s * 0.5
	var gap := s * 0.07
	var sw := (PANEL_W * s - gap * 2.0) / 3.0
	var out: Array[Rect2] = []
	for i in 3:
		out.append(Rect2(Vector2(tl.x + i * (sw + gap), tl.y + s * 1.1), Vector2(sw, s * 0.95)))
	return out


## TRAINING GROUND's CHANGE GUN (HUD._can_repick): a small plate left of the small slots' row,
## below the score bar's band, as tall as half a slot.
static func weapon_repick(w: Dictionary, vs: Vector2) -> Rect2:
	var s := size_px(w, vs)
	var row := weapon_slots(w, vs)[0]
	var size := Vector2(s * 1.25, s * 0.56)
	return Rect2(Vector2(row.position.x - s * 0.1 - size.x, row.get_center().y - size.y * 0.5), size)


## The ping's place (left end, vertical centre) beside the gear `w`, as the reference shows it (a
## signal icon and the number right of its gear: the frame's (0.278, 0.031) at 16:9): on the gear's
## inner side, on its row. null when the gear sits in the right half (the ping then goes in the
## column beside the weapon panel, HudNet).
static func ping_spot(w: Dictionary, vs: Vector2) -> Variant:
	var c := center(w, vs)
	if c.x > vs.x * 0.5:
		return null
	return Vector2(c.x + 0.12 * unit(vs), c.y)


static func minimap_rect(w: Dictionary, vs: Vector2) -> Rect2:
	var s := size_px(w, vs)
	return Rect2(center(w, vs) - Vector2(s, s) * 0.5, Vector2(s, s))


static func hit_rect(id: String, w: Dictionary, vs: Vector2) -> Rect2:
	if not w.has("id"):
		w = w.duplicate()
		w.id = id
	var he := half_extent(w, vs)
	return Rect2(center(w, vs) - he, he * 2.0)
