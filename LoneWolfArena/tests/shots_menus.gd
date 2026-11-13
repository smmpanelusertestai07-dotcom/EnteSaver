extends Node
## Menus screenshot tour (everything outside the match), with real-input checks:
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_menus.gd
## Boot/loading screen, the first-start name prompt (top of the screen, RANDOM, OK), lobby (the
## reference's layout: the bottom bar's captions bright, FRIENDS and the gear top-right, no left
## menu, stats chips, name plate or version; drag to turn the character, START position report),
## the modes (mode card, SELECT MODE with the opponent chips, the "?" picture help of each mode
## card (every page; arrow, swipe, dot; X and back), the DUMMY chip, LONE WOLF's START opens
## the QUICK MATCH search, CANCEL; the size chips and the mode card's team-size box), name edit (pencil tap, long name ends in "..."), the player card (opens
## PROFILE), the wardrobe (card tap, every outfit listed), ONLINE 1 VS 1 and FRIENDS, every
## settings tab (tab and sub-tab taps, HIGH graphics, EXTREME's question, the HUD page's CUSTOM, a
## CONTROLS row's picture, the HIGH / DEFAULT sensitivity presets, RESET's question, ACCOUNT with the Privacy Notice and DELETE MY DATA's question), HOW TO
## PLAY from the settings (MODES on top), the quit dialog, the match card of an online match, START ->
## match loading overlay (TRAINING GROUND) -> arena, the in-match settings (opened by Android
## back and by the HUD gear: QUIT MATCH in them, EDIT CUSTOM HUD opens the editor over the
## match), results screens (win, defeat, draw, invalid, online) with the opponent's row in an
## empty scene whose stub scoreboard stands in for the arena, PLAY AGAIN and LOBBY taps.
## Android back is sent the way the engine delivers it (_back(): the node, then its children
## by index, children added during the walk included), so a menu opened by a back request also
## receives that same request. Returns the number of failed checks.

var _fails := 0
var _at: Node
var saved_guest := false
## The capture box draws 1-3 frames a second and caps the process step, so tweens (process
## time) lag the autotest timers (real time): waits before shots use _settle().


