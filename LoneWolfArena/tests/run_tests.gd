extends Node
## Unit tests for the pure gameplay logic. Run:
##   godot --headless --path . -s res://tests/run_tests.gd

var _fails := 0
var _passes := 0


func _check(cond: bool, what: String) -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
		print("FAIL: ", what)


func _near(a: float, b: float, what: String, eps := 0.001) -> void:
	_check(absf(a - b) <= eps, "%s (got %f, want %f)" % [what, a, b])


func _ready() -> void:
	_test_damage()
	_test_spread()
	_test_weapon_state()
	_test_hud_layout()
	print("TESTS: %d passed, %d failed" % [_passes, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _test_damage() -> void:
	var ar: Dictionary = Weapons.DEFS.ar
	_near(Weapons.damage_at(ar, 32.0, 10.0), 32.0, "AR no falloff inside falloff_start")
	_near(Weapons.damage_at(ar, 32.0, 90.0), 32.0 * 0.62, "AR min damage at max range")
	_check(Weapons.damage_at(ar, 32.0, 50.0) < 32.0 and Weapons.damage_at(ar, 32.0, 50.0) > 32.0 * 0.62, "AR falloff in between")
	_near(Weapons.zone_mult(ar, "head"), 2.1, "head multiplier")
	_near(Weapons.zone_mult(ar, "limb"), 0.85, "limb multiplier")
	_near(Weapons.zone_mult(ar, "body"), 1.0, "body multiplier")
	_near(Weapons.after_armor(100.0, "body", 0.3, 0.35), 70.0, "vest reduces 30%")
	_near(Weapons.after_armor(100.0, "head", 0.3, 0.35), 65.0, "helmet reduces 35%")
	_near(Weapons.after_armor(10.0, "zone", 0.3, 0.35), 10.0, "zone ignores armor")
	# Time-to-kill sanity: AR body shots needed to kill 200 HP through a vest.
	var per_hit := Weapons.after_armor(32.0, "body", 0.3, 0.35)
	var hits := ceili(200.0 / per_hit)
	_check(hits >= 8 and hits <= 11, "AR body hits to kill in 8..11 (got %d)" % hits)
	var sg: Dictionary = Weapons.DEFS.sg
	var sg_full := Weapons.after_armor(float(sg.damage) * int(sg.pellets), "body", 0.3, 0.35)
	_check(sg_full > 100.0 and sg_full < 200.0, "shotgun point blank body = 2-shot kill")


func _test_spread() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var fwd := Vector3(0.3, -0.1, -1.0).normalized()
	var max_ang := 0.0
	for i in 500:
		var d := Weapons.spread_dir(fwd, 3.0, rng)
		_check(d.is_normalized(), "spread dir normalized")
		max_ang = maxf(max_ang, rad_to_deg(fwd.angle_to(d)))
	_check(max_ang <= 3.0001, "spread stays inside 3 deg cone (max %f)" % max_ang)
	_check(max_ang > 2.0, "spread uses the cone (max %f)" % max_ang)
	_check(Weapons.spread_dir(fwd, 0.0, rng).is_equal_approx(fwd), "zero spread keeps direction")
	var up := Weapons.spread_dir(Vector3.UP, 2.0, rng)
	_check(up.is_normalized(), "spread works straight up")


func _test_weapon_state() -> void:
	var w := WeaponState.new("ar")
	_check(w.ammo == 30 and w.can_fire(), "AR starts full")
	w.on_fire()
	_check(w.ammo == 29 and not w.can_fire(), "cooldown after shot")
	w.tick(0.11)
	_check(w.can_fire(), "can fire after interval")
	_check(w.bloom > 0.0, "bloom grows")
	for i in 40:
		w.on_fire()
	_check(w.bloom <= float(w.def.spread_max) + 0.0001, "bloom capped")
	w.ammo = 0
	_check(not w.can_fire(), "empty mag can't fire")
	_check(w.start_reload(), "reload starts")
	_check(not w.start_reload(), "reload not restarted")
	var done := false
	for i in 30:
		if w.tick(0.1):
			done = true
	_check(done and w.ammo == 30 and not w.reloading, "reload completes and refills")
	_check(not w.start_reload(), "full mag doesn't reload")
	var p := WeaponState.new("pistol")
	p.on_fire()
	p.tick(1.0)
	_check(p.bloom == 0.0 and p.burst == 0, "bloom/burst recover")


func _test_hud_layout() -> void:
	var lay := HudLayout.resolve({"fire_r": {"x": 2.0, "y": -1.0, "s": 9.0, "o": 0.0}, "bogus": {}})
	_check(lay.has("fire_r") and not lay.has("bogus"), "layout keeps only known widgets")
	_check(lay.fire_r.x <= 0.98 and lay.fire_r.y >= 0.04, "layout clamps position")
	_check(lay.fire_r.s <= 0.45 and lay.fire_r.o >= 0.15, "layout clamps size/opacity")
	var vs := Vector2(1280, 720)
	var slots := HudLayout.weapon_slots(lay.weapons, vs)
	_check(slots.size() == 3 and slots[0].end.x < slots[1].position.x, "three non-overlapping weapon slots")
	for id in HudLayout.DEFAULTS:
		var r := HudLayout.hit_rect(id, HudLayout.resolve({})[id], vs)
		_check(Rect2(Vector2.ZERO, vs).encloses(r) or id == "joystick", "default %s fits on a 16:9 screen" % id)
	var tall := HudLayout.resolve({})
	var wide := Vector2(1560, 720)
	_check(HudLayout.center(tall.fire_r, wide).x > 1200.0, "layout scales to wide (19.5:9) screens")
