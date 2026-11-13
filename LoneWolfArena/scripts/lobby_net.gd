class_name LobbyNet
extends Node
## The lobby's online extras (scripts/net_chat.gd, Cloud card v3):
##  - CHAT buttons (`chat_button`): a friend's row in the ONLINE window's FRIENDS tab and a friend's
##    player card; they show how many messages wait unread ("CHAT 2").
##  - The chat panel (`open`, node `ChatWindow`): it slides in from the left over the live lobby
##    (left half of the screen, its "Frame"; a tap on the lobby beside it or its X closes it), as the
##    reference's chat: the FRIENDS tab along the top, the friends to chat with in a column (avatar,
##    name, unread count; a tap switches), the conversation (each message a row: avatar, name, time,
##    a dark bubble), our own quick phrases (NetChat.QUICK) to send with a tap, a text field
##    (NetChat.FRIEND_MAX characters) and the yellow SEND. It is filled again when a message comes in
##    (Cloud.friend_chat_changed), marks them read, and listens to the player cards while it is open
##    when the friend's key is not known yet. X and back go back to where it was opened.
##  - The CAREER block of another player's card (`career_block`): matches, wins, kills, K/D,
##    headshot rate and level from their card v3, or a line saying the player keeps it hidden.
##  - Lobby notices (`toast`): a short line at the top (`LobbyToast` in the lobby's `NoticeLayer`,
##    over the popups and the settings) for TOAST_S seconds; a tap opens what it is about
##    (LobbyFriends: a friend's message opens that chat, a friend request the FRIENDS tab). The
##    lobby only: a match shows chat in its own feed (HudNet).
##  - The unread badge (`set_badge`, `UnreadBadge`) on the ONLINE 1 VS 1 menu row
##    (NetChat.unread_total).

const WINDOW_W := 760.0
## The chat panel's share of the screen width, and its friends column.
const PANEL_W := 0.53
const PEOPLE_W := 178.0
const TOAST_S := 4.0
const TOAST_W := 660.0
const TOAST_H := 64.0
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


