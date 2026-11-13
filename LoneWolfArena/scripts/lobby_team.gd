class_name LobbyTeam
extends RefCounted
## The lobby's group (LONE WOLF, design/GROUPS.txt 1). Up to GROUP_MAX (4) players: the first
## invite makes this player the LEADER. While this player is in a group the TEAM bar (TeamBar)
## shows under the player card top-left; a tap opens the TEAM panel from the left (TeamPanel,
## open_panel): TEAM n/4 (GroupHead), the GROUP CODE with COPY (GroupCodeRow: GroupCode,
## GroupCodeCopy; a member sees it only while the leader's JOIN BY CODE is on, Cloud.code_open, else
## GroupCodeNote THE LEADER SHARES THE GROUP CODE), the members (leader first, then in join order:
## GroupMember_<n> with the level, the name, LEADER / YOU, the leader's flag LeaderTag, a free place
## SpeakMark_<n> for the voice's speaking mark, the leader's REMOVE GroupRemove_<n> on others),
## + INVITE (GroupInvite: the right-hand social panel, LobbySocial; greyed for a member and in a
## full group), TEAMS (GroupTeams: the BLUE / ORANGE slot panel, the leader moves members, the
## others see it) and EXIT GROUP (GroupExit, a member) or DISBAND GROUP (GroupDisband, the leader),
## both asked first. Where the rest lives: the switch JOIN BY CODE and the team size are the mode
## card's TEAM panel (LobbyDialogs.open_size_box), a solo's invites and JOIN BY CODE the social
## panel (its "+" calls ask_friend: Cloud.group_invite, then the popup GroupInvited says INVITED
## <NAME> and how they answered; its GROUP CODE keypad: Cloud.join_group_code).
## The lobby makes it (Lobby.team), builds it (build), redraws it on Cloud.group_changed and on
## SELECT MODE (refresh) and calls process() every frame; LobbyFriends hands it a declined invite
## (on_answered).
## It reads and calls Cloud's group API (GROUPS.txt 3) through the helpers below (group / members /
## in_group / is_leader / group_max / search_progress). A CUSTOM ROOM with slots is a group too
## (Cloud.in_room): its players show in the room's own slot panel (LobbyFriends), no TEAM bar.
## Node names: TeamBar, TeamPanel (TeamOutside, TeamPanelClose, GroupHead, GroupCodeRow,
## GroupCodeNote, GroupMember_<n>, LeaderTag, SpeakMark_<n>, GroupRemove_<n>, GroupInvite,
## GroupTeams, GroupExit, GroupDisband), GroupInvited, GroupInvitedOk, GroupTeamPanel (with a SlotPanel).

const BAR_W := 236.0                    # the TEAM bar's width
const PANEL_W := 0.36                   # the TEAM panel's right edge (share of the width)
const PANEL_MIN_W := 440.0
const ONLINE_GREEN := Color(0.38, 0.86, 0.44)
const GROUP_MAX_DEFAULT := 4
## A member's line where the GROUP CODE would be while the leader's JOIN BY CODE is off.
const CODE_NOTE := "THE LEADER SHARES THE GROUP CODE"

var lobby: Lobby
var bar: Button                          # the TEAM bar (TeamBar)
var _panel_v: VBoxContainer              # the open TEAM panel's rows (null when it is not open)
var _sig := ""                           # what the panel shows now (drawn again only when it changes)
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


## What sits in START's place outside a search: "" (START works) or the line a member sees (a
## search shows the MATCHING... plate instead, and the search tab with PLAYERS n/N: SearchTab).
static func start_gate_text(grouped: bool, leader: bool, leader_n: String) -> String:
	if not grouped or leader:
		return ""
	return "WAITING FOR %s TO START" % (leader_n if leader_n != "" else "THE LEADER")


