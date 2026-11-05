class_name Lobby
extends Node3D
## Lobby: our character large on a lit hexagonal podium in a container yard at sunset (cheap
## 3D: a few boxes and props, fog, one shadowed light); drag on the character to turn it.
## UI in the battle-royale lobby layout (original art, nothing to buy: no currency, no store):
## player card (profile picture, name + EDIT, level, XP line: a tap opens PROFILE) top-left, logo +
## glyph buttons top-right, a
## text menu on the left (ONLINE 1 VS 1, WARDROBE, CUSTOM HUD, SETTINGS, HOW TO PLAY) and, bottom
## right, match stats, the opponent chips (TRAINING GROUND: EASY / NORMAL / HARD bot or the
## DUMMY), the mode card (TRAINING GROUND or LONE WOLF on CARGO CAGE; a tap opens SELECT MODE)
## and the big START. START plays the card's mode: TRAINING GROUND shows the match loading
## overlay (Loading.start_match) and enters the arena; LONE WOLF opens the ONLINE window (a duel
## starts when a challenge is accepted). WARDROBE opens the outfit picker (every outfit free:
## item cards, preview on the podium, EQUIP / BACK).
## This file has the 3D stage, the top bar, the menus, the mode card, START, the settings panel
## and input. Four parts have their own files: helpers the lobby makes, which build under `ui`
## and reach back through their `lobby`: LobbyDialogs (`dialogs`: the popup frame, SELECT MODE,
## HOW TO PLAY, the name editor, the quit dialog), LobbyFriends (`friends`: ONLINE 1 VS 1, custom
## rooms, the net signals), LobbyWardrobe (`wardrobe_ui`: WARDROBE) and LobbyProfile
## (`profile_ui`: PROFILE and another player's card).
## Node names used by the screenshot walkthrough: StartButton, ModeCard, Diff_<EASY|NORMAL|HARD|
## DUMMY>, SettingsButton, BundlesButton (WARDROBE), Bundle_<id>, EquipButton.

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
const SKYLINE := "res://assets/ui/lobby_skyline.png"
## The art each mode shows (mode card, SELECT MODE): [texture, the part of it to show]. LONE
## WOLF is the two fighters facing off, TRAINING GROUND our hero aiming at a far-off target.
const MODE_ART := {
	"training": ["keyart_clean.jpg", Rect2(380, 150, 1320, 660)],
	"lonewolf": ["mode_lonewolf.jpg", Rect2(0, 30, 640, 320)],
}

var model: CharacterModel
var camera: Camera3D
var ui: CanvasLayer
var start_btn: Button
## The mode card above START (node ModeCard: opens SELECT MODE) and what follows the mode.
var mode_card: Button
var _mode_label: Label
var _mode_sub: Label
var _diff_row: HBoxContainer
var _stats_row: HBoxContainer
## The lobby's parts in their own files (see above).
var dialogs := LobbyDialogs.new(self)
var friends := LobbyFriends.new(self)
var wardrobe_ui := LobbyWardrobe.new(self)
var profile_ui := LobbyProfile.new(self)
## The open popup, the wardrobe layer while it is open and the outfit it previews: the parts keep
## them, the screenshot tours read them here.
var _modal: Control:
	get:
		return dialogs.modal
var wardrobe: Control:
	get:
		return wardrobe_ui.layer
@warning_ignore("unused_private_class_variable")
var _preview_bundle: String:
	get:
		return wardrobe_ui.preview_bundle
var _main_ui: Control
var _drag_index := -1
var _idle_t := 0.0
var _name_label: Label
var _avatar_view: Control
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


