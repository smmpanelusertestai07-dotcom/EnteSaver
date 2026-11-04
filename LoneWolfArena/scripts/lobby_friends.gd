class_name LobbyFriends
extends RefCounted
## PLAY WITH FRIENDS in the lobby (Lan / Cloud) and the net services' signals while the lobby is
## open: the challenge popup, a declined or cancelled challenge, the custom room's changes and the
## session that starts an online match. The lobby makes it (Lobby.friends) and calls
## on_lobby_ready() from its _ready, on_lobby_exit() from its _exit_tree and process() every
## frame; popups open through Lobby.dialogs.
## Node names: Tab_<online|friends|room>, NetList, MyId, FriendSearch, FriendAccept,
## FriendDecline, RoomHead, RoomStart, RoomPin, Rule_<key>, RoomCreate, JoinCode, JoinPin,
## RoomJoin, JoinState, AcceptButton.

var lobby: Lobby
var _net_kind := "online"
var _net_list: VBoxContainer
var _net_status: Label
var _net_sig := ""
var _net_note := ""
var _net_refresh_t := 0.0
var _friend_query := ""                # FRIENDS tab search (an ID or a name)
var _room_rules := Cloud.ROOM_RULES.duplicate()     # the next custom room's rules
var _room_pin_draft := ""              # the password typed before a rule button rebuilt the tab
var _room_join_code := ""              # the room this phone asked to join (for its status line)


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


## The lobby is up: listen to both services and go online.
func on_lobby_ready() -> void:
	_connect_net(Game.lan_service())
	_connect_net(Game.cloud_service())
	# Online presence starts with the lobby, so friends and other players see this phone online
	# as soon as the game is open (the same-Wi-Fi mode is gone: no LAN discovery any more).
	Game.cloud_service().start_lobby()


## The lobby is leaving the tree.
func on_lobby_exit() -> void:
	for svc: Node in [Game.lan, Game.cloud]:
		if svc:
			_disconnect_net(svc)
			svc.cancel_invite()
	if Game.lan:
		Game.lan.stop_discovery()
	if Game.cloud:
		if not Game.cloud.in_session:
			Game.cloud.close_room()
			Game.cloud.leave_join()
		# presence stays on through a match: friends keep seeing this phone online


## Every frame: the open list follows the service (players, requests, invites).
func process(delta: float) -> void:
	if _net_list and is_instance_valid(_net_list):
		_net_refresh_t -= delta
		if _net_refresh_t <= 0.0:
			_net_refresh_t = 0.4
			_refresh_friends()


# ---------------------------------------------------------------- play with friends (Lan / Cloud)

