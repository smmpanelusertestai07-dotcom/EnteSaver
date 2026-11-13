class_name LobbySocial
extends RefCounted
## The lobby's right-hand social panel (the reference's invite panel): an arrow tab at the screen's
## right edge (SocialArrow, "<") slides it in over the lobby's right side (SocialPanel, its "Frame";
## a tap beside it or its ">" closes it). Tabs FRIENDS / RECENT (SocialTab_<friends|recent>), a
## status choice (SocialStatus: JOIN ME ANYTIME = a GROUP INVITE is accepted at once, ONLINE = asked as
## before, BUSY = declined at once; setting team_status 0 / 1 / 2), REFRESH, a search
## (SocialSearch: name or ID) and GROUP CODE (SocialGroupCode: a numeric keypad, CodePad, that
## joins a friend's group by its code: Cloud.join_group_code). Each row (SocialRow_<code>): the
## player's picture, name and where they are, and the invite "+" (SocialInvite_<code>: a GROUP
## INVITE through LobbyTeam.ask_friend; greyed when they are offline, in a match, already in the
## group, or this player may not invite); a RECENT player who is not a friend has ADD FRIEND there
## instead (SocialAdd_<code>: Cloud.request_friend; ASKED once sent). No friends: ADD FRIENDS (opens FRIENDS > PLAYERS).
## Hidden while online teams are off and in a custom room. The lobby makes it (Lobby.social).

const STATUS := [["JOIN ME ANYTIME", Color(0.38, 0.86, 0.44)], ["ONLINE", Color(0.98, 0.78, 0.2)], ["BUSY", Color(0.92, 0.3, 0.3)]]
const PANEL_X := 0.70                    # the panel's left edge (share of the width)
const PANEL_BOTTOM := 0.75               # its bottom (the mode card and START stay clear below)

var lobby: Lobby
var arrow: Button
var _tab := "friends"
var _query := ""
var _list: VBoxContainer
var _pad_shown: Label
var _pad_state: Label
var _pad_digits := ""
var _pad_asked := false


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


## The status the player picked: 0 JOIN ME ANYTIME, 1 ONLINE, 2 BUSY.
static func status() -> int:
	return clampi(int(Game.settings.get("team_status", 1)), 0, 2)


## What a GROUP INVITE meets here: "accept" (JOIN ME ANYTIME), "decline" (BUSY) or "ask".
static func invite_answer(st: int) -> String:
	return "accept" if st == 0 else ("decline" if st == 2 else "ask")


func build(root: Control) -> void:
	arrow = Button.new()
	arrow.name = "SocialArrow"
	arrow.text = "<"
	arrow.focus_mode = Control.FOCUS_NONE
	arrow.anchor_left = 1.0
	arrow.anchor_right = 1.0
	arrow.anchor_top = 0.30
	arrow.anchor_bottom = 0.30
	arrow.offset_left = -40
	arrow.offset_right = 0
	arrow.offset_top = 0
	arrow.offset_bottom = 72
	arrow.add_theme_font_override("font", UI.font("heavy"))
	arrow.add_theme_font_size_override("font_size", 26)
	arrow.add_theme_color_override("font_color", UI.ACCENT)
	var st := UI.chamfer(Color(0.02, 0.02, 0.025, 0.7), 8, 1, Color(UI.ACCENT, 0.6), 0.0, ["tl", "bl"])
	for s: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		arrow.add_theme_stylebox_override(s, st)
	arrow.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		open())
	root.add_child(arrow)


## Every frame: the arrow shows with the lobby's own controls (not in a room, not while teams are
## off); an open keypad follows Cloud.code_state.
func process() -> void:
	if arrow and is_instance_valid(arrow):
		arrow.visible = Game.TEAMS_ONLINE and not Game.cloud_service().in_room() and lobby.wardrobe == null
	_follow_pad()


