extends Node
## Screenshot tour of the lobby's own windows (made-up players; the online service is pointed at a
## local port nobody listens on and held still, so no public relay is reached):
##   tools/qa/capture.sh <out_dir> 1280x720 script:res://tests/shots_lobby.gd
## The lobby, the FRIENDS page on each tab (friends, requests, players, custom room, no internet,
## and the empty friends list), the chat panel, a confirmation popup, SELECT MODE, the team-size
## box and LONE WOLF with the GROUP bar. Returns the failed checks.

const PEOPLE := [["tour-l-fox", "NIGHTFOX21", "shadow", 23, true, false], ["tour-l-kite", "KITE", "default", 9, true, true],
	["tour-l-ember", "EMBER_7", "default", 41, false, false]]
const STRANGERS := [["tour-l-rook", "ROOKIE99", 3, true], ["tour-l-vex", "VEXA", 15, false]]

var _fails := 0


func run(at: Node) -> int:
	OS.set_environment("LW_MQTT_URL", "ws://127.0.0.1:9")
	if DisplayServer.get_name() == "headless":
		get_tree().root.size = Vector2i(1280, 720)
	var saved_profile: Dictionary = Game.profile.duplicate(true)
	var saved_settings: Dictionary = Game.settings.duplicate(true)
	NetChat.reset_for_test()
	await at.wait(1.5)
	var lobby := get_tree().current_scene as Lobby
	if lobby == null:
		_check(false, "the lobby is up")
		return _fails
	if lobby.dialogs.modal:
		lobby.dialogs.close_modal()
	var cloud := Game.cloud_service()
	cloud.set_process(false)
	cloud.status = "online"
	cloud.relay_rtt = 64
	var now := int(Time.get_unix_time_from_system())
	await at.shot("l01_lobby")
	# FRIENDS with nobody yet: the empty state and its link.
	lobby._open_friends("friends")
	await at.wait(0.6)
	_check(lobby.dialogs.modal != null and lobby.dialogs.modal.find_child("EmptyState", true, false) != null, "no friends: the empty state")
	await at.shot("l02_friends_empty")
	var ids := {}
	for p: Array in PEOPLE:
		var id := String(p[0]).sha256_text().left(32)
		ids[p[1]] = id
		Game.profile.friends[id] = {"name": p[1]}
		cloud.directory[id] = {"name": p[1], "bundle": p[2], "pk": "", "ts": now - 3600 * (1 + PEOPLE.find(p)), "v": 3,
			"avatar": "default", "banner": "", "level": p[3], "signature": "", "career": {}}
		if bool(p[4]):
			cloud.peers[id] = {"name": p[1], "bundle": p[2], "pk": "", "seen": Time.get_ticks_msec()}
			if bool(p[5]):
				cloud.peers[id]["im"] = true
	for p: Array in STRANGERS:
		var id := String(p[0]).sha256_text().left(32)
		cloud.directory[id] = {"name": p[1], "bundle": "default", "pk": "", "ts": now - 600, "v": 3, "avatar": "default",
			"banner": "", "level": p[2], "signature": "", "career": {}}
		if bool(p[3]):
			cloud.peers[id] = {"name": p[1], "bundle": "default", "pk": "", "seen": Time.get_ticks_msec()}
	var asker := "tour-l-asker".sha256_text().left(32)
	cloud.friend_requests[asker] = {"name": "SABRE", "pk": "", "ts": now}
	cloud.peers_changed.emit()
	lobby._open_friends("friends")
	await at.wait(0.8)
	var page := lobby.dialogs.modal
	_check(page != null and page.find_child("Tab_requests", true, false) != null and page.find_child("RequestsLink", true, false) != null
		and page.find_child("Duel_" + Cloud.friend_code(ids.NIGHTFOX21), true, false) != null, "FRIENDS lists the friends and links the requests")
	await at.shot("l03_friends")
	lobby.friends.open("requests")
	await at.wait(0.6)
	_check(lobby.dialogs.modal.find_child("FriendAccept", true, false) != null, "REQUESTS has ACCEPT")
	await at.shot("l04_requests")
	lobby.friends.open("online")
	await at.wait(0.6)
	_check(lobby.dialogs.modal.find_child("OnlineHead", true, false) != null, "PLAYERS lists who is online")
	await at.shot("l05_players")
	lobby.friends.open("room")
	await at.wait(0.6)
	await at.shot("l06_room")
	lobby.friends.open("local")
	await at.wait(0.6)
	await at.shot("l07_no_internet")
	lobby.dialogs.close_modal()
	# The chat panel from the left.
	var fox: String = ids.NIGHTFOX21
	for m: Array in [[now - 90000, false, "GG! THAT LAST ROUND WAS CLOSE"], [now - 560, true, "REMATCH TONIGHT?"],
			[now - 90, false, "SURE, AFTER 9. BRING THE SNIPER"], [now - 30, true, "DEAL. SEE YOU THEN!"]]:
		NetChat.add(fox, int(m[0]), bool(m[1]), String(m[2]))
	NetChat.add(ids.KITE, now - 20, false, "READY?")
	LobbyNet.open(lobby, fox, "NIGHTFOX21", "friends")
	await at.wait(0.8)
	var chat := lobby.dialogs.modal
	_check(chat != null and chat.find_child("ChatWindow", true, false) != null and chat.find_children("ChatMine*", "", true, false).size() == 2
		and chat.find_child("ChatPerson_" + Cloud.friend_code(ids.KITE), true, false) != null, "the chat panel shows the messages and the friends")
	await at.shot("l08_chat")
	# a left camera cutout: the panel's background still starts at the edge, its content clear of it
	UI.margins_for_test = Vector2(90, 0)
	lobby.dialogs.close_modal()
	LobbyNet.open(lobby, fox, "NIGHTFOX21", "friends")
	await at.wait(0.8)
	chat = lobby.dialogs.modal
	var frame := chat.find_child("Frame", true, false) as Control if chat else null
	var tab := chat.find_child("ChatTab_friends", true, false) as Control if chat else null
	var kite := chat.find_child("ChatPerson_" + Cloud.friend_code(ids.KITE), true, false) as Control if chat else null
	_check(frame != null and tab != null and kite != null and is_zero_approx(frame.global_position.x)
		and tab.global_position.x >= 90.0 and kite.global_position.x >= 90.0, "the chat panel's content keeps clear of a left cutout")
	await at.shot("l08b_chat_cutout")
	UI.margins_for_test = Vector2(-1, -1)
	var outside := chat.find_child("ChatOutside", true, false) as Button if chat else null
	if outside:
		outside.pressed.emit()
	await at.wait(0.6)
	_check(lobby.dialogs.modal != null and lobby.dialogs.modal.find_child("Tab_friends", true, false) != null, "a tap beside the chat goes back to FRIENDS")
	lobby.dialogs.close_modal()
	# A confirmation popup and SELECT MODE.
	lobby.dialogs.confirm("REMOVE FRIEND", "Remove KITE from your friends? You can send a new friend request later.", "REMOVE", func() -> void: pass, Callable(), true)
	await at.wait(0.4)
	await at.shot("l09_popup")
	lobby.dialogs.close_modal()
	lobby.dialogs.select_mode()
	await at.wait(0.6)
	await at.shot("l10_select_mode")
	lobby.dialogs.close_modal()
	lobby.dialogs.open_size_box()
	await at.wait(0.4)
	await at.shot("l11_size_box")
	lobby.dialogs.close_size_box()
	# LONE WOLF: the GROUP bar.
	Game.mode = "lonewolf"
	Game.settings.mode = "lonewolf"
	lobby._refresh_mode()
	await at.wait(0.6)
	await at.shot("l12_lobby_lone_wolf")
	Game.profile = saved_profile
	Game.settings = saved_settings
	NetChat.reset_for_test()
	print("SHOTS_LOBBY fails=%d" % _fails)
	return _fails


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("FAIL  " + what)
	else:
		print("ok    " + what)
