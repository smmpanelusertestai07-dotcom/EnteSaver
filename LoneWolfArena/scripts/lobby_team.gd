class_name LobbyTeam
extends RefCounted
## The lobby's TEAM bar (DUO / SQUAD; PLAN_TEAMS 8.1): under the player card top-left, the places of
## this player's team after the player: "+ INVITE" (a friend joins), then BOT tiles (bots fill the
## rest: SQUAD has one INVITE and two BOT tiles). Hidden in SOLO and while Game.TEAMS_ONLINE is off
## (bar_shown). INVITE opens the list of friends (TeamInviteList): the ones online now (in
## Cloud.peers) first, each with INVITE, which sends a TEAM INVITE (Cloud.team_invite(id, size,
## true): the two of them, plus bots in SQUAD, against bots; accepting starts the match at once);
## offline friends are greyed; with no friends a note and FRIENDS. Then the popup TEAM INVITE waits:
## "WAITING FOR <NAME>" with CANCEL (Cloud.cancel_invite), "<NAME> DECLINED" when they say no (or
## never answer). Once accepted, LobbyFriends._on_net_session loads the match (TeamArena.link_match).
## The lobby makes it (Lobby.team), builds it with its UI (build), follows SELECT MODE (refresh)
## and calls process() every frame; LobbyFriends hands it the answers (on_answered).
## Node names: TeamBar, TeamHead, TeamInvite, TeamBot_<n>, TeamInviteList, TeamFriend_<code>,
## TeamAsk_<code>, TeamListNote, TeamFriends, TeamWait, TeamWaitCancel.

const TILE_W := 250.0
const ONLINE_GREEN := Color(0.38, 0.86, 0.44)

var lobby: Lobby
var bar: VBoxContainer
var _list: VBoxContainer                 # the open invite list's rows (null when it is not open)
var _list_sig := ""
var _list_note := ""
var _refresh_t := 0.0
var _wait_name := ""                     # the friend the TEAM INVITE waits for ("" when none)
var _wait_label: Label
var _wait_cancel: Button


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


## Whether the TEAM bar shows: DUO or SQUAD, with online teams switched on.
static func bar_shown(size: int, teams_online := Game.TEAMS_ONLINE) -> bool:
	return teams_online and size > 1


## The TEAM bar's places after the player for a team size: "invite" then "bot" ([] in SOLO).
static func tiles_for(size: int) -> Array:
	var out: Array = []
	for i in maxi(size - 1, 0):
		out.append("invite" if i == 0 else "bot")
	return out


func build(root: Control) -> void:
	bar = VBoxContainer.new()
	bar.name = "TeamBar"
	bar.add_theme_constant_override("separation", 6)
	bar.position = Vector2(12, 90)
	bar.custom_minimum_size = Vector2(TILE_W, 0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)
	refresh()


## Follows the team size (SELECT MODE) and whether a TEAM INVITE waits.
func refresh() -> void:
	if bar == null or not is_instance_valid(bar):
		return
	for c in bar.get_children():
		bar.remove_child(c)
		c.queue_free()
	var size := Game.team_size
	bar.visible = bar_shown(size)
	if not bar.visible:
		return
	var head := UI.shadowed(UI.label("YOUR %s" % String(LobbyDialogs.SIZE_NAMES.get(size, "DUO")), 15, UI.TEXT, "heavy"))
	head.name = "TeamHead"
	bar.add_child(head)
	var tiles := tiles_for(size)
	for i in tiles.size():
		if tiles[i] == "invite":
			bar.add_child(_invite_tile(i + 2))
		else:
			bar.add_child(_bot_tile(i + 2))


func _tile_style(bg: Color, edge: Color) -> StyleBoxFlat:
	var st := UI.chamfer(bg, 10, 1, edge, 0.0, ["br"])
	st.content_margin_left = 8
	st.content_margin_right = 12
	st.content_margin_top = 4
	st.content_margin_bottom = 4
	return st


## The place's number in the team, on blue (the player's own team colour in a match).
func _badge(n: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.box(UI.BLUE, 3, 0, Color.TRANSPARENT, 4.0))
	p.custom_minimum_size = Vector2(30, 30)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UI.label(str(n), 18, UI.TEXT, "heavy")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(l)
	return p


