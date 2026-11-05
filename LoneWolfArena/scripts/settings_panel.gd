class_name SettingsPanel
extends Control
## Settings: a full-screen modal with a tab column on the left, sectioned rows on dark plates, a
## close X (node "Close") top-right and a per-tab RESET bottom-left that, once confirmed, puts the
## tab's settings (TAB_KEYS) back to their defaults. Every change applies at once (Game.settings +
## Game.apply_settings(); graphics and visual effects also through Game.settings_changed, which the
## arena and the lobby follow); closing saves (Game.save_settings()) and emits `closed`. Works
## while the tree is paused.
##  - BASIC: graphics AUTO / LOW .. EXTREME (AUTO marks the level it picked for this phone and
##    picks again after a frame-rate change; EXTREME asks first, it can heat the phone), frame rate
##    (30 and 60; 90 and 120 where the screen refreshes that fast), the FPS counter, visual effects,
##    vibration;
##  - SENSITIVITY: General, Red Dot, 2x Scope, Sniper Scope, Free Look and Fire Button Drag, with
##    the STANDARD / FAST presets;
##  - CONTROLS: dynamic joystick, aim precision, the left fire button, crosshair colour and size
##    (with a live preview), custom HUD;
##  - SOUND: master, effects, music.
## Questions (RESET, EXTREME) open over the panel as node "Confirm" (buttons "ConfirmOk" and
## "ConfirmCancel"); back closes them first.
## _show_tab(i) takes the index in TABS (the screenshot walkthrough opens 2 = CONTROLS).
## In a match (opened from the pause menu, or over the arena) the EDIT CUSTOM HUD button is
## replaced by a note: going to the editor would abandon the match.

signal closed

const TABS := ["BASIC", "SENSITIVITY", "CONTROLS", "SOUND"]
## Menu order on screen (indices into TABS).
const ORDER := [0, 2, 1, 3]
## The settings each tab shows, and its RESET puts back.
const TAB_KEYS := [
	["graphics_auto", "graphics", "fps", "show_fps", "visual_effects", "vibration"],
	["sens_general", "sens_reddot", "sens_2x", "sens_sniper", "sens_freelook", "sens_fire"],
	["dynamic_joystick", "aim_precision", "left_fire", "crosshair_color", "crosshair_size"],
	["vol_master", "vol_sfx", "vol_music"],
]
## Settings the scene applies when they change (Game.settings_changed); the rest are read live.
const SCENE_KEYS := ["visual_effects"]
## Settings no tab shows: chosen elsewhere (the mode and the bot level in the lobby, the gun at the
## pick) or the game's own bookkeeping.
const NOT_SHOWN := ["settings_version", "mode", "difficulty", "last_pick", "graphics_auto_done"]
const GRAPHICS_CHOICES := ["AUTO", "LOW", "MEDIUM", "HIGH", "EXTREME"]
## Names of Game.CROSSHAIR_COLORS, in its order.
const COLOR_NAMES := ["WHITE", "GREEN", "YELLOW", "CYAN"]
## The choices of the settings aim_precision and left_fire, by value, with aim precision's notes.
const PRECISION_NAMES := ["ASSISTED", "MANUAL IN SCOPE", "FULL MANUAL"]
const PRECISION_NOTES := [
	"The aim sticks to an enemy and holds the head or body you drag to",
	"No aim assist while aiming down a sight; assisted from the hip",
	"No aim assist: shots go exactly where you aim",
]
const LEFT_FIRE_NAMES := ["ALWAYS", "WHEN AIMING"]
## The sensitivity rows top to bottom: [title, setting, note].
const SENS_ROWS := [
	["General", "sens_general", "Camera turn when dragging the right side"],
	["Red Dot", "sens_reddot", "While aiming down the red-dot sight"],
	["2x Scope", "sens_2x", "While aiming through a 2x scope"],
	["Sniper Scope", "sens_sniper", "While looking through the sniper scope"],
	["Free Look", "sens_freelook", "Turning the camera with the eye button"],
	["Fire Button Drag", "sens_fire", "Fire-button drags turn at this % of the view's speed"],
]
## STANDARD is the defaults; FAST our quicker set, in the usual order (Red Dot >= General > 2x >
## Sniper).
const PRESET_NAMES := ["STANDARD", "FAST"]
const SENS_PRESETS := {
	"STANDARD": {"sens_general": 100, "sens_reddot": 100, "sens_2x": 100, "sens_sniper": 71, "sens_freelook": 100, "sens_fire": 100},
	"FAST": {"sens_general": 165, "sens_reddot": 170, "sens_2x": 150, "sens_sniper": 125, "sens_freelook": 140, "sens_fire": 100},
}
const MENU_W := 230.0

