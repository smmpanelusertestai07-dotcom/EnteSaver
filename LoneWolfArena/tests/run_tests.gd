extends Node
## Unit tests for the pure gameplay logic. Run through the scene, so the autoloads exist:
##   godot --headless --path . res://tests/run_tests.tscn

const GuardCode := preload("res://autoload/guard.gd")     # its static helpers, without the autoload

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
	_test_signer_digests()
	_test_settings_sanitize()
	_test_honour()
	print("TESTS: %d passed, %d failed" % [_passes, _fails])
	get_tree().quit(1 if _fails > 0 else 0)


func _test_damage() -> void:
	var ar: Dictionary = Weapons.DEFS.ar
	_near(Weapons.damage_at(ar, 40.0, 10.0), 40.0, "AR no falloff inside falloff_start")
	_near(Weapons.damage_at(ar, 40.0, 80.0), 24.0, "AR min damage at max range")
	_check(Weapons.damage_at(ar, 40.0, 50.0) < 40.0 and Weapons.damage_at(ar, 40.0, 50.0) > 24.0, "AR falloff in between")
	_near(Weapons.zone_mult(ar, "head"), 2.6, "AR head multiplier")
	_near(Weapons.zone_mult(ar, "limb"), 0.75, "legs take less")
	_near(Weapons.zone_mult(ar, "body"), 1.0, "body multiplier")
	var smg: Dictionary = Weapons.DEFS.smg
	_check(Weapons.zone_mult(smg, "head", 25.0) < Weapons.zone_mult(smg, "head", 5.0), "SMG headshot bonus decays with range")
	_near(Weapons.after_armor(100.0, "body", 0.35, 0.35), 65.0, "a Lv2 vest stops 35%")
	_near(Weapons.after_armor(10.0, "zone", 0.35, 0.35), 10.0, "zone ignores armor")
	_near(Weapons.pen_mult(ar, "body"), 1.0, "no penetration: no change")
	var groza: Dictionary = Weapons.DEFS.groza
	_near(Weapons.after_armor(100.0 * Weapons.pen_mult(groza, "body"), "body", Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION),
		100.0 * (1.0 - Weapons.VEST_REDUCTION * 0.75), "25% penetration: the vest stops 3/4 of its share")
	_near(Weapons.pen_mult(groza, "zone"), 1.0, "penetration does nothing outside armour")
	# Hits to kill through Lv2 armour (200 HP), like the reference roster.
	_check(_hits("ar", "body") >= 7 and _hits("ar", "body") <= 9, "M4A1: 7..9 body shots kill (%d)" % _hits("ar", "body"))
	_check(_hits("ar", "head") == 3, "M4A1: 3 headshots kill (%d)" % _hits("ar", "head"))
	_check(_hits("ak", "body") < _hits("ar", "body"), "AK47 hits harder than the M4A1")
	_check(_hits("smg", "body") >= 9 and _hits("smg", "body") <= 11, "MP40: 9..11 body shots (%d)" % _hits("smg", "body"))
	_check(_hits("pistol", "head") == 1, "hand cannon headshot is a one-tap through a Lv2 helmet")
	_check(_hits("lever", "body") == 2, "M1887: two shells to the body")
	_check(_hits("sg", "body") == 3, "M1014: three shells to the body")
	_check(_hits("kar98k", "head") == 1 and _hits("sniper", "head") == 1, "bolt rifles one-tap the head")
	_check(_hits("sniper", "body") == 2, "the heavy sniper's penetration: two body shots")
	_check(_hits("ar", "limb") > _hits("ar", "body"), "leg shots need more hits")
	for id in Weapons.PICKABLE:
		_check(Weapons.DEFS.has(id), "pickable weapon %s exists" % id)
		var def: Dictionary = Weapons.DEFS.get(id, {})
		_check(def.get("attach") is Array, "%s lists its attachments" % id)
		for v in Weapons.bars(def).values():
			_check(float(v) > 0.0 and float(v) <= 1.0, "%s bars inside 0..1" % id)


