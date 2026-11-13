extends "res://scripts/hud_editor.gd"
## The custom HUD editor over a match: CUSTOM on the HUD page of the settings in the in-match menu
## (PauseMenu) opens it on top of the match, as the reference lets its HUD be edited mid-match.
## Everything is the lobby's editor (scripts/hud_editor.gd); BACK (and Android back) closes it back
## to the settings instead of going to the lobby (a second BACK still discards unsaved changes),
## and it works while a TRAINING GROUND match is paused. SAVE applies to the match at once (the menu
## reloads the HUD's layout when the editor closes). Emits `closed` when it goes away.

signal closed


func _ready() -> void:
	name = "HudEditor"
	process_mode = Node.PROCESS_MODE_ALWAYS
	super()


func _on_back() -> void:
	if _dirty and not _back_armed:
		_back_armed = true
		_sel_label.text = "UNSAVED CHANGES: SAVE, OR BACK AGAIN TO DISCARD"
		return
	closed.emit()
	queue_free()