func run(at: Node) -> int:
	_at = at
	var saved_settings: Dictionary = Game.settings.duplicate(true)
	var saved_bundle := String(Game.profile.bundle)
	var saved_name := String(Game.profile.name)
	saved_guest = bool(Game.profile.guest_ok)
	Game.settings.difficulty = 1
	Game.mode = "training"
	Game.practice = false
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
	_check(lobby.find_child("Coins", true, false) == null and lobby.find_child("FeatureCard", true, false) == null
		and _find_label(lobby, "OFFLINE") == null, "no coin strip, OFFLINE chip or featured card in the lobby")
	var bar := lobby.find_child("BottomBar", true, false) as Control
	var ward := lobby.find_child("BundlesButton", true, false) as Button
	var online_btn := lobby.find_child("OnlineButton", true, false) as Button
	var prof_btn := lobby.find_child("ProfileButton", true, false) as Button
	_check(bar != null and ward != null and online_btn != null and prof_btn != null and ward.text == "WARDROBE" and online_btn.text == "ONLINE 1 VS 1"
		and prof_btn.text == "PROFILE" and bar.is_ancestor_of(ward) and bar.is_ancestor_of(online_btn) and bar.is_ancestor_of(prof_btn),
		"the bottom bar: WARDROBE, PROFILE and ONLINE 1 VS 1")
	var strip := lobby.find_child("ChatStrip", true, false) as Control
	var add_btn := lobby.find_child("AddFriendButton", true, false) as Control
	_check(strip != null and bar != null and strip.get_global_rect().end.y <= bar.get_global_rect().position.y
		and add_btn != null and add_btn.get_global_rect().position.x > get_viewport().get_visible_rect().size.x * 0.9,
		"the chat strip sits on the bottom bar, ADD on the right edge")
	var vs0 := get_viewport().get_visible_rect().size
	_check(bar != null and bar.get_global_rect().position.x < vs0.x * 0.05 and bar.get_global_rect().end.y > vs0.y * 0.9
		and bar.get_global_rect().end.x < vs0.x * 0.5, "the bar sits bottom-left")
	var pals := lobby.find_child("FriendsButton", true, false) as Control
	var gear := lobby.find_child("SettingsButton", true, false) as Control
	_check(pals != null and gear != null and pals.get_global_rect().position.x > vs0.x * 0.8 and pals.get_global_rect().end.x <= gear.get_global_rect().position.x
		and gear.get_global_rect().end.y < vs0.y * 0.12, "FRIENDS left of the gear, top-right")
	_check(lobby.find_child("Menu", true, false) == null and lobby.find_child("HowToPlayButton", true, false) == null
		and lobby.find_child("CustomHudButton", true, false) == null and lobby.find_child("HelpButton", true, false) == null
		and lobby.find_child("Stats", true, false) == null and lobby.find_child("OutfitName", true, false) == null
		and _find_label(lobby, "v%s" % ProjectSettings.get_setting("application/config/version", "")) == null
		and _find_label(lobby, String(Game.profile.name)) == lobby.find_child("PlayerName", true, false),
		"no left menu, stats chips, outfit or version text, no name plate: the name only in the player card")
	var lum := await _caption_lum(ward)
	_check(lum >= 230.0, "the bar's captions are drawn bright (WARDROBE max lum %.0f)" % lum)
	for c: Control in [ward, prof_btn, online_btn, pals, gear, strip, add_btn]:
		_check(c.size.y >= UI.TOUCH_MIN and c.size.x >= UI.TOUCH_MIN, "%s is a full touch target" % c.name)
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
	await _tour_modes(lobby)
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
	# The whole player card opens PROFILE (tests/shots_profile.gd tours it); back closes it.
	var card := lobby.find_child("PlayerCard", true, false) as Control
	if card:
		await _tap_at(card.get_global_rect().position + Vector2(34, 31))
		await _settle(0.3)
	_check(lobby.find_child("Profile", true, false) != null, "tapping the player card opens PROFILE")
	_back()
	await _settle(0.3)
	_check(lobby.find_child("Profile", true, false) == null and lobby.get("_modal") == null, "back closes PROFILE")
	# ONLINE 1 VS 1 (the bottom bar) opens the ONLINE window on its ONLINE tab, FRIENDS on FRIENDS.
	await _tap(online_btn)
	await _settle(0.6)
	var win := lobby.get("_modal") as Control
	_check(win != null and win.find_child("Tab_online", true, false) != null and String(lobby.friends.get("_net_kind")) == "online",
		"ONLINE 1 VS 1 opens the ONLINE window")
	await at.shot("m04_online")
	_back()
	await _settle(0.4)
	await _tap(pals)
	await _settle(0.6)
	win = lobby.get("_modal") as Control
	_check(win != null and String(lobby.friends.get("_net_kind")) == "friends", "FRIENDS opens the ONLINE window on FRIENDS")
	await at.shot("m04b_friends")
	_back()
	await _settle(0.4)
	_check(lobby.get("_modal") == null, "back closes the ONLINE window")
	# Wardrobe: open with a tap (the bar reads WARDROBE), every outfit listed (no rarity tabs), pick
	# a card by tapping it, back closes it.
	var ward_row := ward
	await _tap(ward_row)
	await at.wait(1.2)
	var royal := lobby.find_child("Bundle_royal", true, false) as Control
	_check(royal != null, "wardrobe lists Bundle_royal")
	if royal:
		await _tap(royal)
		await at.wait(0.6)
	_check(String(lobby.get("_preview_bundle")) == "royal", "tapping a bundle card previews it")
	var listed := 0
	for b: Dictionary in CharacterModel.BUNDLE_INFO:
		if lobby.find_child("Bundle_" + String(b.id), true, false) != null:
			listed += 1
	_check(listed == CharacterModel.BUNDLE_INFO.size() and lobby.find_child("Tab_epic", true, false) == null,
		"the wardrobe lists all %d outfits, with no rarity tabs" % CharacterModel.BUNDLE_INFO.size())
	await _settle(0.5)
	await at.shot("m05_wardrobe")
	_back()
	await _settle(0.8)
	_check(lobby.get("wardrobe") == null and String(Game.profile.bundle) == saved_bundle, "back closes the wardrobe and keeps the equipped outfit")
	# Settings: open from the gear, walk the tabs with taps, tap a few options.
	await _tap(lobby.find_child("SettingsButton", true, false) as Control)
	await _settle(0.6)
	var sp := _settings(lobby)
	_check(sp != null, "settings opens from the gear")
	if sp:
		await at.shot("m07a_settings_hud")
		_check(sp.find_child("EditHud", true, false) != null and (sp.find_child("SubTabs", true, false) as Control).visible,
			"the settings open on IN-MATCH > HUD: lobby settings offer CUSTOM")
		await _tap(_find_text(sp, "DISPLAY"))
		await _settle(0.4)
		await at.shot("m07_settings_display")
		var g_before := int(Game.settings.graphics)
		var high_q := _find_text(sp, "HIGH")
		if high_q:
			await _tap(high_q)
		_check(int(Game.settings.graphics) == 2, "tapping HIGH sets graphics 2")
		# EXTREME asks first (it can heat the phone); back answers the question, not the panel.
		await _tap(_find_text(sp, "EXTREME"))
		await _settle(0.4)
		await at.shot("m07b_settings_extreme")
		_check(sp.find_child("Confirm", true, false) != null and int(Game.settings.graphics) == 2, "EXTREME asks before it applies")
		_back()
		await _settle(0.4)
		_check(_settings(lobby) != null and sp.find_child("Confirm", true, false) == null and int(Game.settings.graphics) == 2,
			"back closes the question and keeps the settings open")
		Game.settings.graphics = g_before
		await _tap(_find_text(sp, "IN-MATCH"))
		await _settle(0.3)
		await _tap(_find_text(sp, "CONTROLS"))
		await _settle(0.4)
		await at.shot("m08_settings_controls")
		_check(sp.find_child("Preview", true, false) != null and (sp.find_child("Preview", true, false) as Control).visible
			and String(sp.get("_sel")) == "aim", "CONTROLS: the picture of the first row (aim precision)")
		(sp.get("_scroll") as ScrollContainer).scroll_vertical = 100000
		await _settle(0.4)
		var fl := sp.find_child("Row_freelook_button", true, false) as Control
		if fl:
			await _tap(fl)
		await _settle(0.4)
		await at.shot("m09_settings_controls_more")
		_check(String(sp.get("_sel")) == "freelook_button", "a tap on a row selects it (its picture shows)")
		await _tap(_find_text(sp, "SENSITIVITY"))
		await _settle(0.3)
		var fast := _find_text(sp, "HIGH")
		if fast:
			await _tap(fast)
		await _settle(0.3)
		await at.shot("m10_settings_sensitivity")
		var fp: Dictionary = SettingsPanel.SENS_PRESETS.HIGH
		_check(int(Game.settings.sens_general) == int(fp.sens_general) and int(Game.settings.sens_sniper) == int(fp.sens_sniper)
			and int(Game.settings.sens_2x) == int(fp.sens_2x), "HIGH preset sets its values")
		var standard := _find_text(sp, "DEFAULT")
		if standard:
			await _tap(standard)
		_check(int(Game.settings.sens_general) == 100 and int(Game.settings.sens_sniper) == 71, "DEFAULT preset sets 100 / 71")
		# RESET asks first; CANCEL keeps everything.
		await _tap(sp.find_child("Reset", true, false) as Control)
		await _settle(0.4)
		await at.shot("m10b_settings_reset_confirm")
		_check(sp.find_child("Confirm", true, false) != null, "RESET asks before it resets")
		await _tap(sp.find_child("ConfirmCancel", true, false) as Control)
		await _settle(0.3)
		_check(sp.find_child("Confirm", true, false) == null, "CANCEL closes the question")
		await _tap(_find_text(sp, "SOUND"))
		await _settle(0.3)
		await at.shot("m11_settings_sound")
		_check(sp.find_children("*", "HSlider", true, false).size() == 3, "SOUND: effects, music, voice chat (no master)")
		# ACCOUNT: the player ID, CLEAR CACHE, the links along the bottom (no RESET).
		await _tap(_find_text(sp, "ACCOUNT"))
		await _settle(0.4)
		await at.shot("m11b_settings_account")
		_check(sp.find_child("PlayerIdValue", true, false) != null and sp.find_child("ClearCache", true, false) != null
			and not (sp.find_child("Reset", true, false) as Control).visible, "ACCOUNT: the player ID, CLEAR CACHE, no RESET")
		await _tap(sp.find_child("PrivacyLink", true, false) as Control)
		await _settle(0.5)
		await at.shot("m11c_settings_privacy")
		_check(sp.find_child("Sheet", false, false) != null and sp.find_child("DocScroll", true, false) != null,
			"the Privacy Notice opens over the settings")
		_back()
		await _settle(0.4)
		_check(sp.find_child("Sheet", false, false) == null and _settings(lobby) != null, "back closes the Privacy Notice, not the settings")
		await _tap(sp.find_child("DeleteData", true, false) as Control)
		await _settle(0.4)
		await at.shot("m11d_settings_delete_ask")
		_check(sp.find_child("Confirm", true, false) != null, "DELETE MY DATA asks first")
		await _tap(sp.find_child("ConfirmCancel", true, false) as Control)
		await _settle(0.3)
		_check(sp.find_child("Confirm", true, false) == null and bool(Game.profile.guest_ok) == saved_guest,
			"CANCEL deletes nothing")
		# HOW TO PLAY under the tabs: a page with MODES on top; its X closes it.
		await _tap(sp.find_child("HowToPlay", false, false) as Control)
		await _settle(0.6)
		await at.shot("m04_how_to_play")
		var page := sp.find_child("Sheet", false, false)
		var modes_row := page.find_child("HowToModes", true, false) if page else null
		_check(modes_row != null and modes_row.get_child_count() == Game.MODE_NAMES.size() and _find_label(page, "TRAINING GROUND") != null
			and _find_label(page, "LONE WOLF") != null and _find_label(page, "FIRST TO %d ROUNDS" % Game.ROUNDS_TO_WIN) != null,
			"HOW TO PLAY (SETTINGS) explains both modes and first to %d" % Game.ROUNDS_TO_WIN)
		if page:
			await _tap(page.find_child("Close", true, false) as Control)
			await _settle(0.3)
		_check(sp.find_child("Sheet", false, false) == null and _settings(lobby) != null, "the page's X closes HOW TO PLAY")
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
	# The match card of an online match; the lobby comes back without a session.
	var next_lobby := await _tour_online_card(lobby)
	if next_lobby:
		lobby = next_lobby
	# START (TRAINING GROUND, the bot) -> match loading overlay (back is ignored there) -> arena.
	var start := lobby.get("start_btn") as Button
	await _tap(start, 0.05)
	await _settle(0.25)
	await at.shot("m13_match_loading")
	_check(start.disabled and (start.get_node("Caption") as Label).text == "LOADING", "START says LOADING (not MATCHING) for a bot match")
	var ov := _find_overlay()
	_check(ov != null and _label_text(ov, "MatchMode") == "TRAINING GROUND"
		and _texts(ov).contains("FIRST TO %d|1 VS BOT|BOT: NORMAL" % Game.rounds_to_win()),
		"the match card: TRAINING GROUND, FIRST TO n, 1 VS BOT, BOT: NORMAL")
	_back()
	await _settle(0.1)
	_check(lobby.find_child("QuitDialog", true, false) == null, "back during the match loading does nothing")
	var arena := await _wait_scene("Arena", 30.0)
	_check(arena != null, "START enters the arena")
	if arena:
		await at.wait(1.0)
		# Android back opens the in-match menu: the settings straight away (and the same request
		# must not close them again), QUIT MATCH in their tab column, the match paused.
		_back()
		await _settle(0.5)
		var pm := arena.find_child("PauseMenu", true, false)
		var psp: Node = pm.get("settings") if pm else null
		_check(pm != null and get_tree().paused and psp is SettingsPanel, "back in a match opens the settings at once and keeps them open")
		var hud := arena.get("hud") as CanvasItem
		_check(hud != null and not hud.visible, "the match HUD is hidden under the in-match settings")
		var quit: Button = (psp.find_child("Quit", true, false) as Button) if psp else null
		_check(quit != null and quit.text == "QUIT MATCH" and quit.get_global_rect().end.x <= SettingsPanel.MENU_W + 1.0
			and quit.size.y >= UI.TOUCH_MIN, "QUIT MATCH sits in the settings' tab column")
		await at.shot("m14_pause")
		# (TRAINING GROUND quits at one tap; the online question is in the HUD tour, tests/shots_hud.gd)
		if psp:
			await _tap(_find_text(psp, "HUD"))
			await _settle(0.4)
			await at.shot("m15_pause_settings")
			var edit := psp.find_child("EditHud", true, false) as Control
			_check(edit != null and psp.find_child("EditHudNote", true, false) == null, "in a match EDIT CUSTOM HUD is there")
			# EDIT CUSTOM HUD opens the editor over the match; back closes it to the settings.
			await _tap(edit)
			await _settle(0.6)
			var ed := pm.find_child("HudEditor", true, false)
			_check(ed != null and get_tree().paused and arena == get_tree().current_scene, "EDIT CUSTOM HUD opens the editor over the paused match")
			await at.shot("m15b_pause_hud_editor")
			_back()
			await _settle(0.4)
			_check(pm.find_child("HudEditor", true, false) == null and is_instance_valid(psp) and not psp.is_queued_for_deletion(),
				"back closes the editor, the settings stay")
			_back()
			await _settle(0.4)
			_check(arena.find_child("PauseMenu", true, false) == null and not get_tree().paused and hud.visible,
				"back again closes the settings: the match goes on, its HUD shows again")
		# The HUD gear opens them too; their X closes them and the match goes on.
		var gear_c := HudLayout.center(HudLayout.current().settings, get_viewport().get_visible_rect().size)
		await _tap_at(gear_c)
		await _settle(0.4)
		var pm2 := arena.find_child("PauseMenu", true, false)
		_check(pm2 != null and get_tree().paused and pm2.get("settings") is SettingsPanel, "the HUD gear opens the settings")
		if pm2 and pm2.get("settings") is SettingsPanel:
			await _tap((pm2.get("settings") as Node).find_child("Close", true, false) as Control)
			await _settle(0.4)
		_check(not get_tree().paused and arena.find_child("PauseMenu", true, false) == null, "the settings' X closes them and unpauses")
	# Results in an empty scene (the key art stands in for the arena behind; a stub scoreboard
	# gives the opponent's row).
	for r in [_sample("victory"), _sample("defeat"), _sample("draw"), _sample("invalid"), _sample("online")]:
		var rs := await _results_scene(r)
		await _settle(2.8)
		await at.shot("m16_results_%s" % String(r.kind))
		_check(_find_label(rs, String(r.mode)) != null, "the results name the mode %s (%s)" % [r.mode, r.kind])
		# Page 2 (the tables, EnemyRow among them): CONTINUE turns to it (results in two pages).
		await _tap(rs.find_child("Continue", true, false) as Control)
		await _settle(0.5)
		_check(rs.page == 2, "CONTINUE turns the results to their tables (%s)" % r.kind)
		await at.shot("m16b_results_%s_tables" % String(r.kind))
		if String(r.kind) == "online":
			_check(rs.find_child("Rematch", true, false) != null and rs.find_child("AddFriend", true, false) != null
				and rs.find_child("PlayAgain", true, false) == null and rs.find_child("Lobby", true, false) != null,
				"online results: REMATCH and ADD FRIEND (not PLAY AGAIN) + LOBBY")
		else:
			_check(rs.find_child("PlayAgain", true, false) != null and rs.find_child("Lobby", true, false) != null, "results buttons PlayAgain + Lobby (%s)" % r.kind)
		_check(rs.find_child("EnemyRow", true, false) != null, "the opponent's row comes from the scoreboard (%s)" % r.kind)
		if String(r.kind) == "online":
			# (on page 2, where EnemyRow is: _find_label wants it shown)
			var bot_words := Array(_texts(rs).split("|")).filter(func(w: String) -> bool: return w.contains("BOT"))
			_check(_find_label(rs.find_child("EnemyRow", true, false), "ONLINE") != null and bot_words.is_empty(),
				"an online opponent is ONLINE, never a BOT level %s" % str(bot_words))
	# LOBBY tap, back on results, PLAY AGAIN tap.
	var rs2 := await _results_scene(_sample("defeat"))
	await _settle(0.6)
	await _tap(rs2.find_child("Continue", true, false) as Control)       # (LOBBY is on page 2)
	await _settle(0.4)
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
	Game.practice = false
	Game.profile.bundle = saved_bundle
	Game.profile.name = saved_name
	Game.save_profile()
	at.log_line("MENUS TOUR DONE fails=%d" % _fails)
	return _fails


