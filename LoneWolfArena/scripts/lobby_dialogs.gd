class_name LobbyDialogs
extends RefCounted
## The lobby's popups: the popup frame they share (open_modal / close_modal, one at a time, in
## `modal`), SELECT MODE, HOW TO PLAY, the player name editor with the first-start name prompt,
## and the "Quit the game?" dialog. The lobby makes it (Lobby.dialogs) and its parts open popups
## through it; everything is built under the lobby's UI layer.
## Node names: Modal (or QuitDialog), Close, Mode_<training|lonewolf>, NameEdit, NameRandom,
## NameOk, QuitCancel, QuitConfirm. Markers: "name prompt" and "ui name_ok" (the emulator test
## taps OK there).

## SELECT MODE: what each mode's card says under its name ({rounds}: Game.ROUNDS_TO_WIN).
const MODE_INFO := {
	"training": {"tag": "VS BOT", "lines": ["1 VS BOT: EASY, NORMAL OR HARD", "OR THE TARGET DUMMY, TO PRACTISE YOUR AIM"]},
	"lonewolf": {"tag": "ONLINE", "lines": ["1 VS 1 AGAINST ANOTHER PLAYER", "PLAYERS ONLINE, FRIENDS OR A CUSTOM ROOM"]},
}
## HOW TO PLAY. Texts may hold {rounds} (Game.ROUNDS_TO_WIN). MODES spans the width on top, the
## other groups fill two columns under it.
const HOW_TO_MODES := ["MODES", [
	["v_crosshair", "TRAINING GROUND", "1 vs a bot (EASY, NORMAL or HARD), first to {rounds} rounds on CARGO CAGE. Or the TARGET DUMMY: it never goes down, no zone, no clock, nothing counted."],
	["v_player", "LONE WOLF", "1 vs 1 online against another player, first to {rounds}. START opens the ONLINE list: duel a player online, a friend or a CUSTOM ROOM."],
]]
const HOW_TO := [
	["MOVE & LOOK", [
		["stance_sprint", "MOVE", "Left thumb on the joystick. Push it past the ring to sprint."],
		["v_eye", "LOOK  ·  FREE LOOK", "Drag on the right side to turn the camera. Hold the eye and drag to look all around, even at your own face."],
		["v_fire", "FIRE", "Hold the big button to shoot; keep holding and drag to aim while firing."],
		["v_scope", "SCOPE", "Aim down the red dot, or the sniper scope with a sniper rifle."],
		["stance_crouch", "CROUCH · PRONE · JUMP", "Crouch and prone make you a smaller target; jump onto crates."],
		["v_reload", "RELOAD", "Tap the weapon panel (or it reloads by itself when the magazine is empty)."],
	]],
	["ITEMS", [
		["v_medkit", "MEDKIT  x2", "+75 HP over 4 seconds. You walk slower; firing cancels it."],
		["v_wall", "SHIELD WALL  x2", "Tap it, then FIRE: frozen-foam cover that soaks 600 damage for 45 seconds."],
		["item_grenade", "FRAG GRENADE  x1", "Tap it, then FIRE to throw along the arc. Up to 150 damage (a vest stops a third), 3 s fuse."],
	]],
	["THE MATCH", [
		["v_player", "FIRST TO {rounds} ROUNDS", "1 vs 1, 200 HP each, Lv2 helmet and vest. Win {rounds} rounds to win the match."],
		["v_timer", "PICK THE GUN", "Every 2 rounds one side picks the gun you both use (12 guns, fixed attachments); the pick takes turns."],
		["v_zone", "SAFE ZONE", "Holds 25 s, then shrinks. Outside it you lose HP; at time-out more HP wins."],
	]],
]

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
	var head := UI.popup_header(title, 26, 54.0)
	(head.get_node("Close") as Button).pressed.connect(close_modal)
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


# ---------------------------------------------------------------- select mode

## SELECT MODE (the lobby's mode card opens it): the two modes as cards (art, name, map, what
## START plays, this player's numbers in it). A tap picks one, which START then plays (kept as
## the setting "mode"), and closes the popup.
func select_mode() -> void:
	var v := open_modal("SELECT MODE", 980.0)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	v.add_child(row)
	for m: String in Game.MODE_NAMES:
		row.add_child(_mode_choice(m))
	v.add_child(UI.label("Both are played 1 vs 1 on CARGO CAGE, first to %d rounds; the gun is picked every 2 rounds." % Game.ROUNDS_TO_WIN,
		16, UI.TEXT_DIM, "semi"))


