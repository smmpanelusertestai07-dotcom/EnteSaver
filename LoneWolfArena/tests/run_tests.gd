extends Node
## Unit tests for the pure gameplay logic. Run through the scene, so the autoloads exist:
##   godot --headless --path . res://tests/run_tests.tscn

const GuardCode := preload("res://autoload/guard.gd")     # its static helpers, without the autoload
const GameCode := preload("res://autoload/game.gd")       # (the same for Game's)
const NetFeatureCheck := preload("res://tests/net_feature_check.gd")
const LanUnitCheck := preload("res://tests/lan_unit_check.gd")
const DirectCheck := preload("res://tests/direct_check.gd")
const MatchUnitCheck := preload("res://tests/match_unit_check.gd")
const RoundRulesUnit := preload("res://tests/round_rules_unit.gd")
const TeamLobbyUnit := preload("res://tests/team_lobby_unit.gd")   # DUO / SQUAD: WP-B1 fills it
const TeamHudUnit := preload("res://tests/team_hud_unit.gd")       # DUO / SQUAD: WP-B2 fills it
const TeamRulesUnit := preload("res://tests/team_rules_unit.gd")   # DUO / SQUAD: WP-C fills it
const TeamNetUnit := preload("res://tests/team_net_unit.gd")       # DUO / SQUAD: WP-N fills it
const GroupLobbyUnit := preload("res://tests/group_lobby_unit.gd") # GROUPS: the lobby (UI)

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


## A fighter without armour (Lone Wolf gives both level 2 every round; the tests try both).
class Unarmored extends Bot:
	func armor_mult(_zone: String) -> float:
		return 1.0


## A Cloud that keeps what it would send to the relay instead of sending it: [topic, payload
## size, retained] for each message, and every packet (DELETE MY DATA's checks).
class RecordingCloud extends Cloud:
	var published: Array = []
	var packets: Array = []

	func _publish(topic: String, payload: PackedByteArray, retain := false) -> void:
		if _connected:
			published.append([topic, payload.size(), retain])

	func _send_packet(p: PackedByteArray) -> void:
		packets.append(p)


func _ready() -> void:
	_test_damage()
	_test_damage_shown()
	_test_spread()
	_test_weapon_state()
	_test_hud_layout()
	_test_hud_touch_areas()
	_test_guard()
	_test_signer_digests()
	_test_settings_sanitize()
	_test_settings_v6()
	_test_fps_options()
	_test_sensitivity_per_sight()
	_test_controls_settings()
	_test_settings_panel()
	_test_delete_my_data()
	_test_auto_graphics()
	_test_perf_governor()
	_test_modes()
	_test_profile_keys()
	_test_profile_migration()
	_test_career()
	_test_history()
	_test_honour()
	_test_signed_cards()
	_test_card_v2()
	_test_blocking()
	_test_id_search()
	_test_online_status()
	_test_net_limits()
	NetFeatureCheck.run(self)     # ping, smoothing, chat, card v3, voice codec (tests/net_feature_check.gd)
	LanUnitCheck.run(self)        # PLAY WITHOUT INTERNET: code, discovery, pairing, tampering (tests/lan_unit_check.gd)
	DirectCheck.run(self)         # the direct UDP path: STUN, sealed packets, fallback (tests/direct_check.gd)
	_test_session_ends()
	_test_release_fixes()
	_test_safe_saves()
	_test_clear_cache()
	_test_no_sprint_firing()
	_test_move_speeds()
	_test_lobby_ui_rules()
	MatchUnitCheck.run(self)      # round cap, end-of-match numbers, out banner, challenge rows (tests/match_unit_check.gd)
	RoundRulesUnit.run(self)      # two-stage clock, zone over time, weapon cooldown, kit (tests/round_rules_unit.gd)
	TeamLobbyUnit.run(self)       # DUO / SQUAD lobby, START, TEAM invites, records (tests/team_lobby_unit.gd)
	TeamHudUnit.run(self)         # DUO / SQUAD match HUD and results (tests/team_hud_unit.gd)
	TeamRulesUnit.run(self)       # DUO / SQUAD rules: knocks, revives, rounds (tests/team_rules_unit.gd)
	TeamNetUnit.run(self)         # DUO / SQUAD between two phones (tests/team_net_unit.gd)
	GroupLobbyUnit.run(self)      # GROUPS in the lobby: bar, START gating, podium, texts (tests/group_lobby_unit.gd)
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


## The damage shown is the damage done. For every gun and the fists, against a bot with and without
## armour, shot after shot until it falls (head, body and leg pellets mixed, near and far, the last
## shot more than it had left): every number as the HUD shows it is what the shot took, the
## head-coloured one only the head pellets' part, and all of them add up to exactly the 200 HP lost,
## as do the stats (results DAMAGE, CAREER). Online, hits on the other phone's fighter show no more
## than it has left as this phone's hits leave it.
func _test_damage_shown() -> void:
	var zones := ["body", "head", "limb", "body", "body"]
	for armored: bool in [true, false]:
		for id: String in Weapons.PICKABLE + ["fists"]:
			var d: Dictionary = Weapons.DEFS[id]
			var shooter := Bot.new()
			var target: Bot = Bot.new() if armored else Unarmored.new()
			for f: Bot in [shooter, target]:
				f.process_mode = Node.PROCESS_MODE_DISABLED
				add_child(f)
			shooter.set_loadout(id)
			var shown := []               # [the number as the HUD shows it, head colour]
			shooter.hit_landed.connect(func(_t: Fighter, amount: float, head: bool, _p: Vector3, _k: bool) -> void:
				shown.append([maxi(roundi(amount), 1), head]))
			var parts_ok := true
			var shots := 0
			while target.alive and shots < 200:
				var hits := []
				var want := {"head": 0.0, "body": 0.0}
				for i in int(d.pellets):
					var zone: String = zones[(shots + i) % zones.size()]
					var dist: float = [2.0, 9.0, 24.0][shots % 3]
					var raw := Weapons.damage_at(d, float(d.damage), dist) * Weapons.zone_mult(d, zone, dist) * Weapons.pen_mult(d, zone)
					hits.append([target, zone, raw, Vector3.ZERO])
					want["head" if zone == "head" else "body"] += target.hit_points(raw, zone)
				var n0 := shown.size()
				var hp0 := target.hp
				shooter.land_hits(hits)
				var got := {"head": 0, "body": 0}
				for k in range(n0, shown.size()):
					got["head" if shown[k][1] else "body"] += int(shown[k][0])
				if target.alive:
					parts_ok = parts_ok and got.head == roundi(want.head) and got.body == roundi(want.body)
				parts_ok = parts_ok and got.head + got.body == roundi(hp0 - target.hp)
				shots += 1
			var total := 0
			for s: Array in shown:
				total += int(s[0])
			var what := "%s vs a bot %s" % [d.name, "in armour" if armored else "without armour"]
			_check(not target.alive and total == roundi(Fighter.MAX_HP),
				"%s: the numbers shown add up to the 200 HP it lost (%d in %d shots)" % [what, total, shots])
			_check(parts_ok, "%s: each shot shows what it took, the head part alone in head colour" % what)
			_check(roundi(float(shooter.stats.damage)) == total, "%s: the stats count what the numbers showed (%d)" % [what, roundi(float(shooter.stats.damage))])
			shooter.free()
			target.free()
	# Online: the other phone applies the hits; this phone shows what they will take there.
	var me := Bot.new()
	me.is_player = true
	var other := RemoteFighter.new()
	for f: Bot in [me, other]:
		f.process_mode = Node.PROCESS_MODE_DISABLED
		add_child(f)
	me.set_loadout("ak")
	other.set_loadout("ak")
	var sum := [0.0]
	me.hit_landed.connect(func(_t: Fighter, amount: float, _h: bool, _p: Vector3, _k: bool) -> void: sum[0] += amount)
	for i in 30:
		me.land_hits([[other, "head" if i % 3 == 0 else "body", 46.0 * (2.5 if i % 3 == 0 else 1.0), Vector3.ZERO]])
	_check(is_equal_approx(sum[0], Fighter.MAX_HP) and other.hp_left == 0.0,
		"online: the numbers stop at the HP the other phone has left (%d)" % roundi(sum[0]))
	var state := RemoteFighter.pack(other)
	state[8] = Fighter.MAX_HP
	other.apply_state(state)
	_check(other.hp_left == 0.0, "online: a report sent before the hits got there does not give the HP back")
	other._hit_sent_at = -99.0
	state[8] = 120.0
	other.apply_state(state)
	var resynced := other.hp_left == 120.0
	state[8] = 150.0
	other._hit_sent_at = Time.get_ticks_msec() / 1000.0
	other.apply_state(state)
	_check(resynced and other.hp_left == 150.0, "online: back in step with its reports once they caught up, heals count")
	me.free()
	other.free()


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


## The default HUD's touch areas never overlap (as HUD._widget_at tests them: round buttons to
## 1.15 x their touch radius, the weapon panel's slots grown 4 px), only the gear on the panel's
## corner on purpose, and keep clear of the score bar, from 16:10 to 22:9; a saved layout with PRONE
## at its old place takes the new one; a camera cutout moves the edge-anchored widgets in.
func _test_hud_touch_areas() -> void:
	var def := HudLayout.resolve({})
	for vs: Vector2 in [Vector2(1280, 800), Vector2(1280, 720), Vector2(1440, 720), Vector2(1560, 720), Vector2(1600, 720), Vector2(1760, 720)]:
		var u := HudLayout.unit(vs)
		var areas := {}          # id -> [circles as Vector3(x, y, r)] or [Rect2]
		for id: String in HudLayout.DEFAULTS:
			var w: Dictionary = def[id]
			match HudLayout.kind(id):
				"button":
					var c := HudLayout.center(w, vs)
					areas[id] = [Vector3(c.x, c.y, HudLayout.touch_radius(w, vs) * 1.15)]
				"panel":
					var slots := HudLayout.weapon_slots(w, vs)
					areas[id] = [HudLayout.weapon_main(w, vs).grow(4), slots[0].grow(4), slots[2].grow(4)]
				"square":
					areas[id] = [HudLayout.minimap_rect(w, vs)]
		var score := Rect2(Vector2(vs.x * 0.5 - 0.33 * u, 0.0), Vector2(0.66 * u, 0.09 * u))
		var overlaps := PackedStringArray()
		var ids := areas.keys()
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				if [ids[i], ids[j]] in [["settings", "weapons"], ["weapons", "settings"]]:
					continue
				if _areas_meet(areas[ids[i]], areas[ids[j]]):
					overlaps.append("%s+%s" % [ids[i], ids[j]])
			if HudLayout.kind(ids[i]) == "button" and _areas_meet(areas[ids[i]], [score]):
				overlaps.append("%s+score bar" % ids[i])
		_check(overlaps.is_empty(), "no two default touch areas overlap on %s %s" % [vs, overlaps])
	var old := HudLayout.resolve({"prone": {"x": 0.673, "y": 0.073, "s": 0.12, "o": 0.5, "a": "c"}, "jump": {"x": 0.5, "y": 0.5, "a": "c"}})
	_check(old.prone.x == HudLayout.DEFAULTS.prone.x and old.prone.a == "r" and is_equal_approx(old.prone.s, 0.12)
		and is_equal_approx(old.prone.o, 0.5) and old.jump.x == 0.5, "a saved PRONE at its old place moves to the new one, keeping its size")
	HudLayout.inset = Vector2(64, 0)
	var vs := Vector2(1560, 720)
	var shifted := HudLayout.center(def.wall, vs).x - 64.0
	HudLayout.inset = Vector2.ZERO
	var plain := HudLayout.center(def.wall, vs).x
	HudLayout.inset = Vector2(64, 30)
	var inside := true
	for id: String in HudLayout.DEFAULTS:
		var r := HudLayout.hit_rect(id, def[id], vs)
		var moved: Dictionary = def[id].duplicate()
		HudLayout.place(moved, HudLayout.center(def[id], vs), vs)
		inside = inside and r.position.x >= 64.0 and r.end.x <= vs.x - 30.0 and HudLayout.center(moved, vs).is_equal_approx(HudLayout.center(def[id], vs))
	HudLayout.inset = Vector2.ZERO
	_check(is_equal_approx(shifted, plain) and inside, "a camera cutout moves the edge-anchored widgets in by its width, nothing stays under it")


