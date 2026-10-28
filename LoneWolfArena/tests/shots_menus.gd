extends Node
## Menus screenshot tour (everything outside the match), with input checks:
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_menus.gd
## Boot/loading screen, lobby, name edit, how to play, wardrobe (card tap, rarity tab), every
## settings tab (taps change settings, presets, close saves), credits, START -> match loading
## overlay -> arena, pause menu (+ settings from it), results screens (win, defeat, draw,
## invalid) in an empty scene with sample data. Returns the number of failed checks.

var _fails := 0
var _at: Node
## The capture box draws 1-3 frames a second and caps the process step, so tweens (process
## time) lag the autotest timers (real time): waits before shots use _settle().


func run(at: Node) -> int:
	_at = at
	var saved_settings: Dictionary = Game.settings.duplicate(true)
	var saved_bundle := String(Game.profile.bundle)
	Game.settings.difficulty = 1
	# The autotest boot goes straight to the lobby; wait for it, then look at the boot screen.
	await _wait_scene("Lobby", 30.0)
	Loading.hold_for_test = true
	get_tree().change_scene_to_file("res://scenes/loading.tscn")
	var t := 0.0
	while t < 20.0:
		await at.wait(0.1)
		t += 0.1
		var l := get_tree().current_scene as Loading
		if l and l.progress > 0.45:
			break
	await at.shot("m01_loading")
	var ld := get_tree().current_scene as Loading
	_check(ld != null and ld.progress > 0.0, "boot screen shows progress")
	t = 0.0
	while ld and not ld.done and t < 20.0:
		await at.wait(0.2)
		t += 0.2
	_check(ld != null and ld.done, "boot loading finishes")
	Loading.hold_for_test = false
	Game.goto_lobby()
	var lobby := await _wait_scene("Lobby", 30.0)
	await _settle(2.0)
	await at.shot("m02_lobby")
	# Name edit + how to play.
	lobby.call("_edit_name")
	await _settle(0.6)
	await at.shot("m03_name_edit")
	lobby.call("_close_modal")
	lobby.call("_how_to_play")
	await _settle(0.6)
	await at.shot("m04_how_to_play")
	lobby.call("_close_modal")
	await at.wait(0.3)
	# Wardrobe: open with a tap, pick a card by tapping it, filter by rarity.
	await _tap(lobby.find_child("BundlesButton", true, false) as Control)
	await at.wait(1.2)
	var royal := lobby.find_child("Bundle_royal", true, false) as Control
	_check(royal != null, "wardrobe lists Bundle_royal")
	if royal:
		await _tap(royal)
		await at.wait(0.6)
	_check(String(lobby.get("_preview_bundle")) == "royal", "tapping a bundle card previews it")
	await at.shot("m05_wardrobe")
	await _tap(lobby.find_child("Tab_epic", true, false) as Control)
	await _settle(0.5)
	await at.shot("m06_wardrobe_epic")
	_check(lobby.find_child("Bundle_royal", true, false) == null and lobby.find_child("Bundle_neon", true, false) != null, "EPIC tab filters the cards")
	await _tap(lobby.find_child("BackButton", true, false) as Control)
	await at.wait(0.8)
	_check(lobby.get("wardrobe") == null, "BACK closes the wardrobe")
	# Settings: open from the gear, walk the tabs, tap a few options.
	await _tap(lobby.find_child("SettingsButton", true, false) as Control)
	await at.wait(0.6)
	var sp := _settings(lobby)
	_check(sp != null, "settings opens from the gear")
	if sp:
		await at.shot("m07_settings_basic")
		var g_before := int(Game.settings.graphics)
		var ultra := _find_text(sp, "ULTRA")
		if ultra:
			await _tap(ultra)
		_check(int(Game.settings.graphics) == 2, "tapping ULTRA sets graphics 2")
		Game.settings.graphics = g_before
		sp.call("_show_tab", 2)
		await _settle(0.4)
		await at.shot("m08_settings_controls")
		(sp.get("_scroll") as ScrollContainer).scroll_vertical = 100000
		await _settle(0.4)
		await at.shot("m09_settings_controls_more")
		sp.call("_show_tab", 1)
		await at.wait(0.3)
		var high := _find_text(sp, "HIGH")
		if high:
			await _tap(high)
		await _settle(0.3)
		await at.shot("m10_settings_sensitivity")
		_check(int(Game.settings.sens_general) == 185 and int(Game.settings.sens_sniper) == 150, "HIGH preset sets 185 / 150")
		var deflt := _find_text(sp, "DEFAULT")
		if deflt:
			await _tap(deflt)
		_check(int(Game.settings.sens_general) == 100 and int(Game.settings.sens_sniper) == 71, "DEFAULT preset sets 100 / 71")
		sp.call("_show_tab", 3)
		await _settle(0.3)
		await at.shot("m11_settings_sound")
		var closed := [false]
		sp.closed.connect(func() -> void: closed[0] = true)
		await _tap(sp.find_child("Close", true, false) as Control)
		await at.wait(0.4)
		_check(closed[0] and _settings(lobby) == null, "Close saves and closes the settings")
	# Credits.
	await _tap(lobby.find_child("CreditsButton", true, false) as Control)
	await _settle(0.8)
	await at.shot("m12_credits")
	for c in lobby.get_children():
		if c is CreditsPanel:
			c.queue_free()
	await at.wait(0.3)
	# START -> match loading overlay -> arena.
	await _tap(lobby.get("start_btn") as Control, 0.05)
	await _settle(0.25)
	await at.shot("m13_match_loading")
	var arena := await _wait_scene("Arena", 30.0)
	_check(arena != null, "START enters the arena")
	if arena:
		await at.wait(1.0)
		arena.call("open_pause")
		await _settle(0.5)
		await at.shot("m14_pause")
		var pm := arena.find_child("PauseMenu", true, false)
		_check(pm != null and get_tree().paused, "pause menu pauses the match")
		if pm:
			await _tap(pm.find_child("Settings", true, false) as Control)
			await _settle(0.5)
			await at.shot("m15_pause_settings")
			var psp: Node = null
			for c in pm.get_children():
				if c is SettingsPanel:
					psp = c
			if psp is SettingsPanel:
				(psp as SettingsPanel).call("_close")
			await at.wait(0.3)
			await _tap(pm.find_child("Resume", true, false) as Control)
			await at.wait(0.4)
			_check(not get_tree().paused, "RESUME unpauses")
	# Results in an empty scene (the key art stands in for the arena behind).
	for r in [_sample("victory"), _sample("defeat"), _sample("draw"), _sample("invalid")]:
		var root := Control.new()
		root.name = "ResultsTest"
		root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var tex := UI.texture("keyart_clean.jpg")
		if tex:
			root.add_child(UI.cover(tex))
		get_tree().change_scene_to_node(root)
		await at.wait(0.3)
		var rs := ResultsScreen.new()
		root.add_child(rs)
		rs.setup(r)
		await _settle(2.8)
		await at.shot("m16_results_%s" % String(r.kind))
		_check(rs.find_child("PlayAgain", true, false) != null and rs.find_child("Lobby", true, false) != null, "results buttons PlayAgain + Lobby (%s)" % r.kind)
	_check(ResultsScreen.honour({"headshots": 2, "hp_left": 50, "taken": 150}) == "SHARPSHOOTER", "honour SHARPSHOOTER")
	_check(ResultsScreen.honour({"headshots": 0, "hp_left": 180, "taken": 20}) == "UNTOUCHABLE", "honour UNTOUCHABLE")
	_check(ResultsScreen.honour({"headshots": 1, "hp_left": 12, "taken": 188}) == "CLUTCH", "honour CLUTCH")
	_check(ResultsScreen.honour({"headshots": 0, "hp_left": 0, "taken": 200}) == "FIGHTER", "honour FIGHTER")
	Game.settings = saved_settings
	Game.profile.bundle = saved_bundle
	at.log_line("MENUS TOUR DONE fails=%d" % _fails)
	return _fails


