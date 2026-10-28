class_name WeaponState
extends RefCounted
## Runtime state of one weapon (magazine + reserve ammo, cooldown, reload, spread bloom).
## Melee weapons have mag = -1 (infinite, never reload).

var id: String
var def: Dictionary
var ammo: int:
	get:
		return int(_ammo.value())
	set(v):
		_ammo.set_value(v)
var reserve: int:
	get:
		return int(_reserve.value())
	set(v):
		_reserve.set_value(v)
var cooldown := 0.0
var reloading := false
var reload_left := 0.0
var bloom := 0.0
var burst := 0
var since_shot := 99.0
var _ammo := SecureNum.new(0)
var _reserve := SecureNum.new(0)


func _init(weapon_id: String) -> void:
	id = weapon_id
	def = Weapons.DEFS[weapon_id]
	ammo = int(def.mag)
	reserve = int(def.get("reserve", 0))


func infinite() -> bool:
	return int(def.mag) < 0


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
			var need := int(def.mag) - ammo
			var take := mini(need, reserve)
			ammo += take
			reserve -= take
			return true
	return false


func can_reload() -> bool:
	return not infinite() and not reloading and ammo < int(def.mag) and reserve > 0


func start_reload() -> bool:
	if not can_reload():
		return false
	reloading = true
	reload_left = def.reload
	return true


func cancel_reload() -> void:
	reloading = false


func can_fire() -> bool:
	return not reloading and cooldown <= 0.0 and (infinite() or ammo > 0)


func reload_progress() -> float:
	if not reloading:
		return 0.0
	return clampf(1.0 - reload_left / float(def.reload), 0.0, 1.0)


func on_fire() -> void:
	if not infinite():
		ammo -= 1
	cooldown = def.interval
	since_shot = 0.0
	burst += 1
	bloom = minf(bloom + def.spread_per_shot, def.spread_max)