## Whether two lists of touch areas (Vector3 circles x, y, r or Rect2) meet anywhere.
func _areas_meet(a: Array, b: Array) -> bool:
	for p: Variant in a:
		for q: Variant in b:
			if p is Vector3 and q is Vector3:
				if Vector2(p.x, p.y).distance_to(Vector2(q.x, q.y)) < p.z + q.z:
					return true
			elif p is Rect2 and q is Rect2:
				if (p as Rect2).intersects(q as Rect2):
					return true
			else:
				var c: Vector3 = p if p is Vector3 else q
				var r: Rect2 = q if p is Vector3 else p
				var near := Vector2(clampf(c.x, r.position.x, r.end.x), clampf(c.y, r.position.y, r.end.y))
				if near.distance_to(Vector2(c.x, c.y)) < c.z:
					return true
	return false


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


## The settings of version 6, the reference's set: what is gone (FPS counter, crosshair colour and
## size, fire-button drag, master volume), the vibration rows, the reference's defaults (joystick
## DYNAMIC, free look button off) beside the owner's (LEFT FIRE always, RELOAD and SWITCH on),
## ranges, on/off values and the migration of older files.
func _test_settings_v6() -> void:
	var saved := Game.settings.duplicate(true)
	var d: Dictionary = Game.DEFAULT_SETTINGS
	_check(Game.SETTINGS_VERSION == 6 and d.settings_version == 6, "settings version 6")
	_check(d.mode == "training" and d.graphics_auto == true and d.graphics == 1 and d.fps == 60 and d.sens_general == 100
		and d.sens_reddot == 100 and d.sens_2x == 100 and d.sens_sniper == 71 and d.sens_freelook == 100 and d.difficulty == 1
		and d.vol_sfx == 90 and d.vol_music == 45 and d.vol_voice == 80 and d.last_pick == "ar", "the settings kept keep their defaults")
	_check(d.dynamic_joystick == true and d.freelook_button == false, "the reference's defaults: the joystick follows the thumb, no free look button")
	_check(d.left_fire == 0 and d.reload_button == true and d.switch_button == true, "the owner's: LEFT FIRE always, RELOAD and SWITCH on")
	_check(d.vibrate_footsteps == true and d.vibrate_damage == false and d.vibrate_shooting == false and d.vibration == true,
		"vibration as the reference's rows: enemy footsteps on, taking damage and shooting off, out of a match on")
	for k in ["show_fps", "crosshair_color", "crosshair_size", "sens_fire", "vol_master"]:
		_check(not d.has(k) and not Game.SETTING_RANGES.has(k) and not (k in Game.BOOL_SETTINGS), "%s is no longer a setting" % k)
	_check(Game.FIXED_SETTINGS.show_fps == false and Game.FIXED_SETTINGS.sens_fire == 100 and Game.FIXED_SETTINGS.has("damage_numbers")
		and Game.FIXED_SETTINGS.has("dynamic_crosshair"), "no FPS counter, FIRE drags at the view's own sensitivity: fixed")
	_check(Game.crosshair_color() == Color.WHITE and is_equal_approx(Game.crosshair_scale(), Game.CROSSHAIR_SCALE),
		"the crosshair is white at its standard size")
	_near(Game.CROSSHAIR_SCALE, lerpf(0.75, 1.35, 0.5), "the crosshair keeps the size the HUD drew before")
	_check(Game.VIBRATE_KEYS.values().all(func(k: String) -> bool: return d.has(k) and k in Game.BOOL_SETTINGS),
		"every kind of buzz has its on/off setting")
	# What each kind of buzz needs.
	Game.settings = d.duplicate(true)
	_check(Game.vibration_on("footsteps") and not Game.vibration_on("damage") and not Game.vibration_on("shooting")
		and Game.vibration_on("lobby") and not Game.vibration_on("nope"), "a new install buzzes for footsteps and in the lobby only")
	Game.settings.merge({"vibrate_damage": true, "vibrate_footsteps": false}, true)
	_check(Game.vibration_on("damage") and not Game.vibration_on("footsteps"), "each row turns its own buzz on and off")
	# Ranges and on/off values.
	Game.settings = d.duplicate(true)
	Game.settings.merge({"sens_freelook": 0, "sens_2x": 900, "vibrate_damage": "yes", "vibration": 0, "graphics_auto": [],
		"dynamic_joystick": false, "mode": "battle", "vol_sfx": 140}, true)
	Game._sanitize_settings()
	var s := Game.settings
	_check(s.sens_freelook == 1 and s.sens_2x == 200 and s.vol_sfx == 100, "free look and 2x stay in 1..200, a volume in 0..100")
	_check(s.vibrate_damage == false and s.vibration == true and s.graphics_auto == true and s.dynamic_joystick == false,
		"an on/off setting that is not true or false falls back to its default; a real one is kept")
	_check(s.mode == "training", "an unknown mode falls back to TRAINING GROUND")
	s.mode = 7
	Game._sanitize_settings()
	_check(s.mode == "training", "a mode must be a mode's name")
	# A version 4 file (through JSON, as saved): the values that were fixed then have no say, free
	# look and 2x start at the sensitivity they turned with, a picked graphics level keeps AUTO off.
	var v4: Dictionary = JSON.parse_string(JSON.stringify({"settings_version": 4, "graphics": 2, "sens_general": 150,
		"sens_reddot": 120, "sens_sniper": 60, "vibration": false, "show_fps": true, "crosshair_color": 2,
		"crosshair_size": 50, "sens_fire": 30, "dynamic_joystick": false, "difficulty": 2, "damage_numbers": false, "bogus": 1}))
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings(v4)
	s = Game.settings
	_check(s.settings_version == Game.SETTINGS_VERSION and s.graphics == 2 and s.sens_general == 150 and s.sens_reddot == 120
		and s.sens_sniper == 60 and s.difficulty == 2, "a version 4 file keeps its settings")
	_check(s.vibration == true and s.vibrate_footsteps == true and s.show_fps == false and s.sens_fire == 100 and s.dynamic_joystick == true
		and not s.has("crosshair_color") and not s.has("crosshair_size"), "a version 4 file's fixed values give way to version 6's")
	_check(s.sens_freelook == 150 and s.sens_2x == 120, "free look and 2x start at General and Red Dot (%s, %s)" % [s.sens_freelook, s.sens_2x])
	_check(s.graphics_auto == false, "a player who picked a graphics level keeps it (AUTO off)")
	_check(s.mode == "training" and s.damage_numbers == true and not s.has("bogus"), "fixed behaviour wins, unknown keys are dropped")
	_check(typeof(s.sens_freelook) == TYPE_INT and typeof(s.graphics) == TYPE_INT, "numbers read from JSON are whole numbers again")
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings({"settings_version": 4, "graphics": 1})
	_check(Game.settings.graphics_auto == true and Game.settings.sens_freelook == 100, "at the default graphics level AUTO stays on")
	# A version 5 file: what version 6 dropped goes, a master volume turned down goes into the others,
	# the joystick and free look take the reference's defaults, vibration off stays off everywhere.
	var v5: Dictionary = JSON.parse_string(JSON.stringify({"settings_version": 5, "mode": "lonewolf", "graphics_auto": false,
		"show_fps": true, "vibration": false, "crosshair_color": 3, "crosshair_size": 140, "sens_fire": 80,
		"sens_freelook": 90, "sens_2x": 110, "sens_general": 150, "dynamic_joystick": false, "freelook_button": true,
		"vol_master": 50, "vol_sfx": 90, "vol_music": 41, "vol_voice": 100, "left_fire": 1, "switch_button": false}))
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings(v5)
	s = Game.settings
	_check(s.mode == "lonewolf" and s.graphics_auto == false and s.sens_freelook == 90 and s.sens_2x == 110 and s.sens_general == 150
		and s.left_fire == 1 and s.switch_button == false, "a version 5 file keeps its settings")
	_check(s.show_fps == false and s.sens_fire == 100 and not s.has("crosshair_color") and not s.has("crosshair_size")
		and not s.has("vol_master"), "a version 5 file loses the FPS counter, crosshair, fire-button drag and master volume")
	_check(s.vol_sfx == 45 and s.vol_music == 21 and s.vol_voice == 50, "a master volume at 50 goes into effects, music and voice (%s, %s, %s)"
		% [s.vol_sfx, s.vol_music, s.vol_voice])
	_check(s.dynamic_joystick == true and s.freelook_button == false, "every player gets the reference's joystick and free look default")
	_check(s.vibration == false and s.vibrate_footsteps == false and s.vibrate_damage == false and s.vibrate_shooting == false,
		"vibration turned off stays off in every row")
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings({"settings_version": 5, "vol_master": Game.OLD_MASTER_DEFAULT, "vol_sfx": 70, "vibration": true})
	s = Game.settings
	_check(s.vol_sfx == 70 and s.vol_music == 45 and s.vibration == true and s.vibrate_footsteps == true and s.vibrate_damage == false,
		"a master volume left at its default changes nothing; vibration on gets the reference's rows")
	# Older files migrate as before: v1's 0-100 sensitivities are dropped.
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings({"settings_version": 1, "sens_general": 40, "sens_reddot": 40, "dynamic_joystick": false, "vol_music": 10})
	s = Game.settings
	_check(s.sens_general == 100 and s.sens_freelook == 100 and s.sens_2x == 100 and s.dynamic_joystick == true and s.vol_music == 10,
		"a version 1 file migrates as before")
	# A version 6 file keeps its choices.
	var v6: Dictionary = JSON.parse_string(JSON.stringify({"settings_version": 6, "dynamic_joystick": false, "freelook_button": true,
		"vibrate_damage": true, "vibrate_footsteps": false, "vibration": false, "vol_sfx": 33}))
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings(v6)
	s = Game.settings
	_check(s.dynamic_joystick == false and s.freelook_button == true and s.vibrate_damage == true and s.vibrate_footsteps == false
		and s.vibration == false and s.vol_sfx == 33, "a version 6 file keeps the joystick, free look, vibration and volumes chosen")
	# DELETE MY DATA's reset: a new install's settings, AUTO graphics measuring again (automated:
	# AUTO guesses nothing).
	var at := Game.autotest
	var pending := Game.auto_graphics_pending
	Game.autotest = "unit"
	Game.settings.merge({"graphics_auto": false, "graphics": 3, "vibrate_damage": true, "mode": "lonewolf"}, true)
	Game.reset_settings()
	s = Game.settings
	_check(s.graphics_auto == true and s.vibrate_damage == false and s.mode == "training" and s.show_fps == false
		and s.sens_fire == 100 and s.settings_version == Game.SETTINGS_VERSION, "reset_settings: as on a new install")
	Game.autotest = at
	Game.auto_graphics_pending = pending
	Game.settings = saved
	Game.apply_settings()


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
	Game.settings.left_fire = HUD.LEFT_FIRE_OFF
	var left_off := not hud._button_visible("fire_l")
	Game.settings.merge({"left_fire": 0, "reload_button": false, "switch_button": false}, true)
	var quick_off := not hud._button_visible("reload") and not hud._button_visible("swap") and hud._button_visible("fire_l")
	hud.editor_mode = true
	var placed := hud._button_visible("reload") and hud._button_visible("swap")
	hud.editor_mode = false
	Game.settings.merge({"reload_button": true, "switch_button": true}, true)
	_check(left_off and quick_off and placed and hud._button_visible("reload") and hud._button_visible("swap"),
		"LEFT FIRE can be off; RELOAD and SWITCH follow their settings; the editor still places them")
	hud.free()
	_check(d.reload_button == true and d.switch_button == true and d.reload_on_crosshair == true and d.hold_fire_scope == true
		and not Game.FIXED_SETTINGS.has("reload_on_crosshair") and not Game.FIXED_SETTINGS.has("hold_fire_scope"),
		"RELOAD, SWITCH, the reload ring and hold fire to scope start on, and they are settings now")
	var v5: Dictionary = JSON.parse_string(JSON.stringify({"settings_version": 5, "left_fire": 1, "reload_on_crosshair": true}))
	Game.settings = d.duplicate(true)
	Game._apply_saved_settings(v5)
	_check(Game.settings.left_fire == 1 and Game.settings.reload_button == true and Game.settings.switch_button == true,
		"a version 5 file keeps WHEN AIMING and gets the new buttons on")
	Game.settings.merge({"reload_button": "no", "left_fire": 5, "run_mode": -1, "freelook_button": 3}, true)
	Game._sanitize_settings()
	_check(Game.settings.reload_button == true and Game.settings.left_fire == 2 and Game.settings.run_mode == 0
		and Game.settings.freelook_button == false, "on/off, left fire and run mode values are checked")
	_check(d.run_mode == 2 and d.freelook_button == false and SettingsPanel.RUN_MODE_NAMES.size() == int(Game.SETTING_RANGES.run_mode[1]) + 1
		and SettingsPanel.RUN_MODE_NOTES.size() == SettingsPanel.RUN_MODE_NAMES.size(),
		"run mode TAP / DRAG / MIXED (MIXED as before), the free look button off (the reference's default)")
	_check(SettingsPanel.JOYSTICK_NAMES == ["DYNAMIC", "FIXED"] and SettingsPanel.JOYSTICK_NOTES.size() == 2 and d.dynamic_joystick == true,
		"the joystick DYNAMIC (the default, as the reference's) or FIXED")
	var hud2 := HUD.new()
	Game.settings.merge({"run_mode": 1, "freelook_button": false}, true)
	var drag_only := not hud2._button_visible("sprint") and not hud2._button_visible("freelook")
	Game.settings.merge({"run_mode": 0, "freelook_button": true}, true)
	_check(drag_only and hud2._button_visible("sprint") and hud2._button_visible("freelook"), "DRAG hides the sprint button; the free look button follows its setting")
	hud2.free()
	Game.settings = d.duplicate(true)
	_check(SettingsPanel.LEFT_FIRE_VALUES.size() == SettingsPanel.LEFT_FIRE_NAMES.size() and SettingsPanel.LEFT_FIRE_VALUES[0] == HUD.LEFT_FIRE_OFF
		and SettingsPanel.LEFT_FIRE_NAMES[SettingsPanel.LEFT_FIRE_VALUES.find(0)] == "ALWAYS", "LEFT FIRE offers OFF / ALWAYS / WHEN AIMING")
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
## back), the presets set all five sensitivities, and the screen's controls do what they say: the
## reference's groups (DISPLAY; CONTROLS with VIBRATION; ACCOUNT with the cache, DELETE MY DATA and
## the two documents), HOW TO PLAY under the tabs, the pages over the panel that back closes first.
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
	_check(SettingsPanel.TABS == ["DISPLAY", "SENSITIVITY", "CONTROLS", "SOUND", "ONLINE", "ACCOUNT"] and SettingsPanel.ORDER == [0, 2, 1, 3, 4, 5],
		"the tabs: DISPLAY, CONTROLS, SENSITIVITY, SOUND, ONLINE, ACCOUNT")
	_check(SettingsPanel.TAB_KEYS[0] == ["graphics_auto", "graphics", "fps", "visual_effects"], "DISPLAY: graphics (AUTO), frame rate, visual effects")
	_check(["dynamic_joystick", "aim_precision", "left_fire", "freelook_button", "vibrate_footsteps", "vibrate_damage", "vibrate_shooting"].all(
		func(k: String) -> bool: return k in SettingsPanel.TAB_KEYS[2]), "CONTROLS: joystick, aim precision, left fire, free look and the vibration rows")
	_check(SettingsPanel.TAB_KEYS[3] == ["vol_sfx", "vol_music", "vol_voice"] and "vibration" in SettingsPanel.TAB_KEYS[4]
		and (SettingsPanel.TAB_KEYS[5] as Array).is_empty(), "SOUND: effects, music, voice; ONLINE: the lobby's vibration; ACCOUNT: no setting")
	_check(SettingsPanel.VIBRATION_ROWS.map(func(r: Array) -> String: return String(r[1])) == ["vibrate_footsteps", "vibrate_damage", "vibrate_shooting"],
		"VIBRATION: enemy footsteps, taking damage, shooting")
	var sens: Array = SettingsPanel.TAB_KEYS[1]
	_check(sens == SettingsPanel.SENS_ROWS.map(func(r: Array) -> String: return String(r[1])) and sens.size() == 5 and not ("sens_fire" in sens),
		"SENSITIVITY shows its five rows in order (no fire-button drag)")
	_check(SettingsPanel.PRESET_NAMES == ["STANDARD", "FAST"] and SettingsPanel.SENS_PRESETS.size() == 2, "two presets: STANDARD and FAST")
	var dp: Dictionary = SettingsPanel.SENS_PRESETS.STANDARD
	var fp: Dictionary = SettingsPanel.SENS_PRESETS.FAST
	_check(dp.size() == 5 and sens.all(func(k: String) -> bool: return dp.has(k) and int(dp[k]) == int(Game.DEFAULT_SETTINGS[k])),
		"the STANDARD preset is the defaults of all five")
	var in_range := fp.size() == 5
	for k: String in sens:
		var lim: Array = Game.SETTING_RANGES[k]
		in_range = in_range and fp.has(k) and int(fp[k]) >= int(lim[0]) and int(fp[k]) <= int(lim[1])
	_check(in_range and int(fp.sens_general) > int(dp.sens_general), "the FAST preset sets all five, faster, within range")
	_check(SettingsPanel.PRECISION_NAMES.size() == int(Game.SETTING_RANGES.aim_precision[1]) + 1
		and SettingsPanel.PRECISION_NOTES.size() == SettingsPanel.PRECISION_NAMES.size()
		and SettingsPanel.LEFT_FIRE_NAMES.size() == int(Game.SETTING_RANGES.left_fire[1]) + 1, "every aim precision and left fire value has a choice")
	# The screen itself (automated: AUTO guesses nothing, nothing is saved).
	var saved := Game.settings.duplicate(true)
	var saved_pending := Game.auto_graphics_pending
	var saved_at := Game.autotest
	Game.autotest = "unit"
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game.settings.merge(Game.FIXED_SETTINGS, true)
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
		"a confirmed RESET on SENSITIVITY restores all five")
	panel._apply_preset(1)
	_check(panel._preset_index() == 1 and Game.settings.sens_2x == fp.sens_2x and Game.settings.sens_freelook == fp.sens_freelook,
		"the FAST preset applies all five")
	var slider: HSlider = (panel._sens_rows.sens_freelook as Control).get_meta("slider")
	slider.value = 90
	_check(Game.settings.sens_freelook == 90 and panel._preset_index() == -1, "a slider moved off the preset applies at once")
	panel._show_tab(2)
	panel._set_precision(2)
	_check(Game.settings.aim_precision == 2 and panel._aim_note.text == SettingsPanel.PRECISION_NOTES[2], "aim precision applies and explains itself")
	var joy := panel.find_child("Toggle_dynamic_joystick", true, false)
	_check(joy != null and (joy.get_child(0) as Button).text == "DYNAMIC" and (joy.get_child(0) as Button).button_pressed,
		"MOVEMENT: the joystick reads DYNAMIC first, picked by default")
	panel._set_joystick(1)
	_check(Game.settings.dynamic_joystick == false and panel._joy_note.text == SettingsPanel.JOYSTICK_NOTES[1], "FIXED keeps the stick in its place")
	for r: Array in SettingsPanel.VIBRATION_ROWS:
		_check(panel.find_child("Toggle_" + String(r[1]), true, false) != null, "CONTROLS has the vibration row %s" % r[0])
	_check(panel.find_child("CrosshairColor", true, false) == null and panel.find_child("CrosshairSize", true, false) == null
		and panel.find_child("CrosshairPreview", true, false) == null and panel.find_child("AimPrecision", true, false) != null
		and panel.find_child("LeftFire", true, false) != null, "CONTROLS: aim precision and the left fire button, no crosshair colour or size")
	Game.settings.merge({"dynamic_joystick": false, "left_fire": 1, "vibrate_damage": true, "freelook_button": true}, true)
	panel._reset_tab()
	_check(Game.settings.dynamic_joystick == true and Game.settings.aim_precision == 0 and Game.settings.left_fire == 0
		and Game.settings.vibrate_damage == false and Game.settings.freelook_button == false,
		"RESET on CONTROLS restores the joystick, aim precision, left fire, free look and the vibration rows")
	panel._show_tab(0)
	var gseg := panel.find_child("GraphicsChoice", true, false)
	_check(gseg != null and gseg.get_child_count() == 5, "graphics: AUTO and the four levels")
	_check(panel.find_child("Toggle_show_fps", true, false) == null and panel.find_child("Toggle_vibration", true, false) == null
		and panel.find_child("ClearCache", true, false) == null, "DISPLAY: no FPS counter, vibration or cache rows")
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
	panel._apply("vibrate_shooting", true)
	_check(changes[0] == 1 and Game.vibration_on("shooting"), "a setting the game reads live does not re-apply the scene")
	Game.settings_changed.disconnect(count)
	Game.settings.merge({"fps": 30, "graphics_auto": false, "graphics": 3}, true)
	panel._reset_tab()
	_check(Game.settings.fps == 60 and Game.settings.graphics_auto == true and Game.settings.visual_effects == true,
		"RESET on DISPLAY: 60 FPS, effects on, AUTO graphics")
	# ACCOUNT: the player ID, CLEAR CACHE, the links along the bottom; no RESET there.
	panel._show_tab(5)
	var reset := panel.find_child("Reset", true, false) as Control
	_check(reset != null and not reset.visible and panel.find_child("PlayerIdValue", true, false) != null
		and panel.find_child("CopyId", true, false) != null, "ACCOUNT: the player ID with COPY, no RESET")
	var links := panel.find_child("AccountLinks", true, false) as Control
	_check(links != null and links.find_child("DeleteData", false, false) != null and links.find_child("TermsLink", false, false) != null
		and links.find_child("PrivacyLink", false, false) != null and not panel._hint.visible,
		"ACCOUNT's bottom: DELETE MY DATA, the Terms of Use and the Privacy Notice in the hint's place")
	for b in links.find_children("*", "Button", false, false):
		_check((b as Control).get_combined_minimum_size().y >= UI.TOUCH_MIN, "the link %s is a full touch target" % b.name)
	var clear_btn := panel.find_child("ClearCache", true, false) as Button
	if clear_btn:
		DirAccess.make_dir_recursive_absolute("user://shader_cache")
		var cf := FileAccess.open("user://shader_cache/panel_check.cache", FileAccess.WRITE)
		cf.store_string("cache")
		cf.close()
		clear_btn.pressed.emit()
	var asked := panel._ask_layer != null and FileAccess.file_exists("user://shader_cache/panel_check.cache")
	if asked:
		(panel._ask_layer.find_child("ConfirmOk", true, false) as Button).pressed.emit()
	_check(clear_btn != null and asked and not FileAccess.file_exists("user://shader_cache/panel_check.cache")
		and panel._cache_note.text.begins_with("Freed"), "ACCOUNT: CLEAR CACHE asks first, then says what it freed")
	(links.find_child("PrivacyLink", false, false) as Button).pressed.emit()
	var sheet := panel.find_child("Sheet", false, false)
	_check(sheet != null and sheet.find_child("DocScroll", true, false) != null and sheet.find_child("SheetOk", true, false) != null,
		"the Privacy Notice opens as a page over the settings")
	panel.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(panel._sheet == null and panel.is_inside_tree() and not panel.is_queued_for_deletion(), "back closes the page, not the settings")
	(links.find_child("TermsLink", false, false) as Button).pressed.emit()
	(panel._sheet.find_child("SheetOk", true, false) as Button).pressed.emit()
	_check(panel._sheet == null, "the Terms of Use open too; OK closes them")
	(links.find_child("DeleteData", false, false) as Button).pressed.emit()
	_check(panel._ask_layer != null and panel._ask_layer.find_child("ConfirmOk", true, false) != null, "DELETE MY DATA asks first")
	(panel._ask_layer.find_child("ConfirmOk", true, false) as Button).pressed.emit()
	var second := panel._ask_layer
	_check(second != null and _label_under(second, "ARE YOU SURE?"), "and asks a second time")
	(second.find_child("ConfirmCancel", true, false) as Button).pressed.emit()
	_check(panel._ask_layer == null and panel.find_child("Erasing", false, false) == null and not panel.busy,
		"CANCEL the second time deletes nothing")
	# HOW TO PLAY under the tabs: a page with both modes on top; back closes it, not the settings.
	(panel.find_child("HowToPlay", false, false) as Button).pressed.emit()
	var modes := panel._sheet.find_child("HowToModes", true, false) if panel._sheet else null
	_check(modes != null and modes.get_child_count() == Game.MODE_NAMES.size(), "HOW TO PLAY opens from the settings with the modes on top")
	panel.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(panel._sheet == null and not panel.is_queued_for_deletion(), "back closes HOW TO PLAY first")
	panel._ask_reset()
	panel.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	_check(panel._ask_layer == null and panel.is_inside_tree() and not panel.is_queued_for_deletion(), "back closes the question, not the settings")
	panel.busy = true
	panel.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	panel._close()
	_check(not panel.is_queued_for_deletion(), "while a task runs (busy) back and the X leave the settings open")
	panel.busy = false
	panel.free()
	# In a match DELETE MY DATA is a note (the lobby's), the documents still open.
	var in_match := SettingsPanel.new()
	in_match.in_match = true
	add_child(in_match)
	in_match._show_tab(5)
	_check(in_match.find_child("DeleteData", true, false) == null and in_match.find_child("DeleteNote", true, false) != null
		and in_match.find_child("PrivacyLink", true, false) != null, "in a match DELETE MY DATA waits for the lobby")
	in_match.free()
	Game.settings = saved
	Game.auto_graphics_pending = saved_pending
	Game.autotest = saved_at
	Game.apply_settings()


