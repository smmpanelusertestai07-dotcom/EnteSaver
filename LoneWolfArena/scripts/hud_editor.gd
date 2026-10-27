extends Control
## Custom HUD editor: drag any control to move it, then adjust its size and opacity.
## Layout is saved to user://hud_layout.json and used in every match.

var hud: HUD
var layout := {}
var _drag_index := -1
var _drag_offset := Vector2.ZERO
var _size_slider: HSlider
var _alpha_slider: HSlider
var _sel_label: Label
var _syncing := false


func _ready() -> void:
	UI.full_rect(self)
	var bg := TextureRect.new()
	UI.full_rect(bg)
	var grad := Gradient.new()
	grad.set_color(0, Color(0.32, 0.46, 0.6))
	grad.set_color(1, Color(0.12, 0.14, 0.16))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0.5, 0)
	gt.fill_to = Vector2(0.5, 1)
	bg.texture = gt
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(bg)
	var grid := Control.new()
	UI.full_rect(grid)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.draw.connect(func() -> void:
		var s := grid.size
		for i in range(1, 16):
			grid.draw_line(Vector2(s.x * i / 16.0, 0), Vector2(s.x * i / 16.0, s.y), Color(1, 1, 1, 0.05), 1.0)
		for j in range(1, 9):
			grid.draw_line(Vector2(0, s.y * j / 9.0), Vector2(s.x, s.y * j / 9.0), Color(1, 1, 1, 0.05), 1.0))
	add_child(grid)
	layout = HudLayout.current()
	hud = HUD.new()
	hud.editor_mode = true
	add_child(hud)
	hud.layout = layout
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 10)
	top.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	top.position = Vector2(-330, 14)
	top.size = Vector2(660, 56)
	add_child(top)
	var t := UI.outlined(UI.label("CUSTOM HUD", 34, UI.TEXT, "title"), 5)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(t)
	var reset := UI.button("RESET", 20, "ghost", Vector2(120, 52))
	reset.pressed.connect(func() -> void:
		layout = HudLayout.resolve({})
		hud.layout = layout
		_sync_sliders())
	top.add_child(reset)
	var save := UI.button("SAVE", 22, "primary", Vector2(130, 52))
	save.name = "SaveButton"
	save.pressed.connect(func() -> void:
		Game.save_hud_layout(layout)
		_sel_label.text = "SAVED!")
	top.add_child(save)
	var back := UI.button("BACK", 20, "dark", Vector2(120, 52))
	back.pressed.connect(Game.goto_lobby)
	top.add_child(back)
	var panel := UI.panel(Color(0, 0, 0, 0.6), 12)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.position = Vector2(-300, -60)
	panel.custom_minimum_size = Vector2(600, 0)
	add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	panel.add_child(v)
	_sel_label = UI.label("TAP A BUTTON TO SELECT IT, DRAG TO MOVE", 18, UI.ACCENT, "semi")
	_sel_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_sel_label)
	var size_row := UI.slider(100, 50, 160, func(val: float) -> void: _on_size(val))
	_size_slider = size_row.get_child(0)
	v.add_child(UI.row("Size %", size_row, 130.0))
	var alpha_row := UI.slider(80, 15, 100, func(val: float) -> void: _on_alpha(val))
	_alpha_slider = alpha_row.get_child(0)
	v.add_child(UI.row("Opacity %", alpha_row, 130.0))
	_select("fire_r")


func _select(id: String) -> void:
	hud.selected_id = id
	_sel_label.text = "SELECTED: %s" % HudLayout.LABELS.get(id, id)
	_sync_sliders()


func _sync_sliders() -> void:
	var id := hud.selected_id
	if id == "" or not layout.has(id):
		return
	_syncing = true
	_size_slider.value = float(layout[id].s) / float(HudLayout.DEFAULTS[id].s) * 100.0
	_alpha_slider.value = float(layout[id].o) * 100.0
	_syncing = false


func _on_size(val: float) -> void:
	var id := hud.selected_id
	if _syncing or id == "":
		return
	layout[id].s = float(HudLayout.DEFAULTS[id].s) * val / 100.0


func _on_alpha(val: float) -> void:
	var id := hud.selected_id
	if _syncing or id == "":
		return
	layout[id].o = val / 100.0


func _input(event: InputEvent) -> void:
	var vs := size
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			if t.position.y < 80 or _over_panel(t.position):
				return
			for id: String in HudLayout.ORDER:
				var r := HudLayout.hit_rect(id, layout[id], vs).grow(10)
				if r.has_point(t.position):
					_select(id)
					_drag_index = t.index
					_drag_offset = HudLayout.center(layout[id], vs) - t.position
					return
		elif t.index == _drag_index:
			_drag_index = -1
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _drag_index and hud.selected_id != "":
			var c := d.position + _drag_offset
			layout[hud.selected_id].x = clampf(c.x / vs.x, 0.03, 0.97)
			layout[hud.selected_id].y = clampf(c.y / vs.y, 0.1, 0.97)


func _over_panel(p: Vector2) -> bool:
	for c in get_children():
		if c is PanelContainer and (c as Control).get_global_rect().has_point(p):
			return true
	return false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		Game.goto_lobby()