## Opens the chat with a friend: the panel from the left over the lobby.
static func open(owner_lobby: Lobby, friend_id: String, friend_name: String, back: String) -> void:
	if not Game.is_friend(friend_id) or Game.is_blocked(friend_id):
		return
	var dlg := owner_lobby.dialogs
	dlg.close_modal()
	var w := LobbyNet.new()
	w.name = "ChatWindow"
	w.lobby = owner_lobby
	w.id = friend_id
	w.who = friend_name
	w.back_to = back
	var modal := Control.new()
	modal.name = "Modal"
	UI.full_rect(modal)
	modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	owner_lobby.ui.add_child(modal)
	dlg.modal = modal
	modal.set_meta("on_back", w.go_back)
	# the lobby beside the panel: dimmed a little, a tap there closes the chat
	var outside := Button.new()
	outside.name = "ChatOutside"
	outside.focus_mode = Control.FOCUS_NONE
	outside.anchor_left = PANEL_W
	outside.anchor_right = 1.0
	outside.anchor_bottom = 1.0
	var dim := UI.box(Color(0, 0, 0, 0.18), 0, 0, Color.TRANSPARENT, 0.0)
	for st: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		outside.add_theme_stylebox_override(st, dim)
	outside.pressed.connect(dlg.back)
	modal.add_child(outside)
	var frame := PanelContainer.new()
	frame.name = "Frame"
	frame.anchor_right = PANEL_W
	frame.anchor_bottom = 1.0
	var st := UI.box(UI.CHAT_BG, 0, 0, Color.TRANSPARENT, 0.0)
	st.border_width_right = 1
	st.border_color = Color(1, 1, 1, 0.12)
	frame.add_theme_stylebox_override("panel", st)
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	modal.add_child(frame)
	modal.add_child(w)
	# the background runs to the screen's edge; the content keeps clear of a camera cutout there
	var safe := MarginContainer.new()
	safe.name = "Safe"
	frame.add_child(safe)
	UI.pad_clear_of_cutout(safe)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	safe.add_child(v)
	w.build(v)
	frame.position.x = -40.0
	modal.modulate.a = 0.0
	var tw := modal.create_tween().set_parallel()
	tw.tween_property(modal, "modulate:a", 1.0, 0.14)
	tw.tween_property(frame, "position:x", 0.0, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func build(v: VBoxContainer) -> void:
	# The tabs along the top (one channel: FRIENDS; a match's chat stays in the match HUD) and X.
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	tabs.custom_minimum_size = Vector2(0, 56)
	v.add_child(tabs)
	var ft := UI.top_tab("FRIENDS", true, 21, Vector2(190, 56))
	ft.name = "ChatTab_friends"
	tabs.add_child(ft)
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tabs.add_child(gap)
	var x := UI.close_button(56.0)
	x.name = "Close"
	x.pressed.connect(lobby.dialogs.back)
	tabs.add_child(x)
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.14)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(line)
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 0)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(body)
	# the friends to chat with
	var people_sc := ScrollContainer.new()
	people_sc.name = "ChatPeople"
	people_sc.custom_minimum_size = Vector2(PEOPLE_W, 0)
	people_sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(people_sc)
	body.add_child(people_sc)
	var people := VBoxContainer.new()
	people.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	people.add_theme_constant_override("separation", 2)
	people_sc.add_child(people)
	_fill_people(people)
	UI.drag_scroll(people_sc, people)
	var sep := ColorRect.new()
	sep.color = Color(1, 1, 1, 0.08)
	sep.custom_minimum_size = Vector2(1, 0)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.add_child(sep)
	var conv_m := MarginContainer.new()
	conv_m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side: String in ["left", "right", "top", "bottom"]:
		conv_m.add_theme_constant_override("margin_" + side, 12 if side in ["left", "right"] else 8)
	body.add_child(conv_m)
	var conv := VBoxContainer.new()
	conv.add_theme_constant_override("separation", 8)
	conv_m.add_child(conv)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	conv.add_child(head)
	var name_l := UI.ellipsis(UI.label("%s  #%s" % [who, Cloud.friend_code(id)], 22, UI.TEXT, "heavy"))
	name_l.name = "ChatWith"
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(name_l)
	_status = UI.label("", 16, UI.TEXT_DIM, "bold")
	_status.name = "ChatStatus"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	head.add_child(_status)
	_scroll = ScrollContainer.new()
	_scroll.name = "ChatScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(_scroll)
	conv.add_child(_scroll)
	_list = VBoxContainer.new()
	_list.name = "ChatList"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 12)
	_scroll.add_child(_list)
	_note = UI.label("END-TO-END ENCRYPTED. WHILE YOUR FRIEND IS OFFLINE, YOUR LAST MESSAGE WAITS FOR THEM.", 14, UI.TEXT_DIM, "semi")
	_note.name = "ChatNote"
	_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	conv.add_child(_note)
	# our own quick phrases: a tap sends one
	var quick_sc := ScrollContainer.new()
	quick_sc.name = "ChatQuick"
	quick_sc.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	quick_sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	quick_sc.custom_minimum_size = Vector2(0, 48)
	conv.add_child(quick_sc)
	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 6)
	quick_sc.add_child(quick)
	for q: String in NetChat.QUICK:
		var qb := UI.button(q, 15, "dark", Vector2(0, 44))
		qb.name = "Quick_%d" % quick.get_child_count()
		qb.pressed.connect(func() -> void:
			_field.text = q
			send())
		quick.add_child(qb)
	UI.drag_scroll(quick_sc, quick)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	conv.add_child(row)
	_field = lobby.friends._text_field("MESSAGE (%d CHARACTERS)" % NetChat.FRIEND_MAX, NetChat.FRIEND_MAX, false)
	_field.name = "ChatField"
	_field.text_submitted.connect(func(_t2: String) -> void: send())
	row.add_child(_field)
	var send_b := UI.button("SEND", 20, "primary", Vector2(120, 56))
	send_b.name = "ChatSend"
	send_b.pressed.connect(send)
	row.add_child(send_b)
	var cloud := Game.cloud_service()
	cloud.friend_chat_changed.connect(_on_message)
	if cloud.friend_key(id) == "":
		_dir_on = true
		cloud.start_directory("chat")       # their key comes with their player card
	refresh()