func _ready() -> void:
	_build_stage()
	_build_ui()
	if not bool(Game.profile.get("name_set", false)):
		_edit_name.call_deferred(true)
	Audio.play_music("lobby_music", -4.0)
	Game.mark("lobby ready")
	# Where START is on screen, for the emulator test, once the layout has settled (a method
	# connection is dropped automatically if the lobby is left first).
	get_tree().process_frame.connect(_mark_start, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	get_viewport().size_changed.connect(_on_viewport_resized)
	Game.settings_changed.connect(_apply_quality)
	# The net services' signals; online presence starts with the lobby.
	friends.on_lobby_ready()


## The graphics setting on the stage, at build and again on every change (settings_changed): 3D
## resolution and anti-aliasing (the stage, about 150-170 draw calls, is a little lighter than the
## arena, so each level gets a bit more than in a match), and from MEDIUM up the glow, the key
## light's shadow and the dust motes (CPU-simulated: LOW and VISUAL EFFECTS off drop them). The
## stage's PerfGovernor only measures the phone for AUTO graphics (no dynamic resolution here).
func _apply_quality() -> void:
	var g := clampi(int(Game.settings.graphics), 0, STAGE_QUALITY.size() - 1)
	var q: Array = STAGE_QUALITY[g]
	var vp := get_viewport()
	vp.scaling_3d_scale = float(q[0])
	vp.msaa_3d = int(q[1]) as Viewport.MSAA
	var stage_env := get_node_or_null(^"StageEnv") as WorldEnvironment
	if stage_env:
		stage_env.environment.glow_enabled = g >= 1
	var key_light := get_node_or_null(^"KeyLight") as Light3D
	if key_light:
		key_light.shadow_enabled = g >= 1
	var motes := get_node_or_null(^"Motes") as CPUParticles3D
	if motes:
		motes.visible = g >= 1 and bool(Game.settings.visual_effects)
		motes.emitting = motes.visible
	PerfGovernor.attach(self, float(q[0]), false)


func _mark_start() -> void:
	Game.mark_ui("start", start_btn, start_btn.size / 2.0)


func _exit_tree() -> void:
	friends.on_lobby_exit()
	profile_ui.on_lobby_exit()
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
	var vp := get_viewport()
	_vp_msaa = vp.msaa_3d
	_vp_scale = vp.scaling_3d_scale
	var env := WorldEnvironment.new()
	env.name = "StageEnv"
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
	e.glow_intensity = 0.55               # glow on from MEDIUM (_apply_quality)
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
	key.name = "KeyLight"                 # its shadow from MEDIUM (_apply_quality)
	key.position = Vector3(3.1, 4.0, 2.7)
	key.light_energy = 2.5
	key.spot_range = 12.0
	key.spot_angle = 28.0
	key.spot_attenuation = 0.8
	key.light_color = Color(1.0, 0.9, 0.8)
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
	_apply_quality()


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
	_build_left_menu(root)
	_build_right_column(root)
	_build_bottom_left(root)
	_build_name_plate(root)


func _build_top_bar(root: Control) -> void:
	# Player card: profile picture with level badge, name + EDIT, level and a thin XP line. The
	# whole card is a button that opens PROFILE (a big touch target); the pencil opens the name
	# editor.
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
		_open_profile())
	root.add_child(card)
	var av := Panel.new()
	av.position = Vector2(8, 5)
	av.size = Vector2(52, 52)
	av.mouse_filter = Control.MOUSE_FILTER_IGNORE
	av.add_theme_stylebox_override("panel", UI.box(Color(0.1, 0.1, 0.12), 0, 2, UI.ACCENT, 0.0))
	card.add_child(av)
	# the profile picture PROFILE's NAME CARD picks (the emblem by default)
	_avatar_view = Control.new()
	_avatar_view.name = "PlayerAvatar"
	_avatar_view.position = Vector2(3, 3)
	_avatar_view.size = Vector2(46, 46)
	_avatar_view.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_avatar_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar_view.draw.connect(func() -> void:
		LobbyProfile.draw_avatar(_avatar_view, String(Game.profile.avatar), Rect2(Vector2.ZERO, _avatar_view.size)))
	av.add_child(_avatar_view)
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


