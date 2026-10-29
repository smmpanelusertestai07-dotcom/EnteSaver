class_name HudLayout
extends RefCounted
## Default places of the movable HUD widgets and helpers that put them on any screen.
## The defaults were measured on a 20:9 phone (the reference layout). A widget is
##   x: centre x as a fraction of the 20:9 reference width,   y: centre y (fraction of height),
##   s: size as a fraction of the screen height (button diameter, minimap side, weapon slot height),
##   o: opacity 0.1 .. 1,   a: anchor "l" | "c" | "r".
## The anchor keeps the widget's distance to that screen edge (or to the centre) constant in
## screen heights, so the 20:9 layout keeps its look from 16:9 to 22:9; on screens narrower than
## 16:9 (tablets) the whole HUD shrinks to fit. Editor overrides live in Game.hud_layout (saved
## JSON, tagged with "_v"; layouts from older versions are ignored).
## v3: the weapon panel sits at the top like the reference (main slot y 0.05 .. 0.155, small
## slots 0.166 .. 0.266) under a small corner gear; the scoreboard button moved left of the
## panel; sprint and wall buttons 0.148 h.

const VERSION := 3
const REF_ASPECT := 20.0 / 9.0
const MIN_ASPECT := 16.0 / 9.0
const SIZE_MIN := 0.5            # editor size range relative to the default (50 .. 200 %)
const SIZE_MAX := 2.0
const OPACITY_MIN := 0.1         # editor opacity range 10 .. 100 %
const PANEL_W := 3.3             # weapon panel width in slot heights
const PANEL_H := 2.05            # main slot (1) + gap + the row of small slots
const STRIP_H := 0.17            # zone status strip under the minimap, in minimap sides
const MIN_TOUCH := 0.036         # smallest touch radius (screen heights) of a round button

## Hit-test order (first wins when two widgets overlap) and editor list.
const ORDER := ["settings", "scoreboard", "weapons", "fire_r", "fire_l", "scope", "jump", "crouch", "prone",
	"sprint", "reload", "medkit", "wall", "grenade", "minimap", "joystick"]
