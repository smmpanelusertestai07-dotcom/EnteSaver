class_name LobbyLan
extends RefCounted
## The ONLINE window's tab PLAY WITHOUT INTERNET (Tab_local, scripts/lan.gd): two phones on the same
## Wi-Fi, or one phone's hotspot that the other joins. HOST shows a pairing code and waits; JOIN
## lists the hosts it finds, a tap on one asks for its code (CONNECT). The match is LONE WOLF, the
## same flow and results as online, marked LOCAL. LobbyFriends makes it (LobbyFriends.lan) and
## builds the tab through build(), status_text() and fill(); the Lan's signals are listened to from
## the first time the tab opens until the lobby leaves (on_lobby_exit).
## Node names: LanHost, LanJoin, LanStop, LanCode, LanHost_<n> (a found host's row), LanCodeField,
## LanConnect, LanAddress.

var friends: LobbyFriends
var lobby: Lobby
var note := ""                     # what went wrong last (a wrong code, the host left)
var _picked := ""                  # JOIN: the host whose code is being typed
var _code_draft := ""
var _connected := false

const GUIDE := "One phone: turn on hotspot. Other phone: join it. Mobile data can stay off. (Both on the same Wi-Fi works too.)"


func _init(by: LobbyFriends) -> void:
	friends = by
	lobby = by.lobby


func service() -> Lan:
	var lan := Game.lan_service()
	if not _connected:
		_connected = true
		lan.hosts_changed.connect(_redraw)
		lan.code_changed.connect(_redraw)
		lan.pair_failed.connect(_on_pair_failed)
		lan.invite_failed.connect(_on_invite_failed)
		lan.session_started.connect(_on_session)
		lan.session_ended.connect(_on_ended)
	return lan


## The lobby is leaving: discovery stops (a match that starts keeps its connection).
func on_lobby_exit() -> void:
	var lan := Game.lan
	if lan == null:
		friends = null
		return
	if not lan.in_session:
		lan._leave_room()
	lan.stop()
	for sig in ["hosts_changed", "code_changed", "pair_failed", "invite_failed", "session_started", "session_ended"]:
		for c: Dictionary in lan.get_signal_connection_list(sig):
			if (c.callable as Callable).get_object() == self:
				lan.disconnect(sig, c.callable)
	_connected = false
	friends = null                  # (LobbyFriends holds this one: no reference cycle left behind)


## Another tab or the window closed: HOST / JOIN stop.
func on_tab_closed() -> void:
	if Game.lan and not Game.lan.in_session:
		Game.lan._leave_room()
		Game.lan.stop()
	_picked = ""


## The tab's head: the guidance, HOST / JOIN (or what this phone is doing), the code.
func build(v: VBoxContainer) -> void:
	var lan := service()
	if Lan.local_address() == "" and Game.autotest == "":
		var off := UI.label("NOT ON WI-FI: turn on this phone's hotspot, or join the other phone's hotspot or the same Wi-Fi.", 18, UI.ACCENT, "bold")
		off.name = "LanAddress"
		off.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(off)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	if lan.role == "" and not lan.getting_ready():
		var h := UI.button("HOST", 22, "primary", Vector2(260, 64))
		h.name = "LanHost"
		h.pressed.connect(func() -> void:
			note = "" if service().host() else "COULD NOT OPEN THE GAME HERE: TRY AGAIN"
			_redraw())
		row.add_child(h)
		var j := UI.button("JOIN", 22, "light", Vector2(260, 64))
		j.name = "LanJoin"
		j.pressed.connect(func() -> void:
			note = "" if service().seek() else "COULD NOT LOOK FOR GAMES HERE: TRY AGAIN"
			_picked = ""
			_redraw())
		row.add_child(j)
	else:
		if lan.role == "host":
			var c := UI.label("CODE  %s" % (lan.code if lan.code != "" else "----"), 40, UI.TEXT, "heavy")
			c.name = "LanCode"
			c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(c)
		else:
			var t := UI.label("GAMES ON THIS NETWORK", 22, UI.TEXT, "heavy")
			t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(t)
		var s := UI.button("CANCEL", 19, "dark", Vector2(170, 56))
		s.name = "LanStop"
		s.pressed.connect(func() -> void:
			on_tab_closed()
			note = ""
			_redraw())
		row.add_child(s)
	v.add_child(row)
	if lan.role == "host":
		var tell := UI.label("Tell the other player this code. They tap JOIN, pick %s and type it." % String(Game.profile.name), 17, UI.TEXT_DIM, "semi")
		tell.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(tell)
	if lan.role == "join" and _picked != "" and lan.hosts.has(_picked):
		var r := HBoxContainer.new()
		r.add_theme_constant_override("separation", 10)
		var le: LineEdit = friends._text_field("%s'S CODE" % String(lan.hosts[_picked].name), Lan.CODE_DIGITS, true)
		le.name = "LanCodeField"
		le.text = _code_draft
		le.text_changed.connect(func(t: String) -> void: _code_draft = t)
		r.add_child(le)
		var go := UI.button("CONNECT", 20, "primary", Vector2(190, 56))
		go.name = "LanConnect"
		var go_on := func() -> void: _connect_to(le.text)
		go.pressed.connect(go_on)
		le.text_submitted.connect(func(_t: String) -> void: go_on.call())
		r.add_child(go)
		v.add_child(r)