## The text menu, centred on the left edge between the player card and the outfit line.
func _build_left_menu(root: Control) -> void:
	var menu := VBoxContainer.new()
	menu.name = "Menu"
	menu.add_theme_constant_override("separation", 6)
	root.add_child(menu)
	var items := [
		["ONLINE 1 VS 1", "v_player", "FriendsButton", _open_friends],
		["WARDROBE", "v_wardrobe", "BundlesButton", _open_wardrobe],
		["CUSTOM HUD", "v_hud", "CustomHudButton", Game.goto_hud_editor],
		["SETTINGS", "v_settings", "SettingsMenuButton", _open_settings],
		["HOW TO PLAY", "v_info", "HowToPlayButton", _how_to_play],
	]
	for it in items:
		menu.add_child(_menu_row(String(it[0]), String(it[1]), String(it[2]), it[3]))
	menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_MINSIZE)
	menu.grow_vertical = Control.GROW_DIRECTION_BOTH


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
	# Mode card above it: the mode START plays (name, map, format, the mode's art); a tap opens
	# SELECT MODE.
	mode_card = Button.new()
	mode_card.name = "ModeCard"
	mode_card.focus_mode = Control.FOCUS_NONE
	for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		mode_card.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	mode_card.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	mode_card.offset_left = -430
	mode_card.offset_right = -12
	mode_card.offset_top = -170
	mode_card.offset_bottom = -98
	mode_card.draw.connect(_draw_mode_card)
	for sig in ["mouse_entered", "mouse_exited", "button_down", "button_up"]:
		mode_card.connect(sig, mode_card.queue_redraw)
	mode_card.pressed.connect(func() -> void:
		Audio.play("ui_click", -4.0)
		_select_mode())
	root.add_child(mode_card)
	var text := VBoxContainer.new()
	text.position = Vector2(20, 2)
	text.add_theme_constant_override("separation", -4)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mode_card.add_child(text)
	_mode_label = UI.shadowed(UI.label("", 32, UI.AMBER, "heavy"))
	_mode_label.name = "ModeName"
	text.add_child(_mode_label)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.add_child(line)
	line.add_child(UI.label("CARGO CAGE", 22, UI.TEXT, "heavy"))
	_mode_sub = UI.label("", 14, UI.TEXT_DIM, "bold")
	_mode_sub.name = "ModeFormat"
	_mode_sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	line.add_child(_mode_sub)
	# TRAINING GROUND's opponent above the card: a bot level or the target dummy.
	_diff_row = HBoxContainer.new()
	_diff_row.name = "Difficulty"
	_diff_row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_diff_row.offset_left = -430
	_diff_row.offset_right = -12
	_diff_row.offset_top = -214
	_diff_row.offset_bottom = -178
	_diff_row.add_theme_constant_override("separation", 6)
	_diff_row.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(_diff_row)
	var group := ButtonGroup.new()
	for i in Game.DIFFICULTY_NAMES.size():
		_diff_row.add_child(_diff_chip(String(Game.DIFFICULTY_NAMES[i]), i, group))
	_diff_row.add_child(_diff_chip("DUMMY", -1, group))
	# Match stats chips (above the chips; one row lower when LONE WOLF hides them).
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
	_stats_row = stats
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
	_refresh_mode()


## Draws a mode's art into `dest` of `ci`, cut from its MODE_ART part to dest's shape (centred).
static func draw_mode_art(ci: CanvasItem, m: String, dest: Rect2) -> void:
	var art: Array = MODE_ART.get(m, MODE_ART[Game.DEFAULT_MODE])
	var tex := UI.texture(String(art[0]))
	if tex == null:
		ci.draw_rect(dest, Color(0.12, 0.11, 0.1))
		return
	var src: Rect2 = art[1]
	var want := dest.size.x / maxf(dest.size.y, 1.0)
	if src.size.x / src.size.y > want:
		var w := src.size.y * want
		src = Rect2(src.position.x + (src.size.x - w) * 0.5, src.position.y, w, src.size.y)
	else:
		var h := src.size.x / want
		src = Rect2(src.position.x, src.position.y + (src.size.y - h) * 0.5, src.size.x, h)
	ci.draw_texture_rect_region(tex, dest, src)


func _draw_mode_card() -> void:
	var c := mode_card
	var s := c.size
	var a := 0.98 if c.is_pressed() else 0.92
	var pts := UI.chamfer_points(Rect2(Vector2.ZERO, s), 12.0, ["tl"])
	var warm := Color(0.16, 0.12, 0.07, a)
	var dark := Color(0.07, 0.06, 0.05, a)
	c.draw_polygon(pts, PackedColorArray([warm, warm, dark, dark, Color(0.12, 0.09, 0.06, a)]))
	var thumb := Rect2(s.x - 128, 6, 120, s.y - 12)
	draw_mode_art(c, Game.mode, thumb)
	c.draw_rect(thumb, Color(1, 1, 1, 0.35), false, 1.5)
	# a dropdown chevron beside the mode name: tap to choose the other mode
	var hot := c.is_hovered() or c.is_pressed()
	var cx := s.x - 150.0
	c.draw_polyline(PackedVector2Array([Vector2(cx - 9, 18), Vector2(cx, 27), Vector2(cx + 9, 18)]),
		UI.ACCENT if hot else Color(1, 1, 1, 0.8), 3.0, true)
	c.draw_rect(Rect2(0, s.y - 2, s.x, 2), UI.ACCENT if hot else Color(UI.AMBER, 0.8))


## The mode card, the opponent chips (TRAINING GROUND only) and the stats row follow Game.mode and
## the chosen opponent (Game.practice: the target dummy).
func _refresh_mode() -> void:
	var training := Game.mode == "training"
	_mode_label.text = Game.mode_name()
	if not training:
		_mode_sub.text = "1 VS 1 ONLINE"
	elif Game.practice:
		_mode_sub.text = "TARGET DUMMY"
	else:
		_mode_sub.text = "1 VS BOT  ·  FIRST TO %d" % Game.rounds_to_win()
	_diff_row.visible = training
	_stats_row.offset_top = -258.0 if training else -214.0
	_stats_row.offset_bottom = _stats_row.offset_top + 36.0
	mode_card.queue_redraw()