## Hits of `id` (all pellets, no falloff) that take 200 HP through Lv2 armour on `zone`.
func _hits(id: String, zone: String) -> int:
	var d: Dictionary = Weapons.DEFS[id]
	var raw := float(d.damage) * int(d.pellets) * Weapons.zone_mult(d, zone) * Weapons.pen_mult(d, zone)
	return ceili(200.0 / Weapons.after_armor(raw, zone, Weapons.VEST_REDUCTION, Weapons.HELMET_REDUCTION) - 0.0001)


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
	var lay := HudLayout.resolve({"fire_r": {"x": 2.0, "y": -1.0, "s": 9.0, "o": 3.0}, "jump": {"o": 0.12},
		"crouch": {"o": 0.0}, "scope": {"x": "left", "a": "up"}, "bogus": {}})
	_check(lay.has("fire_r") and not lay.has("bogus"), "layout keeps only known widgets")
	_check(lay.fire_r.x == 0.98 and lay.fire_r.y == 0.04, "layout clamps position")
	_check(is_equal_approx(lay.fire_r.s, minf(HudLayout.DEFAULTS.fire_r.s * HudLayout.SIZE_MAX, 0.45)), "layout clamps size")
	_check(lay.fire_r.o == 1.0 and is_equal_approx(lay.jump.o, 0.12), "layout clamps opacity to 10..100 %")
	_check(lay.crouch.o == HudLayout.DEFAULTS.crouch.o, "an invisible (0 %) control falls back to the default opacity")
	_check(lay.scope.x == HudLayout.DEFAULTS.scope.x and lay.scope.a == HudLayout.DEFAULTS.scope.a, "wrongly typed values are ignored")
	var back := HudLayout.resolve(HudLayout.to_save(lay))
	_check(int(HudLayout.to_save(lay)._v) == HudLayout.VERSION and is_equal_approx(back.jump.o, lay.jump.o)
		and is_equal_approx(back.fire_r.x, lay.fire_r.x), "saved layout loads back the same")
	var saved := Game.hud_layout
	Game.hud_layout = {"fire_r": {"x": 0.3}}
	_check(HudLayout.current().fire_r.x == HudLayout.DEFAULTS.fire_r.x, "a layout from an older HUD version is ignored")
	Game.hud_layout = {"_v": [], "fire_r": {"x": 0.3}}
	_check(HudLayout.current().fire_r.x == HudLayout.DEFAULTS.fire_r.x, "a layout with a wrongly typed version is ignored")
	Game.hud_layout = saved
	var def := HudLayout.resolve({})
	var phone := Vector2(2400, 1080)
	for vs: Vector2 in [Vector2(1280, 720), phone, Vector2(1560, 720)]:
		var screen := Rect2(Vector2.ZERO, vs)
		var off_screen := PackedStringArray()
		var drift := PackedStringArray()
		var unanchored := PackedStringArray()
		for id: String in HudLayout.DEFAULTS:
			var w: Dictionary = def[id]
			var c := HudLayout.center(w, vs)
			var moved := w.duplicate()
			HudLayout.place(moved, c, vs)
			if not HudLayout.center(moved, vs).is_equal_approx(c):
				drift.append(id)
			if id != "joystick" and not screen.encloses(HudLayout.hit_rect(id, w, vs)):
				off_screen.append(id)
			if w.a != "c" and id != "joystick":
				# Anchored widgets keep their distance to their edge, in screen heights.
				var ref := HudLayout.center(w, phone)
				var edge := c.x if w.a == "l" else vs.x - c.x
				var ref_edge := ref.x if w.a == "l" else phone.x - ref.x
				if absf(edge / vs.y - ref_edge / phone.y) > 0.002:
					unanchored.append(id)
		_check(off_screen.is_empty(), "default widgets fit on a %s screen %s" % [vs, off_screen])
		_check(drift.is_empty(), "place() then center() gives the same spot on %s %s" % [vs, drift])
		_check(unanchored.is_empty(), "edge-anchored widgets keep their edge distance on %s %s" % [vs, unanchored])
		var main := HudLayout.weapon_main(def.weapons, vs)
		var slots := HudLayout.weapon_slots(def.weapons, vs)
		_check(slots.size() == 3 and slots[0].end.x < slots[1].position.x and slots[1].end.x < slots[2].position.x,
			"three non-overlapping weapon slots on %s" % vs)
		_check(main.end.y <= slots[0].position.y and screen.encloses(main.merge(slots[2])), "weapon panel: main slot above the small ones, on screen (%s)" % vs)
	_check(HudLayout.center(def.fire_r, Vector2(1560, 720)).x > 1200.0, "layout scales to wide (19.5:9) screens")


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
	_check(not Guard.verify_dict({"name": "OLD", "xp": 99999}).ok, "an unsigned profile is rejected")
	_check(not Guard.verify_dict({"name": "OLD", "_sig": 12345}).ok and not Guard.verify_dict({"_sig": []}).ok,
		"a profile with a malformed signature is rejected")
	_check(GuardCode.speed_window(3.0, 3.0) == 0 and GuardCode.speed_window(3.0, 3.3) == 0, "speed check: a normal clock passes")
	_check(GuardCode.speed_window(3.0, 1.5) == 1 and GuardCode.speed_window(3.0, 6.0) == 1, "speed check: a 2x faster or slower game clock strikes")
	_check(GuardCode.speed_window(3.0, -2.0) == -1 and GuardCode.speed_window(3.0, 0.0) == -1, "speed check: a wall clock set backwards gives no verdict")
	_check(Game.clean_name("  [color=red]hacker[/color]\u0007\u202e") == "COLORREDHACKER", "player names keep only A-Z 0-9 space _ - . (14 max)")
	var saved_profile := Game.profile.duplicate(true)
	Game.profile.merge({"name": "", "bundle": "nope", "matches": -5, "wins": 9, "kills": -1, "xp": -40}, true)
	Game._sanitize_profile()
	_check(Game.profile.name == "ROOKIE" and Game.profile.bundle == "default", "profile: empty name and unknown outfit fall back")
	_check(Game.profile.matches == 0 and Game.profile.wins == 0 and Game.profile.kills == 0 and Game.profile.xp == 0,
		"profile: counts are never negative and wins never exceed matches")
	Game.profile = saved_profile