const DEFAULTS := {
	"joystick": {"x": 0.177, "y": 0.79, "s": 0.25, "o": 0.8, "a": "l"},
	"fire_r": {"x": 0.82, "y": 0.69, "s": 0.22, "o": 0.9, "a": "r"},
	"fire_l": {"x": 0.075, "y": 0.5, "s": 0.13, "o": 0.85, "a": "l"},
	"scope": {"x": 0.932, "y": 0.55, "s": 0.13, "o": 0.85, "a": "r"},
	"jump": {"x": 0.932, "y": 0.725, "s": 0.115, "o": 0.85, "a": "r"},
	"crouch": {"x": 0.932, "y": 0.925, "s": 0.11, "o": 0.85, "a": "r"},
	"prone": {"x": 0.859, "y": 0.925, "s": 0.11, "o": 0.85, "a": "r"},
	"sprint": {"x": 0.174, "y": 0.475, "s": 0.148, "o": 0.85, "a": "l"},
	"reload": {"x": 0.735, "y": 0.8, "s": 0.1, "o": 0.85, "a": "r"},
	"medkit": {"x": 0.28, "y": 0.925, "s": 0.11, "o": 0.85, "a": "l"},
	"wall": {"x": 0.29, "y": 0.7, "s": 0.148, "o": 0.85, "a": "l"},
	"grenade": {"x": 0.648, "y": 0.925, "s": 0.11, "o": 0.85, "a": "c"},
	"settings": {"x": 0.952, "y": 0.027, "s": 0.046, "o": 0.9, "a": "r"},
	"scoreboard": {"x": 0.785, "y": 0.216, "s": 0.062, "o": 0.85, "a": "r"},
	"weapons": {"x": 0.891, "y": 0.158, "s": 0.105, "o": 0.95, "a": "r"},
	"minimap": {"x": 0.1, "y": 0.155, "s": 0.26, "o": 0.95, "a": "l"},
}
const LABELS := {
	"joystick": "MOVE", "fire_r": "FIRE", "fire_l": "LEFT FIRE", "scope": "SCOPE", "jump": "JUMP",
	"crouch": "CROUCH", "prone": "PRONE", "sprint": "SPRINT", "reload": "RELOAD", "medkit": "MEDKIT",
	"wall": "WALL", "grenade": "GRENADE", "settings": "SETTINGS", "scoreboard": "SCOREBOARD",
	"weapons": "WEAPONS", "minimap": "MAP",
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
			for k in ["x", "y", "s", "o"]:
				if od.has(k) and (od[k] is float or od[k] is int):
					d[k] = float(od[k])
			if od.get("a") is String and String(od.a) in ["l", "c", "r"]:
				d.a = String(od.a)
		d.x = clampf(float(d.x), 0.02, 0.98)
		d.y = clampf(float(d.y), 0.04, 0.98)
		d.s = clampf(float(d.s), float(def.s) * SIZE_MIN, minf(float(def.s) * SIZE_MAX, 0.45))
		if float(d.o) < OPACITY_MIN:
			d.o = def.o           # 0 / garbage: an invisible control is never what the player wants
		d.o = clampf(float(d.o), OPACITY_MIN, 1.0)
		d.id = id
		out[id] = d
	return out


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


## The HUD's size unit: the screen height, or less on screens narrower than 16:9 so it all fits.
static func unit(vs: Vector2) -> float:
	return minf(vs.y, vs.x / MIN_ASPECT)


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
			x = float(w.x) * ref_w
		"r":
			x = vs.x - (1.0 - float(w.x)) * ref_w
	return Vector2(x, float(w.y) * vs.y)


static func center(w: Dictionary, vs: Vector2) -> Vector2:
	var he := half_extent(w, vs)
	var c := raw_center(w, vs)
	var m := 2.0
	return Vector2(clampf(c.x, he.x + m, maxf(vs.x - he.x - m, he.x + m)), clampf(c.y, he.y + m, maxf(vs.y - he.y - m, he.y + m)))


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
		x = pos.x / ref_w
	elif a == "r":
		x = 1.0 - (vs.x - pos.x) / ref_w
	w.a = a
	w.x = clampf(x, 0.02, 0.98)
	w.y = clampf(pos.y / vs.y, 0.04, 0.98)


## Main slot of the weapon panel (the round's gun).
static func weapon_main(w: Dictionary, vs: Vector2) -> Rect2:
	var s := size_px(w, vs)
	var tl := center(w, vs) - Vector2(PANEL_W, PANEL_H) * s * 0.5
	return Rect2(tl, Vector2(PANEL_W * s, s))


## The three small slots under the main slot, left to right: gun, (empty), fists.
static func weapon_slots(w: Dictionary, vs: Vector2) -> Array[Rect2]:
	var s := size_px(w, vs)
	var tl := center(w, vs) - Vector2(PANEL_W, PANEL_H) * s * 0.5
	var gap := s * 0.07
	var sw := (PANEL_W * s - gap * 2.0) / 3.0
	var out: Array[Rect2] = []
	for i in 3:
		out.append(Rect2(Vector2(tl.x + i * (sw + gap), tl.y + s * 1.1), Vector2(sw, s * 0.95)))
	return out


static func minimap_rect(w: Dictionary, vs: Vector2) -> Rect2:
	var s := size_px(w, vs)
	return Rect2(center(w, vs) - Vector2(s, s) * 0.5, Vector2(s, s))


static func hit_rect(id: String, w: Dictionary, vs: Vector2) -> Rect2:
	if not w.has("id"):
		w = w.duplicate()
		w.id = id
	var he := half_extent(w, vs)
	return Rect2(center(w, vs) - he, he * 2.0)