var _body: VBoxContainer
var _scroll: ScrollContainer
var _menu: VBoxContainer
var _menu_buttons := {}
var _current := 0
var _sens_rows := {}
var _preset_seg: HBoxContainer
var _graphics_seg: HBoxContainer
var _graphics_note: Label
var _aim_note: Label
var _preview: Control
var _ask_layer: Control
var _hint: Label
## True when opened during a match (set by the pause menu; also detected from the scene).
var in_match := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var scene := get_tree().current_scene
	if scene and scene.has_method("open_pause"):
		in_match = true
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.02, 0.025, 0.8)
	UI.full_rect(shade)
	add_child(shade)
	var bg := UI.gradient_rect([[0.0, Color(0.11, 0.09, 0.07, 0.96)], [0.55, Color(0.07, 0.065, 0.06, 0.97)], [1.0, Color(0.05, 0.05, 0.055, 0.98)]], true)
	UI.full_rect(bg)
	add_child(bg)
	# Left tab column.
	var col := Panel.new()
	col.add_theme_stylebox_override("panel", UI.box(Color(0, 0, 0, 0.45), 0, 0, Color.TRANSPARENT, 0.0))
	col.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	col.offset_right = MENU_W
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)
	_menu = VBoxContainer.new()
	_menu.add_theme_constant_override("separation", 6)
	_menu.position = Vector2(0, 74)
	_menu.custom_minimum_size = Vector2(MENU_W, 0)
	add_child(_menu)
	for i in ORDER:
		var b := _menu_button(TABS[i], i)
		_menu.add_child(b)
		_menu_buttons[i] = b
	var reset := UI.button("RESET", 18, "ghost", Vector2(150, UI.TOUCH_MIN))
	reset.name = "Reset"
	reset.icon = UI.icon_texture("v_reload")
	reset.expand_icon = true
	reset.add_theme_constant_override("icon_max_width", 22)
	reset.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	reset.position = Vector2(24, -70)
	reset.pressed.connect(_ask_reset)
	add_child(reset)
	# Header: title + close.
	var title := UI.label("SETTINGS", 30, UI.TEXT, "heavy")
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title.offset_left = -360
	title.offset_right = -84
	title.offset_top = 16
	title.offset_bottom = 60
	add_child(title)
	var close := UI.close_button(UI.TOUCH_MIN)
	close.name = "Close"
	close.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	close.offset_left = -66
	close.offset_right = -12
	close.offset_top = 10
	close.offset_bottom = 64
	close.pressed.connect(_close)
	add_child(close)
	var underline := ColorRect.new()
	underline.color = Color(UI.ACCENT, 0.85)
	underline.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	underline.offset_left = -126
	underline.offset_right = -84
	underline.offset_top = 58
	underline.offset_bottom = 61
	underline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(underline)
	# Content.
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_left = MENU_W + 28
	_scroll.offset_right = -28
	_scroll.offset_top = 74
	_scroll.offset_bottom = -64
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	UI.style_scroll(_scroll)
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	_scroll.add_child(_body)
	_hint = UI.label("", 16, UI.TEXT_DIM, "semi")
	_hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.offset_left = MENU_W + 28
	_hint.offset_right = -28
	_hint.offset_top = -52
	_hint.offset_bottom = -16
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_hint)
	# AUTO's pick can arrive while the panel is open (the measurement ends): BASIC shows it.
	Game.settings_changed.connect(_refresh_graphics)
	_show_tab(0)
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.18)