## The two modes in the lobby: the mode card shows TRAINING GROUND (the default) against the NORMAL
## bot; SELECT MODE offers both, with TRAINING GROUND's opponent chips (the bot's level or the
## DUMMY) on its card; LONE WOLF's START opens the QUICK MATCH search (CANCEL stops it); back to
## TRAINING GROUND at the end.
func _tour_modes(lobby: Node) -> void:
	var card := lobby.find_child("ModeCard", true, false) as Control
	_check(lobby.find_child("PracticeButton", true, false) == null and lobby.find_child("Difficulty", true, false) == null,
		"the lobby has no opponent chips of its own: they are in SELECT MODE")
	_check(card != null and _label_text(card, "ModeName") == "TRAINING GROUND" and _find_label(card, "CARGO CAGE") != null,
		"the mode card shows TRAINING GROUND on CARGO CAGE")
	_check(_label_text(card, "ModeFormat") == "BOT: NORMAL  ·  FIRST TO %d" % Game.rounds_to_win(),
		"the mode card names the bot and the real round count (%s)" % _label_text(card, "ModeFormat"))
	# SELECT MODE from the mode card: both modes, the opponent chips on TRAINING GROUND's card.
	await _tap(card)
	await _settle(0.6)
	var popup := lobby.get("_modal") as Control
	var tg := popup.find_child("Mode_training", true, false) if popup else null
	var chips := tg.find_child("Difficulty", true, false) if tg else null
	_check(popup != null and tg != null and popup.find_child("Mode_lonewolf", true, false) != null,
		"the mode card opens SELECT MODE with both modes")
	_check(chips != null and chips.get_child_count() == Game.DIFFICULTY_NAMES.size() + 1 and chips.find_child("Diff_DUMMY", false, false) != null
		and (chips.find_child("Diff_NORMAL", false, false) as Button).button_pressed, "TRAINING GROUND's card offers EASY, NORMAL, HARD and the DUMMY")
	await _at.shot("m02b_select_mode")
	await _tour_mode_help(lobby)
	popup = lobby.get("_modal") as Control
	chips = popup.find_child("Difficulty", true, false) if popup else null
	# The DUMMY chip: the target dummy instead of a bot (the card says so); it closes SELECT MODE.
	await _tap(chips.find_child("Diff_DUMMY", false, false) as Control if chips else null)
	await _settle(0.4)
	_check(Game.practice and Game.mode == "training" and lobby.get("_modal") == null and _label_text(card, "ModeFormat") == "TARGET DUMMY",
		"DUMMY picks the target dummy and closes SELECT MODE")
	await _at.shot("m02e_lobby_dummy")
	await _tap(card)
	await _settle(0.5)
	popup = lobby.get("_modal") as Control
	await _tap(popup.find_child("Diff_HARD", true, false) as Control if popup else null)
	await _settle(0.4)
	_check(not Game.practice and int(Game.settings.difficulty) == 2 and _label_text(card, "ModeFormat").begins_with("BOT: HARD"),
		"HARD picks the bot again, at its level")
	await _tap(card)
	await _settle(0.5)
	popup = lobby.get("_modal") as Control
	await _tap(popup.find_child("Diff_NORMAL", true, false) as Control if popup else null)
	await _settle(0.4)
	_check(int(Game.settings.difficulty) == 1 and not Game.practice, "NORMAL again")
	# LONE WOLF.
	await _tap(card)
	await _settle(0.5)
	popup = lobby.get("_modal") as Control
	if popup:
		await _tap_art(popup.find_child("Mode_lonewolf", true, false) as Control)
		await _settle(0.5)
	_check(Game.mode == "lonewolf" and lobby.get("_modal") == null and Game.settings.mode == "lonewolf", "picking LONE WOLF keeps it and closes the popup")
	_check(_label_text(card, "ModeName") == "LONE WOLF" and _label_text(card, "ModeFormat") == "1 VS 1 ONLINE",
		"the LONE WOLF card says 1 VS 1 ONLINE")
	await _at.shot("m02c_lobby_lone_wolf")
	# LONE WOLF's START searches for a random opponent (QUICK MATCH: the search tab at the top with
	# the time and its X; no popup, no match loads by itself); the X stops the search.
	var start := lobby.get("start_btn") as Button
	await _tap(start)
	await _settle(1.2)
	var tab := lobby.get("search_tab") as Control
	var quick := lobby.get_node_or_null("NetMatch") as NetMatch
	_check(lobby.get("_modal") == null and tab != null and tab.is_visible_in_tree() and tab.find_child("SearchCancel", true, false) != null
		and quick != null and quick.searching and not start.disabled and Game.cloud_service().seeking,
		"LONE WOLF's START shows the QUICK MATCH search tab (no popup)")
	_check(_find_overlay() == null, "LONE WOLF's START loads no match")
	await _at.shot("m02d_lone_wolf_start")
	if tab:
		await _tap(tab.find_child("SearchCancel", true, false) as Control)
		await _settle(0.4)
	_check(tab != null and not tab.is_visible_in_tree() and quick != null and not quick.searching and not Game.cloud_service().seeking,
		"the search tab's X stops the search")
	# And back to TRAINING GROUND (a tap on its card, away from the chips).
	await _tap(card)
	await _settle(0.5)
	popup = lobby.get("_modal") as Control
	if popup:
		await _tap_art(popup.find_child("Mode_training", true, false) as Control)
		await _settle(0.5)
	_check(Game.mode == "training" and _label_text(card, "ModeName") == "TRAINING GROUND"
		and _label_text(card, "ModeFormat").begins_with("BOT: NORMAL"), "TRAINING GROUND is picked again")
	# DUO / SQUAD: the size chips on the mode cards; DUO shows the TEAM bar (+ INVITE), SOLO hides it.
	await _tap(card)
	await _settle(0.5)
	popup = lobby.get("_modal") as Control
	var duo := popup.find_child("Mode_training", true, false).find_child("Size_2", true, false) as Control if popup else null
	await _tap(duo)
	await _settle(0.5)
	# (The TEAM bar became LONE WOLF's GROUP bar in 1.5: TRAINING GROUND's DUO plays with bots and
	# shows no group bar; tests/group_lobby_check.gd checks the bar.)
	var group_bar := lobby.find_child("GroupBar", true, false) as Control
	_check(Game.team_size == 2 and _label_text(card, "ModeFormat") == "DUO  ·  BOT: NORMAL" and group_bar != null
		and not group_bar.is_visible_in_tree(), "TRAINING DUO: the mode card says so, no GROUP bar (bot teammates)")
	await _at.shot("m02f_lobby_duo")
	# The team-size box from the figure at the card's right end: DUO lit; SOLO there picks SOLO.
	await _tap(card.find_child("SizeBoxButton", true, false) as Control)
	await _settle(0.4)
	var box := lobby.get("dialogs").size_box as Control
	_check(box != null and box.find_child("SizeTile_2", true, false) != null and lobby.get("_modal") == null,
		"the mode card's figure opens the team-size box (not SELECT MODE)")
	await _at.shot("m02g_size_box")
	await _tap(box.find_child("SizeTile_1", true, false) as Control if box else null)
	await _settle(0.4)
	_check(Game.team_size == 1 and lobby.get("dialogs").size_box == null and _label_text(card, "ModeFormat").begins_with("BOT: NORMAL"),
		"SOLO in the box picks SOLO and closes it")
	await _tap(card)
	await _settle(0.5)
	popup = lobby.get("_modal") as Control
	await _tap(popup.find_child("Mode_training", true, false).find_child("Size_2", true, false) as Control if popup else null)
	await _settle(0.5)
	await _tap(card)
	await _settle(0.5)
	popup = lobby.get("_modal") as Control
	await _tap(popup.find_child("Mode_training", true, false).find_child("Size_1", true, false) as Control if popup else null)
	await _settle(0.5)
	_check(Game.team_size == 1 and group_bar != null and not group_bar.is_visible_in_tree() and _label_text(card, "ModeFormat").begins_with("BOT: NORMAL"),
		"SOLO again")


