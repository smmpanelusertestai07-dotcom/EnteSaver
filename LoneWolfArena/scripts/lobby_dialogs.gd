class_name LobbyDialogs
extends RefCounted
## The lobby's popups: the popup frame they share (open_modal / close_modal, one at a time, in
## `modal`; back() is the header X and Android back: a popup's own way back, else close), SELECT
## MODE (with TRAINING GROUND's opponent chips), the player name editor with the first-start name
## prompt, a confirmation (confirm()), a message with one OK (notice()) and the "Quit the game?"
## dialog. The lobby makes it (Lobby.dialogs) and its parts open popups through it; everything is
## built under the lobby's UI layer. (HOW TO PLAY is in SETTINGS: scripts/how_to_play.gd.)
## Node names: Modal (or QuitDialog) with its Frame, Close, Mode_<training|lonewolf>, Sizes with
## Size_<1|2|4> (SOLO, DUO, SQUAD: on both mode cards; LONE WOLF's SOLO in a group of two reads
## DUEL · YOU VS <NAME>: size_chip_text), Difficulty with
## Diff_<EASY|NORMAL|HARD|DUMMY>, ModeStats, NameEdit, NameRandom, NamePreview, NameOk,
## ConfirmCancel, ConfirmOk, NoticeText, NoticeOk, QuitCancel, QuitConfirm. Markers: "name prompt"
## and "ui name_ok" (the emulator test taps OK there).

## SELECT MODE: what each mode's card says under its name ({rounds}: Game.ROUNDS_TO_WIN).
const MODE_INFO := {
	"training": {"tag": "VS BOT", "lines": ["1 VS A BOT, OR THE TARGET DUMMY TO PRACTISE YOUR AIM:"]},
	"lonewolf": {"tag": "ONLINE", "lines": ["1 VS 1 AGAINST ANOTHER PLAYER", "PLAYERS ONLINE, FRIENDS OR A CUSTOM ROOM"]},
}
## TRAINING GROUND's opponents in SELECT MODE: the bot's levels (Game.DIFFICULTY_NAMES), then the
## target dummy (SOLO only: a team match is always against bots).
const DUMMY := "DUMMY"
## SELECT MODE's size chips (Game.TEAM_SIZES): the players a team, on both mode cards.
const SIZE_NAMES := {1: "SOLO", 2: "DUO", 4: "SQUAD"}

## A popup closed (also when another one replaces it): a challenge that waited shows then.
signal modal_closed

var lobby: Lobby
## The open popup (node "Modal", or "QuitDialog"); null when none is open.
var modal: Control


func _init(owner_lobby: Lobby) -> void:
	lobby = owner_lobby


# ---------------------------------------------------------------- the popup frame

## A popup in the reference look: the light header strip (dark caps title, hazard line, X on a
## dark tile), then the near-black body with a yellow corner mark. Returns the body column.
## top: the frame sits at the top of the screen, clear of the on-screen keyboard (text entry).
func open_modal(title: String, width := 980.0, top := false) -> VBoxContainer:
	close_modal()
	modal = Control.new()
	modal.name = "Modal"
	UI.full_rect(modal)
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	lobby.ui.add_child(modal)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.72)
	UI.full_rect(shade)
	modal.add_child(shade)
	var frame := VBoxContainer.new()
	frame.name = "Frame"
	frame.add_theme_constant_override("separation", 0)
	frame.anchor_left = 0.5
	frame.anchor_right = 0.5
	frame.anchor_top = 0.0 if top else 0.5
	frame.anchor_bottom = 0.0 if top else 0.5
	frame.offset_left = -width * 0.5
	frame.offset_right = width * 0.5
	frame.offset_top = 18.0 if top else 0.0
	frame.grow_vertical = Control.GROW_DIRECTION_END if top else Control.GROW_DIRECTION_BOTH
	modal.add_child(frame)
	var head := UI.popup_header(title, 26, 56.0)
	(head.get_node("Close") as Button).pressed.connect(back)
	frame.add_child(head)
	var panel := UI.popup_body()
	frame.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	modal.modulate.a = 0.0
	modal.create_tween().tween_property(modal, "modulate:a", 1.0, 0.15)
	return v