## A chip for TRAINING GROUND's opponent: a bot level (idx into Game.DIFFICULTY_NAMES) or, with
## idx -1, the target dummy.
func _diff_chip(text: String, idx: int, group: ButtonGroup) -> Button:
	var b := Button.new()
	b.name = "Diff_" + text
	b.toggle_mode = true
	b.button_group = group
	b.button_pressed = Game.practice if idx < 0 else (not Game.practice and idx == int(Game.settings.difficulty))
	b.focus_mode = Control.FOCUS_NONE
	b.text = text
	b.custom_minimum_size = Vector2(100, 36)
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
		Game.practice = idx < 0
		if idx >= 0:
			Game.settings.difficulty = idx
			Game.save_settings()
		_refresh_mode())
	return b


func _build_bottom_left(root: Control) -> void:
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
	_bundle_label = UI.shadowed(UI.label("", 22, UI.TEXT, "bold"))
	_bundle_label.name = "OutfitName"
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


## The player card top-left follows the profile (PROFILE picks the picture, the editor the name).
func refresh_player_card() -> void:
	_name_label.text = String(Game.profile.name)
	_plate_label.text = String(Game.profile.name)
	if _avatar_view:
		_avatar_view.queue_redraw()


## The outfit line bottom-left: the outfit's name in its own colour.
func _update_bundle_label(id: String) -> void:
	var info := CharacterModel.bundle_info(id)
	_bundle_label.text = String(info.name)
	_bundle_label.add_theme_color_override("font_color", LobbyWardrobe.outfit_color(String(info.id)))


## START plays the mode on the card: TRAINING GROUND loads the match against the bot (or the
## target dummy) at once; LONE WOLF opens the ONLINE window, where a duel starts once a player
## accepts a challenge (or the host of a custom room starts it).
func _start() -> void:
	if start_btn.disabled:
		return
	if Game.mode == "lonewolf":
		_open_friends("online")
		return
	Game.online = false
	start_btn.disabled = true
	UI.set_caption(start_btn, "LOADING")
	Loading.start_match(self)


func _select_mode() -> void:
	dialogs.select_mode()


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


# ---------------------------------------------------------------- the parts in their own files

func _how_to_play() -> void:
	dialogs.how_to_play()


func _edit_name(first := false) -> void:
	dialogs.edit_name(first)


func _open_friends(kind := "online") -> void:
	friends.open(kind)


func _open_wardrobe() -> void:
	wardrobe_ui.open()


func _open_profile() -> void:
	profile_ui.open()


func _close_wardrobe() -> void:
	wardrobe_ui.close()


## Moves the camera to a view (the wardrobe's or the main one) over the next 0.45 s.
func _move_camera(pos: Vector3, look: Vector3) -> void:
	# start from where the camera looks now (also mid-transition)
	_cam_from_pos = camera.position
	_cam_from_look = camera.position + (-camera.global_basis.z) * camera.position.distance_to(_cam_to_look)
	_cam_to_pos = pos
	_cam_to_look = look
	_cam_t = 0.0


# ---------------------------------------------------------------- input / anim

func _modal_open() -> bool:
	return _modal != null or _find_settings() != null or profile_ui.layer != null


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
	friends.process(delta)
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
	wardrobe_ui.process()
	profile_ui.process(delta)
	if _name_plate and _main_ui.visible and camera:
		var feet := Vector3(model.global_position.x, PODIUM_TOP, 0.55)
		if not camera.is_position_behind(feet):
			var p := camera.unproject_position(feet)
			_name_plate.position = (p - Vector2(_name_plate.size.x * 0.5, 0)).round()


## Android back: closes the top-most layer (settings, a popup: its own way back, PROFILE, the
## wardrobe); with nothing open it asks before quitting; while START's match loading runs it does
## nothing.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_GO_BACK_REQUEST:
		return
	if start_btn and start_btn.disabled:
		return                      # the match is loading
	if _find_settings():
		return                      # the panel closes itself
	if _modal:
		dialogs.back()
	elif profile_ui.layer:
		profile_ui.close()
	elif wardrobe:
		model.apply_bundle(String(Game.profile.bundle))
		_update_bundle_label(String(Game.profile.bundle))
		_close_wardrobe()
	else:
		dialogs.confirm_quit()
