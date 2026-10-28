class_name ResultsScreen
extends Control
## End-of-round results. setup(result) gets the dictionary built by arena.gd:
## won, draw, invalid, kills, damage, headshots, accuracy, time, xp, enemy, mode, map, weapon,
## score_player, score_bot, hp_left, difficulty, taken.

var _result := {}


func setup(result: Dictionary) -> void:
	_result = result
	UI.full_rect(self)
	process_mode = Node.PROCESS_MODE_ALWAYS
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.55)
	UI.full_rect(overlay)
	add_child(overlay)
	var center := CenterContainer.new()
	UI.full_rect(center)
	add_child(center)
	var panel := UI.panel(UI.PANEL, 16)
	panel.custom_minimum_size = Vector2(640, 0)
	center.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	var won: bool = result.get("won", false)
	var draw: bool = result.get("draw", false)
	var invalid: bool = result.get("invalid", false)
	var title_txt := "INVALID" if invalid else ("DRAW" if draw else ("VICTORY" if won else "DEFEAT"))
	var title_col := UI.BAD if invalid else (Color.WHITE if draw else (UI.ACCENT if won else UI.BAD))
	var title := UI.outlined(UI.label(title_txt, 76, title_col, "title"), 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.name = "Title"
	v.add_child(title)
	var sub := UI.label("%s  ·  %s  ·  vs %s" % [result.get("mode", ""), result.get("map", ""), result.get("enemy", "")], 20, UI.TEXT_DIM, "semi")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	v.add_child(grid)
	var t := float(result.get("time", 0.0))
	var cells := [
		["ELIMINATIONS", str(int(result.get("kills", 0)))], ["DAMAGE", str(int(result.get("damage", 0)))],
		["HEADSHOTS", str(int(result.get("headshots", 0)))], ["ACCURACY", "%d%%" % roundi(float(result.get("accuracy", 0.0)))],
		["TIME", "%d:%02d" % [int(t) / 60, int(t) % 60]], ["XP", "+%d" % int(result.get("xp", 0))],
	]
	for c in cells:
		var cell := UI.panel(UI.PANEL_2, 10)
		cell.custom_minimum_size = Vector2(190, 92)
		var cv := VBoxContainer.new()
		cv.alignment = BoxContainer.ALIGNMENT_CENTER
		var val := UI.label(String(c[1]), 40, UI.TEXT, "number")
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var cap := UI.label(String(c[0]), 16, UI.TEXT_DIM, "semi")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(val)
		cv.add_child(cap)
		cell.add_child(cv)
		grid.add_child(cell)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 14)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	var again := UI.button("PLAY AGAIN", 26, "primary", Vector2(260, 64))
	again.name = "PlayAgain"
	again.pressed.connect(Game.goto_arena)
	var lobby := UI.button("LOBBY", 26, "dark", Vector2(200, 64))
	lobby.name = "Lobby"
	lobby.pressed.connect(Game.goto_lobby)
	buttons.add_child(again)
	buttons.add_child(lobby)
	v.add_child(buttons)
	panel.modulate.a = 0.0
	panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.35)
