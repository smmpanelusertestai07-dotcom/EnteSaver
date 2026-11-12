class_name LobbyFriends
extends RefCounted
## ONLINE 1 VS 1 in the lobby (LONE WOLF, through Cloud) and the online service's signals while
## the lobby is open: the challenge popup, a declined or cancelled challenge, friend requests, the
## custom room's changes and the session that starts an online match. The lobby makes it
## (Lobby.friends) and calls on_lobby_ready() from its _ready, on_lobby_exit() from its _exit_tree
## and process() every frame; popups open through Lobby.dialogs.
## A friend's chat message that comes in while the lobby is up shows as a notice at the top
## (LobbyNet.toast: "NAME: first words", a soft sound; a tap opens that chat), unless that chat is
## open, a match is loading, FRIENDS CHAT is off or the friend is blocked; the ONLINE 1 VS 1 row
## carries the unread count (LobbyNet.set_badge). A friend request that comes in while a popup is
## open shows as a notice too (with no popup open it gets its own popup); with FRIEND REQUESTS off
## none come in (Cloud.requests_allowed) and none pop up.
## A tap on a player's name in a list (ONLINE, ALL PLAYERS, the FRIENDS tab's friends and search
## results) opens their player card (LobbyProfile.open_player); blocked players are left out of
## every list (Game.block).
## The tab PLAY WITHOUT INTERNET (Tab_local) is LobbyLan's (scripts/lobby_lan.gd): two phones on the
## same Wi-Fi or one phone's hotspot, no internet at all (scripts/lan.gd).
## A TEAM INVITE (a friend's invite into their DUO / SQUAD against bots: Cloud.invite_from().team)
## shows in the same popup as a duel, titled TEAM INVITE; while Game.TEAMS_ONLINE is off it is
## declined at once. A session a team invite started (Cloud.session_team) loads the team match
## (Game.team_match = TeamArena.link_match), any other one the 1 vs 1 (Game.team_match = {}).
## GROUPS (design/GROUPS.txt, through Cloud's group API): a GROUP INVITE
## (Cloud.group_invited) shows "<NAME> invites you to their group" with ACCEPT / DECLINE / BLOCK and
## waits behind a busy popup as a duel does; LONE WOLF DUO / SQUAD's search has no popup: the
## lobby's search tab shows PLAYERS n/N (Cloud.search_found / search_needed) and the time searched,
## its X is cancel_search (Cloud.group_search_stop): real players only, no bots. Cloud.group_changed redraws the lobby's group parts (Lobby.on_group_changed).
## Node names: Tab_<online|friends|room|local>, NetList, MyId, FriendSearch, FriendAccept,
## FriendDecline, RoomHead, RoomStart, RoomPin, RoomMode_<1|2|4>, Rule_<key>, RoomCreate, JoinCode, JoinPin,
## RoomJoin, JoinState, AcceptButton, Player_<friend code> (a list row's name: opens the card),
## GroupInvitePopup (GroupInviteText, GroupInviteBlock, DeclineButton, AcceptButton).

var lobby: Lobby
var _net_kind := "online"
var _net_list: VBoxContainer
var _net_scroll: ScrollContainer       # the list scrolls once it would push the window off the screen
var _net_status: Label
var _net_sig := ""
var _net_note := ""
var _net_refresh_t := 0.0
var _friend_query := ""                # FRIENDS tab search (an ID or a name)
var _room_rules := Cloud.ROOM_RULES.duplicate()     # the next custom room's rules
var _room_pin_draft := ""              # the password typed before a rule button rebuilt the tab
var _room_join_code := ""              # the room this phone asked to join (for its status line)
var _room_size := 1                    # the next custom room's mode: SOLO 1, DUO 2, SQUAD 4
var _dir_on := false                   # this window asked the cloud for the player cards
var _place := {}                       # the tab and scroll a player's card was opened from: {"kind", "scroll"}
var _scroll_back := -1                 # open(kind, true) scrolls the new list back there once it is laid out
var _scroll_wait := 0
var _badge_n := -1                     # the unread count the ONLINE 1 VS 1 row shows
var _badge_t := 0.0
var _kb_field: LineEdit = null         # the text field the popup is lifted for (_lift_for_keyboard)
var _kb_seen := false                  # the on-screen keyboard was up for it (_follow_keyboard)
const MAX_ALL_PLAYERS := 60            # offline players listed under ALL PLAYERS


var lan: LobbyLan                      # the tab PLAY WITHOUT INTERNET
var _match_loading := false            # this lobby is loading an online match (_on_net_session)


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby
	lan = LobbyLan.new(self)


## The lobby is up: listen to the online service and go online; an online match that was called
## off (Game.match_notice) is explained once.
func on_lobby_ready() -> void:
	_connect_net(Game.cloud_service())
	lobby.dialogs.modal_closed.connect(_on_modal_closed, CONNECT_DEFERRED)
	# Online presence starts with the lobby, so friends and other players see this phone online
	# as soon as the game is open.
	Game.cloud_service().start_lobby()
	if Game.match_notice.size() == 2:
		lobby.dialogs.notice.call_deferred(String(Game.match_notice[0]), String(Game.match_notice[1]))
	Game.match_notice = []


## The lobby is leaving the tree.
func on_lobby_exit() -> void:
	lan.on_lobby_exit()
	var cloud := Game.cloud
	if cloud == null:
		return
	_disconnect_net(cloud)
	if _dir_on:
		_dir_on = false
		cloud.stop_directory("window")
	cloud.cancel_invite()
	if not cloud.in_session:
		cloud.close_room()
		cloud.leave_join()
	# presence stays on through a match: friends keep seeing this phone online


## Every frame: the open list follows the service (players, requests, invites); the unread badge.
func process(delta: float) -> void:
	_follow_keyboard()
	_badge_t -= delta
	if _badge_t <= 0.0:
		_badge_t = 0.5
		_update_badge()
	if _scroll_back >= 0 and _net_scroll and is_instance_valid(_net_scroll):
		_scroll_wait -= 1
		if _scroll_wait <= 0:                # two frames: the new list and the window are laid out
			_net_scroll.scroll_vertical = _scroll_back
			_scroll_back = -1
	if _dir_on and not (lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal)):
		_dir_on = false
		Game.cloud_service().stop_directory("window")
	if Game.lan and (Game.lan.role != "" or Game.lan.getting_ready()) and not (_net_kind == "local" and _net_list and is_instance_valid(_net_list)):
		lan.on_tab_closed()             # the tab PLAY WITHOUT INTERNET closed: HOST / JOIN stop
	if _net_list and is_instance_valid(_net_list):
		_net_refresh_t -= delta
		if _net_refresh_t <= 0.0:
			_net_refresh_t = 0.4
			_refresh_friends()


# ---------------------------------------------------------------- online 1 vs 1 (Cloud)

