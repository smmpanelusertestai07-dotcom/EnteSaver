class_name Weapons
extends RefCounted
## Weapon data and shared ballistic helpers. Lone Wolf rules: before the round one gun is
## picked and BOTH fighters get it (plus fists). The guns follow the classic mobile battle-royale
## roster and its numbers (2026 public stat guides): rifles kill in 7-8 body shots or 3 to the
## head, the lever shotgun in two shells, the hand cannon and the bolt rifle one-tap the head;
## the names are generic designations or our own, the models are ours.
##
## Damage = base x zone (head / body / limb) x range falloff x armour. Arms count as body; legs
## and feet ("limb") take less. Each gun comes with fixed attachments (`attach`, shown at the
## pick); their effect is already in its numbers. `pen` is the share of armour a gun ignores.

const DEFS := {
	"ar": {
		"name": "M4A1", "class": "AR", "icon": "weapon_ar", "model": "weapon_ar", "sound": "ar_shot",
		"damage": 40.0, "min_damage": 24.0, "falloff_start": 30.0, "range": 80.0,
		"head_mult": 2.6, "head_far_mult": 1.0, "limb_mult": 0.75, "pen": 0.0,
		"interval": 0.1, "auto": true, "mag": 30, "reserve": 120,
		"reload": 2.3, "pellets": 1, "spread_hip": 1.1, "spread_ads": 0.25, "spread_move": 1.1, "spread_air": 4.0,
		"spread_per_shot": 0.22, "spread_max": 2.6, "spread_recover": 8.5,
		"recoil_v": 0.2, "recoil_h": 0.1, "recoil_ramp": 0.03, "scope": "reddot", "ads_fov": 50.0,
		"move": 0.92, "fire_move": 0.85, "equip": 0.35, "assist": 1.0, "crosshair": "ring",
		"attach": ["MUZZLE", "FOREGRIP", "STOCK"],
	},
	"smg": {
		"name": "MP40", "class": "SMG", "icon": "weapon_smg", "model": "weapon_smg", "sound": "smg_shot",
		"damage": 34.0, "min_damage": 12.0, "falloff_start": 6.0, "range": 25.0,
		"head_mult": 2.2, "head_far_mult": 0.8, "limb_mult": 0.75, "pen": 0.0,
		"interval": 0.07, "auto": true, "mag": 20, "reserve": 100,
		"reload": 1.9, "pellets": 1, "spread_hip": 2.0, "spread_ads": 0.8, "spread_move": 0.8, "spread_air": 3.0,
		"spread_per_shot": 0.35, "spread_max": 4.0, "spread_recover": 9.0,
		"recoil_v": 0.17, "recoil_h": 0.16, "recoil_ramp": 0.015, "scope": "reddot", "ads_fov": 56.0,
		"move": 0.98, "fire_move": 0.95, "equip": 0.3, "assist": 1.15, "crosshair": "ring",
		"attach": ["MUZZLE", "FOREGRIP"],
	},
	"lever": {
		"name": "M1887", "class": "SG", "icon": "weapon_sg_lever", "model": "weapon_sg", "sound": "sg_shot",
		"damage": 20.0, "min_damage": 6.0, "falloff_start": 4.0, "range": 15.0,
		"head_mult": 2.2, "head_far_mult": 0.8, "limb_mult": 0.8, "pen": 0.0,
		"interval": 0.32, "auto": false, "mag": 2, "reserve": 24,
		"reload": 2.2, "pellets": 8, "spread_hip": 2.4, "spread_ads": 1.8, "spread_move": 1.0, "spread_air": 2.5,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 1.3, "recoil_h": 0.4, "recoil_ramp": 0.0, "scope": "none", "ads_fov": 58.0,
		"move": 0.93, "fire_move": 0.85, "equip": 0.45, "assist": 1.2, "crosshair": "wide",
		"tint": Color(0.75, 0.55, 0.35), "attach": [],
	},
	"sg": {
		"name": "M1014", "class": "SG", "icon": "weapon_sg", "model": "weapon_sg", "sound": "sg_shot",
		"damage": 14.0, "min_damage": 5.0, "falloff_start": 3.5, "range": 13.0,
		"head_mult": 2.0, "head_far_mult": 0.8, "limb_mult": 0.8, "pen": 0.0,
		"interval": 0.28, "auto": false, "mag": 6, "reserve": 30,
		"reload": 3.0, "pellets": 8, "spread_hip": 4.2, "spread_ads": 3.2, "spread_move": 1.0, "spread_air": 2.5,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 1.0, "recoil_h": 0.35, "recoil_ramp": 0.0, "scope": "none", "ads_fov": 58.0,
		"move": 0.92, "fire_move": 0.85, "equip": 0.45, "assist": 1.2, "crosshair": "wide",
		"attach": ["STOCK"],
	},
	"pistol": {
		"name": "HAWK .50", "class": "PISTOL", "icon": "weapon_pistol", "model": "weapon_pistol", "sound": "pistol_shot",
		"damage": 90.0, "min_damage": 45.0, "falloff_start": 15.0, "range": 50.0,
		"head_mult": 4.0, "head_far_mult": 1.0, "limb_mult": 0.75, "pen": 0.0,
		"interval": 0.45, "auto": false, "mag": 7, "reserve": 35,
		"reload": 1.9, "pellets": 1, "spread_hip": 1.4, "spread_ads": 0.3, "spread_move": 1.0, "spread_air": 3.0,
		"spread_per_shot": 1.0, "spread_max": 3.0, "spread_recover": 7.0,
		"recoil_v": 1.1, "recoil_h": 0.25, "recoil_ramp": 0.0, "scope": "reddot", "ads_fov": 58.0,
		"move": 0.96, "fire_move": 0.9, "equip": 0.25, "assist": 1.0, "crosshair": "ring",
		"attach": [],
	},
	"sniper": {
		"name": "FALCON SR", "class": "SNIPER", "icon": "weapon_sniper", "model": "weapon_sniper", "sound": "sniper_shot",
		"damage": 150.0, "min_damage": 120.0, "falloff_start": 60.0, "range": 150.0,
		"head_mult": 3.0, "head_far_mult": 1.0, "limb_mult": 0.8, "pen": 0.4,
		"interval": 1.4, "auto": false, "mag": 5, "reserve": 20,
		"reload": 2.8, "pellets": 1, "spread_hip": 6.0, "spread_ads": 0.0, "spread_move": 3.0, "spread_air": 8.0,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 2.4, "recoil_h": 0.3, "recoil_ramp": 0.0, "scope": "sniper", "ads_fov": 14.0,
		"move": 0.9, "fire_move": 0.6, "equip": 0.6, "assist": 0.5, "crosshair": "dot",
		"attach": ["SCOPE 8X", "MAGAZINE"],
	},
	"ak": {
		"name": "AK47", "class": "AR", "icon": "weapon_ar", "model": "weapon_ar", "sound": "ar_shot", "pitch": 0.88,
		"damage": 46.0, "min_damage": 26.0, "falloff_start": 28.0, "range": 75.0,
		"head_mult": 2.5, "head_far_mult": 1.0, "limb_mult": 0.75, "pen": 0.0,
		"interval": 0.12, "auto": true, "mag": 30, "reserve": 120,
		"reload": 2.5, "pellets": 1, "spread_hip": 1.4, "spread_ads": 0.35, "spread_move": 1.3, "spread_air": 4.5,
		"spread_per_shot": 0.3, "spread_max": 3.4, "spread_recover": 7.5,
		"recoil_v": 0.3, "recoil_h": 0.16, "recoil_ramp": 0.04, "scope": "reddot", "ads_fov": 50.0,
		"move": 0.9, "fire_move": 0.82, "equip": 0.38, "assist": 1.0, "crosshair": "ring",
		"tint": Color(0.82, 0.62, 0.42), "attach": ["MUZZLE", "FOREGRIP"],
	},
	"groza": {
		"name": "GROZA", "class": "AR", "icon": "weapon_ar", "model": "weapon_ar", "sound": "ar_shot", "pitch": 0.94,
		"damage": 44.0, "min_damage": 24.0, "falloff_start": 25.0, "range": 70.0,
		"head_mult": 2.5, "head_far_mult": 1.0, "limb_mult": 0.75, "pen": 0.25,
		"interval": 0.1, "auto": true, "mag": 30, "reserve": 120,
		"reload": 2.6, "pellets": 1, "spread_hip": 1.3, "spread_ads": 0.3, "spread_move": 1.3, "spread_air": 4.5,
		"spread_per_shot": 0.26, "spread_max": 3.0, "spread_recover": 8.0,
		"recoil_v": 0.26, "recoil_h": 0.12, "recoil_ramp": 0.035, "scope": "reddot", "ads_fov": 50.0,
		"move": 0.88, "fire_move": 0.8, "equip": 0.4, "assist": 1.0, "crosshair": "ring",
		"tint": Color(0.62, 0.66, 0.6), "attach": ["MUZZLE", "FOREGRIP", "SCOPE 2X"],
	},
	"bizon": {
		"name": "BIZON", "class": "SMG", "icon": "weapon_smg", "model": "weapon_smg", "sound": "smg_shot", "pitch": 0.93,
		"damage": 28.0, "min_damage": 12.0, "falloff_start": 8.0, "range": 30.0,
		"head_mult": 2.2, "head_far_mult": 0.8, "limb_mult": 0.75, "pen": 0.0,
		"interval": 0.075, "auto": true, "mag": 50, "reserve": 150,
		"reload": 2.6, "pellets": 1, "spread_hip": 1.8, "spread_ads": 0.7, "spread_move": 0.8, "spread_air": 3.0,
		"spread_per_shot": 0.3, "spread_max": 3.6, "spread_recover": 9.0,
		"recoil_v": 0.15, "recoil_h": 0.12, "recoil_ramp": 0.012, "scope": "reddot", "ads_fov": 56.0,
		"move": 0.96, "fire_move": 0.93, "equip": 0.32, "assist": 1.15, "crosshair": "ring",
		"tint": Color(0.6, 0.6, 0.66), "attach": ["MUZZLE", "STOCK"],
	},
	"m1917": {
		"name": "M1917", "class": "PISTOL", "icon": "weapon_pistol", "model": "weapon_pistol", "sound": "pistol_shot", "pitch": 0.9,
		"damage": 72.0, "min_damage": 36.0, "falloff_start": 12.0, "range": 40.0,
		"head_mult": 3.4, "head_far_mult": 1.0, "limb_mult": 0.75, "pen": 0.0,
		"interval": 0.38, "auto": false, "mag": 6, "reserve": 36,
		"reload": 2.6, "pellets": 1, "spread_hip": 1.3, "spread_ads": 0.3, "spread_move": 1.0, "spread_air": 3.0,
		"spread_per_shot": 0.8, "spread_max": 2.6, "spread_recover": 7.5,
		"recoil_v": 0.9, "recoil_h": 0.22, "recoil_ramp": 0.0, "scope": "reddot", "ads_fov": 58.0,
		"move": 0.97, "fire_move": 0.92, "equip": 0.25, "assist": 1.0, "crosshair": "ring",
		"tint": Color(0.78, 0.72, 0.62), "attach": ["FOREGRIP", "STOCK"],
	},
	"sks": {
		"name": "SKS", "class": "DMR", "icon": "weapon_sniper", "model": "weapon_sniper", "sound": "sniper_shot", "pitch": 1.15,
		"damage": 82.0, "min_damage": 60.0, "falloff_start": 40.0, "range": 100.0,
		"head_mult": 2.6, "head_far_mult": 1.0, "limb_mult": 0.8, "pen": 0.1,
		"interval": 0.32, "auto": false, "mag": 10, "reserve": 40,
		"reload": 2.4, "pellets": 1, "spread_hip": 2.0, "spread_ads": 0.15, "spread_move": 1.5, "spread_air": 5.0,
		"spread_per_shot": 0.6, "spread_max": 2.5, "spread_recover": 7.0,
		"recoil_v": 0.7, "recoil_h": 0.18, "recoil_ramp": 0.0, "scope": "reddot", "ads_fov": 40.0,
		"move": 0.9, "fire_move": 0.75, "equip": 0.45, "assist": 0.8, "crosshair": "ring",
		"tint": Color(0.8, 0.6, 0.42), "attach": ["SCOPE 2X", "MUZZLE"],
	},
	"kar98k": {
		"name": "KAR98K", "class": "SNIPER", "icon": "weapon_sniper", "model": "weapon_sniper", "sound": "sniper_shot", "pitch": 1.05,
		"damage": 120.0, "min_damage": 100.0, "falloff_start": 50.0, "range": 130.0,
		"head_mult": 3.2, "head_far_mult": 1.0, "limb_mult": 0.8, "pen": 0.0,
		"interval": 1.3, "auto": false, "mag": 5, "reserve": 20,
		"reload": 2.7, "pellets": 1, "spread_hip": 5.5, "spread_ads": 0.0, "spread_move": 3.0, "spread_air": 8.0,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 2.0, "recoil_h": 0.3, "recoil_ramp": 0.0, "scope": "sniper", "ads_fov": 14.0,
		"move": 0.92, "fire_move": 0.6, "equip": 0.55, "assist": 0.5, "crosshair": "dot",
		"tint": Color(0.72, 0.5, 0.32), "attach": ["SCOPE 8X"],
	},
	"fists": {
		"name": "FISTS", "class": "MELEE", "icon": "v_fist", "model": "", "sound": "hit_body",
		"damage": 30.0, "min_damage": 30.0, "falloff_start": 2.0, "range": 2.0,
		"head_mult": 1.5, "head_far_mult": 1.0, "limb_mult": 0.8, "pen": 0.0,
		"interval": 0.45, "auto": true, "mag": -1, "reserve": -1,
		"reload": 0.0, "pellets": 1, "spread_hip": 0.0, "spread_ads": 0.0, "spread_move": 0.0, "spread_air": 0.0,
		"spread_per_shot": 0.0, "spread_max": 0.0, "spread_recover": 8.0,
		"recoil_v": 0.0, "recoil_h": 0.0, "recoil_ramp": 0.0, "scope": "none", "ads_fov": 68.0,
		"move": 1.0, "fire_move": 1.0, "equip": 0.2, "assist": 1.0, "crosshair": "dot",
		"melee": true, "attach": [],
	},
}
## Order of the weapon-pick grid (the classic picks first).
const PICKABLE := ["ar", "smg", "lever", "sg", "pistol", "sniper", "ak", "groza", "bizon", "m1917", "sks", "kar98k"]
const DEFAULT_PICK := "ar"

