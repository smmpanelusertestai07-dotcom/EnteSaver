class_name LobbyTeam
extends RefCounted
## The lobby's GROUP bar (LONE WOLF, design/GROUPS.txt 1): under the player card top-left. Up to
## GROUP_MAX (4) players: the first invite makes this player the LEADER. The bar lists the members
## (leader first, then in join order: GroupMember_<n>, a LEADER tag on the leader, YOU on this
## player), the leader's REMOVE on each other member (GroupRemove_<n>), "+ INVITE" (GroupInvite:
## the leader's, or a solo's, while the group is not full; greyed otherwise), TEAMS (GroupTeams: the
## BLUE / ORANGE slot panel, the leader moves members, the others see it), and EXIT GROUP
## (GroupExit, a member) or DISBAND GROUP (GroupDisband, the leader). INVITE opens the list of online
## friends (GroupInviteList: Cloud.peers ∩ friends, never blocked ones; GroupAsk_<code> ->
## Cloud.group_invite(id)), then a popup says INVITED <NAME> and how they answered (GroupInvited).
## Hidden while Game.TEAMS_ONLINE is off, and outside LONE WOLF unless the player is in a group.
## The lobby makes it (Lobby.team), builds it (build), redraws it on Cloud.group_changed and on
## SELECT MODE (refresh) and calls process() every frame; LobbyFriends hands it a declined invite
## (on_answered).
## It reads and calls Cloud's group API (GROUPS.txt 3) through the helpers below (group / members /
## in_group / is_leader / group_max / search_progress). A CUSTOM ROOM with slots is a group too
## (Cloud.in_room): its players show in the room's own slot panel (LobbyFriends), not in this bar.
## Node names: GroupBar, GroupHead, GroupMember_<n>, GroupRemove_<n>, GroupInvite, GroupTeams,
## GroupExit, GroupDisband, GroupInviteList, GroupFriend_<code>, GroupAsk_<code>, GroupListNote,
## GroupFriends, GroupInvited, GroupInvitedOk, GroupTeamPanel (with a SlotPanel).

const TILE_W := 280.0
const ONLINE_GREEN := Color(0.38, 0.86, 0.44)
const GROUP_MAX_DEFAULT := 4

var lobby: Lobby
var bar: VBoxContainer
var _list: VBoxContainer                 # the open invite list's rows (null when it is not open)
var _list_sig := ""
var _list_note := ""
var _refresh_t := 0.0
var _sig := ""                           # what the bar shows now (redrawn only when it changes)
var _invited_id := ""                    # the friend the last GROUP INVITE went to
var _invited_name := ""
var _invited_label: Label
var _slot_panel: SlotPanel               # the open TEAMS popup's panel


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


# ---------------------------------------------------------------- the Cloud group API

## Cloud.group: {} | {"gid", "leader", "members", "status", "mode", "size"} (+ "room" in a room).
static func group() -> Dictionary:
	return Game.cloud_service().group


## Cloud.group_members(): [{"id", "name", "bundle", "leader", "me", "team", "slot"}], leader first.
static func members() -> Array:
	return Game.cloud_service().group_members()


static func in_group() -> bool:
	return Game.cloud_service().in_group()


## True when not in a group too (a solo leads itself).
static func is_leader() -> bool:
	return Game.cloud_service().is_group_leader()


## In a group and not its leader: START and SELECT MODE are the leader's.
static func is_member() -> bool:
	return in_group() and not is_leader()


static func group_max() -> int:
	return Cloud.GROUP_MAX


## The search's progress: [found, needed] (needed 0: not searching).
static func search_progress() -> Array:
	var c := Game.cloud_service()
	return [c.search_found, c.search_needed]


## The leader's name (the member marked leader), "" outside a group.
static func leader_name(list: Array) -> String:
	for m: Dictionary in list:
		if bool(m.get("leader", false)):
			return String(m.get("name", "PLAYER"))
	return ""


# ---------------------------------------------------------------- pure rules (unit tested)

## Whether the GROUP bar shows: online teams on, and LONE WOLF picked or already in a group.
static func bar_shown(m: String, grouped: bool, teams_online := Game.TEAMS_ONLINE) -> bool:
	return teams_online and (m == "lonewolf" or grouped)