## The friends column: every friend (not blocked), the ones with unread messages first, then the
## ones online; the open conversation lit with a yellow edge. A tap opens that friend's chat.
func _fill_people(people: VBoxContainer) -> void:
	var cloud := Game.cloud_service()
	var ids: Array = []
	for f: String in Game.profile.friends:
		if not Game.is_blocked(f):
			ids.append(f)
	ids.sort_custom(func(a: String, b: String) -> bool:
		var ka := [NetChat.unread(a) > 0, cloud.peers.has(a), String(Game.profile.friends[a].name)]
		var kb := [NetChat.unread(b) > 0, cloud.peers.has(b), String(Game.profile.friends[b].name)]
		if ka[0] != kb[0]:
			return ka[0]
		if ka[1] != kb[1]:
			return ka[1]
		return String(ka[2]) < String(kb[2]))
	for f: String in ids:
		var fname := String(Game.profile.friends[f].name)
		if fname == "":
			fname = "PLAYER"
		var on := f == id
		var b := Button.new()
		b.name = "ChatPerson_" + Cloud.friend_code(f)
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(0, 60)
		for stn: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			b.add_theme_stylebox_override(stn, StyleBoxEmpty.new())
		var card: Dictionary = cloud.directory.get(f, {})
		var avatar := String(card.get("avatar", Game.DEFAULT_PROFILE.avatar))
		var unread := NetChat.unread(f) if f != id else 0     # (the open one is marked read)
		var online := cloud.peers.has(f)
		b.draw.connect(func() -> void:
			var s := b.size
			if on:
				b.draw_rect(Rect2(Vector2.ZERO, s), Color(1, 1, 1, 0.08))
				b.draw_rect(Rect2(0, 0, 4, s.y), UI.ACCENT)
			elif b.is_pressed():
				b.draw_rect(Rect2(Vector2.ZERO, s), Color(1, 1, 1, 0.05))
			var r := Rect2(12, 8, 44, 44)
			LobbyProfile.draw_avatar(b, avatar, r)
			b.draw_rect(r, Color(1, 1, 1, 0.7), false, 1.5)
			if online:
				b.draw_circle(r.end - Vector2(3, 3), 5.0, LobbyProfile.ONLINE_GREEN)
			var fnt := UI.font("bold")
			b.draw_string(fnt, Vector2(64, s.y * 0.5 + 7), fname, HORIZONTAL_ALIGNMENT_LEFT, s.x - 64 - (30 if unread > 0 else 6), 17,
				UI.ACCENT if on else UI.TEXT)
			if unread > 0:
				var c := Vector2(s.x - 16, s.y * 0.5)
				b.draw_circle(c, 11.0, UI.BAD)
				b.draw_string(fnt, c + Vector2(-11, 5), str(mini(unread, 9)), HORIZONTAL_ALIGNMENT_CENTER, 22, 14, Color.WHITE))
		b.button_down.connect(b.queue_redraw)
		b.button_up.connect(b.queue_redraw)
		b.pressed.connect(func() -> void:
			if f != id:
				Audio.play("ui_select", -6.0)
				LobbyNet.open(lobby, f, fname, back_to))
		people.add_child(b)


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
	# numbered: a name repeated among siblings would be replaced by an automatic one
	row.name = ("ChatMine_%d" if mine else "ChatTheirs_%d") % _list.get_child_count()
	row.add_theme_constant_override("separation", 10)
	var card: Dictionary = Game.cloud_service().directory.get(id, {})
	var avatar := String(Game.profile.avatar) if mine else String(card.get("avatar", Game.DEFAULT_PROFILE.avatar))
	var av := Control.new()
	av.custom_minimum_size = Vector2(48, 48)
	av.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	av.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	av.draw.connect(func() -> void:
		var r := Rect2(Vector2.ZERO, av.size)
		LobbyProfile.draw_avatar(av, avatar, r)
		av.draw_rect(r, Color(1, 1, 1, 0.75), false, 1.5))
	row.add_child(av)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	row.add_child(col)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	col.add_child(head)
	head.add_child(UI.label(String(Game.profile.name) if mine else who, 16, UI.ACCENT if mine else UI.TEXT, "bold"))
	head.add_child(UI.label(time_text(ts, int(Time.get_unix_time_from_system()), _tz_s()), 14, UI.TEXT_DIM, "semi"))
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.add_theme_stylebox_override("panel", UI.box(UI.BUBBLE, 0, 1, Color(1, 1, 1, 0.22), 12.0))
	var l := UI.label(text, 18, UI.TEXT, "semi")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(minf(HudDraw.text_width(text, 18, "semi") + 4.0, 330.0), 0)
	p.add_child(l)
	col.add_child(p)
	return row