## Whether a Label under `root` reads `text` (a section title is upper case).
func _label_under(root: Node, text: String) -> bool:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == text:
			return true
	return false


## DELETE MY DATA (Settings, ACCOUNT): Cloud.forget_me asks the relay to delete, with empty
## retained messages, everything this id left there or has waiting there (the player card, friend
## requests and answers either way, the last chat messages either way), then leaves it (DISCONNECT
## last) and forgets the key; offline it tells the relay nothing but forgets all the same.
## SettingsAccount.forget_everything resets the game's memory as on a new install (the guest login
## comes back); erase_files deletes the saves, keys and caches, never another file.
func _test_delete_my_data() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var saved_settings := Game.settings.duplicate(true)
	var saved_cloud := Game.cloud
	var saved_lan := Game.lan
	var at := Game.autotest
	var pending := Game.auto_graphics_pending
	Game.autotest = "unit"          # nothing is written to user:// (and AUTO guesses nothing)
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var me := "me-key".sha256_text().left(32)
	var f := "friend-f".sha256_text().left(32)
	var o := "asked-o".sha256_text().left(32)
	var i := "asker-i".sha256_text().left(32)
	var w := "withdrawn-w".sha256_text().left(32)
	Game.profile.friends[f] = {"name": "FRED"}
	Game.profile.friend_out[o] = {"name": "OLGA", "t": 1}
	Game.profile.friend_in[i] = {"name": "IGOR", "t": 1}
	Game.profile.withdrawn = [w]
	var cl := RecordingCloud.new()
	cl.my_id = me
	cl._connected = true
	cl._want_lobby = true
	cl.status = "online"
	cl.relay_rtt = 40
	cl.peers[f] = {"name": "FRED", "bundle": "default", "pk": "", "seen": 0}
	cl.directory[o] = {"name": "OLGA", "bundle": "default", "pk": "", "ts": 1}
	cl._dir_wants["window"] = true
	cl.room_code = "123456"
	var told := cl.forget_me()
	var topics := {}
	var empty_retained := not cl.published.is_empty()
	for m: Array in cl.published:
		topics[String(m[0])] = true
		empty_retained = empty_retained and int(m[1]) == 0 and bool(m[2])
	var r := Cloud.ROOT
	var want := [r + "/p/" + me, r + "/fr/" + o + "/" + me, r + "/fa/" + me + "/" + o, r + "/fr/" + w + "/" + me,
		r + "/fa/" + me + "/" + w, r + "/fr/" + me + "/" + i, r + "/fa/" + f + "/" + me, r + "/fm/" + f + "/" + me,
		r + "/fm/" + me + "/" + f]
	_check(told and empty_retained and topics.size() == want.size() and want.all(func(t: String) -> bool: return topics.has(t)),
		"forget_me deletes the card, the requests and answers either way and the chat messages either way (%s)" % str(topics.keys()))
	_check(not cl.packets.is_empty() and cl.packets.back() == PackedByteArray([0xE0, 0x00]), "then it leaves the relay (DISCONNECT last)")
	_check(cl.my_id == "" and cl._key == null and cl._pk_pem == "" and not cl._want_lobby and not cl._connected and cl.peers.is_empty()
		and cl.directory.is_empty() and cl._dir_wants.is_empty() and cl.room_code == "" and cl.status == "offline" and cl.relay_rtt == -1,
		"and forgets the key, the id, the lists and the custom room")
	var off := RecordingCloud.new()
	off.my_id = me
	_check(not off.forget_me() and off.published.is_empty() and off.my_id == "", "offline the relay is told nothing; the id goes all the same")
	off.free()
	cl.free()
	# The game's memory, as on a new install.
	var gone := RecordingCloud.new()
	gone.my_id = me
	gone._connected = true
	Game.cloud = gone
	Game.lan = null
	NetChat.reset_for_test()
	NetChat.add(f, 100, true, "SEE YOU")
	Game.hud_layout = {"_v": 3, "fire_r": {"x": 0.5}}
	Game.practice = true
	Game.room_rules = {"rounds": 3}
	Game.match_notice = ["T", "X"]
	Game.settings.merge({"vibrate_damage": true, "dynamic_joystick": false, "mode": "lonewolf"}, true)
	var told_all := SettingsAccount.forget_everything()
	_check(told_all and gone.my_id == "" and not gone.published.is_empty(), "forget_everything tells the relay through the online service")
	_check(Game.profile.hash() == Game.DEFAULT_PROFILE.hash() and not bool(Game.profile.guest_ok) and Game.hud_layout.is_empty()
		and not Game.practice and Game.room_rules.is_empty() and Game.match_notice.is_empty() and not Game.online,
		"forget_everything: a new profile (the guest login comes back), no HUD layout, nothing of the session")
	_check(Game.settings.vibrate_damage == false and Game.settings.dynamic_joystick == true and Game.settings.mode == "training",
		"forget_everything: a new install's settings")
	_check(NetChat.messages(f).is_empty() and NetChat.unread_total() == 0, "forget_everything: no chats")
	gone.free()
	Game.cloud = saved_cloud
	Game.lan = saved_lan
	NetChat.reset_for_test()
	# The files: every save, backup, leftover and key at the top, and the caches; nothing else.
	var root := "user://erase_check"
	var files := ["profile.json", "profile.json.bak", "settings.json", "settings.json.tmp", "hud_layout.json", "chat.json",
		"net_identity.key", "net_identity_host.key", "notes.txt", "shader_cache/a1/s.cache", "logs/godot.log",
		"logs/godot2026-11-01T10.00.00.log", "keep/inner.json"]
	for rel: String in files:
		var path := root.path_join(rel)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var fa := FileAccess.open(path, FileAccess.WRITE)
		fa.store_string("{\"a\": 1}")
		fa.close()
	var n := SettingsAccount.erase_files(root)
	var left := []
	for rel: String in files:
		if FileAccess.file_exists(root.path_join(rel)):
			left.append(rel)
	_check(n == 10 and left == ["notes.txt", "logs/godot.log", "keep/inner.json"],
		"erase_files deletes the saves, backups, leftovers, keys and caches, nothing else (%d, left %s)" % [n, str(left)])
	for rel: String in left:
		DirAccess.remove_absolute(root.path_join(rel))
	for dir: String in ["shader_cache/a1", "shader_cache", "logs", "keep", ""]:
		DirAccess.remove_absolute(root.path_join(dir))
	Game.profile = saved_profile
	Game.settings = saved_settings
	Game.autotest = at
	Game.auto_graphics_pending = pending
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
		"friend_out", "withdrawn"].filter(func(k: String) -> bool: return not d.has(k))
	_check(missing.is_empty(), "the profile has the new keys (missing %s)" % [missing])
	_check(d.profile_version == Game.PROFILE_VERSION and d.guest_ok == false and d.created == 0 and d.avatar == "emblem"
		and d.banner == "default" and d.signature == "" and d.recent.is_empty() and d.blocked.is_empty()
		and d.friend_in.is_empty() and d.friend_out.is_empty() and d.withdrawn.is_empty(), "the new profile keys start empty")
	_check(Game.PROFILE_COUNTERS.all(func(k: String) -> bool: return d[k] == 0)
		and Game.RECORD_MODES.keys().all(func(m: String) -> bool: return d.modes[m] == {"matches": 0, "wins": 0, "kills": 0}),
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
		"friends": pals, "withdrawn": [ids[3], 7, "zz", ids[3]] + ids.slice(4, 60)}, true)
	Game._sanitize_profile()
	var p := Game.profile
	_check(p.guest_ok == false and p.created == 0 and p.avatar == "emblem" and p.banner == "default",
		"profile: a wrong flag, time, avatar or banner falls back")
	_check(p.signature == "BHELLOB WORLD THE VERY BEST PL", "profile: the signature keeps name characters, 30 at most (%s)" % p.signature)
	_check(p.deaths == 0 and p.damage == 3 and typeof(p.damage) == TYPE_INT and p.time_played == 0 and p.rounds_won == 4
		and typeof(p.rounds_won) == TYPE_INT and p.rounds_lost == 2, "profile: counters are whole numbers, never negative")
	_check(p.hits == 10 and p.headshots == 10, "profile: hits never exceed shots, headshots never exceed hits")
	_check(p.modes.keys() == Game.RECORD_MODES.keys() and p.modes.training == {"matches": 3, "wins": 3, "kills": 0}
		and p.modes.lonewolf == {"matches": 0, "wins": 0, "kills": 0}, "profile: one set of numbers per mode, wins never above matches")
	_check(p.recent.size() == Game.MAX_RECENT and p.recent[0] == {"id": ids[0], "name": "FOE 0", "t": 1700000000}
		and p.recent[1].id == ids[1] and p.recent[19].id == ids[19], "profile: 20 recent players at most, newest first, each once")
	_check(p.blocked.size() == Game.MAX_BLOCKED and p.blocked.map(func(e: Dictionary) -> String: return e.id) == ids.slice(0, 50)
		and p.blocked[0] == {"id": ids[0], "name": "", "t": 0}, "profile: 50 blocks at most, valid ids each once; a bare id is a block without a name")
	_check(p.withdrawn == ids.slice(3, 53), "profile: 50 requests to delete at most, valid ids each once (%d)" % p.withdrawn.size())
	for k in ["friend_in", "friend_out"]:
		var r: Dictionary = p[k]
		_check(r.size() == Game.MAX_REQUESTS and r.has(ids[0]) and not r.has("bad") and not r.has(ids[65]) and not r.has(ids[50])
			and r[ids[0]] == {"name": "ASKER 0", "t": 0} and r[ids[1]].t == 1700000000, "profile: %s keeps 50 valid requests" % k)
	_check(p.friends.size() == Game.MAX_FRIENDS and p.friends[ids[0]] == {"name": "PAL 0"}, "profile: 50 friends at most")
	Game.profile.blocked = [{"id": ids[1], "name": "  rude guy! ", "t": 1700000000}, {"id": ids[1], "name": "AGAIN"}, {"id": "zz"},
		{"name": "X"}, ids[2], 42, {"id": ids[3], "name": 5, "t": -4}]
	Game._sanitize_profile()
	_check(Game.profile.blocked == [{"id": ids[1], "name": "RUDE GUY", "t": 1700000000}, {"id": ids[2], "name": "", "t": 0},
		{"id": ids[3], "name": "", "t": 0}], "profile: a block keeps a cleaned name and its time (%s)" % str(Game.profile.blocked))
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
		"requests to delete": func(x: Dictionary) -> void: (x.withdrawn as Array).append(ids[4]),
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
## version 1, from version 2 (before HISTORY), version 3, and an edited one.
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
	# A version 2 profile (from before HISTORY) keeps every key and starts with an empty HISTORY.
	var v2: Dictionary = Game.DEFAULT_PROFILE.duplicate(true)
	v2.merge({"name": "NEW ONE", "name_set": true, "guest_ok": false, "created": 1780000000, "avatar": "royal", "signature": "GG",
		"matches": 9, "wins": 4, "kills": 11, "xp": 900, "deaths": 7, "headshots": 3, "damage": 1800, "shots": 120, "hits": 40,
		"rounds_won": 20, "rounds_lost": 15, "time_played": 3600,
		"modes": {"training": {"matches": 6, "wins": 3, "kills": 8}, "lonewolf": {"matches": 3, "wins": 1, "kills": 2}},
		"recent": [{"id": "r".sha256_text().left(32), "name": "RIVAL", "t": 1780000100}], "blocked": ["b".sha256_text().left(32)],
		"friend_in": {"i".sha256_text().left(32): {"name": "ASKER", "t": 1780000200}},
		"friend_out": {"o".sha256_text().left(32): {"name": "ASKED", "t": 1780000300}}, "friends": {friend_id: {"name": "BUDDY"}}}, true)
	v2.profile_version = 2
	v2.erase("history")
	var v3: Dictionary = v2.duplicate(true)
	v3.profile_version = 3
	v3.history = []
	# (a profile from before DUO / SQUAD loads their numbers as zeros: Game.RECORD_MODES)
	v3.modes.merge({"duo": {"matches": 0, "wins": 0, "kills": 0}, "squad": {"matches": 0, "wins": 0, "kills": 0}})
	v3.blocked = [{"id": "b".sha256_text().left(32), "name": "", "t": 0}]       # a bare id is a block without a name
	_check(Game.PROFILE_VERSION == 3 and Game.DEFAULT_PROFILE.history == [], "version 3: a new profile has an empty HISTORY")
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	ok = Game._apply_saved_profile(_as_saved(v2))
	_check(ok and Game.profile == v3, "a version 2 profile keeps every key and gets an empty HISTORY")
	var odd: Dictionary = v2.duplicate(true)
	odd.history = [{"result": "won", "mode": "training", "enemy": "BOT REX", "id": "", "score": 5, "enemy_score": 0, "kills": 5,
		"damage": 900, "headshots": 2, "t": 1780000400}]
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	ok = Game._apply_saved_profile(_as_saved(odd))
	_check(ok and (Game.profile.history as Array).is_empty(), "the migration to version 3 starts HISTORY empty, whatever the old save holds")
	# A version 3 profile loads back exactly, its HISTORY included.
	v3.history = odd.history.duplicate(true)
	v3.history.append({"result": "draw", "mode": "lonewolf", "enemy": "RIVAL", "id": "r".sha256_text().left(32), "score": 4,
		"enemy_score": 4, "kills": 4, "damage": 912, "headshots": 1, "t": 1780000300})
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	ok = Game._apply_saved_profile(_as_saved(v3))
	_check(ok and Game.profile == v3, "a version 3 profile loads back exactly (HISTORY kept, no second migration)")
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