## The friends to invite: [{"id", "name", "online", "in_match"}], online ones first, then by name;
## "in_match": its lobby announce says it plays a match (IN A MATCH, INVITE greyed); blocked
## players never (`friends`: profile "friends", `online_ids`: Cloud.peers); members left out.
static func invite_rows(friends: Dictionary, online_ids: Dictionary, in_group_ids: Array = []) -> Array:
	var out: Array = []
	for id: String in friends:
		if Game.is_blocked(id) or in_group_ids.has(id):
			continue
		var f: Variant = friends[id]
		var who := String((f as Dictionary).get("name", "PLAYER")) if f is Dictionary else "PLAYER"
		var seen: Variant = online_ids.get(id)
		out.append({"id": id, "name": who if who != "" else "PLAYER", "online": online_ids.has(id),
			"in_match": seen is Dictionary and bool((seen as Dictionary).get("im", false))})
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


# ---------------------------------------------------------------- the TEAM bar and its panel

## The TEAM bar (TeamBar): under the player card top-left, only while this player is in a group
## (not in a custom room); "TEAM n/4" and the group's mark. A tap opens the TEAM panel.
func build(root: Control) -> void:
	bar = Button.new()
	bar.name = "TeamBar"
	bar.focus_mode = Control.FOCUS_NONE
	bar.position = Vector2(0, 70)
	bar.size = Vector2(BAR_W, UI.TOUCH_MIN)
	bar.custom_minimum_size = bar.size
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		bar.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	bar.draw.connect(_draw_bar)
	for sig in ["button_down", "button_up"]:
		bar.connect(sig, bar.queue_redraw)
	bar.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		open_panel())
	bar.visible = false
	root.add_child(bar)
	refresh()


## The bar: an amber band fading to the right with TEAM, the count and a flag at its right end.
func _draw_bar() -> void:
	var sz := bar.size
	var y := 6.0
	var h := sz.y - 12.0
	var a := 1.0 if not bar.is_pressed() else 0.8
	var pts := PackedVector2Array([Vector2(0, y), Vector2(sz.x, y), Vector2(sz.x - 10.0, y + h), Vector2(0, y + h)])
	var c0 := Color(0.86, 0.45, 0.08, 0.92 * a)
	var c1 := Color(0.86, 0.45, 0.08, 0.35 * a)
	bar.draw_polygon(pts, PackedColorArray([c0, c1, c1, c0]))
	bar.draw_rect(Rect2(0, y + h - 2.0, sz.x - 10.0, 2.0), Color(UI.ACCENT, 0.9))
	var n := maxi(members().size(), 1)
	HudDraw.text(bar, "TEAM", Vector2(12, sz.y * 0.5), 19, UI.TEXT, 0, 0, "heavy")
	HudDraw.text(bar, "%d/%d" % [n, group_max()], Vector2(80, sz.y * 0.5), 15, Color(UI.TEXT, 0.85), 0, 0, "bold")
	var fc := Vector2(sz.x - 30.0, sz.y * 0.5)
	bar.draw_circle(fc, 13.0, Color(0, 0, 0, 0.45), true, -1.0, true)
	draw_flag(bar, fc, 15.0, UI.ACCENT)


## A small flag (the leader's mark): a pole and a notched cloth, `s` px tall, centred on `c`.
static func draw_flag(ci: CanvasItem, c: Vector2, s: float, col: Color) -> void:
	var x0 := c.x - s * 0.38
	var top := c.y - s * 0.5
	ci.draw_rect(Rect2(x0, top, maxf(1.5, s * 0.1), s), col)
	ci.draw_colored_polygon(PackedVector2Array([Vector2(x0, top), Vector2(x0 + s * 0.78, top), Vector2(x0 + s * 0.6, top + s * 0.25),
		Vector2(x0 + s * 0.78, top + s * 0.5), Vector2(x0, top + s * 0.5)]), col)


## Follows the group (Cloud.group_changed) and SELECT MODE: the bar shows in a group, and an open
## TEAM panel is drawn again when what it shows changed.
func refresh() -> void:
	if bar == null or not is_instance_valid(bar):
		return
	var cloud := Game.cloud_service()
	var on := in_group() and bar_shown(Game.mode, true) and not cloud.in_room()
	bar.visible = on
	bar.queue_redraw()
	var sig := "%s|%s|%s|%d|%s|%s" % [str(members()), in_group(), is_leader(), Game.team_size, cloud.group_code(), cloud.code_open()]
	if sig == _sig:
		return
	_sig = sig
	if _panel_v != null and is_instance_valid(_panel_v):
		if on:
			_fill_panel()
		else:
			lobby.dialogs.close_modal()          # (the group is gone: so is its panel)


