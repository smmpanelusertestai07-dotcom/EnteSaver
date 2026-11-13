extends Node
## Screenshot tour of the lobby's own windows (made-up players; the online service is pointed at a
## local port nobody listens on and held still, so no public relay is reached):
##   tools/qa/capture.sh <out_dir> 1280x720 script:res://tests/shots_lobby.gd
## The lobby, the FRIENDS page on each tab (friends, requests, players, custom room, no internet,
## and the empty friends list), the chat panel, a confirmation popup, SELECT MODE, the team-size
## box (the TEAM panel) and LONE WOLF: a solo's TEAM panel, a group of 4 with the TEAM bar, the hero
## left and the members to its right, the TEAM panel from the left (also with a left camera
## cutout) and a member's read-only TEAM panel. Returns the failed checks.

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
	# The REQUESTS tab's count follows a new request and one answered.
	var tab_req := lobby.dialogs.modal.find_child("Tab_requests", true, false) as Button
	var asker2 := "tour-l-asker2".sha256_text().left(32)
	cloud.friend_requests[asker2] = {"name": "ORBIT", "pk": "", "ts": now}
	await at.wait(0.6)
	_check(tab_req != null and tab_req.text == "REQUESTS  2", "a new request counts on the REQUESTS tab (%s)" % (tab_req.text if tab_req else "none"))
	cloud.friend_requests.erase(asker2)
	cloud.friend_requests.erase(asker)
	await at.wait(0.6)
	_check(tab_req != null and tab_req.text == "REQUESTS", "answered requests leave the REQUESTS tab's count (%s)" % (tab_req.text if tab_req else "none"))
	cloud.friend_requests[asker] = {"name": "SABRE", "pk": "", "ts": now}
	lobby.friends.open("online")
	# (opening a tab asks the cloud to connect: with no relay that can turn the tour's held "online"
	# into CONNECTING before the list is filled, depending on when the refused connection was seen;
	# the tour holds it online, the list follows within its 0.4 s refresh)
	cloud.status = "online"
	await at.wait(0.6)
	_check(lobby.dialogs.modal.find_child("OnlineHead", true, false) != null, "PLAYERS lists who is online (status %s)" % cloud.status)
	await at.shot("l05_players")
	lobby.friends.open("room")
	await at.wait(0.6)
	await at.shot("l06_room")
	# A RUNNING room (SQUAD, this phone hosts): the ID and password, the places, CLOSE ROOM and START,
	# all inside the page's height.
	var me_id := cloud.my_id if cloud.my_id != "" else "tour-l-me".sha256_text().left(32)
	var my_was := cloud.my_id
	cloud.my_id = me_id
	cloud.room_code = "482913"
	cloud.room_pin = "5521"
	cloud._grp = {"gid": "tour"}
	var mem := [{"id": me_id, "name": String(Game.profile.name), "bundle": "default", "team": 0, "slot": 0},
		{"id": ids.NIGHTFOX21, "name": "NIGHTFOX21", "bundle": "shadow", "team": 0, "slot": 1},
		{"id": ids.KITE, "name": "KITE", "bundle": "default", "team": 1, "slot": 4},
		{"id": ids.EMBER_7, "name": "EMBER_7", "bundle": "default", "team": 1, "slot": 5}]
	cloud.group = {"room": "482913", "size": 4, "leader": me_id, "members": mem, "status": "idle"}
	lobby.friends.open("room")
	cloud.status = "online"
	await at.wait(0.6)
	var rstart := lobby.dialogs.modal.find_child("RoomStart", true, false) as Control
	var rhead := lobby.dialogs.modal.find_child("RoomHead", true, false) as Control
	var vs_r := lobby.get_viewport().get_visible_rect().size
	_check(rstart != null and rhead != null and rstart.get_global_rect().end.y <= vs_r.y and rhead.global_position.y >= 60.0
		and rstart.get_global_rect().end.x <= vs_r.x, "a running room's places and START fit the page (START ends at %.0f of %.0f)" % [
		rstart.get_global_rect().end.y if rstart else -1.0, vs_r.y])
	await at.shot("l06b_room_running")
	cloud.group = {}
	cloud._grp = {}
	cloud.room_code = ""
	cloud.room_pin = ""
	cloud.my_id = my_was
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
	# (round 8) the quick phrases behind the square button left of SEND, as a list above it
	var qb := chat.find_child("ChatQuickButton", true, false) as Button if chat else null
	if qb:
		qb.pressed.emit()
		await at.wait(0.3)
		_check(lobby.ui.find_child("ChatQuickList", true, false) != null and lobby.ui.find_child("Quick_0", true, false) != null,
			"the quick button opens the quick phrases as a list")
		await at.shot("l08b_chat_quick")
		qb.pressed.emit()
		await at.wait(0.2)
	_check(qb != null and lobby.ui.find_child("ChatQuickList", true, false) == null, "the quick button closes its list again")
	# The friends column follows another friend's new message and who is online.
	var kite_row := chat.find_child("ChatPerson_" + Cloud.friend_code(ids.KITE), true, false) if chat else null
	var kite_n := int(kite_row.get_meta("unread", -1)) if kite_row else -1
	NetChat.add(ids.KITE, now - 5, false, "STILL THERE?")
	Game.cloud_service().friend_chat_changed.emit(ids.KITE)
	await at.wait(0.1)
	kite_row = chat.find_child("ChatPerson_" + Cloud.friend_code(ids.KITE), true, false) if chat else null
	_check(kite_row != null and int(kite_row.get_meta("unread", -1)) == kite_n + 1,
		"the chat's friends column counts another friend's new message (%d -> %d)" % [kite_n, int(kite_row.get_meta("unread", -1)) if kite_row else -1])
	var kite_on := bool(kite_row.get_meta("online", false)) if kite_row else false
	var peers_was: Dictionary = Game.cloud_service().peers.duplicate()
	if kite_on:
		Game.cloud_service().peers.erase(ids.KITE)
	else:
		Game.cloud_service().peers[ids.KITE] = {"name": "KITE", "bundle": "", "pk": "", "seen": Time.get_ticks_msec(), "im": false}
	Game.cloud_service().peers_changed.emit()
	await at.wait(0.1)
	kite_row = chat.find_child("ChatPerson_" + Cloud.friend_code(ids.KITE), true, false) if chat else null
	_check(kite_row != null and bool(kite_row.get_meta("online", kite_on)) != kite_on, "the chat's friends column follows who is online")
	Game.cloud_service().peers = peers_was
	Game.cloud_service().peers_changed.emit()
	# Typing: the panel and its header stay put, only the input row (and the quick phrases) rise
	# above the keyboard; the dim behind the panel covers the whole lobby so nothing under it is
	# pressed while the chat is open.
	var cframe := chat.find_child("Frame", true, false) as Control if chat else null
	var cclose := chat.find_child("Close", true, false) as Control if chat else null
	var cfield := chat.find_child("ChatField", true, false) as LineEdit if chat else null
	var cout := chat.find_child("ChatOutside", true, false) as Control if chat else null
	if cframe and cclose and cfield and cout:
		# (the tour opened FRIENDS just before: the panel is exactly the screen's height, the field on it)
		var vs0 := lobby.get_viewport().get_visible_rect().size
		_check(absf(cframe.size.y - vs0.y) < 1.0 and Rect2(Vector2.ZERO, vs0).encloses(cfield.get_global_rect()),
			"the chat panel is the screen's height with its field on screen (panel %.0f of %.0f, field %s)" % [
			cframe.size.y, vs0.y, str(cfield.get_global_rect())])
		var fy := cframe.global_position.y
		var xy := cclose.global_position.y
		var ly := cfield.global_position.y
		lobby.friends._lift_for_keyboard(cfield, true)
		await at.wait(0.3)
		var vs := lobby.get_viewport().get_visible_rect().size
		_check(is_equal_approx(cframe.global_position.y, fy) and is_equal_approx(cclose.global_position.y, xy) and absf(cframe.size.y - vs.y) < 1.0
			and cfield.global_position.y < ly - 100.0 and cfield.get_global_rect().end.y <= vs.y * 0.6,
			"typing in the chat lifts only the input row (field %.0f -> %.0f), the panel stays" % [ly, cfield.global_position.y])
		_check(cout.get_global_rect().has_point(Vector2(5, vs.y - 5)) and cout.get_global_rect().has_point(Vector2(vs.x - 5, 5)),
			"the chat's outside covers the whole lobby")
		await at.shot("l08c_chat_typing")
		lobby.friends._lift_for_keyboard(cfield, false)
		await at.wait(0.2)
		_check(absf(cfield.global_position.y - ly) < 1.0, "the input row comes back down after typing")
	else:
		_check(false, "the chat panel has its Frame, Close, field and outside")
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
		and absf(frame.size.y - lobby.get_viewport().get_visible_rect().size.y) < 1.0 and tab.global_position.x >= 90.0 and kite.global_position.x >= 90.0, "the chat panel's content keeps clear of a left cutout")
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
	_check_mode_page(lobby)
	# a real tap on the X's centre closes the page (the body reaches up beside it)
	var mclose := lobby.dialogs.modal.find_child("Close", true, false) as Control if lobby.dialogs.modal else null
	var has_x := mclose != null
	if has_x:
		var at_x: Vector2 = lobby.get_tree().root.get_final_transform() * mclose.get_global_rect().get_center()
		at.touch(0, at_x, true)
		await at.wait(0.08)
		at.touch(0, at_x, false)
		await at.wait(0.3)
	_check(has_x and lobby.dialogs.modal == null, "a tap on the mode page's X closes it")
	# With a left camera cutout the page keeps its cards and buttons clear of it.
	UI.margins_for_test = Vector2(90, 40)
	lobby.dialogs.close_modal()
	lobby.dialogs.select_mode()
	await at.wait(0.6)
	var cards := lobby.dialogs.modal.find_child("ModeCards", true, false) as Control if lobby.dialogs.modal else null
	_check(cards != null and cards.global_position.x >= 90.0, "the mode page keeps clear of a left cutout")
	_check_mode_page(lobby)
	await at.shot("l10b_select_mode_cutout")
	UI.margins_for_test = Vector2(-1, -1)
	# HOW TO PLAY on its bottom row: a page whose X comes back to the mode page.
	var how := lobby.dialogs.modal.find_child("ModeWay_help", true, false) as Button if lobby.dialogs.modal else null
	if how:
		how.pressed.emit()
	await at.wait(0.4)
	_check(lobby.dialogs.modal != null and lobby.dialogs.modal.find_child("HowToScroll", true, false) != null, "HOW TO PLAY opens from the mode page")
	await at.shot("l10c_mode_how_to_play")
	lobby.dialogs.back()
	await at.wait(0.3)
	_check(lobby.dialogs.modal != null and lobby.dialogs.modal.find_child("Mode_lonewolf", true, false) != null, "HOW TO PLAY's X goes back to the mode page")
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
	await _team_screens(at, lobby, cloud)
	Game.profile = saved_profile
	Game.settings = saved_settings
	NetChat.reset_for_test()
	print("SHOTS_LOBBY fails=%d" % _fails)
	return _fails


