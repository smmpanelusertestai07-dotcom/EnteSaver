extends Node
## Screenshot tour of the custom room's create page and the friends' rows (made-up players; the
## online service is pointed at a local port nobody listens on and held still):
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_room.gd
## FRIENDS rows (one online with DUEL 1 VS 1, one offline: the same columns), CUSTOM ROOM's ROOM
## page, its GAME page (CLASSIC, then CUSTOM options), and the open room with its rules strip.
## Returns the failed checks.

var _fails := 0


func run(at: Node) -> int:
	OS.set_environment("LW_MQTT_URL", "ws://127.0.0.1:9")
	if DisplayServer.get_name() == "headless":
		get_tree().root.size = Vector2i(1560, 720)
	var saved_profile: Dictionary = Game.profile.duplicate(true)
	await at.wait(1.5)
	var lobby := get_tree().current_scene as Lobby
	var cloud := Game.cloud_service()
	cloud.set_process(false)
	cloud.status = "online"
	var now := int(Time.get_unix_time_from_system())
	var ids := []
	for f: Array in [["NIGHTFOX21", true, 23], ["RIVERSTONE", false, 7], ["A_VERY_LONG_NAME_77", true, 41]]:
		var id := String(f[0]).sha256_text().left(32)
		ids.append(id)
		Game.profile.friends[id] = {"name": String(f[0])}
		cloud.directory[id] = {"name": String(f[0]), "bundle": "shadow", "pk": "", "ts": now - 3600, "v": 3, "avatar": "shadow",
			"banner": "gold_rush", "level": int(f[2]), "signature": ""}
		if bool(f[1]):
			cloud.peers[id] = {"name": String(f[0]), "bundle": "shadow", "pk": "", "seen": Time.get_ticks_msec()}
	lobby.friends.open("friends")
	await at.wait(0.8)
	var rows := []
	for id: String in ids:
		var b := lobby.dialogs.modal.find_child("Player_" + Cloud.friend_code(id), true, false) as Control
		rows.append(b.size.x if b else -1.0)
	_check(rows[0] > 0 and rows[0] == rows[1] and rows[1] == rows[2], "FRIENDS rows: the name column is as wide with and without DUEL 1 VS 1 (%s)" % str(rows))
	await at.shot("r01_friends_rows")
	lobby.friends.open("room")
	await at.wait(0.8)
	var modal := lobby.dialogs.modal
	_check(modal.find_child("RoomPage_room", true, false) != null and modal.find_child("RoomName", true, false) != null
		and modal.find_child("RoomMode_4", true, false) != null, "the create page shows ROOM with the name, password and TEAM MODE")
	await at.shot("r02_room_page")
	await _tap(at, modal.find_child("RoomMode_2", true, false) as Control)
	await _tap(at, lobby.dialogs.modal.find_child("RoomPage_game", true, false) as Control)
	modal = lobby.dialogs.modal
	_check(modal.find_child("RoomPreset_classic", true, false) != null and modal.find_child("Rule_hp", true, false) != null
		and modal.find_child("Rule_zone_no", true, false) != null, "GAME shows the presets, the fields and the YES / NO rows")
	_check((modal.find_child("Rule_rounds", true, false) as Button).text == "FIRST TO 4", "DUO's CLASSIC plays first to 4 as today")
	await at.shot("r03_game_classic")
	await _tap(at, modal.find_child("Rule_hp", true, false) as Control)
	await _tap(at, lobby.dialogs.modal.find_child("Rule_speed", true, false) as Control)
	await _tap(at, lobby.dialogs.modal.find_child("Rule_gun_fixed", true, false) as Control)
	await _tap(at, lobby.dialogs.modal.find_child("Rule_zone_no", true, false) as Control)
	modal = lobby.dialogs.modal
	_check((modal.find_child("Rule_hp", true, false) as Button).text == "150" and modal.find_child("Rule_gun_id", true, false) != null
		and not RoomRules.is_classic(lobby.friends.room_draft.rules, true), "a changed option is CUSTOM (HP 150, ONE GUN, no zone)")
	await at.shot("r04_game_custom")
	await _tap(at, modal.find_child("RoomCreate", true, false) as Control)
	await at.wait(0.6)
	modal = lobby.dialogs.modal
	_check(modal != null and modal.find_child("RoomRules", true, false) != null and int(cloud.room_rules.hp) == 150,
		"the open room shows its rules")
	await at.shot("r05_room_open")
	cloud.close_room()
	lobby.dialogs.close_modal()
	await at.wait(0.4)
	# The right-hand social panel: FRIENDS with the invite "+", the status choice, GROUP CODE's keypad.
	var arrow := lobby.find_child("SocialArrow", true, false) as Button
	_check(arrow != null and arrow.visible, "the lobby shows the social panel's arrow at the right edge")
	await _tap(at, arrow)
	modal = lobby.dialogs.modal
	_check(modal != null and modal.find_child("SocialPanel", true, false) != null and modal.find_child("SocialInvite_" + Cloud.friend_code(ids[0]), true, false) != null
		and not (modal.find_child("SocialInvite_" + Cloud.friend_code(ids[0]), true, false) as Button).disabled
		and (modal.find_child("SocialInvite_" + Cloud.friend_code(ids[1]), true, false) as Button).disabled,
		"the social panel lists friends with the invite + (greyed for one offline)")
	await at.shot("r06_social_panel")
	await _tap(at, modal.find_child("SocialStatus", true, false) as Control)
	_check(LobbySocial.status() == 2 and LobbySocial.invite_answer(2) == "decline" and LobbySocial.invite_answer(0) == "accept",
		"the status steps ONLINE -> BUSY (invites declined at once); JOIN ME ANYTIME accepts")
	Game.settings.team_status = 1
	await _tap(at, lobby.dialogs.modal.find_child("SocialGroupCode", true, false) as Control)
	for k in ["4", "2", "1", "3"]:
		await _tap(at, lobby.dialogs.modal.find_child("CodeKey_" + k, true, false) as Control)
	_check((lobby.dialogs.modal.find_child("CodePadShown", true, false) as Label).text.replace(" ", "") == "4213", "GROUP CODE's keypad shows the digits as a code")
	await at.shot("r07_group_code_pad")
	lobby.dialogs.close_modal()
	# RECENT: a player met in a match who is no friend gets ADD FRIEND, not a greyed "+".
	var stranger := "tour-r-stranger".sha256_text().left(32)
	Game.profile.recent = [{"id": stranger, "name": "DRIFTER"}, {"id": ids[0], "name": "FRIEND ONE"}]
	lobby.social.open("recent")
	await at.wait(0.5)
	modal = lobby.dialogs.modal
	_check(modal != null and modal.find_child("SocialAdd_" + Cloud.friend_code(stranger), true, false) != null
		and modal.find_child("SocialInvite_" + Cloud.friend_code(stranger), true, false) == null
		and modal.find_child("SocialInvite_" + Cloud.friend_code(ids[0]), true, false) != null,
		"RECENT: ADD FRIEND on a stranger, the invite + on a friend")
	await at.shot("r08_social_recent")
	lobby.dialogs.close_modal()
	# In a group already: the keypad says so at once and stays open (it closes only for its own join).
	var me_was := cloud.my_id
	if cloud.my_id == "":
		cloud.my_id = "tour-r-me".sha256_text().left(32)
	cloud.group = {"gid": "d4".repeat(16), "leader": cloud.my_id, "status": "idle", "mode": "lonewolf", "size": 2,
		"members": [{"id": cloud.my_id, "name": "ME", "bundle": "default"}, {"id": ids[0], "name": "FRIEND ONE", "bundle": "default"}]}
	lobby.social.open_pad()
	await at.wait(1.2)
	modal = lobby.dialogs.modal
	var pad_state := modal.find_child("CodePadState", true, false) as Label if modal else null
	_check(pad_state != null and pad_state.text.begins_with("EXIT YOUR GROUP FIRST"), "the keypad stays open in a group and says EXIT YOUR GROUP FIRST")
	await at.shot("r09_code_pad_in_group")
	lobby.dialogs.close_modal()
	cloud.group = {}
	cloud.my_id = me_was
	Game.profile = saved_profile
	return _fails


func _tap(at: Node, c: Control) -> void:
	if c == null:
		_check(false, "a control to tap is missing")
		return
	(c as BaseButton).pressed.emit()
	await at.wait(0.4)


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("[shots_room] FAIL " + what)
	else:
		print("[shots_room] ok   " + what)