## PROFILE's CAREER numbers (LobbyProfile.career_stats): counts, rates and averages, and "-" (no
## division by zero) while there is nothing to divide by; junk values count as 0.
func _test_career() -> void:
	var z := _career(Game.DEFAULT_PROFILE)
	_check(z.size() == 14 and z.matches == "0" and z.wins == "0" and z.kills == "0" and z.deaths == "0" and z.headshots == "0"
		and z.damage == "0" and z.rounds_won == "0" and z.rounds_lost == "0" and z.time_played == "0M", "CAREER of a new player: every count is 0")
	_check(z.win_rate == "-" and z.kd == "-" and z.headshot_rate == "-" and z.accuracy == "-" and z.avg_damage == "-",
		"CAREER of a new player: no rate or average without data (%s)" % str(z))
	var p: Dictionary = Game.DEFAULT_PROFILE.duplicate(true)
	p.merge({"matches": 48, "wins": 29, "kills": 151, "deaths": 97, "headshots": 63, "hits": 702, "shots": 1880, "damage": 61234,
		"time_played": 30250, "rounds_won": 178, "rounds_lost": 131}, true)
	var n := _career(p)
	_check(n.matches == "48" and n.win_rate == "60.4%" and n.kd == "1.56" and n.headshot_rate == "9.0%" and n.accuracy == "37.3%",
		"CAREER rates: wins per match, kills per death, headshots per hit, hits per shot (%s)" % str(n))
	_check(n.damage == "61,234" and n.avg_damage == "1,276" and n.time_played == "8H 24M" and n.rounds_won == "178" and n.rounds_lost == "131",
		"CAREER totals and the average damage per match (%s, %s, %s)" % [n.damage, n.avg_damage, n.time_played])
	p.merge({"matches": 3, "wins": 0, "kills": 5, "deaths": 0, "shots": 0, "hits": 0, "headshots": 0, "damage": 0}, true)
	n = _career(p)
	_check(n.kd == "5.00" and n.accuracy == "-" and n.headshot_rate == "-" and n.win_rate == "0.0%" and n.avg_damage == "0",
		"CAREER with zeros on one side: K/D before the first death, no shots, no wins (%s)" % str(n))
	n = _career({"matches": "lots", "wins": -4, "kills": null, "hits": 9, "shots": 3, "time_played": [1]})
	_check(n.matches == "0" and n.wins == "0" and n.win_rate == "-" and n.kills == "0" and n.accuracy == "100.0%" and n.time_played == "0M",
		"CAREER reads junk as 0 and keeps a rate within 100 %% (%s)" % str(n))
	p.modes = {"training": {"matches": 6, "wins": 3, "kills": 8}}
	_check(LobbyProfile.mode_stats(p, "training") == {"matches": 6, "wins": 3, "kills": 8}
		and LobbyProfile.mode_stats(p, "lonewolf") == {"matches": 0, "wins": 0, "kills": 0}
		and LobbyProfile.mode_stats({"modes": 7}, "training") == {"matches": 0, "wins": 0, "kills": 0}, "CAREER's row per mode, 0 when missing")
	_check(LobbyProfile.play_time(59) == "0M" and LobbyProfile.play_time(3600) == "1H 00M" and LobbyProfile.play_time(-5) == "0M"
		and LobbyProfile.thousands(1234567) == "1,234,567" and LobbyProfile.thousands(999) == "999" and LobbyProfile.thousands(1000) == "1,000",
		"time played and thousands separators")
	var now := 1790000000
	_check(LobbyProfile.time_ago(0, now) == "" and LobbyProfile.time_ago(now - 30, now) == "JUST NOW"
		and LobbyProfile.time_ago(now - 300, now) == "5 MIN AGO" and LobbyProfile.time_ago(now - 7200, now) == "2 H AGO"
		and LobbyProfile.time_ago(now - 86400, now) == "1 DAY AGO" and LobbyProfile.time_ago(now - 3 * 86400, now) == "3 DAYS AGO"
		and LobbyProfile.time_ago(now + 500, now) == "JUST NOW", "how long ago a match was")
	_check(LobbyProfile.since_text(1780000000, now).begins_with("PLAYING SINCE ") and LobbyProfile.since_text(1780000000, now).ends_with(" 2026")
		and LobbyProfile.since_text(0, now) == LobbyProfile.since_text(now, now), "PLAYING SINCE: the first save's date (today before it)")