## Two ways to find a friend: ONLINE (internet, no account: a free public relay carries
## end-to-end encrypted messages, see Cloud) and SAME WI-FI (no server at all, see Lan). Players
## show up by name; CHALLENGE sends a request, the other phone accepts or declines. The ONLINE
## list connects only once this tab is opened.
func open(kind := "online") -> void:
	_net_kind = kind
	var svc: Node = _net_service()
	if kind != "wifi":
		Game.cloud_service().start_lobby()
	var v := lobby.dialogs.open_modal("PLAY WITH FRIENDS", 980.0)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 10)
	for t: Array in [["online", "ONLINE"], ["friends", "FRIENDS"], ["room", "CUSTOM ROOM"]]:
		var b := UI.button(String(t[1]), 19, "primary" if t[0] == kind else "dark", Vector2(205, 48))
		b.name = "Tab_" + String(t[0])
		var tk := String(t[0])
		b.pressed.connect(func() -> void:
			if tk != _net_kind:
				open(tk))
		tabs.add_child(b)
	v.add_child(tabs)
	var notes := {
		"online": "Everyone playing right now, from anywhere. DUEL 1 VS 1 challenges a player, ADD FRIEND sends a friend request.",
		"friends": "Add players as friends with their ID. Friends who are online can be challenged to a 1 vs 1 duel.",
		"room": "A private room: share its ID and password. The host sets the rules and starts the match.",
		"wifi": "Same Wi-Fi or one phone's hotspot: nearby players show up by name.",
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
	_net_list = VBoxContainer.new()
	_net_list.name = "NetList"
	_net_list.add_theme_constant_override("separation", 8)
	_net_list.custom_minimum_size = Vector2(0, 170 if kind in ["online", "wifi"] else 0)
	v.add_child(_net_list)
	_net_sig = "-"
	_net_note = ""
	if svc:
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
	var copy := UI.button("COPY", 18, "light", Vector2(120, 46))
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
	var go := UI.button("SEARCH", 19, "primary", Vector2(160, 54))
	var search := func() -> void:
		_friend_query = Game.clean_name(le.text)
		_net_sig = "-"
		_refresh_friends()
	go.pressed.connect(search)
	le.text_submitted.connect(func(_t: String) -> void: search.call())
	row.add_child(go)
	v.add_child(row)


## CUSTOM ROOM tab: create one (password, rules) or join one (ID + password); once in a room it
## shows the room's ID, password and players, and the host's START.
func _build_room_tab(v: VBoxContainer) -> void:
	var cloud := Game.cloud_service()
	if cloud.room_code != "":
		var head := UI.label("ROOM ID  %s     PASSWORD  %s" % [cloud.room_code, cloud.room_pin], 30, UI.TEXT, "heavy")
		head.name = "RoomHead"
		v.add_child(head)
		v.add_child(UI.label(_rules_text(cloud.room_rules), 18, UI.TEXT_DIM, "semi"))
		var slots := HBoxContainer.new()
		slots.add_theme_constant_override("separation", 14)
		var guest := String(cloud.room_guest.get("name", ""))
		for t: Array in [[String(Game.profile.name) + "  (HOST)", UI.ACCENT], [guest if guest != "" else "WAITING FOR A PLAYER...", UI.TEXT if guest != "" else UI.TEXT_DIM]]:
			var slot := UI.label(String(t[0]), 22, t[1], "bold")
			slot.custom_minimum_size = Vector2(420, 54)
			slot.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			slot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			slot.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.45), 8, 1, Color(1, 1, 1, 0.2), 12.0, ["br"]))
			slots.add_child(slot)
		v.add_child(slots)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 12)
		var close := UI.button("CLOSE ROOM", 19, "light", Vector2(200, 52))
		close.pressed.connect(func() -> void:
			Game.cloud_service().close_room()
			open("room"))
		var start := UI.button("START", 22, "primary", Vector2(200, 52))
		start.name = "RoomStart"
		start.disabled = guest == ""
		start.pressed.connect(func() -> void:
			start.disabled = true
			UI.set_caption(start, "STARTING")
			if not Game.cloud_service().start_room_match():
				_net_note = "COULD NOT START, TRY AGAIN"
				start.disabled = false)
		row.add_child(close)
		row.add_child(start)
		v.add_child(row)
		return
	if cloud.join_state != "":
		var msg := {"asking": "JOINING ROOM %s...", "in": "IN ROOM %s: WAITING FOR THE HOST TO START",
			"wrong": "WRONG PASSWORD FOR ROOM %s", "none": "NO ROOM %s FOUND (OR ITS HOST LEFT)"}
		var st := UI.label(String(msg.get(cloud.join_state, "%s")) % String(_room_join_code), 24, UI.TEXT, "heavy")
		st.name = "JoinState"
		v.add_child(st)
		var back := UI.button("LEAVE" if cloud.join_state in ["asking", "in"] else "BACK", 19, "light", Vector2(200, 52))
		back.pressed.connect(func() -> void:
			Game.cloud_service().leave_join()
			open("room"))
		v.add_child(back)
		return
	# Create: password (digits), rules.
	var create := HBoxContainer.new()
	create.add_theme_constant_override("separation", 10)
	create.add_child(UI.label("NEW ROOM  ·  PASSWORD", 20, UI.TEXT, "bold"))
	var pin := _text_field("4-6 DIGITS", 6, true)
	pin.name = "RoomPin"
	pin.text = "%04d" % randi_range(0, 9999)
	pin.custom_minimum_size = Vector2(170, 54)
	pin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	create.add_child(pin)
	var mode := UI.label("1 VS 1", 20, UI.ACCENT, "heavy")
	create.add_child(mode)
	v.add_child(create)
	var rules := HBoxContainer.new()
	rules.add_theme_constant_override("separation", 8)
	for k: Array in [["ammo", "UNLIMITED AMMO"], ["walls", "UNLIMITED WALLS"], ["frags", "UNLIMITED FRAGS"]]:
		var key := String(k[0])
		var tb := UI.button(String(k[1]), 16, "primary" if bool(_room_rules[key]) else "dark", Vector2(190, 46))
		tb.name = "Rule_" + key
		tb.pressed.connect(func() -> void:
			_room_rules[key] = not bool(_room_rules[key])
			_room_pin_draft = pin.text
			open("room"))
		rules.add_child(tb)
	var rounds := UI.button("FIRST TO %d" % int(_room_rules.rounds), 16, "light", Vector2(150, 46))
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
	var make := UI.button("CREATE ROOM", 20, "primary", Vector2(230, 52))
	make.name = "RoomCreate"
	make.pressed.connect(func() -> void:
		var p := pin.text
		if p.length() < 4:
			_net_note = "THE PASSWORD NEEDS 4 TO 6 DIGITS"
			_net_sig = "-"
			return
		_room_pin_draft = ""
		Game.cloud_service().open_room(p, _room_rules)
		open("room"))
	v.add_child(make)
	v.add_child(UI.label("2 VS 2 and 4 VS 4 rooms (8 slots) need team matches, which are not in this version yet.", 15, UI.TEXT_DIM, "semi"))
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
	var go := UI.button("JOIN", 20, "primary", Vector2(150, 54))
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
	le.custom_minimum_size = Vector2(150, 54)
	le.virtual_keyboard_enabled = true
	le.virtual_keyboard_show_on_focus = true
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER if digits_only else LineEdit.KEYBOARD_TYPE_DEFAULT
	le.add_theme_font_override("font", UI.font("bold"))
	le.add_theme_font_size_override("font_size", 24)
	le.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.25), 14.0, ["br"]))
	le.add_theme_stylebox_override("focus", UI.chamfer(Color(0, 0, 0, 0.5), 8, 2, UI.ACCENT, 14.0, ["br"]))
	le.add_theme_color_override("font_color", UI.TEXT)
	le.add_theme_color_override("caret_color", UI.ACCENT)
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