func open(tab := "") -> void:
	if tab != "":
		_tab = tab
	var dlg := lobby.dialogs
	dlg.close_modal()
	var modal := Control.new()
	modal.name = "Modal"
	UI.full_rect(modal)
	modal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lobby.ui.add_child(modal)
	dlg.modal = modal
	modal.set_meta("on_back", dlg.close_modal)
	var outside := Button.new()
	outside.name = "SocialOutside"
	outside.focus_mode = Control.FOCUS_NONE
	UI.full_rect(outside)
	for s: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		outside.add_theme_stylebox_override(s, StyleBoxEmpty.new())
	outside.pressed.connect(dlg.close_modal)
	modal.add_child(outside)
	var frame := PanelContainer.new()
	frame.name = "SocialPanel"
	frame.anchor_left = PANEL_X
	frame.anchor_right = 1.0
	frame.anchor_bottom = PANEL_BOTTOM
	var fs := UI.box(Color(0.05, 0.045, 0.06, 0.94), 0, 0, Color.TRANSPARENT, 0.0)
	fs.border_width_left = 1
	fs.border_color = Color(1, 1, 1, 0.14)
	frame.add_theme_stylebox_override("panel", fs)
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	modal.add_child(frame)
	var safe := MarginContainer.new()
	frame.add_child(safe)
	UI.pad_clear_of_cutout(safe)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	safe.add_child(v)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	v.add_child(tabs)
	var close := UI.button(">", 24, "dark", Vector2(56, 56))
	close.name = "SocialClose"
	close.pressed.connect(dlg.close_modal)
	tabs.add_child(close)
	for t: Array in [["friends", "FRIENDS"], ["recent", "RECENT"]]:
		var key := String(t[0])
		var b := UI.top_tab(String(t[1]), _tab == key, 18, Vector2(0, 56))
		b.name = "SocialTab_" + key
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void:
			if _tab != key:
				open(key))
		tabs.add_child(b)
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 6)
	v.add_child(tools)
	var stb := UI.button(String(STATUS[status()][0]), 13, "dark", Vector2(132, 56))
	stb.name = "SocialStatus"
	stb.add_theme_color_override("font_color", STATUS[status()][1])
	stb.pressed.connect(func() -> void:
		Game.settings.team_status = (status() + 1) % STATUS.size()
		Game.save_settings()
		open())
	tools.add_child(stb)
	var rf := UI.button("REFRESH", 13, "dark", Vector2(0, 56))
	rf.name = "SocialRefresh"
	rf.pressed.connect(func() -> void:
		Game.cloud_service().start_lobby()
		open())
	tools.add_child(rf)
	var tc := UI.button("GROUP CODE", 14, "light", Vector2(0, 56))
	tc.name = "SocialGroupCode"
	tc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tc.pressed.connect(open_pad)
	tools.add_child(tc)
	var search := LineEdit.new()
	search.name = "SocialSearch"
	search.placeholder_text = "SEARCH NAME OR ID"
	search.max_length = 24
	search.text = _query
	search.custom_minimum_size = Vector2(0, 56)
	search.add_theme_font_size_override("font_size", 16)
	search.text_submitted.connect(func(s: String) -> void:
		_query = s.strip_edges().to_upper()
		open())
	v.add_child(search)
	var sc := ScrollContainer.new()
	sc.name = "SocialScroll"
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(sc)
	v.add_child(sc)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	sc.add_child(_list)
	_fill()
	UI.drag_scroll(sc, _list)
	frame.offset_left = 40.0
	frame.offset_right = 40.0
	var tw := modal.create_tween().set_parallel()
	for side: String in ["offset_left", "offset_right"]:
		tw.tween_property(frame, side, 0.0, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


## The rows: FRIENDS (online first, never blocked ones) or RECENT (the players last met, newest
## first), filtered by the search.
func _fill() -> void:
	var cloud := Game.cloud_service()
	var ids: Array = []
	var names := {}
	if _tab == "recent":
		for r: Variant in Game.profile.get("recent", []):
			if r is Dictionary and String((r as Dictionary).get("id", "")) != "":
				ids.append(String(r.id))
				names[String(r.id)] = String((r as Dictionary).get("name", "PLAYER"))
	else:
		for f: String in Game.profile.friends:
			ids.append(f)
			names[f] = String(Game.profile.friends[f].name)
		ids.sort_custom(func(a: String, b: String) -> bool:
			if cloud.peers.has(a) != cloud.peers.has(b):
				return cloud.peers.has(a)
			return String(names[a]) < String(names[b]))
	var shown := 0
	for id: String in ids:
		if Game.is_blocked(id):
			continue
		var who := String(names[id]) if String(names[id]) != "" else "PLAYER"
		if _query != "" and not who.contains(_query) and not Cloud.friend_code(id).begins_with(_query):
			continue
		_list.add_child(_row(cloud, id, who))
		shown += 1
	if shown == 0:
		var empty := UI.label("NO PLAYERS MATCH" if _query != "" else ("NO MATCHES PLAYED WITH OTHERS YET" if _tab == "recent" else "NO FRIENDS YET"),
			17, UI.TEXT_DIM, "semi")
		empty.name = "SocialEmpty"
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_list.add_child(empty)
		if _tab == "friends":
			var add := UI.button("ADD FRIENDS", 17, "light", Vector2(0, 56))
			add.name = "SocialAddFriends"
			add.pressed.connect(func() -> void: lobby.friends.open("online"))
			_list.add_child(add)


## One player: picture, name, where they are, and the invite "+".
func _row(cloud: Cloud, id: String, who: String) -> Control:
	var code := Cloud.friend_code(id)
	var row := LobbyFriends.plain_row(id, cloud)
	row.name = "SocialRow_" + code
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", -2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(col)
	col.add_child(UI.ellipsis(UI.label(who, 18, UI.TEXT, "heavy")))
	var on := cloud.peers.has(id)
	var playing := on and cloud.peer_in_match(id)
	var mates := LobbyTeam.members().map(func(m: Dictionary) -> String: return String(m.id))
	var where := "IN YOUR TEAM" if mates.has(id) else ("IN A MATCH" if playing else ("ONLINE" if on else "OFFLINE"))
	col.add_child(UI.label(where, 13, LobbyProfile.ONLINE_GREEN if where == "ONLINE" else UI.TEXT_DIM, "bold"))
	if not Game.is_friend(id):
		# (RECENT: only a friend can be invited, so a stranger's row offers ADD FRIEND instead of a
		# greyed "+"; ASKED once the request went out)
		var asked := cloud.friend_asked(id)
		var add := UI.button("ASKED" if asked else "ADD FRIEND", 13, "dark" if asked else "light", Vector2(104, 56))
		add.name = "SocialAdd_" + code
		add.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		add.disabled = asked
		add.pressed.connect(func() -> void:
			Audio.play("ui_click", -4.0)
			if cloud.request_friend(id):
				LobbyNet.toast(lobby, "FRIEND REQUEST SENT", who, Callable())
				open()
			else:
				LobbyNet.toast(lobby, "COULD NOT SEND THE REQUEST", "TRY AGAIN WHEN ONLINE", Callable()))
		row.add_child(add)
		return row
	var plus := UI.button("+", 26, "primary", Vector2(56, 56))
	plus.name = "SocialInvite_" + code
	plus.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var may := LobbyTeam.is_leader() and (not LobbyTeam.in_group() or LobbyTeam.members().size() < LobbyTeam.group_max())
	plus.disabled = not (on and not playing and not mates.has(id) and may)
	plus.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		lobby.team.ask_friend(id, who))
	row.add_child(plus)
	return row