## LONE WOLF's team screens (made-up group; Cloud held still).
func _team_screens(at: Node, lobby: Lobby, cloud: Cloud) -> void:
	var me_id := cloud.my_id if cloud.my_id != "" else "tour-l-me".sha256_text().left(32)
	var my_was := cloud.my_id
	cloud.my_id = me_id
	if cloud.my_code == "":
		cloud.my_code = "4213579086"
	Game.team_size = 4
	lobby._refresh_mode()
	lobby.dialogs.open_size_box()
	await at.wait(0.5)
	var box := lobby.dialogs.size_box
	_check(box != null and box.find_child("GroupCodeRow", true, false) != null and box.find_child("TeamFillTick", true, false) != null
		and box.find_child("SizeTile_4", true, false) != null, "a solo's TEAM panel: code, ticks, tiles")
	await at.shot("l13_team_panel_solo")
	lobby.dialogs.close_size_box()
	var ids := ["tour-l-fox", "tour-l-kite", "tour-l-ember"].map(func(x: String) -> String: return x.sha256_text().left(32))
	var mem := [{"id": me_id, "name": String(Game.profile.name), "bundle": "default"},
		{"id": ids[0], "name": "NIGHTFOX21", "bundle": "shadow"}, {"id": ids[1], "name": "KITE", "bundle": "default"},
		{"id": ids[2], "name": "EMBER_7", "bundle": "default"}]
	var key := Crypto.new().generate_random_bytes(32)
	cloud._grp = {"gid": "c3".repeat(16), "aes": key, "mac": key, "seq": 0, "their": {}, "seen": {}, "invited": {}, "beat_t": 3.0,
		"join_t": 0.0, "leader_ms": Time.get_ticks_msec(), "joining": false, "manual": false}
	NetGroup.arrange(mem, 4, false)
	cloud.group = {"gid": "c3".repeat(16), "leader": me_id, "status": "idle", "mode": "lonewolf", "size": 4, "members": mem}
	cloud.group_changed.emit()
	await at.wait(1.4)
	var bar := lobby.find_child("TeamBar", true, false) as Control
	_check(bar != null and bar.is_visible_in_tree() and lobby.find_child("PodiumInvite", true, false) == null, "a group shows the TEAM bar, no + plate")
	await at.shot("l14_group_lobby")
	lobby.team.open_panel()
	await at.wait(1.0)
	var panel := lobby.dialogs.modal.find_child("TeamPanel", true, false) as Control if lobby.dialogs.modal else null
	var vs := lobby.get_viewport().get_visible_rect()
	var exit := panel.find_child("GroupDisband", true, false) as Control if panel else null
	_check(panel != null and exit != null and vs.encloses(exit.get_global_rect().grow(-0.5)), "the TEAM panel of 4 fits the screen (%s in %s)"
		% [str(exit.get_global_rect()) if exit else "no DISBAND", str(vs)])
	await at.shot("l14b_team_panel")
	lobby.dialogs.close_modal()
	UI.margins_for_test = Vector2(90, 0)
	lobby.team.open_panel()
	await at.wait(1.0)
	panel = lobby.dialogs.modal.find_child("TeamPanel", true, false) as Control if lobby.dialogs.modal else null
	var head := panel.find_child("GroupHead", true, false) as Control if panel else null
	_check(head != null and head.global_position.x >= 90.0, "the TEAM panel's content keeps clear of a left cutout")
	await at.shot("l14c_team_panel_cutout")
	lobby.dialogs.close_modal()
	await at.wait(0.3)
	await at.shot("l14d_group_lobby_cutout")
	UI.margins_for_test = Vector2(-1, -1)
	# a member's view: the mode card's TEAM panel shows the leader's choice
	mem.push_front(mem.pop_at(1))
	NetGroup.arrange(mem, 2, false)
	cloud.group = {"gid": "c3".repeat(16), "leader": ids[0], "status": "idle", "mode": "lonewolf", "size": 2, "members": mem,
		"code": "4213579086", "code_join": true}
	cloud.group_changed.emit()
	await at.wait(0.8)
	lobby.dialogs.open_size_box()
	await at.wait(0.5)
	await at.shot("l15_member_team_panel")
	lobby.dialogs.close_size_box()
	cloud.group = {}
	cloud._grp = {}
	cloud.group_changed.emit()
	cloud.my_id = my_was
	await at.wait(0.6)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("FAIL  " + what)
	else:
		print("ok    " + what)


