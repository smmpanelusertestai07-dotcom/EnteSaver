class_name SettingsPanel
extends Control
## Settings: a full-screen modal with a tab column on the left (BASIC, CONTROLS, SENSITIVITY,
## SOUND), sectioned rows on dark plates, a close X (node "Close") top-right and a per-tab
## RESET bottom-left. Every change applies at once (Game.settings + Game.apply_settings());
## closing saves (Game.save_settings()) and emits `closed`. Works while the tree is paused.
## _show_tab(i) takes the index in TABS (the screenshot walkthrough opens 2 = CONTROLS).
## In a match (opened from the pause menu, or over the arena) the EDIT CUSTOM HUD button is
## replaced by a note: going to the editor would abandon the match.

signal closed

const TABS := ["BASIC", "SENSITIVITY", "CONTROLS", "SOUND"]
## Menu order on screen (indices into TABS).
const ORDER := [0, 2, 1, 3]
const TAB_KEYS := [
	["graphics", "fps", "show_fps", "damage_numbers", "vibration"],
	["sens_general", "sens_reddot", "sens_sniper", "sens_fire"],
	["aim_precision", "aim_assist", "aim_assist_strength", "left_fire", "hold_fire_scope", "reload_on_crosshair",
		"run_mode", "dynamic_joystick", "dynamic_crosshair", "crosshair_color", "crosshair_size"],
	["vol_master", "vol_sfx", "vol_music"],
]
const SENS_PRESETS := {
	"DEFAULT": {"sens_general": 100, "sens_reddot": 100, "sens_sniper": 71, "sens_fire": 100},
	"HIGH": {"sens_general": 185, "sens_reddot": 185, "sens_sniper": 150, "sens_fire": 150},
}
const MENU_W := 230.0

var _body: VBoxContainer
var _scroll: ScrollContainer
var _menu: VBoxContainer
var _menu_buttons := {}
var _current := 0
var _sens_rows := {}
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
	var reset := UI.button("RESET", 18, "ghost", Vector2(150, 46))
	reset.name = "Reset"
	reset.icon = UI.icon_texture("v_reload")
	reset.expand_icon = true
	reset.add_theme_constant_override("icon_max_width", 22)
	reset.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	reset.position = Vector2(24, -70)
	reset.pressed.connect(_reset_tab)
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
	var close := UI.close_button(54)
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


