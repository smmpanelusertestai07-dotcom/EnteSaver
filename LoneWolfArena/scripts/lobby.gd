extends Node3D
## Lobby: our character large on a lit hexagonal podium in a container yard at sunset (cheap
## 3D: a few boxes and props, fog, one shadowed light); drag on the character to turn it.
## UI in the battle-royale lobby layout (original art): player card (avatar, name + EDIT, level,
## XP line) and an offline coin strip top-left, logo + glyph buttons top-right, a text menu on
## the left (PRACTICE, PLAY WITH FRIENDS, BUNDLES, CUSTOM HUD, SETTINGS, HOW TO PLAY), the mode card
## "LONE WOLF / CARGO CAGE" with difficulty chips, match stats and the big START bottom-right.
## BUNDLES opens the wardrobe (vault-like: rarity tabs, item cards with rarity glow and bar,
## preview on the podium, EQUIP / BACK). START shows the match loading overlay
## (Loading.start_match) and then enters the arena.
## Node names used by the screenshot walkthrough: StartButton, SettingsButton, BundlesButton,
## Bundle_<id>, EquipButton.

const PODIUM_TOP := 0.24
## Camera: distance and heights of the main and wardrobe views; the x offset is worked out per
## screen aspect so the character stands at HERO_X (main) / WARD_X (wardrobe) of the width.
const CAM_DIST := 3.55
const CAM_Y := 0.98
const CAM_LOOK_Y := 1.12
const CAM_WARD_DIST := 3.75
const CAM_WARD_Y := 1.0
const CAM_WARD_LOOK_Y := 1.13
const CAM_FOV := 38.0
const HERO_X := 0.41
const WARD_X := 0.78
const MODEL_YAW := PI - 0.32
const RARITY_ORDER := ["legendary", "epic", "rare", "common"]
const CARD_SIZE := Vector2(168, 222)
const SKYLINE := "res://assets/ui/lobby_skyline.png"

var model: CharacterModel
var camera: Camera3D
var ui: CanvasLayer
var start_btn: Button
var _net_kind := "online"
var _net_list: VBoxContainer
var _net_status: Label
var _net_sig := ""
var _net_note := ""
var _net_refresh_t := 0.0
var wardrobe: Control
var _main_ui: Control
var _preview_bundle := ""
var _drag_index := -1
var _idle_t := 0.0
var _name_label: Label
var _bundle_label: Label
var _name_plate: Control
var _plate_label: Label
var _time := 0.0
var _cam_t := 1.0
var _cam_from_pos := Vector3(0, CAM_Y, CAM_DIST)
var _cam_from_look := Vector3(0, CAM_LOOK_Y, 0)
var _cam_to_pos := Vector3(0, CAM_Y, CAM_DIST)
var _cam_to_look := Vector3(0, CAM_LOOK_Y, 0)
## [3D scale, MSAA] for LOW, MEDIUM, HIGH, EXTREME.
const STAGE_QUALITY := [[0.85, Viewport.MSAA_DISABLED], [1.0, Viewport.MSAA_DISABLED], [1.0, Viewport.MSAA_2X],
	[1.0, Viewport.MSAA_4X]]

var _vp_msaa := Viewport.MSAA_DISABLED
var _vp_scale := 1.0
var _modal: Control
var _ward_grid: GridContainer
var _ward_filter := "all"
var _ward_info_name: Label
var _ward_info_rarity: Label
var _ward_info_desc: Label
var _ward_equip: Button
var _ward_tabs := {}


func _ready() -> void:
	_build_stage()
	_build_ui()
	Audio.play_music("lobby_music", -4.0)
	Game.mark("lobby ready")
	# Where START is on screen, for the emulator test, once the layout has settled (a method
	# connection is dropped automatically if the lobby is left first).
	get_tree().process_frame.connect(_mark_start, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	get_viewport().size_changed.connect(_on_viewport_resized)
	Game.settings_changed.connect(_apply_quality)
	_connect_net(Game.lan_service())
	_connect_net(Game.cloud_service())
	Game.lan.start_discovery()


## 3D resolution and anti-aliasing by the graphics setting. The stage (about 150-170 draw calls)
## is a little lighter than the arena, so each level gets a bit more than in a match.
func _apply_quality() -> void:
	var q: Array = STAGE_QUALITY[clampi(int(Game.settings.graphics), 0, STAGE_QUALITY.size() - 1)]
	var vp := get_viewport()
	vp.scaling_3d_scale = float(q[0])
	vp.msaa_3d = int(q[1]) as Viewport.MSAA


func _mark_start() -> void:
	Game.mark_ui("start", start_btn, start_btn.size / 2.0)


func _exit_tree() -> void:
	for svc: Node in [Game.lan, Game.cloud]:
		if svc:
			_disconnect_net(svc)
			svc.cancel_invite()
	if Game.lan:
		Game.lan.stop_discovery()
	if Game.cloud:
		Game.cloud.stop_lobby()
	# the arena sets its own anti-aliasing and 3D scale; hand the viewport back as it was
	var vp := get_viewport()
	if vp:
		vp.msaa_3d = _vp_msaa
		vp.scaling_3d_scale = _vp_scale


## Camera x that puts the character (at x = 0) at `frac` of the screen width on this aspect
## (the camera keeps its vertical field of view, so wider screens see more to the sides).
func _cam_x(frac: float, dist: float) -> float:
	var vs := get_viewport().get_visible_rect().size
	var aspect := vs.x / maxf(vs.y, 1.0)
	return -(frac - 0.5) * 2.0 * tan(deg_to_rad(CAM_FOV * 0.5)) * aspect * dist


func _main_view() -> Array:
	var x := _cam_x(HERO_X, CAM_DIST)
	return [Vector3(x, CAM_Y, CAM_DIST), Vector3(x, CAM_LOOK_Y, 0.0)]


func _ward_view() -> Array:
	var x := _cam_x(WARD_X, CAM_WARD_DIST)
	return [Vector3(x, CAM_WARD_Y, CAM_WARD_DIST), Vector3(x, CAM_WARD_LOOK_Y, 0.0)]


func _on_viewport_resized() -> void:
	if camera == null:
		return
	var v := _ward_view() if wardrobe else _main_view()
	_cam_to_pos = v[0]
	_cam_to_look = v[1]
	if _cam_t >= 1.0:
		camera.position = _cam_to_pos
		camera.look_at(_cam_to_look)


# ---------------------------------------------------------------- 3D stage

func _build_stage() -> void:
	var hi := int(Game.settings.graphics) >= 1
	var vp := get_viewport()
	_vp_msaa = vp.msaa_3d
	_vp_scale = vp.scaling_3d_scale
	_apply_quality()
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.07, 0.08, 0.26)
	sm.sky_horizon_color = Color(1.0, 0.52, 0.30)
	sm.sky_curve = 0.09
	sm.sky_energy_multiplier = 1.0
	sm.ground_horizon_color = Color(0.40, 0.24, 0.24)
	sm.ground_bottom_color = Color(0.05, 0.04, 0.05)
	sm.sun_angle_max = 30.0
	sm.sun_curve = 0.1
	sky.sky_material = sm
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.58, 0.5, 0.62)
	e.ambient_light_energy = 0.34          # low, so white fabric keeps its folds and shading
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	e.tonemap_exposure = 0.95
	e.tonemap_white = 4.0                 # roll off highlights (white outfits) instead of clipping
	e.glow_enabled = hi
	e.glow_intensity = 0.55
	e.glow_bloom = 0.06
	e.glow_hdr_threshold = 1.0
	e.fog_enabled = true
	e.fog_light_color = Color(0.86, 0.58, 0.5)
	e.fog_density = 0.0045
	e.adjustment_enabled = true
	e.adjustment_contrast = 1.1
	e.adjustment_saturation = 1.18
	e.fog_sky_affect = 0.0
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.62, 0.38)
	sun.light_energy = 1.1
	sun.shadow_enabled = false
	add_child(sun)
	# low sun behind the yard, to the right: backlight + the sky's sun disc
	sun.look_at(Vector3(-0.85, -0.17, 1.0))
	# Ground: polished concrete.
	var floor_m := StandardMaterial3D.new()
	floor_m.albedo_color = Color(0.30, 0.28, 0.29)
	floor_m.roughness = 0.62
	floor_m.metallic = 0.15
	var ft := UI.texture("res://assets/textures/floor_concrete.png")
	if ft:
		floor_m.albedo_texture = ft
		floor_m.uv1_scale = Vector3(42, 42, 1)      # about 5.7 m per tile on the 240 m plane
		var fn := UI.texture("res://assets/textures/floor_concrete_n.png")
		if fn:
			floor_m.normal_enabled = true
			floor_m.normal_texture = fn
			floor_m.normal_scale = 0.35        # polished concrete, not rippled sand
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(240, 240)            # reaches under the skyline card on the horizon
	floor_mi.mesh = pm
	floor_mi.material_override = floor_m
	add_child(floor_mi)
	_build_podium()
	_build_backdrop()
	_build_motes()
	# Character.
	model = CharacterModel.new()
	add_child(model)
	model.position = Vector3(0, PODIUM_TOP, 0)
	model.rotation.y = MODEL_YAW
	model.setup(String(Game.profile.bundle), false)
	model.play_lobby()
	# Lights: warm key from the side with the only shadow (a gradient across the body), cool +
	# warm rims, soft fill.
	var key := SpotLight3D.new()
	key.position = Vector3(3.1, 4.0, 2.7)
	key.light_energy = 2.5
	key.spot_range = 12.0
	key.spot_angle = 28.0
	key.spot_attenuation = 0.8
	key.light_color = Color(1.0, 0.9, 0.8)
	key.shadow_enabled = hi
	add_child(key)
	key.look_at(Vector3(0, 1.0, 0))
	var rim := SpotLight3D.new()
	rim.position = Vector3(-2.6, 3.0, -2.6)
	rim.light_energy = 6.0
	rim.spot_range = 10.0
	rim.spot_angle = 30.0
	rim.light_color = Color(0.3, 0.72, 1.0)
	add_child(rim)
	rim.look_at(Vector3(0, 1.25, 0))
	var rim2 := SpotLight3D.new()
	rim2.position = Vector3(2.8, 2.6, -2.4)
	rim2.light_energy = 5.0
	rim2.spot_range = 10.0
	rim2.spot_angle = 30.0
	rim2.light_color = Color(1.0, 0.55, 0.25)
	add_child(rim2)
	rim2.look_at(Vector3(0, 1.2, 0))
	var fill := OmniLight3D.new()
	fill.position = Vector3(-1.6, 1.5, 2.6)
	fill.light_energy = 0.42
	fill.omni_range = 6.0
	fill.light_color = Color(0.75, 0.8, 1.0)
	add_child(fill)
	camera = Camera3D.new()
	camera.fov = CAM_FOV
	add_child(camera)
	var view := _main_view()
	_cam_from_pos = view[0]
	_cam_to_pos = view[0]
	_cam_from_look = view[1]
	_cam_to_look = view[1]
	camera.position = view[0]
	camera.look_at(view[1])
	camera.current = true


