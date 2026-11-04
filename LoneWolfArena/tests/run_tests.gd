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
	_test_settings_v5()
	_test_fps_options()
	_test_sensitivity_per_sight()
	_test_controls_settings()
	_test_settings_panel()
	_test_auto_graphics()
	_test_perf_governor()
	_test_modes()
	_test_profile_keys()
	_test_profile_migration()
	_test_honour()
	_test_signed_cards()
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


## The settings of version 5 (mode, AUTO graphics, FPS counter, vibration, crosshair colour and
## size, fire-button / free-look / 2x sensitivity): defaults, ranges, on/off values, migration.
func _test_settings_v5() -> void:
	var saved := Game.settings.duplicate(true)
	var d: Dictionary = Game.DEFAULT_SETTINGS
	_check(d.mode == "training" and d.graphics_auto == true and d.show_fps == false and d.vibration == true
		and d.crosshair_color == 0 and d.crosshair_size == 100 and d.sens_fire == 100 and d.sens_freelook == 100
		and d.sens_2x == 100, "the new settings start as the game played before they existed")
	_check(d.graphics == 1 and d.fps == 60 and d.sens_general == 100 and d.sens_reddot == 100 and d.sens_sniper == 71
		and d.vol_master == 85 and d.vol_sfx == 90 and d.vol_music == 45 and d.difficulty == 1
		and d.dynamic_joystick == false and d.last_pick == "ar", "the older settings keep their defaults")
	for k in ["show_fps", "vibration", "crosshair_color", "crosshair_size", "sens_fire"]:
		_check(d.has(k) and not Game.FIXED_SETTINGS.has(k), "%s is a setting now, no longer fixed" % k)
	_check(Game.FIXED_SETTINGS.has("damage_numbers") and Game.FIXED_SETTINGS.has("run_mode"), "the rest stays fixed")
	_check(int(Game.SETTING_RANGES.crosshair_color[1]) == Game.CROSSHAIR_COLORS.size() - 1, "the crosshair colour range is the colour list")
	_near(Game.CROSSHAIR_SCALE, lerpf(0.75, 1.35, 0.5), "crosshair size 100 % is the size the HUD drew before")
	# Ranges and on/off values.
	Game.settings = d.duplicate(true)
	Game.settings.merge({"crosshair_size": 10, "crosshair_color": 9, "sens_freelook": 0, "sens_2x": 900, "sens_fire": -3,
		"show_fps": "yes", "vibration": 0, "graphics_auto": [], "dynamic_joystick": true, "mode": "battle"}, true)
	Game._sanitize_settings()
	var s := Game.settings
	_check(s.crosshair_size == 50 and s.crosshair_color == 3, "crosshair size and colour are clamped (%s, %s)" % [s.crosshair_size, s.crosshair_color])
	_check(s.sens_freelook == 1 and s.sens_2x == 200 and s.sens_fire == 1, "free look, 2x and fire-button sensitivity stay in 1..200")
	_check(s.show_fps == false and s.vibration == true and s.graphics_auto == true and s.dynamic_joystick == true,
		"an on/off setting that is not true or false falls back to its default; a real one is kept")
	_check(s.mode == "training", "an unknown mode falls back to TRAINING GROUND")
	s.crosshair_size = 999
	s.mode = 7
	Game._sanitize_settings()
	_check(s.crosshair_size == 150 and s.mode == "training", "crosshair size at most 150 %, a mode must be a mode's name")
	_near(Game.crosshair_scale(), Game.CROSSHAIR_SCALE * 1.5, "the crosshair scale follows the size")
	s.crosshair_size = 100
	_near(Game.crosshair_scale(), Game.CROSSHAIR_SCALE, "crosshair scale at 100 %")
	# A version 4 file (through JSON, as saved): the values that were fixed then have no say, free
	# look and 2x start at the sensitivity they turned with, a picked graphics level keeps AUTO off.
	var v4: Dictionary = JSON.parse_string(JSON.stringify({"settings_version": 4, "graphics": 2, "sens_general": 150,
		"sens_reddot": 120, "sens_sniper": 60, "vibration": false, "show_fps": true, "crosshair_color": 2,
		"crosshair_size": 50, "sens_fire": 30, "dynamic_joystick": true, "difficulty": 2, "damage_numbers": false, "bogus": 1}))
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings(v4)
	s = Game.settings
	_check(s.settings_version == Game.SETTINGS_VERSION and s.graphics == 2 and s.sens_general == 150 and s.sens_reddot == 120
		and s.sens_sniper == 60 and s.dynamic_joystick == true and s.difficulty == 2, "a version 4 file keeps its settings")
	_check(s.vibration == true and s.show_fps == false and s.crosshair_color == 0 and s.crosshair_size == 100 and s.sens_fire == 100,
		"a version 4 file's fixed values give way to what version 4 played with")
	_check(s.sens_freelook == 150 and s.sens_2x == 120, "free look and 2x start at General and Red Dot (%s, %s)" % [s.sens_freelook, s.sens_2x])
	_check(s.graphics_auto == false, "a player who picked a graphics level keeps it (AUTO off)")
	_check(s.mode == "training" and s.damage_numbers == true and not s.has("bogus"), "fixed behaviour wins, unknown keys are dropped")
	_check(typeof(s.sens_freelook) == TYPE_INT and typeof(s.graphics) == TYPE_INT, "numbers read from JSON are whole numbers again")
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings({"settings_version": 4, "graphics": 1})
	_check(Game.settings.graphics_auto == true and Game.settings.sens_freelook == 100, "at the default graphics level AUTO stays on")
	# A version 5 file keeps every new setting.
	var v5: Dictionary = JSON.parse_string(JSON.stringify({"settings_version": 5, "mode": "lonewolf", "graphics_auto": false,
		"show_fps": true, "vibration": false, "crosshair_color": 3, "crosshair_size": 140, "sens_fire": 80,
		"sens_freelook": 90, "sens_2x": 110, "sens_general": 150}))
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings(v5)
	s = Game.settings
	_check(s.mode == "lonewolf" and s.graphics_auto == false and s.show_fps == true and s.vibration == false and s.crosshair_color == 3
		and s.crosshair_size == 140 and s.sens_fire == 80 and s.sens_freelook == 90 and s.sens_2x == 110, "a version 5 file keeps the new settings")
	# Older files migrate as before: v1's 0-100 sensitivities are dropped, before v4 the joystick resets.
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings({"settings_version": 1, "sens_general": 40, "sens_reddot": 40, "dynamic_joystick": true, "vol_music": 10})
	s = Game.settings
	_check(s.sens_general == 100 and s.sens_freelook == 100 and s.sens_2x == 100 and s.dynamic_joystick == false and s.vol_music == 10,
		"a version 1 file migrates as before")
	Game.settings = saved