func _net_service() -> Node:
	return (Game.lan_service() as Node) if _net_kind == "wifi" else (Game.cloud_service() as Node)


func _refresh_friends() -> void:
	if _net_list == null or not is_instance_valid(_net_list):
		return
	var svc: Node = _net_service()
	var waiting := String(svc.waiting_for())
	var peers: Dictionary = svc.peers
	var cloud := svc as Cloud
	if _net_kind != "wifi" and String(svc.status) != "online":
		match String(svc.status):
			"preparing":
				_net_status.text = "GETTING READY..."
			"connecting":
				_net_status.text = "CONNECTING..."
			_:
				_net_status.text = "NO INTERNET: RETRYING..."
	elif _net_kind == "wifi" and String(svc.local_address()) == "":
		_net_status.text = "NOT ON WI-FI: JOIN A WI-FI NETWORK OR A HOTSPOT"
	elif waiting != "":
		_net_status.text = "WAITING FOR %s TO ACCEPT..." % waiting
	elif _net_note != "":
		_net_status.text = _net_note
	elif _net_kind == "friends":
		_net_status.text = "%d FRIEND REQUEST%s" % [cloud.friend_requests.size(), "" if cloud.friend_requests.size() == 1 else "S"] \
			if not cloud.friend_requests.is_empty() else "FRIENDS"
	elif _net_kind == "room":
		_net_status.text = "ROOM OPEN: SHARE ITS ID AND PASSWORD" if cloud.room_code != "" else ""
	elif peers.is_empty():
		_net_status.text = "LOOKING FOR PLAYERS ONLINE..." if _net_kind == "online" else "LOOKING FOR PLAYERS ON THIS WI-FI..."
	else:
		_net_status.text = "PLAYERS ONLINE" if _net_kind == "online" else "PLAYERS NEARBY"
	if _net_kind == "room":
		return
	if _net_kind == "friends" and lobby.dialogs.modal and cloud.my_id != "":
		var my := lobby.dialogs.modal.find_child("MyId", true, false) as Label
		if my:
			my.text = "YOUR ID:  %s" % Cloud.friend_code(cloud.my_id)     # the key may be made after the tab opened
	var sig := waiting + "|" + _net_kind + "|" + _friend_query
	for id in peers:
		sig += "|%s:%s" % [id, peers[id].name]
	if cloud:
		sig += "|f%d|r%s" % [(Game.profile.friends as Dictionary).size(), ",".join(PackedStringArray(cloud.friend_requests.keys()))]
		for id in peers:
			sig += ",a" if cloud.friend_asked(String(id)) else ""
	if sig == _net_sig:
		return
	_net_sig = sig
	for c in _net_list.get_children():
		c.queue_free()
	if _net_kind == "friends":
		_fill_friends(cloud, waiting)
		return
	for id: String in peers:
		_net_list.add_child(_player_row(svc, id, String(peers[id].name), waiting))


