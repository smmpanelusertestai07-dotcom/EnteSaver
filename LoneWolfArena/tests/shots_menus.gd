extends Node
## Menus screenshot tour (everything outside the match), with real-input checks:
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_menus.gd
## Boot/loading screen, the first-start name prompt (top of the screen, RANDOM, OK), lobby (menu
## captions bright, drag to turn the character, START position report), name edit (pencil tap,
## long name ends in "..."), the player card, how to play, the
## wardrobe (card tap, rarity tab), every settings tab (tab taps, HIGH graphics, the HIGH / DEFAULT
## sensitivity presets), credits, the quit dialog, START -> match loading overlay -> arena, the pause menu
## (opened by Android back and by the HUD gear, settings inside it without the HUD editor
## shortcut), results screens (win, defeat, draw, invalid) with the opponent's row in an empty
## scene whose stub scoreboard stands in for the arena, PLAY AGAIN and LOBBY taps.
## Android back is sent the way the engine delivers it (_back(): the node, then its children
## by index, children added during the walk included), so a menu opened by a back request also
## receives that same request. Returns the number of failed checks.

var _fails := 0
var _at: Node
## The capture box draws 1-3 frames a second and caps the process step, so tweens (process
## time) lag the autotest timers (real time): waits before shots use _settle().