## What the bar offers this player: {"invite": shown, "invite_on": tappable, "exit", "disband",
## "remove": the leader's REMOVE on other members, "teams": TEAMS shown}.
static func bar_actions(grouped: bool, leader: bool, count: int, size: int, max_n := GROUP_MAX_DEFAULT) -> Dictionary:
	return {"invite": true, "invite_on": leader and count < max_n, "exit": grouped and not leader,
		"disband": grouped and leader, "remove": grouped and leader, "teams": grouped and size > 1}


## What sits in START's place: "" (START works) or the line a member sees.
static func start_gate_text(grouped: bool, leader: bool, leader_n: String, searching := Vector2i.ZERO) -> String:
	if not grouped or leader:
		return ""
	if searching.y > 0:
		return "SEARCHING PLAYERS %d/%d" % [searching.x, searching.y]
	return "WAITING FOR %s TO START" % (leader_n if leader_n != "" else "THE LEADER")


## The search popup's count line.
static func search_text(found: int, needed: int) -> String:
	if needed <= 0:
		return "STARTING MATCH..."
	return "SEARCHING PLAYERS %d/%d" % [clampi(found, 0, needed), needed]


## The friends to invite: [{"id", "name", "online"}], online ones first, then by name; blocked
## players never (`friends`: profile "friends", `online_ids`: Cloud.peers); members left out.
static func invite_rows(friends: Dictionary, online_ids: Dictionary, in_group_ids: Array = []) -> Array:
	var out: Array = []
	for id: String in friends:
		if Game.is_blocked(id) or in_group_ids.has(id):
			continue
		var f: Variant = friends[id]
		var who := String((f as Dictionary).get("name", "PLAYER")) if f is Dictionary else "PLAYER"
		out.append({"id": id, "name": who if who != "" else "PLAYER", "online": online_ids.has(id)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.online != b.online:
			return a.online
		return String(a.name) < String(b.name))
	return out


## The teams a group shows in TEAMS: [{"id", "name", "team", "slot", "host", "me"}] for a size
## (players a team). A member's own "team" / "slot" (set_group_team) wins; the rest fill in join
## order: DUO BLUE = leader + first member, ORANGE = the next two; SQUAD all BLUE.
static func team_entries(list: Array, size: int) -> Array:
	var per := NetGroup.per_team(size)
	var taken := {}
	var out: Array = []
	for m: Dictionary in list:
		if m.has("team") and m.has("slot"):
			var t := clampi(int(m.team), 0, 1)
			var s := clampi(int(m.slot) - t * per, 0, per - 1)     # (Cloud's slot is the roster's: team * per + place)
			if not taken.has("%d_%d" % [t, s]):
				taken["%d_%d" % [t, s]] = true
				out.append(_entry(m, t, s))
	var k := 0
	for m: Dictionary in list:
		if m.has("team") and m.has("slot") and out.any(func(e: Dictionary) -> bool: return e.id == String(m.get("id", ""))):
			continue
		while k < per * 2 and taken.has("%d_%d" % [k / per, k % per]):
			k += 1
		if k >= per * 2:
			break
		taken["%d_%d" % [k / per, k % per]] = true
		out.append(_entry(m, k / per, k % per))
	return out


static func _entry(m: Dictionary, t: int, s: int) -> Dictionary:
	return {"id": String(m.get("id", "")), "name": String(m.get("name", "PLAYER")), "team": t, "slot": s,
		"host": bool(m.get("leader", false)), "me": bool(m.get("me", false))}


# ---------------------------------------------------------------- the bar

func build(root: Control) -> void:
	bar = VBoxContainer.new()
	bar.name = "GroupBar"
	bar.add_theme_constant_override("separation", 6)
	bar.position = Vector2(12, 90)
	bar.custom_minimum_size = Vector2(TILE_W, 0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)
	refresh()


## Follows the group (Cloud.group_changed), SELECT MODE and the invite list.
func refresh() -> void:
	if bar == null or not is_instance_valid(bar):
		return
	var list := members()
	var grouped := in_group()
	var leader := is_leader()
	var sig := "%s|%s|%s|%d|%s|%s" % [str(list), grouped, leader, Game.team_size, Game.mode, _invited_id]
	if sig == _sig:
		return
	_sig = sig
	for c in bar.get_children():
		bar.remove_child(c)
		c.queue_free()
	bar.visible = bar_shown(Game.mode, grouped) and not Game.cloud_service().in_room()
	if not bar.visible:
		return
	var acts := bar_actions(grouped, leader, list.size(), Game.team_size, group_max())
	var head := UI.shadowed(UI.label("YOUR GROUP  %d/%d" % [maxi(list.size(), 1), group_max()], 15, UI.TEXT, "heavy"))
	head.name = "GroupHead"
	bar.add_child(head)
	for i in list.size():
		bar.add_child(_member_tile(i + 1, list[i], bool(acts.remove)))
	bar.add_child(_invite_tile(list.size() + 1 if grouped else 2, bool(acts.invite_on)))
	if acts.teams:
		bar.add_child(_action_button("TEAMS", "GroupTeams", "dark", open_teams))
	if acts.exit:
		bar.add_child(_action_button("EXIT GROUP", "GroupExit", "light", _ask_exit))
	if acts.disband:
		bar.add_child(_action_button("DISBAND GROUP", "GroupDisband", "danger", _ask_disband))


func _tile_style(bg: Color, edge: Color) -> StyleBoxFlat:
	var st := UI.chamfer(bg, 10, 1, edge, 0.0, ["br"])
	st.content_margin_left = 8
	st.content_margin_right = 8
	st.content_margin_top = 0
	st.content_margin_bottom = 0
	return st


## The place's number in the group, on blue (the player's own team colour in a match).
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


func _tile_text(title: String, title_color: Color, sub: String, sub_color := UI.TEXT_DIM) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(UI.ellipsis(UI.label(title, 20, title_color, "heavy")))
	v.add_child(UI.ellipsis(UI.label(sub, 12, sub_color, "bold")))
	return v


## A member (GroupMember_<n>): the number, the name, LEADER / YOU, the leader's REMOVE on others.
func _member_tile(n: int, m: Dictionary, can_remove: bool) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "GroupMember_%d" % n
	var lead := bool(m.get("leader", false))
	var me := bool(m.get("me", false))
	p.add_theme_stylebox_override("panel", _tile_style(Color(0.02, 0.02, 0.025, 0.66), Color(UI.ACCENT, 0.7) if lead else Color(1, 1, 1, 0.14)))
	p.custom_minimum_size = Vector2(TILE_W, UI.TOUCH_MIN)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	h.add_child(_badge(n))
	var tags := PackedStringArray()
	if lead:
		tags.append("LEADER")
	if me:
		tags.append("YOU")
	h.add_child(_tile_text(String(m.get("name", "PLAYER")), UI.TEXT, "  ·  ".join(tags) if not tags.is_empty() else "MEMBER",
		UI.ACCENT if lead else UI.TEXT_DIM))
	if lead:
		var tag := UI.label("LEADER", 12, UI.INK, "heavy")
		tag.name = "LeaderTag"
		tag.add_theme_stylebox_override("normal", UI.chamfer(UI.ACCENT, 4, 0, Color.TRANSPARENT, 4.0, ["br"]))
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.add_child(tag)
	elif can_remove and not me:
		var rm := UI.button("REMOVE", 13, "dark", Vector2(84, UI.TOUCH_MIN))
		rm.name = "GroupRemove_%d" % n
		var id := String(m.get("id", ""))
		var who := String(m.get("name", "PLAYER"))
		rm.pressed.connect(func() -> void:
			lobby.dialogs.confirm("REMOVE FROM GROUP", "Remove %s from your group?" % who, "REMOVE",
				func() -> void: Game.cloud_service().kick_from_group(id), Callable(), true))
		h.add_child(rm)
	return p


## "+ INVITE" (GroupInvite): the leader's (or a solo's) while the group is not full; greyed otherwise.
func _invite_tile(n: int, on: bool) -> Button:
	var b := Button.new()
	b.name = "GroupInvite"
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(TILE_W, UI.TOUCH_MIN)
	b.disabled = not on
	var normal := _tile_style(Color(0.02, 0.02, 0.025, 0.66), Color(UI.ACCENT, 0.55))
	var lit := _tile_style(Color(UI.ACCENT, 0.22), UI.ACCENT)
	for st in ["normal", "focus"]:
		b.add_theme_stylebox_override(st, normal)
	for st in ["hover", "pressed", "hover_pressed"]:
		b.add_theme_stylebox_override(st, lit)
	b.add_theme_stylebox_override("disabled", _tile_style(Color(0.02, 0.02, 0.025, 0.45), Color(1, 1, 1, 0.1)))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 8
	h.offset_right = -10
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	h.add_child(_badge(mini(n, group_max())))
	var full := members().size() >= group_max()
	var sub := "A FRIEND ONLINE JOINS" if on else ("THE GROUP IS FULL" if full else "THE LEADER INVITES")
	h.add_child(_tile_text("+ INVITE", UI.ACCENT if on else UI.TEXT_DIM, sub))
	if not on:
		h.modulate = Color(1, 1, 1, 0.55)
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		open_list())
	return b


