extends Node
## Intro sting and guest login screenshot tour, with real-input and layout checks:
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_login.gd
## (also 1280x720 and 1024x768). The intro sting over the boot screen (the streak, just after the
## impact, the wordmark being written, the title, the outro) and its hand-over to the boot screen;
## the guest login (everything on screen, nothing overlapping, touch targets); the Privacy Notice
## and the Terms of Use (link taps, scrolled to the end, OK and back close them); back asks before
## quitting; the profile step (RANDOM, a picture, a card, the live preview, the player ID, an
## empty name, back to the guest step and in again); CONFIRM, WELCOME and the lobby without its own
## name prompt. Android back is sent the way the engine delivers it (_back()). Returns the number
## of failed checks.

var _fails := 0
var _at: Node


func run(at: Node) -> int:
	_at = at
	var saved_profile: Dictionary = Game.profile.duplicate(true)
	await _wait_scene("Lobby", 30.0)
	await _intro_tour()
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)       # a fresh install
	get_tree().change_scene_to_file("res://scenes/login.tscn")
	var login := await _wait_scene("Login", 15.0)
	if login:
		await _guest_tour(login)
		await _profile_tour(login)
	Game.profile = saved_profile
	return _fails


func _intro_tour() -> void:
	IntroSting.show_for_test = true
	Loading.hold_for_test = true
	get_tree().change_scene_to_file("res://scenes/loading.tscn")
	var ld := await _wait_scene("Loading", 20.0)
	var layer := ld.get_node_or_null(IntroSting.LAYER_NAME) if ld else null
	var intro := layer.get_child(0) as IntroSting if layer else null
	_check(intro != null, "the boot screen plays the intro sting on top")
	if intro:
		for f: Array in [[0.55, "l01_intro_streak"], [0.97, "l02_intro_impact"], [1.22, "l03_intro_wordmark"],
				[1.8, "l04_intro_title"], [2.22, "l05_intro_outro"]]:
			intro.hold_at(float(f[0]))
			await _settle(0.1)
			await _at.shot(String(f[1]))
		_check(IntroSting.playing(ld) and not ld.get("_leaving"), "the boot screen waits for the sting")
		intro.hold_at(2.3)
		intro.hold_at(-1.0)
		var t := 0.0
		while IntroSting.playing(ld) and t < 3.0:
			await _at.wait(0.1)
			t += 0.1
		_check(not IntroSting.playing(ld), "the sting ends by itself and lets the boot screen go on")
		await _settle(0.3)
		await _at.shot("l06_boot_after_intro")
	IntroSting.show_for_test = false
	Loading.hold_for_test = false