## The frame rates offered per screen: 30 and 60 always, 90 and 120 only where the screen refreshes
## that fast (an unknown rate offers 30 and 60).
func _test_fps_options() -> void:
	_check(Game.FPS_OPTIONS == [30, 60, 90, 120], "the frame-rate setting holds 30, 60, 90 or 120")
	_check(Game.fps_options_for(60.0) == [30, 60] and Game.fps_options_for(59.94) == [30, 60] and Game.fps_options_for(50.0) == [30, 60],
		"a 60 Hz (or slower) screen offers 30 and 60")
	_check(Game.fps_options_for(90.0) == [30, 60, 90] and Game.fps_options_for(89.0) == [30, 60, 90], "a 90 Hz screen adds 90")
	_check(Game.fps_options_for(120.0) == [30, 60, 90, 120] and Game.fps_options_for(119.88) == [30, 60, 90, 120]
		and Game.fps_options_for(144.0) == [30, 60, 90, 120], "a 120 Hz (or faster) screen offers all four")
	_check(Game.fps_options_for(NAN) == [30, 60] and Game.fps_options_for(-1.0) == [30, 60] and Game.fps_options_for(0.0) == [30, 60],
		"an unknown refresh rate offers 30 and 60")
	_check(Game.fps_choices().has(30) and Game.fps_choices().has(60), "this screen's choices include 30 and 60")
	var saved := Game.settings.duplicate(true)
	Game.settings.fps = 120
	Game._sanitize_settings()
	_check(Game.settings.fps == 120, "120 FPS is a valid setting")
	Game.settings.fps = 75
	Game._sanitize_settings()
	_check(Game.settings.fps == 60, "a frame rate outside the options falls back to 60")
	Game.settings = saved


## Each sight turns with its own sensitivity, and the SCOPE 2X guns really aim at a 2x zoom.
func _test_sensitivity_per_sight() -> void:
	var d := Weapons.DEFS
	_check(Player.sens_key(d.ar, false) == "sens_general" and Player.sens_key(d.sniper, false) == "sens_general"
		and Player.sens_key(d.groza, false) == "sens_general", "from the hip every gun turns with General")
	_check(Player.sens_key(d.ar, true) == "sens_reddot" and Player.sens_key(d.pistol, true) == "sens_reddot", "red-dot guns aim with Red Dot")
	_check(Player.sens_key(d.lever, true) == "sens_reddot", "iron sights aim with Red Dot")
	_check(Player.sens_key(d.sniper, true) == "sens_sniper" and Player.sens_key(d.kar98k, true) == "sens_sniper", "sniper scopes aim with Sniper Scope")
	_check(Player.sens_key(d.groza, true) == "sens_2x" and Player.sens_key(d.sks, true) == "sens_2x", "the SCOPE 2X guns aim with 2x Scope")
	var twos := []
	for id: String in Weapons.PICKABLE:
		var def: Dictionary = d[id]
		var sight := Player.sight_of(def)
		if "SCOPE 2X" in (def.attach as Array):
			twos.append(id)
			var zoom := tan(deg_to_rad(Player.FOV_HIP) * 0.5) / tan(deg_to_rad(float(def.ads_fov)) * 0.5)
			_near(zoom, 2.0, "%s aims at twice the hip view's zoom" % id, 0.01)
			_check(sight == "2x", "%s aims through its 2x scope" % id)
		else:
			_check(sight == String(def.scope), "%s aims through its own sight (%s)" % [id, sight])
		_check(Game.DEFAULT_SETTINGS.has(Player.sens_key(def, true)), "%s's sight has a sensitivity setting" % id)
	_check(twos == ["groza", "sks"], "GROZA and SKS carry the 2x scope (%s)" % [twos])
	_check(SettingsPanel.guns_with_sight("2x") == PackedStringArray(["GROZA", "SKS"]), "the 2x row names the guns it is for")


## Aim precision, the left fire button and visual effects: defaults, sanitising and what they switch.
func _test_controls_settings() -> void:
	var d: Dictionary = Game.DEFAULT_SETTINGS
	_check(d.aim_precision == 0 and d.left_fire == 0 and d.visual_effects == true, "aim assist, the left fire button and the effects start as before")
	_check(Player.assist_allowed(0, false) and Player.assist_allowed(0, true), "ASSISTED: the assist works from the hip and while aiming")
	_check(Player.assist_allowed(1, false) and not Player.assist_allowed(1, true), "MANUAL IN SCOPE: assisted from the hip only")
	_check(not Player.assist_allowed(2, false) and not Player.assist_allowed(2, true), "FULL MANUAL: no assist")
	var saved := Game.settings.duplicate(true)
	Game.settings.merge({"aim_precision": 7, "left_fire": -2, "visual_effects": "no"}, true)
	Game._sanitize_settings()
	_check(Game.settings.aim_precision == 2 and Game.settings.left_fire == 0 and Game.settings.visual_effects == true,
		"aim precision and the left fire button are clamped, effects fall back to on")
	var hud := HUD.new()
	Game.settings.left_fire = 1
	var hidden_at_hip := not hud._button_visible("fire_l") and hud._button_visible("fire_r")
	Game.settings.left_fire = 0
	_check(hidden_at_hip and hud._button_visible("fire_l"), "the left fire button shows always, or only while aiming")
	hud.free()
	Game.settings = saved
	var lights := Effects.lights_enabled
	var share := Effects.particle_share
	Effects.configure(2, true)
	_check(Effects.lights_enabled and is_equal_approx(Effects.particle_share, 1.0), "HIGH with effects: lights and every particle")
	Effects.configure(1, true)
	_check(not Effects.lights_enabled and is_equal_approx(Effects.particle_share, 1.0), "MEDIUM: no lights")
	Effects.configure(0, true)
	_check(not Effects.lights_enabled and is_equal_approx(Effects.particle_share, 0.5), "LOW: half the particles")
	Effects.configure(3, false)
	_check(not Effects.lights_enabled and is_equal_approx(Effects.particle_share, 0.5), "effects off: no lights, half the particles")
	Effects.configure(0, false)
	_check(is_equal_approx(Effects.particle_share, 0.25), "LOW with the effects off: a quarter")
	Effects.lights_enabled = lights
	Effects.particle_share = share


