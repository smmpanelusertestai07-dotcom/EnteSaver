extends Node
## Screenshot tour of the online extras (made-up players; the online service is pointed at a
## local port nobody listens on and held still, so no public relay is reached):
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_net.gd
## The lobby's ping chip, a friend's chat window, a player card with its CAREER block, a friend's
## message as a notice with the unread badge, the settings' ONLINE tab (top and end) and SOUND
## tab, then a match HUD with the online layer (ping under the gear, CHAT / MUTE /
## TALK / SOUND, the feed under the score bar; the ping of the direct path with its DIRECT tag) and
## its chat panel. Returns the failed checks.

const FRIEND := "tour-chat-friend"

var _fails := 0


func run(at: Node) -> int:
	OS.set_environment("LW_MQTT_URL", "ws://127.0.0.1:9")
	if DisplayServer.get_name() == "headless":
		get_tree().root.size = Vector2i(1560, 720)
	var saved_profile: Dictionary = Game.profile.duplicate(true)
	var saved_settings: Dictionary = Game.settings.duplicate(true)
	NetChat.reset_for_test()
	await at.wait(1.5)
	var lobby := get_tree().current_scene as Lobby
	var cloud := Game.cloud_service()
	cloud.set_process(false)                 # held still: what it shows is set here
	cloud.status = "online"
	cloud.relay_rtt = 87
	var id := FRIEND.sha256_text().left(32)
	var now := int(Time.get_unix_time_from_system())
	Game.profile.friends[id] = {"name": "NIGHTFOX21"}
	cloud.peers[id] = {"name": "NIGHTFOX21", "bundle": "shadow", "pk": "", "seen": Time.get_ticks_msec()}
	cloud.directory[id] = {"name": "NIGHTFOX21", "bundle": "shadow", "pk": "", "ts": now - 40, "v": 3, "avatar": "shadow",
		"banner": "gold_rush", "level": 23, "signature": "DUEL ME AFTER 9 PM",
		"career": {"matches": 148, "wins": 91, "kills": 412, "kd": 236, "hs": 31}}
	await at.wait(1.0)
	_check(lobby.find_child("PingChip", true, false) != null, "the lobby shows the ping chip")
	await at.shot("n01_lobby_ping")
	# Voice: the [mic | speaker] pill under the character, and its MIC MODE popup.
	var pill := lobby.find_child("VoicePill", true, false) as VoiceButtons
	_check(pill != null and pill.visible, "the lobby shows the voice pill under the character")
	if pill:
		pill.popup = VoiceButtons.open_popup(pill.get_parent() as Control, "mic", pill.global_position + Vector2(VoiceButtons.PILL.x * 0.5, -10.0), false)
		await at.wait(0.3)
		_check(lobby.find_child("MicModeBox", true, false) != null and lobby.find_child("PushToTalk", true, false) != null
			and lobby.find_child("Mic_GROUP", true, false) != null, "MIC MODE: OFF / ALL / GROUP and PUSH TO TALK")
		await at.shot("n01b_lobby_mic_mode")
		pill.popup.queue_free()
		await at.wait(0.2)
	for m: Array in [[now - 600, false, "GG! THAT LAST ROUND WAS CLOSE"], [now - 560, true, "REMATCH TONIGHT?"],
			[now - 90, false, "SURE, AFTER 9. BRING THE SNIPER"], [now - 30, true, "DEAL. SEE YOU THEN!"]]:
		NetChat.add(id, int(m[0]), bool(m[1]), String(m[2]))
	LobbyNet.open(lobby, id, "NIGHTFOX21", "friends")
	await at.wait(0.8)
	_check(lobby.dialogs.modal != null and lobby.dialogs.modal.find_child("ChatField", true, false) != null
		and lobby.dialogs.modal.find_children("ChatMine*", "", true, false).size() == 2, "the chat window shows the messages and a text field")
	await at.shot("n02_friend_chat")
	lobby.profile_ui.open_player(id, "friends")
	await at.wait(0.8)
	_check(lobby.dialogs.modal.find_child("PlayerCareer", true, false) != null and lobby.dialogs.modal.find_child("FriendChat", true, false) != null,
		"a friend's card shows their CAREER and a CHAT button")
	await at.shot("n03_player_card")
	lobby.dialogs.close_modal()
	# A friend's message while the lobby is up: a notice at the top and the unread badge on
	# ONLINE 1 VS 1; a tap on the notice opens that chat.
	NetChat.add(id, now - 5, false, "ARE YOU ONLINE? I WANT A REMATCH ON CARGO CAGE TONIGHT")
	cloud.friend_chat_changed.emit(id)
	await at.wait(0.6)
	var toast := lobby.find_child("LobbyToast", true, false) as Button
	var badge := lobby.ui.find_child("UnreadBadge", true, false) as Label
	_check(toast != null and badge != null and badge.visible and badge.text == "1", "a friend's message shows a notice and the unread badge")
	await at.shot("n03b_friend_notice")
	if toast:
		toast.pressed.emit()
	await at.wait(0.6)
	_check(lobby.dialogs.modal != null and lobby.dialogs.modal.find_child("ChatWindow", true, false) != null, "a tap on the notice opens that chat")
	lobby.dialogs.close_modal()
	Game.settings.friend_chat = false
	NetChat.add(id, now - 2, false, "STILL THERE?")
	cloud.friend_chat_changed.emit(id)
	await at.wait(0.3)
	_check(lobby.find_child("LobbyToast", true, false) == null, "no notice with FRIENDS CHAT off")
	Game.settings.friend_chat = true
	NetChat.mark_read(id)
	lobby._open_settings()
	await at.wait(0.5)
	var panel := lobby._find_settings()
	if panel:
		panel._show_tab(4)
		await at.wait(0.4)
		await at.shot("n04_settings_online")
		panel._scroll.scroll_vertical = 10000
		await at.wait(0.3)
		await at.shot("n04b_settings_online_end")
		panel._show_tab(3)
		await at.wait(0.3)
		await at.shot("n04c_settings_sound")
		panel._close()
	# A match with the online layer (a training match stands in: the layer is added by hand).
	Game.settings.push_to_talk = true      # (TALK shows with PUSH TO TALK and the mic on)
	Game.settings.mic_mode = NetVoice.ALL
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = get_tree().current_scene
	arena.set("prep_left", 1.0)
	await at.wait_for_phase(arena, 1)
	await at.wait(2.5)
	Game.session = cloud
	cloud.peer_rtt = 142
	# The direct path up (NetDirect, never opened here): the chip shows its round trip and DIRECT.
	var direct := NetDirect.new(true, Crypto.new().generate_random_bytes(32))
	direct.rtt = 38
	direct._rx_ms = Time.get_ticks_msec() + 3600000
	direct._peer_hears = true
	cloud.direct = direct
	var hud: HUD = arena.get("hud")
	var net := HudNet.attach(hud)
	net.add_line("NIGHTFOX21", "NICE SHOT! YOU GOT LUCKY THERE", false)
	net.add_line("YOU", "GG", true)
	await at.wait(0.5)
	_check(net.button_centers().size() == 5, "SPEAKER, MIC, TALK (push to talk), CHAT and MUTE show in an online match")
	_check(net.link_tag() == "DIRECT" and net.ping_ms() == 38, "the ping chip shows the direct round trip, tagged DIRECT")
	await at.shot("n05_match_hud")
	net.open_panel()
	await at.wait(0.4)
	await at.shot("n06_match_chat_panel")
	net.close_panel()
	net.open_voice_popup()
	await at.wait(0.4)
	_check(net.voice_popup != null and net.find_child("Mic_GROUP", true, false) == null, "the match's MIC MODE: no GROUP without teammates")
	await at.shot("n07_match_mic_mode")
	net.voice_popup.queue_free()
	await at.wait(0.2)
	# (round 8) An all-human DUO as this phone sees it (a Cloud outside the tree stands in: nothing is
	# sent): the chat's TEAM / ALL tabs, numbered feed lines, a sticker, the quick-chat bubble and
	# its tabs, the team's map markers on screen.
	cloud.direct = null
	net.queue_free()
	var fake := Cloud.new()
	fake.my_id = "tour-me"
	fake.in_session = true
	fake.session_multi = true
	fake._room = "tour"
	fake.session_roster = [{"id": "tour-me", "team": 0, "slot": 0, "name": "YOU"}, {"id": "tour-m2", "team": 0, "slot": 1, "name": "KESTREL"},
		{"id": "tour-e1", "team": 1, "slot": 2, "name": "NIGHTFOX21"}, {"id": "tour-e2", "team": 1, "slot": 3, "name": "VIPER"}]
	fake._multi = {"ids": {"tour-me": 0, "tour-m2": 1, "tour-e1": 2, "tour-e2": 3}, "left": {}}
	Game.session = fake
	Game.settings.mic_mode = NetVoice.OFF
	await at.wait(0.2)
	var tn := HudNet.attach(hud)
	await at.wait(0.3)
	_check(tn.team_tabs() and tn.channel == "team", "a DUO with a human teammate: the chat starts on TEAM")
	_check(tn.button_centers().has("quickchat") and tn.button_centers().has("marker"), "the quick-chat bubble and MARKER show in a DUO")
	tn._on_chat_from("PUSH LEFT, I COVER", "tour-m2", true)
	tn._on_chat_from("GG EASY", "tour-e1", false)
	tn._on_sticker(1, "tour-m2")
	_check(tn.feed.size() == 3 and int(tn.feed[0].num) == 2 and bool(tn.feed[1].all) and int(tn.feed[2].stk) == 1,
		"feed lines: the teammate's number, the enemy's ALL tag, a sticker")
	var me_f: Fighter = arena.get("player")
	var fwd := -me_f.global_transform.basis.z
	var t_now := Time.get_ticks_msec()
	fake.markers = {"tour-m2": {"p": me_f.global_position + fwd * 14.0 + Vector3(2.0, 0.0, 0.0), "t": t_now},
		"tour-me": {"p": me_f.global_position - fwd * 20.0, "t": t_now}}
	_check(fake.live_markers().size() == 2, "both team markers are live")
	await at.wait(0.4)
	await at.shot("n08_team_feed_markers")
	tn.open_panel()
	await at.wait(0.4)
	_check(tn.panel != null and tn.panel.find_child("Tab_team", true, false) != null and tn.panel.find_child("Tab_all", true, false) != null,
		"the chat panel has TEAM and ALL")
	await at.shot("n09_team_chat_panel")
	tn.set_channel("all")
	await at.wait(0.2)
	tn.close_panel()
	tn.open_bubble()
	await at.wait(0.4)
	_check(tn.bubble != null and tn.bubble.find_child("BubbleQuick_%d" % NetChat.TEAM_BASE, true, false) != null, "the bubble's QUICK tab has the team set")
	await at.shot("n10_bubble_quick")
	tn.bubble_tab = "stickers"
	tn._fill_bubble()
	await at.wait(0.3)
	_check(tn.bubble.find_child("Sticker_5", true, false) != null, "the bubble's STICKERS tab has the six stickers")
	await at.shot("n11_bubble_stickers")
	tn.close_bubble()
	tn.queue_free()
	await at.wait(0.2)
	Game.session = null
	fake.in_session = false
	fake.session_multi = false
	fake.free()
	Game.session = null
	Game.profile = saved_profile
	Game.settings = saved_settings
	at.log_line("net tour: %d failed" % _fails)
	return _fails


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)
