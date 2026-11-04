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
	_test_modes()
	_test_profile_keys()
	_test_profile_migration()
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
	Game.settings = saved


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
