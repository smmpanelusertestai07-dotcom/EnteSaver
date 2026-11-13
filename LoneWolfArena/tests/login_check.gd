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
## - the Privacy Notice stays true to scripts/cloud.gd (and scripts/net_rooms.gd's public room
##   card): every relay host, the card and request
##   ages, and the player card still carries what the notice lists (Cloud.card_text, card2_text,
##   card3_text, my_card), chat and voice as they work (NetChat, NetVoice), the direct connection
##   (NetDirect: its STUN servers, the IP address the opponent learns, OFF), PLAY WITHOUT INTERNET
##   (scripts/lan.gd: what a host's beacon tells the local network, nothing leaves it), DELETE MY
##   DATA (Cloud.forget_me). Change the notice (Login.privacy_sections) together with what goes
##   online or on the local network;
## - DELETE MY DATA from the lobby's settings (ACCOUNT): asked twice, a waiting screen that back
##   does not close, the game's memory as a new install's, a notice that the relay could not be
##   reached (only a dead local one is known here), and its OK opens the guest login.
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
	await _check_delete_my_data()
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
	for srv: Array in NetDirect.STUN_SERVERS:
		_check(notice.contains(String(srv[0])), "the Privacy Notice names the STUN server %s" % srv[0])
	_check(notice.contains("%d days after you were last online" % roundi(Cloud.CARD_MAX_AGE_S / 86400.0))
		and notice.contains("dropped after %d days" % roundi(Cloud.REQUEST_MAX_AGE_S / 86400.0)),
		"the Privacy Notice gives the card and request ages of cloud.gd")
	# What the player card carries (Cloud.card_text: id, name, outfit, time; card v2's card2_text adds
	# the picture, banner, level and signature from Cloud.my_card; the card adds the public key) is
	# what the notice lists. A card that carries more needs the notice changed.
	var card_args := {}
	for m: Dictionary in (load("res://scripts/cloud.gd") as Script).get_script_method_list():
		if String(m.name) in ["card_text", "card2_text", "card3_text"]:
			card_args[String(m.name)] = (m.args as Array).size()
	_check(card_args.get("card_text") == 4 and card_args.get("card2_text") == 8 and card_args.get("card3_text") == 9,
		"the player card carries the ID, name, outfit, name card, level, career and time the Privacy Notice lists (%s)" % str(card_args))
	var shown := Cloud.my_card().keys()
	shown.sort()
	_check(shown == ["avatar", "banner", "bundle", "career", "level", "name", "signature"], "the player card shows what the notice lists (%s)" % str(shown))
	_check(Cloud.CAREER_KEYS == ["matches", "wins", "kills", "kd", "hs"], "the career summary is what the notice lists")
	# A PUBLIC room's card (NetRooms.card_json) carries what the notice lists: the room's name, the
	# host's name, ID and public key, the room ID, its mode (size) and rules, the players in it and
	# whether it has a password. A card that carries more needs the notice changed.
	var room_card: Dictionary = JSON.parse_string(NetRooms.card_json({"host": "H", "name": "R", "size": 1, "filled": 1, "total": 2,
		"rules": "X", "pw": false, "code": "123456"}, "id", "pk", 1, Crypto.new().generate_rsa(2048)))
	var room_keys := room_card.keys()
	room_keys.sort()
	_check(room_keys == ["code", "filled", "host", "id", "name", "pk", "pw", "rules", "sig", "size", "t", "total", "ts", "v"],
		"a public room's card carries what the notice lists (%s)" % str(room_keys))
	# The lobby announce: the ID, name, outfit and public key, and in a match only the flag "im".
	var hello := Cloud.new()
	var hi_keys := hello.hello_msg().keys()
	hello.in_session = true
	var hi_match := hello.hello_msg().keys()
	hello.free()
	hi_keys.sort()
	hi_match.sort()
	_check(hi_keys == ["bundle", "id", "name", "pk", "t"] and hi_match == ["bundle", "id", "im", "name", "pk", "t"],
		"the lobby announce carries what the notice lists (%s / %s)" % [str(hi_keys), str(hi_match)])
	for what: String in ["random player ID, name, outfit and public key", "name card (profile picture, banner and signature line) and level",
			"the time you were last online", "whether you are in a match right now (only that, nothing about the match)", "match history", "blocked players", "end-to-end encrypted",
			"career summary (matches, wins, kills, K/D and headshot rate) unless you turn SHOW MY CAREER off",
			"last %d chat messages with each friend" % NetChat.HISTORY_MAX, "only your friend's phone can read it",
			"keeps your last unread message", "never a blocked player", "sent only while you speak", "never stored",
			"no microphone unless you turn MIC on",
			"On unless you turn DIRECT CONNECTION off", "your opponent's game learns your phone's IP address",
			"Turned off, your phone never sends its address", "Apart from the relay and the direct connection above",
			"No account, no e-mail address or phone number, no ads, no analytics", "Uninstall the game, or clear its data",
			"these games never leave the local network", "your name, outfit, player ID and public key", "pairing code",
			"never to know where you are", "DELETE MY DATA (Settings, ACCOUNT) deletes everything the game keeps on this phone",
			"asks the relay to delete your player card", "the last chat message to and from each friend",
			"If you make a custom room PUBLIC, every player online can see its name, your name and player ID, its room ID",
			"whether it has a password (never the password)", "a private room is never listed"]:
		_check(notice.contains(what), "the Privacy Notice says: %s" % what)
	# A host's beacon (Lan.beacon) tells the local network what the notice lists: name, outfit, player
	# ID and public key, plus the protocol, its port and a random nonce. A beacon that says more needs
	# the notice changed.
	var lan := Lan.new()
	var told := lan.beacon().keys()
	lan.free()
	told.sort()
	_check(told == ["bundle", "id", "lw", "name", "nonce", "pk", "port", "t"], "a host's beacon carries what the notice lists (%s)" % str(told))
	var terms := ""
	for sct: Array in Login.terms_sections():
		terms += String(sct[0]) + "\n" + String(sct[1]) + "\n"
	_check(terms.contains("Play fair") and terms.contains("provided as is") and terms.contains("nothing to buy"),
		"the Terms of Use: fair play, as is, free")
	_check(not (notice + terms).contains("http") and not (notice + terms).contains("www."), "the documents carry no web links")
	var probe := Cloud.new()
	_check(probe.has_method("forget_me") and terms.contains("DELETE MY DATA"),
		"DELETE MY DATA is what the notice and the terms say it is (Cloud.forget_me)")
	probe.free()


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