## The settings screen: every setting a player can change is in exactly one tab (whose RESET puts it
## back), the presets set all six sensitivities, and the screen's controls do what they say.
func _test_settings_panel() -> void:
	var shown := {}
	var twice := []
	for keys: Array in SettingsPanel.TAB_KEYS:
		for k: String in keys:
			if shown.has(k):
				twice.append(k)
			shown[k] = true
	var missing := []
	for k: String in Game.DEFAULT_SETTINGS:
		if not shown.has(k) and not (k in SettingsPanel.NOT_SHOWN):
			missing.append(k)
	_check(missing.is_empty() and twice.is_empty(), "every setting is in one tab or deliberately not shown (missing %s, twice %s)" % [missing, twice])
	_check(shown.keys().all(func(k: String) -> bool: return Game.DEFAULT_SETTINGS.has(k))
		and SettingsPanel.NOT_SHOWN.all(func(k: String) -> bool: return Game.DEFAULT_SETTINGS.has(k) and not shown.has(k)),
		"the tabs and the not-shown list name real settings")
	_check(["graphics_auto", "graphics", "fps", "show_fps", "visual_effects", "vibration"].all(func(k: String) -> bool: return k in SettingsPanel.TAB_KEYS[0]),
		"BASIC: graphics (AUTO), frame rate, FPS counter, visual effects, vibration")
	_check(["dynamic_joystick", "aim_precision", "left_fire", "crosshair_color", "crosshair_size"].all(func(k: String) -> bool: return k in SettingsPanel.TAB_KEYS[2]),
		"CONTROLS: joystick, aim precision, left fire button, crosshair colour and size")
	var sens: Array = SettingsPanel.TAB_KEYS[1]
	_check(sens == SettingsPanel.SENS_ROWS.map(func(r: Array) -> String: return String(r[1])) and sens.size() == 6,
		"SENSITIVITY shows its six rows in order")
	_check(SettingsPanel.PRESET_NAMES == ["STANDARD", "FAST"] and SettingsPanel.SENS_PRESETS.size() == 2, "two presets: STANDARD and FAST")
	var dp: Dictionary = SettingsPanel.SENS_PRESETS.STANDARD
	var fp: Dictionary = SettingsPanel.SENS_PRESETS.FAST
	_check(dp.size() == 6 and sens.all(func(k: String) -> bool: return dp.has(k) and int(dp[k]) == int(Game.DEFAULT_SETTINGS[k])),
		"the STANDARD preset is the defaults of all six")
	var in_range := fp.size() == 6
	for k: String in sens:
		var lim: Array = Game.SETTING_RANGES[k]
		in_range = in_range and fp.has(k) and int(fp[k]) >= int(lim[0]) and int(fp[k]) <= int(lim[1])
	_check(in_range and int(fp.sens_general) > int(dp.sens_general), "the FAST preset sets all six, faster, within range")
	_check(SettingsPanel.COLOR_NAMES.size() == Game.CROSSHAIR_COLORS.size(), "every crosshair colour has a name")
	_check(SettingsPanel.PRECISION_NAMES.size() == int(Game.SETTING_RANGES.aim_precision[1]) + 1
		and SettingsPanel.PRECISION_NOTES.size() == SettingsPanel.PRECISION_NAMES.size()
		and SettingsPanel.LEFT_FIRE_NAMES.size() == int(Game.SETTING_RANGES.left_fire[1]) + 1, "every aim precision and left fire value has a choice")
	# The screen itself (automated: AUTO guesses nothing, nothing is saved).
	var saved := Game.settings.duplicate(true)
	var saved_pending := Game.auto_graphics_pending
	var saved_at := Game.autotest
	Game.autotest = "unit"
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	var panel := SettingsPanel.new()
	add_child(panel)
	panel._show_tab(1)
	for k: String in sens:
		Game.settings[k] = 37
	panel._ask_reset()
	_check(panel._ask_layer != null and Game.settings.sens_general == 37, "RESET asks first and changes nothing yet")
	(panel._ask_layer.find_child("ConfirmCancel", true, false) as Button).pressed.emit()
	_check(panel._ask_layer == null and Game.settings.sens_general == 37, "CANCEL keeps the settings")
	panel._ask_reset()
	(panel._ask_layer.find_child("ConfirmOk", true, false) as Button).pressed.emit()
	_check(panel._ask_layer == null and sens.all(func(k: String) -> bool: return Game.settings[k] == Game.DEFAULT_SETTINGS[k]),
		"a confirmed RESET on SENSITIVITY restores all six")
	panel._apply_preset(1)
	_check(panel._preset_index() == 1 and Game.settings.sens_2x == fp.sens_2x and Game.settings.sens_freelook == fp.sens_freelook,
		"the FAST preset applies all six")
	var slider: HSlider = (panel._sens_rows.sens_freelook as Control).get_meta("slider")
	slider.value = 90
	_check(Game.settings.sens_freelook == 90 and panel._preset_index() == -1, "a slider moved off the preset applies at once")
	panel._show_tab(2)
	panel._set_precision(2)
	_check(Game.settings.aim_precision == 2 and panel._aim_note.text == SettingsPanel.PRECISION_NOTES[2], "aim precision applies and explains itself")
	Game.settings.merge({"crosshair_color": 3, "crosshair_size": 140, "dynamic_joystick": true, "left_fire": 1}, true)
	panel._reset_tab()
	_check(Game.settings.crosshair_color == 0 and Game.settings.crosshair_size == 100 and Game.settings.dynamic_joystick == false
		and Game.settings.aim_precision == 0 and Game.settings.left_fire == 0, "RESET on CONTROLS restores joystick, aim precision, left fire and crosshair")
	var colors := panel.find_child("CrosshairColor", true, false)
	_check(colors != null and colors.get_child_count() == Game.CROSSHAIR_COLORS.size() and panel.find_child("CrosshairPreview", true, false) != null
		and panel.find_child("AimPrecision", true, false) != null and panel.find_child("LeftFire", true, false) != null,
		"CONTROLS offers aim precision, the left fire button, every crosshair colour and a preview")
	panel._show_tab(0)
	var gseg := panel.find_child("GraphicsChoice", true, false)
	_check(gseg != null and gseg.get_child_count() == 5, "graphics: AUTO and the four levels")
	panel._on_graphics(3)
	_check(Game.settings.graphics == 2 and Game.settings.graphics_auto == false and panel._graphics_note.text.begins_with("Low"),
		"picking HIGH turns AUTO off")
	panel._on_graphics(4)
	_check(panel._ask_layer != null and Game.settings.graphics == 2 and (gseg.get_child(3) as Button).button_pressed
		and not (gseg.get_child(4) as Button).button_pressed, "EXTREME asks first (it can heat the phone); the row keeps HIGH meanwhile")
	(panel._ask_layer.find_child("ConfirmOk", true, false) as Button).pressed.emit()
	_check(Game.settings.graphics == 3 and (gseg.get_child(4) as Button).button_pressed, "confirmed: EXTREME")
	panel._on_graphics(0)
	_check(Game.settings.graphics_auto == true and panel._graphics_note.text == "AUTO picked EXTREME for this phone",
		"AUTO names the level it picked (%s)" % panel._graphics_note.text)
	var fseg := panel.find_child("FpsChoice", true, false)
	_check(fseg != null and fseg.get_child_count() == Game.fps_choices().size(), "the frame-rate row offers this screen's rates")
	var changes := [0]
	var count := func() -> void: changes[0] += 1
	Game.settings_changed.connect(count)
	panel._apply("visual_effects", false)
	_check(Game.settings.visual_effects == false and changes[0] == 1, "visual effects apply at once (the arena re-applies its effects)")
	panel._apply("show_fps", true)
	_check(changes[0] == 1, "a setting the HUD reads live does not re-apply the scene")
	Game.settings_changed.disconnect(count)
	Game.settings.merge({"fps": 30, "vibration": false, "graphics_auto": false, "graphics": 3}, true)
	panel._reset_tab()
	_check(Game.settings.fps == 60 and Game.settings.show_fps == false and Game.settings.vibration == true and Game.settings.graphics_auto == true
		and Game.settings.visual_effects == true, "RESET on BASIC: 60 FPS, no counter, effects and vibration on, AUTO graphics")
	panel._ask_reset()
	panel.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(panel._ask_layer == null and panel.is_inside_tree() and not panel.is_queued_for_deletion(), "back closes the question, not the settings")
	panel.free()
	Game.settings = saved
	Game.auto_graphics_pending = saved_pending
	Game.autotest = saved_at
	Game.apply_settings()