func _sample(kind: String) -> Dictionary:
	var r := {"kind": kind, "won": kind == "victory", "draw": kind == "draw", "invalid": kind == "invalid",
		"kills": 1 if kind == "victory" else 0, "damage": 200 if kind == "victory" else 137, "headshots": 3 if kind == "victory" else 1,
		"accuracy": 46.7, "time": 74.0, "xp": 0 if kind == "invalid" else (330 if kind == "victory" else 74),
		"enemy": "VIPER", "mode": "LONE WOLF", "map": "CARGO CAGE", "weapon": "AR-7 RIFLE",
		"score_player": 1 if kind == "victory" else 0, "score_bot": 1 if kind == "defeat" else 0,
		"hp_left": 112 if kind == "victory" else (0 if kind == "defeat" else 84), "difficulty": "NORMAL",
		"taken": 88 if kind == "victory" else 200}
	return r


func _settings(lobby: Node) -> SettingsPanel:
	for c in (lobby.get("ui") as Node).get_children():
		if c is SettingsPanel:
			return c
	return null


func _find_text(root: Node, text: String) -> Button:
	for b in root.find_children("*", "Button", true, false):
		if (b as Button).text == text and (b as Button).is_visible_in_tree():
			return b
	return null


## Waits `sec` of process time (what tweens and _process see) and at least 3 drawn frames.
func _settle(sec: float) -> void:
	var t := 0.0
	var frames := 0
	while t < sec or frames < 3:
		await get_tree().process_frame
		t += get_process_delta_time()
		frames += 1


func _wait_scene(scene_name: String, timeout: float) -> Node:
	var t := 0.0
	while t < timeout:
		var s := get_tree().current_scene
		if s and s.name == scene_name:
			return s
		await _at.wait(0.1)
		t += 0.1
	_check(false, "scene %s within %.0fs" % [scene_name, timeout])
	return null


## A real tap (touch down / up, emulated as a mouse click by the engine) on a control's centre.
func _tap(c: Control, hold := 0.08) -> void:
	if c == null:
		_check(false, "tap target exists")
		return
	var p := c.get_global_rect().get_center()
	var w: Vector2 = get_tree().root.get_final_transform() * p
	_at.touch(0, w, true)
	await _at.wait(hold)
	_at.touch(0, w, false)
	await _at.wait(0.12)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	_at.log_line(("ok   " if ok else "FAIL ") + what)