func _unshaded(c: Color, additive := false, tex: Texture2D = null) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	if tex:
		m.albedo_texture = tex
	if additive:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.disable_fog = true
	return m


## Hexagonal podium: diamond-plate top, dark steel side, glowing yellow edge, a warm light pool.
func _build_podium() -> void:
	var top_m := StandardMaterial3D.new()
	top_m.albedo_color = Color(0.42, 0.42, 0.44)
	top_m.metallic = 0.75
	top_m.roughness = 0.38
	var dp := UI.texture("res://assets/textures/diamond_plate.png")
	if dp:
		# projected along each axis, so the 0.24 m side faces get the same plate size as the top
		top_m.albedo_texture = dp
		top_m.uv1_triplanar = true
		top_m.uv1_scale = Vector3(1.3, 1.3, 1.3)
		var dn := UI.texture("res://assets/textures/diamond_plate_n.png")
		if dn:
			top_m.normal_enabled = true
			top_m.normal_texture = dn
	var hex := CylinderMesh.new()
	hex.top_radius = 1.0
	hex.bottom_radius = 1.1
	hex.height = PODIUM_TOP
	hex.radial_segments = 6
	hex.rings = 1
	var pod := MeshInstance3D.new()
	pod.mesh = hex
	pod.material_override = top_m
	pod.position = Vector3(0, PODIUM_TOP * 0.5, 0)
	pod.rotation.y = PI / 6.0
	add_child(pod)
	# glowing edge: a thin, slightly larger hex just under the top
	var edge := CylinderMesh.new()
	edge.top_radius = 1.035
	edge.bottom_radius = 1.035
	edge.height = 0.04
	edge.cap_top = false
	edge.cap_bottom = false
	edge.radial_segments = 6
	edge.rings = 1
	var em := MeshInstance3D.new()
	em.mesh = edge
	# amber like the UI accent. Kept within 0..1: the Compatibility renderer clamps brighter
	# colours per channel, which turned an "HDR" amber into yellow-lime (R = G = 1)
	em.material_override = _unshaded(Color(1.0, 0.68, 0.05))
	em.position = Vector3(0, PODIUM_TOP - 0.03, 0)
	em.rotation.y = PI / 6.0
	add_child(em)
	# light pool on the floor around the podium
	var glow := UI.texture("res://assets/textures/glow.png")
	if glow:
		var q := MeshInstance3D.new()
		var qm := PlaneMesh.new()
		qm.size = Vector2(5.5, 5.5)
		q.mesh = qm
		q.material_override = _unshaded(Color(1.0, 0.55, 0.25, 0.55), true, glow)
		q.position = Vector3(0, 0.01, 0)
		add_child(q)


## The yard: container stacks either side, a long container behind with our emblem, a gantry
## crane and warehouse blocks on the skyline and two floodlight masts.
func _build_backdrop() -> void:
	var c20: PackedScene = load("res://assets/props/container.glb") if ResourceLoader.exists("res://assets/props/container.glb") else null
	var c40: PackedScene = load("res://assets/props/container_40.glb") if ResourceLoader.exists("res://assets/props/container_40.glb") else null
	var paint_tex := UI.texture("res://assets/textures/container_paint.png")
	var corr_n := UI.texture("res://assets/textures/corrugated_n.png")
	var stacks := [
		# [scene, position, yaw, colour]: two-high stacks either side, singles further out,
		# a long one far behind carrying our emblem.
		[c20, Vector3(-9.6, 0, -17.0), 10.0, Color(0.10, 0.34, 0.62)],
		[c20, Vector3(-9.6, 2.59, -17.0), 6.0, Color(0.72, 0.18, 0.12)],
		[c20, Vector3(-16.5, 0, -24.0), -4.0, Color(0.85, 0.50, 0.10)],
		[c20, Vector3(10.6, 0, -18.0), -8.0, Color(0.88, 0.48, 0.10)],
		[c20, Vector3(10.6, 2.59, -18.0), -12.0, Color(0.10, 0.45, 0.50)],
		[c20, Vector3(17.0, 0, -26.0), 4.0, Color(0.60, 0.14, 0.12)],
		[c40, Vector3(2.0, 0, -33.0), 0.0, Color(0.86, 0.80, 0.68)],
	]
	for s in stacks:
		var ps: PackedScene = s[0]
		var pos: Vector3 = s[1]
		var col: Color = s[3]
		var node: Node3D
		if ps:
			node = ps.instantiate()
			for mi in node.find_children("*", "MeshInstance3D", true, false):
				var m := mi as MeshInstance3D
				for i in m.mesh.get_surface_count():
					var mat := m.mesh.surface_get_material(i)
					if mat and mat.resource_name.to_lower().contains("paint"):
						var pmat := StandardMaterial3D.new()
						pmat.albedo_color = col
						# Rougher, softer ribs than in the match: far away, sharp rib highlights
						# turn into sparkling lines.
						pmat.roughness = 0.78
						pmat.metallic = 0.2
						if paint_tex:
							pmat.albedo_texture = paint_tex
						if corr_n:
							pmat.normal_enabled = true
							pmat.normal_texture = corr_n
							pmat.normal_scale = 0.55
						m.set_surface_override_material(i, pmat)
		else:
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(6.06, 2.59, 2.44)
			box.mesh = bm
			box.position.y = 1.295
			var mat := StandardMaterial3D.new()
			mat.albedo_color = col
			box.material_override = mat
			node = Node3D.new()
			node.add_child(box)
		add_child(node)
		node.position = pos
		node.rotation.y = deg_to_rad(float(s[2]))
	# our emblem painted on the long container behind
	var emb := UI.texture("emblem.png")
	if emb:
		var spr := Sprite3D.new()
		spr.texture = emb
		spr.pixel_size = 2.4 / 256.0
		spr.position = Vector3(2.0, 1.32, -31.76)
		spr.shaded = false
		spr.modulate = Color(1, 0.92, 0.85, 0.95)
		add_child(spr)
	# skyline: the painted card (port cranes, warehouses with lit windows, the city), hazy in
	# the fog; plain blocks only if the card is missing
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.10, 0.07, 0.11)
	dark.roughness = 0.9
	if not _build_skyline():
		for b in [[Vector3(8, 12, -66), Vector3(1.6, 24, 1.6)], [Vector3(44, 12, -66), Vector3(1.6, 24, 1.6)],
				[Vector3(26, 24.6, -66), Vector3(46, 2.2, 2.4)], [Vector3(-46, 4, -80), Vector3(34, 8, 12)],
				[Vector3(34, 5, -82), Vector3(30, 10, 12)]]:
			var bi := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = b[1]
			bi.mesh = bm
			bi.material_override = dark
			bi.position = b[0]
			bi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(bi)
	# floodlight masts with bright lamp heads (the glow does the rest)
	for side: float in [-1.0, 1.0]:
		var mast := MeshInstance3D.new()
		var mm := BoxMesh.new()
		mm.size = Vector3(0.3, 8.6, 0.3)       # lamp heads just inside the top of the view
		mast.mesh = mm
		mast.material_override = dark
		mast.position = Vector3(side * 13.5, 4.3, -21.0)
		add_child(mast)
		for k in 2:
			var head := MeshInstance3D.new()
			var hm := BoxMesh.new()
			hm.size = Vector3(0.9, 0.55, 0.25)
			head.mesh = hm
			head.material_override = _unshaded(Color(1.0, 0.93, 0.78) * 3.2)
			head.position = Vector3(side * 13.5 + (k - 0.5) * 1.05, 8.7, -20.8)
			add_child(head)


