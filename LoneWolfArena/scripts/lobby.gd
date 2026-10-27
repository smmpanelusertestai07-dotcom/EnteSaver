extends Node3D
## Lobby: the hero on a lit stage, profile, bundles (wardrobe), settings, difficulty
## and the START button that drops straight into a Lone Wolf match.

var model: CharacterModel
var camera: Camera3D
var ui: CanvasLayer
var start_btn: Button
var wardrobe: Control
var _preview_bundle := ""
var _drag_index := -1
var _turntable := 0.0
var _name_label: Label
var _bundle_label: Label
var _time := 0.0


func _ready() -> void:
	_build_stage()
	_build_ui()
	Audio.play_music("lobby_music", -4.0)


func _build_stage() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.04, 0.05, 0.12)
	sm.sky_horizon_color = Color(0.28, 0.17, 0.33)
	sm.ground_horizon_color = Color(0.2, 0.12, 0.22)
	sm.ground_bottom_color = Color(0.02, 0.02, 0.04)
	sm.sun_angle_max = 1.0
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	e.ambient_light_energy = 0.7
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.glow_enabled = true
	e.glow_intensity = 0.6
	e.glow_bloom = 0.08
	e.glow_hdr_threshold = 0.9
	e.fog_enabled = true
	e.fog_light_color = Color(0.18, 0.12, 0.25)
	e.fog_density = 0.035
	env.environment = e
	add_child(env)
	var floor_m := StandardMaterial3D.new()
	floor_m.albedo_color = Color(0.05, 0.05, 0.07)
	floor_m.roughness = 0.25
	floor_m.metallic = 0.5
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	floor_mi.mesh = pm
	floor_mi.material_override = floor_m
	add_child(floor_mi)
	var stage := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 1.25
	cm.bottom_radius = 1.35
	cm.height = 0.22
	cm.radial_segments = 48
	stage.mesh = cm
	var stage_m := StandardMaterial3D.new()
	stage_m.albedo_color = Color(0.12, 0.12, 0.15)
	stage_m.metallic = 0.7
	stage_m.roughness = 0.35
	stage.material_override = stage_m
	stage.position = Vector3(-0.7, 0.11, 0)
	add_child(stage)
	var ring := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 1.28
	tm.outer_radius = 1.34
	tm.rings = 48
	ring.mesh = tm
	var ring_m := StandardMaterial3D.new()
	ring_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_m.albedo_color = Color(1.0, 0.72, 0.2) * 2.2
	ring.material_override = ring_m
	ring.position = Vector3(-0.7, 0.22, 0)
	add_child(ring)
	for i in 7:
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.12, 7.0, 0.12)
		bar.mesh = bm
		var bmat := StandardMaterial3D.new()
		bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		var c := Color(1.0, 0.6, 0.15) if i % 2 == 0 else Color(0.2, 0.75, 1.0)
		bmat.albedo_color = c * 1.8
		bar.material_override = bmat
		bar.position = Vector3(-6.5 + i * 2.2, 3.5, -6.0 - (i % 3) * 1.5)
		add_child(bar)
	model = CharacterModel.new()
	add_child(model)
	model.position = Vector3(-0.7, 0.22, 0)
	model.rotation.y = PI - 0.25
	model.setup(String(Game.profile.bundle), false)
	model.play_lobby()
	var key := SpotLight3D.new()
	key.position = Vector3(1.5, 4.0, 3.5)
	key.light_energy = 6.0
	key.spot_range = 12.0
	key.spot_angle = 30.0
	key.light_color = Color(1.0, 0.92, 0.82)
	key.shadow_enabled = true
	add_child(key)
	key.look_at(Vector3(-0.7, 1.0, 0))
	var rim := SpotLight3D.new()
	rim.position = Vector3(-2.5, 3.0, -3.0)
	rim.light_energy = 5.0
	rim.spot_range = 10.0
	rim.spot_angle = 35.0
	rim.light_color = Color(0.3, 0.75, 1.0)
	add_child(rim)
	rim.look_at(Vector3(-0.7, 1.2, 0))
	var fill := OmniLight3D.new()
	fill.position = Vector3(-0.2, 1.6, 2.4)
	fill.light_energy = 0.6
	fill.omni_range = 6.0
	fill.light_color = Color(1.0, 0.75, 0.6)
	add_child(fill)
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.position = Vector3(0.35, 1.35, 4.6)
	add_child(camera)
	camera.look_at(Vector3(0.35, 1.05, 0))
	camera.current = true


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	var root := Control.new()
	UI.full_rect(root)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)
	# Profile card (top-left).
	var prof := UI.panel(Color(0, 0, 0, 0.45), 12)
	prof.position = Vector2(20, 18)
	root.add_child(prof)
	var ph := HBoxContainer.new()
	ph.add_theme_constant_override("separation", 12)
	prof.add_child(ph)
	var avatar := PanelContainer.new()
	avatar.custom_minimum_size = Vector2(58, 58)
	avatar.add_theme_stylebox_override("panel", UI.box(UI.ACCENT, 29, 0, Color.TRANSPARENT, 0.0))
	var initial := UI.label(String(Game.profile.name).substr(0, 1), 32, UI.INK, "title")
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	avatar.add_child(initial)
	ph.add_child(avatar)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 2)
	ph.add_child(pv)
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)
	_name_label = UI.label(String(Game.profile.name), 26, UI.TEXT, "bold")
	name_row.add_child(_name_label)
	var edit := UI.button("EDIT", 14, "ghost", Vector2(56, 30))
	edit.pressed.connect(_edit_name)
	name_row.add_child(edit)
	pv.add_child(name_row)
	pv.add_child(UI.label("LEVEL %d" % Game.level(), 16, UI.ACCENT, "semi"))
	var xp := ProgressBar.new()
	xp.show_percentage = false
	xp.custom_minimum_size = Vector2(190, 7)
	xp.value = Game.level_progress() * 100.0
	xp.add_theme_stylebox_override("background", UI.box(Color(1, 1, 1, 0.12), 3, 0, Color.TRANSPARENT, 0.0))
	xp.add_theme_stylebox_override("fill", UI.box(UI.ACCENT, 3, 0, Color.TRANSPARENT, 0.0))
	pv.add_child(xp)
	# Stats + settings (top-right).
	var top_r := HBoxContainer.new()
	top_r.add_theme_constant_override("separation", 10)
	top_r.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	top_r.position = Vector2(-560, 22)
	top_r.size = Vector2(540, 60)
	top_r.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(top_r)
	for s in [["MATCHES", Game.profile.matches], ["WINS", Game.profile.wins], ["KILLS", Game.profile.kills]]:
		var chip := UI.panel(Color(0, 0, 0, 0.45), 10)
		var cv := VBoxContainer.new()
		cv.add_theme_constant_override("separation", 0)
		var val := UI.label(str(int(s[1])), 24, UI.TEXT, "number")
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var cap := UI.label(String(s[0]), 13, UI.TEXT_DIM, "semi")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cv.add_child(val)
		cv.add_child(cap)
		chip.add_child(cv)
		top_r.add_child(chip)
	var gear := UI.button("SETTINGS", 18, "dark", Vector2(130, 58))
	gear.name = "SettingsButton"
	gear.pressed.connect(_open_settings)
	top_r.add_child(gear)
	# Title.
	var title := UI.outlined(UI.label("LONE WOLF ARENA", 44, UI.TEXT, "title"), 6)
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.position = Vector2(-title.get_minimum_size().x * 0.5, 96)
	title.add_theme_color_override("font_color", Color(1, 1, 1))
	root.add_child(title)
	var sub := UI.label("OFFLINE  ·  1 VS 1", 16, UI.ACCENT, "semi")
	sub.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	sub.position = Vector2(-sub.get_minimum_size().x * 0.5, 146)
	root.add_child(sub)
	# Left menu.
	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 12)
	menu.position = Vector2(20, 210)
	root.add_child(menu)
	var b1 := UI.button("BUNDLES", 22, "dark", Vector2(210, 60))
	b1.name = "BundlesButton"
	b1.pressed.connect(_open_wardrobe)
	menu.add_child(b1)
	var b2 := UI.button("CUSTOM HUD", 22, "dark", Vector2(210, 60))
	b2.pressed.connect(Game.goto_hud_editor)
	menu.add_child(b2)
	var b3 := UI.button("HOW TO PLAY", 22, "dark", Vector2(210, 60))
	b3.pressed.connect(_how_to_play)
	menu.add_child(b3)
	# Equipped bundle (bottom-left).
	var info := CharacterModel.bundle_info(String(Game.profile.bundle))
	_bundle_label = UI.outlined(UI.label("", 20, UI.RARITY_COLORS[info.rarity], "bold"), 4)
	_bundle_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_bundle_label.position = Vector2(24, -70)
	root.add_child(_bundle_label)
	_update_bundle_label(String(Game.profile.bundle))
	var ver := UI.label("v%s  ·  Made with Godot (open source)" % ProjectSettings.get_setting("application/config/version", "1.0"), 14, UI.TEXT_DIM, "semi")
	ver.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	ver.position = Vector2(24, -36)
	root.add_child(ver)
	# Mode + START (bottom-right).
	var mode := UI.panel(Color(0, 0, 0, 0.5), 12)
	mode.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	mode.position = Vector2(-420, -268)
	mode.custom_minimum_size = Vector2(400, 0)
	root.add_child(mode)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 8)
	mode.add_child(mv)
	mv.add_child(UI.label("LONE WOLF", 30, UI.TEXT, "title"))
	mv.add_child(UI.label("1 VS 1  ·  1 ROUND  ·  BOT OPPONENT", 15, UI.TEXT_DIM, "semi"))
	mv.add_child(UI.segmented(Game.DIFFICULTY_NAMES, int(Game.settings.difficulty), func(v: int) -> void:
		Game.settings.difficulty = v
		Game.save_settings(), 18, 118.0))
	start_btn = UI.button("START", 44, "primary", Vector2(400, 92))
	start_btn.name = "StartButton"
	start_btn.add_theme_font_override("font", UI.font("title"))
	start_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	start_btn.position = Vector2(-420, -112)
	start_btn.pressed.connect(_start)
	root.add_child(start_btn)