## The status line under the tabs.
func status_text() -> String:
	var lan := Game.lan
	if lan == null:
		return note
	if lan.paired_with() != "":
		return "CONNECTING TO %s..." % lan.paired_with() if not lan.is_host else "%s IS JOINING..." % lan.paired_with()
	if note != "":
		return note
	if lan.getting_ready():
		return "GETTING READY..."
	if lan.role == "host":
		return "WAITING FOR THE OTHER PHONE..."
	if lan.role == "join":
		return "LOOKING FOR GAMES..." if lan.hosts.is_empty() else "TAP A GAME, THEN TYPE ITS CODE"
	return "PLAY WITHOUT INTERNET"


## What the list shows (redrawn when it changes).
func signature() -> String:
	var lan := Game.lan
	if lan == null:
		return "none"
	var s := "%s|%s|%s|%s|%s" % [lan.role, lan.code, _picked, lan.paired_with(), lan.getting_ready()]
	for id in lan.hosts:
		s += "|%s:%s" % [id, lan.hosts[id].name]
	return s


## JOIN's list: every host found, a tap picks it (its code is typed above).
func fill(list: VBoxContainer) -> void:
	var lan := Game.lan
	if lan == null or lan.role != "join":
		return
	var i := 0
	for id: String in lan.hosts:
		var h: Dictionary = lan.hosts[id]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var t := UI.label("%s   #%s" % [String(h.name), Cloud.friend_code(id)], 22, UI.TEXT, "bold")
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(t)
		var b := UI.button("PICKED" if id == _picked else "JOIN", 19, "dark" if id == _picked else "primary", Vector2(170, 56))
		b.name = "LanHost_%d" % i
		b.pressed.connect(func() -> void:
			_picked = id
			_code_draft = ""
			note = ""
			_redraw())
		row.add_child(b)
		list.add_child(row)
		i += 1


func _connect_to(text: String) -> void:
	var lan := service()
	if text.strip_edges().length() != Lan.CODE_DIGITS:
		note = "THE CODE HAS %d DIGITS" % Lan.CODE_DIGITS
	elif not lan.join(_picked, text):
		note = "THAT GAME IS GONE: TAP JOIN AGAIN" if not lan.hosts.has(_picked) else "COULD NOT CONNECT: TRY AGAIN"
	else:
		note = ""
	_redraw()


func _redraw() -> void:
	if friends:
		friends.redraw_local()


func _on_pair_failed(why: String) -> void:
	note = {"code": "WRONG CODE: ASK FOR IT AGAIN", "busy": "THAT GAME IS BUSY"}.get(why, "THE OTHER PHONE WENT AWAY")
	_code_draft = ""
	_redraw()


func _on_invite_failed(who: String) -> void:
	note = "%s COULD NOT BE REACHED" % who
	_redraw()


## Both phones are paired: the match loads as an online one does (LobbyFriends._on_net_session).
func _on_session(_host: bool) -> void:
	var lan := Game.lan
	if lobby.start_btn.disabled:
		lan.end_session("left")         # a match against the bot is loading already: tell the other phone
		return
	Game.team_match = {}                # PLAY WITHOUT INTERNET is the 1 vs 1 (no team matches over LAN yet)
	lan.stop()
	Game.online = true
	Game.session = lan
	Game.room_rules = {}
	lobby.dialogs.close_modal()
	lobby.start_btn.disabled = true
	UI.set_caption(lobby.start_btn, "LOADING")
	Loading.start_match(lobby)


func _on_ended(reason: String) -> void:
	note = "THE OTHER PLAYER LEFT" if reason == "left" else "CONNECTION LOST"
	if not (Game.online and lobby.start_btn.disabled):
		Game.online = false
	_redraw()