## Warm dust motes drifting up through the light around the podium: one CPUParticles3D of 30
## additive quads (one draw call, a few microseconds of CPU a frame) so the yard is never still.
func _build_motes() -> void:
	var p := CPUParticles3D.new()
	p.name = "Motes"
	p.amount = 30
	p.lifetime = 9.0
	p.preprocess = 9.0
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(4.5, 1.3, 2.5)
	p.position = Vector3(0.4, 1.3, -1.6)
	p.direction = Vector3(0.3, 1.0, 0.0)
	p.spread = 35.0
	p.gravity = Vector3(0.03, 0.02, 0.0)
	p.initial_velocity_min = 0.05
	p.initial_velocity_max = 0.18
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.3
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.25, 0.75, 1.0])
	g.colors = PackedColorArray([Color(1.0, 0.72, 0.42, 0.0), Color(1.0, 0.74, 0.45, 0.85), Color(1.0, 0.66, 0.38, 0.6), Color(1.0, 0.66, 0.38, 0.0)])
	p.color_ramp = g
	var qm := QuadMesh.new()
	qm.size = Vector2(0.045, 0.045)
	var m := _unshaded(Color.WHITE, true, UI.texture("res://assets/textures/glow.png"))
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	qm.material = m
	p.mesh = qm
	add_child(p)


## The skyline card: one big unshaded quad far behind the yard (one draw call), its texture
## painted by tools/media/make_keyart.py with transparency above the silhouettes, so the
## procedural sunset sky shows through. Its lower edge sits under the floor.
func _build_skyline() -> bool:
	var tex := UI.texture(SKYLINE)
	if tex == null:
		return false
	var w := 280.0
	var h := w * tex.get_height() / float(tex.get_width())
	var q := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(w, h)
	q.mesh = qm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_texture = tex
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	m.disable_receive_shadows = true
	m.disable_fog = true                   # the card's haze is painted in (far layers paler)
	q.material_override = m
	q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	q.position = Vector3(14.0, h * 0.5 - h * 0.08, -96.0)
	add_child(q)
	return true


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	_main_ui = Control.new()
	UI.full_rect(_main_ui)
	_main_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(_main_ui)
	var root := _main_ui
	# soft vignette so text reads over the 3D
	var top := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.5)], [0.16, Color(0, 0, 0, 0.0)], [0.8, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.55)]])
	UI.full_rect(top)
	root.add_child(top)
	var left := UI.gradient_rect([[0.0, Color(0, 0, 0, 0.45)], [0.25, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.0)]], true)
	UI.full_rect(left)
	root.add_child(left)
	_build_top_bar(root)
	_build_feature_card(root)
	_build_left_menu(root)
	_build_right_column(root)
	_build_bottom_left(root)
	_build_name_plate(root)


func _build_top_bar(root: Control) -> void:
	# Player card: avatar with level badge, name + EDIT, level and a thin XP line. The whole card
	# is a button that opens the name editor (a big touch target); the pencil does the same.
	var card := Button.new()
	card.name = "PlayerCard"
	card.position = Vector2(0, 0)
	card.size = Vector2(300, 62)
	card.custom_minimum_size = card.size
	card.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		card.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	card.draw.connect(func() -> void:
		var pts := PackedVector2Array([Vector2(0, 0), Vector2(300, 0), Vector2(286, 62), Vector2(0, 62)])
		var a := 0.9 if card.is_pressed() else 0.78
		card.draw_polygon(pts, PackedColorArray([Color(0, 0, 0, a), Color(0.1, 0.1, 0.12, 0.55), Color(0.1, 0.1, 0.12, 0.55), Color(0, 0, 0, a)]))
		card.draw_rect(Rect2(0, 60, 286, 2), Color(UI.ACCENT, 0.9)))
	card.button_down.connect(card.queue_redraw)
	card.button_up.connect(card.queue_redraw)
	card.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		_edit_name())
	root.add_child(card)
	var av := Panel.new()
	av.position = Vector2(8, 5)
	av.size = Vector2(52, 52)
	av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	av.add_theme_stylebox_override("panel", UI.box(Color(0.1, 0.1, 0.12), 0, 2, UI.ACCENT, 0.0))
	card.add_child(av)
	var em := UI.texture("emblem.png")
	if em:
		var t := TextureRect.new()
		t.texture = em
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		t.position = Vector2(3, 3)
		t.size = Vector2(46, 46)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		av.add_child(t)
	var lvb := PanelContainer.new()
	lvb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lvb.add_theme_stylebox_override("panel", UI.box(UI.ACCENT, 0, 0, Color.TRANSPARENT, 3.0))
	var lvl := UI.label(str(Game.level()), 14, UI.INK, "heavy")
	lvl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lvb.add_child(lvl)
	lvb.position = Vector2(42, 40)
	lvb.custom_minimum_size = Vector2(22, 18)
	card.add_child(lvb)
	# ellipsis first, then the size: an unclipped label would keep its full text width
	_name_label = UI.ellipsis(UI.label(String(Game.profile.name), 24, UI.TEXT, "bold"))
	_name_label.name = "PlayerName"
	_name_label.position = Vector2(72, 4)
	_name_label.size = Vector2(166, 30)
	card.add_child(_name_label)
	var edit := _pencil_button()
	edit.name = "EditName"
	edit.position = Vector2(244, 4)
	edit.pressed.connect(_edit_name)
	card.add_child(edit)
	var lv_txt := UI.label("LV %d" % Game.level(), 14, UI.ACCENT, "bold")
	lv_txt.position = Vector2(72, 34)
	card.add_child(lv_txt)
	var xp := Control.new()
	# The XP line starts after the measured "LV n" label (LV 100 is wider than LV 1).
	var xp_x := maxf(110.0, 72.0 + lv_txt.get_combined_minimum_size().x + 8.0)
	xp.position = Vector2(xp_x, 42)
	xp.size = Vector2(234.0 - xp_x, 4)
	xp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	xp.draw.connect(func() -> void:
		xp.draw_rect(Rect2(Vector2.ZERO, xp.size), Color(1, 1, 1, 0.15))
		xp.draw_rect(Rect2(Vector2.ZERO, Vector2(xp.size.x * Game.level_progress(), xp.size.y)), UI.ACCENT))
	card.add_child(xp)
	# Coin strip with a slanted end (offline, cosmetic).
	var strip := Control.new()
	strip.position = Vector2(292, 0)
	strip.size = Vector2(330, 46)
	strip.draw.connect(func() -> void:
		var s := strip.size
		strip.draw_colored_polygon(PackedVector2Array([Vector2(14, 0), Vector2(s.x, 0), Vector2(s.x - 22, s.y), Vector2(0, s.y)]), Color(0.16, 0.18, 0.22, 0.72))
		strip.draw_line(Vector2(s.x, 0), Vector2(s.x - 22, s.y), Color(1, 1, 1, 0.25), 1.5, true))
	root.add_child(strip)
	var sh := HBoxContainer.new()
	sh.position = Vector2(26, 5)
	sh.add_theme_constant_override("separation", 8)
	strip.add_child(sh)
	sh.add_child(UI.icon("v_coin", 30, Color(1.0, 0.82, 0.25)))
	var coins := UI.label(_fmt_thousands(_coins()), 26, UI.TEXT, "number")
	coins.name = "Coins"
	sh.add_child(coins)
	sh.add_child(UI.spacer(0))
	var div := ColorRect.new()
	div.color = Color(1, 1, 1, 0.18)
	div.custom_minimum_size = Vector2(1, 28)
	div.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sh.add_child(div)
	sh.add_child(UI.icon("v_trophy", 26, UI.TEXT))
	var wins := UI.label("%d WINS" % int(Game.profile.wins), 20, UI.TEXT, "bold")
	wins.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	wins.custom_minimum_size = Vector2(0, 34)
	sh.add_child(wins)
	var off := PanelContainer.new()
	off.add_theme_stylebox_override("panel", UI.chamfer(Color(UI.ACCENT, 0.18), 4, 1, Color(UI.ACCENT, 0.6), 6.0, ["br"]))
	off.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	off.add_child(UI.label("OFFLINE", 13, UI.ACCENT, "bold"))
	sh.add_child(off)
	# A long-time player's numbers widen the row: the slanted strip grows with it.
	strip.size.x = maxf(330.0, sh.position.x + sh.get_combined_minimum_size().x + 34.0)
	# Logo wordmark centred at about 0.75 W (the reference's place), glyph buttons top-right.
	var lg := UI.texture("logo.png")
	if lg:
		var lr := TextureRect.new()
		lr.name = "Logo"
		lr.texture = lg
		lr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		lr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		lr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		var lw := 48.0 * lg.get_width() / lg.get_height()
		lr.anchor_left = 0.755
		lr.anchor_right = 0.755
		lr.offset_left = -lw * 0.5
		lr.offset_right = lw * 0.5
		lr.offset_top = 6
		lr.offset_bottom = 54
		lr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(lr)
	var top_right := HBoxContainer.new()
	top_right.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	top_right.offset_left = -200
	top_right.offset_right = -10
	top_right.offset_top = 6
	top_right.offset_bottom = 56
	top_right.alignment = BoxContainer.ALIGNMENT_END
	top_right.add_theme_constant_override("separation", 8)
	root.add_child(top_right)
	var info := UI.glyph_button("v_info", 46, "?")
	info.name = "HelpButton"
	info.pressed.connect(_how_to_play)
	top_right.add_child(info)
	var gear := UI.glyph_button("v_settings", 46, "SET")
	gear.name = "SettingsButton"
	gear.pressed.connect(_open_settings)
	top_right.add_child(gear)