func _guest_tour(login: Node) -> void:
	await _settle(0.8)
	await _at.shot("l07_guest_login")
	var marks: Dictionary = Game.get("_marks")
	_check(marks.has("login ready") and marks.has("ui guest"), "the guest login reports itself and where PLAY AS GUEST is")
	var guest := _find(login, "GuestButton")
	var note := _find(login, "GuestNote") as Label
	var consent := _find(login, "Consent")
	var logo := _find(login, "Logo")
	var ver := _find(login, "Version")
	for c: Control in [guest, note, consent, logo, ver, _find(login, "TermsLink"), _find(login, "PrivacyLink")]:
		_inside(c)
	_tall(guest, 76.0)
	_tall(_find(login, "TermsLink"), 44.0)
	_tall(_find(login, "PrivacyLink"), 44.0)
	_apart(guest, note)
	_apart(note, consent)
	_apart(logo, guest)
	_apart(consent, ver)
	_check(note != null and note.get_line_count() <= note.get_visible_line_count(), "the guest note shows all its lines")
	# The Privacy Notice: a tap on its link; it names the relays, scrolls to its end; OK closes it.
	await _tap(_find(login, "PrivacyLink"))
	await _settle(0.4)
	var modal := login.get("_modal") as Control
	_check(modal != null and modal.name == "Modal", "the Privacy Notice link opens the notice in the game")
	if modal:
		await _at.shot("l08_privacy")
		var all := ""
		for l in modal.find_children("*", "Label", true, false):
			all += (l as Label).text + "\n"
		for url: String in Cloud.BROKERS:
			var host := url.get_slice("://", 1).get_slice("/", 0).get_slice(":", 0)
			_check(all.contains(host), "the notice names the relay %s" % host)
		var scroll := modal.find_child("DocScroll", true, false) as ScrollContainer
		_inside(modal.find_child("ModalOk", true, false) as Control)
		_tall(modal.find_child("ModalOk", true, false) as Control, 56.0)
		if scroll:
			scroll.scroll_vertical = 100000
			await _settle(0.3)
			await _at.shot("l08b_privacy_end")
		await _tap(modal.find_child("ModalOk", true, false) as Control)
		await _settle(0.3)
	_check(login.get("_modal") == null, "OK closes the notice")
	await _tap(_find(login, "TermsLink"))
	await _settle(0.4)
	modal = login.get("_modal") as Control
	_check(modal != null, "the Terms of Use link opens the terms")
	if modal:
		await _at.shot("l09_terms")
		_back()
		await _settle(0.3)
	_check(login.get("_modal") == null, "back closes the terms")
	# Back on the guest login asks before quitting; CANCEL keeps the game.
	_back()
	await _settle(0.4)
	modal = login.get("_modal") as Control
	_check(modal != null and modal.name == "QuitDialog", "back on the guest login asks before quitting")
	if modal:
		await _at.shot("l10_quit")
		for n in ["QuitCancel", "QuitConfirm"]:
			_tall(modal.find_child(n, true, false) as Control, 56.0)
			_inside(modal.find_child(n, true, false) as Control)
		await _tap(modal.find_child("QuitCancel", true, false) as Control)
		await _settle(0.3)
	_check(login.get("_modal") == null, "CANCEL closes the quit dialog")


