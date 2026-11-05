class_name SettingsOnline
extends RefCounted
## SettingsPanel's ONLINE tab (its TAB_KEYS row: chat, friend_chat, show_career, voice_chat):
##  - CHAT IN MATCHES ON / OFF (NetChat: quick messages and text with the opponent);
##  - FRIENDS CHAT FRIENDS ONLY / OFF (NetChat: messages from friends; blocked players never);
##  - SHOW MY CAREER ON / OFF (the player card's career summary, Cloud card v3);
##  - VOICE CHAT OFF / ON (NetVoice, experimental, push to talk). Turning it on asks Android for the
##    microphone (RECORD_AUDIO) at that moment; refused, it stays off and says so.


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