## The "?" on each SELECT MODE card: its picture help (ModeHelp) with a page per shot, turned by
## the arrow, a swipe and a dot; the mode is not picked by it; X (LONE WOLF) and Android back
## (TRAINING GROUND) go back to SELECT MODE.
func _tour_mode_help(lobby: Node) -> void:
	for m: String in ["lonewolf", "training"]:
		var popup := lobby.get("_modal") as Control
		var mode_was := Game.mode
		var q := popup.find_child("Help_" + m, true, false) as Control if popup else null
		_check(q != null and q.size.x >= UI.TOUCH_MIN and q.size.y >= UI.TOUCH_MIN, "the %s card has a ? with a 56 px touch area" % m)
		await _tap(q)
		await _settle(0.5)
		popup = lobby.get("_modal") as Control
		var help := popup.find_child("ModeHelp", true, false) as ModeHelp if popup else null
		var n := ModeHelp.pages_of(m).size()
		_check(help != null and help.mode == m and help.page == 0 and n >= 3 and n <= 4 and Game.mode == mode_was
			and popup.find_child("Mode_" + m, true, false) == null, "the ? opens %s's picture help on page 1 of %d (the mode is not picked)" % [m, n])
		if help == null:
			continue
		_check(help.find_child("HelpDots", true, false).get_child_count() == n and (help.find_child("HelpPrev", true, false) as Button).disabled,
			"%d page dots; no page before the first" % n)
		await _at.shot("m02h_help_%s_1" % m)
		for i in range(1, n):
			if i == 1:
				# A swipe to the left across the picture turns to the next page.
				var pic := help.find_child("HelpPicture", true, false) as Control
				var r := pic.get_global_rect()
				var w0: Vector2 = get_tree().root.get_final_transform() * (r.get_center() + Vector2(r.size.x * 0.25, 0))
				var w1: Vector2 = get_tree().root.get_final_transform() * (r.get_center() - Vector2(r.size.x * 0.25, 0))
				_at.touch(0, w0, true)
				await _at.wait(0.05)
				_at.drag(0, w1, w1 - w0)
				await _at.wait(0.05)
				_at.touch(0, w1, false)
			elif i == 2:
				await _tap(help.find_child("HelpDot_2", true, false) as Control)
			else:
				await _tap(help.find_child("HelpNext", true, false) as Control)
			await _settle(0.3)
			_check(help.page == i, "%s help: page %d by %s" % [m, i + 1, ["", "a swipe", "its dot", "the arrow"][mini(i, 3)]])
			await _at.shot("m02h_help_%s_%d" % [m, i + 1])
		_check((help.find_child("HelpNext", true, false) as Button).disabled, "no page after the last")
		await _tap(help.find_child("HelpPrev", true, false) as Control)
		await _settle(0.2)
		_check(help.page == n - 2, "the back arrow turns back a page")
		if m == "lonewolf":
			await _tap(popup.find_child("Close", true, false) as Control)
		else:
			_back()
		await _settle(0.4)
		popup = lobby.get("_modal") as Control
		_check(popup != null and popup.find_child("ModeHelp", true, false) == null and popup.find_child("Mode_" + m, true, false) != null
			and Game.mode == mode_was, "%s closes the help, back to SELECT MODE" % ("X" if m == "lonewolf" else "Android back"))