## career_stats as {key: shown value}.
func _career(p: Dictionary) -> Dictionary:
	var out := {}
	for s: Array in LobbyProfile.career_stats(p):
		out[s[0]] = s[2]
	return out


## HISTORY: Game.record_match adds the match (newest first, Game.MAX_HISTORY at most) and the
## CAREER numbers; saved entries are checked like every saved key; the signature covers them.
func _test_history() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var saved_result: Dictionary = Game.last_result
	var at := Game.autotest
	Game.autotest = "unit"          # nothing is written to user://
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var rival := "rival".sha256_text().left(32)
	Game.record_match({"won": true, "kills": 5, "damage": 1176, "headshots": 3, "xp": 330, "mode_id": "training", "enemy": "BOT VIPER",
		"score_player": 5, "score_bot": 2, "time": 412.5, "shots": 60, "hits": 28, "deaths": 2, "enemy_id": ""})
	Game.record_match({"won": false, "draw": true, "kills": 4, "damage": 912, "headshots": 1, "xp": 150, "mode_id": "lonewolf",
		"enemy": "night fox!", "score_player": 4, "score_bot": 4, "time": 380.0, "shots": 50, "hits": 20, "deaths": 4, "enemy_id": rival})
	var h: Array = Game.profile.history
	_check(h.size() == 2 and h[0].result == "draw" and h[0].mode == "lonewolf" and h[0].enemy == "NIGHT FOX" and h[0].id == rival
		and h[0].score == 4 and h[0].enemy_score == 4 and h[0].kills == 4 and h[0].damage == 912 and h[0].headshots == 1
		and h[1].result == "won" and h[1].mode == "training" and h[1].enemy == "BOT VIPER" and h[1].id == "" and h[1].score == 5
		and h[1].enemy_score == 2, "HISTORY keeps each match, newest first (%s)" % str(h))
	_check((h[0] as Dictionary).size() == 10 and int(h[0].t) > 1600000000, "a HISTORY entry: the ten keys, the time it ended")
	var p := Game.profile
	_check(p.deaths == 6 and p.headshots == 4 and p.damage == 2088 and p.shots == 110 and p.hits == 48 and p.rounds_won == 9
		and p.rounds_lost == 6 and p.time_played == 792 and p.wins == 1 and p.kills == 9, "record_match counts the CAREER numbers")
	_check(p.recent.size() == 1 and p.recent[0].id == rival and p.recent[0].name == "NIGHT FOX", "an online opponent becomes a recent player")
	# QUIT MATCH (Arena.record_left): HISTORY says LEFT, never a win; what was played counts.
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game.record_match({"won": true, "left": true, "kills": 1, "damage": 240, "xp": 0, "mode_id": "training", "enemy": "BOT ONYX",
		"score_player": 1, "score_bot": 0, "time": 95.0, "shots": 12, "hits": 6, "deaths": 0, "enemy_id": ""})
	h = Game.profile.history
	_check(h.size() == 1 and h[0].result == "left" and h[0].score == 1 and h[0].kills == 1 and Game.profile.wins == 0
		and Game.profile.modes.training.wins == 0 and Game.profile.kills == 1 and Game.profile.rounds_won == 1 and Game.profile.time_played == 95,
		"a match left with QUIT MATCH: HISTORY says LEFT, no win, what was played counts")
	Game.profile.history = [{"result": "left", "mode": "lonewolf", "enemy": "RIVAL"}]
	Game._sanitize_profile()
	_check(Game.profile.history.size() == 1 and Game.profile.history[0].result == "left", "a saved LEFT entry is kept")
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game.record_match({"won": false, "kills": 0, "mode_id": "training", "enemy": "BOT KAI", "shots": 5, "hits": 9, "headshots": 30})
	p = Game.profile
	_check(p.shots == 5 and p.hits == 5 and p.headshots == 5, "hits never above shots, headshots never above hits")
	for i in 25:
		Game.record_match({"won": i % 2 == 0, "kills": i % 3, "mode_id": "training", "enemy": "BOT %d" % i, "score_player": 1})
	h = Game.profile.history
	_check(h.size() == Game.MAX_HISTORY and h[0].enemy == "BOT 24" and h[19].enemy == "BOT 5" and h[0].result == "won"
		and h[1].result == "lost", "HISTORY keeps the last %d matches, newest first" % Game.MAX_HISTORY)
	# Saved entries are checked one by one: wrong ones are dropped, values clamped, names cleaned.
	var good := {"result": "lost", "mode": "lonewolf", "enemy": "RIVAL", "id": rival, "score": 2, "enemy_score": 5, "kills": 2,
		"damage": 537, "headshots": 1, "t": 1780000000}
	var saved := ["not a match", {"result": "champion"}, {"mode": "training"}, 42, good,
		{"result": "won", "mode": "royale", "enemy": "  [b]x[/b]  ", "id": "zz", "score": -3, "enemy_score": 500, "kills": 2.7,
			"damage": "a lot", "headshots": 1e9, "t": -5, "extra": "dropped"},
		{"result": "draw", "enemy": 42}]
	for i in 30:
		saved.append(good.duplicate())
	Game.profile.history = saved
	Game._sanitize_profile()
	h = Game.profile.history
	_check(h.size() == Game.MAX_HISTORY and h[0] == good, "saved HISTORY: unknown results dropped, %d entries at most" % Game.MAX_HISTORY)
	_check(h[1] == {"result": "won", "mode": "training", "enemy": "BXB", "id": "", "score": 0, "enemy_score": 99, "kills": 2, "damage": 0,
		"headshots": 9999, "t": 0}, "saved HISTORY: a bad mode, name, id or number is repaired (%s)" % str(h[1]))
	_check(h[2] == {"result": "draw", "mode": "training", "enemy": "PLAYER", "id": "", "score": 0, "enemy_score": 0, "kills": 0, "damage": 0,
		"headshots": 0, "t": 0}, "saved HISTORY: missing values are filled in")
	Game.profile.history = "nothing"
	Game._sanitize_profile()
	_check(Game.profile.history == [], "saved HISTORY that is not a list is emptied")
	# The signature covers HISTORY.
	Game.profile.history = [good.duplicate()]
	var parsed := _as_saved(Game.profile)
	_check(Guard.verify_dict(parsed).ok, "a profile with HISTORY verifies after a JSON round trip")
	var edited: Dictionary = parsed.duplicate(true)
	edited.history[0].kills = 40
	_check(not Guard.verify_dict(edited).ok, "the signature covers HISTORY")
	Game.profile = saved_profile
	Game.last_result = saved_result
	Game.autotest = at


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