func close_modal() -> void:
	if modal:
		modal.queue_free()
		modal = null
		DisplayServer.virtual_keyboard_hide()     # a text field in it may have opened the keyboard
		modal_closed.emit()


## The popup's X and Android back: its own way back when it set one (meta "on_back", a Callable:
## a player card goes back to the list it came from, a confirmation to what asked), else close.
func back() -> void:
	if modal == null:
		return
	var to: Variant = modal.get_meta("on_back") if modal.has_meta("on_back") else null
	if to is Callable and (to as Callable).is_valid():
		(to as Callable).call()
	else:
		close_modal()


## A yes / no question in a popup: CANCEL (and X, back) calls on_cancel, else just closes; the
## OK button (yellow, or red when `danger`) calls on_ok after closing.
func confirm(title: String, text: String, ok_text: String, on_ok: Callable, on_cancel := Callable(), danger := false) -> void:
	var v := open_modal(title, 680.0)
	var t := UI.label(text, 20, UI.TEXT, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(600, 0)
	v.add_child(t)
	v.add_child(UI.spacer(4))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	v.add_child(row)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(190, 56))
	cancel.name = "ConfirmCancel"
	row.add_child(cancel)
	var ok := UI.button(ok_text, 22, "danger" if danger else "primary", Vector2(210, 56))
	ok.name = "ConfirmOk"
	row.add_child(ok)
	if on_cancel.is_valid():
		modal.set_meta("on_back", on_cancel)
	cancel.pressed.connect(back)
	ok.pressed.connect(func() -> void:
		close_modal()
		on_ok.call())


## A message with one OK (X and back close it too): an online match that was called off, a
## challenge that never got going.
func notice(title: String, text: String) -> void:
	var v := open_modal(title, 680.0)
	var t := UI.label(text, 21, UI.TEXT, "semi")
	t.name = "NoticeText"
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(600, 0)
	v.add_child(t)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	v.add_child(row)
	var ok := UI.button("OK", 22, "primary", Vector2(190, 56))
	ok.name = "NoticeOk"
	ok.pressed.connect(close_modal)
	row.add_child(ok)


# ---------------------------------------------------------------- select mode

## SELECT MODE (the lobby's mode card opens it): the two modes as cards (art, name, map, what
## START plays, this player's numbers in it). A tap on a card picks its mode, which START then
## plays (kept as the setting "mode"), and closes the popup; on TRAINING GROUND's card the chips
## pick its opponent too (a bot's level, kept as the setting "difficulty", or the target dummy for
## this session: Game.practice), which also picks TRAINING GROUND.
func select_mode() -> void:
	if LobbyTeam.is_member():
		# In a group the leader picks (Cloud.group's mode / size, shown on the mode card).
		var who := LobbyTeam.leader_name(LobbyTeam.members())
		notice("SELECT MODE", "%s picks the mode while you are in their group: %s %s. EXIT GROUP to pick your own." % [
			who if who != "" else "The leader", Game.mode_name(), String(SIZE_NAMES.get(Game.team_size, "SOLO"))])
		return
	var v := open_modal("SELECT MODE", 980.0)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	v.add_child(row)
	for m: String in Game.MODE_NAMES:
		row.add_child(_mode_choice(m))
	v.add_child(UI.label("On CARGO CAGE. SOLO: 1 vs 1, first to %d rounds, the gun picked every 2 rounds. DUO / SQUAD: teams, first to %d, knock down and revive." % [
		Game.ROUNDS_TO_WIN, TeamArena.TEAM_ROUNDS_TO_WIN], 16, UI.TEXT_DIM, "semi"))