func _apply(key: String, value: Variant) -> void:
	Game.settings[key] = value
	Game.apply_settings()
	if key == "graphics":
		Game.settings_changed.emit()     # the arena re-applies its quality level at once


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
	_scroll.scroll_vertical = 0
	match _current:
		0:
			_body.add_child(UI.section("DISPLAY"))
			_body.add_child(UI.plate_row("Graphics", UI.segmented(Game.GRAPHICS_NAMES, int(Game.settings.graphics), func(v: int) -> void: _apply("graphics", v), 17, 104.0),
				"Low runs best on older phones; Extreme adds shadows, MSAA and glow"))
			var fps_opts: Array = Game.FPS_OPTIONS
			var labels := []
			for f in fps_opts:
				labels.append("%d FPS" % f)
			_body.add_child(UI.plate_row("Frame rate", UI.segmented(labels, maxi(fps_opts.find(int(Game.settings.fps)), 0), func(v: int) -> void: _apply("fps", fps_opts[v]), 17, 104.0)))
			_body.add_child(UI.plate_row("Show FPS", _toggle("show_fps")))
			_body.add_child(UI.spacer(6))
			_body.add_child(UI.section("GAMEPLAY"))
			_body.add_child(UI.plate_row("Damage numbers", _toggle("damage_numbers"), "Floating hit damage over the target"))
			_body.add_child(UI.plate_row("Vibration", _toggle("vibration"), "Short buzz on hits and eliminations"))
			_hint.text = "Graphics and frame rate apply at once. A lower frame rate saves battery."
		1:
			var head := HBoxContainer.new()
			head.add_theme_constant_override("separation", 12)
			var sec := UI.section("SENSITIVITY")
			sec.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			head.add_child(sec)
			head.add_child(UI.label("PRESET", 16, UI.TEXT_DIM, "bold"))
			var preset := _preset_index()
			head.add_child(UI.segmented(["DEFAULT", "HIGH"], preset, _apply_preset, 16, 110.0))
			_body.add_child(head)
			_sens_row("General", "sens_general", "Camera turn when dragging the right side")
			_sens_row("Red Dot", "sens_reddot", "While aiming down the red-dot sight")
			_sens_row("Sniper Scope", "sens_sniper", "While looking through the sniper scope")
			_sens_row("Fire-button drag", "sens_fire", "Turning while you hold and drag FIRE")
			_hint.text = "1-200. Higher turns the camera faster for the same swipe. DEFAULT = 100 / 100 / 71 / 100."
		2:
			_body.add_child(UI.section("SHOOTING"))
			_body.add_child(UI.plate_row("Aim precision", UI.segmented(Game.AIM_PRECISION_NAMES, int(Game.settings.aim_precision), func(v: int) -> void: _apply("aim_precision", v), 15, 150.0),
				"Assisted: always. Hip only: off while scoped. Manual: off"))
			_body.add_child(UI.plate_row("Aim assist", _toggle("aim_assist")))
			_body.add_child(UI.plate_row("Aim assist strength", UI.slider(Game.settings.aim_assist_strength, 0, 100, func(v: float) -> void: _apply("aim_assist_strength", int(v)))))
			_body.add_child(UI.plate_row("Left fire button", UI.segmented(Game.LEFT_FIRE_NAMES, int(Game.settings.left_fire), func(v: int) -> void: _apply("left_fire", v), 15, 140.0)))
			_body.add_child(UI.plate_row("Hold fire to scope", _toggle("hold_fire_scope"), "Sniper rifles: hold FIRE to scope, release to shoot"))
			_body.add_child(UI.plate_row("Reload progress on crosshair", _toggle("reload_on_crosshair")))
			_body.add_child(UI.spacer(6))
			_body.add_child(UI.section("MOVEMENT"))
			_body.add_child(UI.plate_row("Run mode", UI.segmented(Game.RUN_MODE_NAMES, int(Game.settings.run_mode), func(v: int) -> void: _apply("run_mode", v), 15, 120.0),
				"Drag: push the stick past the ring to sprint"))
			_body.add_child(UI.plate_row("Dynamic joystick", _toggle("dynamic_joystick"), "The stick follows your thumb"))
			_body.add_child(UI.spacer(6))
			_body.add_child(UI.section("CROSSHAIR"))
			_body.add_child(UI.plate_row("Crosshair colour", UI.segmented(Game.CROSSHAIR_COLOR_NAMES, int(Game.settings.crosshair_color), func(v: int) -> void: _apply("crosshair_color", v), 15, 104.0),
				"Always turns red on an enemy"))
			_body.add_child(UI.plate_row("Crosshair size", UI.slider(Game.settings.crosshair_size, 0, 100, func(v: float) -> void: _apply("crosshair_size", int(v)))))
			_body.add_child(UI.plate_row("Dynamic crosshair", _toggle("dynamic_crosshair"), "Spreads while moving and firing"))
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
		3:
			_body.add_child(UI.section("VOLUME"))
			_body.add_child(UI.plate_row("Master", UI.stepper(Game.settings.vol_master, 0, 100, func(v: float) -> void: _apply("vol_master", int(v)), 5.0)))
			_body.add_child(UI.plate_row("Effects", UI.stepper(Game.settings.vol_sfx, 0, 100, func(v: float) -> void: _apply("vol_sfx", int(v)), 5.0)))
			_body.add_child(UI.plate_row("Music", UI.stepper(Game.settings.vol_music, 0, 100, func(v: float) -> void: _apply("vol_music", int(v)), 5.0)))
			_hint.text = "0 mutes a channel."


func _sens_row(title: String, key: String, note: String) -> void:
	var st := UI.stepper(Game.settings[key], 1, 200, func(v: float) -> void: _apply(key, int(v)))
	_sens_rows[key] = st
	_body.add_child(UI.plate_row(title, st, note))


func _preset_index() -> int:
	for i in ["DEFAULT", "HIGH"].size():
		var p: Dictionary = SENS_PRESETS[["DEFAULT", "HIGH"][i]]
		var same := true
		for k in p:
			if int(Game.settings[k]) != int(p[k]):
				same = false
		if same:
			return i
	return -1


func _apply_preset(i: int) -> void:
	var p: Dictionary = SENS_PRESETS[["DEFAULT", "HIGH"][i]]
	for k in p:
		_apply(k, int(p[k]))
		if _sens_rows.has(k):
			var s: HSlider = (_sens_rows[k] as Control).get_meta("slider")
			s.set_value_no_signal(float(p[k]))
			var v := (_sens_rows[k] as HBoxContainer).get_child(0) as Label
			v.text = str(int(p[k]))


func _toggle(key: String) -> Control:
	return UI.segmented(["OFF", "ON"], 1 if Game.settings[key] else 0, func(v: int) -> void: _apply(key, v == 1), 17, 104.0)


## RESET puts the current tab's settings back to their defaults.
func _reset_tab() -> void:
	for k in TAB_KEYS[_current]:
		Game.settings[k] = Game.DEFAULT_SETTINGS[k]
	Game.apply_settings()
	_show_tab(_current)


func _close() -> void:
	Game.save_settings()
	closed.emit()
	queue_free()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree():
		_close()