## One player in a list: name and code, ADD (online, not yet a friend) and CHALLENGE.
func _player_row(svc: Node, id: String, who: String, waiting: String, online_tag := "") -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var label := "%s  #%s" % [who, Cloud.friend_code(id) if svc is Cloud else id.left(4).to_upper()]
	var name_l := UI.label(label + online_tag, 24, UI.TEXT, "heavy")
	name_l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_l)
	var cloud := svc as Cloud
	if cloud and not Game.is_friend(id) and cloud.peers.has(id):
		var asked := cloud.friend_asked(id)
		var add := UI.button("ASKED" if asked else "ADD FRIEND", 17, "dark" if asked else "light", Vector2(170, 52))
		add.disabled = asked
		add.pressed.connect(func() -> void:
			if not Game.cloud_service().request_friend(id):
				_net_note = "COULD NOT SEND THE REQUEST, TRY AGAIN"
			_net_sig = "-"
			_refresh_friends())
		row.add_child(add)
	if svc.peers.has(id):
		var b := UI.button("CANCEL" if waiting != "" else "DUEL 1 VS 1", 19, "light" if waiting != "" else "primary", Vector2(210, 52))
		b.pressed.connect(func() -> void:
			var sv: Node = _net_service()
			_net_note = ""
			if String(sv.waiting_for()) != "":
				sv.cancel_invite()
			elif not bool(sv.invite(id)):
				_net_note = "COULD NOT SEND THE REQUEST, TRY AGAIN"
			_net_sig = "-"
			_refresh_friends())
		row.add_child(b)
	return row


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
			var b := UI.button(String(a[0]), 18, String(a[2]), Vector2(150, 50))
			b.name = "Friend" + String(a[0]).capitalize()
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
			if Cloud.friend_code(id).begins_with(_friend_query) or who.contains(_friend_query):
				_net_list.add_child(_player_row(cloud, id, who, waiting, "  ·  ONLINE"))
				found += 1
		if found == 0:
			_net_list.add_child(UI.label("NOBODY ONLINE MATCHES \"%s\"" % _friend_query, 18, UI.TEXT_DIM, "semi"))
	var friends: Dictionary = Game.profile.friends
	if friends.is_empty():
		_net_list.add_child(UI.label("NO FRIENDS YET: SEARCH A PLAYER'S ID OR NAME, OR TAP ADD FRIEND IN THE ONLINE TAB.", 18, UI.TEXT_DIM, "semi"))
	for id: String in friends:
		var on := cloud.peers.has(id)
		var who := String(friends[id].name) if String(friends[id].name) != "" else "PLAYER"
		var row := _player_row(cloud, id, String(cloud.peers[id].name) if on else who, waiting, "  ·  ONLINE" if on else "  ·  OFFLINE")
		var rm := UI.button("REMOVE", 16, "dark", Vector2(130, 52))
		rm.pressed.connect(func() -> void:
			Game.remove_friend(id)
			_net_sig = "-"
			_refresh_friends())
		row.add_child(rm)
		_net_list.add_child(row)


# ---------------------------------------------------------------- net signals

func _on_net_invited(who: String, svc: Node) -> void:
	_net_list = null
	Audio.play("ui_select", 0.0)
	if bool(Game.settings.get("vibration", true)):
		Input.vibrate_handheld(250)
	var v := lobby.dialogs.open_modal("DUEL CHALLENGE", 640.0)
	var t := UI.label("%s challenges you to a 1 vs 1 duel" % who, 26, UI.TEXT, "heavy")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(t)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var no := UI.button("DECLINE", 20, "light", Vector2(190, 52))
	no.pressed.connect(func() -> void:
		svc.answer(false)
		lobby.dialogs.close_modal())
	var yes := UI.button("ACCEPT", 22, "primary", Vector2(190, 52))
	yes.name = "AcceptButton"
	yes.pressed.connect(func() -> void:
		yes.disabled = true
		UI.set_caption(yes, "CONNECTING")
		svc.answer(true))
	row.add_child(no)
	row.add_child(yes)
	v.add_child(row)