## Player card v2 (Cloud.card_json): the public part of the profile (Cloud.my_card: name, outfit,
## picture, banner, level, signature) signed as a whole ("sig2"), still listed by builds from
## before (its "sig" signs the v1 text). On arrival (Cloud._check_card) a changed field fails,
## a card from an older build (no "v") is still listed, and every field is checked.
func _test_card_v2() -> void:
	var key := Crypto.new().generate_rsa(2048)
	var pk := key.save_to_string(true)
	var id := pk.sha256_text().left(32)
	var now := int(Time.get_unix_time_from_system())
	var c := {"name": "SWIFTWOLF42", "bundle": "neon", "avatar": "royal", "banner": "hive", "level": 12, "signature": "ONE MORE ROUND"}
	var card: Dictionary = JSON.parse_string(Cloud.card_json(c, id, pk, now, key))
	var keys := card.keys()
	keys.sort()
	_check(keys == ["avatar", "banner", "bundle", "id", "level", "name", "pk", "sig", "sig2", "signature", "t", "ts", "v"],
		"a v2 card carries the shown fields, the id, key, time and signatures, nothing else (%s)" % str(keys))
	var mine := Cloud.my_card().keys()
	mine.sort()
	_check(mine == ["avatar", "banner", "bundle", "career", "level", "name", "signature"], "my_card() is the whole public part of the profile")
	_check(int(card.v) == 2 and Cloud.verify_signed(pk, Cloud.card2_text(id, "SWIFTWOLF42", "neon", "royal", "hive", 12, "ONE MORE ROUND", now),
		String(card.sig2)), "sig2 signs every field of a v2 card")
	_check(Cloud.verify_signed(pk, Cloud.card_text(id, "SWIFTWOLF42", "neon", now), String(card.sig)),
		"a v2 card's sig still signs the v1 text, so older builds keep listing the player")
	var cl := Cloud.new()
	cl._check_card(JSON.stringify(card).to_utf8_buffer())
	var e: Dictionary = cl.directory.get(id, {})
	_check(e.get("v") == 2 and e.get("name") == "SWIFTWOLF42" and e.get("bundle") == "neon" and e.get("avatar") == "royal"
		and e.get("banner") == "hive" and e.get("level") == 12 and e.get("signature") == "ONE MORE ROUND" and e.get("ts") == now,
		"a v2 card is listed with every field (%s)" % str(e))
	# A changed field (anyone can publish to a public relay) fails the signature.
	for k: String in ["name", "bundle", "avatar", "banner", "level", "signature", "ts"]:
		var t := card.duplicate()
		t[k] = {"name": "FAKENAME", "bundle": "royal", "avatar": "shadow", "banner": "scope", "level": 99, "signature": "SEND ME GOLD",
			"ts": now - 5}[k]
		_check(not _card_listed(cl, t, id), "a v2 card with a changed %s is rejected" % k)
	var swapped := card.duplicate()
	swapped.sig2 = card.sig
	var no_sig2 := card.duplicate()
	no_sig2.erase("sig2")
	var other_key := card.duplicate()
	other_key.pk = Crypto.new().generate_rsa(2048).save_to_string(true)
	_check(not _card_listed(cl, swapped, id) and not _card_listed(cl, no_sig2, id) and not _card_listed(cl, other_key, id),
		"a v2 card needs its own sig2 from the key its id comes from")
	# A card from a build before v2 (no "v"): listed, the v2 fields at their defaults.
	var v1 := {"t": "card", "id": id, "name": "OLDTIMER", "bundle": "desert", "pk": pk, "ts": now,
		"sig": Cloud._sign_with(key, Cloud.card_text(id, "OLDTIMER", "desert", now))}
	_check(_card_listed(cl, v1, id) and cl.directory[id] == {"name": "OLDTIMER", "bundle": "desert", "pk": pk, "ts": now, "v": 1,
		"avatar": "emblem", "banner": "default", "level": 0, "signature": "", "career": {}},
		"a v1 card is still listed, with the default picture and banner")
	var v1_bad := v1.duplicate()
	v1_bad.name = "FAKENAME"
	_check(not _card_listed(cl, v1_bad, id), "a v1 card with a changed name is still rejected")
	# Stripped to v1, a v2 card shows only what its owner signed for v1, with the defaults.
	var stripped := card.duplicate()
	for k: String in ["v", "avatar", "banner", "level", "signature", "sig2"]:
		stripped.erase(k)
	_check(_card_listed(cl, stripped, id) and cl.directory[id].avatar == "emblem" and cl.directory[id].signature == ""
		and cl.directory[id].name == "SWIFTWOLF42", "a v2 card stripped to v1 shows only its owner's v1 fields")
	var explicit_v1 := card.duplicate()
	explicit_v1.v = 1
	_check(not _card_listed(cl, explicit_v1, id), "a card that says v 1 is not one (v1 cards carry no v)")
	# Field checks: properly signed values this build cannot show are mapped, malformed ones reject
	# the whole card.
	var shown := {"avatar": ["dragon", "emblem"], "banner": ["nope", "default"], "level": [5000, Cloud.CARD_LEVEL_MAX], "signature": ["gg, wp!", "GG WP"]}
	for k: String in shown:
		var bad := c.duplicate()
		bad[k] = shown[k][0]
		var bc: Dictionary = JSON.parse_string(Cloud.card_json(bad, id, pk, now, key))
		_check(_card_listed(cl, bc, id) and cl.directory[id][k] == shown[k][1],
			"a signed card's %s %s shows as %s" % [k, str(shown[k][0]), str(shown[k][1])])
	var zero := c.duplicate()
	zero.level = 0
	_check(_card_listed(cl, JSON.parse_string(Cloud.card_json(zero, id, pk, now, key)), id) and cl.directory[id].level == 1,
		"a level under 1 shows as 1")
	# [field, value, signed]: a signed value can only be stopped by the field check; the others
	# cannot even be signed as they are and go into the JSON after signing.
	var rejected := {"a negative level": ["level", -1, true], "a level that is not whole": ["level", 2.5, false],
		"a level as text": ["level", "12", false], "an avatar that is not text": ["avatar", 42, false],
		"a banner that is not text": ["banner", ["hive"], false], "no signature": ["signature", null, false],
		"a signature over the field limit": ["signature", "X".repeat(Cloud.CARD_FIELD_MAX + 1), true],
		"a | in the signature": ["signature", "GG|WP", true], "a | in the banner": ["banner", "hive|x", true],
		"a | in the name": ["name", "SWIFT|WOLF", true]}
	for what: String in rejected:
		var r: Array = rejected[what]
		var bad := c.duplicate()
		if r[2]:
			bad[r[0]] = r[1]
		var bc: Dictionary = JSON.parse_string(Cloud.card_json(bad, id, pk, now, key))
		if not r[2]:
			if r[1] == null:
				bc.erase(r[0])
			else:
				bc[r[0]] = r[1]
		_check(not _card_listed(cl, bc, id), "a card with %s is rejected" % what)
	var big := card.duplicate()
	big.padding = "X".repeat(Cloud.MAX_MESSAGE)
	_check(not _card_listed(cl, big, id), "a card over %d bytes is rejected" % Cloud.MAX_MESSAGE)
	# What the card shows in one string (card_key): a change of any field publishes it again.
	var saved_profile := Game.profile.duplicate(true)
	var k0 := Cloud.card_key(Cloud.my_card())
	var changed := 0
	for change: Array in [["name", "NEWNAME"], ["bundle", "royal"], ["avatar", "shadow"], ["banner", "scope"], ["signature", "HELLO"],
			["xp", 5000]]:
		Game.profile = saved_profile.duplicate(true)
		Game.profile[change[0]] = change[1]
		if Cloud.card_key(Cloud.my_card()) != k0:
			changed += 1
	_check(changed == 6, "a new name, outfit, picture, banner, signature or level changes the card (%d of 6)" % changed)
	Game.profile = saved_profile
	cl.free()


## Hands a card to a fresh directory (Cloud._check_card) and tells whether it was listed.
func _card_listed(cl: Cloud, card: Dictionary, id: String) -> bool:
	cl.directory.clear()
	cl._check_card(JSON.stringify(card).to_utf8_buffer())
	return cl.directory.has(id)


## Blocking: Game.block drops the friend and the requests either way (MAX_BLOCKED at most: one
## more lifts the oldest block), Game.unblock lifts it. The online service (Cloud) ignores a
## blocked player's challenge, acceptance, friend request, room request and room messages, and
## Cloud.drop_player ends what was going on with them: the challenge sent to them (they could
## still accept it), theirs, their seat in the hosted room and the friend request sent to them,
## whose deletion on the relay waits for the next connection when offline.
func _test_blocking() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var at := Game.autotest
	Game.autotest = "unit"          # nothing is written to user://
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var p := Game.profile
	var x := "blocked-x".sha256_text().left(32)     # the id the "public key" "blocked-x" makes
	var y := "player-y".sha256_text().left(32)
	var z := "player-z".sha256_text().left(32)
	p.friends[x] = {"name": "XENA"}
	p.friend_in[x] = {"name": "XENA", "t": 1}
	p.friend_out[x] = {"name": "XENA", "t": 1}
	p.friends[y] = {"name": "YURI"}
	Game.block(x)
	_check(Game.is_blocked(x) and not Game.is_blocked(y) and not Game.is_friend(x) and not p.friend_in.has(x)
		and not p.friend_out.has(x) and Game.is_friend(y), "a block drops the friend and the requests either way, nobody else's")
	Game.block(x)
	Game.block("not-an-id")
	_check(p.blocked.size() == 1, "a player is blocked once, a junk id never")
	Game.unblock(x)
	_check(not Game.is_blocked(x) and p.blocked.is_empty(), "UNBLOCK lifts the block")
	Game.block(x, " xena! ")
	_check(p.blocked.size() == 1 and p.blocked[0].id == x and p.blocked[0].name == "XENA" and int(p.blocked[0].t) > 1600000000
		and LobbyProfile.known_name(x) == "XENA" and LobbyProfile.who_label(x) == "XENA  #" + Cloud.friend_code(x),
		"a block keeps the name and the time: BLOCKED names the player after a restart")
	Game.unblock(x)
	var many := []
	for i in Game.MAX_BLOCKED:
		many.append(("pest%d" % i).sha256_text().left(32))
		Game.block(many[i], "PEST %d" % i if i == 0 else "")
	var full_question := LobbyProfile.block_question("NEWCOMER")
	_check(Game.block_lifts().get("id") == many[0] and full_question.contains("lifts your oldest block, PEST 0  #" + Cloud.friend_code(many[0])),
		"with BLOCKED full the BLOCK question names the block it lifts (%s)" % full_question)
	many.append(("pest%d" % Game.MAX_BLOCKED).sha256_text().left(32))
	Game.block(many[Game.MAX_BLOCKED])
	_check(p.blocked.size() == Game.MAX_BLOCKED and not Game.is_blocked(many[0]) and Game.is_blocked(many[1])
		and Game.is_blocked(many[Game.MAX_BLOCKED]), "at most %d blocks: one more lifts the oldest" % Game.MAX_BLOCKED)
	p.blocked.clear()
	_check(Game.block_lifts().is_empty() and not LobbyProfile.block_question("NEWCOMER").contains("oldest"),
		"with room in BLOCKED the question lifts nothing")
	# What the online service ignores from a blocked player (a control player y gets through).
	var cl := Cloud.new()
	cl.my_id = "me".sha256_text().left(32)
	var heard := {"invited": 0, "cancelled": 0, "room": 0, "friends": 0, "started": 0}
	cl.invited.connect(func(_who: String) -> void: heard.invited += 1)
	cl.invite_cancelled.connect(func() -> void: heard.cancelled += 1)
	cl.room_changed.connect(func() -> void: heard.room += 1)
	cl.friends_changed.connect(func() -> void: heard.friends += 1)
	cl.session_started.connect(func(_host: bool) -> void: heard.started += 1)
	Game.block(x)
	cl._on_inbox({"t": "inv", "from": x, "sec": "AAAA", "name": "XENA"})
	cl._on_inbox({"t": "frq", "from": x, "pk": "blocked-x", "name": "XENA"})
	cl.room_code = "123456"
	cl.room_pin = "1234"
	var room_key := cl._room_key("123456", "1234")
	cl._on_room_ask({"t": "ask", "from": x, "pk": "blocked-x", "name": "XENA", "mac": cl._room_tag(room_key, "ask", x)})
	_check(not cl.has_invite() and heard.invited == 0 and not p.friend_in.has(x) and cl.room_guest.is_empty(),
		"a blocked player's challenge, friend request and room request are ignored")
	cl._on_room_ask({"t": "ask", "from": y, "pk": "player-y", "name": "YURI", "mac": cl._room_tag(room_key, "ask", y)})
	_check(String(cl.room_guest.get("id", "")) == y, "an unblocked player with the password gets the room seat (control)")
	# A challenge sent before the block: their acceptance and their room's "join" start nothing.
	var keys := Crypto.new()
	var invite := {"id": x, "name": "XENA", "bundle": "default", "room": keys.generate_random_bytes(16).hex_encode(),
		"aes": keys.generate_random_bytes(32), "mac": keys.generate_random_bytes(32), "t": Time.get_ticks_msec()}
	var them := Cloud.new()
	them.my_id = x
	them._aes = invite.aes
	them._mac = invite.mac
	cl._outgoing = invite.duplicate()
	cl._enter_room(invite)
	cl._last_heard = 0
	cl._on_inbox({"t": "acc", "from": x, "mac": cl._tag(invite, "acc", x)})
	var acc_heard := cl._last_heard
	cl._on_room(them._room_packet({"k": "join"}))
	_check(acc_heard == 0 and not cl.in_session and heard.started == 0, "a blocked player's acceptance and room join start no match")
	Game.unblock(x)
	cl._on_inbox({"t": "acc", "from": x, "mac": cl._tag(invite, "acc", x)})
	acc_heard = cl._last_heard
	cl._on_room(them._room_packet({"k": "join"}))
	_check(acc_heard > 0 and cl.in_session and heard.started == 1, "the same acceptance and join from an unblocked player start it (control)")
	cl.end_session("left")
	# drop_player (BLOCK on a card) ends the challenge to them, theirs, their room seat and the
	# friend request sent to them; offline the request's deletion waits for the next connection.
	cl._outgoing = invite.duplicate()
	cl._enter_room(invite)
	cl._incoming = invite.duplicate()
	cl.room_guest = {"id": x, "name": "XENA"}
	p.friend_out[x] = {"name": "XENA", "t": 1}
	heard.cancelled = 0
	heard.room = 0
	heard.friends = 0
	cl.drop_player(x)
	_check(cl.waiting_for() == "" and cl._room == "" and cl.opponent.is_empty() and not cl.has_invite() and heard.cancelled == 1
		and cl.room_guest.is_empty() and heard.room == 1, "drop_player calls off the challenge either way and frees their room seat")
	_check(not cl.friend_asked(x) and p.withdrawn == [x] and heard.friends == 0,
		"drop_player takes the friend request back without a friend-request alert; offline its deletion waits")
	cl._outgoing = {"id": y, "name": "YURI", "bundle": "default", "room": "00", "aes": invite.aes, "mac": invite.mac, "t": 0}
	cl.drop_player(x)
	_check(cl.waiting_for() == "YURI", "drop_player leaves a challenge to another player alone")
	cl._outgoing = {}
	cl._rx = PackedByteArray([0x20, 0x02, 0x00, 0x00])           # CONNACK: the relay answers again
	cl._parse()
	_check(cl.status == "online" and p.withdrawn.is_empty(), "the deletion of a request taken back offline goes out on the next connection")
	cl.withdraw_request(x, false)
	_check(p.withdrawn.is_empty(), "online a request is taken back at once (nothing left waiting)")
	p.withdrawn = [z]
	cl.directory[z] = {"name": "ZED", "bundle": "default", "pk": "", "ts": 1}
	_check(cl.request_friend(z) and cl.friend_asked(z) and p.withdrawn.is_empty(),
		"a new request to a player cancels the deletion still waiting for them")
	# A relay that refuses the phone (CONNACK return code 5: not authorised, say its shared login
	# changed) is left for the next relay at once, not asked twice more (_next_broker on the close).
	cl._ws = WebSocketPeer.new()
	cl._fail_n = 0
	var relay_before: int = cl._broker_i
	cl._rx = PackedByteArray([0x20, 0x02, 0x00, 0x05])
	cl._parse()
	cl._next_broker()
	_check(cl._broker_i == (relay_before + 1) % cl._brokers.size() and cl._fail_n == 0,
		"a relay that refuses the phone (CONNACK 5) is left for the next relay at once")
	_check(relay_before != 0 or cl._home_bad_ms >= 0, "the first relay failing the phone is remembered (may_return_home)")
	# Networks that let only port 443 out still reach a relay; each login as its relay publishes it.
	_check(String(Cloud.BROKERS[1]).contains(":443/") and Cloud.BROKERS.size() >= 4,
		"a relay on port 443 comes right after the first one (%s)" % str(Cloud.BROKERS))
	_check(Cloud.connect_flags([]) == 0x02 and Cloud.connect_flags(["freemqtt", "public"]) == 0xC2
		and Cloud.connect_flags(["demo", ""]) == 0x82, "CONNECT's flags: no login, user and password, user only")
	for url: String in Cloud.BROKER_LOGINS:
		_check(url in Cloud.BROKERS and (Cloud.BROKER_LOGINS[url] as Array).size() == 2, "the login of %s is for a relay in the list" % url)
	_check(Cloud.may_return_home(10000, -1) and not Cloud.may_return_home(10000 + Cloud.HOME_RETRY_MS - 1, 10000)
		and Cloud.may_return_home(10000 + Cloud.HOME_RETRY_MS + 1, 10000),
		"a phone the first relay failed stays on the one it reached for HOME_RETRY_MS")
	cl._ws = null
	cl.free()
	them.free()
	Game.profile = saved_profile
	Game.autotest = at