# ---------------------------------------------------------------- GROUP CODE keypad

## GROUP CODE: a keypad (CodePad) for a friend's Cloud.CODE_LEN-digit group code: keys
## CodeKey_<0-9>, CodeKeyBack (yellow), CodeKeyPaste, CodeKeyGo (yellow tick: Cloud.join_group_code);
## the line under it follows Cloud.code_state and the pad closes once the join it started let this
## player in (a player already in a group reads EXIT YOUR GROUP FIRST there and the pad stays open).
func open_pad() -> void:
	var v := lobby.dialogs.open_modal("GROUP CODE", 520.0, true)
	v.name = "CodePad"
	_pad_digits = ""
	_pad_asked = false
	_pad_shown = UI.label("", 34, UI.TEXT, "heavy")
	_pad_shown.name = "CodePadShown"
	_pad_shown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pad_shown.custom_minimum_size = Vector2(440, 56)
	_pad_shown.add_theme_stylebox_override("normal", UI.box(Color(0, 0, 0, 0.5), 0, 0, Color.TRANSPARENT, 8.0))
	v.add_child(_pad_shown)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	v.add_child(grid)
	for k: String in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "PASTE", "0", "<"]:
		var b := UI.button(k, 22 if k.length() == 1 else 15, "primary" if k == "<" else "dark", Vector2(140, 56))
		b.name = "CodeKeyBack" if k == "<" else ("CodeKeyPaste" if k == "PASTE" else "CodeKey_" + k)
		b.pressed.connect(_pad_key.bind(k))
		grid.add_child(b)
	var go := UI.button("JOIN", 22, "primary", Vector2(436, 56))
	go.name = "CodeKeyGo"
	go.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	go.pressed.connect(func() -> void:
		var why := Game.cloud_service().join_group_code(_pad_digits)
		_pad_asked = why == ""
		_pad_state.text = why if why != "" else LobbyTeam.code_state_text(Game.cloud_service().code_state))
	v.add_child(go)
	# (in a group already the code cannot be used: said at once, and the pad stays open)
	_pad_state = UI.label("EXIT YOUR GROUP FIRST: a code joins another group." if LobbyTeam.in_group()
		else "Enter a friend's %d-digit GROUP CODE (their JOIN BY CODE must be ON)." % Cloud.CODE_LEN, 16, UI.TEXT_DIM, "semi")
	_pad_state.name = "CodePadState"
	_pad_state.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pad_state.custom_minimum_size = Vector2(440, 0)
	v.add_child(_pad_state)
	_show_pad()