## A real tap on a SELECT MODE card's art (its upper part: the mode, never a chip).
func _tap_art(c: Control) -> void:
	if c == null:
		_check(false, "tap target exists")
		return
	await _tap_at(c.get_global_rect().position + Vector2(c.size.x * 0.5, 90.0))


## The match card of an online match (LONE WOLF, FIRST TO n, 1 VS 1 ONLINE, the opponent's name;
## never "1 VS BOT"): the overlay over the lobby as a challenge starts it. With no real session
## the arena hands back to a new lobby at once, which is returned.
func _tour_online_card(lobby: Node) -> Node:
	var cloud := Game.cloud_service()
	var saved_opponent: Dictionary = cloud.opponent
	cloud.opponent = {"id": "", "name": "SHADOWHUNTER77", "bundle": "neon"}
	Game.online = true
	Game.session = cloud
	(lobby.get("start_btn") as Button).disabled = true
	Loading.start_match(lobby)
	await _settle(0.25)
	await _at.shot("m13b_match_loading_online")
	var ov := _find_overlay()
	var texts := _texts(ov) if ov else ""
	_check(ov != null and _label_text(ov, "MatchMode") == "LONE WOLF" and texts.contains("1 VS 1 ONLINE")
		and texts.contains("VS SHADOWHUNTER77") and texts.contains("FIRST TO %d" % Game.rounds_to_win(true))
		and not texts.contains("BOT"), "the online match card: LONE WOLF, FIRST TO n, 1 VS 1 ONLINE, the opponent")
	var t := 0.0
	var next: Node = null
	while t < 30.0:
		await _at.wait(0.2)
		t += 0.2
		var s := get_tree().current_scene
		if s and s != lobby and s.name == "Lobby":
			next = s
			break
	_check(next != null and not Game.online, "without a session the arena hands back to the lobby")
	cloud.opponent = saved_opponent
	await _settle(1.0)
	# The lobby says why the online match did not start (never a bot match instead), once.
	var modal: Node = next.get("_modal") if next else null
	var notice := modal.find_child("NoticeText", true, false) as Label if modal else null
	_check(notice != null and notice.text.contains("before the match began"), "the lobby says the online match did not start")
	if notice:
		await _at.shot("m13c_online_called_off")
		await _tap(modal.find_child("NoticeOk", true, false) as Control)
		await _settle(0.3)
	return next


