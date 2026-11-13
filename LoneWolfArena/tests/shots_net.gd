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
	_check(net.button_centers().size() == 4, "CHAT, MUTE, TALK and SOUND show with chat and voice on")
	_check(net.link_tag() == "DIRECT" and net.ping_ms() == 38, "the ping chip shows the direct round trip, tagged DIRECT")
	await at.shot("n05_match_hud")
	net.open_panel()
	await at.wait(0.4)
	await at.shot("n06_match_chat_panel")
	net.close_panel()
	cloud.direct = null
	Game.session = null
	Game.profile = saved_profile
	Game.settings = saved_settings
	at.log_line("net tour: %d failed" % _fails)
	return _fails


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)
