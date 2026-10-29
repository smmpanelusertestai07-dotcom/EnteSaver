class_name Weapons
extends RefCounted
## Weapon data and shared ballistic helpers. Lone Wolf rules: before the round one gun is
## picked and BOTH fighters get it (plus fists). Stats follow the classic mobile battle-royale
## gun classes (hand cannon one-taps the head, lever shotgun two shells, ...); names and models
## are our own. Damage = base x part x range falloff x (1 - armour).

const DEFS := {
	"ar": {
		"name": "VIPER AR", "class": "AR", "icon": "weapon_ar", "model": "weapon_ar", "sound": "ar_shot",
		"damage": 32.0, "min_damage": 18.0, "falloff_start": 30.0, "range": 80.0,
		"head_mult": 4.0, "head_far_mult": 1.0, "interval": 0.10, "auto": true, "mag": 30, "reserve": 120,
		"reload": 2.4, "pellets": 1, "spread_hip": 1.2, "spread_ads": 0.3, "spread_move": 1.2, "spread_air": 4.0,
		"spread_per_shot": 0.25, "spread_max": 3.0, "spread_recover": 8.0,
		"recoil_v": 0.22, "recoil_h": 0.12, "recoil_ramp": 0.03, "scope": "reddot", "ads_fov": 50.0,
		"move": 0.92, "fire_move": 0.85, "equip": 0.35, "assist": 1.0, "crosshair": "ring",
	},
	"smg": {
		"name": "WASP SMG", "class": "SMG", "icon": "weapon_smg", "model": "weapon_smg", "sound": "smg_shot",
		"damage": 26.0, "min_damage": 12.0, "falloff_start": 8.0, "range": 30.0,
		"head_mult": 3.5, "head_far_mult": 0.8, "interval": 0.075, "auto": true, "mag": 20, "reserve": 100,
		"reload": 2.3, "pellets": 1, "spread_hip": 2.0, "spread_ads": 0.8, "spread_move": 0.8, "spread_air": 3.0,
		"spread_per_shot": 0.35, "spread_max": 4.0, "spread_recover": 9.0,
		"recoil_v": 0.18, "recoil_h": 0.15, "recoil_ramp": 0.015, "scope": "reddot", "ads_fov": 56.0,
		"move": 0.98, "fire_move": 0.95, "equip": 0.3, "assist": 1.15, "crosshair": "ring",
	},
	"sg": {
		"name": "THUNDER SG", "class": "SG", "icon": "weapon_sg", "model": "weapon_sg", "sound": "sg_shot",
		"damage": 21.0, "min_damage": 6.0, "falloff_start": 3.0, "range": 12.0,
		"head_mult": 3.0, "head_far_mult": 0.8, "interval": 0.45, "auto": false, "mag": 6, "reserve": 30,
		"reload": 3.0, "pellets": 8, "spread_hip": 5.0, "spread_ads": 3.8, "spread_move": 1.0, "spread_air": 2.5,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 1.2, "recoil_h": 0.4, "recoil_ramp": 0.0, "scope": "none", "ads_fov": 58.0,
		"move": 0.92, "fire_move": 0.85, "equip": 0.45, "assist": 1.2, "crosshair": "wide",
	},
	"lever": {
		"name": "M1887", "class": "SG", "icon": "weapon_sg_lever", "model": "weapon_sg", "sound": "sg_shot",
		"damage": 26.0, "min_damage": 6.0, "falloff_start": 4.0, "range": 15.0,
		"head_mult": 3.0, "head_far_mult": 0.8, "interval": 0.35, "auto": false, "mag": 2, "reserve": 24,
		"reload": 2.2, "pellets": 8, "spread_hip": 2.4, "spread_ads": 1.8, "spread_move": 1.0, "spread_air": 2.5,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 1.3, "recoil_h": 0.4, "recoil_ramp": 0.0, "scope": "none", "ads_fov": 58.0,
		"move": 0.93, "fire_move": 0.85, "equip": 0.45, "assist": 1.2, "crosshair": "wide",
		"tint": Color(0.75, 0.55, 0.35),
	},
	"pistol": {
		"name": "HAWK .50", "class": "PISTOL", "icon": "weapon_pistol", "model": "weapon_pistol", "sound": "pistol_shot",
		"damage": 90.0, "min_damage": 45.0, "falloff_start": 15.0, "range": 50.0,
		"head_mult": 5.5, "head_far_mult": 1.0, "interval": 0.45, "auto": false, "mag": 7, "reserve": 35,
		"reload": 1.9, "pellets": 1, "spread_hip": 1.4, "spread_ads": 0.3, "spread_move": 1.0, "spread_air": 3.0,
		"spread_per_shot": 1.0, "spread_max": 3.0, "spread_recover": 7.0,
		"recoil_v": 1.1, "recoil_h": 0.25, "recoil_ramp": 0.0, "scope": "reddot", "ads_fov": 58.0,
		"move": 0.96, "fire_move": 0.9, "equip": 0.25, "assist": 1.0, "crosshair": "ring",
	},
	"sniper": {
		"name": "FALCON SR", "class": "SNIPER", "icon": "weapon_sniper", "model": "weapon_sniper", "sound": "sniper_shot",
		"damage": 150.0, "min_damage": 120.0, "falloff_start": 60.0, "range": 150.0,
		"head_mult": 5.5, "head_far_mult": 1.0, "interval": 1.4, "auto": false, "mag": 5, "reserve": 20,
		"reload": 2.8, "pellets": 1, "spread_hip": 6.0, "spread_ads": 0.0, "spread_move": 3.0, "spread_air": 8.0,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 2.4, "recoil_h": 0.3, "recoil_ramp": 0.0, "scope": "sniper", "ads_fov": 14.0,
		"move": 0.93, "fire_move": 0.6, "equip": 0.6, "assist": 0.5, "crosshair": "dot",
	},
	"fists": {
		"name": "FISTS", "class": "MELEE", "icon": "v_fist", "model": "", "sound": "hit_body",
		"damage": 25.0, "min_damage": 25.0, "falloff_start": 2.0, "range": 2.0,
		"head_mult": 1.5, "head_far_mult": 1.0, "interval": 0.45, "auto": true, "mag": -1, "reserve": -1,
		"reload": 0.0, "pellets": 1, "spread_hip": 0.0, "spread_ads": 0.0, "spread_move": 0.0, "spread_air": 0.0,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 0.0, "recoil_h": 0.0, "recoil_ramp": 0.0, "scope": "none", "ads_fov": 68.0,
		"move": 1.0, "fire_move": 1.0, "equip": 0.2, "assist": 1.0, "crosshair": "dot",
		"melee": true,
	},
}
## Order of the weapon-pick grid.
const PICKABLE := ["ar", "smg", "sg", "lever", "pistol", "sniper"]
const DEFAULT_PICK := "ar"