func _update_bundle_label(id: String) -> void:
	var info := CharacterModel.bundle_info(id)
	_bundle_label.text = "%s  ·  %s" % [info.name, String(info.rarity).to_upper()]
	_bundle_label.add_theme_color_override("font_color", UI.RARITY_COLORS[info.rarity])


func _start() -> void:
	start_btn.disabled = true
	start_btn.text = "LOADING..."
	Audio.play("ui_select", 0.0)
	await get_tree().create_timer(0.15).timeout
	Game.goto_arena()


func _open_settings() -> void:
	var sp := SettingsPanel.new()
	ui.add_child(sp)


func _how_to_play() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "HOW TO PLAY"
	dlg.dialog_text = "Left side: move with the joystick.\nRight side: drag to look around.\nFIRE: hold to shoot - keep holding and drag to aim while firing.\nSCOPE: red-dot aim.  CROUCH / JUMP / RELOAD as labelled.\nHEAL: medkit (+75 HP, 3 s).  WALL: deploy a shield wall.\nGRENADE: throw a frag.\nWin the round by eliminating the bot before the zone closes."
	dlg.add_theme_font_override("font", UI.font("semi"))
	ui.add_child(dlg)
	dlg.popup_centered(Vector2i(760, 420))


func _edit_name() -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "PLAYER NAME"
	var le := LineEdit.new()
	le.text = String(Game.profile.name)
	le.max_length = 14
	le.custom_minimum_size = Vector2(320, 48)
	dlg.add_child(le)
	ui.add_child(dlg)
	dlg.confirmed.connect(func() -> void:
		var n := le.text.strip_edges().to_upper()
		if n != "":
			Game.profile.name = n
			Game.save_profile()
			_name_label.text = n)
	dlg.popup_centered(Vector2i(420, 160))
	le.grab_focus()