var _seen_requests := {}


## A new friend request shows up at once: a popup with ACCEPT / DECLINE when no window is open
## (with the FRIENDS tab open it simply appears in its list).
func _on_friends_changed() -> void:
	_net_sig = "-"
	var cloud := Game.cloud_service()
	for id: String in cloud.friend_requests:
		if _seen_requests.has(id):
			continue
		_seen_requests[id] = true
		Audio.play("ui_select", 0.0)
		if bool(Game.settings.get("vibration", true)):
			Input.vibrate_handheld(120)
		if lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal):
			return
		var who := String(cloud.friend_requests[id].name)
		_net_list = null
		var v := lobby.dialogs.open_modal("FRIEND REQUEST", 640.0)
		var t := UI.label("%s  #%s wants to be your friend" % [who, Cloud.friend_code(id)], 26, UI.TEXT, "heavy")
		t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(t)
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END
		row.add_theme_constant_override("separation", 12)
		var no := UI.button("DECLINE", 20, "light", Vector2(190, 52))
		no.pressed.connect(func() -> void:
			Game.cloud_service().answer_friend(id, false)
			lobby.dialogs.close_modal())
		var yes := UI.button("ACCEPT", 22, "primary", Vector2(190, 52))
		yes.name = "AcceptFriendButton"
		yes.pressed.connect(func() -> void:
			Game.cloud_service().answer_friend(id, true)
			lobby.dialogs.close_modal())
		row.add_child(no)
		row.add_child(yes)
		v.add_child(row)
		return


func _on_net_invite_cancelled(_svc: Node) -> void:
	if lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal) and lobby.dialogs.modal.find_child("AcceptButton", true, false):
		lobby.dialogs.close_modal()


func _on_net_answered(accepted: bool, who: String, _svc: Node) -> void:
	if not accepted:
		_net_note = "%s DECLINED (OR DID NOT ANSWER)" % who
		_net_sig = "-"


## The custom room changed (a player joined, a join attempt ended): redraw the room tab.
func _on_room_changed() -> void:
	if _net_kind == "room" and lobby.dialogs.modal and is_instance_valid(lobby.dialogs.modal) and _net_list and is_instance_valid(_net_list):
		open("room")


func _on_net_session(_host: bool, svc: Node) -> void:
	if lobby.start_btn.disabled:
		return
	Game.practice = false
	Game.online = true
	Game.session = svc
	var rules: Variant = svc.get("session_rules")
	Game.room_rules = (rules as Dictionary).duplicate() if rules is Dictionary else {}
	if svc is Cloud:
		(svc as Cloud).close_room()
		(svc as Cloud).leave_join()
	lobby.dialogs.close_modal()
	lobby.start_btn.disabled = true
	UI.set_caption(lobby.start_btn, "MATCHING")
	Loading.start_match(lobby)


func _on_net_ended(reason: String, _svc: Node) -> void:
	Game.online = false
	_net_note = "CONNECTION LOST" if reason == "left" else reason.to_upper()
	_net_sig = "-"


func _connect_net(svc: Node) -> void:
	if svc is Cloud:
		(svc as Cloud).room_changed.connect(_on_room_changed)
		(svc as Cloud).friends_changed.connect(_on_friends_changed)
	svc.invited.connect(_on_net_invited.bind(svc))
	svc.invite_cancelled.connect(_on_net_invite_cancelled.bind(svc))
	svc.invite_answered.connect(_on_net_answered.bind(svc))
	svc.session_started.connect(_on_net_session.bind(svc))
	svc.session_ended.connect(_on_net_ended.bind(svc))


## Drops this object's connections (the handlers above, the lambda too) from a service.
func _disconnect_net(svc: Node) -> void:
	for sig in ["invited", "invite_cancelled", "invite_answered", "session_started", "session_ended", "room_changed", "friends_changed"]:
		if not svc.has_signal(sig):
			continue
		for c: Dictionary in svc.get_signal_connection_list(sig):
			if (c.callable as Callable).get_object() == self:
				svc.disconnect(sig, c.callable)