func _tile_text(title: String, title_color: Color, sub: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(UI.ellipsis(UI.label(title, 20, title_color, "heavy")))
	v.add_child(UI.ellipsis(UI.label(sub, 12, UI.TEXT_DIM, "bold")))
	return v


## "+ INVITE": a friend into this place (the list of friends); while a TEAM INVITE waits it says who.
func _invite_tile(n: int) -> Button:
	var b := Button.new()
	b.name = "TeamInvite"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(TILE_W, UI.TOUCH_MIN)
	var normal := _tile_style(Color(0.02, 0.02, 0.025, 0.66), Color(UI.ACCENT, 0.55))
	var lit := _tile_style(Color(UI.ACCENT, 0.22), UI.ACCENT)
	for st in ["normal", "focus"]:
		b.add_theme_stylebox_override(st, normal)
	for st in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, lit)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 8
	h.offset_right = -10
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	h.add_child(_badge(n))
	var waiting := _wait_name != ""
	h.add_child(_tile_text("WAITING..." if waiting else "+ INVITE", UI.ACCENT,
		_wait_name if waiting else "A FRIEND ONLINE JOINS"))
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		if _wait_name != "":
			_show_wait()
		else:
			open_list())
	return b


## A place bots fill (not a button: nothing to choose).
func _bot_tile(n: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "TeamBot_%d" % n
	p.add_theme_stylebox_override("panel", _tile_style(Color(0.02, 0.02, 0.025, 0.5), Color(1, 1, 1, 0.12)))
	p.custom_minimum_size = Vector2(TILE_W, UI.TOUCH_MIN)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	h.add_child(_badge(n))
	h.add_child(_tile_text("BOT", UI.TEXT, "FILLS THIS PLACE"))
	return p


# ---------------------------------------------------------------- the invite list

## The friends to invite: [{"id", "name", "online"}], online ones first, then by name; blocked
## players never (`friends`: profile "friends", `online_ids`: Cloud.peers).
static func invite_rows(friends: Dictionary, online_ids: Dictionary) -> Array:
	var out: Array = []
	for id: String in friends:
		if Game.is_blocked(id):
			continue
		var f: Variant = friends[id]
		var who := String((f as Dictionary).get("name", "PLAYER")) if f is Dictionary else "PLAYER"
		out.append({"id": id, "name": who if who != "" else "PLAYER", "online": online_ids.has(id)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.online != b.online:
			return a.online
		return String(a.name) < String(b.name))
	return out


## INVITE: the list of friends (TeamInviteList) with INVITE on the ones online now.
func open_list() -> void:
	var word := String(LobbyDialogs.SIZE_NAMES.get(Game.team_size, "DUO"))
	var v := lobby.dialogs.open_modal("INVITE TO YOUR %s" % word, 760.0)
	var bots := Game.team_size - 2
	var t := UI.label("An online friend joins your team: you two%s against bots. The match starts when they accept." % (
		"" if bots <= 0 else " and %d bots" % bots), 18, UI.TEXT_DIM, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(680, 0)
	v.add_child(t)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(700, 0)
	v.add_child(scroll)
	_list = VBoxContainer.new()
	_list.name = "TeamInviteList"
	_list.add_theme_constant_override("separation", 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)
	_list_sig = ""
	_list_note = ""
	Game.cloud_service().start_lobby()
	_fill_list()


func _fill_list() -> void:
	if _list == null or not is_instance_valid(_list):
		return
	var cloud := Game.cloud_service()
	var rows := invite_rows(Game.profile.friends, cloud.peers)
	var sig := str(rows) + _list_note + cloud.status
	if sig == _list_sig:
		return
	_list_sig = sig
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	if _list_note != "":
		var n := UI.label(_list_note, 17, UI.ACCENT, "bold")
		n.name = "TeamListNote"
		_list.add_child(n)
	if rows.is_empty():
		var none := UI.label("No friends yet. Add players as friends in FRIENDS, then invite them here.", 19, UI.TEXT, "semi")
		none.name = "TeamListNote" if _list_note == "" else "TeamListEmpty"
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		none.custom_minimum_size = Vector2(660, 0)
		_list.add_child(none)
		var fb := UI.button("FRIENDS", 20, "primary", Vector2(220, 56))
		fb.name = "TeamFriends"
		fb.pressed.connect(func() -> void:
			lobby.dialogs.close_modal()
			lobby._open_friends("friends"))
		_list.add_child(fb)
	else:
		var online_n := 0
		for r: Dictionary in rows:
			online_n += 1 if r.online else 0
			_list.add_child(_friend_row(r))
		if online_n == 0:
			var off := UI.label("None of your friends is online right now." if cloud.status == "online" else "CONNECTING...", 16, UI.TEXT_DIM, "bold")
			off.name = "TeamListOffline"
			_list.add_child(off)
	var scroll := _list.get_parent() as ScrollContainer
	if scroll:
		scroll.custom_minimum_size.y = minf(_list.get_combined_minimum_size().y, 330.0)


func _friend_row(r: Dictionary) -> PanelContainer:
	var id := String(r.id)
	var code := Cloud.friend_code(id)
	var p := PanelContainer.new()
	p.name = "TeamFriend_" + code
	var st := UI.chamfer(Color(1, 1, 1, 0.06), 6, 0, Color.TRANSPARENT, 10.0, ["br"])
	st.content_margin_top = 4
	st.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	p.add_child(h)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_child(UI.ellipsis(UI.label(String(r.name), 22, UI.TEXT, "heavy")))
	v.add_child(UI.label("#%s  ·  %s" % [code, "ONLINE" if r.online else "OFFLINE"], 13, ONLINE_GREEN if r.online else UI.TEXT_DIM, "bold"))
	h.add_child(v)
	var ask := UI.button("INVITE", 20, "primary", Vector2(160, 56))
	ask.name = "TeamAsk_" + code
	ask.disabled = not bool(r.online)
	ask.pressed.connect(ask_friend.bind(id, String(r.name)))
	h.add_child(ask)
	if not r.online:
		p.modulate = Color(1, 1, 1, 0.5)
	return p


## TeamAsk_<code>: the TEAM INVITE goes to this friend (a challenge still waiting is called off);
## then the popup waits for the answer.
func ask_friend(id: String, who: String) -> void:
	var cloud := Game.cloud_service()
	if cloud.waiting_for() != "":
		cloud.cancel_invite()
	if not cloud.team_invite(id, Game.team_size, true):
		_list_note = "%s COULD NOT BE REACHED" % who
		_list_sig = ""
		_fill_list()
		return
	_wait_name = who
	_show_wait()
	refresh()


## TEAM INVITE: WAITING FOR <NAME> with CANCEL (X and back cancel too).
func _show_wait() -> void:
	_list = null
	var v := lobby.dialogs.open_modal("TEAM INVITE", 640.0)
	lobby.dialogs.modal.set_meta("on_back", cancel_wait)
	_wait_label = UI.label("WAITING FOR %s" % _wait_name, 28, UI.ACCENT, "heavy")
	_wait_label.name = "TeamWait"
	_wait_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wait_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_wait_label.custom_minimum_size = Vector2(560, 0)
	v.add_child(_wait_label)
	var t := UI.label("The match starts as soon as they accept.", 17, UI.TEXT_DIM, "semi")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	_wait_cancel = UI.button("CANCEL", 22, "dark", Vector2(240, 56))
	_wait_cancel.name = "TeamWaitCancel"
	_wait_cancel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_wait_cancel.pressed.connect(cancel_wait)
	v.add_child(_wait_cancel)


## CANCEL (or X / back) on the waiting popup: the TEAM INVITE is called off; after an answer it is OK.
func cancel_wait() -> void:
	if _wait_name != "":
		Game.cloud_service().cancel_invite()
	_wait_name = ""
	lobby.dialogs.close_modal()
	refresh()


## The answer to this phone's challenge (LobbyFriends hands it on): a TEAM INVITE that was declined
## (or not answered in time) says so in its popup. Accepted: the session starts the match.
func on_answered(accepted: bool, who: String) -> void:
	if _wait_name == "":
		return
	if accepted:
		_wait_name = ""
		return
	_wait_name = ""
	if _wait_label and is_instance_valid(_wait_label):
		_wait_label.text = "%s DECLINED" % who
		UI.set_caption(_wait_cancel, "OK")
	refresh()


func process(delta: float) -> void:
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = 0.5
	if _list and is_instance_valid(_list):
		_fill_list()
	elif _list:
		_list = null
	if _wait_name != "" and Game.cloud and Game.cloud.waiting_for() == "" and not Game.cloud.in_session:
		_wait_name = ""              # the invite went (called off elsewhere)
		refresh()
