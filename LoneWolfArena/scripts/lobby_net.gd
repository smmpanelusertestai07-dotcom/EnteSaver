class_name LobbyNet
extends Node
## The lobby's online extras (scripts/net_chat.gd, Cloud card v3):
##  - CHAT buttons (`chat_button`): a friend's row in the ONLINE window's FRIENDS tab and a friend's
##    player card; they show how many messages wait unread ("CHAT 2").
##  - The chat window (`open`): a lobby popup (`ChatWindow`) with the messages (yours on the right),
##    a text field (NetChat.FRIEND_MAX characters) and SEND; it is filled again when a message comes
##    in (Cloud.friend_chat_changed), marks them read, and listens to the player cards while it is
##    open when the friend's key is not known yet. X and back go back to where it was opened.
##  - The CAREER block of another player's card (`career_block`): matches, wins, kills, K/D,
##    headshot rate and level from their card v3, or a line saying the player keeps it hidden.

const WINDOW_W := 760.0
const LIST_H := 300.0
const REASONS := {"OFFLINE": "YOU ARE OFFLINE: TRY AGAIN WHEN CONNECTED", "OFF": "FRIENDS CHAT IS OFF (SETTINGS, ONLINE)",
	"NOT A FRIEND": "ONLY FRIENDS CAN CHAT", "EMPTY": "TYPE A MESSAGE FIRST", "WAIT": "ONE MESSAGE A SECOND",
	"NO KEY": "LOOKING FOR YOUR FRIEND'S PLAYER CARD: TRY AGAIN IN A MOMENT"}

var lobby: Lobby
var id := ""
var who := ""
var back_to := ""                # "friends" (the FRIENDS tab), "card:<tab>" (their player card), "" (just close)
var _list: VBoxContainer
var _scroll: ScrollContainer
var _field: LineEdit
var _note: Label
var _status: Label
var _shown := ""
var _t := 0.0
var _dir_on := false


## A CHAT button for a friend (with the unread count).
static func chat_button(owner_lobby: Lobby, friend_id: String, friend_name: String, back: String, width := 130.0) -> Button:
	var n := NetChat.unread(friend_id)
	var b := UI.button("CHAT %d" % n if n > 0 else "CHAT", 17, "primary" if n > 0 else "light", Vector2(width, 56))
	b.name = "FriendChat"
	b.pressed.connect(func() -> void: open(owner_lobby, friend_id, friend_name, back))
	return b


## Opens the chat with a friend in the lobby's popup.
static func open(owner_lobby: Lobby, friend_id: String, friend_name: String, back: String) -> void:
	if not Game.is_friend(friend_id) or Game.is_blocked(friend_id):
		return
	var w := LobbyNet.new()
	w.name = "ChatWindow"
	w.lobby = owner_lobby
	w.id = friend_id
	w.who = friend_name
	w.back_to = back
	var v := owner_lobby.dialogs.open_modal("CHAT", WINDOW_W, true)
	owner_lobby.dialogs.modal.set_meta("on_back", w.go_back)
	owner_lobby.dialogs.modal.add_child(w)
	w.build(v)


func build(v: VBoxContainer) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	v.add_child(head)
	var name_l := UI.label("%s  #%s" % [who, Cloud.friend_code(id)], 24, UI.TEXT, "heavy")
	name_l.name = "ChatWith"
	head.add_child(name_l)
	_status = UI.label("", 17, UI.TEXT_DIM, "bold")
	_status.name = "ChatStatus"
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_status)
	_scroll = ScrollContainer.new()
	_scroll.name = "ChatScroll"
	_scroll.custom_minimum_size = Vector2(WINDOW_W - 52.0, LIST_H)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(_scroll)
	v.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.name = "ChatList"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 8)
	_scroll.add_child(_list)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	v.add_child(row)
	_field = lobby.friends._text_field("MESSAGE (%d CHARACTERS)" % NetChat.FRIEND_MAX, NetChat.FRIEND_MAX, false)
	_field.name = "ChatField"
	_field.text_submitted.connect(func(_t2: String) -> void: send())
	row.add_child(_field)
	var send_b := UI.button("SEND", 20, "primary", Vector2(150, 56))
	send_b.name = "ChatSend"
	send_b.pressed.connect(send)
	row.add_child(send_b)
	_note = UI.label("END-TO-END ENCRYPTED. WHILE YOUR FRIEND IS OFFLINE, YOUR LAST MESSAGE WAITS FOR THEM.", 15, UI.TEXT_DIM, "semi")
	_note.name = "ChatNote"
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_note.custom_minimum_size = Vector2(WINDOW_W - 52.0, 0)
	v.add_child(_note)
	var cloud := Game.cloud_service()
	cloud.friend_chat_changed.connect(_on_message)
	if cloud.friend_key(id) == "":
		_dir_on = true
		cloud.start_directory("chat")       # their key comes with their player card
	refresh()


func _exit_tree() -> void:
	var cloud := Game.cloud
	if cloud == null:
		return
	if cloud.friend_chat_changed.is_connected(_on_message):
		cloud.friend_chat_changed.disconnect(_on_message)
	if _dir_on:
		cloud.stop_directory("chat")


func _process(delta: float) -> void:
	_t -= delta
	if _t <= 0.0:
		_t = 0.5
		refresh()


func _on_message(from: String) -> void:
	if from == id:
		Audio.play("ui_select", -6.0)
		refresh()