## The TEAM panel (TeamPanel): slides in from the left over the lobby's left part (a tap beside it,
## its "<" (TeamPanelClose) or Android back closes it). TEAM n/4; the GROUP CODE row (code_row: the
## code and COPY; a member's only while the leader's JOIN BY CODE is on, else GroupCodeNote); a row
## per member (GroupMember_<n>: the level, the name, YOU, the LEADER flag on the leader, a free
## place for the voice's speaking mark SpeakMark_<n>, and the leader's REMOVE on other members:
## GroupRemove_<n>, asked first); INVITE (GroupInvite: the right-hand social panel, LobbySocial;
## greyed for a member or a full group); TEAMS (GroupTeams: the BLUE / ORANGE places, DUO / SQUAD);
## EXIT GROUP (GroupExit, a member) or DISBAND GROUP (GroupDisband, the leader), both asked first.
func open_panel() -> void:
	if not in_group():
		return
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
	outside.name = "TeamOutside"
	outside.focus_mode = Control.FOCUS_NONE
	UI.full_rect(outside)
	for st: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		outside.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	outside.pressed.connect(dlg.close_modal)
	modal.add_child(outside)
	var frame := PanelContainer.new()
	frame.name = "TeamPanel"
	frame.anchor_right = PANEL_W
	frame.anchor_bottom = 1.0
	frame.custom_minimum_size = Vector2(PANEL_MIN_W, 0)
	var fs := UI.box(Color(0.045, 0.035, 0.06, 0.96), 0, 0, Color.TRANSPARENT, 0.0)
	fs.border_width_right = 1
	fs.border_color = Color(1, 1, 1, 0.14)
	frame.add_theme_stylebox_override("panel", fs)
	frame.mouse_filter = Control.MOUSE_FILTER_STOP
	modal.add_child(frame)
	var safe := MarginContainer.new()
	frame.add_child(safe)
	UI.pad_clear_of_cutout(safe)
	var pad := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, 14 if side != "top" else 8)
	safe.add_child(pad)
	_panel_v = VBoxContainer.new()
	_panel_v.add_theme_constant_override("separation", 8)
	pad.add_child(_panel_v)
	_fill_panel()
	frame.offset_left = -40.0
	frame.offset_right = -40.0
	var tw := modal.create_tween().set_parallel()
	for side: String in ["offset_left", "offset_right"]:
		tw.tween_property(frame, side, 0.0, 0.16).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)


func _fill_panel() -> void:
	for c in _panel_v.get_children():
		_panel_v.remove_child(c)
		c.queue_free()
	var list := members()
	var leader := is_leader()
	var cloud := Game.cloud_service()
	var acts := bar_actions(true, leader, list.size(), Game.team_size, group_max())
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	_panel_v.add_child(head)
	var title := UI.label("TEAM  %d/%d" % [list.size(), group_max()], 24, UI.TEXT, "heavy")
	title.name = "GroupHead"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close := UI.button("<", 24, "dark", Vector2(UI.TOUCH_MIN, UI.TOUCH_MIN))
	close.name = "TeamPanelClose"
	close.pressed.connect(lobby.dialogs.close_modal)
	head.add_child(close)
	if cloud.group_code() != "" and (leader or cloud.code_open()):
		_panel_v.add_child(code_row(cloud.group_code(), leader))
	elif not leader:
		_panel_v.add_child(code_note())
	for i in list.size():
		_panel_v.add_child(_member_tile(i + 1, list[i], bool(acts.remove)))
	var inv := _action_button("+ INVITE", "GroupInvite", "light", func() -> void:
		lobby.dialogs.close_modal()
		lobby.social.open("friends"))
	inv.disabled = not bool(acts.invite_on)
	_panel_v.add_child(inv)
	if acts.teams:
		_panel_v.add_child(_action_button("TEAMS", "GroupTeams", "dark", open_teams))
	if acts.exit:
		_panel_v.add_child(_action_button("EXIT GROUP", "GroupExit", "light", _ask_exit))
	if acts.disband:
		_panel_v.add_child(_action_button("DISBAND GROUP", "GroupDisband", "danger", _ask_disband))