## The ONLINE window (LONE WOLF's START and the ONLINE 1 VS 1 menu row open it). No account: a
## free public relay carries end-to-end encrypted messages (see Cloud). Tabs: ONLINE (players
## online now, then every player with a card), FRIENDS (your ID, search, requests, friends) and
## CUSTOM ROOM. Players show up by name; DUEL 1 VS 1 sends a challenge, the other phone accepts
## or declines. This window listens to the player cards while it is open (PROFILE's BLOCKED does
## too: Cloud.start_directory(by)).
## back: it opens again under a player's card that closed (X, back, BLOCK, DUEL 1 VS 1): the list
## scrolls back to where that card was opened from, so a long ALL PLAYERS keeps the player's place.
func open(kind := "online", back := false) -> void:
	_net_kind = kind
	_scroll_back = int(_place.scroll) if back and String(_place.get("kind", "")) == kind else -1
	_scroll_wait = 2
	var cloud := Game.cloud_service()
	cloud.start_lobby()
	cloud.start_directory("window")  # every registered player, online or not
	_dir_on = true
	var v := lobby.dialogs.open_modal("ONLINE 1 VS 1", 980.0)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 10)
	for t: Array in [["online", "ONLINE", 175], ["friends", "FRIENDS", 175], ["room", "CUSTOM ROOM", 205],
			["local", "PLAY WITHOUT INTERNET", 300]]:
		var b := UI.button(String(t[1]), 19 if t[0] != "local" else 16, "primary" if t[0] == kind else "dark", Vector2(int(t[2]), 56))
		b.name = "Tab_" + String(t[0])
		var tk := String(t[0])
		b.pressed.connect(func() -> void:
			if tk != _net_kind:
				open(tk))
		tabs.add_child(b)
	v.add_child(tabs)
	var notes := {
		"online": "Players online now can be challenged: DUEL 1 VS 1. ADD FRIEND works for every player, online or not (an offline player gets the request when they come back).",
		"friends": "Search any player by ID or name. Friend requests reach players who are offline too. Friends who are online can be challenged to a 1 vs 1 duel.",
		"room": "A private room: share its ID and password. The host picks SOLO, DUO or SQUAD; players take the places they tap. Only the host starts, empty places stay empty.",
		"local": LobbyLan.GUIDE,
	}
	var info := UI.label(String(notes[kind]), 17, UI.TEXT_DIM, "semi")
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(info)
	_net_status = UI.label("", 20, UI.ACCENT, "bold")
	v.add_child(_net_status)
	if kind == "friends":
		_build_friends_tab(v)
	elif kind == "room":
		_build_room_tab(v)
	elif kind == "local":
		lan.build(v)
	_net_scroll = ScrollContainer.new()
	_net_scroll.name = "NetScroll"
	_net_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(_net_scroll)
	v.add_child(_net_scroll)
	_net_list = VBoxContainer.new()
	_net_list.name = "NetList"
	_net_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_net_list.add_theme_constant_override("separation", 8)
	_net_list.custom_minimum_size = Vector2(0, 170 if kind == "online" else 0)
	_net_scroll.add_child(_net_list)
	_net_list.minimum_size_changed.connect(_fit_list, CONNECT_DEFERRED)
	_net_sig = "-"
	_net_note = ""
	_refresh_friends()


## FRIENDS tab head: this phone's ID and a search box (an ID or a name among the players online).
func _build_friends_tab(v: VBoxContainer) -> void:
	var cloud := Game.cloud_service()
	var me := HBoxContainer.new()
	me.add_theme_constant_override("separation", 12)
	var code := Cloud.friend_code(cloud.my_id) if cloud.my_id != "" else "--------"
	var my_id := UI.label("YOUR ID:  %s" % code, 24, UI.TEXT, "heavy")
	my_id.name = "MyId"
	my_id.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	me.add_child(my_id)
	var copy := UI.button("COPY", 18, "light", Vector2(120, 56))
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(Cloud.friend_code(Game.cloud_service().my_id))
		_net_note = "ID COPIED"
		_net_sig = "-")
	me.add_child(copy)
	v.add_child(me)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var le := _text_field("FRIEND'S ID OR NAME", 14, false)
	le.name = "FriendSearch"
	le.text = _friend_query
	row.add_child(le)
	var go := UI.button("SEARCH", 19, "primary", Vector2(160, 56))
	var search := func() -> void:
		_friend_query = Game.clean_name(le.text)
		_net_sig = "-"
		_refresh_friends()
	go.pressed.connect(search)
	le.text_submitted.connect(func(_t: String) -> void: search.call())
	row.add_child(go)
	v.add_child(row)