## The FRIENDS tab's search matches an ID by its start: the 8-character code or the start of the
## whole ID that COPY puts on the clipboard (the search box keeps 14 characters, upper-case).
func _test_id_search() -> void:
	var id := "someone".sha256_text().left(32)
	_check(LobbyFriends._id_matches(id, Cloud.friend_code(id)) and LobbyFriends._id_matches(id, id.to_upper().left(14))
		and not LobbyFriends._id_matches(id, Cloud.friend_code("someone else".sha256_text().left(32))),
		"an ID search matches the code or the start of the whole ID, nothing else")


## The ONLINE tab's status line goes by the players it lists (LobbyFriends._refresh_friends): with
## every player online blocked, the list is empty and it still looks for players.
func _test_online_status() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var saved_cloud := Game.cloud
	var at := Game.autotest
	Game.autotest = "unit"
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var x := "blocked-x".sha256_text().left(32)
	var cl := Cloud.new()
	cl.status = "online"
	cl.peers[x] = {"name": "XENA", "bundle": "default", "pk": "", "seen": 0}
	Game.cloud = cl
	Game.block(x)
	var lf := LobbyFriends.new(null)
	lf._net_scroll = ScrollContainer.new()
	lf._net_list = VBoxContainer.new()
	lf._net_scroll.add_child(lf._net_list)
	lf._net_status = Label.new()
	lf._refresh_friends()
	var blocked_only := [lf._net_status.text, lf._net_list.get_child_count()]
	Game.unblock(x)
	lf._refresh_friends()
	_check(blocked_only == ["LOOKING FOR PLAYERS ONLINE...", 1] and lf._net_status.text == "PLAYERS ONLINE"
		and lf._net_list.get_child_count() == 2, "the ONLINE status counts only the players it lists, not blocked ones (%s)" % str(blocked_only))
	_check(not lf._net_status.visible and lf._net_list.get_child(0).name == "OnlineHead"
		and (lf._net_list.get_child(0) as Label).text == "PLAYERS ONLINE", "the PLAYERS ONLINE heading is the list's first row: it scrolls with its section")
	lf._net_scroll.free()
	lf._net_status.free()
	lf.lan = null                     # (its LobbyLan holds it; a lobby lets go in LobbyLan.on_lobby_exit)
	cl.free()
	Game.cloud = saved_cloud
	Game.profile = saved_profile
	Game.autotest = at


## What the other phone's messages may make on this one (Arena._on_net_event): walls and frags
## only within the round's items (a custom room's unlimited ones up to ROOM_SPAWN_CAP), at real
## spots in the hall, while the round is fought and no faster than a hand; shots no faster than
## the gun fires.
func _test_net_limits() -> void:
	var a: Node3D = load("res://scripts/arena.gd").new()
	var saved_rules := Game.room_rules
	Game.room_rules = {}
	var spot := Vector3(2.0, 0.0, 3.0)
	a.phase = 0
	a.prep_left = 6.0
	_check(not a._remote_spawn_allowed("wall", spot), "no wall from the other phone early in the prep")
	a.phase = 1
	var outside := 0
	for p: Vector3 in [Vector3(1.0e6, 0.0, 0.0), Vector3(NAN, 0.0, 0.0), Vector3(0.0, 40.0, 0.0), Vector3(INF, 0.0, 0.0)]:
		outside += 1 if a._remote_spawn_allowed("wall", p) else 0
	_check(outside == 0, "no wall outside the hall or at a point that is not a number")
	_check(not a._in_hall(a._net_vec(["1", 2.0, 3.0], 0)) and a._in_hall(a._net_vec([1, 0.0, 3.0], 0)),
		"event data that is not a number is no point")
	var walls := 0
	var frags := 0
	for i in 20:
		walls += 1 if a._remote_spawn_allowed("wall", spot) else 0
		frags += 1 if a._remote_spawn_allowed("grenade", spot) else 0
	_check(walls == Fighter.START_SHIELDS and frags == Fighter.START_GRENADES,
		"a round takes only the walls and frags a player has (%d walls, %d frags)" % [walls, frags])
	a._net_spawns.clear()
	a._net_buckets.clear()
	a.online = true
	Game.room_rules = {"walls": true, "frags": true}
	var burst := 0
	for i in 50:
		burst += 1 if a._remote_spawn_allowed("wall", spot) else 0
	_check(burst == 3 and a.spawn_cap("wall") == a.ROOM_SPAWN_CAP, "unlimited walls come no faster than a hand (%d at once)" % burst)
	var total := burst
	for i in 200:
		a._net_buckets["wall"] = [3.0, Time.get_ticks_msec()]       # as if seconds had passed
		total += 1 if a._remote_spawn_allowed("wall", spot) else 0
	_check(total == a.ROOM_SPAWN_CAP, "unlimited walls stop at %d a round (got %d)" % [a.ROOM_SPAWN_CAP, total])
	a.phase = 2
	a._net_spawns.clear()
	a._net_buckets.clear()
	_check(not a._remote_spawn_allowed("grenade", spot), "no frag from the other phone once the match is over")
	var shots := 0
	for i in 100:
		shots += 1 if a._remote_shot_allowed() else 0
	_check(shots > 0 and shots <= 8, "shot reports come no faster than the gun fires (%d at once)" % shots)
	Game.room_rules = saved_rules
	a.free()


## How an online session ends and whose doing it is (Cloud): a phone away about as long as the
## other one waits (by the tick clock, or asleep by the wall clock) ends its match as "connection
## lost" before it reads its buffer; a challenge accepted here gives up when the room handshake
## never comes, at once when it is called off as it is accepted; a loading match sends
## keep-alives; a joined custom room that stops answering is noticed.
func _test_session_ends() -> void:
	var saved_profile := Game.profile.duplicate(true)
	var at := Game.autotest
	Game.autotest = "unit"
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var x := "opponent-x".sha256_text().left(32)
	var cl := Cloud.new()
	cl.my_id = "me".sha256_text().left(32)
	var heard := {"ended": [], "failed": 0, "room": 0}
	cl.session_ended.connect(func(reason: String) -> void: heard.ended.append(reason))
	cl.invite_failed.connect(func(_who: String) -> void: heard.failed += 1)
	cl.room_changed.connect(func() -> void: heard.room += 1)
	var keys := Crypto.new()
	var invite := {"id": x, "name": "XENA", "bundle": "default", "room": keys.generate_random_bytes(16).hex_encode(),
		"aes": keys.generate_random_bytes(32), "mac": keys.generate_random_bytes(32), "t": Time.get_ticks_msec()}
	var them := Cloud.new()
	them.my_id = x
	them._aes = invite.aes
	them._mac = invite.mac
	cl._incoming = invite.duplicate()
	cl.answer(true)
	cl._tick_room(0.1)
	_check(cl._room != "" and heard.failed == 0, "an accepted challenge waits for its room handshake")
	cl._tick_room(0.1, cl._accept_ms + Cloud.JOIN_TIMEOUT_MS + 100)
	_check(cl._room == "" and heard.failed == 1, "an accepted challenge whose room handshake never comes gives up")
	cl._incoming = invite.duplicate()
	cl.answer(true)
	cl._on_inbox({"t": "can", "from": x, "mac": cl._tag(invite, "can", x)})
	_check(cl._room == "" and heard.failed == 2, "a challenge called off just as it was accepted ends at once")
	cl._incoming = invite.duplicate()
	cl.answer(true)
	cl._on_room(them._room_packet({"k": "join"}))
	_check(cl.in_session and cl._accept_ms == 0, "the room handshake starts the session")
	cl._keep_t = 0.0
	cl._tick_room(0.1)
	_check(is_equal_approx(cl._keep_t, 1.0), "a session whose arena still loads sends keep-alives")
	cl._process(0.016)
	_check(cl.in_session, "a normal frame keeps the session")
	cl._check_away(cl._frame_ms + Cloud.AWAY_MS + 2000)
	_check(cl.in_session and heard.ended.is_empty(), "a frame gap while the match loads (shaders compile) is not being away")
	var arena_up := func(_k: String, _d: Array) -> void: pass
	cl.event_received.connect(arena_up)
	cl._check_away(cl._frame_ms + 16)
	cl._check_away(cl._frame_ms + Cloud.AWAY_MS + 2000)
	_check(cl.in_session and heard.ended.is_empty(), "nor is one in the first seconds after the arena appears")
	cl._check_away(cl._frame_ms + Cloud.LOAD_STALL_MS)
	_check(cl.in_session, "a frame gap shorter than the other phone waits keeps the session")
	cl._check_away(cl._frame_ms + Cloud.AWAY_MS + 500)
	_check(cl.in_session and heard.ended.is_empty() and cl.rejoining(),
		"a phone away a while keeps its match (AWAY, back it waits for the other phone's word)")
	cl._check_away(cl._frame_ms + Cloud.SELF_GRACE_MS + 500)
	cl.event_received.disconnect(arena_up)
	_check(not cl.in_session and heard.ended == ["connection lost"] and cl.last_end_reason == "connection lost",
		"a phone away about as long as the other one waits (the grace) ends its match as connection lost (%s)" % str(heard.ended))
	cl._incoming = invite.duplicate()
	cl.answer(true)
	cl._on_room(them._room_packet({"k": "join"}))
	cl._process(0.016)
	cl.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	cl._paused_unix -= 30.0                              # asleep for 30 s: the tick clock stood still
	cl.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	cl._process(0.016)
	_check(cl.in_session and heard.ended.size() == 1 and cl.rejoining(),
		"a phone that slept 30 s keeps its match and rejoins it (%s)" % str(heard.ended))
	cl.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	cl._paused_unix -= 100.0                             # then 100 s more: past the grace
	cl.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	cl._process(0.016)
	_check(not cl.in_session and heard.ended.size() == 2 and heard.ended[1] == "connection lost",
		"a phone that slept through the match ends it as connection lost (%s)" % str(heard.ended))
	cl._inbox_budget = 8.0
	cl.join_room("424242", "4821")
	cl._on_inbox({"t": "rin", "from": x, "code": "424242"})
	_check(cl.join_state == "in", "the custom room's host lets this phone in")
	cl._join.t = 0                                        # long ago, then the host answers again
	cl._on_inbox({"t": "rin", "from": x, "code": "424242"})
	var answered := int(cl._join.t)
	cl._tick_room(0.1, answered + Cloud.JOIN_TIMEOUT_MS - 1000)
	_check(answered > 0 and cl.join_state == "in", "a room whose host still answers keeps its guest")
	heard.room = 0
	cl._tick_room(0.1, answered + Cloud.JOIN_TIMEOUT_MS + 100)
	_check(cl.join_state == "none" and heard.room == 1, "a joined room whose host stopped answering is noticed")
	cl.free()
	them.free()
	Game.profile = saved_profile
	Game.autotest = at


