class_name SearchTab
extends PanelContainer
## The search tab: while LONE WOLF searches for a match (the 1 vs 1 QUICK MATCH, NetMatch, or a
## DUO / SQUAD search, Cloud.group_start), a small dark plate hangs from the top centre of the
## lobby instead of a popup, so WARDROBE, SETTINGS, PROFILE, FRIENDS and chat stay usable behind
## it. It shows a short line ("ESTIMATED 0:10" for the first ESTIMATE_S seconds, then "STILL
## SEARCHING..."; the caller may put its own there, e.g. CONNECTING...), the time searched counting
## up in big digits, for DUO / SQUAD "PLAYERS n/N", and a cancel X at its right end. A group member
## sees it without the X: only the leader cancels. The lobby makes one (Lobby.search_tab) and shows
## or hides it from what is searching (Lobby.search_kind); the tab itself only draws and counts.
## Node names: SearchTab, SearchLine, SearchTimer, SearchPlayers, SearchCancel.

const ESTIMATE_S := 10              # what the line promises at first (seconds)
const TAB_W := 340.0
const DROP_S := 0.22                # the slide down from the top edge

var elapsed := 0.0                  # seconds searched (the caller may set it, e.g. NetMatch.elapsed)
var on_cancel := Callable()         # the X (none: a member's tab)
var _line: Label
var _timer: Label
var _players: Label
var _cancel: Button
var _status := ""                   # the caller's own line ("" = the estimate / still searching)
var _shown := false


func _init() -> void:
	name = "SearchTab"
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_CENTER_TOP)
	offset_left = -TAB_W * 0.5
	offset_right = TAB_W * 0.5
	offset_top = 0.0
	grow_vertical = Control.GROW_DIRECTION_END
	add_theme_stylebox_override("panel", UI.chamfer(Color(0.03, 0.03, 0.035, 0.9), 14, 2, Color(UI.ACCENT, 0.85), 10.0, ["bl", "br"]))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	add_child(row)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", -4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)
	_line = UI.label("", 15, UI.ACCENT, "heavy")
	_line.name = "SearchLine"
	_line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_line)
	_timer = UI.shadowed(UI.label("0:00", 38, UI.TEXT, "heavy"))
	_timer.name = "SearchTimer"
	_timer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_timer)
	_players = UI.label("", 15, UI.TEXT_DIM, "bold")
	_players.name = "SearchPlayers"
	_players.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_players.visible = false
	col.add_child(_players)
	_cancel = UI.close_button(UI.TOUCH_MIN)
	_cancel.name = "SearchCancel"
	_cancel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_cancel.pressed.connect(func() -> void:
		if on_cancel.is_valid():
			on_cancel.call())
	row.add_child(_cancel)


## The small line: the estimate for the first ESTIMATE_S seconds, then STILL SEARCHING...
static func line_text(seconds: float) -> String:
	if seconds < float(ESTIMATE_S) + 1.0:
		return "ESTIMATED %d:%02d" % [ESTIMATE_S / 60, ESTIMATE_S % 60]
	return "STILL SEARCHING..."


## The count-up timer: m:ss.
static func timer_text(seconds: float) -> String:
	var s := maxi(int(seconds), 0)
	return "%d:%02d" % [s / 60, s % 60]


## DUO / SQUAD's count ("" for the 1 vs 1: needed 0).
static func players_text(found: int, needed: int) -> String:
	return "PLAYERS %d/%d" % [clampi(found, 0, needed), needed] if needed > 0 else ""


## A search begins (or goes on): the tab drops in when it was hidden; `cancel` is the X's action
## (an invalid Callable hides the X: a group member's tab).
func begin(cancel: Callable) -> void:
	on_cancel = cancel
	_cancel.visible = cancel.is_valid()
	if _shown:
		return
	_shown = true
	elapsed = 0.0
	_status = ""
	visible = true
	refresh()
	offset_top = -120.0
	create_tween().tween_property(self, "offset_top", 0.0, DROP_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## The search is over (matched, cancelled, stopped): the tab goes.
func end() -> void:
	if not _shown:
		return
	_shown = false
	on_cancel = Callable()
	visible = false


func is_shown() -> bool:
	return _shown


## The caller's own small line ("" goes back to the estimate / STILL SEARCHING...).
func set_status(text: String) -> void:
	_status = text


## The DUO / SQUAD count (needed 0 hides it).
func set_players(found: int, needed: int) -> void:
	var t := players_text(found, needed)
	_players.visible = t != ""
	if _players.text != t:
		_players.text = t


## Redraws the texts (only what changed).
func refresh() -> void:
	var l := _status if _status != "" else line_text(elapsed)
	if _line.text != l:
		_line.text = l
	var tt := timer_text(elapsed)
	if _timer.text != tt:
		_timer.text = tt