func _menu_button(text: String, idx: int) -> Button:
	var b := Button.new()
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(MENU_W, 58)
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 24)
	var normal := UI.box(Color(0, 0, 0, 0), 0, 0, Color.TRANSPARENT, 24.0)
	var hover := UI.box(Color(1, 1, 1, 0.06), 0, 0, Color.TRANSPARENT, 24.0)
	var on := UI.chamfer(UI.ACCENT, 12, 0, Color.TRANSPARENT, 24.0, ["br"])
	for st in [normal, hover, on]:
		st.content_margin_left = 26
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	# hazard stripes, corner cut and notch on the selected (yellow) tab
	b.draw.connect(func() -> void:
		if b.button_pressed:
			UI.draw_tab_selected(b, b.size))
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_show_tab(idx))
	return b


## A setting changed on the panel: it applies at once (the scene reads most of them live; it
## re-applies SCENE_KEYS on settings_changed).
func _apply(key: String, value: Variant) -> void:
	Game.settings[key] = value
	Game.apply_settings()
	if key in SCENE_KEYS:
		Game.settings_changed.emit()
	if key == "vibration" and bool(value):
		Game.vibrate(40)                # a short buzz: this is what it does
	if _preview:
		_preview.queue_redraw()


func _show_tab(i: int) -> void:
	_current = clampi(i, 0, TABS.size() - 1)
	for k in _menu_buttons:
		var b: Button = _menu_buttons[k]
		b.set_pressed_no_signal(k == _current)
		b.queue_redraw()
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	_sens_rows.clear()
	_preset_seg = null
	_graphics_seg = null
	_graphics_note = null
	_aim_note = null
	_preview = null
	_scroll.scroll_vertical = 0
	match _current:
		0:
			_build_basic()
		1:
			_build_sensitivity()
		2:
			_build_controls()
		3:
			_build_sound()
	# A finger drag that starts on a row scrolls the tab (a tap still presses); a slider keeps its
	# own drag, so moving one never scrolls the list.
	UI.drag_scroll(_scroll, _body)
	for s in _body.find_children("*", "Slider", true, false):
		(s as Control).mouse_filter = Control.MOUSE_FILTER_STOP


# ---------------------------------------------------------------- BASIC

func _build_basic() -> void:
	_body.add_child(UI.section("DISPLAY"))
	var sel := 0 if bool(Game.settings.graphics_auto) else int(Game.settings.graphics) + 1
	_graphics_seg = UI.segmented(GRAPHICS_CHOICES, sel, _on_graphics, 17, 104.0)
	_graphics_seg.name = "GraphicsChoice"
	for i in range(1, _graphics_seg.get_child_count()):
		var b := _graphics_seg.get_child(i) as Button
		var level := i - 1
		b.draw.connect(func() -> void:
			# AUTO's pick: a short accent bar under its caption
			if bool(Game.settings.graphics_auto) and int(Game.settings.graphics) == level:
				b.draw_rect(Rect2(b.size.x * 0.3, b.size.y - 8.0, b.size.x * 0.4, 3.0), UI.ACCENT))
	var row := UI.plate_row("Graphics", _graphics_seg, "-")
	_graphics_note = _note_of(row)
	_body.add_child(row)
	_refresh_graphics()
	var fps_opts := Game.fps_choices()
	var labels := []
	var fps_sel := 0
	for k in fps_opts.size():
		labels.append("%d FPS" % int(fps_opts[k]))
		if int(fps_opts[k]) <= int(Game.settings.fps):
			fps_sel = k        # a saved rate this screen can't show: the fastest it can
	var fps_seg := UI.segmented(labels, fps_sel, func(v: int) -> void: _set_fps(int(fps_opts[v])), 17, 104.0)
	fps_seg.name = "FpsChoice"
	_body.add_child(UI.plate_row("Frame rate", fps_seg, _fps_note(fps_opts)))
	_body.add_child(UI.plate_row("Show FPS", _toggle("show_fps"), "The frame rate under the minimap in a match"))
	_body.add_child(UI.plate_row("Visual effects", _toggle("visual_effects"), "Lights on shots and blasts, full sparks; off helps weak phones"))
	_body.add_child(UI.spacer(4))
	_body.add_child(UI.section("FEEDBACK"))
	_body.add_child(UI.plate_row("Vibration", _toggle("vibration"), "A buzz when you are hit, on a kill and on heavy shots"))
	_hint.text = "Changes apply at once. In a match the 3D view draws a little smaller while frames run slow; the HUD stays sharp."