## What a mode's card in SELECT MODE says under its name for a team size (1 SOLO, 2 DUO, 4 SQUAD):
## the lines of MODE_INFO for SOLO; DUO and SQUAD say who plays whom (TRAINING GROUND: the bot's
## level; LONE WOLF: real players only, never bots, or "NEXT UPDATE" while Game.TEAMS_ONLINE is off).
static func mode_lines(m: String, size: int, teams_online := Game.TEAMS_ONLINE) -> Array:
	if size <= 1:
		var info: Dictionary = MODE_INFO.get(m, MODE_INFO[Game.DEFAULT_MODE])
		return info.lines
	var word := String(SIZE_NAMES.get(size, "DUO"))
	var mates := "A BOT" if size == 2 else "%d BOTS" % (size - 1)
	if m == "lonewolf":
		if not teams_online:
			return ["ONLINE DUO / SQUAD: NEXT UPDATE", "PLAY DUO AND SQUAD IN TRAINING GROUND"]
		return ["%s · %d VS %d · REAL PLAYERS" % [word, size, size], "YOUR GROUP OF FRIENDS, OR PLAYERS FOUND ONLINE"]
	var level := String(Game.DIFFICULTY_NAMES[clampi(int(Game.settings.difficulty), 0, Game.DIFFICULTY_NAMES.size() - 1)])
	return ["%s · YOU + %s VS %d BOTS · BOT: %s" % [word, mates, size, level], "DUMMY IS SOLO ONLY"]


## One mode's card in SELECT MODE (node Mode_<m>): yellow outline and tick on the current mode;
## TRAINING GROUND's has the opponent chips (row Difficulty).
func _mode_choice(m: String) -> Button:
	var info: Dictionary = MODE_INFO.get(m, MODE_INFO[Game.DEFAULT_MODE])
	var card := Button.new()
	card.name = "Mode_" + m
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = Vector2(440, 400)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		card.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var art_h := 150.0
	card.draw.connect(func() -> void:
		var s := card.size
		card.draw_rect(Rect2(Vector2.ZERO, s), Color(0.1, 0.095, 0.09, 0.97))
		Lobby.draw_mode_art(card, m, Rect2(0, 0, s.x, art_h))
		card.draw_rect(Rect2(0, art_h - 3, s.x, 3), Color(UI.AMBER, 0.9))
		var picked := Game.mode == m
		if picked:
			card.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), UI.ACCENT, false, 3.0)
			UI.draw_tick_corner(card, s, 40.0)
		elif card.is_hovered() or card.is_pressed():
			card.draw_rect(Rect2(Vector2(1, 1), s - Vector2(2, 2)), Color(1, 1, 1, 0.6), false, 2.0)
		else:
			card.draw_rect(Rect2(Vector2(0.5, 0.5), s - Vector2(1, 1)), Color(1, 1, 1, 0.14), false, 1.0))
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		card.connect(sig, card.queue_redraw)
	var tag := PanelContainer.new()
	tag.add_theme_stylebox_override("panel", UI.chamfer(UI.ACCENT, 6, 0, Color.TRANSPARENT, 8.0, ["br"]))
	tag.add_child(UI.label(String(info.tag), 16, UI.INK, "heavy"))
	tag.position = Vector2(12, 12)
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(tag)
	# The text under the art fills the card down to its bottom edge (the numbers sit there).
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 18
	v.offset_right = -18
	v.offset_top = art_h + 8
	v.offset_bottom = -12
	v.add_theme_constant_override("separation", 0)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(UI.label(Game.mode_name(m), 32, UI.AMBER, "heavy"))
	var map_l := UI.label("CARGO CAGE", 22, UI.TEXT, "heavy")
	map_l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(map_l)
	v.add_child(head)
	var lines := mode_lines(m, Game.team_size)
	for i in maxi(lines.size(), 2):         # two lines on both cards: their chips line up
		v.add_child(UI.label(String(lines[i]) if i < lines.size() else " ", 15, UI.TEXT_DIM, "bold"))
	v.add_child(UI.spacer(8))
	v.add_child(_size_chips(m))
	if m == "training":
		v.add_child(UI.spacer(6))
		v.add_child(_opponent_chips())
	var fill := UI.spacer(0)
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(fill)
	var n: Dictionary = (Game.profile.modes as Dictionary).get(m, {})
	var stats := UI.label("MATCHES %d   ·   WINS %d   ·   KILLS %d" % [int(n.get("matches", 0)), int(n.get("wins", 0)), int(n.get("kills", 0))],
		15, UI.TEXT, "bold")
	stats.name = "ModeStats"
	v.add_child(stats)
	card.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_pick(m))
	return card


