extends RefCounted
## Unit tests of the 1 vs 1 match feedback (round 8): the ELIMINATED BY card against the HP block,
## whose HP the block shows, damage-number bursts, the minimap's view, the two-line kill feed, the
## quick wall and the settings migration v8. Run from tests/run_tests.gd (which counts the checks).

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._test_death_card()
	me._test_damage_numbers()
	me._test_migration_v8()
	me._test_hit_bloom()
	me._test_minimap_whole()
	me._test_break_controls()
	me._test_solo_feed()
	me._test_kill_badge()
	me._test_zoom_label()
	me._test_gun_alert()
	me._test_impact_kind()
	me._test_outline_meshes()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _hud() -> HUD:
	var hud := HUD.new()
	hud.layout = HudLayout.resolve({})
	return hud


## The card ends left of the HP block's first armour icon from 16:10 to 22:9; a dead player (in
## the round or in the break) gets no HP block of their own, a spectator the watched fighter's.
func _test_death_card() -> void:
	var hud := _hud()
	for aspect: float in [16.0 / 10.0, 16.0 / 9.0, 18.0 / 9.0, 19.5 / 9.0, 20.0 / 9.0, 22.0 / 9.0]:
		var vs := Vector2(roundf(720.0 * aspect), 720.0)
		var u := HudLayout.unit(vs)
		var card := hud.death_card_rect(vs, u)
		var icon_x := float(hud.hp_geometry(vs, u).x0)
		_check(card.end.x <= icon_x - 0.01 * u + 0.01, "aspect %.2f: the ELIMINATED BY card (right %.0f) ends 0.01u before the HP icons (%.0f)" % [aspect, card.end.x, icon_x])
		_check(card.position.x >= 0.0 and card.size.x >= 0.2 * u, "aspect %.2f: the card keeps a usable width" % aspect)
	var me := Player.new()
	var foe := Fighter.new()
	hud.player = me
	_check(hud.hp_subject() == me, "alive: the HP block is the player's")
	me.alive = false
	hud.match_over = true
	_check(hud.hp_subject() == null, "dead in the break (match_over): no HP block of the dead player")
	hud.match_over = false
	me.spectating = foe
	_check(hud.hp_subject() == foe, "spectating the killer: the HP block shows the killer's HP")
	foe.hp = 120.0
	_check(hud.hp_label() == "HP 120/%d" % int(foe.hp_max), "the label reads the watched fighter's HP (got %s)" % hud.hp_label())
	foe.alive = false
	_check(hud.hp_subject() == null, "nobody alive to watch: no HP block")
	hud.free()
	me.free()
	foe.free()


## A 10-hit burst (one hit every 0.1 s) makes at most 3 numbers, each within 0.1u of the head
## point; a hit 0.4 s after the last one starts a new number.
func _test_damage_numbers() -> void:
	var hud := _hud()
	var foe := Fighter.new()
	var u := 720.0
	for i in 10:
		hud._add_damage_number(foe, 20.0, i == 4, Vector3.ZERO)
		for n: Dictionary in hud._dmg_numbers:
			n.t += 0.1
			n.last += 0.1
	_check(hud._dmg_numbers.size() <= 3, "a 10-hit burst shows at most 3 numbers (got %d)" % hud._dmg_numbers.size())
	var total := 0.0
	for n: Dictionary in hud._dmg_numbers:
		total += float(n.amount)
		_check(HUD.dmg_offset(n, u).length() < 0.1 * u, "a number sits within 0.1u of the head point")
	_check(is_equal_approx(total, 200.0), "the numbers add up to the burst's damage (got %.0f)" % total)
	_check(bool(hud._dmg_numbers[0].head), "a headshot in the burst marks its number")
	hud._dmg_numbers.clear()
	hud._add_damage_number(foe, 30.0, false, Vector3.ZERO)
	hud._dmg_numbers[0].last = 0.4
	hud._dmg_numbers[0].t = 0.4
	hud._add_damage_number(foe, 30.0, false, Vector3.ZERO)
	_check(hud._dmg_numbers.size() == 2, "a hit 0.4 s after the last one shows a new number")
	_check(HUD.dmg_offset(hud._dmg_numbers[1], u).length() < 0.1 * u, "the second number stays by the head (spread at most 0.04u)")
	_check(hud._dmg_size(20.0, false, u) <= int(0.05 * u) and hud._dmg_size(20.0, false, u) >= int(0.032 * u), "numbers are 0.032u .. 0.05u")
	hud.free()
	foe.free()