func _pad_key(k: String) -> void:
	Audio.play("ui_click", -4.0)
	if k == "<":
		_pad_digits = _pad_digits.left(maxi(_pad_digits.length() - 1, 0))
	elif k == "PASTE":
		var only := ""
		for ch in DisplayServer.clipboard_get():
			if ch >= "0" and ch <= "9":
				only += ch
		_pad_digits = only.left(Cloud.CODE_LEN)
	elif _pad_digits.length() < Cloud.CODE_LEN:
		_pad_digits += k
	_show_pad()


func _show_pad() -> void:
	if _pad_shown and is_instance_valid(_pad_shown):
		_pad_shown.text = Cloud.code_display(_pad_digits) if _pad_digits != "" else "-" .repeat(Cloud.CODE_LEN)


func _follow_pad() -> void:
	if _pad_state == null:
		return
	if not is_instance_valid(_pad_state) or not _pad_state.is_inside_tree():
		_pad_state = null
		return
	# Closes once the join this pad started let the player in (not for a player who was in a group
	# already: their JOIN reads EXIT YOUR GROUP FIRST and the pad stays).
	if _pad_asked and LobbyTeam.in_group():
		_pad_state = null
		lobby.dialogs.close_modal()
		return
	var st := LobbyTeam.code_state_text(Game.cloud_service().code_state)
	if _pad_asked and st != "" and _pad_state.text != st:
		_pad_state.text = st