## SELECT MODE as a page: the MODES tab, both cards side by side filling the page between the tab bar
## and the bottom row, inside the screen, the picked card framed; the bottom row's three ways.
func _check_mode_page(lobby: Lobby) -> void:
	var page := lobby.dialogs.modal
	var vs := lobby.get_viewport().get_visible_rect().size
	var tab := page.find_child("ModeTab", true, false) as Label if page else null
	var a := page.find_child("Mode_training", true, false) as Control if page else null
	var b := page.find_child("Mode_lonewolf", true, false) as Control if page else null
	var ways := page.find_child("ModeWays", true, false) as Control if page else null
	_check(page != null and page.has_meta("page") and tab != null and tab.text == "MODES", "SELECT MODE is a page with the MODES tab")
	if a == null or b == null or ways == null:
		_check(false, "the mode page has both cards and the bottom row")
		return
	var ra := a.get_global_rect()
	var rb := b.get_global_rect()
	_check(absf(ra.position.y - rb.position.y) < 1.0 and ra.end.x < rb.position.x and ra.size.y >= 300.0 and rb.end.x <= vs.x
		and ra.end.y < ways.get_global_rect().position.y and ways.get_global_rect().end.y <= vs.y,
		"the mode cards stand side by side above the bottom row, on the screen (%s %s)" % [str(ra), str(rb)])
	for k: String in ["room", "local", "help"]:
		var w := ways.find_child("ModeWay_" + k, true, false) as Button
		_check(w != null and w.size.y >= UI.TOUCH_MIN and w.get_global_rect().end.x <= vs.x, "the bottom row has %s" % k)
	var ta := a.find_child("ModeTitle", true, false) as Control
	var tb := b.find_child("ModeTitle", true, false) as Control
	_check(ta != null and tb != null and absf(ta.global_position.y - tb.global_position.y) < 1.0, "both cards' names line up")