func run(at: Node) -> int:
	_at = at
	var saved_settings: Dictionary = Game.settings.duplicate(true)
	var saved_bundle := String(Game.profile.bundle)
	var saved_name := String(Game.profile.name)
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
	var cache := get_tree().root.get_node_or_null("LoadingCache")
	_check(cache != null, "boot preloads kept by LoadingCache")
	# The timeout path hands requests still in flight to the cache, which must collect them.
	if cache is Loading.Cache:
		var path := "res://assets/ui/keyart.jpg"
		if ResourceLoader.load_threaded_request(path) == OK:
			(cache as Loading.Cache).collect([path])
			t = 0.0
			while not (cache as Loading.Cache).pending.is_empty() and t < 10.0:
				await at.wait(0.1)
				t += 0.1
			var kept: Array = cache.get_meta("resources", [])
			_check((cache as Loading.Cache).pending.is_empty() and kept.any(func(r: Resource) -> bool: return r.resource_path == path),
				"LoadingCache collects a load that was still running at the timeout")
	Loading.hold_for_test = false
	Game.goto_lobby()
	var lobby := await _wait_scene("Lobby", 30.0)
	await _settle(1.0)
	# First start (no name chosen yet): the name prompt sits at the top, clear of the keyboard;
	# RANDOM rolls a name and OK keeps it (the prompt does not come back).
	if not bool(Game.profile.get("name_set", false)):
		var first_edit := lobby.find_child("NameEdit", true, false) as LineEdit
		_check(first_edit != null, "the first start asks for a name")
		if first_edit:
			_check(first_edit.get_global_rect().end.y < get_viewport().get_visible_rect().size.y * 0.42,
				"the name field sits in the top part of the screen, above the on-screen keyboard")
			var before := first_edit.text
			await _tap(lobby.find_child("NameRandom", true, false) as Control)
			await _settle(0.3)
			_check(first_edit.text != before and Game.clean_name(first_edit.text) == first_edit.text and first_edit.text.length() <= 14,
				"RANDOM rolls a valid name (%s)" % first_edit.text)
			await at.shot("m02a_name_prompt")
			await _tap(lobby.find_child("NameOk", true, false) as Control)
			await _settle(0.4)
			_check(bool(Game.profile.name_set) and lobby.get("_modal") == null, "OK keeps the name and closes the prompt")
	await _settle(1.0)
	await at.shot("m02_lobby")
	if OS.get_environment("LW_MENUS_STOP") == "lobby":       # quick look while tuning the stage
		Game.settings = saved_settings
		return _fails
	var marks: Dictionary = Game.get("_marks")
	_check(marks.has("ui start"), "lobby reports the START position")
	var howto := lobby.find_child("HowToPlayButton", true, false) as Control
	var lum := await _caption_lum(howto)
	_check(lum >= 230.0, "menu captions are drawn bright, not under their plate (HOW TO PLAY max lum %.0f)" % lum)
	# Drag on the character turns it.
	var model := lobby.get("model") as Node3D
	var yaw0 := model.rotation.y
	var vs := get_viewport().get_visible_rect().size
	var fx: Transform2D = get_tree().root.get_final_transform()
	var p0 := fx * Vector2(vs.x * 0.42, vs.y * 0.5)
	at.touch(1, p0, true)
	for k in 6:
		await at.wait(0.05)
		at.drag(1, p0 + Vector2(30 * (k + 1), 0) * fx.get_scale(), Vector2(30, 0) * fx.get_scale())
	at.touch(1, p0 + Vector2(180, 0) * fx.get_scale(), false)
	await at.wait(0.1)
	_check(absf(model.rotation.y - yaw0) > 0.3, "dragging on the character turns it (%.2f rad)" % (model.rotation.y - yaw0))
	# Name edit from the pencil; a long name ends in "..." inside the player card.
	await _tap(lobby.find_child("EditName", true, false) as Control)
	await _settle(0.5)
	var le := lobby.find_child("NameEdit", true, false) as LineEdit
	_check(le != null, "the pencil opens the name editor")
	if le:
		await at.shot("m03_name_edit")
		le.text = "SHADOWHUNTER99"
		await _tap(lobby.find_child("NameOk", true, false) as Control)
		await _settle(0.4)
		var nl := lobby.find_child("PlayerName", true, false) as Label
		_check(String(Game.profile.name) == "SHADOWHUNTER99" and nl and nl.size.x <= 170.0,
			"a 14-character name is saved and fits the card (%.0f px)" % (nl.size.x if nl else -1.0))
		await at.shot("m03b_long_name")
	# The whole player card opens the editor too; back closes it.
	var card := lobby.find_child("PlayerCard", true, false) as Control
	if card:
		await _tap_at(card.get_global_rect().position + Vector2(34, 31))
		await _settle(0.3)
	_check(lobby.find_child("NameEdit", true, false) != null, "tapping the player card opens the name editor")
	_back()
	await _settle(0.3)
	_check(lobby.get("_modal") == null, "back closes the name editor")
	# How to play from its menu row; the header X closes it.
	await _tap(howto)
	await _settle(0.6)
	await at.shot("m04_how_to_play")
	var modal := lobby.get("_modal") as Node
	_check(modal != null, "HOW TO PLAY opens")
	if modal:
		await _tap(modal.find_child("Close", true, false) as Control)
		await _settle(0.3)
	_check(lobby.get("_modal") == null, "the popup X closes HOW TO PLAY")
	# Wardrobe: open with a tap, pick a card by tapping it, filter by rarity, back closes it.
	await _tap(lobby.find_child("BundlesButton", true, false) as Control)
	await at.wait(1.2)
	var royal := lobby.find_child("Bundle_royal", true, false) as Control
	_check(royal != null, "wardrobe lists Bundle_royal")
	if royal:
		await _tap(royal)
		await at.wait(0.6)
	_check(String(lobby.get("_preview_bundle")) == "royal", "tapping a bundle card previews it")
	await _settle(0.5)
	await at.shot("m05_wardrobe")
	await _tap(lobby.find_child("Tab_epic", true, false) as Control)
	await _settle(0.5)
	await at.shot("m06_wardrobe_epic")
	_check(lobby.find_child("Bundle_royal", true, false) == null and lobby.find_child("Bundle_neon", true, false) != null, "EPIC tab filters the cards")
	_back()
	await _settle(0.8)
	_check(lobby.get("wardrobe") == null and String(Game.profile.bundle) == saved_bundle, "back closes the wardrobe and keeps the equipped outfit")
	# Settings: open from the gear, walk the tabs with taps, tap a few options.
	await _tap(lobby.find_child("SettingsButton", true, false) as Control)
	await _settle(0.6)
	var sp := _settings(lobby)
	_check(sp != null, "settings opens from the gear")
	if sp:
		await at.shot("m07_settings_basic")
		var g_before := int(Game.settings.graphics)
		var high_q := _find_text(sp, "HIGH")
		if high_q:
			await _tap(high_q)
		_check(int(Game.settings.graphics) == 2, "tapping HIGH sets graphics 2")
		Game.settings.graphics = g_before
		await _tap(_find_text(sp, "CONTROLS"))
		await _settle(0.4)
		await at.shot("m08_settings_controls")
		_check(sp.find_child("EditHud", true, false) != null, "lobby settings offer EDIT CUSTOM HUD")
		(sp.get("_scroll") as ScrollContainer).scroll_vertical = 100000
		await _settle(0.4)
		await at.shot("m09_settings_controls_more")
		await _tap(_find_text(sp, "SENSITIVITY"))
		await _settle(0.3)
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
		await _tap(_find_text(sp, "SOUND"))
		await _settle(0.3)
		await at.shot("m11_settings_sound")
		var closed := [false]
		sp.closed.connect(func() -> void: closed[0] = true)
		_back()
		await _settle(0.4)
		_check(closed[0] and _settings(lobby) == null and lobby.get("_modal") == null, "back saves and closes the settings (and nothing else)")
	# Back with nothing open asks before quitting; CANCEL and back both close the dialog.
	_back()
	await _settle(0.4)
	_check(lobby.find_child("QuitDialog", true, false) != null, "back in the lobby asks before quitting")
	await at.shot("m12b_quit_dialog")
	await _tap(lobby.find_child("QuitCancel", true, false) as Control)
	await _settle(0.3)
	_check(lobby.get("_modal") == null, "CANCEL closes the quit dialog")
	_back()
	await _settle(0.2)
	_back()
	await _settle(0.3)
	_check(lobby.get("_modal") == null, "a second back closes the quit dialog")
	# START -> match loading overlay (back is ignored there) -> arena.
	await _tap(lobby.get("start_btn") as Control, 0.05)
	await _settle(0.25)
	await at.shot("m13_match_loading")
	_back()
	await _settle(0.1)
	_check(lobby.find_child("QuitDialog", true, false) == null, "back during the match loading does nothing")
	var arena := await _wait_scene("Arena", 30.0)
	_check(arena != null, "START enters the arena")
	if arena:
		await at.wait(1.0)
		# Android back opens the pause menu (and the same request must not close it again).
		_back()
		await _settle(0.5)
		var pm := arena.find_child("PauseMenu", true, false)
		_check(pm != null and get_tree().paused, "back in a match opens the pause menu and keeps it open")
		var hud := arena.get("hud") as CanvasItem
		_check(hud != null and not hud.visible, "the match HUD is hidden under the pause menu")
		await at.shot("m14_pause")
		if pm:
			await _tap(pm.find_child("Settings", true, false) as Control)
			await _settle(0.5)
			var psp: Node = null
			for c in pm.get_children():
				if c is SettingsPanel:
					psp = c
			_check(psp != null, "SETTINGS opens over the pause menu")
			if psp:
				await _tap(_find_text(psp, "CONTROLS"))
				await _settle(0.4)
				(psp.get("_scroll") as ScrollContainer).scroll_vertical = 100000
				await _settle(0.4)
				await at.shot("m15_pause_settings")
				_check(psp.find_child("EditHud", true, false) == null and psp.find_child("EditHudNote", true, false) != null,
					"in a match the HUD editor shortcut is replaced by a note")
				_back()
				await _settle(0.4)
			_check(arena.find_child("PauseMenu", true, false) != null and _no_settings(pm), "back closes the settings, the pause menu stays")
			_back()
			await _settle(0.4)
			_check(arena.find_child("PauseMenu", true, false) == null and not get_tree().paused and hud.visible,
				"a second back resumes the match and shows the HUD again")
		# The HUD gear opens it too; RESUME closes it.
		var gear_c := HudLayout.center(HudLayout.current().settings, get_viewport().get_visible_rect().size)
		await _tap_at(gear_c)
		await _settle(0.4)
		var pm2 := arena.find_child("PauseMenu", true, false)
		_check(pm2 != null and get_tree().paused, "the HUD gear opens the pause menu")
		if pm2:
			await _tap(pm2.find_child("Resume", true, false) as Control)
			await _settle(0.4)
		_check(not get_tree().paused, "RESUME unpauses")
	# Results in an empty scene (the key art stands in for the arena behind; a stub scoreboard
	# gives the opponent's row).
	for r in [_sample("victory"), _sample("defeat"), _sample("draw"), _sample("invalid")]:
		var rs := await _results_scene(r)
		await _settle(2.8)
		await at.shot("m16_results_%s" % String(r.kind))
		_check(rs.find_child("PlayAgain", true, false) != null and rs.find_child("Lobby", true, false) != null, "results buttons PlayAgain + Lobby (%s)" % r.kind)
		_check(rs.find_child("EnemyRow", true, false) != null, "the opponent's row comes from the scoreboard (%s)" % r.kind)
	# LOBBY tap, back on results, PLAY AGAIN tap.
	var rs2 := await _results_scene(_sample("defeat"))
	await _settle(0.6)
	await _tap(rs2.find_child("Lobby", true, false) as Control)
	_check(await _wait_scene("Lobby", 30.0) != null, "LOBBY returns to the lobby")
	rs2 = await _results_scene(_sample("draw"))
	await _settle(0.6)
	_back()
	_check(await _wait_scene("Lobby", 30.0) != null, "back on the results returns to the lobby")
	rs2 = await _results_scene(_sample("victory"))
	await _settle(0.6)
	await _tap(rs2.find_child("PlayAgain", true, false) as Control)
	await _settle(0.2)
	var overlay := false
	for n in get_tree().root.find_children("*", "Control", true, false):
		if n is Loading:
			overlay = true
	_check(overlay or get_tree().current_scene.name == "Arena", "PLAY AGAIN shows the match loading")
	_back()
	_check(await _wait_scene("Arena", 30.0) != null, "PLAY AGAIN starts a new match (back ignored while it loads)")
	_check(ResultsScreen.honour({"headshots": 2, "hp_left": 50, "taken": 150}) == "SHARPSHOOTER", "honour SHARPSHOOTER")
	_check(ResultsScreen.honour({"headshots": 0, "hp_left": 180, "taken": 20}) == "UNTOUCHABLE", "honour UNTOUCHABLE")
	_check(ResultsScreen.honour({"won": true, "headshots": 1, "hp_left": 12, "taken": 188}) == "CLUTCH", "honour CLUTCH")
	_check(ResultsScreen.honour({"won": false, "headshots": 1, "hp_left": 12, "taken": 188}) == "FIGHTER", "no CLUTCH without a win")
	_check(ResultsScreen.honour({"headshots": 0, "hp_left": 0, "taken": 200}) == "FIGHTER", "honour FIGHTER")
	Game.settings = saved_settings
	Game.save_settings()
	Game.profile.bundle = saved_bundle
	Game.profile.name = saved_name
	Game.save_profile()
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