## A mode card's team sizes (row Sizes: Size_1 SOLO, Size_2 DUO, Size_4 SQUAD); the current one
## (Game.team_size) is lit. A tap picks the size with the card's mode and closes SELECT MODE; a team
## is never against the target dummy, so DUO and SQUAD pick the bot again.
func _size_chips(m: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Sizes"
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var group := ButtonGroup.new()
	for n: int in Game.TEAM_SIZES:
		var word := size_chip_text(m, n, LobbyTeam.members())
		var b := _chip(word, "Size_%d" % n, n == Game.team_size, group)
		if word.length() > 8:
			b.add_theme_font_size_override("font_size", 14)
		b.pressed.connect(func() -> void:
			Audio.play("ui_select", -6.0)
			Game.team_size = n
			if n > 1:
				Game.practice = false
			_pick(m))
		row.add_child(b)
	return row


## A size chip's word: SOLO / DUO / SQUAD; in LONE WOLF with a group of exactly two, SOLO is the
## duel between the two: "DUEL · YOU VS <NAME>" (START plays it: Lobby.start_duel). `members`:
## Cloud.group_members() (this player marked "me").
static func size_chip_text(m: String, n: int, members: Array) -> String:
	if m == "lonewolf" and n == 1 and members.size() == 2:
		for p: Dictionary in members:
			if not bool(p.get("me", false)):
				return "DUEL · YOU VS %s" % String(p.get("name", "PLAYER"))
	return String(SIZE_NAMES.get(n, "SOLO"))


## TRAINING GROUND's opponent (row Difficulty): EASY, NORMAL and HARD bots, then the target dummy
## (Diff_<name>, SOLO only: greyed in DUO and SQUAD); the current one is lit while TRAINING GROUND
## is the mode.
func _opponent_chips() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Difficulty"
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var group := ButtonGroup.new()
	for i in Game.DIFFICULTY_NAMES.size():
		row.add_child(_opponent_chip(String(Game.DIFFICULTY_NAMES[i]), i, group))
	row.add_child(_opponent_chip(DUMMY, -1, group))
	return row


## A chip for TRAINING GROUND's opponent: a bot level (idx into Game.DIFFICULTY_NAMES) or, with
## idx -1, the target dummy. A tap picks it with TRAINING GROUND and closes SELECT MODE.
func _opponent_chip(text: String, idx: int, group: ButtonGroup) -> Button:
	var b := _chip(text, "Diff_" + text, Game.practice if idx < 0 else (not Game.practice and idx == int(Game.settings.difficulty)), group)
	if idx < 0 and Game.team_size > 1:
		b.disabled = true                 # DUMMY IS SOLO ONLY (the card's line says so)
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		Game.practice = idx < 0
		if idx >= 0:
			Game.settings.difficulty = idx
		else:
			Game.team_size = 1
		_pick("training"))
	return b


## One chip of SELECT MODE (a size or an opponent): toggled in its group, lit when picked.
func _chip(text: String, node_name: String, lit: bool, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.name = node_name
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = lit
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.custom_minimum_size = Vector2(96, UI.TOUCH_MIN)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 17)
	var off := UI.chamfer(Color(0, 0, 0, 0.55), 8, 1, Color(1, 1, 1, 0.2), 8.0, ["tl", "br"], 0.0)
	var hov := UI.chamfer(Color(1, 1, 1, 0.1), 8, 1, Color(1, 1, 1, 0.35), 8.0, ["tl", "br"], 0.0)
	var on := UI.chamfer(UI.ACCENT, 8, 0, Color.TRANSPARENT, 8.0, ["tl", "br"], 0.0)
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	b.add_theme_color_override("font_disabled_color", Color(UI.TEXT_DIM, 0.45))
	b.add_theme_stylebox_override("disabled", UI.chamfer(Color(0, 0, 0, 0.3), 8, 1, Color(1, 1, 1, 0.08), 8.0, ["tl", "br"], 0.0))
	return b


