class_name PauseMenu
extends Control
## In-match pause menu (the tree is paused while it is open), in the menus' dialog look: a
## full-width dark band across the middle with PAUSED and a yellow underline, the match state
## (mode, map, score, time left, HP) on the left and RESUME (yellow), SETTINGS (grey) and
## QUIT MATCH (asks once more) on the right. Emits `closed` when it goes away.

signal closed

const QUIT_CONFIRM_S := 3.0

var _quit: Button
var _quit_armed := 0.0
var _band: Control


func _ready() -> void:
	name = "PauseMenu"
	process_mode = Node.PROCESS_MODE_ALWAYS
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	UI.full_rect(shade)
	add_child(shade)
	_band = Control.new()
	_band.anchor_left = 0.0
	_band.anchor_right = 1.0
	_band.anchor_top = 0.22
	_band.anchor_bottom = 0.78
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_band.draw.connect(_draw_band)
	add_child(_band)
	var margin := MarginContainer.new()
	UI.full_rect(margin)
	margin.add_theme_constant_override("margin_left", 64)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 26)
	_band.add_child(margin)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 40)
	margin.add_child(h)
	# Left: title + match state.
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 6)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(info)
	var title := UI.shadowed(UI.label("PAUSED", 64, UI.TEXT, "italic"))
	info.add_child(title)
	var bar := ColorRect.new()
	bar.color = UI.ACCENT
	bar.custom_minimum_size = Vector2(72, 4)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	info.add_child(bar)
	info.add_child(UI.spacer(4))
	var arena := get_tree().current_scene
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 12)
	mode_row.add_child(UI.label("LONE WOLF", 26, UI.AMBER, "heavy"))
	var map_name := String(arena.get("map_name")) if arena and arena.get("map_name") != null else "CARGO CAGE"
	mode_row.add_child(UI.label(map_name, 26, UI.TEXT, "heavy"))
	info.add_child(mode_row)
	var chips := HBoxContainer.new()
	chips.add_theme_constant_override("separation", 10)
	info.add_child(chips)
	if arena and arena.get("score") is Dictionary:
		var sc: Dictionary = arena.get("score")
		chips.add_child(_chip("SCORE", "%d : %d" % [int(sc.get("player", 0)), int(sc.get("bot", 0))]))
	if arena and arena.get("time_left") != null:
		var t := maxf(float(arena.get("time_left")), 0.0)
		chips.add_child(_chip("TIME LEFT", "%d:%02d" % [int(t) / 60, int(t) % 60]))
	var p: Variant = arena.get("player") if arena else null
	if p is Node and (p as Node).get("hp") != null:
		chips.add_child(_chip("HP", str(roundi(float((p as Node).get("hp"))))))
	info.add_child(UI.spacer(2))
	info.add_child(UI.label("The match waits for you.", 17, UI.TEXT_DIM, "semi"))
	# Right: actions.
	var acts := VBoxContainer.new()
	acts.add_theme_constant_override("separation", 12)
	acts.alignment = BoxContainer.ALIGNMENT_CENTER
	acts.custom_minimum_size = Vector2(330, 0)
	h.add_child(acts)
	var resume := UI.button("RESUME", 26, "primary", Vector2(330, 64))
	resume.name = "Resume"
	resume.pressed.connect(_close)
	acts.add_child(resume)
	var settings := UI.button("SETTINGS", 24, "light", Vector2(330, 58))
	settings.name = "Settings"
	settings.pressed.connect(func() -> void: add_child(SettingsPanel.new()))
	acts.add_child(settings)
	_quit = UI.button("QUIT MATCH", 22, "dark", Vector2(330, 54))
	_quit.name = "Quit"
	_quit.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))
	_quit.add_theme_color_override("font_hover_color", Color(1.0, 0.65, 0.6))
	_quit.pressed.connect(_on_quit)
	acts.add_child(_quit)
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.15)


func _chip(cap: String, value: String) -> PanelContainer:
	var p := PanelContainer.new()
	var st := UI.chamfer(Color(1, 1, 1, 0.06), 8, 1, Color(1, 1, 1, 0.14), 14.0, ["br"])
	st.content_margin_top = 4
	st.content_margin_bottom = 4
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var c := UI.label(cap, 15, UI.TEXT_DIM, "bold")
	c.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(c)
	h.add_child(UI.label(value, 26, UI.TEXT, "number"))
	p.add_child(h)
	return p


func _draw_band() -> void:
	var s := _band.size
	_band.draw_rect(Rect2(Vector2.ZERO, s), Color(0.114, 0.10, 0.075, 0.94))
	# soft lighter wash toward the left, hazard tab top-left, accent lines
	_band.draw_rect(Rect2(0, 0, s.x * 0.45, s.y), Color(1, 1, 1, 0.025))
	UI.draw_hazard(_band, Rect2(0, 0, 150, 7), 7.0)
	_band.draw_rect(Rect2(0, s.y - 3, s.x, 3), Color(UI.ACCENT, 0.75))
	_band.draw_rect(Rect2(0, 7, s.x, 1), Color(1, 1, 1, 0.08))


func _on_quit() -> void:
	if _quit_armed > 0.0:
		get_tree().paused = false
		Game.goto_lobby()
		return
	_quit_armed = QUIT_CONFIRM_S
	_quit.text = "TAP AGAIN TO QUIT"


func _process(delta: float) -> void:
	if _quit_armed > 0.0:
		_quit_armed -= delta
		if _quit_armed <= 0.0:
			_quit.text = "QUIT MATCH"


func _close() -> void:
	closed.emit()
	queue_free()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree():
		for c in get_children():
			if c is SettingsPanel:
				return          # the settings panel closes itself first
		_close()