## An empty scene with the key art and a stub `scoreboard_rows()` (what the arena offers), the
## results screen on top.
func _results_scene(r: Dictionary) -> ResultsScreen:
	var stub := GDScript.new()
	stub.source_code = "extends Control\nvar rows: Array = []\nfunc scoreboard_rows() -> Array:\n\treturn rows\n"
	stub.reload()
	var root := Control.new()
	root.set_script(stub)
	root.name = "ResultsTest"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# the opponent's numbers match the outcome: beaten, winner, or level on HP at the time-out
	var e: Dictionary = {"victory": {"hp": 0, "kills": 0, "damage": 88, "headshots": 0},
		"defeat": {"hp": 64, "kills": 1, "damage": 200, "headshots": 2},
		"draw": {"hp": 84, "kills": 0, "damage": 116, "headshots": 1},
		"invalid": {"hp": 140, "kills": 0, "damage": 60, "headshots": 0}}[String(r.kind)]
	root.set("rows", [
		{"name": "ROOKIE", "me": true, "alive": int(r.hp_left) > 0, "hp": int(r.hp_left), "kills": int(r.kills), "damage": int(r.damage),
			"headshots": int(r.headshots), "accuracy": 47, "rounds": int(r.score_player), "weapon": "AR-7 RIFLE"},
		{"name": "VIPER", "me": false, "alive": int(e.hp) > 0, "hp": int(e.hp), "kills": int(e.kills), "damage": int(e.damage),
			"headshots": int(e.headshots), "accuracy": 31, "rounds": int(r.score_bot), "weapon": "AR-7 RIFLE"},
	])
	var tex := UI.texture("keyart_clean.jpg")
	if tex:
		root.add_child(UI.cover(tex))
	get_tree().change_scene_to_node(root)
	await _at.wait(0.3)
	var rs := ResultsScreen.new()
	root.add_child(rs)
	rs.setup(r)
	return rs