## CUSTOM ROOM tab: create one (password, the mode: SOLO 1 VS 1 with its rules, DUO 2 VS 2, SQUAD
## 4 VS 4) or join one (ID + password). In a room (Cloud.in_room: the room is a group whose players
## joined by its code): the ID and password, the BLUE / ORANGE places (SlotPanel, host_word HOST: a
## tap on an empty place moves this player there, Cloud.room_take; the host's KICK on every other
## player, Cloud.kick_from_group) and the host's START (Cloud.room_start, only the host's works:
## uneven teams are fine, empty places stay empty, never a bot). A player out of the room (KICK, the
## room closed, its host gone) is back on the tab with a notice (Cloud.room_notice).
func _build_room_tab(v: VBoxContainer) -> void:
	var cloud := Game.cloud_service()
	if cloud.room_code != "":
		var head := UI.label("ROOM ID  %s     PASSWORD  %s" % [cloud.room_code, cloud.room_pin], 30, UI.TEXT, "heavy")
		head.name = "RoomHead"
		v.add_child(head)
		var size := int(cloud.group.get("size", 1)) if cloud.in_room() else 1
		v.add_child(UI.label(_room_mode_text(size, cloud.room_rules), 18, UI.TEXT_DIM, "semi"))
		if cloud.in_room():
			_room_slots(v, cloud, true)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 12)
		var close := UI.button("CLOSE ROOM", 19, "light", Vector2(200, 56))
		close.pressed.connect(func() -> void:
			Game.cloud_service().close_room()
			open("room"))
		var start := UI.button("START", 22, "primary", Vector2(200, 56))
		start.name = "RoomStart"
		start.disabled = not room_ready(cloud)
		start.pressed.connect(func() -> void:
			start.disabled = true
			UI.set_caption(start, "STARTING")
			var why := Game.cloud_service().room_start()
			if why != "":
				_net_note = why
				_net_sig = "-"
				UI.set_caption(start, "START")
				start.disabled = false)
		row.add_child(close)
		row.add_child(start)
		v.add_child(row)
		return
	if cloud.join_state != "":
		var msg := {"asking": "JOINING ROOM %s...", "in": "IN ROOM %s: WAITING FOR THE HOST TO START",
			"wrong": "WRONG PASSWORD FOR ROOM %s", "full": "ROOM %s IS FULL", "none": "NO ROOM %s FOUND (OR ITS HOST LEFT)"}
		var st := UI.label(String(msg.get(cloud.join_state, "%s")) % String(_room_join_code), 24, UI.TEXT, "heavy")
		st.name = "JoinState"
		v.add_child(st)
		if cloud.join_state == "in" and cloud.in_room():
			v.add_child(UI.label(_room_mode_text(int(cloud.group.get("size", 1)), {}), 18, UI.TEXT_DIM, "semi"))
			_room_slots(v, cloud, false)
		var back := UI.button("LEAVE" if cloud.join_state in ["asking", "in"] else "BACK", 19, "light", Vector2(200, 56))
		back.pressed.connect(func() -> void:
			Game.cloud_service().leave_join()
			open("room"))
		v.add_child(back)
		return
	# Create: password (digits), the mode, the rules (SOLO's 1 vs 1).
	var create := HBoxContainer.new()
	create.add_theme_constant_override("separation", 10)
	create.add_child(UI.label("NEW ROOM  ·  PASSWORD", 20, UI.TEXT, "bold"))
	var pin := _text_field("4-6 DIGITS", 6, true)
	pin.name = "RoomPin"
	pin.text = "%04d" % randi_range(0, 9999)
	pin.custom_minimum_size = Vector2(170, 56)
	pin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	create.add_child(pin)
	for m: Array in [[1, "SOLO 1 VS 1"], [2, "DUO 2 VS 2"], [4, "SQUAD 4 VS 4"]]:
		var n := int(m[0])
		var mb := UI.button(String(m[1]), 16, "primary" if n == _room_size else "dark", Vector2(150, 56))
		mb.name = "RoomMode_%d" % n
		mb.pressed.connect(func() -> void:
			_room_size = n
			_room_pin_draft = pin.text
			open("room"))
		create.add_child(mb)
	v.add_child(create)
	if _room_size == 1:
		var rules := HBoxContainer.new()
		rules.add_theme_constant_override("separation", 8)
		for k: Array in [["ammo", "UNLIMITED AMMO"], ["walls", "UNLIMITED WALLS"], ["frags", "UNLIMITED FRAGS"]]:
			var key := String(k[0])
			var tb := UI.button(String(k[1]), 16, "primary" if bool(_room_rules[key]) else "dark", Vector2(190, 56))
			tb.name = "Rule_" + key
			tb.pressed.connect(func() -> void:
				_room_rules[key] = not bool(_room_rules[key])
				_room_pin_draft = pin.text
				open("room"))
			rules.add_child(tb)
		var rounds := UI.button("FIRST TO %d" % int(_room_rules.rounds), 16, "light", Vector2(150, 56))
		rounds.name = "Rule_rounds"
		rounds.pressed.connect(func() -> void:
			var steps := [1, 3, 5, 7]
			_room_rules.rounds = steps[(steps.find(int(_room_rules.rounds)) + 1) % steps.size()]
			_room_pin_draft = pin.text
			open("room"))
		rules.add_child(rounds)
		v.add_child(rules)
	if _room_pin_draft != "":
		pin.text = _room_pin_draft
	var make := UI.button("CREATE ROOM", 20, "primary", Vector2(230, 56))
	make.name = "RoomCreate"
	make.pressed.connect(func() -> void:
		var p := pin.text
		if p.length() < 4:
			_net_note = "THE PASSWORD NEEDS 4 TO 6 DIGITS"
			_net_sig = "-"
			return
		_room_pin_draft = ""
		Game.cloud_service().open_room(p, _room_rules, "", _room_size)
		open("room"))
	v.add_child(make)
	# Join: room ID + password.
	var join := HBoxContainer.new()
	join.add_theme_constant_override("separation", 10)
	join.add_child(UI.label("JOIN A ROOM", 20, UI.TEXT, "bold"))
	var code := _text_field("ROOM ID", 6, true)
	code.name = "JoinCode"
	join.add_child(code)
	var jpin := _text_field("PASSWORD", 6, true)
	jpin.name = "JoinPin"
	join.add_child(jpin)
	var go := UI.button("JOIN", 20, "primary", Vector2(150, 56))
	go.name = "RoomJoin"
	go.pressed.connect(func() -> void:
		if code.text.length() != 6 or jpin.text.length() < 4:
			_net_note = "ENTER THE 6-DIGIT ROOM ID AND ITS PASSWORD"
			_net_sig = "-"
			return
		_room_join_code = code.text
		Game.cloud_service().join_room(code.text, jpin.text)
		open("room"))
	join.add_child(go)
	v.add_child(join)


## The room's places (SlotPanel): its players by name in BLUE / ORANGE; a tap on an empty place
## moves this player there; the host also has KICK on every other player.
func _room_slots(v: VBoxContainer, cloud: Cloud, host: bool) -> void:
	var size := int(cloud.group.get("size", 1))
	var panel := SlotPanel.new()
	panel.take_empty = true
	panel.kick = host
	panel.host_word = "HOST"
	panel.slot_tapped.connect(func(t: int, i: int) -> void:
		if not Game.cloud_service().room_take(t, i):
			_net_note = "THAT PLACE IS TAKEN"
			_net_sig = "-")
	panel.kick_tapped.connect(func(id: String) -> void: Game.cloud_service().kick_from_group(id))
	v.add_child(panel)
	panel.show_slots(NetGroup.places(size, true), room_entries(cloud.group_members(), size))


## The room's players as SlotPanel entries: each in their team's place (Cloud's slot is the roster
## slot, team * per_team + place), the host tagged.
static func room_entries(list: Array, size: int) -> Array:
	var base := NetGroup.per_team(size)
	var out := []
	for m: Dictionary in list:
		var t := clampi(int(m.get("team", 0)), 0, 1)
		out.append({"id": String(m.get("id", "")), "name": String(m.get("name", "PLAYER")), "team": t,
			"slot": int(m.get("slot", 0)) - t * base, "host": bool(m.get("leader", false)), "me": bool(m.get("me", false))})
	return out


## Whether the host's START can go: SOLO once the other player is in, DUO / SQUAD once both teams
## have a player (uneven is fine).
static func room_ready(cloud: Cloud) -> bool:
	if not cloud.in_room() or int(cloud.group.get("size", 1)) == 1:
		return not cloud.room_guest.is_empty()
	return NetGroup.plan(cloud.group.members, int(cloud.group.size)) == "match"


## What the room plays: SOLO with its rules, DUO / SQUAD between the players in the places.
func _room_mode_text(size: int, rules: Dictionary) -> String:
	if size == 1:
		return _rules_text(rules) if not rules.is_empty() else "SOLO  ·  1 VS 1"
	return "%s  ·  %d VS %d  ·  REAL PLAYERS, EMPTY PLACES STAY EMPTY" % ["DUO" if size == 2 else "SQUAD", size, size]


func _rules_text(r: Dictionary) -> String:
	var parts := ["1 VS 1", "FIRST TO %d" % int(r.get("rounds", 5))]
	for k: Array in [["ammo", "UNLIMITED AMMO"], ["walls", "UNLIMITED WALLS"], ["frags", "UNLIMITED FRAGS"]]:
		if bool(r.get(String(k[0]), false)):
			parts.append(String(k[1]))
	return "   ·   ".join(PackedStringArray(parts))