## The 1.2.0 fixes: a dark clear colour (a scene change never flashes light blue), the version the
## game shows from the project, QUIT MATCH's second tap not rushed, and what a death credits.
func _test_release_fixes() -> void:
	var clear: Color = ProjectSettings.get_setting("rendering/environment/defaults/default_clear_color")
	_check(clear.get_luminance() < 0.05, "scene changes never flash a light clear colour (%s)" % str(clear))
	var ver := String(ProjectSettings.get_setting("application/config/version", ""))
	_check(ver == "1.5.3", "the version shown (loading, login) is the project's 1.5.3 (%s)" % ver)
	for path: String in ["res://scripts/loading.gd", "res://scripts/login.gd"]:
		_check(FileAccess.get_file_as_string(path).contains("application/config/version"), "%s shows the project's version" % path)
	_check(not FileAccess.get_file_as_string("res://scripts/lobby.gd").contains("application/config/version"),
		"the lobby shows no version (as the reference: only before the lobby)")
	_check(PauseMenu.QUIT_CONFIRM_S >= 5.0, "QUIT MATCH's second tap may come a while later")
	var arena_script: GDScript = load("res://scripts/arena.gd")
	var v := Bot.new()
	var k := Bot.new()
	for c: Array in [["zone", null, "zone"], ["fall", null, "fall"], ["left", null, "left"], ["frag", k, "frag"], ["", k, "gun"],
			["", null, "zone"], ["frag", v, "self"]]:
		v.last_hit_cause = String(c[0])
		var got := String(arena_script.call("death_cause", v, c[1]))
		_check(got == String(c[2]), "a death by %s is a %s death (%s)" % [str(c[0]), str(c[2]), got])
	v.free()
	k.free()


## Saves survive a write cut short (Game.write_json / read_json, behind profile.json, settings.json
## and hud_layout.json): a file only ever turns into a whole new one, the one before stays as .bak,
## and a broken file reads as that.
func _test_safe_saves() -> void:
	var path := "user://save_check.json"
	for p: String in [path, path + ".bak", path + ".tmp"]:
		DirAccess.remove_absolute(p)
	var first := GameCode.write_json(path, {"n": 1, "name": "ROOKIE"})
	_check(first and int(GameCode.read_json(path).get("n", 0)) == 1 and not FileAccess.file_exists(path + ".tmp"),
		"a save is written whole and no temporary file is left")
	GameCode.write_json(path, {"n": 2})
	_check(int(GameCode.read_json(path).get("n", 0)) == 2 and int(GameCode.read_json(path + ".bak").get("n", 0)) == 1,
		"the save before stays as .bak")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{\"n\": 3, \"name\": \"ROO")             # what a full phone left of a write
	f.close()
	_check(int(GameCode.read_json(path).get("n", 0)) == 1, "a save cut short reads as the one before it")
	_check(not GameCode.write_json("user://no_such_folder/x/save.json", {"n": 4}), "a save that cannot be written says so")
	for p: String in [path, path + ".bak"]:
		DirAccess.remove_absolute(p)
	_check(GameCode.read_json(path).is_empty(), "no save reads as nothing")


## The stick pushed past the ring asks for a sprint every frame: firing keeps it off (and with it
## the firing slowdown), letting go of FIRE brings it back.
## CLEAR CACHE deletes the shader and pipeline caches, old logs and the saves' leftovers (a .tmp,
## a .bak older than a save that reads whole) and says how much it freed; the saves, the identity
## key, the current log, a backup still needed and any other file stay.
func _test_clear_cache() -> void:
	var root := "user://cache_check"
	var files := {
		"shader_cache/a1/b2/shader.cache": 300, "vulkan/pipelines.cache": 200, "logs/godot2026-11-01T10.00.00.log": 50,
		"logs/godot.log": 40, "settings.json": -1, "settings.json.bak": -1, "profile.json.tmp": 70,
		"hud_layout.json": 10, "hud_layout.json.bak": -1, "net_identity.key": 30, "notes.txt": 5,
	}
	for rel: String in files:
		var path := root.path_join(rel)
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if rel.ends_with(".json.bak") or rel == "settings.json":
			f.store_string("{\"a\": 1}")
		else:
			f.store_string("x".repeat(int(files[rel])))          # hud_layout.json: not whole JSON
		f.close()
	var found: Dictionary = CacheCleaner.scan(root)
	var want := 300 + 200 + 50 + 70 + 8          # settings.json.bak: its 8 bytes
	var freed := CacheCleaner.clear(root)
	var gone := ["shader_cache/a1/b2/shader.cache", "vulkan/pipelines.cache", "logs/godot2026-11-01T10.00.00.log",
		"profile.json.tmp", "settings.json.bak"]
	var kept := ["logs/godot.log", "settings.json", "hud_layout.json", "hud_layout.json.bak", "net_identity.key", "notes.txt"]
	_check(int(found.bytes) == want and freed == want, "CLEAR CACHE finds and frees the caches (%d / %d of %d bytes)" % [int(found.bytes), freed, want])
	_check(gone.all(func(r: String) -> bool: return not FileAccess.file_exists(root.path_join(r)))
		and kept.all(func(r: String) -> bool: return FileAccess.file_exists(root.path_join(r))),
		"caches, old logs and leftovers go; saves, the key, the current log and a needed backup stay")
	_check(CacheCleaner.clear(root) == 0 and CacheCleaner.size_text(0) == "0 B" and CacheCleaner.size_text(1536) == "2 KB"
		and CacheCleaner.size_text(13 * 1048576) == "13.0 MB", "a second clear frees nothing; sizes read as B, KB, MB")
	for rel: String in kept:
		DirAccess.remove_absolute(root.path_join(rel))


func _test_no_sprint_firing() -> void:
	var p := Player.new()
	p.firing = true
	p.set_sprint(true)
	var while_firing := p.sprinting
	p.firing = false
	p.set_sprint(true)
	_check(not while_firing and p.sprinting, "no sprint while firing, back once FIRE is let go")
	p.free()


## Fists out, a fighter walks, runs, sprints and crouch-walks 15 % faster than with a rifle, clearly
## faster than with any gun; the guns by class (SMG fastest, rifle = pistol, then shotgun, marksman,
## sniper). Players and bots by the same rules.
func _test_move_speeds() -> void:
	_check(Weapons.move_mult(Weapons.DEFS.fists) == 1.15 and Weapons.move_mult(Weapons.DEFS.ar) == 1.0, "fists 1.15 x, rifles 1.0 x")
	for f: Fighter in [Player.new(), Bot.new()]:
		var who := "player" if f is Player else "bot"
		var speeds := {}             # weapon id -> [walk, run, sprint, crouch]
		for id: String in Weapons.PICKABLE + ["fists"]:
			f.set_loadout("ar" if id == "fists" else id)
			f.current = 1 if id == "fists" else 0
			var row: Array[float] = []
			for gait: String in ["walk", "run", "sprint", "crouch"]:
				f.stance = Fighter.Stance.CROUCH if gait == "crouch" else Fighter.Stance.STAND
				f.move_dir = Vector2(0, 0.3 if gait == "walk" else 1.0)
				f.sprinting = gait == "sprint"
				row.append(f.move_speed())
			speeds[id] = row
		var fist_ok := true
		var guns_slower := true
		for i in 4:
			fist_ok = fist_ok and is_equal_approx(speeds.fists[i] / speeds.ar[i], 1.15)
			for id: String in Weapons.PICKABLE:
				guns_slower = guns_slower and speeds[id][i] * 1.05 < speeds.fists[i]
		_check(fist_ok, "%s: fists out it moves 15 %% faster than with the rifle (%s vs %s)" % [who, speeds.fists, speeds.ar])
		_check(guns_slower, "%s: no gun comes within 5 %% of the fists' speed" % who)
		_near(speeds.ar[1], 4.6, "%s: with the rifle it runs as fast as before" % who)
		_check(speeds.smg[1] > speeds.ar[1] and speeds.ar[1] == speeds.pistol[1] and speeds.pistol[1] > speeds.lever[1]
			and speeds.lever[1] > speeds.sks[1] and speeds.sks[1] > speeds.sniper[1] and speeds.ak[1] == speeds.ar[1]
			and speeds.bizon[1] == speeds.smg[1], "%s: SMG > rifle = pistol > shotgun > marksman > sniper, the same within a class" % who)
		f.free()


## Names keep accented Latin letters as plain ones and say when nothing can be shown; a lobby
## message without its "id" (anyone can publish there) is dropped quietly; a friend request is not
## answered while offline (the relay's copy would bring it back); the settings panel leaves Android
## back to a popup that came in over it.
func _test_lobby_ui_rules() -> void:
	_check(Game.clean_name("José Müller") == "JOSE MULLER" and Game.clean_name("Straße") == "STRASSE"
		and Game.clean_name("Иван") == "" and Game.clean_name("Łukasz-7") == "LUKASZ-7",
		"accented letters become plain letters, other scripts are left out (%s)" % Game.clean_name("José Müller"))
	var saved_profile := Game.profile.duplicate(true)
	var at := Game.autotest
	Game.autotest = "unit"
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var cl := Cloud.new()
	cl.my_id = "me".sha256_text().left(32)
	cl._on_publish(Cloud.ROOT + "/lobby", "{\"t\": \"hi\", \"from\": \"abc\"}".to_utf8_buffer())
	cl._on_publish(Cloud.ROOT + "/u/" + cl.my_id, "{\"t\": \"frq\", \"id\": \"abc\"}".to_utf8_buffer())
	cl._on_publish(Cloud.ROOT + "/lobby", "[1, 2]".to_utf8_buffer())
	_check(cl.peers.is_empty() and cl.friend_requests.is_empty(), "lobby and inbox messages without their id are dropped")
	var x := "asker-x".sha256_text().left(32)
	cl.friend_requests[x] = {"name": "XENA", "t": 1}
	cl.answer_friend(x, false)
	_check(cl.friend_requests.has(x), "a friend request is not answered while the relay is not connected")
	cl.free()
	Game.profile = saved_profile
	Game.autotest = at
	var root := Control.new()
	var sp := SettingsPanel.new()
	root.add_child(sp)
	var alone := sp.covered()
	var popup := Control.new()
	root.add_child(popup)
	var under := sp.covered()
	popup.visible = false
	_check(not alone and under and not sp.covered(), "the settings panel leaves back to a popup shown over it")
	root.free()