## Armour (Lone Wolf gives level 2 of both every round).
const HELMET_REDUCTION := 0.45
const VEST_REDUCTION := 0.50


static func damage_at(def: Dictionary, base: float, dist: float) -> float:
	var r: float = def.range
	var fs: float = def.falloff_start
	if dist <= fs:
		return base
	var t := clampf((dist - fs) / maxf(r - fs, 0.001), 0.0, 1.0)
	return lerpf(base, base * float(def.min_damage) / float(def.damage), t)


## Part multiplier. Limbs count as body (no limb penalty); the headshot bonus of SMGs and
## shotguns decays with distance (to head_far_mult of itself at the end of the range).
static func zone_mult(def: Dictionary, zone: String, dist := 0.0) -> float:
	if zone != "head":
		return 1.0
	var far := clampf((dist - float(def.falloff_start)) / maxf(float(def.range) - float(def.falloff_start), 0.001), 0.0, 1.0)
	return float(def.head_mult) * lerpf(1.0, float(def.head_far_mult), far)


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


## Final damage after armour for a hit zone (vest/helmet reduce damage by a fraction).
static func after_armor(amount: float, zone: String, vest: float, helmet: float) -> float:
	if zone == "zone" or zone == "fall":
		return amount
	return amount * (1.0 - (helmet if zone == "head" else vest))


static func is_melee(def: Dictionary) -> bool:
	return bool(def.get("melee", false))