func _tile_style(bg: Color, edge: Color) -> StyleBoxFlat:
	var st := UI.chamfer(bg, 10, 1, edge, 0.0, ["br"])
	st.content_margin_left = 8
	st.content_margin_right = 8
	st.content_margin_top = 0
	st.content_margin_bottom = 0
	return st


## A member's level as this phone knows it: its own, else the member's card (Cloud.directory), 0
## when unknown.
static func member_level(m: Dictionary) -> int:
	if bool(m.get("me", false)):
		return Game.level()
	var card: Variant = Game.cloud_service().directory.get(String(m.get("id", "")))
	return int((card as Dictionary).get("level", 0)) if card is Dictionary else 0


## The member's level in a small square (the member row's first mark): "LV" over the number.
func _level_badge(lv: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UI.box(Color(0.12, 0.11, 0.14), 3, 1, Color(UI.ACCENT, 0.5), 2.0))
	p.custom_minimum_size = Vector2(40, 40)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -6)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(v)
	for t: Array in [["LV", 10, UI.TEXT_DIM], [str(lv) if lv > 0 else "-", 17, UI.ACCENT]]:
		var l := UI.label(String(t[0]), int(t[1]), t[2], "heavy")
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(l)
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


## A member (GroupMember_<n>): the level, the name (yellow for this player), YOU / MEMBER, a free
## place for the speaking mark (SpeakMark_<n>, the voice fills it), the leader's flag (LeaderTag)
## or, for the leader, REMOVE on the others.
func _member_tile(n: int, m: Dictionary, can_remove: bool) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "GroupMember_%d" % n
	var lead := bool(m.get("leader", false))
	var me := bool(m.get("me", false))
	p.add_theme_stylebox_override("panel", _tile_style(Color(1, 1, 1, 0.06), Color(UI.ACCENT, 0.7) if lead else Color(1, 1, 1, 0.12)))
	p.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	h.add_child(_level_badge(member_level(m)))
	var tags := PackedStringArray()
	if lead:
		tags.append("LEADER")
	if me:
		tags.append("YOU")
	h.add_child(_tile_text(String(m.get("name", "PLAYER")), UI.ACCENT if me else UI.TEXT, "  ·  ".join(tags) if not tags.is_empty() else "MEMBER"))
	var speak := Control.new()
	speak.name = "SpeakMark_%d" % n
	speak.custom_minimum_size = Vector2(24, 24)
	speak.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	speak.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(speak)
	if lead:
		var tag := Control.new()
		tag.name = "LeaderTag"
		tag.custom_minimum_size = Vector2(30, 30)
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.draw.connect(func() -> void:
			tag.draw_circle(tag.size * 0.5, 15.0, UI.ACCENT, true, -1.0, true)
			draw_flag(tag, tag.size * 0.5, 16.0, UI.INK))
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


## The GROUP CODE (GroupCodeRow) in the TEAM panel and on the mode card's TEAM panel: the group's
## flag, the code (GroupCode, grouped "12 3456 7890") and COPY (GroupCodeCopy: the bare digits; for
## the leader or a solo it also turns JOIN BY CODE on, since copying means sharing). The switch
## JOIN BY CODE is the mode card's TEAM panel's tick (LobbyDialogs: GroupCodeSwitch).
func code_row(code: String, leader: bool) -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "GroupCodeRow"
	p.add_theme_stylebox_override("panel", _tile_style(Color(0.02, 0.02, 0.025, 0.66), Color(1, 1, 1, 0.14)))
	p.custom_minimum_size = Vector2(0, UI.TOUCH_MIN)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	p.add_child(h)
	var flag := Control.new()
	flag.custom_minimum_size = Vector2(22, 22)
	flag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	flag.draw.connect(func() -> void: draw_flag(flag, flag.size * 0.5, 20.0, Color.WHITE))
	h.add_child(flag)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -4)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(UI.label("GROUP CODE", 11, UI.TEXT_DIM, "bold"))
	var l := UI.label(Cloud.code_display(code), 20, UI.ACCENT, "heavy")
	l.name = "GroupCode"
	v.add_child(l)
	h.add_child(v)
	var copy := UI.button("COPY", 13, "dark", Vector2(UI.TOUCH_MIN + 16, UI.TOUCH_MIN))
	copy.name = "GroupCodeCopy"
	copy.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(code)
		if leader:
			Game.cloud_service().set_code_join(true)
		LobbyNet.toast(lobby, "GROUP CODE COPIED", "JOIN BY CODE IS ON" if leader else Cloud.code_display(code), Callable()))
	h.add_child(copy)
	return p