## A text box in the lobby's style; digits_only keeps only 0-9 and opens the number keyboard.
func _text_field(placeholder: String, max_len: int, digits_only: bool) -> LineEdit:
	var le := LineEdit.new()
	le.placeholder_text = placeholder
	le.max_length = max_len
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size = Vector2(150, 56)
	le.virtual_keyboard_enabled = true
	le.virtual_keyboard_show_on_focus = true
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER if digits_only else LineEdit.KEYBOARD_TYPE_DEFAULT
	le.add_theme_font_override("font", UI.font("bold"))
	le.add_theme_font_size_override("font_size", 24)
	le.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.25), 14.0, ["br"]))
	le.add_theme_stylebox_override("focus", UI.chamfer(Color(0, 0, 0, 0.5), 8, 2, UI.ACCENT, 14.0, ["br"]))
	le.add_theme_color_override("font_color", UI.TEXT)
	le.add_theme_color_override("caret_color", UI.ACCENT)
	le.editing_toggled.connect(func(on: bool) -> void: _lift_for_keyboard(le, on))
	if digits_only:
		le.text_changed.connect(func(t: String) -> void:
			var d := ""
			for ch in t:
				if ch >= "0" and ch <= "9":
					d += ch
			if d != t:
				le.text = d
				le.caret_column = d.length())
	return le


## The on-screen keyboard covers about the lower half of a landscape screen and the immersive
## window is not resized for it: while a text field is being typed in, the popup moves up until the
## field sits in the top fifth of the screen (and back down when the typing ends).
func _lift_for_keyboard(le: LineEdit, on: bool) -> void:
	var modal := lobby.dialogs.modal
	var frame := modal.get_node_or_null("Frame") as Control if modal and is_instance_valid(modal) else null
	if frame == null or not le.is_inside_tree():
		return
	var lifted := float(frame.get_meta("lifted", 0.0))
	frame.offset_top += lifted
	frame.offset_bottom += lifted
	frame.set_meta("lifted", 0.0)
	if on:
		var lift := maxf(le.get_global_rect().position.y + lifted - lobby.get_viewport().get_visible_rect().size.y * 0.2, 0.0)
		frame.offset_top -= lift
		frame.offset_bottom -= lift
		frame.set_meta("lifted", lift)
	_kb_field = le if on else null
	_kb_seen = false


## While a field is lifted for typing, the on-screen keyboard's real height (DisplayServer, on a
## phone): the popup sits just above the keyboard (a chat's history stays in view when there is
## room), and comes back down when the keyboard goes away while the field keeps its focus (Android's
## back closes only the keyboard). Desktop reports no keyboard: the lift stays as typing began.
func _follow_keyboard() -> void:
	if _kb_field == null:
		return
	if not is_instance_valid(_kb_field) or not _kb_field.is_inside_tree():
		_kb_field = null
		return
	var kb := DisplayServer.virtual_keyboard_get_height()
	if kb > 0:
		_kb_seen = true
		_place_above_keyboard(_kb_field, kb)
	elif _kb_seen:
		var le := _kb_field
		_lift_for_keyboard(le, false)
		le.release_focus()


## Lifts the popup just enough that the field clears a keyboard kb_px (screen pixels) high, at most
## until the field is near the top of the screen.
func _place_above_keyboard(le: LineEdit, kb_px: int) -> void:
	var modal := lobby.dialogs.modal
	var frame := modal.get_node_or_null("Frame") as Control if modal and is_instance_valid(modal) else null
	if frame == null:
		return
	var vh := lobby.get_viewport().get_visible_rect().size.y
	var kb_top := vh - float(kb_px) * vh / maxf(float(DisplayServer.window_get_size().y), 1.0)
	var lifted := float(frame.get_meta("lifted", 0.0))
	var r := le.get_global_rect()
	var lift := clampf(r.end.y + lifted + 12.0 - kb_top, 0.0, maxf(r.position.y + lifted - vh * 0.06, 0.0))
	if absf(lift - lifted) > 1.0:
		frame.offset_top += lifted - lift
		frame.offset_bottom += lifted - lift
		frame.set_meta("lifted", lift)


func _refresh_friends() -> void:
	if _net_list == null or not is_instance_valid(_net_list):
		return
	if _net_kind == "local":
		_net_status.text = lan.status_text()
		var lsig := lan.signature()
		if lsig != _net_sig:
			_net_sig = lsig
			for c in _net_list.get_children():
				_net_list.remove_child(c)
				c.queue_free()
			lan.fill(_net_list)
			UI.drag_scroll(_net_scroll, _net_list)
		return
	var cloud := Game.cloud_service()
	var waiting := cloud.waiting_for()
	var peers: Dictionary = cloud.peers
	var blocked := Game.blocked_ids()
	var listed := peers.keys().filter(func(i: String) -> bool: return not blocked.has(i))     # blocked players are left out
	if cloud.status != "online":
		match cloud.status:
			"preparing":
				_net_status.text = "GETTING READY..."
			"connecting":
				_net_status.text = "CONNECTING..."
			_:
				_net_status.text = "NO INTERNET: RETRYING... OR TAP PLAY WITHOUT INTERNET"
	elif waiting != "":
		_net_status.text = "WAITING FOR %s TO ACCEPT..." % waiting
	elif _net_note != "":
		_net_status.text = _net_note
	elif _net_kind == "friends":
		_net_status.text = "%d FRIEND REQUEST%s" % [cloud.friend_requests.size(), "" if cloud.friend_requests.size() == 1 else "S"] \
			if not cloud.friend_requests.is_empty() else "FRIENDS"
	elif _net_kind == "room":
		_net_status.text = "ROOM OPEN: SHARE ITS ID AND PASSWORD" if cloud.room_code != "" else ""
	elif listed.is_empty():
		_net_status.text = "LOOKING FOR PLAYERS ONLINE..."
	else:
		_net_status.text = "PLAYERS ONLINE"
	# ONLINE: the players-online heading is the list's first row, so it scrolls away with its
	# section (ALL PLAYERS below has its own); the line above the list keeps the passing states.
	var heading := _net_kind == "online" and _net_status.text in ["PLAYERS ONLINE", "LOOKING FOR PLAYERS ONLINE..."]
	_net_status.visible = not heading
	if _net_kind == "room":
		return
	if _net_kind == "friends" and lobby.dialogs.modal and cloud.my_id != "":
		var my := lobby.dialogs.modal.find_child("MyId", true, false) as Label
		if my:
			my.text = "YOUR ID:  %s" % Cloud.friend_code(cloud.my_id)     # the key may be made after the tab opened
	var sig := waiting + "|" + _net_kind + "|" + _friend_query + "|" + cloud.status
	for id in peers:
		sig += "|%s:%s" % [id, peers[id].name]
	sig += "|f%d|r%s|o%d|d%d|b%s" % [(Game.profile.friends as Dictionary).size(), ",".join(PackedStringArray(cloud.friend_requests.keys())),
		(Game.profile.friend_out as Dictionary).size(), cloud.directory.size(), ",".join(PackedStringArray(blocked.keys()))]
	for id in peers:
		sig += ",a" if cloud.friend_asked(String(id)) else ""
	sig += "|u" + NetChat.unread_key()          # a friend's CHAT button shows the unread messages
	sig += "|h" + (_net_status.text if heading else "")
	if sig == _net_sig:
		return
	_net_sig = sig
	for c in _net_list.get_children():
		_net_list.remove_child(c)
		c.queue_free()
	if _net_kind == "friends":
		_fill_friends(cloud, waiting)
	else:
		if heading:
			var online_head := UI.label(_net_status.text, 20, UI.ACCENT, "bold")
			online_head.name = "OnlineHead"
			_net_list.add_child(online_head)
		for id: String in listed:
			_net_list.add_child(_player_row(cloud, id, String(peers[id].name), waiting, "  ·  ONLINE"))
		if _net_kind == "online":
			var offline := _offline_players(cloud, "")
			if not offline.is_empty():
				var head := UI.label("ALL PLAYERS  ·  %d" % offline.size(), 19, UI.TEXT_DIM, "bold")
				head.name = "AllPlayersHead"
				_net_list.add_child(head)
			for id: String in offline:
				_net_list.add_child(_player_row(cloud, id, String(cloud.directory[id].name), waiting, "  ·  " + _ago(int(cloud.directory[id].ts))))
	UI.drag_scroll(_net_scroll, _net_list)          # a finger drag on a row scrolls the list