func _pencil_button() -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(44, 38)
	b.size = Vector2(44, 38)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_stylebox_override("normal", UI.chamfer(Color(1, 1, 1, 0.08), 4, 1, Color(1, 1, 1, 0.25), 0.0, ["br"]))
	b.add_theme_stylebox_override("hover", UI.chamfer(Color(1, 1, 1, 0.16), 4, 1, Color(1, 1, 1, 0.4), 0.0, ["br"]))
	b.add_theme_stylebox_override("pressed", UI.chamfer(Color(UI.ACCENT, 0.4), 4, 1, UI.ACCENT, 0.0, ["br"]))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var c := b.size * 0.5
		var d := Vector2(1, -1).normalized()
		var n := Vector2(1, 1).normalized()
		var k := 1.25
		var a := c - d * 7.0 * k
		var e := c + d * 6.0 * k
		b.draw_colored_polygon(PackedVector2Array([a + n * 2.2 * k, e + n * 2.2 * k, e - n * 2.2 * k, a - n * 2.2 * k]), UI.TEXT)
		b.draw_colored_polygon(PackedVector2Array([a + n * 2.2 * k, a - n * 2.2 * k, a - d * 4.0 * k]), UI.ACCENT))
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	return b


func _coins() -> int:
	return 500 + int(Game.profile.wins) * 120 + int(Game.profile.kills) * 15 + int(Game.profile.matches) * 25


func _fmt_thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


## Featured card above the menu: the duel art with the mode pitch (opens HOW TO PLAY).
func _build_feature_card(root: Control) -> void:
	var tex := UI.texture("mode_lonewolf.jpg")
	var b := Button.new()
	b.name = "FeatureCard"
	b.position = Vector2(10, 76)
	b.size = Vector2(300, 132)
	b.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		b.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	b.draw.connect(func() -> void:
		var r := Rect2(Vector2.ZERO, b.size)
		if tex:
			b.draw_texture_rect_region(tex, r, Rect2(40, 40, 560, 246))
		b.draw_rect(Rect2(0, r.size.y - 50, r.size.x, 50), Color(0, 0, 0, 0.55))
		b.draw_rect(r, Color(1, 1, 1, 0.25) if not b.is_hovered() else UI.ACCENT, false, 2.0))
	b.pressed.connect(_how_to_play)
	b.pressed.connect(func() -> void: Audio.play("ui_click", -4.0))
	root.add_child(b)
	var t1 := UI.shadowed(UI.label("1V1 DUEL", 26, UI.TEXT, "italic"))
	t1.position = Vector2(12, 80)
	b.add_child(t1)
	var t2 := UI.label("BEAT THE BOT IN CARGO CAGE", 14, UI.ACCENT, "bold")
	t2.position = Vector2(14, 108)
	b.add_child(t2)
	var tag := PanelContainer.new()
	tag.add_theme_stylebox_override("panel", UI.chamfer(UI.ACCENT, 5, 0, Color.TRANSPARENT, 6.0, ["br"]))
	tag.add_child(UI.label("NEW MAP", 13, UI.INK, "heavy"))
	tag.position = Vector2(8, 8)
	b.add_child(tag)


func _build_left_menu(root: Control) -> void:
	var menu := VBoxContainer.new()
	menu.name = "Menu"
	menu.position = Vector2(0, 236)
	menu.add_theme_constant_override("separation", 6)
	root.add_child(menu)
	var items := [
		["PRACTICE", "v_crosshair", "PracticeButton", _start_practice],
		["PLAY WITH FRIENDS", "v_player", "FriendsButton", _open_friends],
		["BUNDLES", "v_wardrobe", "BundlesButton", _open_wardrobe],
		["CUSTOM HUD", "v_hud", "CustomHudButton", Game.goto_hud_editor],
		["SETTINGS", "v_settings", "SettingsMenuButton", _open_settings],
		["HOW TO PLAY", "v_info", "HowToPlayButton", _how_to_play],
	]
	for it in items:
		menu.add_child(_menu_row(String(it[0]), String(it[1]), String(it[2]), it[3]))


func _menu_row(text: String, icon_name: String, node_name: String, action: Callable) -> Button:
	var b := Button.new()
	b.name = node_name
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(262, 50)
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.icon = UI.icon_texture(icon_name)
	b.expand_icon = true
	b.add_theme_constant_override("icon_max_width", 30)
	b.add_theme_constant_override("h_separation", 12)
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 25)
	var empty := UI.box(Color(0, 0, 0, 0), 0, 0, Color.TRANSPARENT, 0.0)
	empty.content_margin_left = 22
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		b.add_theme_stylebox_override(st, empty)
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.ACCENT)
	b.add_theme_color_override("font_pressed_color", UI.ACCENT)
	b.add_theme_constant_override("outline_size", 4)
	b.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	b.add_theme_color_override("icon_normal_color", UI.TEXT)
	b.add_theme_color_override("icon_hover_color", UI.ACCENT)
	b.add_theme_color_override("icon_pressed_color", UI.ACCENT)
	# The dark plate fading to the right is a child drawn BEHIND the button: a Button's own
	# `draw` signal fires after it has drawn its text and icon, so a plate drawn there would
	# cover (and grey out) the caption.
	var plate := Control.new()
	plate.name = "Plate"
	plate.show_behind_parent = true
	plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UI.full_rect(plate)
	plate.draw.connect(func() -> void:
		var s := plate.size
		var a := 0.86 if b.is_pressed() else 0.74
		var pts := PackedVector2Array([Vector2(0, 2), Vector2(s.x, 2), Vector2(s.x - 14, s.y - 2), Vector2(0, s.y - 2)])
		plate.draw_polygon(pts, PackedColorArray([Color(0, 0, 0, a), Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.0), Color(0, 0, 0, a)])))
	b.add_child(plate)
	# only the accent tick is drawn over the button (left of the icon, never over the text)
	b.draw.connect(func() -> void:
		b.draw_rect(Rect2(0, 2, 4, b.size.y - 4), UI.ACCENT if b.is_hovered() or b.is_pressed() else Color(1, 1, 1, 0.3)))
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		b.connect(sig, func() -> void:
			b.queue_redraw()
			plate.queue_redraw())
	b.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		action.call())
	return b