## AUTO graphics: the first guess from the device, the measured step and the flow (a lowered level
## is measured once more, then kept).
func _test_auto_graphics() -> void:
	var gib := 1024 * 1024 * 1024
	var phone := Vector2i(2400, 1080)
	var small := Vector2i(1600, 720)
	_check(PerfGovernor.device_level("llvmpipe (LLVM 20.1.2, 256 bits)", 16, 32 * gib, Vector2i(1920, 1080), false) == 0
		and PerfGovernor.device_level("Google SwiftShader", 8, 8 * gib, phone, true) == 0, "a software renderer gets LOW")
	_check(PerfGovernor.device_level("NVIDIA GeForce RTX 3060", 12, 32 * gib, Vector2i(2560, 1440), false) == 2
		and PerfGovernor.device_level("Intel(R) HD Graphics", 2, 4 * gib, Vector2i(1366, 768), false) == 1, "a desktop gets HIGH (MEDIUM on 2 cores)")
	_check(PerfGovernor.device_level("Adreno (TM) 740", 8, 8 * gib, Vector2i(3088, 1440), true) == 2, "a flagship phone gets HIGH, even on a big screen")
	_check(PerfGovernor.device_level("Adreno (TM) 619", 8, 6 * gib, phone, true) == 1
		and PerfGovernor.device_level("Mali-G57 MC2", 8, 4 * gib, small, true) == 1, "a mid-range phone gets MEDIUM")
	_check(PerfGovernor.device_level("Adreno (TM) 610", 8, 4 * gib, small, true) == 0
		and PerfGovernor.device_level("Mali-G52 MC2", 8, 4 * gib, small, true) == 0
		and PerfGovernor.device_level("PowerVR Rogue GE8320", 8, 3 * gib, small, true) == 0, "an entry-level GPU gets LOW")
	_check(PerfGovernor.device_level("Mali-G57 MC2", 4, 4 * gib, phone, true) == 0
		and PerfGovernor.device_level("Mali-G57 MC2", 8, 2 * gib, phone, true) == 0
		and PerfGovernor.device_level("Mali-G57 MC2", 8, 6 * gib, Vector2i(3200, 1440), true) == 0,
		"4 cores, under 3 GiB of memory or a huge screen take a level off")
	_check(PerfGovernor.device_level("Mali-G710 MC10", 8, 8 * gib, phone, true) == 2 and PerfGovernor.device_level("Mali-G710 MC10", 4, 8 * gib, phone, true) == 1,
		"a flagship GPU with 4 cores gets MEDIUM")
	_check(PerfGovernor.device_level("Maleoon 910", 0, 0, phone, true) == 1, "an unknown phone starts at MEDIUM")
	var tiers := {"Adreno (TM) 506": -1, "Adreno (TM) 540": 0, "Adreno (TM) 612": -1, "Adreno (TM) 618": 0, "Adreno (TM) 650": 1,
		"Adreno (TM) 702": -1, "Adreno (TM) 710": 0, "Adreno (TM) 750": 1, "Adreno (TM) 830": 1, "Mali-T830 MP2": -1, "Mali-G31 MP2": -1,
		"Mali-G68 MC4": 0, "Mali-G76 MP12": 1, "Mali-G615 MC6": 0, "Mali-G720 MC7": 1, "Immortalis-G925": 1, "Samsung Xclipse 940": 1,
		"PowerVR B-Series BXM-8-256": -1, "": 0}
	var wrong := []
	for gpu: String in tiers:
		if PerfGovernor.gpu_tier(gpu) != int(tiers[gpu]):
			wrong.append(gpu)
	_check(wrong.is_empty(), "GPU classes from the driver's name (wrong: %s)" % [wrong])
	# The measured step at 60 FPS (16.7 ms a frame).
	var t := 1000.0 / 60.0
	_check(PerfGovernor.refine_level(1, _frames(60, t), 5.0, t) == 2, "frames on target with the CPU and GPU idle most of the time: a level up")
	_check(PerfGovernor.refine_level(2, _frames(60, t), 5.0, t) == 2, "AUTO never goes past HIGH")
	_check(PerfGovernor.refine_level(1, _frames(60, t), 5.0, t, false) == 1, "a second measurement never goes up")
	_check(PerfGovernor.refine_level(1, _frames(60, t), 0.0, t) == 1 and PerfGovernor.refine_level(1, _frames(60, t), 12.0, t) == 1,
		"no level up without clear room (or when the driver does not tell)")
	_check(PerfGovernor.refine_level(2, _frames(60, t * 1.25), 15.0, t) == 1, "frames a quarter too long: a level down")
	_check(PerfGovernor.refine_level(2, _frames(60, t * 1.8), 25.0, t) == 0, "far too slow: two levels down")
	_check(PerfGovernor.refine_level(1, _frames(52, t) + _frames(8, t * 2.5), 5.0, t) == 0, "one frame in ten over twice the target: a level down")
	_check(PerfGovernor.refine_level(0, _frames(60, t * 3.0), 40.0, t) == 0, "LOW is the floor")
	_check(PerfGovernor.refine_level(2, _frames(3, t * 3.0), 40.0, t) == 2, "too few frames tell nothing")
	_check(PerfGovernor.refine_level(1, _frames(60, 1000.0 / 30.0), 9.0, 1000.0 / 30.0) == 2, "at 30 FPS the budget is 33 ms a frame")
	# The flow (automated: nothing is saved and no device guess is made).
	var saved := Game.settings.duplicate(true)
	var saved_pending := Game.auto_graphics_pending
	var saved_at := Game.autotest
	Game.autotest = "unit"
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game.start_auto_graphics()
	_check(not Game.auto_graphics_pending and Game.settings.graphics == 1 and Game.settings.graphics_auto, "automated runs keep their level (no measuring)")
	Game.settings.graphics = 2
	Game.auto_graphics_pending = true        # as on a phone whose first guess was HIGH
	_check(Game.auto_graphics_first_pass(), "the first measurement may go up")
	Game.finish_auto_graphics(1)
	_check(Game.settings.graphics == 1 and Game.auto_graphics_pending and not Game.settings.graphics_auto_done and not Game.auto_graphics_first_pass(),
		"a lowered level is measured once more")
	Game.finish_auto_graphics(0)
	_check(Game.settings.graphics == 0 and not Game.auto_graphics_pending and Game.settings.graphics_auto_done, "the second answer is kept")
	Game.finish_auto_graphics(2)
	_check(Game.settings.graphics == 0, "nothing changes once AUTO is done")
	Game.start_auto_graphics()
	Game.auto_graphics_pending = true
	Game.settings.graphics = 1
	Game.finish_auto_graphics(2)
	_check(Game.settings.graphics == 2 and not Game.auto_graphics_pending and Game.settings.graphics_auto_done, "a raised level is kept at once")
	Game.start_auto_graphics()
	Game.auto_graphics_pending = true
	Game.stop_auto_graphics()
	Game.settings.graphics = 3
	Game.finish_auto_graphics(0)
	_check(Game.settings.graphics == 3 and not Game.settings.graphics_auto, "a level picked by hand stops AUTO's measuring")
	var file: Dictionary = JSON.parse_string(JSON.stringify({"settings_version": 5, "graphics": 2, "graphics_auto": true, "graphics_auto_done": true}))
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings(file)
	_check(Game.settings.graphics == 2 and Game.settings.graphics_auto_done == true, "AUTO's measured level is kept in the settings file")
	Game.settings = saved
	Game.auto_graphics_pending = saved_pending
	Game.autotest = saved_at
	Game.apply_settings()


