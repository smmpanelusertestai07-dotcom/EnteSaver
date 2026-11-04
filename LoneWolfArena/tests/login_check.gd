extends Node
## Guest login checks, headless (tools/qa/run_checks.sh "login"):
##   godot --headless --path . -- --autotest=script:res://tests/login_check.gd
## - Game.goto_login(): the guest login for a new player, the lobby once profile.guest_ok is set,
##   and always the lobby in automated runs;
## - CONFIRM writes the cleaned name, name_set, guest_ok, the picture and the card and saves
##   ("created" stamped); an empty name writes nothing; WELCOME then opens the lobby, whose own
##   name prompt stays shut; Login.create_profile keeps the current values for empty or unknown
##   ones;
## - every name card in Game.BANNERS and every picture in Game.avatar_ids() has its art, and every
##   banner picture in assets/ui/banners/ can be chosen;
## - Cloud.prepare_identity makes (then reloads) the player ID without going online;
## - the intro sting: automated runs skip it, a tap before SKIP_AFTER is ignored and one after it
##   skips, it ends by itself, and IntroSting.playing() follows it;
## - the Privacy Notice stays true to scripts/cloud.gd: every relay host, the card and request
##   ages, and the player card still carries what the notice lists (Cloud.card_text). Change the
##   notice (Login.privacy_sections) together with what goes online.
## Returns the number of failed checks.

var _fails := 0
var _at: Node


func run(at: Node) -> int:
	_at = at
	var saved: Dictionary = Game.profile.duplicate(true)
	_check_texts()
	_check_art()
	_check_create_profile()
	await _check_routing()
	await _check_confirm()
	await _check_identity()
	await _check_intro()
	Game.profile = saved
	_at.log_line("login checks: %d failed" % _fails)
	return _fails


func _check_texts() -> void:
	var notice := ""
	for sct: Array in Login.privacy_sections():
		notice += String(sct[0]) + "\n" + String(sct[1]) + "\n"
	for url: String in Cloud.BROKERS:
		var host := url.get_slice("://", 1).get_slice("/", 0).get_slice(":", 0)
		_check(notice.contains(host), "the Privacy Notice names the relay %s" % host)
	_check(notice.contains("%d days after you were last online" % roundi(Cloud.CARD_MAX_AGE_S / 86400.0))
		and notice.contains("dropped after %d days" % roundi(Cloud.REQUEST_MAX_AGE_S / 86400.0)),
		"the Privacy Notice gives the card and request ages of cloud.gd")
	# What the player card carries (Cloud.card_text: id, name, outfit, time; the card adds the
	# public key) is what the notice lists. A card that carries more needs the notice changed.
	var card_args := -1
	for m: Dictionary in (load("res://scripts/cloud.gd") as Script).get_script_method_list():
		if String(m.name) == "card_text":
			card_args = (m.args as Array).size()
	_check(card_args == 4, "the player card carries the ID, name, outfit and time the Privacy Notice lists (card_text has %d fields)"
		% card_args)
	for what: String in ["random player ID, name, outfit and public key", "the time you were last online", "end-to-end encrypted",
			"No account, no e-mail address or phone number, no ads, no analytics", "Uninstall the game, or clear its data"]:
		_check(notice.contains(what), "the Privacy Notice says: %s" % what)
	var terms := ""
	for sct: Array in Login.terms_sections():
		terms += String(sct[0]) + "\n" + String(sct[1]) + "\n"
	_check(terms.contains("Play fair") and terms.contains("provided as is") and terms.contains("nothing to buy"),
		"the Terms of Use: fair play, as is, free")
	_check(not (notice + terms).contains("http") and not (notice + terms).contains("www."), "the documents carry no web links")


func _check_art() -> void:
	for id: String in Game.BANNERS:
		_check(Login.banner_texture(id) != null, "the name card %s has its art" % id)
	_check(Login.banner_texture("nope") == null, "an unknown name card has no art")
	var files := 0
	for f in ResourceLoader.list_directory("res://assets/ui/banners/"):
		if f.ends_with(".png"):
			files += 1
	_check(files > 0 and files == Game.BANNERS.size(), "every banner picture can be chosen (%d files, %d cards)" % [files, Game.BANNERS.size()])
	for id: String in Game.avatar_ids():
		_check(Login.avatar_texture(id) != null, "the profile picture %s has its art" % id)


func _check_create_profile() -> void:
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game.profile.name = "OLD NAME"
	Login.create_profile("  ?! ", "dragon", "gold")
	var p := Game.profile
	_check(p.name == "OLD NAME" and p.avatar == "emblem" and p.banner == "default" and p.name_set == true and p.guest_ok == true
		and int(p.created) > 0, "create_profile keeps the name, picture and card for empty or unknown ones, and saves")
	Login.create_profile("x".repeat(30), "royal", "hive")
	_check(p.name == "X".repeat(Game.NAME_MAX) and p.avatar == "royal" and p.banner == "hive", "create_profile cleans the name to 14 characters")


## goto_login with the real routing (Game.autotest cleared only around the call: it saves nothing).
func _check_routing() -> void:
	var auto := Game.autotest
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game.autotest = ""
	Game.goto_login()
	Game.autotest = auto
	var s := await _wait_scene("Login", 15.0)
	_check(s != null and s.scene_file_path == "res://scenes/login.tscn", "goto_login: a new player gets the guest login")
	# (a player who passed it has a name: the lobby's own first-start prompt stays shut)
	Game.profile.guest_ok = true
	Game.profile.name_set = true
	Game.autotest = ""
	Game.goto_login()
	Game.autotest = auto
	s = await _wait_scene("Lobby", 40.0)
	_check(s != null, "goto_login: a player who passed the guest login goes straight to the lobby")
	await _frames(4)
	Game.profile.guest_ok = false
	Game.goto_login()
	await _frames(4)
	s = await _wait_scene("Lobby", 40.0)
	await _frames(4)
	_check(s != null and get_tree().current_scene.name == "Lobby", "goto_login: automated runs always get the lobby")