## The Loading overlay in the tree (the match card), or null.
func _find_overlay() -> Loading:
	for n in get_tree().root.find_children("*", "Control", true, false):
		if n is Loading and not n.is_queued_for_deletion():
			return n
	return null


## The text of the Label named `label_name` under `root` ("" when there is none).
func _label_text(root: Node, label_name: String) -> String:
	var l := root.find_child(label_name, true, false) as Label if root else null
	return l.text if l else ""


## Every label text under `root`, joined with "|".
func _texts(root: Node) -> String:
	var out := PackedStringArray()
	for l in root.find_children("*", "Label", true, false):
		out.append((l as Label).text)
	return "|".join(out)


## A result as the arena builds it: TRAINING GROUND against BOT VIPER (victory, defeat, draw,
## invalid), or an online LONE WOLF win against another player ("online").
func _sample(kind: String) -> Dictionary:
	var online := kind == "online"
	var won := kind == "victory" or online
	# [your rounds, theirs, your kills (one per round won), damage, headshots, HP left, XP]
	var n: Array = {"victory": [5, 2, 5, 1176, 3, 112, 330], "defeat": [2, 5, 2, 537, 1, 0, 74],
		"draw": [4, 4, 4, 912, 1, 84, 150], "invalid": [1, 0, 1, 200, 1, 84, 0],
		"online": [5, 3, 5, 1214, 3, 96, 330]}[kind]
	var r := {"kind": kind, "won": won, "draw": kind == "draw", "invalid": kind == "invalid",
		"kills": int(n[2]), "damage": int(n[3]), "headshots": int(n[4]),
		"accuracy": 46.7, "time": 412.0, "xp": int(n[6]),
		"enemy": "SHADOWHUNTER77" if online else "BOT VIPER", "mode": Game.mode_name("lonewolf" if online else "training"),
		"mode_id": "lonewolf" if online else "training", "map": "CARGO CAGE", "weapon": String(Weapons.DEFS[Weapons.DEFAULT_PICK].name),
		"score_player": int(n[0]), "score_bot": int(n[1]), "hp_left": int(n[5]), "difficulty": "ONLINE" if online else "NORMAL",
		"taken": 88 if won else 200, "enemy_id": "shadowhunter77".sha256_text().left(32) if online else ""}
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
	var e: Dictionary = {"victory": {"hp": 0, "kills": 2, "damage": 488, "headshots": 0},
		"defeat": {"hp": 64, "kills": 5, "damage": 1000, "headshots": 2},
		"draw": {"hp": 84, "kills": 4, "damage": 916, "headshots": 1},
		"invalid": {"hp": 140, "kills": 0, "damage": 60, "headshots": 0},
		"online": {"hp": 0, "kills": 3, "damage": 652, "headshots": 1}}[String(r.kind)]
	var gun := String(r.weapon)
	root.set("rows", [
		{"name": "ROOKIE", "me": true, "alive": int(r.hp_left) > 0, "hp": int(r.hp_left), "kills": int(r.kills), "damage": int(r.damage),
			"headshots": int(r.headshots), "accuracy": 47, "rounds": int(r.score_player), "weapon": gun},
		{"name": String(r.enemy), "me": false, "alive": int(e.hp) > 0, "hp": int(e.hp), "kills": int(e.kills), "damage": int(e.damage),
			"headshots": int(e.headshots), "accuracy": 31, "rounds": int(r.score_bot), "weapon": gun},
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


## A visible label showing exactly `text` under `root`, or null.
func _find_label(root: Node, text: String) -> Label:
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).text == text and (l as Label).is_visible_in_tree():
			return l
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