func _settings(lobby: Node) -> SettingsPanel:
	for c in (lobby.get("ui") as Node).get_children():
		if c is SettingsPanel and not c.is_queued_for_deletion():
			return c
	return null


func _no_settings(n: Node) -> bool:
	if n == null:
		return true
	for c in n.get_children():
		if c is SettingsPanel and not c.is_queued_for_deletion():
			return false
	return true


func _find_text(root: Node, text: String) -> Button:
	for b in root.find_children("*", "Button", true, false):
		if (b as Button).text == text and (b as Button).is_visible_in_tree():
			return b
	return null


## Android back as the engine delivers it (Window::_propagate_window_notification): the node
## first, then its children by index, re-reading the count, so children added on the way get
## the same notification.
func _back() -> void:
	_prop(get_tree().root)


func _prop(n: Node) -> void:
	n.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	var i := 0
	while i < n.get_child_count():
		var c := n.get_child(i)
		if not (c is Window):
			_prop(c)
		i += 1


## Brightest pixel (luminance 0..255) of a menu row's caption start (where a plate drawn over
## the text used to grey it out most).
func _caption_lum(c: Control) -> float:
	if c == null:
		return 0.0
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var fx: Transform2D = get_tree().root.get_final_transform()
	var r := c.get_global_rect()
	var a: Vector2 = fx * (r.position + Vector2(60, 8))
	var b: Vector2 = fx * (r.position + Vector2(130, r.size.y - 8))
	var best := 0.0
	for y in range(int(a.y), int(b.y)):
		for x in range(int(a.x), int(b.x)):
			var col := img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(y, 0, img.get_height() - 1))
			best = maxf(best, col.r * 0.2126 + col.g * 0.7152 + col.b * 0.0722)
	return best * 255.0


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
	await _tap_at(c.get_global_rect().get_center(), hold)


## A real tap at a canvas position.
func _tap_at(p: Vector2, hold := 0.08) -> void:
	var w: Vector2 = get_tree().root.get_final_transform() * p
	_at.touch(0, w, true)
	await _at.wait(hold)
	_at.touch(0, w, false)
	await _at.wait(0.12)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	_at.log_line(("ok   " if ok else "FAIL ") + what)