# ---------------------------------------------------------------- wardrobe

func _open_wardrobe() -> void:
	if wardrobe:
		return
	_preview_bundle = String(Game.profile.bundle)
	wardrobe = Control.new()
	UI.full_rect(wardrobe)
	wardrobe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(wardrobe)
	var panel := UI.panel(UI.PANEL, 14)
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -470
	panel.offset_right = -16
	panel.offset_top = 16
	panel.offset_bottom = -16
	wardrobe.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)
	v.add_child(UI.label("BUNDLES", 38, UI.TEXT, "title"))
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 10)
	scroll.add_child(list)
	var group := ButtonGroup.new()
	for b in CharacterModel.BUNDLE_INFO:
		var card := Button.new()
		card.toggle_mode = true
		card.button_group = group
		card.button_pressed = b.id == _preview_bundle
		card.custom_minimum_size = Vector2(0, 84)
		card.focus_mode = Control.FOCUS_NONE
		card.name = "Bundle_" + String(b.id)
		var rc: Color = UI.RARITY_COLORS[b.rarity]
		var normal := UI.box(Color(rc.r * 0.25, rc.g * 0.25, rc.b * 0.25, 0.9), 10, 2, Color(rc, 0.5))
		var pressed := UI.box(Color(rc.r * 0.45, rc.g * 0.45, rc.b * 0.45, 0.95), 10, 3, rc)
		card.add_theme_stylebox_override("normal", normal)
		card.add_theme_stylebox_override("hover", normal)
		card.add_theme_stylebox_override("pressed", pressed)
		card.add_theme_stylebox_override("hover_pressed", pressed)
		card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var cv := VBoxContainer.new()
		cv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cv.offset_left = 16
		cv.offset_top = 10
		var nm := UI.label(String(b.name), 26, UI.TEXT, "bold")
		var tag := "%s  ·  %s" % [String(b.rarity).to_upper(), String(b.desc)]
		if b.id == String(Game.profile.bundle):
			tag += "  ·  EQUIPPED"
		cv.add_child(nm)
		cv.add_child(UI.label(tag, 15, rc, "semi"))
		card.add_child(cv)
		var id := String(b.id)
		card.pressed.connect(func() -> void:
			Audio.play("ui_select", -6.0)
			_preview_bundle = id
			model.apply_bundle(id)
			_update_bundle_label(id))
		list.add_child(card)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	v.add_child(row)
	var equip := UI.button("EQUIP", 24, "primary", Vector2(220, 60))
	equip.name = "EquipButton"
	equip.pressed.connect(func() -> void:
		Game.profile.bundle = _preview_bundle
		Game.save_profile()
		_close_wardrobe())
	row.add_child(equip)
	var back := UI.button("BACK", 22, "dark", Vector2(180, 60))
	back.pressed.connect(func() -> void:
		model.apply_bundle(String(Game.profile.bundle))
		_update_bundle_label(String(Game.profile.bundle))
		_close_wardrobe())
	row.add_child(back)


func _close_wardrobe() -> void:
	if wardrobe:
		wardrobe.queue_free()
		wardrobe = null


# ---------------------------------------------------------------- input / anim

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		var vs := get_viewport().get_visible_rect().size
		if t.pressed and t.position.x < vs.x * 0.55 and t.position.y > vs.y * 0.25 and t.position.y < vs.y * 0.85:
			_drag_index = t.index
		elif not t.pressed and t.index == _drag_index:
			_drag_index = -1
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _drag_index:
			model.rotation.y += d.relative.x * 0.01
			_turntable = 2.0


func _process(delta: float) -> void:
	_time += delta
	_turntable -= delta
	if start_btn and not start_btn.disabled:
		var s := 1.0 + sin(_time * 3.0) * 0.015
		start_btn.pivot_offset = start_btn.size * 0.5
		start_btn.scale = Vector2(s, s)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if wardrobe:
			_close_wardrobe()
		else:
			get_tree().quit()