## n frame times of ms each.
func _frames(n: int, ms: float) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	for i in n:
		a.append(ms)
	return a


## Dynamic resolution, driven with modelled frame times (no viewport): it settles where the frames
## fit, never below the floor or above the level's own scale, holds in the first second of a round,
## on a single long frame and in the band between its thresholds, undoes a step down that did not
## help, and backs off after a step up that had to be undone.
func _test_perf_governor() -> void:
	var t60 := 1.0 / 60.0
	_near(PerfGovernor.target_fps(60, 60.0), 60.0, "60 FPS on a 60 Hz screen")
	_near(PerfGovernor.target_fps(90, 60.0), 60.0, "a 90 FPS cap on a 60 Hz screen runs at 60")
	_near(PerfGovernor.target_fps(120, 120.0), 120.0, "120 FPS on a 120 Hz screen")
	_near(PerfGovernor.target_fps(30, 120.0), 30.0, "a lower frame cap is the target")
	_near(PerfGovernor.target_fps(60, NAN), 60.0, "an unknown refresh rate counts as 60 Hz")
	_near(PerfGovernor.target_fps(0, 144.0), 144.0, "no frame cap: the screen's rate")
	var g := PerfGovernor.new()
	g.target_s = t60
	# GPU-bound (25 ms at full size, growing with the pixels): it settles at 0.85 (18 ms, in the band).
	g.reset(1.0)
	var r := _govern(g, func(s: float) -> float: return maxf(0.010, 0.025 * s * s), 40.0)
	_near(float(r.scale), 0.85, "GPU-bound frames: the 3D scale steps down to where they fit")
	_near(float(r.lowest), 0.85, "... and no lower")
	g.reset(1.0)
	r = _govern(g, func(s: float) -> float: return 0.06 * s * s, 60.0)
	_near(float(r.lowest), PerfGovernor.FLOOR, "a very slow GPU: down to the floor, never below")
	# CPU-bound: a step down does not help, so it is undone and lowering pauses.
	g.reset(1.0)
	r = _govern(g, func(_s: float) -> float: return 0.022, 60.0)
	_check(float(r.lowest) >= 0.949 and float(r.below) < 0.2,
		"CPU-bound frames: a step down that does not help is undone (lowest %.2f, lowered %.0f %% of the time)" % [r.lowest, float(r.below) * 100.0])
	# Room to spare: back up one slow step at a time to the level's own scale, never above it.
	g.reset(0.85)
	g.scale = 0.6
	r = _govern(g, func(_s: float) -> float: return t60, 60.0)
	_near(float(r.scale), 0.85, "frames on target: back up to the level's own scale")
	_check(float(r.highest) <= 0.851 and int(r.raises) == 5, "0.05 at a time, never above it (%d steps)" % r.raises)
	# Hysteresis: frames between FAST and SLOW x the target change nothing.
	g.reset(1.0)
	g.scale = 0.8
	r = _govern(g, func(_s: float) -> float: return t60 * 1.1, 60.0)
	_check(is_equal_approx(float(r.scale), 0.8) and float(r.lowest) >= 0.799 and int(r.raises) == 0, "frames 10 % over the target: no change")
	# A step up that has to be undone: the next try waits twice as long (no pumping).
	g.reset(1.0)
	g.scale = 0.9
	r = _govern(g, func(s: float) -> float: return t60 if s <= 0.901 else 0.02, 150.0)
	_check(int(r.raises) <= 4 and float(r.highest) <= 0.951 and float(r.lowest) >= 0.899, "a step up that is too much backs off (%d tries in 150 s)" % r.raises)
	g.reset(1.0)
	r = _govern(g, func(_s: float) -> float: return 0.025, 10.0, 0.5)
	_check(is_equal_approx(float(r.scale), 1.0), "nothing changes in the first second of a round")
	g.reset(1.0)
	_check(is_equal_approx(g.advance(2.0, 99.0), 1.0) and is_equal_approx(g.advance(0.6, 99.0), 1.0) and g._avg == 0.0,
		"a load or a pause (one long frame) is left out")
	g.free()


## Runs a governor on frames from model(scale) -> seconds for `seconds`, `round_t` s into the round
## (99: mid-round): the final, lowest and highest scale, the share of the time below the ceiling and
## the steps up.
func _govern(g: PerfGovernor, model: Callable, seconds: float, round_t := 99.0) -> Dictionary:
	var t := 0.0
	var below := 0.0
	var out := {"lowest": g.scale, "highest": g.scale, "raises": 0}
	while t < seconds:
		var dt: float = model.call(g.scale)
		var was := g.scale
		g.advance(dt, round_t)
		if g.scale > was + 0.001:
			out.raises = int(out.raises) + 1
		out.lowest = minf(float(out.lowest), g.scale)
		out.highest = maxf(float(out.highest), g.scale)
		if g.scale < g.ceiling - 0.001:
			below += dt
		t += dt
	out.scale = g.scale
	out.below = below / t
	return out