func _build_right_column(root: Control) -> void:
	# START (bottom-right): the hero button.
	start_btn = UI.hero_button("START", 52, Vector2(330, 78))
	start_btn.name = "StartButton"
	start_btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	start_btn.offset_left = -342
	start_btn.offset_top = -90
	start_btn.offset_right = -12
	start_btn.offset_bottom = -12
	start_btn.pressed.connect(_start)
	root.add_child(start_btn)
	# Mode card above it.
	var card := Control.new()
	card.name = "ModeCard"
	card.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	card.offset_left = -430
	card.offset_right = -12
	card.offset_top = -170
	card.offset_bottom = -98
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var thumb := UI.texture("mode_lonewolf.jpg")
	card.draw.connect(func() -> void:
		var s := card.size
		var pts := UI.chamfer_points(Rect2(Vector2.ZERO, s), 12.0, ["tl"])
		card.draw_polygon(pts, PackedColorArray([Color(0.16, 0.12, 0.07, 0.92), Color(0.16, 0.12, 0.07, 0.92), Color(0.07, 0.06, 0.05, 0.92), Color(0.07, 0.06, 0.05, 0.92), Color(0.12, 0.09, 0.06, 0.92)]))
		if thumb:
			# the two fighters of the mode art, at the slot's aspect (120 x 60)
			card.draw_texture_rect_region(thumb, Rect2(s.x - 128, 6, 120, s.y - 12), Rect2(110, 96, 420, 210))
			card.draw_rect(Rect2(s.x - 128, 6, 120, s.y - 12), Color(1, 1, 1, 0.35), false, 1.5)
		card.draw_rect(Rect2(0, s.y - 2, s.x, 2), Color(UI.AMBER, 0.8)))
	root.add_child(card)
	var mode_l := UI.shadowed(UI.label("LONE WOLF", 32, UI.AMBER, "heavy"))
	mode_l.position = Vector2(20, 2)
	card.add_child(mode_l)
	var map_l := UI.label("CARGO CAGE", 22, UI.TEXT, "heavy")
	map_l.position = Vector2(22, 38)
	card.add_child(map_l)
	var sub := UI.label("1 VS 1  ·  1 ROUND", 14, UI.TEXT_DIM, "bold")
	sub.position = Vector2(138, 44)
	card.add_child(sub)
	# Difficulty chips above the card.
	var diff := HBoxContainer.new()
	diff.name = "Difficulty"
	diff.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	diff.offset_left = -430
	diff.offset_right = -12
	diff.offset_top = -214
	diff.offset_bottom = -178
	diff.add_theme_constant_override("separation", 6)
	diff.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(diff)
	var cap := UI.label("BOT", 15, UI.TEXT_DIM, "bold")
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.custom_minimum_size = Vector2(0, 36)
	diff.add_child(cap)
	var group := ButtonGroup.new()
	for i in Game.DIFFICULTY_NAMES.size():
		diff.add_child(_diff_chip(String(Game.DIFFICULTY_NAMES[i]), i, group))
	# Match stats chips.
	var stats := HBoxContainer.new()
	stats.name = "Stats"
	stats.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	stats.offset_left = -430
	stats.offset_right = -12
	stats.offset_top = -258
	stats.offset_bottom = -222
	stats.add_theme_constant_override("separation", 6)
	stats.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(stats)
	for s in [["v_player", "MATCHES", Game.profile.matches], ["v_trophy", "WINS", Game.profile.wins], ["v_skull", "KILLS", Game.profile.kills]]:
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", UI.chamfer(Color(0, 0, 0, 0.55), 6, 1, Color(1, 1, 1, 0.12), 10.0, ["br"]))
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 6)
		h.add_child(UI.icon(String(s[0]), 20, UI.TEXT_DIM))
		var v := UI.label(str(int(s[2])), 22, UI.TEXT, "number")
		v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		h.add_child(v)
		var c := UI.label(String(s[1]), 13, UI.TEXT_DIM, "bold")
		c.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		h.add_child(c)
		p.add_child(h)
		stats.add_child(p)


func _diff_chip(text: String, idx: int, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.name = "Diff_" + text
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = idx == int(Game.settings.difficulty)
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.custom_minimum_size = Vector2(104, 36)
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 17)
	var off := UI.chamfer(Color(0, 0, 0, 0.55), 8, 1, Color(1, 1, 1, 0.2), 8.0, ["tl", "br"], 0.0)
	var hov := UI.chamfer(Color(1, 1, 1, 0.1), 8, 1, Color(1, 1, 1, 0.35), 8.0, ["tl", "br"], 0.0)
	var on := UI.chamfer(UI.ACCENT, 8, 0, Color.TRANSPARENT, 8.0, ["tl", "br"], 0.0)
	b.add_theme_stylebox_override("normal", off)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT)
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		Game.settings.difficulty = idx
		Game.save_settings())
	return b


func _build_bottom_left(root: Control) -> void:
	var info := CharacterModel.bundle_info(String(Game.profile.bundle))
	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	box.offset_left = 22
	box.offset_right = 420
	box.offset_top = -78
	box.offset_bottom = -12
	box.add_theme_constant_override("separation", 2)
	root.add_child(box)
	var cap := UI.label("OUTFIT", 13, UI.TEXT_DIM, "bold")
	box.add_child(cap)
	_bundle_label = UI.shadowed(UI.label("", 22, UI.RARITY_COLORS[info.rarity], "bold"))
	box.add_child(_bundle_label)
	_update_bundle_label(String(Game.profile.bundle))
	var ver := UI.label("v%s" % ProjectSettings.get_setting("application/config/version", "1.0"), 13, Color(1, 1, 1, 0.45), "semi")
	box.add_child(ver)


## Name plate under the character's feet (follows the projected position).
func _build_name_plate(root: Control) -> void:
	_name_plate = PanelContainer.new()
	_name_plate.add_theme_stylebox_override("panel", UI.chamfer(Color(0, 0, 0, 0.6), 6, 1, Color(1, 1, 1, 0.14), 14.0, ["tl", "br"]))
	_name_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.add_child(UI.icon("v_player", 18, UI.ACCENT))
	_plate_label = UI.label(String(Game.profile.name), 18, UI.TEXT, "bold")
	h.add_child(_plate_label)
	_name_plate.add_child(h)
	root.add_child(_name_plate)


func _update_bundle_label(id: String) -> void:
	var info := CharacterModel.bundle_info(id)
	_bundle_label.text = "%s  ·  %s" % [info.name, String(info.rarity).to_upper()]
	_bundle_label.add_theme_color_override("font_color", UI.RARITY_COLORS[info.rarity])


func _start() -> void:
	if start_btn.disabled:
		return
	Game.practice = false
	Game.online = false
	start_btn.disabled = true
	UI.set_caption(start_btn, "MATCHING")
	Loading.start_match(self)


# ---------------------------------------------------------------- play with friends (Lan / Cloud)

## Two ways to find a friend: ONLINE (internet, no account: a free public relay carries
## end-to-end encrypted messages, see Cloud) and SAME WI-FI (no server at all, see Lan). Players
## show up by name; CHALLENGE sends a request, the other phone accepts or declines. The ONLINE
## list connects only once this tab is opened.
func _open_friends(kind := "online") -> void:
	_net_kind = kind
	var svc: Node = _net_service()
	if kind == "online":
		Game.cloud_service().start_lobby()
	var v := _open_modal("PLAY WITH FRIENDS", 940.0)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 10)
	for t: Array in [["online", "ONLINE"], ["wifi", "SAME WI-FI"]]:
		var b := UI.button(String(t[1]), 20, "primary" if t[0] == kind else "dark", Vector2(220, 48))
		var tk := String(t[0])
		b.pressed.connect(func() -> void:
			if tk != _net_kind:
				_open_friends(tk))
		tabs.add_child(b)
	v.add_child(tabs)
	var note := "Play a friend from anywhere over the internet. No sign-up needed: friends who are online show up by name." \
		if kind == "online" else "Same Wi-Fi or one phone's hotspot: nearby players show up by name."
	var info := UI.label(note, 17, UI.TEXT_DIM, "semi")
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(info)
	_net_status = UI.label("", 20, UI.ACCENT, "bold")
	v.add_child(_net_status)
	_net_list = VBoxContainer.new()
	_net_list.add_theme_constant_override("separation", 8)
	_net_list.custom_minimum_size = Vector2(0, 170)
	v.add_child(_net_list)
	_net_sig = "-"
	_net_note = ""
	if svc:
		_refresh_friends()


func _net_service() -> Node:
	return (Game.cloud_service() as Node) if _net_kind == "online" else (Game.lan_service() as Node)


func _refresh_friends() -> void:
	if _net_list == null or not is_instance_valid(_net_list):
		return
	var svc: Node = _net_service()
	var waiting := String(svc.waiting_for())
	var peers: Dictionary = svc.peers
	if _net_kind == "online" and String(svc.status) != "online":
		match String(svc.status):
			"preparing":
				_net_status.text = "GETTING READY..."
			"connecting":
				_net_status.text = "CONNECTING..."
			_:
				_net_status.text = "NO INTERNET: RETRYING..."
	elif _net_kind == "wifi" and String(svc.local_address()) == "":
		_net_status.text = "NOT ON WI-FI: JOIN A WI-FI NETWORK OR A HOTSPOT"
	elif waiting != "":
		_net_status.text = "WAITING FOR %s TO ACCEPT..." % waiting
	elif _net_note != "":
		_net_status.text = _net_note
	elif peers.is_empty():
		_net_status.text = "LOOKING FOR PLAYERS ONLINE..." if _net_kind == "online" else "LOOKING FOR PLAYERS ON THIS WI-FI..."
	else:
		_net_status.text = "PLAYERS ONLINE" if _net_kind == "online" else "PLAYERS NEARBY"
	var sig := waiting
	for id in peers:
		sig += "|%s:%s" % [id, peers[id].name]
	if sig == _net_sig:
		return
	_net_sig = sig
	for c in _net_list.get_children():
		c.queue_free()
	for id: String in peers:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		var who := UI.label("%s  #%s" % [String(peers[id].name), id.left(4).to_upper()], 26, UI.TEXT, "heavy")
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		who.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(who)
		var b := UI.button("CANCEL" if waiting != "" else "CHALLENGE", 20, "light" if waiting != "" else "primary", Vector2(230, 52))
		b.pressed.connect(func() -> void:
			var sv: Node = _net_service()
			_net_note = ""
			if String(sv.waiting_for()) != "":
				sv.cancel_invite()
			elif not bool(sv.invite(id)):
				_net_note = "COULD NOT SEND THE REQUEST, TRY AGAIN"
			_net_sig = "-"
			_refresh_friends())
		row.add_child(b)
		_net_list.add_child(row)


