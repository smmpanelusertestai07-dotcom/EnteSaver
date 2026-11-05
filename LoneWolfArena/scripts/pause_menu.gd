class_name PauseMenu
extends Control
## The in-match menu behind the HUD's gear (and Android back), the reference's way: the settings
## open straight away (`SettingsPanel`, in_match) with QUIT MATCH at the foot of their tab column
## (it asks once more) and EDIT CUSTOM HUD in CONTROLS opening the editor over the match
## (scripts/hud_editor_overlay.gd: SAVE applies it to this match). The settings' X (or back) closes
## the menu and the match goes on. A TRAINING GROUND match is paused while it is open (the arena
## pauses the tree); online the match runs on underneath (the other phone plays on): the fighter
## takes no input (the HUD is hidden, and a hidden HUD ignores touches) and the end of a round or
## of the match closes the menu, the HUD editor with it. Emits `closed` when it goes away.
##
## Android back: the arena opens this menu while it handles NOTIFICATION_WM_GO_BACK_REQUEST, and
## the engine then delivers that same notification to the new menu (it walks the tree parent
## first, children added on the way included). The settings are therefore added at the end of that
## frame, and the menu ignores a back request in the frame it was opened; the next back goes to
## the settings (a question or the editor over them first), whose closing closes the menu.

signal closed

const QUIT_CONFIRM_S := 6.0     # real seconds the second tap may take (a slow phone, a slow touch)
const HudEditorOverlay := preload("res://scripts/hud_editor_overlay.gd")

var settings: SettingsPanel     # the settings shown (null once they closed)
var _quit: Button
var _quit_armed := 0.0
var _was_over := false          # online: the round was already over when last looked at
var _opened_frame := -1
var _hud: CanvasItem
var _hud_was_visible := false
var _closing := false
var _editor: Control            # the HUD editor over the match, while open


func _ready() -> void:
	name = "PauseMenu"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_opened_frame = Engine.get_process_frames()
	UI.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_hide_match_hud()
	var arena := get_tree().current_scene
	_was_over = arena != null and arena.get("phase") == 3          # opened between rounds
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.5)
	UI.full_rect(shade)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	_open_settings.call_deferred()


## The settings with QUIT MATCH in their tab column, above HOW TO PLAY and RESET (a child of the
## panel: a later sibling would count as something opened over it, which takes the back).
func _open_settings() -> void:
	if _closing or not is_inside_tree():
		return
	settings = SettingsPanel.new()
	settings.name = "Settings"
	settings.in_match = true
	settings.edit_hud = _open_hud_editor
	settings.closed.connect(func() -> void:
		settings = null              # (it saved itself)
		_close())
	add_child(settings)
	_quit = UI.button("QUIT MATCH", 19, "dark", Vector2(SettingsPanel.MENU_W - 48.0, UI.TOUCH_MIN))
	_quit.name = "Quit"
	_quit.add_theme_color_override("font_color", Color(1.0, 0.55, 0.5))
	_quit.add_theme_color_override("font_hover_color", Color(1.0, 0.65, 0.6))
	_quit.add_theme_color_override("font_pressed_color", Color(1.0, 0.65, 0.6))
	_quit.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_quit.offset_left = 24.0
	_quit.offset_right = SettingsPanel.MENU_W - 24.0
	_quit.offset_top = -146.0 - UI.TOUCH_MIN     # above HOW TO PLAY (-136..-80) and RESET
	_quit.offset_bottom = -146.0
	_quit.pressed.connect(_on_quit)
	settings.add_child(_quit)
	_quit_text("QUIT MATCH")


## EDIT CUSTOM HUD in a match: the editor over it (back or BACK closes it again, to the settings).
func _open_hud_editor() -> void:
	if _closing or (_editor != null and is_instance_valid(_editor)):
		return
	var ed := HudEditorOverlay.new()
	ed.closed.connect(func() -> void:
		_editor = null
		if _hud and is_instance_valid(_hud) and _hud.has_method("reload_layout"):
			_hud.call("reload_layout"))         # a layout SAVEd there counts in this match at once
	_editor = ed
	add_child(ed)


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
		var arena := get_tree().current_scene
		if arena and arena.has_method("record_left"):
			arena.call("record_left")        # a counted match goes into HISTORY as LEFT, a defeat
		if settings != null:
			Game.save_settings()             # (the panel saves only when it closes itself)
		get_tree().paused = false
		Game.goto_lobby()
		return
	_quit_armed = Time.get_ticks_msec() + QUIT_CONFIRM_S * 1000.0
	if _quit:
		_quit_text("TAP AGAIN TO QUIT")


## QUIT MATCH's caption, its font made smaller until it fits the tab column.
func _quit_text(text: String) -> void:
	_quit.text = text
	var font := _quit.get_theme_font("font")
	var room := SettingsPanel.MENU_W - 48.0 - 28.0
	var fs := 19
	while fs > 13 and font != null and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > room:
		fs -= 1
	_quit.add_theme_font_size_override("font_size", fs)


func _process(_delta: float) -> void:
	if _quit_armed > 0.0 and Time.get_ticks_msec() >= _quit_armed:     # (real time: not the slow motion)
		_quit_armed = 0.0
		if _quit:
			_quit_text("QUIT MATCH")
	var arena := get_tree().current_scene
	if arena == null or arena.get("online") != true or _closing:
		return
	# Online the match goes on: the end of a round or of the match closes the menu (the round
	# result and the results screen are never drawn under it).
	var phase := int(arena.get("phase"))
	var over := phase == 2 or phase == 3
	if (over and not _was_over) or phase == 2:
		_close()
		return
	_was_over = over


## Closes the menu (the settings' X or back, or the arena: the end of an online round, the results).
func _close() -> void:
	if _closing:
		return
	_closing = true
	if settings != null and is_instance_valid(settings):
		Game.save_settings()                 # closed from outside: the panel did not save itself
	_restore_match_hud()
	closed.emit()
	queue_free()


func _exit_tree() -> void:
	_restore_match_hud()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST and is_inside_tree() and not _closing:
		if Engine.get_process_frames() == _opened_frame:
			return              # the back request that opened this menu
		if settings != null and is_instance_valid(settings):
			return              # the settings take it (and close the menu with them)
		_close()