func _test_modes() -> void:
	var saved := Game.settings.duplicate(true)
	_check(Game.MODE_NAMES.size() == 2 and Game.MODE_NAMES.training == "TRAINING GROUND" and Game.MODE_NAMES.lonewolf == "LONE WOLF",
		"two modes: TRAINING GROUND and LONE WOLF")
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	_check(Game.DEFAULT_MODE == "training" and Game.DEFAULT_SETTINGS.mode == "training" and Game.mode == "training",
		"TRAINING GROUND is the default (START plays a bot match)")
	Game.mode = "lonewolf"
	_check(Game.mode == "lonewolf" and Game.settings.mode == "lonewolf" and Game.mode_name() == "LONE WOLF", "the mode is kept as a setting")
	Game.mode = "royale"
	_check(Game.mode == "training" and Game.mode_name() == "TRAINING GROUND", "an unknown mode sets TRAINING GROUND")
	_check(Game.mode_name("lonewolf") == "LONE WOLF" and Game.mode_name("nope") == "TRAINING GROUND", "a given mode's name")
	for m: String in Game.MODE_NAMES:
		Game.mode = m
		_check(Game.mode == m and Game.mode_name() == Game.MODE_NAMES[m] and Game.mode_name(m) == Game.MODE_NAMES[m]
			and Game.mode_name().length() > 0, "mode_name() covers %s" % m)
		_check((Game.DEFAULT_PROFILE.modes as Dictionary).has(m), "the profile keeps numbers for %s" % m)
	Game.settings = saved
	_test_rounds_to_win()
	_test_mode_counters()
	_test_match_card()


## "FIRST TO n": 5, a custom room's own number online (1-7), LW_ROUNDS_TO_WIN in test runs.
func _test_rounds_to_win() -> void:
	var saved: Dictionary = Game.room_rules
	var env := OS.get_environment("LW_ROUNDS_TO_WIN")
	var base := maxi(int(env), 1) if env != "" else Game.ROUNDS_TO_WIN
	Game.room_rules = {}
	_check(Game.ROUNDS_TO_WIN == 5 and Game.rounds_to_win() == base and Game.rounds_to_win(true) == base,
		"a plain match is first to %d" % base)
	Game.room_rules = {"rounds": 3}
	_check(Game.rounds_to_win(true) == 3 and Game.rounds_to_win(false) == base, "a custom room's rounds count online only")
	Game.room_rules = {"rounds": 99}
	_check(Game.rounds_to_win(true) == 7, "a room plays first to 7 at most")
	Game.room_rules = {"rounds": -2}
	_check(Game.rounds_to_win(true) == 1, "a room plays first to 1 at least")
	Game.room_rules = saved


## count_match / record_match count the totals and the match's own mode (profile.modes).
func _test_mode_counters() -> void:
	var saved_profile: Dictionary = Game.profile.duplicate(true)
	var saved_result: Dictionary = Game.last_result
	var at := Game.autotest
	Game.autotest = "unit"          # nothing is written to user://
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game.count_match("training")
	Game.record_match({"won": true, "kills": 3, "xp": 200, "mode_id": "training", "mode": "TRAINING GROUND"})
	Game.count_match("lonewolf")
	Game.record_match({"won": false, "kills": 1, "xp": 60, "mode_id": "lonewolf", "mode": "LONE WOLF"})
	Game.count_match("lonewolf")
	Game.record_match({"won": true, "kills": 2, "xp": 300, "mode_id": "lonewolf"})
	var p := Game.profile
	_check(int(p.matches) == 3 and int(p.wins) == 2 and int(p.kills) == 6 and int(p.xp) == 560, "the totals count every mode")
	_check(p.modes.training == {"matches": 1, "wins": 1, "kills": 3}, "TRAINING GROUND counts its own match, win and kills")
	_check(p.modes.lonewolf == {"matches": 2, "wins": 1, "kills": 3}, "LONE WOLF counts its own matches, win and kills")
	Game.count_match("royale")
	Game.record_match({"won": true, "kills": 1, "xp": 10, "mode_id": "royale"})
	_check(p.modes.training == {"matches": 2, "wins": 2, "kills": 4} and int(p.matches) == 4, "an unknown mode counts as TRAINING GROUND")
	Game._sanitize_profile()
	_check(Game.profile.modes.lonewolf == {"matches": 2, "wins": 1, "kills": 3}, "the per-mode numbers survive the save check")
	Game.profile = saved_profile
	Game.last_result = saved_result
	Game.autotest = at


## The match loading card: TRAINING GROUND (bot or dummy) or LONE WOLF online, FIRST TO n, and an
## online match never reads as a bot match.
func _test_match_card() -> void:
	var bot := Loading.match_info(false, "", false, 1, 5)
	_check(bot.mode == "TRAINING GROUND" and bot.chips == ["FIRST TO 5", "1 VS BOT", "BOT: NORMAL"], "bot match card: %s" % str(bot.chips))
	var hard := Loading.match_info(false, "", false, 2, 1)
	_check(hard.chips == ["FIRST TO 1", "1 VS BOT", "BOT: HARD"], "the card shows the real round count and level")
	var dummy := Loading.match_info(false, "", true, 1, 5)
	_check(dummy.mode == "TRAINING GROUND" and "TARGET DUMMY" in dummy.chips and not "1 VS BOT" in dummy.chips, "target dummy card")
	var online := Loading.match_info(true, "VIPER", false, 1, 3)
	_check(online.mode == "LONE WOLF" and online.chips == ["FIRST TO 3", "1 VS 1 ONLINE", "VS VIPER"], "online card: %s" % str(online.chips))
	var online_dummy := Loading.match_info(true, "VIPER", true, 2, 5)
	var words := " ".join(PackedStringArray(online_dummy.chips))
	_check(online_dummy.mode == "LONE WOLF" and not "BOT" in words and not "DUMMY" in words, "an online match never shows a bot or the dummy")