## The frame-rate row's note: which rates this screen can't show, if any.
func _fps_note(shown: Array) -> String:
	var missing := PackedStringArray()
	for f: int in Game.FPS_OPTIONS:
		if not (f in shown):
			missing.append(str(f))
	if missing.is_empty():
		return "Higher is smoother, lower saves battery"
	return "%s FPS %s a faster screen" % [" and ".join(missing), "needs" if missing.size() == 1 else "need"]


## A graphics choice: 0 AUTO, then LOW .. EXTREME. EXTREME asks first (it can heat the phone); until
## the answer the row keeps showing the current choice.
func _on_graphics(i: int) -> void:
	if i == GRAPHICS_CHOICES.size() - 1 and not (int(Game.settings.graphics) == i - 1 and not bool(Game.settings.graphics_auto)):
		_refresh_graphics()
		_ask("EXTREME GRAPHICS", "Extreme can make the phone hot and empty the battery faster, and frames may drop. Use it anyway?",
			"USE EXTREME", func() -> void: _set_graphics(i))
		return
	_set_graphics(i)


func _set_graphics(i: int) -> void:
	if i == 0:
		Game.start_auto_graphics()
	else:
		Game.stop_auto_graphics()
		Game.settings.graphics = i - 1
	Game.apply_settings()
	Game.settings_changed.emit()          # the arena / lobby re-apply graphics at once
	_refresh_graphics()


func _set_fps(f: int) -> void:
	if f == int(Game.settings.fps):
		return
	Game.settings.fps = f
	Game.apply_settings()
	if bool(Game.settings.graphics_auto):
		Game.start_auto_graphics()        # AUTO picks again for the new frame rate
		Game.settings_changed.emit()


## The graphics row as the settings are now: AUTO or the level selected, AUTO's pick marked
## (accent caption and bar) and named in the note.
func _refresh_graphics() -> void:
	if _graphics_seg == null or not is_instance_valid(_graphics_seg):
		return
	var auto := bool(Game.settings.graphics_auto)
	var level := clampi(int(Game.settings.graphics), 0, Game.GRAPHICS_NAMES.size() - 1)
	for i in _graphics_seg.get_child_count():
		var b := _graphics_seg.get_child(i) as Button
		b.set_pressed_no_signal(i == (0 if auto else level + 1))
		var col := UI.ACCENT if auto and i == level + 1 else UI.TEXT
		b.add_theme_color_override("font_color", col)
		b.add_theme_color_override("font_hover_color", col)
		b.queue_redraw()
	if _graphics_note and is_instance_valid(_graphics_note):
		var picked := String(Game.GRAPHICS_NAMES[level])
		if auto and Game.auto_graphics_pending:
			_graphics_note.text = "AUTO: %s for now, checking this phone" % picked
		elif auto:
			_graphics_note.text = "AUTO picked %s for this phone" % picked
		else:
			_graphics_note.text = "Low runs best on older phones; Extreme adds shadows, MSAA and glow"


## The dim note under a UI.plate_row's title.
static func _note_of(row: Control) -> Label:
	var v := row.get_child(0).get_child(0)
	return v.get_child(v.get_child_count() - 1) as Label


# ---------------------------------------------------------------- SENSITIVITY