## The list's height: all of it while the window fits the screen, else as much as fits, scrolling
## (ALL PLAYERS can list dozens of players).
func _fit_list() -> void:
	if _net_scroll == null or not is_instance_valid(_net_scroll) or not _net_scroll.is_inside_tree():
		return
	var frame := _net_scroll.get_parent().get_parent().get_parent() as Control     # the popup's column (open_modal)
	if frame == null:
		return
	var rest := frame.get_combined_minimum_size().y - _net_scroll.custom_minimum_size.y
	var room := maxf(lobby.get_viewport().get_visible_rect().size.y - 32.0 - rest, 140.0)
	_net_scroll.custom_minimum_size.y = minf(_net_list.get_combined_minimum_size().y, room)


## Players with a card who are not online right now (search: an ID start or part of the name),
## most recently seen first; blocked players are left out.
func _offline_players(cloud: Cloud, query: String) -> Array:
	var out := []
	var blocked := Game.blocked_ids()
	for id: String in cloud.directory:
		if cloud.peers.has(id) or blocked.has(id):
			continue
		if query != "" and not (_id_matches(id, query) or String(cloud.directory[id].name).contains(query)):
			continue
		out.append(id)
	out.sort_custom(func(a: String, b: String) -> bool: return int(cloud.directory[a].ts) > int(cloud.directory[b].ts))
	return out.slice(0, MAX_ALL_PLAYERS)


## A search matches an ID by its start: the 8-character code or the start of the full ID that the
## profile's COPY puts on the clipboard (the search box keeps its first 14 characters).
static func _id_matches(id: String, query: String) -> bool:
	return id.to_upper().begins_with(query)


## "LAST SEEN 5 MIN AGO" from a card's unix time.
static func _ago(ts: int) -> String:
	var s := maxi(int(Time.get_unix_time_from_system()) - ts, 0)
	if s < 120:
		return "SEEN JUST NOW"
	if s < 3600:
		return "LAST SEEN %d MIN AGO" % (s / 60)
	if s < 86400:
		return "LAST SEEN %d H AGO" % (s / 3600)
	return "LAST SEEN %d DAY%s AGO" % [s / 86400, "" if s / 86400 == 1 else "S"]


## One player in a list: the name and code (a tap opens the player card), ADD FRIEND (not a friend
## yet) and DUEL 1 VS 1 (online now). Only the row of the player the challenge waits for reads
## CANCEL; the others keep DUEL 1 VS 1, which calls that challenge off and challenges this player.
func _player_row(cloud: Cloud, id: String, who: String, waiting: String, online_tag := "") -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.add_child(_who_button(id, "%s  #%s%s" % [who, Cloud.friend_code(id), online_tag]))
	if not Game.is_friend(id) and (cloud.peers.has(id) or cloud.directory.has(id)):
		var asked := cloud.friend_asked(id)
		var add := UI.button("ASKED" if asked else "ADD FRIEND", 17, "dark" if asked else "light", Vector2(170, 56))
		add.disabled = asked
		add.pressed.connect(add_friend.bind(id))
		row.add_child(add)
	if cloud.peers.has(id):
		# (while a challenge waits, the room it set up names its player: Cloud.opponent)
		var theirs := waiting != "" and String(cloud.opponent.get("id", "")) == id
		var b := UI.button("CANCEL" if theirs else "DUEL 1 VS 1", 19, "light" if theirs else "primary", Vector2(210, 56))
		b.name = "Cancel_" + Cloud.friend_code(id) if theirs else "Duel_" + Cloud.friend_code(id)
		b.pressed.connect(func() -> void:
			var sv := Game.cloud_service()
			if sv.waiting_for() != "" and String(sv.opponent.get("id", "")) != id:
				sv.cancel_invite()           # one challenge at a time: this one replaces the one waiting
			challenge(id))
		row.add_child(b)
	return row


## A list row's name (LobbyProfile.player_button): a tap opens the player's card, which goes back
## to this tab when it closes.
func _who_button(id: String, text: String) -> Button:
	var b := LobbyProfile.player_button(id, text)
	b.pressed.connect(func() -> void:
		_place = {"kind": _net_kind, "scroll": _net_scroll.scroll_vertical if _net_scroll and is_instance_valid(_net_scroll) else 0}
		lobby.profile_ui.open_player(id, _net_kind))
	return b


## DUEL 1 VS 1 (a list row or a player card): challenges the player, or cancels the challenge
## that is waiting for an answer.
func challenge(id: String) -> void:
	var sv := Game.cloud_service()
	_net_note = ""
	if sv.waiting_for() != "":
		sv.cancel_invite()
	elif not sv.invite(id):
		_net_note = "COULD NOT SEND THE REQUEST, TRY AGAIN"
	_net_sig = "-"
	_refresh_friends()


## A line in the window's status (after a BLOCK on a card: who was blocked); it shows while the
## service is online and nothing more pressing is said there, until the window opens again.
func note(text: String) -> void:
	_net_note = text
	_net_sig = "-"
	_refresh_friends()


## ADD FRIEND (a list row or a player card): sends the request, online or not.
func add_friend(id: String) -> void:
	if not Game.cloud_service().request_friend(id):
		_net_note = "COULD NOT SEND THE REQUEST, TRY AGAIN"
	_net_sig = "-"
	_refresh_friends()