## Armour (Lone Wolf gives level 2 of both every round): the share of damage each one stops.
const HELMET_REDUCTION := 0.35
const VEST_REDUCTION := 0.35


static func damage_at(def: Dictionary, base: float, dist: float) -> float:
	var r: float = def.range
	var fs: float = def.falloff_start
	if dist <= fs:
		return base
	var t := clampf((dist - fs) / maxf(r - fs, 0.001), 0.0, 1.0)
	return lerpf(base, base * float(def.min_damage) / float(def.damage), t)


## Part multiplier: head x head_mult, legs and feet x limb_mult, the rest (arms too) x 1. The
## headshot bonus of SMGs and shotguns decays with distance (to head_far_mult of itself at the
## end of the range).
static func zone_mult(def: Dictionary, zone: String, dist := 0.0) -> float:
	if zone == "limb":
		return float(def.get("limb_mult", 1.0))
	if zone != "head":
		return 1.0
	var far := clampf((dist - float(def.falloff_start)) / maxf(float(def.range) - float(def.falloff_start), 0.001), 0.0, 1.0)
	return float(def.head_mult) * lerpf(1.0, float(def.head_far_mult), far)


## Armour penetration as a damage factor before the armour: the target's armour then stops
## only (1 - pen) of its share (the hit is sent before the armour, so both phones agree).
static func pen_mult(def: Dictionary, zone: String) -> float:
	var pen := clampf(float(def.get("pen", 0.0)), 0.0, 1.0)
	if pen <= 0.0 or zone == "zone" or zone == "fall":
		return 1.0
	var r := HELMET_REDUCTION if zone == "head" else VEST_REDUCTION
	return (1.0 - r * (1.0 - pen)) / maxf(1.0 - r, 0.01)


## The pick card's bars, 0..1: damage per second, damage per hit, range, accuracy, speed.
static func bars(def: Dictionary) -> Dictionary:
	var hit := float(def.damage) * int(def.pellets)
	return {
		"DAMAGE": clampf(hit / 160.0, 0.08, 1.0),
		"RATE": clampf(0.07 / float(def.interval), 0.05, 1.0),
		"RANGE": clampf(float(def.range) / 120.0, 0.08, 1.0),
		"ACCURACY": clampf(1.0 - float(def.spread_hip) / 6.5, 0.08, 1.0),
		"SPEED": clampf((float(def.move) - 0.84) / 0.14, 0.08, 1.0),
	}


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