func _build_sensitivity() -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	var sec := UI.section("SENSITIVITY")
	sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sec)
	head.add_child(UI.label("PRESET", 16, UI.TEXT_DIM, "bold"))
	_preset_seg = UI.segmented(PRESET_NAMES, _preset_index(), _apply_preset, 16, 110.0)
	head.add_child(_preset_seg)
	_body.add_child(head)
	var defaults := PackedStringArray()
	for r: Array in SENS_ROWS:
		var note := String(r[2])
		if r[1] == "sens_2x":
			note += " (%s)" % ", ".join(guns_with_sight("2x"))
		_sens_row(String(r[0]), String(r[1]), note)
		defaults.append(str(SENS_PRESETS.STANDARD[r[1]]))
	_hint.text = "1-200. Higher turns faster for the same swipe. STANDARD = %s." % " / ".join(defaults)


## The pickable guns' names that aim through `sight` (Player.sight_of).
static func guns_with_sight(sight: String) -> PackedStringArray:
	var out := PackedStringArray()
	for id: String in Weapons.PICKABLE:
		if Player.sight_of(Weapons.DEFS[id]) == sight:
			out.append(String(Weapons.DEFS[id].name))
	return out


func _sens_row(title: String, key: String, note: String) -> void:
	var st := UI.stepper(Game.settings[key], 1, 200, func(v: float) -> void:
		_apply(key, int(v))
		_refresh_preset())
	st.name = "Sens_" + key
	_sens_rows[key] = st
	_body.add_child(UI.plate_row(title, st, note))


func _preset_index() -> int:
	for i in PRESET_NAMES.size():
		var p: Dictionary = SENS_PRESETS[PRESET_NAMES[i]]
		var same := true
		for k: String in p:
			if int(Game.settings[k]) != int(p[k]):
				same = false
		if same:
			return i
	return -1


func _apply_preset(i: int) -> void:
	var p: Dictionary = SENS_PRESETS[PRESET_NAMES[i]]
	for k: String in p:
		_apply(k, int(p[k]))
		if _sens_rows.has(k):
			var s: HSlider = (_sens_rows[k] as Control).get_meta("slider")
			s.set_value_no_signal(float(p[k]))
			var v := (_sens_rows[k] as HBoxContainer).get_child(0) as Label
			v.text = str(int(p[k]))
	_refresh_preset()


## The preset buttons show which preset the sliders match (none after a slider moved off it).
func _refresh_preset() -> void:
	if _preset_seg == null or not is_instance_valid(_preset_seg):
		return
	var at := _preset_index()
	for i in _preset_seg.get_child_count():
		(_preset_seg.get_child(i) as Button).set_pressed_no_signal(i == at)


# ---------------------------------------------------------------- CONTROLS

