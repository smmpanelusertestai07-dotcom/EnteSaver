class_name WeaponState
extends RefCounted
## Runtime state of one weapon (ammo, cooldown, reload, spread bloom).

var id: String
var def: Dictionary
var ammo: int
var cooldown := 0.0
var reloading := false
var reload_left := 0.0
var bloom := 0.0
var burst := 0
var since_shot := 99.0


func _init(weapon_id: String) -> void:
	id = weapon_id
	def = Weapons.DEFS[weapon_id]
	ammo = int(def.mag)


## Advances timers. Returns true when a reload finished during this tick.
func tick(delta: float) -> bool:
	cooldown = maxf(cooldown - delta, 0.0)
	since_shot += delta
	if since_shot > maxf(0.12, float(def.interval) * 1.2):
		bloom = maxf(bloom - float(def.spread_recover) * delta, 0.0)
	if since_shot > 0.3:
		burst = 0
	if reloading:
		reload_left -= delta
		if reload_left <= 0.0:
			reloading = false
			ammo = int(def.mag)
			return true
	return false


func start_reload() -> bool:
	if reloading or ammo >= int(def.mag):
		return false
	reloading = true
	reload_left = def.reload
	return true


func cancel_reload() -> void:
	reloading = false


func can_fire() -> bool:
	return not reloading and cooldown <= 0.0 and ammo > 0


func reload_progress() -> float:
	if not reloading:
		return 0.0
	return clampf(1.0 - reload_left / float(def.reload), 0.0, 1.0)


func on_fire() -> void:
	ammo -= 1
	cooldown = def.interval
	since_shot = 0.0
	burst += 1
	bloom = minf(bloom + def.spread_per_shot, def.spread_max)