## v8: LEFT FIRE moves from always (0) to while aiming (1) only in older files still on the old
## default; a v8 file keeps 0, an older OFF stays OFF.
func _test_migration_v8() -> void:
	var keep := Game.settings.duplicate(true)
	_check(int(Game.DEFAULT_SETTINGS.left_fire) == 1, "LEFT FIRE starts while aiming")
	for case: Array in [[7, 0, 1], [5, 0, 1], [7, 2, 2], [8, 0, 0], [8, 1, 1]]:
		Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
		Game._apply_saved_settings(JSON.parse_string(JSON.stringify({"settings_version": case[0], "left_fire": case[1]})))
		_check(int(Game.settings.left_fire) == int(case[2]), "a v%d file with left_fire %d reads %d (got %d)" % [case[0], case[1], case[2], int(Game.settings.left_fire)])
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings({"settings_version": 7, "wall_quick": "yes", "hit_ring": 3})
	_check(Game.settings.wall_quick == true and Game.settings.hit_ring == true and Game.settings.enemy_outline == true
		and Game.settings.gunshot_alerts == true and Game.settings.kill_badges == true, "round 8's switches start on and bad values fall back")
	Game.settings = keep


## The hit ring blooms to 1/16 of the screen width across (a headshot's larger).
func _test_hit_bloom() -> void:
	var vs := Vector2(1280, 720)
	_check(is_equal_approx(HUD.hit_bloom_radius(vs, false) * 2.0, 80.0), "the hit ring is 1/16 of the width across")
	_check(HUD.hit_bloom_radius(vs, true) > HUD.hit_bloom_radius(vs, false), "a headshot's ring is larger")


## At the spawn (an end alcove) the minimap shows the whole arena: the view covers map_rect along
## its long side (a turned map may clip the corners), with at most ~10 % of the view outside it.
func _test_minimap_whole() -> void:
	var mr := Rect2(-27.6, -15.6, 55.2, 31.2)          # the arena's map_rect (MapBuilder)
	var side := 200.0
	var spawn := Vector2(-25.0, 0.0)
	var vm := HudMinimap.view_m(mr)
	_check(vm >= 55.2 and vm <= 60.0, "the view is the map's long side + 5 %% (%.1f m)" % vm)
	var xf := HudMinimap.view_xform(spawn, 0.0, side, mr, false)
	var shown := HudMinimap.view_world_rect(xf, side)
	_check(shown.encloses(mr), "north up at the spawn: the view covers map_rect (%s)" % shown)
	var xt := HudMinimap.view_xform(spawn, PI * 0.5, side, mr, true)
	var a := xt * Vector2(mr.position.x, mr.get_center().y)
	var b := xt * Vector2(mr.end.x, mr.get_center().y)
	_check(Rect2(0, 0, side, side).grow(0.5).has_point(a) and Rect2(0, 0, side, side).grow(0.5).has_point(b),
		"turned at the spawn: both short walls are on the minimap")
	var outside := 1.0 - shown.intersection(mr.grow(0.0)).get_area() / shown.get_area()
	_check(HudMinimap.view_center(spawn, Rect2(-100, -100, 200, 200), 28.0).distance_to(spawn) < 0.01,
		"on a big map the view follows the player")
	_check(HudMinimap.view_m(Rect2(-100, -100, 200, 200)) == HudMinimap.VIEW_M, "a map too big to show whole keeps the 28 m window")
	_check(shown.get_center().distance_to(mr.get_center()) < 0.01, "the map sits in the middle of the view (%.0f %% of the view is outside its long walls)" % (outside * 100.0))