## The profile keys of version 2 (guest login, profile page, numbers per mode, friend requests,
## recent players, blocks): defaults, sanitising, limits and the signature over all of them.
func _test_profile_keys() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var d: Dictionary = Game.DEFAULT_PROFILE
	var missing := ["profile_version", "guest_ok", "created", "avatar", "banner", "signature", "deaths", "headshots", "damage",
		"shots", "hits", "rounds_won", "rounds_lost", "time_played", "modes", "recent", "blocked", "friend_in",
		"friend_out"].filter(func(k: String) -> bool: return not d.has(k))
	_check(missing.is_empty(), "the profile has the new keys (missing %s)" % [missing])
	_check(d.profile_version == Game.PROFILE_VERSION and d.guest_ok == false and d.created == 0 and d.avatar == "emblem"
		and d.banner == "default" and d.signature == "" and d.recent.is_empty() and d.blocked.is_empty()
		and d.friend_in.is_empty() and d.friend_out.is_empty(), "the new profile keys start empty")
	_check(Game.PROFILE_COUNTERS.all(func(k: String) -> bool: return d[k] == 0)
		and Game.MODE_NAMES.keys().all(func(m: String) -> bool: return d.modes[m] == {"matches": 0, "wins": 0, "kills": 0}),
		"every counter starts at 0, per mode too")
	var avatars := Game.avatar_ids()
	_check("emblem" in avatars and CharacterModel.BUNDLE_INFO.all(func(b: Dictionary) -> bool: return String(b.id) in avatars),
		"avatars: the emblem and every outfit's portrait")
	var ids := []
	for i in 70:
		ids.append(("player%d" % i).sha256_text().left(32))
	_check(Game.is_player_id(ids[0]) and not Game.is_player_id(String(ids[0]).left(31)) and not Game.is_player_id("z".repeat(32))
		and not Game.is_player_id(42), "player ids are 32 hex characters")
	_check(Game.clean_text("  Hi, [b]you[/b]!  ", 30) == "HI BYOUB" and Game.clean_text("abcdefgh", 5) == "ABCDE",
		"typed text keeps the name characters, up to a length")
	# Out-of-range and malformed values (an edited save, a bug) are repaired.
	var recent := []
	recent.append({"id": "not-an-id", "name": "X", "t": 1})
	for i in 25:
		recent.append({"id": ids[i], "name": "  foe %d!" % i, "t": 1700000000 + i})
	recent.insert(2, {"id": ids[0], "name": "AGAIN", "t": 5})     # the same player again: only the newer entry stays
	recent.append("junk")
	var reqs := {"bad": {"name": "X", "t": 1}, ids[65]: "not a dict"}
	for i in 60:
		reqs[ids[i]] = {"name": "asker %d" % i, "t": -5 if i == 0 else 1700000000}
	var pals := {}
	for i in 55:
		pals[ids[i]] = {"name": "pal %d" % i}
	Game.profile = d.duplicate(true)
	Game.profile.merge({"guest_ok": "yes", "created": -9, "avatar": "dragon", "banner": "gold",
		"signature": "  [b]Hello[/b] world: the very best player of all time!! ", "deaths": -1, "damage": 3.7,
		"shots": 10, "hits": 25, "headshots": 40, "time_played": -60, "rounds_won": 4.0, "rounds_lost": 2,
		"modes": {"training": {"matches": 3, "wins": 9, "kills": -2}, "battle": {"matches": 5}},
		"recent": recent, "blocked": ids.slice(0, 60) + [ids[0], "zz", 42], "friend_in": reqs, "friend_out": reqs.duplicate(true),
		"friends": pals}, true)
	Game._sanitize_profile()
	var p := Game.profile
	_check(p.guest_ok == false and p.created == 0 and p.avatar == "emblem" and p.banner == "default",
		"profile: a wrong flag, time, avatar or banner falls back")
	_check(p.signature == "BHELLOB WORLD THE VERY BEST PL", "profile: the signature keeps name characters, 30 at most (%s)" % p.signature)
	_check(p.deaths == 0 and p.damage == 3 and typeof(p.damage) == TYPE_INT and p.time_played == 0 and p.rounds_won == 4
		and typeof(p.rounds_won) == TYPE_INT and p.rounds_lost == 2, "profile: counters are whole numbers, never negative")
	_check(p.hits == 10 and p.headshots == 10, "profile: hits never exceed shots, headshots never exceed hits")
	_check(p.modes.keys() == Game.MODE_NAMES.keys() and p.modes.training == {"matches": 3, "wins": 3, "kills": 0}
		and p.modes.lonewolf == {"matches": 0, "wins": 0, "kills": 0}, "profile: one set of numbers per mode, wins never above matches")
	_check(p.recent.size() == Game.MAX_RECENT and p.recent[0] == {"id": ids[0], "name": "FOE 0", "t": 1700000000}
		and p.recent[1].id == ids[1] and p.recent[19].id == ids[19], "profile: 20 recent players at most, newest first, each once")
	_check(p.blocked.size() == Game.MAX_BLOCKED and p.blocked == ids.slice(0, 50), "profile: 50 blocked ids at most, valid and each once")
	for k in ["friend_in", "friend_out"]:
		var r: Dictionary = p[k]
		_check(r.size() == Game.MAX_REQUESTS and r.has(ids[0]) and not r.has("bad") and not r.has(ids[65]) and not r.has(ids[50])
			and r[ids[0]] == {"name": "ASKER 0", "t": 0} and r[ids[1]].t == 1700000000, "profile: %s keeps 50 valid requests" % k)
	_check(p.friends.size() == Game.MAX_FRIENDS and p.friends[ids[0]] == {"name": "PAL 0"}, "profile: 50 friends at most")
	Game.profile.avatar = "royal"
	Game._sanitize_profile()
	_check(Game.profile.avatar == "royal", "an outfit's portrait is a valid avatar")
	# The signature covers the new keys too.
	Game.profile = d.duplicate(true)
	Game.profile.merge({"guest_ok": true, "recent": [{"id": ids[1], "name": "RIVAL", "t": 1700000000}], "blocked": [ids[2]]}, true)
	Game.profile.modes.training.wins = 1
	Game.profile.modes.training.matches = 2
	var parsed: Dictionary = JSON.parse_string(JSON.stringify(Guard.sign_dict(Game.profile), "\t"))
	_check(Guard.verify_dict(parsed).ok, "a profile with the new keys verifies after a JSON round trip")
	var edits := {
		"per-mode wins": func(x: Dictionary) -> void: x.modes.training.wins = 2,
		"recent players": func(x: Dictionary) -> void: x.recent[0].name = "FAKE",
		"blocks": func(x: Dictionary) -> void: (x.blocked as Array).clear(),
		"friend requests": func(x: Dictionary) -> void: x.friend_in[ids[3]] = {"name": "X", "t": 1},
		"guest login": func(x: Dictionary) -> void: x.guest_ok = false,
	}
	for what: String in edits:
		var copy: Dictionary = parsed.duplicate(true)
		(edits[what] as Callable).call(copy)
		_check(not Guard.verify_dict(copy).ok, "the signature covers the %s" % what)
	# The first save stamps the creation time, later ones keep it (autotest set: nothing is written).
	var at := Game.autotest
	Game.autotest = "unit"
	Game.save_profile()
	var created := int(Game.profile.created)
	Game.save_profile()
	Game.autotest = at
	_check(created > 1600000000 and int(Game.profile.created) == created, "the first save stamps \"created\", later ones keep it")
	Game.profile = saved_profile