func _action_button(text: String, node_name: String, style: String, action: Callable) -> Button:
	var b := UI.button(text, 18, style, Vector2(TILE_W, UI.TOUCH_MIN))
	b.name = node_name
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		action.call())
	return b


## EXIT GROUP (a member), asked first.
func _ask_exit() -> void:
	lobby.dialogs.confirm("EXIT GROUP", "Leave %s's group? The others stay together." % leader_name(members()), "EXIT GROUP",
		func() -> void: Game.cloud_service().leave_group(), Callable(), true)


## DISBAND GROUP (the leader), asked first: everyone leaves.
func _ask_disband() -> void:
	lobby.dialogs.confirm("DISBAND GROUP", "Disband your group? Every member leaves it.", "DISBAND",
		func() -> void: Game.cloud_service().leave_group(), Callable(), true)


# ---------------------------------------------------------------- the invite list

## INVITE: the friends (GroupInviteList) with INVITE on the ones online now.
func open_list() -> void:
	if not bool(bar_actions(in_group(), is_leader(), members().size(), Game.team_size, group_max()).invite_on):
		return
	var v := lobby.dialogs.open_modal("INVITE TO YOUR GROUP", 760.0)
	var t := UI.label("An online friend joins your group (up to %d players). The leader picks the mode and starts: real players only, no bots." % group_max(),
		18, UI.TEXT_DIM, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(680, 0)
	v.add_child(t)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(700, 0)
	v.add_child(scroll)
	_list = VBoxContainer.new()
	_list.name = "GroupInviteList"
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
	var ids: Array = members().map(func(m: Dictionary) -> String: return String(m.get("id", "")))
	var rows := invite_rows(Game.profile.friends, cloud.peers, ids)
	var sig := str(rows) + _list_note + cloud.status
	if sig == _list_sig:
		return
	_list_sig = sig
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	if _list_note != "":
		var n := UI.label(_list_note, 17, UI.ACCENT, "bold")
		n.name = "GroupListNote"
		_list.add_child(n)
	if rows.is_empty():
		var none := UI.label("No friends to invite yet. Add players as friends in FRIENDS, then invite them here.", 19, UI.TEXT, "semi")
		none.name = "GroupListEmpty"
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		none.custom_minimum_size = Vector2(660, 0)
		_list.add_child(none)
		var fb := UI.button("FRIENDS", 20, "primary", Vector2(220, 56))
		fb.name = "GroupFriends"
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
			off.name = "GroupListOffline"
			_list.add_child(off)
	var scroll := _list.get_parent() as ScrollContainer
	if scroll:
		scroll.custom_minimum_size.y = minf(_list.get_combined_minimum_size().y, 330.0)


func _friend_row(r: Dictionary) -> PanelContainer:
	var id := String(r.id)
	var code := Cloud.friend_code(id)
	var p := PanelContainer.new()
	p.name = "GroupFriend_" + code
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
	ask.name = "GroupAsk_" + code
	ask.disabled = not bool(r.online)
	ask.pressed.connect(ask_friend.bind(id, String(r.name)))
	h.add_child(ask)
	if not r.online:
		p.modulate = Color(1, 1, 1, 0.5)
	return p


## GroupAsk_<code>: the GROUP INVITE goes to this friend (Cloud.group_invite); then a popup says
## INVITED <NAME> and, when it comes, their answer.
func ask_friend(id: String, who: String) -> void:
	if not Game.cloud_service().group_invite(id):
		_list_note = "%s COULD NOT BE REACHED" % who
		_list_sig = ""
		_fill_list()
		return
	_invited_id = id
	_invited_name = who
	_show_invited()


## The popup after an invite went out: INVITED <NAME>, then JOINED / DECLINED.
func _show_invited() -> void:
	_list = null
	var v := lobby.dialogs.open_modal("GROUP INVITE", 640.0)
	_invited_label = UI.label("INVITED %s" % _invited_name, 28, UI.ACCENT, "heavy")
	_invited_label.name = "GroupInvited"
	_invited_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_invited_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_invited_label.custom_minimum_size = Vector2(560, 0)
	v.add_child(_invited_label)
	var t := UI.label("They join your group when they accept. Nothing starts until you press START.", 17, UI.TEXT_DIM, "semi")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(560, 0)
	v.add_child(t)
	var ok := UI.button("OK", 22, "primary", Vector2(240, 56))
	ok.name = "GroupInvitedOk"
	ok.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ok.pressed.connect(lobby.dialogs.close_modal)
	v.add_child(ok)
	_follow_invited()


## The invite's popup follows the answer: the friend in the group = JOINED.
func _follow_invited() -> void:
	if _invited_id == "" or _invited_label == null or not is_instance_valid(_invited_label):
		return
	for m: Dictionary in members():
		if String(m.get("id", "")) == _invited_id:
			_invited_label.text = "%s JOINED YOUR GROUP" % _invited_name
			_invited_id = ""
			return


## A declined (or unanswered) invite (LobbyFriends hands Cloud.invite_answered on).
func on_answered(accepted: bool, who: String) -> void:
	if accepted or _invited_name == "" or who != _invited_name:
		return
	_invited_id = ""
	if _invited_label and is_instance_valid(_invited_label):
		_invited_label.text = "%s DECLINED" % who


# ---------------------------------------------------------------- TEAMS

## TEAMS (GroupTeams): the BLUE / ORANGE slot panel. The leader taps a member, then a slot
## (Cloud.set_group_team(id, team, slot)); uneven teams are fine and empty slots stay empty (no
## bots). The others see the arrangement.
func open_teams() -> void:
	var leader := is_leader()
	var v := lobby.dialogs.open_modal("GROUP TEAMS", 760.0)
	v.name = "GroupTeamPanel"
	var t := UI.label("Tap a player, then a place, to move them. Empty places stay empty: no bots." if leader
		else "The leader sets the teams.", 17, UI.TEXT_DIM, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(680, 0)
	v.add_child(t)
	_slot_panel = SlotPanel.new()
	_slot_panel.editable = leader
	_slot_panel.moved.connect(func(id: String, team: int, slot: int) -> void:
		Game.cloud_service().set_group_team(id, team, team * NetGroup.per_team(Game.team_size) + slot))
	v.add_child(_slot_panel)
	_slot_panel.show_slots(NetGroup.per_team(Game.team_size), team_entries(members(), Game.team_size))


## The group changed: the bar, the invite's popup and the open TEAMS panel follow.
func on_group_changed() -> void:
	refresh()
	_follow_invited()
	if _slot_panel and is_instance_valid(_slot_panel):
		_slot_panel.editable = is_leader()
		_slot_panel.show_slots(NetGroup.per_team(Game.team_size), team_entries(members(), Game.team_size))


func process(delta: float) -> void:
	_refresh_t -= delta
	if _refresh_t > 0.0:
		return
	_refresh_t = 0.5
	if _list and is_instance_valid(_list):
		_fill_list()
	elif _list:
		_list = null
