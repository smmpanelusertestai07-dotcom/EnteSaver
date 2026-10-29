class_name PauseMenu
extends Control
## In-match pause menu (the tree is paused while it is open), in the reference system-dialog
## look: a full-width dark band across the middle (0.30 .. 0.70 H) with PAUSED and a yellow
## underline, the match state (mode, map, score, time left, HP) on the left and RESUME (yellow),
## SETTINGS (grey) and QUIT MATCH (asks once more) on the right. The match HUD is hidden while
## it is open (its weapon-pick panel would show through). Emits `closed` when it goes away.
##
## Android back: the arena opens this menu while it handles NOTIFICATION_WM_GO_BACK_REQUEST, and
## the engine then delivers that same notification to the new menu (it walks the tree parent
## first, children added on the way included). The menu therefore ignores a back request in the
## frame it was opened; the next back closes it (or the settings panel on top of it).

signal closed

const QUIT_CONFIRM_S := 3.0

var _quit: Button
var _quit_armed := 0.0
var _band: Control
var _opened_frame := -1
var _hud: CanvasItem
var _hud_was_visible := false
var _closing := false


func _ready() -> void:
	name = "PauseMenu"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_opened_frame = Engine.get_process_frames()
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_hide_match_hud()
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
	UI.full_rect(shade)
	add_child(shade)
	_band = Control.new()
	_band.name = "Band"
	_band.anchor_left = 0.0
	_band.anchor_right = 1.0
	_band.anchor_top = 0.30
	_band.anchor_bottom = 0.70
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_band.draw.connect(func() -> void: UI.draw_dialog_band(_band, _band.size))
	add_child(_band)
	var margin := MarginContainer.new()
	UI.full_rect(margin)
	margin.add_theme_constant_override("margin_left", 64)
	margin.add_theme_constant_override("margin_right", 48)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 20)
	_band.add_child(margin)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 40)
	margin.add_child(h)
	# Left: title + match state.
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 4)
	info.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_child(info)
	var title := UI.shadowed(UI.label("PAUSED", 50, UI.TEXT, "bold"))     # dialog titles are upright
	info.add_child(title)
	var bar := ColorRect.new()
	bar.color = UI.ACCENT
	bar.custom_minimum_size = Vector2(64, 4)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.add_child(bar)
	info.add_child(UI.spacer(4))
	var arena := get_tree().current_scene
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 12)
	mode_row.add_child(UI.label("LONE WOLF", 24, UI.AMBER, "heavy"))
	var map_name := String(arena.get("map_name")) if arena and arena.get("map_name") != null else "CARGO CAGE"
	mode_row.add_child(UI.label(map_name, 24, UI.TEXT, "heavy"))
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
	# Right: actions.
	var acts := VBoxContainer.new()
	acts.add_theme_constant_override("separation", 10)
	acts.alignment = BoxContainer.ALIGNMENT_CENTER
	acts.custom_minimum_size = Vector2(320, 0)
	h.add_child(acts)
	var resume := UI.button("RESUME", 24, "primary", Vector2(320, 56))
	resume.name = "Resume"
	resume.pressed.connect(_close)
	acts.add_child(resume)
	var settings := UI.button("SETTINGS", 22, "light", Vector2(320, 50))
	settings.name = "Settings"
	settings.pressed.connect(_open_settings)
	acts.add_child(settings)
	_quit = UI.button("QUIT MATCH", 20, "dark", Vector2(320, 48))
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
	st.content_margin_top = 3
	st.content_margin_bottom = 3
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var c := UI.label(cap, 15, UI.TEXT_DIM, "bold")
	c.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(c)
	h.add_child(UI.label(value, 24, UI.TEXT, "number"))
	p.add_child(h)
	return p


## The settings panel on top, without the HUD editor shortcut (leaving for the editor would
## abandon the match).
func _open_settings() -> void:
	for c in get_children():
		if c is SettingsPanel:
			return
	var sp := SettingsPanel.new()
	sp.in_match = true
	add_child(sp)


func _hide_match_hud() -> void:
	var scene := get_tree().current_scene
	var h: Variant = scene.get("hud") if scene else null
	if h is CanvasItem:
		_hud = h
		_hud_was_visible = _hud.visible
		_hud.visible = false


func _restore_match_hud() -> void:
	if _hud and is_instance_valid(_hud) and _hud_was_visible:
		_hud.visible = true
	_hud = null


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
	if _closing:
		return
	_closing = true
	_restore_match_hud()
	closed.emit()
	queue_free()


func _exit_tree() -> void:
	_restore_match_hud()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree() and not _closing:
		if Engine.get_process_frames() == _opened_frame:
			return              # the back request that opened this menu
		for c in get_children():
			if c is SettingsPanel:
				return          # the settings panel closes itself first
		_close()