## Saved profiles through the real load path (signature, migration, merge, sanitising): from
## version 1, from version 2, and an edited one.
func _test_profile_migration() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var friend_id := "friend".sha256_text().left(32)
	var old := {"name": "Old Timer", "bundle": "neon", "matches": 12, "wins": 5, "kills": 30, "xp": 2400, "name_set": true,
		"friends": {friend_id: {"name": "BUDDY"}}}
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var ok := Game._apply_saved_profile(_as_saved(old))
	var p := Game.profile
	_check(ok and p.guest_ok == true and p.name_set == true, "an old profile whose player chose a name skips the guest login")
	_check(p.name == "OLD TIMER" and p.bundle == "neon" and p.matches == 12 and p.wins == 5 and p.kills == 30 and p.xp == 2400
		and p.friends == {friend_id: {"name": "BUDDY"}}, "an old profile keeps its progress, outfit and friends")
	_check(p.modes.training == {"matches": 12, "wins": 5, "kills": 30} and p.modes.lonewolf == {"matches": 0, "wins": 0, "kills": 0},
		"an old profile's totals become TRAINING GROUND's numbers")
	_check(p.profile_version == Game.PROFILE_VERSION and p.avatar == "emblem" and p.signature == "" and p.recent.is_empty()
		and p.friend_in.is_empty() and p.created == 0 and p.deaths == 0, "an old profile gets the new keys' defaults")
	_check(typeof(p.matches) == TYPE_INT and typeof(p.modes.training.wins) == TYPE_INT, "numbers read from JSON are whole numbers again")
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game._apply_saved_profile(_as_saved({"name": "ROOKIE", "matches": 1, "name_set": false}))
	_check(Game.profile.guest_ok == false and Game.profile.modes.training.matches == 1, "an old profile without a chosen name still gets the guest login")
	# A version 2 profile loads back exactly: every new key kept, nothing migrated again.
	var v2: Dictionary = Game.DEFAULT_PROFILE.duplicate(true)
	v2.merge({"name": "NEW ONE", "name_set": true, "guest_ok": false, "created": 1780000000, "avatar": "royal", "signature": "GG",
		"matches": 9, "wins": 4, "kills": 11, "xp": 900, "deaths": 7, "headshots": 3, "damage": 1800, "shots": 120, "hits": 40,
		"rounds_won": 20, "rounds_lost": 15, "time_played": 3600,
		"modes": {"training": {"matches": 6, "wins": 3, "kills": 8}, "lonewolf": {"matches": 3, "wins": 1, "kills": 2}},
		"recent": [{"id": "r".sha256_text().left(32), "name": "RIVAL", "t": 1780000100}], "blocked": ["b".sha256_text().left(32)],
		"friend_in": {"i".sha256_text().left(32): {"name": "ASKER", "t": 1780000200}},
		"friend_out": {"o".sha256_text().left(32): {"name": "ASKED", "t": 1780000300}}, "friends": {friend_id: {"name": "BUDDY"}}}, true)
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	ok = Game._apply_saved_profile(_as_saved(v2))
	_check(ok and Game.profile == v2, "a version 2 profile loads back exactly (every new key kept, no second migration)")
	# An edited save is still rejected: only the name is kept, and the edit is flagged.
	var flags_before := Guard.flags.size()
	var edited := _as_saved(v2)
	edited.xp = 999999
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	ok = Game._apply_saved_profile(edited)
	_check(not ok and Game.profile.name == "NEW ONE" and Game.profile.xp == 0 and Game.profile.guest_ok == false
		and Game.profile.modes.lonewolf.matches == 0 and Guard.flags.has("save"), "an edited profile is rejected, only its name is kept")
	Guard.flags.resize(flags_before)
	Game.profile = saved_profile


## A profile as profile.json holds it: signed, then through JSON (numbers come back as floats).
func _as_saved(p: Dictionary) -> Dictionary:
	var d: Dictionary = JSON.parse_string(JSON.stringify(Guard.sign_dict(p), "\t"))
	return d


func _test_honour() -> void:
	var win := {"won": true, "hp_left": 20, "taken": 180, "headshots": 0}
	_check(ResultsScreen.honour(win) == "CLUTCH", "a win under 30 HP is a clutch")
	_check(ResultsScreen.honour({"won": false, "hp_left": 20, "taken": 180}) == "FIGHTER", "a draw with low HP is no clutch")
	_check(ResultsScreen.honour({"won": false, "hp_left": 0, "taken": 200}) == "FIGHTER", "a defeat is no clutch")
	_check(ResultsScreen.honour({"won": true, "hp_left": 20, "taken": 180, "headshots": 2}) == "SHARPSHOOTER", "2+ headshots win over clutch")
	_check(ResultsScreen.honour({"won": true, "hp_left": 170, "taken": 30}) == "UNTOUCHABLE", "under 50 damage taken and alive")
	_check(ResultsScreen.honour({"won": false, "hp_left": 0, "taken": 30}) == "FIGHTER", "a dead player is never untouchable")
	_check(ResultsScreen.honour({"invalid": true, "won": true, "hp_left": 20, "headshots": 3}) == "", "a voided match has no honour")


## Player cards and waiting friend requests are signed with the phone's own key: a good signature
## checks out, a changed name, time or key does not.
func _test_signed_cards() -> void:
	var key := Crypto.new().generate_rsa(2048)
	var other := Crypto.new().generate_rsa(2048)
	var pk := key.save_to_string(true)
	var id := pk.sha256_text().left(32)
	var text := Cloud.card_text(id, "SWIFTWOLF42", "default", 1793800000)
	var sig := Marshalls.raw_to_base64(Crypto.new().sign(HashingContext.HASH_SHA256, text.sha256_buffer(), key))
	_check(Cloud.verify_signed(pk, text, sig), "a player card's signature checks out")
	_check(not Cloud.verify_signed(pk, Cloud.card_text(id, "FAKENAME", "default", 1793800000), sig), "a card with a changed name is rejected")
	_check(not Cloud.verify_signed(pk, Cloud.card_text(id, "SWIFTWOLF42", "default", 1793800001), sig), "a card with a changed time is rejected")
	_check(not Cloud.verify_signed(other.save_to_string(true), text, sig), "a card signed with another key is rejected")
	_check(not Cloud.verify_signed("not a key", text, sig) and not Cloud.verify_signed(pk, text, "AAAA"), "junk keys and signatures are rejected")
	var req := Cloud.waiting_text("frq", id, "0123456789abcdef0123456789abcdef", 1793800000)
	var rsig := Marshalls.raw_to_base64(Crypto.new().sign(HashingContext.HASH_SHA256, req.sha256_buffer(), key))
	_check(Cloud.verify_signed(pk, req, rsig) and not Cloud.verify_signed(pk, Cloud.waiting_text("fra", id, "0123456789abcdef0123456789abcdef", 1793800000), rsig),
		"a friend request's signature does not pass as an answer")