## One mode's card in SELECT MODE (node Mode_<m>): yellow outline and tick on the current mode.
func _mode_choice(m: String) -> Button:
	var info: Dictionary = MODE_INFO.get(m, MODE_INFO[Game.DEFAULT_MODE])
	var card := Button.new()
	card.name = "Mode_" + m
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = Vector2(440, 340)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		card.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var art_h := 186.0
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
	var v := VBoxContainer.new()
	v.position = Vector2(18, art_h + 8)
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
	for line: String in info.lines:
		v.add_child(UI.label(line, 15, UI.TEXT_DIM, "bold"))
	var n: Dictionary = (Game.profile.modes as Dictionary).get(m, {})
	var stats := UI.label("MATCHES %d   ·   WINS %d   ·   KILLS %d" % [int(n.get("matches", 0)), int(n.get("wins", 0)), int(n.get("kills", 0))],
		15, UI.TEXT, "bold")
	stats.name = "ModeStats"
	v.add_child(UI.spacer(4))
	v.add_child(stats)
	card.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		Game.mode = m
		Game.save_settings()
		close_modal()
		lobby._refresh_mode())
	return card


# ---------------------------------------------------------------- how to play

func how_to_play() -> void:
	var v := open_modal("HOW TO PLAY", 1040.0)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 520)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var page := VBoxContainer.new()
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", 6)
	scroll.add_child(page)
	# MODES across the top: the two modes side by side.
	page.add_child(UI.section(String(HOW_TO_MODES[0]), 18))
	var modes := HBoxContainer.new()
	modes.name = "HowToModes"
	modes.add_theme_constant_override("separation", 24)
	page.add_child(modes)
	for it: Array in HOW_TO_MODES[1]:
		var item := _howto_item(String(it[0]), _rounds_text(String(it[1])), _rounds_text(String(it[2])))
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		modes.add_child(item)
	page.add_child(UI.spacer(6))
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 24)
	page.add_child(cols)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	cols.add_child(left)
	cols.add_child(right)
	for gi in HOW_TO.size():
		var g: Array = HOW_TO[gi]
		var col := left if gi == 0 else right
		if gi > 1:
			col.add_child(UI.spacer(6))
		col.add_child(UI.section(String(g[0]), 18))
		for it in g[1]:
			col.add_child(_howto_item(String(it[0]), _rounds_text(String(it[1])), _rounds_text(String(it[2]))))


## A HOW TO PLAY text with {rounds} filled in (the rounds a match is played to).
static func _rounds_text(t: String) -> String:
	return t.format({"rounds": Game.ROUNDS_TO_WIN})


func _howto_item(icon_name: String, title: String, text: String) -> Control:
	var p := PanelContainer.new()
	var st := UI.chamfer(Color(1, 1, 1, 0.045), 6, 0, Color.TRANSPARENT, 10.0, ["br"])
	st.content_margin_top = 5
	st.content_margin_bottom = 5
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var ic := PanelContainer.new()
	var ics := UI.box(Color(0, 0, 0, 0.45), 21, 1, Color(1, 1, 1, 0.18), 0.0)
	ics.set_content_margin_all(7)
	ic.add_theme_stylebox_override("panel", ics)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ic.add_child(UI.icon(icon_name, 28, UI.TEXT))
	h.add_child(ic)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(title, 17, UI.ACCENT, "bold"))
	var t := UI.label(text, 15, UI.TEXT, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(380, 0)
	v.add_child(t)
	h.add_child(v)
	p.add_child(h)
	return p


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
	le.custom_minimum_size = Vector2(0, 54)
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
	var dice := UI.button("RANDOM", 20, "light", Vector2(150, 54))
	dice.name = "NameRandom"
	dice.pressed.connect(func() -> void:
		le.text = Game.random_name()
		le.caret_column = le.text.length()
		Audio.play("ui_click", -4.0))
	line.add_child(dice)
	v.add_child(line)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var cancel := UI.button("KEEP" if first else "CANCEL", 20, "light", Vector2(170, 52))
	var keep := func() -> void:
		if first:
			Game.profile.name_set = true
			Game.save_profile()
		close_modal()
	cancel.pressed.connect(keep)
	var ok := UI.button("OK", 22, "primary", Vector2(170, 52))
	ok.name = "NameOk"
	var apply := func() -> void:
		var n := Game.clean_name(le.text)
		if n != "":
			Game.profile.name = n
			lobby._name_label.text = n
			lobby._plate_label.text = n
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
	var cancel := UI.button("CANCEL", 20, "light", Vector2(190, 52))
	cancel.name = "QuitCancel"
	cancel.pressed.connect(close_modal)
	row.add_child(cancel)
	var quit := UI.button("QUIT", 22, "primary", Vector2(190, 52))
	quit.name = "QuitConfirm"
	quit.pressed.connect(func() -> void: lobby.get_tree().quit())
	row.add_child(quit)
	modal.modulate.a = 0.0
	modal.create_tween().tween_property(modal, "modulate:a", 1.0, 0.12)