func _test_signer_digests() -> void:
	var hex := "0123456789abcdef".repeat(4)
	var colons := ":".join(PackedStringArray(Array(range(0, 64, 2)).map(func(i: int) -> String: return hex.substr(i, 2).to_upper())))
	var d := GuardCode.signer_digests(hex)
	_check(d.size() == 1 and d[0].size() == 32 and d[0][0] == 0x01 and d[0][31] == 0xef, "signer file: a hex digest becomes 32 bytes")
	_check(GuardCode.signer_digests(colons + "\n") == d, "signer file: keytool's AB:CD:.. form gives the same bytes")
	var two := GuardCode.signer_digests(hex + "\n\n" + "ab".repeat(32) + "\n")
	_check(two.size() == 2 and two[1][0] == 0xab, "signer file: one accepted certificate per line")
	_check(GuardCode.signer_digests("").is_empty() and GuardCode.signer_digests(hex.left(62)).is_empty(), "signer file: empty or short text is rejected")
	_check(GuardCode.signer_digests(hex + "\n" + hex.left(63) + "z").is_empty(), "signer file: a non-hex line rejects the file")
	_check(Guard._signature_state() == "not android", "signature check only runs on Android")


func _test_settings_sanitize() -> void:
	var saved := Game.settings.duplicate(true)
	Game.settings.sens_reddot = 5000
	Game.settings.sens_general = -40
	Game.settings.difficulty = 9
	Game.settings.graphics = -1
	Game.settings.fps = 7
	Game.settings.last_pick = "railgun"
	Game._sanitize_settings()
	_check(Game.settings.sens_reddot == 200, "edited red-dot sensitivity is clamped to 200")
	_check(Game.settings.sens_general == 1, "edited sensitivity is clamped to 1..200")
	_check(Game.settings.difficulty == 2 and Game.DIFFICULTY_NAMES.size() > Game.settings.difficulty, "difficulty stays a valid index")
	_check(Game.settings.graphics == 0, "graphics level clamped")
	_check(Game.settings.fps == 60, "unknown frame rate falls back to 60")
	_check(Game.settings.last_pick == Weapons.DEFAULT_PICK, "unknown weapon pick falls back to the default")
	Game.settings = saved


func _test_honour() -> void:
	var win := {"won": true, "hp_left": 20, "taken": 180, "headshots": 0}
	_check(ResultsScreen.honour(win) == "CLUTCH", "a win under 30 HP is a clutch")
	_check(ResultsScreen.honour({"won": false, "hp_left": 20, "taken": 180}) == "FIGHTER", "a draw with low HP is no clutch")
	_check(ResultsScreen.honour({"won": false, "hp_left": 0, "taken": 200}) == "FIGHTER", "a defeat is no clutch")
	_check(ResultsScreen.honour({"won": true, "hp_left": 20, "taken": 180, "headshots": 2}) == "SHARPSHOOTER", "2+ headshots win over clutch")
	_check(ResultsScreen.honour({"won": true, "hp_left": 170, "taken": 30}) == "UNTOUCHABLE", "under 50 damage taken and alive")
	_check(ResultsScreen.honour({"won": false, "hp_left": 0, "taken": 30}) == "FIGHTER", "a dead player is never untouchable")
	_check(ResultsScreen.honour({"invalid": true, "won": true, "hp_left": 20, "headshots": 3}) == "", "a voided match has no honour")