## A stand-in arena in the break (phase 3).
class BreakArena extends Node:
	var phase := 3


## The round break keeps the controls for a player still standing; a dead one gets them back at the
## next round's band; the match's end shows none.
func _test_break_controls() -> void:
	var hud := _hud()
	var a := BreakArena.new()
	var me := Player.new()
	hud.player = me
	hud.arena = a
	_check(hud.controls_shown(), "in the fight the controls show")
	hud.match_over = true
	hud._break = {"age": RoundRules.BREAK_RESULT_AT + 0.5, "title": "VICTORY", "round": 2}
	_check(hud.controls_shown(), "the break: a living player keeps the controls")
	me.alive = false
	_check(not hud.controls_shown(), "the break: a dead player has no controls")
	hud._break.age = RoundRules.BREAK_BAND_AT + 0.2
	_check(hud.controls_shown(), "from the next round's band everyone has the controls")
	me.alive = true
	hud._result = {"title": "VICTORY", "age": 0.5, "sub": ""}
	_check(not hud.controls_shown(), "the match's end: no controls")
	hud.free()
	me.free()
	a.free()


## The 1 vs 1 feed: one line at 0.767; a second at the same time under it at 0.80; a third pushes
## the oldest out; lines live 3.5 s; a death to the zone reads "<NAME> ELIMINATED" with no killer.
func _test_solo_feed() -> void:
	var hud := _hud()
	hud.feed_lines = 2
	_check(is_equal_approx(HUD.solo_feed_y(0, 1), 0.767), "one line at 0.767")
	_check(is_equal_approx(HUD.solo_feed_y(1, 2), 0.767) and is_equal_approx(HUD.solo_feed_y(0, 2), 0.80), "a second line stacks under the first (0.80)")
	hud.add_kill_feed("A", "B", "AR", "", false, false)
	hud.add_kill_feed("C", "", "", "", false, false, "ELIMINATED")
	hud.add_kill_feed("D", "", "", "", false, false, "LEFT")
	_check(hud._kill_feed.size() == 2 and String(hud._kill_feed[1].killer) == "C", "two lines at most, the oldest goes")
	_check(is_equal_approx(float(hud._kill_feed[0].t), HUD.FEED_LIFE_SOLO) and HUD.FEED_LIFE_SOLO <= 4.0, "1 vs 1 lines stay about 3 s")
	_check(String(hud._kill_feed[1].victim) == "" and String(hud._kill_feed[1].verb) == "ELIMINATED", "a zone death names no killer")
	hud.free()


## The kill badge names the player; DOUBLE / TRIPLE only in DUO / SQUAD.
func _test_kill_badge() -> void:
	_check(HUD.streak_word(1, true, false) == "ELIMINATED" and HUD.streak_word(2, true, false) == "DOUBLE"
		and HUD.streak_word(3, true, true) == "TRIPLE" and HUD.streak_word(4, true, false) == "TRIPLE", "DUO / SQUAD streak words")
	_check(HUD.streak_word(2, false, true) == "HEADSHOT" and HUD.streak_word(2, false, false) == "ELIMINATED", "no streak words in the 1 vs 1")
	var hud := _hud()
	var me := Player.new()
	me.display_name = "WOLF"
	hud.player = me
	hud.kill_banner("BOT X", false)
	_check(String(hud._kill_banner.by) == "WOLF", "the badge's plate names the player")
	hud.free()
	me.free()


## The scope button's zoom label follows the gun's sight.
func _test_zoom_label() -> void:
	var ok := true
	for id: String in Weapons.DEFS:
		var d: Dictionary = Weapons.DEFS[id]
		var want := String({"reddot": "1X", "2x": "2X", "sniper": "8X"}.get(Player.sight_of(d), ""))
		ok = ok and HUD.zoom_label(d) == want
	_check(ok, "every gun's scope label matches its sight (none without one)")
	_check(HUD.zoom_label({"scope": "none"}) == "" and HUD.zoom_label({"scope": "sniper"}) == "8X", "no sight, no label; a sniper scope 8X")