## A mode picked in SELECT MODE: kept (the setting "mode", saved with the bot's level), the popup
## closes and the lobby's mode card follows.
func _pick(m: String) -> void:
	if LobbyTeam.is_member():
		close_modal()                   # (the leader's choice stands: Lobby.on_group_changed)
		lobby.on_group_changed()
		return
	Game.mode = m
	Game.save_settings()
	close_modal()
	lobby._refresh_mode()
	if LobbyTeam.in_group():
		Game.cloud_service().set_group_mode(Game.mode, Game.team_size)   # the members' cards follow


# ---------------------------------------------------------------- player name

## The name editor. first: asked once at start (new installs and ones from before this prompt):
## type a name or roll a random one; closing it keeps the current name.
func edit_name(first := false) -> void:
	var v := open_modal("CHOOSE YOUR NAME" if first else "PLAYER NAME", 640.0, true)
	v.add_child(UI.label("Type a name or tap RANDOM. Up to 14 letters or digits; shown in matches.", 16, UI.TEXT_DIM, "semi"))
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)
	var le := LineEdit.new()
	le.name = "NameEdit"
	le.text = String(Game.profile.name)
	le.max_length = 14
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.custom_minimum_size = Vector2(0, 56)
	le.virtual_keyboard_enabled = true
	le.virtual_keyboard_show_on_focus = true
	le.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_DEFAULT
	le.select_all_on_focus = first
	le.add_theme_font_override("font", UI.font("bold"))
	le.add_theme_font_size_override("font_size", 26)
	le.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.25), 14.0, ["br"]))
	le.add_theme_stylebox_override("focus", UI.chamfer(Color(0, 0, 0, 0.5), 8, 2, UI.ACCENT, 14.0, ["br"]))
	le.add_theme_color_override("font_color", UI.TEXT)
	le.add_theme_color_override("caret_color", UI.ACCENT)
	line.add_child(le)
	var dice := UI.button("RANDOM", 20, "light", Vector2(150, 56))
	dice.name = "NameRandom"
	dice.pressed.connect(func() -> void:
		le.text = Game.random_name()
		le.caret_column = le.text.length()
		Audio.play("ui_click", -4.0))
	line.add_child(dice)
	v.add_child(line)
	# What other players will see, as it is typed (accents become plain letters, other scripts
	# and symbols are left out, Game.clean_name).
	var preview := UI.label("", 18, UI.TEXT_DIM, "bold")
	preview.name = "NamePreview"
	v.add_child(preview)
	var show_preview := func(t: String) -> void:
		var shown := Game.clean_name(t)
		preview.text = "SHOWN AS:  " + shown if shown != "" else "USE LETTERS A-Z OR DIGITS: NOTHING HERE CAN BE SHOWN"
		preview.add_theme_color_override("font_color", UI.TEXT_DIM if shown != "" else UI.BAD)
	le.text_changed.connect(show_preview)
	show_preview.call(le.text)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var cancel := UI.button("KEEP" if first else "CANCEL", 20, "light", Vector2(170, 56))
	var keep := func() -> void:
		if first:
			Game.profile.name_set = true
			Game.save_profile()
		close_modal()
	cancel.pressed.connect(keep)
	var ok := UI.button("OK", 22, "primary", Vector2(170, 56))
	ok.name = "NameOk"
	var apply := func() -> void:
		var n := Game.clean_name(le.text)
		if n == "":
			show_preview.call(le.text)     # nothing that can be shown: the editor stays open and says so
			return
		Game.profile.name = n
		lobby._name_label.text = n
		Game.profile.name_set = true
		Game.save_profile()
		close_modal()
	ok.pressed.connect(apply)
	le.text_submitted.connect(func(_t: String) -> void: apply.call())
	row.add_child(cancel)
	row.add_child(ok)
	v.add_child(row)
	# The two calls below come after this frame / 0.2 s, when the lobby may be gone already (a
	# test or a quick START leaves it at once): they carry the controls' ids, not the controls,
	# and are dropped with this object.
	if first:
		var x := modal.find_child("Close", true, false) as Button
		if x:
			x.pressed.connect(keep)
		lobby.get_tree().process_frame.connect(_mark_name_prompt.bind(ok.get_instance_id()), CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	# Focus once the dialog is up: the keyboard then opens under it, with the field in view.
	lobby.get_tree().create_timer(0.2).timeout.connect(_focus_name_field.bind(le.get_instance_id()))


## Where the first-start prompt's OK is, once it is laid out (the emulator test taps it).
func _mark_name_prompt(ok_id: int) -> void:
	var ok := instance_from_id(ok_id) as Control
	if ok and ok.is_inside_tree():
		Game.mark("name prompt")
		Game.mark_ui("name_ok", ok, ok.size / 2.0)


func _focus_name_field(field_id: int) -> void:
	var le := instance_from_id(field_id) as LineEdit
	if le and le.is_inside_tree():
		le.grab_focus()
		le.caret_column = le.text.length()


# ---------------------------------------------------------------- quit

## "Quit the game?" as a system dialog: a full-width dark band with the emblem, the question,
## CANCEL (grey) and QUIT (yellow). Back or CANCEL closes it.
func confirm_quit() -> void:
	close_modal()
	modal = Control.new()
	modal.name = "QuitDialog"
	UI.full_rect(modal)
	modal.mouse_filter = Control.MOUSE_FILTER_STOP
	lobby.ui.add_child(modal)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.62)
	UI.full_rect(shade)
	modal.add_child(shade)
	var band := Control.new()
	band.anchor_right = 1.0
	band.anchor_top = 0.30
	band.anchor_bottom = 0.70
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.draw.connect(func() -> void: UI.draw_dialog_band(band, band.size))
	modal.add_child(band)
	var em := UI.texture("emblem.png")
	if em:
		var t := TextureRect.new()
		t.texture = em
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		t.anchor_left = 0.16
		t.anchor_right = 0.16
		t.anchor_top = 0.5
		t.anchor_bottom = 0.5
		t.offset_left = -84
		t.offset_right = 84
		t.offset_top = -84
		t.offset_bottom = 84
		t.modulate = Color(1, 1, 1, 0.9)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		band.add_child(t)
	var v := VBoxContainer.new()
	v.anchor_left = 0.3
	v.anchor_right = 0.95
	v.anchor_top = 0.0
	v.anchor_bottom = 1.0
	v.offset_top = 34
	v.offset_bottom = -26
	v.add_theme_constant_override("separation", 8)
	band.add_child(v)
	v.add_child(UI.label("QUIT THE GAME?", 38, UI.TEXT, "bold"))
	var bar := ColorRect.new()
	bar.color = UI.ACCENT
	bar.custom_minimum_size = Vector2(64, 4)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(bar)
	v.add_child(UI.spacer(2))
	v.add_child(UI.label("Your name, outfits, settings and progress stay saved on this phone.", 19, Color(1, 1, 1, 0.86), "semi"))
	var fill := UI.spacer(0)
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(fill)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(190, 56))
	cancel.name = "QuitCancel"
	cancel.pressed.connect(close_modal)
	row.add_child(cancel)
	var quit := UI.button("QUIT", 22, "primary", Vector2(190, 56))
	quit.name = "QuitConfirm"
	quit.pressed.connect(func() -> void: lobby.get_tree().quit())
	row.add_child(quit)
	modal.modulate.a = 0.0
	modal.create_tween().tween_property(modal, "modulate:a", 1.0, 0.12)
