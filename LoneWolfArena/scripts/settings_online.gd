class_name SettingsOnline
extends RefCounted
## SettingsPanel's ONLINE tab (its TAB_KEYS row: chat, friend_chat, show_career, voice_chat,
## challenges_from, friend_requests, vibration, direct_connect):
##  - CHAT IN MATCHES ON / OFF (NetChat: quick messages and text with the opponent);
##  - FRIENDS CHAT FRIENDS ONLY / OFF (NetChat: messages from friends; blocked players never);
##  - SHOW MY CAREER ON / OFF (the player card's career summary, Cloud card v3);
##  - VOICE CHAT OFF / ON (NetVoice, experimental, push to talk). Turning it on asks Android for the
##    microphone (RECORD_AUDIO) at that moment; refused, it stays off and says so;
##  - DUEL CHALLENGES FROM EVERYONE / FRIENDS ONLY / NOBODY (Cloud.challenge_allowed: the others are
##    declined at once and never shown) and FRIEND REQUESTS ON / OFF (Cloud.requests_allowed: off,
##    they are ignored and never shown), and OUT OF A MATCH vibration ON / OFF (the reference's
##    out-of-match vibration: a buzz when a challenge or a friend request reaches the lobby);
##  - DIRECT CONNECTION ON / OFF (NetDirect, last on the tab): the match state goes straight to the
##    other phone (faster), which shows each phone's IP address to the other; OFF never sends an
##    address and plays through the relay only.

const CHALLENGE_CHOICES := ["EVERYONE", "FRIENDS ONLY", "NOBODY"]     # by Game.CHALLENGES_* value


static func build(panel: SettingsPanel) -> void:
	var body: VBoxContainer = panel._body
	body.add_child(UI.section("CHAT"))
	body.add_child(UI.plate_row("Chat in matches", panel._toggle("chat"),
		"Quick messages and text with your opponent, end-to-end encrypted"))
	var fc := UI.segmented(["OFF", "FRIENDS ONLY"], 1 if bool(Game.settings.friend_chat) else 0,
		func(v: int) -> void: panel._apply("friend_chat", v == 1), 16, 150.0)
	fc.name = "Toggle_friend_chat"
	body.add_child(UI.plate_row("Friends chat", fc, "Messages from your friends only; blocked players never reach you"))
	body.add_child(UI.section("PROFILE"))
	body.add_child(UI.plate_row("Show my career", panel._toggle("show_career"),
		"Other players see your matches, wins, kills, K/D and headshot rate on your player card"))
	body.add_child(UI.section("WHO CAN REACH YOU"))
	var duel := UI.segmented(CHALLENGE_CHOICES, int(Game.settings.challenges_from),
		func(v: int) -> void: panel._apply("challenges_from", v), 16, 128.0)
	duel.name = "Toggle_challenges_from"
	body.add_child(UI.plate_row("Duel challenges from", duel, "Anyone else is declined at once; nothing pops up for you"))
	body.add_child(UI.plate_row("Friend requests", panel._toggle("friend_requests"),
		"Off: new friend requests are ignored and never shown"))
	body.add_child(UI.plate_row("Vibration out of a match", panel._toggle("vibration"),
		"A buzz when a duel challenge or a friend request comes in while you are in the lobby"))
	body.add_child(UI.section("VOICE (EXPERIMENTAL)"))
	var note := UI.label("", 16, UI.ACCENT, "semi")
	note.name = "VoiceNote"
	var vc := UI.segmented(["OFF", "ON"], 1 if bool(Game.settings.voice_chat) else 0,
		func(v: int) -> void: _set_voice(panel, v == 1, note), 17, 104.0)
	vc.name = "Toggle_voice_chat"
	body.add_child(UI.plate_row("Voice chat", vc,
		"Push to talk in online matches: sent only while you hold the button, encrypted, never stored"))
	body.add_child(note)
	panel._hint.text = "No account: chat and voice are encrypted on your phone; the relay only passes them on."
	_build_direct(panel)


## VOICE CHAT: on Android the microphone permission is asked for first; refused, it stays OFF.
static func _set_voice(panel: SettingsPanel, on: bool, note: Label) -> void:
	if not on or OS.get_name() != "Android":
		panel._apply("voice_chat", on)
		return
	if OS.request_permission(NetVoice.MIC_PERMISSION):
		panel._apply("voice_chat", true)            # already allowed
		return
	note.text = "ALLOW THE MICROPHONE TO TALK"
	var tree := panel.get_tree()
	var answer := func(perm: String, granted: bool) -> void:
		if perm != NetVoice.MIC_PERMISSION or not is_instance_valid(panel):
			return
		panel._apply("voice_chat", granted)
		if is_instance_valid(note):
			note.text = "" if granted else "MICROPHONE NOT ALLOWED: VOICE CHAT STAYS OFF"
		if not granted and panel.is_inside_tree():
			panel._show_tab(panel._current)
	tree.on_request_permissions_result.connect(answer, CONNECT_ONE_SHOT)


## DIRECT CONNECTION (NetDirect): the last row of the tab.
static func _build_direct(panel: SettingsPanel) -> void:
	var body: VBoxContainer = panel._body
	body.add_child(UI.section("CONNECTION"))
	body.add_child(UI.plate_row("Direct connection", panel._toggle("direct_connect"),
		"Faster matches: the two phones talk directly, so your opponent's game learns your IP address. OFF: relay only"))