## Gunshot alerts fade with distance: full close by, none at 60 m and beyond.
func _test_gun_alert() -> void:
	_check(is_equal_approx(HUD.gun_alert_alpha(0.0), 1.0) and is_equal_approx(HUD.gun_alert_alpha(30.0), 0.5)
		and HUD.gun_alert_alpha(60.0) == 0.0 and HUD.gun_alert_alpha(90.0) == 0.0, "a gunshot alert's opacity is 1 - dist / 60")
	var hud := _hud()
	var me := Player.new()
	var foe := Fighter.new()
	hud.player = me
	var keep: Variant = Game.settings.get("gunshot_alerts", true)
	Game.settings.gunshot_alerts = false
	hud.gun_alert(foe)
	_check(hud._gun_alerts.is_empty(), "GUNSHOT ALERTS off: no alert")
	Game.settings.gunshot_alerts = keep
	hud.gun_alert(me)
	_check(hud._gun_alerts.is_empty(), "the player's own shots never alert")
	hud.free()
	me.free()
	foe.free()


## Impact sounds by what the bullet hit.
func _test_impact_kind() -> void:
	var a := Node3D.new()
	a.name = "Container_3"
	var b := Node3D.new()
	b.name = "Crate_1"
	var c := Node3D.new()
	c.name = "WallNorth"
	var g := Node3D.new()
	g.add_to_group("wood")
	_check(Effects.impact_kind(a) == "metal" and Effects.impact_kind(b) == "wood" and Effects.impact_kind(c) == "concrete"
		and Effects.impact_kind(g) == "wood" and Effects.impact_kind(null) == "concrete", "impact sounds: metal, wood, concrete")
	for n in [a, b, c, g]:
		n.free()
	for f: String in ["weapon_draw", "punch_swish", "punch_hit", "dry_click", "bullet_whiz", "impact_metal", "impact_wood",
			"impact_concrete", "grunt_1", "grunt_2", "grunt_3"]:
		_check(ResourceLoader.exists("res://assets/audio/%s.wav" % f), "the sound %s ships" % f)


## ENEMY OUTLINE: only the outer silhouette (skin and outfit) gets the hull; the eyes, brows,
## lashes, hair and alpha-cut cards never do (a hull round them rang the eyes and painted the face).
func _test_outline_meshes() -> void:
	for n: String in ["Eyes", "Eyebrows", "Eyelashes", "Hair_Default", "Teeth"]:
		_check(not CharacterModel.outline_mesh_ok(n), "no outline on %s" % n)
	for n: String in ["Body_Head", "Body_Torso", "Body_Hands", "Outfit_shadow_Top", "Outfit_desert_Cap"]:
		_check(CharacterModel.outline_mesh_ok(n), "the outline on %s" % n)
	var m := CharacterModel.new()
	t.add_child(m)
	m.setup("neon", false)
	m.set_outline(true)
	var on_body := false
	var on_inner := false
	for n: String in m.meshes:
		var mi: MeshInstance3D = m.meshes[n]
		for i in mi.mesh.get_surface_count():
			var bm := mi.get_surface_override_material(i) as BaseMaterial3D
			if bm == null or bm.next_pass == null:
				continue
			if CharacterModel.outline_mesh_ok(n) and bm.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				on_body = true
			else:
				on_inner = true
	_check(on_body and not on_inner, "set_outline puts the hull on the body and outfit only (body %s, inner %s)" % [on_body, on_inner])
	m.set_outline(false)
	var left := false
	for n: String in m.meshes:
		var mi: MeshInstance3D = m.meshes[n]
		for i in mi.mesh.get_surface_count():
			var bm := mi.get_surface_override_material(i) as BaseMaterial3D
			left = left or (bm != null and bm.next_pass != null)
	_check(not left, "set_outline(false) clears every hull")
	m.free()