func _build_controls() -> void:
	_body.add_child(UI.section("MOVEMENT"))
	_body.add_child(UI.plate_row("Dynamic joystick", _toggle("dynamic_joystick"), "The stick follows your thumb"))
	_body.add_child(UI.spacer(4))
	_body.add_child(UI.section("SHOOTING"))
	var precision := clampi(int(Game.settings.aim_precision), 0, PRECISION_NAMES.size() - 1)
	var aim_seg := UI.segmented(PRECISION_NAMES, precision, _set_precision, 16, 172.0)
	aim_seg.name = "AimPrecision"
	var aim_row := UI.plate_row("Aim precision", aim_seg, String(PRECISION_NOTES[precision]))
	_aim_note = _note_of(aim_row)
	_body.add_child(aim_row)
	var left_fire := UI.segmented(LEFT_FIRE_NAMES, int(Game.settings.left_fire), func(v: int) -> void: _apply("left_fire", v), 16, 150.0)
	left_fire.name = "LeftFire"
	_body.add_child(UI.plate_row("Left fire button", left_fire, "Shown always, or only while aiming down a sight"))
	_body.add_child(UI.spacer(4))
	_body.add_child(UI.section("CROSSHAIR"))
	var cross := HBoxContainer.new()
	cross.add_theme_constant_override("separation", 8)
	var rows := VBoxContainer.new()
	rows.add_theme_constant_override("separation", 8)
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var colors := UI.segmented(COLOR_NAMES, int(Game.settings.crosshair_color), func(v: int) -> void: _apply("crosshair_color", v), 16, 118.0)
	colors.name = "CrosshairColor"
	for i in colors.get_child_count():
		_add_swatch(colors.get_child(i) as Button, Game.CROSSHAIR_COLORS[i])
	rows.add_child(UI.plate_row("Colour", colors, "It turns red on an enemy whatever its colour"))
	var size_st := UI.stepper(Game.settings.crosshair_size, 50, 150, func(v: float) -> void: _apply("crosshair_size", int(v)), 5.0)
	size_st.name = "CrosshairSize"
	rows.add_child(UI.plate_row("Size", size_st, "50-150 % of the standard size"))
	cross.add_child(rows)
	_preview = CrosshairPreview.new()
	_preview.name = "CrosshairPreview"
	_preview.custom_minimum_size = Vector2(150, 0)
	cross.add_child(_preview)
	_body.add_child(cross)
	_body.add_child(UI.spacer(6))
	if in_match:
		var note := UI.label("IN THE LOBBY", 17, UI.TEXT_DIM, "bold")
		note.name = "EditHudNote"
		_body.add_child(UI.plate_row("Custom HUD", note, "Leaving for the editor now would end this match"))
		_hint.text = "Custom HUD: open it from the lobby to move, resize and fade every in-match button."
	else:
		var hud_btn := UI.button("EDIT CUSTOM HUD", 20, "light", Vector2(300, 52))
		hud_btn.name = "EditHud"
		hud_btn.pressed.connect(func() -> void:
			Game.save_settings()
			Game.goto_hud_editor())
		var r := HBoxContainer.new()
		r.add_child(hud_btn)
		_body.add_child(r)
		_hint.text = "Custom HUD: move, resize and fade every in-match button."


func _set_precision(v: int) -> void:
	_apply("aim_precision", v)
	if _aim_note and is_instance_valid(_aim_note):
		_aim_note.text = String(PRECISION_NOTES[v])


## A colour choice button: its colour as a dot left of the name (the name moves right for it).
func _add_swatch(b: Button, col: Color) -> void:
	for state: String in ["normal", "hover", "pressed", "hover_pressed"]:
		var st := b.get_theme_stylebox(state).duplicate() as StyleBox
		st.content_margin_left = 30.0
		b.add_theme_stylebox_override(state, st)
	b.draw.connect(func() -> void:
		var c := Vector2(17.0, b.size.y * 0.5)
		b.draw_circle(c, 7.5, Color(0, 0, 0, 0.75))
		b.draw_circle(c, 6.0, col))


## The match's rifle crosshair (HUD._draw_crosshair: ring and centre dot) at the chosen colour and
## size, over a patch of the arena's grey wall.
class CrosshairPreview extends Control:
	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		var top := Color(0.52, 0.54, 0.57)
		var bottom := Color(0.3, 0.31, 0.33)
		draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, 0.0), r.end, Vector2(0.0, r.end.y)]),
			PackedColorArray([top, top, bottom, bottom]))
		draw_rect(r, Color(1, 1, 1, 0.16), false, 1.0)
		draw_string(UI.font("bold"), Vector2(8, 17), "PREVIEW", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.7))
		var c := size * 0.5 + Vector2(0, 6)
		var sc := Game.crosshair_scale()
		var col := Game.crosshair_color()
		var ring_r := 0.028 * HudLayout.unit(get_viewport_rect().size) * sc
		HudDraw.ring(self, c, ring_r, Color(0, 0, 0, 0.3), 3.0)
		HudDraw.ring(self, c, ring_r, Color(col, col.a * 0.92), 1.4)
		HudDraw.disk(self, c, 2.6 * sc, Color(0, 0, 0, 0.45))
		HudDraw.disk(self, c, 1.7 * sc, col)


# ---------------------------------------------------------------- SOUND