func _on_net_invited(who: String, svc: Node) -> void:
	_net_list = null
	var v := _open_modal("CHALLENGE", 640.0)
	var t := UI.label("%s wants a 1 vs 1 (%s)" % [who, "online" if svc is Cloud else "Wi-Fi"], 26, UI.TEXT, "heavy")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(t)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var no := UI.button("DECLINE", 20, "light", Vector2(190, 52))
	no.pressed.connect(func() -> void:
		svc.answer(false)
		_close_modal())
	var yes := UI.button("ACCEPT", 22, "primary", Vector2(190, 52))
	yes.name = "AcceptButton"
	yes.pressed.connect(func() -> void:
		yes.disabled = true
		UI.set_caption(yes, "CONNECTING")
		svc.answer(true))
	row.add_child(no)
	row.add_child(yes)
	v.add_child(row)


func _on_net_invite_cancelled(_svc: Node) -> void:
	if _modal and is_instance_valid(_modal) and _modal.find_child("AcceptButton", true, false):
		_close_modal()


func _on_net_answered(accepted: bool, who: String, _svc: Node) -> void:
	if not accepted:
		_net_note = "%s DECLINED (OR DID NOT ANSWER)" % who
		_net_sig = "-"


func _on_net_session(_host: bool, svc: Node) -> void:
	if start_btn.disabled:
		return
	Game.practice = false
	Game.online = true
	Game.session = svc
	_close_modal()
	start_btn.disabled = true
	UI.set_caption(start_btn, "MATCHING")
	Loading.start_match(self)


func _on_net_ended(reason: String, _svc: Node) -> void:
	Game.online = false
	_net_note = "CONNECTION LOST" if reason == "left" else reason.to_upper()
	_net_sig = "-"


func _connect_net(svc: Node) -> void:
	svc.invited.connect(_on_net_invited.bind(svc))
	svc.invite_cancelled.connect(_on_net_invite_cancelled.bind(svc))
	svc.invite_answered.connect(_on_net_answered.bind(svc))
	svc.session_started.connect(_on_net_session.bind(svc))
	svc.session_ended.connect(_on_net_ended.bind(svc))


func _disconnect_net(svc: Node) -> void:
	for sig in ["invited", "invite_cancelled", "invite_answered", "session_started", "session_ended"]:
		for c: Dictionary in svc.get_signal_connection_list(sig):
			if (c.callable as Callable).get_object() == self:
				svc.disconnect(sig, c.callable)


## Practice against a training dummy that never goes down (no zone, no clock, nothing recorded).
func _start_practice() -> void:
	if start_btn.disabled:
		return
	Game.practice = true
	start_btn.disabled = true
	Loading.start_match(self)


func _open_settings() -> void:
	if _find_settings():
		return
	var sp := SettingsPanel.new()
	ui.add_child(sp)


func _find_settings() -> SettingsPanel:
	for c in ui.get_children():
		if c is SettingsPanel:
			return c
	return null


# ---------------------------------------------------------------- modals (how to play, name)

## A popup in the reference look: the light header strip (dark caps title, hazard line, X on a
## dark tile), then the near-black body with a yellow corner mark. Returns the body column.
func _open_modal(title: String, width := 980.0) -> VBoxContainer:
	_close_modal()
	_modal = Control.new()
	_modal.name = "Modal"
	UI.full_rect(_modal)
	_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(_modal)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.72)
	UI.full_rect(shade)
	_modal.add_child(shade)
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 0)
	frame.anchor_left = 0.5
	frame.anchor_right = 0.5
	frame.anchor_top = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -width * 0.5
	frame.offset_right = width * 0.5
	frame.grow_vertical = Control.GROW_DIRECTION_BOTH
	_modal.add_child(frame)
	var head := UI.popup_header(title, 26, 54.0)
	(head.get_node("Close") as Button).pressed.connect(_close_modal)
	frame.add_child(head)
	var panel := UI.popup_body()
	frame.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	panel.add_child(v)
	_modal.modulate.a = 0.0
	_modal.create_tween().tween_property(_modal, "modulate:a", 1.0, 0.15)
	return v


func _close_modal() -> void:
	if _modal:
		_modal.queue_free()
		_modal = null


const HOW_TO := [
	["MOVE & LOOK", [
		["stance_sprint", "MOVE", "Left thumb on the joystick. Push it past the ring to sprint."],
		["v_eye", "LOOK", "Drag anywhere on the right side to turn the camera."],
		["v_fire", "FIRE", "Hold the big button to shoot; keep holding and drag to aim while firing."],
		["v_scope", "SCOPE", "Aim down the red dot, or the sniper scope with a sniper rifle."],
		["stance_crouch", "CROUCH · PRONE · JUMP", "Crouch and prone make you a smaller target; jump onto crates."],
		["v_reload", "RELOAD", "Tap the weapon panel (or it reloads by itself when the magazine is empty)."],
	]],
	["ITEMS", [
		["v_medkit", "MEDKIT  x2", "+75 HP over 4 seconds. You walk slower; firing cancels it."],
		["v_wall", "SHIELD WALL  x2", "Throws up cover that soaks 600 damage for 45 seconds."],
		["item_grenade", "FRAG GRENADE  x1", "Up to 150 damage at the centre (a vest halves it), 3-second fuse."],
	]],
	["THE MATCH", [
		["v_player", "FIRST TO 5 ROUNDS", "1 vs 1, 200 HP each, Lv2 helmet and vest. Win 5 rounds to win the match."],
		["v_timer", "PICK THE GUN", "Every 2 rounds one side picks the gun you both use; the pick takes turns."],
		["v_zone", "SAFE ZONE", "Holds 25 s, then shrinks. Outside it you lose HP; at time-out more HP wins."],
	]],
]


func _how_to_play() -> void:
	var v := _open_modal("HOW TO PLAY", 1040.0)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 470)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var cols := HBoxContainer.new()
	cols.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_theme_constant_override("separation", 24)
	scroll.add_child(cols)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	cols.add_child(left)
	cols.add_child(right)
	for gi in HOW_TO.size():
		var g: Array = HOW_TO[gi]
		var col := left if gi == 0 else right
		if gi > 1:
			col.add_child(UI.spacer(6))
		col.add_child(UI.section(String(g[0]), 18))
		for it in g[1]:
			col.add_child(_howto_item(String(it[0]), String(it[1]), String(it[2])))


func _howto_item(icon_name: String, title: String, text: String) -> Control:
	var p := PanelContainer.new()
	var st := UI.chamfer(Color(1, 1, 1, 0.045), 6, 0, Color.TRANSPARENT, 10.0, ["br"])
	st.content_margin_top = 5
	st.content_margin_bottom = 5
	p.add_theme_stylebox_override("panel", st)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var ic := PanelContainer.new()
	var ics := UI.box(Color(0, 0, 0, 0.45), 21, 1, Color(1, 1, 1, 0.18), 0.0)
	ics.set_content_margin_all(7)
	ic.add_theme_stylebox_override("panel", ics)
	ic.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ic.add_child(UI.icon(icon_name, 28, UI.TEXT))
	h.add_child(ic)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(UI.label(title, 17, UI.ACCENT, "bold"))
	var t := UI.label(text, 15, UI.TEXT, "semi")
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.custom_minimum_size = Vector2(380, 0)
	v.add_child(t)
	h.add_child(v)
	p.add_child(h)
	return p


func _edit_name() -> void:
	var v := _open_modal("PLAYER NAME", 560.0)
	v.add_child(UI.label("Up to 14 letters or digits. Shown in matches and results.", 16, UI.TEXT_DIM, "semi"))
	var le := LineEdit.new()
	le.name = "NameEdit"
	le.text = String(Game.profile.name)
	le.max_length = 14
	le.custom_minimum_size = Vector2(0, 54)
	le.add_theme_font_override("font", UI.font("bold"))
	le.add_theme_font_size_override("font_size", 26)
	le.add_theme_stylebox_override("normal", UI.chamfer(Color(0, 0, 0, 0.5), 8, 1, Color(1, 1, 1, 0.25), 14.0, ["br"]))
	le.add_theme_stylebox_override("focus", UI.chamfer(Color(0, 0, 0, 0.5), 8, 2, UI.ACCENT, 14.0, ["br"]))
	le.add_theme_color_override("font_color", UI.TEXT)
	le.add_theme_color_override("caret_color", UI.ACCENT)
	v.add_child(le)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 12)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(170, 52))
	cancel.pressed.connect(_close_modal)
	var ok := UI.button("OK", 22, "primary", Vector2(170, 52))
	ok.name = "NameOk"
	var apply := func() -> void:
		var n := Game.clean_name(le.text)
		if n != "":
			Game.profile.name = n
			Game.save_profile()
			_name_label.text = n
			_plate_label.text = n
		_close_modal()
	ok.pressed.connect(apply)
	le.text_submitted.connect(func(_t: String) -> void: apply.call())
	row.add_child(cancel)
	row.add_child(ok)
	v.add_child(row)
	le.grab_focus()
	le.caret_column = le.text.length()


