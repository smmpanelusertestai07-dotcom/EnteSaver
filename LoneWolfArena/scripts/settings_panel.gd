class_name SettingsPanel
extends Control
## Modal settings screen with tabs (Basic, Sensitivity, Controls, Audio). Changes apply
## live and are saved to user://settings.json when the panel closes.

signal closed

var _tabs: HBoxContainer
var _body: VBoxContainer
var _current := 0
const TABS := ["BASIC", "SENSITIVITY", "CONTROLS", "AUDIO"]


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	UI.full_rect(self)
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.65)
	UI.full_rect(overlay)
	add_child(overlay)
	var margin := MarginContainer.new()
	UI.full_rect(margin)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 36 if side in ["left", "right"] else 22)
	add_child(margin)
	var panel := UI.panel(UI.PANEL, 16)
	margin.add_child(panel)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	panel.add_child(root)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	root.add_child(header)
	var title := UI.label("SETTINGS", 40, UI.TEXT, "title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var reset := UI.button("RESET", 20, "ghost", Vector2(130, 50))
	reset.pressed.connect(func() -> void:
		Game.reset_settings()
		_show_tab(_current))
	header.add_child(reset)
	var close := UI.button("CLOSE", 22, "primary", Vector2(150, 50))
	close.name = "Close"
	close.pressed.connect(_close)
	header.add_child(close)
	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 8)
	root.add_child(_tabs)
	var seg := UI.segmented(TABS, 0, _show_tab, 20, 180.0)
	_tabs.add_child(seg)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 16)
	scroll.add_child(_body)
	_show_tab(0)


func _apply(key: String, value: Variant) -> void:
	Game.settings[key] = value
	Game.apply_settings()


func _show_tab(i: int) -> void:
	_current = i
	for c in _body.get_children():
		c.queue_free()
	match i:
		0:
			_body.add_child(UI.row("Graphics quality", UI.segmented(Game.GRAPHICS_NAMES, int(Game.settings.graphics), func(v: int) -> void: _apply("graphics", v))))
			var fps_opts := [30, 60, 90]
			_body.add_child(UI.row("Frame rate", UI.segmented(["30 FPS", "60 FPS", "90 FPS"], maxi(fps_opts.find(int(Game.settings.fps)), 0), func(v: int) -> void: _apply("fps", fps_opts[v]))))
			_body.add_child(UI.row("Show FPS", _toggle("show_fps")))
			_body.add_child(UI.row("Damage numbers", _toggle("damage_numbers")))
			_body.add_child(UI.row("Vibration", _toggle("vibration")))
			_body.add_child(_hint("Smooth = best performance on older phones. Ultra = shadows, MSAA and lighting effects."))
		1:
			_body.add_child(UI.row("General", UI.slider(Game.settings.sens_general, 1, 200, func(v: float) -> void: _apply("sens_general", int(v)))))
			_body.add_child(UI.row("Red dot / scope", UI.slider(Game.settings.sens_reddot, 1, 200, func(v: float) -> void: _apply("sens_reddot", int(v)))))
			_body.add_child(UI.row("Fire button drag", UI.slider(Game.settings.sens_fire, 1, 200, func(v: float) -> void: _apply("sens_fire", int(v)))))
			_body.add_child(_hint("Drag anywhere on the right side to look. Hold FIRE and drag to aim while shooting."))
		2:
			_body.add_child(UI.row("Aim assist", _toggle("aim_assist")))
			_body.add_child(UI.row("Aim assist strength", UI.slider(Game.settings.aim_assist_strength, 0, 100, func(v: float) -> void: _apply("aim_assist_strength", int(v)))))
			_body.add_child(UI.row("Left fire button", UI.segmented(Game.LEFT_FIRE_NAMES, int(Game.settings.left_fire), func(v: int) -> void: _apply("left_fire", v), 16, 130.0)))
			_body.add_child(UI.row("Dynamic crosshair", _toggle("dynamic_crosshair")))
			_body.add_child(UI.row("Crosshair color", UI.segmented(Game.CROSSHAIR_COLOR_NAMES, int(Game.settings.crosshair_color), func(v: int) -> void: _apply("crosshair_color", v), 16, 88.0)))
			_body.add_child(UI.row("Crosshair size", UI.slider(Game.settings.crosshair_size, 0, 100, func(v: float) -> void: _apply("crosshair_size", int(v)))))
			var hud_btn := UI.button("EDIT CUSTOM HUD", 22, "dark", Vector2(320, 56))
			hud_btn.pressed.connect(func() -> void:
				Game.save_settings()
				Game.goto_hud_editor())
			var row := HBoxContainer.new()
			row.add_child(hud_btn)
			_body.add_child(row)
		3:
			_body.add_child(UI.row("Master volume", UI.slider(Game.settings.vol_master, 0, 100, func(v: float) -> void: _apply("vol_master", int(v)))))
			_body.add_child(UI.row("Effects volume", UI.slider(Game.settings.vol_sfx, 0, 100, func(v: float) -> void: _apply("vol_sfx", int(v)))))
			_body.add_child(UI.row("Music volume", UI.slider(Game.settings.vol_music, 0, 100, func(v: float) -> void: _apply("vol_music", int(v)))))


func _toggle(key: String) -> Control:
	return UI.segmented(["OFF", "ON"], 1 if Game.settings[key] else 0, func(v: int) -> void: _apply(key, v == 1), 18, 92.0)


func _hint(t: String) -> Label:
	var l := UI.label(t, 17, UI.TEXT_DIM, "semi")
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _close() -> void:
	Game.save_settings()
	closed.emit()
	queue_free()