## A member's line in the code's place while the leader's JOIN BY CODE is off (GroupCodeNote): the
## code would not let anyone in, and a member's COPY cannot turn the leader's switch on.
func code_note() -> PanelContainer:
	var p := PanelContainer.new()
	p.name = "GroupCodeNote"
	p.add_theme_stylebox_override("panel", _tile_style(Color(0.02, 0.02, 0.025, 0.5), Color(1, 1, 1, 0.1)))
	p.custom_minimum_size = Vector2(0, 40)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := UI.label(CODE_NOTE, 13, UI.TEXT_DIM, "bold")
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	p.add_child(UI.ellipsis(l))
	return p


## What JOIN BY CODE's status line says for Cloud.code_state ("" while nothing is under way).
static func code_state_text(state: String) -> String:
	match state:
		"asking":
			return "LOOKING FOR THE GROUP..."
		"in":
			return "JOINING THE GROUP..."
		"full":
			return "THE GROUP IS FULL"
		"none":
			return "NO GROUP WITH THIS CODE"
		"blocked":
			return "YOU BLOCKED THIS GROUP'S LEADER"
		"failed":
			return "COULD NOT JOIN: TRY AGAIN"
	return ""


func _action_button(text: String, node_name: String, style: String, action: Callable) -> Button:
	var b := UI.button(text, 18, style, Vector2(0, UI.TOUCH_MIN))
	b.name = node_name
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		action.call())
	return b


## The leave glyph on this player's name plate (LobbyPlate): EXIT GROUP for a member, DISBAND GROUP
## for the leader, each asked first.
func ask_leave() -> void:
	if not in_group():
		return
	if is_leader():
		_ask_disband()
	else:
		_ask_exit()


## EXIT GROUP (a member), asked first.
func _ask_exit() -> void:
	lobby.dialogs.confirm("EXIT GROUP", "Leave %s's group? The others stay together." % leader_name(members()), "EXIT GROUP",
		func() -> void: Game.cloud_service().leave_group(), Callable(), true)


## DISBAND GROUP (the leader), asked first: everyone leaves.
func _ask_disband() -> void:
	lobby.dialogs.confirm("DISBAND GROUP", "Disband your group? Every member leaves it.", "DISBAND",
		func() -> void: Game.cloud_service().leave_group(), Callable(), true)


# ---------------------------------------------------------------- invites

## The GROUP INVITE goes to this friend (Cloud.group_invite; the social panel's "+"); then a popup
## says INVITED <NAME> and, when it comes, their answer. One that cannot go out says so (a toast).
func ask_friend(id: String, who: String) -> void:
	if not Game.cloud_service().group_invite(id):
		LobbyNet.toast(lobby, "%s COULD NOT BE REACHED" % who, "INVITE AGAIN WHEN THEY ARE ONLINE", Callable())
		return
	_invited_id = id
	_invited_name = who
	_show_invited()


## The popup after an invite went out: INVITED <NAME>, then JOINED / DECLINED.
func _show_invited() -> void:
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


## The group changed: the bar, its panel, the invite's popup, the open TEAMS panel and the mode
## card's TEAM panel follow.
func on_group_changed() -> void:
	refresh()
	_follow_invited()
	lobby.dialogs.refresh_size_box()
	if _slot_panel and is_instance_valid(_slot_panel):
		_slot_panel.editable = is_leader()
		_slot_panel.show_slots(NetGroup.per_team(Game.team_size), team_entries(members(), Game.team_size))


func process(_delta: float) -> void:
	if _panel_v != null and not is_instance_valid(_panel_v):
		_panel_v = null