func _build_sound() -> void:
	_body.add_child(UI.section("VOLUME"))
	_body.add_child(UI.plate_row("Master", UI.stepper(Game.settings.vol_master, 0, 100, func(v: float) -> void: _apply("vol_master", int(v)), 5.0)))
	_body.add_child(UI.plate_row("Effects", UI.stepper(Game.settings.vol_sfx, 0, 100, func(v: float) -> void: _apply("vol_sfx", int(v)), 5.0)))
	_body.add_child(UI.plate_row("Music", UI.stepper(Game.settings.vol_music, 0, 100, func(v: float) -> void: _apply("vol_music", int(v)), 5.0)))
	_hint.text = "0 mutes a channel."


func _toggle(key: String) -> Control:
	var t := UI.segmented(["OFF", "ON"], 1 if Game.settings[key] else 0, func(v: int) -> void: _apply(key, v == 1), 17, 104.0)
	t.name = "Toggle_" + key
	return t


## RESET asks before it puts the current tab back.
func _ask_reset() -> void:
	var tab := String(TABS[_current])
	_ask("RESET " + tab, "Put every %s setting back to its default?" % tab, "RESET", _reset_tab)


## A question over the panel: ok_text runs on_ok, CANCEL (or back) only closes it.
func _ask(title: String, text: String, ok_text: String, on_ok: Callable) -> void:
	_close_ask()
	var layer := Control.new()
	layer.name = "Confirm"
	UI.full_rect(layer)
	layer.mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.62)
	UI.full_rect(shade)
	layer.add_child(shade)
	var center := CenterContainer.new()
	UI.full_rect(center)
	layer.add_child(center)
	var box := UI.panel(Color(0.085, 0.08, 0.075, 0.98), 12, 1)
	center.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 16)
	box.add_child(v)
	v.add_child(UI.section(title, 24))
	var l := UI.label(text, 19, UI.TEXT, "semi")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(540, 0)
	v.add_child(l)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var no := UI.button("CANCEL", 18, "light", Vector2(170, 50))
	no.name = "ConfirmCancel"
	no.pressed.connect(_close_ask)
	var yes := UI.button(ok_text, 18, "primary", Vector2(200, 50))
	yes.name = "ConfirmOk"
	yes.pressed.connect(func() -> void:
		_close_ask()
		on_ok.call())
	row.add_child(no)
	row.add_child(yes)
	v.add_child(row)
	add_child(layer)
	_ask_layer = layer


func _close_ask() -> void:
	if _ask_layer and is_instance_valid(_ask_layer):
		_ask_layer.queue_free()
	_ask_layer = null


## RESET (once confirmed) puts the current tab's settings back to their defaults (BASIC: AUTO
## graphics picks afresh for this phone).
func _reset_tab() -> void:
	var keys: Array = TAB_KEYS[_current]
	for k: String in keys:
		Game.settings[k] = Game.DEFAULT_SETTINGS[k]
	if "graphics_auto" in keys:
		if bool(Game.settings.graphics_auto):
			Game.start_auto_graphics()
		else:
			Game.stop_auto_graphics()
	Game.apply_settings()
	if "graphics" in keys or keys.any(func(k: String) -> bool: return k in SCENE_KEYS):
		Game.settings_changed.emit()
	_show_tab(_current)


func _close() -> void:
	Game.save_settings()
	closed.emit()
	queue_free()


## Android back: answers an open question first, else closes the panel; never while something was
## opened on top of it (a challenge popup in the lobby: that one takes the back).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree():
		if covered():
			return
		if _ask_layer and is_instance_valid(_ask_layer):
			_close_ask()            # back answers an open question first
		else:
			_close()


## True while a visible Control was put on top of this panel (a later sibling: the lobby's popup
## for a challenge or a friend request that came in meanwhile).
func covered() -> bool:
	var p := get_parent()
	if p == null:
		return false
	for i in range(get_index() + 1, p.get_child_count()):
		var c := p.get_child(i) as Control
		if c != null and c.visible and not c.is_queued_for_deletion():
			return true
	return false