# ---------------------------------------------------------------- wardrobe

func _open_wardrobe() -> void:
	if wardrobe:
		return
	_close_modal()
	_preview_bundle = String(Game.profile.bundle)
	wardrobe = Control.new()
	wardrobe.name = "Wardrobe"
	UI.full_rect(wardrobe)
	wardrobe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(wardrobe)
	_main_ui.visible = false
	var view := _ward_view()
	_move_camera(view[0], view[1])
	var shade := UI.gradient_rect([[0.0, Color(0.03, 0.03, 0.04, 0.94)], [0.5, Color(0.03, 0.03, 0.04, 0.88)], [0.66, Color(0, 0, 0, 0.0)], [1.0, Color(0, 0, 0, 0.0)]], true)
	UI.full_rect(shade)
	wardrobe.add_child(shade)
	# Header.
	var head := HBoxContainer.new()
	head.position = Vector2(26, 16)
	head.add_theme_constant_override("separation", 16)
	wardrobe.add_child(head)
	head.add_child(UI.section("BUNDLES", 30))
	var note := UI.label("ALL OUTFITS UNLOCKED  ·  OFFLINE", 15, UI.TEXT_DIM, "bold")
	note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	note.custom_minimum_size = Vector2(0, 36)
	head.add_child(note)
	# Rarity tabs (left).
	var tabs := VBoxContainer.new()
	tabs.position = Vector2(0, 76)
	tabs.add_theme_constant_override("separation", 4)
	wardrobe.add_child(tabs)
	_ward_tabs.clear()
	for f in ["all", "legendary", "epic", "rare", "common"]:
		var tb := _ward_tab(f)
		tabs.add_child(tb)
		_ward_tabs[f] = tb
	# Item grid with the item info strip under it.
	var col := VBoxContainer.new()
	col.anchor_bottom = 1.0
	col.offset_left = 196
	col.offset_right = 196 + 3 * CARD_SIZE.x + 2 * 10
	col.offset_top = 74
	col.offset_bottom = -16
	col.add_theme_constant_override("separation", 10)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wardrobe.add_child(col)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)
	_ward_grid = GridContainer.new()
	_ward_grid.columns = 3
	_ward_grid.add_theme_constant_override("h_separation", 10)
	_ward_grid.add_theme_constant_override("v_separation", 10)
	scroll.add_child(_ward_grid)
	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 0)
	col.add_child(info)
	var ih := PanelContainer.new()
	ih.add_theme_stylebox_override("panel", UI.chamfer(Color(0.05, 0.42, 0.48, 0.95), 8, 0, Color.TRANSPARENT, 14.0, ["tl"]))
	var ihh := HBoxContainer.new()
	ihh.add_theme_constant_override("separation", 12)
	ihh.add_child(UI.icon("v_wardrobe", 24, UI.TEXT))
	_ward_info_name = UI.label("", 24, UI.TEXT, "bold")
	_ward_info_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ihh.add_child(_ward_info_name)
	_ward_info_rarity = UI.label("", 16, UI.TEXT, "heavy")
	_ward_info_rarity.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ihh.add_child(_ward_info_rarity)
	ih.add_child(ihh)
	info.add_child(ih)
	var ib := PanelContainer.new()
	ib.add_theme_stylebox_override("panel", UI.chamfer(Color(0.06, 0.06, 0.07, 0.9), 8, 0, Color.TRANSPARENT, 14.0, ["br"]))
	_ward_info_desc = UI.label("", 17, UI.TEXT, "semi")
	_ward_info_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ib.add_child(_ward_info_desc)
	info.add_child(ib)
	# EQUIP / BACK under the preview.
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	row.offset_left = -460
	row.offset_right = -20
	row.offset_top = -80
	row.offset_bottom = -14
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wardrobe.add_child(row)
	var back := UI.button("BACK", 26, "light", Vector2(170, 64))
	back.name = "BackButton"
	back.pressed.connect(func() -> void:
		model.apply_bundle(String(Game.profile.bundle))
		_update_bundle_label(String(Game.profile.bundle))
		_close_wardrobe())
	row.add_child(back)
	_ward_equip = UI.hero_button("EQUIP", 38, Vector2(240, 64))
	_ward_equip.name = "EquipButton"
	_ward_equip.pressed.connect(func() -> void:
		Game.profile.bundle = _preview_bundle
		Game.save_profile()
		_update_bundle_label(_preview_bundle)
		_close_wardrobe())
	row.add_child(_ward_equip)
	_fill_wardrobe()
	wardrobe.modulate.a = 0.0
	wardrobe.create_tween().tween_property(wardrobe, "modulate:a", 1.0, 0.2)


func _ward_tab(f: String) -> Button:
	var b := Button.new()
	b.name = "Tab_" + f
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(190, 52)
	b.text = f.to_upper()
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.button_pressed = f == _ward_filter
	b.add_theme_font_override("font", UI.font("bold"))
	b.add_theme_font_size_override("font_size", 22)
	var normal := UI.box(Color(0, 0, 0, 0), 0, 0, Color.TRANSPARENT, 0.0)
	var hover := UI.box(Color(1, 1, 1, 0.06), 0, 0, Color.TRANSPARENT, 0.0)
	var on := UI.chamfer(UI.ACCENT, 12, 0, Color.TRANSPARENT, 0.0, ["br"])
	for st in [normal, hover, on]:
		st.content_margin_left = 30
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", on)
	b.add_theme_stylebox_override("hover_pressed", on)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", UI.TEXT if f == "all" else UI.RARITY_COLORS.get(f, UI.TEXT))
	b.add_theme_color_override("font_hover_color", UI.TEXT)
	b.add_theme_color_override("font_pressed_color", UI.INK)
	b.add_theme_color_override("font_hover_pressed_color", UI.INK)
	b.draw.connect(func() -> void:
		if b.button_pressed:
			UI.draw_tab_selected(b, b.size))
	b.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_ward_filter = f
		for k in _ward_tabs:
			(_ward_tabs[k] as Button).set_pressed_no_signal(k == f)
			(_ward_tabs[k] as Button).queue_redraw()
		_fill_wardrobe())
	return b


func _fill_wardrobe() -> void:
	for c in _ward_grid.get_children():
		_ward_grid.remove_child(c)
		c.queue_free()
	var group := ButtonGroup.new()
	var list := []
	for r in RARITY_ORDER:
		for b in CharacterModel.BUNDLE_INFO:
			if b.rarity == r and (_ward_filter == "all" or _ward_filter == r):
				list.append(b)
	# The info box and the podium follow the first card when the previewed one is filtered out.
	if not list.is_empty() and not list.any(func(b: Dictionary) -> bool: return String(b.id) == _preview_bundle):
		_preview_bundle = String(list[0].id)
		model.apply_bundle(_preview_bundle)
		_update_bundle_label(_preview_bundle)
	for b in list:
		_ward_grid.add_child(_bundle_card(b, group))
	_update_ward_info()


