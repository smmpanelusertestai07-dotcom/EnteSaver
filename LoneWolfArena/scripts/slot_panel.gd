class_name SlotPanel
extends HBoxContainer
## Two team columns, BLUE and ORANGE, of slot boxes: the one control the GROUP's TEAMS popup and the
## CUSTOM ROOM share (design/GROUPS.txt). show_slots(per_team, entries) draws per_team places a team
## (SOLO 1, DUO 2, SQUAD 4) and the players in theirs: entries [{"id", "name", "team" 0 | 1, "slot",
## "host", "me"}]. An empty place stays empty (no bots). The host / leader carries a tag (HostTag,
## `host_word`: "LEADER" in a group, "HOST" in a room).
## editable (the group's leader): tap a player, then a place: moved(id, team, slot); uneven teams
## (1 VS 2) are fine. take_empty (a room's player): a tap on an empty place = slot_tapped(team, slot).
## kick (the room's host): SlotKick_<n> on every other player = kick_tapped(id).
## Node names: SlotPanel, SlotTeam_<0|1>, Slot_<team>_<i>, SlotKick_<n> (n = team * per_team + i),
## HostTag.

signal moved(id: String, team: int, slot: int)
signal slot_tapped(team: int, slot: int)
signal kick_tapped(id: String)

const TEAM_NAMES := ["BLUE", "ORANGE"]
const TEAM_COLORS := [Color(0.106, 0.569, 0.851), Color(0.95, 0.47, 0.13)]
const SLOT_W := 300.0

var editable := false
var take_empty := false
var kick := false
var host_word := "LEADER"
var picked := ""                         # the player the leader tapped (moves with the next tap)
var _per := 1
var _entries: Array = []


func _init() -> void:
	name = "SlotPanel"
	add_theme_constant_override("separation", 18)
	alignment = BoxContainer.ALIGNMENT_CENTER


## Who sits where: {"<team>_<slot>": entry}.
static func seat_map(entries: Array) -> Dictionary:
	var out := {}
	for e: Dictionary in entries:
		out["%d_%d" % [int(e.get("team", 0)), int(e.get("slot", 0))]] = e
	return out


## The players a team for a team size: SOLO 1, DUO 2, SQUAD 4 (a 2-, 4- or 8-place panel).
static func places_for(team_size: int) -> int:
	return 4 if team_size >= 4 else (2 if team_size == 2 else 1)


func show_slots(per_team: int, entries: Array) -> void:
	_per = maxi(per_team, 1)
	_entries = entries
	if picked != "" and not entries.any(func(e: Dictionary) -> bool: return String(e.get("id", "")) == picked):
		picked = ""
	for c in get_children():
		remove_child(c)
		c.queue_free()
	var seats := seat_map(entries)
	for t in 2:
		var col := VBoxContainer.new()
		col.name = "SlotTeam_%d" % t
		col.add_theme_constant_override("separation", 6)
		add_child(col)
		var head := UI.label(String(TEAM_NAMES[t]), 18, TEAM_COLORS[t], "heavy")
		col.add_child(head)
		for i in _per:
			col.add_child(_slot_row(t, i, seats.get("%d_%d" % [t, i], {})))


func _slot_row(t: int, i: int, e: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var b := Button.new()
	b.name = "Slot_%d_%d" % [t, i]
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(SLOT_W, UI.TOUCH_MIN)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var filled := not e.is_empty()
	var id := String(e.get("id", ""))
	var lit := filled and id == picked
	var edge: Color = UI.ACCENT if lit else Color(TEAM_COLORS[t], 0.7 if filled else 0.3)
	var bg := Color(TEAM_COLORS[t], 0.22) if filled else Color(0, 0, 0, 0.4)
	var st := UI.chamfer(bg, 8, 3 if lit else 1, edge, 8.0, ["br"])
	for s in ["normal", "focus", "hover", "pressed", "hover_pressed", "disabled"]:
		b.add_theme_stylebox_override(s, st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 12
	h.offset_right = -8
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	var who := String(e.get("name", "PLAYER")) + ("  (YOU)" if bool(e.get("me", false)) else "") if filled else "EMPTY"
	var l := UI.ellipsis(UI.label(who, 19, UI.TEXT if filled else UI.TEXT_DIM, "heavy" if filled else "bold"))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	if filled and bool(e.get("host", false)):
		var tag := UI.label(host_word, 12, UI.INK, "heavy")
		tag.name = "HostTag"
		tag.add_theme_stylebox_override("normal", UI.chamfer(UI.ACCENT, 4, 0, Color.TRANSPARENT, 4.0, ["br"]))
		tag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(tag)
	b.pressed.connect(_on_slot.bind(t, i))
	row.add_child(b)
	if kick and filled and not bool(e.get("me", false)) and not bool(e.get("host", false)):
		var k := UI.button("KICK", 15, "danger", Vector2(84, UI.TOUCH_MIN))
		k.name = "SlotKick_%d" % (t * _per + i)
		k.pressed.connect(func() -> void: kick_tapped.emit(id))
		row.add_child(k)
	return row


## A tap on a place: the leader picks a player, then the place they go to; a room's player takes an
## empty place.
func _on_slot(t: int, i: int) -> void:
	Audio.play("ui_click", -4.0)
	var e: Dictionary = seat_map(_entries).get("%d_%d" % [t, i], {})
	if editable:
		if picked != "":
			var mine: Dictionary = {}
			for x: Dictionary in _entries:
				if String(x.get("id", "")) == picked:
					mine = x
			var id := picked
			picked = ""
			if int(mine.get("team", -1)) != t or int(mine.get("slot", -1)) != i:
				moved.emit(id, t, i)
			show_slots(_per, _entries)
		elif not e.is_empty():
			picked = String(e.get("id", ""))
			show_slots(_per, _entries)
		return
	if take_empty and e.is_empty():
		slot_tapped.emit(t, i)