## Fills the list again when something changed (messages, presence); marks the messages read.
func refresh() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	var cloud := Game.cloud_service()
	var msgs := NetChat.messages(id)
	var online := cloud.peers.has(id)
	_status.text = "ONLINE NOW" if online else ("OFFLINE" if cloud.status == "online" else "YOU ARE OFFLINE")
	_status.add_theme_color_override("font_color", LobbyProfile.ONLINE_GREEN if online else UI.TEXT_DIM)
	NetChat.mark_read(id)
	var key := "%d|%s" % [msgs.size(), str(msgs.back()) if not msgs.is_empty() else ""]
	if key == _shown:
		return
	_shown = key
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	if msgs.is_empty():
		var e := UI.label("NO MESSAGES YET. SAY HELLO!", 18, UI.TEXT_DIM, "semi")
		e.name = "ChatEmpty"
		_list.add_child(e)
	for m: Array in msgs:
		_list.add_child(_bubble(bool(m[1]), String(m[2]), int(m[0])))
	UI.drag_scroll(_scroll, _list)
	_scroll_to_end.call_deferred()


func _scroll_to_end() -> void:
	if _scroll and is_instance_valid(_scroll):
		await get_tree().process_frame
		if is_instance_valid(_scroll):
			_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _bubble(mine: bool, text: String, ts: int) -> Control:
	var row := HBoxContainer.new()
	row.name = "ChatMine" if mine else "ChatTheirs"
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.chamfer(Color(UI.ACCENT, 0.9) if mine else Color(1, 1, 1, 0.09), 8, 0,
		Color.TRANSPARENT, 12.0, ["br"] if mine else ["tl"]))
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	p.add_child(col)
	var l := UI.label(text, 19, UI.INK if mine else UI.TEXT, "semi")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(minf(HudDraw.text_width(text, 19, "semi") + 4.0, 470.0), 0)
	col.add_child(l)
	var d := Time.get_datetime_dict_from_unix_time(ts + _tz_s())
	var tl := UI.label("%02d:%02d" % [int(d.hour), int(d.minute)], 12, Color(UI.INK, 0.7) if mine else UI.TEXT_DIM, "bold")
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	col.add_child(tl)
	if mine:
		row.add_child(gap)
		row.add_child(p)
	else:
		row.add_child(p)
		row.add_child(gap)
	return row


static func _tz_s() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


## SEND: through the relay, encrypted to the friend (Cloud.send_friend_chat); why not, if not.
func send() -> void:
	var why := Game.cloud_service().send_friend_chat(id, _field.text)
	if why == "":
		_field.text = ""
		_note.text = "SENT, END-TO-END ENCRYPTED."
		_note.remove_theme_color_override("font_color")
		refresh()
	else:
		_note.text = String(REASONS.get(why, why))
		_note.add_theme_color_override("font_color", UI.ACCENT)


## X and back: to the FRIENDS tab or the player card it was opened from.
func go_back() -> void:
	if back_to == "friends":
		lobby.friends.open("friends", true)
	elif back_to.begins_with("card:"):
		lobby.profile_ui.open_player(id, back_to.substr(5))
	else:
		lobby.dialogs.close_modal()


# ---------------------------------------------------------------- another player's CAREER

const CAREER_CAPTIONS := ["MATCHES", "WINS", "KILLS", "K/D", "HEADSHOT RATE", "LEVEL"]


## The six values the CAREER block shows ("-" for a rate with nothing to divide by).
static func career_values(career: Dictionary, level: int) -> Array:
	var kd := int(career.get("kd", -1))
	var hs := int(career.get("hs", -1))
	return [LobbyProfile.thousands(int(career.get("matches", 0))), LobbyProfile.thousands(int(career.get("wins", 0))),
		LobbyProfile.thousands(int(career.get("kills", 0))), "-" if kd < 0 else "%.2f" % (kd / 100.0),
		"-" if hs < 0 else "%d%%" % hs, str(maxi(level, 1))]


## The CAREER block of a player card (`card`: the player's Cloud.directory entry), w px wide:
## nothing for a card from a build before v3, a line when the player hides it.
static func career_block(card: Dictionary, w: float) -> Control:
	if int(card.get("v", 0)) < 3:
		return null
	var box := VBoxContainer.new()
	box.name = "PlayerCareer"
	box.add_theme_constant_override("separation", 4)
	box.add_child(UI.label("CAREER", 13, UI.TEXT_DIM, "bold"))
	var career: Dictionary = card.get("career", {})
	if career.is_empty():
		var l := UI.label("THIS PLAYER KEEPS THEIR CAREER HIDDEN", 18, UI.TEXT_DIM, "semi")
		l.name = "CareerHidden"
		box.add_child(l)
		return box
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var values := career_values(career, int(card.get("level", 1)))
	var cell_w := (w - 8.0 * (values.size() - 1)) / values.size()
	for i in values.size():
		var p := PanelContainer.new()
		var st := UI.chamfer(Color(1, 1, 1, 0.06), 6, 0, Color.TRANSPARENT, 8.0, ["br"])
		st.content_margin_top = 4
		st.content_margin_bottom = 4
		p.add_theme_stylebox_override("panel", st)
		p.custom_minimum_size = Vector2(cell_w, 0)
		var c := VBoxContainer.new()
		c.add_theme_constant_override("separation", -2)
		p.add_child(c)
		var cap := UI.label(String(CAREER_CAPTIONS[i]), 12, UI.TEXT_DIM, "bold")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c.add_child(cap)
		var val := UI.label(String(values[i]), 22, UI.ACCENT if i in [3, 4] else UI.TEXT, "number")
		val.name = "PlayerCareer_%d" % i
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		c.add_child(val)
		row.add_child(p)
	return box
