extends Control
## Custom HUD editor: every in-match widget is shown at its place (buttons, joystick, weapon
## panel, minimap; the score bar, HP block and kill feed for context). Tap a widget to select it,
## drag it to move it (its anchor follows the screen third it ends up in), set its size
## (50-200 %) and opacity (10-100 %), nudge it with the arrows, RESET to the defaults, SAVE
## (Game.save_hud_layout) and BACK to the lobby (a second BACK discards unsaved changes).

const NUDGE_PX := 4.0

var hud: HUD
var layout := {}
var _drag_index := -1
var _drag_offset := Vector2.ZERO
var _size_slider: HSlider
var _alpha_slider: HSlider
var _sel_label: Label
var _panel: PanelContainer
var _body: VBoxContainer
var _hide_btn: Button
var _syncing := false
var _dirty := false
var _back_armed := false


func _ready() -> void:
	UI.full_rect(self)
	_build_backdrop()
	layout = HudLayout.current()
	hud = HUD.new()
	hud.editor_mode = true
	add_child(hud)
	hud.layout = layout
	_build_panel()
	_select("fire_r")


func _build_backdrop() -> void:
	var bg := TextureRect.new()
	UI.full_rect(bg)
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.48, 0.5, 1.0])
	grad.colors = PackedColorArray([Color(0.36, 0.5, 0.64), Color(0.62, 0.7, 0.76), Color(0.34, 0.33, 0.31), Color(0.17, 0.17, 0.17)])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0.5, 0)
	gt.fill_to = Vector2(0.5, 1)
	bg.texture = gt
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var grid := Control.new()
	UI.full_rect(grid)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.draw.connect(func() -> void:
		var s := grid.size
		for i in range(1, 20):
			grid.draw_line(Vector2(s.x * i / 20.0, 0), Vector2(s.x * i / 20.0, s.y), Color(1, 1, 1, 0.05), 1.0)
		for j in range(1, 9):
			grid.draw_line(Vector2(0, s.y * j / 9.0), Vector2(s.x, s.y * j / 9.0), Color(1, 1, 1, 0.05), 1.0)
		grid.draw_line(Vector2(s.x * 0.5, 0), Vector2(s.x * 0.5, s.y), Color(1, 1, 1, 0.12), 1.0))
	add_child(grid)


func _build_panel() -> void:
	_panel = UI.panel(Color(0.05, 0.06, 0.08, 0.86), 10)
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_panel.custom_minimum_size = Vector2(560, 0)
	_panel.position = Vector2(-280, 66)
	add_child(_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	_panel.add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	var back := UI.button("BACK", 19, "dark", Vector2(96, 46))
	back.name = "BackButton"
	back.pressed.connect(_on_back)
	top.add_child(back)
	var title := UI.outlined(UI.label("CUSTOM HUD", 30, UI.TEXT, "title"), 4)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	top.add_child(title)
	var reset := UI.button("RESET", 19, "ghost", Vector2(100, 46))
	reset.name = "ResetButton"
	reset.pressed.connect(_on_reset)
	top.add_child(reset)
	var save := UI.button("SAVE", 20, "primary", Vector2(110, 46))
	save.name = "SaveButton"
	save.pressed.connect(_on_save)
	top.add_child(save)
	var sel_row := HBoxContainer.new()
	sel_row.add_theme_constant_override("separation", 8)
	v.add_child(sel_row)
	_sel_label = UI.label("TAP A CONTROL TO SELECT IT, DRAG TO MOVE IT", 18, UI.ACCENT, "semi")
	_sel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sel_row.add_child(_sel_label)
	_hide_btn = UI.button("HIDE", 16, "ghost", Vector2(76, 38))
	_hide_btn.pressed.connect(func() -> void:
		_body.visible = not _body.visible
		_hide_btn.text = "HIDE" if _body.visible else "SHOW")
	sel_row.add_child(_hide_btn)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 4)
	v.add_child(_body)
	var size_row := UI.slider(100, HudLayout.SIZE_MIN * 100.0, HudLayout.SIZE_MAX * 100.0, func(val: float) -> void: _on_size(val))
	_size_slider = size_row.get_child(0)
	_body.add_child(UI.row("SIZE %", size_row, 130.0))
	var alpha_row := UI.slider(85, HudLayout.OPACITY_MIN * 100.0, 100, func(val: float) -> void: _on_alpha(val))
	_alpha_slider = alpha_row.get_child(0)
	_body.add_child(UI.row("OPACITY %", alpha_row, 130.0))
	var nudge := HBoxContainer.new()
	nudge.add_theme_constant_override("separation", 8)
	nudge.alignment = BoxContainer.ALIGNMENT_CENTER
	_body.add_child(nudge)
	var hint := UI.label("FINE MOVE", 17, UI.TEXT_DIM, "semi")
	hint.custom_minimum_size = Vector2(130, 0)
	nudge.add_child(hint)
	for d in [Vector2.LEFT, Vector2.UP, Vector2.DOWN, Vector2.RIGHT]:
		nudge.add_child(_arrow_button(d))


