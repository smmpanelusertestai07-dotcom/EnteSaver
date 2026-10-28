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
	_test_guard()
	_test_apk_signature()
	_test_settings_sanitize()
	print("TESTS: %d passed, %d failed" % [_passes, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _test_damage() -> void:
	var ar: Dictionary = Weapons.DEFS.ar
	_near(Weapons.damage_at(ar, 32.0, 10.0), 32.0, "AR no falloff inside falloff_start")
	_near(Weapons.damage_at(ar, 32.0, 80.0), 18.0, "AR min damage at max range")
	_check(Weapons.damage_at(ar, 32.0, 50.0) < 32.0 and Weapons.damage_at(ar, 32.0, 50.0) > 18.0, "AR falloff in between")
	_near(Weapons.zone_mult(ar, "head"), 4.0, "AR head multiplier")
	_near(Weapons.zone_mult(ar, "limb"), 1.0, "limbs count as body")
	_near(Weapons.zone_mult(ar, "body"), 1.0, "body multiplier")
	var smg: Dictionary = Weapons.DEFS.smg
	_check(Weapons.zone_mult(smg, "head", 30.0) < Weapons.zone_mult(smg, "head", 5.0), "SMG headshot bonus decays with range")
	_near(Weapons.after_armor(100.0, "body", 0.5, 0.45), 50.0, "vest Lv2 halves body damage")
	_near(Weapons.after_armor(100.0, "head", 0.5, 0.45), 55.0, "helmet Lv2 takes 45%")
	_near(Weapons.after_armor(10.0, "zone", 0.5, 0.45), 10.0, "zone ignores armor")
	# Time-to-kill sanity through Lv2 armour (200 HP).
	var per_hit := Weapons.after_armor(32.0, "body", Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION)
	var hits := ceili(200.0 / per_hit)
	_check(hits >= 11 and hits <= 14, "AR body hits to kill 11..14 (got %d)" % hits)
	var ar_head := Weapons.after_armor(32.0 * Weapons.zone_mult(ar, "head"), "head", Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION)
	_check(ceili(200.0 / ar_head) == 3, "AR: 3 headshots kill")
	var p: Dictionary = Weapons.DEFS.pistol
	var p_head := Weapons.after_armor(90.0 * Weapons.zone_mult(p, "head"), "head", Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION)
	_check(p_head >= 200.0, "hand cannon headshot is a one-tap through a Lv2 helmet")
	var sg: Dictionary = Weapons.DEFS.sg
	var sg_full := Weapons.after_armor(float(sg.damage) * int(sg.pellets), "body", Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION)
	_check(sg_full > 66.0 and sg_full < 100.0, "shotgun point blank body = 3-shot kill")
	var sn: Dictionary = Weapons.DEFS.sniper
	_check(Weapons.after_armor(150.0 * Weapons.zone_mult(sn, "head"), "head", 0.5, 0.45) >= 200.0, "sniper headshot kills")
	for id in Weapons.PICKABLE:
		_check(Weapons.DEFS.has(id), "pickable weapon %s exists" % id)


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
	_check(w.ammo == 30 and w.reserve == 120 and w.can_fire(), "AR starts full with reserve")
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
	_check(w.reserve == 90, "reload takes ammo from the reserve (got %d)" % w.reserve)
	var f := WeaponState.new("fists")
	_check(f.infinite() and f.can_fire() and not f.start_reload(), "fists never run dry")
	_check(not w.start_reload(), "full mag doesn't reload")
	var pw := WeaponState.new("pistol")
	pw.on_fire()
	pw.tick(1.0)
	_check(pw.bloom == 0.0 and pw.burst == 0, "bloom/burst recover")


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


func _test_guard() -> void:
	var n := SecureNum.new(200.0)
	_near(n.value(), 200.0, "secure number keeps its value")
	n.set_value(n.value() - 37.5)
	_near(n.value(), 162.5, "secure number arithmetic")
	var flags_before := Guard.flags.size()
	n.set("_enc", int(n.get("_enc")) ^ 0x5A5A)
	_near(n.value(), 0.0, "tampered secure number reads as 0")
	_check(Guard.flags.has("memory"), "tampering is flagged")
	Guard.flags.resize(flags_before)
	var data := {"name": "ROOKIE", "xp": 1250, "wins": 3}
	var signed := Guard.sign_dict(data)
	_check(signed.has("_sig"), "profile gets a signature")
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(signed))
	_check(Guard.verify_dict(parsed).ok, "signature survives a JSON round trip (ints become floats)")
	parsed["xp"] = 999999
	_check(not Guard.verify_dict(parsed).ok, "edited profile is rejected")
	_check(Guard.verify_dict({"name": "OLD"}).unsigned, "old unsigned profile is accepted once")


func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b


func _u64(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(8)
	b.encode_u64(0, v)
	return b


func _lp(content: PackedByteArray) -> PackedByteArray:
	return _u32(content.size()) + content


## A minimal file with the APK layout: data, signing block (one v2 signer with `cert`),
## central directory, end-of-central-directory record.
func _fake_apk(cert: PackedByteArray, magic := "APK Sig Block 42") -> PackedByteArray:
	var signed := _lp(PackedByteArray()) + _lp(_lp(cert)) + _lp(PackedByteArray())
	var signer := _lp(signed) + _lp(PackedByteArray()) + _lp(PackedByteArray())
	var value := _lp(_lp(signer))
	var pair := _u64(4 + value.size()) + _u32(0x7109871a) + value
	var size := pair.size() + 8 + 16
	var block := _u64(size) + pair + _u64(size) + magic.to_ascii_buffer()
	var data := "local file data".to_ascii_buffer()
	var cd := "CDIR".to_ascii_buffer()
	var eocd := _u32(0x06054b50) + PackedByteArray([0, 0, 0, 0, 1, 0, 1, 0]) + _u32(cd.size()) \
		+ _u32(data.size() + block.size()) + PackedByteArray([0, 0])
	return data + block + cd + eocd


func _test_apk_signature() -> void:
	var cert := "fake X.509 certificate bytes".to_ascii_buffer()
	var path := OS.get_user_data_dir().path_join("test_fake.apk")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(_fake_apk(cert))
	f.close()
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(cert)
	var want := h.finish().hex_encode()
	var got := Guard.apk_signer_hashes(path)
	_check(got.size() == 1 and got[0] == want, "APK signing block: signer certificate hash is read")
	f = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(_fake_apk(cert, "APK Sig Block 41"))
	f.close()
	_check(Guard.apk_signer_hashes(path).is_empty(), "APK without a valid signing block gives no hash (unknown, allowed)")
	_check(Guard.apk_signer_hashes(path + ".missing").is_empty(), "unreadable APK gives no hash (unknown, allowed)")
	DirAccess.remove_absolute(path)
	var real := ProjectSettings.globalize_path("res://apk/LoneWolfArena.apk")
	if FileAccess.file_exists(real):
		var hashes := Guard.apk_signer_hashes(real)
		_check(hashes.size() >= 1 and hashes[0].length() == 64, "shipped APK's signer certificate is read")


func _test_settings_sanitize() -> void:
	var saved := Game.settings.duplicate(true)
	Game.settings.aim_assist_strength = 5000
	Game.settings.sens_general = -40
	Game.settings.difficulty = 9
	Game.settings.graphics = -1
	Game.settings.fps = 7
	Game.settings.last_pick = "railgun"
	Game._sanitize_settings()
	_check(Game.settings.aim_assist_strength == 100, "edited aim assist strength is clamped to 100")
	_check(Game.settings.sens_general == 1, "edited sensitivity is clamped to 1..200")
	_check(Game.settings.difficulty == 2 and Game.DIFFICULTY_NAMES.size() > Game.settings.difficulty, "difficulty stays a valid index")
	_check(Game.settings.graphics == 0, "graphics level clamped")
	_check(Game.settings.fps == 60, "unknown frame rate falls back to 60")
	_check(Game.settings.last_pick == Weapons.DEFAULT_PICK, "unknown weapon pick falls back to the default")
	Game.settings = saved