func _check_confirm() -> void:
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	get_tree().change_scene_to_file("res://scenes/login.tscn")
	var login := await _wait_scene("Login", 15.0)
	if login == null:
		return
	await _frames(4)
	var marks: Dictionary = Game.get("_marks")
	_check(marks.has("login ready") and marks.has("ui guest"), "the guest login reports itself and where PLAY AS GUEST is")
	(login.find_child("GuestButton", true, false) as Button).pressed.emit()
	await _frames(4)
	_check(login.get("_step") == "profile" and marks.has("profile setup") and marks.has("ui name_field") and marks.has("ui confirm"),
		"PLAY AS GUEST opens the profile setup, which reports the name field and CONFIRM")
	var field := login.find_child("NameField", true, false) as LineEdit
	var confirm := login.find_child("ConfirmButton", true, false) as Button
	_check(field != null and Game.clean_name(field.text) == field.text and field.text != "" and field.max_length == Game.NAME_MAX,
		"the name field offers a valid name")
	field.text = " ?! "
	confirm.pressed.emit()
	await _frames(2)
	_check(login.get("_step") == "profile" and not bool(Game.profile.guest_ok) and not bool(Game.profile.name_set),
		"CONFIRM with an empty name writes nothing")
	(login.find_child("Avatar_shadow", true, false) as Button).pressed.emit()
	(login.find_child("Banner_scope", true, false) as Button).pressed.emit()
	field.text = "  neo wolf-7 "
	confirm.pressed.emit()
	var p := Game.profile
	_check(p.name == "NEO WOLF-7" and p.name_set == true and p.guest_ok == true and p.avatar == "shadow" and p.banner == "scope"
		and int(p.created) > 0, "CONFIRM writes the name, name_set, guest_ok, the picture and the card, and saves")
	_check(marks.has("profile created") and login.get("_step") == "welcome", "CONFIRM reports the profile and shows WELCOME")
	var lobby := await _wait_scene("Lobby", 40.0)
	await _frames(10)
	_check(lobby != null and lobby.get("_modal") == null, "WELCOME opens the lobby, which does not ask for a name again")


func _check_identity() -> void:
	var role := OS.get_environment("LW_LAN_ROLE")
	OS.set_environment("LW_LAN_ROLE", "login_check")      # a key file of its own
	var path := "user://net_identity_login_check.key"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var c := Cloud.new()
	add_child(c)
	c.prepare_identity()
	var t := 0.0
	while c.my_id == "" and t < 60.0:
		await _at.wait(0.1)
		t += 0.1
	_check(Game.is_player_id(c.my_id), "prepare_identity makes the player ID on the phone")
	_check(c.get("_ws") == null and not (c.status in ["connecting", "online"]), "prepare_identity does not go online")
	var again := Cloud.new()
	add_child(again)
	again.prepare_identity()
	_check(again.my_id == c.my_id and c.my_id != "", "the next start loads the same player ID")
	c.queue_free()
	again.queue_free()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	OS.set_environment("LW_LAN_ROLE", role)


func _check_intro() -> void:
	var host := Control.new()
	add_child(host)
	_check(IntroSting.play_over(host) == null and not IntroSting.playing(host), "automated runs skip the intro sting")
	IntroSting.show_for_test = true
	var s := IntroSting.play_over(host)
	IntroSting.show_for_test = false
	_check(s != null and IntroSting.playing(host), "the intro sting plays over its host")
	if s == null:
		return
	await _frames(2)
	s.hold_at(0.2)
	_check(not s.skip(), "a tap in the first 0.4 s does not skip the sting")
	s.hold_at(0.6)
	s.hold_at(-1.0)
	var w: Vector2 = get_tree().root.get_final_transform() * Vector2(400, 300)
	_at.touch(0, w, true)
	_at.touch(0, w, false)
	var t := 0.0
	while IntroSting.playing(host) and t < 2.0:
		await _frames(1)
		t += get_process_delta_time()
	_check(not IntroSting.playing(host) and (not is_instance_valid(s) or s.done), "a tap after 0.4 s skips the sting (gone in %.2fs)" % t)
	var host2 := Control.new()
	add_child(host2)
	IntroSting.show_for_test = true
	var s2 := IntroSting.play_over(host2)
	IntroSting.show_for_test = false
	var finished := [false]
	if s2:
		s2.finished.connect(func() -> void: finished[0] = true)
	var start := Time.get_ticks_msec()
	while IntroSting.playing(host2) and Time.get_ticks_msec() - start < 5000:
		await _frames(1)
	var took := (Time.get_ticks_msec() - start) / 1000.0
	_check(bool(finished[0]) and not IntroSting.playing(host2) and took >= IntroSting.LENGTH - 0.1 and took < IntroSting.LENGTH + 1.5,
		"the sting ends by itself after its %.1fs (%.2fs)" % [IntroSting.LENGTH, took])
	host.queue_free()
	host2.queue_free()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait_scene(scene_name: String, timeout: float) -> Node:
	var t := 0.0
	while t < timeout:
		var s := get_tree().current_scene
		if s and s.name == scene_name and s.is_node_ready():
			return s
		await _at.wait(0.1)
		t += 0.1
	_check(false, "scene %s within %.0fs" % [scene_name, timeout])
	return null


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
	_at.log_line(("ok   " if ok else "FAIL ") + what)