## Small button with a chevron drawn on it (the UI fonts have no arrow glyphs).
func _arrow_button(dir: Vector2) -> Button:
	var b := UI.button("", 18, "dark", Vector2(62, 40))
	var glyph := Control.new()
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.draw.connect(func() -> void:
		var c := glyph.size * 0.5
		var side := dir.orthogonal() * 8.0
		glyph.draw_polyline(PackedVector2Array([c - dir * 4.0 + side, c + dir * 5.0, c - dir * 4.0 - side]), Color(1, 1, 1, 0.9), 3.0, true))
	b.add_child(glyph)
	b.pressed.connect(func() -> void: _nudge(dir))
	return b


func _select(id: String) -> void:
	if not layout.has(id):
		return
	hud.selected_id = id
	_sel_label.text = "SELECTED: %s" % String(HudLayout.LABELS.get(id, id))
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
	layout[id].s = minf(float(HudLayout.DEFAULTS[id].s) * val / 100.0, 0.45)
	_changed()


func _on_alpha(val: float) -> void:
	var id := hud.selected_id
	if _syncing or id == "":
		return
	layout[id].o = clampf(val / 100.0, HudLayout.OPACITY_MIN, 1.0)
	_changed()


func _nudge(dir: Vector2) -> void:
	var id := hud.selected_id
	if id == "":
		return
	var vs := size
	HudLayout.place(layout[id], HudLayout.center(layout[id], vs) + dir * NUDGE_PX, vs)
	_changed()


func _changed() -> void:
	_dirty = true
	_back_armed = false


func _on_reset() -> void:
	layout = HudLayout.resolve({})
	hud.layout = layout
	_changed()
	_sel_label.text = "DEFAULT LAYOUT RESTORED (TAP SAVE TO KEEP IT)"
	_sync_sliders()


func _on_save() -> void:
	Game.save_hud_layout(HudLayout.to_save(layout))
	_dirty = false
	_back_armed = false
	_sel_label.text = "SAVED! USED IN EVERY MATCH"
	Audio.play("ui_select", -4.0)


func _on_back() -> void:
	if _dirty and not _back_armed:
		_back_armed = true
		_sel_label.text = "UNSAVED CHANGES: SAVE, OR BACK AGAIN TO DISCARD"
		return
	Game.goto_lobby()


# ---------------------------------------------------------------- dragging

func _input(event: InputEvent) -> void:
	var vs := size
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			if _panel.get_global_rect().has_point(t.position):
				return
			var id := _widget_at(t.position, vs)
			if id != "":
				_select(id)
				_drag_index = t.index
				_drag_offset = HudLayout.center(layout[id], vs) - t.position
				get_viewport().set_input_as_handled()
		elif t.index == _drag_index:
			_drag_index = -1
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _drag_index and hud.selected_id != "":
			HudLayout.place(layout[hud.selected_id], d.position + _drag_offset, vs)
			_changed()


## Widget under the finger; round buttons pick the closest centre, panels their rect.
func _widget_at(pos: Vector2, vs: Vector2) -> String:
	var best := ""
	var best_d := INF
	for id: String in HudLayout.ORDER:
		var w: Dictionary = layout[id]
		var r := HudLayout.hit_rect(id, w, vs)
		if HudLayout.kind(id) in ["panel", "square"]:
			if r.grow(6).has_point(pos):
				return id
			continue
		var rad := r.size.x * 0.5
		var d := pos.distance_to(r.get_center()) / maxf(rad, 1.0)
		if d <= 1.2 and d < best_d:
			best = id
			best_d = d
	return best


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_on_back()