## FRIENDS tab body: requests to answer, the search's matches among players online, the friends.
func _fill_friends(cloud: Cloud, waiting: String) -> void:
	for id: String in cloud.friend_requests:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var t := UI.label("%s  #%s  wants to be friends" % [String(cloud.friend_requests[id].name), Cloud.friend_code(id)], 22, UI.ACCENT, "bold")
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(t)
		for a: Array in [["DECLINE", false, "light"], ["ACCEPT", true, "primary"]]:
			var yes := bool(a[1])
			var b := UI.button(String(a[0]), 18, String(a[2]), Vector2(150, 56))
			b.name = "Friend" + String(a[0]).capitalize()
			b.disabled = cloud.status != "online"     # an answer goes through the relay (offline it would come back)
			b.pressed.connect(func() -> void:
				Game.cloud_service().answer_friend(id, yes)
				_net_sig = "-"
				_refresh_friends())
			row.add_child(b)
		_net_list.add_child(row)
	if _friend_query != "":
		var found := 0
		for id: String in cloud.peers:
			var who := String(cloud.peers[id].name)
			if not Game.is_blocked(id) and (_id_matches(id, _friend_query) or who.contains(_friend_query)):
				_net_list.add_child(_player_row(cloud, id, who, waiting, "  ·  ONLINE"))
				found += 1
		for id: String in _offline_players(cloud, _friend_query):
			_net_list.add_child(_player_row(cloud, id, String(cloud.directory[id].name), waiting, "  ·  " + _ago(int(cloud.directory[id].ts))))
			found += 1
		if found == 0:
			_net_list.add_child(UI.label("NO PLAYER MATCHES \"%s\"" % _friend_query, 18, UI.TEXT_DIM, "semi"))
	var friends: Dictionary = Game.profile.friends
	if friends.is_empty():
		_net_list.add_child(UI.label("NO FRIENDS YET: SEARCH A PLAYER'S ID OR NAME, OR TAP ADD FRIEND IN THE ONLINE TAB.", 18, UI.TEXT_DIM, "semi"))
	for id: String in friends:
		if Game.is_blocked(id):
			continue
		var on := cloud.peers.has(id)
		var who := String(friends[id].name) if String(friends[id].name) != "" else "PLAYER"
		var seen := "  ·  " + _ago(int(cloud.directory[id].ts)) if cloud.directory.has(id) else "  ·  OFFLINE"
		var row := _player_row(cloud, id, String(cloud.peers[id].name) if on else who, waiting, "  ·  ONLINE" if on else seen)
		row.add_child(LobbyNet.chat_button(lobby, id, who, "friends"))       # (scripts/lobby_net.gd)
		var rm := UI.button("REMOVE", 16, "dark", Vector2(130, 56))
		rm.name = "FriendRemove"
		rm.pressed.connect(func() -> void:
			# Asked first, as on the player card (it sits right beside DUEL 1 VS 1).
			var back := open.bind("friends", true)
			_place = {"kind": "friends", "scroll": _net_scroll.scroll_vertical if _net_scroll and is_instance_valid(_net_scroll) else 0}
			lobby.dialogs.confirm("REMOVE FRIEND", "Remove %s from your friends? You can send a new friend request later." % who, "REMOVE",
				func() -> void:
					Game.remove_friend(id)
					back.call(), back, true))
		row.add_child(rm)
		_net_list.add_child(row)


# ---------------------------------------------------------------- net signals

## A challenge came in: the popup at once, unless the open one is busy (a question waiting for its
## answer, a text being typed): then it shows as soon as that one closes (the challenge waits 25 s
## for an answer, Cloud.INVITE_TIMEOUT_MS).
func _on_net_invited(who: String) -> void:
	if not invite_team(Game.cloud_service()).is_empty() and not Game.TEAMS_ONLINE:
		Game.cloud_service().answer(false)      # online teams are off in this build
		return
	Audio.play("ui_select", 0.0)
	if bool(Game.settings.get("vibration", true)):
		Input.vibrate_handheld(250)
	if _popup_busy():
		return
	_show_challenge(who)


## The open popup must not be replaced: a confirmation (BLOCK, REMOVE...) or a text field in use.
func _popup_busy() -> bool:
	var m := lobby.dialogs.modal
	if m == null or not is_instance_valid(m):
		return false
	if m.find_child("ConfirmOk", true, false):
		return true
	for le in m.find_children("*", "LineEdit", true, false):
		if (le as LineEdit).has_focus() or String(le.name) in ["NameEdit", "SignatureEdit"]:
			return true
	return false


## A popup closed: a challenge (or a GROUP INVITE) that waited behind it shows now.
func _on_modal_closed() -> void:
	var cloud := Game.cloud_service()
	var free := not lobby.start_btn.disabled and (lobby.dialogs.modal == null or not is_instance_valid(lobby.dialogs.modal))
	if cloud.has_invite() and free:
		_show_challenge(String(cloud.invite_from().get("name", "PLAYER")))
		return
	var gi := cloud.group_invite_from()
	if free and not gi.is_empty():
		_show_group_invite(String(gi.get("name", "PLAYER")))


# ---------------------------------------------------------------- groups

## What GROUP INVITE says.
static func group_invite_text(who: String) -> String:
	return "%s invites you to their group" % who


## A GROUP INVITE came in (Cloud.group_invited): the popup at once, unless the open one is busy or a
## match loads; then it shows when that popup closes (_on_modal_closed), as a duel challenge does.
func _on_group_invited(who: String) -> void:
	Audio.play("ui_select", 0.0)
	if bool(Game.settings.get("vibration", true)):
		Input.vibrate_handheld(250)
	if _popup_busy() or lobby.start_btn.disabled:
		return
	_show_group_invite(who)


## GROUP INVITE: "<NAME> invites you to their group", BLOCK (asked first), DECLINE (also X and
## back) and ACCEPT (Cloud.answer_group_invite(true): this player joins the group; no match starts).
func _show_group_invite(who: String) -> void:
	_net_list = null
	var v := lobby.dialogs.open_modal("GROUP INVITE", 680.0)
	v.name = "GroupInvitePopup"
	var decline := func() -> void:
		Game.cloud_service().answer_group_invite(false)
		lobby.dialogs.close_modal()
	lobby.dialogs.modal.set_meta("on_back", decline)
	var t := UI.label(group_invite_text(who), 26, UI.TEXT, "heavy")
	t.name = "GroupInviteText"
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(600, 0)
	v.add_child(t)
	var sub := UI.label("Up to 4 players. The leader picks the mode and starts: real players only, no bots.", 17, UI.TEXT_DIM, "semi")
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.custom_minimum_size = Vector2(600, 0)
	v.add_child(sub)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var block := UI.button("BLOCK", 18, "dark", Vector2(140, 56))
	block.name = "GroupInviteBlock"
	block.pressed.connect(_ask_block_group_inviter.bind(who))
	var no := UI.button("DECLINE", 20, "light", Vector2(190, 56))
	no.name = "DeclineButton"
	no.pressed.connect(decline)
	var yes := UI.button("ACCEPT", 22, "primary", Vector2(190, 56))
	yes.name = "AcceptButton"
	yes.pressed.connect(func() -> void:
		Game.cloud_service().answer_group_invite(true)
		lobby.dialogs.close_modal())
	row.add_child(block)
	row.add_child(no)
	row.add_child(yes)
	v.add_child(row)


## BLOCK on a GROUP INVITE, asked first: declined and the player blocked; CANCEL goes back to it.
func _ask_block_group_inviter(who: String) -> void:
	var id := String(Game.cloud_service().group_invite_from().get("id", ""))
	var back := func() -> void:
		if not Game.cloud_service().group_invite_from().is_empty():
			_show_group_invite(who)
		else:
			lobby.dialogs.close_modal()
	lobby.dialogs.confirm("BLOCK PLAYER", LobbyProfile.block_question(who), "BLOCK", func() -> void:
		Game.cloud_service().answer_group_invite(false)
		if id != "":
			Game.block(id, who), back, true)