func _bundle_card(b: Dictionary, group: ButtonGroup) -> Button:
	var id := String(b.id)
	var rc: Color = UI.RARITY_COLORS[b.rarity]
	var card := Button.new()
	card.name = "Bundle_" + id
	card.toggle_mode = true
	card.button_group = group
	card.button_pressed = id == _preview_bundle
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = CARD_SIZE
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		card.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	var portrait := UI.texture("bundle_%s.png" % id)
	var glow := UI.radial_glow(Color(rc, 0.62))
	var floor_glow := UI.radial_glow(Color(rc.lightened(0.15), 0.5))
	card.draw.connect(func() -> void:
		var s := card.size
		card.draw_rect(Rect2(Vector2.ZERO, s), Color(0.075, 0.072, 0.07, 0.97))
		# rarity glow: a smooth radial gradient behind the outfit, inside the card, plus a
		# brighter pool at the feet
		card.draw_texture_rect(glow, Rect2(0, 0, s.x, s.y - 46), false)
		card.draw_texture_rect(floor_glow, Rect2(s.x * 0.12, s.y * 0.62, s.x * 0.76, s.y * 0.2), false)
		card.draw_rect(Rect2(0, 0, s.x, s.y * 0.5), Color(1, 1, 1, 0.02))
		if portrait:
			var ph := s.y - 58
			var pw := ph * 0.75
			card.draw_texture_rect(portrait, Rect2((s.x - pw) * 0.5, 8, pw, ph), false)
		# name strip + rarity bar
		card.draw_rect(Rect2(0, s.y - 52, s.x, 48), Color(0, 0, 0, 0.6))
		card.draw_rect(Rect2(0, s.y - 5, s.x, 5), rc)
		# equipped: yellow outline + tick; previewed: white outline
		var equipped := id == String(Game.profile.bundle)
		if equipped:
			card.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), UI.ACCENT, false, 3.0)
			UI.draw_tick_corner(card, Vector2(s.x, s.y - 5), 34.0)
		if card.button_pressed and not equipped:
			card.draw_rect(Rect2(Vector2(1.5, 1.5), s - Vector2(3, 3)), Color(1, 1, 1, 0.95), false, 3.0)
		elif card.is_hovered() and not equipped:
			card.draw_rect(Rect2(Vector2(1, 1), s - Vector2(2, 2)), Color(1, 1, 1, 0.5), false, 2.0)
		elif not equipped:
			card.draw_rect(Rect2(Vector2(0.5, 0.5), s - Vector2(1, 1)), Color(1, 1, 1, 0.1), false, 1.0))
	var nm := UI.ellipsis(UI.label(String(b.name), 18, UI.TEXT, "bold"))
	nm.position = Vector2(9, CARD_SIZE.y - 50)
	nm.size = Vector2(CARD_SIZE.x - 18, 24)
	card.add_child(nm)
	var rl := UI.label(String(b.rarity).to_upper(), 14, rc, "bold")
	rl.position = Vector2(9, CARD_SIZE.y - 28)
	card.add_child(rl)
	card.mouse_entered.connect(card.queue_redraw)
	card.mouse_exited.connect(card.queue_redraw)
	card.toggled.connect(func(_on: bool) -> void: card.queue_redraw())
	card.pressed.connect(func() -> void:
		Audio.play("ui_select", -6.0)
		_preview_bundle = id
		model.apply_bundle(id)
		_update_bundle_label(id)
		_update_ward_info()
		for other in _ward_grid.get_children():
			(other as Control).queue_redraw())
	return card


func _update_ward_info() -> void:
	if _ward_info_name == null:
		return
	var info := CharacterModel.bundle_info(_preview_bundle)
	_ward_info_name.text = String(info.name)
	_ward_info_rarity.text = String(info.rarity).to_upper()
	_ward_info_rarity.add_theme_color_override("font_color", UI.RARITY_COLORS[info.rarity].lightened(0.25))
	var equipped := _preview_bundle == String(Game.profile.bundle)
	_ward_info_desc.text = String(info.desc) + ("   EQUIPPED" if equipped else "")
	if _ward_equip:
		UI.set_caption(_ward_equip, "EQUIPPED" if equipped else "EQUIP")


func _close_wardrobe() -> void:
	if wardrobe:
		wardrobe.queue_free()
		wardrobe = null
		_ward_grid = null
		_ward_info_name = null
		_ward_equip = null
	_main_ui.visible = true
	var view := _main_view()
	_move_camera(view[0], view[1])


func _move_camera(pos: Vector3, look: Vector3) -> void:
	# start from where the camera looks now (also mid-transition)
	_cam_from_pos = camera.position
	_cam_from_look = camera.position + (-camera.global_basis.z) * camera.position.distance_to(_cam_to_look)
	_cam_to_pos = pos
	_cam_to_look = look
	_cam_t = 0.0


# ---------------------------------------------------------------- input / anim

func _modal_open() -> bool:
	return _modal != null or _find_settings() != null


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed and _drag_index == -1 and not _modal_open() and _in_drag_zone(t.position):
			_drag_index = t.index
		elif not t.pressed and t.index == _drag_index:
			_drag_index = -1
	elif event is InputEventScreenDrag:
		var d := event as InputEventScreenDrag
		if d.index == _drag_index:
			var vs := get_viewport().get_visible_rect().size
			model.rotation.y += d.relative.x / maxf(vs.x, 1.0) * 6.0
			_idle_t = 0.0


## Where a drag turns the character: around it, between the menus.
func _in_drag_zone(p: Vector2) -> bool:
	var vs := get_viewport().get_visible_rect().size
	var x := p.x / vs.x
	var y := p.y / vs.y
	if wardrobe:
		return x > 0.62 and y > 0.1 and y < 0.68
	return x > 0.24 and x < 0.66 and y > 0.1 and y < 0.86


func _process(delta: float) -> void:
	_time += delta
	_idle_t += delta
	if _net_list and is_instance_valid(_net_list):
		_net_refresh_t -= delta
		if _net_refresh_t <= 0.0:
			_net_refresh_t = 0.4
			_refresh_friends()
	if _cam_t < 1.0:
		_cam_t = minf(1.0, _cam_t + delta / 0.45)
		var k := 1.0 - pow(1.0 - _cam_t, 3.0)
		camera.position = _cam_from_pos.lerp(_cam_to_pos, k)
		camera.look_at(_cam_from_look.lerp(_cam_to_look, k))
	# back to the hero angle a while after a drag
	if _drag_index == -1 and _idle_t > 4.0:
		model.rotation.y = lerp_angle(model.rotation.y, MODEL_YAW, minf(1.0, delta * 2.0))
	if start_btn and not start_btn.disabled:
		var s := 1.0 + sin(_time * 3.2) * 0.012
		start_btn.pivot_offset = start_btn.size * 0.5
		start_btn.scale = Vector2(s, s)
	if start_btn:
		start_btn.queue_redraw()
	if _ward_equip:
		_ward_equip.queue_redraw()
	if _name_plate and _main_ui.visible and camera:
		var feet := Vector3(model.global_position.x, PODIUM_TOP, 0.55)
		if not camera.is_position_behind(feet):
			var p := camera.unproject_position(feet)
			_name_plate.position = (p - Vector2(_name_plate.size.x * 0.5, 0)).round()


## Android back: closes the top-most layer (settings, credits, a popup, the wardrobe); with
## nothing open it asks before quitting; while START's match loading runs it does nothing.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if start_btn and start_btn.disabled:
		return                      # the match is loading
	if _find_settings():
		return                      # the panel closes itself
	if _modal:
		_close_modal()
	elif wardrobe:
		model.apply_bundle(String(Game.profile.bundle))
		_update_bundle_label(String(Game.profile.bundle))
		_close_wardrobe()
	else:
		_confirm_quit()


## "Quit the game?" as a system dialog: a full-width dark band with the emblem, the question,
## CANCEL (grey) and QUIT (yellow). Back or CANCEL closes it.
func _confirm_quit() -> void:
	_close_modal()
	_modal = Control.new()
	_modal.name = "QuitDialog"
	UI.full_rect(_modal)
	_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	ui.add_child(_modal)
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.62)
	UI.full_rect(shade)
	_modal.add_child(shade)
	var band := Control.new()
	band.anchor_right = 1.0
	band.anchor_top = 0.30
	band.anchor_bottom = 0.70
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.draw.connect(func() -> void: UI.draw_dialog_band(band, band.size))
	_modal.add_child(band)
	var em := UI.texture("emblem.png")
	if em:
		var t := TextureRect.new()
		t.texture = em
		t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		t.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		t.anchor_left = 0.16
		t.anchor_right = 0.16
		t.anchor_top = 0.5
		t.anchor_bottom = 0.5
		t.offset_left = -84
		t.offset_right = 84
		t.offset_top = -84
		t.offset_bottom = 84
		t.modulate = Color(1, 1, 1, 0.9)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
		band.add_child(t)
	var v := VBoxContainer.new()
	v.anchor_left = 0.3
	v.anchor_right = 0.95
	v.anchor_top = 0.0
	v.anchor_bottom = 1.0
	v.offset_top = 34
	v.offset_bottom = -26
	v.add_theme_constant_override("separation", 8)
	band.add_child(v)
	v.add_child(UI.label("QUIT THE GAME?", 38, UI.TEXT, "bold"))
	var bar := ColorRect.new()
	bar.color = UI.ACCENT
	bar.custom_minimum_size = Vector2(64, 4)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(bar)
	v.add_child(UI.spacer(2))
	v.add_child(UI.label("Your name, outfits, settings and progress stay saved on this phone.", 19, Color(1, 1, 1, 0.86), "semi"))
	var fill := UI.spacer(0)
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(fill)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 14)
	v.add_child(row)
	var cancel := UI.button("CANCEL", 20, "light", Vector2(190, 52))
	cancel.name = "QuitCancel"
	cancel.pressed.connect(_close_modal)
	row.add_child(cancel)
	var quit := UI.button("QUIT", 22, "primary", Vector2(190, 52))
	quit.name = "QuitConfirm"
	quit.pressed.connect(func() -> void: get_tree().quit())
	row.add_child(quit)
	_modal.modulate.a = 0.0
	_modal.create_tween().tween_property(_modal, "modulate:a", 1.0, 0.12)