## DELETE MY DATA from the lobby (SETTINGS, ACCOUNT), with an online service that only knows a dead
## local relay: asked twice, then a waiting screen that back does not close; a new install's memory;
## the notice says the relay could not be reached; its OK opens the guest login. Automated runs
## keep the files (Game.autotest): erase_files is checked by the unit tests.
func _check_delete_my_data() -> void:
	var old_lobby := get_tree().current_scene
	var old := Game.cloud_service()
	var t := 0.0
	while old.my_id == "" and t < 60.0:          # (its key is made on a worker thread)
		await _at.wait(0.2)
		t += 0.2
	OS.set_environment("LW_MQTT_URL", "ws://127.0.0.1:9")
	old.free()
	Game.cloud = null
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	Game.profile.merge({"name": "DOOMED", "name_set": true, "guest_ok": true, "xp": 1200}, true)
	Game.settings.vibrate_damage = true
	Game.goto_lobby()
	var lobby: Lobby = null
	t = 0.0
	while lobby == null and t < 40.0:
		await _at.wait(0.1)
		t += 0.1
		var sc := get_tree().current_scene
		if sc is Lobby and sc != old_lobby and sc.is_node_ready():
			lobby = sc
	_check(lobby != null, "a new lobby for DELETE MY DATA")
	if lobby == null:
		return
	t = 0.0
	while Game.cloud.my_id == "" and t < 20.0:
		await _at.wait(0.2)
		t += 0.2
	var id := Game.cloud.my_id
	lobby._open_settings()
	await _frames(3)
	var panel := lobby._find_settings()
	panel._show_tab(5)
	await _frames(2)
	var code := panel.find_child("PlayerIdValue", true, false) as Label
	_check(code != null and id != "" and code.text == Cloud.friend_code(id), "ACCOUNT shows the player ID")
	(panel.find_child("DeleteData", true, false) as Button).pressed.emit()
	await _frames(2)
	(panel.find_child("ConfirmOk", true, false) as Button).pressed.emit()
	await _frames(2)
	var sure := panel.find_child("Confirm", true, false)
	_check(sure != null and _texts(sure).contains(Cloud.friend_code(id)), "the second question names the player ID")
	(sure.find_child("ConfirmOk", true, false) as Button).pressed.emit()
	await _frames(2)
	var erasing := panel.find_child("Erasing", true, false)
	_check(erasing != null and panel.busy, "a waiting screen while the data goes")
	panel.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	lobby.notification(NOTIFICATION_WM_GO_BACK_REQUEST)
	await _frames(2)
	_check(is_instance_valid(panel) and not panel.is_queued_for_deletion() and lobby.find_child("QuitDialog", true, false) == null,
		"back does nothing while the data goes")
	var ok := erasing.find_child("EraseOk", true, false) as Button if erasing else null
	t = 0.0
	while ok and not ok.visible and t < 20.0:
		await _at.wait(0.2)
		t += 0.2
	_check(ok != null and ok.visible, "the deletion ends with a notice (%.1fs)" % t)
	var said := (erasing.find_child("EraseText", true, false) as Label).text if erasing else ""
	_check(said.contains("Everything Wolf Arena kept on this phone is deleted") and said.contains("could not be reached"),
		"the notice says what was deleted, and that the relay could not be reached (%s)" % said)
	_check(not bool(Game.profile.guest_ok) and Game.profile.name == "ROOKIE" and int(Game.profile.xp) == 0
		and Game.cloud.my_id == "" and Game.settings.vibrate_damage == false, "a new install's profile and settings, no player ID")
	if ok:
		ok.pressed.emit()
	var s := await _wait_scene("Login", 15.0)
	_check(s != null and s.scene_file_path == "res://scenes/login.tscn", "OK opens the guest login")
	OS.set_environment("LW_MQTT_URL", "")


## Every label text under `root`, joined with "|".
func _texts(root: Node) -> String:
	var out := PackedStringArray()
	for l in root.find_children("*", "Label", true, false):
		out.append((l as Label).text)
	return "|".join(out)


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