## LONE WOLF DUO / SQUAD searching for real players (after Cloud.group_start said ""): no popup,
## the lobby's search tab (Lobby.search_tab) shows PLAYERS n/N and the time searched while
## Cloud.search_needed > 0; its X (and Android back with no window open) is this. No bots: it waits
## until every place is taken; the session that starts loads the match (_on_net_session).
func cancel_search() -> void:
	Game.cloud_service().group_search_stop()


## The team of the challenge waiting here ({"size", "coop"}: a TEAM INVITE), {} for a duel.
static func invite_team(cloud: Cloud) -> Dictionary:
	var t: Variant = cloud.invite_from().get("team")
	return t as Dictionary if t is Dictionary else {}


## What the challenge popup says: [title, text]; a TEAM INVITE names the team and who plays whom.
static func challenge_text(who: String, team: Dictionary) -> Array:
	if team.is_empty():
		return ["DUEL CHALLENGE", "%s challenges you to a 1 vs 1 duel" % who]
	var size := int(team.get("size", 2))
	var word := "DUO team" if size <= 2 else "SQUAD"
	if not bool(team.get("coop", true)):
		return ["TEAM INVITE", "%s wants a %s match: each of you with bot teammates" % [who, "DUO" if size <= 2 else "SQUAD"]]
	return ["TEAM INVITE", "%s wants you in their %s: YOU TWO %sVS BOTS" % [who, word, "" if size <= 2 else "AND %d BOTS " % (size - 2)]]


## DUEL CHALLENGE (or TEAM INVITE): DECLINE, ACCEPT, and BLOCK for someone who keeps challenging
## (asked first). X and Android back decline too, so the challenger hears at once.
func _show_challenge(who: String) -> void:
	_net_list = null
	var words := challenge_text(who, invite_team(Game.cloud_service()))
	var v := lobby.dialogs.open_modal(String(words[0]), 680.0)
	var decline := func() -> void:
		Game.cloud_service().answer(false)
		lobby.dialogs.close_modal()
	lobby.dialogs.modal.set_meta("on_back", decline)
	var t := UI.label(String(words[1]), 26, UI.TEXT, "heavy")
	t.name = "ChallengeText"
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(t)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var block := UI.button("BLOCK", 18, "dark", Vector2(140, 56))
	block.name = "ChallengeBlock"
	block.pressed.connect(_ask_block_challenger.bind(who))
	var no := UI.button("DECLINE", 20, "light", Vector2(190, 56))
	no.name = "DeclineButton"
	no.pressed.connect(decline)
	var yes := UI.button("ACCEPT", 22, "primary", Vector2(190, 56))
	yes.name = "AcceptButton"
	yes.pressed.connect(func() -> void:
		yes.disabled = true
		UI.set_caption(yes, "CONNECTING")
		Game.cloud_service().answer(true))
	row.add_child(block)
	row.add_child(no)
	row.add_child(yes)
	v.add_child(row)


## BLOCK on a challenge, asked first: the challenge is dropped unanswered and the player blocked
## (Cloud.drop_player, Game.block); CANCEL goes back to the challenge while it still waits.
func _ask_block_challenger(who: String) -> void:
	var cloud := Game.cloud_service()
	var id := String(cloud.invite_from().get("id", ""))
	if id == "":
		lobby.dialogs.close_modal()
		return
	var back := func() -> void:
		if Game.cloud_service().has_invite():
			_show_challenge(who)
		else:
			lobby.dialogs.close_modal()
	lobby.dialogs.confirm("BLOCK PLAYER", LobbyProfile.block_question(who), "BLOCK", func() -> void:
		Game.cloud_service().drop_player(id)
		Game.block(id, who), back, true)


var _seen_requests := {}


func _on_directory_changed() -> void:
	_net_sig = "-"


## The unread count on the lobby's FRIENDS button (top-right), redrawn when it changes.
func _update_badge() -> void:
	var n := NetChat.unread_total()
	if n == _badge_n:
		return
	if lobby.ui == null:
		return
	var row := lobby.ui.find_child("FriendsButton", true, false) as Control
	if row:
		_badge_n = n
		LobbyNet.set_badge(row, n)


## A friend's chat message came in (Cloud.friend_chat_changed, after its checks: friends only,
## FRIENDS CHAT on, never a blocked player): a notice with a soft sound, unless their chat is open
## (it shows the message) or a match is loading.
func _on_friend_message(from: String) -> void:
	_badge_t = 0.0
	if lobby.start_btn.disabled or not Game.is_friend(from) or Game.is_blocked(from) or not bool(Game.settings.get("friend_chat", true)):
		return
	var m := lobby.dialogs.modal
	if m and is_instance_valid(m):
		var chat := m.find_child("ChatWindow", true, false) as LobbyNet
		if chat and chat.id == from:
			return
	var msgs := NetChat.messages(from)
	if msgs.is_empty() or bool(msgs.back()[1]):
		return
	var who := String(((Game.profile.friends as Dictionary)[from] as Dictionary).get("name", "PLAYER"))
	Audio.play("ui_select", -12.0, 1.3)
	LobbyNet.toast(lobby, "%s: %s" % [who, NetChat.first_words(String(msgs.back()[2]))], "TAP TO OPEN",
		func() -> void: LobbyNet.open(lobby, from, who, ""))


## A new friend request shows up at once: a popup with ACCEPT / DECLINE when no window is open,
## a notice at the top (its tap opens the FRIENDS tab) over another popup; with the FRIENDS tab
## open it simply appears in its list. With FRIEND REQUESTS off nothing pops up.
func _on_friends_changed() -> void:
	_net_sig = "-"
	if not Cloud.requests_allowed():
		return
	var cloud := Game.cloud_service()
	for id: String in cloud.friend_requests:
		if _seen_requests.has(id):
			continue
		_seen_requests[id] = true
		Audio.play("ui_select", 0.0)
		if bool(Game.settings.get("vibration", true)):
			Input.vibrate_handheld(120)
		var who := String(cloud.friend_requests[id].name)
		if lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal):
			var listed := _net_kind == "friends" and _net_list != null and is_instance_valid(_net_list)
			if not lobby.start_btn.disabled and not listed:     # another popup: a notice, its tap opens FRIENDS
				LobbyNet.toast(lobby, "FRIEND REQUEST: %s  #%s" % [who, Cloud.friend_code(id)], "TAP TO SEE",
					func() -> void: open("friends"), "v_friend_add")
			return
		_net_list = null
		var v := lobby.dialogs.open_modal("FRIEND REQUEST", 640.0)
		var t := UI.label("%s  #%s wants to be your friend" % [who, Cloud.friend_code(id)], 26, UI.TEXT, "heavy")
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(t)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 12)
		var no := UI.button("DECLINE", 20, "light", Vector2(190, 56))
		no.pressed.connect(func() -> void:
			Game.cloud_service().answer_friend(id, false)
			lobby.dialogs.close_modal())
		var yes := UI.button("ACCEPT", 22, "primary", Vector2(190, 56))
		yes.name = "AcceptFriendButton"
		yes.pressed.connect(func() -> void:
			Game.cloud_service().answer_friend(id, true)
			lobby.dialogs.close_modal())
		row.add_child(no)
		row.add_child(yes)
		v.add_child(row)
		return


