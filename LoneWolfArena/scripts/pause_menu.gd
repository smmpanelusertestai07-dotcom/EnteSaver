class_name PauseMenu
extends Control
## In-match pause menu (the game is paused while it is open): resume, settings, quit.

signal closed


func _ready() -> void:
	name = "PauseMenu"
	process_mode = Node.PROCESS_MODE_ALWAYS
	UI.full_rect(self)
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	UI.full_rect(overlay)
	add_child(overlay)
	var center := CenterContainer.new()
	UI.full_rect(center)
	add_child(center)
	var panel := UI.panel(UI.PANEL, 16)
	panel.custom_minimum_size = Vector2(420, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 14)
	panel.add_child(v)
	var title := UI.label("PAUSED", 48, UI.TEXT, "title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var resume := UI.button("RESUME", 26, "primary", Vector2(0, 62))
	resume.name = "Resume"
	resume.pressed.connect(_close)
	v.add_child(resume)
	var settings := UI.button("SETTINGS", 24, "dark", Vector2(0, 58))
	settings.pressed.connect(func() -> void:
		var sp := SettingsPanel.new()
		add_child(sp))
	v.add_child(settings)
	var quit := UI.button("QUIT MATCH", 24, "danger", Vector2(0, 58))
	quit.pressed.connect(func() -> void:
		get_tree().paused = false
		Game.goto_lobby())
	v.add_child(quit)


func _close() -> void:
	closed.emit()
	queue_free()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_close()
