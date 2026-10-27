class_name HudLayout
extends RefCounted
## Default positions of the movable HUD controls and helpers to resolve them on any screen.
## x/y are normalized screen coordinates of the center, s is the size as a fraction of the
## screen height, o is opacity. User overrides live in Game.hud_layout (saved as JSON).

const ORDER := ["fire_r", "fire_l", "scope", "jump", "crouch", "reload", "medkit", "shield", "grenade", "weapons", "joystick"]
const DEFAULTS := {
	"joystick": {"x": 0.15, "y": 0.71, "s": 0.30, "o": 0.7},
	"fire_r": {"x": 0.845, "y": 0.63, "s": 0.19, "o": 0.85},
	"fire_l": {"x": 0.105, "y": 0.35, "s": 0.13, "o": 0.75},
	"scope": {"x": 0.935, "y": 0.43, "s": 0.105, "o": 0.8},
	"jump": {"x": 0.935, "y": 0.80, "s": 0.11, "o": 0.8},
	"crouch": {"x": 0.80, "y": 0.885, "s": 0.10, "o": 0.8},
	"reload": {"x": 0.705, "y": 0.905, "s": 0.085, "o": 0.8},
	"medkit": {"x": 0.29, "y": 0.905, "s": 0.09, "o": 0.8},
	"shield": {"x": 0.745, "y": 0.43, "s": 0.10, "o": 0.8},
	"grenade": {"x": 0.86, "y": 0.27, "s": 0.09, "o": 0.8},
	"weapons": {"x": 0.50, "y": 0.915, "s": 0.10, "o": 0.9},
}
const LABELS := {
	"joystick": "MOVE", "fire_r": "FIRE", "fire_l": "FIRE L", "scope": "SCOPE", "jump": "JUMP",
	"crouch": "CROUCH", "reload": "RELOAD", "medkit": "HEAL", "shield": "WALL", "grenade": "GRENADE",
	"weapons": "WEAPONS",
}


static func resolve(overrides: Dictionary) -> Dictionary:
	var out := {}
	for id in DEFAULTS:
		var d: Dictionary = DEFAULTS[id].duplicate()
		var o: Variant = overrides.get(id)
		if o is Dictionary:
			for k in ["x", "y", "s", "o"]:
				if (o as Dictionary).has(k):
					d[k] = float(o[k])
		d.x = clampf(d.x, 0.02, 0.98)
		d.y = clampf(d.y, 0.04, 0.98)
		d.s = clampf(d.s, 0.04, 0.45)
		d.o = clampf(d.o, 0.15, 1.0)
		out[id] = d
	return out


static func current() -> Dictionary:
	return resolve(Game.hud_layout)


static func center(w: Dictionary, vs: Vector2) -> Vector2:
	return Vector2(float(w.x) * vs.x, float(w.y) * vs.y)


static func radius(w: Dictionary, vs: Vector2) -> float:
	return float(w.s) * vs.y * 0.5


## Rects of the three weapon slots for the "weapons" widget.
static func weapon_slots(w: Dictionary, vs: Vector2) -> Array[Rect2]:
	var h := float(w.s) * vs.y * 0.82
	var wd := float(w.s) * vs.y * 1.8
	var gap := 8.0
	var c := center(w, vs)
	var total := wd * 3.0 + gap * 2.0
	var out: Array[Rect2] = []
	for i in 3:
		out.append(Rect2(Vector2(c.x - total * 0.5 + i * (wd + gap), c.y - h * 0.5), Vector2(wd, h)))
	return out


static func hit_rect(id: String, w: Dictionary, vs: Vector2) -> Rect2:
	if id == "weapons":
		var slots := weapon_slots(w, vs)
		return slots[0].merge(slots[2])
	var r := radius(w, vs)
	var c := center(w, vs)
	return Rect2(c - Vector2(r, r), Vector2(r, r) * 2.0)