func _on_net_invite_cancelled() -> void:
	if lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal) and lobby.dialogs.modal.find_child("AcceptButton", true, false):
		lobby.dialogs.close_modal()


## A challenge this phone accepted never got going (the challenger went away or called it off as
## it was accepted): the popup that said CONNECTING gives way to why.
func _on_net_invite_failed(who: String) -> void:
	_on_net_invite_cancelled()
	_net_note = "%s COULD NOT BE REACHED" % who
	_net_sig = "-"
	if lobby.start_btn.disabled:
		return
	if lobby.dialogs.modal == null or not is_instance_valid(lobby.dialogs.modal):
		lobby.dialogs.notice("DUEL CANCELLED", "%s could not be reached: the duel did not start." % who)


func _on_net_answered(accepted: bool, who: String) -> void:
	lobby.team.on_answered(accepted, who)
	if not accepted:
		_net_note = "%s DECLINED (OR DID NOT ANSWER)" % who
		_net_sig = "-"


## The custom room changed (a player joined, a join attempt ended): redraw the room tab. Out of a
## room (KICK, closed, its host gone: Cloud.room_notice) the lobby says why.
func _on_room_changed() -> void:
	var cloud := Game.cloud_service()
	if cloud.room_notice != "" and not _match_loading:
		var why := cloud.room_notice
		cloud.room_notice = ""
		lobby.dialogs.notice("CUSTOM ROOM", why)
		return
	if _net_kind == "room" and lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal) and _net_list and is_instance_valid(_net_list):
		open("room")


## A room's players or places changed (its group): the room tab follows.
func _on_room_group_changed() -> void:
	var cloud := Game.cloud_service()
	if cloud.room_code != "" or cloud.join_state != "":
		_on_room_changed()


## Both phones agreed (a challenge accepted, the host started a custom room): load the match. It
## is LONE WOLF whatever mode the lobby shows; the arena ignores TRAINING GROUND's dummy choice
## (Game.practice) online, so that choice stays for later. A session a TEAM INVITE started
## (Cloud.session_team) is a team match (session_team_match), any other one the 1 vs 1.
## An all-human match (a GROUP's, Cloud.session_multi) loads the same way, its Game.team_match from
## Cloud.session_roster (TeamArena.link_roster); a member's START may be disabled meanwhile (only the
## leader starts), so only a match this lobby is already loading turns it down.
func _on_net_session(_host: bool) -> void:
	var cloud := Game.cloud_service()
	var busy := _match_loading or (lobby.start_btn.disabled and not cloud.session_multi)
	if busy or (not cloud.session_team.is_empty() and not Game.TEAMS_ONLINE):
		cloud.end_session("left")       # a match is loading already (or online teams are off): tell the other phone
		return
	Game.team_match = session_team_match(cloud)
	if cloud.session_multi and Game.team_match.is_empty():
		cloud.end_session("left")       # (a roster this phone cannot play: not in it, a team empty)
		return
	_match_loading = true
	Game.online = true
	Game.session = cloud
	Game.room_rules = cloud.session_rules.duplicate()
	cloud.close_room()
	cloud.leave_join()
	lobby.close_layers()                # (a window open meanwhile closes: the match loads)
	lobby.start_btn.disabled = true
	UI.set_caption(lobby.start_btn, "LOADING")
	Loading.start_match(lobby)


## The team match of the session that just started, as Game.team_match ({} for a 1 vs 1): both
## phones build the same roster from the same inputs (the host / guest from this profile and
## Cloud.opponent, the seed from the two ids; TeamArena.link_match).
static func session_team_match(cloud: Cloud) -> Dictionary:
	var st: Dictionary = cloud.session_team
	if st.is_empty() or not Game.TEAMS_ONLINE:
		return {}
	if cloud.session_multi:
		return TeamArena.link_roster(4 if int(st.get("size", 2)) == 4 else 2, cloud.session_roster, cloud.my_id, cloud.session_host_id,
			cloud.session_host_id.hash())
	var me := {"id": cloud.my_id, "name": String(Game.profile.name), "bundle": String(Game.profile.bundle)}
	var other := {"id": String(cloud.opponent.get("id", "")), "name": String(cloud.opponent.get("name", "PLAYER")),
		"bundle": String(cloud.opponent.get("bundle", "default"))}
	var host := me if cloud.is_host else other
	var guest := other if cloud.is_host else me
	var size := 4 if int(st.get("size", 2)) == 4 else 2
	return TeamArena.link_match(size, bool(st.get("coop", true)), host, guest, cloud.is_host,
		(String(host.id) + String(guest.id)).hash())


## The session ended while the lobby is up, that is while its match loads: Game.online stays set
## then, so the arena finds the session gone and comes back here with the reason (it would
## otherwise start a match against the bot under the LONE WOLF loading card).
func _on_net_ended(reason: String) -> void:
	_net_note = "THE OTHER PLAYER LEFT" if reason == "left" else "CONNECTION LOST"
	_net_sig = "-"
	if not (Game.online and lobby.start_btn.disabled):
		Game.online = false


func _connect_net(cloud: Cloud) -> void:
	cloud.room_changed.connect(_on_room_changed)
	cloud.friends_changed.connect(_on_friends_changed)
	cloud.directory_changed.connect(_on_directory_changed)
	cloud.invited.connect(_on_net_invited)
	cloud.invite_cancelled.connect(_on_net_invite_cancelled)
	cloud.invite_failed.connect(_on_net_invite_failed)
	cloud.invite_answered.connect(_on_net_answered)
	cloud.session_started.connect(_on_net_session)
	cloud.session_ended.connect(_on_net_ended)
	cloud.friend_chat_changed.connect(_on_friend_message)
	cloud.group_changed.connect(lobby.on_group_changed)
	cloud.group_changed.connect(_on_room_group_changed)
	cloud.group_invited.connect(_on_group_invited)
	lobby.on_group_changed.call_deferred()      # a group from before this lobby (back from a match)


## Drops this object's connections (the handlers above) from the service, which outlives the lobby.
func _disconnect_net(cloud: Cloud) -> void:
	for sig in ["invited", "invite_cancelled", "invite_failed", "invite_answered", "session_started", "session_ended", "room_changed",
			"friends_changed", "directory_changed", "friend_chat_changed", "group_changed", "group_invited"]:
		for c: Dictionary in cloud.get_signal_connection_list(sig):
			var o := (c.callable as Callable).get_object()
			if o == self or o == lobby:
				cloud.disconnect(sig, c.callable)


## The tab PLAY WITHOUT INTERNET changed what it shows (LobbyLan): built again while it is open.
func redraw_local() -> void:
	if _net_kind == "local" and lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal) and _net_list and is_instance_valid(_net_list):
		open("local")