func _profile_tour(login: Node) -> void:
	await _tap(_find(login, "GuestButton"))
	await _settle(0.6)
	var field := _find(login, "NameField") as LineEdit
	_check(field != null and login.get("_step") == "profile", "PLAY AS GUEST opens the profile setup")
	if field == null:
		return
	var marks: Dictionary = Game.get("_marks")
	_check(marks.has("profile setup") and marks.has("ui name_field") and marks.has("ui confirm"),
		"the profile setup reports itself, the name field and CONFIRM")
	_check(not bool(Game.profile.guest_ok), "nothing is written before CONFIRM")
	_check(Game.clean_name(field.text) == field.text and field.text.length() > 0 and field.max_length == Game.NAME_MAX,
		"the name field offers a valid name (%s), 14 characters at most" % field.text)
	_check(field.get_global_rect().end.y < get_viewport().get_visible_rect().size.y * 0.42,
		"the name field sits in the top part of the screen, above the on-screen keyboard")
	await _at.shot("l11_profile")
	var tiles := []
	for id: String in Game.avatar_ids():
		tiles.append(_find(login, "Avatar_" + id))
	for id: String in Game.BANNERS:
		tiles.append(_find(login, "Banner_" + id))
	var confirm := _find(login, "ConfirmButton")
	var card := _find(login, "NameCard")
	var pid := _find(login, "PlayerId")
	var badge := _find(login, "GuestBadge")
	for c: Control in tiles + [field, _find(login, "NameRandom"), _find(login, "BackButton"), card, pid, confirm,
			_find(login, "NameHint"), badge]:
		_inside(c)
	for c: Control in tiles + [field, _find(login, "NameRandom"), _find(login, "BackButton"), confirm]:
		_tall(c, 56.0)
	for c: Control in tiles + [card, pid, badge]:
		_apart(c, confirm)
	_apart(card, badge)
	_apart(card, _find(login, "Avatar_royal"))
	_check(tiles.size() == Game.avatar_ids().size() + Game.BANNERS.size() and not tiles.has(null),
		"every profile picture and name card can be chosen")
	# RANDOM rolls a new valid name and the preview follows.
	var before := field.text
	await _tap(_find(login, "NameRandom"))
	await _settle(0.2)
	var card_name := login.get("_card_name") as Label
	_check(field.text != before and Game.clean_name(field.text) == field.text, "RANDOM rolls a valid name (%s)" % field.text)
	_check(card_name != null and card_name.text == field.text, "the preview shows the name")
	await _tap(_find(login, "Avatar_royal"))
	await _tap(_find(login, "Banner_hive"))
	await _settle(0.2)
	_check(login.get("_avatar") == "royal" and login.get("_banner") == "hive", "a tap picks a picture and a card")
	var card_art := login.get("_card_art") as TextureRect
	var card_avatar := login.get("_card_avatar") as TextureRect
	_check(card_art != null and card_art.texture == Login.banner_texture("hive") and card_avatar.texture == Login.avatar_texture("royal"),
		"the preview shows the chosen picture and card")
	var t := 0.0
	while Game.cloud and Game.cloud.my_id == "" and t < 20.0:
		await _at.wait(0.2)
		t += 0.2
	await _settle(0.2)
	_check(Game.cloud != null and Game.cloud.my_id != "" and (pid as Label).text == Cloud.friend_code(Game.cloud.my_id),
		"the player ID is made on the phone and shown (%s)" % (pid as Label).text)
	await _at.shot("l12_profile_choices")
	# An empty name is not taken: the hint says what to do.
	field.text = "  !! "
	field.text_changed.emit(field.text)
	await _tap(confirm)
	await _settle(0.4)
	_check(login.get("_step") == "profile" and not bool(Game.profile.guest_ok), "CONFIRM with an empty name does nothing")
	_check((_find(login, "NameHint") as Label).text == Login.NAME_EMPTY, "the hint asks for a name")
	await _at.shot("l13_empty_name")
	# Back returns to the guest login; PLAY AS GUEST comes back to the same choices.
	_back()
	await _settle(0.4)
	_check(login.get("_step") == "guest" and _find(login, "GuestButton").is_visible_in_tree(), "back returns to the guest login")
	await _tap(_find(login, "GuestButton"))
	await _settle(0.5)
	_check(login.get("_step") == "profile" and login.get("_avatar") == "royal", "the choices are kept")
	field.text = "neo wolf 7"
	field.text_changed.emit(field.text)
	await _tap(confirm)
	await _settle(0.7)
	var p := Game.profile
	_check(p.name == "NEO WOLF 7" and p.name_set == true and p.guest_ok == true and p.avatar == "royal" and p.banner == "hive"
		and int(p.created) > 0, "CONFIRM writes the name, the picture, the card and the login, and saves")
	_check(Game.get("_marks").has("profile created"), "the profile is reported created")
	await _at.shot("l14_welcome")
	var lobby := await _wait_scene("Lobby", 30.0)
	await _settle(1.2)
	_check(lobby != null and lobby.get("_modal") == null, "the lobby does not ask for a name again")
	await _at.shot("l15_lobby")


## The first descendant called `node_name` (or null).
func _find(root: Node, node_name: String) -> Control:
	return root.find_child(node_name, true, false) as Control


func _inside(c: Control) -> void:
	if c == null:
		_check(false, "a control to check exists")
		return
	var vr := get_viewport().get_visible_rect().grow(1.0)
	var r := c.get_global_rect()
	_check(vr.encloses(r), "%s is on the screen (%s)" % [c.name, r])


func _tall(c: Control, px: float) -> void:
	if c:
		_check(c.size.y >= px, "%s is at least %.0f px tall (%.0f)" % [c.name, px, c.size.y])


func _apart(a: Control, b: Control) -> void:
	if a and b:
		_check(not a.get_global_rect().grow(-1.0).intersects(b.get_global_rect().grow(-1.0)),
			"%s and %s do not overlap" % [a.name, b.name])


## Android back as the engine delivers it (Window::_propagate_window_notification): the node
## first, then its children by index, re-reading the count.
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
	var w: Vector2 = get_tree().root.get_final_transform() * c.get_global_rect().get_center()
	_at.touch(0, w, true)
	await _at.wait(hold)
	_at.touch(0, w, false)
	await _at.wait(0.12)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	_at.log_line(("ok   " if ok else "FAIL ") + what)