## A message's time as the chat shows it: "TODAY 17:16", "YESTERDAY 09:05" or "12/11 17:16" (local
## time: `tz_s` seconds east of UTC).
static func time_text(ts: int, now: int, tz_s: int) -> String:
	var d := Time.get_datetime_dict_from_unix_time(ts + tz_s)
	var hm := "%02d:%02d" % [int(d.hour), int(d.minute)]
	var day := floori(float(ts + tz_s) / 86400.0)
	var today := floori(float(now + tz_s) / 86400.0)
	if day == today:
		return "TODAY " + hm
	if day == today - 1:
		return "YESTERDAY " + hm
	return "%02d/%02d %s" % [int(d.day), int(d.month), hm]


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


# ---------------------------------------------------------------- lobby notices

## A notice at the top of the lobby: an icon, `text` (cut with "..." when too long) and a small
## `caption` on the right; it slides in, stays TOAST_S seconds and fades. A tap closes it and
## runs on_tap. A newer notice takes its place.
static func toast(owner_lobby: Lobby, text: String, caption: String, on_tap: Callable, icon_name := "v_player") -> Button:
	var layer := owner_lobby.get_node_or_null(^"NoticeLayer") as CanvasLayer
	if layer == null:
		layer = CanvasLayer.new()
		layer.name = "NoticeLayer"
		layer.layer = 20                 # over the lobby's ui (popups, settings); the match loading is 100
		owner_lobby.add_child(layer)
	for c in layer.get_children():
		layer.remove_child(c)
		c.queue_free()
	var b := Button.new()
	b.name = "LobbyToast"
	b.focus_mode = Control.FOCUS_NONE
	var st := UI.chamfer(Color(0.05, 0.05, 0.045, 0.94), 12, 2, Color(UI.ACCENT, 0.9), 14.0, ["tl", "br"])
	for k in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(k, st)
	b.set_anchors_preset(Control.PRESET_CENTER_TOP)
	b.offset_left = -TOAST_W * 0.5
	b.offset_right = TOAST_W * 0.5
	b.offset_top = -TOAST_H - 8.0
	b.offset_bottom = -8.0
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 12)
	UI.full_rect(row)
	row.offset_left = 20
	row.offset_right = -18
	b.add_child(row)
	var icon := UI.icon(icon_name, 28.0, UI.ACCENT)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	var l := UI.ellipsis(UI.label(text, 20, UI.TEXT, "semi"))
	l.name = "ToastText"
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(l)
	var cap := UI.label(caption, 14, UI.ACCENT, "bold")
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(cap)
	layer.add_child(b)
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		b.queue_free()
		on_tap.call())
	var tw := b.create_tween()
	tw.tween_property(b, "offset_top", 10.0, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(b, "offset_bottom", 10.0 + TOAST_H, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_interval(TOAST_S)
	tw.tween_property(b, "modulate:a", 0.0, 0.3)
	tw.tween_callback(b.queue_free)
	return b


## The unread count on a lobby menu row (ONLINE 1 VS 1): a small red badge on its icon's corner,
## hidden at 0.
static func set_badge(row: Control, n: int) -> void:
	var badge := row.get_node_or_null(^"UnreadBadge") as Label
	if badge == null:
		badge = UI.label("", 14, UI.TEXT, "heavy")
		badge.name = "UnreadBadge"
		badge.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		badge.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var st := UI.box(UI.BAD, 12, 2, Color(0, 0, 0, 0.55), 0.0)
		st.content_margin_left = 5
		st.content_margin_right = 5
		badge.add_theme_stylebox_override("normal", st)
		badge.custom_minimum_size = Vector2(24, 24)
		badge.position = Vector2(40, 1)
		row.add_child(badge)
	badge.visible = n > 0
	badge.text = "9+" if n > 9 else str(n)


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
