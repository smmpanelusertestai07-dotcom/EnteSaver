class_name Weapons
extends RefCounted
## Weapon data (Lone Wolf fixed loadout) and shared ballistic helpers.

const DEFS := {
	"ar": {
		"name": "VIPER AR", "slot": 0, "damage": 32.0, "head_mult": 2.1, "limb_mult": 0.85,
		"interval": 0.105, "mag": 30, "reload": 2.1, "range": 90.0, "falloff_start": 28.0, "falloff_min": 0.62,
		"pellets": 1, "spread_hip": 1.5, "spread_ads": 0.35, "spread_move": 1.3, "spread_air": 4.0,
		"spread_per_shot": 0.28, "spread_max": 3.6, "spread_recover": 8.0,
		"recoil_v": 0.55, "recoil_h": 0.3, "recoil_ramp": 0.07, "ads_fov": 50.0,
		"sound": "ar_shot", "model": "weapon_ar", "equip": 0.35,
	},
	"sg": {
		"name": "THUNDER SG", "slot": 1, "damage": 21.0, "head_mult": 1.6, "limb_mult": 0.85,
		"interval": 0.85, "mag": 6, "reload": 2.4, "range": 26.0, "falloff_start": 7.0, "falloff_min": 0.2,
		"pellets": 8, "spread_hip": 5.2, "spread_ads": 3.6, "spread_move": 1.0, "spread_air": 2.5,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 3.0, "recoil_h": 0.9, "recoil_ramp": 0.0, "ads_fov": 56.0,
		"sound": "sg_shot", "model": "weapon_sg", "equip": 0.45,
	},
	"pistol": {
		"name": "HAWK P9", "slot": 2, "damage": 34.0, "head_mult": 2.0, "limb_mult": 0.85,
		"interval": 0.24, "mag": 12, "reload": 1.4, "range": 60.0, "falloff_start": 20.0, "falloff_min": 0.6,
		"pellets": 1, "spread_hip": 1.3, "spread_ads": 0.4, "spread_move": 1.0, "spread_air": 3.0,
		"spread_per_shot": 0.45, "spread_max": 2.5, "spread_recover": 9.0,
		"recoil_v": 1.15, "recoil_h": 0.45, "recoil_ramp": 0.0, "ads_fov": 54.0,
		"sound": "pistol_shot", "model": "weapon_pistol", "equip": 0.25,
	},
}
const LOADOUT := ["ar", "sg", "pistol"]


static func damage_at(def: Dictionary, base: float, dist: float) -> float:
	var r: float = def.range
	var fs: float = def.falloff_start
	if dist <= fs:
		return base
	var t := clampf((dist - fs) / maxf(r - fs, 0.001), 0.0, 1.0)
	return base * lerpf(1.0, def.falloff_min, t)


static func zone_mult(def: Dictionary, zone: String) -> float:
	match zone:
		"head":
			return def.head_mult
		"limb":
			return def.limb_mult
	return 1.0


## Random direction inside a cone of `angle_deg` (uniform over the disc) around `forward`.
static func spread_dir(forward: Vector3, angle_deg: float, rng: RandomNumberGenerator) -> Vector3:
	if angle_deg <= 0.001:
		return forward
	var a := deg_to_rad(angle_deg) * sqrt(rng.randf())
	var phi := rng.randf() * TAU
	var up := Vector3.UP if absf(forward.y) < 0.98 else Vector3.FORWARD
	var basis := Basis.looking_at(forward, up)
	var local := Vector3(sin(a) * cos(phi), sin(a) * sin(phi), -cos(a))
	return (basis * local).normalized()


## Final damage after armor for a hit zone (vest/helmet reduce damage by a fraction).
static func after_armor(amount: float, zone: String, vest: float, helmet: float) -> float:
	if zone == "zone":
		return amount
	return amount * (1.0 - (helmet if zone == "head" else vest))
